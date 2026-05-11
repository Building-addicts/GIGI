# GATE 5 — Path 4: Claude Code CLI subprocess + MCP harness-browser + Spike C

> **Status**: Pending (richiede GATE 4 chiuso)
> **Effort stimato**: 5-7 giorni lavorativi (di cui 0.5g Spike C)
> **Bloccanti pre-gate**: GATE 4 chiuso (Path 3 Ollama live); Claude Code CLI installato sul harness (`claude --version` ritorna >= 1.x); subscription Claude Code (Pro $20 / Max 5x $100 / Max 20x $200) attiva; MCP `harness-browser` already wired in `claude-runner.js` (GATE 0 prep)
> **Sblocca**: GATE 6 (killer demo Tesla→nota), GATE 7 (modes UI), GATE 8 (hardening)
> **Funzione consegnata (1 frase)**: quando il router decide `path: "delegate_cloud"`, GIGI spawn-a un subprocess Claude Code via `claude-runner.js` con MCP `harness-browser` attivo, riceve eventi `claude_event` streaming (thoughts, tool_use, text_response) via WebSocket, mostra UI thought bubbles + screenshot, gestisce confirm gating event-based per azioni distruttive, deprecando completamente `ios-computer-use.js` Anthropic SDK loop + rimuovendo dep `@anthropic-ai/sdk` da package.json.

---

## 1. Obiettivo

