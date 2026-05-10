import SwiftUI
import AppIntents
import WebKit

// GoogleSignIn + GigiAuthManager rimossi nel rework armando-rework (ADR-0004).

@main
struct GIGIApp: App {
    @UIApplicationDelegateAdaptor(GigiAppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        GigiDebugLogger.log("GIGIApp init STARTED — bundle=\(Bundle.main.bundleIdentifier ?? "nil")")
        if #available(iOS 16.0, *) {
            GigiAppShortcuts.updateAppShortcutParameters()
        }
        // Synchronous flush attempt for prior crash logs (so they reach the wire
        // before THIS run potentially crashes too).
        let prior = UserDefaults.standard.stringArray(forKey: "gigi_crash_logs") ?? []
        GigiDebugLogger.log("GIGIApp init: prior crash logs count=\(prior.count)")
        Task { await GigiDebugLogger.flushCrashLogs() }
        GigiDebugLogger.log("GIGIApp init FINISHED")
    }

    var body: some Scene {
        GigiDebugLogger.log("GIGIApp body evaluated")
        return WindowGroup {
            MainTabView()
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { @MainActor in GigiApnsSync.onAppDidBecomeActive() }
                        // Presence Mode is the canonical always-available path.
                        // On every foreground transition, sync the user's preference:
                        // enabled → Presence owns Dynamic Island + wake word; disabled → no wake engine.
                        Task { @MainActor in
                            GigiDebugLogger.log("scenePhase=.active → sync always-available Presence")
                            PresenceSessionController.shared.syncAlwaysAvailablePreference()
                        }
                        // Silently re-verify WhatsApp session after app resumes from background
                        Task {
                            guard UserDefaults.standard.bool(forKey: "gigi.whatsapp.linked"),
                                  GigiWebAgent.shared.webView.url?.host == "web.whatsapp.com"
                            else { return }
                            let still = (try? await GigiWebAgent.shared.js(
                                "document.querySelector('[data-testid=\"chat-list\"]') !== null"
                            )) as? Bool ?? false
                            if !still {
                                UserDefaults.standard.set(false, forKey: "gigi.whatsapp.linked")
                                print("GIGI: WhatsApp session expired — user must re-link")
                            }
                        }
                    }
                }
                .task {
                    GigiDebugLogger.log("MainTabView .task started")
                    await GigiDebugLogger.flushCrashLogs()
                    GigiDebugLogger.log("flushCrashLogs done")
                    GigiBrainDiagnostics.log()
                    GigiBrainDiagnostics.shared.startMonitoring()
                    GigiDebugLogger.log("GigiBrainDiagnostics done — reachability monitor started")
                    // Presence Mode is now the single always-available mode. This starts
                    // Presence only when the user enabled it; otherwise it guarantees the
                    // wake-word engine is off so there is no second parallel logic.
                    PresenceSessionController.shared.syncAlwaysAvailablePreference()
                    GigiDebugLogger.log("Presence always-available sync done")
                    // Realtime engine connects lazily on first use to save battery at startup
                    // Pre-load semantic memory for top-priority namespaces (non-blocking)
                    await GigiVectorStore.shared.preload(namespaces: [.contacts, .preferences, .places])
                    await GigiUserProfile.shared.seedMVPPreferencesIfNeeded()
                    #if DEBUG
                    let mvpRoundTripOK = await GigiUserProfile.shared._debugMVPRoundTrip()
                    GigiDebugLogger.log("AC5 MVPPreferences round-trip → \(mvpRoundTripOK ? "OK" : "FAIL")")
                    // GigiDayPlanReasoner smoke tests removed (2026-05-11): engine moved
                    // to _legacy/ (ADR-0005). Reactivate alongside sub 4/4 (#59).
                    #endif
                    GigiDebugLogger.log("MainTabView .task finished")
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if let window = UIApplication.shared.connectedScenes
                            .compactMap({ $0 as? UIWindowScene })
                            .first?.windows.first {
                            GigiWebAgent.shared.attach(to: window)
                        }
                    }
                }
                .onOpenURL { url in
                    // gigi:// custom scheme handled here. Google OAuth callback
                    // scheme rimosso con il kill GoogleSignIn (ADR-0004).
                    if url.scheme?.lowercased() == "gigi" {
                        if url.host == "listen" {
                            startListenFromControl()
                            return
                        }
                        NotificationCenter.default.post(name: .gigiGatewayCallback, object: url)
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { handlePendingControlListenIfAny() }
                }
        }
    }

    // MARK: - Control Center toggle handshake (#159)

    private func startListenFromControl() {
        if !PresenceSessionController.shared.isActive {
            PresenceSessionController.shared.startSession()
        }
        GigiSmartOrchestrator.shared.startListening()
    }

    /// Picks up the UserDefaults handshake set by `GIGIControlOpenIntent`
    /// when the Control Center button taps. Without this, the AppIntent
    /// foregrounds the app but no listening kicks in (the URL path used
    /// to do that work).
    private func handlePendingControlListenIfAny() {
        let suite = UserDefaults(suiteName: "group.com.gigi.presence") ?? .standard
        guard suite.bool(forKey: "pendingControlListenRequest") else { return }
        let ts = suite.double(forKey: "pendingControlListenAt")
        // 5s freshness window so a stale flag from a prior session does not
        // accidentally start a listen on the next launch.
        if Date().timeIntervalSince1970 - ts < 5 {
            startListenFromControl()
        }
        suite.set(false, forKey: "pendingControlListenRequest")
        suite.removeObject(forKey: "pendingControlListenAt")
    }
}
