# GATE 2 — Router Apple FM upfront (first gate in process pipeline)

> **Status**: Pending (richiede GATE 1 chiuso con verdetto PASS o conditional)
> **Effort stimato**: 3-5 giorni lavorativi
> **Bloccanti pre-gate**: GATE 1 chiuso (Spike A risultati documentati, ADR-0011 closed); decisione Q11 presa (pin iOS 26.3 / accept 26.4 / feature flag); IPA installato sul telefono fisico
> **Sblocca**: GATE 3 (Path 2 Tool calling), GATE 4 (Path 3 Ollama), GATE 5 (Path 4 Claude Code)
> **Funzione consegnata (1 frase)**: Apple FM diventa il **primo gate** della pipeline `GigiAgentEngine.process()`, prende ogni query iOS in ingresso, ritorna un `FoundationRouterDecision` strutturato che decide tra 5 path (native_tool / delegate_local / delegate_cloud / ask_clarification / reject), e il dispatch è già wirato — anche se Path 2/3/4 sono ancora stub o legacy, il routing decision è osservabile in debug log e il Brain Path Override DEBUG continua a funzionare come escape hatch.

---

## 1. Obiettivo

Oggi `GigiAgentEngine.process(text:)` è un 3-Gate flat: Force Claude → NLU fast-path → Groq agentLoop. Apple FM è chiamato solo da `Brain Path Override = appleFM` (debug-only). Vogliamo invertire la responsabilità: Apple FM diventa il PRIMO gate non-debug, decide il routing per OGNI query, e il vecchio flow Groq diventa fallback dietro `path == "delegate_cloud"` per ora (sarà sostituito da Claude Code in GATE 5).

Questa è la trasformazione più importante del piano: senza un router upfront affidabile, tutti i GATE successivi sono inutili. Il GATE 2 implementa lo schema `FoundationRouterDecision`, il metodo `routeRequest()` su `GigiFoundationSession`, e il `GigiRequestRouter` come dispatch primary.

Output concreto:
- `GigiFoundationContracts.swift` contiene `FoundationRouterDecision @Generable` con 9 campi
- `GigiFoundationSession.routeRequest(text:history:) -> FoundationRouterDecision` funzionante
- `GigiRequestRouter.swift` (oggi stub) diventa impl ~280 righe e gestisce dispatch per i 5 path
- `GigiAgentEngine.process(text:)` chiama `GigiRequestRouter.shared.route(text:)` come prima cosa (dopo Brain Path Override DEBUG check)
- BrainPathOverride DEBUG continua a funzionare come escape hatch per testare path singoli ignorando il router
- Per ogni `path` valore, dispatch concreto:
  - `native_tool` → invocare NLU fast-path se intent corrispondente esiste, altrimenti stub "Path 2 not implemented yet (GATE 3)"
  - `delegate_local` → stub "Path 3 Ollama not implemented yet (GATE 4)"
  - `delegate_cloud` → invocare Groq agentLoop CORRENTE (sarà sostituito da Claude Code in GATE 5)
  - `ask_clarification` → speak `directSpeech`
  - `reject` → speak `directSpeech`

---

## 2. Pre-condizioni

- [ ] GATE 0 + GATE 1 chiusi
- [ ] Q11 decisa (deployment target iOS confermato)
- [ ] iPhone fisico con IPA installato e Brain Path Override picker funzionante
- [ ] Console Xcode accessibile per leggere log `os_log` durante test
- [ ] Stub `GigiRequestRouter.swift` presente (creato in `bdc393a`)
- [ ] Stub `GigiFoundationContracts.swift` presente con `FoundationAgentOutput` già migrato

---

## 3. Task implementativi

