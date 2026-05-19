import Foundation

// MARK: - GigiFoundationToolRegistry
//
// Apple FM `Tool` protocol implementations (iOS 26+). Each tool wraps a
// canonical action in `GigiActionBridge` so Apple FM constrained decoding
// can pick + call the right one without the legacy `selectRelevant` scoring.
//
// **15 Q2 tools** (decided 2026-05-12):
//   set_timer, set_alarm, set_reminder, send_message, make_call, facetime,
//   navigate, play_music, open_app, weather, read_calendar, find_free_slot,
//   read_email, homekit_on, homekit_off.
//
// `delegate_to_claude` was excluded — it's handled by the router's
// `delegate_cloud` path, not as a tool. HomeKit kept split (on/off) rather
// than a unified toggle since the bridge handlers are also split.
//
// Reference: docs/plans/frolicking-stargazing-pancake.md §3.6
// ADR-0008 — Apple FM Tool calling vs scored tool registry (closes TD-001)

#if canImport(FoundationModels)
import FoundationModels

// MARK: - Shared dispatch helper

@available(iOS 18.1, *)
@MainActor
private func dispatchAction(label: String, params: [String: String]) async -> String {
    let intent = GigiIntent(label: label, confidence: 1.0, params: params)
    let result = await GigiActionBridge.shared.execute(intent)
    if result.isEmpty {
        return GigiFoundationAgent.localSpeech(for: intent)
    }
    return result
}

// MARK: - 1. SetTimerTool

@available(iOS 26.0, *)
struct FMSetTimerTool: Tool {
    let name = "set_timer"
    let description = "Start a countdown timer. Use when the user asks to time something for a specific duration."

    @Generable
    struct Arguments {
        @Guide(description: "Duration in natural language. Examples: '5 minutes', '1 hour 30 minutes', '90 seconds'.")
        var duration: String

        @Guide(description: "Optional label like 'pasta' or 'workout'. Empty string if not specified.")
        var label: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "set_timer", params: [
            "text": arguments.duration,
            "taskText": arguments.duration,
            "raw": arguments.duration,
            "label": arguments.label
        ])
    }
}

// MARK: - 2. SetAlarmTool

@available(iOS 26.0, *)
struct FMSetAlarmTool: Tool {
    let name = "set_alarm"
    let description = "Schedule a one-shot alarm at a specific time."

    @Generable
    struct Arguments {
        @Guide(description: "Time in HH:MM (24h) or 'h:mm a' format. Examples: '07:30', '7:30 AM'.")
        var time: String

        @Guide(description: "Date reference: 'today', 'tomorrow'. Empty defaults to today/next.")
        var date: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "set_alarm", params: [
            "time": arguments.time,
            "date": arguments.date.isEmpty ? "today" : arguments.date
        ])
    }
}

// MARK: - 3. SetReminderTool

@available(iOS 26.0, *)
struct FMSetReminderTool: Tool {
    let name = "set_reminder"
    let description = "Add an item to the Reminders app."

    @Generable
    struct Arguments {
        @Guide(description: "What to be reminded of. Example: 'call Marco'.")
        var taskText: String

        @Guide(description: "Optional date reference: 'tomorrow', 'Monday'. Empty if no date.")
        var date: String

        @Guide(description: "Optional time HH:MM. Empty if no time.")
        var time: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "set_reminder", params: [
            "text": arguments.taskText,
            "title": arguments.taskText,
            "date": arguments.date,
            "time": arguments.time
        ])
    }
}

// MARK: - 4. SendMessageTool

@available(iOS 26.0, *)
struct FMSendMessageTool: Tool {
    let name = "send_message"
    let description = "Send a text message (iMessage, SMS, WhatsApp, or Telegram)."

    @Generable
    struct Arguments {
        @Guide(description: "Recipient's name only, exactly as in Contacts. Strip framing words like 'to', 'and', 'send', 'message', 'a'. Example: from 'send a message to fede and say hi' extract 'fede', not 'to fede and'.")
        var contact: String

        @Guide(description: "Verbatim message body. Strip framing words like 'saying' or 'tell them'.")
        var body: String

