# Inventario Completo Workspace GIGI

Totale file nel workspace iOS+MDM: **933** (pre-assorbimento Harness).
Post assorbimento `03_HARNESS/`: aggiunti file sorgente Node (telegram-bridge ~13 file, browser-mcp ~8 file, memory-upgrade docs ~30 file). `node_modules` e `browser-profile/` esclusi via `.gitignore`.

Nota: la cartella `01_SERVER_MDM/node_modules` contiene **829 file** auto-generati dalle dipendenze npm; sono inclusi nell'inventario come blocco dedicato.

## Root

- `.DS_Store` - metadata Finder macOS.
- `.gitignore` - regole file ignorati da Git.
- `.vercel/README.txt` - note setup Vercel locale.
- `.vercel/project.json` - configurazione progetto Vercel.
- `.vercelignore` - esclusioni deploy Vercel.
- `vercel.json` - config deploy e routing Vercel.
- `gigi_labels.json` - labels globali per NLU.
- `INVENTARIO_COMPLETO.md` - questo inventario.

## 00_DOCS

- `00_DOCS/ARCHITETTURA.md` - documentazione architettura.

## GigiNLU_Transformer.mlpackage

- `GigiNLU_Transformer.mlpackage/Manifest.json` - manifest del pacchetto modello ML.

## 02_GIGI_APP

- `02_GIGI_APP/GIGI/GIGIApp.swift` - entrypoint app SwiftUI.
- `02_GIGI_APP/GIGI/MainTabView.swift` - tab principali dell'app.
- `02_GIGI_APP/GIGI/ChatView.swift` - interfaccia chat con assistente.
- `02_GIGI_APP/GIGI/DashboardView.swift` - dashboard e stato rapido.
- `02_GIGI_APP/GIGI/GigiLoginView.swift` - schermata di login.
- `02_GIGI_APP/GIGI/GigiAuthManager.swift` - gestione autenticazione/sessione.
- `02_GIGI_APP/GIGI/GigiOrchestrator.swift` - orchestrazione comandi.
- `02_GIGI_APP/GIGI/GigiSmartOrchestrator.swift` - orchestrazione avanzata.
- `02_GIGI_APP/GIGI/GigiDialogueEngine.swift` - motore dialogo multi-turno.
- `02_GIGI_APP/GIGI/GigiImplicationEngine.swift` - inferenze e implicazioni intent.
- `02_GIGI_APP/GIGI/GigiNLUEngine.swift` - parsing NLU input utente.
- `02_GIGI_APP/GIGI/GigiEntityExtractor.swift` - estrazione entita da testo.
- `02_GIGI_APP/GIGI/GigiVADEngine.swift` - voice activity detection.
- `02_GIGI_APP/GIGI/GigiAudioSequestrator.swift` - gestione pipeline audio.
- `02_GIGI_APP/GIGI/GigiActionBridge.swift` - bridge azioni iOS/intents.
- `02_GIGI_APP/GIGI/GigiShortcutGenerator.swift` - generazione shortcuts automatici.
- `02_GIGI_APP/GIGI/GigiAutoSender.swift` - invio automatico/fallback messaggi.
- `02_GIGI_APP/GIGI/Info.plist` - configurazione app iOS.
- `02_GIGI_APP/GIGI/GIGI.entitlements` - entitlements app principale.
- `02_GIGI_APP/GIGI/gigi_labels.json` - labels NLU locali app.
- `02_GIGI_APP/GIGI/client_828342254195-dnrgigjogu3veckt6ef177baie3vdrek.apps.googleusercontent.com.plist` - config Google Sign-In.
- `02_GIGI_APP/GIGI/Assets.xcassets/Contents.json` - indice asset catalog.
- `02_GIGI_APP/GIGI/Assets.xcassets/AppIcon.appiconset/Contents.json` - mapping icone app.
- `02_GIGI_APP/GIGI/Assets.xcassets/AccentColor.colorset/Contents.json` - colore accento UI.
- `02_GIGI_APP/GigiIntents1/IntentHandler.swift` - handler extension Siri Intents.
- `02_GIGI_APP/GigiIntents1/Info.plist` - config extension intents.
- `02_GIGI_APP/GigiIntents1/GigiIntents1.entitlements` - entitlement Siri extension.
- `02_GIGI_APP/GIGI_Accessibility_MDM.mobileconfig` - profilo MDM/accessibility.
- `02_GIGI_APP/GIGI.xcodeproj/project.pbxproj` - configurazione progetto Xcode.
- `02_GIGI_APP/GIGI.xcodeproj/project.xcworkspace/contents.xcworkspacedata` - workspace Xcode.
- `02_GIGI_APP/GIGI.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` - lock dipendenze SPM.
- `02_GIGI_APP/GIGI.xcodeproj/xcshareddata/xcschemes/GIGI.xcscheme` - scheme principale.
- `02_GIGI_APP/GIGI.xcodeproj/xcshareddata/xcschemes/GigiIntents1.xcscheme` - scheme extension.
- `02_GIGI_APP/GIGI.xcodeproj/xcuserdata/corte.xcuserdatad/xcdebugger/Breakpoints_v2.xcbkptlist` - breakpoints utente.
- `02_GIGI_APP/GIGI.xcodeproj/xcuserdata/corte.xcuserdatad/xcschemes/xcschememanagement.plist` - gestione schemi utente.

