# GATE 4 — Path 3: Ollama harness (offline reasoning) + Spike B validation

> **Status**: Pending (richiede GATE 3 chiuso)
> **Effort stimato**: 4-5 giorni lavorativi (di cui 1-1.5g per Spike B)
> **Bloccanti pre-gate**: GATE 3 chiuso (Path 2 funzionante con 15 tool); Mac con 16GB+ RAM disponibile (Mac M4 Pro ideale per Spike B); Ollama installabile sull'host del harness
> **Sblocca**: GATE 5 (Path 4 Claude Code), GATE 6 (killer demo)
> **Funzione consegnata (1 frase)**: quando il router decide `path: "delegate_local"`, GIGI delega al server Ollama che gira sull'harness LAN (Qwen 3 14B default), riceve la response in streaming via SSE, la pronuncia tramite TTS — zero API a pagamento, zero dipendenza cloud, hardware-tier configurabile da Settings.

---

## 1. Obiettivo

Path 3 è il motore di reasoning offline. Senza Path 3, ogni query non-action ("explain Bayes", "summarize this email", "rephrase professionally") va a Path 4 Claude Code bruciando subscription cap. Cost-aware routing del piano §3.4 richiede che task semplici/medi (`complexity ≤40 + non-browser`) vadano a Ollama.

GATE 4 implementa:
1. **Spike B empirico**: validare che Qwen 3 14B sia il tier default corretto (BFCL ≥75%, loop rate <5% su 200+ multi-turn)
2. **`ollama-client.js`** harness HTTP wrapper (da stub a impl)
3. **`ios-local-llm.js`** SSE streaming endpoint per app iOS (da stub a impl, oggi ritorna 501)
4. **`GigiHarnessClient.runLocalLLM()`** Swift extension che consuma SSE
5. **`GigiRequestRouter.dispatchDelegateLocal()`** aggiornato per chiamare `runLocalLLM` invece dello stub "not configured yet"
6. **Settings → Brain section**: tier model selector (lite/standard/default/pro) che legge harness config
7. **Brain Path Override `ollama`** non è più stub

Output: query "Explain Bayes theorem in 3 sentences" produce response streaming via Ollama, latency 7-15s, AVSpeechSynthesizer pronuncia chunk-by-chunk.

---

## 2. Pre-condizioni

- [ ] GATE 0-3 chiusi
- [ ] Mac M4 Pro o equivalente (16GB+ RAM) accessibile via SSH (può essere lo stesso MacInCloud usato per build verify, OR il Mac harness di Armando in locale)
- [ ] Ollama installato (`brew install ollama` o `https://ollama.com/download`)
- [ ] 30GB liberi su disco per pull dei 4 modelli Qwen
- [ ] Harness Node.js attualmente running per integrazione (vedi `03_HARNESS/CLAUDE.md`)
- [ ] App iOS con IPA installato e connessa al harness via QR pairing

---

## 3. Task implementativi

