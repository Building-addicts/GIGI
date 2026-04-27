import Foundation

// MARK: - GigiPresenceAppGroup
//
// Bidirectional signal bridge between the widget extension (Dynamic Island buttons)
// and the main app (PresenceSessionController).
//
// Widget intents write a command to the shared UserDefaults suite, then post a
// Darwin notification. The main app observes Darwin notifications and reads the command.
//
// Requires App Groups entitlement: group.com.gigi.presence
// Add to both GIGI.entitlements and GIGIWidget.entitlements.

final class GigiPresenceAppGroup {
    nonisolated static let suiteName  = "group.com.gigi.presence"
    nonisolated static let commandKey = "pendingCommand"
    nonisolated static let darwinMute  = "com.gigi.presence.mute"
    nonisolated static let darwinStop  = "com.gigi.presence.stop"
    nonisolated static let darwinStart = "com.gigi.presence.start"
    nonisolated static let darwinLock  = "com.gigi.presence.islandLock"

    enum Command: String {
        case start, mute, unmute, stop, lockIsland, unlockIsland
    }

    // Called by the widget intent process. nonisolated so AppIntent.perform()
    // (which runs in its own concurrency context) can call without crossing
    // a MainActor boundary. UserDefaults + CFNotificationCenter are thread-safe.
    nonisolated static func postCommand(_ cmd: Command) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.set(cmd.rawValue, forKey: commandKey)
        let notifName: String
        switch cmd {
        case .start:         notifName = darwinStart
        case .mute, .unmute: notifName = darwinMute
        case .stop:          notifName = darwinStop
        case .lockIsland, .unlockIsland:
            notifName = darwinLock
        }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notifName as CFString),
            nil, nil, true
        )
    }

    // Called by the main app to start observing commands via NotificationCenter bridge.
    // CFNotificationCallback must be a plain C function (no captures), so we use
    // a static relay that fires NotificationCenter, which Swift closures can observe.
    @MainActor
    static func observeCommands(_ handler: @escaping (Command) -> Void) {
        registerDarwinObservers()

        NotificationCenter.default.addObserver(
            forName: .gigiPresenceMute, object: nil, queue: .main
        ) { _ in
            let raw = UserDefaults(suiteName: suiteName)?.string(forKey: commandKey) ?? "mute"
            if let cmd = Command(rawValue: raw) { handler(cmd) }
        }
        NotificationCenter.default.addObserver(
            forName: .gigiPresenceStop, object: nil, queue: .main
        ) { _ in
            handler(.stop)
        }
        NotificationCenter.default.addObserver(
            forName: .gigiPresenceStart, object: nil, queue: .main
        ) { _ in
            handler(.start)
        }
        NotificationCenter.default.addObserver(
            forName: .gigiPresenceIslandLock, object: nil, queue: .main
        ) { _ in
            let raw = UserDefaults(suiteName: suiteName)?.string(forKey: commandKey) ?? "lockIsland"
            if let cmd = Command(rawValue: raw) { handler(cmd) }
        }
    }

    private static var darwinObserversRegistered = false
    private static func registerDarwinObservers() {
        guard !darwinObserversRegistered else { return }
        darwinObserversRegistered = true

        let muteCallback: CFNotificationCallback = { _, _, _, _, _ in
            NotificationCenter.default.post(name: .gigiPresenceMute, object: nil)
        }
        let stopCallback: CFNotificationCallback = { _, _, _, _, _ in
            NotificationCenter.default.post(name: .gigiPresenceStop, object: nil)
        }
        let startCallback: CFNotificationCallback = { _, _, _, _, _ in
            NotificationCenter.default.post(name: .gigiPresenceStart, object: nil)
        }
        let lockCallback: CFNotificationCallback = { _, _, _, _, _ in
            NotificationCenter.default.post(name: .gigiPresenceIslandLock, object: nil)
        }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, nil, muteCallback,  darwinMute  as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, nil, stopCallback,  darwinStop  as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, nil, startCallback, darwinStart as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, nil, lockCallback,  darwinLock  as CFString, nil, .deliverImmediately)
    }
}

private extension Notification.Name {
    static let gigiPresenceMute  = Notification.Name("com.gigi.presence.mute.local")
    static let gigiPresenceStop  = Notification.Name("com.gigi.presence.stop.local")
    static let gigiPresenceStart = Notification.Name("com.gigi.presence.start.local")
    static let gigiPresenceIslandLock = Notification.Name("com.gigi.presence.islandLock.local")
}