- **Task 2.1 — Implementare `FoundationRouterDecision` @Generable schema** (3h)
  - File: `02_GIGI_APP/GIGI/GigiFoundationContracts.swift`
  - Aggiungere `@Generable struct FoundationRouterDecision` con i 9 campi del piano §3.4:
    1. `path: String` — `"native_tool" | "delegate_local" | "delegate_cloud" | "ask_clarification" | "reject"`
    2. `primaryAction: String` — canonical action name se `path == "native_tool"`, empty otherwise
    3. `confidence: Double` — 0.0-1.0
    4. `complexityEstimate: Int` — 0-100
    5. `requiredCapabilities: [String]` — `["browser", "code", "vision", "memory_recall", "multi_step", "web_search"]`
    6. `reason: String` — max 12 words rationale
    7. `slots: ActionSlots` — pre-extracted slots struct
    8. `directSpeech: String` — testo da pronunciare per `ask_clarification` / `reject`
    9. `delegatePrompt: String` — rephrased prompt per delegate paths
  - Aggiungere `@Generable struct ActionSlots` con campi opzionali: `contact`, `body`, `destination`, `date`, `time`, `taskText`, `duration`, `label`, `appName`, `query`
  - Ogni campo con `@Guide(description: "...")` chiaro
  - Riferimento: piano `frolicking-stargazing-pancake.md` §3.4 schema completo
  - Note: TUTTE le `@Guide` description in inglese (regola CLAUDE.md), perché Apple FM è instructed in inglese e prompt user è in inglese

- **Task 2.2 — Implementare `GigiFoundationSession.routeRequest()`** (4h)
  - File: `02_GIGI_APP/GIGI/GigiFoundationSession.swift`
  - Aggiungere metodo:
    ```swift
    @MainActor
    func routeRequest(text: String, history: [ChatMessage]) async throws -> FoundationRouterDecision
    ```
  - Internamente:
    1. Costruire system prompt da `GigiFoundationAgent.routerSystemPrompt` (definito in Task 2.3)
    2. Costruire preamble compattato con ultimi 2-3 turni history (max 500 token)
    3. Invocare `LanguageModelSession.respond(to: text, generating: FoundationRouterDecision.self)`
    4. Gestire errori: `.exceededContextWindowSize`, `.modelUnavailable`, `.networkError` (PCC)
    5. Loggare via `os_log(.info, "router_decision: path=%@ confidence=%f", decision.path, decision.confidence)`
    6. Ritornare la decision
  - Su errore: throw, NON ritornare dummy decision (il caller in `GigiRequestRouter` deciderà fallback)

- **Task 2.3 — Aggiungere `routerSystemPrompt` curated** (2h)
  - File: `02_GIGI_APP/GIGI/GigiFoundationAgent.swift`
  - Aggiungere static var `routerSystemPrompt: String` con prompt strutturato che insegna ad Apple FM:
    - Cos'è ognuno dei 5 path
    - Quando scegliere quale
    - Esempi few-shot (3-5 per ognuna delle 5 categorie)
    - Regole di cost-aware: complexity ≤40 + non-browser → delegate_local
    - Esempi di slot extraction
  - Inglese, ~80-120 righe di prompt
  - Riferimento: piano §3.4 example queries + §3.7 budget 2k tok per system + tool defs + history
  - Test prompt manuale: copia-incolla il prompt nel Playground Apple FM (se disponibile) o testarlo runtime con 5 query e verificare che `path` sia coerente

- **Task 2.4 — Implementare `GigiRequestRouter.swift` da stub a full impl** (8h)
  - File: `02_GIGI_APP/GIGI/GigiRequestRouter.swift`
  - Da stub vuoto (commit `bdc393a` ~50 righe) → full impl ~280 righe
  - Struttura:
    ```swift
    @MainActor
    final class GigiRequestRouter {
        static let shared = GigiRequestRouter()
        private let foundationSession: GigiFoundationSession
        private let fallback: GigiFallbackRouter // stub per ora

        // Entry point
        func route(text: String, history: [ChatMessage]) async -> RouteResult

        // 5 path dispatch
        private func dispatchNativeTool(decision: FoundationRouterDecision) async -> RouteResult
        private func dispatchDelegateLocal(decision: FoundationRouterDecision) async -> RouteResult
        private func dispatchDelegateCloud(decision: FoundationRouterDecision) async -> RouteResult
        private func dispatchAskClarification(decision: FoundationRouterDecision) -> RouteResult
        private func dispatchReject(decision: FoundationRouterDecision) -> RouteResult

        // Fallback se Apple FM unavailable / erra
        private func routeFallback(text: String) async -> RouteResult
    }

    enum RouteResult {
        case spoken(String)              // ready to TTS
        case actionInvoked(GigiAgentResponse)
        case delegateLocal(prompt: String) // GATE 4 wirerà
        case delegateCloud(prompt: String) // GATE 5 wirerà
    }
    ```
  - Logica `dispatchNativeTool`:
    - Cercare `decision.primaryAction` nel `GigiActionDispatcher` mapping
    - Se trovato: invocare con `decision.slots` → ritornare `actionInvoked`
    - Se NON trovato (action name unknown): fallback a delegate_cloud
    - Caso speciale: se NLU fast-path già ha gestito (in `GigiAgentEngine` upstream), skip
  - Logica `dispatchDelegateLocal`:
    - Per GATE 2: stub speak `"Path 3 Ollama is not configured yet"` (sarà sostituito in GATE 4)
  - Logica `dispatchDelegateCloud`:
    - Per GATE 2: invocare il **Groq agentLoop CORRENTE** (sarà sostituito in GATE 5)
    - Mantiene continuità funzionale durante il transition
  - Logica `dispatchAskClarification` / `dispatchReject`: speak `decision.directSpeech`
  - Riferimento: piano §3.4 dispatch logic, stub esistente `GigiRequestRouter.swift`

