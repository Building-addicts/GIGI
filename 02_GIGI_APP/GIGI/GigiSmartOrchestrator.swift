import Combine
import Foundation
import SwiftUI
import UIKit

// MARK: - GigiSmartOrchestrator
//
// Conversation coordinator. Owns the high-level turn lifecycle:
//   receive text → brain pipeline → TTS → action → reset
//
// Heavy logic lives in dedicated classes:
//   GigiBrainPipeline    — 4-level AI response cascade
//   GigiActionDispatcher — intent execution + realtime tool calls

@MainActor
class GigiSmartOrchestrator: ObservableObject {
    static let shared = GigiSmartOrchestrator()

    // MARK: - Published state

    @Published var status          = "GIGI: Ready"
    @Published var isListening     = false
    @Published var isThinking      = false
    @Published var bannerMessage   = ""
    @Published var showGatewayInstallPrompt = false

    // MARK: - Draft preview (Sub #47 — WhatsApp/iMessage draft Send/Edit/Cancel sheet)

    struct PendingDraft: Equatable {
        let contact: String
        let platform: String  // "whatsapp", "imessage"
        var body: String
        let raw: String       // pre-enrichment, for "show original"
    }
    @Published var showDraftPreview: Bool = false
    @Published var pendingDraft: PendingDraft?

    // MARK: - Contact disambiguation (bug #017 — multi-match safety)
    //
    // When the user says "Call Marco" and Contacts has 2+ Marcos, GIGI shows
    // a sheet listing all matches. User taps the intended one → dispatch
    // proceeds. User taps Cancel → action aborted. After the first pick,
    // GigiMemory remembers it so subsequent "Call Marco" goes straight
    // through (no popup repetition).
    //
    // The state is published; ChatView observes and presents a
    // confirmationDialog. The completion closure is invoked once by the UI
    // and resolves a CheckedContinuation in GigiActionBridge.

    struct ContactCandidate: Identifiable, Hashable {
        let id = UUID()
        let phone: String
        let name: String
    }

    struct ContactDisambiguationState: Identifiable {
        let id = UUID()
        let query: String           // user-spoken name, e.g. "Marco"
        let candidates: [ContactCandidate]
        let actionLabel: String     // "call", "message", "facetime"
        let completion: (ContactCandidate?) -> Void
    }

    @Published var contactDisambiguation: ContactDisambiguationState?

    func presentContactDisambiguation(
        query: String,
        candidates: [(phone: String, name: String)],
        actionLabel: String,
        completion: @escaping (ContactCandidate?) -> Void
    ) {
        let mapped = candidates.map { ContactCandidate(phone: $0.phone, name: $0.name) }
        contactDisambiguation = ContactDisambiguationState(
            query: query,
            candidates: mapped,
            actionLabel: actionLabel,
            completion: completion
        )
    }

    func presentDraft(contact: String, platform: String, body: String, raw: String) {
        pendingDraft = PendingDraft(contact: contact, platform: platform, body: body, raw: raw)
        showDraftPreview = true
    }

    @discardableResult
    func sendDraft() async -> String {
        guard let d = pendingDraft else { return "no draft" }
        print("DRAFT MOCK SEND: to=\(d.contact) platform=\(d.platform) body.length=\(d.body.count)")
        speech.speak("Sent to \(d.contact).")
        memory.addGigi("Sent to \(d.contact) on \(d.platform.capitalized): \"\(d.body)\"")
        showDraftPreview = false
        pendingDraft = nil
        return "Sent (mock) to \(d.contact)."
    }

    func cancelDraft() {
        guard let d = pendingDraft else { return }
        speech.speak("Cancelled.")
        memory.addGigi("Draft to \(d.contact) cancelled.")
        showDraftPreview = false
        pendingDraft = nil
    }

    // MARK: - Dependencies

    private let agentEngine  = GigiAgentEngine.shared
    private let dispatcher   = GigiActionDispatcher.shared
    private let speech       = GigiSpeechService.shared
    private let memory       = GigiConversationMemory.shared

    // pendingCallContact removed (2026-05-11, zombie audit): was assigned by
    // setPendingCallAction but never read elsewhere.

    // Turn finalization: completeWithDone is deferred until TTS reports finished so the
    // pill stays in `.speaking` while the synthesizer plays. `pendingDoneMessage` carries
    // the banner; `doneSafetyTask` fires it after 8s if TTS never reports back (cancel,
    // crash, empty buffer, etc.).
    private var pendingDoneMessage: String?
    private var doneSafetyTask: Task<Void, Never>?
    private var currentVoiceTurnId: String?

