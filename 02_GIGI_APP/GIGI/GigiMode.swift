import Foundation

// MARK: - GigiMode
//
// Operating mode chosen by the user in Settings → Modes. Drives which of
// the 5 paths are enabled in the router (GATE 7). Auto-detected at boot
// via `GigiSmartOrchestrator.detectAvailableModes()` based on capability
// probes (Apple Intelligence, Ollama, Claude Code subscription).
//
// Reference: docs/plans/frolicking-stargazing-pancake.md §3.9 (modes table)
// ADR-0009 (Hardware targets and modes).

enum GigiMode: String, CaseIterable, Identifiable {
    case minimal         = "minimal"
    case localFirst      = "local_first"
    case appleOptimized  = "apple_optimized"
    case fullPower       = "full_power"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .minimal:        return "Minimal"
        case .localFirst:     return "Local-First"
        case .appleOptimized: return "Apple Optimized"
        case .fullPower:      return "Full Power"
        }
    }

    var summary: String {
        switch self {
        case .minimal:
            return "Path 1 (native) + Path 4 (Claude). Quickest setup."
        case .localFirst:
            return "Path 1 + Path 2 + Path 3. 100% on-device or on your LAN. No cloud."
        case .appleOptimized:
            return "Path 1 + Path 2 + Path 4. Best balance for iPhone 15 Pro+."
        case .fullPower:
            return "All 5 paths. Apple FM + Ollama + Claude Code with browser."
        }
    }

    var requirements: [String] {
        switch self {
        case .minimal:        return ["Claude Code subscription"]
        case .localFirst:     return ["Apple Intelligence", "Ollama on harness"]
        case .appleOptimized: return ["Apple Intelligence", "Claude Code subscription"]
        case .fullPower:      return ["Apple Intelligence", "Ollama on harness", "Claude Code subscription"]
        }
    }

    var privacyHint: String {
        switch self {
        case .minimal:        return "Reasoning goes through Claude subscription."
        case .localFirst:     return "Stays on-device or on your LAN."
        case .appleOptimized: return "Native actions local; reasoning via Claude."
        case .fullPower:      return "Local-first when possible, cloud when needed."
        }
    }

    var latencyHint: String {
        switch self {
        case .minimal:        return "Action 80ms · Reasoning 30-60s"
        case .localFirst:     return "Action 80ms · Reasoning 7-15s"
        case .appleOptimized: return "Action 80ms · Reasoning 30-60s"
        case .fullPower:      return "Action 80ms · Reasoning 7-60s adaptive"
        }
    }

    // MARK: - Path gating

    var allowsAppleFMRouter: Bool {
        switch self {
        case .minimal:        return false
        case .localFirst:     return true
        case .appleOptimized: return true
        case .fullPower:      return true
        }
    }

    var allowsLocal: Bool {
        switch self {
        case .minimal:        return false
        case .localFirst:     return true
        case .appleOptimized: return false
        case .fullPower:      return true
        }
    }

    var allowsCloud: Bool {
        switch self {
        case .minimal:        return true
        case .localFirst:     return false
        case .appleOptimized: return true
        case .fullPower:      return true
        }
    }

    /// Apply mode policy to a router decision: if a path is disabled in this
    /// mode, remap it to the closest enabled alternative (or to a "blocked"
    /// sentinel that the router speaks back to the user).
    func remap(_ path: String, capabilities: [String]) -> String {
        switch path {
        case "delegate_local":
            if allowsLocal { return path }
            // Allowed cloud fallback?
            return allowsCloud ? "delegate_cloud" : "mode_blocked_local"
        case "delegate_cloud":
            if allowsCloud { return path }
            // Try local fallback if capabilities are simple enough.
            let caps = Set(capabilities)
            if allowsLocal, caps.isDisjoint(with: ["browser", "code", "vision", "web_search"]) {
                return "delegate_local"
            }
            return "mode_blocked_cloud"
        default:
            // native_tool / ask_clarification / reject are always allowed.
            return path
        }
    }
}
