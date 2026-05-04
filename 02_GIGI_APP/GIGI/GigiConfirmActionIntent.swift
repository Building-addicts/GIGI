import AppIntents
import Foundation

// MARK: - GigiConfirmActionIntent
//
// Final step of the advanced generated Shortcut chain. The Shortcut calls this
// after it has executed a marker so GIGI can produce a clean final phrase and,
// later, update Dynamic Island / telemetry with the native action outcome.

@available(iOS 16.0, *)
struct GigiConfirmActionIntent: AppIntent {
    static var title: LocalizedStringResource = "Confirm GIGI action"
    static var description = IntentDescription(
        "Tell GIGI that the Shortcut executed an action and get the final spoken confirmation."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "GIGI result", description: "The marker or answer returned by Orchestrate with GIGI.")
    var result: String

    @Parameter(title: "Outcome", description: "Optional execution outcome from the Shortcut.")
    var outcome: String?

    @Parameter(title: "Session ID", description: "The GIGI session token from Begin GIGI session.")
    var sessionID: String?

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let speech = confirmationSpeech(for: result, outcome: outcome)
        if let sessionID, !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await GigiOrchestratorSessionStore.shared.confirm(
                sessionID: sessionID,
                result: result,
                confirmation: speech
            )
        }
        return .result(value: speech)
    }

    private func confirmationSpeech(for result: String, outcome: String?) -> String {
        if let outcome, !outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return outcome
        }

        if result.hasPrefix("SYS:") {
            let parts = result.split(separator: ":", omittingEmptySubsequences: false)
            let command = parts.count > 1 ? String(parts[1]) : "action"
            switch command {
            case "torch": return "Flashlight updated."
            case "volume": return "Volume updated."
            case "brightness": return "Brightness updated."
            case "wifi": return "Wi-Fi updated."
            case "bluetooth": return "Bluetooth updated."
            case "airplane": return "Airplane mode updated."
            case "dnd": return "Do Not Disturb updated."
            case "silent": return "Silent mode updated."
            case "lpm": return "Low Power Mode updated."
            case "screenshot": return "Screenshot captured."
            case "alarm": return "Alarm created."
            case "timer": return "Timer started."
            case "reminder": return "Reminder created."
            case "event": return "Calendar event created."
            case "music": return "Music updated."
            case "weather": return "Weather checked."
            case "battery": return "Battery checked."
            case "location": return "Location checked."
            case "spotify": return "Spotify opened."
            case "youtube": return "YouTube opened."
            case "amazon": return "Amazon opened."
            case "maps": return "Maps opened."
            case "instagram": return "Instagram opened."
            default: return "Done."
            }
        }

        if result.hasPrefix("CALL:") { return "Calling now." }
        if result.hasPrefix("SMS:") { return "Message sent." }
        if result.hasPrefix("OPEN:") { return "Opened." }
        return result
    }
}