        @Guide(description: "Platform: whatsapp, imessage, sms, telegram. Default imessage.")
        var platform: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        let cleanedBody = Self.stripFramingPrefix(arguments.body)
        let platform = await Self.resolvePlatform(fmExtracted: arguments.platform)
        let contact = arguments.contact.trimmingCharacters(in: .whitespacesAndNewlines)

        // Body validation: Apple FM sometimes calls this tool with an
        // empty body — usually when the user said "Send him a message"
        // without specifying what. Worse, with conversation history in
        // context, FM may HALLUCINATE the body from a previous turn.
        // Defense: if the cleaned body is empty OR doesn't appear in the
        // current utterance (= came from elsewhere), ask the user.
        let utteranceLower = GigiAgentEngine.currentUserUtterance.lowercased()
        let bodyAppearsInUtterance = !cleanedBody.isEmpty
            && utteranceLower.contains(cleanedBody.lowercased())
        if cleanedBody.isEmpty || !bodyAppearsInUtterance {
            let targetName = contact.isEmpty ? "them" : contact
            GigiConversationMemory.shared.setPendingClarification(.init(
                intent: "send_message",
                slot: "body",
                partialParams: ["contact": contact, "platform": platform],
                timestamp: Date()
            ))
            return "What do you want to say to \(targetName)?"
        }

        return await dispatchAction(label: "send_message", params: [
            "contact": contact,
            "body": cleanedBody,
            "platform": platform
        ])
    }

    /// Determines messaging platform by inspecting the actual user
    /// utterance (single source of truth) rather than trusting Apple FM's
    /// platform slot extraction (which often hallucinates WhatsApp).
    /// Delegates to GigiRequestRouter.resolveMessagePlatform for the
    /// canonical priority rules (text mention > user pref > imessage).
    @MainActor
    static func resolvePlatform(fmExtracted: String) async -> String {
        return await GigiRequestRouter.resolveMessagePlatform(
            forUtterance: GigiAgentEngine.currentUserUtterance
        )
    }

    /// Strip leading framing words/phrases ("saying ", "tell them ",
    /// "telling them ", "to say ", "and say ", "that says ", IT variants)
    /// from the message body. Case-insensitive, idempotent.
    static func stripFramingPrefix(_ body: String) -> String {
        var s = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // Trim matched optional surrounding quotes.
        if (s.hasPrefix("\"") && s.hasSuffix("\""))
            || (s.hasPrefix("'") && s.hasSuffix("'")) {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let framers = [
            "saying ", "to say ", "and say ", "that says ", "that ",
            "telling them ", "tell them ", "tell him ", "tell her ",
            "telling him ", "telling her ", "told them ", "told him ",
            "told her ", "to tell them ", "to tell him ", "to tell her ",
            "with the message ", "the message ", "message ",
            "with ", "writing "
        ]
        let lower = s.lowercased()
        for f in framers where lower.hasPrefix(f) {
            s = String(s.dropFirst(f.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            // One pass is enough; loop again to chain ("saying that ..."):
            return stripFramingPrefix(s)
        }
        return s
    }
}

// MARK: - 5. MakeCallTool

@available(iOS 26.0, *)
struct FMMakeCallTool: Tool {
    let name = "make_call"
    let description = "Place a phone call to a contact."

    @Generable
    struct Arguments {
        @Guide(description: "Full name of the contact, e.g. 'Mum', 'Marco Rossi'.")
        var contact: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "make_call", params: ["contact": arguments.contact])
    }
}

// MARK: - 6. FacetimeTool

@available(iOS 26.0, *)
struct FMFacetimeTool: Tool {
    let name = "facetime"
    let description = "Start a FaceTime video call to a contact."

    @Generable
    struct Arguments {
        @Guide(description: "Full name of the contact to FaceTime.")
        var contact: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "facetime", params: ["contact": arguments.contact])
    }
}

// MARK: - 7. NavigateTool

@available(iOS 26.0, *)
struct FMNavigateTool: Tool {
    let name = "navigate"
    let description = "Open Maps with driving directions to a destination."

    @Generable
    struct Arguments {
        @Guide(description: "Destination address or place name, e.g. 'Bologna train station'.")
        var destination: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "navigate", params: ["destination": arguments.destination])
    }
}

// MARK: - 8. PlayMusicTool

@available(iOS 26.0, *)
struct FMPlayMusicTool: Tool {
    let name = "play_music"
    let description = "Play music — artist, song, or genre."

