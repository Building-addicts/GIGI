# Architettura Workspace GIGI

Ultimo aggiornamento: 2026-04-25

Questo documento descrive lo stato reale del workspace `GIGI-harness`: cosa contiene, come funziona l'app iOS, come funziona l'harness Node, quali pezzi sono collegati, quali sono legacy o incoerenti, quali rischi vanno chiusi e quali aree vanno stabilizzate per prime.
   
## 1. Visione del progetto

GIGI e' un assistente personale vocale per iPhone, pensato come agente operativo e non come semplice chatbot.

Obiettivo prodotto:

- l'utente parla a GIGI;
- GIGI capisce il comando;
- decide se rispondere, usare un tool nativo iOS, usare una web automation, o delegare al Mac/PC;
- esegue;
- parla la risposta;
- mantiene memoria e contesto;
- resta presente tramite wake word, Quick Talk, Presence Mode e Dynamic Island/Live Activity.

Il workspace ha due anime:

- **App iOS**: voce, UI, agent loop veloce, tool nativi, Dynamic Island, settings, memoria locale.
- **Harness Mac/PC**: backend Node locale/remoto che espone API, Claude CLI, browser automation, memoria server, APNS e canali esterni.

Schema mentale:

```text
iPhone GIGI
  -> Wake word / Quick Talk / Presence
  -> STT
  -> Agent loop Groq + tool calling
  -> Tool nativi iOS oppure Harness
  -> TTS
  -> Live Activity / Dynamic Island

Mac/PC Harness
  -> API iOS HTTP + WebSocket
  -> Claude CLI
  -> Playwright/Chrome
  -> Memory store
  -> APNS
  -> Setup panel + QR pairing
  -> Telegram/WhatsApp channel webhooks
```

## 2. Struttura root

```text
GIGI-harness/
  00_DOCS/
  01_SERVER_MDM/
  02_GIGI_APP/
  03_HARNESS/
  public/
  start-harness.sh
  Task per Speed to Taste Test to speech.md
  ARCHITETTURA_WORKSPACE_GIGI.md
```

### 00_DOCS

Contiene documentazione architetturale e piani:

- `ARCHITETTURA_V3.md`: visione "True Agent", agent loop, tool calling, memoria, web automation.
- `PIANO_INTEGRAZIONE_HARNESS.md`: piano fase per fase dell'integrazione iOS/harness.
- `TEST_E2E.md`: test end-to-end.
- `archive/`: materiale storico.

Nota: `ARCHITETTURA_V3.md` e' molto ambizioso e descrive anche parti future. Non tutto quello che descrive e' stabilizzato nel codice.

### 01_SERVER_MDM

Contiene un profilo `.mobileconfig` e README per automazione iOS via MDM.

Stato:

- utile come idea per espandere computer-use on-device;
- da verificare con device reale supervisionato;
- non e' un requisito per il core attuale: voce, brain, harness e Dynamic Island funzionano anche senza MDM.

Rischio:

- il README promette capacita' MDM molto forti, ma iOS standard non concede tap/screenshot cross-app liberamente a una normale app App Store;
- trattarlo come esperimento avanzato, non come dipendenza affidabile del prodotto.

### 02_GIGI_APP

App iOS Swift/SwiftUI.

Contiene:

- progetto Xcode `GIGI.xcodeproj`;
- target app `GIGI`;
- target widget/live activity `GIGIWidget`;
- config locale `Config.xcconfig`;
- template `Config.example.xcconfig`;
- setup README.

### 03_HARNESS

Backend Node.

Contiene:

- server HTTP+WS per iOS;
- panel admin;
- Claude CLI runner;
- computer-use con Playwright;
- browser pool;
- memoria JSON;
- APNS;
- pairing QR;
- diagnostica setup;
- canali Telegram/WhatsApp.

### public

Contiene materiale di deploy statico/Vercel. Non e' il cuore runtime dell'app.

### start-harness.sh

Launcher root:

```bash
./start-harness.sh
```

Esegue:

```text
03_HARNESS/server/start-all.sh
```

Serve a partire dalla root senza ricordarsi la cartella giusta.

## 3. App iOS: struttura principale

File principali in `02_GIGI_APP/GIGI/`.

### Avvio app

File: `GIGIApp.swift`

Responsabilita':

- inizializza debug logger;
- monta `MainTabView`;
- su app active sincronizza APNS;
- verifica silenziosamente sessione WhatsApp Web;
- avvia wake word listening;
- precarica memoria semantica;
- aggancia `GigiWebAgent` alla window;
- gestisce URL custom `gigi://`.

Flusso startup:

```text
GIGIApp.init
  -> flush crash logs
  -> MainTabView
  -> GigiBrainDiagnostics.log()
  -> GigiAudioManager.startWakeWordListening()
  -> GigiVectorStore.preload()
  -> GigiWebAgent.attach(window)
```

