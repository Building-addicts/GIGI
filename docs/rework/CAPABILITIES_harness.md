# Harness — Inventario capability (Node backend)

Mappa completa delle superfici e dei moduli in `03_HARNESS/`, per supportare la decisione di sfoltimento del rework.
Path repo (read-only): `C:\Users\arman\Desktop\PROGETTI VIBE CODING\GIGI FOLDER\GIGI-main\03_HARNESS`.

Dipendenze npm chiave (`server/package.json`): `@anthropic-ai/sdk`, `playwright-core`, `puppeteer-core`, `ws`, `qrcode`, `qrcode-terminal`, `bonjour-service`. Nessuna libreria APNS esterna (HTTP/2 + crypto nativi).

iOS client effettivamente chiama (`grep` su `02_GIGI_APP/**/*.swift`): `/api/ios/agent/{run,cancel}`, `/api/ios/session{,/reset}`, `/api/ios/memo`, `/api/ios/memory/{put,query}` + `/api/ios/memory/<id>` DELETE, `/api/ios/computer-use{,/<id>{,/confirm}}`, `/api/ios/push/{register,unregister}`, `/api/ios/health`, `/api/ios/status`, `/api/debug/ingest`. **Mai chiamati da iOS:** `/api/ios/memory/all`, `/api/ios/push/test`.

---

## 1. Bootstrap & orchestrator

### 1.1 HTTP+WS server iOS (porta 7779)
- **Entry**: `server/server.js:144` — `main()`
- **What**: lock file, carica config, avvia watchers + RPC, monta HTTP server con catena di handler (debug-ingest → pair → diagnostics → autofix → panel-connections → setup → ios-router → channel-router) + WebSocket upgrade.
- **Files**: `server.js`, `paths.js`, `logger.js`.
- **Calls**: tutti i moduli api/ios-*, `apns/`, `tunnel/`, `watchers.js`.
- **Called by**: avviato come child di `panel.js` (bridge process) o standalone.
- **Status**: live.
- **Removability**: low — è l'orchestratore.

### 1.2 Admin panel (porta 7777)
- **Entry**: `server/panel.js:1` (~700 righe)
- **What**: pannello web HTTP separato; spawna `server.js` come "bridge", screenshot Chrome via puppeteer-core, expose 37+ route legacy (`/api/status`, `/api/config`, `/api/bridge/*`, `/api/browser/*`, `/api/sessions`, `/api/watchers`, `/api/terminal/*`, `/api/autostart`, `/api/logs`, `/browser-login`, `/api/browser/passport/*`).
- **Files**: `panel.js`, `panel-routes.js`, `public/{index,start,pair,setup,browser-login}.html`, `public/app.js`.
- **Calls**: `puppeteer-core`, processi figli (`spawn`/`execFile`), `bridge-rpc` su 7778.
- **Called by**: utente (browser locale), windows autostart `.vbs`.
- **Status**: live ma sovradimensionato.
- **Removability**: medium — molte route panel sono legacy (browser passport, autostart Windows, terminal toggle); il setup wizard è importante ma è duplicato in `api/setup.js`.

### 1.3 RPC loopback panel↔server (porta 7778)
- **Entry**: `server/bridge-rpc.js:23` — `startRpc(cfg, log)`
- **What**: HTTP loopback che permette al panel di invocare mutation watcher (`/watchers/<id>/{fire,toggle}`, `/watchers/{rate-limit,clear}`) sul processo bridge senza spawnare Claude duplicati.
- **Files**: `bridge-rpc.js`.
- **Called by**: `panel-routes.js` (fetch verso 127.0.0.1:7778).
- **Status**: live.
- **Removability**: medium — utile solo se panel resta processo separato; in setup single-process si elimina.

---

## 2. iOS API surface (`/api/ios/*` — Bearer auth)

### 2.1 Router iOS + auth Bearer + CORS
- **Entry**: `server/api/ios-router.js:24` — `handleIosRequest`
- **What**: dispatch di tutte le route `/api/ios/*`, applica `checkBearer`, blocked-device check, CORS.
- **Files**: `ios-router.js`, `ios-auth.js`.
- **Status**: live.
- **Removability**: low.

