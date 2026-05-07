# Cross-cut Capability Map — GIGI

> Vista trasversale: ogni capability user-facing attraversa iOS + harness Node + (a volte) Shortcut iOS / APNS / MDM. Questo doc traccia il flusso end-to-end per ogni capability principale, in modo che decidendo di sfoltire una parte si veda subito cosa rompe a valle/monte.
>
> Fonti: `docs/MVP_SCOPE.md`, `docs/ARCHITETTURA_V3.md` (rev. 2), `docs/COMPONENTS.md`, `docs/PIANO_INTEGRAZIONE_HARNESS.md`, `docs/VOICE_ASSISTANT_SYSTEM_ANALYSIS.md`, `docs/memory/PROJECT.md`, `docs/memory/CONTEXT.md`, `docs/adr/`, `03_HARNESS/docs/api/ios-integration.md`, `docs/runbooks/talk-to-gigi-universal-shortcut.md`.
>
> Data: 2026-05-07. Riflette stato repo a inizio "Settimana lancio MVP" (deadline 1 maggio già scaduta; il repo conserva tutta la struttura del lancio).

---

## Capability User-Facing (lista master)

Capability che l'utente finale percepisce, una riga ciascuna. Le otto numerate da `MVP_SCOPE.md` + quelle implicite nell'architettura V3.

1. **Voice Activation** — invocare GIGI con la voce (wake word "Hey GIGI" o tap)
2. **Talking Session / Presence Mode** — sessione conversazionale long-lived dopo attivazione esplicita
3. **Quick Talk (foreground)** — conversazione singola dentro l'app
4. **Background Talk via Shortcut + Dictate Text** — loop di conversazione gestito da Apple Shortcuts come fallback "iOS-killed-the-mic"
5. **Action Button / Back Tap trigger** — invocare GIGI senza voce via gesture hardware (lo Shortcut universale)
6. **Wake word always-listening** — keyword spotting on-device dentro Presence Mode
7. **Dynamic Island / Live Activity** — UI persistente extra-app per stato (Ready/Listening/Thinking/Speaking)
8. **Preference Memory** — memoria di preferenze e relazioni del singolo utente, riusabili tra turni
9. **Day Plan / Calendar conversation** — discussione vocale del piano della giornata + estrazione task
10. **Active Help / Suggestions** — proposte proattive durante una Talking Session
11. **Better-Siri Action with Permission** — drafting di azione (es. WhatsApp a Fede), conferma vocale, esecuzione
12. **Native Phone Actions (call, message, navigate, music, timer, alarm, HomeKit, ecc.)** — i ~30 tool nativi del registry
13. **Web Automation On-Device (GigiWebAgent)** — WhatsApp Web, TheFork, OpenTable via WKWebView
14. **Computer-Use (server-side Claude)** — task browser complessi (Deliveroo/UberEats/...) eseguiti dal harness
15. **Confirm Mode / Permission Before Execution** — gating obbligatorio per pagamenti, azioni distruttive, multi-recipient
16. **Pairing iPhone↔harness via QR + Cloudflare Tunnel** — onboarding del backend personale
17. **APNS Push (proattivi + confirm + silent sync)** — morning briefing, meeting prep, confirm card, async results
18. **Watchers proattivi (server-side)** — cron-like che generano push (morning-briefing, meeting-prep)
19. **Streaming interim thoughts (WS)** — feedback "GIGI sta pensando/cercando..." durante run Claude
20. **Cancel / interrupt run** — annullare un task in volo
21. **Session resume Claude (--resume)** — continuità conversazione cross-restart lato harness
22. **MDM Accessibility profile install** — onboarding profilo `gigi_profile.mobileconfig` per accessibility
23. **Sideload IPA distribution** — installazione app via Sideloadly (no App Store)
24. **Memo / memory snapshot** — auto-summary conversazione a 75% contesto
25. **Cost tracking visibile in app** — stima `costEstimate` per turno (Freemium hook)
26. **Apple Foundation Models L1 fallback** — risposta on-device se cloud down (iOS 18+)
27. **CoreML Instant Commands** — bypass Gemini/Claude per "torch on", "play/pause" (< 100ms)
28. **Gemini Live full-duplex** — barge-in WebSocket con Gemini (modalità AirPods)
29. **Admin Panel (porta 7777)** — pannello dev per debug harness, watcher toggle, spawn server
30. **Device-side Diagnostics / debug logger remoto** — `GigiDebugLogger`, `GigiBrainDiagnostics`

---

## Per ogni capability — sezione

### 1. Voice Activation