## 01_SERVER_MDM (core)

- `01_SERVER_MDM/server.js` - server Node per distribuzione profili.
- `01_SERVER_MDM/package.json` - dipendenze e script npm.
- `01_SERVER_MDM/package-lock.json` - lock dipendenze npm.
- `01_SERVER_MDM/.gitignore` - ignore locale server.
- `01_SERVER_MDM/.env` - variabili ambiente server.
- `01_SERVER_MDM/public/index.html` - pagina web locale server.
- `01_SERVER_MDM/gigi_profile.mobileconfig` - profilo MDM.
- `01_SERVER_MDM/gigi_profile_signed.mobileconfig` - profilo MDM firmato.
- `01_SERVER_MDM/certs/gigi_identity.p12` - certificato identita firma.
- `01_SERVER_MDM/certs/cert.pem` - certificato estratto PEM.
- `01_SERVER_MDM/certs/key.pem` - chiave privata estratta PEM.
- `01_SERVER_MDM/node_modules/.package-lock.json` - lock interno moduli.

## 01_SERVER_MDM/node_modules

- `01_SERVER_MDM/node_modules/**` - **829 file** di dipendenze npm (runtime, types, licenze, README, changelog e artefatti pacchetti come `dotenv`, `express`, `uuid`, ecc.).

## public

- `public/index.html` - pagina statica pubblica.
- `public/deploy/manifest.plist` - manifest OTA install.
- `public/profiles/gigi_access_pro.mobileconfig` - profilo mobileconfig pubblico.

## web

- `web/index.html` - pagina web alternativa.
- `web/deploy/manifest.plist` - manifest deploy web.
- `web/profiles/gigi_access_pro.mobileconfig` - profilo pubblicato via web.
- `web/nginx-mobileconfig.conf` - config nginx per mobileconfig.
- `web/nginx-killsiri.xyz.conf` - vhost nginx dominio.

## scripts

- `scripts/` - cartella presente ma senza file.

## 03_HARNESS

Sottosistema Node (ex repo `ArmandoBattaglino/Harness`, assorbito in GIGI). Espone telegram-bridge, browser MCP, memory-upgrade.

### 03_HARNESS root

- `03_HARNESS/CLAUDE.md` - indice memoria harness (entry point sessione Claude Code).
- `03_HARNESS/.gitignore` - ignore locale harness (config.json, browser-profile/, logs/, whisper-models/).
- `03_HARNESS/Control Panel.url` - shortcut Windows al pannello locale.

### 03_HARNESS/docs/memory

- `03_HARNESS/docs/memory/context.md` - contesto statico del progetto (struttura, regole critiche, watchers).

### 03_HARNESS/telegram-bridge

- `03_HARNESS/telegram-bridge/bridge.js` - processo principale Telegram ↔ Claude Code (~102k).
- `03_HARNESS/telegram-bridge/panel.js` - HTTP server control panel porta 7777.
- `03_HARNESS/telegram-bridge/panel-routes.js` - route HTTP pannello.
- `03_HARNESS/telegram-bridge/bridge-rpc.js` - RPC verso bridge.
- `03_HARNESS/telegram-bridge/watchers.js` - runtime worker autonomi periodici.
- `03_HARNESS/telegram-bridge/watchers.json` - definizioni watcher (leo-wa-terminal, tommy-wa-assistant).
- `03_HARNESS/telegram-bridge/transcribe.js` - whisper.cpp per voice note Telegram.
- `03_HARNESS/telegram-bridge/config.example.json` - template config (Windows paths originali).
- `03_HARNESS/telegram-bridge/.env.example` - template env vars.
- `03_HARNESS/telegram-bridge/package.json` + `package-lock.json` - deps npm.
- `03_HARNESS/telegram-bridge/start.bat` / `start_hidden.vbs` / `kill.ps1` / `watchdog.ps1` - script Windows.
- `03_HARNESS/telegram-bridge/public/` - asset statici panel web.
- `03_HARNESS/telegram-bridge/docs/` - docs interne bridge.

### 03_HARNESS/browser-mcp

- `03_HARNESS/browser-mcp/server.js` - server MCP Puppeteer pool Chrome.
- `03_HARNESS/browser-mcp/server-playwright.js` - variante Playwright.
- `03_HARNESS/browser-mcp/package.json` + `package-lock.json` - deps npm.
- `03_HARNESS/browser-mcp/PLAN*.md`, `FUTURE-PLAN.md` - design doc.

### 03_HARNESS/memory-upgrade

Progettazione nuovo sistema memoria (non ancora implementato).

- `03_HARNESS/memory-upgrade/README.md` - indice.
- `03_HARNESS/memory-upgrade/research/` - findings, prior-art, dialogue.
- `03_HARNESS/memory-upgrade/single-user/` - piani N=1 (v1 → v4.2).
- `03_HARNESS/memory-upgrade/multi-user-v1/` - BRANCH ATTIVO: 10 utenti + fine-tuning federated.
  - `plan-multi-user-v1.md` - architettura + 10 decisioni pendenti.
  - `gap-analysis.md` - 31 gap + severity matrix.
