# GATE 10 — Capability Expansion Week 2: Productivity Boost

> **Status**: Pending (richiede GATE 9 chiuso)
> **Effort stimato**: ~14h (≈2 giorni lavorativi)
> **Bloccanti pre-gate**: GATE 9 chiuso (Week 1 Power user unlock shipped: `run_shortcut` + `set_homekit_scene` + `web_search` + Onboarding Layer A); iPhone 15 Pro+ Apple Intelligence; iOS 18+ per Translation framework; EventKit + UserNotifications permission flow già funzionante
> **Sblocca**: GATE 11 (Week 3 Ambient & social — HomeKit advanced, location, email/Telegram/Signal)
> **Funzione consegnata (1 frase)**: 8 nuovi tool produttività (calendar/note/clipboard/utility/knowledge) + Layer B conversational discovery — l'utente può dire *"crea evento con Marco venerdì alle 15"*, *"aggiungi alla nota lavoro idee Q3"*, *"traduci 'thank you' in giapponese"*, *"cosa sai fare?"* e GIGI esegue o suggerisce capability context-aware.

---

## 1. Obiettivo

GATE 9 ha aperto il rubinetto delle capability con 3 tool ad alto ROI + onboarding. GATE 10 estende il toolkit di **8 nuovi tool** che coprono workflow produttivi tipici (calendar/note/utility/knowledge mini) e introduce la **Layer B conversational discovery** — il primo meccanismo per cui l'utente può chiedere a GIGI cosa sa fare in linguaggio naturale, ricevendo risposte **context-aware** (mattina vs sera, casa vs fuori, recent activity).

Output concreto:
- 8 nuovi `Tool` struct in `GigiFoundationToolRegistry.swift` (organizzati per category secondo §7 ADR-0010)
- `GigiCapabilityCatalog.swift` (nuovo file ~150 righe) — lookup `tool_name → user_example + category + context_hints`
- `GigiRequestRouter.swift` modificato: intercept pseudo-tool `discover_capabilities` PRIMA del normal tool calling
- `GigiActionDispatcher+Productivity.swift` (nuovo file) — handler bridge per i nuovi tool
- Permission flow EventKit (`NSCalendarsFullAccessUsageDescription`) wireato a primo uso `create_calendar_event`
- Shortcut bridge documentato per `add_to_note` (utente installa "GIGI Append to Note" shortcut)

Razionale Layer B: senza meccanismo di scoperta i tool diventano "feature ghetto" (vedi piano §R3) — l'utente non sa cosa GIGI sa fare oltre i 3-5 esempi dell'onboarding. *"What can you do?"* deve ritornare risposte differenti se è mattina (suggerisce `read_calendar`/`create_calendar_event`) vs sera (suggerisce `set_alarm` per domani). Context-aware = 1° citizen, non add-on.

---

## 2. Pre-condizioni

- [ ] GATE 0 → 9 chiusi
- [ ] GATE 9 ha shipped: `run_shortcut`, `set_homekit_scene`, `web_search`, `GigiOnboardingFlow.swift` (Layer A)
- [ ] `GigiFoundationToolRegistry.allTools` ha 18 tool (15 GATE 3 + 3 GATE 9)
- [ ] EventKit framework linkato in target `GIGI` (verifica `xcodebuild -showBuildSettings | grep -i eventkit`)
- [ ] `NSCalendarsFullAccessUsageDescription` presente in `Info.plist` ("GIGI needs calendar access to create and read events you ask about.")
- [ ] iOS 18+ deployment target (Translation framework richiede iOS 18 minimum)
- [ ] iPhone 15 Pro+ fisico con Apple Intelligence attivata
- [ ] Shortcut "GIGI Append to Note" creato dall'utente (documentato in `docs/runbooks/gate-10-shortcut-setup.md`) — `add_to_note` dipende da questa Shortcut
- [ ] `GigiActionDispatcher.bridge.executeRaw(label:, params:)` confermato funzionante (testato in GATE 3/9)

---

## 3. Task implementativi

### Task 10.1 — `create_calendar_event` tool (EventKit write) — 4h

**Files**:
- MODIFY: `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` (+50 righe)
- CREATE: `02_GIGI_APP/GIGI/GigiActionDispatcher+Productivity.swift` (~120 righe, contiene handler per tutti i tool 10.1-10.3)
- MODIFY: `02_GIGI_APP/GIGI/GigiActionBridge.swift` (+15 righe, route `create_calendar_event` al nuovo handler)
- MODIFY: `02_GIGI_APP/GIGI/Info.plist` (verify `NSCalendarsFullAccessUsageDescription` presente; se no, aggiungere)

