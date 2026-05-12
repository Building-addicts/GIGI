# GATE 14 — Macro Engine + Voice Authoring (closeout capability expansion)

> **Status**: 📋 PLANNED (2026-05-12)
> **Effort stimato**: 12-15h (~2-3 giorni full-time)
> **Bloccanti pre-gate**: GATE 13 chiuso (full ~62 tool catalog + Layer D Proactive shipped + telemetry MVP attiva)
> **Sblocca**: nessun GATE successivo (è il closeout dell'intera capability expansion roadmap, v1.1 ready)
> **Funzione consegnata (1 frase)**: GIGI permette all'utente di definire macro voice-triggered che compongono i ~62 tool esistenti in sequenze custom, salvate su iCloud, editabili conversazionalmente — bypassando il signing-wall di Apple Shortcuts.

---

## 1. Obiettivo

L'utente power vuole automazioni custom: *"quando dico X fai A, B, C"*. Path
standard iOS sarebbe creare uno Shortcut nell'app Apple, ma:
1. Richiede al power user di imparare l'app Shortcuts (curva ripida)
2. GIGI non può generare programmaticamente .shortcut perché Apple ha
   chiuso questa porta dal iOS 16+ con signing crittografico stretto

**Soluzione GATE 14**: Macro Engine **interno a GIGI**, in-process. L'utente
detta verbalmente la macro a GIGI; Apple FM (o Claude Code per macro
condizionali) parsa la richiesta in una sequenza di `MacroAction` (tool name +
arguments). La macro è salvata in CloudKit (iCloud sync cross-device). Al
trigger phrase, il router intercepta PRIMA del tool calling normale e chiama
`GigiMacroEngine.execute(macro)` che cicla le azioni via `GigiActionBridge`.

Esempio flow:
```
User:  "GIGI, when I say 'gym time' set Focus to Sport, play Gym playlist,
        and start a 60-minute timer"
                ↓
        Apple FM on-device parsa frase →
            triggerPhrase: "gym time"
            actions: [
              { tool: "set_focus_mode", args: {mode: "Sport"}, waitBefore: 0 },
              { tool: "play_music",     args: {type: "playlist", name: "Gym"}, waitBefore: 0.5 },
              { tool: "set_timer",      args: {duration: "60 minutes"},        waitBefore: 0.5 }
            ]
                ↓
        Save in CloudKit (iCloud KV) → sync su tutti i device entro 60s
                ↓
GIGI TTS (English):
        "Got it. Saying 'gym time' will now do three things:
         Set Focus to Sport, play the Gym playlist, and start a sixty-minute
         timer. Want to try it now?"

[later]
User:  "gym time"
                ↓
        GigiRequestRouter intercept: MacroEngine.tryMatch("gym time")
                ↓
        Match found → execute sequence
                ↓
GIGI TTS (English):
        "Sport Focus on. Gym playlist starting. Timer set for 60 minutes."
```

Output concreto:
- `GigiMacroEngine.swift` (~150 righe) — singleton MainActor con in-memory store + execute
- `GigiMacroSync.swift` (~80 righe) — CloudKit fetch/save/delete + ubiquity update notification
- `GigiMacroParser.swift` (~120 righe) — `create_macro` Tool con Apple FM @Generable + Claude Code fallback
- `GigiMacro.swift` (~50 righe) — Codable `GigiMacro` + `MacroAction` + `ConditionalMacroAction` models
- 4 nuovi `Tool` struct in `GigiFoundationToolRegistry.swift`: `create_macro`, `list_macros`, `delete_macro`, `edit_macro`
- `GigiRequestRouter.swift` modificato: intercept `MacroEngine.tryMatch` PRIMA del normal Apple FM dispatch
- `docs/adr/0011-macro-engine-voice-authoring.md` — ADR PROPOSED → Accepted alla chiusura GATE

---

## 2. Pre-condizioni

- [ ] GATE 9 → 13 chiusi (full ~62 tool catalog disponibile come building block per macro)
- [ ] Layer D Proactive Suggestions shipped (GATE 13.P) — per offrire suggestion *"You did this 3 times — want to make it a macro?"*
- [ ] Entitlement iCloud + CloudKit container `iCloud.com.killsiri.GIGI` attivo (già in `02_GIGI_APP/GIGI/GIGI.entitlements`)
- [ ] Telemetry MVP attiva — per evaluation post-launch quali macro sono più creati/usati
- [ ] `GigiActionLog.swift` (da GATE 12) disponibile come fonte per "suggest macro from recent action history"
- [ ] Action Bridge `GigiActionBridge.execute(intent:)` come dispatch comune per ogni MacroAction (no nuovo dispatch path)
- [ ] iPhone 15 Pro+ fisico con Apple Intelligence attiva (Apple FM disponibile per macro parsing)
- [ ] Harness Cloudflare Tunnel attivo (per fallback Claude Code su macro condizionali)

---

## 3. Task implementativi

### Task 14.1 — Macro Engine core + iCloud sync (5h, sub-gate 14.A)

**File: `02_GIGI_APP/GIGI/GigiMacro.swift`** (CREATE, ~50 righe)

```swift
import Foundation

struct GigiMacro: Codable, Identifiable {
    var id: String { triggerPhrase.lowercased() }
    let triggerPhrase: String                 // e.g. "gym time"
    let actions: [MacroAction]
    let createdAt: Date
    var useCount: Int = 0
    var lastUsedAt: Date?
}

enum MacroActionKind: String, Codable {
    case standard      // GigiActionBridge tool call
    case conditional   // requires runtime predicate evaluation
}

struct MacroAction: Codable {
    let kind: MacroActionKind
    let toolName: String                      // canonical action name from GigiFoundationToolRegistry
    let arguments: [String: String]
    let waitBefore: TimeInterval              // seconds delay before executing
    let condition: ConditionalPredicate?      // nil for .standard
}

struct ConditionalPredicate: Codable {
    let kind: PredicateKind                   // .timeOfDay | .location | .focusActive | .deviceState
    let comparator: String                    // "before" | "after" | "is" | "isNot"
    let value: String                         // e.g. "22:00" | "home" | "Work"
}

enum PredicateKind: String, Codable {
    case timeOfDay, location, focusActive, deviceState
}
```

**File: `02_GIGI_APP/GIGI/GigiMacroEngine.swift`** (CREATE, ~150 righe)

```swift
import Foundation

@MainActor
final class GigiMacroEngine {
    static let shared = GigiMacroEngine()

    private var macros: [String: GigiMacro] = [:]
    private let sync = GigiMacroSync()

    private init() {
        Task { await loadFromCloud() }
    }

    // MARK: - Load / Sync

    func loadFromCloud() async {
        let cloudMacros = await sync.fetchAll()
        macros = Dictionary(uniqueKeysWithValues: cloudMacros.map { ($0.id, $0) })
        GigiDebugLogger.log("MacroEngine loaded \(macros.count) macros from iCloud")
    }

    func save(_ macro: GigiMacro) async {
        macros[macro.id] = macro
        await sync.save(macro)
    }

    func delete(triggerPhrase: String) async -> Bool {
        let key = triggerPhrase.lowercased()
        guard macros.removeValue(forKey: key) != nil else { return false }
        await sync.delete(id: key)
        return true
    }

    // MARK: - Match / Execute

    /// Strict normalized match. NO fuzzy edit distance (avoids false positive
    /// where utterance "set timer" matches generic macro "set"). User must say
    /// the exact trigger phrase (case-insensitive, trimmed, punctuation stripped).
    func tryMatch(_ utterance: String) -> GigiMacro? {
        let normalized = utterance
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet.punctuationCharacters)
            .joined()
        return macros[normalized]
    }

    /// Execute the macro: cycle through actions with waitBefore delays.
    /// On per-step failure, abort and surface step index in TTS (English).
    @discardableResult
    func execute(_ macro: GigiMacro) async -> MacroExecutionResult {
        var executedCount = 0
        var failureIndex: Int?

        for (idx, action) in macro.actions.enumerated() {
            if action.waitBefore > 0 {
                try? await Task.sleep(nanoseconds: UInt64(action.waitBefore * 1_000_000_000))
            }

            // Conditional check
            if action.kind == .conditional, let pred = action.condition {
                guard evaluatePredicate(pred) else {
                    GigiDebugLogger.log("MacroEngine skipped action \(idx) (predicate false)")
                    continue
                }
            }

            let intent = GigiIntent(
                label: action.toolName,
                confidence: 1.0,
                params: action.arguments
            )
            let result = await GigiActionBridge.shared.execute(intent)
            if result.isEmpty {
                failureIndex = idx
                break
            }
            executedCount += 1
        }

        // Update telemetry
        if var m = macros[macro.id] {
            m.useCount += 1
            m.lastUsedAt = Date()
            await save(m)
        }

        return MacroExecutionResult(
            executed: executedCount,
            total: macro.actions.count,
            failureIndex: failureIndex
        )
    }

    private func evaluatePredicate(_ pred: ConditionalPredicate) -> Bool {
        // Lightweight runtime evaluation — only standard kinds supported here.
        // Complex predicates should have been transformed into branches at parse time.
        switch pred.kind {
        case .timeOfDay:
            return evaluateTimeOfDay(pred)
        case .focusActive:
            return evaluateFocusActive(pred)
        case .location, .deviceState:
            // Delegated to Claude Code parser at create time, not evaluated here.
            return true
        }
    }

    private func evaluateTimeOfDay(_ pred: ConditionalPredicate) -> Bool { /* HH:mm compare */ false }
    private func evaluateFocusActive(_ pred: ConditionalPredicate) -> Bool { /* INFocusStatusCenter */ false }

    var allMacros: [GigiMacro] { Array(macros.values).sorted { $0.useCount > $1.useCount } }
}

struct MacroExecutionResult {
    let executed: Int
    let total: Int
    let failureIndex: Int?
    var isSuccess: Bool { failureIndex == nil }
}
```

**File: `02_GIGI_APP/GIGI/GigiMacroSync.swift`** (CREATE, ~80 righe)

CloudKit fetch/save/delete. Uses CKDatabase (private DB, user iCloud) since
macros are per-user and not shared. Container ID: `iCloud.com.killsiri.GIGI`.
RecordType: `GigiMacro`. Sync trigger: `CKDatabaseSubscription` notifies on
remote change → reloads engine cache.

(implementation omitted for brevity — standard CloudKit boilerplate, ~80 lines)

**Hook in `GigiRequestRouter.route(text:)`** — PRIMA del normal Apple FM dispatch:

```swift
// Layer 0: Macro intercept (added GATE 14)
// Strict trigger phrase match — if user said exactly a macro trigger,
// execute the macro and short-circuit. Never falls back to Apple FM
// even if match fails (next layer handles).
if let macro = GigiMacroEngine.shared.tryMatch(text) {
    let result = await GigiMacroEngine.shared.execute(macro)
    let speech = buildMacroExecutionSpeech(macro: macro, result: result)  // English TTS
    GigiConversationMemory.shared.addModelSpeech(speech)
    return .actionInvoked(speech: speech, tool: "macro:\(macro.triggerPhrase)")
}
// [existing Apple FM dispatch continues below]
```

### Task 14.2 — Voice authoring via `create_macro` Tool (4h, sub-gate 14.B)

**File: `02_GIGI_APP/GIGI/GigiMacroParser.swift`** (CREATE, ~120 righe)

```swift
@available(iOS 26.0, *)
struct FMCreateMacroTool: Tool {
    let name = "create_macro"
    let description = """
    Create a voice-triggered macro that executes a sequence of actions. Use \
    when the user says 'when I say X do A, B, C' or 'create a routine to ...' \
    or 'every time I say X then ...'. NOT for one-shot actions (use the \
    specific tool instead).
    """

    @Generable
    struct Arguments {
        @Guide(description: "Exact trigger phrase the user wants to use later, e.g. 'gym time' or 'good night'. Lowercase, no punctuation.")
        var triggerPhrase: String

        @Guide(description: "Ordered list of actions to execute. Each action is a tool name + arguments. Format as JSON array string.")
        var actionsJSON: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        // Parse actionsJSON → [MacroAction]
        guard let data = arguments.actionsJSON.data(using: .utf8),
              let actions = try? JSONDecoder().decode([MacroAction].self, from: data) else {
            return "I couldn't parse that macro — try rephrasing the actions."
        }

        let macro = GigiMacro(
            triggerPhrase: arguments.triggerPhrase,
            actions: actions,
            createdAt: Date()
        )
        await GigiMacroEngine.shared.save(macro)

        // English confirmation TTS — required by §2.6 language rule.
        let summary = humanReadableActionSummary(actions)  // "Set Focus to Sport, play the Gym playlist, and start a 60-minute timer"
        return "Got it. Saying '\(arguments.triggerPhrase)' will now do: \(summary). Want to try it now?"
    }

    private func humanReadableActionSummary(_ actions: [MacroAction]) -> String {
        // Maps each MacroAction to a short English description
        // e.g. set_focus_mode args {mode:Sport} → "set Focus to Sport"
        // ...
    }
}
```

Register in `GigiFoundationToolRegistry.allTools`.

### Task 14.3 — Macro management (3h, sub-gate 14.C)

3 nuovi Tool struct: `FMListMacrosTool`, `FMDeleteMacroTool`, `FMEditMacroTool`.

**List macros example response (English)**:
> "You have 4 macros: gym time, good night, morning routine, and focus work. Say one of them to run it, or ask me to edit any of them."

**Delete macros example response (English)**:
> "Deleted 'gym time'. You won't be able to trigger it anymore."

**Edit macros example** — user says *"add 'open Spotify' to gym time"*:
> "Added 'open Spotify' to gym time. The macro now does four things: ..."

### Task 14.4 — Claude Code fallback per macro condizionali (3h, sub-gate 14.D)

Apple FM on-device parsa bene macro lineari ma fatica con condizioni (*"if it's
after 10pm turn off lights, else dim them to 30%"*). Quando Apple FM rileva
parole-chiave condizionali (`if`, `else`, `when`, `unless`), il `create_macro`
Tool delega al harness Claude Code subprocess via la pipeline esistente
`GigiActionBridge.delegateToHarness(action: "parse_conditional_macro", text: userUtterance)`.

Claude Code ritorna JSON con `ConditionalMacroAction` esplicito; engine lo
salva e a runtime usa `evaluatePredicate()` per skip/execute ogni action.

**Esempio scenario testabile**:
- User: *"GIGI when I say 'going home' if it's after 6pm play relaxing music else play news podcast"*
- Apple FM rileva `if/else` → delega a Claude Code
- Claude Code ritorna:
  ```json
  {
    "triggerPhrase": "going home",
    "actions": [
      { "kind": "conditional", "condition": {"kind":"timeOfDay","comparator":"after","value":"18:00"},
        "toolName": "play_music", "arguments": {"type": "playlist", "name": "Relax"} },
      { "kind": "conditional", "condition": {"kind":"timeOfDay","comparator":"before","value":"18:00"},
        "toolName": "play_podcast", "arguments": {"show": "news"} }
    ]
  }
  ```

---

## 4. Acceptance Criteria

### Sub-gate 14.A — Macro Engine core (5 AC)

- [ ] **AC-14.1**: File `GigiMacroEngine.swift` esiste come singleton MainActor.
- [ ] **AC-14.2**: `MacroEngine.tryMatch(utterance)` ritorna `GigiMacro` per match strict normalized; ritorna `nil` per mismatch o utterance generica (es. *"set timer"* NON matcha macro generica *"set"*).
- [ ] **AC-14.3**: Macro salvate in CloudKit `iCloud.com.killsiri.GIGI`, sync verificato cross-device entro 60s (test: salva su iPhone A, dopo 60s appare su iPhone B con stesso Apple ID).
- [ ] **AC-14.4**: `MacroEngine.execute(macro)` cicla attraverso `actions`, rispetta `waitBefore` delays, dispatch ogni action via `GigiActionBridge.execute(intent)`.
- [ ] **AC-14.5**: Hook in `GigiRequestRouter.route()` esegue Macro intercept PRIMA del normal Apple FM dispatch — verificato con Console log `GIGI Router → macro_intercept: triggerPhrase=...`.

### Sub-gate 14.B — Voice authoring (5 AC)

- [ ] **AC-14.6**: `FMCreateMacroTool` registrato in `GigiFoundationToolRegistry.allTools` E in `canonicalActions` array.
- [ ] **AC-14.7**: Tool `description` in **inglese**, segue pattern *"<action>. Use when <trigger>. NOT for <counter>."*
- [ ] **AC-14.8**: E2E: user dice *"GIGI, when I say 'gym time' set Focus to Sport, play Gym playlist, and start a 60-minute timer"* → macro creato, salvato, confirmation TTS in inglese contiene trigger phrase + summary leggibile.
- [ ] **AC-14.9**: Confirmation TTS è in **inglese** (verifica grep guard contro stringhe italiane in `humanReadableActionSummary`).
- [ ] **AC-14.10**: Macro persistito sopravvive a app cold restart (load from iCloud al boot).

### Sub-gate 14.C — Macro management (4 AC)

- [ ] **AC-14.11**: `FMListMacrosTool` ritorna lista macros con `useCount` desc + risposta TTS in inglese.
- [ ] **AC-14.12**: `FMDeleteMacroTool` rimuove macro da engine + CloudKit; confirm TTS *"Deleted 'gym time'."* in inglese.
- [ ] **AC-14.13**: `FMEditMacroTool` aggiunge/rimuove action a macro esistente; rifiuta edit per macro non esistente con TTS *"I don't have a macro called X."* in inglese.
- [ ] **AC-14.14**: User-facing strings in tutti e 3 i tool E in eventuali alert SwiftUI = **inglese** (LANG-AUDIT pass).

### Sub-gate 14.D — Conditional macro fallback (3 AC)

- [ ] **AC-14.15**: `GigiActionBridge.delegateToHarness(action:text:)` riceve la richiesta condizionale e inoltra a harness `/api/ios/parse-conditional-macro` endpoint.
- [ ] **AC-14.16**: Harness invoca Claude Code subprocess con prompt costruito da `parse_conditional_macro` template; ritorna JSON `[MacroAction]` valido (test: `if it's after 10pm ...` → 2 conditional actions in JSON).
- [ ] **AC-14.17**: Conditional macro al runtime `evaluatePredicate()` correttamente: skip se predicato falso, execute se vero.

### Cross-cutting (4 AC)

- [ ] **AC-14.18 (LANG-AUDIT)**: Grep guard `bash docs/runbooks/language-audit.sh 02_GIGI_APP/GIGI/Gigi*Macro*.swift` ritorna 0 match. Nessuna stringa italiana in `Text(...)`, `Button(...)`, `Alert(...)`, `speech.speak(...)`, `showBanner(...)`, push body, accessibility hint.
- [ ] **AC-14.19**: ADR-0011 *"Macro Engine — voice-authored automation without iOS Shortcuts"* da Proposed → Accepted alla chiusura GATE 14.
- [ ] **AC-14.20**: `GigiCapabilityCatalog.swift` aggiornato — i 4 nuovi tool aggiunti con `category: .automation`, `userExample` inglese.
- [ ] **AC-14.21**: Build verify post-merge: `xcodebuild` BUILD SUCCEEDED + no nuove warning rilevanti.

---

## 5. Test E2E sull'iPhone fisico (16 frasi)

> ⚠️ Tutte le frasi di esempio sono in formato *"user input → expected GIGI English response"*. L'input utente può essere parlato in italiano se preferisce (Apple FM bilingue); la risposta GIGI **sempre** in inglese.

### Macro creation (semplice)

- **E2E-14.1**: User: *"GIGI when I say 'gym time' set Focus to Sport, play Gym playlist, and start a 60-minute timer"* → GIGI: *"Got it. Saying 'gym time' will now do three things: set Focus to Sport, play the Gym playlist, and start a sixty-minute timer. Want to try it now?"*
- **E2E-14.2**: User: *"create a macro 'good night' that turns off all lights, sets alarm for 7am, and starts Do Not Disturb"* → GIGI: confirmation English summary.
- **E2E-14.3**: User: *"every time I say 'morning routine' read my calendar, tell me the weather, and play upbeat playlist"* → GIGI: confirmation in English.

### Macro execution (trigger phrase)

- **E2E-14.4**: User (week later): *"gym time"* → GIGI executes sequence + TTS *"Sport Focus on. Gym playlist starting. Timer set for 60 minutes."*
- **E2E-14.5**: User: *"morning routine"* → GIGI: *"You have 2 events today: Marco at 10am, and lunch with Sara at 1pm. Weather: 22 degrees and sunny. Starting your upbeat playlist."*
- **E2E-14.6**: Edge — user pronuncia trigger phrase con punctuation casuale: *"gym time!"* → GIGI normalizes → executes (no false negative).
- **E2E-14.7**: Edge — user pronuncia frase contenente trigger ma con altro intent: *"what time is gym today"* → GIGI does NOT execute macro (strict match), falls back to normal tool dispatch.

### Macro management

- **E2E-14.8**: User: *"list my macros"* → GIGI: *"You have 3 macros: gym time, morning routine, and good night. Say any of them to run it."*
- **E2E-14.9**: User: *"delete gym time"* → GIGI: *"Deleted 'gym time'. You won't be able to trigger it anymore."*
- **E2E-14.10**: User: *"add 'open Spotify' to morning routine"* → GIGI: *"Added 'open Spotify'. Morning routine now does four things: ..."*
- **E2E-14.11**: User: *"delete gym time"* (after already deleted) → GIGI: *"I don't have a macro called gym time."* (English error response)

### Macro condizionale (Claude Code fallback)

- **E2E-14.12**: User: *"GIGI when I say 'going home' if it's after 6pm play relaxing music else play news podcast"* → GIGI detects `if/else` → delegates to harness → confirmation in English.
- **E2E-14.13**: User at 7pm: *"going home"* → GIGI evaluates predicate (time > 18:00) → plays Relax playlist.
- **E2E-14.14**: User at 2pm: *"going home"* → predicate false → plays news podcast.

### Cross-device sync

- **E2E-14.15**: User creates macro on iPhone A → 60s later opens GIGI on iPad (same Apple ID) → `list my macros` shows the new macro.

### Failure handling

- **E2E-14.16**: User triggers macro but one of the actions fails (e.g. HomeKit accessory offline) → GIGI TTS in English: *"Sport Focus on. Gym playlist starting. Couldn't start the timer — please try again."* (graceful, identifies the failure step).

---

## 6. Test post-creazione (verificabile mesi dopo)

```bash
# (a) Existence + structure of Macro Engine files
grep -l 'final class GigiMacroEngine' 02_GIGI_APP/GIGI/GigiMacroEngine.swift
grep -l 'struct GigiMacro' 02_GIGI_APP/GIGI/GigiMacro.swift
grep -l 'final class GigiMacroSync' 02_GIGI_APP/GIGI/GigiMacroSync.swift
grep -l 'FMCreateMacroTool' 02_GIGI_APP/GIGI/GigiMacroParser.swift

# (b) Tool registry includes 4 new macro tools
grep -E 'create_macro|list_macros|delete_macro|edit_macro' \
    02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift | wc -l  # must be >= 8 (4 in allTools + 4 in canonicalActions)

# (c) Router intercept hook present
grep -n 'MacroEngine.shared.tryMatch' 02_GIGI_APP/GIGI/GigiRequestRouter.swift

# (d) Language audit — no Italian in user-facing strings in macro files
bash docs/runbooks/language-audit.sh 02_GIGI_APP/GIGI/Gigi*Macro*.swift
# exit 0 = clean. exit 1 = found Italian → block merge.

# (e) Build verify on Mac
ssh user@mac 'cd ~/GIGI/02_GIGI_APP && xcodebuild -scheme GIGI -destination "generic/platform=iOS" build' 2>&1 | tail -3
# expected: ** BUILD SUCCEEDED **

# (f) ADR-0011 exists and is Accepted
grep -E 'Status:.*Accepted' docs/adr/0011-macro-engine-voice-authoring.md
```

---

## 7. Rollback plan

Feature flag granulare (`gigi.feature.macro_engine`) in `UserDefaults`:

```swift
if UserDefaults.standard.bool(forKey: "gigi.feature.macro_engine") {
    // Layer 0 Macro intercept active
} else {
    // Skip — proceed straight to Apple FM dispatch
}
```

Se rilevato problema critico (es. macro execution loop infinito, CloudKit sync
corruption):
1. Disable feature flag remotamente via push (se messaging infra v1.1 attiva) o
   richiede update IPA con default-off
2. Le macro restano salvate su CloudKit — niente data loss
3. Riabilitazione dopo fix
4. Worst case: `git revert` del commit GATE 14 — i tool macro management
   spariscono, le macro salvate in CloudKit restano orfane (recuperabili al
   re-enable)

---

## 8. File table

### Modify (4 file)

| File | Modifica |
|---|---|
| `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` | +4 Tool struct (`FMCreateMacroTool`, `FMListMacrosTool`, `FMDeleteMacroTool`, `FMEditMacroTool`); update `allTools` array (62→66); update `canonicalActions` array |
| `02_GIGI_APP/GIGI/GigiRequestRouter.swift` | Add Macro intercept hook in `route()` PRIMA della normal Apple FM dispatch |
| `02_GIGI_APP/GIGI/GigiActionBridge.swift` | Add `delegateToHarness(action: "parse_conditional_macro", text:)` for Claude Code fallback (~30 righe) |
| `02_GIGI_APP/GIGI/GigiCapabilityCatalog.swift` | Aggiungere 4 nuovi tool catalog entries con `category: .automation`, `userExample` inglese |

### Create (5 file)

| File | Righe stimate |
|---|---|
| `02_GIGI_APP/GIGI/GigiMacroEngine.swift` | ~150 |
| `02_GIGI_APP/GIGI/GigiMacroSync.swift` | ~80 |
| `02_GIGI_APP/GIGI/GigiMacroParser.swift` | ~120 |
| `02_GIGI_APP/GIGI/GigiMacro.swift` | ~50 |
| `docs/adr/0011-macro-engine-voice-authoring.md` | ~100 |
| `docs/runbooks/language-audit.sh` | ~40 (script bash grep) |

### Backend (harness, optional Task 14.4 only)

| File | Modifica |
|---|---|
| `03_HARNESS/server/routes/ios.js` | Add endpoint `POST /api/ios/parse-conditional-macro` (riceve utterance → invoca Claude Code subprocess con template prompt → ritorna JSON `[MacroAction]`) |

---

## 9. ADR collegati

- **ADR-0008** (Apple FM Tool calling) — eredita pattern, espande registry 62→66
- **ADR-0010** (Tool taxonomy + discovery UX) — Accepted alla chiusura GATE 12, macro tool entrano in `category: .automation`
- **ADR-0011** ❗ NEW PROPOSED → Accepted alla chiusura GATE 14 — *"Macro Engine — voice-authored automation without iOS Shortcuts"*:
  - **Context**: Apple ha chiuso il signing programmatico .shortcut dal iOS 16+. Claude Code che genera Shortcut on-the-fly e li installa non funziona su iOS 26+ — rifiutati al momento install per signature mismatch.
  - **Decision**: Macro Engine in-process GIGI bypassa interamente Shortcuts. Storage CloudKit (entitlement già OK). Voice authoring via Apple FM on-device (semplici) + Claude Code fallback (condizionali). Strict trigger phrase match (no fuzzy).
  - **Alternatives considered**: (a) iCloud share link Shortcut → richiederebbe nostro account dev ad hostare ogni macro custom, non scalabile; (b) Generated .shortcut con Apple signing reverse — Apple closed door, fragile/breaking; (c) Macro stored locally only → no cross-device sync UX.
  - **Consequences**: ✅ scalabilità infinita di macro per utente; ✅ no signing wall; ⚠️ macro compone solo tool che GIGI conosce (~66), per actions completely outside scope (es. controllare Tesla via web), serve combinare con `run_shortcut` (path A user-created); ⚠️ macro complesse multi-condition delegano a Claude Code online (privacy trade-off accettato per power user).
  - **Follow-ups**: monitor adoption rate (target ≥30% MAU crea almeno 1 macro entro 2 settimane); telemetry su trigger phrase fuzzy-match false positive (target <1%).

---

## 10. Note operative

**Branch**: `feat/gate-14-macro-engine`

**Conventional commits suggeriti** (uno per sub-gate):

1. `feat(macro): GigiMacroEngine core + CloudKit sync (GATE 14.A)` — files 14.A
2. `feat(macro): voice authoring via FMCreateMacroTool (GATE 14.B)` — files 14.B
3. `feat(macro): list/delete/edit management tools (GATE 14.C)` — files 14.C
4. `feat(macro): Claude Code fallback for conditional macros (GATE 14.D)` — files 14.D
5. `docs(adr): ADR-0011 macro engine voice authoring Accepted` — ADR finalization
6. `chore(lang): language-audit.sh runbook + AC-T7 enforcement` — cross-cutting

**Branch lifecycle**: ognuno dei 6 commit può vivere in PR separate per review
incrementale, oppure tutto in un singolo PR `feat/gate-14-macro-engine` con
commit organizzati per sub-gate.

**Build verify post ogni sub-gate**: `xcodebuild` BUILD SUCCEEDED + AC-14.x
sub-gate corrispondenti chiusi prima di passare al successivo.

**Language audit cross-cutting**: prima di mergiare ANY commit di questo
GATE, eseguire `bash docs/runbooks/language-audit.sh 02_GIGI_APP/GIGI/`. Block
merge se exit code ≠ 0. Lo script è creato come deliverable di questo GATE
(vedi §8 File table).

**Tester power-user**: identificare 5-10 beta tester con appetito per
automation (e.g. quelli che già usano Shortcuts molto). Loro saranno first-run
del Macro Engine — feedback critico per macro phrase ergonomics, edge cases
(omonimia, ambiguità) prima del rollout generale.

---

**End of GATE 14 task plan.**
