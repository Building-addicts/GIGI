# Panel Observability & Connection Management

**Status**: Draft · **Owner**: Armando · **Phase**: 6

## Requirements Summary

Estendere il Panel web (`localhost:7777`) con visibilità sullo stato reale di GIGI: quali device sono paired, chi è connesso adesso, qual è il tunnel attivo e con che URL, le ultime richieste servite. Aggiungere azioni di management essenziali (stop tunnel, revoke device, reset session) così l'utente può controllare tutto senza aprire un terminale o modificare file.

Origin del problema osservato: dopo il pair dall'iPhone, l'app dice "connessione stabilita" ma dal Panel l'utente non vede niente → non sa se è davvero connesso, in che modalità, né come disconnettere.

## Decisioni architetturali

1. **Nuova tab "Connections"** nell'`index.html` esistente. Non creiamo un'app separata — rimaniamo nell'estetica e tab-structure già presente (Stato, Configurazione, Browsers, Workers, Log, **Connections**).
2. **Polling 3s** invece di WebSocket live-push — il Panel ha già un pattern polling per Status tab. Mantenere consistenza, più semplice, sufficiente per la scala (1 utente personale).
3. **In-memory ring buffer** per richieste recenti (ultime 100) — non persistiamo su disco, questa è UI live, per audit persistente c'è già `bridge.log` + `state.json`.
4. **Azioni destructive** (revoke, rotate secret) richiedono conferma popup — preveniamo errori fatali.
5. **Nessuna auth sul Panel** — resta loopback-only come già è (`panel.js` binda `127.0.0.1`).

## Acceptance Criteria

### AC-1 — Nuova tab Connections
- [ ] Tab "Connections" visibile tra le tab esistenti in `03_HARNESS/server/public/index.html`
- [ ] Click attiva il pannello senza ricaricare la pagina (behavior esistente `data-tab`)
- [ ] Polling ogni 3 secondi su nuovo endpoint `GET /api/panel/connections`

### AC-2 — Tunnel status card (sempre visibile in tab)
- [ ] Mostra: modalità corrente (quick/named/lan/manual), URL pubblico (se presente), uptime cloudflared, restart count, last error
- [ ] Icona stato colorata: verde = up, grigia = off, rossa = error
- [ ] Pulsante "Stop tunnel" (conferma popup) → chiama `/api/setup/manual`
- [ ] Pulsante "Restart tunnel" (no conferma) → stop + start stessa modalità

### AC-3 — Active WebSocket clients
- [ ] Lista dei WebSocket `/ws/ios/stream` attualmente connessi: deviceId, connected_since (durata), remoteAddress (IP visto da Node)
- [ ] Vuota quando nessuno è connesso, con stringa chiara "Nessun client WS connesso"
- [ ] Pulsante "Disconnect" per device (force-close WS) — utile per debug

