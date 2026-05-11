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

// MARK: - Registry

@available(iOS 26.0, *)
@MainActor
enum GigiFoundationToolRegistry {

    /// Static collection of all 15 tools. Used by `GigiRequestRouter` to
    /// pick the relevant tool (or pass them all to Apple FM when the
    /// router decision is ambiguous).
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
            FMHomeKitOffTool()
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
        "homekit_on", "homekit_off"
    ]
}

#endif