### UI principale

File: `MainTabView.swift`

Tab:

- `ChatView`: esperienza principale chat/voice.
- `Presence`: sessione lunga sempre presente.
- `DashboardView`: profilo/memoria/stato.
- `SettingsView`: chiavi, harness, wake word, privacy, debug.

In piu':

- onboarding overlay se `gigi.onboarding.complete` non e' true;
- sheet per `PresenceView`.

### Settings

File: `SettingsView.swift`

Contiene:

- chiavi Groq e Gemini;
- Connected Keys con usage locale;
- Brain Mode;
- Harness pairing/diagnostics;
- WhatsApp link;
- profilo utente;
- wake word;
- HomeKit;
- voce/TTS;
- privacy;
- debug.

Punto importante:

- usage chiavi = usage locale registrato da GIGI, non limite ufficiale provider;
- Groq e Gemini sono separati;
- Force Claude esiste nei settings, ma va verificato nel flusso runtime: la toggle e' salvata in Keychain, pero' l'agent loop principale oggi passa da `GigiAgentEngine.process` e non risulta un bypass completo automatico a `GigiClaudeBridge` in quel metodo.

## 4. Configurazione iOS

File:

- `02_GIGI_APP/Config.example.xcconfig`
- `02_GIGI_APP/Config.xcconfig`
- `02_GIGI_APP/GIGI/Info.plist`
- `02_GIGI_APP/GIGI/GigiConfig.swift`

Chiavi:

```xcconfig
GROQ_API_KEY =
GEMINI_API_KEY =
PICOVOICE_ACCESS_KEY =
GIGI_GATEWAY_ICLOUD_URL = https://www.icloud.com/shortcuts/...
```

Semantica:

- `GROQ_API_KEY`: cervello principale, tool calling, Groq vision, NLU cloud.
- `GEMINI_API_KEY`: realtime/native audio opzionale.
- `PICOVOICE_ACCESS_KEY`: wake word custom opzionale.
- `GIGI_GATEWAY_ICLOUD_URL`: link Shortcuts per gateway chiamate.

Priorita' lettura:

```text
Keychain
  -> Info.plist / xcconfig
  -> vuoto
```

Stato buono:

- `Config.xcconfig` e' ignorato da git;
- `Config.example.xcconfig` ha placeholder vuoti;
- `Info.plist` espone `GROQ_API_KEY`, `GEMINI_API_KEY`, `PICOVOICE_ACCESS_KEY`, `GIGI_GATEWAY_ICLOUD_URL`.

## 5. Entitlements e permessi iOS

File:

- `GIGI.entitlements`
- `Info.plist`
- `GIGIWidgetExtension.entitlements`

Entitlements principali:

- APNS development;
- HomeKit;
- iCloud/CloudKit;
- Siri;
- App Group `group.com.gigi.presence`;
- Live Activities.

Permessi Info.plist:

- microfono;
- speech recognition;
- contatti;
- calendari;
- promemoria;
- HomeKit;
- location;
- Siri;
- Apple Music;
- camera;
- local network;
- Bonjour `_gigi._tcp`;
- URL schemes per app esterne;
- background modes: audio, fetch, remote-notification, voip.

Rischi:

- `NSAllowsArbitraryLoads = true` abbassa la sicurezza ATS. Utile in dev per LAN/tunnel, ma in prod va ristretto.
- `UIBackgroundModes` include `voip`; se non c'e' vera integrazione VoIP, puo' essere fragile in review/prod.
- Live Activity e background audio hanno limiti reali iOS: Presence Mode puo' restare utile, ma va testato su device reale con schermo spento, Low Power Mode e sessione lunga.

## 6. Audio, wake word, STT e TTS

### GigiAudioManager

File: `GigiAudioManager.swift`

E' lo stato centrale audio:

```swift
idle
wakeWordListening
recording
speaking
```

Perche' e' importante:

- impedisce conflitti tra wake word, VAD/STT e TTS;
- ferma wake word prima di parlare;
- riattiva wake word dopo TTS se abilitata;
- Presence Mode puo' bypassare alcune soppressioni e usare delay diverso.

### GigiWakeWordEngine

Responsabilita':

- ascolta wake word;
- usa Picovoice/custom se disponibile;
- fallback interno se custom non configurato.

Da stabilizzare:

- log mostrava spesso `session activation failed` / `session not available`;
- serve test device reale con cuffie, speaker, schermo spento e app in foreground/background.

### GigiVADEngine

Responsabilita':

- usa `SFSpeechRecognizer`;
- registra microfono;
- rileva silenzio;
- produce transcript finale;
- chiama orchestrator.

Rischi:

- STT Apple puo' restituire final vuoto dopo partial validi;
- autorizzazioni speech/mic devono essere complete;
- audio session va coordinata con TTS e wake word.

### GigiSpeechService

Responsabilita':

