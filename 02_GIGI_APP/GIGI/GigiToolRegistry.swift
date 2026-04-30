import EventKit
import Foundation

// MARK: - Shared value types

struct ToolResult: Sendable {
    let value: String
    let error: String?
    let requiresConfirm: ConfirmRequest?
    let tokenEstimate: Int

    nonisolated static func success(_ value: String, tokenEstimate: Int = 10) -> ToolResult {
        ToolResult(value: value, error: nil, requiresConfirm: nil, tokenEstimate: tokenEstimate)
    }

    nonisolated static func failure(_ error: String) -> ToolResult {
        ToolResult(value: "", error: error, requiresConfirm: nil, tokenEstimate: 5)
    }

    nonisolated static func confirm(_ request: ConfirmRequest, tokenEstimate: Int = 15) -> ToolResult {
        ToolResult(value: "", error: nil, requiresConfirm: request, tokenEstimate: tokenEstimate)
    }
}

struct ConfirmRequest: @unchecked Sendable {
    let type: ConfirmType
    let summary: String
    let action: String
    let args: [String: Any]   // [String: Any] is not Sendable but args are read-only value copies
}

enum ConfirmType {
    case payment, destructive, sensitive
}

// MARK: - FunctionDeclaration (Encodable → Gemini API JSON)

struct FunctionDeclaration: Encodable {
    let name: String
    let description: String
    let parameters: JSONSchema
}

struct JSONSchema: Encodable {
    let type: String
    let properties: [String: JSONSchemaProperty]
    let required: [String]
}

struct JSONSchemaProperty: Encodable {
    let type: String
    let description: String
    let enumValues: [String]?

    enum CodingKeys: String, CodingKey {
        case type, description
        case enumValues = "enum"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(description, forKey: .description)
        if let ev = enumValues { try c.encode(ev, forKey: .enumValues) }
    }
}

// MARK: - Protocol

protocol GigiTool {
    var name: String { get }
    var declaration: FunctionDeclaration { get }
    var requiresConfirmation: Bool { get }
    /// Words/phrases that trigger inclusion in the 10-tool subset sent to Gemini.
    var tags: [String] { get }
    func execute(args: [String: Any]) async -> ToolResult
}

// MARK: - Helpers

private func bridge(_ toolName: String, params: [String: String] = [:]) async -> ToolResult {
    // Route through executeNative for disambiguation + param validation
    let args: [String: Any] = params
    return await GigiActionDispatcher.shared.executeNative(toolName, args: args)
}

private func str(_ args: [String: Any], _ key: String, fallback: String = "") -> String {
    args[key] as? String ?? fallback
}

// MARK: - Native iOS tools

struct MakeCallTool: GigiTool {
    let name = "make_call"
    let requiresConfirmation = false
    let tags = ["call", "phone", "chiama", "ring", "dial", "chiamare", "telefona"]

