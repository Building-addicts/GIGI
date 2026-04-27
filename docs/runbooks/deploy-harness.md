# Runbook — Deploy harness su VPS

> Quando ti serve: muovere harness dal PC dell'utente a un server remoto sempre attivo.
> Tempo: ~30 min prima volta, ~5 min successive.
> Owner: chiunque tocchi infrastruttura.

## Prerequisiti

- VPS con Node.js v20+ e Chrome installato (Chromium se headless)
- `xvfb` se headless server (per computer-use visible)
- Reverse proxy davanti (nginx) con dominio + TLS
- Apple Developer account + APNS key `.p8` (per push)
- Anthropic API key (per computer-use)

## Procedura

### 1. Copia i sorgenti

```bash
rsync -av --exclude node_modules --exclude server/logs --exclude memory/logs \
  03_HARNESS/ <vps_user>@<vps_host>:~/gigi-harness/
```

### 2. Install deps (sul VPS)

```bash
ssh <vps_user>@<vps_host>
cd ~/gigi-harness/server && npm ci
cd ~/gigi-harness/browser-pool && npm ci
```

### 3. Configura `.env`

```bash
cat > ~/gigi-harness/server/.env <<EOF
HARNESS_SHARED_SECRET=$(openssl rand -hex 16)
ANTHROPIC_API_KEY=sk-ant-xxx
APNS_KEY_PATH=/etc/gigi/AuthKey_XXXX.p8
APNS_KEY_ID=XXXXXXXXXX
APNS_TEAM_ID=YYYYYYYYYY
APNS_BUNDLE_ID=com.gigi.app
APNS_PRODUCTION=true
EOF
chmod 600 ~/gigi-harness/server/.env
```

### 4. Configura process manager (pm2)

```bash
pm2 start server/server.js --name gigi-harness-server --cwd ~/gigi-harness
pm2 start server/panel.js  --name gigi-harness-panel  --cwd ~/gigi-harness
pm2 save
pm2 startup        # segui istruzioni stampate per autostart at boot
```

### 5. Reverse proxy nginx

```nginx
server {
  server_name harness.example.com;
  listen 443 ssl http2;

  # TLS via Let's Encrypt — obbligatorio per WSS su iOS ATS
  ssl_certificate /etc/letsencrypt/live/harness.example.com/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/harness.example.com/privkey.pem;

  location /api/ios/ { proxy_pass http://127.0.0.1:7779; }
  location /ws/ios/  {
    proxy_pass http://127.0.0.1:7779;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 3600s;
  }

  # Panel admin → blocca da internet, accessibile solo via VPN/SSH-tunnel
  location / { allow 10.0.0.0/8; deny all; proxy_pass http://127.0.0.1:7777; }
}
```

### 6. Verifica E2E

Da locale:

```bash
SECRET=$(ssh <vps_user>@<vps_host> 'grep HARNESS_SHARED_SECRET ~/gigi-harness/server/.env | cut -d= -f2')
curl -H "Authorization: Bearer $SECRET" https://harness.example.com/api/ios/health
# atteso: {"ok":true,...}
```

### 7. Aggiorna QR pairing

Re-pair i device puntando al nuovo URL (vedi `docs/runbooks/pair-iphone.md`).

## Errori noti

| Sintomo | Causa | Fix |
|---|---|---|
| `ECONNREFUSED 7779` | server.js non avviato | `pm2 logs gigi-harness-server` |
| WS si chiude ogni 60 s | nginx `proxy_read_timeout` default 60 | Setta `3600s` come sopra |
| computer-use crash silenzioso | manca xvfb | `apt install xvfb` + wrap pm2 con `xvfb-run` |
| iOS rifiuta connessione | TLS self-signed o cert non fidato | Usa Let's Encrypt, non self-signed |

## Rollback

```bash
ssh <vps_user>@<vps_host> 'pm2 stop gigi-harness-server gigi-harness-panel'
# l'app iOS mostra "Harness unreachable" finché non re-pair
```

## Vedi anche

- `03_HARNESS/README.md` §Deploy VPS
- `03_HARNESS/CLAUDE.md` §Environment variables
- `docs/adr/` — eventuali ADR sul deploy