### 2.2 POST `/api/ios/agent/run` (+ cancel, session, session/reset, memo)
- **Entry**: `server/api/ios-agent.js:13` — `handleAgentRun`
- **What**: enqueue per deviceId, spawn Claude CLI con `runClaude`, opzionale streaming via WS, ritorna `{result, session_id, usage}`.
- **Files**: `ios-agent.js`, `claude-runner.js`, `queue.js`, `session-manager.js`, `rate-limit.js`, `transcript-mirror.js`, `memory-snapshot.js`.
- **Calls**: subprocess `claude` CLI, WS `broadcast`.
- **Called by**: iOS GIGI app (entry point principale del prodotto).
- **Status**: live, cuore del sistema.
- **Removability**: low.

### 2.3 GET `/api/ios/session`, POST `/api/ios/session/reset`, POST `/api/ios/memo`
- **Entry**: `server/api/ios-agent.js:101,120,133`
- **What**: ispeziona/resetta sessione Claude per device; `memo` triggera snapshot via Claude `--resume`.
- **Files**: `ios-agent.js`, `memory-snapshot.js`.
- **Status**: live.
- **Removability**: medium — `memo` è feature laterale (potrebbe essere derubricato a interna).

### 2.4 POST `/api/ios/memory/put`, `/query`, DELETE `/<id>`, GET `/all`
- **Entry**: `server/api/ios-memory.js:8,22,35,47`
- **What**: CRUD memoria semantica per-device tramite `memory/store.js`.
- **Files**: `ios-memory.js`, `memory/store.js`, `memory/backends/json-store.js`.
- **Status**: live (put/query/delete) — **`/all` no caller in iOS** → dead-code candidate.
- **Removability**: `/all` high; gli altri low.

### 2.5 POST `/api/ios/computer-use` + GET status + POST confirm
- **Entry**: `server/api/ios-computer-use.js:1` — `handleStart/handleStatus/handleConfirm`
- **What**: agent loop con `@anthropic-ai/sdk` (cloud Anthropic, non Claude CLI!) usando tool `computer_20241022` + Playwright CDP; CONFIRM pattern per checkout/pagamenti; cost tracking.
- **Files**: `ios-computer-use.js`, `browser-pool/driver.js`.
- **Calls**: SDK Anthropic, Playwright `chromium` su CDP, WS broadcast.
- **Status**: live ma esperimentale + costoso.
- **Removability**: medium-high — è una feature isolata; tagliarla rimuove dipendenza da `@anthropic-ai/sdk` + Playwright pool (Chrome loggato, lease file). Da decidere se MVP la richiede.

### 2.6 POST `/api/ios/push/{register,unregister}`
- **Entry**: `server/api/ios-push-register.js:26,47`
- **What**: salva/rimuove device token APNS in `apns/tokens.json`.
- **Status**: live.
- **Removability**: low (necessario per APNS).

### 2.7 POST `/api/ios/push/test`
- **Entry**: `server/api/ios-push-test.js`
- **What**: invia push smoke a un deviceId.
- **Status**: live ma **no caller in iOS** → solo curl di debug.
- **Removability**: high — è solo per smoke test manuale.

### 2.8 GET `/api/ios/health`
- **Entry**: inline in `ios-router.js:85`
- **What**: pid + uptime.
- **Status**: live.
- **Removability**: medium — duplicato concettuale di `/api/ios/status` ma molto leggero.

### 2.9 GET `/api/ios/status`
- **Entry**: `server/api/ios-status.js:81` — `handleStatus`
- **What**: rich card per Settings (request rate, ws clients, watcher state). Chiamato dal Settings iOS ogni N sec.
- **Status**: live.
- **Removability**: low.

### 2.10 WebSocket `/ws/ios/stream?deviceId=...`
- **Entry**: `server/api/ios-stream.js:40` — `attachWebSocketServer`
- **What**: room-per-device per streaming eventi Claude (tool call, delta, done) e computer-use updates; heartbeat 30s; auth Bearer in header (non query).
- **Files**: `ios-stream.js`.
- **Calls**: `ws` (WebSocketServer noServer + httpServer.upgrade).
- **Called by**: iOS `GigiHarnessStream.swift`.
- **Status**: live.
- **Removability**: low.