- **Task 2.5 — Refactor `GigiAgentEngine.process()` per usare router** (4h)
  - File: `02_GIGI_APP/GIGI/GigiAgentEngine.swift`
  - Mantieni il `#if DEBUG` Brain Path Override gate per testing (`DebugBrainPath.current`)
  - Quando override è `auto` (caso non-debug), invece di cascata 3-Gate flat, chiamare:
    ```swift
    let result = await GigiRequestRouter.shared.route(text: text, history: history)
    return convertRouteResultToAgentResponse(result)
    ```
  - Mantieni helpers DEBUG (`processAppleFMOverride`, `ollamaStubResult`, `processForceClaude`) — saranno aggiornati in GATE successivi
  - **Mantieni anche NLU fast-path PRIMA del router**: se NLU regex hit con confidence ≥0.95, evita Apple FM round-trip e dispatch diretto a `GigiActionDispatcher`. Documenta nel codice perché.
    Razionale: Apple FM è 1-3s, NLU fast-path è 80-200ms. Per intent ovvi ("set timer", "what time is it") il router upfront sarebbe waste.
  - Quindi il nuovo flow è: `DEBUG override check → NLU fast-path → GigiRequestRouter.route() → response`

- **Task 2.6 — Wirare BrainPathOverride al router (skip Apple FM gate)** (1h)
  - File: `02_GIGI_APP/GIGI/SettingsView.swift` + `GigiAgentEngine.swift`
  - Quando override è `appleFM` / `ollama` / `claude`, il router DEVE essere skippato e si va dritti al path forzato
  - Quando override è `auto`, il router decide
  - Aggiornare `BrainPathOverride.helpText` per spiegare il nuovo comportamento
  - Riferimento: piano §3.11 D1 nota Phase 2

- **Task 2.7 — Logging strutturato + osservabilità** (2h)
  - File: `GigiRequestRouter.swift` + `GigiFoundationSession.swift`
  - Ogni decisione router log via `os_log` con format:
    `router_decision: path=%@ action=%@ complexity=%d capabilities=%@ confidence=%.2f`
  - In Settings → Debug aggiungere un toggle "Show last router decision" (popup small overlay che mostra ultimo `FoundationRouterDecision` in JSON)
  - Riferimento: piano §3.11 D1 note "il picker debug è anteprima testing"

- **Task 2.8 — Test integrazione 10 query mixed** (3h)
  - Eseguire manualmente su iPhone fisico, registrare in `docs/research/gate-2-router-integration-test.md`:
    1. "Set a timer for 5 minutes" → expect `native_tool`, dispatch immediato
    2. "What time is it" → expect NLU fast-path (skip router)
    3. "Send a message to Marco on WhatsApp" → expect `native_tool`, primaryAction=send_message
    4. "Explain Bayes theorem in 3 sentences" → expect `delegate_local`, complexity ~30
    5. "Search Wikipedia for Tesla" → expect `delegate_cloud`, capabilities=[browser]
    6. "Write a Python script to sort a list" → expect `delegate_cloud`, capabilities=[code]
    7. "Maybe set something for later" → expect `ask_clarification`
    8. "Buy bitcoin" → expect `reject` con cortese refusal
    9. "Turn on the kitchen light" → expect `native_tool`, primaryAction=homekit_on
    10. "Tell me a joke" → expect `delegate_local` (semplice reasoning)

---

## 4. Acceptance Criteria (AC)

