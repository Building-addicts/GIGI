# iOS Capability Inventory

> Generated 2026-05-07 from main @ 7ec7e94. Path: `02_GIGI_APP/`.
> 80 Swift files explored: 75 in main app target (`02_GIGI_APP/GIGI/`), 5 in widget extension (`02_GIGI_APP/GIGIWidget/`).
> Format: one block per user-facing capability or load-bearing internal module. Removability scored against current pipeline incast — not against design merit.

## Index

### App shell & lifecycle
- [App entry & scenePhase wiring](#app-entry--scenephase-wiring)
- [APNS registration & push handlers](#apns-registration--push-handlers)
- [Tab navigation shell](#tab-navigation-shell)
- [Onboarding flow (7-step)](#onboarding-flow-7-step)
- [Crash log capture & remote ingest](#crash-log-capture--remote-ingest)

### Voice channels (entry points)
- [Quick Talk (one-shot foreground voice)](#quick-talk-one-shot-foreground-voice)
- [Presence Mode (always-available session)](#presence-mode-always-available-session)
- [Background Talk Intent (Shortcut-piped voice)](#background-talk-intent-shortcut-piped-voice)
- [Wake Word Engine (currently kill-switched)](#wake-word-engine-currently-kill-switched)
- [Control Center button → listen](#control-center-button--listen)

### Audio / speech infrastructure
- [Audio session coordinator (state machine)](#audio-session-coordinator-state-machine)
- [Audio session sequestrator (AVAudioSession lifecycle)](#audio-session-sequestrator-avaudiosession-lifecycle)
- [VAD + STT engine](#vad--stt-engine)
- [TTS speech service](#tts-speech-service)
- [Realtime engine (Gemini Live WebSocket)](#realtime-engine-gemini-live-websocket)
- [Earcon / haptic sound engine](#earcon--haptic-sound-engine)

### Brain / NLU / orchestration
- [Smart Orchestrator (turn lifecycle)](#smart-orchestrator-turn-lifecycle)
- [Brain pipeline (4-level cascade)](#brain-pipeline-4-level-cascade)
- [NLU engine (rule + CoreML + transformer)](#nlu-engine-rule--coreml--transformer)
- [Foundation Models agent (iOS 18.1+)](#foundation-models-agent-ios-181)
- [Agent loop engine (Groq react-loop)](#agent-loop-engine-groq-react-loop)
- [Planner engine (task decomposer)](#planner-engine-task-decomposer)
- [Day Plan Reasoner (different from planner)](#day-plan-reasoner-different-from-planner)
- [Cloud service (Groq + Gemini REST)](#cloud-service-groq--gemini-rest)

### Action execution & tools
- [Action Bridge (native iOS actions)](#action-bridge-native-ios-actions)
- [Action Dispatcher (intent → action router)](#action-dispatcher-intent--action-router)
- [Tool Registry (38 tool declarations)](#tool-registry-38-tool-declarations)
- [Confirmation Policy Engine](#confirmation-policy-engine)
- [Fallback engine (error copy)](#fallback-engine-error-copy)
- [Task Extractor (transcript → todos)](#task-extractor-transcript--todos)
- [Tone enrichment (draft message rewrite)](#tone-enrichment-draft-message-rewrite)

### Web / computer-use
- [GigiWebAgent (WKWebView automation)](#gigiwebagent-wkwebview-automation)
- [Vision-loop web automation (Groq vision)](#vision-loop-web-automation-groq-vision)
- [Computer-use client (harness Playwright)](#computer-use-client-harness-playwright)

### Harness backend integration
- [Harness HTTP client](#harness-http-client)
- [Harness WebSocket stream](#harness-websocket-stream)
- [Claude Bridge (delegation coordinator)](#claude-bridge-delegation-coordinator)
- [Harness pairing (QR scan + Keychain)](#harness-pairing-qr-scan--keychain)
- [QR pairing camera scanner](#qr-pairing-camera-scanner)
- [mDNS / Bonjour LAN discovery](#mdns--bonjour-lan-discovery)
- [APNS token sync to harness](#apns-token-sync-to-harness)
- [Harness diagnostics & offline banner](#harness-diagnostics--offline-banner)
- [Setup diagnostic gate (post-pair)](#setup-diagnostic-gate-post-pair)
- [Harness status card (settings panel)](#harness-status-card-settings-panel)
- [Diagnostic walkthroughs](#diagnostic-walkthroughs)

### Memory & profile
- [GigiMemory (CloudKit key/value)](#gigimemory-cloudkit-keyvalue)
- [Conversation memory (chat history)](#conversation-memory-chat-history)
- [Vector store (on-device semantic search)](#vector-store-on-device-semantic-search)
- [User profile (form-fill data)](#user-profile-form-fill-data)
- [MVP preferences (7 soft prefs)](#mvp-preferences-7-soft-prefs)
- [Memory hint toast](#memory-hint-toast)
- [QuickTalk command history store](#quicktalk-command-history-store)

### System integrations
- [Contacts engine (fuzzy resolver)](#contacts-engine-fuzzy-resolver)
- [HomeKit integration](#homekit-integration)
- [Keychain wrapper](#keychain-wrapper)
- [Auth manager (Google Sign-In)](#auth-manager-google-sign-in)
- [Config (API keys storage)](#config-api-keys-storage)

### UI views (screen-level)
- [Chat view](#chat-view)
- [Dashboard view](#dashboard-view)
- [Settings view](#settings-view)
- [Quick Talk overlay](#quick-talk-overlay)
- [Presence companion view](#presence-companion-view)
- [Talking Session task list overlay](#talking-session-task-list-overlay)
- [Draft message preview sheet](#draft-message-preview-sheet)
- [Permission confirmation sheet](#permission-confirmation-sheet)

### Live Activity / Dynamic Island
- [Live Activity controller (3 activity types)](#live-activity-controller-3-activity-types)
- [Activity attributes & GigiPhase enum](#activity-attributes--gigiphase-enum)
- [Presence app group bridge (widget↔app)](#presence-app-group-bridge-widgetapp)
- [Presence AppIntents (start/stop/mute)](#presence-appintents-startstopmute)
- [Quick Talk AppIntent + AppShortcuts](#quick-talk-appintent--appshortcuts)
- [Live Activity widget (Dynamic Island UI)](#live-activity-widget-dynamic-island-ui)
- [Control Center widget button](#control-center-widget-button)
- [Boilerplate timeline widget (Xcode default)](#boilerplate-timeline-widget-xcode-default)

### Ops / debug
- [Debug logger (remote ingest)](#debug-logger-remote-ingest)
- [Brain diagnostics (harness reachability)](#brain-diagnostics-harness-reachability)
- [Command logger (Quick Talk telemetry)](#command-logger-quick-talk-telemetry)
- [Voice contracts (cross-channel types)](#voice-contracts-cross-channel-types)

---

## App entry & scenePhase wiring
- **Entry point**: `02_GIGI_APP/GIGI/GIGIApp.swift:7` — `struct GIGIApp: App`
- **What it does**: bootstrap dell'app SwiftUI, registra AppDelegate APNS, gestisce deeplink `gigi://listen` e `gigi://...gateway`, pre-carica memoria semantica, riallinea Presence Mode su scenePhase=.active.
- **Files involved**:
  - `02_GIGI_APP/GIGI/GIGIApp.swift`
- **Calls / depends on**: `GigiAppDelegate`, `MainTabView`, `GigiAppShortcuts`, `GigiDebugLogger`, `GigiApnsSync`, `PresenceSessionController`, `GigiVectorStore`, `GigiUserProfile`, `GigiDayPlanReasoner` (only in DEBUG), `GigiSmartOrchestrator`, `GigiWebAgent`, `GIDSignIn`.
- **Called by**: SwiftUI runtime (`@main`).
- **Status**: live
- **Removability**: low — è il root, qualsiasi rework ne costruisce sopra.
- **Note**: in DEBUG esegue tre chiamate a `GigiDayPlanReasoner.debugRunWith*` come "smoke test" che si auto-eseguono ad ogni cold start (#15 sub MVP).

## APNS registration & push handlers
- **Entry point**: `02_GIGI_APP/GIGI/GigiAppDelegate.swift:11` — `final class GigiAppDelegate`
- **What it does**: chiede permission notifiche, riceve device token, instrada payload "confirm" / "morning-briefing" / "meeting-prep" via `NotificationCenter`.
- **Files involved**: `GigiAppDelegate.swift`
- **Calls / depends on**: `UNUserNotificationCenter`, `GigiApnsSync`, `GigiDebugLogger`.
- **Called by**: `GIGIApp` via `@UIApplicationDelegateAdaptor`.
- **Status**: live
- **Removability**: low — payload routing è punto unico di ingresso APNS.

## Tab navigation shell
- **Entry point**: `02_GIGI_APP/GIGI/MainTabView.swift:3` — `struct MainTabView`
- **What it does**: TabView 4-tab (Chat / Presence / Dashboard / Settings) + banner pairing viola + banner offline harness + overlay TalkingSession + sheet Pairing/Presence/QuickTalk/Onboarding.
- **Files involved**: `MainTabView.swift`
- **Calls / depends on**: `ChatView`, `DashboardView`, `SettingsView`, `PresenceView`, `OnboardingView`, `GigiPairingSheet`, `QuickTalkView`, `TalkingSessionTaskListView`, `HarnessOfflineBanner`, `PresenceSessionController`, `GigiSmartOrchestrator`, `QuickTalkController`, `GigiLiveActivityController`, `GigiHarnessClient`, `GigiAuthManager`.
- **Called by**: `GIGIApp.body`.
- **Status**: live
- **Removability**: low — orchestratore visivo di tutta l'app.

## Onboarding flow (7-step)
- **Entry point**: `02_GIGI_APP/GIGI/OnboardingView.swift:17` — `struct OnboardingView`
- **What it does**: welcome → permissions (mic, contacts, calendar, notifs) → API keys (Groq+Gemini) → harness pairing (skippable) → profile → hardware-trigger setup → done. Persiste `gigi.onboarding.complete` UserDefaults.
- **Files involved**: `OnboardingView.swift`
- **Calls / depends on**: `GigiKeychain`, `GigiHarnessClient`, `GigiAuthManager`, `GigiPairingSheet`, `GigiUserProfile`, `Walkthroughs`, AVFoundation/Speech/Contacts/EventKit permissions.
- **Called by**: `MainTabView` se `gigi.onboarding.complete == false`.
- **Status**: live
- **Removability**: medium — richiesta permissions è incastrata, ma molti step (Gemini, harness mid-onboarding) sono candidate-cull per un rework più snello.

## Crash log capture & remote ingest
- **Entry point**: `02_GIGI_APP/GIGI/GigiDebugLogger.swift:3` — `class GigiDebugLogger`
- **What it does**: log a `print` + UserDefaults ring buffer 200 entries, opzionale POST a remote ingest endpoint (attualmente nil).
- **Files involved**: `GigiDebugLogger.swift`
- **Calls / depends on**: UserDefaults, URLSession.
- **Called by**: ovunque (~50+ files).
- **Status**: live
- **Removability**: low — usato pervasivamente.
- **Note**: `remoteIngestURL = nil` di proposito (commento dice che causava saturazione URLSession pool) → metà del codice è morto ma sempre presente.

## Quick Talk (one-shot foreground voice)
- **Entry point**: `02_GIGI_APP/GIGI/QuickTalkController.swift:14` — `final class QuickTalkController`
- **What it does**: tap o intent → listening → STT → agent → TTS → idle. Modalità continuous chains turni finché user non dice "stop".
- **Files involved**: `QuickTalkController.swift`, `QuickTalkView.swift`, `QuickTalkCommandStore.swift`, `GigiQuickTalkIntent.swift`
- **Calls / depends on**: `GigiAudioManager`, `GigiSmartOrchestrator`, `GigiSpeechService`, `GigiCommandLogger`, `GigiFallbackEngine`.
- **Called by**: `MainTabView` (sheet auto-presented), `GigiQuickTalkIntent.perform`, `ChatView`.
- **Status**: live
- **Removability**: medium — entry point principale del demo, ma sostituibile con un orchestratore unificato.

## Presence Mode (always-available session)
- **Entry point**: `02_GIGI_APP/GIGI/PresenceSessionController.swift:13` — `final class PresenceSessionController`
- **What it does**: sessione lunga sleeping↔listening↔thinking↔speaking. Bypassa screen-dark/low-power suppression. Espone state machine a Live Activity + UI.
- **Files involved**: `PresenceSessionController.swift`, `PresenceView.swift`, `GigiPresenceIntent.swift`, `GigiPresenceAppGroup.swift`
- **Calls / depends on**: `GigiAudioManager`, `GigiWakeWordEngine`, `GigiSmartOrchestrator`, `GigiLiveActivityController`, `GigiPresenceAppGroup`.
- **Called by**: `MainTabView` (Presence tab + sheet), `GIGIApp.scenePhase`, AppIntents widget.
- **Status**: live (ma dipende da WakeWord che è kill-switched #102 → comportamento parziale)
- **Removability**: medium — flusso parallelo a Quick Talk; semantica "always-available" è di scope MVP, ma effettivamente non sempre attiva.

## Background Talk Intent (Shortcut-piped voice)
- **Entry point**: `02_GIGI_APP/GIGI/GigiBackgroundTalkIntent.swift` — `struct GigiBackgroundTalkIntent` (+ `LocalAnswer` pattern router)
- **What it does**: AppIntent background che riceve testo dittato da iOS Shortcuts, lo invia all'harness o lo risolve on-device per query banali (orario, data), parla la risposta via Speak Text.
- **Files involved**: `GigiBackgroundTalkIntent.swift`
- **Calls / depends on**: `GigiHarnessClient.agentRun`, `Contacts`, `UserNotifications`.
- **Called by**: iOS Shortcut user-built ("Talk to GIGI").
- **Status**: live
- **Removability**: medium — utile per "demo senza foreground" ma duplica capability con Quick Talk; in un rework può essere consolidato.

## Wake Word Engine (currently kill-switched)
- **Entry point**: `02_GIGI_APP/GIGI/GigiWakeWordEngine.swift:31` — `final class GigiWakeWordEngine`
- **What it does**: SFSpeechRecognizer en-US on-device + AVAudioEngine + restart 50s gap-free. Trigger: "hey gigi" / "ok gigi" / "gigi". Pausa su low-power, call, app inactive >2min.
- **Files involved**: `GigiWakeWordEngine.swift`
- **Calls / depends on**: SFSpeechRecognizer, AVAudioEngine, CallKit, UIKit.
- **Called by**: `GigiAudioManager`, `PresenceSessionController`, `GigiRealtimeEngine` (riferimento), `SoundEngine` (riferimento), `DashboardView` (toggle UI).
- **Status**: experimental — kill switch #102 attivo (iOS non permette mic in background continuo non-VoIP).
- **Removability**: medium — il flag `userDefaultsEnabledKey` è letto da Presence/Dashboard. Disabilitato a runtime ma classe mai rimossa, ~600 righe.
- **Note**: candidate cull per il rework (sostituito da Action Button + Back Tap + AppIntent).

## Control Center button → listen
- **Entry point**: `02_GIGI_APP/GIGIWidget/GIGIWidgetControl.swift:14` — `struct GIGIControlOpenIntent` (iOS 18+)
- **What it does**: bottone Control Center "Talk to GIGI" → handshake UserDefaults App Group → app foregrounded → Presence start + listening.
- **Files involved**: `GIGIWidgetControl.swift`, `GIGIApp.swift` (handler)
- **Calls / depends on**: App Group `group.com.gigi.presence`, `PresenceSessionController`, `GigiSmartOrchestrator`.
- **Called by**: iOS Control Center.
- **Status**: live (iOS 18+)
- **Removability**: medium — minor feature isolata.

## Audio session coordinator (state machine)
- **Entry point**: `02_GIGI_APP/GIGI/GigiAudioManager.swift:23` — `final class GigiAudioManager`
- **What it does**: state machine `idle ↔ wakeWordListening ↔ recording ↔ speaking`. Single owner per evitare conflitti AVAudioSession.
- **Files involved**: `GigiAudioManager.swift`
- **Calls / depends on**: `GigiVADEngine`, `GigiWakeWordEngine`, `GigiSpeechService`, `GigiAudioSequestrator`.
- **Called by**: `GigiSmartOrchestrator`, `PresenceSessionController`, `QuickTalkController`, `SettingsView`, `PresenceView`.
- **Status**: live
- **Removability**: low — coordinatore centrale.

## Audio session sequestrator (AVAudioSession lifecycle)
- **Entry point**: `02_GIGI_APP/GIGI/GigiAudioSequestrator.swift:14` — `final class GigiAudioSequestrator`
- **What it does**: ref-count mic users (VAD+Realtime), gestisce playAndRecord/Bluetooth HFP, prewarm 300-500ms, evita background-deactivate (kill timer 30s).
- **Files involved**: `GigiAudioSequestrator.swift`
- **Calls / depends on**: AVAudioSession, UIApplication.
- **Called by**: `GigiAudioManager`, `GigiVADEngine`, `GigiRealtimeEngine`, `GigiSpeechService`.
- **Status**: live
- **Removability**: low — load-bearing per audio routing.

## VAD + STT engine
- **Entry point**: `02_GIGI_APP/GIGI/GigiVADEngine.swift:25` — `class GigiVADEngine`
- **What it does**: AVAudioEngine + SFSpeechRecognizer en-US. Adaptive silence threshold (0.8/1.2/1.8s), noise gate 100ms.
- **Files involved**: `GigiVADEngine.swift`
- **Calls / depends on**: AVAudioEngine, Speech, Accelerate.
- **Called by**: `GigiAudioManager`.
- **Status**: live
- **Removability**: low — used by every voice path.

## TTS speech service
- **Entry point**: `02_GIGI_APP/GIGI/GigiSpeechService.swift:14` — `final class GigiSpeechService`
- **What it does**: AVSpeechSynthesizer wrapper con tones (normal/urgent/calm/excited). Pubblica `onEmptyText` per evitare pill stuck.
- **Files involved**: `GigiSpeechService.swift`
- **Calls / depends on**: AVSpeechSynthesizer, `GigiAudioManager`.
- **Called by**: `GigiSmartOrchestrator`, `GigiActionDispatcher`, `GigiAgentEngine`, `DashboardView`, `GigiWebAgent`.
- **Status**: live
- **Removability**: low.

## Realtime engine (Gemini Live WebSocket)
- **Entry point**: `02_GIGI_APP/GIGI/GigiRealtimeEngine.swift:21` — `final class GigiRealtimeEngine`
- **What it does**: WebSocket verso Gemini `BidiGenerateContent`. Streaming PCM 16kHz, function-calling, jitter-buffered audio out, barge-in.
- **Files involved**: `GigiRealtimeEngine.swift`
- **Calls / depends on**: AVAudioEngine, URLSessionWebSocket, `GigiCloudService`, `GigiAudioSequestrator`.
- **Called by**: `GigiSmartOrchestrator` (callbacks `onTranscript`, `onToolCall`, `onBargein`, `onStreamingUtteranceComplete`), `GigiBrainPipeline` (level 0).
- **Status**: live ma "lazy connect"
- **Removability**: medium — è level 0 della cascade, ma fragile (richiede Gemini key) e potenziale candidate-cull se brain → solo Claude/Foundation.
- **Note**: ramo Gemini Live è un primary dependency con cui se interagiscono altri pezzi (es. handle text-only intents).

## Earcon / haptic sound engine
- **Entry point**: `02_GIGI_APP/GIGI/SoundEngine.swift:15` — `final class SoundEngine`
- **What it does**: sintetizza buffer PCM (sweep, blip, trill) per 5 eventi (wakeWord, taskDone, error, thinking, confirmRequired). Haptics per "thinking".
- **Files involved**: `SoundEngine.swift`
- **Calls / depends on**: AVAudioEngine, UIKit haptics.
- **Called by**: `GigiAudioManager`, `GigiWakeWordEngine`, `GigiRealtimeEngine`, `PresenceSessionController`, `DashboardView`.
- **Status**: live
- **Removability**: high — feedback UX, non funzionale. Rimovibile sostituendo con system sound.

## Smart Orchestrator (turn lifecycle)
- **Entry point**: `02_GIGI_APP/GIGI/GigiSmartOrchestrator.swift:16` — `class GigiSmartOrchestrator`
- **What it does**: receive text → brain pipeline → TTS → action → reset. Possiede draft preview state, Quick Talk callbacks, Presence flag, voice turn IDs.
- **Files involved**: `GigiSmartOrchestrator.swift`
- **Calls / depends on**: `GigiAgentEngine`, `GigiActionDispatcher`, `GigiSpeechService`, `GigiConversationMemory`, `GigiAudioManager`, `GigiRealtimeEngine`, `GigiLiveActivityController`.
- **Called by**: `MainTabView`, `ChatView`, `QuickTalkController`, `PresenceSessionController`, `GIGIApp` (control deeplink).
- **Status**: live
- **Removability**: low — punto di convergenza di ogni flusso voce.

## Brain pipeline (4-level cascade)
- **Entry point**: `02_GIGI_APP/GIGI/GigiBrainPipeline.swift:14` — `final class GigiBrainPipeline`
- **What it does**: cascade level 0 Gemini Live → 1 Foundation Models → 2 Gemini REST → 3 NLU rule-based. Pre-check: high-confidence action intents skippano Gemini Live.
- **Files involved**: `GigiBrainPipeline.swift`
- **Calls / depends on**: `GigiFoundationAgent`, `GigiCloudService`, `GigiNLUEngine`, `GigiRealtimeEngine`.
- **Called by**: `GigiSmartOrchestrator` (via `GigiAgentEngine` / direct).
- **Status**: live
- **Removability**: medium — molta complessità per pochi watt di latency. Cull candidato: collassare a 2 livelli (Foundation+Claude).
- **Note**: lo strato Gemini-REST è duplicato funzionalmente con Claude bridge.

## NLU engine (rule + CoreML + transformer)
- **Entry point**: `02_GIGI_APP/GIGI/GigiNLUEngine.swift:38` — `class GigiNLUEngine`
- **What it does**: pipeline 4-livelli: rule EN → MobileBERT (.mlpackage opzionale) → MaxEntropy (.mlmodel) → ask_cloud fallback. Estrae entities (NLTagger).
- **Files involved**: `GigiNLUEngine.swift`, `GigiNLU.mlmodel`, `GigiNLU_Transformer.mlpackage`, `gigi_labels.json` (resources)
- **Calls / depends on**: CoreML, NaturalLanguage.
- **Called by**: `GigiBrainPipeline`, `GigiAgentEngine`.
- **Status**: live
- **Removability**: medium — locale-only path; se ci si fida solo di Foundation/Claude, è dead weight.

## Foundation Models agent (iOS 18.1+)
- **Entry point**: `02_GIGI_APP/GIGI/GigiFoundationAgent.swift` — `GigiAgentResponse` struct + agent
- **What it does**: classify+extract via Apple Foundation Models on-device (iOS 18.1+). Output strutturato `@Generable` con 12 campi (action, contact, body, ...).
- **Files involved**: `GigiFoundationAgent.swift`, `GigiFoundationSession.swift`
- **Calls / depends on**: `FoundationModels` framework.
- **Called by**: `GigiBrainPipeline` (level 1), `GigiAgentEngine`, `GigiRealtimeEngine`.
- **Status**: live (richiede iOS 18.1 + Apple Intelligence)
- **Removability**: low — primary brain path scelto per #76 V3.

## Agent loop engine (Groq react-loop)
- **Entry point**: `02_GIGI_APP/GIGI/GigiAgentEngine.swift:30` — `final class GigiAgentEngine`
- **What it does**: react-loop max 8 iterazioni, parallel function calling Groq llama-3.3-70b. Fast-path NLU >=0.95 confidence salta il LLM. Tracking costo per turn (~$0.00000015/token).
- **Files involved**: `GigiAgentEngine.swift`
- **Calls / depends on**: `GigiToolRegistry`, `GigiActionDispatcher`, `GigiCloudService`, `GigiNLUEngine`, `GigiPlannerEngine`, `GigiClaudeBridge` (via tool `ask_claude`), `GigiConfirmationPolicyEngine`.
- **Called by**: `GigiSmartOrchestrator`.
- **Status**: live
- **Removability**: low — backbone esecuzione comandi.

## Planner engine (task decomposer)
- **Entry point**: `02_GIGI_APP/GIGI/GigiPlannerEngine.swift:36` — `final class GigiPlannerEngine`
- **What it does**: Groq llama-3.1-8b ~200ms decide isSimple=true/false. Falsi → decompose in subtask con dependency graph.
- **Files involved**: `GigiPlannerEngine.swift`
- **Calls / depends on**: `GigiCloudService` (Groq).
- **Called by**: `GigiAgentEngine` SOLAMENTE (riga 143).
- **Status**: live ma single-caller
- **Removability**: high — un solo callsite; se rework rimuove la branca multi-task, sparisce un'intera classe.

## Day Plan Reasoner (different from planner)
- **Entry point**: `02_GIGI_APP/GIGI/GigiDayPlanReasoner.swift` — engine + types
- **What it does**: dato calendar+prefs+tasks produce piano della giornata vocale-friendly via LLM (Groq). DIVERSO da `GigiPlannerEngine`.
- **Files involved**: `GigiDayPlanReasoner.swift`
- **Calls / depends on**: `GigiCloudService`, `GigiUserProfile`.
- **Called by**: SOLO da `GIGIApp` in DEBUG (`debugRunWithMockData/RealCalendar/LiveSources`). Niente production caller.
- **Status**: experimental
- **Removability**: high — l'engine esiste ma non viene mai esposto come tool runtime; è un blueprint di sub-issue #56-#59 ancora in piano.
- **Note**: candidate dead-code se l'epic #15 viene de-scopata. Nome "PlannerEngine" + "DayPlanReasoner" è confondente — naming va riconsolidato nel rework.

## Cloud service (Groq + Gemini REST)
- **Entry point**: `02_GIGI_APP/GIGI/GigiCloudService.swift` — `JSONAny` + service singleton
- **What it does**: HTTP client Groq + Gemini REST. Espone `extractTasksRaw`, `chatCompletion`, etc.
- **Files involved**: `GigiCloudService.swift`
- **Calls / depends on**: URLSession, `GigiConfig` (API keys).
- **Called by**: `GigiBrainPipeline`, `GigiAgentEngine`, `GigiPlannerEngine`, `GigiDayPlanReasoner`, `GigiTaskExtractor`, `GigiFallbackEngine` (string-fallback), `GigiActionBridge` (web search), `DashboardView` (key validation).
- **Status**: live
- **Removability**: low — cloud LLM gateway.

## Action Bridge (native iOS actions)
- **Entry point**: `02_GIGI_APP/GIGI/GigiActionBridge.swift:33` — `class GigiActionBridge`
- **What it does**: esegue intent legacy "v2" (make_call, send_message, navigate, weather, ...). 30+ azioni native iOS (CallKit, MFMessageCompose, Maps, EventKit, Reminders, MediaPlayer, MPNowPlaying, HomeKit shortcuts).
- **Files involved**: `GigiActionBridge.swift`
- **Calls / depends on**: Contacts, UIKit, EventKit, AVFoundation, MediaPlayer, UserNotifications, `GigiContactsEngine`, `GigiHomeKit`, `GigiCloudService`, `GigiMemory`.
- **Called by**: `GigiActionDispatcher` (via `bridge.execute`), `GigiAgentEngine`, `GigiBackgroundTalkIntent`.
- **Status**: live
- **Removability**: low — superficie di tutte le azioni di sistema.

## Action Dispatcher (intent → action router)
- **Entry point**: `02_GIGI_APP/GIGI/GigiActionDispatcher.swift:10` — `final class GigiActionDispatcher`
- **What it does**: traduce `GigiAgentResponse` / `GigiToolCall` in azione. Tre file partial: core + `+Native` + `+Web`.
- **Files involved**: `GigiActionDispatcher.swift`, `GigiActionDispatcher+Native.swift`, `GigiActionDispatcher+Web.swift`
- **Calls / depends on**: `GigiActionBridge`, `GigiSpeechService`, `GigiMemory`, `GigiConversationMemory`, `GigiLiveActivityController`, `GigiWebAgent`, `GigiComputerUse`.
- **Called by**: `GigiSmartOrchestrator`, `GigiAgentEngine`.
- **Status**: live
- **Removability**: low.

## Tool Registry (38 tool declarations)
- **Entry point**: `02_GIGI_APP/GIGI/GigiToolRegistry.swift` — `FunctionDeclaration` + `JSONSchema` types
- **What it does**: dichiarazione di 38 tool ESposti al modello (Foundation/Groq) + meta-classifier `AskClaudeTool` per delegare al harness.
- **Files involved**: `GigiToolRegistry.swift`
- **Calls / depends on**: `GigiActionDispatcher`, `GigiClaudeBridge`.
- **Called by**: `GigiAgentEngine` (function-calling list), `GigiSmartOrchestrator`, `GigiActionDispatcher+Native/+Web`.
- **Status**: live
- **Removability**: low — schema source of truth.

## Confirmation Policy Engine
- **Entry point**: `02_GIGI_APP/GIGI/GigiConfirmationPolicyEngine.swift:9` — `final class GigiConfirmationPolicyEngine`
- **What it does**: per-tool policy override (send / externalAction / modify). Decide se serve confirm sheet.
- **Files involved**: `GigiConfirmationPolicyEngine.swift`
- **Calls / depends on**: types in `GigiToolRegistry`.
- **Called by**: `GigiAgentEngine`.
- **Status**: live
- **Removability**: medium — utile ma sostituibile da policy inline.

## Fallback engine (error copy)
- **Entry point**: `02_GIGI_APP/GIGI/GigiFallbackEngine.swift:7` — `final class GigiFallbackEngine`
- **What it does**: produce frasi user-facing per errori (mic denied, STT failed, network, agent error). Disambiguation list.
- **Files involved**: `GigiFallbackEngine.swift`
- **Calls / depends on**: `GigiCloudService` (per disambiguation LLM).
- **Called by**: `QuickTalkController`.
- **Status**: live (ma single-caller)
- **Removability**: high — file da 60 righe inlinable in `QuickTalkController`.

## Task Extractor (transcript → todos)
- **Entry point**: `02_GIGI_APP/GIGI/GigiTaskExtractor.swift:15` — `final class GigiTaskExtractor`
- **What it does**: invia transcript a Groq, decode `[ExtractedTask]`, dedup, espone `tasks: [ExtractedTask]` ObservableObject. Surface in `TalkingSessionTaskListView`.
- **Files involved**: `GigiTaskExtractor.swift`
- **Calls / depends on**: `GigiCloudService.extractTasksRaw`.
- **Called by**: `TalkingSessionTaskListView`, `GigiSmartOrchestrator`.
- **Status**: live
- **Removability**: medium — feature isolata, eliminabile se demo non punta su task extraction.

## Tone enrichment (draft message rewrite)
- **Entry point**: `02_GIGI_APP/GIGI/GigiToneEnrichment.swift:15` — `final class GigiToneEnrichment`
- **What it does**: rewrite di draft WhatsApp/iMessage in voice utente (warm/casual, ≤2 sentences, ≤1 emoji) via dedicated `LanguageModelSession` (FoundationModels).
- **Files involved**: `GigiToneEnrichment.swift`
- **Calls / depends on**: `FoundationModels` framework.
- **Called by**: `GigiSmartOrchestrator` (in `presentDraft` flow #47).
- **Status**: live (iOS 18.1+)
- **Removability**: medium — feature di pre-MVP demo, candidate cull se draft preview semplificato.

## GigiWebAgent (WKWebView automation)
- **Entry point**: `02_GIGI_APP/GIGI/GigiWebAgent.swift` — `class GigiWebAgent` + `enum WebScript`
- **What it does**: hidden WKWebView che esegue script WhatsApp Web / TheFork / Google. Persiste sessione (cookie), notifica `gigiWhatsAppNeedsQR`.
- **Files involved**: `GigiWebAgent.swift`, `GigiWebAgent+Vision.swift`
- **Calls / depends on**: WebKit, UIKit.
- **Called by**: `GIGIApp` (attach to window), `GigiActionDispatcher+Web`, `DashboardView` (link banner), `SettingsView` (sheet WhatsApp link).
- **Status**: live
- **Removability**: medium — WhatsApp Web è la unica integrazione messaging cross-platform; rimuovere significa droppare una capability demo.

## Vision-loop web automation (Groq vision)
- **Entry point**: `02_GIGI_APP/GIGI/GigiWebAgent+Vision.swift` — `extension GigiWebAgent` + `VisionAction`
- **What it does**: navigation autonoma multi-step (click/type/scroll/fill) guidata da Groq vision. Loop "see → act → see".
- **Files involved**: `GigiWebAgent+Vision.swift`
- **Calls / depends on**: `GigiCloudService` (vision endpoint), WebKit screenshot.
- **Called by**: `GigiActionDispatcher+Web` (`web_vision_task`).
- **Status**: experimental
- **Removability**: high — branch web-vision overlaps con computer-use harness; spesso cull candidate.

## Computer-use client (harness Playwright)
- **Entry point**: `02_GIGI_APP/GIGI/GigiComputerUse.swift:11` — `final class GigiComputerUse`
- **What it does**: client `/api/ios/computer-use` (Claude + Playwright lato harness). Polling fino a done/awaiting_confirm/failed.
- **Files involved**: `GigiComputerUse.swift`
- **Calls / depends on**: `GigiHarnessClient`.
- **Called by**: `GigiActionDispatcher+Web` (tool `computer_use`, fallback per `web_book_restaurant`/`web_order_food`/`web_search_and_read`).
- **Status**: live
- **Removability**: medium — capability "external action" demo-critical, ma collegata solo a harness.

## Harness HTTP client
- **Entry point**: `02_GIGI_APP/GIGI/GigiHarnessClient.swift:34` — `final class GigiHarnessClient`
- **What it does**: HTTP wrapper verso 14+ endpoint `/api/ios/*` (agent/run, agent/cancel, session, memo, memory, computer-use, push, health). Bearer + Keychain config + retry esponenziale.
- **Files involved**: `GigiHarnessClient.swift`
- **Calls / depends on**: URLSession, `GigiKeychain`.
- **Called by**: `GigiClaudeBridge`, `GigiComputerUse`, `GigiBackgroundTalkIntent`, `GigiBrainDiagnostics`, `GigiApnsSync`, `OnboardingView`, `GigiPairingSheet`, `SettingsView`, `DashboardView`, `SetupDiagnosticView`, `HarnessStatusCard`.
- **Status**: live
- **Removability**: low — cuore della delegation V3.

## Harness WebSocket stream
- **Entry point**: `02_GIGI_APP/GIGI/GigiHarnessClient.swift:551` — `final class GigiHarnessStream` (declared in same file)
- **What it does**: long-lived URLSessionWebSocketTask `/ws/ios/stream` con ping/pong + reconnect exp backoff + missedPongs detection.
- **Files involved**: `GigiHarnessClient.swift` (stesso file)
- **Calls / depends on**: URLSession, `GigiDebugLogger`.
- **Called by**: `GigiClaudeBridge` (mantiene un'istanza lazy).
- **Status**: live
- **Removability**: low — streaming Claude bridge.
- **Note**: `GigiHarnessStream.swift` non esiste come file separato — la classe è definita inline in `GigiHarnessClient.swift` (contraddice `docs/COMPONENTS.md` che la elenca come file).

## Claude Bridge (delegation coordinator)
- **Entry point**: `02_GIGI_APP/GIGI/GigiClaudeBridge.swift:38` — `final class GigiClaudeBridge`
- **What it does**: tradisce eventi Claude CLI (system/assistant/tool_use/tool_result/result) in `.thinking`/`.toolEvent` bubbles. Costruisce snapshot context (profile + calendar + memories) per ogni run.
- **Files involved**: `GigiClaudeBridge.swift`
- **Calls / depends on**: `GigiHarnessStream`, `GigiHarnessClient`, `GigiConversationMemory`, `GigiUserProfile`, `GigiMemory`.
- **Called by**: `GigiAgentEngine` (via tool `ask_claude` in registry), `SettingsView` (Force-Claude toggle), `GigiCommandLogger`.
- **Status**: live
- **Removability**: low — V3 True Agent delegation.

## Harness pairing (QR scan + Keychain)
- **Entry point**: `02_GIGI_APP/GIGI/GigiPairingSheet.swift:18` — `struct GigiPairingSheet`
- **What it does**: state machine: macSetup → scanning → validating → diagnostic → success/failure. Salva URL+secret+deviceId in Keychain, posta `gigiHarnessPairingDidChange`.
- **Files involved**: `GigiPairingSheet.swift`
- **Calls / depends on**: `GigiPairScannerView`, `HarnessQRScanner`, `GigiHarnessClient`, `GigiKeychain`, `SetupDiagnosticView`.
- **Called by**: `MainTabView` (sheet), `OnboardingView`, `SettingsView`.
- **Status**: live
- **Removability**: medium — flow critico ma riassemblabile.

## QR pairing camera scanner
- **Entry point**: `02_GIGI_APP/GIGI/GigiPairScanner.swift:18` — `struct GigiPairScannerView` (+ `HarnessQRScanner`)
- **What it does**: VisionKit `DataScannerViewController` SwiftUI wrapper. Permission handling. Backup AVFoundation in `HarnessQRScanner.swift` (legacy).
- **Files involved**: `GigiPairScanner.swift`, `HarnessQRScanner.swift`
- **Calls / depends on**: VisionKit, AVFoundation, AudioToolbox.
- **Called by**: `GigiPairingSheet`, `OnboardingView`, `SettingsView`.
- **Status**: live (ma 2 implementazioni overlap)
- **Removability**: medium — `HarnessQRScanner` è legacy AVFoundation; `GigiPairScanner` è VisionKit-based. Duplicate.
- **Note**: candidate dedup esplicita.

## mDNS / Bonjour LAN discovery
- **Entry point**: `02_GIGI_APP/GIGI/GigiMDNSDiscovery.swift:14` — `final class GigiMDNSDiscovery`
- **What it does**: NWBrowser `_gigi._tcp.local.` per discovery automatico harness su LAN. Espone peer + TXT.
- **Files involved**: `GigiMDNSDiscovery.swift`
- **Calls / depends on**: Network framework.
- **Called by**: SOLO da se stesso (grep restituisce 1 file: il file stesso). `Info.plist` lista `_gigi._tcp` in NSBonjourServices.
- **Status**: dead-code candidato
- **Removability**: high — nessun call site esterno trovato. Era previsto per LAN-only mode mai attivato.

## APNS token sync to harness
- **Entry point**: `02_GIGI_APP/GIGI/GigiApnsSync.swift:25` — `enum GigiApnsSync`
- **What it does**: persiste token in Keychain, sincronizza a harness con fingerprint SHA256(URL+secret) per detect cambio backend; retry su `didBecomeActive`.
- **Files involved**: `GigiApnsSync.swift`
- **Calls / depends on**: `GigiKeychain`, `GigiHarnessClient`, CryptoKit.
- **Called by**: `GigiAppDelegate`, `GIGIApp.scenePhase`.
- **Status**: live
- **Removability**: low — APNS pipeline.

## Harness diagnostics & offline banner
- **Entry point**: `02_GIGI_APP/GIGI/GigiBrainDiagnostics.swift:14` — `final class GigiBrainDiagnostics` + `02_GIGI_APP/GIGI/HarnessOfflineBanner.swift`
- **What it does**: cron `/api/ios/health` poll, espone `harnessStatus` (online/degraded/offline/unknown) + `lastTurnPath`. Banner top-edge mostra "GIGI offline".
- **Files involved**: `GigiBrainDiagnostics.swift`, `HarnessOfflineBanner.swift`
- **Calls / depends on**: `GigiHarnessClient`.
- **Called by**: `GIGIApp.task`, `MainTabView`, `DashboardView`.
- **Status**: live
- **Removability**: low — UX feedback essenziale.

## Setup diagnostic gate (post-pair)
- **Entry point**: `02_GIGI_APP/GIGI/SetupDiagnosticView.swift:24` — `struct SetupDiagnosticView`
- **What it does**: 5s polling `/api/setup/diagnostics` post-pair. Mostra check colorati + hint copyable. Bottone Finalize attivato solo a critical=green.
- **Files involved**: `SetupDiagnosticView.swift`, `Walkthroughs.swift`
- **Calls / depends on**: `GigiHarnessClient.diagnose`, `Walkthroughs`.
- **Called by**: `GigiPairingSheet`.
- **Status**: live
- **Removability**: medium — UX polish, riducibile a "ok/ko" minimal.

## Harness status card (settings panel)
- **Entry point**: `02_GIGI_APP/GIGI/HarnessStatusCard.swift:14` — `struct HarnessStatusCard`
- **What it does**: 15s poll `/api/ios/status` mostrando tunnel mode, URL redacted, last request, count/h, latency button.
- **Files involved**: `HarnessStatusCard.swift`
- **Calls / depends on**: `GigiHarnessClient.status` + `health`.
- **Called by**: `SettingsView`.
- **Status**: live
- **Removability**: high — Settings card ricca; cull candidato per UI minimal.

## Diagnostic walkthroughs
- **Entry point**: `02_GIGI_APP/GIGI/Walkthroughs.swift` — `enum WalkthroughStep` + dictionary
- **What it does**: 5 procedure hardcoded (text + copyable command) per check non-fixable da harness (es. "Apri Settings → Live Activities").
- **Files involved**: `Walkthroughs.swift`
- **Calls / depends on**: nessuna.
- **Called by**: `SetupDiagnosticView`, `OnboardingView`.
- **Status**: live
- **Removability**: high — contenuto statico estraibile a JSON, file 100% rimovibile a costo basso.

## GigiMemory (CloudKit key/value)
- **Entry point**: `02_GIGI_APP/GIGI/GigiMemory.swift:16` — `final class GigiMemory`
- **What it does**: CloudKit private DB per profile utente. Convention key prefix: `contact:`, `routine:`, `pref:`, `place:`, `person:`. In-memory cache.
- **Files involved**: `GigiMemory.swift`
- **Calls / depends on**: CloudKit, `GigiVectorStore` (per remember/recall semantica).
- **Called by**: `GigiActionDispatcher`, `GigiClaudeBridge` (snapshot), `GigiAgentEngine`, `GigiToolRegistry`, `OnboardingView`.
- **Status**: live
- **Removability**: low — store memoria persistente.

## Conversation memory (chat history)
- **Entry point**: `02_GIGI_APP/GIGI/GigiConversationMemory.swift:25` — `final class GigiConversationMemory`
- **What it does**: ObservableObject con `messages: [GigiMessage]`. Roles: user / gigi / thinking / toolEvent. Persistenza session 1h TTL (UserDefaults).
- **Files involved**: `GigiConversationMemory.swift`
- **Calls / depends on**: nessuna esterna.
- **Called by**: `ChatView`, `GigiSmartOrchestrator`, `GigiAgentEngine`, `GigiClaudeBridge`, `GigiActionDispatcher`.
- **Status**: live
- **Removability**: low.

## Vector store (on-device semantic search)
- **Entry point**: `02_GIGI_APP/GIGI/GigiVectorStore.swift:39` — `final class GigiVectorStore`
- **What it does**: NLEmbedding word-level + cosine vDSP. 5 namespace (contacts/preferences/routines/places/context). Cap 500 entry, evict stale.
- **Files involved**: `GigiVectorStore.swift`
- **Calls / depends on**: NaturalLanguage, Accelerate.
- **Called by**: `GIGIApp.task` (preload), `GigiMemory` (recall semantic).
- **Status**: live
- **Removability**: medium — pregevole architetturalmente ma load minimo.

## User profile (form-fill data)
- **Entry point**: `02_GIGI_APP/GIGI/GigiUserProfile.swift` — `struct UserProfileData` + `MVPPreferences` + singleton
- **What it does**: persiste profile (name/email/phone/address) per autocompile checkout/booking. Anche soft prefs MVP via `seedMVPPreferencesIfNeeded`.
- **Files involved**: `GigiUserProfile.swift`
- **Calls / depends on**: `GigiKeychain`, `GigiMemory` (CSV round-trip per array).
- **Called by**: `GIGIApp.task`, `OnboardingView`, `SettingsView`, `GigiClaudeBridge` (snapshot).
- **Status**: live
- **Removability**: low.

## MVP preferences (7 soft prefs)
- **Entry point**: `02_GIGI_APP/GIGI/GigiUserProfile.swift` — `struct MVPPreferences`
- **What it does**: 7 prefs (tone, workHours, morningFocus, vipContacts, travelBuffer, food, routine). Iniettate nei prompt LLM.
- **Files involved**: `GigiUserProfile.swift` (stesso file)
- **Calls / depends on**: stesso GigiUserProfile.
- **Called by**: `GigiClaudeBridge`, `GigiAgentEngine`, `GigiDayPlanReasoner`.
- **Status**: live
- **Removability**: medium — feature scope #13.

## Memory hint toast
- **Entry point**: `02_GIGI_APP/GIGI/MemoryHintView.swift` — `struct MemoryHintView`
- **What it does**: toast 2s "💭 GIGI ha usato la pref X" quando `gigiPreferenceApplied` notification arriva. Demo affordance #79.
- **Files involved**: `MemoryHintView.swift`
- **Calls / depends on**: NotificationCenter only.
- **Called by**: NESSUNO grep-able come `MemoryHintView()`. File presente ma non instanziato in MainTabView/ChatView visto nei file letti.
- **Status**: dead-code candidato (file standalone, nessun callsite trovato)
- **Removability**: high — file 50 righe, presumibile residuo di sub-issue non chiusa.

## QuickTalk command history store
- **Entry point**: `02_GIGI_APP/GIGI/QuickTalkCommandStore.swift:13` — `final class QuickTalkCommandStore`
- **What it does**: persiste ultimi 20 comandi Quick Talk in UserDefaults (transcript + response + duration + success).
- **Files involved**: `QuickTalkCommandStore.swift`
- **Calls / depends on**: UserDefaults.
- **Called by**: `QuickTalkController`.
- **Status**: live
- **Removability**: medium — telemetry loggable, sostituibile da CommandLogger.

## Contacts engine (fuzzy resolver)
- **Entry point**: `02_GIGI_APP/GIGI/GigiContactsEngine.swift:11` — `final class GigiContactsEngine`
- **What it does**: CNContactStore + relationship aliases italiano/inglese (mamma/mom/...). Ritorna (phone, displayName) o disambig.
- **Files involved**: `GigiContactsEngine.swift`
- **Calls / depends on**: Contacts framework.
- **Called by**: `GigiActionBridge`, `GigiActionDispatcher+Native`, `GigiBackgroundTalkIntent`, `GigiAgentEngine`.
- **Status**: live
- **Removability**: low — usato da call/message/email tools.

## HomeKit integration
- **Entry point**: `02_GIGI_APP/GIGI/GigiHomeKit.swift:30` — `final class GigiHomeKit`
- **What it does**: light/thermostat/lock control via voice. HMHomeManager wrapper, accessory cache, normalized name match.
- **Files involved**: `GigiHomeKit.swift`
- **Calls / depends on**: HomeKit framework.
- **Called by**: `GigiActionBridge`, `SettingsView`, `DashboardView`.
- **Status**: live
- **Removability**: high — feature isolata, demo-rare, candidate cull (HomeKit usage richiede entitlement aggiuntivo + permission).

## Keychain wrapper
- **Entry point**: `02_GIGI_APP/GIGI/GigiKeychain.swift` — `enum GigiKeychain`
- **What it does**: thin wrapper SecItem* per Generic Password. Notifica `gigiHarnessPairingDidChange` su update key relevant.
- **Files involved**: `GigiKeychain.swift`
- **Calls / depends on**: Security framework.
- **Called by**: 20+ files (Config, Onboarding, Pairing, ApnsSync, ClaudeBridge, ...).
- **Status**: live
- **Removability**: low — store secrets centrale.

## Auth manager (Google Sign-In)
- **Entry point**: `02_GIGI_APP/GIGI/GigiAuthManager.swift:6` — `class GigiAuthManager`
- **What it does**: Google Sign-In + scopes `generative-language.retriever` per Gemini Live. Persiste user info (name, email, photo).
- **Files involved**: `GigiAuthManager.swift`
- **Calls / depends on**: GoogleSignIn SDK.
- **Called by**: `GIGIApp`, `MainTabView`, `Info.plist` URL scheme handler.
- **Status**: live
- **Removability**: high — l'unico uso reale dei token è alimentare Gemini Live; se la cascade level 0 viene rimossa, sparisce anche Google Sign-In. Forte candidate cull.
- **Note**: Google Sign-In è il primo "tassello pesante" runtime (SDK + entitlements + plist) che porta una sola feature dependent (Gemini Live).

## Config (API keys storage)
- **Entry point**: `02_GIGI_APP/GIGI/GigiConfig.swift:3` — `enum GigiConfig`
- **What it does**: get/set per Groq + Gemini API keys. Migration one-time da Gemini key slot.
- **Files involved**: `GigiConfig.swift`
- **Calls / depends on**: `GigiKeychain`, Bundle Info.plist fallback.
- **Called by**: `GigiCloudService`, `OnboardingView`, `SettingsView`.
- **Status**: live
- **Removability**: low — wrapper minimale.

## Chat view
- **Entry point**: `02_GIGI_APP/GIGI/ChatView.swift:3` — `struct ChatView`
- **What it does**: scrollable chat history (4 message types), text input, mic button, header con stato (Ready/Listening/Thinking/Speaking).
- **Files involved**: `ChatView.swift`
- **Calls / depends on**: `GigiSmartOrchestrator`, `GigiConversationMemory`, `QuickTalkController`, `PresenceSessionController`.
- **Called by**: `MainTabView` (tab 0).
- **Status**: live
- **Removability**: medium — UI riassemblabile.

## Dashboard view
- **Entry point**: `02_GIGI_APP/GIGI/DashboardView.swift:9` — `struct DashboardView`
- **What it does**: status overview (groqReady, whatsappLinked, profileScore, memoryCount, homeKitCount). Quick setup actions.
- **Files involved**: `DashboardView.swift`
- **Calls / depends on**: `GigiBrainDiagnostics`, `GigiWakeWordEngine`, `GigiHomeKit`, `GigiMemory`, `GigiUserProfile`, `GigiWebAgent`.
- **Called by**: `MainTabView` (tab 2).
- **Status**: live
- **Removability**: medium — schermata completa di setup hint riducibile.

## Settings view
- **Entry point**: `02_GIGI_APP/GIGI/SettingsView.swift:20` — `struct SettingsView`
- **What it does**: API keys (Groq+Gemini), Wake word toggle, harness section, brain mode (Force Claude), TTS rate, memory count, debug.
- **Files involved**: `SettingsView.swift`
- **Calls / depends on**: tutti gli engine principali (config + audio + presence + harness + homekit + memory).
- **Called by**: `MainTabView` (tab 3).
- **Status**: live
- **Removability**: medium — molte sub-section coltabili (Force Claude toggle, Wake word toggle disabled #102).

## Quick Talk overlay
- **Entry point**: `02_GIGI_APP/GIGI/QuickTalkView.swift:7` — `struct QuickTalkView`
- **What it does**: overlay sheet "Siri-style" con waveform listening / dots thinking / response text. Continuous mode hint.
- **Files involved**: `QuickTalkView.swift`
- **Calls / depends on**: `QuickTalkController`.
- **Called by**: `MainTabView` (sheet).
- **Status**: live
- **Removability**: medium.

## Presence companion view
- **Entry point**: `02_GIGI_APP/GIGI/PresenceView.swift:7` — `struct PresenceView`
- **What it does**: in-app companion Presence. State orb, last transcript, mute/stop.
- **Files involved**: `PresenceView.swift`
- **Calls / depends on**: `PresenceSessionController`, `GigiAudioManager`.
- **Called by**: `MainTabView` (sheet).
- **Status**: live
- **Removability**: medium.

## Talking Session task list overlay
- **Entry point**: `02_GIGI_APP/GIGI/TalkingSessionTaskListView.swift:3` — `struct TalkingSessionTaskListView`
- **What it does**: overlay flottante draggable + collapsible che mostra task estratti durante una Presence session.
- **Files involved**: `TalkingSessionTaskListView.swift`
- **Calls / depends on**: `GigiTaskExtractor`.
- **Called by**: `MainTabView` (when presence.isActive).
- **Status**: live
- **Removability**: high — feature niche (#14 sub 3/3), dropable.

## Draft message preview sheet
- **Entry point**: `02_GIGI_APP/GIGI/DraftMessagePreviewSheet.swift:5` — `struct DraftMessagePreviewSheet`
- **What it does**: sheet Send/Edit/Cancel sopra ChatView quando `pendingDraft` è settato. Mostra contact + body editable.
- **Files involved**: `DraftMessagePreviewSheet.swift`
- **Calls / depends on**: `GigiSmartOrchestrator.pendingDraft`.
- **Called by**: NESSUNO grep-able come `DraftMessagePreviewSheet()`. Solo file standalone.
- **Status**: dead-code candidato (definito ma mai presentato dal codice letto)
- **Removability**: high — file 60 righe.
- **Note**: probabile residuo #47 wired solo lato orchestrator.

## Permission confirmation sheet
- **Entry point**: `02_GIGI_APP/GIGI/PermissionConfirmationSheet.swift` — `enum PermissionPayload` + sheet
- **What it does**: sheet "meaningful action" generic per message/calendar/reminder/followUpTask/scheduleSwap. Ogni payload ha header/badge.
- **Files involved**: `PermissionConfirmationSheet.swift`
- **Calls / depends on**: nessuna esterna.
- **Called by**: NESSUNO grep-able come `PermissionConfirmationSheet()`. Solo definizione.
- **Status**: dead-code candidato
- **Removability**: high — feature di scope #77 mai instradata.

## Live Activity controller (3 activity types)
- **Entry point**: `02_GIGI_APP/GIGI/GigiLiveActivityController.swift:5` — `final class GigiLiveActivityController`
- **What it does**: gestisce 3 Activity simultanee mutuamente esclusive: turnActivity (Shazam-pill), presenceActivity, monitoringActivity. State machine `GigiPhase`.
- **Files involved**: `GigiLiveActivityController.swift`, `GigiActivityAttributes.swift`
- **Calls / depends on**: ActivityKit.
- **Called by**: `MainTabView`, `GigiSmartOrchestrator`, `GigiActionDispatcher`, `PresenceSessionController`, `GigiAgentEngine`.
- **Status**: live
- **Removability**: low — Dynamic Island è demo-critical (#9).

## Activity attributes & GigiPhase enum
- **Entry point**: `02_GIGI_APP/GIGI/GigiActivityAttributes.swift:11` — `struct GigiActivityAttributes` + `enum GigiPhase`
- **What it does**: shared types tra app e Widget Extension. 9 fasi (listening/thinking/executing/done/sleeping/speaking/followUp/muted/error).
- **Files involved**: `GigiActivityAttributes.swift`
- **Calls / depends on**: ActivityKit.
- **Called by**: app target + widget target.
- **Status**: live
- **Removability**: low — schema condiviso.

## Presence app group bridge (widget↔app)
- **Entry point**: `02_GIGI_APP/GIGI/GigiPresenceAppGroup.swift:13` — `final class GigiPresenceAppGroup`
- **What it does**: UserDefaults shared `group.com.gigi.presence` + Darwin notifications cross-process. 4 commands (start/mute/unmute/stop).
- **Files involved**: `GigiPresenceAppGroup.swift`
- **Calls / depends on**: CFNotificationCenter, UserDefaults.
- **Called by**: AppIntents widget, `PresenceSessionController`.
- **Status**: live
- **Removability**: low.

## Presence AppIntents (start/stop/mute)
- **Entry point**: `02_GIGI_APP/GIGI/GigiPresenceIntent.swift:5` — 4 struct AppIntent
- **What it does**: 4 intents: GigiStartPresenceIntent (openApp=true), GigiStopPresenceIntent, GigiMutePresenceIntent, GigiUnmutePresenceIntent. Eseguiti da Dynamic Island buttons.
- **Files involved**: `GigiPresenceIntent.swift`
- **Calls / depends on**: `GigiPresenceAppGroup`.
- **Called by**: widget Live Activity buttons (`GigiLiveActivityWidget`).
- **Status**: live
- **Removability**: low.

## Quick Talk AppIntent + AppShortcuts
- **Entry point**: `02_GIGI_APP/GIGI/GigiQuickTalkIntent.swift:8` — `struct GigiQuickTalkIntent` + `GigiAppShortcuts`
- **What it does**: AppIntent foreground "Open GIGI" → `QuickTalkController.startContinuous()`. Registered come AppShortcut Spotlight/Action Button.
- **Files involved**: `GigiQuickTalkIntent.swift`
- **Calls / depends on**: `QuickTalkController`.
- **Called by**: Action Button, Spotlight, Siri suggestions.
- **Status**: live
- **Removability**: low — entry hardware trigger.

## Live Activity widget (Dynamic Island UI)
- **Entry point**: `02_GIGI_APP/GIGIWidget/GigiLiveActivityWidget.swift:11` — `struct GigiLiveActivityWidget`
- **What it does**: render Dynamic Island (compact/expanded/minimal) + Lock Screen banner per ogni `GigiPhase`. Buttons mute/stop AppIntent-driven.
- **Files involved**: `GigiLiveActivityWidget.swift`, `GigiActivityAttributes.swift` (shared)
- **Calls / depends on**: WidgetKit, ActivityKit, `GigiPresenceIntent`.
- **Called by**: iOS system (registered in `GIGIWidgetBundle`).
- **Status**: live
- **Removability**: low.

## Control Center widget button
- **Entry point**: `02_GIGI_APP/GIGIWidget/GIGIWidgetControl.swift:14` — `struct GIGIWidgetControl` (iOS 18+)
- **What it does**: ControlWidget "Talk to GIGI" mic.fill button → `GIGIControlOpenIntent`.
- **Files involved**: `GIGIWidgetControl.swift`
- **Calls / depends on**: WidgetKit ControlWidget API (iOS 18).
- **Called by**: registered in `GIGIWidgetBundle`.
- **Status**: live (iOS 18+)
- **Removability**: medium — feature additiva.

## Boilerplate timeline widget (Xcode default)
- **Entry point**: `02_GIGI_APP/GIGIWidget/GIGIWidget.swift` — `struct Provider: AppIntentTimelineProvider` + `SimpleEntry`
- **What it does**: timeline widget di default Xcode che mostra "Time:" + clock. Configurazione `ConfigurationAppIntent` con `favoriteEmoji` (esempio).
- **Files involved**: `GIGIWidget.swift`, `AppIntent.swift` (configuration)
- **Calls / depends on**: WidgetKit only.
- **Called by**: NESSUNO — non è registrato in `GIGIWidgetBundle.body` (che lista solo `GigiLiveActivityWidget` e `GIGIWidgetControl`).
- **Status**: dead-code (template Xcode mai rimosso)
- **Removability**: high — 2 file circa 100 righe templated, zero feature value. Cull immediato.
- **Note**: il file mostra "Created by Corte leonardo 17/04/26" — è il timeline widget generato automaticamente da Xcode che nessuno ha rimosso.

## Debug logger (remote ingest)
- **Entry point**: `02_GIGI_APP/GIGI/GigiDebugLogger.swift` — duplicato sopra. Inserito qui per indicizzazione.
- (vedi sopra)

## Brain diagnostics (harness reachability)
- **Entry point**: `02_GIGI_APP/GIGI/GigiBrainDiagnostics.swift` — vedi sopra "Harness diagnostics".

## Command logger (Quick Talk telemetry)
- **Entry point**: `02_GIGI_APP/GIGI/GigiCommandLogger.swift:24` — `final class GigiCommandLogger`
- **What it does**: persiste fino a 200 entry `QuickTalkLog` (transcript, response, tools, latencies STT/agent/TTS, channel) in JSON file documents.
- **Files involved**: `GigiCommandLogger.swift`
- **Calls / depends on**: FileManager, `GigiClaudeBridge` (riferimento type).
- **Called by**: `QuickTalkController` (e `GigiClaudeBridge`).
- **Status**: live
- **Removability**: medium — telemetria sostituibile da `os_log`/Sentry.

## Voice contracts (cross-channel types)
- **Entry point**: `02_GIGI_APP/GIGI/GigiVoiceContracts.swift:7` — value types
- **What it does**: enum `GigiVoiceSessionState`, `GigiChannel` (iosQuickTalk/iosPresence/telegram/whatsapp), `GigiAudioMode`. Definito a M0 per future channel parity.
- **Files involved**: `GigiVoiceContracts.swift`
- **Calls / depends on**: nessuna.
- **Called by**: `GigiCommandLogger`, `QuickTalkController` (channel field).
- **Status**: live (poco utilizzato in iOS — telegram/whatsapp sono future)
- **Removability**: medium — types definiti per cross-channel ma solo iOS realmente cabled.

---

## Note finali sui file di config (non capability ma rilevanti)

- `02_GIGI_APP/GIGIApp.xcconfig` — config debug/release symbol.
- `02_GIGI_APP/Config.example.xcconfig` — template per signing locale.
- `02_GIGI_APP/GIGIWidgetExtension.entitlements` — entitlements widget (App Group).
- `02_GIGI_APP/GIGI/Info.plist` — `NSBonjourServices`, `NSCameraUsageDescription`, URL schemes (`gigi://`).
- `02_GIGI_APP/README_SETUP.md` — setup specifico app iOS.
