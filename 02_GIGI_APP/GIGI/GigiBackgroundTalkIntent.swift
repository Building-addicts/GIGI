import AppIntents
import Contacts
import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

// MARK: - GigiBackgroundTalkIntent
//
// Background-running AppIntent that receives a transcribed user phrase from
// an iOS Shortcut, sends it to the GIGI harness for processing, and returns
// the answer as a spoken dialog the Shortcut can route through Speak Text.
// The app is never brought to the foreground (`openAppWhenRun: false`) — iOS
// wakes the process briefly to run `perform()` and lets it return.
//
// The expected Shortcut flow:
//
//   1. Hardware trigger (Back Tap / Action Button) runs the Shortcut.
//   2. Shortcut → Dictate Text. iOS shows its own dictation overlay; the
//      microphone is owned by the Shortcuts app, not by GIGI. No app
//      foregrounding.
//   3. Shortcut → Run "Process speech with GIGI" with the dictated text.
//      iOS calls into this intent in the background.
//   4. We forward the text through `GigiHarnessClient.agentRun(text:)`. The
//      harness performs whatever system-action routing or Claude reasoning
//      it already does for the foreground app — same endpoint, same auth,
//      same pairing. Nothing duplicated client-side.
//   5. Shortcut → Speak Text on the dialog returned here.
//
// Failure modes are spoken back through the same dialog channel so the user
// always hears something even if the harness is offline or unpaired.

// MARK: - LocalAnswer
//
// Pattern-based router that handles a small set of system queries entirely
// on-device, without going through the harness. The point of this layer is
// twofold:
//   1. The banner stays useful when the Mac harness is unreachable (Mac
//      off, tunnel down, not paired) for any request that doesn't need
//      Claude or an external integration.
//   2. We don't burn a Claude turn on questions whose answer is in the
//      device clock or the current locale.
//
// Anything not matched here falls through to `agentRun`, which is where
// reasoning, memory, and cross-platform actions (order pizza, book Uber,
// search Amazon — the things that genuinely need the harness) are handled.
//
// Phrases are matched on lowercased / whitespace-trimmed text. We accept
// English and Italian forms because the demo speaker mixes them. This is
// deliberately a thin keyword router rather than the full GigiNLUEngine,
// because the engine has UI dependencies that don't make sense in a
// background AppIntent context.

private enum LocalAnswer {
    private enum OnOff {
        case on
        case off

        var markerValue: String {
            switch self {
            case .on: return "on"
            case .off: return "off"
            }
        }
    }

    /// Every case here corresponds to a `SYS:<command>:<param>` marker the
    /// universal Shortcut consumes. The catalog is deliberately closed: each
    /// case must be both produced by `parseSystemAction` (or by an explicit
    /// fallback like the battery branch in `tryAnswer`) AND consumed by a
    /// branch in the Shortcut. Adding a case without wiring both sides leaves
    /// the user hearing the literal marker string.
    ///
    /// Timer / reminder / event were previously listed here but deliberately
    /// removed: timer + reminder are answered in-process via
    /// `UNNotificationRequest` (no Shortcut round-trip needed) and event was
    /// never parsed. Add them back only when the Shortcut grows the matching
    /// branches.
    private enum SystemAction {
        case torch(OnOff)
        case volume(Int)
        case brightness(Int)
        case wifi(OnOff)
        case bluetooth(OnOff)
        case airplane(OnOff)
        case dnd(OnOff)
        case silent(OnOff)
        case lpm(OnOff)
        case screenshot
        case alarm(time: String)
        case music(String)
        case weather
        case battery
        case location
        func toMarker() -> String {
            switch self {
            case .torch(let value):
                return "SYS:torch:\(value.markerValue)"
            case .volume(let value):
                return "SYS:volume:\(value)"
            case .brightness(let value):
                return "SYS:brightness:\(value)"
            case .wifi(let value):
                return "SYS:wifi:\(value.markerValue)"
            case .bluetooth(let value):
                return "SYS:bluetooth:\(value.markerValue)"
            case .airplane(let value):
                return "SYS:airplane:\(value.markerValue)"
            case .dnd(let value):
                return "SYS:dnd:\(value.markerValue)"
            case .silent(let value):
                return "SYS:silent:\(value.markerValue)"
            case .lpm(let value):
                return "SYS:lpm:\(value.markerValue)"
            case .screenshot:
                return "SYS:screenshot:"
            case .alarm(let time):
                // The Shortcut splits the marker on `:`, so a raw `HH:MM`
                // would be eaten by the splitter (only `HH` would survive).
                // We emit `HH-MM` here; the SYS:alarm branch swaps `-` back
                // to `:` before passing the value into the Create Alarm
                // action.
                return "SYS:alarm:\(time.replacingOccurrences(of: ":", with: "-"))"
            case .music(let command):
                return "SYS:music:\(command)"
            case .weather:
                return "SYS:weather:"
            case .battery:
                return "SYS:battery:"
            case .location:
                return "SYS:location:"
            }
        }
    }