- TTS voce GIGI;
- stop speaking;
- notifica audio manager quando inizia/finisce.

Da verificare:

- comportamento con Bluetooth;
- barge-in mentre GIGI parla;
- ritorno automatico a wake word.

### GigiRealtimeEngine

File: `GigiRealtimeEngine.swift`

Intento:

- WebSocket Gemini Live;
- input audio PCM 16 kHz;
- transcript realtime;
- tool call realtime;
- barge-in;
- idle disconnect per batteria.

Stato:

- esiste molta infrastruttura;
- `GigiBrainPipeline` lo usa come Level 0 solo per turni conversazionali/testuali;
- l'agent loop principale moderno usa Groq tool calling in `GigiAgentEngine`;
- Gemini key e' opzionale.

Da chiarire:

- se il realtime audio completo e' davvero collegato all'esperienza principale o solo predisposto;
- evitare doppio percorso brain: `GigiBrainPipeline` vs `GigiAgentEngine`.

## 7. Orchestrazione conversazione

### GigiSmartOrchestrator

File: `GigiSmartOrchestrator.swift`

E' il coordinatore alto livello:

```text
transcript
  -> process(text)
  -> memory.addUser
  -> pending confirmation?
  -> learn profile
  -> GigiAgentEngine.process
  -> handleResult
  -> TTS
  -> Live Activity
```

Responsabilita':

- riceve trascrizioni da `GigiAudioManager`;
- gestisce Quick Talk callbacks;
- gestisce Presence flag;
- gestisce conferme "si / procedi / conferma";
- aggiorna UI e memoria;
- parla la risposta;
- mostra banner.

Punto architetturale:

- i commenti parlano ancora di `GigiBrainPipeline`, ma il percorso principale attuale chiama `GigiAgentEngine`.
- `GigiBrainPipeline` resta nel progetto ma non sembra piu' il cuore del turno normale.

Da sistemare:

- aggiornare commenti/README per dire chiaramente che il brain principale e' `GigiAgentEngine`;
- decidere se `GigiBrainPipeline` resta come fallback o va rimosso/deprecato.

## 8. Cervello agentico

### GigiAgentEngine

File: `GigiAgentEngine.swift`

E' il core attuale.

Passi:

1. aggiunge turno utente a `GigiConversationMemory`;
2. costruisce history multi-turn;
3. recupera memory rilevante da `GigiMemory`;
4. usa `GigiPlannerEngine` per decomporre task complessi;
5. se task multi-dominio, esegue piano orchestrato;
6. altrimenti entra in agent loop;
7. seleziona tool rilevanti da `GigiToolRegistry`;
8. chiama Groq con tool declarations;
9. se Groq emette function call, esegue tool paralleli;
10. rimanda risultati al modello;
11. continua fino a risposta finale o safety lock;
12. gestisce confirm request.

Parametri:

- `maxIterations = 8`
- timeout fast: 20s
- timeout slow: 90s
- tool lenti: web, harness, computer-use.

Difese implementate:

- retry su tool hallucination `tool_use_failed`;
- retry/fallback modello su Groq 429;
- carry-forward dei tool gia' chiamati nella history;
- confirmation flow su azioni sensibili.

Rischi:

- confirmation mapping prende il primo tool call quando trova un confirm, non necessariamente quello che ha prodotto `requiresConfirm` se ci sono piu' tool paralleli;
- `web_order_food` nel registry ha `requiresConfirmation = false`, ma nella pratica dovrebbe sempre fermarsi prima di pagamento/ordine. Il confirm viene demandato al risultato testuale/harness, ma il metadata del tool e' incoerente;
- `Force Claude` settings non sembra integrato come bypass globale dentro `GigiAgentEngine.process`.

### GigiPlannerEngine

Scopo:

- decide se decomporre un task;
- produce subtask con domini: iOS, browser, research, calendar, messaging.

Uso:

- `GigiAgentEngine` lo usa come gate;
- se piano non semplice e ha task multipli/non iOS, route verso harness.

Da verificare:

- qualita' dei piani su input italiano;
- latenza;
- cosa succede se planner fallisce o produce domain sbagliato.

### GigiCloudService

File: `GigiCloudService.swift`

Provider reale attuale:

- Groq OpenAI-compatible endpoint.

Modelli:

- main: `llama-3.3-70b-versatile`;
- fast: `llama-3.1-8b-instant`.

Responsabilita':

- call con tools;
- parsing Groq response;
- NLU cloud;
- chat ask;
- usage locale chiavi.

Nota importante:

- esiste ancora metodo `processWithGemini`, ma e' un alias legacy che chiama Groq. Da rinominare per non confondere.

## 9. Tool e azioni

### GigiToolRegistry

File: `GigiToolRegistry.swift`

Dichiara tool disponibili al modello:

