import Combine
import Foundation
import UIKit

enum HarnessStatus: String {
    case online, degraded, offline, unknown
}

enum TurnPath: String {
    case unknown, harness, fallback
}

@MainActor
final class GigiBrainDiagnostics: ObservableObject {
    static let shared = GigiBrainDiagnostics()

    @Published private(set) var harnessStatus: HarnessStatus = .unknown
    @Published private(set) var lastSuccessAt: Date?
    @Published private(set) var consecutiveFailures: Int = 0

    /// Which path served the most recent turn — surfaced by `GigiClaudeBridge`.
    /// UI binds to this for the provisional "LOCAL AI" indicator on the
    /// dashboard. Resets to `.harness` whenever a turn flows through the
    /// harness; sticks at `.fallback` while the local path is in use.
    @Published private(set) var lastTurnPath: TurnPath = .unknown

    private var monitorTask: Task<Void, Never>?

    private init() {}

    func recordTurnPath(_ path: TurnPath) {
        lastTurnPath = path
    }

    /// Starts a polling loop that pings the harness health endpoint and
    /// publishes the resulting `HarnessStatus`. Foreground 5s, background 30s.
    /// Idempotent: a second call cancels and replaces the previous loop.
    func startMonitoring(
        foregroundIntervalSec: TimeInterval = 5,
        backgroundIntervalSec: TimeInterval = 30
    ) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                let isBackground = await MainActor.run {
                    UIApplication.shared.applicationState == .background
                }
                let interval = isBackground ? backgroundIntervalSec : foregroundIntervalSec
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func tick() async {
        let ok = await GigiHarnessClient.shared.pingHealth()
        if ok {
            let wasOffline = harnessStatus == .offline
            consecutiveFailures = 0
            lastSuccessAt = Date()
            harnessStatus = .online
            if wasOffline {
                GigiDebugLogger.log("Harness recovery: offline → online")
            }
        } else {
            consecutiveFailures += 1
            // 1 fail = degraded, 2+ consecutive = offline (≥10s of unreachability with foreground 5s tick)
            let newStatus: HarnessStatus = consecutiveFailures >= 2 ? .offline : .degraded
            if harnessStatus != newStatus {
                GigiDebugLogger.log("Harness status: \(harnessStatus.rawValue) → \(newStatus.rawValue) (consecutiveFailures=\(consecutiveFailures))")
            }
            harnessStatus = newStatus
        }
    }

    // MARK: - Legacy log shim
    //
    // Pre-existing call sites (`GIGIApp.swift`, `SettingsView.swift`) print a
    // one-shot "Brain Status" banner at app launch. Kept intact to avoid
    // ripple-edit; new state lives on `harnessStatus` and is observable.

    static func log() {
        let apiKey = GigiConfig.groqAPIKey
        let keyStatus: String
        if apiKey.isEmpty {
            keyStatus = "❌ MISSING — add your Groq key in Settings"
        } else {
            let preview = String(apiKey.prefix(8)) + "..."
            keyStatus = "✓ set (\(preview), \(apiKey.count) chars)"
        }

        var foundationStatus = "not available"
        if #available(iOS 18.1, *) {
            foundationStatus = GigiFoundationAgent.isSupported
                ? "✓ Apple Intelligence ready"
                : "optional off — Groq/local fallback active"
        }

        print("""
        ┌─ GIGI Brain Status ────────────────────────────────────
        │  Groq API key   : \(keyStatus)
        │  Model          : llama-3.3-70b-versatile
        │  Foundation AI  : \(foundationStatus)
        │  Fallback NLU   : ✓ always available (offline)
        └────────────────────────────────────────────────────────
        """)
    }
}