    static func tryAnswer(for raw: String) async -> String? {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return nil }

        // Greeting matches only when the utterance is the greeting itself
        // (no intent attached). "hello" → "Hi!", but "hello turn on the
        // flashlight" must fall through to `parseSystemAction` so the
        // user's intent isn't shadowed by the salutation.
        if isExactGreeting(lower) {
            return "Hi! What can I help with?"
        }

        if let action = parseSystemAction(raw: raw, lower: lower) {
            return action.toMarker()
        }

        // Battery level — UIDevice exposes this from a background AppIntent
        // once we flip the monitoring flag. Drains nothing since we read
        // once and let iOS turn the monitor back off when the process is
        // suspended. When monitoring is unavailable (simulator, restricted
        // process state) we fall back to `SYS:battery:` so the Shortcut can
        // answer via its native Get Battery Level + Speak action.
        if containsAny(lower, phrases: ["battery", "batteria", "carica", "how much battery"]) {
            #if canImport(UIKit)
            UIDevice.current.isBatteryMonitoringEnabled = true
            let level = UIDevice.current.batteryLevel
            if level >= 0 {
                let percent = Int((level * 100).rounded())
                return "Battery is at \(percent)%."
            }
            #endif
            return SystemAction.battery.toMarker()
        }

        // Timer / reminder. Scheduling a UNNotificationRequest works fully
        // in the background AppIntent context — no foreground required, no
        // harness, no network. We parse a couple of common phrasings and
        // confirm the result via dialog.
        if let minutes = parseTimerMinutes(from: lower) {
            scheduleLocalReminder(after: TimeInterval(minutes * 60),
                                  body: "Timer expired.")
            return "Timer set for \(minutes) minute\(minutes == 1 ? "" : "s")."
        }

        if let payload = parseReminder(from: raw) {
            scheduleLocalReminder(after: 60, body: payload)
            return "I'll remind you in a minute: \(payload)"
        }

        // Native actions that iOS refuses to launch reliably from a background
        // AppIntent are returned as command markers. The user's Shortcut owns
        // the privileged foreground action. For calls, the demo-safe path is:
        //
        //   "call mom" → resolve Mom in Contacts here → CALL:+15551234
        //             → Shortcut Call action → iOS native call confirmation
        //
        // That keeps GIGI closed even if the user started from Instagram, while
        // still using Apple's compliant call-confirmation surface. We only emit
        // `CALL:` after resolving a real phone number: feeding a plain contact
        // name into Shortcuts is flaky and can surface conversion errors.
        if let name = parseCallRequest(lower) {
            return await callMarker(for: name)
        }

        if let message = parseMessageRequest(raw: raw, lower: lower) {
            return await messageMarker(for: message)
        }

        if let target = parseOpenAppRequest(lower) {
            return "OPEN:\(target.scheme)"
        }