- chiamate;
- messaggi;
- navigazione;
- musica;
- reminder;
- eventi calendario;
- sveglie/timer;
- app opening;
- tempo/data/meteo;
- torch;
- FaceTime;
- media controls;
- calendario/free slot;
- news/search;
- email;
- Wi-Fi/Bluetooth;
- HomeKit;
- memoria;
- gruppi;
- WhatsApp Web;
- restaurant booking;
- food ordering;
- web search/read;
- web vision task;
- computer use;
- ask harness.

Selezione tool:

- sempre inclusi: `make_call`, `send_message`, `ask_time`, `ask_date`, `weather`;
- keyword/tag matching;
- se harness configurato, include sempre `ask_harness` con score alto;
- ritorna fino a 12 tool.

Rischio:

- commento dice "max 10", codice ritorna 12;
- includere sempre `ask_harness` puo' far delegare troppo facilmente task semplici al backend;
- tag matching puo' sbagliare italiano/inglese o misspelling.

### GigiActionDispatcher

File:

- `GigiActionDispatcher.swift`
- `GigiActionDispatcher+Native.swift`
- `GigiActionDispatcher+Web.swift`

Ruolo:

- prende tool call/intenti;
- valida parametri;
- gestisce disambiguazione contatti;
- applica foreground guard;
- divide per categoria;
- chiama bridge nativo, web agent o harness.

Categorie:

- communication;
- calendar;
- media;
- memory;
- system;
- HomeKit;
- web.

### GigiActionBridge

Esegue azioni iOS concrete:

- `tel://` e gateway Shortcuts;
- messaggi;
- WhatsApp fallback;
- Maps;
- Music/Spotify;
- calendar/reminders;
- weather/search/news;
- HomeKit;
- app deep links.

Rischi:

- molte azioni iOS richiedono foreground e conferme di sistema;
- Shortcuts gateway va installato e mantenuto;
- WhatsApp/iMessage possono essere limitati da UI e policy iOS.

## 10. Web automation iOS

### GigiWebAgent

File:

- `GigiWebAgent.swift`
- `GigiWebAgent+Vision.swift`

Responsabilita':

- WKWebView nascosta/attaccata alla window;
- navigazione siti;
- WhatsApp Web;
- form filling;
- screenshot/vision loop;
- automazioni on-device leggere.

Usi:

- WhatsApp Web;
- restaurant booking;
- food ordering fallback;
- web search/read;
- generic web vision task.

Problemi gia' visti:

- rate limit Groq vision;
- loop ripetuti su siti delivery;
- siti reali cambiano DOM, cookie, login, captcha;
- `execCommand` per contenteditable e' deprecato ma pratico per WhatsApp Web.

Direzione:

- per task web seri, preferire harness/Chrome;
- usare WKWebView come fallback o per task leggeri.

## 11. Harness client iOS

### GigiHarnessClient

File: `GigiHarnessClient.swift`

Legge da Keychain:

- base URL harness;
- bearer secret;
- device ID.

Endpoint gestiti:

- agent run/cancel;
- session status/reset;
- memo snapshot;
- memory put/query/delete/all;
- computer-use start/status/confirm;
- push register/unregister/test;
- status/health;
- diagnostics;
- autofix;
- WebSocket stream.

Pairing state:

- missing base URL;
- invalid base URL;
- missing secret;
- configured.

Da stabilizzare:

- retry/backoff su rete locale/tunnel;
- messaggi utente quando Local Network permission blocca `192.168.x.x`;
- differenziare LAN, Cloudflare tunnel, manual/Tailscale.

## 12. Pairing e diagnostica

File iOS:

- `GigiPairingSheet.swift`
- `HarnessQRScanner.swift`
- `SetupDiagnosticView.swift`
- `SetupDiagnosticWalkthroughs.swift`
- `HarnessStatusCard.swift`
- `GigiMDNSDiscovery.swift`

File server:

- `api/pair.js`
- `api/setup.js`
- `api/diagnostics.js`
- `api/autofix.js`
- `preflight/checks.js`
- `preflight/auto_fixers.js`
- `preflight/runner.js`
- `tunnel/*`

Flusso:

```text
Panel/harness genera QR
  -> iPhone scansiona
  -> salva baseURL + secret + deviceId
  -> diagnostics
  -> autofix dove possibile
  -> walkthrough utente dove non possibile
  -> finalize pair
```

Check diagnostic:

- Claude CLI installed;
- Claude CLI authenticated;
- bearer secret strength;
- tunnel mode active;
- tunnel running;
- cloudflared binary;
- outbound HTTPS;
- port 7779 bound;
- disk space;
- last request ago.

Stato recente:

- `SetupDiagnosticWalkthroughs.swift` aggiunge istruzioni mancanti per i check.
- Build iOS passa.

## 13. Live Activity, Dynamic Island e Presence

### GigiLiveActivityController

File: `GigiLiveActivityController.swift`

Gestisce:

- activity breve per listen/thinking/executing/done;
- presence activity lunga;
- update stato;
- end immediate;
- stale date.

### GIGIWidget

File:

- `GigiLiveActivityWidget.swift`
- `GigiWidget.swift`
- `GIGIWidgetBundle.swift`
- `GIGIWidgetControl.swift`
- `AppIntent.swift`

Dynamic Island:

- compact;
- minimal;
- expanded leading/center/trailing/bottom;
- URL tap `gigi://listen`.

App Group:

- `group.com.gigi.presence`;
- usato per comandi widget/app.

Da pulire:

- `AppIntent.swift` contiene ancora esempio "Favorite Emoji". Va rimosso o sostituito con intent reali GIGI.

### PresenceSessionController

File: `PresenceSessionController.swift`

Gestisce sessione lunga:

```text
inactive
  -> sleeping
  -> listening
  -> thinking
  -> speaking
  -> sleeping
```

Feature:

- timer durata;
- inactivity timeout 5 min;
- mute/unmute/stop;
- update Dynamic Island;
- wake word attiva durante sessione;
- osserva comandi da App Group.

Rischi:

- iOS puo' sospendere audio/background in condizioni reali;
- log precedenti mostravano session activation failure;
- serve test con schermo spento, blocco device, cuffie, speaker, Low Power Mode.

## 14. Quick Talk

File:

- `QuickTalkController.swift`
- `QuickTalkView.swift`
- `GigiQuickTalkIntent.swift`
- `QuickTalkCommandStore.swift`

Idea:

- "premi e parla";
- UI minimale listening/thinking/speaking;
- ottimo primo flusso da stabilizzare.

Runtime:

- `QuickTalkController` si aggancia alle callback di `GigiSmartOrchestrator`;
- `GigiSmartOrchestrator.startQuickTalk()` avvia recording;
- risultato torna in UI e TTS.

Da verificare:

- Action Button/App Intent se configurato su device;
- latenza dal tap alla registrazione;
- stato quando TTS sta ancora parlando.

## 15. Memoria

### Memoria iOS

File:

- `GigiMemory.swift`
- `GigiConversationMemory.swift`
- `GigiVectorStore.swift`
- `GigiUserProfile.swift`

Tipi:

- memoria conversazionale multi-turn;
- memoria lunga key/value;
- vettori locali per contacts/preferences/places;
- profilo utente.

Uso:

- `GigiAgentEngine` recupera memory block rilevantee lo mette nel system prompt ;
- `GigiConversationMemory` mantiene history e tool results;
- `GigiUserProfile` impara passivamente da testo.

Problemi:

- `GigiConversationMemory` ha ancora metodo/string context legacy da v2;
- CloudKit puo' fallire per quota o setup;
- serve separare bene memoria locale, CloudKit e memoria harness.

### Memoria harness

File:

- `03_HARNESS/memory/store.js`
- `03_HARNESS/memory/backends/json-store.js`
- `03_HARNESS/server/api/ios-memory.js`

Backend:

- JSON attuale;
- LanceDB previsto ma file backend non risulta presente nella lista runtime, mentre `store.js` prova a importarlo se `MEMORY_BACKEND=lancedb`.

Rischio:

- impostare `MEMORY_BACKEND=lancedb` puo' rompere se `backends/lancedb-store.js` non esiste.

## 16. Harness Node: runtime

### server.js

File: `03_HARNESS/server/server.js`

Avvia:

- lock anti doppia istanza;
- config;
- watchers;
- RPC loopback;
- HTTP iOS server;
- WebSocket server;
- channel router;
- panel route handlers.

Porte:

- `7777`: panel admin;
- `7778`: RPC loopback;
- `7779`: iOS HTTP+WS;
- `9224/9225/9226`: Chrome CDP profiles.

### ios-router

File: `server/api/ios-router.js`

Applica:

- CORS dev `*`;
- Bearer auth;
- route `/api/ios/*`.

Endpoint:

- agent;
- session;
- memo;
- memory;
- computer-use;
- push;
- status/health.

Rischio:

- CORS `*` va bene per dev, non per prod esposta;
- bearer secret e' l'unica protezione degli endpoint iOS.

### claude-runner

File: `server/claude-runner.js`

Responsabilita':

- spawn Claude CLI;
- gestire sessioni;
- resume;
- streaming eventi;
- rate limit/session not found recovery.

Config importante:

- `claude.bin`;
- `claude.model`;
- `permission_mode`.

Rischio:

- `permission_mode = bypassPermissions` e' potente e pericoloso se harness esposto;
- il bearer secret deve essere forte e il server non deve essere aperto pubblicamente senza TLS e auth robusta.

### queue e rate-limit

File:

- `queue.js`
- `rate-limit.js`

Funzioni:

- serializzazione per device;
- cancel;
- tracking child process;
- stato interrotto su rate limit;
- recovery.