### 2.11 POST `/api/debug/ingest`
- **Entry**: `server/api/debug-ingest.js:30`
- **What**: riceve log in-app da `GigiDebugLogger`, append in `logs/ios-debug.log`.
- **Status**: live (debug only).
- **Removability**: medium — utile durante debug crash early-launch; rimuovibile in versione "clean".

---

## 3. Setup & onboarding (loopback-only, no Bearer)

### 3.1 GET `/api/pair` (+QR)
- **Entry**: `server/api/pair.js`
- **What**: produce JSON `{url, secret, deviceName, createdAt}` o SVG QR; auto-detect IPv4 Tailscale (100.x.y.z) o pubblica Cloudflare URL.
- **Calls**: `qrcode`, `tunnel/cloudflared-manager`.
- **Status**: live.
- **Removability**: low (pairing iniziale).

### 3.2 `/api/setup/*` wizard (manual/quick/lan/named)
- **Entry**: `server/api/setup.js` (~15 endpoint: env, status, quick/{start,stop}, lan/{start,stop}, manual, named/{login,cert-status,configure,stop})
- **What**: 4 modalità di esposizione del backend al telefono: cloudflared anonimo, mDNS LAN, Cloudflare Named tunnel OAuth, manuale.
- **Files**: `setup.js`, `tunnel/cloudflared-manager.js`, `tunnel/install-cloudflared.js`, `tunnel/install-service.js`, `tunnel/mdns.js`, `tunnel/cf-api.js`.
- **Status**: live; named mode parzialmente stub (501).
- **Removability**: medium — le 4 modalità sono ridondanti per MVP; tenerne max 2 (es. quick + manual) sfoltisce ~600 righe + dipendenze (`bonjour-service`, parte di `cf-api.js`).

### 3.3 GET `/api/setup/diagnostics` + POST `/api/setup/autofix`
- **Entry**: `server/api/diagnostics.js:30`, `server/api/autofix.js:45`; runner `server/preflight/runner.js`, primitive `server/preflight/checks.js`, fix `server/preflight/auto_fixers.js`.
- **What**: 10+ probe in parallelo (claude CLI install/auth, secret strength, tunnel mode/running, cloudflared bin, outbound HTTPS, port 7779, disk, last request, ecc.) + auto-fix batch.
- **Status**: live, Bearer-authed (chiamato dal telefono).
- **Removability**: medium — pesante (~500 righe checks) ma utile per troubleshooting.

### 3.4 `/api/panel/*` (Connections tab, loopback)
- **Entry**: `server/api/panel-connections.js:185+` — 6 endpoint (connections GET, tunnel stop/restart, ws close, device revoke/reset-session).
- **Status**: live, usato solo dal panel.
- **Removability**: medium — dipende dalla scelta di mantenere il panel.

---

## 4. Channel router (legacy)

### 4.1 POST `/api/channels/{telegram,whatsapp}`
- **Entry**: `server/api/channel-router.js:23` — `handle`
- **What**: webhook Telegram/WhatsApp; **disabilitato di default**, ritorna 410 CHANNEL_DISABLED se `cfg.channels.<x>.enabled !== true`.
- **Files**: `channel-router.js`, `channels/telegram.js`, `channels/whatsapp.js`, `audio/{stt,tts,normalize}.js`, `identity/user-mapper.js`.
- **Calls**: Groq Whisper / OpenAI Whisper (STT), TTS provider, ffmpeg (normalize), Telegram Bot API.
- **Status**: dead-code (ufficialmente "GIGI is iPhone-only").
- **Removability**: high — ~7 file (telegram.js, whatsapp.js, stt.js, tts.js, normalize.js, channel-router.js, user-mapper.js) eliminabili in blocco. Liberano dipendenza implicita ffmpeg.

---

## 5. Claude integration

### 5.1 Claude CLI subprocess runner
- **Entry**: `server/claude-runner.js` — `spawnClaude`, `runClaude`, `runParallelTask`
- **What**: `spawn('claude', args)` con `--session-id`/`--resume`, output stream-json line-by-line, friendly tool labels, mirror transcript JSONL, gestione rate-limit/session-not-found.
- **Files**: `claude-runner.js`, `session-manager.js`, `transcript-mirror.js`, `rate-limit.js`, `queue.js`, `memory-snapshot.js`.
- **Called by**: ios-agent, watchers (entrambi spawnano `claude` CLI), memo snapshot.
- **Status**: live.
- **Removability**: low.