        if containsAny(lower, phrases: ["what time", "what's the time", "che ore sono", "che ora è", "ora è"]) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return "It's \(formatter.string(from: Date()))."
        }

        if containsAny(lower, phrases: ["what day", "what's the date", "today's date", "che giorno è", "che data è"]) {
            let formatter = DateFormatter()
            formatter.dateStyle = .full
            formatter.timeStyle = .none
            return "Today is \(formatter.string(from: Date()))."
        }

        if containsAny(lower, phrases: ["thank you", "thanks", "grazie"]) {
            return "You're welcome."
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
            return "I can answer questions, send messages, plan your day, and run actions on your devices. Try saying: what time is it, plan my day, send a message to Marco, or order a pizza."
        }

        // Self-test phrase the demo can use to confirm the banner is wired
        // up before turning the harness on. Useful during stage prep.
        if containsAny(lower, phrases: ["are you there", "ping", "test"]) {
            return "I'm here. The banner works."
        }

        return nil
    }

    private static func containsAny(_ text: String, phrases: [String]) -> Bool {
        phrases.contains { text.contains($0) }
    }

    /// True only when the entire utterance is a bare greeting — no follow-up
    /// intent attached. We strip trailing punctuation so "hello!" / "hi gigi."
    /// still count as bare. Anything else (e.g. "hi gigi turn on the
    /// flashlight") returns false and is routed to the action parsers.
    private static func isExactGreeting(_ lower: String) -> Bool {
        let greetings = ["hello", "hi", "hi gigi", "hey", "hey gigi", "ciao", "ciao gigi"]
        let stripped = lower.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?…"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return greetings.contains(stripped)
    }

    // MARK: - System action

    /// Routes voice phrases to a `SYS:` marker the Shortcut consumes via its
    /// SYS branch. Each sub-parser is keyword-gated first, then on/off cues
    /// are matched, so generic words like "on" / "off" / digits don't trigger
    /// false positives.
    ///
    /// Battery / timer / reminder are deliberately NOT handled here — they
    /// have direct in-process handlers later in `tryAnswer` that answer locally
    /// without round-tripping through the Shortcut.
    ///
    /// Keep this parser aligned with the manually-built SYS branch. If Swift
    /// emits a `SYS:` command that the Shortcut does not consume, the final
    /// `Stop this shortcut` in the SYS branch makes the request fail silently.
    private static func parseSystemAction(raw: String, lower: String) -> SystemAction? {
        if let a = parseTorch(lower) { return a }
        if let a = parseVolume(lower) { return a }
        if let a = parseBrightness(lower) { return a }
        if let a = parseWifi(lower) { return a }
        if let a = parseBluetooth(lower) { return a }
        if let a = parseAirplane(lower) { return a }
        if let a = parseDND(lower) { return a }
        if let a = parseSilent(lower) { return a }
        if let a = parseLPM(lower) { return a }

        if let a = parseScreenshot(lower) { return a }
        if let a = parseAlarm(lower) { return a }
        if let a = parseMusic(lower) { return a }
        if let a = parseWeather(lower) { return a }
        if let a = parseLocationQuery(lower) { return a }

        return nil
    }

    /// Looks for an explicit on/off cue in the phrase. Cues that need a word
    /// boundary (`" on"`, `" off"`) are space-prefixed so they don't match
    /// inside compound words.
    private static func explicitOnOff(in lower: String) -> OnOff? {
        let offCues = ["turn off", "switch off", "disable", "spegni", "disattiva", "disabilita", " off"]
        let onCues = ["turn on", "switch on", "enable", "accendi", "attiva", "abilita", " on"]
        if offCues.contains(where: lower.contains) { return .off }
        if onCues.contains(where: lower.contains) { return .on }
        return nil
    }

    /// True when an off cue is present. Used by toggles whose default
    /// (when only the keyword is present) is "on".
    private static func hasOffCue(_ lower: String) -> Bool {
        let offCues = ["turn off", "switch off", "disable", "spegni", "disattiva", "disabilita", " off"]
        return offCues.contains(where: lower.contains)
    }

    /// First positive integer in the string, decoupled from any specific
    /// keyword. Used by `parseVolume` / `parseBrightness` after the keyword
    /// gate has already matched.
    private static func firstInt(in text: String) -> Int? {
        let scanner = Scanner(string: text)
        scanner.charactersToBeSkipped = .alphanumerics.subtracting(.decimalDigits)
            .union(.whitespaces).union(.punctuationCharacters)
        var value: Int = 0
        return scanner.scanInt(&value) ? value : nil
    }

    private static func parseTorch(_ lower: String) -> SystemAction? {
        let keywords = ["flashlight", "torch", "torcia"]
        guard keywords.contains(where: lower.contains) else { return nil }
        return explicitOnOff(in: lower).map { .torch($0) }
    }

    private static func parseVolume(_ lower: String) -> SystemAction? {
        guard lower.contains("volume") else { return nil }
        guard let n = firstInt(in: lower), (0...100).contains(n) else { return nil }
        return .volume(n)
    }

    private static func parseBrightness(_ lower: String) -> SystemAction? {
        let keywords = ["brightness", "luminosità", "luminosita"]
        guard keywords.contains(where: lower.contains) else { return nil }
        guard let n = firstInt(in: lower), (0...100).contains(n) else { return nil }
        return .brightness(n)
    }

    private static func parseWifi(_ lower: String) -> SystemAction? {
        let keywords = ["wifi", "wi-fi", "wireless"]
        guard keywords.contains(where: lower.contains) else { return nil }
        return explicitOnOff(in: lower).map { .wifi($0) }
    }

    private static func parseBluetooth(_ lower: String) -> SystemAction? {
        guard lower.contains("bluetooth") else { return nil }
        return explicitOnOff(in: lower).map { .bluetooth($0) }
    }

    private static func parseAirplane(_ lower: String) -> SystemAction? {
        let keywords = ["airplane mode", "flight mode", "modalità aereo", "modalita aereo", "modalità volo"]
        guard keywords.contains(where: lower.contains) else { return nil }
        return .airplane(hasOffCue(lower) ? .off : .on)
    }

    private static func parseDND(_ lower: String) -> SystemAction? {
        let phrases = ["do not disturb", "non disturbare"]
        // `dnd` needs explicit handling because `lower.contains("dnd")` also
        // matches inside arbitrary words. Accept it only as a whole token.
        let dndAlone = lower == "dnd" || lower.hasPrefix("dnd ") || lower.hasSuffix(" dnd") || lower.contains(" dnd ")
        guard phrases.contains(where: lower.contains) || dndAlone else { return nil }
        return .dnd(hasOffCue(lower) ? .off : .on)
    }

    private static func parseSilent(_ lower: String) -> SystemAction? {
        let keywords = ["silent mode", "modalità silenziosa", "modalita silenziosa", "silenzioso"]
        guard keywords.contains(where: lower.contains) else { return nil }
        return .silent(hasOffCue(lower) ? .off : .on)
    }

    private static func parseLPM(_ lower: String) -> SystemAction? {
        let keywords = ["low power mode", "battery saver", "risparmio energetico", "risparmio batteria"]
        guard keywords.contains(where: lower.contains) else { return nil }
        return .lpm(hasOffCue(lower) ? .off : .on)
    }

    private static func parseScreenshot(_ lower: String) -> SystemAction? {
        let phrases = ["screenshot", "screen shot", "fai uno screenshot", "scatta screenshot", "cattura schermo"]
        return phrases.contains(where: lower.contains) ? .screenshot : nil
    }

    /// Tries to extract a time from the phrase. Match order matters because
    /// `\b\d{1,2}\b` would otherwise eat the hour out of `8:30` or `7am`.
    /// Bare-hour ("wake me at 7") normalizes to `HH:00` so the Shortcut's
    /// Create Alarm action gets a valid HH:MM input.
    private static func parseAlarm(_ lower: String) -> SystemAction? {
        let keywords = ["set alarm", "set an alarm", "alarm at", "alarm for", "wake me", "sveglia alle", "imposta sveglia", "metti sveglia"]
        guard keywords.contains(where: lower.contains) else { return nil }
        if let range = lower.range(of: "\\b\\d{1,2}:\\d{2}\\b", options: .regularExpression) {
            return .alarm(time: String(lower[range]))
        }
        if let range = lower.range(of: "\\b\\d{1,2}\\s*(?:am|pm)\\b", options: .regularExpression) {
            return .alarm(time: String(lower[range]).replacingOccurrences(of: " ", with: ""))
        }
        if let range = lower.range(of: "\\b\\d{1,2}\\b", options: .regularExpression) {
            let hour = String(lower[range])
            return .alarm(time: "\(hour):00")
        }
        return nil
    }

    private static func parseMusic(_ lower: String) -> SystemAction? {
        if containsAny(lower, phrases: ["next track", "next song", "skip song", "skip track", "prossima canzone", "prossimo brano", "salta canzone"]) {
            return .music("next")
        }
        if containsAny(lower, phrases: ["previous track", "previous song", "prev song", "prev track", "brano precedente", "canzone precedente"]) {
            return .music("prev")
        }
        if containsAny(lower, phrases: ["pause music", "pause song", "pause the music", "pausa musica", "metti in pausa", "ferma musica"]) {
            return .music("pause")
        }
        if containsAny(lower, phrases: ["play music", "resume music", "start music", "metti musica", "riproduci musica", "fai partire la musica"]) {
            return .music("play")
        }
        // Bare-word commands as a last resort, only when the phrase is exactly
        // the verb. Avoids stealing "play <song> on spotify" or "pause and
        // wait" — those are claimed by deep-link search or fall through.
        switch lower {
        case "play", "resume": return .music("play")
        case "pause", "stop": return .music("pause")
        case "next", "skip": return .music("next")
        case "previous", "prev": return .music("prev")
        default: return nil
        }
    }

    private static func parseWeather(_ lower: String) -> SystemAction? {
        let phrases = ["what's the weather", "what is the weather", "how's the weather", "weather today", "che tempo fa", "che tempo c'è", "meteo", "previsioni meteo"]
        return phrases.contains(where: lower.contains) ? .weather : nil
    }

    private static func parseLocationQuery(_ lower: String) -> SystemAction? {
        let phrases = ["where am i", "current location", "my location", "what's my location", "dove sono", "posizione attuale", "la mia posizione"]
        return phrases.contains(where: lower.contains) ? .location : nil
    }

    // MARK: - Message marker

    private enum MessagePlatform {
        case sms
        case whatsapp
    }

    /// Recognizes simple message requests for the Shortcut's Send Message branch.
    /// Format returned to Shortcuts: `SMS:<phone>|<body>` for iMessage/SMS, or
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
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return "Tell me what message to send to \(message.contact)."
        }

        guard await ensureContactsAccessForBackgroundAction() else {
            return "I need Contacts permission before I can send a message to \(message.contact). Open GIGI once, allow Contacts, then try again."
        }

        guard let resolved = await GigiContactsEngine.shared.resolve(message.contact) else {
            return "I couldn't find \(message.contact) in Contacts."
        }

        guard let recipient = shortcutDialablePhoneNumber(from: resolved.phone) else {
            return "I found \(resolved.name), but the phone number doesn't look messageable."
        }

        switch message.platform {
        case .sms:
            return "SMS:\(recipient)|\(body)"
        case .whatsapp:
            guard let phone = whatsappPhoneNumber(from: recipient) else {
                return "I found \(resolved.name), but the phone number doesn't look WhatsApp-compatible."
            }
            let encoded = urlQueryValue(body)
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
            return "I need Contacts permission to call \(contactName). Open GIGI once, allow Contacts, then try again from the Action Button."
        }

        guard let resolved = await GigiContactsEngine.shared.resolve(contactName) else {
            return "I couldn't find \(contactName) in Contacts."
        }

        guard let phoneNumber = shortcutDialablePhoneNumber(from: resolved.phone) else {
            return "I found \(resolved.name), but the phone number doesn't look dialable."
        }

        // Canonical demo marker. The Shortcut's CALL branch strips `CALL:` and
        // passes this value into the native Shortcuts "Call" action. That is
        // more reliable than Open URL + tel: and still keeps GIGI closed while
        // iOS owns the compliant call confirmation surface.
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
        // Keep only real phone-number characters for the native Shortcuts Call
        // action. We deliberately drop service-code characters for demo safety.
        let cleaned = phone.filter { "0123456789+".contains($0) }
        guard cleaned.filter(\.isNumber).count >= 3 else { return nil }
        return cleaned
    }

    private static func whatsappPhoneNumber(from phone: String) -> String? {
        let digits = phone.filter(\.isNumber)
        return digits.count >= 6 ? digits : nil
    }

    /// Percent-encodes a value for use as the `<param>` segment of a SYS or
    /// OPEN marker. We strip the standard URL-significant characters
    /// (`+&=#?`) and additionally `:` and `|`, which are the SYS / SMS marker
    /// separators — leaving them raw would let a Spotify URI like
    /// `track:abc:xyz` break the Shortcut's split-by-colon parser.
    private static func urlQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#?:|")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func cleanContactName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Pulls a minute count out of common timer phrasings.
    /// Examples it handles: "set a timer for 5 minutes", "timer 10",
    /// "metti un timer di 3 minuti", "timer di 7".
    private static func parseTimerMinutes(from lower: String) -> Int? {
        let triggers = ["timer", "set a timer", "start a timer", "metti un timer", "imposta un timer"]
        guard triggers.contains(where: lower.contains) else { return nil }
        // Find the first integer in the string.
        let scanner = Scanner(string: lower)
        scanner.charactersToBeSkipped = .alphanumerics.subtracting(.decimalDigits).union(.whitespaces).union(.punctuationCharacters)
        var value: Int = 0
        if scanner.scanInt(&value), value > 0, value <= 600 {
            return value
        }
        return nil
    }

    /// Strips a leading "remind me to" / "ricordami di" prefix and returns
    /// the remaining body, which becomes the notification text.
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

    /// Schedules a local notification N seconds from now. UNUserNotificationCenter
    /// is reachable from a background AppIntent; the system fires the alert even
    /// after the GIGI process exits. If the user has never granted notification
    /// permission this returns silently — the dialog above will still play, the
    /// notification just won't appear, which is acceptable degradation.
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

