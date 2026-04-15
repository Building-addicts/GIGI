# Inventario Completo Workspace GIGI

Totale file nel workspace: **933**

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