### AC-4 — Known devices
- [ ] Lista dei deviceId noti = union di: config.ios.allowed_device_ids + chiavi di `logs/sessions.json` + `apns/tokens.json`
- [ ] Per ogni device: deviceId, last_seen (dall'`last_active_at` di sessions), APNS registered (sì/no), session attiva (sì/no)
- [ ] Pulsante "Revoke" (conferma popup) → aggiunge deviceId a `config.ios.blocked_device_ids` (nuovo campo) + chiude WS attivi + cancella sessione
- [ ] Pulsante "Reset session" → cancella session_id dal sessions.json + chiude WS → la prossima richiesta parte da zero

### AC-5 — Recent requests log (ring buffer)
- [ ] Tabella delle ultime 50 richieste servite su `/api/ios/*`
- [ ] Colonne: timestamp (HH:MM:SS), deviceId (primi 8 char), method + path, status code, latency_ms
- [ ] Error rows evidenziate in rosso
- [ ] Click su riga espande dettagli: full deviceId, full URL, full request body preview (primi 500 char), response snippet
- [ ] Ring buffer in-memory da 100 entries, aggiornato dal middleware request logger

### AC-6 — Backend endpoint `GET /api/panel/connections`
- [ ] Risposta aggrega: tunnel status + WS clients + known devices + recent requests
- [ ] Loopback-only (già default del panel)
- [ ] Risposta sotto 50ms p95 (data già in RAM, nessuna lettura disco nel path hot)
- [ ] Schema JSON stabile documentato nel file

### AC-7 — Backend action endpoints
- [ ] `POST /api/panel/tunnel/stop` → chiama cloudflared.stop() + setMode('manual'). Ritorna nuovo status.
- [ ] `POST /api/panel/tunnel/restart` → chiama cloudflared.stop() + restart nella modalità precedente
- [ ] `POST /api/panel/ws/:deviceId/close` → chiude tutti WS per deviceId
- [ ] `POST /api/panel/device/:deviceId/revoke` → aggiunge a blocked_device_ids + chiude WS + reset session
- [ ] `POST /api/panel/device/:deviceId/reset-session` → rimuove da sessions.json + chiude WS
- [ ] Tutti loopback-only

### AC-8 — Request logger middleware
- [ ] Nuovo `server/request-log.js`: ring buffer + middleware logger
- [ ] Si attacca a tutte le richieste `/api/ios/*` PRIMA di handleIosRequest
- [ ] Cattura: ts, deviceId (da Bearer check o body), method, path, status, latency
- [ ] Buffer size 100, eviction FIFO

### AC-9 — Blocking middleware (revoke funziona)
- [ ] `ios-auth.js` estende check Bearer per rifiutare deviceId nel blocked list
- [ ] Revoca ha effetto immediato (nessun caching)

### AC-10 — UI feedback on actions
- [ ] Ogni pulsante ha stato loading durante l'azione
- [ ] Toast di conferma su successo
- [ ] Error box con messaggio chiaro su failure

## Implementation Plan

### Backend (harness server)

**B1 — Request ring buffer + middleware** · NEW `03_HARNESS/server/request-log.js`
- Export `logRequest({deviceId, method, path, status, latencyMs})` → push in array, cap 100
- Export `recentRequests()` → return snapshot (most recent first)
- Export `wrapRequestHandler(handler)` → returns wrapped handler che misura latenza + deviceId + status e chiama logRequest
- **Stima**: 45min

**B2 — Tunnel status aggregator** · modifica `03_HARNESS/server/api/setup.js`
- Expose helper `getTunnelSnapshot()` che ritorna `{ mode, publicUrl, uptime_s, restartCount, lastError, cloudflaredPid }`
- Restart count letto da `cloudflared-manager.js` — aggiungere counter incrementale lì
- **Stima**: 30min

**B3 — WS clients introspection** · modifica `03_HARNESS/server/api/ios-stream.js`
- Export `activeClients()` che ritorna `[{ deviceId, connected_since, remote_address }]`
- Track `connected_since` as `ws._connectedAt = Date.now()` al joinRoom
- **Stima**: 30min

**B4 — Known devices aggregator** · NEW `03_HARNESS/server/api/panel-connections.js`
- Helper `knownDevices()`:
  - Leggi `logs/sessions.json` → deviceId + last_active_at
  - Leggi `apns/tokens.json` → deviceId che hanno APNS token
  - Leggi `config.ios.allowed_device_ids` (se usato) + blocked_device_ids
  - Merge per deviceId, fill fields
- **Stima**: 1h

**B5 — Panel API router** · NEW `03_HARNESS/server/api/panel-connections.js` (stesso file di B4)
- Export `handlePanelRequest(req, res, { cfg, cfgPath })` che dispatches su path `/api/panel/*`
- Endpoints:
  - `GET /api/panel/connections` → aggrega tunnel + ws + devices + recent requests
  - `POST /api/panel/tunnel/stop`
  - `POST /api/panel/tunnel/restart`
  - `POST /api/panel/ws/:deviceId/close`
  - `POST /api/panel/device/:deviceId/revoke`
  - `POST /api/panel/device/:deviceId/reset-session`
- **Stima**: 2h

**B6 — Wire in server.js** · modifica `03_HARNESS/server/server.js`
- Import handlePanelRequest
- Call before handleIosRequest, after handlePair + handleSetup
- Also wrap handleIosRequest con wrapRequestHandler per logging
- **Stima**: 20min

**B7 — Blocking logic in ios-auth** · modifica `03_HARNESS/server/api/ios-auth.js`
- checkBearer estende check: se deviceId è in `config.ios.blocked_device_ids`, rifiuta con 403 + code `DEVICE_REVOKED`
- **Stima**: 20min

### Frontend (Panel UI)

**F1 — Nuova tab Connections** · modifica `03_HARNESS/server/public/index.html`
- Aggiungi `<button class="tab" data-tab="connections">Connections</button>` nella nav
- Aggiungi `<section id="tab-connections" class="panel">...</section>` con quattro sub-card: Tunnel · WS clients · Devices · Requests
- **Stima**: 45min (HTML structure + placeholder styling)

**F2 — CSS** · modifica `03_HARNESS/server/public/style.css`
- Styling per tabella requests (mono font, row hover, error-red highlight)
- Styling per device row con action buttons
- Status pill colors (green/gray/red)
- **Stima**: 30min

**F3 — JS client** · modifica `03_HARNESS/server/public/app.js`
- Funzione `loadConnections()` che fetcha `/api/panel/connections` e renderizza le 4 card
- Polling 3s quando tab è attiva (pause quando altra tab selezionata)
- Handler click per azioni: stop/restart tunnel, disconnect, revoke, reset-session
- Popup conferma nativo `confirm()` per azioni destructive
- Toast di feedback (fade-in/out top-right)
- **Stima**: 2h

### Test + polish

**T1 — Smoke test end-to-end**
- Manual: avviare Quick Tunnel → pair iPhone → verifica comparsa in Connections → disconnetti WS → verifica rimozione
- Azioni: revoke → prossima richiesta da quel deviceId riceve 403
- **Stima**: 1h

**Totale**: ~9h backend+frontend + 1h test = **~10h**

## Risks and Mitigations

| Rischio | Probabilità | Impatto | Mitigazione |
|---|---|---|---|
| Ring buffer in-memory perde dati al restart | Alta | Basso | È voluto (è UI live, per persistent audit c'è bridge.log). Documentato. |
| Revoke applicato ma WS non si chiude subito | Media | Medio | `revoke` chiama esplicitamente `closeWs(deviceId)` nello stesso endpoint |
| Utente clicca "Rotate secret" per errore → tutti i device disconnessi | Bassa | Alto | Non incluso in questo plan — rotate secret differita a sottofase futura |
| Polling ogni 3s consuma risorse se Panel resta aperto tutto il giorno | Bassa | Basso | Payload piccolo (<5KB), polling pause quando altra tab selezionata |
| `blocked_device_ids` in config.json read/write race | Bassa | Basso | Lock file-based non necessario a questa scala; write atomic (writeFileSync) |
| Action endpoints exposed senza auth in caso di bug loopback | Bassa | Alto | Double-check loopback in every action handler; test con request esterna → deve dare 403 |

## Verification Steps

**Setup**: harness + panel running, iPhone pair via Quick Tunnel come da flusso Phase 5.

**Test cases**:
1. ✓ Apro `/` del Panel → clicco tab "Connections" → vedo tunnel mode + URL + uptime corretti
2. ✓ Vedo WS client vuoto → riapro app iPhone → nel giro di 3s compare WS client
3. ✓ Vedo device nel Known devices con last_seen recente
4. ✓ Invio messaggio da iPhone → compare nella tabella Requests con status 200
5. ✓ Spegne harness lato Claude (timeout) → compare in Requests con status 500 rosso
6. ✓ Click "Disconnect" su WS → app iPhone riceve close, si riconnette automaticamente (heartbeat)
7. ✓ Click "Revoke device" con conferma → prossima richiesta da quel iPhone ha 403 DEVICE_REVOKED
8. ✓ Click "Stop tunnel" → cloudflared termina, modalità torna a "manual", card tunnel diventa grigia
9. ✓ Click "Restart tunnel" con quick attivo → stop+start, nuovo URL appare
10. ✓ Polling non genera spam log (no "GET /api/panel/connections 200" flood)

## Open Questions / Follow-ups

- **WebSocket per live updates invece di polling**: futuro, quando il panel avrà bisogno di <1s latency
- **Grafi storici**: richieste per ora, errori per ora — rimandato a v2 (scope analytics)
- **Rotate secret**: azione dedicata con warning extra, rimandata
- **Multi-user view**: quando GIGI avrà più utenti su stessa harness (non ora)
- **Export logs button**: utile per debug condiviso, rimandato

## Dependencies

- No new npm packages required
- Reuses existing `bonjour-service`, `qrcode`, `ws`
- No iOS changes — tutto server-side + web
