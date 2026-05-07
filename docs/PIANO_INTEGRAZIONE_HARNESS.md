# Piano integrazione Harness → GIGI

> **Obiettivo**: estrarre i pattern architetturali di `03_HARNESS/` (nati per Telegram)
> e trapiantarli dentro GIGI come backend server-side dell'app iOS. Telegram uscirà
> dal flusso principale — utente GIGI = app iOS.

**Data**: 2026-04-23
**Scope**: backend Node che serve l'app iOS (memoria, computer-use, watchers proattivi,
browser pool, session management cross-device, APNS).

---

## 1. Analisi struttura harness — inventario pattern riutilizzabili

### 1.1 File Node core

| File | LOC | Ruolo oggi | Valore per GIGI |
|---|---|---|---|
| `telegram-bridge/bridge.js` | 2270 | Loop Telegram + spawn CLI Claude + session mgmt | **Estraibile** (drop Telegram I/O, tieni session/claude/queue) |
| `telegram-bridge/panel.js` | 328 | HTTP server :7777 + process mgmt Chrome | **Tieni** come admin panel |
| `telegram-bridge/panel-routes.js` | 295 | Route handlers hot-reloadable | **Estendi** con route iOS |
| `telegram-bridge/bridge-rpc.js` | 114 | RPC panel→bridge | **Tieni** |
| `telegram-bridge/watchers.js` | 441 | Worker autonomi periodici | **Tieni** (GIGI proattivo) |
| `telegram-bridge/transcribe.js` | 94 | Whisper voice note | **Drop** (iOS ha GigiSpeechService) |
| `browser-mcp/server.js` | 451 | MCP server + pool Chrome + leases | **Tieni intatto** |
| `browser-mcp/server-playwright.js` | 460 | Variante Playwright | **Tieni** (Playwright > Puppeteer per computer-use) |

### 1.2 Pattern architetturali da copiare

| Pattern | Implementazione harness | Utile a GIGI per |
|---|---|---|
| **Lock file single-instance** | `bridge.js:19-33` via `logs/bridge.lock` | Server GIGI non parte doppio |
| **State JSON persistente** | `state.json`, `sessions.json`, `interrupted.json` | Stato cross-restart |
| **Session mgmt Claude resume** | `bridge.js:528-666` (timeout 60min, --resume) | Context continuo tra richieste iOS |
| **Parallel task (max 3)** | `bridge.js:666-744` | Multiple richieste iOS concorrenti |
| **Queue + depth + cancel** | `bridge.js:744-814` (`enqueue`, `incDepth`, `handleCancel`) | iOS annulla una richiesta lunga |
| **Offline queue** | `bridge.js:861-896` (`drainOfflineQueue`) | iOS offline → task si accumulano |
| **Rate limit detection + recovery** | `bridge.js:341-372` (`isRateLimit`, `notifyRateLimit`, `interrupted.json`) | Resume dopo errore Claude |
| **Transcript mirror** | `bridge.js:221-252` (`mirrorTranscript`) | Backup storia chat portabile |
| **Memory snapshot (/memo)** | `bridge.js:283-340` | Auto-summarize conversazione a 75% contesto |
| **Watcher budget + auto-disable** | `watchers.js` (respons_count + max_responses) | Proactive GIGI non spamma |
| **Browser pool con file-lock lease** | `browser-mcp/server.js:42-120` | Evita due task su stessa istanza |
| **Panel hot-reload routes** | `panel.js` (cache-busted import) | Sviluppo senza restart |
| **Friendly tool names per log** | `bridge.js:395-440` (`TOOL_FRIENDLY`) | Admin debug |
| **Streaming JSONL from Claude** | `bridge.js:452-527` (`spawnClaude` con `--stream-json`) | Interim thoughts iOS |

### 1.3 Pattern da NON copiare (Telegram-specific)

