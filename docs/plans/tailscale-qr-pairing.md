# Tailscale + QR Pairing

**Status**: Draft · **Owner**: Armando · **Scope**: iOS app (Settings/onboarding) + harness Node (panel + new `/api/pair` endpoint) · **User setup**: Tailscale install on PC + iPhone

## Requirements Summary

Rimuovere completamente la necessità per l'utente di digitare Base URL e Bearer secret per collegare l'app GIGI al backend Harness. Sostituire con una procedura di pairing che:

1. **Funziona da qualsiasi rete** (casa, 4G/5G, hotel, Barcellona) — grazie a Tailscale come layer di networking privato cifrato
2. **Richiede zero typing** — un QR code generato dall'harness viene scansionato dall'app
3. **È una-tantum** — salvataggio in Keychain, nessuna riconfigurazione successiva
4. **Rileva connection loss** con messaggio chiaro che spiega se ri-pairare o verificare Tailscale
5. **È pronta per migrazione VPS** — quando l'harness passa a VPS, si rigenera il QR e si riscannerizza, senza modifiche app-side

## Decisioni architetturali

### Networking: Tailscale
- Free tier (100 device personali)
- WireGuard sotto il cofano, cifratura E2E
- IP stabili `100.x.y.z` che funzionano da qualsiasi rete del mondo
- Alternativa scartata: port forwarding (insicuro, complesso), Cloudflare Tunnel (URL instabile gratuito), reverse SSH a VPS (setup più elaborato, utile come V2 se e quando si sposta sul VPS)

### Pairing: QR code
- Backend espone `GET /api/pair` che restituisce un payload JSON firmato
- Panel a `localhost:7777/pair` visualizza il QR con istruzioni
- App iOS usa `DataScannerView` (VisionKit, iOS 16+) per scansionare
- Payload: `{ url, secret, deviceName, createdAt }` codificato JSON

### Rotazione secret
- Il QR espone sempre il secret **corrente** del config.json
- Rigenerare il QR NON ruota il secret (utile per pairing di più device)
- Comando CLI separato `npm run rotate-secret` (futuro) per rotazione attiva

## Acceptance Criteria

### AC-1 — Tailscale setup end-to-end
- [ ] PC: Tailscale installato, login completato, IP `100.x.y.z` stabile
- [ ] iPhone: app Tailscale installata, stesso account, IP `100.x.y.z` stabile
- [ ] `ping 100.x.y.z` dal PC al Tailscale IP dell'iPhone risponde
- [ ] Dal browser del PC: `http://<tailscale-iphone-ip>` timeout normale (iPhone non espone server)
- [ ] Dal iPhone Safari: `http://<tailscale-pc-ip>:7779/api/ios/health` (senza Bearer) restituisce 401 Unauthorized

### AC-2 — Backend `/api/pair` endpoint
- [ ] `GET http://localhost:7779/api/pair` ritorna HTTP 200 con payload:
  ```json
  { "url": "http://100.x.y.z:7779", "secret": "...", "deviceName": "Armando-PC", "createdAt": "2026-04-24T19:00:00Z" }
  ```
- [ ] L'URL nel payload usa il **Tailscale IP auto-rilevato** del PC, non `localhost` né `192.168.x.x`
- [ ] Endpoint **non richiede Bearer** (serve per bootstrappare il Bearer stesso)
- [ ] Endpoint è **accessibile solo da localhost** (binding loopback o check `req.socket.remoteAddress`) per evitare che chiunque sulla Tailscale possa estrarre il secret

### AC-3 — Panel pagina `/pair`
- [ ] Browser su PC: `http://localhost:7777/pair` mostra il QR visivamente (librerie `qrcode` Node o JS client-side)
- [ ] Pagina include: QR, URL leggibile (per debug), secret parzialmente oscurato (primi 4 + ultimi 4 char), istruzioni in italiano
- [ ] Tasto "Rigenera QR" (no-op, ricarica pagina) e "Copia URL" per debug
- [ ] Pagina funziona solo con `localhost:7777` (Panel è loopback)

### AC-4 — iOS Info.plist permessi camera
- [ ] `NSCameraUsageDescription` aggiunto a `Info.plist` con testo: "GIGI usa la fotocamera per leggere il QR code del tuo Harness backend."
- [ ] Build iOS continua a firmare regolarmente via Sideloadly

### AC-5 — iOS QR scanner view
- [ ] Nuovo file `GigiPairScanner.swift` con `DataScannerView` wrapper SwiftUI
- [ ] Scanner riconosce solo QR code (non barcode generici)
- [ ] Al primo avvio chiede permesso camera → se negato, mostra prompt "Vai in Impostazioni → GIGI → Camera"
- [ ] Scan riuscito → callback con `String` (payload raw QR)

