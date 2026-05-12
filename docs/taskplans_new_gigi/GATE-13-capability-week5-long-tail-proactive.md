# GATE 13 — Capability Expansion Week 5+: Long Tail Tools + Proactive Suggestions

> **Status**: Pending (richiede GATE 12 chiuso + telemetry MVP attiva)
> **Effort stimato**: ~20-40h totali (variabile — il long-tail è prioritized backlog, non tutto è obbligatorio)
> **Bloccanti pre-gate**: GATE 12 chiuso (Week 4 Knowledge + Meta + Layer C Capability Sheet); telemetry MVP attivata (per decidere priorità long-tail in base a usage reale); ADR-0010 in stato Accepted dopo GATE 12
> **Sblocca**: nessun GATE successivo strict; questo è il fine del rollout capability expansion. Eventuale GATE 14+ sarebbe nuove feature beyond capability catalog (es. modalità multi-device, agentic workflow long-running).
> **Funzione consegnata (1 frase)**: GIGI completa la copertura catalog con un sottoinsieme on-demand dei ~30 tool long-tail rimanenti (social/produttività/media/ambiente/sistema avanzati) e introduce **Layer D Proactive Suggestions** — un sistema opt-in che, in base al contesto (mattino, post-failure, ricorrenza), suggerisce capability rilevanti riducendo il Time-To-Value per i nuovi utenti.

---

## 1. Obiettivo

Dopo i 4 GATE intermedi (9 → 12) che hanno coperto Power user unlock, Productivity boost, Ambient & social e Knowledge & meta, GIGI ha già ~50 tool e 3 layer di discovery (Onboarding, Conversational, UI Sheet). Rimangono però due aree dichiarate nel piano master §6 Week 5+:

1. **Long tail tools (~30 capability rimanenti)** — feature di nicchia che hanno valore per *qualche* utente ma non per tutti. Implementarle TUTTE upfront è anti-pattern: meglio prioritizzare in base a telemetria post-MVP (quali capability mancanti vengono *chieste* dagli utenti via Apple FM fallback "I don't know how to do that"). Per questo GATE 13 dichiara la lista completa come **prioritized backlog** e accetta che il PM ne shippi un subset dinamico.

2. **Layer D Proactive Suggestions** — è il quarto e ultimo layer di discovery definito in ADR-0010. A differenza degli altri 3 (Onboarding 1x, Conversational on-demand, UI Sheet passivo), Layer D è **attivo**: GIGI parla per primo. Esempi:
   - Mattina alle 8:30: banner sulla dashboard *"Good morning. Want me to read today's calendar?"*
   - Dopo `make_call` fallito (popup iOS Phone): *"That contact has no phone. Want to message them on WhatsApp instead?"*
   - Dopo 3 timer settati nella stessa giornata: *"Tip: you can also set recurring reminders — try 'remind me every Tuesday at 6pm'."*

Questo è il layer più potente per ridurre il TTV dei nuovi utenti (perché non devono *sapere* cosa chiedere) ma anche il più rischioso per UX (può diventare spam). Per questo è **opt-in** (default OFF), con prompt esplicito in onboarding e setting toggle dedicato, e con anti-spam built-in (max 1/30min, 3-dismiss auto opt-out).

Output concreto:
- Subset (definito dal PM in base a telemetria) dei ~30 long-tail tool, ognuno con sub-task indipendente, shippable in PR singole (branch per tool).
- `GigiSuggestionEngine.swift` (nuovo, ~250 righe) — core engine + protocollo `SuggestionProvider` + dispatcher.
- ≥3 `SuggestionProvider` concreti: `MorningCalendarSuggestion`, `PostCallFailureSuggestion`, `RecurringTimerSuggestion`.
- Settings toggle `proactive_suggestions_enabled` (default false) + onboarding prompt durante GATE 9 Layer A revisited.
- Banner SwiftUI riusabile per suggestion mostrate sulla dashboard.

Questo GATE è il **closeout** del capability expansion roadmap. Dopo questo, la backlog è "feature beyond catalog" (multi-device, agentic, etc.).

---

## 2. Pre-condizioni

- [ ] GATE 9, 10, 11, 12 tutti chiusi (Week 1-4 capability expansion completata)
- [ ] **Telemetry MVP attivata** in `GigiTelemetry.swift` con almeno questi eventi loggati:
  - `tool_invoked(name, success, latency_ms)` per ogni tool call
  - `fallback_unknown_capability(query)` quando Apple FM ritorna "I cannot help with that" → log della query per scoprire long-tail richiesti
  - `discovery_layer_used(layer: a|b|c)` per misurare l'efficacia dei layer esistenti
- [ ] **Dataset telemetry ≥2 settimane** post-launch disponibile per decidere quali long-tail tool prioritizzare (decisione PM, documentata nel kickoff commit di GATE 13)
- [ ] ADR-0010 in stato Accepted (chiuso in GATE 12)
- [ ] `GigiCapabilityCatalog.swift` esiste con campo `category` + `userExample` + `discoveryHint` per ogni tool (output GATE 12)
- [ ] `CapabilitySheetView.swift` esiste e funzionante (output GATE 12) — sarà esteso per mostrare i long-tail
- [ ] Settings storage UserDefaults disponibile (no nuova dipendenza)
- [ ] iPhone 15 Pro+ fisico con Apple Intelligence attivata per test E2E

