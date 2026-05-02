import SwiftUI
import GoogleSignIn
import WebKit

@main
struct GIGIApp: App {
    @UIApplicationDelegateAdaptor(GigiAppDelegate.self) var appDelegate
    @StateObject var auth = GigiAuthManager.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        GigiDebugLogger.log("GIGIApp init STARTED — bundle=\(Bundle.main.bundleIdentifier ?? "nil")")
        // Synchronous flush attempt for prior crash logs (so they reach the wire
        // before THIS run potentially crashes too).
        let prior = UserDefaults.standard.stringArray(forKey: "gigi_crash_logs") ?? []
        GigiDebugLogger.log("GIGIApp init: prior crash logs count=\(prior.count)")
        Task { await GigiDebugLogger.flushCrashLogs() }
        GigiDebugLogger.log("GIGIApp init FINISHED")
    }

    // Reads the App Group flag set by GIGIControlListenIntent (Control Center
    // toggle). Called on every scenePhase=.active transition. If a fresh
    // listen request is pending (timestamp within last 5s), starts QuickTalk
    // continuous mode and clears the flag.
    private static func consumeControlCenterListenRequestIfPending() {
        guard let defaults = UserDefaults(suiteName: "group.com.gigi.presence") else { return }
        let key = "gigi.cc.listenRequestedAt"
        let ts = defaults.double(forKey: key)
        guard ts > 0 else { return }
        let age = Date().timeIntervalSince1970 - ts
        defaults.removeObject(forKey: key)
        guard age < 5 else { return }
        Task { @MainActor in
            QuickTalkController.shared.startContinuous()
        }
    }

    var body: some Scene {
        GigiDebugLogger.log("GIGIApp body evaluated")
        return WindowGroup {
            MainTabView()
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        GIGIApp.consumeControlCenterListenRequestIfPending()
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
                    // Cover the cold-launch race where the AppIntent's
                    // perform() may run AFTER scenePhase=.active fires:
                    // poll the App Group flag for 3 seconds.
                    Task {
                        for _ in 0..<15 {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            GIGIApp.consumeControlCenterListenRequestIfPending()
                        }
                    }
                    GigiDebugLogger.log("MainTabView .task started")
                    await GigiDebugLogger.flushCrashLogs()
                    GigiDebugLogger.log("flushCrashLogs done")
                    GigiBrainDiagnostics.log()
                    GigiDebugLogger.log("GigiBrainDiagnostics done")
                    // Presence Mode is now the single always-available mode. This starts
                    // Presence only when the user enabled it; otherwise it guarantees the
                    // wake-word engine is off so there is no second parallel logic.
                    PresenceSessionController.shared.syncAlwaysAvailablePreference()
                    GigiDebugLogger.log("Presence always-available sync done")
                    // Realtime engine connects lazily on first use to save battery at startup
                    // Pre-load semantic memory for top-priority namespaces (non-blocking)
                    await GigiVectorStore.shared.preload(namespaces: [.contacts, .preferences, .places])
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
                    if url.scheme?.lowercased() == "gigi" {
                        if url.host == "listen" {
                            if !PresenceSessionController.shared.isActive {
                                PresenceSessionController.shared.startSession()
                            }
                            GigiSmartOrchestrator.shared.startListening()
                            return
                        }
                        NotificationCenter.default.post(name: .gigiGatewayCallback, object: url)
                        return
                    }
                    _ = GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
