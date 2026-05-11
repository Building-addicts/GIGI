# GATE 3 — Path 2: Apple FM Tool calling (subset 15 tool nativi iOS)

> **Status**: Pending (richiede GATE 2 chiuso + Q2 decisa)
> **Effort stimato**: 4-6 giorni lavorativi
> **Bloccanti pre-gate**: GATE 2 chiuso (router upfront funzionante); **decisione Q2 presa** (lista finale 15 tool Apple FM); iPhone Apple Intelligence-capable disponibile
> **Sblocca**: GATE 4 (Path 3 Ollama) — perché Path 2 e Path 3 sono indipendenti, ma GATE 6 killer demo dipende da entrambi
> **Funzione consegnata (1 frase)**: Apple FM Tool calling diventa il motore di Path 2 — quando il router decide `path: "native_tool"`, Apple FM invoca uno dei 15 `Tool` registrati che fa il bridge a `GigiActionDispatcher`, eseguendo l'azione iOS native senza più chiamare Groq né NLU brittle scoring.

---

## 1. Obiettivo

Il router upfront (GATE 2) classifica già le query come `native_tool` con `primaryAction` pre-estratto. Ma oggi il dispatch a `GigiActionDispatcher` passa attraverso `GigiToolRegistry.selectRelevant_DEPRECATED()` (47 tool con scoring brittle) — TD-001 che ADR-0008 vuole chiudere.

GATE 3 implementa il pattern WWDC 2025 `Tool` protocol di Apple FM: 15 `Tool` struct conformi (uno per ognuno del subset Q2), ognuno con `@Generable struct Arguments`, ognuno il cui `call(arguments:)` fa il bridge a `GigiActionDispatcher.bridge.executeRaw(label:, params:)`. Apple FM tool calling diventa così affidabile (constrained decoding) e il `selectRelevant_DEPRECATED` può essere finalmente rimosso dal compile target (rimosso fisicamente: in GATE 8).

Per device NON-Apple-FM-capable (iPhone <15 Pro, iPad non-M), `GigiFallbackRouter` rule-based fa la stessa job con keyword matching — funziona ma con accuracy minore. Questo è ADR-0009 hardware target.

Output concreto:
- `GigiFoundationToolRegistry.swift` (da stub a impl ~400 righe) con 15 `Tool` struct
- `GigiFoundationSession.respondWithTools(text:tools:)` Phase 2 API
- `GigiFallbackRouter.swift` (da stub a impl ~120 righe) per device non-Apple-FM
- `GigiRequestRouter.dispatchNativeTool()` aggiornato per usare Path 2 vero (non più stub)
- `selectRelevant_DEPRECATED()` non più chiamato da nessuno (lo rimuoviamo fisicamente in GATE 8 cleanup)

---

## 2. Pre-condizioni

- [ ] GATE 0 + 1 + 2 chiusi
- [ ] **Q2 decisa**: lista finale dei 15 tool da esporre ad Apple FM. Proposta corrente nel piano:
  - `set_timer`, `set_alarm`, `set_reminder`, `send_message`, `make_call`, `facetime`, `navigate`, `play_music`, `open_app`, `weather`, `read_calendar`, `find_free_slot`, `read_email`, `homekit_on`, `homekit_off`, `delegate_to_claude`
  - Sono 16 tool, da chiudere a 15: candidati removal `delegate_to_claude` (può vivere come fallback nel router, non come tool diretto) OR fusione `homekit_on` + `homekit_off` in `homekit_toggle(state: on|off)`
  - Decisione PM: documentare nel commit body
- [ ] `GigiActionDispatcher.bridge.executeRaw(label:, params:)` esiste in `GigiActionBridge.swift` (verifica con grep)
- [ ] iPhone 15 Pro+ fisico con Apple Intelligence attivata

---

## 3. Task implementativi