    @Generable
    struct Arguments {
        @Guide(description: "Search query — artist, song title, or genre. Required.")
        var query: String

        @Guide(description: "Platform: spotify, apple_music, default empty (Apple Music).")
        var platform: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "play_music", params: [
            "query": arguments.query,
            "platform": arguments.platform
        ])
    }
}

// MARK: - 9. OpenAppTool

@available(iOS 26.0, *)
struct FMOpenAppTool: Tool {
    let name = "open_app"
    let description = "Launch an installed app by name."

    @Generable
    struct Arguments {
        @Guide(description: "App name, e.g. 'Spotify', 'Notes', 'Calendar'.")
        var appName: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "open_app", params: ["app": arguments.appName])
    }
}

// MARK: - 10. WeatherTool

@available(iOS 26.0, *)
struct FMWeatherTool: Tool {
    let name = "weather"
    let description = "Get the current weather and short-term forecast for a location."

    @Generable
    struct Arguments {
        @Guide(description: "City or location name. Empty string = current location.")
        var location: String

        @Guide(description: "Optional date reference: 'today', 'tomorrow'. Empty = today.")
        var date: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "weather", params: [
            "destination": arguments.location,
            "query": arguments.location,
            "date": arguments.date
        ])
    }
}

// MARK: - 11. ReadCalendarTool

@available(iOS 26.0, *)
struct FMReadCalendarTool: Tool {
    let name = "read_calendar"
    let description = "Read upcoming calendar events (today by default; this week if requested)."

    @Generable
    struct Arguments {
        @Guide(description: "Range: 'today' or 'week'. Default 'today'.")
        var range: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        let label = arguments.range.lowercased().contains("week") ? "read_week_calendar" : "read_calendar"
        return await dispatchAction(label: label, params: [:])
    }
}

// MARK: - 12. FindFreeSlotTool

@available(iOS 26.0, *)
struct FMFindFreeSlotTool: Tool {
    let name = "find_free_slot"
    let description = "Find the next free time slot in the user's calendar."

    @Generable
    struct Arguments {
        @Guide(description: "Slot duration in minutes. Default 60.")
        var durationMinutes: Int

        @Guide(description: "Preference like 'morning', 'afternoon', 'evening', or a specific hour. Empty = any.")
        var preferredTime: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        let duration = arguments.durationMinutes > 0 ? arguments.durationMinutes : 60
        return await dispatchAction(label: "find_free_slot", params: [
            "duration": String(duration),
            "preferred": arguments.preferredTime,
            "time": arguments.preferredTime
        ])
    }
}

// MARK: - 13. ReadEmailTool

@available(iOS 26.0, *)
struct FMReadEmailTool: Tool {
    let name = "read_email"
    let description = "Open the user's email inbox (Mail app)."

    @Generable
    struct Arguments {
        @Guide(description: "Reserved for future use; pass empty string.")
        var unused: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "read_email", params: [:])
    }
}

// MARK: - 14. HomeKitOnTool

@available(iOS 26.0, *)
struct FMHomeKitOnTool: Tool {
    let name = "homekit_on"
    let description = "Turn on a HomeKit accessory (light, switch, plug)."

    @Generable
    struct Arguments {
        @Guide(description: "Accessory name as configured in Home app, e.g. 'living room light'.")
        var accessory: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "homekit_on", params: [
            "accessory": arguments.accessory,
            "taskText": arguments.accessory
        ])
    }
}

// MARK: - 16. CreateNoteTool (GATE 6 — killer demo Tesla→note)

@available(iOS 26.0, *)
struct FMCreateNoteTool: Tool {
    let name = "create_note"
    let description = "Save a note to the iOS Notes app. Use after research or summary tasks when the user asks to remember something. The note title + body are placed on the clipboard and the Notes app opens — user pastes with long-press."

    @Generable
    struct Arguments {
        @Guide(description: "Note title — short, descriptive (e.g. 'Nikola Tesla', 'Pasta recipe').")
        var title: String

        @Guide(description: "Note body content, up to 2-4 sentences. Plain text, no markdown.")
        var body: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "create_note", params: [
            "title": arguments.title,
            "body": arguments.body
        ])
    }
}