---

## 3. Task implementativi

Il GATE è organizzato in **sotto-GATE intermedi** per modularità. PM può sceglierne uno alla volta in base a priorità.

### Sotto-GATE 13.LT — Long-tail tools (prioritized backlog, ~15-25h totali se shippati tutti)

Ogni gruppo qui sotto è una sub-task indipendente. PM seleziona quali shippare in base a telemetria post-MVP. Branch dedicato per gruppo (vedi §10).

- **Task 13.A — Social/Comm avanzato** (~6h)
  - `find_contact_info` — 1h — Lookup phone/email di un contact via `CNContactStore`. Tool `Arguments { contactName: String }`. Risposta: `"\(name) has phone \(phone) and email \(email)"`. Permessi: `NSContactsUsageDescription` già presente.
  - `share_contact_card` — 1.5h — Apre share sheet con vCard del contact specificato. Tool `Arguments { contactName: String }`. UIActivityViewController via `GigiActionDispatcher.handleShareContactCard()`.
  - `block_number` — 2.5h — Aggiunge numero a `CallDirectoryExtension` blocklist. Richiede nuovo target Extension (`GigiCallDirectory`) e provisioning profile aggiornato. Tool `Arguments { phoneNumber: String }`. Note: la prima volta richiede setup utente in Settings → Phone → Call Blocking.
  - `read_email_unread_count` — 0.5h — Bridge a Shortcut "Get Unread Mail Count". Tool nessun argument. Risposta: `"You have \(N) unread emails"`.
  - `read_messages_unread_count` — 0.5h — Bridge a Shortcut "Get Unread Messages". Stesso pattern.

- **Task 13.B — Produttività long tail** (~7h)
  - `move_calendar_event` — 1.5h — EventKit `EKEvent.startDate = newDate`. Tool `Arguments { eventTitle: String, newDate: String, newTime: String }`. Edge case: multipli eventi con stesso titolo → chiedere disambiguation (riusa `GigiDisambiguationFlow` da GATE 10).
  - `cancel_calendar_event` — 1h — `EKEventStore.remove(event:span:)`. Tool `Arguments { eventTitle: String, date: String }`. Conferma vocale prima di delete: *"Cancel \(event)? Say yes to confirm."*
  - `create_note_with_tag` — 1h — Shortcut bridge "Create Note with Tag". Tool `Arguments { content: String, tag: String }`.
  - `search_notes` — 1h — Shortcut bridge "Search Notes". Tool `Arguments { query: String }`. Risposta: titoli + snippet primi 3 risultati.
  - `complete_reminder` — 0.5h — EventKit Reminders `reminder.isCompleted = true`. Tool `Arguments { reminderTitle: String }`.
  - `read_pdf_aloud` — 1.5h — Apre PDF da `save_to_files` location o iCloud, estrae testo via PDFKit, lo passa a `AVSpeechSynthesizer`. Tool `Arguments { pdfPath: String }`. Path facoltativo: se vuoto, usa "most recent PDF".
  - `save_to_files` — 0.5h — Salva contenuto (clipboard, screenshot, note) in iCloud Drive `/GIGI/`. Tool `Arguments { fileName: String, content: String }`.

- **Task 13.C — Media/Intrattenimento** (~3h)
  - `play_podcast` — 0.5h — Apple Podcasts URL scheme `podcasts://search?term=`. Tool `Arguments { showName: String }`.
  - `skip_track` — 0.3h — `MPRemoteCommandCenter.shared().nextTrackCommand`. Tool no args.
  - `set_playlist` — 0.5h — Spotify/Apple Music URL scheme. Tool `Arguments { playlistName: String, platform: String }`.
  - `like_current_track` — 0.4h — MPRemoteCommand `likeCommand`. Tool no args.
  - `read_now_playing` — 0.3h — `MPNowPlayingInfoCenter.default().nowPlayingInfo`. Risposta speech.
  - `play_radio_station` — 1h — Apple Music radio URL scheme `music://radio?station=`. Tool `Arguments { stationName: String }`.

- **Task 13.D — Ambiente** (~3h)
  - `read_homekit_sensor` — 1h — HomeKit `HMCharacteristic.readValue()` per sensori temperature/humidity. Tool `Arguments { sensorName: String }`. Risposta: `"\(sensor) reads \(value)\(unit)"`.
  - `set_geofence_reminder` — 2h — EventKit reminder con `EKAlarm.structuredLocation`. Tool `Arguments { task: String, locationName: String, trigger: String (arrive|leave) }`. Permessi: Location When-In-Use già presente.

