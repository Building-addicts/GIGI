# Runbook — Pair iPhone con harness

> Quando ti serve: primo setup di un device, oppure dopo un re-deploy del tunnel.
> Tempo: ~1 min.
> Owner: chiunque.

## Prerequisiti

- Harness in esecuzione sul PC (`./start-harness.sh` dalla root o `node panel.js` in `03_HARNESS/server/`)
- Tunnel attivo (Cloudflare Quick / Named, mDNS LAN, o Tailscale)
- App GIGI installata sul device (vedi `runbooks/build-ipa.md`)

## Procedura

### 1. Avvia il tunnel

Apri `http://localhost:7777` → tab **Setup** → seleziona modalità tunnel:

| Modalità | Quando | Setup |
|---|---|---|
| **Cloudflare Quick Tunnel** ⭐ | Default MVP | One click — URL ephemeral |
| **Cloudflare Named Tunnel** | URL stabile | Account Cloudflare + dominio |
| **LAN (mDNS)** | Stessa Wi-Fi | Zero config |
| **Tailscale** | P2P/E2E | Tailscale install su entrambi i device |

Atteso entro 15 s: URL pubblico mostrato in panel.

### 2. Diagnostica

Sul panel **Setup** scorri ai 10 check (Claude CLI, secret strength, tunnel up,
outbound HTTPS, disk space). Tutto il **rosso** ha bottone "Auto-fix" o comando da
copiare. Risolvi prima di proseguire.

### 3. Genera QR

Apri `http://localhost:7777/pair`. Mostra QR con URL pubblico + secret one-time.
Lascia il tab aperto.

### 4. Scansiona dal device

Apri GIGI su iPhone. Banner viola in alto → **Connect GIGI to your PC** → camera →
inquadra il QR.

L'app:
1. Legge URL + secret
2. Salva in iOS Keychain (`harnessBaseURL`, `harnessSecret`)
3. Chiama `/api/ios/health` → check verde
4. Esegue diagnostica device-side
5. Bottone **Finalize pair** → banner sparisce

### 5. Verifica

Sul panel `localhost:7777` → tab **Connections** → device deve apparire con stato
**Active**. Manda un messaggio dall'app: arriva nei log harness in real-time.

## Errori noti

| Sintomo | Causa | Fix |
|---|---|---|
| Banner pairing resta viola dopo finalize | Race su persistence | Force-quit + reopen app |
| "Harness unreachable" dopo un po' | Quick Tunnel URL cambiato (restart cloudflared) | Re-pair con QR fresco; per stabile usa Named Tunnel |
| Camera nera nello scanner | Permesso negato | Impostazioni → GIGI → Camera |
| Diagnostica fallisce su `WS check` | Cloudflare 100s timeout | Verifica heartbeat lato server |

## Revoca un device

Panel `localhost:7777` → tab **Connections** → device → **Revoke**. La prossima
richiesta da quel device riceve `403 DEVICE_REVOKED`.

## Vedi anche

- `docs/adr/0001-pairing-cloudflare-tunnel-mvp.md`
- `docs/research/pairing-landscape-2026.md`
- `03_HARNESS/server/api/pair.js` (endpoint loopback-only)