// MARK: - 15. HomeKitOffTool

@available(iOS 26.0, *)
struct FMHomeKitOffTool: Tool {
    let name = "homekit_off"
    let description = "Turn off a HomeKit accessory."

    @Generable
    struct Arguments {
        @Guide(description: "Accessory name as configured in Home app, e.g. 'kitchen light'.")
        var accessory: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "homekit_off", params: [
            "accessory": arguments.accessory,
            "taskText": arguments.accessory
        ])
    }
}

// MARK: - 17. WebOrderFoodTool (bug #011 — food delivery dispatch)

@available(iOS 26.0, *)
struct FMWebOrderFoodTool: Tool {
    let name = "web_order_food"
    let description = "Open a food delivery app or website. Use when the user wants to order food, takeout, kebab, sushi, pizza, or delivery. Prefer this over reject/clarification when the user mentions a delivery service or food."

    @Generable
    struct Arguments {
        @Guide(description: "Service name lowercase: justeat, deliveroo, ubereats, glovo, doordash, talabat. Empty string if the user did not specify a service — bridge will fall back to a web search.")
        var service: String

        @Guide(description: "Optional restaurant or cuisine query (e.g. 'tariq kebab', 'sushi near me', 'pizza margherita'). Empty if unspecified.")
        var query: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "web_order_food", params: [
            "service": arguments.service.lowercased(),
            "query": arguments.query
        ])
    }
}

// MARK: - 18. RunShortcutTool (GATE 9.A — universal Apple Shortcuts bridge)

@available(iOS 26.0, *)
struct FMRunShortcutTool: Tool {
    let name = "run_shortcut"
    let description = """
    Open the Apple Shortcuts app and run a user-installed Shortcut by name. \
    THIS IS THE ONLY TOOL TO USE when the utterance starts with "run", \
    "execute", "launch", "trigger", "esegui", "lancia" OR ends with "shortcut" \
    or "scorciatoia". Examples that REQUIRE this tool: "run accendi torcia", \
    "execute work mode", "run accendi torcia shortcut", "trigger my morning \
    routine", "lancia modalità lavoro", "esegui buongiorno". The body after \
    the verb is the literal Shortcut name the user chose in the Shortcuts app \
    — DO NOT interpret it as a HomeKit accessory or timer duration. \
    NEVER pick set_timer, homekit_on, homekit_off, or open_app for these \
    utterances — they are explicit Shortcut invocations.
    """

    @Generable
    struct Arguments {
        @Guide(description: "Exact or near-exact name of the Shortcut as the user said it. Examples: 'morning routine', 'work mode', 'arrive home'.")
        var name: String

        @Guide(description: "Optional text input to pass to the Shortcut as its input. Empty string if none.")
        var input: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "run_shortcut", params: [
            "name": arguments.name,
            "input": arguments.input,
            "raw": arguments.name
        ])
    }
}

// MARK: - 19. SetHomeKitSceneTool (GATE 9.B — scene activation by name)

@available(iOS 26.0, *)
struct FMSetHomeKitSceneTool: Tool {
    let name = "set_homekit_scene"
    let description = "Activate a HomeKit scene by name (e.g. 'Good Morning', 'Cinema', 'Goodnight'). Use when the user asks to activate, run, trigger, or set a scene. NOT for individual accessory control — use homekit_on or homekit_off for single lights/devices."

    @Generable
    struct Arguments {
        @Guide(description: "Scene name as the user said it. Examples: 'Cinema', 'Good morning', 'Sleep mode', 'Movie night'.")
        var sceneName: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "set_homekit_scene", params: [
            "scene": arguments.sceneName,
            "sceneName": arguments.sceneName,
            "raw": arguments.sceneName
        ])
    }
}

// MARK: - 20. WebSearchTool (GATE 9.C — iPhone Safari open on EXPLICIT request only)
//
// ADR-0013 design: generic research queries ("look up X", "find X online",
// "google X") are NOT this tool — they delegate_cloud to the harness Claude
// subprocess which uses the browser MCP tool to do actual research and
// synthesize an answer inline. This tool is RESERVED for the user's explicit
// "open Safari on my phone" intent.