- **Task 13.E — Sistema** (~2h)
  - `set_volume` — 0.5h — `AVAudioSession.setOutputVolume()` (deprecated) → workaround: open Settings → Sounds (URL scheme `App-prefs:Sounds`). Tool `Arguments { level: Int (0-100) }`.
  - `get_focus_mode_status` — 0.5h — `INFocusStatusCenter.default.focusStatus`. Risposta: `"Focus mode is \(state)"`. Permessi: `NSFocusStatusUsageDescription` richiesto.
  - `take_screenshot` — 1h — `UIScreen.main.snapshotView()` + `UIImageWriteToSavedPhotosAlbum`. Tool no args. Permessi: `NSPhotoLibraryAddUsageDescription` richiesto.

- **Task 13.F — Automazione** (~2h)
  - `list_shortcuts` — 1h — Shortcut bridge "Get My Shortcuts". Tool no args. Risposta: prime 10 shortcut names.
  - `set_automation` — 1h — Tutorial guidato: apre Settings → Shortcuts → Automation. Tool `Arguments { description: String }`. Risposta vocale: *"I cannot create automations directly. Open Shortcuts app and tap '+'. I'll guide you."*. Apre URL `shortcuts://create-automation`.

**Note per ognuno dei long-tail**:
- Pattern uguale a GATE 3 (struct `Tool` conforme, `@Generable Arguments`, bridge a `executeRaw`)
- Description in inglese, max 80 token, chiara su QUANDO usare il tool
- Aggiungere entry a `GigiCapabilityCatalog.swift` con category appropriata
- Aggiornare `GigiFoundationToolRegistry.allTools` array
- Estendere `GigiFallbackRouter.keywordTable` per device non-Apple-FM
- Aggiungere a `CapabilitySheetView` cards (auto se catalog driven)

### Sotto-GATE 13.P1 — `GigiSuggestionEngine` core infrastructure (~4h)

- **Task 13.P1.1 — Creare `GigiSuggestionEngine.swift`** (3h)
  - File: `02_GIGI_APP/GIGI/GigiSuggestionEngine.swift` (new, ~250 righe)
  - Struttura:
    ```swift
    @MainActor
    final class GigiSuggestionEngine: ObservableObject {
        static let shared = GigiSuggestionEngine()

        @Published private(set) var pendingSuggestion: GigiSuggestion?

        private var recentSuggestions: [GigiSuggestion] = []   // in-memory log, no persistence
        private var lastFireDate: Date?
        private var dismissCount: Int = 0                       // dal UserDefaults, persistente
        private let providers: [any SuggestionProvider]

        init() {
            self.providers = [
                MorningCalendarSuggestion(),
                PostCallFailureSuggestion(),
                RecurringTimerSuggestion(),
            ]
        }

        /// Chiamato a ogni `process(text:)` + a wake event + a iOS background refresh.
        func tick(context: SuggestionContext) async {
            guard UserDefaults.standard.bool(forKey: "proactive_suggestions_enabled") else { return }
            guard canFire() else { return }   // anti-spam check
            for provider in providers {
                if let suggestion = await provider.evaluate(context: context, recent: recentSuggestions) {
                    fire(suggestion)
                    return
                }
            }
        }

        func dismiss(_ suggestion: GigiSuggestion) {
            dismissCount += 1
            UserDefaults.standard.set(dismissCount, forKey: "suggestion_dismiss_count")
            if dismissCount >= 3 {
                UserDefaults.standard.set(false, forKey: "proactive_suggestions_enabled")
                // notify user via local notification: "Proactive suggestions disabled. Re-enable in Settings."
            }
            pendingSuggestion = nil
        }

        func accept(_ suggestion: GigiSuggestion) {
            // delega l'azione a GigiActionDispatcher
            Task { await GigiActionDispatcher.shared.bridge.executeRaw(label: suggestion.actionLabel, params: suggestion.actionParams) }
            pendingSuggestion = nil
        }

        private func canFire() -> Bool {
            guard let last = lastFireDate else { return true }
            return Date().timeIntervalSince(last) > 30 * 60   // 30 min throttle
        }

        private func fire(_ suggestion: GigiSuggestion) {
            recentSuggestions.append(suggestion)
            if recentSuggestions.count > 20 { recentSuggestions.removeFirst() }
            lastFireDate = Date()
            pendingSuggestion = suggestion
            // logging
            os_log("suggestion_fired type=%{public}@", suggestion.type.rawValue)
        }
    }

    struct GigiSuggestion: Identifiable {
        let id = UUID()
        let type: SuggestionType
        let speechPrompt: String      // "Want me to read your calendar?"
        let bannerTitle: String       // "Morning briefing"
        let bannerBody: String        // "You have 3 events today."
        let actionLabel: String       // "read_calendar"
        let actionParams: [String: String]
        let firedAt: Date = Date()
    }

    enum SuggestionType: String {
        case morningCalendar
        case postCallFailure
        case recurringTimer
        case afterFailedAction
        case locationArrival
    }

    protocol SuggestionProvider {
        func evaluate(context: SuggestionContext, recent: [GigiSuggestion]) async -> GigiSuggestion?
    }

    struct SuggestionContext {
        let currentTime: Date
        let lastUserText: String?
        let lastActionResult: GigiActionResult?
        let isInForeground: Bool
        let location: CLLocation?
    }
    ```
  - Logging `os_log` per ogni fire/dismiss/accept
  - No persistence per il `recentSuggestions` log (in-memory only, reset al boot)
  - `dismissCount` PERSISTENTE in UserDefaults