## 17. Computer Use

File iOS:

- `GigiComputerUse.swift`

File server:

- `server/api/ios-computer-use.js`
- `browser-pool/driver.js`

Flusso:

```text
iOS POST /api/ios/computer-use
  -> crea job
  -> lease Chrome CDP
  -> Anthropic computer-use loop
  -> screenshot
  -> tool_use click/type/key/scroll
  -> confirm_required se checkout/pagamento
  -> iOS poll status
  -> result/confirm/error
```

Protezione pagamento:

- regex su totale/checkout/pay/place order;
- system prompt chiede di fermarsi prima di conferma pagamento;
- iOS riceve `CONFIRM_REQUIRED`.

Rischi:

- regex non basta come safety assoluta;
- serve hard stop tecnico sui click su pulsanti pagamento, non solo prompt;
- costi Claude/Anthropic stimati;
- richiede Chrome gia' avviato su CDP;
- richiede `ANTHROPIC_API_KEY`.

## 18. Browser pool

Cartella: `03_HARNESS/browser-pool`

Contiene:

- `driver.js`: usato direttamente da computer-use iOS;
- `server.js`: MCP Puppeteer legacy;
- `server-playwright.js`: MCP Playwright;
- piani futuri.

Stato:

- `driver.js` e' il percorso importante per computer-use attuale;
- `server.js` Puppeteer e' legacy;
- `server-playwright.js` puo' essere utile per Claude/MCP, ma va chiarito se e' usato in runtime.

Da pulire:

- rinominare `server.js` legacy come suggerito nei piani;
- documentare quale browser path e' ufficiale.

## 19. APNS e push

File:

- `GigiAPNSSync.swift`
- `GigiAppDelegate.swift`
- `server/api/ios-push-register.js`
- `server/api/ios-push-test.js`
- `apns/send.js`

Flusso:

```text
iPhone riceve APNS token
  -> GigiAPNSSync POST /api/ios/push/register
  -> harness salva token
  -> push test/watchers possono inviare notifiche
```

Problemi visti:

- errori `Local network prohibited` su `192.168.x.x`;
- serve permesso Local Network e pairing/tunnel corretto.

Rischi:

- `apns/tokens.json` contiene PII/device token ed e' ignorato da git;
- production/development APNS devono combaciare con provisioning.

## 20. Watchers proattivi

File:

- `server/watchers.js`
- `server/watchers.json`

Scopo:

- worker periodici;
- morning briefing;
- meeting prep;
- push APNS;
- task ricorrenti.

Regola architetturale:

- se l'utente chiede "metti in loop", creare watcher, non usare scheduling improvvisato.

Da verificare:

- budget watcher;
- rate limit Claude;
- sicurezza su task automatici;
- UI per attivazione/disattivazione.

## 21. Canali Telegram e WhatsApp

File:

- `server/api/channel-router.js`
- `server/channels/telegram.js`
- `server/channels/whatsapp.js`
- `server/audio/stt.js`
- `server/audio/tts.js`
- `server/identity/user-mapper.js`

Stato reale:

- il codice canali esiste;
- `server.js` monta `channel-router`;
- config template contiene `telegram` e `whatsapp`;
- README harness dice invece "Telegram rimosso completamente".

Questa e' una discrepanza da risolvere.

Possibili decisioni:

1. **Tenere canali esterni**: aggiornare README, settings e sicurezza.
2. **Rimuoverli davvero**: eliminare router, channels, config template e docs.
3. **Metterli dietro flag**: default off, documentati come experimental.

Rischi Telegram:

- webhook non verifica firma Telegram;
- sicurezza dipende dal segreto del bot token e dal fatto che endpoint non sia abusabile;
- import `createHmac` non usato.

Rischi WhatsApp:

- verifica firma solo se `app_secret` configurato;
- Business API richiede setup Meta serio;
- invio audio/TTS richiede OpenAI key nel server.

## 22. Onboarding

File:

- `OnboardingView.swift`
- `GigiPairingSheet.swift`
- `HarnessQRScanner.swift`

Percorso:

- setup chiavi;
- permessi;
- pairing harness;
- test diagnostici;
- completamento.

Da verificare:

- se onboarding riflette la separazione Groq/Gemini aggiornata;
- se l'utente capisce quando serve harness e quando no;
- se Local Network permission viene spiegato bene.

## 23. Dashboard

File:

- `DashboardView.swift`

Scopo:

- profilo utente;
- stato memoria;
- potenzialmente stato agent/task.

Da analizzare ulteriormente:

- quanto e' usato realmente rispetto a Settings;
- se duplica profile/settings;
- se conviene renderlo centro operativo o semplificarlo.

## 24. Sicurezza e privacy

### Cose buone

