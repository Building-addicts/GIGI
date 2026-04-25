import Foundation

// MARK: - GigiAPIKeyUsageStore
//
// Local-only usage counters for keys stored in this app. Provider account limits
// are not exposed by these runtime APIs, so Settings labels this as GIGI local usage.

struct GigiAPIKeyUsageSnapshot {
    let requests: Int
    let inputTokens: Int
    let outputTokens: Int
    let lastUsedAt: Date?

    var totalTokens: Int { inputTokens + outputTokens }
}

enum GigiAPIKeyUsageStore {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard

    nonisolated static func record(provider: String, inputTokens: Int = 0, outputTokens: Int = 0) {
        let prefix = keyPrefix(provider)
        defaults.set(defaults.integer(forKey: "\(prefix).requests") + 1, forKey: "\(prefix).requests")
        defaults.set(defaults.integer(forKey: "\(prefix).input") + max(0, inputTokens), forKey: "\(prefix).input")
        defaults.set(defaults.integer(forKey: "\(prefix).output") + max(0, outputTokens), forKey: "\(prefix).output")
        defaults.set(Date().timeIntervalSince1970, forKey: "\(prefix).last")
    }

    nonisolated static func snapshot(provider: String) -> GigiAPIKeyUsageSnapshot {
        let prefix = keyPrefix(provider)
        let last = defaults.double(forKey: "\(prefix).last")
        return GigiAPIKeyUsageSnapshot(
            requests: defaults.integer(forKey: "\(prefix).requests"),
            inputTokens: defaults.integer(forKey: "\(prefix).input"),
            outputTokens: defaults.integer(forKey: "\(prefix).output"),
            lastUsedAt: last > 0 ? Date(timeIntervalSince1970: last) : nil
        )
    }

    nonisolated static func reset(provider: String) {
        let prefix = keyPrefix(provider)
        ["requests", "input", "output", "last"].forEach {
            defaults.removeObject(forKey: "\(prefix).\($0)")
        }
    }

    nonisolated private static func keyPrefix(_ provider: String) -> String {
        "gigi.apiUsage.\(provider.lowercased())"
    }
}