- **AC1** — `GigiFoundationContracts.swift` contiene `@Generable struct FoundationRouterDecision` con tutti e 9 i campi del piano §3.4 (verifica via grep nei campi: path/primaryAction/confidence/complexityEstimate/requiredCapabilities/reason/slots/directSpeech/delegatePrompt)
- **AC2** — `GigiFoundationContracts.swift` contiene `@Generable struct ActionSlots` con almeno 10 campi opzionali (contact, body, destination, date, time, taskText, duration, label, appName, query)
- **AC3** — `GigiFoundationSession.swift` espone `routeRequest(text:history:) async throws -> FoundationRouterDecision` su `@MainActor`
- **AC4** — `GigiFoundationAgent.swift` espone static `routerSystemPrompt: String` di almeno 1500 caratteri (~80 righe prompt completo)
- **AC5** — Build verify: `xcodebuild` ritorna BUILD SUCCEEDED su iOS 26.3 SDK con questi cambiamenti
- **AC6** — `GigiRequestRouter.shared.route(text:history:)` esiste, è `@MainActor`, ritorna `RouteResult` enum
- **AC7** — Query "set a timer for 5 minutes" classificata da `routeRequest` come `path: "native_tool"`, `primaryAction: "set_timer"`, `slots.duration` contiene `"5 minutes"`, `confidence >= 0.85`. Verificato in log `router_decision`
- **AC8** — Query "explain Bayes theorem in 3 sentences" classificata come `path: "delegate_local"` con `complexityEstimate` nel range 20-50
- **AC9** — Query "search Wikipedia for Tesla" classificata come `path: "delegate_cloud"` con `requiredCapabilities` contiene `"browser"`
- **AC10** — Query "buy bitcoin" classificata come `path: "reject"`, `directSpeech` non vuoto e in inglese
- **AC11** — Brain Path Override `auto`: il router decide; override `appleFM` / `ollama` / `claude`: il router viene skippato e si va dritti al path forzato (verifica via log)
- **AC12** — NLU fast-path continua a funzionare PRIMA del router: query "what time is it" risponde in <500ms senza chiamare `routeRequest`
- **AC13** — Continuità funzionale: query non-NLU non-action (es. "tell me a joke") risponde tramite Groq agentLoop CORRENTE via `dispatchDelegateCloud` (Path 4 Claude Code NON ancora implementato in GATE 2)
- **AC14** — Settings → Debug ha toggle "Show last router decision" che mostra l'ultimo `FoundationRouterDecision` in formato JSON leggibile
- **AC15** — Su 10 query test integration (Task 2.8), almeno 8/10 sono classificate dal path corretto (confidence ≥0.7)

---

## 5. Test E2E sul telefono (verificabili dall'utente)

- **E2E-1** — Brain Path Override = `auto`, pronunciare "Set a timer for 5 minutes"
  - Atteso: latency totale ≤2.5s, speech response "Timer set", notifica iOS schedulata dopo 5 min
  - In log Xcode: `router_decision: path=native_tool action=set_timer confidence=>=0.85`
  - In log Xcode: dispatch to `GigiActionDispatcher.set_timer` con slots populated

- **E2E-2** — Brain Path Override = `auto`, pronunciare "What time is it"
  - Atteso: latency ≤500ms (NLU fast-path)
  - In log Xcode: `nlu_fast_path: intent=ask_time` (NO router decision, perché skipped da fast-path)

- **E2E-3** — Brain Path Override = `auto`, pronunciare "Explain Bayes theorem in three sentences"
  - Atteso: router decision `path=delegate_local complexity=~30`, response "Path 3 Ollama is not configured yet" (sarà rimosso in GATE 4)
  - In log Xcode: `router_decision: path=delegate_local ... dispatch_stub: ollama_not_configured`

- **E2E-4** — Brain Path Override = `auto`, pronunciare "Tell me a joke"
  - Atteso: router decision `path=delegate_local OR delegate_cloud`, response tramite Groq agentLoop (continuità funzionale)
  - Latency 2-8s

- **E2E-5** — Brain Path Override = `auto`, pronunciare "Search Wikipedia for Nikola Tesla"
  - Atteso: router decision `path=delegate_cloud requiredCapabilities=[browser, web_search] complexity=~70`, response stub "Path 4 Claude Code not configured yet" o fallback Groq