- `tg()` chiamate API Telegram, `sendMessage/editMessage/deleteMessage` → sostituisci con HTTP response + WebSocket push + APNS
- `BUILTIN_COMMANDS` e `setMyCommands` → sostituisci con endpoint `/api/commands`
- `handleCallbackQuery`, wizard inline keyboard watchers → sostituisci con endpoint REST che iOS chiama da dashboard dev
- `mdToHtml` → iOS rende Markdown nativamente (swift-markdown o attributedString)
- `allowed_chat_ids` auth → sostituisci con Bearer token (Keychain iOS)
- `long-polling getUpdates` → iOS initia chiamata, no polling

---

## 2. Architettura target GIGI post-integrazione

### 2.1 Layout file `03_HARNESS/`

```
03_HARNESS/
├── server/                          ← ex telegram-bridge, rinominato + ripulito
│   ├── server.js                    ← entry point (era bridge.js)
│   ├── session-manager.js           ← estratto da bridge.js:528-666
│   ├── claude-runner.js             ← estratto spawnClaude + runClaude
│   ├── queue.js                     ← estratto enqueue/depth/cancel
│   ├── rate-limit.js                ← estratto isRateLimit/interrupted
│   ├── memory-snapshot.js           ← estratto /memo
│   ├── transcript-mirror.js         ← estratto mirrorTranscript
│   ├── panel.js                     ← invariato (admin dev)
│   ├── panel-routes.js              ← ESTESO con /api/ios/*
│   ├── bridge-rpc.js                ← invariato
│   ├── watchers.js                  ← invariato (proactive worker)
│   ├── watchers.json                ← watchers default GIGI
│   └── api/
│       ├── ios-auth.js              ← middleware Bearer token
│       ├── ios-memory.js            ← POST /api/ios/memory/*
│       ├── ios-agent.js             ← POST /api/ios/agent/run (core)
│       ├── ios-computer-use.js      ← POST /api/ios/computer-use/*
│       ├── ios-push-register.js     ← POST /api/ios/push/register
│       └── ios-stream.js            ← WebSocket /ws/ios/stream
├── browser-pool/                    ← ex browser-mcp, rinominato
│   ├── server.js                    ← invariato (MCP stdio)
│   ├── server-playwright.js         ← invariato
│   └── driver.js                    ← NUOVO: API diretta per ios-computer-use.js
├── memory/                          ← IMPLEMENTA memory-upgrade v4 minimo
│   ├── store.js                     ← LanceDB wrapper
│   ├── embed.js                     ← BGE-M3 via ONNX runtime
│   ├── memory-tool.js               ← Anthropic Memory Tool wrapper
│   ├── graph.js                     ← SurrealDB (o stub JSON iniziale)
│   └── retrieval.js                 ← hybrid (vector + keyword)
├── apns/                            ← Apple Push Notification
│   ├── send.js                      ← @parse/node-apn wrapper
│   └── tokens.json                  ← device token per userId
├── clients/
│   └── telegram/                    ← ex-bridge Telegram, OPZIONALE
│       └── telegram-client.js       ← sottile shim sopra server/ core (se tieni Telegram)
├── docs/
│   ├── memory/context.md            ← invariato
│   ├── memory/memory.md             ← generato
│   └── api/
│       └── ios-integration.md       ← spec endpoint completo
└── CLAUDE.md                        ← aggiornato con nuovo layout
```

### 2.2 Flussi dati

#### Flusso: iOS manda comando vocale → GIGI risponde

