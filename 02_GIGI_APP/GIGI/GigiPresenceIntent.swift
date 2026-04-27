import AppIntents
import Foundation

// MARK: - GigiStartPresenceIntent

@available(iOS 16.0, *)
struct GigiStartPresenceIntent: AppIntent {
    static var title: LocalizedStringResource = "Start GIGI Presence"
    static var description = IntentDescription("Start a GIGI Presence Mode session")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        GigiPresenceAppGroup.postCommand(.start)
        return .result()
    }
}

// MARK: - GigiStopPresenceIntent

@available(iOS 16.0, *)
struct GigiStopPresenceIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop GIGI Presence"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        GigiPresenceAppGroup.postCommand(.stop)
        return .result()
    }
}

// MARK: - GigiMutePresenceIntent (from Dynamic Island widget button)

@available(iOS 16.0, *)
struct GigiMutePresenceIntent: AppIntent {
    static var title: LocalizedStringResource = "Mute GIGI"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        GigiPresenceAppGroup.postCommand(.mute)
        return .result()
    }
}

// MARK: - GigiUnmutePresenceIntent (from Dynamic Island widget button)

@available(iOS 16.0, *)
struct GigiUnmutePresenceIntent: AppIntent {
    static var title: LocalizedStringResource = "Unmute GIGI"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        GigiPresenceAppGroup.postCommand(.unmute)
        return .result()
    }
}