@available(iOS 26.0, *)
struct FMWebSearchTool: Tool {
    let name = "web_search"
    let description = """
    Open Safari on the iPhone with a search query. Use ONLY when the user \
    explicitly asks to open Safari, open the browser, or search on their \
    phone (e.g. 'open Safari and search X', 'cerca X su Safari', 'apri \
    Safari', 'open the browser with X', 'cerca questo sul telefono'). \
    For generic research and information lookup that does NOT request the \
    iPhone Safari (e.g. 'what is the capital of Chile', 'look up best ramen \
    in Milan', 'find me a pasta recipe', 'google something'), DO NOT pick \
    this tool — the harness Claude subprocess with browser MCP will \
    research and synthesize the answer inline via delegate_cloud, keeping \
    the user inside the GIGI chat.
    """

    @Generable
    struct Arguments {
        @Guide(description: "The search query in natural language to feed into iPhone Safari. Examples: 'pasta carbonara recipe', 'best ramen in Milan'.")
        var query: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "web_search", params: [
            "query": arguments.query,
            "raw": arguments.query
        ])
    }
}

// MARK: - 21. ReadClipboardTool (GATE 10.B — utility)

@available(iOS 26.0, *)
struct FMReadClipboardTool: Tool {
    let name = "read_clipboard"
    let description = "Read aloud the current iOS clipboard text. Use when the user asks 'what's in my clipboard', 'read clipboard', 'what did I copy', or 'tell me what's copied'. NOT for setting clipboard or other clipboard operations."

    @Generable
    struct Arguments {
        @Guide(description: "Empty — no arguments needed.")
        var unused: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "read_clipboard", params: [:])
    }
}

// MARK: - 22. GetDeviceBatteryTool (GATE 10.B — utility)

@available(iOS 26.0, *)
struct FMGetDeviceBatteryTool: Tool {
    let name = "get_device_battery"
    let description = "Report the iPhone's current battery level and charging state. Use when the user asks 'how's my battery', 'battery level', 'is my phone charging', 'quanto ho di batteria'. NOT for other device info — only battery."

    @Generable
    struct Arguments {
        @Guide(description: "Empty — no arguments needed.")
        var unused: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "get_device_battery", params: [:])
    }
}

// MARK: - 23. ToggleFlashlightTool (GATE 10.B — utility)

@available(iOS 26.0, *)
struct FMToggleFlashlightTool: Tool {
    let name = "toggle_flashlight"
    let description = "Turn the iPhone flashlight (rear LED torch) on or off. Use when the user asks 'turn on flashlight', 'flashlight on', 'turn off torch', 'accendi torcia', 'spegni torcia'. NOT for HomeKit lights — that's homekit_on/homekit_off."

    @Generable
    struct Arguments {
        @Guide(description: "Target state: 'on' or 'off'. Empty string toggles current state.")
        var state: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "toggle_flashlight", params: [
            "state": arguments.state.lowercased(),
            "raw": arguments.state
        ])
    }
}

// MARK: - 24. DefineWordTool (GATE 10.C — knowledge mini)

@available(iOS 26.0, *)
struct FMDefineWordTool: Tool {
    let name = "define_word"
    let description = "Look up the dictionary definition of a word using the iOS system dictionary. Use when the user asks 'define X', 'what does X mean', 'definition of X', 'cosa significa X'. NOT for translation (use translate_text) or for facts (use delegate_cloud)."

    @Generable
    struct Arguments {
        @Guide(description: "The single word or short phrase to define. Examples: 'serendipity', 'ephemeral', 'gastronomia'.")
        var word: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "define_word", params: [
            "word": arguments.word,
            "raw": arguments.word
        ])
    }
}

// MARK: - 25. CalculateMathTool (GATE 10.C — knowledge mini)

@available(iOS 26.0, *)
struct FMCalculateMathTool: Tool {
    let name = "calculate_math"
    let description = "Evaluate a math expression and read the result aloud. Use when the user asks 'what's X plus Y', 'calculate X', 'how much is X', 'quanto fa X'. Supports basic arithmetic, percentages, exponents. NOT for unit conversions or word problems — only direct math."

    @Generable
    struct Arguments {
        @Guide(description: "The math expression in natural language or symbols. Examples: '47 * 23', '15% of 200', '2^10', 'sqrt(144)'.")
        var expression: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "calculate_math", params: [
            "expression": arguments.expression,
            "raw": arguments.expression
        ])
    }
}

