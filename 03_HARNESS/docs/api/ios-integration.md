# Spec API iOS ↔ Harness backend

**Base URL dev**: `http://127.0.0.1:7779` (Mac locale)
**Base URL prod**: configurabile in Keychain iOS (`harness_base_url`)

**Auth**: header `Authorization: Bearer <HARNESS_SHARED_SECRET>` su **ogni** richiesta HTTP e WS.
Il secret è condiviso fra app iOS (Keychain) e backend (env `HARNESS_SHARED_SECRET` o `cfg.ios.shared_secret`).

**Content-type**: `application/json; charset=utf-8` — sia in request che response.

**Envelope**: ogni risposta HTTP ha shape:
```json
{ "ok": true,  "data":  {...} }
{ "ok": false, "error": { "code": "...", "message": "..." } }
```

**CORS**: abilitato per origin `*` (dev). Restringere in prod.

---

## 1. Agent loop

### POST /api/ios/agent/run

Body:
```json
{ "deviceId": "uuid-locale-device", "text": "ciao, chi è Marco?", "stream": false }
```

Response 200:
```json
{
  "ok": true,
  "data": {
    "result": "Marco è tuo fratello.",
    "session_id": "abc-123",
    "session_new": false,
    "usage": { "input_tokens": 210, "output_tokens": 42 },
    "runId": "f4d0-..."
  }
}
```

Errori: 401 `UNAUTHORIZED`, 429 `RATE_LIMITED`, 500 `CLAUDE_ERROR`, 400 `MISSING_DEVICE|MISSING_TEXT|BAD_JSON`.

Se `stream=true`: connetti **prima** il WebSocket `/ws/ios/stream?deviceId=...`, poi fai la POST. Il backend pubblica interim thoughts + tool calls sul WS e la response HTTP contiene comunque il risultato finale.

### POST /api/ios/agent/cancel

Body:
```json
{ "deviceId": "...", "runId": "f4d0-..." }
```

Marca il run come cancellato. Se era già finito, no-op. 200 sempre.

### GET /api/ios/session?deviceId=...

Response:
```json
{ "ok": true, "data": { "active": true, "session_id": "abc-123", "last_active_at": 1776919000000, "started_at": 1776900000000 } }
```

### POST /api/ios/session/reset

Body `{ "deviceId": "..." }` → cancella la sessione Claude per quel device, prossima `agent/run` apre sessione nuova.

### POST /api/ios/memo

Body `{ "deviceId": "...", "reason": "manual" }` → forza snapshot memoria (Claude riassume la conversazione in `docs/memory/memory.md`).

---

## 2. Memoria semantica (per-device)

