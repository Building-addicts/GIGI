import Foundation

// MARK: - GigiPersistentMemory
//
// Read-only client for the harness-side gigi-memory store (orders.json).
// Fetches recent confirmed orders at the start of each agent turn so the
// on-device FM can offer "same as last time" without needing memory of
// its own. The local FM never WRITES — only Claude cloud writes, after
// real browser staging, via the gigi-memory MCP server's record_order
// tool. This asymmetry is the anti-fabrication guarantee.
//
// Cache: 60s TTL. Memory rarely changes mid-conversation (only after a
// successful confirmed order). Keep the cache short enough that a
// just-completed order shows up on the very next turn.

@MainActor
final class GigiPersistentMemory {
    static let shared = GigiPersistentMemory()

    private let harness = GigiHarnessClient.shared
    private let cacheTTL: TimeInterval = 60
    private let defaultLimit = 5

    private var cachedOrders: [GigiHarnessClient.OrderEntry] = []
    private var cachedAt: Date?

    private init() {}

    /// Fetch + cache recent orders. Returns the cached value if it's still
    /// fresh, otherwise hits the harness. On harness failure, returns the
    /// last good cache (possibly empty) rather than throwing — memory is
    /// an optional input to routing, not a hard dependency.
    func recentOrders(limit: Int? = nil, forceRefresh: Bool = false) async -> [GigiHarnessClient.OrderEntry] {
        let n = limit ?? defaultLimit
        if !forceRefresh,
           let ts = cachedAt,
           Date().timeIntervalSince(ts) < cacheTTL,
           cachedOrders.count >= n {
            return Array(cachedOrders.prefix(n))
        }
        let result = await harness.recentOrders(limit: max(n, defaultLimit))
        switch result {
        case .success(let orders):
            cachedOrders = orders
            cachedAt = Date()
            return Array(orders.prefix(n))
        case .failure(let err):
            GigiDebugLogger.log("GIGI PersistentMemory: fetch failed (\(err.localizedDescription)) — using stale cache (\(cachedOrders.count) entries)")
            return Array(cachedOrders.prefix(n))
        }
    }

    /// Drop the cache. Called from chat ↻ reset so a wiped session also
    /// re-pulls memory on next turn (defends against the user editing
    /// orders.json manually mid-session).
    func clearCache() {
        cachedOrders.removeAll()
        cachedAt = nil
    }

    /// Format the recent orders as a compact text block to inject into the
    /// FM router's `history` parameter. Format chosen to be small AND
    /// unambiguous so the FM doesn't confuse it with conversation turns:
    ///
    ///   <past_orders>
    ///   1. order at <merchant>: <item> [<variant>] (<total>)
    ///   2. ...
    ///   </past_orders>
    ///
    /// Returns empty string when there are no orders, so callers can join
    /// it into history unconditionally without producing dangling tags.
    func contextString(limit: Int = 5) async -> String {
        let orders = await recentOrders(limit: limit)
        guard !orders.isEmpty else { return "" }
        let lines: [String] = orders.enumerated().map { idx, o in
            var parts = ["\(idx + 1). \(o.kind) at \(o.merchant): \(o.item)"]
            if let v = o.variant, !v.isEmpty { parts.append("[\(v)]") }
            if let t = o.total, !t.isEmpty { parts.append("(\(t))") }
            return parts.joined(separator: " ")
        }
        return "<past_orders>\n" + lines.joined(separator: "\n") + "\n</past_orders>"
    }
}
