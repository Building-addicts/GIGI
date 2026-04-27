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

// MARK: - GigiLockIslandIntent / GigiUnlockIslandIntent (Dynamic Island hold)

@available(iOS 16.0, *)
struct GigiLockIslandIntent: AppIntent {
    static var title: LocalizedStringResource = "Lock GIGI Island"
    static var description = IntentDescription("Keep the current GIGI Dynamic Island state visible until unlocked")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        GigiPresenceAppGroup.postCommand(.lockIsland)
        return .result()
    }
}

@available(iOS 16.0, *)
struct GigiUnlockIslandIntent: AppIntent {
    static var title: LocalizedStringResource = "Unlock GIGI Island"
    static var description = IntentDescription("Release the GIGI Dynamic Island back to automatic idle updates")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        GigiPresenceAppGroup.postCommand(.unlockIsland)
        return .result()
    }
}

// MARK: - GigiAllowAlwaysListeningIntent / GigiDeclineAlwaysListeningIntent
// First-wake consent prompt buttons. Allow = enter Always Listening (locks the
// island into a persistent compact pill, keeps wake word + mic alive across turns).
// Decline = single-turn flow, no lock; user is not re-prompted in this app launch.

@available(iOS 16.0, *)
struct GigiAllowAlwaysListeningIntent: AppIntent {
    static var title: LocalizedStringResource = "Allow always listening"
    static var description = IntentDescription("Keep GIGI listening across this session until you stop it")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        GigiPresenceAppGroup.postCommand(.allowAlwaysListening)
        return .result()
    }
}

@available(iOS 16.0, *)
struct GigiDeclineAlwaysListeningIntent: AppIntent {
    static var title: LocalizedStringResource = "Just this time"
    static var description = IntentDescription("Continue with a single turn; do not keep listening after the response")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        GigiPresenceAppGroup.postCommand(.declineAlwaysListening)
        return .result()
    }
}