- **Task 4.1 — Spike B: pull 4 modelli + 40-query test set** (1g)
  - Sul Mac harness:
    ```bash
    ollama pull qwen3:4b      # ~2.5GB
    ollama pull qwen3:8b      # ~5GB
    ollama pull qwen3:14b     # ~9GB (DEFAULT proposto)
    ollama pull qwen3.6:27b   # ~16GB (PRO tier)
    ```
  - Verifica con `ollama list`
  - **AVOID**: `qwen3.5:*` (Ollama tool calling broken — Issue ollama#14493). Verifica issue status prima.
  - Preparare test set 40 query in `docs/research/spike-b-test-set.md`:
    - 20 intent classification (cosa risponde Qwen come router? — utile come baseline)
    - 10 reasoning ("explain X", "summarize Y", "rephrase Z")
    - 5 tool calling multi-arg
    - 5 ambiguous router decision
  - Riferimento: `docs/research/phase-1-1-empirical-validation.md` Spike B

- **Task 4.2 — Spike B: eseguire test set** (6-8h)
  - Per ognuno dei 4 modelli:
    1. Run 40 query via `ollama run <model>` CLI
    2. Per le 5 tool calling: usare `ollama run <model> --format json` con prompt che richiede JSON output
    3. Per ogni modello, eseguire 200+ multi-turn tool call sequences per detettare infinite loop (Qwen MoE problema noto)
    4. Registrare in `docs/research/spike-b-results.md`:
       - Modello, query, accuracy %, latency P50/P95, RAM peak, loop rate
  - Calcolare metriche aggregate
  - Verdetto: Qwen 3 14B PASS se BFCL ≥75% + loop <5%
  - Documentare anti-shortlist (`qwen3.5:*` confermato broken)

- **Task 4.3 — Implementare `ollama-client.js`** (4h)
  - File: `03_HARNESS/server/local-llm/ollama-client.js`
  - Da stub commenti → impl ~200 righe
  - API esposte:
    ```javascript
    export class OllamaClient {
      constructor({ baseURL = 'http://localhost:11434', timeout = 60000 }) { ... }

      async listModels() { /* GET /api/tags */ }

      async generate({ model, prompt, stream = true, signal }) {
        // POST /api/generate con stream=true
        // Yields chunk-by-chunk
      }

      async chat({ model, messages, tools = [], stream = true, signal }) {
        // POST /api/chat
      }

      async pullModel(modelName, onProgress) { /* POST /api/pull */ }
    }
    ```
  - Retry/timeout: 3 retry exponential backoff, abort se signal triggered
  - AbortSignal forwarding per cancel mid-task
  - Logging strutturato (`logger.info("ollama_request", ...)`)
  - Error handling: model not found, server down, timeout
  - Reference: piano §3.2 + Phase 2 task #4

- **Task 4.4 — Implementare `ios-local-llm.js` SSE endpoint** (3h)
  - File: `03_HARNESS/server/api/ios-local-llm.js`
  - Da 501 stub → impl ~150 righe
  - Endpoint: `POST /api/ios/local-llm/generate`
  - Request body: `{ prompt: string, model?: string, history?: [], signal_runId?: string }`
  - Response: SSE stream con events:
    - `event: chunk\ndata: {"text": "..."}\n\n`
    - `event: done\ndata: {"latencyMs": 1234}\n\n`
    - `event: error\ndata: {"message": "..."}\n\n`
  - Internamente chiama `OllamaClient.generate({ model, prompt, stream:true })` e re-emette chunks
  - Model selection: legge da `03_HARNESS/server/local-llm/config.json` (esiste già come `config.example.json`)
  - Auth: stesso pattern degli altri endpoint `ios-*` (verifica Bearer token harness)
  - Riferimento: `03_HARNESS/docs/api/ios-integration.md` per pattern auth

- **Task 4.5 — Aggiornare `local-llm/config.example.json`** (1h)
  - File: `03_HARNESS/server/local-llm/config.example.json`
  - Sostituire eventuale template con schema concreto:
    ```json
    {
      "defaultModel": "qwen3:14b",
      "tiers": {
        "lite":     { "model": "qwen3:4b",     "minRAM": 8,  "description": "Lite (4GB RAM) — qwen3 4B" },
        "standard": { "model": "qwen3:8b",     "minRAM": 16, "description": "Standard (16GB RAM) — qwen3 8B" },
        "default":  { "model": "qwen3:14b",    "minRAM": 16, "description": "Default (16GB+ RAM) — qwen3 14B" },
        "pro":      { "model": "qwen3.6:27b",  "minRAM": 32, "description": "Pro Quality (32GB+ RAM) — qwen3.6 27B" }
      },
      "timeoutMs": 60000,
      "ollamaURL": "http://localhost:11434"
    }
    ```
  - Documentare per ogni tier: model, RAM minimo, latency stimata, qualità (Spike B results)

- **Task 4.6 — Implementare `GigiHarnessClient.runLocalLLM()` Swift extension** (3h)
  - File: `02_GIGI_APP/GIGI/GigiHarnessClient.swift`
  - Aggiungere metodo:
    ```swift
    func runLocalLLM(prompt: String, history: [ChatMessage]) -> AsyncStream<LocalLLMEvent>
    enum LocalLLMEvent {
        case chunk(String)
        case done(latencyMs: Int)
        case error(String)
    }
    ```
  - Internamente: WebSocket OR HTTP SSE su `/api/ios/local-llm/generate`
  - Streaming chunk-by-chunk
  - Cancel support: passa `signal_runId` con `runId` univoco, expose `cancel(runId:)`
  - Riferimento: pattern esistente `GigiHarnessClient.runClaudeCode` (se già esiste) o `streamEvents`

- **Task 4.7 — Aggiornare `GigiRequestRouter.dispatchDelegateLocal()`** (2h)
  - File: `02_GIGI_APP/GIGI/GigiRequestRouter.swift`
  - Logica:
    ```swift
    private func dispatchDelegateLocal(decision: FoundationRouterDecision) async -> RouteResult {
        let prompt = decision.delegatePrompt.isEmpty ? originalText : decision.delegatePrompt
        var fullResponse = ""
        for await event in harnessClient.runLocalLLM(prompt: prompt, history: history) {
            switch event {
            case .chunk(let text):
                fullResponse += text
                // Streaming TTS chunk (vedi GigiSpeechSynthesizer)
            case .done(let latency):
                logger.info("ollama_done: latency=\(latency)ms")
            case .error(let msg):
                // Fallback a Path 4 con warning
                return await dispatchDelegateCloud(decision: decision)
            }
        }
        return .spoken(fullResponse)
    }
    ```
  - Capability check: se `decision.requiredCapabilities` contains `["browser", "code", "vision"]` → forzare fallback a `delegate_cloud` anche se `path == "delegate_local"` (per piano §3.4 logic)
  - Timeout-based fallback: se Ollama non risponde in 20s, fallback a Path 4

- **Task 4.8 — Settings → Brain section: tier selector** (3h)
  - File: `02_GIGI_APP/GIGI/SettingsView.swift`
  - In sezione "Brain" aggiungere:
    - Picker "Ollama Tier" con 4 valori (lite/standard/default/pro) letto da harness config
    - Status: "Connected to Ollama" green / "Ollama unavailable" red (ping `/api/tags`)
    - Auto-detect RAM hint: harness expone `GET /api/ios/local-llm/hardware-info` con `{ totalRAM: 32, recommendedTier: "default" }`
  - Salva user preference in UserDefaults `gigi.ollama.tier`, propaga a request body `model` field

- **Task 4.9 — Brain Path Override `ollama` non è più stub** (1h)
  - File: `02_GIGI_APP/GIGI/GigiAgentEngine.swift`
  - `processOllamaOverride()` helper esistente: cambiare dal returning "Path 3 Ollama is not configured yet" a vera invocazione `GigiHarnessClient.runLocalLLM`
  - Stesso flow di `dispatchDelegateLocal` ma bypassando router

- **Task 4.10 — Test E2E reasoning + summarize + offline** (3h)
  - Eseguire 8 query reasoning su iPhone fisico, registrare in `docs/research/gate-4-ollama-e2e.md`
  - Test offline: disconnettere harness (kill processo), verifica fallback graceful

---

## 4. Acceptance Criteria (AC)

- **AC1** — Spike B documento `docs/research/spike-b-results.md` completato con tabelle accuracy/latency/loop rate per 4 modelli Qwen
- **AC2** — Verdetto Spike B: Qwen 3 14B BFCL ≥75%, loop rate <5% — OR mitigation documentata
- **AC3** — `03_HARNESS/server/local-llm/ollama-client.js` ha classe `OllamaClient` con metodi `listModels`, `generate`, `chat`, `pullModel`
- **AC4** — `03_HARNESS/server/api/ios-local-llm.js` espone `POST /api/ios/local-llm/generate` che ritorna SSE stream (NON più 501)
- **AC5** — `03_HARNESS/server/local-llm/config.example.json` ha schema tiers con 4 tier completi
- **AC6** — `GigiHarnessClient.runLocalLLM(prompt:history:)` ritorna `AsyncStream<LocalLLMEvent>`
- **AC7** — `GigiRequestRouter.dispatchDelegateLocal()` invoca `runLocalLLM` invece di stub
- **AC8** — Capability check: query con `requiredCapabilities = ["browser"]` viene fallbacked a `delegate_cloud` anche se `path == "delegate_local"`
- **AC9** — Settings → Brain section ha picker Ollama Tier con 4 opzioni
- **AC10** — Status indicator "Ollama Connected" / "Ollama Unavailable" basato su ping reale
- **AC11** — Brain Path Override `ollama`: pronuncia query QUALSIASI → response vero da Ollama (NON più stub message)
- **AC12** — Query "Explain Bayes theorem in three sentences" classificata `delegate_local` → response streaming via Ollama → AVSpeechSynthesizer pronuncia chunk-by-chunk, latency totale 7-15s
- **AC13** — Test offline: kill harness → query "explain X" → router rileva harness down → fallback a Path 4 (o speak error graceful)
- **AC14** — Cancel mid-task: pronunciare query, tap cancel button → Ollama HTTP request abortita (verifica con `ollama logs` che la generation si ferma)
- **AC15** — Build verify: harness `npm test` passa (aggiungere test min per ollama-client), iOS `xcodebuild` BUILD SUCCEEDED

---

## 5. Test E2E sul telefono (verificabili dall'utente)

- **E2E-1** — Brain Path Override `auto`, pronunciare "Explain Bayes theorem in three sentences"
  - Atteso: router classifica `delegate_local complexity=~30`, Ollama Qwen 3 14B genera response in 7-12s, AVSpeechSynthesizer pronuncia 3 frasi coerenti
  - Verifica log: `router_decision: path=delegate_local`, `ollama_request: model=qwen3:14b`, `ollama_done: latencyMs=...`

- **E2E-2** — Brain Path Override `auto`, pronunciare "Summarize this: <paste 200-word email text>"
  - Atteso: router `delegate_local complexity=~35`, summary 3-4 righe
  - Verifica: il body summary deve essere conciso

- **E2E-3** — Brain Path Override `auto`, pronunciare "Rephrase 'I'm running late' more professionally"
  - Atteso: response stile "I apologize for the delay; I'll be there shortly" o equivalente
  - Path: `delegate_local`

- **E2E-4** — Brain Path Override `auto`, pronunciare "What's the capital of France"
  - Atteso: `delegate_local` con response "Paris" o frase completa
  - Verifica: NON va a Path 4 (cost-aware)

- **E2E-5** — Brain Path Override `auto`, disconnetti harness (kill processo `start-harness.sh`), pronuncia "explain X"
  - Atteso: WebSocket disconnesso, router rileva harness offline → speak "Local AI unavailable. Try again when harness is online." graceful fallback
  - NESSUN crash app

- **E2E-6** — Brain Path Override `ollama`, pronunciare qualsiasi cosa
  - Atteso: dispatch diretto a Ollama bypassando router, response vero (NON più stub message)

- **E2E-7** — Settings → Brain → cambia tier da "default" a "lite"
  - Atteso: ping Ollama indica modello cambiato a `qwen3:4b`
  - Re-eseguire E2E-1: response qualitativamente più povera ma più veloce (3-5s)

- **E2E-8** — Test cancel: pronunciare query lunga "Write a long essay on quantum physics", durante streaming tap cancel button (long-press mic o button apposito)
  - Atteso: stream interrotto immediatamente, `ollama logs` mostra "generation cancelled"

- **E2E-9** — Pronunciare query browser-requiring "Search Wikipedia for Tesla"
  - Atteso: router decide `delegate_cloud` perché `requiredCapabilities=[browser]` — Ollama NON chiamato (cost-aware: capabilities mismatch)

- **E2E-10** — Pronunciare 5 query reasoning consecutive
  - Atteso: tutte vanno a Ollama (cost-aware), nessuna brucia subscription Claude Code
  - Verifica log: `path=delegate_local` × 5

---

## 6. Test post-creazione (verifica autonoma)

### 6.1 Verifica via grep

```bash
ROOT_IOS="C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/02_GIGI_APP/GIGI"
ROOT_HARNESS="C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/03_HARNESS"

# 1. OllamaClient class esiste con metodi chiave
grep -E "class OllamaClient|listModels|generate|chat|pullModel" "$ROOT_HARNESS/server/local-llm/ollama-client.js"
# Output atteso: 5+ match

# 2. ios-local-llm.js NON ritorna più 501
grep -c "501\|not implemented\|NotImplemented" "$ROOT_HARNESS/server/api/ios-local-llm.js"
# Output atteso: 0 (a meno di comment)

# 3. config.example.json ha 4 tier
grep -c "\"lite\"\|\"standard\"\|\"default\"\|\"pro\"" "$ROOT_HARNESS/server/local-llm/config.example.json"
# Output atteso: 4

# 4. runLocalLLM esposto in Swift
grep "func runLocalLLM" "$ROOT_IOS/GigiHarnessClient.swift"
# Output atteso: 1 match

# 5. dispatchDelegateLocal non è più stub
grep -A5 "func dispatchDelegateLocal" "$ROOT_IOS/GigiRequestRouter.swift" | grep -c "runLocalLLM\|harnessClient"
# Output atteso: 1+ match (chiama runLocalLLM)

# 6. Spike B doc ha verdetto
grep -E "Verdict|PASS|FAIL|Qwen 3 14B" "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/docs/research/spike-b-results.md"
# Output atteso: verdetto chiaro
```

### 6.2 Verifica via ollama

```bash
ssh user297422@FF125.macincloud.com "ollama list | head -10"
# Output atteso: qwen3:4b, qwen3:8b, qwen3:14b, qwen3.6:27b
```

### 6.3 Verifica via curl harness

```bash
# (con harness running)
curl -X POST http://localhost:7777/api/ios/local-llm/generate \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Say hello", "model":"qwen3:14b"}'
# Output atteso: SSE stream con event: chunk + event: done
```

### 6.4 Verifica via runtime

Re-eseguire E2E-1 e verificare latency in range 7-15s + qualità response.

---

## 7. Rollback plan

```bash
cd "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework"
git revert <SHA-gate-4>
```

Alternative:
- Feature flag `gigi.feature.path3_ollama: bool` in `GigiRequestRouter`. Quando false, `dispatchDelegateLocal` cade su `dispatchDelegateCloud` (Path 4).
- Harness lato: env var `OLLAMA_ENABLED=false` disabilita endpoint `/api/ios/local-llm/*`

Side effects:
- Ollama modelli scaricati: 30GB. Possono restare se feature flag off (no harm)
- UserDefaults `gigi.ollama.tier`: può rimanere

---

## 8. Files modificati / creati

| Path | Operazione | Righe stimate |
|---|---|---|
| `03_HARNESS/server/local-llm/ollama-client.js` | MODIFY (stub → impl) | +200 (-15) |
| `03_HARNESS/server/api/ios-local-llm.js` | MODIFY (501 → SSE) | +150 (-20) |
| `03_HARNESS/server/local-llm/config.example.json` | MODIFY (tiers schema) | +35 (-5) |
| `02_GIGI_APP/GIGI/GigiHarnessClient.swift` | MODIFY (runLocalLLM) | +120 |
| `02_GIGI_APP/GIGI/GigiRequestRouter.swift` | MODIFY (dispatchDelegateLocal) | +60 |
| `02_GIGI_APP/GIGI/GigiAgentEngine.swift` | MODIFY (processOllamaOverride) | +30 |
| `02_GIGI_APP/GIGI/SettingsView.swift` | MODIFY (tier selector) | +120 |
| `docs/research/spike-b-test-set.md` | CREATE | ~100 |
| `docs/research/spike-b-results.md` | CREATE | ~300 |
| `docs/research/gate-4-ollama-e2e.md` | CREATE | ~80 |
| `docs/adr/0010-ollama-as-first-class-path.md` | MODIFY (Proposed → Accepted) | +60 |

---

## 9. ADR collegati

- **ADR-0010** (Ollama as first-class path) — questo GATE la chiude con dati Spike B
- ADR-0007 (Hybrid 5-path) — Path 3 finalmente live

---

## 10. Note operative

- **Spike B priority**: NON skippare. È il gate decision-making per il tier default.
- **Qwen 3.5 avoid**: confermare prima di partire che Issue ollama#14493 non è risolta. Se risolta, valutare se aggiungere Qwen 3.5 al lineup.
- **Conventional Commits suggeriti**:
  ```
  feat(harness): GATE 4.1 — Spike B test set 40 query
  test(harness): GATE 4.2 — Spike B results Qwen tier validation
  feat(harness): GATE 4.3 — ollama-client.js HTTP wrapper
  feat(harness): GATE 4.4 — ios-local-llm.js SSE endpoint
  chore(harness): GATE 4.5 — local-llm/config.example.json tiers schema
  feat(ios): GATE 4.6 — GigiHarnessClient.runLocalLLM Swift extension
  feat(ios): GATE 4.7 — GigiRequestRouter.dispatchDelegateLocal Ollama wired
  feat(ios): GATE 4.8 — Settings Brain section Ollama tier selector
  feat(ios): GATE 4.9 — BrainPathOverride ollama is no longer a stub
  test(e2e): GATE 4.10 — 10-query Ollama integration test results
  ```
- **Privacy**: Path 3 è 100% on-harness (LAN). Documentare nel commit body + ADR-0010 update.
- **Cost-aware**: assicurarsi che `dispatchDelegateLocal` rispetti `complexityEstimate ≤40 + non-browser` rule. Se decision.complexity > 40 ma path è delegate_local, può capitare? Sì se Apple FM router sbaglia: rispondere con fallback Path 4 senza warning user.

### Cosa fare se Spike B FAIL (Qwen 3 14B sotto threshold)

1. Demote default tier a qwen3:8b
2. Aggiungere disclaimer in Settings → Brain "Default model may give shorter answers"
3. Documentare in ADR-0010 + spike-b-results.md verdict section

### Cosa fare se RAM detection fallisce (Mac M3 con 8GB)

- Setup wizard (GATE 7) propone tier "lite" qwen3:4b
- Avviso "Limited mode: Path 3 quality may be reduced"