    // MARK: - Quick Talk callbacks (set by QuickTalkController)
    var onQuickTalkStateChange: ((QuickTalkController.Phase) -> Void)?
    var onQuickTalkTranscript:  ((String) -> Void)?
    var onQuickTalkResponse:    ((String) -> Void)?
    var onQuickTalkFinished:    ((Bool) -> Void)?   // Bool = success

    private var isQuickTalkSession = false

    // MARK: - Presence Mode flag (set by PresenceSessionController)
    var isPresenceActive = false

    private init() {
        GigiDebugLogger.log("GigiSmartOrchestrator init START")
        GigiAudioManager.shared.onTranscription = { [weak self] text in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isListening = false
                await self.process(text: text)
            }
        }
        GigiAudioManager.shared.onSilenceDetected = { [weak self] in
            Task { @MainActor [weak self] in self?.isListening = false }
        }
        GigiAudioManager.shared.onListeningFailed = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stopMicCapture()
                self.status     = "GIGI: Ready"
                self.isThinking = false
                GigiAudioManager.shared.startWakeWordListening()
            }
        }
        // TTS finished → complete the turn (close the pill) deferred from handleResult.
        GigiAudioManager.shared.onSpeakingFinished = { [weak self] in
            Task { @MainActor [weak self] in self?.fireDone() }
        }
        // T8: empty-speech safety net. If any call site (DashboardView intro/outro,
        // ActionDispatcher confirms, WebAgent) passes "" to speak(), force the pill
        // to close so it does not dangle in .thinking forever.
        GigiSpeechService.shared.onEmptyText = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                GigiDebugLogger.voiceEvent("orchestrator.onEmptyText", turnId: self.currentVoiceTurnId)
                self.pendingDoneMessage = nil
                self.doneSafetyTask?.cancel()
                self.doneSafetyTask = nil
                // In presence / quickTalk the AudioManager follow-up window owns the pill —
                // forcing completeWithDone here races and leaves the pill stuck (#99).
                // Mirror finalizeTurnNow's policy: only close the pill outside those modes.
                if !GigiAudioManager.shared.presenceMode && !self.isQuickTalkSession {
                    await GigiLiveActivityController.shared.completeWithDone(message: "Done.")
                }
                self.status = "GIGI: Ready"
                self.isThinking = false
                self.currentVoiceTurnId = nil
            }
        }
        // Wire interim events from agent loop → status bar + sound/haptics
        agentEngine.onInterimEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .thinking(let i):
                if i > 0 {
                    self.status = "GIGI: ancora un momento..."
                    SoundEngine.play(.thinking)   // haptic-only pulse
                }
            case .toolStarted(let name):
                self.status = "GIGI: \(self.toolCaption(name))..."
                SoundEngine.impact(.light)
            case .toolCompleted:
                SoundEngine.impact(.soft)
            case .waitingForConfirmation(let req):
                self.status = "GIGI: in attesa di conferma..."
                self.showBanner("⚠️ \(req.summary)", autoHideAfter: 5)
            }
        }
        GigiDebugLogger.log("GigiSmartOrchestrator init END")
    }

    // MARK: - Gateway helpers

    func refreshGatewayInstallPrompt() {
        showGatewayInstallPrompt = !UserDefaults.standard.bool(forKey: GigiGateway.isInstalledUserDefaultsKey)
    }
    // markGatewayShortcutInstalled() removed (2026-05-11, zombie audit): no call sites.
    func openGatewayShortcutDownloadPage() {
        // Open Shortcuts app directly. The iCloud link is user-specific — guide them to
        // create a shortcut named "GIGI_Gateway" that accepts text and runs a Phone call action.
        let shortcutsApp = URL(string: "shortcuts://")!
        if UIApplication.shared.canOpenURL(shortcutsApp) {
            UIApplication.shared.open(shortcutsApp)
            showBanner("Create a shortcut named \"GIGI_Gateway\" that accepts text input and calls the contact.", autoHideAfter: 6)
        } else if let icloud = GigiGateway.iCloudDownloadURL {
            UIApplication.shared.open(icloud)
        }
    }
    // setPendingCallAction(contact:prompt:) removed (2026-05-11, zombie audit):
    // assigned pendingCallContact var that was never read elsewhere.
    // Call sites in GigiActionBridge also removed in the same commit.

    func showBanner(_ message: String, autoHideAfter seconds: Double = 2.5) {
        bannerMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if self?.bannerMessage == message { self?.bannerMessage = "" }
        }
    }

    // MARK: - Main entry point

    func process(text: String) async {
        isThinking = true
        stopMicCapture()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            GigiDebugLogger.voiceEvent("orchestrator.emptyTranscript", turnId: currentVoiceTurnId)
            isThinking = false
            currentVoiceTurnId = nil
            return
        }

        let turnId = ensureVoiceTurn(reason: "transcript")
        GigiDebugLogger.voiceEvent("orchestrator.transcript", turnId: turnId, ["length": "\(trimmed.count)"])

        await GigiLiveActivityController.shared.transitionToThinking(transcript: trimmed)
        status = "GIGI: Sto pensando..."

        if isQuickTalkSession {
            onQuickTalkStateChange?(.thinking)
            onQuickTalkTranscript?(trimmed)
        }

        // Update UI message list
        memory.addUser(trimmed)
        let thinkingID = memory.addThinking()

        // --- Draft preview voice control (Sub #49) ---
        // While DraftMessagePreviewSheet is up, intercept the transcript:
        //   "send / yes / manda" → sendDraft
        //   "cancel / no / annulla" → cancelDraft
        //   anything else → replace draft body
        if showDraftPreview {
            let lower = trimmed.lowercased()
            let yes = ["send", "manda", "invia", "yes", "sì", "go ahead", "mandala", "envialo"]
            let no  = ["cancel", "annulla", "no", "stop", "non mandare", "non inviare"]
            if yes.contains(where: { lower.contains($0) }) {
                let result = await sendDraft()
                memory.resolveThinking(id: thinkingID, with: result)
                isThinking = false
                return
            }
            if no.contains(where: { lower.contains($0) }) {
                cancelDraft()
                memory.resolveThinking(id: thinkingID, with: "Cancelled.")
                isThinking = false
                return
            }
            if var d = pendingDraft {
                d.body = trimmed
                pendingDraft = d
                speech.speak("Updated. Say send when ready.")
                memory.resolveThinking(id: thinkingID, with: "Draft updated.")
                isThinking = false
                return
            }
        }

        // --- Pending confirmation turn ---
        // If a destructive/payment action is waiting for user approval, check intent.
        // Tolerant: anything that isn't a clear "yes" cancels the confirm and processes normally.
        if agentEngine.pendingConfirmRequest != nil {
            if isConfirmation(trimmed) {
                let result = await agentEngine.confirmAndContinue()
                handleResult(result, thinkingID: thinkingID)
                return
            } else {
                agentEngine.cancelConfirmation()
                // Fall through — treat as new request
            }
        }

        // Passively learn user profile data from natural speech (non-blocking)
        Task { await GigiUserProfile.shared.learnFromText(trimmed) }

        // --- V3 agent loop ---
        let result = await agentEngine.process(text: trimmed)
        handleResult(result, thinkingID: thinkingID)
    }

    // MARK: - Result handling (shared by normal turn + confirmation)

    private func handleResult(_ result: AgentResult, thinkingID: UUID) {
        // Memory order: UI update → speak (GigiAgentEngine already updated contentsArray)
        memory.resolveThinking(id: thinkingID, with: result.speech)

        if let confirm = result.requiresConfirm {
            // Awaiting confirmation: speak summary, then let Presence open the follow-up mic window.
            SoundEngine.play(.confirmRequired)
            status = "GIGI: In attesa di conferma..."
            isThinking = false
            Task { await GigiLiveActivityController.shared.transitionToSpeaking(message: "Conferma?") }
            scheduleDoneAfterTTS(message: "Conferma?")
            speech.speak(confirm.summary)
            return
        }

        SoundEngine.play(result.isError ? .error : .taskDone)

        if isQuickTalkSession {
            onQuickTalkStateChange?(.speaking)
            onQuickTalkResponse?(result.speech)
        }

        let trimmed = result.speech.trimmingCharacters(in: .whitespacesAndNewlines)
        let banner = trimmed.isEmpty ? "Fatto." : Self.bannerForPill(speech: trimmed)

        // T5: empty speech path. Skip TTS (avoids `speak("")` → empty AVSpeech buffer
        // → mDataByteSize=0 noise), close the pill straight away.
        guard !trimmed.isEmpty else {
            finalizeTurnNow(message: banner)
            return
        }

        // T3: pill flips to .speaking with the response banner BEFORE TTS starts so the
        // visual matches the audio. T4: completeWithDone is held back — fireDone() runs
        // after AVSpeechSynthesizer reports didFinish/didCancel via onSpeakingFinished.
        GigiDebugLogger.voiceEvent("orchestrator.transitionToSpeaking", turnId: currentVoiceTurnId, ["banner.length": "\(banner.count)"])
        Task { await GigiLiveActivityController.shared.transitionToSpeaking(message: banner) }
        scheduleDoneAfterTTS(message: banner)
        speech.speak(trimmed)

        // Status/thinking flip immediately — only the pill close is deferred.
        status     = "GIGI: Ready"
        isThinking = false
    }

    // MARK: - Deferred turn close (T4)

    private func scheduleDoneAfterTTS(message: String) {
        GigiDebugLogger.voiceEvent("orchestrator.scheduleDoneAfterTTS", turnId: currentVoiceTurnId)
        pendingDoneMessage = message
        doneSafetyTask?.cancel()
        // Safety: if AVSpeechSynthesizer never reports finish (cancel storms, hardware
        // interruption), close the pill anyway so it doesn't dangle in .speaking forever.
        doneSafetyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.fireDone() }
        }
    }

    private func fireDone() {
        guard let msg = pendingDoneMessage else { return }
        GigiDebugLogger.voiceEvent("orchestrator.fireDone", turnId: currentVoiceTurnId, ["lastPhase": "\(GigiLiveActivityController.shared.lastPhase)"])
        pendingDoneMessage = nil
        doneSafetyTask?.cancel()
        doneSafetyTask = nil
        finalizeTurnNow(message: msg)
        currentVoiceTurnId = nil
    }

    private func finalizeTurnNow(message: String) {
        GigiDebugLogger.voiceEvent("orchestrator.finalizeTurn", turnId: currentVoiceTurnId, ["presenceMode": "\(GigiAudioManager.shared.presenceMode)", "quickTalk": "\(isQuickTalkSession)"])
        SoundEngine.releaseSession()

        if isQuickTalkSession {
            Task { await GigiLiveActivityController.shared.completeWithDone(message: message) }
            isQuickTalkSession = false
            onQuickTalkFinished?(true)
        } else if GigiAudioManager.shared.presenceMode {
            // Presence Mode must feel alive: after TTS, AudioManager opens the
            // follow-up listening window. Do not schedule a delayed Done/Ready
            // Live Activity update here, because it can race and overwrite
            // Listening while the mic is open.
        } else {
            Task { await GigiLiveActivityController.shared.completeWithDone(message: message) }
        }
    }

    // MARK: - Confirmation detection

    private func isConfirmation(_ text: String) -> Bool {
        let lower = text.lowercased()
        let yes: [String] = ["sì", "si", "ok", "okay", "vai", "procedi", "conferma",
                             "yes", "sure", "go ahead", "do it", "absolutely"]
        return yes.contains { lower.contains($0) }
    }

    // MARK: - Tool caption (tool name → English UI string)
    // 2026-05-12: migrated from Italian (worldwide demo per CLAUDE.md rule).

    private func toolCaption(_ name: String) -> String {
        switch name {
        case "make_call":             return "Calling"
        case "send_message",
             "send_whatsapp":         return "Sending message"
        case "web_whatsapp":          return "Connecting to WhatsApp Web"
        case "navigate":              return "Opening Maps"
        case "play_music":            return "Looking up music"
        case "set_reminder":          return "Setting reminder"
        case "create_event":          return "Adding to calendar"
        case "set_alarm":             return "Setting alarm"
        case "set_timer":             return "Starting timer"
        case "weather":               return "Checking the weather"
        case "search_web",
             "web_search_and_read":   return "Searching the web"
        case "find_free_slot":        return "Checking your calendar"
        case "read_calendar",
             "read_week_calendar":    return "Reading calendar"
        case "web_book_restaurant":   return "Checking restaurant availability"
        case "web_order_food":        return "Opening food delivery"
        case "computer_use":          return "Working in remote browser"
        case "homekit_on",
             "homekit_off":           return "Controlling the light"
        case "homekit_scene":         return "Activating the scene"
        case "homekit_temp":          return "Adjusting the thermostat"
        case "homekit_lock",
             "homekit_unlock":        return "Operating the lock"
        case "remember":              return "Saving to memory"
        case "recall":                return "Looking up memory"
        default:                      return "Working on it"
        }
    }

    // MARK: - Listening control

    // MARK: - Quick Talk entry point

    func startQuickTalk() {
        isQuickTalkSession = true
        onQuickTalkStateChange?(.listening)
        if GigiAudioManager.shared.state == .speaking {
            interruptAndListen(source: "quickTalk")
            return
        }
        _ = ensureVoiceTurn(reason: "quickTalk")
        speech.stopSpeaking()
        isListening = true
        status = "GIGI: Listening..."
        GigiAudioManager.shared.startRecording()
        Task { await GigiLiveActivityController.shared.beginListening() }
    }

    func stopQuickTalk() {
        isQuickTalkSession = false
        stopMicCapture()
        Task { await GigiLiveActivityController.shared.endImmediately() }
    }

    func startListening() {
        GigiDebugLogger.log("startListening called")
        if GigiAudioManager.shared.state == .speaking {
            interruptAndListen(source: "wakeOrTap")
            return
        }
        _ = ensureVoiceTurn(reason: "wakeOrTap")
        speech.stopSpeaking()
        isListening = true
        status      = "GIGI: Listening..."
        GigiAudioManager.shared.startRecording()
        Task { await GigiLiveActivityController.shared.beginListening() }
    }


    func interruptAndListen(source: String) {
        let turnId = ensureVoiceTurn(reason: "interrupt.\(source)")
        clearPendingDone(reason: "bargeIn.\(source)")
        GigiDebugLogger.voiceEvent("orchestrator.interruptAndListen", turnId: turnId, ["source": source, "audioState": "\(GigiAudioManager.shared.state)"])

        // Flip pill to .listening FIRST so user sees state change within 500ms,
        // independent of audio engine settle time below.
        Task { await GigiLiveActivityController.shared.beginListening() }

        SoundEngine.play(.wakeWord)
        if isQuickTalkSession { onQuickTalkStateChange?(.listening) }

        isListening = true
        isThinking = false
        status = "GIGI: Listening..."

        if GigiAudioManager.shared.state == .speaking {
            GigiAudioManager.shared.startRecording()
            speech.stopSpeaking()
        } else {
            speech.stopSpeaking()
            GigiAudioManager.shared.startRecording()
        }
    }

    func stopMicCapture() {
        speech.stopSpeaking()
        isListening = false
        GigiAudioManager.shared.stopRecording()
    }

    func stopListening() {
        stopMicCapture()
        Task { await GigiLiveActivityController.shared.endImmediately() }
    }

    // MARK: - Voice turn lifecycle

    // Idempotent: callers (transcript, quickTalk, wakeOrTap, interrupt) just want a
    // non-nil turnId without caring whether one is already in flight. A barge-in keeps
    // the existing turn so structured logs (`orchestrator.interruptAndListen`) continue
    // the same trace; first call after `fireDone` clears `currentVoiceTurnId` allocates
    // a fresh one.
    @discardableResult
    private func ensureVoiceTurn(reason: String) -> String {
        if let existing = currentVoiceTurnId { return existing }
        let id = UUID().uuidString.prefix(8).description
        currentVoiceTurnId = id
        GigiDebugLogger.voiceEvent("orchestrator.turnStart", turnId: id, ["reason": reason])
        return id
    }

    private func clearPendingDone(reason: String) {
        GigiDebugLogger.voiceEvent("orchestrator.clearPendingDone", turnId: currentVoiceTurnId, ["reason": reason])
        pendingDoneMessage = nil
        doneSafetyTask?.cancel()
        doneSafetyTask = nil
    }

    // MARK: - Helpers

    /// Formats a TTS speech string into a Live Activity pill banner: trims to last
    /// word boundary under 80 chars, strips emoji presentation scalars (ActivityKit
    /// renders some multi-codepoint emoji incorrectly), falls back to "Speaking…"
    /// if the cleaned text is too short.
    static func bannerForPill(speech: String) -> String {
        let cleaned = speech
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .filter { !$0.properties.isEmojiPresentation && !($0.value >= 0x1F300 && $0.value <= 0x1FAFF) }
            .reduce(into: "") { $0.append(Character($1)) }
        guard cleaned.count >= 2 else { return "Speaking…" }
        guard cleaned.count > 80 else { return cleaned }
        let cap = cleaned.prefix(80)
        if let lastSpace = cap.lastIndex(of: " ") {
            return String(cap[..<lastSpace]) + "…"
        }
        return String(cap) + "…"
    }

    // splitMultipleIntents() removed (2026-05-11, zombie audit): no call sites.
    // Multi-intent decomposition delegated to the 5-path router (Apple FM
    // FoundationRouterDecision) and to Claude Code subprocess.
}