// MARK: - 29. BuildShortcutTool (Phase 2 — AI-generated Shortcuts)
//
// Apple FM generates a Cherri DSL specification from a natural-language
// request. The harness compiles + signs on a Mac and returns a signed
// .shortcut URL that iOS opens for the user's 1-tap install.
//
// IMPORTANT: actions array is constrained to the CHERRI_VOCABULARY in
// GigiCherriDSL.swift — Apple FM picks from a known-good list rather
// than free-form generating Cherri code.

@available(iOS 26.0, *)
struct FMBuildShortcutTool: Tool {
    let name = "build_shortcut"
    let description = """
    Build a new iOS Shortcut from natural language. Use ONLY when the user \
    explicitly asks GIGI to BUILD, CREATE, MAKE, or COMPOSE a new Shortcut \
    (e.g. 'build me a shortcut that turns off all lights', 'make a goodnight \
    shortcut', 'create a focus session shortcut', 'fammi uno shortcut che...'). \
    NOT for running existing Shortcuts (use run_shortcut). NOT for tools \
    already in the registry — pick the dedicated tool instead.

    The Apple FM model generates a sequence of actions from a fixed \
    vocabulary; the harness compiles + signs via a Mac and returns a signed \
    .shortcut file. The user gets a 1-tap install preview in Shortcuts.app.
    """

    @Generable
    struct Arguments {
        @Guide(description: "Short Shortcut name, 2-4 words. Examples: 'Goodnight Routine', 'Focus Session', 'Gym Time', 'Quick Note'.")
        var title: String

        @Guide(description: """
        JSON array of action objects, each {action: <verb>, params: {<name>: <value>}}. \
        Available actions (action names — MUST match exactly): showResult (params: text), \
        showNotification (text), speakText (text), waitSeconds (seconds), setClipboard (text), \
        getClipboard, torchOn, torchOff, playMusic, pauseMusic, skipForward, skipBackward, \
        homeKitScene (scene), setFocus (mode: Work/Sleep/Personal/DoNotDisturb), turnOffFocus, \
        openApp (appName), setVolume (level: 0-100). \
        Example for 'turn on torch and wait 5 seconds and turn off': \
        [{"action":"torchOn","params":{}},{"action":"waitSeconds","params":{"seconds":"5"}},{"action":"torchOff","params":{}}]
        """)
        var actionsJSON: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "build_shortcut", params: [
            "title": arguments.title,
            "actionsJSON": arguments.actionsJSON,
            "raw": arguments.title
        ])
    }
}

// MARK: - 26. CreateCalendarEventTool (GATE 10.A — productivity)

@available(iOS 26.0, *)
struct FMCreateCalendarEventTool: Tool {
    let name = "create_calendar_event"
    let description = "Create a new event in the iOS Calendar. Use when the user asks 'create event', 'add event', 'schedule meeting', 'crea evento', 'aggiungi appuntamento'. NOT for reminders (use set_reminder), alarms (use set_alarm), or reading existing events (use read_calendar)."

    @Generable
    struct Arguments {
        @Guide(description: "Event title or short description. Examples: 'Meeting with Marco', 'Doctor appointment', 'Dinner with Sara'.")
        var title: String

        @Guide(description: "Date in natural language. Examples: 'today', 'tomorrow', 'Friday', 'next Tuesday', 'May 15'.")
        var date: String

        @Guide(description: "Start time. Examples: '3pm', '15:00', '10:30 AM'. Defaults to 'noon' if unspecified.")
        var time: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "create_event", params: [
            "title": arguments.title,
            "date": arguments.date,
            "time": arguments.time,
            "raw": arguments.title
        ])
    }
}

// MARK: - 27. AddToNoteTool (GATE 10.A — productivity)

@available(iOS 26.0, *)
struct FMAddToNoteTool: Tool {
    let name = "add_to_note"
    let description = "Append text to an existing Apple Note by title, or create one if missing. Use when the user asks 'add to my note', 'append to note X', 'aggiungi alla nota'. NOT for creating new standalone content (use create_note) — this targets a SPECIFIC existing note by name."

    @Generable
    struct Arguments {
        @Guide(description: "Title or name of the target note. Examples: 'Work', 'Ideas Q3', 'Shopping list'.")
        var noteTitle: String