- **Task 13.P1.2 — Banner SwiftUI riusabile** (1h)
  - File: `02_GIGI_APP/GIGI/Views/ProactiveSuggestionBanner.swift` (new, ~80 righe)
  - SwiftUI view che osserva `GigiSuggestionEngine.shared.$pendingSuggestion`
  - Quando non nil: mostra card flottante con titolo/body + bottoni `Yes` / `Not now`
  - Tap `Yes` → `engine.accept()`, tap `Not now` → `engine.dismiss()`
  - Auto-dismiss dopo 30s di non interazione (timer)
  - Animazione: slide-in dal top, spring
  - Mount: in `DashboardView` come overlay top z-index

### Sotto-GATE 13.P2 — ≥3 SuggestionProvider concreti (~5h)

- **Task 13.P2.1 — `MorningCalendarSuggestion`** (1.5h)
  - File: stesso `GigiSuggestionEngine.swift` (extension)
  - Logica `evaluate`:
    - Fire SOLO se `context.currentTime` è tra 7:00 e 10:00 local time
    - Fire SOLO se non già fired oggi (check `recent` per type=morningCalendar nello stesso giorno)
    - Fire SOLO se `EventKit` ritorna >=1 evento per oggi
    - Ritorna `GigiSuggestion(type: .morningCalendar, speechPrompt: "Good morning. You have \(N) events today. Want me to read them?", actionLabel: "read_calendar", ...)`

- **Task 13.P2.2 — `PostCallFailureSuggestion`** (1.5h)
  - File: stesso `GigiSuggestionEngine.swift` (extension)
  - Logica `evaluate`:
    - Fire se `context.lastActionResult?.label == "make_call"` AND `result.success == false`
    - Reason check: se contact ha email OR WhatsApp, suggerisci alternativa
    - Ritorna `GigiSuggestion(type: .postCallFailure, speechPrompt: "That call didn't go through. Want me to message \(name) on WhatsApp instead?", actionLabel: "send_message", actionParams: ["contact": name, "platform": "whatsapp"], ...)`
  - Hook: `GigiActionDispatcher.handleMakeCall` deve chiamare `GigiSuggestionEngine.shared.tick(context:)` con `lastActionResult` settato dopo failure

- **Task 13.P2.3 — `RecurringTimerSuggestion`** (1.5h)
  - File: stesso `GigiSuggestionEngine.swift` (extension)
  - Logica `evaluate`:
    - Track count timer settati nella stessa giornata (in-memory counter, reset al boot)
    - Fire al 3° timer della giornata
    - Ritorna `GigiSuggestion(type: .recurringTimer, speechPrompt: "I notice you set a few timers today. Tip: I can also set recurring reminders. Try 'remind me every Tuesday at 6pm'.", actionLabel: nil, ...)` — questa è puramente informativa, no actionLabel

- **Task 13.P2.4 — Hook nel main flow** (0.5h)
  - File: `GigiSmartOrchestrator.swift` + `GigiActionDispatcher.swift`
  - Dopo OGNI `process(text:)` ed OGNI action result: chiamare `GigiSuggestionEngine.shared.tick(context: SuggestionContext(...))`
  - Hook anche su `applicationDidBecomeActive` per check mattino

### Sotto-GATE 13.P3 — Opt-in flow + setting toggle (~2h)

- **Task 13.P3.1 — Settings toggle** (0.5h)
  - File: `SettingsView.swift`
  - Aggiungere sezione "Proactive Suggestions":
    - Toggle binding a `UserDefaults.standard.bool(forKey: "proactive_suggestions_enabled")`
    - Sotto-testo: *"GIGI will occasionally suggest helpful actions based on time, context, and recent activity. Max 1 suggestion per 30 minutes."*
    - Se toggle disabilitato → reset `dismissCount` a 0

- **Task 13.P3.2 — Onboarding prompt** (1h)
  - File: `OnboardingView.swift` (esistente da GATE 9)
  - Aggiungere step finale "Proactive Help":
    - Title: *"Want GIGI to suggest things proactively?"*
    - Body: *"GIGI can offer helpful suggestions — like reading your calendar in the morning or alternatives when a call fails. You can turn this off any time."*
    - Bottoni: `Enable` (set UserDefaults true) / `Maybe later` (set false)
    - Step opzionale, skippabile

- **Task 13.P3.3 — Re-enable notification** (0.5h)
  - File: `GigiSuggestionEngine.swift`
  - Dopo 3 dismiss → auto-disabilita + local notification:
    - Title: "Proactive suggestions disabled"
    - Body: "GIGI noticed you dismissed several suggestions. Re-enable in Settings → Proactive Suggestions."

---

## 4. Acceptance Criteria

### Long-tail (opzionali, dipende dal subset shippato)