Oggi `ios-computer-use.js` usa Anthropic SDK loop con `computer_20241022` tool, fatturando API a pagamento ($0.20-2/turn). Per essere OSS-friendly + zero API metering, vogliamo:
1. Sostituire Anthropic SDK con `claude-runner.js` subprocess (subscription flat)
2. Esporre MCP `harness-browser` ai subprocess Claude Code (browser automation tramite Playwright)
3. iOS-side: spawn Claude Code via `GigiHarnessClient.runClaudeCode`, mostrare thought stream nell'UI ChatView
4. Confirm gating: WS event `confirm_required` prima di azioni distruttive, sheet iOS con screenshot preview
5. Deprecate `ios-computer-use.js` → `examples/.legacy/`
6. Rimuovere dep `@anthropic-ai/sdk` da `package.json` (verificare zero import dopo deprecate)
7. Setup wizard hint: `unset ANTHROPIC_API_KEY` per evitare silent API billing (Issue claude-code#45572)

Output: query "Search Wikipedia for Nikola Tesla" attiva Claude Code subprocess con MCP browser, naviga Wikipedia, ritorna summary, latency 30-60s, zero API metering.

---

## 2. Pre-condizioni

- [ ] GATE 0-4 chiusi
- [ ] Claude Code CLI installato sul harness host (`claude --version` ritorna >= 1.x)
- [ ] Subscription Claude Code attiva (Pro $20 minimum, Max 5x raccomandato)
- [ ] `claude-runner.js` accepts `options.mcpServers: [...]` (verificato da GATE 0 prep, vedi commit `bdc393a`)
- [ ] MCP `harness-browser` running (verifica `03_HARNESS/server/mcp/harness-browser/`)
- [ ] iPhone fisico + harness running + tunneling Cloudflare attivo

---

## 3. Task implementativi

- **Task 5.1 — Spike C: Claude Code subscription burn rate** (0.5g)
  - File: `docs/research/spike-c-results.md` (nuovo)
  - 100 query simulazione across 1 day:
    - 70 single-tool / fast actions (NLU bypass expected ma verifica)
    - 20 Path 4 reasoning ("write email", "summarize document")
    - 10 Path 4 browser ("search Wikipedia + create note")
  - Track 5h rolling window message count
  - Metriche: messages consumed / 5h, time to plan exhaustion, cap reset behavior
  - Pass criteria: Pro plan <30 messages/5h demo-like; Max 5x comfortable buffer
  - Verdetto: README setup recommended tier
  - Riferimento: `phase-1-1-empirical-validation.md` Spike C

- **Task 5.2 — Verify `claude-runner.js` MCP wiring** (1h)
  - File: `03_HARNESS/server/claude-runner.js`
  - Verificare che `options.mcpServers` array sia processato correttamente
  - Test manuale: `node -e "import {claudeRun} from './claude-runner.js'; await claudeRun({prompt: 'list browser tools', mcpServers: ['harness-browser']})"` → output deve listare tool MCP
  - Se NO: fix wiring
  - Riferimento: piano §3.12 "claude-runner.js accetta options.mcpServers"

- **Task 5.3 — Implementare `GigiHarnessClient.runClaudeCode()`** (4h)
  - File: `02_GIGI_APP/GIGI/GigiHarnessClient.swift`
  - Metodo nuovo:
    ```swift
    func runClaudeCode(prompt: String, mcpServers: [String]) -> AsyncStream<ClaudeEvent>
    enum ClaudeEvent {
        case thought(String)
        case toolUse(name: String, args: [String: Any], screenshot: Data?)
        case textResponse(String)
        case confirmRequired(actionDescription: String, screenshot: Data?, runId: String)
        case done(latencyMs: Int)
        case error(String)
    }
    ```
  - WebSocket connection a `/api/ios/agent/claude` con payload `{prompt, mcpServers}`
  - Re-emette eventi dal harness in stream typed
  - Cancel support: `cancel(runId:)` → POST `/api/ios/agent/cancel` con runId, harness SIGTERM su subprocess Claude Code
  - Riferimento: pattern esistente `streamEvents` se presente

- **Task 5.4 — Aggiungere endpoint `/api/ios/agent/claude` su harness** (3h)
  - File: `03_HARNESS/server/api/ios-claude-agent.js` (nuovo) OR `ios-agent.js` esistente extended
  - WebSocket endpoint che:
    1. Riceve `{prompt, mcpServers}` da iOS
    2. Genera `runId` univoco
    3. Chiama `claudeRun({prompt, mcpServers, onEvent: forwardToWS})`
    4. Forwarda ogni `claude_event` (thought, tool_use, text, confirm) verso WS iOS
    5. Su completamento: emit `done` event + cleanup subprocess
  - Cancel endpoint: `POST /api/ios/agent/cancel` con `{runId}` → SIGTERM subprocess
  - Auth: stesso pattern degli altri endpoint
  - Riferimento: `03_HARNESS/server/api/ios-computer-use.js` per pattern WS (anche se sarà deprecato)

- **Task 5.5 — Aggiornare `GigiRequestRouter.dispatchDelegateCloud()`** (3h)
  - File: `02_GIGI_APP/GIGI/GigiRequestRouter.swift`
  - Sostituire la chiamata corrente a Groq agentLoop con:
    ```swift
    private func dispatchDelegateCloud(decision: FoundationRouterDecision) async -> RouteResult {
        let prompt = decision.delegatePrompt.isEmpty ? originalText : decision.delegatePrompt
        let mcpServers: [String] = decision.requiredCapabilities.contains("browser")
            ? ["harness-browser"]
            : []

        var finalText = ""
        for await event in harnessClient.runClaudeCode(prompt: prompt, mcpServers: mcpServers) {
            switch event {
            case .thought(let t): publishThought(t)  // → ChatView thought bubble
            case .toolUse(let n, let args, let screenshot): publishToolUse(n, args, screenshot)
            case .textResponse(let t): finalText += t
            case .confirmRequired(let desc, let shot, let runId):
                let approved = await presentConfirmSheet(description: desc, screenshot: shot)
                await postConfirm(runId: runId, approved: approved)
            case .done(let latency): logger.info("claude_code_done: \(latency)ms")
            case .error(let msg): return .spoken("Error: \(msg)")
            }
        }
        return .spoken(finalText)
    }
    ```

- **Task 5.6 — Implementare `ConfirmComputerUseSheet.swift`** (4h)
  - File: `02_GIGI_APP/GIGI/UI/ConfirmComputerUseSheet.swift` (nuovo, ~200 righe)
  - SwiftUI sheet che mostra:
    - Screenshot preview (Image da `Data`)
    - AC click target highlight (rect overlay con `actionDescription`)
    - Descrizione azione es. "Click 'Submit' button on Wikipedia"
    - Button "Approve" (verde) e "Cancel" (rosso)
    - Onboarding-style copy: "GIGI wants to perform this action. Approve only if you trust it."
  - Async-friendly: `presentConfirmSheet(...) -> Bool` ritorna user choice
  - Riferimento: piano §4.4 "Confirm gating event-based"

- **Task 5.7 — POST `/api/ios/agent/confirm` endpoint** (1h)
  - File: `03_HARNESS/server/api/ios-claude-agent.js`
  - `POST /api/ios/agent/confirm` con `{runId, approved}` → harness inietta risposta nel subprocess Claude Code (via stdin OR MCP `AskUserQuestion` reply)
  - Se subprocess ha terminato già: 410 Gone

- **Task 5.8 — Deprecare `ios-computer-use.js`** (2h)
  - Move file: `03_HARNESS/server/api/ios-computer-use.js` → `03_HARNESS/server/examples/ios-computer-use-anthropic-sdk.js.legacy`
  - Aggiornare imports: chi importava `ios-computer-use` ora deve usare `ios-claude-agent`
  - Verifica con grep che nessun import attivo punti a `ios-computer-use`
  - Mantieni il file legacy con header commentato "DEPRECATED 2026-05-XX — use ios-claude-agent.js"

- **Task 5.9 — Rimuovere `@anthropic-ai/sdk` da `package.json`** (1h)
  - File: `03_HARNESS/package.json`
  - Verifica con grep che nessun `import '@anthropic-ai/sdk'` o `require('@anthropic-ai/sdk')` resta nel target compilato (`server/api/*`, `server/orchestrator/*`). Il file legacy può ancora importarlo ma non viene caricato.
  - `npm uninstall @anthropic-ai/sdk`
  - `npm install` per regenerate `package-lock.json`
  - Run `npm test` per verificare no break
  - Documentare in `package.json` `_phase3_done` field

- **Task 5.10 — Setup wizard hint `unset ANTHROPIC_API_KEY`** (1h)
  - File: `03_HARNESS/server/index.js` (entry point harness)
  - All'avvio: check `process.env.ANTHROPIC_API_KEY`. Se settata, log `WARNING: ANTHROPIC_API_KEY is set — Claude Code may bill API instead of using subscription (Issue claude-code#45572). Recommend: unset ANTHROPIC_API_KEY before starting harness.`
  - Aggiungere in `start-harness.sh` linea `unset ANTHROPIC_API_KEY` PRIMA di lanciare node
  - Riferimento: piano §7 Q12

- **Task 5.11 — Brain Path Override `claude` non è più stub** (1h)
  - File: `02_GIGI_APP/GIGI/GigiAgentEngine.swift`
  - `processForceClaude()` helper esistente: verifica che invochi `harnessClient.runClaudeCode` come `dispatchDelegateCloud`. Se attualmente fa altro (Anthropic SDK direct), aggiornare.

- **Task 5.12 — Test E2E 10 scenari** (4h)
  - Registrare in `docs/research/gate-5-claude-code-e2e.md`

---

## 4. Acceptance Criteria (AC)

- **AC1** — Spike C documentato in `spike-c-results.md` con verdetto burn rate
- **AC2** — `claude-runner.js` accetta + processa `options.mcpServers` array (verifica con node CLI test)
- **AC3** — `GigiHarnessClient.runClaudeCode(prompt:mcpServers:)` ritorna `AsyncStream<ClaudeEvent>` con 6 case enum
- **AC4** — Harness endpoint `/api/ios/agent/claude` (WebSocket) accetta payload + emette `claude_event` stream
- **AC5** — Harness endpoint `POST /api/ios/agent/cancel` con runId SIGTERM-a subprocess Claude Code (verifica con `ps -ef | grep claude` dopo cancel)
- **AC6** — Harness endpoint `POST /api/ios/agent/confirm` con `{runId, approved}` inietta risposta nel subprocess
- **AC7** — `GigiRequestRouter.dispatchDelegateCloud()` chiama `runClaudeCode` (NON più Groq agentLoop)
- **AC8** — `ConfirmComputerUseSheet.swift` esiste con SwiftUI view che mostra screenshot + Approve/Cancel button + descrizione
- **AC9** — `confirm_required` event chiude la sheet su Approve → POST confirm → subprocess prosegue
- **AC10** — `confirm_required` event chiude la sheet su Cancel → POST confirm `approved=false` → subprocess aborta
- **AC11** — `ios-computer-use.js` spostato in `03_HARNESS/server/examples/ios-computer-use-anthropic-sdk.js.legacy`
- **AC12** — `package.json` NON contiene più `"@anthropic-ai/sdk"` in `dependencies` (verifica grep)
- **AC13** — `start-harness.sh` esegue `unset ANTHROPIC_API_KEY` prima di `node server/index.js`
- **AC14** — Harness all'avvio logga warning se `ANTHROPIC_API_KEY` settata
- **AC15** — Build verify: `npm test` passa, `xcodebuild` BUILD SUCCEEDED
- **AC16** — Query "Search Wikipedia for Nikola Tesla" classificata `delegate_cloud, capabilities=[browser]` → router dispatch a Path 4 con `mcpServers=["harness-browser"]` → Claude Code naviga Wikipedia (verifica screenshot in ChatView), latency 20-60s, response con summary
- **AC17** — Brain Path Override `claude`: pronuncia query → dispatch diretto a Path 4 (NON più stub)

---

## 5. Test E2E sul telefono (verificabili dall'utente)

- **E2E-1** — Brain Path Override `auto`, "Search the web for the latest WWDC announcements"
  - Atteso: router `delegate_cloud capabilities=[browser, web_search]`, Claude Code subprocess spawn, MCP browser naviga, thought bubbles in ChatView (es. "Searching Google for WWDC 2026..."), response summary, latency 20-40s

- **E2E-2** — "Read the article at https://en.wikipedia.org/wiki/Nikola_Tesla and tell me his most important invention"
  - Atteso: Claude Code apre la URL, legge, response "The alternating current induction motor" o equivalente

- **E2E-3** — Multi-step: "Find me the cheapest flight from Bologna to Munich next weekend"
  - Atteso: Claude Code naviga Skyscanner / Google Flights, response con prezzo + link, latency 40-90s

- **E2E-4** — Cancel mid-task: durante E2E-3, dopo 10s tap cancel button
  - Atteso: subprocess Claude Code SIGTERM-ed, stream chiuso, speak "Cancelled"

- **E2E-5** — Confirm gating: "Buy a pair of shoes on Amazon"
  - Atteso: Claude Code arriva al checkout, emette `confirm_required` con screenshot, sheet iOS appare con "Click 'Place Order' button. Approve only if you want to purchase."
  - User tap Cancel: subprocess aborta, NO purchase

- **E2E-6** — Confirm gating Approve path (su task safe): "Vote for Apple in this poll: https://example.com/poll"
  - Atteso: Claude Code arriva alla vote button, confirm_required, user tap Approve → vote confermato

- **E2E-7** — Cookie banner auto-handling (GATE 8 vero scope ma test base): "Search Bing for news"
  - Atteso: Claude Code può dover gestire cookie banner; oggi senza GATE 8 può fallire ma latency degrade graceful

- **E2E-8** — Subscription exhaustion: simulare 5h continuous query (può durare days). Verifica messaggio chiaro su Pro plan exhausted.

- **E2E-9** — Code-needed: "Write a Python script that sorts a list of integers"
  - Atteso: `delegate_cloud capabilities=[code]`, mcpServers vuoto (NO browser), Claude Code response con code block

- **E2E-10** — Brain Path Override `claude`: "Generic complex task"
  - Atteso: dispatch diretto bypass router, response Claude Code

---

## 6. Test post-creazione (verifica autonoma)

### 6.1 Verifica via grep / Glob

```bash
ROOT_IOS="C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/02_GIGI_APP/GIGI"
ROOT_HARNESS="C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/03_HARNESS"

# 1. runClaudeCode esposto
grep "func runClaudeCode" "$ROOT_IOS/GigiHarnessClient.swift"
# Output atteso: 1 match

# 2. ClaudeEvent enum con 6 case
grep -c "case thought\|case toolUse\|case textResponse\|case confirmRequired\|case done\|case error" "$ROOT_IOS/GigiHarnessClient.swift"
# Output atteso: >=6

# 3. ConfirmComputerUseSheet esiste
ls "$ROOT_IOS/UI/ConfirmComputerUseSheet.swift"
# Output atteso: file esiste

# 4. ios-computer-use.js spostato in examples/legacy
ls "$ROOT_HARNESS/server/examples/ios-computer-use-anthropic-sdk.js.legacy"
# Output atteso: file esiste
ls "$ROOT_HARNESS/server/api/ios-computer-use.js" 2>&1 | grep -E "No such|cannot find"
# Output atteso: file NON esiste piu'

# 5. @anthropic-ai/sdk rimosso
grep "@anthropic-ai/sdk" "$ROOT_HARNESS/package.json"
# Output atteso: 0 match (a meno di _phase2_todos note)

# 6. claude-runner.js MCP wiring
grep "mcpServers" "$ROOT_HARNESS/server/claude-runner.js"
# Output atteso: 2+ match

# 7. unset ANTHROPIC_API_KEY in start-harness.sh
grep "unset ANTHROPIC_API_KEY" "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework/start-harness.sh"
# Output atteso: 1 match

# 8. dispatchDelegateCloud chiama runClaudeCode
grep -A5 "func dispatchDelegateCloud" "$ROOT_IOS/GigiRequestRouter.swift" | grep "runClaudeCode"
# Output atteso: 1 match
```

### 6.2 Verifica via runtime

Re-eseguire E2E-1 (search web). Verifica:
- Console iOS log `dispatch_delegate_cloud: mcpServers=harness-browser`
- Harness log `claude_runner_spawn: pid=...`
- Nessun log `anthropic_sdk` (deprecato)

### 6.3 Verifica via process inspection

Durante E2E-1, su Mac harness:
```bash
ps -ef | grep claude
# Output atteso: processo claude subprocess attivo durante streaming
```

Dopo cancel:
```bash
ps -ef | grep claude
# Output atteso: nessun processo claude (SIGTERM-ed)
```

---

## 7. Rollback plan

```bash
cd "C:/Users/arman/Desktop/PROGETTI VIBE CODING/GIGI FOLDER/GIGI-work/Armando-Rework"
git revert <SHA-gate-5>
```

Specifico per `ios-computer-use.js`:
```bash
git mv 03_HARNESS/server/examples/ios-computer-use-anthropic-sdk.js.legacy 03_HARNESS/server/api/ios-computer-use.js
npm install @anthropic-ai/sdk
```

Feature flag alternativo:
- `gigi.feature.path4_claude_code: bool` in `GigiRequestRouter`. Quando false, `dispatchDelegateCloud` cade su Groq legacy.

Side effects:
- `@anthropic-ai/sdk` rimosso da `node_modules`: rebuilding richiede `npm install`
- `ANTHROPIC_API_KEY` env: `unset` durante start-harness.sh non lascia tracce permanenti

---

## 8. Files modificati / creati

| Path | Operazione | Righe stimate |
|---|---|---|
| `02_GIGI_APP/GIGI/GigiHarnessClient.swift` | MODIFY (runClaudeCode + ClaudeEvent) | +180 |
| `02_GIGI_APP/GIGI/GigiRequestRouter.swift` | MODIFY (dispatchDelegateCloud) | +60 |
| `02_GIGI_APP/GIGI/GigiAgentEngine.swift` | MODIFY (processForceClaude) | +20 |
| `02_GIGI_APP/GIGI/UI/ConfirmComputerUseSheet.swift` | CREATE | ~200 |
| `02_GIGI_APP/GIGI/GigiComputerUse.swift` | MODIFY (semplificare a wrapper) | -150 +50 |
| `03_HARNESS/server/claude-runner.js` | MODIFY (verify MCP wiring) | +20 |
| `03_HARNESS/server/api/ios-claude-agent.js` | CREATE | ~250 |
| `03_HARNESS/server/api/ios-computer-use.js` | MOVE → examples/ + DEPRECATED header | (move) |
| `03_HARNESS/server/examples/ios-computer-use-anthropic-sdk.js.legacy` | CREATE (from move) | (existing) |
| `03_HARNESS/package.json` | MODIFY (remove dep) | -1 |
| `start-harness.sh` | MODIFY (unset env) | +2 |
| `03_HARNESS/server/index.js` | MODIFY (warn check) | +10 |
| `docs/research/spike-c-results.md` | CREATE | ~100 |
| `docs/research/gate-5-claude-code-e2e.md` | CREATE | ~80 |
| `docs/adr/0007-hybrid-5-path-router.md` | MODIFY (Path 4 details) | +30 |

---

## 9. ADR collegati

- **ADR-0002** (Claude dual-path CLI vs SDK) — questo GATE chiude in favore della CLI subprocess (subscription); SDK deprecato
- ADR-0007 (Hybrid 5-path) — Path 4 finalmente live
- ADR-0011 (iOS 26.4 regression) — Path 4 è il fallback principale se Path 2 disabilitato; importante che funzioni a piena potenza

---

## 10. Note operative

- **Subscription requirement**: prima di partire, confermare che Armando ha subscription Claude Code attiva. `claude --version` deve funzionare.
- **MCP harness-browser**: verificare che Playwright Chromium sia installato (`npx playwright install chromium`). Se no, harness-browser MCP fallisce.
- **Conventional Commits suggeriti**:
  ```
  test(harness): GATE 5.1 — Spike C subscription burn rate results
  chore(harness): GATE 5.2 — verify claude-runner.js mcpServers wiring
  feat(ios): GATE 5.3 — GigiHarnessClient.runClaudeCode + ClaudeEvent
  feat(harness): GATE 5.4 — /api/ios/agent/claude WS endpoint + cancel + confirm
  feat(ios): GATE 5.5 — GigiRequestRouter.dispatchDelegateCloud via Claude Code
  feat(ios): GATE 5.6 — ConfirmComputerUseSheet SwiftUI
  refactor(harness): GATE 5.8 — deprecate ios-computer-use.js → examples/legacy
  chore(harness): GATE 5.9 — remove @anthropic-ai/sdk dependency
  chore(harness): GATE 5.10 — setup wizard unset ANTHROPIC_API_KEY guard
  feat(ios): GATE 5.11 — BrainPathOverride claude wired to Path 4
  test(e2e): GATE 5.12 — 10-query Claude Code integration test
  ```

### Cosa fare se subprocess Claude Code zombifica

Problema noto: subprocess Claude Code può non terminare dopo task completion se MCP browser non rilascia resources.

Mitigazione:
- Timeout hard 120s su subprocess
- SIGTERM esplicito dopo `done` event
- Cleanup browser pool MCP-side

### Cosa fare se `harness-browser` MCP lifecycle è instabile

Piano §9 risk row "Custom harness-browser MCP lifecycle non validato": se zombies persistenti, considerare switch a `@playwright/mcp` ufficiale Microsoft (GATE 8 task opzionale).
