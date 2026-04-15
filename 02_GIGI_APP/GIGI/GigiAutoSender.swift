import Foundation
import UIKit
import AVFoundation
import UserNotifications
import os.log

// MARK: - GigiAutoSender
// Invia messaggi automaticamente senza tap utente
// Funziona su TestFlight/MDM — non App Store
// Usa Accessibility API + URL scheme coordination

@MainActor
class GigiAutoSender {
    static let shared = GigiAutoSender()
    private let shortcuts = GigiShortcutGenerator.shared
    private let logger = Logger(subsystem: "GIGI", category: "WhatsAppAutomation")

    // MARK: - Entry point principale
    func send(to contact: String, message: String, via platform: String) async -> String {
        // Cerca shortcut appropriato
        let query: String
        switch platform.lowercased() {
        case "whatsapp", "wa":
            query = "WhatsApp \(contact)"
        case "telegram":
            query = "Telegram \(contact)"
        case "imessage", "sms", "messages":
            query = "Message \(contact)"
        default:
            query = "Message \(contact)"
        }
        
        if let shortcut = shortcuts.findShortcut(for: query) {
            let success = await shortcuts.execute(shortcut, message: message)
            if success {
                return "Message sent to \(contact) on \(platform)."
            }
        }
        
        // Fallback: metodo tradizionale
        switch platform.lowercased() {
        case "whatsapp", "wa":
            return await sendWhatsApp(to: contact, message: message)
        case "telegram":
            return await sendTelegram(to: contact, message: message)
        default:
            return await sendIMessage(to: contact, message: message)
        }
    }

    // MARK: - Chiamata automatica completa
    func call(to contact: String) async -> String {
        // Cerca shortcut chiamata
        let query = "Call \(contact)"
        if let shortcut = shortcuts.findShortcut(for: query) {
            let success = await shortcuts.execute(shortcut)
            if success {
                return "Calling \(contact)."
            }
        }
        return await GigiActionBridge.shared.makeCallWithIntent(to: contact)
    }

    // MARK: - WhatsApp fallback
    private func sendWhatsApp(to contact: String, message: String) async -> String {
        let number = await GigiActionBridge.shared.resolveContact(contact).number ?? ""
        guard !number.isEmpty else {
            return "Couldn't find \(contact) in your contacts."
        }

        guard UIApplication.shared.canOpenURL(URL(string: "whatsapp://")!) else {
            return "WhatsApp is not installed."
        }

        let encoded = message.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "whatsapp://send?phone=\(number)&text=\(encoded)"
        await UIApplication.shared.open(URL(string: urlString)!)
        await runWhatsAppAutomationAfterOpen(phone: number, message: message)
        return "WhatsApp opened for \(contact). Automation follow-up attempted."
    }

    /// Dopo l'apertura di WhatsApp: tenta un tap automatico su "Invia"/"Send" dopo 1s.
    /// Manteniamo anche il retry deep-link come fallback.
    private func runWhatsAppAutomationAfterOpen(phone: String, message: String) async {
        let encoded = message.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "whatsapp://send?phone=\(phone)&text=\(encoded)"
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let didTap = await attemptWhatsAppSendAssist(sendLabels: ["Invia", "Send"])
        logger.log("WhatsApp accessibility tap attempted. Success: \(didTap)")

        // Fallback: riapre il deep link se il tap non è riuscito.
        if !didTap {
            let delays: [UInt64] = [1_500_000_000, 2_000_000_000]
            for ns in delays {
                try? await Task.sleep(nanoseconds: ns)
                if let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) {
                    await UIApplication.shared.open(url)
                }
            }
        }
    }

    /// Cerca un UIButton accessibile con label "Invia"/"Send" e invia touchUpInside.
    private func attemptWhatsAppSendAssist(sendLabels: [String]) async -> Bool {
        let labels = Set(sendLabels.map { $0.lowercased() })
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }

        for window in windows {
            guard let root = window.rootViewController?.view else { continue }
            if let button = findSendButton(in: root, labels: labels) {
                button.sendActions(for: .touchUpInside)
                return true
            }
        }
        return false
    }

    private func findSendButton(in view: UIView, labels: Set<String>) -> UIButton? {
        if let button = view as? UIButton,
           let label = button.accessibilityLabel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           labels.contains(label) {
            return button
        }

        for subview in view.subviews {
            if let found = findSendButton(in: subview, labels: labels) {
                return found
            }
        }
        return nil
    }

    // MARK: - iMessage fallback
    private func sendIMessage(to contact: String, message: String) async -> String {
        let resolved = await GigiActionBridge.shared.resolveContact(contact)
        let target = resolved.number ?? contact
        guard !target.isEmpty else { return "Couldn't find \(contact)." }

        let encoded = message.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "sms:\(target)&body=\(encoded)"
        if let url = URL(string: urlString) { await UIApplication.shared.open(url) }
        return "Message ready for \(contact). Just tap Send."
    }

    // MARK: - Telegram fallback
    private func sendTelegram(to contact: String, message: String) async -> String {
        let resolved = await GigiActionBridge.shared.resolveContact(contact)
        let number = resolved.number ?? ""

        guard UIApplication.shared.canOpenURL(URL(string: "tg://")!) else {
            return "Telegram is not installed."
        }

        let encoded = message.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = number.isEmpty ? "tg://msg?text=\(encoded)" : "tg://msg?to=\(number)&text=\(encoded)"
        if let url = URL(string: urlString) { await UIApplication.shared.open(url) }
        return "Message ready for \(contact) on Telegram. Just tap Send."
    }

    // MARK: - Reminder
    func createReminder(text: String, time: String? = nil) async -> String {
        // Apri Reminders — utente crea manualmente
        await UIApplication.shared.open(URL(string: "x-apple-reminderkit://")!)
        return "Opening Reminders. Create reminder for: \(text)"
    }

    // MARK: - Notifica utente dopo invio
    func notifySuccess(contact: String, platform: String) {
        let content = UNMutableNotificationContent()
        content.title = "GIGI"
        content.body  = "Message sent to \(contact) on \(platform) ✓"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
