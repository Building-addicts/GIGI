# Harness — Backend GIGI (indice memoria)

Questo file è l'indice del sottosistema **Harness**, backend Node dell'app iOS GIGI.
Harness = layer server-side che serve il client iOS: sessioni Claude, memoria persistente,
computer-use browser, watcher proattivi, push APNS.

Quando apri una sessione Claude Code in `03_HARNESS/`, leggi prima questo file.

**Posizione nel monorepo GIGI:**
```
GIGI-harness/                      ← root monorepo (remote: Leonardo-Corte/GIGI)
├── 00_DOCS/                       ← architettura + task plan + piano integrazione harness
├── 01_SERVER_MDM/                 ← server Node per profili MDM iOS
├── 02_GIGI_APP/                   ← app iOS Swift (GIGI V3)
└── 03_HARNESS/                    ← sei qui (backend GIGI)
```

**Stato integrazione (2026-04-23)**: fasi 10-18 complete. Backend iOS operativo.
Piano riferimento: `00_DOCS/PIANO_INTEGRAZIONE_HARNESS.md`.
Spec API: `docs/api/ios-integration.md`. Quick start: `README.md`.

Porte: **7777** panel admin · **7778** RPC loopback · **7779** iOS HTTP+WS.

## Struttura sottosistema

```
03_HARNESS/
├── CLAUDE.md                      ← sei qui
├── docs/
│   ├── memory/
│   │   ├── context.md             ← contesto statico (leggi sempre)
│   │   └── memory.md              ← memoria conversazioni (auto-generato)
│   └── api/
│       └── ios-integration.md     ← spec API iOS (fase 18)
├── server/                        ← backend GIGI (ex telegram-bridge)
│   ├── server.js                  ← orchestratore + main + HTTP+WS iOS (7779)
│   ├── paths.js                   ← path costanti (env override)
│   ├── logger.js                  ← log shared
│   ├── session-manager.js         ← sessione Claude per device iOS
│   ├── claude-runner.js           ← spawn CLI Claude + streaming
│   ├── queue.js                   ← code richieste + cancel + tracking child
│   ├── rate-limit.js              ← recovery rate limit + interrupted state
│   ├── memory-snapshot.js         ← /memo auto snapshot
│   ├── transcript-mirror.js       ← mirror JSONL Claude
│   ├── panel.js                   ← pannello web admin (7777)
│   ├── panel-routes.js            ← route handler hot-reloadable
│   ├── bridge-rpc.js              ← RPC panel↔server (7778)
│   ├── watchers.js                ← worker autonomi + action push_apns
│   ├── watchers.json              ← watcher default (morning-briefing, meeting-prep)
│   ├── config.example.json        ← template Windows
│   ├── config.example.mac.json    ← template macOS/Linux
│   ├── api/                       ← endpoint iOS
│   │   ├── ios-router.js          ← router + Bearer auth + CORS
│   │   ├── ios-auth.js            ← middleware Bearer
│   │   ├── ios-agent.js           ← POST agent/run + cancel + session + memo
│   │   ├── ios-memory.js          ← POST memory/put + query + DELETE + GET all
│   │   ├── ios-computer-use.js    ← loop Anthropic SDK + Playwright
│   │   ├── ios-push-register.js   ← POST push/register + unregister
│   │   ├── ios-push-test.js       ← POST push/test (APNS smoke)
│   │   └── ios-stream.js          ← WebSocket /ws/ios/stream + broadcast room
│   └── logs/                      ← stato runtime (gitignored)
│       ├── state.json
│       ├── sessions.json
│       ├── interrupted.json
│       ├── bridge.log
│       └── transcripts/           ← mirror JSONL per device iOS
├── browser-pool/                  ← pool Chrome loggati (ex browser-mcp)
│   ├── server.js                  ← MCP Puppeteer
│   ├── server-playwright.js       ← MCP Playwright
│   └── driver.js                  ← API diretta per computer-use (fase 14)
├── memory/                        ← implementazione memoria (fase 13)
│   ├── store.js                   ← API astratta MemoryStore
│   ├── retrieval.js               ← hybrid retrieval
│   └── backends/
│       ├── json-store.js          ← MVP JSON file per userId
│       └── lancedb-store.js       ← upgrade futuro (LanceDB + BGE-M3)
├── apns/                          ← Apple Push Notifications (fase 15)
│   ├── send.js                    ← wrapper node-apn
│   └── tokens.json                ← device token per userId
├── memory-upgrade/                ← design sistema memoria (docs only)
│   ├── README.md
│   ├── research/
│   ├── single-user/               ← piani v1→v4.2
│   └── multi-user-v1/             ← branch multi-user
└── browser-profile/ (+ slot1/slot2) ← profili Chrome loggati (gitignored)
```

## File di stato runtime (`server/logs/`)

| File | Contenuto |
|------|-----------|
| `logs/sessions.json` | Session ID Claude attivi per ogni device iOS |
| `logs/interrupted.json` | Task interrotti da rate limit (recovery) |
| `logs/bridge.log` | Log operativo del server |
| `logs/state.json` | Statistiche server (requests, errors) |
| `logs/transcripts/<deviceId>.jsonl` | Mirror JSONL Claude (backup portabile) |
| `logs/browser_leases.json` | Pool lease browser-pool cross-process |
| `logs/watchers_state.json` | Stato + budget watcher |

## Configurazione VPS-ready (env vars)

Tutti i path override via env:
- `HARNESS_CONFIG` — path config.json (default `server/config.json`)
- `HARNESS_LOGS_DIR` — path logs dir (default `server/logs`)
- `HARNESS_WATCHERS` — path watchers.json (default `server/watchers.json`)
- `HARNESS_SHARED_SECRET` — Bearer token per API iOS
- `ANTHROPIC_API_KEY` — per computer-use (fase 14)
- `APNS_KEY_PATH`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID` — APNS (fase 15)

`.env` caricato da `start.sh` se presente.

## Memory Upgrade (design in corso, non ancora implementato)

Redesign memoria in `memory-upgrade/`. Branch attivo: `multi-user-v1/` (10 utenti, federated fine-tuning).
Fase 13 implementa MVP JSON, upgrade a v4 SOTA stack (Anthropic Memory Tool + LanceDB + BGE-M3 + SurrealDB) futuro.

## Regola: loop → watcher

Quando l'utente chiede "metti in loop": **NON** `ScheduleWakeup`. Crea watcher in `server/watchers.json`.
Chiedi SEMPRE frequenza polling. Prompt watcher = richiesta originale. Se serve browser, usa primo slot libero (slot1/slot2).
Hot-reload via `POST /api/watchers/<id>/toggle` su porta 7777.