- **Task 3.1 — Definire 15 `Tool` struct in `GigiFoundationToolRegistry.swift`** (12h totali, ~50min per tool)
  - File: `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift`
  - Da stub vuoto → impl ~400 righe
  - Pattern per ogni tool (esempio `SetTimerTool`):
    ```swift
    @available(iOS 26, *)
    struct SetTimerTool: Tool {
        let name = "set_timer"
        let description = "Set a countdown timer. Use when the user asks to time something."

        @Generable
        struct Arguments {
            @Guide(description: "Timer label like 'pasta' or 'workout'. Empty if not specified.")
            var label: String

            @Guide(description: "Duration in natural language like '5 minutes', '1 hour 30 minutes'.")
            var duration: String
        }

        func call(arguments: Arguments) async -> String {
            return await GigiActionDispatcher.shared.bridge.executeRaw(
                label: "set_timer",
                params: ["label": arguments.label, "duration": arguments.duration]
            )
        }
    }
    ```
  - Costruire 15 tool struct seguendo lo stesso pattern. Per ognuno:
    - Nome canonico esatto come in `GigiActionDispatcher` mapping
    - Description in inglese, max 80 token, chiara su QUANDO usare il tool
    - `Arguments` con i campi che il tool richiede (vedi `GigiActionDispatcher+Native.swift` / `+Web.swift` per quali param ogni handler accetta)
    - `call()` delega a `executeRaw` con dictionary `[String: String]`
  - Esposizione: aggiungere static `static let allTools: [any Tool] = [SetTimerTool(), SetAlarmTool(), ..., DelegateToClaudeTool()]` per facile registrazione
  - Riferimento: piano §3.6 pattern + §3.8 §3.7 context budget (≤80 token per tool)
  - Note: TUTTE le description in inglese, regola CLAUDE.md

- **Task 3.2 — Implementare `GigiFoundationSession.respondWithTools()`** (4h)
  - File: `02_GIGI_APP/GIGI/GigiFoundationSession.swift`
  - Aggiungere metodo:
    ```swift
    @MainActor
    func respondWithTools(
        text: String,
        tools: [any Tool],
        history: [ChatMessage]
    ) async throws -> ToolCallResult
    ```
  - Internamente: invocare `LanguageModelSession(tools: tools).respond(to: text)` con compactedHistory preamble
  - Ritornare struct `ToolCallResult { let toolInvoked: String?, let toolArgs: [String: Any]?, let directSpeech: String? }`
  - Gestione errori:
    - `.exceededContextWindowSize` → fallback a session senza history
    - `.modelUnavailable` → throw, caller gestisce
    - Tool call returns error string → propagate to caller
  - Logging `os_log` per ogni tool invocation

- **Task 3.3 — Aggiornare `GigiRequestRouter.dispatchNativeTool()`** (3h)
  - File: `02_GIGI_APP/GIGI/GigiRequestRouter.swift`
  - Logica nuova:
    1. Cercare il tool corrispondente a `decision.primaryAction` in `GigiFoundationToolRegistry.allTools`
    2. Se trovato: chiamare `GigiFoundationSession.shared.respondWithTools(text: decision.delegatePrompt ?? text, tools: [matchingTool], history: history)`
    3. Se Apple FM non-capable (iOS <26, no Apple Intelligence): cadere su `GigiFallbackRouter.dispatchNativeTool(action: decision.primaryAction, slots: decision.slots)`
    4. Se tool name unknown: fallback a `dispatchDelegateCloud`
  - Ottimizzazione: passare SOLO il tool target (non tutti i 15) per ridurre context — il router ha già deciso quale
  - In alternativa per multi-tool conversation: passare tutti i 15 quando `primaryAction` è ambiguo
  - Riferimento: piano §3.4 dispatch logic + §3.6 esempi

