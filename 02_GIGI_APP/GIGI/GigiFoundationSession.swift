import Foundation

// MARK: - GigiFoundationSession
// Implementazione concreta Apple Foundation Models (iOS 18.1+).
// Questo file DEVE essere compilato con Xcode 16+ (iOS 18.1 SDK).
// Su device non compatibili, isAvailable = false → nessuna chiamata.

#if canImport(FoundationModels)
import FoundationModels

// MARK: - Structured output schema

@available(iOS 18.1, *)
@Generable
struct FoundationAgentOutput {

    @Guide(description: "Single canonical action — you are the orchestration router: infer latent intent like a frontier LLM. Prefer executable actions over respond. Allowed: make_call, send_message, navigate, play_music, set_reminder, create_event, set_alarm, set_timer, open_app, ask_time, ask_date, weather, torch_on, torch_off, facetime, facetime_audio, media_play_pause, media_next, media_previous, read_calendar, read_week_calendar, find_free_slot, search_web, send_email, toggle_wifi, toggle_bluetooth, remember, recall, homekit_on, homekit_off, homekit_dim, homekit_temp, homekit_lock, homekit_unlock, homekit_scene, read_news, order_food, book_restaurant, respond.")
    var action: String

    @Guide(description: "Full name of the person to call or message. Empty string if not applicable.")
    var contact: String

    @Guide(description: "Complete message text to send. Empty string if not a message action.")
    var body: String

    @Guide(description: "Messaging platform: whatsapp, imessage, sms, or telegram. Empty string otherwise.")
    var platform: String

    @Guide(description: "Full destination address or place name for navigation. Empty string otherwise.")
    var destination: String

    @Guide(description: "Music search query — artist, song title, or genre. For search_web, the full search query. Empty string otherwise.")
    var query: String

    @Guide(description: "Name of the app to open. Empty string otherwise.")
    var app: String

    @Guide(description: "Text content for reminders or calendar events. For set_timer, the duration as a human string like '10 minutes' or '2 hours 30 minutes'. Empty string otherwise.")
    var taskText: String

    @Guide(description: "Date reference such as 'tomorrow', 'Monday', or 'April 15'. Empty string if none.")
    var date: String

    @Guide(description: "Time in HH:MM 24-hour format. Empty string if no specific time mentioned.")
    var time: String

    @Guide(description: "Spoken line in natural American English: short confirmation for actions, or substantive answer if respond. Never start with Sure/Of course/Absolutely. Sound like a capable agent, not a chatbot.")
    var speech: String

    @Guide(description: "A single focused clarification question if critical info is missing. Empty string if you have everything you need.")
    var followUp: String
}

// MARK: - Session manager

@available(iOS 18.1, *)
@MainActor
final class GigiFoundationSession {
    static let shared = GigiFoundationSession()

    private var session: LanguageModelSession?
    private(set) var isAvailable: Bool = false
    private var permanentlyDisabled = false  // true after model catalog failure

    private init() {
        setupSession()
    }

    private func setupSession() {
        guard !permanentlyDisabled else { return }
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            print("GIGI Foundation: optional Apple Intelligence unavailable — using Groq/local fallback.")
            isAvailable = false
            return
        }
        session = LanguageModelSession(instructions: GigiFoundationAgent.systemPrompt)
        isAvailable = true
        print("GIGI Foundation: Apple Intelligence ready ✓")
    }

    // MARK: - Main entry point

    func respond(text: String, history: String) async -> GigiAgentResponse? {
        guard let session, isAvailable else { return nil }

        let prompt: String
        if history.isEmpty {
            prompt = "Classify and fill slots for this utterance (one structured action):\n\(text)"
        } else {
            prompt = """
            Recent conversation:
            \(history)

            Latest utterance — use context to resolve pronouns (him/her/it/there/that place) and implied slots, then output one structured action:
            \(text)
            """
        }

        do {
            let result = try await session.respond(to: prompt, generating: FoundationAgentOutput.self)
            let out    = result.content
            let merged = GigiAgentResponse(
                action:   out.action,
                contact:  out.contact,
                body:     out.body,
                platform: out.platform,
                dest:     out.destination,
                query:    out.query,
                app:      out.app,
                taskText: out.taskText,
                date:     out.date,
                time:     out.time,
                speech:   out.speech,
                followUp: out.followUp
            )
            let normalized = GigiFoundationAgent.normalizedResponse(merged)
            print("GIGI Foundation: '\(text)' → \(normalized.action) | speech: \(normalized.speech.prefix(60))")

            return normalized

        } catch {
            let desc = error.localizedDescription + "\(error)"
            print("GIGI Foundation error: \(error)")
            // Model catalog missing — Apple Intelligence not fully downloaded yet
            if desc.contains("modelcatalog") || desc.contains("5000") || desc.contains("SensitiveContentAnalysis") {
                permanentlyDisabled = true
                isAvailable = false
                self.session = nil
                print("GIGI Foundation: model assets not downloaded. Go to Settings → Apple Intelligence & Siri → enable and wait for download.")
            }
            return nil
        }
    }

    // MARK: - Reset

    func resetContext() {
        setupSession()
        print("GIGI Foundation: session reset.")
    }
}

#else

// MARK: - Stub per SDK < iOS 18.1 (compila ma non fa nulla)

@MainActor
final class GigiFoundationSession {
    static let shared = GigiFoundationSession()
    let isAvailable: Bool = false
    private init() {
        print("GIGI Foundation: FoundationModels not available in this SDK.")
    }
    func respond(text: String, history: String) async -> GigiAgentResponse? { nil }
    func resetContext() {}
}

#endif
