# GIGI — Componenti per Funzione

> Fonte di verità "quale file fa cosa" raggruppato **per funzione/feature**, non per path.
> Per layout fisico delle cartelle: `CLAUDE.md` §Layout monorepo.
> Per architettura concettuale: `docs/Architecture-Armando-Revision.md`.

---

## 📱 iOS App (`02_GIGI_APP/GIGI/`)

### Entry & shell
- `GIGIApp.swift` — entrypoint SwiftUI
- `GigiAppDelegate.swift` — delegate UIKit (push, lifecycle)
- `MainTabView.swift` — root tabs + banner pairing viola
- `ChatView.swift` — interfaccia chat con assistente
- `DashboardView.swift` — dashboard / stato rapido
- `SettingsView.swift` — impostazioni (harness section, brain mode)

### Auth & login
- `GigiLoginView.swift` — schermata login
- `GigiAuthManager.swift` — sessione / Google Sign-In
- `client_*.googleusercontent.com.plist` — config Google Sign-In
- `GIGI.entitlements` — entitlements app principale

### Audio & Voice
- `GigiAudioManager.swift` — AVFAudio session, ducking
- `GigiAudioSequestrator.swift` — pipeline audio
- `GigiVADEngine.swift` — voice activity detection

### NLU & Intent (on-device)
- `GigiNLUEngine.swift` — parsing input utente
- `GigiNLU.mlmodel` / `GigiNLU_Transformer.mlpackage` — modello CoreML
- `GigiEntityExtractor.swift` — estrazione entità da testo
- `gigi_labels.json` — labels NLU
- `GigiDialogueEngine.swift` — dialogo multi-turno
- `GigiImplicationEngine.swift` — inferenze sugli intent

### Agent Engine (V3 "True Agent")
- `GigiAgentEngine.swift` — agent loop (max 5 iter, parallel function-calling)
- `GigiOrchestrator.swift` — orchestrazione comandi
- `GigiSmartOrchestrator.swift` — orchestrazione avanzata
- `GigiBrainPipeline.swift` — pipeline cervello (Groq vs Claude)
- `GigiBrainDiagnostics.swift` — diagnostica brain
- `GigiFoundationAgent.swift` / `GigiFoundationSession.swift` — Apple Foundation Models (iOS 18+)

### Bridge Claude (delegation)
- `GigiClaudeBridge.swift` — coordinator + buildContextSnapshot + run() streaming
- `GigiHarnessClient.swift` — HTTP client harness (Bearer)
- `GigiHarnessStream.swift` — WebSocket /ws/ios/stream
- `GigiCloudService.swift` — Gemini cloud client

### Tool registry & action execution
- `GigiToolRegistry.swift` — 38 tool dichiarati + AskClaudeTool + meta-classifier
- `GigiActionBridge.swift` — bridge azioni iOS/intents
- `GigiActionDispatcher.swift` (+ `+Native.swift`, `+Web.swift`) — dispatch concreta
- `GigiShortcutGenerator.swift` — shortcuts automatici
- `GigiAutoSender.swift` — invio automatico/fallback messaggi
- `GigiContactsEngine.swift` — accesso contatti
- `GigiHomeKit.swift` — scenari HomeKit

### Computer-use (browser remoto)
- `GigiComputerUse.swift` — client computer-use verso harness

### Memoria & profilo utente
- `GigiMemory.swift` — memoria semantica (recall/recent)
- `GigiConversationMemory.swift` — history chat (.user/.gigi/.thinking/.toolEvent)
- `GigiKeychain.swift` — Keychain wrapper (harnessBaseURL, harnessSecret)

### Confirm & safety
- `GigiConfirmationPolicyEngine.swift` — confirm mode (pagamenti/azioni costose)
- `GigiFallbackEngine.swift` — fallback su errore

### Pairing iPhone↔harness
- `GigiPairScanner.swift` — VisionKit DataScannerViewController wrapper
- `GigiPairingSheet.swift` — state machine pairing (scan → validate → Keychain → health)
- `GigiMDNSDiscovery.swift` — discovery LAN

### Diagnostics & logging
- `GigiCommandLogger.swift` — log comandi
- `GigiDebugLogger.swift` — debug logger remoto
- `GigiApnsSync.swift` — sync APNS token

### UI ancillari
- `GigiLiveActivityController.swift` / `GigiActivityAttributes.swift` — Live Activities
- `Assets.xcassets/` — icone, accent color
- `Info.plist` (incluso `NSCameraUsageDescription` per QR)

### Siri Intents extension (`02_GIGI_APP/GigiIntents1/`)
- `IntentHandler.swift` — handler intents
- `Info.plist`, `GigiIntents1.entitlements`

### Build & MDM
- `GIGI.xcodeproj/` — progetto Xcode (schemes GIGI + GigiIntents1)
- `GIGI_Accessibility_MDM.mobileconfig` — profilo MDM accessibility
- `README_SETUP.md` — setup specifico app iOS

---

## 🟦 Harness Backend Node (`03_HARNESS/`)

### Quick reference
- `CLAUDE.md` — indice memoria harness
- `README.md` — quick start Mac + deploy VPS
- `docs/api/ios-integration.md` — spec endpoint completa
- `docs/memory/context.md` — contesto statico harness