- **Task 3.4 — Implementare `GigiFallbackRouter.swift` per device non-Apple-FM** (8h)
  - File: `02_GIGI_APP/GIGI/GigiFallbackRouter.swift`
  - Da stub vuoto → impl ~120 righe
  - Logica:
    ```swift
    @MainActor
    final class GigiFallbackRouter {
        static let shared = GigiFallbackRouter()

        // Classifica via keyword matching
        func classifyRequest(text: String) -> FoundationRouterDecision

        // Dispatch quando Apple FM non-capable
        func dispatchNativeTool(action: String, slots: ActionSlots) async -> RouteResult

        // Keyword tables per ogni canonical action
        private static let keywordTable: [String: [String]] = [
            "set_timer": ["timer", "countdown", "remind me in"],
            "set_alarm": ["wake me", "alarm", "wake up"],
            // ... 15 entries
        ]
    }
    ```
  - `classifyRequest` ritorna decision con confidence calcolata su match score
  - `dispatchNativeTool` invoca direttamente `GigiActionDispatcher.shared.bridge.executeRaw`
  - Riferimento: piano §3.5 "Rule-based fallback rule-based" + ADR-0009

- **Task 3.5 — Detection capability Apple FM al boot** (3h)
  - File: `GigiFoundationSession.swift` + `GigiSmartOrchestrator.swift`
  - Esporre `@MainActor static var isAppleFMAvailable: Bool` basato su:
    - iOS version >= 26
    - `LanguageModelSession.modelAvailability` ritorna `.available`
    - Hardware Apple Intelligence-capable (iPhone 15 Pro+, iPad M-series, etc.)
  - Caching del valore al boot, refresh on app foreground
  - Usato da `GigiRequestRouter.shared.route()` per decidere se invocare Apple FM o fallback

- **Task 3.6 — Test E2E 12 query per copertura tool** (4h)
  - Per ognuno dei 15 tool, pronunciare 1 query che lo attivi + 1 query edge case
  - Registrare risultati in `docs/research/gate-3-tool-coverage.md`:
    - tool name, query, dispatch path (apple_fm | fallback), success/fail, latency
  - 80%+ success rate richiesto

- **Task 3.7 — Aggiornare `BrainPathOverride.helpText`** (30min)
  - File: `SettingsView.swift`
  - Per ogni opzione picker, aggiornare la descrizione:
    - `auto`: "Router Apple FM decide path"
    - `appleFM`: "Force Apple FM Tool calling (Path 2)"
    - `ollama`: "Force Ollama harness (Path 3, not configured yet)"
    - `claude`: "Force Claude Code subprocess (Path 4, not configured yet)"

- **Task 3.8 — Note di deprecation `selectRelevant_DEPRECATED`** (1h)
  - File: `GigiToolRegistry.swift`
  - Verificare che nessun caller chiami più `selectRelevant_DEPRECATED` (grep)
  - Aggiungere commento "Removable in GATE 8 cleanup" sopra la funzione
  - NON rimuovere fisicamente ancora (sicurezza in case rollback)

---

## 4. Acceptance Criteria (AC)

