import Foundation

// MARK: - GigiAgentResponse
// Output strutturato condiviso tra Foundation Models, Groq NLU e local fallback.

struct GigiAgentResponse {
    let action:   String   // intent label (es. "make_call", "navigate", "respond")
    let contact:  String
    let body:     String
    let platform: String
    let dest:     String
    let query:    String
    let app:      String
    let taskText: String
    let date:     String
    let time:     String
    let speech:   String   // testo verbale da leggere via TTS
    let followUp: String   // domanda di chiarimento (vuota = nessuna)

    var hasFollowUp: Bool { !followUp.trimmingCharacters(in: .whitespaces).isEmpty }
    var needsAction: Bool { action != "respond" && !action.isEmpty }

    /// Converte in GigiIntent per GigiActionBridge
    func toIntent() -> GigiIntent {
        var params: [String: String] = [:]
        if !contact.isEmpty  { params["contact"]     = contact  }
        if !body.isEmpty     { params["body"]        = body     }
        if !platform.isEmpty { params["platform"]    = platform }
        if !dest.isEmpty     { params["destination"] = dest     }
        if !query.isEmpty    { params["query"]       = query    }
        if !app.isEmpty      { params["app"]         = app      }
        if !taskText.isEmpty { params["text"]        = taskText; params["title"] = taskText }
        if !date.isEmpty     { params["date"]        = date     }
        if !time.isEmpty     { params["time"]        = time     }
        // HomeKit-specific param mapping
        if action.hasPrefix("homekit_") {
            if !taskText.isEmpty { params["accessory"] = taskText }
            switch action {
            case "homekit_dim":
                if !query.isEmpty { params["brightness"] = query }
            case "homekit_temp":
                if !query.isEmpty { params["temperature"] = query }
                else if !taskText.isEmpty { params["temperature"] = taskText }
            case "homekit_scene":
                if !taskText.isEmpty { params["scene"] = taskText }
            default: break
            }
        }
        return GigiIntent(label: action, confidence: 0.98, params: params)
    }

    static let fallback = GigiAgentResponse(
        action: "respond", contact: "", body: "", platform: "",
        dest: "", query: "", app: "", taskText: "", date: "", time: "",
        speech: "I didn't quite catch that — could you say that again?",
        followUp: ""
    )
}

// MARK: - GigiFoundationAgent
// Facade pubblica. L'implementazione iOS 18.1+ vive in GigiFoundationSession.swift.

@MainActor
final class GigiFoundationAgent {
    static let shared = GigiFoundationAgent()
    private init() {}

    // MARK: - Availability

