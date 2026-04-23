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

    private init() {
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
        GigiRealtimeEngine.shared.onStreamingUtteranceComplete = { [weak self] text in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isListening = false
                await self.process(text: text)
            }
        }

        // Barge-in: user spoke while Gemini Live was playing audio → stop TTS, listen
        GigiRealtimeEngine.shared.onBargein = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.speech.stopSpeaking()
                SoundEngine.play(.wakeWord)
                self.isListening = true
                self.status = "GIGI: Listening..."
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
        guard !trimmed.isEmpty else { isThinking = false; return }

        await GigiLiveActivityController.shared.transitionToThinking()
        status = "GIGI: Sto pensando..."

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
            // Awaiting confirmation: speak summary, stay in "thinking" state until user replies
            SoundEngine.play(.confirmRequired)
            speech.speak(confirm.summary)
            status = "GIGI: In attesa di conferma..."
            isThinking = false
            GigiAudioManager.shared.startWakeWordListening()
            Task { await GigiLiveActivityController.shared.completeWithDone(message: "Conferma?") }
            return
        }

        SoundEngine.play(result.isError ? .error : .taskDone)
        speech.speak(result.speech)

        let banner = result.speech.trimmingCharacters(in: .whitespacesAndNewlines)
        finishTurn(message: banner.isEmpty ? "Fatto." : (banner.count <= 100 ? banner : String(banner.prefix(97)) + "…"))
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

    // MARK: - Gemini Live tool execution (called by GigiRealtimeEngine)

    func executeRealtimeToolCall(_ call: GigiToolCall) async -> String {
        await dispatcher.executeRealtimeTool(call)
    }

    // MARK: - Listening control

    func startListening() {
        GigiDebugLogger.log("startListening called")
        speech.stopSpeaking()
        isListening = true
        status      = "GIGI: Listening..."
        usingRealtimeMic = false
        GigiAudioManager.shared.startRecording()
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

    private func finishTurn(message: String) {
        status     = "GIGI: Ready"
        isThinking = false
        SoundEngine.releaseSession()   // un-duck Spotify / other apps
        GigiAudioManager.shared.startWakeWordListening()
        Task { await GigiLiveActivityController.shared.completeWithDone(message: message) }
    }

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
}