- **AC1** — `GigiFoundationToolRegistry.swift` contiene 15 `Tool` struct conformi al protocol `Tool` (`@available(iOS 26, *)`)
- **AC2** — Ogni tool ha `name`, `description`, `Arguments @Generable`, `call(arguments:) async -> String`
- **AC3** — Tutte le `description` dei tool e dei `@Guide` sono in inglese (regola CLAUDE.md)
- **AC4** — Static `allTools: [any Tool]` ritorna 15 elementi
- **AC5** — `GigiFoundationSession.respondWithTools(text:tools:history:)` esiste e ritorna `ToolCallResult`
- **AC6** — `GigiRequestRouter.dispatchNativeTool()` chiama `GigiFoundationToolRegistry` se Apple FM disponibile, altrimenti `GigiFallbackRouter`
- **AC7** — `GigiFallbackRouter.classifyRequest(text:)` ritorna `FoundationRouterDecision` per device non-Apple-FM con keyword table di 15 entries
- **AC8** — `GigiFoundationSession.isAppleFMAvailable` esposto e cached, ritorna `true` su iPhone 15 Pro+ con Apple Intelligence on
- **AC9** — Build verify: `xcodebuild` BUILD SUCCEEDED
- **AC10** — Su iPhone 15 Pro+: pronunciare "Set timer for 5 minutes" → Apple FM invoca `SetTimerTool` (verifica log `tool_invoked: set_timer`) → `GigiActionDispatcher.bridge.executeRaw("set_timer", ...)` → notifica iOS schedulata
- **AC11** — Su iPhone 15 Pro+: per ognuna delle 15 tool, almeno 1 query la attiva correttamente (15/15 coverage)
- **AC12** — Su iPhone non-Apple-FM (se disponibile, OR simulato disattivando Apple Intelligence): query "set timer for 5 minutes" → `GigiFallbackRouter` keyword match → dispatch corretto
- **AC13** — Su Brain Path Override = `appleFM` + query "set timer", il dispatch passa SEMPRE per Path 2 (`GigiFoundationToolRegistry`), MAI per `selectRelevant_DEPRECATED`
- **AC14** — `selectRelevant_DEPRECATED` non è chiamato da nessun caller (grep verifica)

---

## 5. Test E2E sul telefono (verificabili dall'utente)

- **E2E-1** — "Set a timer for 10 minutes" (tool: set_timer)
  - Atteso: Apple FM invoca `SetTimerTool`, slots `{duration:"10 minutes"}`, notifica iOS, "Timer set"

- **E2E-2** — "Wake me up at 7:30 in the morning" (tool: set_alarm)
  - Atteso: Apple FM invoca `SetAlarmTool`, slots `{time:"7:30 AM"}`, alarm Clock app schedulata

- **E2E-3** — "Remind me to call Marco tomorrow at 10am" (tool: set_reminder)
  - Atteso: Apple FM invoca `SetReminderTool`, slots `{taskText:"call Marco", date:"tomorrow", time:"10am"}`, Reminders app entry

- **E2E-4** — "Send a message to Sara on WhatsApp saying I'll be late" (tool: send_message)
  - Atteso: Apple FM invoca `SendMessageTool`, slots `{contact:"Sara", platform:"whatsapp", body:"I'll be late"}`, WhatsApp si apre con conversazione Sara + body precompilato

- **E2E-5** — "Call Mum" (tool: make_call)
  - Atteso: Apple FM invoca `MakeCallTool`, slots `{contact:"Mum"}`, app Phone fa la chiamata

- **E2E-6** — "Facetime Federico" (tool: facetime)
  - Atteso: Apple FM invoca `FacetimeTool`, FaceTime call lanciata

- **E2E-7** — "Navigate to Bologna train station" (tool: navigate)
  - Atteso: Apple FM invoca `NavigateTool`, Maps si apre con destinazione

- **E2E-8** — "Play Daft Punk on Spotify" (tool: play_music)
  - Atteso: Apple FM invoca `PlayMusicTool`, slots `{artist:"Daft Punk", platform:"spotify"}`, Spotify si apre e play

- **E2E-9** — "What's the weather in Milan tomorrow" (tool: weather)
  - Atteso: Apple FM invoca `WeatherTool`, slots `{location:"Milan", date:"tomorrow"}`, response con weather data

- **E2E-10** — "What's on my calendar Friday" (tool: read_calendar)
  - Atteso: Apple FM invoca `ReadCalendarTool`, eventi Friday letti da EventKit, response speech

- **E2E-11** — "Find a free slot Thursday afternoon" (tool: find_free_slot)
  - Atteso: Apple FM invoca `FindFreeSlotTool`, EventKit query, response con free slot

- **E2E-12** — "Read my latest email" (tool: read_email)
  - Atteso: Apple FM invoca `ReadEmailTool`, ultima email letta (Mail.app o Gmail integration), speech response