    let declaration = FunctionDeclaration(
        name: "make_call",
        description: "Call a contact by name. Use contact_id to disambiguate if multiple matches.",
        parameters: JSONSchema(
            type: "object",
            properties: [
                "contact":    JSONSchemaProperty(type: "string", description: "Contact name", enumValues: nil),
                "contact_id": JSONSchemaProperty(type: "string", description: "Exact contact ID from a previous disambiguation step", enumValues: nil)
            ],
            required: ["contact"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("make_call", params: ["contact": str(args, "contact"), "contact_id": str(args, "contact_id")])
    }
}

struct SendMessageTool: GigiTool {
    let name = "send_message"
    let requiresConfirmation = true
    let tags = ["message", "text", "sms", "imessage", "whatsapp", "telegram", "manda", "scrivi", "messaggio"]

    let declaration = FunctionDeclaration(
        name: "send_message",
        description: "Send a message to a contact via iMessage, WhatsApp, SMS, or Telegram.",
        parameters: JSONSchema(
            type: "object",
            properties: [
                "contact":    JSONSchemaProperty(type: "string", description: "Contact name", enumValues: nil),
                "body":       JSONSchemaProperty(type: "string", description: "Message text", enumValues: nil),
                "platform":   JSONSchemaProperty(type: "string", description: "Messaging platform", enumValues: ["imessage", "whatsapp", "sms", "telegram"]),
                "contact_id": JSONSchemaProperty(type: "string", description: "Exact contact ID for disambiguation", enumValues: nil)
            ],
            required: ["contact", "body"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("send_message", params: [
            "contact":    str(args, "contact"),
            "body":       str(args, "body"),
            "platform":   str(args, "platform", fallback: "imessage"),
            "contact_id": str(args, "contact_id")
        ])
    }
}

struct NavigateTool: GigiTool {
    let name = "navigate"
    let requiresConfirmation = false
    let tags = ["navigate", "maps", "directions", "drive", "portami", "naviga", "dove"]

    let declaration = FunctionDeclaration(
        name: "navigate",
        description: "Open Maps and start navigation to a destination.",
        parameters: JSONSchema(
            type: "object",
            properties: ["destination": JSONSchemaProperty(type: "string", description: "Address or place name", enumValues: nil)],
            required: ["destination"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("navigate", params: ["destination": str(args, "destination")])
    }
}

struct PlayMusicTool: GigiTool {
    let name = "play_music"
    let requiresConfirmation = false
    let tags = ["music", "song", "playlist", "spotify", "play", "musica", "canzone", "riproduci", "ascolta"]

    let declaration = FunctionDeclaration(
        name: "play_music",
        description: "Play music by artist, song, or playlist. Supports Apple Music and Spotify.",
        parameters: JSONSchema(
            type: "object",
            properties: [
                "query": JSONSchemaProperty(type: "string", description: "Song, artist, or playlist name", enumValues: nil),
                "app":   JSONSchemaProperty(type: "string", description: "Music app", enumValues: ["apple_music", "spotify"])
            ],
            required: ["query"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("play_music", params: ["query": str(args, "query"), "app": str(args, "app")])
    }
}

struct SetReminderTool: GigiTool {
    let name = "set_reminder"
    let requiresConfirmation = true
    let tags = ["reminder", "remind", "promemoria", "ricordami", "remember", "non dimenticare"]

    let declaration = FunctionDeclaration(
        name: "set_reminder",
        description: "Create a reminder with optional date and time.",
        parameters: JSONSchema(
            type: "object",
            properties: [
                "text": JSONSchemaProperty(type: "string", description: "Reminder text", enumValues: nil),
                "date": JSONSchemaProperty(type: "string", description: "Date (e.g. today, tomorrow, 2026-04-22)", enumValues: nil),
                "time": JSONSchemaProperty(type: "string", description: "Time (e.g. 14:30, 3pm)", enumValues: nil)
            ],
            required: ["text"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("set_reminder", params: ["text": str(args, "text"), "date": str(args, "date"), "time": str(args, "time")])
    }
}

struct CreateEventTool: GigiTool {
    let name = "create_event"
    let requiresConfirmation = true
    let tags = ["calendar", "event", "meeting", "appointment", "schedule", "agenda", "crea", "evento", "riunione", "appuntamento"]

    let declaration = FunctionDeclaration(
        name: "create_event",
        description: "Create a calendar event.",
        parameters: JSONSchema(
            type: "object",
            properties: [
                "title":   JSONSchemaProperty(type: "string", description: "Event title", enumValues: nil),
                "date":    JSONSchemaProperty(type: "string", description: "Date (e.g. tomorrow, 2026-04-22)", enumValues: nil),
                "time":    JSONSchemaProperty(type: "string", description: "Start time (e.g. 14:30)", enumValues: nil),
                "contact": JSONSchemaProperty(type: "string", description: "Attendee to invite", enumValues: nil)
            ],
            required: ["title", "date", "time"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("create_event", params: [
            "title":   str(args, "title"),
            "date":    str(args, "date"),
            "time":    str(args, "time"),
            "contact": str(args, "contact")
        ])
    }
}

struct SetAlarmTool: GigiTool {
    let name = "set_alarm"
    let requiresConfirmation = false
    let tags = ["alarm", "sveglia", "wake", "wake up", "svegliami"]

    let declaration = FunctionDeclaration(
        name: "set_alarm",
        description: "Set an alarm at a specific time.",
        parameters: JSONSchema(
            type: "object",
            properties: [
                "time": JSONSchemaProperty(type: "string", description: "Time (e.g. 7:30, 07:30am)", enumValues: nil),
                "date": JSONSchemaProperty(type: "string", description: "Date (today, tomorrow)", enumValues: nil)
            ],
            required: ["time"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("set_alarm", params: ["time": str(args, "time"), "date": str(args, "date", fallback: "today")])
    }
}

struct SetTimerTool: GigiTool {
    let name = "set_timer"
    let requiresConfirmation = false
    let tags = ["timer", "countdown", "minutes", "seconds", "minuti", "secondi", "tra"]

    let declaration = FunctionDeclaration(
        name: "set_timer",
        description: "Start a countdown timer.",
        parameters: JSONSchema(
            type: "object",
            properties: ["duration": JSONSchemaProperty(type: "string", description: "Duration as natural language (e.g. '10 minutes', '1 hour and 30 minutes')", enumValues: nil)],
            required: ["duration"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("set_timer", params: ["text": str(args, "duration")])
    }
}

struct OpenAppTool: GigiTool {
    let name = "open_app"
    let requiresConfirmation = false
    let tags = ["open", "launch", "apri", "avvia", "app"]

    let declaration = FunctionDeclaration(
        name: "open_app",
        description: "Open an installed app by name.",
        parameters: JSONSchema(
            type: "object",
            properties: ["app": JSONSchemaProperty(type: "string", description: "App name (e.g. Spotify, WhatsApp, Maps)", enumValues: nil)],
            required: ["app"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("open_app", params: ["app": str(args, "app")])
    }
}

struct AskTimeTool: GigiTool {
    let name = "ask_time"
    let requiresConfirmation = false
    let tags = ["time", "ora", "che ore", "orario"]

    let declaration = FunctionDeclaration(
        name: "ask_time",
        description: "Tell the current time.",
        parameters: JSONSchema(type: "object", properties: [:], required: [])
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("ask_time")
    }
}

struct AskDateTool: GigiTool {
    let name = "ask_date"
    let requiresConfirmation = false
    let tags = ["date", "day", "data", "giorno", "oggi"]

    let declaration = FunctionDeclaration(
        name: "ask_date",
        description: "Tell today's date.",
        parameters: JSONSchema(type: "object", properties: [:], required: [])
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("ask_date")
    }
}

struct WeatherTool: GigiTool {
    let name = "weather"
    let requiresConfirmation = false
    let tags = ["weather", "meteo", "temperatura", "piove", "rain", "forecast", "previsioni"]

    let declaration = FunctionDeclaration(
        name: "weather",
        description: "Get current weather and forecast for a location.",
        parameters: JSONSchema(
            type: "object",
            properties: ["location": JSONSchemaProperty(type: "string", description: "City name or 'current location'", enumValues: nil)],
            required: ["location"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("weather", params: ["destination": str(args, "location")])
    }
}

struct TorchOnTool: GigiTool {
    let name = "torch_on"
    let requiresConfirmation = false
    let tags = ["torch", "flashlight", "torcia", "torchio", "luce", "flash"]

    let declaration = FunctionDeclaration(
        name: "torch_on",
        description: "Turn on the camera flashlight.",
        parameters: JSONSchema(type: "object", properties: [:], required: [])
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("torch_on")
    }
}

struct TorchOffTool: GigiTool {
    let name = "torch_off"
    let requiresConfirmation = false
    let tags = ["torch", "flashlight", "torcia", "torchio", "luce", "flash", "off", "spegni"]

    let declaration = FunctionDeclaration(
        name: "torch_off",
        description: "Turn off the camera flashlight.",
        parameters: JSONSchema(type: "object", properties: [:], required: [])
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("torch_off")
    }
}

struct FaceTimeTool: GigiTool {
    let name = "facetime"
    let requiresConfirmation = false
    let tags = ["facetime", "video call", "videochiamata", "video"]

    let declaration = FunctionDeclaration(
        name: "facetime",
        description: "Start a FaceTime video call with a contact.",
        parameters: JSONSchema(
            type: "object",
            properties: ["contact": JSONSchemaProperty(type: "string", description: "Contact name", enumValues: nil)],
            required: ["contact"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("facetime", params: ["contact": str(args, "contact")])
    }
}

struct FaceTimeAudioTool: GigiTool {
    let name = "facetime_audio"
    let requiresConfirmation = false
    let tags = ["facetime", "audio call", "chiamata audio"]

    let declaration = FunctionDeclaration(
        name: "facetime_audio",
        description: "Start a FaceTime audio call with a contact.",
        parameters: JSONSchema(
            type: "object",
            properties: ["contact": JSONSchemaProperty(type: "string", description: "Contact name", enumValues: nil)],
            required: ["contact"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("facetime_audio", params: ["contact": str(args, "contact")])
    }
}

struct MediaPlayPauseTool: GigiTool {
    let name = "media_play_pause"
    let requiresConfirmation = false
    let tags = ["play", "pause", "stop", "pausa", "riproduci", "musica", "media"]

    let declaration = FunctionDeclaration(
        name: "media_play_pause",
        description: "Toggle play/pause for the currently playing media.",
        parameters: JSONSchema(type: "object", properties: [:], required: [])
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("media_play_pause")
    }
}

struct MediaNextTool: GigiTool {
    let name = "media_next"
    let requiresConfirmation = false
    let tags = ["next", "skip", "prossima", "avanti", "canzone"]

    let declaration = FunctionDeclaration(
        name: "media_next",
        description: "Skip to the next track.",
        parameters: JSONSchema(type: "object", properties: [:], required: [])
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("media_next")
    }
}

struct MediaPreviousTool: GigiTool {
    let name = "media_previous"
    let requiresConfirmation = false
    let tags = ["previous", "back", "precedente", "indietro", "canzone"]

    let declaration = FunctionDeclaration(
        name: "media_previous",
        description: "Go to the previous track.",
        parameters: JSONSchema(type: "object", properties: [:], required: [])
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("media_previous")
    }
}

struct ReadCalendarTool: GigiTool {
    let name = "read_calendar"
    let requiresConfirmation = false
    let tags = ["calendar", "agenda", "today", "events", "schedule", "oggi", "calendario", "appuntamenti"]

    let declaration = FunctionDeclaration(
        name: "read_calendar",
        description: "Read today's calendar events.",
        parameters: JSONSchema(type: "object", properties: [:], required: [])
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("read_calendar")
    }
}

struct ReadWeekCalendarTool: GigiTool {
    let name = "read_week_calendar"
    let requiresConfirmation = false
    let tags = ["week", "settimana", "this week", "prossima settimana", "calendar", "agenda"]

    let declaration = FunctionDeclaration(
        name: "read_week_calendar",
        description: "Read a summary of this week's calendar events (compact, not raw).",
        parameters: JSONSchema(type: "object", properties: [:], required: [])
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("read_week_calendar")
    }
}

struct FindFreeSlotTool: GigiTool {
    let name = "find_free_slot"
    let requiresConfirmation = false
    let tags = ["free", "slot", "available", "libero", "disponibile", "quando", "schedule", "meeting", "book"]

    let declaration = FunctionDeclaration(
        name: "find_free_slot",
        description: "Find available time slots in the calendar using semantic context (lunch, dinner, morning). Returns only available slots, not raw events.",
        parameters: JSONSchema(
            type: "object",
            properties: [
                "duration":       JSONSchemaProperty(type: "string", description: "Duration in minutes (e.g. '60')", enumValues: nil),
                "date":           JSONSchemaProperty(type: "string", description: "Date to search (today, tomorrow, 2026-04-22)", enumValues: nil),
                "preferred_time": JSONSchemaProperty(type: "string", description: "Preferred start time (e.g. '14:00')", enumValues: nil),
                "context":        JSONSchemaProperty(type: "string", description: "Semantic context: pranzo, cena, mattina, pomeriggio, riunione", enumValues: nil)
            ],
            required: ["duration", "date"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        let duration  = Int(str(args, "duration", fallback: "60")) ?? 60
        let dateStr   = str(args, "date", fallback: "today")
        let preferred = str(args, "preferred_time")
        let context   = str(args, "context")

        let eventStore = EKEventStore()
        let granted = await requestCalendarAccess(store: eventStore)
        guard granted else {
            return .failure("Calendar access denied. Ask user to enable it in Settings.")
        }

        let (start, end) = resolveDate(dateStr)
        let range = semanticRange(context: context, preferred: preferred, dayStart: start, dayEnd: end)

        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        let slots = findGaps(events: events, duration: duration, range: range)

        let tz = TimeZone.current.abbreviation() ?? "local"
        if slots.isEmpty {
            return .success("No free \(duration)min slots found for \(dateStr) in the \(context.isEmpty ? "requested" : context) window (\(tz)).", tokenEstimate: 20)
        }

        let formatted = slots.map { formatSlot($0, duration: duration) }.joined(separator: ", ")
        return .success("Available slots (\(tz)): \(formatted)", tokenEstimate: 30)
    }

    private func requestCalendarAccess(store: EKEventStore) async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    private func resolveDate(_ dateStr: String) -> (Date, Date) {
        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        let base: Date
        switch dateStr.lowercased() {
        case "today":    base = Date()
        case "tomorrow": base = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        default:
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            df.timeZone = TimeZone.current
            base = df.date(from: dateStr) ?? Date()
        }
        let dayStart = cal.startOfDay(for: base)
        let dayEnd   = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        return (dayStart, dayEnd)
    }

    // Returns (rangeStart, rangeEnd) within the given day
    private func semanticRange(context: String, preferred: String, dayStart: Date, dayEnd: Date) -> (Date, Date) {
        var cal = Calendar.current
        cal.timeZone = TimeZone.current

        func time(_ h: Int, _ m: Int) -> Date {
            cal.date(bySettingHour: h, minute: m, second: 0, of: dayStart) ?? dayStart
        }

        let lower = context.lowercased()
        if lower.contains("pranzo") || lower.contains("lunch") { return (time(12, 0), time(14, 30)) }
        if lower.contains("cena")   || lower.contains("dinner") { return (time(19, 0), time(21, 30)) }
        if lower.contains("mattina") || lower.contains("morning") { return (time(8, 0), time(12, 0)) }
        if lower.contains("pomeriggio") || lower.contains("afternoon") { return (time(14, 0), time(18, 0)) }

        if !preferred.isEmpty {
            let df = DateFormatter()
            df.dateFormat = "HH:mm"
            df.timeZone = TimeZone.current
            if let t = df.date(from: preferred) {
                let comps = cal.dateComponents([.hour, .minute], from: t)
                let h = comps.hour ?? 9, m = comps.minute ?? 0
                return (time(h, m), dayEnd)
            }
        }
        return (time(9, 0), time(18, 0))
    }

    private func findGaps(events: [EKEvent], duration: Int, range: (Date, Date)) -> [Date] {
        var slots: [Date] = []
        var cursor = range.0
        let step = TimeInterval(15 * 60)  // 15-min grid
        let needed = TimeInterval(duration * 60)

        // Collect busy intervals within range
        let busy: [(Date, Date)] = events.compactMap { e in
            guard e.startDate < range.1 && e.endDate > range.0 else { return nil }
            return (max(e.startDate, range.0), min(e.endDate, range.1))
        }

        while cursor.addingTimeInterval(needed) <= range.1 {
            let slotEnd = cursor.addingTimeInterval(needed)
            let overlaps = busy.contains { b in b.0 < slotEnd && b.1 > cursor }
            if !overlaps { slots.append(cursor) }
            cursor = cursor.addingTimeInterval(step)
        }

        // Return distinct non-overlapping slots (every 30min to avoid spam)
        var result: [Date] = []
        var lastAdded: Date? = nil
        for slot in slots {
            if let last = lastAdded, slot.timeIntervalSince(last) < 30 * 60 { continue }
            result.append(slot)
            lastAdded = slot
            if result.count >= 4 { break }
        }
        return result
    }

    private func formatSlot(_ date: Date, duration: Int) -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        df.timeZone = TimeZone.current
        let endDate = date.addingTimeInterval(TimeInterval(duration * 60))
        return "\(df.string(from: date))–\(df.string(from: endDate))"
    }
}

struct SearchWebTool: GigiTool {
    let name = "search_web"
    let requiresConfirmation = false
    let tags = ["search", "google", "cerca", "web", "browser", "safari", "trova"]

    let declaration = FunctionDeclaration(
        name: "search_web",
        description: "Open Safari and search the web for a query.",
        parameters: JSONSchema(
            type: "object",
            properties: ["query": JSONSchemaProperty(type: "string", description: "Search query", enumValues: nil)],
            required: ["query"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("search_web", params: ["query": str(args, "query")])
    }
}

struct ReadNewsTool: GigiTool {
    let name = "read_news"
    let requiresConfirmation = false
    let tags = ["news", "notizie", "headlines", "aggiornamenti", "tg"]

    let declaration = FunctionDeclaration(
        name: "read_news",
        description: "Fetch top news headlines or news about a topic.",
        parameters: JSONSchema(
            type: "object",
            properties: ["query": JSONSchemaProperty(type: "string", description: "Topic or 'top news'", enumValues: nil)],
            required: ["query"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("read_news", params: ["query": str(args, "query", fallback: "top news")])
    }
}

struct SendEmailTool: GigiTool {
    let name = "send_email"
    let requiresConfirmation = false
    let tags = ["email", "mail", "invia", "scrivi", "manda email"]

    let declaration = FunctionDeclaration(
        name: "send_email",
        description: "Compose and send an email.",
        parameters: JSONSchema(
            type: "object",
            properties: [
                "contact": JSONSchemaProperty(type: "string", description: "Recipient name or email address", enumValues: nil),
                "subject": JSONSchemaProperty(type: "string", description: "Email subject", enumValues: nil),
                "body":    JSONSchemaProperty(type: "string", description: "Email body text", enumValues: nil)
            ],
            required: ["contact", "subject", "body"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("send_email", params: [
            "contact": str(args, "contact"),
            "title":   str(args, "subject"),
            "body":    str(args, "body")
        ])
    }
}

struct ToggleWifiTool: GigiTool {
    let name = "toggle_wifi"
    let requiresConfirmation = false
    let tags = ["wifi", "wi-fi", "internet", "rete", "network"]

    let declaration = FunctionDeclaration(
        name: "toggle_wifi",
        description: "Open Wi-Fi settings (iOS does not allow programmatic Wi-Fi toggle).",
        parameters: JSONSchema(type: "object", properties: [:], required: [])
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("toggle_wifi")
    }
}

struct ToggleBluetoothTool: GigiTool {
    let name = "toggle_bluetooth"
    let requiresConfirmation = false
    let tags = ["bluetooth", "bt", "cuffie", "airpods", "headphones"]

    let declaration = FunctionDeclaration(
        name: "toggle_bluetooth",
        description: "Open Bluetooth settings (iOS does not allow programmatic Bluetooth toggle).",
        parameters: JSONSchema(type: "object", properties: [:], required: [])
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("toggle_bluetooth")
    }
}

// NOTE: HomeKit tools require the HomeKit capability in Xcode:
// Signing & Capabilities → + Capability → HomeKit
// Also add NSHomeKitUsageDescription to Info.plist.
struct HomekitOnTool: GigiTool {
    let name = "homekit_on"
    let requiresConfirmation = false
    let tags = ["light", "lamp", "luce", "accendi", "turn on", "home", "homekit", "luci"]

    let declaration = FunctionDeclaration(
        name: "homekit_on",
        description: "Turn on a HomeKit accessory (light, switch, plug).",
        parameters: JSONSchema(
            type: "object",
            properties: ["accessory": JSONSchemaProperty(type: "string", description: "Accessory or room name (e.g. 'living room light')", enumValues: nil)],
            required: ["accessory"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("homekit_on", params: ["accessory": str(args, "accessory")])
    }
}

struct HomekitOffTool: GigiTool {
    let name = "homekit_off"
    let requiresConfirmation = false
    let tags = ["light", "lamp", "luce", "spegni", "turn off", "home", "homekit"]

    let declaration = FunctionDeclaration(
        name: "homekit_off",
        description: "Turn off a HomeKit accessory.",
        parameters: JSONSchema(
            type: "object",
            properties: ["accessory": JSONSchemaProperty(type: "string", description: "Accessory or room name", enumValues: nil)],
            required: ["accessory"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("homekit_off", params: ["accessory": str(args, "accessory")])
    }
}

struct HomekitDimTool: GigiTool {
    let name = "homekit_dim"
    let requiresConfirmation = false
    let tags = ["dim", "brightness", "luminosità", "abbassa", "alza", "luce", "homekit"]

    let declaration = FunctionDeclaration(
        name: "homekit_dim",
        description: "Set brightness of a HomeKit light (0–100%).",
        parameters: JSONSchema(
            type: "object",
            properties: [
                "accessory":  JSONSchemaProperty(type: "string", description: "Accessory name", enumValues: nil),
                "brightness": JSONSchemaProperty(type: "string", description: "Brightness percentage (0–100)", enumValues: nil)
            ],
            required: ["accessory", "brightness"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("homekit_dim", params: ["accessory": str(args, "accessory"), "brightness": str(args, "brightness")])
    }
}

struct HomekitTempTool: GigiTool {
    let name = "homekit_temp"
    let requiresConfirmation = false
    let tags = ["temperature", "thermostat", "temperatura", "termostato", "caldo", "freddo", "riscalda"]

    let declaration = FunctionDeclaration(
        name: "homekit_temp",
        description: "Set thermostat temperature.",
        parameters: JSONSchema(
            type: "object",
            properties: ["temperature": JSONSchemaProperty(type: "string", description: "Target temperature in Celsius (e.g. '21')", enumValues: nil)],
            required: ["temperature"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("homekit_temp", params: ["temperature": str(args, "temperature")])
    }
}

struct HomekitSceneTool: GigiTool {
    let name = "homekit_scene"
    let requiresConfirmation = false
    let tags = ["scene", "scena", "buonanotte", "goodnight", "movie", "cena", "homekit", "routine"]

    let declaration = FunctionDeclaration(
        name: "homekit_scene",
        description: "Activate a HomeKit scene (e.g. Goodnight, Movie, Morning).",
        parameters: JSONSchema(
            type: "object",
            properties: ["scene": JSONSchemaProperty(type: "string", description: "Scene name", enumValues: nil)],
            required: ["scene"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("homekit_scene", params: ["scene": str(args, "scene")])
    }
}

struct RememberTool: GigiTool {
    let name = "remember"
    let requiresConfirmation = false
    let tags = ["remember", "save", "store", "nota", "ricorda", "salva", "memory"]

    let declaration = FunctionDeclaration(
        name: "remember",
        description: "Save a fact to persistent memory (CloudKit). Use namespaced keys: contact:, pref:, place:, routine:, opinion:, relation:.",
        parameters: JSONSchema(
            type: "object",
            properties: [
                "key":   JSONSchemaProperty(type: "string", description: "Namespaced key (e.g. 'contact:Marco', 'pref:cuisine', 'place:home', 'relation:wife')", enumValues: nil),
                "value": JSONSchemaProperty(type: "string", description: "Value to store", enumValues: nil)
            ],
            required: ["key", "value"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await GigiMemory.shared.remember(key: str(args, "key"), value: str(args, "value"))
        return .success("Remembered: \(str(args, "key")) = \(str(args, "value"))")
    }
}

struct RecallTool: GigiTool {
    let name = "recall"
    let requiresConfirmation = false
    let tags = ["recall", "remember", "chi è", "who is", "what is", "dimmi", "numero", "indirizzo", "memory"]

    let declaration = FunctionDeclaration(
        name: "recall",
        description: "Retrieve a previously saved fact from memory.",
        parameters: JSONSchema(
            type: "object",
            properties: ["query": JSONSchemaProperty(type: "string", description: "What to search for (e.g. 'Marco phone number', 'home address')", enumValues: nil)],
            required: ["query"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        let q = str(args, "query")
        if let value = await GigiMemory.shared.recallResolving(q) {
            return .success(value, tokenEstimate: 15)
        }
        return .failure("Nothing found in memory for: \(q)")
    }
}

struct SearchGroupsTool: GigiTool {
    let name = "search_groups"
    let requiresConfirmation = false
    let tags = ["group", "gruppo", "chat di gruppo", "group chat", "whatsapp group"]

    let declaration = FunctionDeclaration(
        name: "search_groups",
        description: "Search for a group chat by name across WhatsApp and iMessage.",
        parameters: JSONSchema(
            type: "object",
            properties: ["name": JSONSchemaProperty(type: "string", description: "Group name or partial name", enumValues: nil)],
            required: ["name"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("search_groups", params: ["query": str(args, "name")])
    }
}

// MARK: - Web automation tools

struct WebWhatsAppTool: GigiTool {
    let name = "web_whatsapp"
    let requiresConfirmation = true
    let tags = ["whatsapp", "wa", "whatsapp web", "messaggio whatsapp"]

    let declaration = FunctionDeclaration(
        name: "web_whatsapp",
        description: "Send a WhatsApp message via WhatsApp Web (on-device WKWebView, no backend needed).",
        parameters: JSONSchema(
            type: "object",
            properties: [
                "contact": JSONSchemaProperty(type: "string", description: "Contact name as it appears in WhatsApp", enumValues: nil),
                "message": JSONSchemaProperty(type: "string", description: "Message text", enumValues: nil)
            ],
            required: ["contact", "message"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("web_whatsapp", params: [
            "contact": str(args, "contact"),
            "message": str(args, "message"),
        ])
    }
}

struct WebBookRestaurantTool: GigiTool {
    let name = "web_book_restaurant"
    let requiresConfirmation = true
    let tags = ["restaurant", "book", "reservation", "prenotazione", "ristorante", "prenota", "tavolo", "thefork", "opentable", "resy"]

    let declaration = FunctionDeclaration(
        name: "web_book_restaurant",
        description: "Book a restaurant table via TheFork, OpenTable, or Resy. Always requires confirmation before final booking.",
        parameters: JSONSchema(
            type: "object",
            properties: [
                "restaurant": JSONSchemaProperty(type: "string", description: "Restaurant name", enumValues: nil),
                "time":       JSONSchemaProperty(type: "string", description: "Desired time (e.g. '20:00')", enumValues: nil),
                "guests":     JSONSchemaProperty(type: "string", description: "Number of guests", enumValues: nil),
                "date":       JSONSchemaProperty(type: "string", description: "Date (today, tomorrow, 2026-04-22)", enumValues: nil),
                "platform":   JSONSchemaProperty(type: "string", description: "Booking platform", enumValues: ["thefork", "opentable", "resy", "auto"])
            ],
            required: ["restaurant", "time", "guests", "date"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("web_book_restaurant", params: [
            "restaurant": str(args, "restaurant"),
            "time":       str(args, "time"),
            "guests":     str(args, "guests", fallback: "2"),
            "date":       str(args, "date", fallback: "today"),
            "platform":   str(args, "platform", fallback: "auto"),
        ])
    }
}

struct WebOrderFoodTool: GigiTool {
    let name = "web_order_food"
    let requiresConfirmation = false
    let tags = ["order", "food", "delivery", "pizza", "deliveroo", "ubereats", "doordash", "glovo", "justeat", "just eat", "just-eat", "just hit", "cibo", "ordina", "ordinami", "consegna"]

    let declaration = FunctionDeclaration(
        name: "web_order_food",
        description: "Order food via a delivery platform. Delegates to Mac harness for browser automation.",
        parameters: JSONSchema(
            type: "object",
            properties: [
                "restaurant": JSONSchemaProperty(type: "string", description: "Restaurant name or cuisine type (e.g. 'Pizzeria Napoli', 'sushi'). Do NOT put the platform name here.", enumValues: nil),
                "items":      JSONSchemaProperty(type: "string", description: "Items to order (optional)", enumValues: nil),
                "platform":   JSONSchemaProperty(type: "string", description: "Delivery platform", enumValues: ["deliveroo", "ubereats", "doordash", "glovo", "justeat", "auto"])
            ],
            required: []
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("web_order_food", params: [
            "restaurant": str(args, "restaurant"),
            "items":      str(args, "items"),
            "platform":   str(args, "platform", fallback: "auto"),
        ])
    }
}

struct WebSearchAndReadTool: GigiTool {
    let name = "web_search_and_read"
    let requiresConfirmation = false
    let tags = ["research", "find online", "article", "leggi", "cerca online", "notizia"]

    let declaration = FunctionDeclaration(
        name: "web_search_and_read",
        description: "Search the web and return a summary of the top results.",
        parameters: JSONSchema(
            type: "object",
            properties: ["query": JSONSchemaProperty(type: "string", description: "Search query", enumValues: nil)],
            required: ["query"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("web_search_and_read", params: ["query": str(args, "query")])
    }
}

struct WebVisionTaskTool: GigiTool {
    let name = "web_vision_task"
    let requiresConfirmation = false
    let tags = ["farfetch", "amazon", "buy", "purchase", "shop", "order", "book", "reserve",
                "checkout", "cart", "instagram", "post", "publish", "website", "form",
                "acquista", "compra", "prenota", "pubblica", "sito", "pagina"]

    let declaration = FunctionDeclaration(
        name: "web_vision_task",
        description: """
        Open a website and complete a task autonomously using vision AI. Use this for any \
        web task not covered by other tools: shopping on Farfetch/Amazon, posting on Instagram, \
        filling out forms, reading prices, booking anything. Provide the starting URL and a \
        natural-language task description. GIGI will screenshot the page and act step by step.
        """,
        parameters: JSONSchema(
            type: "object",
            properties: [
                "url":       JSONSchemaProperty(type: "string", description: "Starting URL (e.g. https://www.farfetch.com). Omit to operate on the currently loaded page.", enumValues: nil),
                "task":      JSONSchemaProperty(type: "string", description: "What to accomplish in plain language", enumValues: nil),
                "max_steps": JSONSchemaProperty(type: "string", description: "Max automation steps, default 8", enumValues: nil)
            ],
            required: ["task"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("web_vision_task", params: [
            "url":       str(args, "url"),
            "task":      str(args, "task"),
            "max_steps": str(args, "max_steps", fallback: "8")
        ])
    }
}

struct ComputerUseTool: GigiTool {
    let name = "computer_use"
    let requiresConfirmation = true
    let tags: [String] = []  // Never auto-selected by meta-classifier — only harness can invoke it explicitly

    let declaration = FunctionDeclaration(
        name: "computer_use",
        description: """
        LAST RESORT ONLY. Use this tool ONLY if ask_harness is unavailable or has already failed. \
        This tool uses a backend Claude agent with a real browser. It costs ~$0.20 per execution and \
        takes 20–40 seconds. Never use it for tasks that native iOS tools can handle.
        """,
        parameters: JSONSchema(
            type: "object",
            properties: ["task": JSONSchemaProperty(type: "string", description: "Detailed description of the browser task to complete", enumValues: nil)],
            required: ["task"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        await bridge("computer_use", params: ["task": str(args, "task")])
    }
}

// MARK: - Harness escalation tool (Leo lane)
//
// Routes the request through GigiHarnessClient.agentRun() — a single
// HTTP round-trip to the harness backend's planner/agent loop. Returns
// a finished result string. Use for tasks that fit the harness's
// browser/research/booking automation.

struct AskHarnessTool: GigiTool {
    let name = "ask_harness"
    let requiresConfirmation = false
    let tags = [
        "research", "find online", "flight", "hotel", "ticket", "prenotazione", "volo",
        "cerca online", "compra", "acquista", "ordina online", "complex task",
        "summarize", "riassumi", "analizza", "analyze", "report", "compare",
        "book", "prenota", "schedule meeting", "agenda", "mac", "computer",
        "cheapest", "price", "availability", "current", "latest",
        "web", "online", "search", "find", "look up", "check", "browse",
        "restaurant", "table", "reservation", "menu", "open",
        "news", "article", "read", "translate", "form",
        "deliveroo", "uber eats", "glovo", "amazon", "farfetch", "booking"
    ]

    let declaration = FunctionDeclaration(
        name: "ask_harness",
        description: """
        Delegate a complex or multi-step task to the Mac harness backend (Claude Opus + real Chrome \
        browser). Use for: deep web research, flight/hotel search, multi-site automation, reading \
        live web pages, file operations, or any task beyond native iOS capabilities. \
        Provide a complete, detailed task description including all context and desired output format.
        """,
        parameters: JSONSchema(
            type: "object",
            properties: [
                "task": JSONSchemaProperty(
                    type: "string",
                    description: "Complete task description with all context, data needed, and desired output format",
                    enumValues: nil
                )
            ],
            required: ["task"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        let task = str(args, "task")
        guard !task.isEmpty else { return .failure("ask_harness: task description required") }
        guard GigiHarnessClient.shared.isConfigured else {
            return .failure("Harness backend not set up. Go to Settings → Harness Backend and scan the QR code from your Mac.")
        }
        switch await GigiHarnessClient.shared.agentRun(text: task, domain: "browser") {
        case .success(let r): return .success(r.result, tokenEstimate: 50)
        case .failure(let e): return .failure("Harness error: \(e.description)")
        }
    }
}

// MARK: - Claude bridge escalation tool (Phase 1.5 — Armando lane)
//
// Exposed to Groq so the LLM can delegate a task to Claude on the harness
// backend. Execution does NOT call the iOS action dispatcher — it goes
// through GigiClaudeBridge which opens a streaming WebSocket to Claude
// and appends thoughts/tool-events to the conversation memory in flight.

struct AskClaudeTool: GigiTool {
    let name = "ask_claude"
    let requiresConfirmation = false
    let tags = [
        "analizza", "analyze", "ricerca", "research", "prenota", "book",
        "trova", "find", "cerca", "search", "computer", "browser",
        "deep", "complex", "multi-step"
    ]

    let declaration = FunctionDeclaration(
        name: "ask_claude",
        description: """
        Delegate to Claude (on the harness backend) for tasks that need deep \
        reasoning, web research, computer-use browsing, or analysis of large \
        data. Do NOT use this for direct device actions (calls, navigation, \
        HomeKit, reminders, timers) — prefer the dedicated tool. Claude thoughts \
        stream live into the chat while it works.
        """,
        parameters: JSONSchema(
            type: "object",
            properties: [
                "task":    JSONSchemaProperty(
                    type: "string",
                    description: "Full natural-language description of what Claude should do. Include the goal and any explicit constraints.",
                    enumValues: nil
                ),
                "context": JSONSchemaProperty(
                    type: "string",
                    description: "Optional extra context Claude will not get from the user snapshot (e.g. data copied from a previous turn).",
                    enumValues: nil
                )
            ],
            required: ["task"]
        )
    )

    func execute(args: [String: Any]) async -> ToolResult {
        let task    = str(args, "task")
        let context = (args["context"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard !task.isEmpty else {
            return ToolResult.failure("ask_claude: task vuoto")
        }
        return await GigiClaudeBridge.shared.run(task: task, context: context)
    }
}

// MARK: - GigiToolRegistry

@MainActor
final class GigiToolRegistry {
    static let shared = GigiToolRegistry()

    let all: [any GigiTool] = [
        MakeCallTool(), SendMessageTool(), NavigateTool(), PlayMusicTool(),
        SetReminderTool(), CreateEventTool(), SetAlarmTool(), SetTimerTool(),
        OpenAppTool(), AskTimeTool(), AskDateTool(), WeatherTool(),
        TorchOnTool(), TorchOffTool(), FaceTimeTool(), FaceTimeAudioTool(),
        MediaPlayPauseTool(), MediaNextTool(), MediaPreviousTool(),
        ReadCalendarTool(), ReadWeekCalendarTool(), FindFreeSlotTool(),
        SearchWebTool(), ReadNewsTool(), SendEmailTool(),
        ToggleWifiTool(), ToggleBluetoothTool(),
        HomekitOnTool(), HomekitOffTool(), HomekitDimTool(),
        HomekitTempTool(), HomekitSceneTool(),
        RememberTool(), RecallTool(), SearchGroupsTool(),
        WebWhatsAppTool(), WebBookRestaurantTool(), WebOrderFoodTool(),
        WebSearchAndReadTool(), WebVisionTaskTool(), ComputerUseTool(),
        AskHarnessTool(),
        AskClaudeTool()
    ]

    // Always included regardless of text (high frequency, low cost).
    // `ask_claude` is always present so Groq can escalate on ANY complex
    // request, not only those whose wording matches its tag list.
    private let alwaysIncluded: Set<String> = [
        "make_call", "send_message", "ask_time", "ask_date", "weather",
        "ask_claude"
    ]

    private lazy var byName: [String: any GigiTool] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
    }()

    private init() {}

    // MARK: - Meta-classifier

    /// Returns max 10 tools most relevant to `text`. Always includes the 5 high-frequency tools.
    /// Uses tag-based matching (keyword → tool) — no regex, no CoreML required.
    func selectRelevant(for text: String) -> [any GigiTool] {
        let lower = text.lowercased()
        let words = Set(lower.components(separatedBy: .whitespacesAndNewlines)
            .flatMap { $0.components(separatedBy: .punctuationCharacters) }
            .filter { !$0.isEmpty })

        var scored: [(tool: any GigiTool, score: Int)] = all.map { tool in
            var score = alwaysIncluded.contains(tool.name) ? 100 : 0
            for tag in tool.tags {
                if lower.contains(tag) { score += 10 }
                // bonus for exact word match
                if words.contains(tag) { score += 5 }
            }
            return (tool, score)
        }

        // Always include ask_harness when harness is configured — it handles what other tools can't.
        if GigiHarnessClient.shared.isConfigured,
           let idx = scored.firstIndex(where: { $0.tool.name == "ask_harness" }) {
            scored[idx] = (scored[idx].tool, max(scored[idx].score, 50))
        }

        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(12).map(\.tool))
    }

    /// Lookup by name for execution in AgentEngine.
    func tool(named name: String) -> (any GigiTool)? {
        byName[name]
    }

    /// FunctionDeclarations for the Gemini API payload (Encodable).
    func declarations(for tools: [any GigiTool]) -> [FunctionDeclaration] {
        tools.map(\.declaration)
    }
}
