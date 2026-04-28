import AppIntents
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
    static func tryAnswer(for raw: String) -> String? {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return nil }

        if matchesAny(lower, prefixes: ["hello", "hi gigi", "hey gigi", "ciao", "ciao gigi"]) {
            return "Hi! What can I help with?"
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
                return "Battery is at \(percent)%."
            }
            #endif
            return "I can't read the battery level right now."
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

    private static func matchesAny(_ text: String, prefixes: [String]) -> Bool {
        prefixes.contains { text == $0 || text.hasPrefix($0 + " ") || text.hasPrefix($0 + ",") }
    }

    private static func containsAny(_ text: String, phrases: [String]) -> Bool {
        phrases.contains { text.contains($0) }
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

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(value: "I didn't catch anything. Try again.",
                           dialog: IntentDialog("I didn't catch anything. Try again."))
        }

        // Local-first routing. Simple system queries that don't require
        // Claude reasoning or external integrations are answered directly
        // from the AppIntent, so the banner works even when the harness is
        // unreachable (Mac off, tunnel down, not paired). Only requests
        // that need cross-platform actions (order, book, browse) or
        // language-model reasoning fall through to the harness path.
        if let local = LocalAnswer.tryAnswer(for: trimmed) {
            return .result(value: local, dialog: IntentDialog(stringLiteral: local))
        }

        let result = await GigiHarnessClient.shared.agentRun(text: trimmed)
        switch result {
        case .success(let agent):
            let answer = agent.result.trimmingCharacters(in: .whitespacesAndNewlines)
            if answer.isEmpty {
                return .result(value: "GIGI didn't return anything. Try again.",
                               dialog: IntentDialog("GIGI didn't return anything. Try again."))
            }
            return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))

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
            return .result(value: message, dialog: IntentDialog(stringLiteral: message))
        }
    }
}