**Pattern Tool struct**:
```swift
@available(iOS 26, *)
struct CreateCalendarEventTool: Tool {
    let name = "create_calendar_event"
    let description = "Create a calendar event with title, start time, and optional location and attendees. Use when the user asks to schedule, book, or add an event to their calendar."

    @Generable
    struct Arguments {
        @Guide(description: "Event title like 'Meeting with Marco' or 'Dentist appointment'.")
        var title: String

        @Guide(description: "Start time in natural language: 'Friday at 3pm', 'tomorrow 9am', 'May 20 14:00'.")
        var start: String

        @Guide(description: "Duration in natural language like '1 hour', '30 minutes'. Default 1 hour if unspecified.")
        var duration: String

        @Guide(description: "Location string or empty if not specified.")
        var location: String

        @Guide(description: "Notes for the event, or empty.")
        var notes: String
    }

    func call(arguments: Arguments) async -> String {
        return await GigiActionDispatcher.shared.bridge.executeRaw(
            label: "create_calendar_event",
            params: [
                "title": arguments.title,
                "start": arguments.start,
                "duration": arguments.duration,
                "location": arguments.location,
                "notes": arguments.notes
            ]
        )
    }
}
```

**Handler `GigiActionDispatcher+Productivity.swift`**:
```swift
extension GigiActionDispatcher {
    func handleCreateCalendarEvent(params: [String: String]) async -> String {
        let store = EKEventStore()
        // Request access iOS 17+ API
        let granted = try? await store.requestFullAccessToEvents()
        guard granted == true else { return "Calendar access denied" }

        let event = EKEvent(eventStore: store)
        event.title = params["title"] ?? ""
        event.startDate = parseNaturalDate(params["start"] ?? "") ?? Date().addingTimeInterval(3600)
        event.endDate = event.startDate.addingTimeInterval(parseDuration(params["duration"] ?? "1 hour") ?? 3600)
        event.location = params["location"]
        event.notes = params["notes"]
        event.calendar = store.defaultCalendarForNewEvents

        do {
            try store.save(event, span: .thisEvent)
            return "Event '\(event.title!)' created for \(event.startDate.formatted())"
        } catch {
            return "Failed to create event: \(error.localizedDescription)"
        }
    }
}
```

Note: `parseNaturalDate` e `parseDuration` helper. Riusare logic da `GigiActionDispatcher+Native.swift` se esistente per `set_reminder` — date parsing è simile.

### Task 10.2 — `add_to_note` tool (Shortcut bridge) — 2h

**Files**:
- MODIFY: `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` (+30 righe)
- MODIFY: `02_GIGI_APP/GIGI/GigiActionDispatcher+Productivity.swift` (+25 righe)
- CREATE: `docs/runbooks/gate-10-shortcut-setup.md` (~40 righe, guida utente per creare "GIGI Append to Note" Shortcut)

**Razionale Shortcut bridge**: Apple non espone API pubbliche `NotesKit` per write — `add_to_note` non può essere implementato senza Shortcut bridge. L'utente installa una Shortcut chiamata "GIGI Append to Note" che accetta input dict `{note_title, content}` e fa il "Find Note" + "Append to Note" action. GIGI invoca via `shortcuts://run-shortcut?name=GIGI%20Append%20to%20Note&input=text&text=...`.

**Tool struct**:
```swift
struct AddToNoteTool: Tool {
    let name = "add_to_note"
    let description = "Append text to an existing note in Apple Notes by title. Use when the user wants to add an entry, idea, or memo to a specific note they keep."

    @Generable
    struct Arguments {
        @Guide(description: "Title of the existing note like 'Work', 'Shopping list', 'Ideas'.")
        var noteTitle: String

        @Guide(description: "Text content to append to the note.")
        var content: String
    }

    func call(arguments: Arguments) async -> String {
        return await GigiActionDispatcher.shared.bridge.executeRaw(
            label: "add_to_note",
            params: ["note_title": arguments.noteTitle, "content": arguments.content]
        )
    }
}
```

**Handler**: costruire JSON input per la Shortcut, encodare in URL `x-callback-url`, aprire con `UIApplication.shared.open`. Se Shortcut non installata → ritornare *"Please install the 'GIGI Append to Note' Shortcut first. See setup guide."*

### Task 10.3 — `read_clipboard` + `get_device_battery` + `toggle_flashlight` (utility) — 2h

**Files**:
- MODIFY: `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` (+60 righe)
- MODIFY: `02_GIGI_APP/GIGI/GigiActionDispatcher+Productivity.swift` (+50 righe)

**3 Tool struct**:

