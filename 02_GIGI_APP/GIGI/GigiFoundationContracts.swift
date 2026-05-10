import Foundation

// MARK: - GigiFoundationContracts
//
// Structured-output schemas (`@Generable`) used by Apple Foundation Models
// throughout GIGI. Kept in a dedicated file so Phase 2 can add new schemas
// (e.g. `FoundationRouterDecision` for the 5-path router) without bloating
// `GigiFoundationSession.swift`.
//
// Extracted from `GigiFoundationSession.swift` on 2026-05-11 as part of the
// pre-Phase 2 refactor preparation. No behavior change — the struct is
// identical to the previous definition. See plan §3.4 and ADR-0006.

#if canImport(FoundationModels)
import FoundationModels

// MARK: - FoundationAgentOutput
//
// One-shot intent classification + slot filling schema. Used by the current
// (legacy) brain path via `GigiFoundationSession.respond(text:history:)`.
//
// **Phase 2 note**: this schema will coexist with the new
// `FoundationRouterDecision` schema. `FoundationAgentOutput` keeps powering
// the chat fallback flow; `FoundationRouterDecision` (TBD) drives the
// 5-path routing gate. Eventually `FoundationAgentOutput` may be deprecated
// when the router fully owns intent inference.

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

// MARK: - Phase 2 placeholder
//
// `FoundationRouterDecision` will live here when Phase 2 lands.
// See plan §3.4 for the proposed shape:
//   - path: "native_tool" | "delegate_local" | "delegate_cloud" | "ask_clarification" | "reject"
//   - primaryAction: String
//   - confidence: Double
//   - complexityEstimate: Int  (0-100, cost-aware routing)
//   - requiredCapabilities: [String]
//   - slots: ActionSlots
//   - directSpeech: String
//   - delegatePrompt: String

#endif