- **Status MVP**: in-scope (AC#1 demo)
- **Flusso end-to-end**:
  1. iOS: `PresenceSessionController.start()` (toggle Settings → "Always Available") → crea Live Activity persistente "Ready"
  2. iOS: `GigiWakeWordEngine` installa tap su `AVAudioEngine`, ascolta `hey gigi / ehi gigi / ciao gigi / gigi / dai gigi`
  3. iOS: wake detected → `GigiSmartOrchestrator.startListening()` → state `recording`
  4. Alternativa fallback: Action Button / Back Tap → Shortcut `gigi-talk-to-gigi-v3` → AppIntent `GigiQuickTalkIntent` (apre app perché `openAppWhenRun=true`, mic richiede foreground)
- **File chiave**:
  - iOS: `PresenceSessionController.swift`, `GigiWakeWordEngine.swift`, `GigiAudioManager.swift`, `GigiAudioSequestrator.swift`, `GigiQuickTalkIntent.swift`, `GIGIApp.swift` (handler `gigi://listen`)
  - Harness: nessuno (pre-trigger è 100% iOS)
  - Altro: Apple Shortcut `gigi-talk-to-gigi-v3`, Action Button mapping
- **ADR rilevanti**: nessuno (deciso informalmente in `VOICE_ASSISTANT_SYSTEM_ANALYSIS.md`)
- **Doc rilevanti**: `docs/VOICE_ASSISTANT_SYSTEM_ANALYSIS.md`, `docs/runbooks/talk-to-gigi-universal-shortcut.md`
- **Risk se rimossa**: l'app diventa "inert" — utente non può attivarla a mani libere. Cade tutto il narrative "Siri but agentic"
- **Sostituibile da**: solo Action Button + Shortcut (perde "Hey GIGI" ma resta usabile demo). MVP_SCOPE §1 è esplicito che basta "naturale", non per forza wake word always-on

### 2. Talking Session / Presence Mode

- **Status MVP**: **killer feature** (AC#2-#5, demo Scene 2-3)
- **Flusso end-to-end**:
  1. iOS: utente dice "Gigi, let's open a talking session" oppure attiva toggle Settings
  2. iOS: `PresenceSessionController` mette `isPresenceActive = true`, salva `alwaysAvailable`, NON termina su inattività
  3. iOS: ciclo `wake → recording → STT → SmartOrchestrator → AgentEngine/HarnessClient → TTS → follow-up 8s → wake`
  4. iOS: dopo TTS apre 8s di follow-up senza richiedere nuova wake word (`GigiAudioManager.swift:141`)
  5. Harness: ogni turno → `POST /api/ios/agent/run` (deviceId + text) → Claude `--resume sessionId`
  6. Harness → iOS via WS `/ws/ios/stream`: interim thoughts + done event
- **File chiave**:
  - iOS: `PresenceSessionController.swift`, `GigiSmartOrchestrator.swift`, `GigiAudioManager.swift`, `GigiVADEngine.swift`, `GigiAgentEngine.swift`, `GigiClaudeBridge.swift`, `GigiHarnessClient.swift`, `GigiHarnessStream.swift`, `GigiConversationMemory.swift`
  - Harness: `server/api/ios-agent.js`, `server/api/ios-stream.js`, `server/session-manager.js`, `server/claude-runner.js`, `server/queue.js`
  - Altro: APNS opzionale per recovery
- **ADR rilevanti**: nessuno (Presence Mode emerso da `VOICE_ASSISTANT_SYSTEM_ANALYSIS.md`, pre-ADR)
- **Doc rilevanti**: `docs/VOICE_ASSISTANT_SYSTEM_ANALYSIS.md`, `docs/MVP_SCOPE.md` §2, `docs/ARCHITETTURA_V3.md` §5
- **Risk se rimossa**: si perde l'intera tesi MVP. Quick Talk è un degraded substitute (singolo turno, non conversazione)
- **Sostituibile da**: Quick Talk + Background Talk loop su Shortcut Dictate Text (50 iterazioni). Funziona per demo se wake word non è affidabile

### 3. Quick Talk (foreground)

- **Status MVP**: in-scope come fallback
- **Flusso end-to-end**:
  1. iOS: utente apre app → tap pulsante o `GigiQuickTalkIntent` (Siri Shortcut "Talk to GIGI")
  2. iOS: `GigiSmartOrchestrator.swift:336` → `GigiAudioManager.startRecording()` + Live Activity `beginListening()`
  3. → uguale al flusso 2 dal punto 4 in poi, ma single-turn (no follow-up loop)
- **File chiave**:
  - iOS: `GigiQuickTalkIntent.swift`, `GigiSmartOrchestrator.swift`, `GigiAudioManager.swift`
  - Harness: stesso di Talking Session
- **ADR rilevanti**: nessuno
- **Risk se rimossa**: nessuno se Talking Session funziona; altrimenti è il fallback minimo
- **Sostituibile da**: Talking Session (lo include)

### 4. Background Talk via Shortcut + Dictate Text

- **Status MVP**: in-scope come piano-B della demo (lo Shortcut canonico è `gigi-talk-to-gigi-v3`)
- **Flusso end-to-end**:
  1. iOS Shortcuts: `Repeat 50` → `Dictate Text` → AppIntent `Process speech with GIGI` (text)
  2. iOS: AppIntent invoca `GigiAgentEngine` o `GigiClaudeBridge` → ritorna marker string (`CALL:`, `SMS:`, `OPEN:`, plain)
  3. iOS Shortcuts: branching su marker → `Call` / `Send Message` / `Open URL` / `Speak Text`
- **File chiave**:
  - iOS: `GigiQuickTalkIntent.swift` (AppIntent), `GigiAgentEngine.swift`, `GigiToolRegistry.swift`
  - Harness: opzionale (se intent richiede backend)
  - Altro: **Apple Shortcut `gigi-talk-to-gigi-v3`** (asset esterno al repo)
- **ADR rilevanti**: nessuno
- **Doc rilevanti**: `docs/runbooks/talk-to-gigi-universal-shortcut.md`
- **Risk se rimossa**: si perde la garanzia Apple-compliant di esecuzione native action senza aprire l'app — cade "true agent on iOS"
- **Sostituibile da**: niente di equivalente — è l'unico path per `Send Message` reale senza compose UI

### 5. Action Button / Back Tap trigger

- **Status MVP**: in-scope (entry point demo)
- **Flusso end-to-end**: Hardware gesture → Apple Shortcut → flusso #4
- **File chiave**: nessun file repo (config Shortcut + iOS Settings)
- **Risk se rimossa**: l'utente deve toccare l'app — peggiora storytelling demo
- **Sostituibile da**: Wake word, Lock-screen Live Activity tap (gigi://listen)

### 6. Wake word always-listening

- **Status MVP**: in-scope con caveat — `VOICE_ASSISTANT_SYSTEM_ANALYSIS.md` dice "best effort iOS-compliant", non promessa hard
- **Flusso end-to-end**:
  1. iOS: `GigiWakeWordEngine` attivo solo se `isPresenceActive` (limite hardcoded 142)
  2. iOS: `SFSpeechRecognizer` Locale.current con keyword list
  3. iOS: pre-warm Bluetooth on detect, ferma monitor, passa a recording
- **File chiave**: `GigiWakeWordEngine.swift`, `GigiAudioSequestrator.swift`, `GigiAudioManager.swift`, `Info.plist` (UIBackgroundModes audio)
- **ADR rilevanti**: nessuno
- **Risk se rimossa**: cade "Hey GIGI" naturale; resta l'esperienza tap-to-talk
- **Sostituibile da**: tap su Live Activity / Action Button. Esplicitamente discusso come "deescalable" in `VOICE_ASSISTANT_SYSTEM_ANALYSIS.md` §"Decisioni da prendere"

### 7. Dynamic Island / Live Activity

- **Status MVP**: in-scope (visibilità + cuore demo Apple-style)
- **Flusso end-to-end**:
  1. iOS: `GigiLiveActivityController` mantiene `presenceActivity` persistente in stato `.sleeping` ("Ready - say Hey GIGI")
  2. iOS: su wake → `descendForListening()` termina standby + crea nuova Activity `.listening` con `AlertConfiguration` per "scendere"
  3. iOS: transizioni `.thinking` / `.executing` / `.speaking` / `.done` mappate ai punti del agent loop
  4. iOS Widget: `GigiLiveActivityWidget.swift` rende UI Lock Screen + Dynamic Island
- **File chiave**: `GigiLiveActivityController.swift`, `GigiActivityAttributes.swift`, `GigiLiveActivityWidget.swift` (in `GIGIWidget/`), `Info.plist` (Live Activities + frequent updates)
- **Risk se rimossa**: si perde la superficie persistente extra-app — l'utente non sa più se GIGI è ascoltando
- **Sostituibile da**: solo notifiche locali (peggio: invasive, no stato continuo)

### 8. Preference Memory

- **Status MVP**: in-scope (AC#6, AC#7)
- **Flusso end-to-end**:
  1. iOS turno N: utente dice qualcosa che implica preferenza → `remember` tool call → `GigiMemory` (CloudKit) **e/o** `POST /api/ios/memory/put` su harness
  2. Harness: `memory/store.js` → `backends/json-store.js` salva file `logs/memory/<deviceId>.json`
  3. iOS turno N+M: AgentEngine/Claude esegue `recall` tool → `POST /api/ios/memory/query` o lookup locale RAG (`GigiVectorStore`)
  4. iOS: top-K record iniettati nel system prompt
- **File chiave**:
  - iOS: `GigiMemory.swift`, `GigiConversationMemory.swift`, `GigiVectorStore.swift` (NL framework)
  - Harness: `server/api/ios-memory.js`, `memory/store.js`, `memory/backends/json-store.js`
  - Altro: CloudKit (Apple e2e encrypted)
- **ADR rilevanti**: nessuno (decisione "MVP JSON → swap LanceDB" è in `PIANO_INTEGRAZIONE_HARNESS.md` §5, non promosso ad ADR)
- **Doc rilevanti**: `docs/ARCHITETTURA_V3.md` §11, `03_HARNESS/memory-upgrade/` (design only, non implementato)
- **Risk se rimossa**: si perde AC#6/#7 della demo. Il "personale" del prodotto sparisce
- **Sostituibile da**: hardcoded curated demo memory (allowed da MVP_SCOPE §3 "small curated demo memory"). È il path di taglio realistico

### 9. Day Plan / Calendar conversation

- **Status MVP**: in-scope (AC#5 #8)
- **Flusso end-to-end**:
  1. iOS: durante Talking Session utente parla del giorno
  2. iOS: AgentEngine chiama in parallelo `read_calendar` / `read_week_calendar` / `find_free_slot` (algoritmo locale semantic-aware)
  3. iOS: `EventKit` legge eventi
  4. iOS: Claude/Gemini estrae task list, propone reorder
  5. iOS: TTS riassume → utente approva
- **File chiave**:
  - iOS: `GigiToolRegistry.swift` (tools `read_calendar`, `read_week_calendar`, `find_free_slot`, `create_event`), `GigiActionDispatcher+Native.swift`
  - Harness: nessuno (calendar è 100% iOS)
- **Risk se rimossa**: si perde la "killer scene" 3-5 della demo. È UNO dei pilastri MVP
- **Sostituibile da**: niente — il calendario è la slice "life-management" più chiara per v1

### 10. Active Help / Suggestions

- **Status MVP**: in-scope (AC#8)
- **Flusso end-to-end**:
  1. iOS turno: AgentEngine ha contesto + memoria preferenze
  2. Claude/Gemini emette `text` che propone azione invece di solo rispondere ("you usually prefer deep work before calls...")
  3. iOS TTS
- **File chiave**: emergent property dei system prompt (`GigiFoundationAgent.swift`), non file dedicato
- **Risk se rimossa**: cade AC#8 ("better day plan suggestion"). Si rompe la differenziazione vs Siri
- **Sostituibile da**: niente — è il punto del prodotto

### 11. Better-Siri Action with Permission (es. WhatsApp Fede)

- **Status MVP**: in-scope (AC#9, AC#10, demo Scene 6-7)
- **Flusso end-to-end**:
  1. iOS: utente "Write to Fede on WhatsApp"
  2. iOS: AgentEngine → `recall` (memoria tono Fede) → `web_whatsapp` tool con `requiresConfirmation`
  3. iOS: `GigiConfirmationPolicyEngine` blocca, TTS "Ho preparato un messaggio..., procedo?"
  4. Utente "sì" → iOS branchia:
     - SE Shortcut universal flow → marker `OPEN:whatsapp://send?phone=X&text=Y` → Apple Shortcut Open URL
     - SE on-device flow → `GigiWebAgent` (WKWebView Desktop UA) `sendWhatsApp(contact, message)`
- **File chiave**:
  - iOS: `GigiAgentEngine.swift`, `GigiConfirmationPolicyEngine.swift`, `GigiWebAgent.swift` (web automation), `GigiAutoSender.swift`, `GigiContactsEngine.swift`, `GigiActionDispatcher+Web.swift`
  - Harness: opzionale (per fallback computer-use)
  - Altro: Apple Shortcut SMS branch (`docs/runbooks/talk-to-gigi-universal-shortcut.md`)
- **Risk se rimossa**: cade AC#9 + intera Scene 6-7. Si rompe permission boundary che è "product identity"
- **Sostituibile da**: niente — è la prova della tesi

### 12. Native Phone Actions (call, navigate, music, ...)

- **Status MVP**: in-scope ma minimal — MVP_SCOPE §"Out of scope" #4 dice esplicitamente NO "complete iOS control"
- **Flusso end-to-end**: iOS AgentEngine → tool `make_call` / `navigate` / `play_music` / `set_alarm` / ... → `GigiActionBridge` → CallKit / MapKit / MediaPlayer / EventKit / Clock
- **File chiave**:
  - iOS: `GigiToolRegistry.swift` (~30 tool nativi), `GigiActionBridge.swift`, `GigiActionDispatcher.swift` + `+Native.swift`, `GigiHomeKit.swift`
  - Harness: nessuno
- **Risk se rimossa**: l'app diventa "solo conversazionale" e perde "Siri-but". Ma molti dei 30 tool sono ridondanti per la demo
- **Sostituibile da**: subset minimo (call, message, alarm, navigate). Tutto il resto è candidato sfoltimento

### 13. Web Automation On-Device (GigiWebAgent)

- **Status MVP**: probabilmente post-MVP per la maggior parte dei siti — MVP_SCOPE §"Out of scope" #6 esclude "Full WhatsApp automation"
- **Flusso end-to-end**: iOS AgentEngine → `web_whatsapp` / `web_book_restaurant` → `GigiWebAgent` WKWebView nascosto Desktop UA → click selectors → result string
- **File chiave**:
  - iOS: `GigiWebAgent.swift` (riferito in `ARCHITETTURA_V3.md` §8 ma non in `COMPONENTS.md` — possibile assenza nel codice attuale)
  - Harness: nessuno (è on-device)
- **Risk se rimossa**: cade Scene 6 (WhatsApp Fede). Ma è sostituibile da `OPEN:whatsapp://send?phone=...` Shortcut path che apre WhatsApp e lascia all'utente premere Send
- **Sostituibile da**: deep link `whatsapp://send` via Apple Shortcut → soluzione raccomandata da `talk-to-gigi-universal-shortcut.md` per la demo

### 14. Computer-Use (server-side Claude)

- **Status MVP**: **fuori scope MVP** (MVP_SCOPE §"Out of scope" #5+#6 esclude "Sending payments / ordering food / Uber"). Resta nell'architettura come capability futura
- **Flusso end-to-end**:
  1. iOS: AgentEngine → `computer_use` tool → `GigiComputerUse` → `POST /api/ios/computer-use {task}`
  2. Harness: `server/api/ios-computer-use.js` → enqueue → Anthropic SDK loop con `computer_20241022` tool
  3. Harness: `browser-pool/driver.js` lease Playwright → screenshot loop → action
  4. Harness: regex `CONFIRM_REQUIRED` → status `awaiting_confirm` → APNS push `type:confirm`
  5. iOS riceve push → mostra card → user tap → `POST /confirm {approved:true}`
  6. Harness riprende → completa → response
- **File chiave**:
  - iOS: `GigiComputerUse.swift`
  - Harness: `server/api/ios-computer-use.js`, `browser-pool/driver.js`, `browser-pool/server.js`, `browser-pool/server-playwright.js`, `apns/send.js`
- **ADR rilevanti**: nessuno (decisione "claude-opus-4-7" è in `PIANO_INTEGRAZIONE_HARNESS.md` §5 — non promossa ad ADR)
- **Risk se rimossa**: zero per MVP. L'intera capability è esplicitamente esclusa
- **Sostituibile da**: simulato/stubbed con risposta finta per la demo. Path consigliato: stub con messaggio "ho preparato l'ordine, procedo?" senza esecuzione reale

### 15. Confirm Mode / Permission Before Execution

- **Status MVP**: **mandatory** (AC#10, "product identity")
- **Flusso end-to-end**:
  1. iOS o Harness emette result `requiresConfirm: ConfirmRequest`
  2. iOS: `GigiConfirmationPolicyEngine` classifica `.payment / .destructive / .sensitive`
  3. iOS: TTS riassume + chiede conferma + audio state torna a `recording`
  4. Utente "sì" → `confirmAndContinue()` esegue step finale
- **File chiave**:
  - iOS: `GigiConfirmationPolicyEngine.swift`, `GigiAgentEngine.swift` (logic confirm)
  - Harness: pattern `CONFIRM_REQUIRED` regex su computer-use jobs (`server/api/ios-computer-use.js`)
- **Risk se rimossa**: cade AC#10. Cade tutto il "trust" narrative
- **Sostituibile da**: niente

### 16. Pairing iPhone↔harness via QR + Cloudflare Tunnel

- **Status MVP**: in-scope (foundation pre-launch già completata, commit `ca8a599`)
- **Flusso end-to-end**:
  1. Harness: `cloudflared` quick tunnel → URL ephemeral
  2. Harness: `server/public/pair.html` mostra QR (loopback-only `/api/pair`)
  3. iOS: `GigiPairScanner` (VisionKit DataScanner) → scan QR → JSON `{harnessBaseURL, secret}`
  4. iOS: `GigiPairingSheet` valida → `GigiKeychain.save(harnessBaseURL/secret)` → health check `GET /api/ios/health`
- **File chiave**:
  - iOS: `GigiPairScanner.swift`, `GigiPairingSheet.swift`, `GigiMDNSDiscovery.swift`, `GigiKeychain.swift`, `MainTabView.swift` (banner pairing)
  - Harness: `server/api/pair.js` (loopback-only), `server/public/pair.html`, `cloudflared` external
- **ADR rilevanti**: **ADR-0001** Cloudflare Quick Tunnel come pairing default MVP
- **Doc rilevanti**: `docs/runbooks/pair-iphone.md`, `docs/research/pairing-landscape-2026.md`, `docs/plans/cloudflare-tunnel-pairing.md`
- **Risk se rimossa**: l'app non può raggiungere il harness fuori LAN → cade tutto il backend
- **Sostituibile da**: solo LAN mDNS (perde "fuori casa", regredisce esperienza). Tailscale come "advanced path" documentato

### 17. APNS Push (proattivi + confirm + silent sync)

- **Status MVP**: in-scope per "morning briefing" + "confirm card" — fase 15 piano integrazione era opzionale ma key disponibile (`PIANO_INTEGRAZIONE_HARNESS.md` §5.5)
- **Flusso end-to-end**:
  1. iOS launch: `GigiApnsSync` → `POST /api/ios/push/register {apnsToken}`
  2. Harness: salva in `apns/tokens.json`
  3. Harness watcher / computer-use trigger → `apns/send.js` HTTP/2 + JWT ES256 → APNS Apple → iPhone
  4. iOS: `GigiAppDelegate` riceve → routing per `type` (morning-briefing / meeting-prep / confirm / silent-sync)
- **File chiave**:
  - iOS: `GigiApnsSync.swift`, `GigiAppDelegate.swift`, `GIGIApp.swift`
  - Harness: `apns/send.js`, `apns/tokens.json`, `server/api/ios-push-register.js`, `server/api/ios-push-test.js`
- **Risk se rimossa**: cade Active Help proattivo + confirm flow background
- **Sostituibile da**: pull-only (iOS chiama harness ogni N secondi quando in foreground) — drasticamente peggio

### 18. Watchers proattivi (server-side)

- **Status MVP**: opzionale — fase 15 era marcata "Opzionale (posticipabile)"
- **Flusso end-to-end**: `server/watchers.js` timer 60s → fire watcher → spawn Claude o computa → `apns/send.js`
- **File chiave**: `server/watchers.js`, `server/watchers.json`, `apns/send.js`
- **Risk se rimossa**: zero per MVP. Ottimo candidato sfoltimento
- **Sostituibile da**: cron job statico (es. push fisso alle 8:00 senza logica)

### 19. Streaming interim thoughts (WS)

- **Status MVP**: probabilmente in-scope (fa parte del piano P1.4 "streaming Claude → iOS" in `CONTEXT.md` Active Threads)
- **Flusso end-to-end**: iOS connect WS → POST /api/ios/agent/run con stream=true → harness pubblica `claude_event` ad ogni JSONL line → iOS aggiorna Live Activity `thinking/executing`
- **File chiave**:
  - iOS: `GigiHarnessStream.swift`, `GigiHarnessClient.swift`, `GigiLiveActivityController.swift`
  - Harness: `server/api/ios-stream.js`, `server/claude-runner.js` (--stream-json)
- **Risk se rimossa**: l'utente vede solo "thinking..." statico → percepisce GIGI come bloccato
- **Sostituibile da**: spinner statico + caption fisse — degrada UX ma non rompe demo

### 20. Cancel / interrupt run

- **Status MVP**: nice-to-have
- **Flusso**: iOS `POST /api/ios/agent/cancel {runId}` → harness `queue.markCancelled` + kill child Claude
- **File chiave**: `server/queue.js`, `server/claude-runner.js`, `server/api/ios-agent.js`
- **Risk se rimossa**: utente blocca app durante run lunghi — peggiora UX. MVP_SCOPE non lo elenca

### 21. Session resume Claude (--resume)

- **Status MVP**: foundation (P1.4 active)
- **Flusso**: harness `session-manager.js` mappa `deviceId → sessionId Claude` con TTL 60min → ogni `agent/run` chiama `claude --resume sessionId`
- **File chiave**: `server/session-manager.js`, `server/sessions.json` (state)
- **Risk se rimossa**: ogni turno parte da zero → costo + latenza + niente memoria conversazione side harness
- **Sostituibile da**: niente — è il pattern che rende l'harness "remember the day"

### 22. MDM Accessibility profile install

- **Status MVP**: probabilmente in-scope per onboarding (sblocca accessibility permissions)
- **Flusso**: `01_SERVER_MDM/server.js` distribuisce `gigi_profile_signed.mobileconfig` → utente Safari → installa profilo iOS
- **File chiave**: `01_SERVER_MDM/server.js`, `01_SERVER_MDM/gigi_profile_signed.mobileconfig`, `01_SERVER_MDM/certs/`, `02_GIGI_APP/GIGI/GIGI_Accessibility_MDM.mobileconfig`
- **Risk se rimossa**: alcune capability accessibility (es. controllo Switch Control via app) non funzionano. Per la demo: probabilmente NON serve
- **Sostituibile da**: niente, ma probabilmente non necessario per MVP demo. **Forte candidato sfoltimento per il rework**

### 23. Sideload IPA distribution

- **Status MVP**: vincolo costante (no App Store)
- **Flusso**: build Xcode → IPA → Sideloadly + Apple ID → installa su device. Workflow personal del dev (`CLAUDE.local.md`)
- **File chiave**: `02_GIGI_APP/GIGI.xcodeproj`, root `start-harness.sh`, MDM profile per Sideloadly trust
- **Risk se rimossa**: niente da rimuovere — è vincolo OS

### 24. Memo / memory snapshot

- **Status MVP**: opzionale
- **Flusso**: harness rileva contesto Claude > 75% → `memory-snapshot.js` chiama Claude per riassumere conversation → salva → reset session. Endpoint manuale `POST /api/ios/memo`
- **File chiave**: `server/memory-snapshot.js`, `server/api/ios-agent.js` (route /memo)
- **Risk se rimossa**: harness va in rate limit dopo conversation lunghe. Per la demo (single turn / short session): ZERO rischio. **Candidato sfoltimento**

### 25. Cost tracking visibile in app

- **Status MVP**: post-MVP (Freemium hook, non parte di MVP_SCOPE AC)
- **Flusso**: `AgentResult.costEstimate` aggregato in `DashboardView`
- **File chiave**: `GigiAgentEngine.swift` (struct), `DashboardView.swift`
- **Risk se rimossa**: nessuno per MVP

### 26. Apple Foundation Models L1 fallback

- **Status MVP**: nice-to-have (richiede iOS 18+)
- **Flusso**: `GigiBrainPipeline` rileva cloud down → `GigiFoundationSession` (`GigiFoundationAgent`) → on-device LLM → response
- **File chiave**: `GigiFoundationAgent.swift`, `GigiFoundationSession.swift`, `GigiBrainPipeline.swift`
- **Risk se rimossa**: zero rete = zero risposta. Ma per demo (Wi-Fi controllato) non serve. **Candidato sfoltimento**

### 27. CoreML Instant Commands

- **Status MVP**: probabilmente sperimentale — `ARCHITETTURA_V3.md` §7 lo descrive ma `GigiNLU.mlmodel` esiste in repo come modello generico, non c'è evidence di "Instant Commands" branch
- **Flusso**: STT testo → CoreML classifier → se score alto e label in `instantCommands` → exec sync (< 50ms), bypass tutto
- **File chiave**: `GigiNLUEngine.swift`, `GigiNLU.mlmodel`, `GigiNLU_Transformer.mlpackage`, `gigi_labels.json`
- **Risk se rimossa**: "torch on" passa da 50ms a 800ms. Demo non lo richiede
- **Sostituibile da**: agent loop standard. **Candidato sfoltimento**

### 28. Gemini Live full-duplex

- **Status MVP**: **fuori scope MVP** (MVP_SCOPE §"Out of scope" #3 esclude ambient listening; Live è fattualmente non-ambient ma è feature complessa). Talking Session usa REST + STT, non Live
- **Flusso**: `GigiRealtimeEngine` apre WSS Gemini → stream PCM 16kHz → Gemini emette functionCall + audio TTS → barge-in
- **File chiave**: `GigiRealtimeEngine.swift` (riferito in `ARCHITETTURA_V3.md` §13 ma non in `COMPONENTS.md` — **possibile orfano / non implementato**)
- **Risk se rimossa**: zero per MVP
- **Sostituibile da**: già sostituito da REST + on-device VAD (è il path attuale). **Forte candidato sfoltimento**

### 29. Admin Panel (porta 7777)

- **Status MVP**: dev-only
- **Flusso**: browser PC → http://localhost:7777 → `panel.js` HTTP → `bridge-rpc.js` :7778 → server `:7779`
- **File chiave**: `server/panel.js`, `server/panel-routes.js`, `server/bridge-rpc.js`, `server/public/pair.html`
- **Risk se rimossa**: dev devono usare API direttamente. Niente rispetto al prodotto end-user
- **Sostituibile da**: CLI scripts. **Candidato sfoltimento light** (ma utile per pairing UI)

### 30. Device-side Diagnostics / debug logger remoto

- **Status MVP**: dev-only
- **Flusso**: iOS `GigiDebugLogger` → POST endpoint backend → log centralizzato
- **File chiave**: `GigiDebugLogger.swift`, `GigiBrainDiagnostics.swift`, `GigiCommandLogger.swift`
- **Risk se rimossa**: harder debug on-device. Non blocca demo

---

## Capability sperimentali / dead candidate

Feature che il codice/docs accenna ma non sembrano completamente vivi/implementati:

| Capability | Status | Evidence |
|---|---|---|
| **Gemini Live full-duplex (`GigiRealtimeEngine`)** | Sperimentale / orfano | Citato in `ARCHITETTURA_V3.md` §13 e §18 (struttura file), assente da `COMPONENTS.md`. Probabile decisione di tagliarlo silenziosamente |
| **GigiWebAgent (WhatsApp Web/TheFork on-device)** | Sperimentale / progettato | `ARCHITETTURA_V3.md` §8 lo descrive in dettaglio, **non compare in `COMPONENTS.md` §iOS App**. Solo `GigiAutoSender.swift` come surrogate |
| **`GigiVectorStore` (RAG locale NL embeddings)** | Sperimentale | `ARCHITETTURA_V3.md` §11/§18 lo descrive, NON in `COMPONENTS.md` |
| **Context Caching Gemini** | Sperimentale | `ARCHITETTURA_V3.md` §3 lo descrive, fase 6 roadmap. Nessuna evidenza implementazione |
| **Meta-classifier locale** | Sperimentale | `ARCHITETTURA_V3.md` §3 idem, fase 6 roadmap |
| **Streaming TTS pipeline** | Sperimentale | `GigiSpeechService.streamSpeak()` riferito in §3 + roadmap fase 6 |
| **CoreML Instant Commands** | Sperimentale | Concept in §7. Modello esiste, branch dedicato no |
| **`GigiPlanner.swift`** | **Deprecato esplicitamente** | `ARCHITETTURA_V3.md` §2 + §18 + Note finali "DEPRECATO (sostituito da agent loop)". File esiste in `COMPONENTS.md` (`GigiOrchestrator.swift`, `GigiSmartOrchestrator.swift` lo sostituiscono) |
| **`memory-upgrade/` (LanceDB + BGE-M3 v4)** | Design only | `03_HARNESS/memory-upgrade/README.md` dice esplicitamente "design only, non implementato" |
| **Multi-user federated fine-tuning** | Design only | `03_HARNESS/memory-upgrade/multi-user-v1/` |
| **`telegram-bridge/` Telegram I/O** | **Removed (fase 17 PIANO)** | `PIANO_INTEGRAZIONE_HARNESS.md` §5 decisione 3 "DROPPA TUTTO". `ARCHITETTURA_V3.md` §9.BIS conferma drop. Vecchio paragrafo §"Struttura" alla fine del doc lo lista ancora — incoerenza interna del paper |
| **Iroh / iroh-ffi P2P** | **Killed** | `ADR-0001` esplicitamente esclude (libreria archiviata Feb 2025) |
| **Tailscale come default** | Killed for default | `ADR-0001` esclude come default, ammesso come "advanced path" |
| **Apple Foundation Models L1** | Conditional / iOS 18+ | Referenced ma usabilità reale incerta su device sideload |

---

## ADR Index

Solo 2 ADR esistono in `docs/adr/`:

- **0000-template.md** — template (non un ADR vero)
- **ADR-0001 Cloudflare Quick Tunnel come pairing default MVP** (Accepted, 2026-04-24, @armando) — Cloudflare quick tunnel = MVP default; Tailscale = advanced documented path; Iroh escluso (archived). Trade-off: privacy edge-TLS Cloudflare vs onboarding-friction Tailscale; URL ephemeral richiede re-pair su restart; WS 100s idle timeout su free tier richiede heartbeat.

**Decisioni architetturali NON promosse ad ADR ma trattate come tali**:
1. "Memory backend MVP JSON → swap LanceDB" — `PIANO_INTEGRAZIONE_HARNESS.md` §5 decisione 1
2. "Computer-use model = `claude-opus-4-7`" — idem decisione 2
3. "Drop completo Telegram" — idem decisione 3
4. "Mac dev / VPS prod via env-var, no path hardcoded" — idem decisione 4
5. "Porte 7777 admin / 7778 RPC / 7779 iOS" — `ARCHITETTURA_V3.md` §9.BIS
6. "Bearer secret in iOS Keychain" — idem
7. "GigiPlanner deprecato in favore di GigiAgentEngine loop" — `ARCHITETTURA_V3.md` §2 §"Note finali"
8. "Talking Session = killer MVP, non ambient listening" — `MVP_SCOPE.md` §2

→ **Questi 8 punti sono ottimi candidati per essere promossi a ADR formali** durante il rework, in modo che decisioni di sfoltimento non re-litighino ground già concordato.

---

## Capability del MVP scope (venerdì 1 maggio)

Dalle Acceptance Criteria di `MVP_SCOPE.md` §"MVP Demo Acceptance Criteria":

| AC# | Requisito | Capability ID |
|---|---|---|
| 1 | User can activate GIGI by voice | #1 Voice Activation |
| 2 | User can open a Talking Session | #2 Talking Session |
| 3 | GIGI listens only after explicit activation | #2 (no ambient) |
| 4 | User converses naturally about the day | #2 + #9 |
| 5 | GIGI extracts tasks from conversation | #9 + #10 |
| 6 | GIGI shows memory of preferences | #8 |
| 7 | GIGI uses preferences to enrich a request | #8 + #11 |
| 8 | GIGI suggests better day plan / next action | #10 |
| 9 | GIGI prepares basic action (message / calendar) | #11 (+ #12 native) |
| 10 | GIGI asks permission before meaningful action | #15 |
| 11 | Demo feels like "Siri but personal/conversational/agentic" | composite |
| 12 | Viewer understands larger vision | composite |

**Capability strettamente necessarie** (taglio one-pass realistico):
- #1 Voice Activation (anche solo Action Button + Shortcut basta per AC#1)
- #2 Talking Session
- #7 Dynamic Island (visibilità percettiva)
- #8 Preference Memory (curated demo memory ammesso)
- #9 Day Plan / Calendar
- #10 Active Help
- #11 Better-Siri Action with Permission
- #15 Confirm Mode
- #16 Pairing iPhone↔harness (foundation)
- #21 Session resume Claude

**Tutto il resto è candidato sfoltimento per il rework**, in particolare:
- #14 Computer-Use server-side (esplicitamente fuori scope)
- #17/#18 APNS proactive/Watchers (opzionale piano fase 15)
- #19 Streaming interim thoughts (degrada graceful)
- #22 MDM Accessibility profile (probabilmente non serve per demo)
- #24 Memo snapshot
- #25 Cost tracking
- #26 Apple Foundation Models L1
- #27 CoreML Instant Commands
- #28 Gemini Live full-duplex (sperimentale)
- #29 Admin Panel (dev-only)
- #30 Diagnostics (dev-only)

---

## Capability con flusso più complesso (più file/component coinvolti)

Top-3 per **costo manutenzione** (numero file iOS + Harness + dipendenze esterne):

1. **#14 Computer-Use server-side** — iOS (`GigiComputerUse`) + Harness (`ios-computer-use`, `browser-pool/driver`, `browser-pool/server-playwright`, `browser-pool/server`, `apns/send`) + Anthropic SDK + Playwright + Chrome pool + APNS provider + regex CONFIRM_REQUIRED + JOB queue. **8+ file, 4 servizi esterni**, esplicitamente OUT OF SCOPE → primo candidato kill totale per rework
2. **#2 Talking Session / Presence Mode** — iOS ~10 file (`PresenceSessionController`, `GigiWakeWordEngine`, `GigiAudioManager`, `GigiVADEngine`, `GigiSmartOrchestrator`, `GigiAgentEngine`, `GigiClaudeBridge`, `GigiHarnessClient`, `GigiHarnessStream`, `GigiConversationMemory`, `GigiLiveActivityController`) + Harness ~6 file + WS + Live Activity + AVAudio. È il **cuore MVP** — non si taglia, ma va consolidato (single owner = `PresenceSessionController` come da `VOICE_ASSISTANT_SYSTEM_ANALYSIS.md`)
3. **#11 Better-Siri Action with Permission** — iOS (`GigiAgentEngine`, `GigiToolRegistry`, `GigiConfirmationPolicyEngine`, `GigiWebAgent`, `GigiAutoSender`, `GigiContactsEngine`, `GigiActionDispatcher+Web`) + Apple Shortcut universale + WhatsApp Web fallback + tool registry da 38. La **complessità è data dal tool registry** — sfoltire da 38 a ~8 tool è il taglio chirurgico più impattante

---

## ADR contraddetti / ambiguità nel codice

Solo 1 ADR esiste, e non è apparentemente contraddetto dal codice. Ma ci sono **incoerenze fra docs** che meritano un ADR di chiarimento:

1. **`ARCHITETTURA_V3.md` §"Struttura" finale** elenca ancora `telegram-bridge/`, `browser-mcp/`, `transcribe.js` come parte attiva, MA **§9.BIS dice "Telegram droppato fase 17"** e `PIANO_INTEGRAZIONE_HARNESS.md` §5 lo conferma. → Servirebbe ADR "Telegram dropped" + cleanup paper
2. **`ARCHITETTURA_V3.md` §8 dichiara `GigiWebAgent` come pilastro web automation on-device**, ma `COMPONENTS.md` non lo elenca tra i file iOS. → o è non implementato, o è documentazione stale
3. **`ARCHITETTURA_V3.md` §13 descrive `GigiRealtimeEngine` con Gemini Live**, ma `COMPONENTS.md` non lo elenca. `MVP_SCOPE.md` non parla di Live. → probabile sperimentale orfano
4. **`PROJECT.md` Tech Stack dice "Apple FM iOS 17+"**, ma `ARCHITETTURA_V3.md` dice "iOS 18+" per Apple Foundation Models. → minor inconsistency
5. **`ARCHITETTURA_V3.md` §9 (backend Anthropic-SDK-diretto + BullMQ + Redis)** vs **§9.BIS (harness reale, no Redis, no BullMQ)** → §9 e §9.BIS descrivono due backend potenzialmente diversi. §9 stesso ammette "L'overlap funzionale è parziale" — ma il gap concreto NON è chiarito. → ADR per riconciliare
6. **`MVP_SCOPE.md` §"Out of scope" #6 esclude "Full WhatsApp automation"** ma **§"In scope" #4 demo example è `Write to Fede on WhatsApp`** → la riconciliazione è "draft-only, no real send" ma codice (`GigiAutoSender.swift`) lascia ambiguità
7. **`CONTEXT.md` Active Threads** menziona "U0: utente deve installare Tailscale" ma **ADR-0001 dice Cloudflare Quick Tunnel = default MVP, Tailscale = advanced path** → context.md scritto prima di ADR-0001? Possibile. Da aggiornare

---

*Doc generato da analista cross-cut, 2026-05-07. Compagno docs di mappature iOS / Harness / Infra prodotte in parallelo.*