```swift
struct ReadClipboardTool: Tool {
    let name = "read_clipboard"
    let description = "Read the current text content of the clipboard. Use when the user asks 'what's in my clipboard' or 'read what I just copied'."

    @Generable
    struct Arguments { /* empty */ }

    func call(arguments: Arguments) async -> String {
        return await GigiActionDispatcher.shared.bridge.executeRaw(label: "read_clipboard", params: [:])
    }
}

struct GetDeviceBatteryTool: Tool {
    let name = "get_device_battery"
    let description = "Tell the current battery level and charging status of the iPhone. Use when the user asks about battery."
    @Generable struct Arguments { }
    func call(arguments: Arguments) async -> String {
        return await GigiActionDispatcher.shared.bridge.executeRaw(label: "get_device_battery", params: [:])
    }
}

struct ToggleFlashlightTool: Tool {
    let name = "toggle_flashlight"
    let description = "Turn the iPhone flashlight on or off. Use when the user asks for light, torch, or flashlight."
    @Generable
    struct Arguments {
        @Guide(description: "Either 'on', 'off', or 'toggle' (default).")
        var state: String
    }
    func call(arguments: Arguments) async -> String {
        return await GigiActionDispatcher.shared.bridge.executeRaw(label: "toggle_flashlight", params: ["state": arguments.state])
    }
}
```

**Handlers**:
- `read_clipboard`: `UIPasteboard.general.string` — speak result o "Clipboard is empty"
- `get_device_battery`: `UIDevice.current.batteryLevel` (after enabling monitoring) + `batteryState` → speech "Battery 78%, charging"
- `toggle_flashlight`: `AVCaptureDevice.default(for: .video)?.torchMode` toggle

Note: `toggle_flashlight` richiede `AVFoundation` framework + Camera privacy entitlement (già presente per altri tool). Battery monitoring enable on App start: `UIDevice.current.isBatteryMonitoringEnabled = true` in `AppDelegate`/`@main App.init`.

### Task 10.4 — `define_word` + `calculate_math` + `translate_text` (knowledge mini) — 4h

**Files**:
- MODIFY: `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` (+80 righe)
- CREATE: `02_GIGI_APP/GIGI/GigiActionDispatcher+Knowledge.swift` (~100 righe)
- MODIFY: `02_GIGI_APP/GIGI/GigiActionBridge.swift` (+10 righe, route 3 nuovi labels)

**3 Tool struct**:

```swift
struct DefineWordTool: Tool {
    let name = "define_word"
    let description = "Read a dictionary definition of a word. Use when the user asks 'what does X mean', 'define X', or 'meaning of X'."
    @Generable
    struct Arguments {
        @Guide(description: "Single word or short phrase to define.") var word: String
        @Guide(description: "Language code like 'en', 'it'. Default 'en'.") var language: String
    }
    func call(arguments: Arguments) async -> String { /* bridge executeRaw */ }
}

struct CalculateMathTool: Tool {
    let name = "calculate_math"
    let description = "Evaluate a math expression. Use for arithmetic, percentages, simple equations like '15% of 250' or '(34+56)*2'."
    @Generable
    struct Arguments {
        @Guide(description: "Math expression as a string, e.g. '15 * 0.20' or '(34+56)*2'.") var expression: String
    }
    func call(arguments: Arguments) async -> String { /* bridge */ }
}

struct TranslateTextTool: Tool {
    let name = "translate_text"
    let description = "Translate text from one language to another. Use when the user asks to translate a phrase."
    @Generable
    struct Arguments {
        @Guide(description: "Text to translate.") var text: String
        @Guide(description: "Source language code or 'auto' for auto-detect.") var fromLang: String
        @Guide(description: "Target language code like 'it', 'en', 'ja', 'fr', 'es'.") var toLang: String
    }
    func call(arguments: Arguments) async -> String { /* bridge */ }
}
```

**Handlers `GigiActionDispatcher+Knowledge.swift`**:

```swift
import Translation

extension GigiActionDispatcher {
    func handleDefineWord(params: [String: String]) async -> String {
        let word = params["word"] ?? ""
        guard UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: word) else {
            return "No definition found for '\(word)'"
        }
        // Present UIReferenceLibraryViewController OR return concise definition via local API
        // For voice-first: use NSAttributedString from system dictionary if accessible.
        await MainActor.run {
            let vc = UIReferenceLibraryViewController(term: word)
            UIApplication.shared.topMostViewController()?.present(vc, animated: true)
        }
        return "Showing definition of '\(word)'"
    }

    func handleCalculateMath(params: [String: String]) async -> String {
        let expr = params["expression"] ?? ""
        // Sanitize: allow only digits, operators, parentheses, dots, %, spaces
        let sanitized = expr.replacingOccurrences(of: "%", with: "*0.01")
        let nsExpr = NSExpression(format: sanitized)
        if let result = nsExpr.expressionValue(with: nil, context: nil) {
            return "\(result)"
        }
        return "Could not evaluate '\(expr)'"
    }

    @available(iOS 18, *)
    func handleTranslateText(params: [String: String]) async -> String {
        let text = params["text"] ?? ""
        let from = params["from_lang"] ?? "auto"
        let to = params["to_lang"] ?? "en"
        // Translation framework iOS 18+
        let source = from == "auto" ? nil : Locale.Language(identifier: from)
        let target = Locale.Language(identifier: to)
        let session = TranslationSession(installedSource: source, target: target)
        do {
            let response = try await session.translate(text)
            return response.targetText
        } catch {
            return "Translation failed: \(error.localizedDescription)"
        }
    }
}
```