- **AC-13-LT-1** — Per ogni long-tail tool shippato: struct `Tool` conforme con `@Generable Arguments` (pattern GATE 3)
- **AC-13-LT-2** — Per ogni long-tail tool shippato: entry in `GigiCapabilityCatalog.swift` con category + userExample + discoveryHint
- **AC-13-LT-3** — Per ogni long-tail tool shippato: entry in `GigiFallbackRouter.keywordTable` per device non-Apple-FM
- **AC-13-LT-4** — Per ogni long-tail tool shippato: appare in `CapabilitySheetView` (auto-driven dal catalog)
- **AC-13-LT-5** — Per ogni long-tail tool shippato: almeno 1 E2E test su iPhone fisico passa (test result registrato in `docs/research/gate-13-tool-coverage.md`)
- **AC-13-LT-6** — Build verify: `xcodebuild` BUILD SUCCEEDED dopo ogni merge sub-task
- **AC-13-LT-7** — Per ogni Extension nuovo (es. CallDirectoryExtension per `block_number`): provisioning profile aggiornato + entitlements documentati
- **AC-13-LT-8** — Permessi nuovi (es. `NSFocusStatusUsageDescription`, `NSPhotoLibraryAddUsageDescription`) aggiunti a `Info.plist` con messaggio chiaro

### Proactive Suggestions (Layer D, ≥6 AC obbligatori)

- **AC-13-PROACTIVE-1** — `GigiSuggestionEngine.swift` esiste con `pendingSuggestion: @Published GigiSuggestion?`, `tick(context:)`, `dismiss(_:)`, `accept(_:)`, `canFire()`
- **AC-13-PROACTIVE-2** — Protocollo `SuggestionProvider` definito + minimo 3 implementazioni concrete (`MorningCalendarSuggestion`, `PostCallFailureSuggestion`, `RecurringTimerSuggestion`)
- **AC-13-PROACTIVE-3** — UserDefaults flag `proactive_suggestions_enabled` (default FALSE) controlla l'engine
- **AC-13-PROACTIVE-4** — Anti-spam: throttle 30 min (verificato via test: 2 fire consecutivi a 25 min distanza → secondo non avviene)
- **AC-13-PROACTIVE-5** — 3 dismiss consecutivi → auto-disabilita + local notification mostrata
- **AC-13-PROACTIVE-6** — `ProactiveSuggestionBanner` SwiftUI view mostra suggestion + 2 bottoni (`Yes` / `Not now`) + auto-dismiss 30s
- **AC-13-PROACTIVE-7** — Onboarding flow include step opt-in Proactive con `Enable` / `Maybe later`
- **AC-13-PROACTIVE-8** — Settings → Proactive Suggestions toggle funzionante + descrizione chiara
- **AC-13-PROACTIVE-9** — Hook in `GigiSmartOrchestrator.process(text:)` chiama `engine.tick()` ad ogni turno
- **AC-13-PROACTIVE-10** — Hook in `applicationDidBecomeActive` chiama `engine.tick()` per check mattino
- **AC-13-PROACTIVE-11** — `recentSuggestions` log in-memory (no persistence, reset al boot)
- **AC-13-PROACTIVE-12** — `dismissCount` persistente in UserDefaults (resiste a kill app)
- **AC-13-PROACTIVE-13** — Build verify: `xcodebuild` BUILD SUCCEEDED
- **AC-13-PROACTIVE-14** — Tutte le `speechPrompt`, `bannerTitle`, `bannerBody` in inglese (regola CLAUDE.md user-facing strings)

---

## 5. Test E2E sul telefono (verificabili dall'utente)

### Long-tail (subset esempi)

- **E2E-13-LT-1** — Social/Comm: "Find Sara's email" → `find_contact_info` invocato → risposta speech `"Sara has email sara@example.com"` (se contact ha email registrata)
- **E2E-13-LT-2** — Social/Comm: "Block this number 555-1234" → `block_number` invocato → numero aggiunto a CallDirectoryExtension blocklist → verify in Settings → Phone → Call Blocking
- **E2E-13-LT-3** — Produttività: "Move my dentist appointment to next Monday" → `move_calendar_event` invocato con disambiguation se più dentist event → EventKit aggiornato
- **E2E-13-LT-4** — Produttività: "Read aloud the latest PDF in my Files" → `read_pdf_aloud` invocato → AVSpeechSynthesizer parla il contenuto
- **E2E-13-LT-5** — Media: "Skip this track" → `skip_track` invocato → traccia successiva in Apple Music
- **E2E-13-LT-6** — Ambiente: "What's the temperature in the bedroom?" → `read_homekit_sensor` → risposta `"Bedroom sensor reads 21°C"` (se HMHome configurato)
- **E2E-13-LT-7** — Ambiente: "Remind me to buy milk when I leave home" → `set_geofence_reminder` invocato → reminder con geofence trigger leave su Home location creato
- **E2E-13-LT-8** — Sistema: "Take a screenshot" → `take_screenshot` invocato → snapshot salvato in Photos → verify in app Photos
- **E2E-13-LT-9** — Sistema: "Is Do Not Disturb on?" → `get_focus_mode_status` invocato → risposta speech corretta
- **E2E-13-LT-10** — Automazione: "What shortcuts do I have?" → `list_shortcuts` invocato → enumera prime 10

### Proactive Suggestions

