import Foundation

// MARK: - GigiFoundationContracts
//
// Structured-output schemas (`@Generable`) used by Apple Foundation Models
// throughout GIGI. Two schemas live here:
//
//   1. `FoundationAgentOutput` — legacy one-shot intent + slot filling
//      (drives the Brain Path Override `appleFM` flow today).
//
//   2. `FoundationRouterDecision` (+ `ActionSlots`) — new in Phase 2 (GATE 2).
//      Drives the 5-path router upfront: every query is classified as
//      `native_tool | delegate_local | delegate_cloud | ask_clarification |
//      reject`, with pre-extracted slots, complexity estimate, and required
//      capabilities. `GigiRequestRouter` dispatches based on the `path`.
//
// Plan reference: docs/plans/frolicking-stargazing-pancake.md §3.4
// ADR-0007 (Hybrid 5-path router) — schema is the contract.

#if canImport(FoundationModels)
import FoundationModels

// MARK: - FoundationAgentOutput (legacy)
//
// One-shot intent classification + slot filling schema. Used by the current
// (legacy) brain path via `GigiFoundationSession.respond(text:history:)`.
// Coexists with `FoundationRouterDecision`; kept as Brain Path Override
// `appleFM` testbed and as fallback when the router rejects with empty path.

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

// MARK: - ActionSlots
//
// Pre-extracted slot bag attached to a `FoundationRouterDecision`. Every
// field is a string; empty string means "not extracted". Designed to match
// the parameter names expected by `GigiActionBridge.execute(_:)` so the
// dispatch is a thin mapping layer.

@available(iOS 18.1, *)
@Generable
struct ActionSlots {

    @Guide(description: "Full name of a person — contact target for call/message/facetime/reminder. Empty if not present.")
    var contact: String

    @Guide(description: "Verbatim message body to send. Strip framing words like 'saying' or 'tell them'. Empty if not a message action.")
    var body: String

    @Guide(description: "Destination address or place name for navigation. Empty if not a navigation action.")
    var destination: String

    @Guide(description: "Date reference such as 'tomorrow', 'Monday', '2026-05-14'. Empty if no date mentioned.")
    var date: String

    @Guide(description: "Time in HH:MM 24-hour format. Empty if no specific time mentioned.")
    var time: String

    @Guide(description: "Free-form task text for reminders, events, or HomeKit accessory names (e.g. 'living room light'). Empty if not applicable.")
    var taskText: String

    @Guide(description: "Duration as natural language for timers — e.g. '10 minutes', '1 hour 30 minutes'. Empty if no timer action.")
    var duration: String

    @Guide(description: "Optional label for the timer or alarm (e.g. 'pasta', 'workout'). Empty if not specified.")
    var label: String

    @Guide(description: "App name to open or scheme to launch — e.g. 'Spotify', 'Maps'. Empty if not an open_app action.")
    var appName: String

    @Guide(description: "Free-form query — music search, weather location, web search, news topic. Empty if not applicable.")
    var query: String

    @Guide(description: "Messaging platform: whatsapp, imessage, sms, telegram. Empty if not a message action.")
    var platform: String
}

// MARK: - FoundationRouterDecision
//
// Output of the Apple FM router gate. Drives every dispatch in
// `GigiRequestRouter`. The `path` field is the single decision; everything
// else is supporting metadata. Cost-aware routing rule:
// `complexity <= 40 && !requiredCapabilities.contains("browser") && !requiredCapabilities.contains("code")`
// → prefer `delegate_local` (Ollama). Else `delegate_cloud` (Claude Code).
//
// Apple FM `@Generable` constrained decoding ensures the LLM cannot return
// a `path` value outside the 5 cases — that's a hard guarantee from the
// SDK, not a prompt-level wish.

@available(iOS 18.1, *)
@Generable
struct FoundationRouterDecision {

    @Guide(description: "Single routing decision. native_tool = run an iOS action via Path 2 Tool calling. delegate_local = simple/medium reasoning via Path 3 Ollama on the harness. delegate_cloud = complex reasoning or browser/code via Path 4 Claude Code. ask_clarification = single short question to disambiguate. reject = politely decline (illegal, harmful, nonsensical). Pick exactly one of: native_tool, delegate_local, delegate_cloud, ask_clarification, reject.")
    var path: String

    @Guide(description: "Canonical action name when path is native_tool, otherwise empty string. Allowed values: set_timer, set_alarm, set_reminder, send_message, make_call, facetime, navigate, play_music, open_app, weather, read_calendar, find_free_slot, read_email, homekit_on, homekit_off, create_note.")
    var primaryAction: String

    @Guide(description: "Confidence in this decision, 0.0 to 1.0. Use 0.85+ when extraction is clean, 0.5-0.7 when slots are ambiguous, below 0.5 when you are guessing.")
    var confidence: Double

    @Guide(description: "Estimated task complexity 0-100. 0-20 = trivial native tool, 20-40 = simple reasoning suitable for local Ollama, 40-70 = multi-step reasoning, 70-100 = browser navigation or code generation needing Claude Code.")
    var complexityEstimate: Int

    @Guide(description: "Capabilities the task requires, as a list of strings drawn from: browser, code, vision, memory_recall, multi_step, web_search. Empty list if the task is a one-shot native tool.")
    var requiredCapabilities: [String]

    @Guide(description: "One-line rationale, max 12 words. Examples: 'simple timer command'. 'needs web navigation to fetch result'. 'ambiguous duration field'.")
    var reason: String

    @Guide(description: "Pre-extracted slot bag. Fill every slot you can confidently extract from the utterance. Empty strings for slots that are not present. Always populated, even for non-native_tool paths (downstream dispatch may still use slots).")
    var slots: ActionSlots

    @Guide(description: "Spoken line to TTS when path is ask_clarification or reject. Empty string for the other three paths. Natural American English, 1 sentence, no Sure/Of course filler.")
    var directSpeech: String

    @Guide(description: "Rephrased prompt for downstream LLM when path is delegate_local or delegate_cloud. Strip filler, keep the user's intent crisp. Empty string for native_tool / ask_clarification / reject.")
    var delegatePrompt: String
}

#endif