Note Translation: iOS 18+ richiede `TranslationSession.Configuration` + view modifier `.translationTask(_:)` in molti casi. Per voice-only (no UI) usare `TranslationSession` standalone se possibile, altrimenti fallback presentando un `Translation` view modifier su un host view di GIGI (acceptable se la prima translation richiede language pack download — UI flow è expected).

### Task 10.5 — Layer B Conversational Discovery (router intercept) — 4h

**Files**:
- CREATE: `02_GIGI_APP/GIGI/GigiCapabilityCatalog.swift` (~150 righe)
- MODIFY: `02_GIGI_APP/GIGI/GigiRequestRouter.swift` (+60 righe, intercept BEFORE normal classification)
- MODIFY: `02_GIGI_APP/GIGI/GigiFoundationSession.swift` (+20 righe, helper per context-aware top-3 selection via Apple FM)

**GigiCapabilityCatalog.swift structure**:

```swift
struct CapabilityEntry {
    let toolName: String              // canonical action name
    let category: CapabilityCategory   // system|social|productivity|entertainment|ambient|knowledge|automation
    let userExample: String            // pronounceable example phrase
    let contextHints: Set<ContextHint> // morning|evening|home|outdoors|recent_call|recent_event...
}

enum CapabilityCategory: String, CaseIterable {
    case system, social, productivity, entertainment, ambient, knowledge, automation
}

enum ContextHint: Hashable {
    case morning, evening, atHome, outdoors, recentCall, recentEvent, lowBattery
}

@MainActor
final class GigiCapabilityCatalog {
    static let shared = GigiCapabilityCatalog()

    let entries: [CapabilityEntry] = [
        .init(toolName: "set_timer", category: .system,
              userExample: "Set a timer for 5 minutes",
              contextHints: []),
        .init(toolName: "create_calendar_event", category: .productivity,
              userExample: "Create a meeting with Marco Friday at 3pm",
              contextHints: [.morning]),
        .init(toolName: "read_calendar", category: .productivity,
              userExample: "What's on my calendar today",
              contextHints: [.morning]),
        .init(toolName: "set_alarm", category: .system,
              userExample: "Wake me at 7am tomorrow",
              contextHints: [.evening]),
        .init(toolName: "set_homekit_scene", category: .ambient,
              userExample: "Activate movie scene",
              contextHints: [.evening, .atHome]),
        .init(toolName: "translate_text", category: .knowledge,
              userExample: "Translate 'thank you' to Japanese",
              contextHints: [.outdoors]),
        // ... fill all 26 tools (15 from GATE 3 + 3 from GATE 9 + 8 from GATE 10)
    ]

    func discover(forQuery query: String, context: DiscoveryContext) -> DiscoveryResponse {
        let lower = query.lowercased()

        // Branch 1: "how do I X?" → semantic match a single tool
        if lower.starts(with: "how do i") || lower.starts(with: "how can i") || lower.contains("come faccio") {
            return findBestMatch(for: query)  // delegate semantic to Apple FM
        }

        // Branch 2: "what can you do with [calendar/homekit]?" → category enumeration
        if let category = extractCategory(from: lower) {
            return enumerateCategory(category)
        }

        // Branch 3: "what can you do?" → top-3 context-aware
        return contextAwareTop3(context: context)
    }

    private func contextAwareTop3(context: DiscoveryContext) -> DiscoveryResponse {
        let hour = Calendar.current.component(.hour, from: Date())
        let timeHint: ContextHint = hour < 11 ? .morning : (hour >= 18 ? .evening : .morning)
        let locHint: ContextHint = context.atHome ? .atHome : .outdoors

        let scored = entries.map { e -> (CapabilityEntry, Int) in
            let score = e.contextHints.contains(timeHint) ? 2 : 0
                      + (e.contextHints.contains(locHint) ? 1 : 0)
            return (e, score)
        }
        let top3 = scored.sorted { $0.1 > $1.1 }.prefix(3).map { $0.0 }
        return .topN(top3)
    }

    private func enumerateCategory(_ cat: CapabilityCategory) -> DiscoveryResponse {
        return .category(cat, entries.filter { $0.category == cat })
    }

    private func findBestMatch(for query: String) -> DiscoveryResponse {
        // Score by keyword overlap with userExample; ties broken by category priority
        // Optional: delegate to Apple FM via respondWithTools([])  to extract intent semantically.
        ...
    }
}

struct DiscoveryContext {
    let atHome: Bool          // derived from CLLocationManager + GeofenceHome
    let recentCallActive: Bool
    let recentEventCreated: Bool
    let batteryBelow20: Bool
}

enum DiscoveryResponse {
    case topN([CapabilityEntry])
    case category(CapabilityCategory, [CapabilityEntry])
    case singleMatch(CapabilityEntry)
}
```