@available(iOS 16.0, *)
struct GigiBackgroundTalkIntent: AppIntent {
    static var title: LocalizedStringResource = "Process speech with GIGI"
    static var description = IntentDescription(
        "Send a phrase to GIGI in the background — the app stays closed, GIGI's harness handles the request, and the answer is spoken back through the Shortcut."
    )
    // Stay in the background: iOS only spins the app process up briefly.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "What you said", description: "The transcribed phrase to send to GIGI.")
    var text: String

    // ReturnsValue only (no ProvidesDialog). Two reasons:
    //   1. ProvidesDialog made iOS double-speak the answer in the Shortcut
    //      flow — the dialog card spoke it once, then the user's Speak Text
    //      action spoke it again, and iOS sometimes interleaved an
    //      "Esci / Continuo" confirmation between the two.
    //   2. The Shortcut path is the canonical UX; the Siri-only path falls
    //      back to the foreground GigiQuickTalkIntent which has its own UI.
    //      Background AppIntent doesn't need a dialog channel.
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(value: "I didn't catch anything. Try again.")
        }

        // Local-first routing. Simple system queries that don't require
        // Claude reasoning or external integrations are answered directly
        // from the AppIntent, so the banner works even when the harness is
        // unreachable (Mac off, tunnel down, not paired). Only requests
        // that need cross-platform actions (order, book, browse) or
        // language-model reasoning fall through to the harness path.
        if let local = await LocalAnswer.tryAnswer(for: trimmed) {
            return .result(value: local)
        }

        let result = await GigiHarnessClient.shared.agentRun(text: trimmed)
        switch result {
        case .success(let agent):
            let answer = agent.result.trimmingCharacters(in: .whitespacesAndNewlines)
            if answer.isEmpty {
                return .result(value: "GIGI didn't return anything. Try again.")
            }
            return .result(value: answer)

        case .failure(let err):
            // Map common failure modes to user-friendly speech rather than
            // surfacing raw error strings. The Shortcut speaks whatever we
            // return, so we keep it conversational.
            let message: String
            switch err {
            case .notConfigured:
                // The user invoked GIGI for something that needs the Mac
                // harness (Claude reasoning, memory, cross-platform tools)
                // but pairing hasn't been completed on this device. We
                // can't pair from a background AppIntent, so we tell the
                // user concretely what to do and what still works without
                // the harness — otherwise the message reads as a generic
                // "open the app" that gives no signal about why.
                message = "I'm running without the Mac brain. Ask me about the time, the date, or say hello — that works on the phone alone. For everything else, open the GIGI app and pair it with your Mac."
            case .transport:
                message = "I couldn't reach GIGI. Check the connection and try again."
            case .badResponse(let status, _):
                if status == 401 || status == 403 {
                    message = "GIGI needs to be re-paired. Open the app to refresh the connection."
                } else if status == 429 {
                    message = "GIGI is rate limited right now. Try again in a moment."
                } else {
                    message = "GIGI returned an error. Try again later."
                }
            case .apiError(let code, _):
                if code == "RATE_LIMITED" {
                    message = "GIGI is rate limited right now. Try again in a moment."
                } else if code == "UNAUTHORIZED" {
                    message = "GIGI needs to be re-paired. Open the app to refresh the connection."
                } else {
                    message = "Something went wrong on GIGI's side. Try again later."
                }
            case .decodeFailed:
                message = "GIGI's reply was unreadable. Try again."
            }
            return .result(value: message)
        }
    }
}