Backend JSON file store di default. Per produzione condivisa usa Supabase con `MEMORY_BACKEND=supabase`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`; lo schema canonico è `supabase/migrations/202605030001_gigi_core.sql`. LanceDB+BGE-M3 resta backend futuro via `MEMORY_BACKEND=lancedb`.

### POST /api/ios/memory/put
```json
{ "deviceId": "...", "text": "Marco è allergico alle noci", "tags": ["persone","allergie"] }
```
Response: `{ ok, data: { id, userId, text, tags, ts } }`.

### POST /api/ios/memory/query
```json
{ "deviceId": "...", "q": "allergie Marco", "limit": 10 }
```
Response: `{ ok, data: { results: [ { id, text, tags, ts, score }, ... ] } }` — ordine: score desc.

### DELETE /api/ios/memory/:id?deviceId=...
Response: `{ ok, data: { removed: true|false, id } }`.

### GET /api/ios/memory/all?deviceId=...
Dump completo (ordine: newest first).

---

## 3. Computer-use (browser via Anthropic Claude)

### POST /api/ios/computer-use
```json
{ "deviceId": "...", "task": "ordina una pizza margherita su Deliveroo" }
```
Response 202:
```json
{ "ok": true, "data": { "jobId": "f4d0-...", "status": "pending" } }
```

### GET /api/ios/computer-use/:jobId
Response:
```json
{
  "ok": true,
  "data": {
    "id": "f4d0-...",
    "deviceId": "...",
    "task": "...",
    "status": "pending|running|awaiting_confirm|done|failed|cancelled",
    "created_at": 1776919000000,
    "updated_at": 1776919500000,
    "steps": [ { "step": 0, "at": ..., "text": "...", "actions": [...] } ],
    "confirm_required": { "reason": "Checkout €28.50", "at": 1776919400000 },
    "confirm_response": null,
    "result": null,
    "error": null,
    "browser_instance": "slot1",
    "tokens": { "in": 5400, "out": 1200 }
  }
}
```

### POST /api/ios/computer-use/:jobId/confirm
Body: `{ "approved": true }` o `{ "approved": false }`.
Se `awaiting_confirm`: approved=true riprende il loop, false lo cancella. Altrimenti 409.

**Pattern CONFIRM_REQUIRED**: regex server-side su testo pagina (€/$ + checkout/totale/pay). Il prompt istruisce Claude a emettere `CONFIRM_REQUIRED: <desc>` invece di cliccare. Confirm esplicita via push APNS `{ type: "confirm", jobId }` → app iOS mostra card.

---

## 4. Push APNS

### POST /api/ios/push/register
Body:
```json
{ "deviceId": "...", "apnsToken": "hexstring", "platform": "ios", "bundleId": "com.leonardocorte.gigi" }
```
Chiamato **ad ogni app launch** (il token può cambiare). Response: `{ ok, data: { registered: true } }`.

### POST /api/ios/push/unregister
Body `{ "deviceId": "..." }` → rimuove token dal server.

### POST /api/ios/push/test
Body `{ "deviceId": "...", "title": "...", "body": "...", "silent": false }` → invia push di test via provider APNS.

**Tipi payload** backend → app:
- `{ aps: { alert: { title, body } }, type: "morning-briefing", ... }`
- `{ aps: { alert: { title, body } }, type: "meeting-prep", eventId, ... }`
- `{ aps: { alert: { title, body } }, type: "confirm", jobId, amount, vendor, ... }` (priority 10)
- `{ aps: { "content-available": 1 }, type: "silent-sync", ... }` (priority 5, pushType=background)

---

## 5. WebSocket streaming

### WS /ws/ios/stream?deviceId=...&token=...

Auth: token in query string (Bearer equivalent) oppure header `Authorization`.
Protocollo: messaggi JSON text frames.

**Messaggi server → client**:
```json
{ "type": "connected", "deviceId": "...", "ts": 1776919000000 }
{ "type": "claude_event", "runId": "...", "event": { /* evento JSONL Claude CLI */ } }
{ "type": "computer_use_update", "jobId": "...", "status": "running", "steps": [...] }
{ "type": "done", "runId": "...", "session_id": "..." }
{ "type": "cancelled", "runId": "..." }
```

Il client deve riconnettere con exp backoff (0.5s → 30s max).

---

## 6. Health

### GET /api/ios/health
Response: `{ ok, data: { pid, uptime_s } }`. Usato da app iOS al primo avvio per validare connettività + secret.

---

## 7. Configurazione Keychain iOS

```swift
GigiKeychain.save("http://10.0.0.5:7779", forKey: GigiKeychain.Key.harnessBaseURL)
GigiKeychain.save("<32-char-secret>",      forKey: GigiKeychain.Key.harnessSecret)
// harnessDeviceID è auto-generato al primo uso (UUID persistente)
```

UI: `SettingsView.harnessSection` — campo URL + SecureField secret + button "Salva e testa" → verifica health.

---

## 8. Errori comuni

| code | significato | azione client |
|---|---|---|
| `UNAUTHORIZED` | Bearer mancante/sbagliato o WS senza token | rileggi secret da Keychain, riprova |
| `RATE_LIMITED` | Claude rate limit attivo (flag globale) | mostra banner, fallback local |
| `MISSING_DEVICE` | deviceId assente | auto-include in ogni chiamata |
| `NOT_FOUND` | endpoint o jobId/id non esiste | verifica path |
| `WRONG_STATE` | confirm su job non in `awaiting_confirm` | refresh stato |
| `CLAUDE_ERROR` | Claude CLI error (stderr) | retry o fallback |
| `INTERNAL` | eccezione non gestita server-side | log + retry |

---

## 9. Retry policy consigliato (client)

- Transport errors (network down, 5xx): 3 tentativi, backoff 0.5s → 1s → 2s.
- `RATE_LIMITED` (429): no retry — fallback offline o chiedi conferma utente.
- `UNAUTHORIZED` (401): no retry — porta utente in Settings.
- `NOT_FOUND` (404): no retry.

Implementazione reference: `GigiHarnessClient.sendJSON()` in `02_GIGI_APP/GIGI/GigiHarnessClient.swift`.