- **E2E-13** — "Turn on the living room light" (tool: homekit_on)
  - Atteso: Apple FM invoca `HomeKitOnTool`, slots `{accessory:"living room light"}`, luce HomeKit accesa

- **E2E-14** — "Turn off the kitchen light" (tool: homekit_off)
  - Atteso: Apple FM invoca `HomeKitOffTool`, luce HomeKit spenta

- **E2E-15** — "Open Spotify" (tool: open_app)
  - Atteso: Apple FM invoca `OpenAppTool`, slots `{appName:"Spotify"}`, app Spotify lanciata

- **E2E-16 (fallback)** — Disattivare Apple Intelligence in iOS Settings → pronunciare "Set timer for 5 minutes"
  - Atteso: `GigiFallbackRouter` keyword match, dispatch via `executeRaw`, "Timer set" — comportamento equivalente ma latency leggermente diversa, log `dispatch_fallback`

---

## 6. Test post-creazione (verifica autonoma)

### 6.1 Verifica via grep

```bash
ROOT="C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/02_GIGI_APP/GIGI"

# 1. 15 tool struct esistono (cerca "let name = " nel file)
grep -c "let name = " "$ROOT/GigiFoundationToolRegistry.swift"
# Output atteso: 15

# 2. allTools array ha 15 elementi
grep -A20 "static let allTools" "$ROOT/GigiFoundationToolRegistry.swift" | grep -c "Tool()"
# Output atteso: 15

# 3. respondWithTools method esiste
grep "func respondWithTools(text:" "$ROOT/GigiFoundationSession.swift"
# Output atteso: 1 match

# 4. GigiFallbackRouter classifyRequest esiste
grep "func classifyRequest(text:" "$ROOT/GigiFallbackRouter.swift"
# Output atteso: 1 match

# 5. keywordTable ha 15 entries
grep -E "set_timer|set_alarm|set_reminder|send_message|make_call|facetime|navigate|play_music|open_app|weather|read_calendar|find_free_slot|read_email|homekit_on|homekit_off" "$ROOT/GigiFallbackRouter.swift" | wc -l
# Output atteso: >=15 (uno per ognuna delle 15 canonical actions)

# 6. selectRelevant_DEPRECATED non chiamato da nessuno
grep -rn "selectRelevant_DEPRECATED" "$ROOT/" | grep -v "GigiToolRegistry.swift"
# Output atteso: 0 match (solo la definizione in GigiToolRegistry, no callers)

# 7. isAppleFMAvailable esposto
grep "isAppleFMAvailable" "$ROOT/GigiFoundationSession.swift"
# Output atteso: 1+ match
```

### 6.2 Verifica via xcodebuild + tool coverage doc

```bash
# Build
ssh user297422@FF125.macincloud.com "cd ~/GIGI-armando-rework/02_GIGI_APP && /usr/bin/xcodebuild ..."

# Tool coverage
cat "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/docs/research/gate-3-tool-coverage.md" | grep -E "PASS|FAIL"
# Output atteso: 15+ righe PASS (1 per tool), max 1-2 FAIL accettabili
```

### 6.3 Verifica runtime per ognuno dei 15 tool

Re-eseguire le 15 E2E sopra (o subset random di 5) e verificare via Console.app log `tool_invoked: <name>`.

---

## 7. Rollback plan

Se Apple FM Tool calling si rivela inaffidabile in produzione:

```bash
cd "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework"
git revert <SHA-gate-3>
```

Alternative meno destructive:
- Feature flag `gigi.feature.path2_apple_fm_tools: bool` in `GigiRequestRouter`. Quando false, `dispatchNativeTool` cade direttamente su `GigiFallbackRouter`. Permette toggle runtime.
- Toggle on `gigi.feature.path2_apple_fm_tools` default true; se Spike A telemetry post-deploy mostra accuracy <70%, set a false.

