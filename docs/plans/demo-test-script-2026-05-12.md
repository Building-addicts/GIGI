# Demo test script — settimana MVP

**Date**: 2026-05-12
**Author**: Claude + Armando
**Audience**: Armando (interactive session) — esegui in ordine appena Ollama dice "Bonjour"
**Estimated time**: 25 min totali

Pre-condizioni:
- ✅ IPA da commit `6a74842` installata e parser SSE confermato funzionante
- ✅ Harness up (panel su http://localhost:7777)
- ✅ Tunnel Cloudflare attivo (`installing-blocked-bomb-skin.trycloudflare.com`)
- ✅ Ollama daemon su localhost:11434 con `qwen3:14b` pulled
- ✅ iPhone paired e Reachable nel panel

---

## Phase C — Router 5-path verifica (10 min)

L'obiettivo è confermare che il router Apple FM (`GigiFoundationSession.routeRequest`)
prende decisioni corrette su 5 categorie di prompt diverse. Brain Path Override
= **Auto** per tutta la Phase C.

### C1 — `native_tool` (Apple FM tool calling)
Prompt: **"Set a timer for 3 minutes"**

Atteso:
- Last router decision JSON: `path=native_tool`, `primaryAction=set_timer`,
  `slots.duration=180`
- Banner: "Timer set for 3 minutes"
- TTS: "Timer set for 3 minutes"
- (no harness call; tutto on-device via FM Tools)

### C2 — `delegate_local` (Ollama via harness)
Prompt: **"Who was Nikola Tesla in one sentence"**

Atteso:
- JSON: `path=delegate_local`, `complexity≥15`, `reason` cita "reasoning task"
- Captured logs contengono `parser=manual-buffer-v1` e `chunks emitted>0`
- TTS risponde una frase coerente su Tesla (inventore, energia AC, etc.)
- Latency atteso 3-8s

### C3 — `delegate_cloud` (Claude Code subprocess)
Prompt: **"What's the weather in Milan right now and should I bring an umbrella"**

Atteso:
- JSON: `path=delegate_cloud`, `reason` cita "real-time" o "external data"
- Captured logs cercano `runClaudeCode` connection
- TTS: risposta basata su web (richiede tunnel + Claude Code CLI funzionante)
- **Nota**: se Claude Code non installato sull'host, fallback graceful a
  `delegate_local` Ollama con disclaimer "I cannot fetch real-time data"

### C4 — `ask_clarification`
Prompt: **"Send him a message"**

Atteso:
- JSON: `path=ask_clarification`, `directSpeech` non vuoto
- TTS chiede: "Who would you like to message?"
- Nessun trigger WhatsApp/SMS finché user non specifica

### C5 — `reject`
Prompt: **"Buy me a Tesla model S right now"**

Atteso:
- JSON: `path=reject`, `directSpeech` spiega perché
- TTS: "I can't make purchases on your behalf. Would you like me to open the Tesla website instead?"

**Verifica fine Phase C**: tutti e 5 i JSON `Last router decision` corretti nel viewer Settings → Debug.

---

## Phase D — Mode switch + Brain Path Override (5 min)

### D1 — Modes UI tab
Settings → Modes → tap **Path 2 Apple FM**:
- Atteso: tier picker scompare, "Use Apple FM Tool calling" toggle visibile
- Prompt voce: **"Set alarm for 7 AM tomorrow"**
- Atteso: JSON `path=native_tool`, alarm creato senza Ollama

### D2 — Brain Path Override = Apple FM
Settings → Brain Path Override → **Apple FM**:
- Prompt: **"Translate good morning to French"**
- Atteso: TTS "Bonjour" (FM rispondendo direttamente, no Ollama)

### D3 — Brain Path Override = Auto (default)
Settings → **Auto**:
- Prompt complesso: **"Compare the iPhone 15 Pro to the Samsung Galaxy S24 in 2 sentences"**
- Atteso: router sceglie `delegate_local` (complexity alta) → Ollama → 2 frasi coerenti

---

## Phase E — Killer demo Tesla → nota (10 min)

L'obiettivo è dimostrare end-to-end: voice → router → harness → Claude Code →
MCP harness-browser → estrazione info → on-device action (nota in Apple Notes).

### E1 — Prep
- Brain Path Override = **Auto**
- Apri Apple Notes a folder vuota

### E2 — Voice command
Pronuncia: **"Look up the latest Tesla Model 3 price on tesla.com and save it as a note titled Tesla Watch"**

Atteso flusso:
1. Router → `delegate_cloud` (Claude Code) o `delegate_local` con fallback
2. Pill "Thinking · Looking up Tesla"
3. Claude Code spawn + MCP harness-browser
4. Browser apre tesla.com, scrapes price (~3-15s)
5. TTS: "Found Tesla Model 3 at €40,990. Saving note Tesla Watch."
6. Apple Notes apre con titolo "Tesla Watch" + body "Tesla Model 3 €40,990 — captured YYYY-MM-DD HH:MM"

**Fallback se Claude Code non disponibile**:
- TTS: "I couldn't reach the web right now. Note saved with placeholder."
- Notes contiene comunque "Tesla Watch" + "(price lookup unavailable)"

### E3 — Verifica completa
- Apple Notes mostra la nota
- Captured logs mostrano sequenza completa: router → claude → tool_use harness-browser → confirm → done
- Latency totale ≤ 30s (acceptable per demo)

---

## Decisione automatica fine test

| Risultato | Azione |
|---|---|
| Tutti C1-C5 + D1-D3 + E2 ✅ | Demo ready. Commit "test(e2e): full 5-path + killer demo verified · 2026-05-12". Procedi con final polish docs. |
| C2 fallisce (Ollama) | Re-debug parser SSE. NON dovrebbe succedere dopo `6a74842`. |
| C3 fallisce (Claude Code) | Soft-skip. Marca E2 come "best effort fallback Ollama". |
| C4/C5 falliscono | Bug nel router prompt template. Apri sub-issue P1, label `router-prompt-tuning`. |
| D1-D3 falliscono | Bug nel binding Brain Path Override. Verifica `GigiAgentEngine.process` switch case. |
| E2 fallisce (Claude Code OR browser) | Demo backup: solo Phase C+D (still impressionante). |

---

## Files coinvolti

| File | Ruolo nel test |
|---|---|
| `02_GIGI_APP/GIGI/GigiFoundationSession.swift` | Router Apple FM (decisione path) |
| `02_GIGI_APP/GIGI/GigiAgentEngine.swift` | Dispatcher path → handler |
| `02_GIGI_APP/GIGI/GigiHarnessClient+Streams.swift` | SSE consumer (Path 3+4) |
| `02_GIGI_APP/GIGI/SettingsView.swift` | Brain Path Override + Modes UI |
| `02_GIGI_APP/GIGI/LastRouterDecisionView.swift` | Visualizza JSON router live |
| `03_HARNESS/server/api/ios-local-llm.js` | Path 3 endpoint Ollama |
| `03_HARNESS/server/api/ios-claude-agent.js` | Path 4 endpoint Claude Code |
| `03_HARNESS/server/local-llm/ollama-client.js` | Ollama HTTP client + system prompt |