**Router intercept `GigiRequestRouter.swift`**:

```swift
@MainActor
func route(text: String, history: [ChatMessage]) async -> RouteResult {
    // INTERCEPT Layer B BEFORE normal Apple FM router classification
    if isDiscoveryQuery(text) {
        let context = await DiscoveryContext.current()
        let response = GigiCapabilityCatalog.shared.discover(forQuery: text, context: context)
        let speech = renderDiscoveryResponse(response)
        return .speech(speech)
    }

    // Normal flow (GATE 2/3 path classification)
    let decision = try await classify(text: text, history: history)
    ...
}

private func isDiscoveryQuery(_ text: String) -> Bool {
    let lower = text.lowercased()
    let patterns = [
        "what can you do", "cosa sai fare", "che cosa puoi fare",
        "how do i ", "how can i ", "come faccio",
        "what else can you", "what other",
        "help me", "aiuto", "show me what"
    ]
    return patterns.contains { lower.contains($0) }
}
```

**Render speech**:
```swift
private func renderDiscoveryResponse(_ r: DiscoveryResponse) -> String {
    switch r {
    case .topN(let entries):
        let examples = entries.map { "say '\($0.userExample)'" }.joined(separator: ", ")
        return "I can help with several things. For example, \(examples). Want more?"
    case .category(let cat, let entries):
        let first3 = entries.prefix(3).map { "'\($0.userExample)'" }.joined(separator: ", ")
        return "For \(cat.rawValue) I can do: \(first3). Try any of these."
    case .singleMatch(let e):
        return "Just say: \(e.userExample)."
    }
}
```

---

## 4. Acceptance Criteria

### Tool registration

- [ ] **AC-10.1**: `GigiFoundationToolRegistry.allTools` ritorna **26 tool** (18 da GATE 3+9 + 8 nuovi)
- [ ] **AC-10.2**: I 8 nuovi `Tool` struct esistono, conformi a `Tool` protocol, con `@available(iOS 26, *)`
- [ ] **AC-10.3**: Tutte le `description` e i `@Guide` dei nuovi tool sono in inglese (regola CLAUDE.md)

### create_calendar_event

- [ ] **AC-10.4**: Su iPhone con Calendar permission granted, pronunciare *"Create event 'Meeting with Marco' Friday at 3pm for 1 hour"* → Apple FM invoca `CreateCalendarEventTool` → EventKit save → log `tool_invoked: create_calendar_event` → evento visibile in app Calendar
- [ ] **AC-10.5**: Primo uso con permission `notDetermined` → iOS alert `NSCalendarsFullAccessUsageDescription` mostrato → su grant, evento creato; su deny, risposta speech *"Calendar access denied"*

### add_to_note

- [ ] **AC-10.6**: Con Shortcut "GIGI Append to Note" installata, pronunciare *"Add to note 'Work' the text 'Q3 ideas: new pricing tier'"* → Shortcuts app si apre → testo aggiunto alla nota Work
- [ ] **AC-10.7**: Senza Shortcut installata, risposta *"Please install the 'GIGI Append to Note' Shortcut first"* (runbook citato)

### Utility (clipboard/battery/flashlight)

- [ ] **AC-10.8**: Pronunciare *"What's in my clipboard"* → speech ritorna il contenuto current pasteboard (o *"Clipboard is empty"*)
- [ ] **AC-10.9**: Pronunciare *"What's my battery"* → speech *"Battery 78%, charging"* (o not charging)
- [ ] **AC-10.10**: Pronunciare *"Turn on the flashlight"* → torch ON; *"Turn off the flashlight"* → torch OFF

### Knowledge mini (define/calculate/translate)

- [ ] **AC-10.11**: Pronunciare *"What does serendipity mean"* → `UIReferenceLibraryViewController` presented con definizione (o speech inline se accessibile)
- [ ] **AC-10.12**: Pronunciare *"Calculate 15 percent of 250"* → speech *"37.5"* via `NSExpression`
- [ ] **AC-10.13**: Pronunciare *"Translate 'thank you' to Japanese"* → speech *"Arigato gozaimasu"* (o testo equivalente) via Translation framework iOS 18+; primo uso può richiedere language pack download (acceptable)

### Layer B Conversational Discovery

- [ ] **AC-10.14**: Pronunciare *"What can you do?"* alle 9:00 (mattina) → top-3 risposta include almeno 1 tool con `contextHints: [.morning]` (`read_calendar` o `create_calendar_event`)
- [ ] **AC-10.15**: Pronunciare *"What can you do?"* alle 21:00 (sera) → top-3 risposta include almeno 1 tool con `contextHints: [.evening]` (`set_alarm` o `set_homekit_scene`)
- [ ] **AC-10.16**: Pronunciare *"How do I send a message?"* → risposta singolo match con esempio canonico *"Just say: 'send a message to Sara saying I'll be late'"*
- [ ] **AC-10.17**: Pronunciare *"What can you do with the calendar?"* → enumera 3+ tool category `productivity` con esempi
- [ ] **AC-10.18**: Discovery query intercepted BEFORE normal router classification — verificare via log `discovery_intercept: <query>` PRIMA del log `router_classify`