- **E2E-13-PROACTIVE-1 (Morning)** — Setup: enable Proactive in onboarding o settings. Cambia data device a domani 8:30 AM. Assicura ≥1 evento calendar oggi.
  - Atteso: aprire app → entro pochi secondi banner appare con `"Good morning. You have 2 events today. Want me to read them?"` + bottoni Yes/Not now
  - Tap Yes → `read_calendar` invocato, calendar letto vocalmente

- **E2E-13-PROACTIVE-2 (Post-call failure)** — Setup: Proactive ON. Pronunciare "Call John Smith" dove John Smith NON è in contacts (no phone).
  - Atteso: dopo errore Phone, entro 2s banner suggerisce `"That call didn't go through. Want me to message John Smith on WhatsApp instead?"` (se John ha WhatsApp registrato) OR `"That contact has no phone. Want me to add John Smith to Contacts?"`
  - Tap Yes → alternative action eseguita

- **E2E-13-PROACTIVE-3 (Recurring timer)** — Setup: Proactive ON. Pronunciare 3 volte nella giornata "Set a timer for 5 minutes" (3 timer separati).
  - Atteso: dopo il 3° timer, banner `"I notice you set a few timers today. Tip: I can also set recurring reminders. Try 'remind me every Tuesday at 6pm'."`
  - Tap Not now → banner si chiude, nessuna azione

- **E2E-13-PROACTIVE-4 (Anti-spam 30 min)** — Setup: Proactive ON. Forzare 2 fire entro 5 minuti (es. cambiando ora device).
  - Atteso: solo il primo si mostra, il secondo viene scartato silenziosamente (verifica log `os_log` "suggestion_throttled")

- **E2E-13-PROACTIVE-5 (3 dismiss auto opt-out)** — Setup: Proactive ON. Forzare 3 fire (cambiando context), dismissare tutti e 3.
  - Atteso: al 3° dismiss → toggle si spegne automaticamente + iOS notification appare: `"Proactive suggestions disabled. Re-enable in Settings."`
  - Verify: Settings → Proactive Suggestions → toggle OFF

- **E2E-13-PROACTIVE-6 (Opt-in default OFF)** — Setup: install fresh build.
  - Atteso: skippare onboarding (tap "Maybe later" sullo step Proactive) → forzare contesto che fa fire (es. mattino con calendar event) → NESSUN banner appare → Settings → Proactive Suggestions → toggle OFF

- **E2E-13-PROACTIVE-7 (Onboarding enable)** — Setup: install fresh build.
  - Atteso: onboarding step Proactive → tap Enable → Settings → Proactive Suggestions → toggle ON

---

## 6. Test post-creazione (verificabile mesi dopo)

### 6.1 Verifica via grep

```bash
ROOT="C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/02_GIGI_APP/GIGI"

# 1. GigiSuggestionEngine.swift esiste
test -f "$ROOT/GigiSuggestionEngine.swift" && echo "OK" || echo "MISSING"

# 2. Protocollo SuggestionProvider definito
grep "protocol SuggestionProvider" "$ROOT/GigiSuggestionEngine.swift"
# Output atteso: 1 match

# 3. Almeno 3 provider concreti
grep -E "(MorningCalendarSuggestion|PostCallFailureSuggestion|RecurringTimerSuggestion).*:.*SuggestionProvider" "$ROOT/GigiSuggestionEngine.swift" | wc -l
# Output atteso: >=3

# 4. UserDefaults key proactive_suggestions_enabled
grep "proactive_suggestions_enabled" "$ROOT/" -r
# Output atteso: ≥3 occorrenze (engine + settings + onboarding)

# 5. Throttle 30 min implementato
grep -E "30 \* 60|1800" "$ROOT/GigiSuggestionEngine.swift"
# Output atteso: 1+ match

# 6. dismissCount persistente
grep "suggestion_dismiss_count" "$ROOT/" -r
# Output atteso: ≥2 (set + read)

# 7. ProactiveSuggestionBanner SwiftUI view esiste
test -f "$ROOT/Views/ProactiveSuggestionBanner.swift" && echo "OK" || echo "MISSING"

# 8. Hook in GigiSmartOrchestrator
grep "GigiSuggestionEngine.shared.tick" "$ROOT/GigiSmartOrchestrator.swift"
# Output atteso: 1+ match

# 9. Onboarding step Proactive
grep -E "Proactive|proactive_suggestions" "$ROOT/OnboardingView.swift"
# Output atteso: 1+ match

# 10. Settings toggle
grep -E "Proactive Suggestions|proactive_suggestions_enabled" "$ROOT/SettingsView.swift"
# Output atteso: 1+ match

# 11. Long-tail tools: per ogni shippato, count entry in registry
grep -E "FindContactInfoTool|BlockNumberTool|ReadPdfAloudTool|TakeScreenshotTool" "$ROOT/GigiFoundationToolRegistry.swift" | wc -l
# Output atteso: dipende dal subset shippato — minimo >=N dove N è subset size

# 12. Catalog entries
grep -E "find_contact_info|block_number|read_pdf_aloud|take_screenshot" "$ROOT/GigiCapabilityCatalog.swift" | wc -l
# Output atteso: >=N
```

