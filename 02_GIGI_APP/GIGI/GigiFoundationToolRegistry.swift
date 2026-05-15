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
        @Guide(description: "Recipient's full name as it appears in Contacts. Required.")
        var contact: String

        @Guide(description: "Verbatim message body. Strip framing words like 'saying' or 'tell them'.")
        var body: String

        @Guide(description: "Platform: whatsapp, imessage, sms, telegram. Default imessage.")
        var platform: String
    }

    @MainActor
    func call(arguments: Arguments) async -> String {
        await dispatchAction(label: "send_message", params: [
            "contact": arguments.contact,
            "body": arguments.body,
            "platform": arguments.platform.isEmpty ? "imessage" : arguments.platform
        ])
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
    let description = "Turn on a HomeKit-paired accessory (lamp, switch, plug, fan)."

    @Generable
    struct Arguments {
        @Guide(description: "Named HomeKit accessory as configured in the Home app, e.g. 'living room light', 'kitchen plug', 'bedroom fan'. NOT for the iPhone flashlight (use torch_on). NOT for music or radio (use play_music). The accessory name must be specific — refuse this tool if the user just said 'turn on the light' without specifying which.")
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
    // Apple FM constrained decoding largely ignores prose disambiguation —
    // it weights tool name and @Guide param descriptions. Keep this short.
    let description = "Execute an already-installed iOS Shortcut by name."

    @Generable
    struct Arguments {
        @Guide(description: "The exact Shortcut name. NOT a verb, NOT a HomeKit accessory, NOT a generic action. Pick this ONLY when the user said run/execute/launch/trigger/esegui/lancia + a name. Wrong picks: 'accendi torcia' (use torch_on), 'turn on lights' (use homekit_on), 'create a shortcut that…' (use build_shortcut).")
        var name: String

        @Guide(description: "Optional input forwarded to the Shortcut. Empty string when none.")
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
            FMBuildShortcutTool()
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
        "build_shortcut"
    ]
}

#endif