### Cross-cutting

- [ ] **AC-10.19**: Build verify: `xcodebuild` BUILD SUCCEEDED (host build via `.claude/local-build.sh`)
- [ ] **AC-10.20**: No regressioni — 15 tool E2E di GATE 3 + 3 tool GATE 9 continuano a funzionare (smoke test random subset 5)

---

## 5. Test E2E sul telefono (verificabili dall'utente)

- **E2E-10.1 — Calendar event creation**
  *"Create an event called 'Dentist appointment' next Tuesday at 10 in the morning for 30 minutes"* → check app Calendar: evento Tuesday 10:00-10:30 con titolo "Dentist appointment"

- **E2E-10.2 — Calendar event with location**
  *"Schedule lunch with Federico Friday at 1pm at Trattoria Romana"* → evento Friday 13:00, location "Trattoria Romana"

- **E2E-10.3 — Calendar permission flow**
  Disinstallare app, reinstall, prima query calendar → check iOS alert mostrato, grant → evento creato; deny → speech feedback corretto

- **E2E-10.4 — Add to existing note**
  Premessa: nota "Work" esiste in Apple Notes; Shortcut "GIGI Append to Note" installato.
  *"Add to my Work note the text 'idea: subscription tier for power users'"* → check nota Work: nuova riga in fondo

- **E2E-10.5 — Read clipboard**
  Copiare manualmente del testo (es. URL). *"What's in my clipboard?"* → speech legge il testo copiato

- **E2E-10.6 — Battery status**
  *"How's my battery?"* o *"Quanta batteria ho?"* → speech *"Battery X%, [charging|not charging]"*

- **E2E-10.7 — Flashlight on/off**
  *"Turn on the flashlight"* → torch ON; aspettare 3s; *"Turn off the flashlight"* → torch OFF

- **E2E-10.8 — Define word**
  *"What does pragmatic mean?"* → UIReferenceLibraryViewController presentato con definizione

- **E2E-10.9 — Math calculation**
  *"What's 15 percent of 240?"* → speech *"36"*

- **E2E-10.10 — Math complex**
  *"Calculate 34 plus 56 times 2"* → speech *"146"*

- **E2E-10.11 — Translation**
  *"Translate 'good morning' to French"* → speech *"Bonjour"* (primo uso può scaricare language pack)

- **E2E-10.12 — Translation Italian**
  *"Come si dice 'thank you' in giapponese?"* → speech traduzione giapponese

- **E2E-10.13 — Layer B "what can you do" morning**
  Alle ~9:00, *"What can you do?"* → response cita almeno 1 fra `read_calendar`/`create_calendar_event` con esempio pronounceable

- **E2E-10.14 — Layer B "what can you do" evening**
  Alle ~21:00, *"Cosa sai fare?"* → response cita almeno 1 fra `set_alarm`/`set_homekit_scene`

- **E2E-10.15 — Layer B "how do I X"**
  *"How do I send a Telegram?"* → response *"Just say: 'send a Telegram to Marco saying I'll be late'"* (o equivalent)

- **E2E-10.16 — Layer B "what else can you do with calendar"**
  *"What can you do with the calendar?"* → response enumera ≥3 tool category productivity (`create_calendar_event`, `read_calendar`, `find_free_slot`)

- **E2E-10.17 — Discovery does NOT route normally**
  Premessa: log Console.app attivo. *"What can you do?"* → log mostra `discovery_intercept` prima di qualsiasi `router_classify` o `apple_fm_session_respond`

---

## 6. Test post-creazione (verifica autonoma)

### 6.1 Verifica via grep

```bash
ROOT="C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/02_GIGI_APP/GIGI"

# 1. 8 nuovi Tool struct esistono
grep -E "struct (CreateCalendarEvent|AddToNote|ReadClipboard|GetDeviceBattery|ToggleFlashlight|DefineWord|CalculateMath|TranslateText)Tool: Tool" "$ROOT/GigiFoundationToolRegistry.swift" | wc -l
# Output atteso: 8

# 2. allTools array ha 26 elementi (15 GATE 3 + 3 GATE 9 + 8 GATE 10)
grep -A40 "static let allTools" "$ROOT/GigiFoundationToolRegistry.swift" | grep -c "Tool()"
# Output atteso: 26

# 3. GigiCapabilityCatalog esiste con entries
grep -c "CapabilityEntry(toolName:" "$ROOT/GigiCapabilityCatalog.swift"
# Output atteso: 26 (1 entry per tool)

# 4. discover_capabilities intercept presente nel router
grep -n "isDiscoveryQuery\|discovery_intercept" "$ROOT/GigiRequestRouter.swift"
# Output atteso: 2+ match (function + log)

# 5. Translation framework import
grep "import Translation" "$ROOT/GigiActionDispatcher+Knowledge.swift"
# Output atteso: 1 match

# 6. EventKit handler presente
grep "handleCreateCalendarEvent" "$ROOT/GigiActionDispatcher+Productivity.swift"
# Output atteso: 1 match

# 7. NSCalendarsFullAccessUsageDescription in Info.plist
grep -A1 "NSCalendarsFullAccessUsageDescription" "$ROOT/Info.plist"
# Output atteso: stringa permission

# 8. Bridge routing dei nuovi labels
grep -E "create_calendar_event|add_to_note|read_clipboard|get_device_battery|toggle_flashlight|define_word|calculate_math|translate_text" "$ROOT/GigiActionBridge.swift" | wc -l
# Output atteso: 8+
```