### AC-6 — Pairing flow + validation
- [ ] Scanner → parse JSON → estrae `url`, `secret`, `deviceName`
- [ ] Validazione URL: deve iniziare con `http://` o `https://`, contiene `:7779` (o qualsiasi porta se valida)
- [ ] Salva in `GigiKeychain` (chiavi esistenti: `harnessBaseURL`, `harnessSecret`); genera nuovo `harnessDeviceID` se non esiste
- [ ] Esegue `GigiHarnessClient.shared.health()` → se OK salva e dismissa sheet, se FAIL mostra errore "Impossibile raggiungere il server. Verifica Tailscale attivo."
- [ ] Successo: toast verde "Connesso ad Armando-PC ✓", banner in Settings aggiornato

### AC-7 — Settings entry
- [ ] In `SettingsView`, nella sezione Harness, sostituire i due TextField con un singolo pulsante **"Pair con Harness"** che apre lo scanner
- [ ] Sotto il pulsante: stato corrente (device paired + ultimo successo health) o "Non configurato"
- [ ] Pulsante secondario "Rimuovi pairing" cancella i valori Keychain
- [ ] TextField manuali conservati come **opzione Advanced** espandibile (per debug / setup non-QR)

### AC-8 — Onboarding primo avvio
- [ ] All'app launch, se Keychain non ha `harnessBaseURL`: mostra banner top "👋 Collega GIGI al tuo PC Harness" con CTA "Pair ora"
- [ ] CTA apre direttamente lo scanner (stesso flow di Settings)
- [ ] Dopo primo pair: banner sparisce, non riappare finché l'utente non rimuove il pair

### AC-9 — Connection loss UX
- [ ] Quando `GigiClaudeBridge.run` fallisce con `.transport` (Tailscale down / harness down): errore utente include riga "🔌 Controlla Tailscale attivo su PC e iPhone"
- [ ] Settings mostra stato `⚠️ Non raggiungibile` quando l'ultimo health check ha fallito (retry ogni 5 minuti in foreground)

## Implementation Plan

### Backend (harness Node)

**B1 — Dep `qrcode`** · file: `03_HARNESS/server/package.json`
- Installa `qrcode` (terminal client + encoder): `npm install qrcode`
- Aggiorna lock file

**B2 — Endpoint `GET /api/pair`** · file NUOVO: `03_HARNESS/server/api/pair.js`
- Export async handler `handlePair(req, res, { cfg })`
- Check `req.socket.remoteAddress === '::1' || === '127.0.0.1'` — else return 403
- Auto-rileva Tailscale IP: scan `os.networkInterfaces()` per interfaccia `Tailscale` o IP `100.x.y.z`
- Fallback a `cfg.server.host` se no Tailscale trovato (per dev locale)
- Ritorna `{ url, secret, deviceName: os.hostname(), createdAt: new Date().toISOString() }`
- Registra route in `server.js` (entry point HTTP) prima del router iOS

**B3 — Panel pagina `/pair`** · file: `03_HARNESS/server/panel-routes.js` + nuovo `03_HARNESS/server/public/pair.html`
- Handler in `panel-routes.js`: serve `public/pair.html`
- HTML statico con `<div id="qr"></div>` + `<script>` che fa fetch `/api/pair` (stesso origin:7777 → proxy interno al 7779 o chiamata diretta... vedi nota sotto)
- Uso libreria `qrcode` lato server: ritorna PNG o SVG già renderizzato via `/api/pair?format=svg`
- Mostra anche URL, secret parzialmente oscurato, host

**Nota tecnica**: Panel gira su 7777, API iOS su 7779. Il Panel può semplicemente chiamare `http://localhost:7779/api/pair` lato client (stesso host), quindi CORS va aperto per `localhost:7777` sull'endpoint `/api/pair`.

### iOS app

**I1 — Info.plist camera** · file: `02_GIGI_APP/GIGI/Info.plist`
- Aggiungi chiave `NSCameraUsageDescription` con valore italiano

**I2 — Scanner SwiftUI wrapper** · file NUOVO: `02_GIGI_APP/GIGI/GigiPairScanner.swift`
- `struct GigiPairScannerView: UIViewControllerRepresentable` (fallback) o usa direttamente `DataScannerView` iOS 16+
- Prop `onScan: (String) -> Void`
- Gestisce permessi via `AVCaptureDevice.requestAccess(for: .video)` prima di avviare scan

**I3 — Pairing sheet view** · file NUOVO: `02_GIGI_APP/GIGI/GigiPairingSheet.swift`
- SwiftUI view presentata come sheet
- State machine: `.scanning` → `.validating` → `.success(deviceName)` | `.failure(String)`
- Logica: parse JSON, valida, salva Keychain, chiama health
- Pulsante "Riprova" su failure

**I4 — Settings integration** · file: `02_GIGI_APP/GIGI/SettingsView.swift`
- Sostituisci `harnessSection` attuale con nuova versione: pulsante grande "Pair con Harness" + stato + "Rimuovi pairing"
- TextField manuali dietro disclosure group "Configurazione manuale (advanced)"

**I5 — Onboarding banner** · file: `02_GIGI_APP/GIGI/GIGIApp.swift` o `MainTabView.swift`
- Osserva `GigiHarnessClient.shared.isConfigured` al launch
- Se false: mostra banner in cima (ZStack top) con CTA → apre `GigiPairingSheet` direttamente

