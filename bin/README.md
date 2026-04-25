# GIGI — Launcher scripts (Windows)

Scripts pronti per testare GIGI senza ricordare comandi a memoria. Numerati per ordine d'uso. Doppio click dall'Explorer, o lanciati da qualsiasi terminale.

## TL;DR — flusso tipico

1. **`1_START_ALL.bat`** → avvia harness + panel + apre il wizard nel browser
2. Nel wizard scegli **Quick Tunnel** (test veloce) o **Named Cloudflare** (serio, con dominio)
3. **`5_OPEN_PAIR_QR.bat`** → apri la pagina QR e scansiona dall'app GIGI iOS
4. Usa GIGI
5. A fine giornata: **`2_STOP_ALL.bat`** (opzionale — puoi lasciare tutto acceso)

---

## Cosa fa ogni script

| Script | Scopo | Quando usarlo |
|---|---|---|
| `1_START_ALL.bat` | Avvia harness (7779) + panel (7777) in background + apre `/setup` | Prima cosa quando riaccendi il PC |
| `2_STOP_ALL.bat` | Kill di tutti i `node.exe` e `cloudflared.exe` | Quando vuoi fermare tutto (rare — meglio lasciare acceso) |
| `3_STATUS.bat` | Check veloce: porte in ascolto, health harness, stato tunnel, processi cloudflared | Quando qualcosa sembra non funzionare |
| `4_OPEN_SETUP.bat` | Apre `localhost:7777/setup` nel browser | Per cambiare modalità tunnel |
| `5_OPEN_PAIR_QR.bat` | Apre `localhost:7777/pair` nel browser | Per scansionare il QR dall'iPhone |
| `6_LOGS.bat` | Tail live del file `bridge.log` | Debug in tempo reale |

---

## Componenti in dettaglio

### Harness server (porta 7779)
- Processo: `node server.js` (in `03_HARNESS/server/`)
- API iOS (`/api/ios/*`) autenticate via Bearer
- WebSocket streaming per thoughts Claude (`/ws/ios/stream`)
- Endpoints loopback-only (localhost): `/api/pair`, `/api/setup/*`

### Panel server (porta 7777)
- Processo: `node panel.js` (in `03_HARNESS/server/`)
- Interfaccia web locale
- Serve due pagine: `/setup` (wizard) e `/pair` (QR code)
- Le pagine chiamano il harness su 7779 lato client

### Cloudflared (processo figlio)
- Avviato e controllato dall'harness quando scegli modalità tunnel
- Quick Tunnel: URL `*.trycloudflare.com` effimero
- Named Tunnel: URL `gigi.tuodominio.me` stabile
- Lanciato via binary in `~/.gigi/bin/cloudflared.exe`

---

## Flussi pratici comuni

### Test veloce (no dominio, URL temporaneo)
1. `1_START_ALL.bat`
2. Nel wizard → **"Avvia Quick Tunnel"**
3. Aspetta ~10 secondi che esca URL `trycloudflare.com`
4. `5_OPEN_PAIR_QR.bat` → QR con l'URL
5. Scansiona dall'app GIGI sull'iPhone
6. Usa. **Attenzione**: se riavvii PC/harness, URL cambia → ri-pair necessario

### Setup definitivo (URL stabile, con dominio proprio)
Prerequisito: dominio aggiunto alla tua zone Cloudflare (puoi comprarlo in 3 min su [dash.cloudflare.com/registrar](https://dash.cloudflare.com/?to=/:account/registrar) tipo `.me` a ~€9/anno).

1. `1_START_ALL.bat`
2. Nel wizard → **"☁️ Cloudflare Tunnel + dominio"** → Step 1 "Login su Cloudflare"
3. Si apre browser, fai login, autorizza
4. Torna sulla tab setup → inserisci hostname (es. `gigi.tuodominio.me`) → **"Crea tunnel + DNS"**
5. Dopo ~15s: tunnel attivo, URL permanente
6. `5_OPEN_PAIR_QR.bat` → QR con l'URL stabile
7. Scansiona dall'app iPhone
8. **Da questo momento**: funziona per sempre. PC spento o acceso, casa o 4G — quando il PC è acceso, GIGI risponde.

### Torna alla modalità manuale (se vuoi disattivare tunnel)
1. Nel wizard → card "Manuale" → **"Imposta come modalità attiva"**
2. cloudflared si ferma
3. L'iPhone torna a usare URL/secret che hai in Settings (flow Phase 4)

---

## Troubleshooting rapido

- **"localhost refused to connect"** al caricamento `/setup` → manca il panel. Lancia `1_START_ALL.bat` o `3_STATUS.bat` per diagnosi.
- **Quick Tunnel fallisce con `spawn EBUSY`** → cloudflared già in uso. Lancia `2_STOP_ALL.bat` + `1_START_ALL.bat`.
- **`/api/setup/named/configure` → error DNS** → il dominio base non è nella tua zone Cloudflare. Verifica su `dash.cloudflare.com/<account>/<domain>` che sia "Active".
- **QR scan non va in chat** → URL nel QR non raggiungibile dall'iPhone. Prova `curl <url>/api/ios/health` dal PC stesso — se va ma dal telefono no, controllare connessione internet iPhone.

---

## Cosa manca (P5.10 — service installer)

Oggi devi lanciare `1_START_ALL.bat` manualmente ad ogni riavvio del PC. Quando implementeremo P5.10 (service installer) harness + panel + cloudflared partiranno automaticamente al boot e questi script serviranno solo per debug. Per ora conviveteci: è una `.bat` sul desktop.

---

## File paths chiave

- Harness server code: `03_HARNESS/server/`
- Config con secret: `03_HARNESS/server/config.json` (git-ignored)
- Log runtime: `03_HARNESS/server/logs/bridge.log`
- cloudflared binary: `~/.gigi/bin/cloudflared.exe`
- Cloudflare cert (dopo login): `~/.cloudflared/cert.pem`
- Tunnel config YAML: `~/.gigi/cloudflared-<uuid>.yml`
- QR ipa app iOS: `bug/GIGI.ipa`