- **E2E-6** — Brain Path Override = `auto`, pronunciare "Maybe set something for later"
  - Atteso: router decision `path=ask_clarification`, speech response chiede chiarimento es. "When would you like me to set it for?"

- **E2E-7** — Brain Path Override = `auto`, pronunciare "Buy bitcoin"
  - Atteso: router decision `path=reject`, speech response cortese refusal in inglese

- **E2E-8** — Settings → Debug → toggle "Show last router decision" su ON, pronunciare una query qualsiasi
  - Atteso: dopo response, appare overlay con JSON dell'ultimo `FoundationRouterDecision` (path, action, slots, complexity, etc)

- **E2E-9** — Brain Path Override = `appleFM`, pronunciare "Set a timer for 5 minutes"
  - Atteso: router SKIPPED, dispatch diretto a Apple FM via `processAppleFMOverride`, latency simile a E2E-1 ma flow diverso (verifica log: NO `router_decision`)

- **E2E-10** — Brain Path Override = `claude`, pronunciare "Search Wikipedia for Tesla"
  - Atteso: router SKIPPED, dispatch diretto a Claude Code subprocess (richiede harness running)

---

## 6. Test post-creazione (verifica autonoma — ripetibile mesi dopo)

### 6.1 Verifica via grep / Glob

```bash
ROOT="C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/02_GIGI_APP/GIGI"

# 1. FoundationRouterDecision esiste con 9 campi
grep -c "var path:\|var primaryAction:\|var confidence:\|var complexityEstimate:\|var requiredCapabilities:\|var reason:\|var slots:\|var directSpeech:\|var delegatePrompt:" "$ROOT/GigiFoundationContracts.swift"
# Output atteso: 9

# 2. ActionSlots esiste
grep "struct ActionSlots" "$ROOT/GigiFoundationContracts.swift"
# Output atteso: 1 match

# 3. routeRequest method esiste
grep "func routeRequest(text:" "$ROOT/GigiFoundationSession.swift"
# Output atteso: 1 match

# 4. GigiRequestRouter ha route() entry point
grep "func route(text:" "$ROOT/GigiRequestRouter.swift"
# Output atteso: 1 match

# 5. RouteResult enum ha 4+ casi
grep -c "case spoken\|case actionInvoked\|case delegateLocal\|case delegateCloud" "$ROOT/GigiRequestRouter.swift"
# Output atteso: 4

# 6. routerSystemPrompt esiste
grep "routerSystemPrompt" "$ROOT/GigiFoundationAgent.swift"
# Output atteso: 1+ match (definizione)

# 7. GigiAgentEngine chiama GigiRequestRouter
grep "GigiRequestRouter.shared.route" "$ROOT/GigiAgentEngine.swift"
# Output atteso: 1 match

# 8. NLU fast-path resta PRIMA del router (verificare ordine)
grep -n "GigiNLUEngine\|GigiRequestRouter" "$ROOT/GigiAgentEngine.swift" | head -5
# Output atteso: linea di NLU appare prima di GigiRequestRouter
```

### 6.2 Verifica via xcodebuild

```bash
ssh user297422@FF125.macincloud.com "cd ~/GIGI-armando-rework/02_GIGI_APP && /usr/bin/xcodebuild \
  -project GIGI.xcodeproj -scheme GIGI -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tail -3"
# Output atteso: BUILD SUCCEEDED
```

### 6.3 Verifica via runtime debug log

Lanciare l'app collegata a Xcode, pronunciare "Set a timer for 5 minutes", aprire Console.app → filter `subsystem:io.gigi`. Atteso almeno:
- `router_decision: path=native_tool ...`
- `dispatch_native_tool: action=set_timer ...`

### 6.4 Verifica via integration test doc

Aprire `docs/research/gate-2-router-integration-test.md` e verificare che le 10 query siano popolate con risultati run e con accuracy ≥80%.

---

## 7. Rollback plan

Se GATE 2 si rivela rotto in produzione (es. router consistently sbaglia):

```bash
cd "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework"
git log --oneline | grep -i "GATE 2"
# Identifica SHA del commit GATE 2
git revert <SHA-gate-2>
# OR per rollback solo del routing logic mantenendo lo schema:
git checkout HEAD~1 -- 02_GIGI_APP/GIGI/GigiAgentEngine.swift  # ripristina 3-Gate flat
```

