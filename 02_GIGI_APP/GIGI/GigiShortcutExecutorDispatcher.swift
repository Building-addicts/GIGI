import Foundation
import UIKit

// MARK: - GigiShortcutExecutorDispatcher
//
// App-side boundary between GIGI's in-process orchestrator and the hidden
// Shortcuts executor. The user-facing entry is the Dynamic Island listening
// flow; Shortcuts only receives preformatted markers after GIGI has routed the
// command.

@MainActor
enum GigiShortcutExecutorDispatcher {
    static func dispatch(_ result: GigiShortcutCommandResult) async -> Bool {
        switch result.kind {
        case .system, .call, .sms, .open:
            return await runExecutorShortcut(marker: result.shortcutValue)
        case .stop:
            PresenceSessionController.shared.stopSession(disablePreference: false)
            return true
        case .speech:
            return false
        }
    }

    static func handleCallback(_ url: URL) {
        switch url.host {
        case "executor-complete":
            Task { await GigiLiveActivityController.shared.completeWithDone(message: "Done.") }
        case "executor-cancel":
            Task { await GigiLiveActivityController.shared.showError(message: "Shortcut cancelled") }
        default:
            break
        }
    }

    private static func runExecutorShortcut(marker: String) async -> Bool {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: GigiHardwareShortcut.executorShortcutName),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: marker),
            URLQueryItem(name: "x-success", value: GigiHardwareShortcut.executorSuccessURLString),
            URLQueryItem(name: "x-cancel", value: GigiHardwareShortcut.executorCancelURLString),
        ]

        guard let url = components.url else { return false }
        guard UIApplication.shared.canOpenURL(url) else { return false }

        await GigiLiveActivityController.shared.transitionToExecuting(message: caption(for: marker))
        await UIApplication.shared.open(url)
        return true
    }

    private static func caption(for marker: String) -> String {
        if marker.hasPrefix("CALL:") { return "Calling..." }
        if marker.hasPrefix("SMS:") { return "Sending message..." }
        if marker.hasPrefix("OPEN:") { return "Opening..." }
        if marker.hasPrefix("SYS:torch:") { return "Updating flashlight..." }
        if marker.hasPrefix("SYS:volume:") { return "Setting volume..." }
        if marker.hasPrefix("SYS:brightness:") { return "Setting brightness..." }
        if marker.hasPrefix("SYS:wifi:") { return "Updating Wi-Fi..." }
        if marker.hasPrefix("SYS:dnd:") { return "Updating Focus..." }
        if marker.hasPrefix("SYS:screenshot:") { return "Taking screenshot..." }
        if marker.hasPrefix("SYS:music:") { return "Controlling music..." }
        if marker.hasPrefix("SYS:battery:") { return "Checking battery..." }
        if marker.hasPrefix("SYS:weather:") { return "Checking weather..." }
        return "Running command..."
    }
}