### 6.2 Verifica via xcodebuild + Console log

```bash
# Build via local-build.sh helper
bash .claude/local-build.sh build_ios

# Runtime — installare IPA, lanciare app, eseguire E2E-10.13 + E2E-10.17, ispezionare Console.app
log stream --predicate 'subsystem == "com.gigi.app"' --info | grep -E "discovery_intercept|tool_invoked|context_hint"
# Output atteso: prima discovery_intercept, poi nessun router_classify per quella query
```

### 6.3 Verifica runtime per ognuno degli 8 tool

Re-eseguire le 17 E2E sopra (o subset random di 8, uno per tool). Verificare via Console.app log `tool_invoked: <name>` E azione side-effect (event in calendar, note updated, clipboard read, etc.).

---

## 7. Rollback plan

Se Layer B discovery rivela bug bloccanti o un tool causa crash:

```bash
cd "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework"
git revert <SHA-gate-10>
```

Alternative meno destructive:
- Feature flag `gigi.feature.layer_b_discovery: bool` in `GigiRequestRouter`. Default `true`. Off → intercept disabilitato, *"what can you do?"* cade su normal classification (probabile `delegate_cloud` Claude fallback) — meno utile ma non rompe nulla.
- Feature flag `gigi.feature.gate10_tools: bool` — toggle che skippa la registrazione degli 8 nuovi tool in `allTools`. Apple FM non li vede, fallback router non li conosce → query cadono su `delegate_cloud`.
- Per singolo tool problematico (es. `translate_text` se Translation framework su iOS 18.0 ha bug): rimuovere SOLO quel tool da `allTools` finché iOS 18.x patch.

Side effects:
- UserDefaults: nessuno nuovo aggiunto
- Permission: `NSCalendarsFullAccessUsageDescription` resta in Info.plist anche dopo rollback (no harm, descrizione user-facing dormiente)
- Shortcut "GIGI Append to Note" installata dall'utente: resta nel sistema utente (non removable da app, ma harmless senza il bridge)

---

## 8. Files modificati / creati

| Path | Operazione | Righe stimate |
|---|---|---|
| `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` | MODIFY (+8 Tool struct + allTools update) | +220 |
| `02_GIGI_APP/GIGI/GigiActionDispatcher+Productivity.swift` | CREATE | ~200 |
| `02_GIGI_APP/GIGI/GigiActionDispatcher+Knowledge.swift` | CREATE | ~100 |
| `02_GIGI_APP/GIGI/GigiActionBridge.swift` | MODIFY (route 8 new labels) | +30 |
| `02_GIGI_APP/GIGI/GigiCapabilityCatalog.swift` | CREATE | ~180 |
| `02_GIGI_APP/GIGI/GigiRequestRouter.swift` | MODIFY (Layer B intercept) | +60 |
| `02_GIGI_APP/GIGI/GigiFoundationSession.swift` | MODIFY (helper semantic match) | +20 |
| `02_GIGI_APP/GIGI/Info.plist` | MODIFY (verify/add `NSCalendarsFullAccessUsageDescription`) | +3 |
| `02_GIGI_APP/GIGI/AppDelegate.swift` (o `GigiApp.swift`) | MODIFY (`isBatteryMonitoringEnabled = true`) | +2 |
| `docs/runbooks/gate-10-shortcut-setup.md` | CREATE | ~50 |
| `docs/research/gate-10-tool-coverage.md` | CREATE | ~80 |

---

## 9. ADR collegati

- **ADR-0008** (Apple FM Tool calling vs scored registry) — applicata: nuovi tool seguono lo stesso pattern protocol `Tool` di GATE 3
- **ADR-0010** (Capability Taxonomy + Discovery Mechanism for Apple FM Tools) — Proposed → **Accepted** alla chiusura di questo GATE. `GigiCapabilityCatalog` è la realizzazione della 7-category taxonomy; Layer B intercept è la realizzazione del "Conversational Discovery" mechanism descritto in ADR-0010.
- ADR-0009 (Hardware targets) — `translate_text` aggiunge dependency iOS 18+ (Translation framework). Documentare nella revisione minor di ADR-0009 il pin minimo aggiornato se cambia.