- chiavi iOS in Keychain;
- `Config.xcconfig` ignorato;
- `server/config.json`, `.env`, logs, memory logs, APNS tokens ignorati;
- bearer secret per `/api/ios/*`;
- pairing QR;
- confirm mode per pagamenti/distruttive;
- CloudKit/local fallback per memoria.

### Rischi da chiudere

1. **ATS permissivo**
   - `NSAllowsArbitraryLoads = true`.
   - In prod va limitato a domini/tunnel noti.

2. **CORS wildcard**
   - `Access-Control-Allow-Origin: *` nel router iOS.
   - Va bene in dev; in prod meglio restringere.

3. **Harness esposto**
   - Se `host=0.0.0.0` e tunnel pubblico, bearer secret e' critico.
   - Secret deve essere random forte, ruotabile, non loggato.

4. **Claude bypassPermissions**
   - Potente e rischioso.
   - Se un endpoint viene abusato, Claude puo' fare operazioni locali ampie.

5. **Telegram webhook**
   - Manca verifica robusta.
   - Va messo dietro secret path/header o rimosso.

6. **WhatsApp signature opzionale**
   - Se `app_secret` mancante, accetta webhook senza firma.
   - In prod va reso obbligatorio.

7. **Computer-use pagamento**
   - Safety via prompt/regex non basta.
   - Serve policy tecnica sui click finali e allowlist/denylist.

8. **MDM docs**
   - Rischiano di promettere piu' di quanto iOS consenta senza supervisione reale.

9. **Log runtime**
   - logs e transcripts possono contenere dati personali.
   - Sono ignorati da git, ma serve comando di cleanup e retention.

## 25. Parti legacy o da rimuovere/chiarire

### Candidati legacy

- `GigiBrainPipeline.swift`
  - Vecchio cascade Foundation/Gemini/Groq/local.
  - Il flusso normale usa `GigiAgentEngine`.
  - Decisione: tenerlo come fallback esplicito o rimuoverlo.

- `GigiCloudService.processWithGemini`
  - Nome ingannevole: chiama Groq.
  - Decisione: rinominare o eliminare.

- `GigiConversationMemory.historyString`
  - Commento dice legacy v2.
  - Decisione: rimuovere quando nessun caller lo usa.

- `browser-pool/server.js`
  - Puppeteer MCP legacy.
  - Decisione: rinominare `server-legacy-puppeteer.js` o rimuovere se non usato.

- `GIGIWidget/AppIntent.swift`
  - Esempio "Favorite Emoji".
  - Decisione: sostituire con intent reali o rimuovere.

- `README.md` harness su Telegram
  - Dice che Telegram e' rimosso, ma codice canale esiste.
  - Decisione: aggiornare docs o rimuovere codice.

- `01_SERVER_MDM`
  - Potenzialmente sperimentale.
  - Decisione: segnare experimental.

### Parti incomplete o fragili

- `MEMORY_BACKEND=lancedb`
  - `store.js` prova import `lancedb-store.js`, ma non risulta presente nel runtime.

- `Force Claude`
  - Settings salvano flag, ma non e' evidente un bypass globale nell'agent loop.

- `Auto Fallback to Groq`
  - Flag settings presente, integrazione runtime da verificare.

- `ComputerUseTool.requiresConfirmation`
  - true, corretto.
  - `WebOrderFoodTool.requiresConfirmation` false, incoerente con natura del task.

- Dynamic Island commands
  - App Group presente, controller osserva comandi, ma va testato sul widget reale.

- Realtime Gemini
  - Motore presente, ma flusso audio completo va verificato.

## 26. Flussi end-to-end da stabilizzare

### Flusso A: Quick Talk minimo

Obiettivo:

```text
utente apre Quick Talk / Action Button
  -> parla
  -> GIGI capisce
  -> risponde
  -> torna idle
```

Perche' prima:

- meno dipendenze;
- massimo valore immediato;
- debug piu' semplice.

Test:

- "che ore sono?"
- "chiama mamma"
- "mandami un promemoria tra 10 minuti"
- "com'e' il meteo?"

### Flusso B: Presence Mode

Obiettivo:

```text
utente avvia sessione
  -> Dynamic Island mostra sleeping
  -> "Hey GIGI"
  -> listening
  -> thinking
  -> speaking
  -> sleeping
```

Test:

- schermo acceso;
- schermo spento;
- Low Power Mode;
- speaker;
- AirPods/Bluetooth;
- sessione 10+ minuti.

### Flusso C: Harness pairing

Obiettivo:

```text
./start-harness.sh
  -> panel
  -> QR
  -> scan iPhone
  -> diagnostics
  -> ready
```

Test:

- LAN;
- Cloudflare quick tunnel;
- Tailscale/manual;
- secret rotation;
- Local Network permission negato/accettato.

### Flusso D: Web ordering safe

Obiettivo:

```text
"ordinami una pizza"
  -> harness/browser
  -> arriva al carrello
  -> STOP prima di pagare
  -> chiede conferma
```