### 5.2 Anthropic SDK client (computer-use)
- **Entry**: `server/api/ios-computer-use.js` — `import Anthropic from '@anthropic-ai/sdk'`
- **What**: chiama API cloud `anthropic.messages.create` con tool `computer_20241022` (no CLI, no abbonamento Claude Code — billing token-by-token via `ANTHROPIC_API_KEY`).
- **Status**: live ma **path completamente diverso** dal resto del sistema.
- **Removability**: high — duplica il modello "agent loop" e introduce billing parallelo. Tagliare elimina sia SDK che browser-pool driver.

### 5.3 Memory snapshot (`/memo`)
- **Entry**: `server/memory-snapshot.js`
- **What**: `--resume <sessionId>` con prompt summarization, salva in `docs/memory/memory.md`. Coda interna (1 alla volta).
- **Status**: live.
- **Removability**: medium — il riassunto manuale è utile ma rimovibile per MVP.

---

## 6. Memory persistence

### 6.1 MemoryStore astrazione
- **Entry**: `memory/store.js:9` — `getStore()`
- **What**: factory swappabile via `MEMORY_BACKEND` env.
- **Files**: `memory/store.js`, `memory/backends/json-store.js` (solo questo presente — `lancedb-store.js` referenziato ma file mancante in `backends/`).
- **Status**: live (json), upgrade futuro mai materializzato.
- **Removability**: low (json store), high (l'astrazione factory è over-engineering per un solo backend).

---

## 7. Browser pool / computer-use

### 7.1 Driver Playwright diretto
- **Entry**: `browser-pool/driver.js` — `lease/release/openSession`
- **What**: connette via CDP (porte 9224/5/6) a Chrome con profili loggati (`main`, `slot1`, `slot2`); lease file-backed (`logs/browser_leases.json`) cross-process.
- **Called by**: `ios-computer-use.js`.
- **Status**: live.
- **Removability**: high se si toglie computer-use.

### 7.2 MCP Puppeteer server (`browser-pool/server.js`)
- **Entry**: stdio MCP server, tools: `browser_navigate`, `browser_click`, ecc.
- **What**: legacy MCP browser pool per Claude CLI tools (alternativa a driver.js).
- **Status**: experimental/legacy — driver.js ha sostituito questo path per computer-use.
- **Removability**: high — duplicate path. Anche `server-playwright.js` è un'alternativa in più (3 modi per fare la stessa cosa: server.js Puppeteer, server-playwright.js Playwright, driver.js diretto).

---

## 8. APNS push

### 8.1 APNS provider HTTP/2 + JWT ES256
- **Entry**: `apns/send.js` — `sendPush`, `sendToDevice`, `broadcastToAll`, `buildAlertPayload`, `buildSilentPayload`
- **What**: zero-deps APNS via `node:http2` + `node:crypto` (firma ES256 della JWT).
- **Files**: `apns/send.js`, `apns/tokens.json` (storage), `server/api/ios-push-register.js`.
- **Called by**: `watchers.js` (action `push_apns`), `/api/ios/push/test`.
- **Status**: live.
- **Removability**: low (richiesto da watchers + iOS Live Activities).

---

## 9. Watchers (background polling)

### 9.1 Watcher engine (timer + lock cross-process)
- **Entry**: `server/watchers.js:393` — `start(cfg, log)` + `fireWatcher` (line 159)
- **What**: timer per watcher abilitato in `watchers.json` (default 60s, stagger 30s). Ogni fire: `spawn claude -p <prompt> --output-format json`, parse output, opzionalmente estrae direttive `{push:[...]}` e invia APNS. Lock persistente in `watchers_runtime.json` (cross-process), pausa globale su 429 fino a mezzanotte Europe/Rome, budget `max_responses`, hot-reload `fs.watch` su file json, istruzioni one-shot via `<id>-instructions.md`.
- **Files**: `watchers.js`, `watchers.json`.
- **Calls**: Claude CLI subprocess, APNS `sendToDevice/broadcastToAll`.
- **Status**: live, ma **entrambi i watcher di default disabilitati** (`enabled: false`).
- **Removability**: medium — engine è solido (~500 righe), ma se MVP non usa watcher proattivi può essere disattivato per ora.

### 9.2 Watcher built-in (`gigi-morning-briefing`, `gigi-meeting-prep`)
- **Definition**: `server/watchers.json`
- **Status**: dead-code (entrambi `enabled:false`, prompt referenziano calendario/news che richiedono tool non garantiti).
- **Removability**: high.

---

## 10. Tunneling & networking

### 10.1 Cloudflared manager
- **Entry**: `server/tunnel/cloudflared-manager.js` — `cloudflared.startQuick/startNamed/stop/status`
- **What**: lifecycle child process `cloudflared`, parse stdout per URL trycloudflare, persiste `~/.gigi/tunnel-current-url.txt`, auto-restart 3 attempts/60s.
- **Files**: `cloudflared-manager.js`, `install-cloudflared.js`, `install-service.js`, `cf-api.js`.
- **Status**: live.
- **Removability**: low se MVP usa tunnel; medium se ci si limita a Tailscale.

### 10.2 mDNS LAN advertise
- **Entry**: `server/tunnel/mdns.js` — `startAdvertise/stopAdvertise`
- **What**: pubblica `_gigi._tcp.local` via Bonjour.
- **Status**: live solo se `tunnel.mode=lan`.
- **Removability**: high — modalità LAN poco usata, dipendenza `bonjour-service`.

### 10.3 Cloudflare API client
- **Entry**: `server/tunnel/cf-api.js`
- **What**: ~5 endpoint v4 (verify cert, list accounts, zones, create tunnel, create DNS CNAME) usati solo dal Named mode wizard.
- **Status**: live ma usato solo se Named mode attivo.
- **Removability**: high (insieme a setup Named).

---

## 11. Cross-cutting

### 11.1 Request log (rolling)
- **Entry**: `server/request-log.js` — `recordRequest`, `recentRequests(50)`.
- **What**: ring buffer in-memory per panel "Connections" tab.
- **Status**: live.
- **Removability**: medium — utile solo per panel.

### 11.2 Logger
- **Entry**: `server/logger.js` — `log(...)`.
- **Status**: live, base.
- **Removability**: low.

### 11.3 Paths constants
- **Entry**: `server/paths.js` — costanti env-overridable (LOGS_DIR, CONFIG_PATH, ecc).
- **Status**: live.
- **Removability**: low.

### 11.4 Public static UI (admin panel)
- **Files**: `server/public/{index,start,pair,setup,browser-login}.html`, `app.js`, `style.css`.
- **What**: SPA admin servita da `panel.js` (browser passport, watchers, browser instances, ecc).
- **Status**: live.
- **Removability**: medium — se si elimina panel, intera cartella va via.

### 11.5 Test files
- **Status**: **NESSUN file di test trovato** in `03_HARNESS/` (no `test/`, no `__tests__`, no `*.test.js`). Solo curl examples in README.
- **Removability**: n/a — niente da rimuovere; va aggiunta una test suite.

---

## Sintesi per categoria

| Categoria | Capability | Removability suggerita |
|---|---|---|
| iOS API core (agent/run, session, status, ws stream, push register) | 6 | low |
| Memory store + put/query/delete | 4 | low |
| Memory `/all` endpoint | 1 | high (no iOS caller) |
| Push test endpoint | 1 | high (smoke only) |
| Computer-use (SDK Anthropic + Playwright + browser pool) | 4 | high (~30% del codice; SDK billing parallelo, browser loggati, 3 path duplicati) |
| Channel router Telegram/WhatsApp + STT/TTS/normalize/user-mapper | 7 file | high (esplicitamente dichiarato dead) |
| Setup wizard 4 modes + diagnostics + autofix | ~10 endpoint | medium (tenere quick+manual) |
| Tunneling Cloudflare Named + mDNS LAN + cf-api | 4 file | medium-high |
| Admin panel (panel.js + panel-routes 37 route + public/* + bridge-rpc) | ~6 file, ~1500 righe | medium (utile dev, eliminabile in prod minimal) |
| Watchers engine + JSON | 2 | medium (engine solido, ma watcher attuali disabilitati) |
| MCP browser pool legacy (puppeteer + playwright server) | 2 file | high (driver.js è il path attuale) |
| Claude CLI runner + queue + sessions + rate-limit + transcript mirror | 5 file | low (cuore) |
| APNS HTTP/2 zero-deps | 1 | low |
