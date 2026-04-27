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

    // MARK: - Dependencies

    private let agentEngine  = GigiAgentEngine.shared
    private let dispatcher   = GigiActionDispatcher.shared
    private let speech       = GigiSpeechService.shared
    private let memory       = GigiConversationMemory.shared

    private var usingRealtimeMic   = false
    private var pendingCallContact = ""

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
        GigiRealtimeEngine.shared.onStreamingUtteranceComplete = { [weak self] text in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isListening = false
                await self.process(text: text)
            }
        }

        // Barge-in: user spoke while realtime voice was playing audio → stop TTS, listen
        GigiRealtimeEngine.shared.onBargein = { [weak self] in
            Task { @MainActor [weak self] in
                self?.interruptAndListen(source: "realtime")
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
    func markGatewayShortcutInstalled() {
        UserDefaults.standard.set(true, forKey: GigiGateway.isInstalledUserDefaultsKey)
        showGatewayInstallPrompt = false
    }
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
    func setPendingCallAction(contact: String, prompt: String) {
        pendingCallContact = contact
    }

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
        let banner = trimmed.isEmpty
            ? "Fatto."
            : (trimmed.count <= 100 ? trimmed : String(trimmed.prefix(97)) + "…")

        // T5: empty speech path. Skip TTS (avoids `speak("")` → empty AVSpeech buffer
        // → mDataByteSize=0 noise), close the pill straight away.
        guard !trimmed.isEmpty else {
            finalizeTurnNow(message: banner)
            return
        }

        // T3: pill flips to .speaking with the response banner BEFORE TTS starts so the
        // visual matches the audio. T4: completeWithDone is held back — fireDone() runs
        // after AVSpeechSynthesizer reports didFinish/didCancel via onSpeakingFinished.
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
        GigiDebugLogger.voiceEvent("orchestrator.fireDone", turnId: currentVoiceTurnId)
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

    // MARK: - Tool caption (tool name → Italian UI string)

    private func toolCaption(_ name: String) -> String {
        switch name {
        case "make_call":             return "Sto chiamando"
        case "send_message",
             "send_whatsapp":         return "Sto inviando il messaggio"
        case "web_whatsapp":          return "Connessione a WhatsApp Web"
        case "navigate":              return "Apro Maps"
        case "play_music":            return "Cerco la musica"
        case "set_reminder":          return "Imposto il promemoria"
        case "create_event":          return "Aggiungo all'agenda"
        case "set_alarm":             return "Imposto la sveglia"
        case "set_timer":             return "Avvio il timer"
        case "weather":               return "Controllo il meteo"
        case "search_web",
             "web_search_and_read":   return "Sto cercando online"
        case "find_free_slot":        return "Guardo i tuoi impegni"
        case "read_calendar",
             "read_week_calendar":    return "Leggo il calendario"
        case "web_book_restaurant":   return "Controllo disponibilità su TheFork"
        case "web_order_food":        return "Apro Deliveroo"
        case "computer_use":          return "Lavoro nel browser remoto"
        case "homekit_on",
             "homekit_off":           return "Controllo la luce"
        case "homekit_scene":         return "Attivo la scena"
        case "homekit_temp":          return "Regolo il termostato"
        case "homekit_lock",
             "homekit_unlock":        return "Agisco sulla serratura"
        case "remember":              return "Salvo in memoria"
        case "recall":                return "Cerco in memoria"
        default:                      return "Sto lavorando"
        }
    }

    // MARK: - Realtime voice tool execution (called by GigiRealtimeEngine)

    func executeRealtimeToolCall(_ call: GigiToolCall) async -> String {
        await dispatcher.executeRealtimeTool(call)
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
        usingRealtimeMic = false
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
        usingRealtimeMic = false
        GigiAudioManager.shared.startRecording()
        Task { await GigiLiveActivityController.shared.beginListening() }
    }


    func interruptAndListen(source: String) {
        let turnId = ensureVoiceTurn(reason: "interrupt.\(source)")
        clearPendingDone(reason: "bargeIn.\(source)")
        GigiDebugLogger.voiceEvent("orchestrator.interruptAndListen", turnId: turnId, ["source": source, "audioState": "\(GigiAudioManager.shared.state)"])

        SoundEngine.play(.wakeWord)
        if isQuickTalkSession { onQuickTalkStateChange?(.listening) }

        isListening = true
        isThinking = false
        status = "GIGI: Listening..."
        usingRealtimeMic = false

        if GigiAudioManager.shared.state == .speaking {
            GigiAudioManager.shared.startRecording()
            speech.stopSpeaking()
        } else {
            speech.stopSpeaking()
            GigiAudioManager.shared.startRecording()
        }
        Task { await GigiLiveActivityController.shared.beginListening() }
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

    // MARK: - Helpers

    /// Splits a text containing multiple sequential commands into individual parts.
    /// Returns nil if only one command is detected (avoids false splits like "call mom and dad").
    static func splitMultipleIntents(_ text: String) -> [String]? {
        let lower = text.lowercased()

        // Explicit sequential connectors — must separate two complete action phrases
        let separators = [
            ", and then ", " and then ", ", then ",
            ", and also ", " and also ",
            "; ", ", also ",
        ]

        var splitParts: [String] = []
        for sep in separators {
            if lower.contains(sep) {
                splitParts = text.components(separatedBy: sep)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if splitParts.count >= 2 { break }
            }
        }

        guard splitParts.count >= 2 else { return nil }

        // Each part must look like an independent actionable command
        let actionKeywords: [String] = [
            "call", "text", "message", "send",
            "play", "listen", "queue",
            "navigate", "directions", "take me to",
            "open", "launch",
            "timer", "create event", "set a reminder",
            "remind", "weather", "forecast",
            "search", "google", "look up",
            "alarm", "email", "read email",
            "turn on", "turn off", "news",
        ]

        let validParts = splitParts.filter { part in
            let pl = part.lowercased()
            return actionKeywords.contains { pl.contains($0) }
        }

        return validParts.count >= 2 ? validParts : nil
    }

    // MARK: - Voice turn lifecycle helpers
    //
    // Reconstructed from call-site contracts after #95 (ensureVoiceTurn /
    // clearPendingDone were referenced by `df5a645` but their definitions
    // were never committed). Behaviour kept conservative: log + minimal
    // state mutation, no impact on existing turn flow.

    /// Returns the current voice turn id, generating a new one if none is active.
    /// `reason` is a short tag describing the trigger (transcript / wake / interrupt / quickTalk).
    @discardableResult
    fileprivate func ensureVoiceTurn(reason: String) -> String {
        if let existing = currentVoiceTurnId {
            GigiDebugLogger.voiceEvent("orchestrator.ensureVoiceTurn.reuse", turnId: existing, ["reason": reason])
            return existing
        }
        let newId = String(UUID().uuidString.prefix(8))
        currentVoiceTurnId = newId
        GigiDebugLogger.voiceEvent("orchestrator.ensureVoiceTurn.new", turnId: newId, ["reason": reason])
        return newId
    }

    /// Cancels any pending deferred-done state (used on barge-in / interrupt).
    fileprivate func clearPendingDone(reason: String) {
        guard pendingDoneMessage != nil || doneSafetyTask != nil else { return }
        GigiDebugLogger.voiceEvent("orchestrator.clearPendingDone", turnId: currentVoiceTurnId, ["reason": reason])
        pendingDoneMessage = nil
        doneSafetyTask?.cancel()
        doneSafetyTask = nil
    }
}