### 6.2 Verifica via xcodebuild

```bash
ssh user297422@FF125.macincloud.com "cd ~/GIGI-armando-rework/02_GIGI_APP && /usr/bin/xcodebuild -scheme GIGI -destination 'generic/platform=iOS' build 2>&1 | grep -E 'error:|warning:' | head -50"
# Output atteso: 0 errori, warning accettabili
```

### 6.3 Verifica via runtime inspection

```bash
# Logs filtrati per Proactive engine
log show --predicate 'subsystem == "com.gigi.app" AND category == "SuggestionEngine"' --last 1h --info
# Atteso: durante test E2E, log "suggestion_fired type=morningCalendar", "suggestion_dismissed", etc.
```

### 6.4 Verifica via tool coverage doc

```bash
cat "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/docs/research/gate-13-tool-coverage.md" | grep -E "PASS|FAIL"
# Output atteso: 1 riga PASS per ogni long-tail tool shippato
```

---

## 7. Rollback plan

### Rollback Proactive Suggestions

Se Proactive genera spam/UX rumorosa o degrada perf:

```bash
# Feature flag globale runtime
defaults write com.gigi.app proactive_suggestions_master_kill -bool true
# Lo engine controlla questo flag PRIMA del user-toggle, se true forza disable
```

Side effects:
- UserDefaults: `proactive_suggestions_master_kill` (NEW), `proactive_suggestions_enabled` (NEW), `suggestion_dismiss_count` (NEW) — possono restare in UserDefaults
- Banner non più mostrato anche se user-toggle è ON
- `GigiSuggestionEngine.tick()` ritorna early

Per rollback totale via git:
```bash
git revert <SHA-gate-13-proactive>
```

### Rollback long-tail tool singolo

Se un long-tail si rivela buggy:

```bash
# Feature flag per-tool
defaults write com.gigi.app gigi.feature.tool_<name>_disabled -bool true
# In GigiFoundationToolRegistry.allTools, filter via flag check
```

Side effects:
- Tool non più esposto ad Apple FM
- Fallback router lo skippa
- Catalog mostra "(coming soon)" invece di card normale

---

## 8. Files modificati / creati

| Path | Operazione | Righe stimate |
|---|---|---|
| `02_GIGI_APP/GIGI/GigiSuggestionEngine.swift` | **CREATE** (new file) | ~250 |
| `02_GIGI_APP/GIGI/Views/ProactiveSuggestionBanner.swift` | **CREATE** (new file) | ~80 |
| `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` | MODIFY (aggiunge long-tail Tool struct) | +30/tool shippato |
| `02_GIGI_APP/GIGI/GigiCapabilityCatalog.swift` | MODIFY (aggiunge catalog entry per long-tail) | +8/tool shippato |
| `02_GIGI_APP/GIGI/GigiFallbackRouter.swift` | MODIFY (aggiunge keyword table entries) | +5/tool shippato |
| `02_GIGI_APP/GIGI/GigiActionDispatcher+Native.swift` | MODIFY (handler nuovi per long-tail) | +20/tool shippato |
| `02_GIGI_APP/GIGI/GigiSmartOrchestrator.swift` | MODIFY (hook `tick()` in process flow) | +15 |
| `02_GIGI_APP/GIGI/OnboardingView.swift` | MODIFY (step Proactive opt-in) | +50 |
| `02_GIGI_APP/GIGI/SettingsView.swift` | MODIFY (toggle Proactive Suggestions) | +30 |
| `02_GIGI_APP/GIGI/Views/DashboardView.swift` | MODIFY (mount `ProactiveSuggestionBanner` overlay) | +10 |
| `02_GIGI_APP/GIGI/Info.plist` | MODIFY (permessi nuovi se long-tail richiede) | +6/permesso |
| `02_GIGI_APP/GIGI/GigiCallDirectoryExtension/` (se `block_number`) | **CREATE** (new Extension target) | ~150 |
| `docs/research/gate-13-tool-coverage.md` | **CREATE** | ~100 |
| `docs/adr/0010-capability-taxonomy-discovery.md` | UPDATE (chiude Layer D pendente) | +30 |

---

## 9. ADR collegati

- **ADR-0008** (Apple FM Tool calling) — riusata, ogni long-tail tool segue lo stesso pattern
- **ADR-0010** (Capability Taxonomy + Discovery Mechanism) — GATE 13 chiude **Layer D**, ultimo dei 4 layer dichiarati. Status passa da "Layer A/B/C Accepted, Layer D Proposed" → "All 4 layers Accepted, MVP+roadmap completed". Aggiornare il file ADR con sezione "Implementation Status" che dichiara closure.
- **ADR-0009** (Hardware targets) — long-tail tool aggiungono entry alla keyword table del fallback router, rispetto delle scelte hardware

---

## 10. Note operative

### Decisione PM upfront (kickoff GATE 13)