```
iPhone app iOS
  │
  │ STT locale (GigiSpeechService) → testo
  │ Agent loop locale (GigiAgentEngine) → decide tool
  │
  ├── CASO 1: tool nativo iOS (call, navigate, ecc.)
  │       ↓ GigiActionDispatcher → esegue → speech
  │
  └── CASO 2: tool che richiede backend (memoria, computer-use, web)
        ↓ GigiHarnessClient.post("/api/ios/agent/run", {...})
        │
        ▼
     server.js (03_HARNESS)
        │ valida Bearer token
        │ enqueue(userId, task) con depth++
        │ getActiveSession(userId) → session_id Claude
        │
        ├── se memoria: memory.retrieve(query) → inject in prompt
        ├── se computer-use: delega a browser-pool/driver.js
        │
        │ spawnClaude(--resume session_id, --stream-json, prompt)
        │     ↓ stream JSONL
        │ WebSocket /ws/ios/stream → iOS riceve interim thoughts + tool calls
        │
        │ salva transcript mirror → logs/transcripts/<userId>.jsonl
        │ salva memoria incrementale (se memo trigger)
        │
        ▼
     iOS riceve risultato finale
        ↓ GigiSpeechService parla
        ↓ UI aggiorna
```

#### Flusso: watcher proattivo → notifica iPhone

```
watchers.js (timer 60s)
   ↓ fire watcher "morning-briefing"
   ↓ spawnClaude(prompt "riassumi calendario + meteo + news")
   ↓ parse output → se utile
   ↓ apns.send(userId, { alert: "Briefing mattutino pronto", data: {...} })
       ↓
    iPhone riceve push silente
    app iOS mostra notifica + aggiorna DashboardView
```

#### Flusso: confirm mode per pagamento

```
iOS → POST /api/ios/computer-use { task: "ordina pizza Deliveroo" }
   ↓ server enqueue + spawn Playwright
   ↓ browser naviga fino a checkout
   ↓ rileva CONFIRM_REQUIRED (pattern match €XX totale)
   ↓ apns.send(userId, { alert: "Deliveroo €28 — OK?", confirmId: XXX })
   ↓ server pausa task, salva state
       ↓
    iPhone mostra card confirm (Live Activity o push)
    utente tap OK
       ↓
    iOS → POST /api/ios/computer-use/:jobId/confirm { approved: true }
       ↓ server riprende task → click checkout → completa
       ↓ WebSocket → iOS "ordine confermato"
```

### 2.3 Spec API iOS ↔ server (sintesi)

Dettaglio completo in `03_HARNESS/docs/api/ios-integration.md` (da scrivere).

```
AUTH
  header: Authorization: Bearer <HARNESS_SHARED_SECRET>
  secret salvato in Keychain iOS (GigiKeychain.Key.harnessSecret)

ENDPOINT principali
  POST /api/ios/agent/run          ← entry point LLM cloud + tool
  POST /api/ios/agent/cancel       ← cancella task in volo
  POST /api/ios/memory/put         ← scrivi memoria
  POST /api/ios/memory/query       ← retrieval
  DELETE /api/ios/memory/:id
  POST /api/ios/computer-use       ← browser task complesso
  GET  /api/ios/computer-use/:id   ← poll status
  POST /api/ios/computer-use/:id/confirm
  POST /api/ios/push/register      ← salva APNS device token
  GET  /api/ios/session            ← session_id + uptime
  POST /api/ios/session/reset      ← nuova sessione Claude
  POST /api/ios/memo               ← forza snapshot memoria

WEBSOCKET
  WS   /ws/ios/stream?session=<id> ← interim thoughts, tool calls, progress

RESPONSE shape
  {
    ok: true|false,
    error?: { code, message },
    data?: { ... },
    jobId?: "uuid",
    stream?: true       // se si consiglia WS per questa richiesta
  }
```

---

## 3. Piano implementativo

### Fase 10 — Refactor layout harness (2h)

- [ ] **10.1** Rinomina `telegram-bridge/` → `server/`
- [ ] **10.2** Rinomina `browser-mcp/` → `browser-pool/`
- [ ] **10.3** Crea cartelle `server/api/`, `memory/`, `memory/backends/`, `apns/`
- [ ] **10.4** Sposta `bridge.js` → `server/server.js` (temporaneo — sarà splittato in 11)
- [ ] **10.5** Aggiorna `package.json` paths, `import` interni, config path references
- [ ] **10.6** **VPS-ready**: sostituisci path hardcoded con env vars (`HARNESS_ROOT`, `HARNESS_CONFIG`, ecc.), `.env` loader
- [ ] **10.7** Aggiorna `CLAUDE.md` + `docs/memory/context.md` + `INVENTARIO` + `ARCHITETTURA §9.BIS`
- [ ] **10.8** Smoke: `node server/server.js` deve ancora partire senza errori

