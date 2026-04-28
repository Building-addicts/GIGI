import Contacts
import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

// MARK: - LocalActionRouter
//
// Pattern-based router shared between the background AppIntent path
// (`GigiBackgroundTalkIntent`) and the foreground orchestrator
// (`GigiSmartOrchestrator`). Handles a small set of system queries entirely
// on-device without going through the harness or any LLM, and returns
// either a spoken answer or a marker the caller can dispatch to a native
// iOS action (Call / Message / Open URL).
//
// The point of factoring this out is to give both entry points the same
// fast-path coverage:
//   • Action Button → Shortcut → AppIntent → router (marker → Shortcut acts)
//   • In-app voice  → orchestrator → router (marker → URL scheme dispatch)
//
// Pattern matching is intentionally a thin keyword router rather than the
// full `GigiNLUEngine`, because the engine has UI and main-actor
// dependencies that don't make sense in the background AppIntent context.

enum LocalActionRouter {

    /// Result of running the router against a phrase.
    enum Outcome {
        /// Native action marker the caller should execute. Format:
        ///   `CALL:<phone>` — phone is dialable digits + optional leading `+`
        ///   `SMS:<phone>|<body>` — pipe separator, body may be empty
        ///   `OPEN:<scheme://...>` — full URL ready for `UIApplication.open`
        case marker(String)

        /// Spoken/text answer. Caller speaks it via TTS or returns to Shortcut.
        case answer(String)

        /// Nothing matched. Caller should fall back to its own routing
        /// (harness, agent loop, cloud LLM, etc.).
        case noMatch
    }

    // MARK: - Public entry point

    /// Resolves a user phrase to either a native-action marker or a spoken
    /// answer, or `.noMatch` if no rule applies. Side effects: may schedule
    /// local notifications (timers/reminders), may resolve contacts, may
    /// flip `UIDevice.isBatteryMonitoringEnabled` on briefly.
    static func resolve(for raw: String) async -> Outcome {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return .noMatch }

        if matchesAny(lower, prefixes: ["hello", "hi gigi", "hey gigi", "ciao", "ciao gigi"]) {
            return .answer("Hi! What can I help with?")
        }

        // Battery level — UIDevice exposes this from a background AppIntent
        // once we flip the monitoring flag. Drains nothing since we read
        // once and let iOS turn the monitor back off when the process is
        // suspended.
        if containsAny(lower, phrases: ["battery", "batteria", "carica", "how much battery"]) {
            #if canImport(UIKit)
            UIDevice.current.isBatteryMonitoringEnabled = true
            let level = UIDevice.current.batteryLevel
            if level >= 0 {
                let percent = Int((level * 100).rounded())
                return .answer("Battery is at \(percent)%.")
            }
            #endif
            return .answer("I can't read the battery level right now.")
        }

        // Timer / reminder. Scheduling a UNNotificationRequest works fully
        // in the background AppIntent context — no foreground required, no
        // harness, no network.
        if let minutes = parseTimerMinutes(from: lower) {
            scheduleLocalReminder(after: TimeInterval(minutes * 60),
                                  body: "Timer expired.")
            return .answer("Timer set for \(minutes) minute\(minutes == 1 ? "" : "s").")
        }

        if let payload = parseReminder(from: raw) {
            scheduleLocalReminder(after: 60, body: payload)
            return .answer("I'll remind you in a minute: \(payload)")
        }

        // Native actions — these become markers the caller routes:
        //   • Background AppIntent → returns marker as `ReturnsValue<String>` and
        //     the Shortcut's CALL/SMS/OPEN branches act on it.
        //   • Foreground orchestrator → dispatches via URL scheme.
        if let name = parseCallRequest(lower) {
            return .marker(await callMarker(for: name))
        }

        if let message = parseMessageRequest(raw: raw, lower: lower) {
            return .marker(await messageMarker(for: message))
        }

        if let target = parseOpenAppRequest(lower) {
            return .marker("OPEN:\(target.scheme)")
        }

