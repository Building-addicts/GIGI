import AppIntents
import Foundation

// MARK: - GigiStartPresenceIntent

@available(iOS 16.0, *)
struct GigiStartPresenceIntent: AppIntent {
    static var title: LocalizedStringResource = "Start GIGI Presence"
    static var description = IntentDescription("Start a GIGI Presence Mode session")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            if PresenceSessionController.shared.isActive {
                PresenceSessionController.shared.stopSession()
            } else {
                PresenceSessionController.shared.startSession()
            }
        }
        return .result()
    }
}

// MARK: - GigiStopPresenceIntent

@available(iOS 16.0, *)
struct GigiStopPresenceIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop GIGI Presence"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run { PresenceSessionController.shared.stopSession() }
        return .result()
    }
}

// MARK: - GigiMutePresenceIntent (from Dynamic Island widget button)

@available(iOS 16.0, *)
struct GigiMutePresenceIntent: AppIntent {
    static var title: LocalizedStringResource = "Mute/Unmute GIGI"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            let c = PresenceSessionController.shared
            if c.state == .muted { c.unmute() } else { c.mute() }
        }
        return .result()
    }
}