### Fase 11 — Estrazione moduli (6h)

- [ ] **11.1** Estrai `server/session-manager.js` (funzioni: `loadSessions`, `saveSessions`, `getActiveSession`)
- [ ] **11.2** Estrai `server/claude-runner.js` (`spawnClaude`, `runClaude`)
- [ ] **11.3** Estrai `server/queue.js` (`enqueue`, `incDepth/decDepth`, `markCancelled`)
- [ ] **11.4** Estrai `server/rate-limit.js` (`isRateLimit`, `notifyRateLimit`, interrupted state)
- [ ] **11.5** Estrai `server/memory-snapshot.js` (`saveMemorySnapshot`, `_doMemoSnapshot`)
- [ ] **11.6** Estrai `server/transcript-mirror.js` (`mirrorTranscript`, `getChatTranscript`)
- [ ] **11.7** `server/server.js` diventa solo orchestratore + event loop (no più Telegram I/O — quello va in `clients/telegram/`)
- [ ] **11.8** Verifica: test manuale `runClaude` da script standalone funziona

### Fase 12 — API iOS server-side (8h)

- [ ] **12.1** `server/api/ios-auth.js` — middleware Bearer verifica `HARNESS_SHARED_SECRET` (da config)
- [ ] **12.2** `server/api/ios-agent.js` — `POST /api/ios/agent/run` → usa session-manager + claude-runner
- [ ] **12.3** `server/api/ios-stream.js` — WebSocket server piggyback su panel HTTP (ws lib nativa Node)
- [ ] **12.4** `server/api/ios-computer-use.js` — enqueue job, usa `browser-pool/driver.js`
- [ ] **12.5** `server/api/ios-push-register.js` — salva token APNS in `apns/tokens.json`
- [ ] **12.6** Estendi `panel-routes.js` con routing `/api/ios/*` → delegato ai file sopra
- [ ] **12.7** Test curl: `curl -H "Authorization: Bearer XXX" -X POST localhost:7777/api/ios/agent/run -d '{"text":"ciao"}'` ritorna OK

### Fase 13 — Memoria MVP JSON (1-2h) + path LanceDB

Decisione 1: parti con JSON, upgrade dopo. API stabile, backend swappabile.

- [ ] **13.1** `memory/store.js` — interfaccia `MemoryStore` astratta: `put(entry)`, `query(text, opts)`, `delete(id)`, `all(userId)`
- [ ] **13.2** `memory/backends/json-store.js` — implementazione JSON: file per userId in `logs/memory/<userId>.json`, array di `{ id, text, tags, userId, ts }`
- [ ] **13.3** `memory/retrieval.js` — keyword BM25 semplice (lunr.js o custom), top-10
- [ ] **13.4** Collega `server/api/ios-memory.js` a `memory/store.js`
- [ ] **13.5** Seed: migra `docs/memory/context.md` + `memory.md` come entry
- [ ] **13.6** Test: query "Marco" dopo `put("Marco è fratello di Leo")` ritorna entry
- [ ] **13.7** (FUTURO) `memory/backends/lancedb-store.js` — stesso API, LanceDB + BGE-M3 embedding. Swap in `store.js` con 1 riga `const backend = process.env.MEMORY_BACKEND || 'json'`

### Fase 14 — Computer-use reale (10h)

