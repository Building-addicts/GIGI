import Foundation
import Contacts
import UIKit

// MARK: - GigiShortcut
struct GigiShortcut: Codable {
    let name: String           // "Call Mom", "WhatsApp Message Dad"
    let type: ShortcutType
    let targetID: String       // numero telefono, bundle ID app, ecc.
    let metadata: [String: String]
    
    enum ShortcutType: String, Codable {
        case call
        case message
        case whatsappMessage
        case telegramMessage
        case openApp
        case navigate
        case email
    }
}

// MARK: - GigiShortcutGenerator
// Scansiona device e genera shortcuts automaticamente
@MainActor
class GigiShortcutGenerator {
    static let shared = GigiShortcutGenerator()
    
    private var shortcuts: [GigiShortcut] = []
    private let contactStore = CNContactStore()
    
    // Percorso cache shortcuts
    private var cacheURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gigi_shortcuts.json")
    }
    
    // MARK: - Init
    init() {
        loadFromCache()
    }
    
    // MARK: - Generazione automatica completa
    func generateAllShortcuts() async {
        print("GIGI Shortcuts: Starting auto-generation...")
        shortcuts.removeAll()
        
        // 1. Genera shortcuts per contatti
        await generateContactShortcuts()
        
        // 2. Genera shortcuts per app installate
        await generateAppShortcuts()
        
        // 3. Salva cache
        saveToCache()
        
        print("GIGI Shortcuts: Generated \(shortcuts.count) shortcuts")
    }
    
    // MARK: - Contatti
    private func generateContactShortcuts() async {
        let contactShortcuts = await Task.detached(priority: .userInitiated) { () -> [GigiShortcut] in
            let store = CNContactStore()
            let status = CNContactStore.authorizationStatus(for: .contacts)
            if status == .notDetermined {
                let granted = await withCheckedContinuation { continuation in
                    store.requestAccess(for: .contacts) { ok, _ in
                        continuation.resume(returning: ok)
                    }
                }
                guard granted else { return [] }
            }

            guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
                return []
            }

            let keys: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactNicknameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var generated: [GigiShortcut] = []

            do {
                try store.enumerateContacts(with: request) { contact, _ in
                    let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                    let displayName = fullName.isEmpty ? (contact.nickname.isEmpty ? "Unknown" : contact.nickname) : fullName

                    for phoneNumber in contact.phoneNumbers {
                        let number = phoneNumber.value.stringValue
                            .components(separatedBy: CharacterSet.decimalDigits.inverted)
                            .joined()
                        guard !number.isEmpty else { continue }

                        generated.append(GigiShortcut(name: "Call \(displayName)", type: .call, targetID: number, metadata: ["contact": displayName]))
                        generated.append(GigiShortcut(name: "Message \(displayName)", type: .message, targetID: number, metadata: ["contact": displayName]))
                        generated.append(GigiShortcut(name: "WhatsApp \(displayName)", type: .whatsappMessage, targetID: number, metadata: ["contact": displayName]))
                        generated.append(GigiShortcut(name: "Telegram \(displayName)", type: .telegramMessage, targetID: number, metadata: ["contact": displayName]))
                    }

                    for email in contact.emailAddresses {
                        let emailAddr = email.value as String
                        generated.append(GigiShortcut(name: "Email \(displayName)", type: .email, targetID: emailAddr, metadata: ["contact": displayName]))
                    }
                }
            } catch {
                return []
            }
            return generated
        }.value

        guard !contactShortcuts.isEmpty else {
            print("GIGI Shortcuts: No contacts permission or no contacts found")
            return
        }
        shortcuts.append(contentsOf: contactShortcuts)
        print("GIGI Shortcuts: Generated shortcuts for contacts")
    }
    
    // MARK: - App installate
    private func generateAppShortcuts() async {
        // Lista app comuni — iOS non permette di enumerare tutte le app installate
        // ma possiamo testare gli URL schemes conosciuti
        let knownApps: [(name: String, scheme: String)] = [
            ("Spotify", "spotify"),
            ("Instagram", "instagram"),
            ("WhatsApp", "whatsapp"),
            ("Telegram", "tg"),
            ("YouTube", "youtube"),
            ("Netflix", "nflx"),
            ("TikTok", "tiktok"),
            ("Twitter", "twitter"),
            ("Facebook", "fb"),
            ("Snapchat", "snapchat"),
            ("LinkedIn", "linkedin"),
            ("Reddit", "reddit"),
            ("Discord", "discord"),
            ("Uber", "uber"),
            ("Lyft", "lyft"),
            ("DoorDash", "doordash"),
            ("Uber Eats", "ubereats"),
            ("Gmail", "googlegmail"),
            ("Slack", "slack"),
            ("Zoom", "zoomus"),
            ("Maps", "maps"),
            ("Google Maps", "comgooglemaps"),
            ("Waze", "waze"),
            ("Signal", "sgnl"),
            ("Messenger", "fb-messenger"),
            ("FaceTime", "facetime"),
            ("Shazam", "shazam"),
            ("Notion", "notion"),
            ("ChatGPT", "chatgpt"),
            ("Claude", "claude"),
            ("Gemini", "gemini"),
            ("Music", "music"),
            ("Podcasts", "podcasts"),
            ("News", "news"),
            ("Translate", "translate")
        ]
        
        for app in knownApps {
            let urlString = "\(app.scheme)://"
            guard let url = URL(string: urlString),
                  UIApplication.shared.canOpenURL(url) else {
                continue
            }
            
            shortcuts.append(GigiShortcut(
                name: "Open \(app.name)",
                type: .openApp,
                targetID: app.scheme,
                metadata: ["app": app.name]
            ))
        }
        
        print("GIGI Shortcuts: Generated shortcuts for installed apps")
    }
    
    // MARK: - Trova shortcut
    func findShortcut(for text: String) -> GigiShortcut? {
        let lower = text.lowercased()
        
        // Match esatto sul nome
        if let exact = shortcuts.first(where: { $0.name.lowercased() == lower }) {
            return exact
        }
        
        // Match parziale — cerca keywords
        let keywords = extractKeywords(from: lower)
        
        for shortcut in shortcuts {
            let shortcutWords = shortcut.name.lowercased().components(separatedBy: .whitespaces)
            
            // Se tutti i keywords matchano
            if keywords.allSatisfy({ kw in shortcutWords.contains(where: { $0.contains(kw) }) }) {
                return shortcut
            }
        }
        
        // Match fuzzy sul contatto
        if let contact = extractContact(from: lower) {
            // Prova varianti
            let variants = [
                "Call \(contact)",
                "Message \(contact)",
                "WhatsApp \(contact)",
                "Telegram \(contact)"
            ]
            
            for _ in variants {
                if let match = shortcuts.first(where: {
                    $0.name.lowercased().contains(contact.lowercased())
                }) {
                    return match
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Esegui shortcut
    func execute(_ shortcut: GigiShortcut, message: String? = nil) async -> Bool {
        print("GIGI Shortcuts: Executing \(shortcut.name)")
        
        switch shortcut.type {
        case .call:
            let who = shortcut.metadata["contact"] ?? ""
            if who.isEmpty {
                let url = URL(string: "tel://\(shortcut.targetID)")!
                await UIApplication.shared.open(url)
            } else {
                _ = await GigiActionBridge.shared.makeCallWithIntent(to: who)
            }
            return true
            
        case .message:
            let encoded = (message ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let urlString = message == nil
                ? "sms:\(shortcut.targetID)"
                : "sms:\(shortcut.targetID)&body=\(encoded)"
            if let url = URL(string: urlString) {
                await UIApplication.shared.open(url)
            }
            return true
            
        case .whatsappMessage:
            let encoded = (message ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let urlString = message == nil
                ? "whatsapp://send?phone=\(shortcut.targetID)"
                : "whatsapp://send?phone=\(shortcut.targetID)&text=\(encoded)"
            if let url = URL(string: urlString) {
                await UIApplication.shared.open(url)
            }
            return true
            
        case .telegramMessage:
            let encoded = (message ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let urlString = message == nil
                ? "tg://msg?to=\(shortcut.targetID)"
                : "tg://msg?to=\(shortcut.targetID)&text=\(encoded)"
            if let url = URL(string: urlString) {
                await UIApplication.shared.open(url)
            }
            return true
            
        case .openApp:
            let url = URL(string: "\(shortcut.targetID)://")!
            await UIApplication.shared.open(url)
            return true
            
        case .email:
            var components = URLComponents(string: "mailto:\(shortcut.targetID)")!
            if let message = message {
                components.queryItems = [URLQueryItem(name: "body", value: message)]
            }
            if let url = components.url {
                await UIApplication.shared.open(url)
            }
            return true
            
        case .navigate:
            let encoded = shortcut.targetID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let url = URL(string: "maps://?daddr=\(encoded)")!
            await UIApplication.shared.open(url)
            return true
        }
    }
    
    // MARK: - Helpers
    private func extractKeywords(from text: String) -> [String] {
        let stopwords = ["the", "a", "an", "to", "on", "in", "at", "for", "and", "or"]
        return text.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty && !stopwords.contains($0) }
    }
    
    private func extractContact(from text: String) -> String? {
        let triggers = ["call", "message", "text", "whatsapp", "telegram", "email"]
        for trigger in triggers {
            if let range = text.range(of: trigger) {
                let remainder = String(text[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                let words = remainder.components(separatedBy: .whitespaces)
                if let first = words.first, !first.isEmpty {
                    return first.capitalized
                }
            }
        }
        return nil
    }
    
    // MARK: - Cache
    private func saveToCache() {
        do {
            let data = try JSONEncoder().encode(shortcuts)
            try data.write(to: cacheURL)
            print("GIGI Shortcuts: Cached \(shortcuts.count) shortcuts")
        } catch {
            print("GIGI Shortcuts: Cache save error — \(error)")
        }
    }
    
    private func loadFromCache() {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        do {
            let data = try Data(contentsOf: cacheURL)
            shortcuts = try JSONDecoder().decode([GigiShortcut].self, from: data)
            print("GIGI Shortcuts: Loaded \(shortcuts.count) from cache")
        } catch {
            print("GIGI Shortcuts: Cache load error — \(error)")
        }
    }
    
    // MARK: - Stats
    func getStats() -> String {
        let byType = Dictionary(grouping: shortcuts, by: { $0.type })
        var stats = "GIGI Shortcuts: \(shortcuts.count) total\n"
        for (type, list) in byType.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            stats += "  \(type.rawValue): \(list.count)\n"
        }
        return stats
    }
}
