import Foundation

// MARK: - GigiShortcutCommandResult
//
// Boundary object returned by the background orchestrator before it is adapted
// to the string-only value that Shortcuts consumes. Today the Shortcut boundary
// still speaks/routes marker strings (`SYS:`, `CALL:`, `SMS:`, `OPEN:`), but the
// app-side orchestrator keeps a typed result so the advanced Begin → Orchestrator
// → Confirm AppIntent chain can grow without duplicating parser logic.

struct GigiShortcutCommandResult: Equatable {
    enum Route: Equatable {
        case local
        case harness
        case cloud
        case fallback
    }

    enum Kind: Equatable {
        case system
        case call
        case sms
        case open
        case stop
        case speech

        static func infer(from shortcutValue: String) -> Kind {
            if shortcutValue.hasPrefix("SYS:") { return .system }
            if shortcutValue.hasPrefix("CALL:") { return .call }
            if shortcutValue.hasPrefix("SMS:") { return .sms }
            if shortcutValue.hasPrefix("OPEN:") { return .open }
            if shortcutValue.hasPrefix("STOP:") { return .stop }
            return .speech
        }
    }

    let shortcutValue: String
    let route: Route
    let kind: Kind

    init(shortcutValue: String, route: Route) {
        self.shortcutValue = shortcutValue
        self.route = route
        self.kind = Kind.infer(from: shortcutValue)
    }
}