- [ ] **14.1** `browser-pool/driver.js` — API diretta (no MCP), esponi `lease/release/execute(page, action)`
- [ ] **14.2** Aggiungi dipendenza `@anthropic-ai/sdk` a `03_HARNESS/server/package.json`
- [ ] **14.3** `server/api/ios-computer-use.js` — loop Anthropic Computer Use (ref: `Architecture Armando Revision.md §9`)
  - Model `claude-opus-4-7` con tool `computer_20241022` (decisione 2)
  - Screenshot scaled 1280×800 JPEG q70
  - CONFIRM_REQUIRED pattern match → pausa + APNS
  - Max 20 step, timeout 2min
  - Cost tracking: stima token usage per request, log `logs/cost_tracking.json`
- [ ] **14.4** Integration test: task "apri google.com" completa successfully
- [ ] **14.5** Integration test: task "ordina pizza" si ferma a checkout con CONFIRM_REQUIRED

### Fase 15 — APNS + watcher proattivi (6h)

- [ ] **15.1** `apns/send.js` — wrapper `@parse/node-apn` con APNs Auth Key `.p8`
- [ ] **15.2** Config: `apns.key_path`, `apns.key_id`, `apns.team_id`, `apns.bundle_id`
- [ ] **15.3** `server/api/ios-push-register.js` — endpoint register device token (salva in `apns/tokens.json`)
- [ ] **15.4** Estendi `watchers.js` con `action: 'push_apns'` type — payload fissato in `watchers.json`
- [ ] **15.5** Crea watcher default `gigi-morning-briefing` (schedule ogni 08:00, manda push con sommario calendario)
- [ ] **15.6** Crea watcher default `gigi-meeting-prep` (polling cal, push 15min prima di eventi)
- [ ] **15.7** Test: `/api/ios/watchers/trigger/morning-briefing` → push arriva su iPhone

### Fase 16 — Client iOS (8h)

- [ ] **16.1** `GigiHarnessClient.swift` — URLSession + JSONEncoder + Bearer header
- [ ] **16.2** Retry policy: 3 tentativi con backoff esponenziale (0.5s, 1s, 2s)
- [ ] **16.3** WebSocket client (URLSessionWebSocketTask) per `/ws/ios/stream`
- [ ] **16.4** `GigiKeychain.Key.harnessSecret` + `.harnessBaseURL`
- [ ] **16.5** Settings UI: campo URL + secret in `SettingsView.swift`
- [ ] **16.6** Aggiorna `GigiComputerUse.swift` → delega a client invece di stub
- [ ] **16.7** Aggiorna `GigiMemory.swift` → `put/query` via client (fallback local se offline)
- [ ] **16.8** Registra device token APNS all'avvio app in `GIGIApp.swift`
- [ ] **16.9** Handler push APNS → naviga a confirm card se `type == confirm`

### Fase 17 — Rimozione Telegram (2h)

Decisione 3: drop completo. Niente `clients/telegram/`.

- [ ] **17.1** Rimuovi da `server/server.js`: `tg()`, `sendMessage`, `editMessage`, `deleteMessage`, `registerTelegramCommands`, `BUILTIN_COMMANDS`, `mdToHtml`, `handleUpdate`, `handleCallbackQuery`, `handleEditedMessage`, `handleCancel` wizard parts, `refreshWaiters`, `drainOfflineQueue` (Telegram queue), tutti i wizard `pendingWatcherFlows`
- [ ] **17.2** Rimuovi da `config.json`: sezione `telegram.*`, `shortcuts` (erano Telegram)
- [ ] **17.3** Rimuovi file `transcribe.js` (whisper per voice Telegram)
- [ ] **17.4** Rimuovi dipendenze npm non più usate: `ffmpeg-static`, `nodejs-whisper`
- [ ] **17.5** Rinomina `logs/chat_messages.json` → concept goes via, usa `sessions.json` per device iOS
- [ ] **17.6** `server.js` loop principale diventa: avvia HTTP server + WS + watchers, nessun Telegram polling
- [ ] **17.7** Test: `node server/server.js` parte senza config Telegram e resta in attesa richieste iOS

### Fase 18 — Docs + test E2E (4h)