PRIMA di iniziare i task, il PM deve:
1. **Esaminare telemetry MVP post-launch** (≥2 settimane di dati)
2. **Compilare lista priorità long-tail** in commit body del primo commit:
   ```
   chore(gate-13): kickoff — long-tail subset decision

   Telemetry dataset: 14 giorni, 1.2k tool invocations, 87 unknown_capability fallbacks.

   Top requested missing capabilities:
   - "read aloud PDF" — 23 requests → ship Task 13.B.read_pdf_aloud
   - "take screenshot" — 18 requests → ship Task 13.E.take_screenshot
   - "skip music track" — 14 requests → ship Task 13.C.skip_track
   - "block number" — 11 requests → ship Task 13.A.block_number
   - "set volume" — 9 requests → ship Task 13.E.set_volume

   Defer to next iteration (low demand):
   - block_number, read_homekit_sensor, set_geofence_reminder, etc.

   Layer D Proactive: ship full (P1+P2+P3).
   ```

### Branch naming per sub-task

Ogni long-tail tool gira su branch dedicato per merge incrementale:
- `feat/gate-13-lt-read-pdf-aloud`
- `feat/gate-13-lt-take-screenshot`
- `feat/gate-13-lt-block-number`
- `feat/gate-13-lt-skip-track`
- `feat/gate-13-lt-find-contact-info`
- ...

Branch unico per Proactive Suggestions (3 sotto-GATE possono stare insieme):
- `feat/gate-13-proactive-suggestions`

### Conventional Commits suggeriti

```
chore(gate-13): kickoff — long-tail subset decision based on telemetry
feat(ios): GATE 13.A.1 — find_contact_info tool
feat(ios): GATE 13.A.3 — block_number tool + CallDirectoryExtension target
feat(ios): GATE 13.B.6 — read_pdf_aloud tool with PDFKit + AVSpeechSynthesizer
feat(ios): GATE 13.E.3 — take_screenshot tool with NSPhotoLibraryAddUsageDescription
feat(ios): GATE 13.P1 — GigiSuggestionEngine core + SuggestionProvider protocol
feat(ios): GATE 13.P2 — 3 concrete providers (morning calendar, post-call failure, recurring timer)
feat(ios): GATE 13.P3 — onboarding opt-in + settings toggle + 3-dismiss auto opt-out
test(ios): GATE 13 — long-tail coverage doc + Proactive E2E results
docs(adr): close ADR-0010 Layer D implementation
```

### Vincoli specifici Layer D Proactive (riepilogo)

- **Max 1 suggestion / 30 min** — throttle hardcoded, non configurabile dall'utente
- **Dismissibile con tap "Not now"** — sempre presente
- **3 dismiss → opt-out automatico** + iOS notification
- **Default OFF** — utente DEVE attivare esplicitamente
- **Trigger types**:
  - time-of-day (morning calendar 7:00-10:00 con eventi)
  - context (post-action-failure)
  - usage pattern (3 timer in giornata → tip recurring)
- **Storage**: `recentSuggestions` in-memory log (no persistence ora; eventuale Core Data in futuro se serve analytics)
- **Implementation**: protocollo `SuggestionProvider` + lista di provider concreti — facilmente estendibile in iterations future (es. `LocationArrivalSuggestion`, `BatteryLowSuggestion`)
- **Telemetry**: ogni suggestion fired/accepted/dismissed loggato per misurare retention impact post-deploy

### Cosa fare se long-tail telemetry post-MVP non è disponibile

Se per qualsiasi ragione (telemetry rotta, dataset insufficiente, lancio rimandato) PM non può prioritizzare basandosi su dati reali, fallback **prioritization by gut feeling**:

Default ordering (alto → basso ROI percepito):
1. `take_screenshot` (request frequente, impl semplice)
2. `read_pdf_aloud` (high-value disability/accessibility)
3. `skip_track` / `like_current_track` / `read_now_playing` (low effort, common use case)
4. `find_contact_info` (utility comune)
5. `complete_reminder` (paira con Reminders esistenti)
6. `move_calendar_event` / `cancel_calendar_event` (paira con Calendar esistenti)
7. `list_shortcuts` (discovery aid)
8. Resto on-demand

### Cosa fare se Proactive Suggestions genera dismiss massivi (>50%)

Se telemetry post-deploy mostra dismiss rate >50%:
1. Esaminare quali tipo di suggestion vengono dismissate (per type)
2. Se tutte le types ugualmente dismissate → problema UX globale, considerare riduzione frequenza (60 min invece di 30)
3. Se 1 specifico provider dominante nei dismiss → revisionare quel provider (es. soglie più strette, contesto più ricco)
4. Considerare **A/B test feature flag** post-iteration: 50% utenti con throttle 30min, 50% con throttle 60min, misurare retention

### Cosa fare se GATE 13.LT diventa indefinito

Il long-tail è esplicitamente **prioritized backlog**. Non c'è obbligo di shippare TUTTI i ~30 tool. PM può chiudere GATE 13 con:
- Sotto-GATE 13.LT: subset minimo 5 tool shippati (dimostrazione che il pattern funziona ripetibile)
- Sotto-GATE 13.P1+P2+P3: TUTTI obbligatori (Layer D è feature singola, non incrementale)

I long-tail residui non shippati restano nel master plan §6 Week 5+ come "future iterations" — saranno picked-up in cicli successivi senza necessità di un nuovo GATE.
