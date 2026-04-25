# Cloudflare Tunnel Pairing (GIGI 2026)

**Status**: Draft · **Owner**: Armando · **Replaces**: `docs/plans/tailscale-qr-pairing.md` (Phase 4 — retained as "advanced mode" fallback)

## Requirements Summary

Integrare Cloudflare Tunnel come trasporto primario per permettere all'iPhone di raggiungere il harness GIGI sul PC dell'utente **da qualsiasi rete nel mondo** (casa, 4G/5G, hotel, estero) senza che l'utente installi applicazioni extra, senza port forwarding, senza VPN da configurare manualmente.

**Target UX**:

1. User scarica "GIGI Harness Installer" (singolo .exe/.dmg/.AppImage con `cloudflared` bundled)
2. Prima esecuzione apre un wizard locale su `localhost:7777/setup`
3. Wizard fa login Cloudflare OAuth (30 secondi), guida eventuale acquisto dominio, configura tunnel, genera QR
4. User scansiona QR dall'app GIGI iOS
5. Da qui in avanti: sempre connesso, da ovunque, zero setup

**Modalità supportate** (l'utente sceglie al primo avvio):

- **A. Cloudflare Tunnel Named (raccomandato)** → URL stabile `https://gigi.<userdomain>` — richiede dominio (~€3-10/anno)
- **B. Cloudflare Quick Tunnel (dev)** → URL effimero `trycloudflare.com` — zero account, zero dominio, URL cambia a ogni restart
- **C. LAN-only** (mDNS/Bonjour) → zero config, funziona solo sulla stessa Wi-Fi di casa
- **D. Manuale/Tailscale** → modalità avanzata, lascia all'utente mettere URL+secret (il lavoro Phase 4 attuale)

Le modalità convivono nello stesso codice; user sceglie una o passa da una all'altra in ogni momento.

## Decisioni architetturali

### Perché Cloudflare Tunnel e non Tailscale (default)

Dal report ricerca `docs/research/pairing-landscape-2026.md`:

- **Zero client iOS da installare** — Cloudflare edge è il punto di ingresso, l'iPhone parla HTTPS/WSS come qualsiasi altra app
- **Unmetered free tier forever** — nessun limite banda, nessun count device
- **Stable dependency** — Cloudflare esiste da 15+ anni, non è startup early-stage
- **cloudflared è single binary** — bundling nell'installer GIGI è banale
- **WebSocket nativi** — TLS 1.3 end-to-end, l'harness non cambia codice
- **Path VPS-ready** — quando l'utente sposta harness su VPS, stesso cloudflared, stesso codice

### Trade-off noti

- **Cloudflare termina TLS all'edge di default** — i metadati del traffico e (nel caso Cloudflare Access) i contenuti sono visibili a Cloudflare. Per privacy massima resta Tailscale come "Priorità 2" modalità avanzata.
- **WebSocket idle timeout 100s** sul free tier — harness deve inviare heartbeat ogni 60-80s
- **Quick Tunnel URL instabile** — accettabile solo per dev/test, non per deploy quotidiano
- **Dominio proprio richiesto per Named Tunnel persistente** — unico attrito utente, mitigabile con guide passo-passo

### Non facciamo

- **NON hostiamo noi un relay condiviso** (violerebbe il modello "personal infrastructure")
- **NON rimuoviamo Tailscale/LAN dalle opzioni** — restano come alternative per chi non vuole Cloudflare
- **NON forziamo Cloudflare Access JWT** — optional per utenti che vogliono hardening extra

## Acceptance Criteria

### AC-1 — Setup wizard primo avvio (harness)

- [ ] Primo lancio harness → non trova config tunnel → apre browser su `http://localhost:7777/setup`
- [ ] Pagina setup presenta 4 opzioni (A/B/C/D) con descrizioni chiare italiano + inglese
- [ ] Pulsante "Skip setup" permette di usare modalità manuale sempre accessibile
- [ ] Wizard salva la scelta in `config.json → tunnel.mode` (named | quick | lan | manual)

### AC-2 — Bundle cloudflared nell'installer

- [ ] Installer Windows/macOS/Linux include `cloudflared` binary corretto per arch host (x64/arm64)
- [ ] Binary cloudflared estratto in cartella managed (`~/.gigi/bin/cloudflared`), non PATH globale
- [ ] Versione pinned (es. `2026.10.x`), upgrade via nostri release
- [ ] Docker image include cloudflared preinstallato

### AC-3 — Modalità A: Named Tunnel con dominio

- [ ] Wizard step 1: Cloudflare OAuth flow → token salvato in `~/.gigi/cloudflare-cert.json`
- [ ] Wizard step 2: input dominio (validation `*.xyz`, `*.com`, `*.me`, ecc.) + check che sia già aggiunto alla zona CF del user
- [ ] Se non aggiunto: UI mostra istruzioni con screenshot + link diretto a `dash.cloudflare.com/zones`
- [ ] Wizard step 3: crea tunnel programmaticamente via CF API `POST /accounts/{id}/cfd_tunnel`
- [ ] Wizard step 4: crea DNS record CNAME `gigi.<userdomain> → <tunnel-uuid>.cfargotunnel.com`
- [ ] Wizard step 5: avvia `cloudflared tunnel run gigi-<random>` come subprocess child del harness
- [ ] Registra cloudflared come servizio Windows (via NSSM) / LaunchAgent macOS / systemd Linux per auto-start
- [ ] QR visibile a `localhost:7777/pair` con `https://gigi.<userdomain>` + bearer

### AC-4 — Modalità B: Quick Tunnel

- [ ] Wizard scelta "dev mode" → avvia `cloudflared tunnel --url http://localhost:7779`
- [ ] Harness legge stdout del processo, estrae URL `*.trycloudflare.com`
- [ ] URL scritto in `~/.gigi/tunnel-current-url.txt`
- [ ] Pagina `localhost:7777/pair` mostra QR + banner giallo "URL temporaneo — cambia ad ogni restart"
- [ ] Al restart: nuovo URL, QR regenerato, banner "devi riscansionare sull'iPhone"

### AC-5 — Modalità C: LAN-only con mDNS

- [ ] Harness registra servizio Bonjour `_gigi._tcp.local` con porta 7779 e TXT record `{deviceName, bearer}`
- [ ] App iOS usa `NWBrowser` per scoprire il servizio sulla LAN
- [ ] Pair QR contiene hostname `.local` + bearer (funziona solo stessa subnet)
- [ ] Messaggio chiaro: "Funziona solo sulla stessa Wi-Fi. Per uso fuori casa, usa Cloudflare Tunnel."

### AC-6 — Modalità D: Manuale/Tailscale (Phase 4 retained)

- [ ] Tutto il flusso Phase 4 (URL+secret manuali, TextField advanced) resta disponibile sotto DisclosureGroup "Configurazione manuale"
- [ ] Documentazione aggiornata: "Se preferisci Tailscale o relay custom, usa questa sezione"

### AC-7 — WebSocket heartbeat (Cloudflare free tier limit)

- [ ] `GigiHarnessStream` (iOS) invia frame ping ogni 60s
- [ ] Harness Node risponde pong entro 5s
- [ ] Su 2 mancati pong consecutivi → reconnect
- [ ] Compatibile con Tailscale / LAN che non hanno questo limite (heartbeat innocuo)

### AC-8 — Configurazione persistente

- [ ] `config.json` include nuova sezione:
  ```json
  "tunnel": {
    "mode": "named" | "quick" | "lan" | "manual",
    "cloudflared_binary": "~/.gigi/bin/cloudflared",
    "named": {
      "tunnel_uuid": "...",
      "hostname": "gigi.userdomain.com",
      "cert_path": "~/.gigi/cloudflare-cert.json"
    },
    "quick": {
      "last_url": "...",
      "last_started_at": "..."
    }
  }
  ```
- [ ] Modifica `tunnel.mode` in runtime richiede restart cloudflared child process (no full harness restart)

### AC-9 — Observability + diagnostics

- [ ] Pannello `localhost:7777/setup/status` mostra:
  - Stato cloudflared: running/stopped/error
  - Hostname corrente pubblico
  - Latenza media (ping dal Cloudflare edge al harness)
  - Ultima connessione client (timestamp)
- [ ] Link "ripara tunnel" che restarta cloudflared se rotto
- [ ] Log cloudflared incluso nella cartella logs del harness per debug

### AC-10 — Migrazione da Phase 4 (Tailscale)

- [ ] User con config Phase 4 già funzionante non vede regression — Tailscale resta in "modalità manuale"
- [ ] Banner opzionale: "Vuoi provare Cloudflare Tunnel per reachability migliore?"
- [ ] Pulsante migra → wizard CF → mantiene pair già fatto come fallback

## Implementation Plan

### Phase 5 — Cloudflare Tunnel integration

_Estimated: 8-12 hours core + 4h QA · Depends on: Phase 4 code stays intact_

### Backend (harness Node)

**B1 — Bundle cloudflared + manager process**
- File: `03_HARNESS/server/tunnel/cloudflared-manager.js` (NEW)
- Scarica binary corretto per OS/arch al primo install, cache in `~/.gigi/bin/`
- Spawn process, cattura stdout/stderr, gestisce restart su crash
- API: `startNamed(tunnelUuid, config)`, `startQuick()`, `stop()`, `getStatus()`
- **Stima**: 2h

**B2 — Cloudflare API client**
- File: `03_HARNESS/server/tunnel/cf-api.js` (NEW)
- Wrapper minimo per endpoint CF necessari: tunnels CRUD, DNS records, zone list
- Usa cert OAuth salvato per auth
- **Stima**: 1.5h

**B3 — Setup wizard API endpoints**
- File: `03_HARNESS/server/api/setup.js` (NEW)
- `GET /api/setup/status` → stato attuale (mode configurato, tunnel up/down)
- `POST /api/setup/cloudflare/oauth` → avvia OAuth flow
- `GET /api/setup/cloudflare/callback` → riceve cert
- `POST /api/setup/named/configure` → crea tunnel + DNS
- `POST /api/setup/quick/start` → avvia quick tunnel
- `POST /api/setup/lan/start` → avvia mDNS mode
- `POST /api/setup/switch-mode` → cambia modalità a runtime
- **Stima**: 2h

**B4 — Setup wizard HTML page**
- File: `03_HARNESS/server/public/setup.html` (NEW)
- 4 card A/B/C/D come da AC-1
- Stepper wizard per opzione A (5 step guidati)
- Progress indicator, error handling chiaro
- **Stima**: 2h

**B5 — mDNS advertise (LAN mode)**
- Dep: `mdns-server` npm o `bonjour-service`
- Advertise `_gigi._tcp.local` con TXT record
- Deregister on shutdown
- **Stima**: 1h

**B6 — WebSocket heartbeat**
- File: `03_HARNESS/server/api/ios-stream.js` (modifica)
- Server risponde pong a ping client
- Cleanup connections inattive >120s
- **Stima**: 30min

### iOS app

**I1 — Setup wizard entry nell'app**
- `GigiPairingSheet.swift` (modifica)
- Quando QR payload contiene nuovo campo `mode`, scanner adatta UX:
  - `named` / `quick` / `manual` → stesso flow attuale
  - `lan` → avvia `NWBrowser` discovery parallelo invece di usare URL fisso
- **Stima**: 1h

**I2 — mDNS discovery iOS**
- File: `02_GIGI_APP/GIGI/GigiMDNSDiscovery.swift` (NEW)
- Usa `Network.framework` `NWBrowser` per scoprire `_gigi._tcp.local`
- Timeout 10s, fallback al URL esplicito del QR
- Permesso Info.plist: `NSBonjourServices` per `_gigi._tcp`
- **Stima**: 1.5h

**I3 — WebSocket ping/pong**
- `GigiHarnessClient.swift` / `GigiHarnessStream` (modifica)
- Timer 60s → invia `.ping`; su 2 mancati pong → reconnect
- **Stima**: 45min

**I4 — Info.plist Bonjour service**
- Aggiungi `NSBonjourServices` array con `["_gigi._tcp"]`
- **Stima**: 5min

### DevOps / Packaging

**D1 — Updater cloudflared binary**
- Script `03_HARNESS/server/tunnel/install-cloudflared.js` (NEW)
- Download appropriate release da GitHub cloudflare/cloudflared
- Verify checksum SHA256
- Estrae in `~/.gigi/bin/cloudflared`
- **Stima**: 45min

**D2 — Service installation (Windows/macOS/Linux)**
- File: `03_HARNESS/server/tunnel/service-installer.js` (NEW)
- Windows: NSSM wrapper o Windows Service native
- macOS: LaunchAgent plist in `~/Library/LaunchAgents/`
- Linux: systemd user unit in `~/.config/systemd/user/`
- Registra cloudflared + harness per auto-start al boot
- **Stima**: 2h

**D3 — Installer packaging** (future, post-MVP)
- Windows: MSI/NSIS con tutto bundled
- macOS: .dmg firmato con notarizzazione
- Linux: .deb + .AppImage
- **Stima**: ~1 giornata intera (rimandabile)

### Doc + UX

**X1 — Guida "Getting started con dominio"**
- File: `docs/guides/getting-a-domain.md` (NEW)
- Screenshots registrar (Porkbun, Cloudflare Registrar, Namecheap)
- Cambio nameserver CF step-by-step
- Stima: 1h

**X2 — Troubleshooting Cloudflare Tunnel**
- File: `docs/guides/cloudflare-tunnel-troubleshooting.md` (NEW)
- Errori comuni: DNS non propagato, tunnel non parte, WSS disconnect
- Log dove trovarli, come diagnosticare
- **Stima**: 1h

## Risks and Mitigations

| Rischio | Probabilità | Impatto | Mitigazione |
|---|---|---|---|
| Utente rinuncia al setup perché "devo comprare dominio" | Media-alta | Alto | Modalità B (Quick Tunnel) come "prova subito senza dominio"; Modalità C (LAN) come fallback per uso casa |
| Cloudflare cambia pricing free tier | Bassa | Alto | Opzione D (Tailscale manuale) sempre disponibile come escape; doc spiega alternative |
| `cloudflared` fallisce su Windows per antivirus / Defender | Media | Medio | Bundle da release ufficiale Cloudflare firmato; doc con istruzioni whitelist |
| OAuth Cloudflare flow cambia e rompe wizard | Bassa | Alto | Versione API usata pinnata in codice; monitoring, release patch se cambia |
| Utente chiude browser a metà wizard | Alta | Basso | Step sono idempotenti; può riprendere da dove aveva lasciato; config parziale scartata |
| WebSocket disconnect frequente su 4G instabile | Media | Medio | Auto-reconnect con backoff esponenziale; banner UI quando riconnesso |
| cloudflared subprocess crasha | Bassa | Medio | Manager restarta su crash, 3 tentativi poi errore UI con link "ripara" |
| DNS propagation lenta (>5 min) | Media | Basso | UI mostra progresso "propagazione DNS in corso" con poll + timeout 10 min |

## Verification Steps

**Pre-condizioni**:
- Harness fresh install su PC Windows + dominio `*.me` acquistato e aggiunto a CF
- iPhone con app GIGI sideloaded
- Test da 3 reti diverse (casa, 4G, hotspot telefono amico)

**Test manuali E2E**:

1. ✓ Fresh harness avvio → browser si apre su `localhost:7777/setup` automaticamente
2. ✓ Scelgo modalità A → click "Login Cloudflare" → OAuth completa in 30s
3. ✓ Inserisco dominio `arman.me` → wizard rileva zona non aggiunta → mostra istruzioni nameserver → cambio NS sul registrar
4. ✓ Wizard poll DNS → dopo ~2-5 min diventa green → avanti
5. ✓ Wizard crea tunnel + DNS record → `https://gigi.arman.me` attivo
6. ✓ Pair QR visibile → scan da iPhone → "Connesso a Armando-PC ✓"
7. ✓ Chat funziona su Wi-Fi casa
8. ✓ iPhone su 4G → chat continua a funzionare senza nulla
9. ✓ Riavvio PC → cloudflared autostart (servizio) → harness autostart → iPhone appena apre app riconnette in <5s
10. ✓ Spengo cloudflared manualmente → iPhone mostra "Harness irraggiungibile" → avvio → riconnette

**Test modalità B (Quick Tunnel)**:
- Seleziono dev mode → URL `trycloudflare.com` generato → pair → chat funziona
- Restart harness → URL cambia → banner "devi riscansionare" → riscansiono → ok

**Test modalità C (LAN mDNS)**:
- Seleziono LAN → iPhone scopre harness via Bonjour → pair → chat funziona
- Esco di casa con 4G → "Harness irraggiungibile" (atteso per LAN-only)

**Test migrazione Phase 4**:
- User con URL Tailscale già salvato → aprire GIGI → vede banner "prova Cloudflare" → skip → tutto continua a funzionare come prima

## Open Questions / Follow-ups

- **Cloudflare Access JWT per hardening**: opzionale, permette revocare pair specifici. Valutare in Phase 5.2.
- **Tunnel senza dominio (cfargotunnel.com)**: verificare se Cloudflare supporta ufficialmente in futuro — sarebbe il "vero magico" senza acquisto dominio. Monitor blog CF.
- **Auto-purchase dominio in-app**: integrare Cloudflare Registrar API per comprare direttamente — UX "apri e funziona" totale. Futuro v2.
- **Bandwidth usage monitoring**: aggiungere counter in harness per allertare se ci si avvicina a limiti TOS CF (~100GB/mese conservativo).
- **Multi-user / team mode**: se user vuole condividere GIGI con partner/famiglia → multi-pair sullo stesso harness. Gia supportato base (deviceID separati), serve solo UI dedicata.
- **Mobile carrier blocking**: alcuni operatori bloccano cfargotunnel.com? Test su TIM/Vodafone/Iliad.