- [ ] **18.1** Scrivi `03_HARNESS/docs/api/ios-integration.md` completo
- [ ] **18.2** Aggiorna `Architecture Armando Revision.md` §9.BIS con architettura finale
- [ ] **18.3** Aggiorna `docs/COMPONENTS.md` con nuovo layout
- [ ] **18.4** Scrivi `03_HARNESS/README.md` (quick start Mac + deploy)
- [ ] **18.5** Test E2E scenario 1: iOS → "ricordati che Marco è allergico alle noci" → memoria persiste → query dopo riavvio app
- [ ] **18.6** Test E2E scenario 2: iOS → "prenota Sakura alle 20" → CONFIRM_REQUIRED → utente OK → prenotato
- [ ] **18.7** Test E2E scenario 3: watcher morning-briefing → push APNS → iOS mostra notifica

---

## 4. Totali

| Fase | Effort | Prioritario? |
|---|---|---|
| 10 Refactor layout | 2h | **SÌ** (fondamento) |
| 11 Estrazione moduli | 6h | **SÌ** |
| 12 API iOS server | 8h | **SÌ** |
| 13 Memoria v4 MVP | 10h | SÌ ma schedulabile dopo 16 |
| 14 Computer-use reale | 10h | SÌ |
| 15 APNS + watcher | 6h | Opzionale (posticipabile) |
| 16 Client iOS | 8h | **SÌ** |
| 17 Telegram thin client | 3h | Opzionale (posticipabile o drop totale) |
| 18 Docs + E2E | 4h | **SÌ** |
| **TOTALE** | **57h** | |

**Path critico minimo (sblocca iOS ↔ backend funzionante)**:
10 → 11 → 12 → 16 = **24h**

**Path + memoria centralizzata**: +13 → **34h**

**Path + computer-use reale**: +14 → **44h**

**Path + push proattivi**: +15 → **50h**

**Full vision**: +17 +18 → **57h**

---

## 5. Decisioni (lockate 2026-04-23)

1. **Memoria stack**: **B — MVP JSON graduale** — parti con JSON file store (1h), stesso API wrapper `memory/store.js` così swap a LanceDB+BGE-M3 dopo è solo cambio backend
2. **Computer-use model**: **claude-opus-4-7** — più preciso su ragionamento complesso, accettiamo costo 3× per qualità
3. **Telegram**: **DROPPA TUTTO** — elimina ogni I/O Telegram, `tg()`, `setMyCommands`, wizard, handler, BUILTIN_COMMANDS, `allowed_chat_ids`. Fase 17 trasformata in "rimuovi codice Telegram"
4. **Host**: **Mac locale per dev, VPS-ready per prod** — niente path hardcoded, tutto env-var (`HARNESS_CONFIG`, `HARNESS_BASE_URL`, `ANTHROPIC_API_KEY`, `APNS_KEY_PATH`, ecc.). Config `.env` overrideable, `config.json` come fallback
5. **APNS**: **key disponibile** — fase 15 attiva, user fornisce `.p8` + Key ID + Team ID + Bundle ID
6. **Esecuzione**: **sequenziale 10→18**

---

## 6. Rischi

| Rischio | Impatto | Mitigazione |
|---|---|---|
| Claude CLI streaming API cambia | Alto — rompe spawnClaude | Lock versione claude CLI, test CI |
| LanceDB/BGE-M3 embedding pesante su server piccolo | Medio — latenza query | Benchmark prima di commit, fallback embedding remoto |
| Computer-use costoso ($0.20-0.50/task) | Medio — budget mensile | Cost tracking in state.json, cap mensile |
| APNS token expira | Basso | Re-register ad ogni app start |
| Server down → iOS locked out | Alto | Fallback offline locale per tutti i tool critici |
| Refactor rompe bridge Telegram in uso | Basso se droppi Telegram | Fase 17 testa o semplicemente droppa |

---

*Piano autore: Claude Code — 2026-04-23*
*Da approvare con Leonardo prima esecuzione Fase 10.*
