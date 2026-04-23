import SwiftUI
import GoogleSignIn
import WebKit

@main
struct GIGIApp: App {
    @StateObject var auth = GigiAuthManager.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        GigiDebugLogger.log("GIGIApp init started")
        Task { await GigiDebugLogger.flushCrashLogs() }
        GigiDebugLogger.log("GIGIApp init finished")
    }

    var body: some Scene {
        GigiDebugLogger.log("GIGIApp body evaluated")
        return WindowGroup {
            MainTabView()
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
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
                    GigiDebugLogger.log("GigiBrainDiagnostics done")
                    // Realtime engine connects lazily on first use to save battery at startup
                    GigiAudioManager.shared.startWakeWordListening()
                    GigiDebugLogger.log("GigiAudioManager startWakeWordListening done")
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