Da rendere robusto:

- mai confermare ordine/pagamento senza approval;
- fallback chiaro su rate limit;
- evitare loop su sito;
- mostrare stato utente.

### Flusso E: WhatsApp/Telegram voice channel

Decisione prodotto:

- opzionale in settings;
- se attivo, deve essere documentato e sicuro;
- se non e' prioritario, tenerlo experimental o rimuoverlo.

## 27. Priorita' consigliata

### P0 - Stabilita' core voice

- Quick Talk;
- wake word;
- VAD/STT;
- TTS;
- audio session;
- "call mom" / "chiama mamma".

### P1 - Brain/tool reliability

- chiarire `GigiAgentEngine` vs `GigiBrainPipeline`;
- collegare davvero Force Claude o rimuovere toggle;
- normalizzare Groq/Gemini naming;
- test tool registry su italiano/misspelling.

### P2 - Harness setup

- pairing senza frizione;
- diagnostics;
- autofix;
- Local Network/tunnel errors chiari;
- status card.

### P3 - Presence/Dynamic Island

- sessione lunga;
- mute/unmute/stop;
- Dynamic Island tap `gigi://listen`;
- comandi widget.

### P4 - Web automation safe

- `ask_harness` come default per task web complessi;
- WKWebView fallback leggero;
- computer-use solo last resort;
- confirm tecnica su pagamento.

### P5 - Cleanup legacy

- docs Telegram;
- browser legacy;
- pipeline legacy;
- AppIntent esempio;
- MDM experimental.

## 28. Come avviare il progetto

### Harness

Da root:

```bash
./start-harness.sh
```

Oppure:

```bash
cd 03_HARNESS/server
npm install
cp config.example.mac.json config.json
node server.js
node panel.js
```

Pannello:

```text
http://localhost:7777
```

API iOS:

```text
http://127.0.0.1:7779
```

### App iOS

1. Copiare:

```bash
cd 02_GIGI_APP
cp Config.example.xcconfig Config.xcconfig
```

2. Inserire almeno:

```xcconfig
GROQ_API_KEY = gsk_...
```

3. Aprire `GIGI.xcodeproj`.

4. Risolvere package Swift.

5. Build su device reale.

6. Pairing harness da Settings.

## 29. Check rapido di salute

Comandi utili:

```bash
git status --short
```

```bash
xcodebuild -quiet -project 02_GIGI_APP/GIGI.xcodeproj -scheme GIGI -configuration Debug -destination generic/platform=iOS build
```

```bash
cd 03_HARNESS/server
npm run start
```

```bash
curl http://127.0.0.1:7779/api/ios/health
```

Nota: `/api/ios/health` richiede bearer perche' passa dal router iOS.

## 30. Stato attuale modifiche workspace

Modifiche recenti da tenere:

- `GigiMDNSDiscovery.swift`: fix warning actor isolation su logger.
- `HarnessStatusCard.swift`: fix warning actor isolation su `relativeTime`.
- `SetupDiagnosticWalkthroughs.swift`: nuovo file con tipi mancanti `Walkthrough`, `WalkthroughStep`, `Walkthroughs`.

Build iOS verificata con successo dopo questi fix.

## 31. Decisioni aperte

1. Il brain ufficiale e' solo `GigiAgentEngine`?
   - Se si, deprecare `GigiBrainPipeline`.

2. Force Claude deve bypassare davvero Groq?
   - Se si, integrare in `GigiAgentEngine.process`.
   - Se no, togliere toggle o rinominarla.

3. Telegram/WhatsApp channel backend restano?
   - Se si, docs e sicurezza.
   - Se no, rimozione codice/config.

4. Computer-use e food ordering usano sempre harness?
   - Consigliato: si, con WKWebView solo fallback.

5. Presence Mode punta a uso reale con telefono bloccato?
   - Serve test device e limiti chiari.

6. MDM fa parte del prodotto?
   - Consigliato: experimental separato.

7. Memory futura: JSON, CloudKit, LanceDB o ibrida?
   - Serve una sola source of truth per fase stabile.

## 32. Sintesi finale

Il workspace contiene gia' una base molto avanzata:

- app iOS con voce, wake word, TTS, settings, memoria, Dynamic Island;
- agent loop con Groq function calling;
- tool registry ampio;
- harness Node con Claude CLI, browser, APNS, memory, diagnostics;
- Presence Mode e Quick Talk;
- web automation on-device e backend.

La parte piu' importante adesso non e' aggiungere nuovi pezzi, ma ridurre ambiguita':

- un solo brain path ufficiale;
- una sola strategia web ufficiale;
- settings che corrispondono al runtime;
- docs allineate al codice;
- canali legacy chiariti;
- sicurezza harness chiusa;
- test end-to-end ripetibili.

Se questi punti vengono stabilizzati, GIGI passa da prototipo molto potente a sistema usabile e debuggabile.
