import Foundation

// MARK: - UserProfileData
// All data GIGI needs to fill forms autonomously: checkout, booking, registration, etc.

struct UserProfileData {
    var name: String = ""
    var firstName: String { name.components(separatedBy: " ").first ?? name }
    var lastName:  String { name.components(separatedBy: " ").dropFirst().joined(separator: " ") }
    var email: String = ""
    var phone: String = ""
    var deliveryAddress: String = ""
    var city: String = ""
    var zip: String = ""
    var state: String = ""
    var country: String = "US"
    var cardLast4: String = ""
    var cardExpiry: String = ""
    var cardHolder: String = ""
    var preferApplePay: Bool = true
}

// MARK: - GigiUserProfile
// Singleton. Non-sensitive fields → GigiMemory (iCloud sync). Card data → Keychain only.

final class GigiUserProfile {
    static let shared = GigiUserProfile()
    private init() {}

    private enum MemKey {
        static let name            = "pref:nome"
        static let email           = "pref:email"
        static let phone           = "pref:telefono"
        static let deliveryAddress = "pref:indirizzo_consegna"
        static let city            = "pref:citta"
        static let zip             = "pref:cap"
        static let state           = "pref:stato"
        static let country         = "pref:paese"
        static let preferApplePay  = "pref:apple_pay"
    }

    private enum KCKey {
        static let cardLast4  = "gigi.card.last4"
        static let cardExpiry = "gigi.card.expiry"
        static let cardHolder = "gigi.card.holder"
        static let cardCVV    = "gigi.card.cvv"
    }

    // MARK: - Load / Save

    func load() async -> UserProfileData {
        let m = GigiMemory.shared
        var p = UserProfileData()
        p.name            = await m.recall(MemKey.name)            ?? ""
        p.email           = await m.recall(MemKey.email)           ?? ""
        p.phone           = await m.recall(MemKey.phone)           ?? ""
        p.deliveryAddress = await m.recall(MemKey.deliveryAddress) ?? ""
        p.city            = await m.recall(MemKey.city)            ?? ""
        p.zip             = await m.recall(MemKey.zip)             ?? ""
        p.state           = await m.recall(MemKey.state)           ?? ""
        p.country         = await m.recall(MemKey.country)         ?? "US"
        p.preferApplePay  = (await m.recall(MemKey.preferApplePay) ?? "true") != "false"
        p.cardLast4       = GigiKeychain.load(forKey: KCKey.cardLast4)  ?? ""
        p.cardExpiry      = GigiKeychain.load(forKey: KCKey.cardExpiry) ?? ""
        p.cardHolder      = GigiKeychain.load(forKey: KCKey.cardHolder) ?? ""
        if p.cardHolder.isEmpty { p.cardHolder = p.name }
        return p
    }

    func save(_ p: UserProfileData) async {
        let m = GigiMemory.shared
        let pairs: [(String, String)] = [
            (MemKey.name,            p.name),
            (MemKey.email,           p.email),
            (MemKey.phone,           p.phone),
            (MemKey.deliveryAddress, p.deliveryAddress),
            (MemKey.city,            p.city),
            (MemKey.zip,             p.zip),
            (MemKey.state,           p.state),
            (MemKey.country,         p.country),
            (MemKey.preferApplePay,  p.preferApplePay ? "true" : "false"),
        ]
        for (key, val) in pairs where !val.isEmpty {
            await m.remember(key: key, value: val)
        }
        if !p.cardLast4.isEmpty  { GigiKeychain.save(p.cardLast4,  forKey: KCKey.cardLast4) }
        if !p.cardExpiry.isEmpty { GigiKeychain.save(p.cardExpiry, forKey: KCKey.cardExpiry) }
        if !p.cardHolder.isEmpty { GigiKeychain.save(p.cardHolder, forKey: KCKey.cardHolder) }
    }

    func saveCVV(_ cvv: String) { GigiKeychain.save(cvv, forKey: KCKey.cardCVV) }
    func loadCVV() -> String    { GigiKeychain.load(forKey: KCKey.cardCVV) ?? "" }

    // MARK: - Learn from conversation
    // Call when user says "my address is..." or "my email is..." during onboarding or chat.

    func learnFromText(_ text: String) async {
        let t = text.lowercased()
        let m = GigiMemory.shared

        let patterns: [(String, String)] = [
            ("(?:my (?:name|sono|mi chiamo) (?:is )?)(\\S+ \\S+)", MemKey.name),
            ("(?:my email (?:is )?|email: ?)([\\w.]+@[\\w.]+)", MemKey.email),
            ("(?:my (?:phone|number) (?:is )?|phone: ?)(\\+?[\\d\\s\\-]{7,})", MemKey.phone),
            ("(?:my (?:address|indirizzo) (?:is )?|address: ?)(.+)", MemKey.deliveryAddress),
            ("(?:my city (?:is )?|city: ?)([\\w ]+)", MemKey.city),
            ("(?:zip (?:code )?(?:is )?|zip: ?)(\\d{4,10})", MemKey.zip),
        ]
        for (pattern, key) in patterns {
            if let range = t.range(of: pattern, options: .regularExpression),
               let match = t[range].components(separatedBy: " ").dropFirst().first {
                let value = match.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { await m.remember(key: key, value: value) }
            }
        }
    }

    // MARK: - Form context for LLM

    func formContext() async -> String {
        let p = await load()
        var lines: [String] = []
        if !p.name.isEmpty            { lines.append("full name: \(p.name)") }
        if !p.email.isEmpty           { lines.append("email: \(p.email)") }
        if !p.phone.isEmpty           { lines.append("phone: \(p.phone)") }
        if !p.deliveryAddress.isEmpty { lines.append("street: \(p.deliveryAddress)") }
        if !p.city.isEmpty            { lines.append("city: \(p.city)") }
        if !p.zip.isEmpty             { lines.append("zip: \(p.zip)") }
        if !p.state.isEmpty           { lines.append("state: \(p.state)") }
        if !p.country.isEmpty         { lines.append("country: \(p.country)") }
        if !p.cardLast4.isEmpty       { lines.append("card ending: \(p.cardLast4), exp: \(p.cardExpiry), holder: \(p.cardHolder)") }
        if lines.isEmpty { return "" }
        return "User profile (use to fill forms):\n" + lines.joined(separator: "\n")
    }
}