---

## 10. Note operative

- **Branch**: `feat/gate-10-capability-week2`
- **Test su device fisico OBBLIGATORIO**: Apple FM Tool calling + EventKit + Translation framework + UIReferenceLibraryViewController non simulano bene su Simulator (specialmente Translation richiede modelli on-device che il simulator non scarica sempre)
- **Conventional Commits suggeriti** (uno per task, ordine implementativo):
  ```
  feat(ios): GATE 10.1 — create_calendar_event tool (EventKit write)
  feat(ios): GATE 10.2 — add_to_note tool (Shortcut bridge)
  feat(ios): GATE 10.3 — utility tools (clipboard, battery, flashlight)
  feat(ios): GATE 10.4 — knowledge mini tools (define, calculate, translate)
  feat(ios): GATE 10.5 — Layer B conversational discovery + capability catalog
  docs(runbook): GATE 10 — Shortcut "GIGI Append to Note" setup guide
  test(ios): GATE 10 — 8 tool + Layer B coverage results
  ```
- **Context budget Apple FM**: 26 tool descriptions × ~70 token avg = ~1.8k token. Lascia ~2.3k per system + user + history su 4096 window. Se overflow, attivare subset selection upfront (router passa solo top-3 tool category-matched ad Apple FM). Vedi GATE 3 §10 "Cosa fare se 15 tool è troppo per context budget" — stessa tecnica si applica qui scaled.

### GATES intermedi dentro GATE 10

Questo GATE è strutturato in **4 sub-gate interni** per permettere ship incrementale + rollback granulare:

#### GATE 10.A — Calendar + Note shipped (Task 10.1 + 10.2)

**Definition of Done**: `create_calendar_event` + `add_to_note` funzionanti su iPhone fisico. AC-10.1..10.7 verde. Permission flow EventKit testato. Runbook Shortcut pubblicato. Commit `feat(ios): GATE 10.A`.

#### GATE 10.B — Utility tools shipped (Task 10.3)

**Definition of Done**: `read_clipboard` + `get_device_battery` + `toggle_flashlight` funzionanti. AC-10.8..10.10 verde. Battery monitoring enabled al boot. Torch state correctly toggled. Commit `feat(ios): GATE 10.B`.

#### GATE 10.C — Knowledge mini shipped (Task 10.4)

**Definition of Done**: `define_word` + `calculate_math` + `translate_text` funzionanti. AC-10.11..10.13 verde. Translation framework operativo (eventualmente con language pack scaricato). NSExpression sanitization in place (no eval injection). Commit `feat(ios): GATE 10.C`.

#### GATE 10.D — Layer B Conversational Discovery (Task 10.5)

**Definition of Done**: `GigiCapabilityCatalog` popolato con 26 entries. `isDiscoveryQuery` intercept in router funziona. AC-10.14..10.18 verde. *"What can you do?"* ritorna risposta context-aware differente fra mattina e sera (test verificabile cambiando ora di sistema o aspettando momenti diversi). Commit `feat(ios): GATE 10.D`.

**Ordine consigliato**: 10.A → 10.B → 10.C → 10.D. La sequenza tool-first → discovery-last è importante perché Layer B legge da `GigiCapabilityCatalog` che deve essere già popolato con tutti gli 8 tool nuovi prima del discovery test.

### Cosa fare se Translation framework fallisce sul device

iOS 18.0 e early 18.x hanno avuto issues con Translation su alcune lingue:

1. Verificare `LanguageAvailability` API: `try await LanguageAvailability().status(from: source, to: target)` deve essere `.installed`
2. Se `.supported` (not installed), iOS deve scaricare il language pack — primo uso richiede UI sheet sistema. È accettabile per voice-first se mostriamo all'utente la sheet la prima volta poi le translation successive sono on-device istantanee
3. Se `.unsupported`: fallback graceful, speech "Translation between \(from) and \(to) is not supported on this device yet"

### Cosa fare se Layer B suggerisce sempre gli stessi tool

`contextAwareTop3` scoring è greedy. Se telemetria mostra che gli utenti chiedono *"what can you do?"* e poi NON provano nessuno dei top-3 suggeriti (silenzio entro 30s), considerare:

1. Round-robin tra entry con score uguale, invece di prendere sempre i primi 3 in declaration order
2. Penalizzare entry che l'utente ha già usato negli ultimi 7gg (è ovvio che li conosce — meglio mostrare nuovi)
3. Aggiungere weight per `recent_call`/`recent_event` context hints (es. dopo un `make_call` fallito, suggerire `send_message` come fallback)

Questo si vede solo dopo aver fatto GATE 7 telemetria (utenti reali). Per ora baseline scoring va bene.