        @Guide(description: "Text content to append to that note. Examples: 'Q3 product idea: voice macros', 'Buy: olive oil, parmesan'.")
        var content: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "add_to_note", params: [
            "noteTitle": arguments.noteTitle,
            "content": arguments.content,
            "raw": arguments.content
        ])
    }
}

// MARK: - 28. TranslateTextTool (GATE 10.C — knowledge mini)

@available(iOS 26.0, *)
struct FMTranslateTextTool: Tool {
    let name = "translate_text"
    let description = "Translate a phrase from one language to another using the iOS on-device Translation framework. Use when the user asks 'translate X to Y', 'how do you say X in Y', 'come si dice X in Y'. NOT for general Q&A — only literal translation."

    @Generable
    struct Arguments {
        @Guide(description: "The text to translate. Examples: 'good morning', 'where is the bathroom', 'buongiorno'.")
        var text: String

        @Guide(description: "Target language in plain words. Examples: 'Italian', 'Japanese', 'French', 'Spanish', 'German'.")
        var targetLanguage: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "translate_text", params: [
            "text": arguments.text,
            "targetLanguage": arguments.targetLanguage,
            "raw": arguments.text
        ])
    }
}

// MARK: - Memory tools (remember / recall)

/// Stores a user-asserted fact in long-term memory. Apple FM should call
/// this for any utterance that asserts a relationship or value, INCLUDING
/// utterances that don't use the verb "remember" explicitly — the model is
/// expected to recognize fact-shapes:
///   "Marco is my brother"
///   "Mio fratello è Marco"
///   "My favorite color is blue"
///   "The wifi password is hello123"
/// In all of these, the FM extracts subject + value + an inferred category.
@available(iOS 26.0, *)
struct FMRememberTool: Tool {
    let name = "remember"
    let description = "Store a fact the user just told GIGI (name, preference, password, relationship, place). Call this whenever the user makes an assertion the assistant should retain for future turns, even when the verb 'remember' is not used. Examples: 'Marco is my brother', 'My favorite color is blue', 'The wifi password is hello123', 'Mom lives at Via Roma 5'."

    @Generable
    struct Arguments {
        @Guide(description: "Subject of the assertion — the entity being described. Usually a name, role, or thing. Lowercase if it's a generic noun. Examples: 'Marco' (from 'Marco is my brother'), 'wifi password' (from 'the wifi password is hello123'), 'favorite color' (from 'my favorite color is blue'). Always provide.")
        var subject: String

        @Guide(description: "Verbatim value or relationship being stored. Strip framing words. Examples: 'my brother' (from 'Marco is my brother'), 'hello123', 'blue'. Always provide.")
        var value: String

        @Guide(description: "Category hint: contact (a person), pref (a preference / setting), place (an address / location), routine (a recurring time/schedule), person (a name resolution). Empty if unsure — backend will infer.")
        var category: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        let subject = arguments.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = arguments.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty, !value.isEmpty else {
            return "I need both a subject and a value to remember."
        }
        let cat = arguments.category.trimmingCharacters(in: .whitespacesAndNewlines)
        // parseRememberKeyValue with non-empty `contact` returns `body`
        // verbatim as the value — so pass JUST the value, NOT
        // "subject is value". Otherwise we store "Batta is my brother"
        // instead of "my brother" and recall produces duplicate phrasing
        // like "Batta is Batta is my brother".
        guard let (key, parsedValue) = GigiMemory.parseRememberKeyValue(contact: subject, body: value) else {
            return ""
        }
        await GigiMemory.shared.remember(key: key, value: parsedValue, category: cat.isEmpty ? nil : cat)
        let displayRaw = key.contains(":")
            ? String(key.split(separator: ":", maxSplits: 1).last ?? Substring(key))
            : key
        let display = GigiMemory.flipFirstPerson(displayRaw)
        let valueSpoken = GigiMemory.flipFirstPerson(parsedValue)
        return "Got it. I'll remember that \(display) is \(valueSpoken)."
    }
}

