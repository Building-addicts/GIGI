import SwiftUI
import GoogleSignIn
import Intents

@main
struct GIGIApp: App {
    @StateObject var auth = GigiAuthManager.shared
    
    init() {
        // Request Siri authorization
        INPreferences.requestSiriAuthorization { status in
            print("Siri authorization: \(status.rawValue)")
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .task {
                    await GigiShortcutGenerator.shared.generateAllShortcuts()
                }
                .onOpenURL { url in
                    _ = GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