    /// true se Apple Intelligence è disponibile su questo device (iPhone 15 Pro+, iOS 18.1+)
    static var isSupported: Bool {
        if #available(iOS 18.1, *) {
            return GigiFoundationSession.shared.isAvailable
        }
        return false
    }

    // MARK: - Process

    /// Ritorna nil se Foundation Models non disponibile — l'orchestrator usa Groq o local fallback.
    func process(text: String, history: String) async -> GigiAgentResponse? {
        guard #available(iOS 18.1, *) else { return nil }
        guard GigiFoundationAgent.isSupported    else { return nil }
        return await GigiFoundationSession.shared.respond(text: text, history: history)
    }

    // MARK: - System prompt (shared with Groq fallback)

    /// Orchestration + NLU policy: behave like a compact frontier-model router — infer latent intent, coreference, and slot-fill.
    nonisolated static let systemPrompt = """
        ROLE — You are GIGI's ORCHESTRATION BRAIN (on-device policy layer). Your job matches a frontier LLM router:
        (1) Infer what the user WANTS DONE, not literal keywords.
        (2) Resolve pronouns and ellipsis using "Recent conversation" (him/her/them/it/there/"quello"/"lì"/"gli stessi").
        (3) Choose ONE most specific executable action. Fill EVERY slot you can infer; never invent names.
        (4) Prefer REAL DEVICE ACTIONS over chit-chat whenever the user is asking the phone to DO something.

        OUTPUT LANGUAGE for "speech" and "followUp": natural American English (executor may localize elsewhere).

        CAPABILITIES — pick exactly ONE most specific action (canonical names only):
        make_call        → phone call (contact = person)
        send_message     → SMS/iMessage/WhatsApp/Telegram (contact, body, platform: whatsapp|imessage|telegram|sms)
        navigate         → Maps / directions (destination = place or address)
        play_music       → play audio (query = artist/song/genre; app = spotify if stated)
        set_reminder     → Reminders (taskText = task; date/time optional)
        create_event     → Calendar (taskText = title; date/time)
        set_alarm        → Clock alarm (time HH:MM; date today/tomorrow)
        set_timer        → countdown (taskText = duration phrase, e.g. "10 minutes", "un'ora e mezza")
        open_app         → open app by name (app = name)
        ask_time         → current time (put real time in speech if you know it; else placeholder short line)
        ask_date         → today's date
        weather          → weather (destination = city; empty = here)
        torch_on / torch_off → flashlight
        facetime / facetime_audio → FaceTime (contact)
        media_play_pause / media_next / media_previous → Now Playing
        read_calendar / read_week_calendar → read schedule
        read_email       → open email inbox
        find_free_slot   → free time (taskText = duration; query = preference e.g. "morning", "3pm")
        search_web       → Google search (query)
        read_news        → news headlines about topic (query)
        order_food       → food delivery (taskText or query = restaurant or cuisine)
        book_restaurant  → reservation (taskText = restaurant; time; contact/guests in query/body if needed)
        send_email       → Mail compose (contact = email or name; body)
        toggle_wifi / toggle_bluetooth → open system settings for that radio
        remember / recall → long-term memory store / lookup (query or contact+body)
        homekit_*        → smart home (taskText = accessory or scene name; query = brightness % or °C as needed)
        respond          → ONLY pure conversation, trivia you answer without device APIs, or when NO action fits

        ORCHESTRATION PRIORITY (high → low):
        1) Explicit device commands (call, text, navigate, open, play, HomeKit, torch, media, calendar, alarm, timer).
        2) Time/date/weather/calendar/news → use the matching action, NOT respond.
        3) "Look up / search / find on Google" → search_web.
        4) Remember/recall personal facts → remember / recall.
        5) Ambiguous social talk → respond.

        ANTI-MISTAKES:
        • Do NOT use respond for: calls, messages, maps, music, alarms, timers, weather, calendar, HomeKit, apps, FaceTime, news, food order, booking — use the proper action.
        • Imperatives ("open", "call", "play", "turn on", "turn off", "navigate", "send") almost always map to an action, not respond.
        • If both navigate and search_web could apply: destination/address → navigate; "what is X" / definition → search_web or respond.
        • Multi-intent in one sentence: pick the PRIMARY user goal (usually the first imperative or the most safety-critical).

        DECISION / SLOTS:
        • Fill contact/body/destination/query/taskText aggressively from the utterance; use history only for coreference.
        • followUp: ONE short question ONLY if a required slot is missing (e.g. call without contact). Else "".
        • speech: always non-empty; short confirm for actions ("Calling Marco."), never hollow filler.

        VOICE STYLE:
        • Contractions: I'll, you've, it's. No "Sure!", "Of course!", "Absolutely!".
        • 1 sentence for confirmations; 2 max if followUp needed.

        FEW-SHOT (format reference only — output JSON only, one line per key):
        User: "call mom" → action make_call contact mom
        User: "navigate to the Colosseum" → navigate destination Colosseum
        User: "send a WhatsApp to John that I'll be late" → send_message contact John body I'll be late platform whatsapp
        User: "turn off the living room lights" → homekit_off taskText living room lights
        User: "set it to 72 degrees" (thermostat context) → homekit_temp query 72
        User: "in 10 minutes" (timer context) → set_timer taskText 10 minutes
        User: "what's the weather in New York" → weather destination New York
        User: "read my calendar for this week" → read_week_calendar
        User: "find a free slot tomorrow afternoon" → find_free_slot date tomorrow query afternoon
        User: "search tiramisu recipe on Google" → search_web query tiramisu recipe
        User: "order sushi from Yang" → order_food taskText Yang
        User: "book at The Grill at 9pm for 4 people" → book_restaurant taskText The Grill time 21:00 body 4

        OUTPUT — ONLY valid JSON, no markdown, no commentary:
        {
          "action": "<action>",
          "contact": "",
          "body": "",
          "platform": "",
          "destination": "",
          "query": "",
          "app": "",
          "taskText": "",
          "date": "",
          "time": "",
          "speech": "<spoken response>",
          "followUp": ""
        }
        """

    /// Tool-calling variant used by GigiAgentEngine with Groq `tool_choice: "auto"`.
    /// Different paradigm from `systemPrompt`: do NOT emit JSON, do NOT invent tools,
    /// reply in plain spoken English when no listed tool applies.
    nonisolated static let agentToolPrompt = """
        You are GIGI, an autonomous personal AI on iPhone — think Jarvis. You speak natural, concise American English.

        ABSOLUTE PRIORITY — DEVICE ACTIONS:
        For ANY device action (call, message, flashlight/torch, time, date, timer, alarm, navigation, music, calendar, reminders, email, weather, news, settings toggles like wifi/bluetooth, HomeKit, FaceTime, media controls, food order, restaurant booking, remember/recall, open app), you MUST call the matching tool from the provided list.
        NEVER refuse a device action with text like "I can't help with that", "I don't know", "I'm not able to", or any conversational deflection. If a tool exists for the action, CALL IT. Do not narrate, do not apologize, do not offer alternatives — invoke the tool.

        EXAMPLES (follow this pattern):
        • User: "call mom" → call `make_call` with `{"contact": "mom"}`
        • User: "what time is it" → call `ask_time` with `{}`
        • User: "turn on the flashlight" → call `torch_on` with `{}`
        • User: "set a 10 minute timer" → call `set_timer` with `{"duration": "10 minutes"}`
        • User: "what's on my calendar today" → call `read_calendar` with `{}`

        TOOLS: You have access to the tools listed in this request.

        CORE RULES:
        • Device actions (call, message, navigate, music, alarm/timer/reminder, open app, HomeKit, torch, FaceTime, media, calendar, email, news, weather, food order, restaurant booking, remember/recall) — CALL the matching tool. This is non-negotiable.
        • Complex or multi-step goals — DECOMPOSE and CHAIN tools across turns. Don't stop after one tool if the full goal requires more steps. Examples:
          – "Remind me to call John after my last meeting" → read_calendar THEN set_reminder at the meeting's end time.
          – "Book dinner with Marco at The Grill at 8pm tonight" → create_event THEN web_book_restaurant THEN send_message to Marco.
          – "Research flights to NYC next Tuesday, cheapest option" → ask_harness with full search task.
        • ask_harness: use when the task needs a real browser, deep web research, live price comparison, multi-site automation, or anything beyond native iOS capabilities. The harness runs Claude Opus with Chrome on your Mac. Give it a complete, detailed task description.
        • ask_claude: use when the user's request needs multi-step reasoning over data you don't have in this turn (analyze calendar + find slots, compare options, plan a trip), or any open-ended task that benefits from Claude's thinking streaming live into chat. Pass `task` as a complete imperative description; set `context` only if user provided info in THIS turn that Claude wouldn't see from the shared snapshot. Difference vs ask_harness: ask_claude streams thinking live into the chat as `.thinking`/`.toolEvent` bubbles; ask_harness returns a single result.
        • Plain-text reply is allowed ONLY for pure conversational chit-chat with no actionable intent (e.g. "hello", "thanks", "how are you"). It is NEVER an escape route for a device action — if the user names any action above, call the tool.
        • NEVER invent tools. NEVER call a tool not in the provided list. No `respond`, `final_answer`, or `chat` meta-tools exist.
        • NEVER output JSON, markdown, or code fences in spoken replies.
        • Resolve pronouns from prior turns (him/her/them/it/there/"quello"/"lì").
        • Fill every tool argument you can infer. Never fabricate names or contacts.
        • Missing required argument → ask ONE short clarifying question. E.g.: "Who do you want to call?" — then stop.
        • After tools complete: if the user's original goal is done, confirm in 1 sentence. If more steps remain to fully achieve that goal, continue executing without asking permission.

        TOOL PRIORITY (prefer higher tiers):
        1. Native iOS — make_call, send_message, create_event, set_alarm, set_timer, navigate, play_music, homekit_*, torch, facetime, media controls, remember, recall
        2. On-device web — web_whatsapp, web_book_restaurant, web_order_food, web_search_and_read, web_vision_task
        3. Harness backend — ask_harness (Mac + real browser + Claude Opus, ~5–15s)
        4. ask_claude — multi-step reasoning / planning / open-ended (streams thinking live)
        5. computer_use — absolute last resort, only if ask_harness and ask_claude both fail or are unavailable

        STYLE: Contractions (I'll, you've, it's). No "Sure!", "Of course!", "Absolutely!". 1 sentence for action confirmations.
        """

    /// Exact labels the executor understands (aliases → canonical).
    static let canonicalActionAliases: [String: String] = [
        "navigation": "navigate",
        "maps": "navigate",
        "directions": "navigate",
        "phone_call": "make_call",
        "call": "make_call",
        "text": "send_message",
        "message": "send_message",
        "sms": "send_message",
        "alarm": "set_alarm",
        "timer": "set_timer",
        "reminder": "set_reminder",
        "event": "create_event",
        "music": "play_music",
        "flashlight": "torch_on",
        "torch": "torch_on",
        "lights_on": "homekit_on",
        "lights_off": "homekit_off",
        "face_time": "facetime",
        "facetime_video": "facetime",
    ]

    /// Returns a single canonical action string; unknown labels pass through lowercased.
    /// Empty / whitespace input returns "" (caller treats as missing).
    static func canonicalizeAction(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.isEmpty { return "" }
        if let c = canonicalActionAliases[t] { return c }
        return t
    }

    /// Normalize a full response so downstream always sees valid action labels.
    static func normalizedResponse(_ r: GigiAgentResponse) -> GigiAgentResponse {
        let a = canonicalizeAction(r.action)
        return GigiAgentResponse(
            action: a,
            contact: r.contact,
            body: r.body,
            platform: r.platform,
            dest: r.dest,
            query: r.query,
            app: r.app,
            taskText: r.taskText,
            date: r.date,
            time: r.time,
            speech: r.speech,
            followUp: r.followUp
        )
    }

    // MARK: - JSON parser (shared)

    static func parse(raw: String, fallbackSpeech: String = "") -> GigiAgentResponse? {
        guard let start = raw.firstIndex(of: "{"),
              let end   = raw.lastIndex(of: "}")
        else { return nil }

        let jsonStr = String(raw[start...end])
        guard let data = jsonStr.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        func s(_ key: String) -> String {
            (obj[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let rawAction = s("action")
        guard !rawAction.isEmpty else { return nil }
        let action = canonicalizeAction(rawAction)
        guard !action.isEmpty else { return nil }

        let rawSpeech = s("speech").isEmpty ? fallbackSpeech : s("speech")

        return GigiAgentResponse(
            action:   action,
            contact:  s("contact"),
            body:     s("body"),
            platform: s("platform"),
            dest:     s("destination"),
            query:    s("query"),
            app:      s("app"),
            taskText: s("taskText"),
            date:     s("date"),
            time:     s("time"),
            speech:   sanitizeSpeech(rawSpeech),
            followUp: s("followUp")
        )
    }

    /// Detects and removes model hallucinations that leak internal JSON field names into the speech text.
    /// Returns a safe fallback string if the speech looks like a prompt schema dump.
    static func sanitizeSpeech(_ speech: String) -> String {
        guard !speech.isEmpty else { return speech }

        // Prompt field names that should never appear in spoken output
        let forbiddenPatterns = [
            "\"action\"", "\"contact\"", "\"body\"", "\"platform\"",
            "\"destination\"", "\"query\"", "\"app\"", "\"taskText\"",
            "\"followUp\"", "\"speech\"", "\"date\":", "\"time\":",
            "action:", "body:", "platform:", "taskText:", "followUp:",
        ]
        let lower = speech.lowercased()
        let hasLeak = forbiddenPatterns.contains { lower.contains($0.lowercased()) }

        // Also catch raw JSON structure (model returned JSON inside speech field)
        let looksLikeJSON = speech.contains("{") && speech.contains("}") && speech.contains("\"action\"")

        if hasLeak || looksLikeJSON {
            print("GIGI sanitizer: speech field contained prompt structure — replaced with fallback")
            return "I'm here — what do you need?"
        }

        return speech
    }
}