/// Looks up a previously-stored fact. Apple FM should call this for any
/// utterance that asks about a known entity — explicit recall verbs are
/// not required:
///   "Who is Marco" / "Who's Marco" / "Whos Marco"
///   "What is the wifi password"
///   "Chi è Marco"
///   "What did I tell you about Marco"
/// On cache miss the tool returns an empty string so the router falls
/// back to delegate_local for generic knowledge.
@available(iOS 26.0, *)
struct FMRecallTool: Tool {
    let name = "recall"
    let description = "Retrieve a fact the user previously asked GIGI to remember. Call this whenever the user asks about a known entity — name, password, preference, place, relationship — regardless of phrasing. Includes 'who is X', 'who's X', 'what's the X', 'chi è X', 'tell me about X', 'remind me what X is'."

    @Generable
    struct Arguments {
        @Guide(description: "Entity to recall — strip filler words and trailing punctuation. Examples: 'marco' (from 'Who is Marco?'), 'wifi password' (from 'what is the wifi password'), 'favorite color' (from 'my favorite color is what'). Lowercase. Always provide.")
        var subject: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        let q = arguments.subject
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "?.,;:!"))
        guard !q.isEmpty else { return "" }
        return await GigiMemory.shared.recallResolving(q) ?? ""
    }
}

// MARK: - Registry

@available(iOS 26.0, *)
@MainActor
enum GigiFoundationToolRegistry {

    /// Static collection of all 26 tools (17 baseline + 3 from GATE 9 Week 1 +
    /// 6 from GATE 10 Week 2: utility 10.B + knowledge mini 10.C). Used by
    /// `GigiRequestRouter` to pick the relevant tool (or pass them all to
    /// Apple FM when ambiguous).
    static var allTools: [any Tool] {
        [
            FMSetTimerTool(),
            FMSetAlarmTool(),
            FMSetReminderTool(),
            FMSendMessageTool(),
            FMMakeCallTool(),
            FMFacetimeTool(),
            FMNavigateTool(),
            FMPlayMusicTool(),
            FMOpenAppTool(),
            FMWeatherTool(),
            FMReadCalendarTool(),
            FMFindFreeSlotTool(),
            FMReadEmailTool(),
            FMHomeKitOnTool(),
            FMHomeKitOffTool(),
            FMCreateNoteTool(),
            FMWebOrderFoodTool(),
            // GATE 9 capability expansion Week 1
            FMRunShortcutTool(),
            FMSetHomeKitSceneTool(),
            FMWebSearchTool(),
            // GATE 10.B capability expansion Week 2 — utility
            FMReadClipboardTool(),
            FMGetDeviceBatteryTool(),
            FMToggleFlashlightTool(),
            // GATE 10.C capability expansion Week 2 — knowledge mini
            FMDefineWordTool(),
            FMCalculateMathTool(),
            FMTranslateTextTool(),
            // GATE 10.A capability expansion Week 2 — productivity
            FMCreateCalendarEventTool(),
            FMAddToNoteTool(),
            // Phase 2 — AI-generated Shortcuts (Cherri pipeline)
            FMBuildShortcutTool(),
            // Memory tools — assertion + lookup of user-stored facts
            FMRememberTool(),
            FMRecallTool()
        ]
    }

    /// Return the single tool matching a canonical action name, or nil.
    static func tool(for action: String) -> (any Tool)? {
        allTools.first { $0.name == action }
    }

    /// All canonical action names exposed to Apple FM.
    static let canonicalActions: [String] = [
        "set_timer", "set_alarm", "set_reminder",
        "send_message", "make_call", "facetime",
        "navigate", "play_music", "open_app",
        "weather", "read_calendar", "find_free_slot", "read_email",
        "homekit_on", "homekit_off",
        "create_note",
        "web_order_food",
        // GATE 9 capability expansion Week 1
        "run_shortcut",
        "set_homekit_scene",
        "web_search",
        // GATE 10.B capability expansion Week 2 — utility
        "read_clipboard",
        "get_device_battery",
        "toggle_flashlight",
        // GATE 10.C capability expansion Week 2 — knowledge mini
        "define_word",
        "calculate_math",
        "translate_text",
        // GATE 10.A capability expansion Week 2 — productivity
        "create_calendar_event",
        "add_to_note",
        // Phase 2 — AI-generated Shortcuts
        "build_shortcut",
        // Memory tools — fact assertion + lookup
        "remember",
        "recall"
    ]
}

#endif
