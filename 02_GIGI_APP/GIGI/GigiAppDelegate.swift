import UIKit
import UserNotifications

// MARK: - GigiAppDelegate
//
// Gestisce la registrazione APNS + arrivo device token + handler push.
// Usato via @UIApplicationDelegateAdaptor in GIGIApp.
// La registrazione APNS parte al primo avvio se l'utente dà consenso;
// il token viene inviato al backend Harness (se configurato in Keychain).

final class GigiAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        requestPushPermissionIfNeeded()
        return true
    }

    // MARK: - APNS

    private func requestPushPermissionIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, err in
                    if let err = err { GigiDebugLogger.log("APNS auth error: \(err.localizedDescription)"); return }
                    if granted {
                        DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
                    } else {
                        GigiDebugLogger.log("APNS auth denied dall'utente")
                    }
                }
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
            case .denied:
                GigiDebugLogger.log("APNS auth precedentemente negato — l'utente deve riabilitare da Impostazioni")
            @unknown default: break
            }
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        GigiDebugLogger.log("APNS token ricevuto: \(token.prefix(16))…")
        // Persisti il token SEMPRE (anche se Harness non configurato) e delega
        // la sincronizzazione al GigiApnsSync, che gestisce retry + cambio config.
        Task { @MainActor in GigiApnsSync.onTokenReceived(token) }
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Retry opportunistico: se in passato la sync è fallita (rete giù, server
        // non raggiungibile, config mancante) il token verrà rinviato qui.
        // No-op se il fingerprint (URL + secret) combacia con l'ultimo sync OK.
        Task { @MainActor in GigiApnsSync.onAppDidBecomeActive() }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Swift.Error) {
        GigiDebugLogger.log("APNS register fail: \(error.localizedDescription)")
    }

    // MARK: - Handler push arrivate (silent + alert)

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        handlePayload(userInfo)
        completionHandler(.newData)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handlePayload(response.notification.request.content.userInfo)
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Mostra banner anche in foreground per briefing/meeting/confirm
        completionHandler([.banner, .sound, .badge])
    }

    private func handlePayload(_ userInfo: [AnyHashable: Any]) {
        let type = (userInfo["type"] as? String) ?? ""
        switch type {
        case "confirm":
            if let jobId = userInfo["jobId"] as? String {
                NotificationCenter.default.post(name: .gigiConfirmRequired, object: nil, userInfo: ["jobId": jobId, "payload": userInfo])
            }
        case "morning-briefing", "meeting-prep":
            NotificationCenter.default.post(name: .gigiProactiveNotification, object: nil, userInfo: userInfo)
        default:
            break
        }
    }
}

extension Notification.Name {
    static let gigiConfirmRequired = Notification.Name("gigi.confirmRequired")
    static let gigiProactiveNotification = Notification.Name("gigi.proactiveNotification")
}