Side effects:
- UserDefaults: nessuno nuovo
- Compilation: rimuovere il file `GigiFoundationToolRegistry.swift` causerebbe break in `GigiRequestRouter` — gestire con `#if FALSE` o stub

---

## 8. Files modificati / creati

| Path | Operazione | Righe stimate |
|---|---|---|
| `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` | MODIFY (stub → 15 Tool) | +400 (-30 stub) |
| `02_GIGI_APP/GIGI/GigiFoundationSession.swift` | MODIFY (respondWithTools + isAppleFMAvailable) | +120 |
| `02_GIGI_APP/GIGI/GigiRequestRouter.swift` | MODIFY (dispatchNativeTool full) | +80 |
| `02_GIGI_APP/GIGI/GigiFallbackRouter.swift` | MODIFY (stub → keyword router) | +120 (-30 stub) |
| `02_GIGI_APP/GIGI/SettingsView.swift` | MODIFY (helpText) | +10 |
| `02_GIGI_APP/GIGI/GigiToolRegistry.swift` | MODIFY (commento removable) | +3 |
| `docs/research/gate-3-tool-coverage.md` | CREATE | ~80 |

---

## 9. ADR collegati

- **ADR-0008** (Apple FM Tool calling vs scored registry) — questo GATE la chiude (Status: Proposed → Accepted)
- **ADR-0009** (Hardware targets and modes) — GigiFallbackRouter è la realizzazione concreta del fallback rule-based di ADR-0009; ADR aggiornata con riferimento all'implementazione
- ADR-0007 (Hybrid 5-path) — Path 2 implementato per la prima volta

---

## 10. Note operative

- **Decisione Q2 commit body**: documentare nel primo commit del GATE quale lista 15 tool finale + razionale (perché DelegateToClaudeTool incluso/escluso, perché homekit_toggle vs on/off split)
- **Test su device fisico OBBLIGATORIO**: Apple FM Tool calling non simula bene su Xcode Simulator
- **Conventional Commits suggeriti**:
  ```
  feat(ios): GATE 3.1 — 15 Apple FM Tool struct in GigiFoundationToolRegistry
  feat(ios): GATE 3.2 — respondWithTools session API
  feat(ios): GATE 3.3 — GigiRequestRouter.dispatchNativeTool via Apple FM
  feat(ios): GATE 3.4 — GigiFallbackRouter keyword-based per non-Apple-FM
  feat(ios): GATE 3.5 — isAppleFMAvailable capability detection
  test(ios): GATE 3.6 — 15 tool coverage test results
  ```
- **Context budget Apple FM**: 15 tool descriptions ≤80 token ognuna = ~1.2k token totali. Lascia ~2k per system + user + history. Se overflow `.exceededContextWindowSize`, ridurre tool description verbosity.

### Cosa fare se un tool specifico fallisce frequentemente

Esempio: `WeatherTool` ritorna sempre risposte inconsistenti.

1. Loggare 10+ tentativi reali in `docs/research/gate-3-tool-coverage.md`
2. Esaminare se è problema di:
   - Prompt description tool (Apple FM non capisce QUANDO usare il tool)
   - Slot extraction (location/date sbagliati)
   - Bridge `executeRaw` (handler iOS-side rotto)
3. Per (a): revise tool description, more clear "use when user asks about weather conditions for a specific location"
4. Per (b): aggiungere `@Guide` esempi
5. Per (c): debug `GigiActionDispatcher+Native.swift` `handleWeather()`

### Cosa fare se 15 tool è troppo per context budget

Se Apple FM rimanda `.exceededContextWindowSize` con tutti i 15 tool:
1. Implementare **subset selection upfront** nel router: il router stesso decide quali 3-5 tool passare ad Apple FM in base a keyword detection veloce
2. Aggiunge un secondo Apple FM round-trip (router → subset → tool call) ma resta sotto 4096 token
3. Latency aumenta di 1-2s ma quality migliora