        if containsAny(lower, phrases: ["what time", "what's the time", "che ore sono", "che ora è", "ora è"]) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return .answer("It's \(formatter.string(from: Date())).")
        }

        if containsAny(lower, phrases: ["what day", "what's the date", "today's date", "che giorno è", "che data è"]) {
            let formatter = DateFormatter()
            formatter.dateStyle = .full
            formatter.timeStyle = .none
            return .answer("Today is \(formatter.string(from: Date())).")
        }

        if containsAny(lower, phrases: ["thank you", "thanks", "grazie"]) {
            return .answer("You're welcome.")
        }

        // Capability questions. Without this branch every "what can you do"
        // hits the harness, which is wasteful and breaks completely if the
        // harness isn't paired (the only feedback the user gets is the
        // not-configured error). Hard-coding the capability list locally
        // turns it into a fast, always-on answer.
        if containsAny(lower, phrases: [
            "what can you do",
            "what do you do",
            "what are you",
            "who are you",
            "help",
            "capabilities",
            "cosa sai fare",
            "cosa puoi fare",
            "chi sei",
            "aiuto",
            "cosa fai"
        ]) {
            return .answer("I can answer questions, send messages, plan your day, and run actions on your devices. Try saying: what time is it, plan my day, send a message to Marco, or order a pizza.")
        }

        // Self-test phrase the demo can use to confirm the banner is wired
        // up before turning the harness on. Useful during stage prep.
        if containsAny(lower, phrases: ["are you there", "ping", "test"]) {
            return .answer("I'm here. The banner works.")
        }

        return .noMatch
    }

    /// Convenience for callers that don't care about the marker/answer
    /// distinction (e.g. background AppIntent which returns whatever the
    /// router produced as a single string for the Shortcut to act on).
    static func tryAnswer(for raw: String) async -> String? {
        switch await resolve(for: raw) {
        case .marker(let m): return m
        case .answer(let a): return a
        case .noMatch:       return nil
        }
    }

    // MARK: - Marker classification (used by foreground dispatch)

    enum MarkerKind {
        case call(phone: String)
        case sms(phone: String, body: String)
        case open(url: URL)
    }

    /// Decomposes a marker string into a typed kind so the foreground
    /// dispatcher can pick the right native action. Returns `nil` if the
    /// string isn't a recognized marker.
    static func classify(marker: String) -> MarkerKind? {
        if marker.hasPrefix("CALL:") {
            let phone = String(marker.dropFirst("CALL:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phone.isEmpty else { return nil }
            return .call(phone: phone)
        }
        if marker.hasPrefix("SMS:") {
            let payload = String(marker.dropFirst("SMS:".count))
            let parts = payload.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first else { return nil }
            let phone = String(first).trimmingCharacters(in: .whitespacesAndNewlines)
            let body = parts.count > 1
                ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            guard !phone.isEmpty else { return nil }
            return .sms(phone: phone, body: body)
        }
        if marker.hasPrefix("OPEN:") {
            let raw = String(marker.dropFirst("OPEN:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw) else { return nil }
            return .open(url: url)
        }
        return nil
    }

    // MARK: - Internal helpers

    private static func matchesAny(_ text: String, prefixes: [String]) -> Bool {
        prefixes.contains { text == $0 || text.hasPrefix($0 + " ") || text.hasPrefix($0 + ",") }
    }

    private static func containsAny(_ text: String, phrases: [String]) -> Bool {
        phrases.contains { text.contains($0) }
    }

    // MARK: - Message marker

    private enum MessagePlatform {
        case sms
        case whatsapp
    }

    /// Recognizes simple message requests for the Shortcut's Send Message branch.
    /// Format returned: `SMS:<phone>|<body>` for iMessage/SMS, or
    /// `OPEN:whatsapp://send?...` for WhatsApp.
    private static func parseMessageRequest(raw: String, lower: String) -> (contact: String, body: String, platform: MessagePlatform)? {
        let triggers: [(prefix: String, platform: MessagePlatform)] = [
            ("send a message to ", .sms),
            ("send a text to ", .sms),
            ("text ", .sms),
            ("message ", .sms),
            ("send an sms to ", .sms),
            ("sms ", .sms),
            ("whatsapp ", .whatsapp),
            ("send a whatsapp to ", .whatsapp),
            ("manda un messaggio a ", .sms),
            ("scrivi a ", .sms),
            ("messaggia ", .sms),
            ("manda whatsapp a ", .whatsapp),
            ("manda un whatsapp a ", .whatsapp)
        ]
        guard let match = triggers.first(where: { lower.hasPrefix($0.prefix) }) else { return nil }
        let trigger = match.prefix
        let restRaw = String(raw.dropFirst(trigger.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        let restLower = String(lower.dropFirst(trigger.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !restRaw.isEmpty else { return nil }

        let bodySeparators = [" saying ", " that ", " with message ", " with the message ", " dicendo ", " che "]
        if let separator = bodySeparators.first(where: { restLower.contains($0) }),
           let range = restLower.range(of: separator) {
            let contactRaw = String(restRaw.prefix(restLower.distance(from: restLower.startIndex, to: range.lowerBound)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let bodyStart = restLower.distance(from: restLower.startIndex, to: range.upperBound)
            let bodyRaw = String(restRaw.dropFirst(bodyStart)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !contactRaw.isEmpty { return (cleanContactName(contactRaw), bodyRaw, match.platform) }
        }

        return (cleanContactName(restRaw), "", match.platform)
    }

    private static func messageMarker(for message: (contact: String, body: String, platform: MessagePlatform)) async -> String {
        let recipient: String
        if await ensureContactsAccessForBackgroundAction(),
           let resolved = await GigiContactsEngine.shared.resolve(message.contact),
           let phone = shortcutDialablePhoneNumber(from: resolved.phone) {
            recipient = phone
        } else {
            recipient = message.contact
        }

        switch message.platform {
        case .sms:
            return "SMS:\(recipient)|\(message.body)"
        case .whatsapp:
            guard let phone = whatsappPhoneNumber(from: recipient) else {
                return "SMS:\(recipient)|\(message.body)"
            }
            let encoded = urlQueryValue(message.body)
            return "OPEN:whatsapp://send?phone=\(phone)&text=\(encoded)"
        }
    }

    // MARK: - Open external app

    /// Maps "open Spotify", "apri WhatsApp", etc. to a known URL scheme.
    /// The list mirrors LSApplicationQueriesSchemes in Info.plist — adding
    /// schemes here without listing them there makes canOpenURL return
    /// false silently.
    private static func parseOpenAppRequest(_ lower: String) -> (scheme: String, label: String)? {
        let triggers = ["open ", "launch ", "start ", "apri ", "lancia ", "avvia "]
        guard let trigger = triggers.first(where: { lower.hasPrefix($0) }) else { return nil }
        let target = String(lower.dropFirst(trigger.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if target.isEmpty { return nil }

        let schemes: [(label: String, keywords: [String], scheme: String)] = [
            ("Spotify",      ["spotify"],                     "spotify://"),
            ("WhatsApp",     ["whatsapp", "whats app"],       "whatsapp://"),
            ("Instagram",    ["instagram", "ig"],             "instagram://"),
            ("Telegram",     ["telegram", "tg"],              "tg://"),
            ("YouTube",      ["youtube", "yt"],               "youtube://"),
            ("TikTok",       ["tiktok", "tik tok"],           "tiktok://"),
            ("Maps",         ["maps", "apple maps", "mappe"], "maps://"),
            ("Google Maps",  ["google maps"],                 "comgooglemaps://"),
            ("Waze",         ["waze"],                        "waze://"),
            ("Uber",         ["uber"],                        "uber://"),
            ("Lyft",         ["lyft"],                        "lyft://"),
            ("Uber Eats",    ["uber eats", "ubereats"],       "ubereats://"),
            ("DoorDash",     ["doordash", "door dash"],       "doordash://")
        ]

        if let match = schemes.first(where: { entry in
            entry.keywords.contains(where: { target.contains($0) })
        }) {
            return (match.scheme, match.label)
        }
        return nil
    }

    // MARK: - Place a call

    /// Recognizes natural "call X" / "chiama X" patterns and returns the name.
    /// Includes common dictation mistakes seen in live tests: "col mom" /
    /// "col mam" for "call mom".
    private static func parseCallRequest(_ lower: String) -> String? {
        let starts = [
            "call ", "phone ", "dial ", "ring ",
            "col ", "calla ",
            "chiama ", "chiamo ", "chiami ", "telefona a "
        ]
        let embedded = [
            "can you call ", "could you call ", "please call ",
            "puoi chiamare ", "puoi chiamarmi ", "mi chiami ",
            "per favore chiama "
        ]

        let name: String
        if let trigger = starts.first(where: { lower.hasPrefix($0) }) {
            name = String(lower.dropFirst(trigger.count))
        } else if let trigger = embedded.first(where: { lower.contains($0) }),
                  let range = lower.range(of: trigger) {
            name = String(lower[range.upperBound...])
        } else {
            return nil
        }

        let cleaned = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .removingCallPolitenessSuffixes()
        return cleaned.isEmpty ? nil : cleanContactName(cleaned)
    }

    private static func callMarker(for contactName: String) async -> String {
        guard await ensureContactsAccessForBackgroundAction() else {
            return "I need Contacts permission to call \(contactName). Open GIGI once, allow Contacts, then try again."
        }

        guard let resolved = await GigiContactsEngine.shared.resolve(contactName) else {
            // Legacy fallback: callers that have a Get Contact + Call branch
            // can still try iOS' own contact picker/resolver. Foreground
            // dispatcher treats this as "ask user" rather than dialing a
            // literal name as a tel:// URL.
            return "CALL:\(contactName)"
        }

        guard let phoneNumber = shortcutDialablePhoneNumber(from: resolved.phone) else {
            return "I found \(resolved.name), but the phone number doesn't look dialable."
        }

        return "CALL:\(phoneNumber)"
    }

    private static func ensureContactsAccessForBackgroundAction() async -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                CNContactStore().requestAccess(for: .contacts) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    private static func shortcutDialablePhoneNumber(from phone: String) -> String? {
        let cleaned = phone.filter { "0123456789+".contains($0) }
        guard cleaned.filter(\.isNumber).count >= 3 else { return nil }
        return cleaned
    }

    private static func whatsappPhoneNumber(from phone: String) -> String? {
        let digits = phone.filter(\.isNumber)
        return digits.count >= 6 ? digits : nil
    }

    private static func urlQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func cleanContactName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func parseTimerMinutes(from lower: String) -> Int? {
        let triggers = ["timer", "set a timer", "start a timer", "metti un timer", "imposta un timer"]
        guard triggers.contains(where: lower.contains) else { return nil }
        let scanner = Scanner(string: lower)
        scanner.charactersToBeSkipped = .alphanumerics.subtracting(.decimalDigits).union(.whitespaces).union(.punctuationCharacters)
        var value: Int = 0
        if scanner.scanInt(&value), value > 0, value <= 600 {
            return value
        }
        return nil
    }

    private static func parseReminder(from raw: String) -> String? {
        let lower = raw.lowercased()
        for prefix in ["remind me to ", "remind me ", "ricordami di ", "ricordami "] {
            if lower.hasPrefix(prefix) {
                let body = String(raw.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { return body }
            }
        }
        return nil
    }

    private static func scheduleLocalReminder(after seconds: TimeInterval, body: String) {
        let content = UNMutableNotificationContent()
        content.title = "GIGI"
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

private extension String {
    func removingCallPolitenessSuffixes() -> String {
        var result = self.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes = [
            " for me", " please", " now",
            " per favore", " grazie", " adesso"
        ]
        for suffix in suffixes {
            if result.hasSuffix(suffix) {
                result = String(result.dropLast(suffix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result
    }
}
