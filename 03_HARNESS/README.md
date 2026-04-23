# 03_HARNESS — Backend GIGI (Node)

Backend che serve l'app iOS GIGI: sessioni Claude, memoria semantica, computer-use browser,
watcher proattivi (push APNS), session cross-device.

Stack: Node 20+, Playwright-core (computer-use), puppeteer-core (MCP browser pool legacy),
ws (WebSocket iOS), @anthropic-ai/sdk (computer-use).

---

## Quick start (Mac locale)

```bash
cd 03_HARNESS/server
npm install

# Crea config.json dalla template macOS
cp config.example.mac.json config.json
# Edita config.json — imposta:
#   - claude.bin         → path al binario Claude CLI
#   - ios.shared_secret  → genera con: openssl rand -hex 16
#   - anthropic.api_key  → per computer-use (fase 14)
#   - apns.*             → per push (fase 15)
#   - browser.instances  → path profili Chrome loggati

# Avvia server (porte 7779 iOS + 7778 RPC + watchers)
node server.js

# In un altro terminale: admin panel (porta 7777)
node panel.js
open http://localhost:7777
```

---

## Architettura runtime

```
 panel.js (7777)     ───────────────> server.js (7779)
  │                                    │
  │ HTTP admin UI                      │ HTTP + WS iOS
  │ + spawn server.js as "bridge"      │
  │                                    ├── watchers.js (60s tick)
  │                                    │     └─> Claude CLI + APNS push
  │                                    │
  │ RPC loopback (:7778) <─────────────┤
  │                                    │
  └── puppeteer screenshot             ├── api/ios-*.js routers
                                       ├── claude-runner.js (spawn Claude CLI)
                                       ├── memory/store.js (JSON backend)
                                       └── browser-pool/driver.js
                                            └─> Playwright CDP → Chrome pool
```

---

## Porte

| Porta | Processo | Uso |
|---|---|---|
| 7777 | `panel.js` | admin UI (HTTP) |
| 7778 | `server.js` | RPC loopback (panel → watchers) |
| 7779 | `server.js` | iOS API (HTTP + WS) |
| 9224/5/6 | Chrome | CDP profile loggato `main`, `slot1`, `slot2` |

---

## Directory layout

Vedi `CLAUDE.md` per l'indice completo. Struttura core:

```
03_HARNESS/
├── server/          ← backend Node (HTTP iOS + watchers + Claude runner)
│   ├── api/         ← router iOS (/api/ios/*)
│   ├── logs/        ← gitignored — sessions, state, transcripts, job computer-use
│   └── public/      ← admin UI static (panel)
├── browser-pool/    ← MCP browser (legacy) + driver.js (computer-use diretto)
├── memory/          ← JSON backend per memoria semantica per-device
├── apns/            ← provider APNS (HTTP/2 + JWT ES256)
└── docs/api/        ← spec endpoint
```

---

## Environment variables (VPS-ready)

Tutti i path override via env:

| Var | Default | Uso |
|---|---|---|
| `HARNESS_CONFIG` | `server/config.json` | path config |
| `HARNESS_LOGS_DIR` | `server/logs` | path logs runtime |
| `HARNESS_WATCHERS` | `server/watchers.json` | path definizioni watcher |
| `HARNESS_SHARED_SECRET` | — | Bearer iOS (override cfg.ios.shared_secret) |
| `HARNESS_MEMORY_DIR` | `memory/logs` | storage JSON memoria per-user |
| `MEMORY_BACKEND` | `json` | `json` o `lancedb` |
| `ANTHROPIC_API_KEY` | — | per computer-use (override cfg.anthropic.api_key) |
| `APNS_KEY_PATH` | cfg.apns.key_path | .p8 APNs Auth Key |
| `APNS_KEY_ID` | cfg.apns.key_id | Key ID 10 char |
| `APNS_TEAM_ID` | cfg.apns.team_id | Team ID 10 char |
| `APNS_BUNDLE_ID` | cfg.apns.bundle_id | bundle app iOS |
| `APNS_PRODUCTION` | cfg.apns.production | `true` per endpoint production |

Carica `.env` da `start.sh` se presente.

---

## Test E2E

### Scenario 1: memoria persistente

```bash
SECRET="dev-secret-32-char"
BASE="http://127.0.0.1:7779"

# put
curl -s -H "Authorization: Bearer $SECRET" -X POST "$BASE/api/ios/memory/put" \
  -d '{"deviceId":"test-1","text":"Marco è allergico alle noci","tags":["persone"]}'

# query
curl -s -H "Authorization: Bearer $SECRET" -X POST "$BASE/api/ios/memory/query" \
  -d '{"deviceId":"test-1","q":"Marco allergia"}'
```

### Scenario 2: agent run

```bash
curl -s -H "Authorization: Bearer $SECRET" -X POST "$BASE/api/ios/agent/run" \
  -d '{"deviceId":"test-1","text":"ciao, chi sei?"}'
```

### Scenario 3: push test (richiede APNS config)

```bash
curl -s -H "Authorization: Bearer $SECRET" -X POST "$BASE/api/ios/push/test" \
  -d '{"deviceId":"test-1","title":"GIGI","body":"Test push"}'
```

---

## Deploy VPS (prod)

1. Copia `03_HARNESS/` sul VPS.
2. `npm install` in `server/` e `browser-pool/`.
3. Crea `.env` con tutti i segreti (`HARNESS_SHARED_SECRET`, `ANTHROPIC_API_KEY`, `APNS_*`).
4. Installa Chrome + `xvfb` se headless server (per computer-use visible).
5. Avvia via `systemd` o `pm2`:
   ```
   pm2 start server/server.js --name gigi-harness-server
   pm2 start server/panel.js  --name gigi-harness-panel
   ```
6. Nginx reverse proxy:
   - `app.example.com/api/ios/*` → `127.0.0.1:7779`
   - `app.example.com/ws/ios/*` → `127.0.0.1:7779` (upgrade WS)
   - TLS via Let's Encrypt (obbligatorio per WSS su iOS ATS).

---

## Drop Telegram (fase 17 completata)

Il codice Telegram è stato rimosso completamente: nessun `bot_token`, `allowed_chat_ids`, `tg()`,
`mdToHtml`, `transcribe.js` (whisper), `BUILTIN_COMMANDS`. Se serve ripristinarlo in futuro,
vedi history git prima di `feat(harness): phase 11-13,17`.
