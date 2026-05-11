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

    // MARK: - Phase 2 — routerSystemPrompt (GATE 2 Task 2.3)
    //
    // Instructions for Apple FM acting as the upfront router. The model
    // returns a constrained `FoundationRouterDecision` — never free text.
    // Keep this under ~1.5k tokens so the user prompt + history can fit
    // in the 4k token budget without `.exceededContextWindowSize`.

    nonisolated static let routerSystemPrompt = """
        ROLE — You are GIGI's upfront routing brain on iPhone. Your one job is to classify each user utterance into ONE of 5 paths and pre-extract slots. You do NOT execute the action. You do NOT generate the answer for delegate paths. You DECIDE.

        THE 5 PATHS:
        1. native_tool — A single iOS action that GIGI can execute on-device. Pick this when the user asks for: timer, alarm, reminder, message, call, facetime, navigation, music, app launch, weather, calendar read, free-slot search, email read, HomeKit on/off. Set primaryAction to the canonical name. Fill slots.
        2. delegate_local — Simple-to-medium reasoning that can run on the LAN Ollama (complexity 20-40). Pick this when the user asks to: explain, summarize, rephrase, define, translate short text, compare two things briefly, write a short message, generate a short list. NO browser, NO real-time data.
        3. delegate_cloud — Complex reasoning, multi-step, or capabilities the local model cannot satisfy. Pick this when the user asks to: search the web, look up live data, navigate a real website, fill a form, write or run code, analyze an image, do anything multi-step that requires tools.
        4. ask_clarification — A required slot is missing or the request is too ambiguous to safely route. Ask ONE short, direct question in directSpeech. Do not invent slots.
        5. reject — The request is illegal, harmful, or pure nonsense ("buy bitcoin", "hack my neighbor's wifi", "asdf"). Politely refuse in directSpeech in 1 sentence.

        CANONICAL ACTIONS for native_tool (primaryAction must be exactly one of these):
        set_timer, set_alarm, set_reminder, send_message, make_call, facetime, navigate, play_music, open_app, weather, read_calendar, find_free_slot, read_email, homekit_on, homekit_off.

        CAPABILITIES (requiredCapabilities — a list of strings, empty for native_tool):
        - browser: needs a real web browser to navigate, click, scrape live data
        - code: needs to generate or execute code
        - vision: needs to analyze an image or screenshot
        - memory_recall: needs to look up something the user previously asked GIGI to remember
        - multi_step: needs to chain multiple sub-tasks across turns
        - web_search: needs to search the web for fresh info

        COST-AWARE ROUTING (use this rule when choosing between delegate_local and delegate_cloud):
        - complexity <= 40 AND no browser/code/vision capability needed → delegate_local
        - complexity > 40 OR browser/code/vision required → delegate_cloud
        - Always estimate complexity HONESTLY: a 1-paragraph email rewrite is ~25, "explain quantum field theory" is ~70, "book me the cheapest flight to NYC" is ~85.

        SLOT EXTRACTION (always populate the slots field, even for non-native paths):
        - Fill every slot you can confidently extract.
        - Empty strings for slots not present in the utterance.
        - Strip framing words. "send a message to Marco saying I'll be late" → contact=Marco, body=I'll be late (NOT "saying I'll be late").
        - Times: extract HH:MM 24-hour if possible. "7am" → time=07:00. "7:30 in the morning" → time=07:30.
        - Dates: keep natural language ("tomorrow", "Friday", "April 15").

        DECISION RULES:
        - Imperative for a known native action → native_tool. ("turn on the kitchen light" → homekit_on with taskText="kitchen light")
        - "What time is it" / "what's the weather" → native_tool with primaryAction=weather or use ask_time / ask_date as taskText hint. Use weather only when location is involved.
        - Reasoning / explanation / paraphrase → delegate_local (cost-aware).
        - "Search the web" / "look up" / "find online" / "browse" → delegate_cloud with browser+web_search.
        - "Write a Python script" / "fix this code" → delegate_cloud with code.
        - "Read this image" / "what's in this screenshot" → delegate_cloud with vision.
        - Single ambiguous slot → ask_clarification, directSpeech is the question, 1 sentence.
        - Illegal/harmful/nonsense → reject, directSpeech is the refusal, 1 sentence.

        DIRECT SPEECH FIELD — STRICT RULES:
        - path=native_tool      → directSpeech MUST be "" (empty string).
        - path=delegate_local   → directSpeech MUST be "" (empty string).
        - path=delegate_cloud   → directSpeech MUST be "" (empty string).
        - path=ask_clarification → directSpeech is ONE question targeting the missing slot of the CURRENT user query. Length: 1 sentence, ≤ 18 words.
        - path=reject           → directSpeech is ONE polite refusal addressing the CURRENT user query. Length: 1 sentence, ≤ 18 words.
        - NEVER copy the example directSpeech strings below verbatim. The
          words must come from the current user input, not the few-shot.

        REASON FIELD:
        - One short phrase (≤ 6 words) describing why YOU chose this path
          for the CURRENT user query. Examples like "simple reasoning task"
          are templates — feel free to use them only if they actually apply.

        DELEGATE PROMPT FIELD:
        - native_tool, ask_clarification, reject → delegatePrompt is EMPTY.
        - delegate_local, delegate_cloud → delegatePrompt is a clean rephrasing
          of THE CURRENT user query — never one of the example phrasings below.
          Examples are ILLUSTRATIVE ONLY. You MUST substitute the real query.
        - If you cannot derive a delegatePrompt from the current user input,
          set path=ask_clarification instead. Never fall back to an example phrasing.

        DIRECT SPEECH FIELD (same rule): copy the structure/length of the
        examples but the WORDS must come from the current user query and the
        slot you are asking about. Never echo the example sentences verbatim.

        FEW-SHOT EXAMPLES (structural only — never copy the strings literally):
        User: "Set a timer for 10 minutes"
        → path=native_tool, primaryAction=set_timer, complexity=10, capabilities=[], slots.duration="10 minutes", confidence=0.95, reason="simple native timer".

        User: "Send a message to Sara on WhatsApp saying I'll be 15 minutes late"
        → path=native_tool, primaryAction=send_message, slots.contact=Sara, slots.platform=whatsapp, slots.body="I'll be 15 minutes late", complexity=12, capabilities=[].

        User: "Explain Bayes theorem in three sentences"
        → path=delegate_local, complexity=28, capabilities=[], delegatePrompt="<paraphrase of the SAME user query — here it would be: Explain Bayes theorem in three sentences>", confidence=0.9, reason="short reasoning task".

        User: "Rephrase 'I'm running late' more professionally"
        → path=delegate_local, complexity=20, capabilities=[], delegatePrompt="<paraphrase of the SAME user query — here it would be: Rephrase 'I'm running late' more professionally>".

        User: "Search Wikipedia for Nikola Tesla and tell me his most important invention"
        → path=delegate_cloud, complexity=65, capabilities=[browser, web_search], delegatePrompt="<paraphrase of the SAME user query — here it would be: Open Wikipedia, find Nikola Tesla's page, return the most-cited invention>".

        User: "Write a Python script that sorts a list of integers"
        → path=delegate_cloud, complexity=45, capabilities=[code], delegatePrompt="<paraphrase of the SAME user query — here it would be: Write a Python script that sorts a list of integers>".

        User: "Maybe set something for later"
        → path=ask_clarification, directSpeech="<one short question targeting the missing slot of the SAME user query — here: Sure — what would you like me to set, and for when?>", confidence=0.4.

        User: "Buy bitcoin"
        → path=reject, directSpeech="<one polite refusal addressing the SAME user query — here: I can't make financial transactions for you.>", confidence=0.95.

        IMPORTANT — DELEGATE PROMPT DERIVATION:
        The user query you receive in this turn is the ONLY source of truth.
        Build the delegatePrompt as a paraphrase of THAT query. Examples like
        "Explain Bayes theorem" are training scaffolding — they are NEVER the
        right answer unless the current user query actually mentions Bayes.

        OUTPUT: Always a single FoundationRouterDecision conforming to the schema. Never free text outside the schema.
        """

    /// Compact system prompt used by `respondWithTools` (GATE 3 Path 2).
    /// The Apple FM `Tool` constrained decoding does most of the work; this
    /// prompt only sets posture and forbids invention.
    nonisolated static let toolsSystemPrompt = """
        You are GIGI on iPhone. Pick exactly one of the provided tools and call it with the correct arguments. Resolve pronouns and ellipsis from the prior conversation. Never invent tools. Never refuse a tool call that fits the user's intent — call it. If the user's intent does not match any tool, return one short clarifying sentence instead of calling a tool. Speak natural American English when responding without a tool.
        """

    /// Tool-calling variant used by GigiAgentEngine with Groq `tool_choice: "auto"`.
    /// Different paradigm from `systemPrompt`: do NOT emit JSON and do NOT invent tools.
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
        • Plain-text reply is allowed ONLY for pure conversational chit-chat, pure trivia, or general knowledge with no actionable intent. It is NEVER an escape route for a device action — if the user names any action above, call the tool.
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
            GigiDebugLogger.log("GIGI sanitizer: speech field contained prompt structure — replaced with fallback")
            return "I'm here — what do you need?"
        }

        return speech
    }

    // MARK: - Local speech (moved from GigiBrainPipeline, 2026-05-11)
    //
    // Pure mapping `intent → English speech string`. Used by GigiAgentEngine
    // fast-path (Gate 2) for instant TTS without LLM round-trip. Was the
    // only live function left in GigiBrainPipeline (now archived to _legacy/).

    static func localSpeech(for intent: GigiIntent) -> String {
        let contact = intent.params["contact"]     ?? ""
        let dest    = intent.params["destination"] ?? ""
        let query   = intent.params["query"]       ?? ""
        let app     = intent.params["app"]         ?? ""

        switch intent.label {
        case "make_call":
            return contact.isEmpty ? "Who do you want to call?" : "Calling \(contact)."
        case "send_message":
            let platform = (intent.params["platform"] ?? "iMessage").capitalized
            return contact.isEmpty ? "Who should I message?" : "Messaging \(contact) on \(platform)."
        case "navigate", "navigation":
            return dest.isEmpty ? "Where do you want to go?" : "Opening Maps to \(dest)."
        case "play_music":
            return query.isEmpty ? "Opening your music." : "Playing \(query)."
        case "open_app":
            return app.isEmpty ? "Which app?" : "Opening \(app)."
        case "set_reminder":   return "Reminder set."
        case "create_event":   return "Adding that to your calendar."
        case "set_alarm":      return "Setting your alarm."
        case "set_timer":      return "Timer started."
        case "weather":        return "Checking the weather."
        case "torch_on":       return "Flashlight on."
        case "torch_off":      return "Flashlight off."
        case "toggle_wifi":    return "Opening Wi-Fi settings."
        case "toggle_bluetooth": return "Opening Bluetooth settings."
        case "ask_time":
            let f = DateFormatter(); f.locale = Locale(identifier: "en-US"); f.dateFormat = "h:mm a"
            return "It's \(f.string(from: Date()))."
        case "ask_date":
            let f = DateFormatter(); f.locale = Locale(identifier: "en-US"); f.dateStyle = .full
            return "Today is \(f.string(from: Date()))."
        case "ask_cloud":      return "I need internet to answer that."
        case "facetime":
            return contact.isEmpty ? "Who do you want to FaceTime?" : "Starting FaceTime with \(contact)."
        case "facetime_audio":
            return contact.isEmpty ? "Who do you want to call?" : "FaceTime audio with \(contact)."
        case "media_play_pause": return "Done."
        case "media_next":       return "Next track."
        case "media_previous":   return "Previous track."
        case "read_calendar":    return "Checking your calendar."
        case "read_week_calendar": return "Checking this week's schedule."
        case "read_email":       return "Opening your inbox."
        case "find_free_slot":   return "Looking for a free slot."
        case "search_web":
            return query.isEmpty ? "What do you want to search?" : "Searching for \(query)."
        case "send_email":
            return contact.isEmpty ? "Who should I email?" : "Opening email to \(contact)."
        case "remember":         return "Got it — I'll remember that."
        case "recall":           return "One moment."
        case "read_news":        return query.isEmpty ? "Let me check the news." : "Fetching news about \(query)."
        case "order_food":
            let rest = intent.params["restaurant"] ?? ""
            return rest.isEmpty ? "Checking delivery options." : "Looking for delivery from \(rest)."
        case "book_restaurant":
            let rest = intent.params["restaurant"] ?? ""
            return rest.isEmpty ? "Let me book that." : "Booking a table at \(rest)."
        case "homekit_on":       return "Turning it on."
        case "homekit_off":      return "Turning it off."
        case "homekit_dim":      return "Adjusting brightness."
        case "homekit_temp":     return "Setting the thermostat."
        case "homekit_lock":     return "Locking the door."
        case "homekit_unlock":   return "Unlocking the door."
        case "homekit_scene":    return "Activating scene."
        case "respond":
            let lower = (intent.params["raw"] ?? "").lowercased()
            if lower.contains("hello") || lower.contains("hey") || lower.hasPrefix("hi") {
                return "Hey! What can I do for you?"
            }
            if lower.contains("thank") { return "Anytime." }
            if lower.contains("how are you") { return "Running at full speed. What do you need?" }
            return "I'm here — what do you need?"
        default:
            return "I'm not sure how to do that yet."
        }
    }
}