### Sessions & Claude runner (`server/`)
- `server.js` — entrypoint, HTTP+WS iOS, orchestratore
- `paths.js` — path costanti (env override VPS-ready)
- `logger.js` — log shared
- `session-manager.js` — sessioni Claude per deviceId
- `claude-runner.js` — spawn CLI Claude + streaming + parallel task
- `queue.js` — code richieste + cancel + tracking child
- `rate-limit.js` — recovery rate limit + interrupted state
- `memory-snapshot.js` — `/memo` auto snapshot
- `transcript-mirror.js` — backup JSONL Claude per device

### iOS API (porta 7779) — `server/api/`
- `ios-router.js` — router /api/ios/* + Bearer + CORS
- `ios-auth.js` — middleware Bearer
- `ios-agent.js` — POST agent/run + cancel + session + memo
- `ios-stream.js` — WebSocket /ws/ios/stream + broadcast room
- `ios-memory.js` — put / query / delete / all (wrap memory/store.js)
- `ios-computer-use.js` — loop Anthropic SDK + Playwright driver
- `ios-push-register.js` — APNS token register/unregister
- `ios-push-test.js` — push smoke test
- `pair.js` — GET /api/pair (loopback-only, JSON o SVG QR)

### Admin Panel (porta 7777)
- `server/panel.js` — HTTP admin UI, spawna server come child
- `server/panel-routes.js` — route handler hot-reloadable
- `server/bridge-rpc.js` — RPC loopback (porta 7778) panel↔server
- `server/public/pair.html` — pagina QR pairing
- `Control Panel.url` — shortcut Windows al panel

### Watchers (worker proattivi)
- `server/watchers.js` — runtime worker + action push_apns
- `server/watchers.json` — watcher default (morning-briefing, meeting-prep)
- Hot-reload: `POST /api/watchers/<id>/toggle` su porta 7777

### Memoria semantica (`memory/`)
- `store.js` — API astratta MemoryStore (put/query/delete/all)
- `backends/json-store.js` — MVP JSON file per userId
- `logs/` (gitignored) — storage per-user
- Upgrade futuro v4 LanceDB+BGE-M3 progettato in `memory-upgrade/`

### Computer-use & Browser pool (`browser-pool/`)
- `driver.js` — API diretta computer-use (lease/release + Playwright CDP)
- `server.js` — MCP Puppeteer pool Chrome (legacy, ancora usato per watcher)
- `server-playwright.js` — variante MCP Playwright

### APNS (`apns/`)
- `send.js` — sendPush/sendToDevice/broadcastToAll, HTTP/2 + JWT ES256, no deps esterne
- `tokens.json` (gitignored) — device token per userId

### Memory upgrade (design only, non implementato)
- `memory-upgrade/README.md` — indice
- `memory-upgrade/research/` — findings, prior-art, dialogue
- `memory-upgrade/single-user/` — piani v1→v4.2
- `memory-upgrade/multi-user-v1/` — branch attivo (10 utenti, federated fine-tuning)

### Config & runtime
- `server/config.example.mac.json` + `config.example.json` — template Mac/Windows
- `server/.env.example` — template env
- `server/start.sh` / `start.bat` / `start_hidden.vbs` / `kill.sh` / `kill.ps1` — script avvio
- `server/logs/` (gitignored) — sessions.json, state.json, transcripts/, computer_use_jobs.json, cost_tracking.json

---

## 🟨 MDM Server (`01_SERVER_MDM/`)

Server Node per distribuzione profili MDM iOS (accessibility).

- `server.js` — server Node distribuzione profili
- `gigi_profile.mobileconfig` + `gigi_profile_signed.mobileconfig` — profili MDM
- `certs/gigi_identity.p12`, `cert.pem`, `key.pem` — identità firma
- `public/index.html` — pagina locale server
- `package.json` + `.env`, `.gitignore`
- `README.md` — setup specifico

---

## 🌐 Web statics (deploy)

- `public/index.html` — pagina pubblica
- `public/deploy/manifest.plist` — manifest OTA install
- `public/profiles/gigi_access_pro.mobileconfig` — profilo pubblico
- `web/index.html` + `web/deploy/manifest.plist` + `web/profiles/` — versione alternativa
- `web/nginx-mobileconfig.conf` + `web/nginx-killsiri.xyz.conf` — vhost nginx
- `vercel.json` — config Vercel + `.vercelignore`

---

## 🛠 Root tooling

- `start-harness.sh` — launcher root → `03_HARNESS/server/start-all.sh`
- `bin/` — tooling root
- `gigi_labels.json` — labels NLU globali
- `.gigi-secret.txt` (gitignored) — harness Bearer locale (rotato)

---

## 📚 Documentazione (`docs/`)

- `README.md` — indice docs
- `GETTING_STARTED.md` — onboarding utente (pairing, sideload)
- `TASK_PLAN.md` — piano task corrente (autoritativo)
- `Architecture-Armando-Revision.md` — paper architettura "True Agent" V3 rev. 2
- `PIANO_INTEGRAZIONE_HARNESS.md` — piano integrazione backend
- `TEST_E2E.md` — scenari test E2E
- `COMPONENTS.md` — questo file
- `memory/` — memoria progetto condivisa (PROJECT, CONTEXT, DECISIONS, CODE_MAP, ACTIVITY_LOG)
- `plans/` — piani per fase (cloudflare, tailscale, claude bridge, …)
- `research/` — finding tecnici (pairing landscape 2026, …)
- `archive/` — doc storiche (TASK_PLAN_V3 superato)
