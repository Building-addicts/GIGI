import Foundation
import Combine

// MARK: - GigiModeDetector
//
// Capability probe that decides which of the 4 `GigiMode` operating modes
// are currently available to the user. Used by:
//   - `ModesSelectionView` to render per-mode availability badges
//   - `OnboardingFlowView` to auto-suggest the best mode after pairing
//   - `DashboardView` to show a "ACTIVE: <mode>" badge
//
// Caching: 60-second TTL, refreshed on app foreground or explicit invalidate.
// Probes are best-effort — a 1.5s timeout per probe avoids hangs.
//
// Reference: docs/plans/frolicking-stargazing-pancake.md §3.9
// ADR-0009 — Hardware targets and modes.

struct ModeAvailability: Identifiable, Equatable {
    let mode: GigiMode
    let isAvailable: Bool
    let missing: [String]      // human-readable requirements still missing
    let notes: String          // extra context (e.g. "RAM 16GB OK")

    var id: String { mode.rawValue }
}

@MainActor
final class GigiModeDetector: ObservableObject {
    static let shared = GigiModeDetector()

    @Published private(set) var lastResults: [ModeAvailability] = []
    private var lastProbeAt: Date?
    private let cacheTTL: TimeInterval = 60

    private init() {}

    // MARK: - Public entry

    /// Probe all four modes and return their availability. Cached for 60s.
    /// Pass `force: true` to bypass the cache (e.g. after the user re-pairs
    /// the harness).
    func detectAvailableModes(force: Bool = false) async -> [ModeAvailability] {
        if !force,
           let at = lastProbeAt,
           Date().timeIntervalSince(at) < cacheTTL,
           !lastResults.isEmpty {
            return lastResults
        }

        async let appleFM = probeAppleFM()
        async let ollama = probeOllama()
        async let claude = probeClaudeCode()
        let (afm, oll, cc) = await (appleFM, ollama, claude)

        let results: [ModeAvailability] = GigiMode.allCases.map { mode in
            switch mode {
            case .minimal:
                return ModeAvailability(
                    mode: mode,
                    isAvailable: cc.available,
                    missing: cc.available ? [] : ["Claude Code subscription"],
                    notes: cc.notes
                )
            case .localFirst:
                var missing: [String] = []
                if !afm.available { missing.append("Apple Intelligence") }
                if !oll.available { missing.append("Ollama on harness") }
                return ModeAvailability(
                    mode: mode,
                    isAvailable: afm.available && oll.available,
                    missing: missing,
                    notes: [afm.notes, oll.notes].filter { !$0.isEmpty }.joined(separator: " · ")
                )
            case .appleOptimized:
                var missing: [String] = []
                if !afm.available { missing.append("Apple Intelligence") }
                if !cc.available  { missing.append("Claude Code subscription") }
                return ModeAvailability(
                    mode: mode,
                    isAvailable: afm.available && cc.available,
                    missing: missing,
                    notes: [afm.notes, cc.notes].filter { !$0.isEmpty }.joined(separator: " · ")
                )
            case .fullPower:
                var missing: [String] = []
                if !afm.available { missing.append("Apple Intelligence") }
                if !oll.available { missing.append("Ollama on harness") }
                if !cc.available  { missing.append("Claude Code subscription") }
                return ModeAvailability(
                    mode: mode,
                    isAvailable: afm.available && oll.available && cc.available,
                    missing: missing,
                    notes: [afm.notes, oll.notes, cc.notes].filter { !$0.isEmpty }.joined(separator: " · ")
                )
            }
        }

        lastResults = results
        lastProbeAt = Date()
        return results
    }

    /// Best-available mode given current probe results. Used by onboarding
    /// to auto-suggest. Falls back to `.minimal` if literally nothing is up.
    func bestAvailableMode() async -> GigiMode {
        let results = await detectAvailableModes()
        if results.first(where: { $0.mode == .fullPower })?.isAvailable == true { return .fullPower }
        if results.first(where: { $0.mode == .appleOptimized })?.isAvailable == true { return .appleOptimized }
        if results.first(where: { $0.mode == .localFirst })?.isAvailable == true { return .localFirst }
        return .minimal
    }

    /// User's currently selected operating mode (from `@AppStorage`).
    var currentMode: GigiMode {
        let raw = UserDefaults.standard.string(forKey: "gigi.user.mode") ?? GigiMode.fullPower.rawValue
        return GigiMode(rawValue: raw) ?? .fullPower
    }

    /// Set the active mode. Triggers a `NotificationCenter` post so any
    /// view observing the change can refresh.
    func setMode(_ mode: GigiMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: "gigi.user.mode")
        NotificationCenter.default.post(name: .gigiModeDidChange, object: mode)
    }

    func invalidate() {
        lastProbeAt = nil
    }

    // MARK: - Probes

    private struct ProbeResult {
        let available: Bool
        let notes: String
    }

    private func probeAppleFM() async -> ProbeResult {
        #if canImport(FoundationModels)
        if #available(iOS 18.1, *) {
            let ok = GigiFoundationSession.shared.isAvailable
            return ProbeResult(available: ok, notes: ok ? "Apple Intelligence ready" : "Model assets unavailable")
        }
        #endif
        return ProbeResult(available: false, notes: "iOS < 18.1")
    }

    private func probeOllama() async -> ProbeResult {
        guard GigiHarnessClient.shared.isConfigured else {
            return ProbeResult(available: false, notes: "Harness not paired")
        }
        let status = await GigiHarnessClient.shared.localLLMStatus()
        if let s = status, s.reachable {
            let model = s.currentTier ?? "default"
            return ProbeResult(available: true, notes: "Ollama tier=\(model)")
        }
        return ProbeResult(available: false, notes: "Ollama unreachable")
    }

    private func probeClaudeCode() async -> ProbeResult {
        guard GigiHarnessClient.shared.isConfigured else {
            return ProbeResult(available: false, notes: "Harness not paired")
        }
        // GATE 5 wired (2026-05-12): probe the dedicated claude-status endpoint
        // which reports whether the subprocess + MCP wiring is ready, not just
        // whether the harness HTTP server is up.
        if await GigiHarnessClient.shared.claudeCodeStatus() {
            return ProbeResult(available: true, notes: "Claude Code subscription ready")
        }
        // Fallback: harness alive but `/claude-status` unreachable (older
        // harness build) — treat as best-effort available via legacy bridge.
        if await GigiHarnessClient.shared.pingHealth() {
            return ProbeResult(available: true, notes: "Harness reachable (legacy bridge)")
        }
        return ProbeResult(available: false, notes: "Harness unreachable")
    }
}

extension Notification.Name {
    static let gigiModeDidChange = Notification.Name("gigi.mode.didChange")
}