Side effects da pulire:
- UserDefaults: `gigi.debug.lastRouterDecision` (chiave nuova introdotta da Task 2.7) — può rimanere, è solo debug
- BrainPathOverride: comportamento `auto` cambia, ma l'enum non cambia → no migration

Alternativa più sicura: introduce feature flag `gigi.feature.routerUpfront` in `GigiAgentEngine`. Quando `false`, ripristina 3-Gate flat legacy. Quando `true`, usa il nuovo router. Permette rollback a runtime senza rebuild.

---

## 8. Files modificati / creati

| Path | Operazione | Righe stimate |
|---|---|---|
| `02_GIGI_APP/GIGI/GigiFoundationContracts.swift` | MODIFY (aggiunge schema) | +120 |
| `02_GIGI_APP/GIGI/GigiFoundationSession.swift` | MODIFY (routeRequest) | +80 |
| `02_GIGI_APP/GIGI/GigiFoundationAgent.swift` | MODIFY (routerSystemPrompt) | +100 |
| `02_GIGI_APP/GIGI/GigiRequestRouter.swift` | MODIFY (stub → full impl) | +280 (-30 stub) |
| `02_GIGI_APP/GIGI/GigiAgentEngine.swift` | MODIFY (route() call) | +40 |
| `02_GIGI_APP/GIGI/SettingsView.swift` | MODIFY (Show last router decision toggle) | +30 |
| `docs/research/gate-2-router-integration-test.md` | CREATE | ~100 |

---

## 9. ADR collegati

- **ADR-0007** (Hybrid 5-path router) — questo GATE flesh-out l'ADR (Status: Proposed → Accepted al merge)
- ADR-0008 (Apple FM Tool calling vs scored registry) — prep per GATE 3; non si chiude qui ma router decision `native_tool` è il prerequisito
- ADR-0011 (iOS 26.4 regression mitigation) — già closed in GATE 1; questo GATE rispetta la decisione presa

---

## 10. Note operative

- **Commit strategy**: 1 commit per ogni Task 2.1-2.7, opzionalmente squash al merge. NON committare in unico bigblob.
- **Conventional Commits suggeriti**:
  ```
  feat(ios): GATE 2.1 — FoundationRouterDecision @Generable schema
  feat(ios): GATE 2.2 — GigiFoundationSession.routeRequest()
  feat(ios): GATE 2.3 — routerSystemPrompt curated prompt
  feat(ios): GATE 2.4 — GigiRequestRouter full implementation
  refactor(ios): GATE 2.5 — GigiAgentEngine uses router as primary gate
  feat(ios): GATE 2.6 — BrainPathOverride skips router for forced paths
  chore(ios): GATE 2.7 — router decision logging + debug overlay
  test(ios): GATE 2.8 — 10-query integration test results
  ```
- **Build verify**: dopo ogni Task major (2.1, 2.4, 2.5) eseguire SSH build per evitare accumulo errori
- **Apple FM context budget**: il router system prompt + 15 tool defs + history sliding window deve stare in ≤2k token. Se si avvicina, ridurre few-shot examples nel prompt
- **PCC opacity warning**: documenta in codice che `routeRequest` può eseguire on-device O via Apple Private Cloud Compute, non c'è controllo iOS-side. Per "Local-First Mode" futuro, vedi GATE 7

### Cosa fare se Apple FM tool calling è instabile (legacy Spike A FAIL)

Se GATE 1 ha chiuso con `Status: Rejected` (regression grave su iOS attuale):

1. Sostituire `routeRequest()` con `GigiFallbackRouter.classifyRequest()` (rule-based) come primary
2. Apple FM resta opt-in solo via Brain Path Override `appleFM`
3. Il router rule-based usa keyword matching su set di canonical actions
4. Documentare deviation in commit message + nota in `GigiRequestRouter.swift`

### Cosa fare se `complexityEstimate` è inaffidabile

Il piano §7 Q11 + §9 risk row "complexityEstimate zero-shot non calibrato" segnala che il modello LLM-generated score può driftare. Mitigazione:
- Loggare a runtime `complexityEstimate` insieme a path → telemetria locale (file JSON in App Support)
- Dopo 100+ query, analizzare distribuzione: se delegate_local risulta sempre `complexity > 40` quando dovrebbe essere ≤40, ricalibrare prompt
- Considerare in GATE 8 una calibrazione semi-automatica
