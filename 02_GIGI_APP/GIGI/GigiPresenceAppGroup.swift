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
    static let suiteName  = "group.com.gigi.presence"
    static let commandKey = "pendingCommand"
    static let darwinMute = "com.gigi.presence.mute"
    static let darwinStop = "com.gigi.presence.stop"

    enum Command: String {
        case mute, unmute, stop
    }

    // Called by the widget intent process
    static func postCommand(_ cmd: Command) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.set(cmd.rawValue, forKey: commandKey)
        let notifName: String
        switch cmd {
        case .mute, .unmute: notifName = darwinMute
        case .stop:          notifName = darwinStop
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
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, nil, muteCallback, darwinMute as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, nil, stopCallback, darwinStop as CFString, nil, .deliverImmediately)
    }
}

private extension Notification.Name {
    static let gigiPresenceMute = Notification.Name("com.gigi.presence.mute.local")
    static let gigiPresenceStop = Notification.Name("com.gigi.presence.stop.local")
}