**I6 — Connection loss hint** · file: `02_GIGI_APP/GIGI/GigiClaudeBridge.swift`
- Nel case `.transport`: appendi alla stringa "Harness irraggiungibile. Verifica che il server sia acceso" la frase "Controlla Tailscale attivo su PC e iPhone" (solo se l'URL salvato inizia con `100.`)

### User setup (documentazione, no codice)

**U1 — Doc onboarding Tailscale** · file NUOVO: `docs/guides/tailscale-setup.md`
- Step-by-step screenshot-driven: install su PC Windows, login, verifica IP; install su iPhone, login stesso account, verifica IP nell'app Tailscale
- Una tantum, impegno utente ~10 min

## Risks and Mitigations

| Rischio | Probabilità | Impatto | Mitigazione |
|---|---|---|---|
| Utente non capisce perché deve installare Tailscale | Alta | Alto | Doc onboarding con screenshot + CTA "Perché serve?" nell'app che apre un mini-spiegone |
| Tailscale IP del PC cambia a ogni avvio | Bassa | Medio | Tailscale assegna IP stabile per device in modo permanente; in caso contrario usare `tailscale-name.ts.net` MagicDNS (sempre stesso hostname) |
| `/api/pair` espone secret a chiunque su Tailscale → leak | Media | Critico | Endpoint binda solo su loopback (127.0.0.1); chiunque sul Tailscale non può raggiungerlo; scan QR richiede accesso fisico al Panel sul PC |
| Utente perde il PC / reinstalla → tutti i secret cambiano | Bassa | Medio | Il QR re-generato espone il secret nuovo; basta riscanareggiare dall'iPhone; nessun dato perso |
| iOS 17+ DataScannerView non disponibile su device simulato | Bassa | Basso | Fallback a `AVCaptureSession` classico; testare su device fisico fin da subito |
| Tailscale ACL bloccano la porta 7779 | Bassa | Medio | Default Tailscale permette tutto tra device dello stesso account; ACL servono solo in team setup |
| QR scan in camera scarsa (notte, zoom) | Bassa | Basso | QR ridondanza media-alta (error correction level H), contenuto < 300 byte |

## Verification Steps

**Pre-condizioni**:
1. Tailscale installato su PC + iPhone, entrambi con stesso account
2. Harness in esecuzione su `100.x.y.z:7779` (binding `0.0.0.0` come già fatto)
3. Panel su `localhost:7777` in esecuzione

**Test manuali end-to-end**:
1. ✓ Apro browser PC → `localhost:7777/pair` → vedo QR ben formato + URL corretto Tailscale
2. ✓ Apro GIGI iPhone (app fresh install) → banner top "Collega GIGI" visibile → tap → camera si apre chiedendo permesso
3. ✓ Inquadro QR → validazione in corso → toast verde "Connesso ad Armando-PC ✓"
4. ✓ Settings → sezione Harness mostra "Pair attivo · Armando-PC · ✓ online"
5. ✓ Chat funzionante (test già validato in Phase 1)
6. ✓ Disabilito Wi-Fi iPhone, uso solo 4G/5G → test query ask_claude funziona identico
7. ✓ Sposto iPhone in Bluetooth-only (no internet) → errore chiaro "🔌 Controlla Tailscale"
8. ✓ Riattivo connessione → scrollback chat intatto, prossima query funziona
9. ✓ Tap "Rimuovi pairing" → Keychain pulito, banner top riappare, scan di nuovo funziona

## Open Questions / Follow-ups

- **Multi-device pairing**: un utente con 2 iPhone (es. personale + lavoro) può scansionare lo stesso QR? Sì, il secret è condiviso, ma il `harnessDeviceID` generato lato iOS è diverso → l'harness li distingue per deviceId nel path. Nessun cambiamento architetturale. Documentare.
- **Rotazione secret**: non incluso in MVP. Futuro: comando `npm run rotate-secret` che rigenera il secret + invalida tutti i pair. Gli iPhone beccano 401, mostrano banner "Secret rotato, ri-pair".
- **Biometric lock sul sheet di pair**: in production potrebbe valere la pena richiedere Face ID prima del pair per evitare pair malevoli (es. qualcuno fa screenshot del QR e si pair da remoto). Nota: il QR è comunque accessibile solo da chi ha fisicamente accesso al PC dell'utente (endpoint loopback-only).
- **Migrazione VPS**: quando l'harness si sposta su VPS, il QR avrà `url` con il Tailscale IP del VPS (o un dominio pubblico HTTPS). Nessun cambio lato app. La nuova "Panel" sul VPS serve la pagina `/pair` identica.

## Dependencies

- **Backend**: `qrcode` npm package (nuovo)
- **iOS**: VisionKit framework (già disponibile in SDK, zero dep aggiuntive)
- **User**: Tailscale account + app su PC + app su iPhone (esterno, free)
- **No breaking changes** lato iOS esistente: TextField manuali restano come advanced
