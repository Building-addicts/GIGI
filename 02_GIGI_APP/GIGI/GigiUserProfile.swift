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

// MARK: - MVPPreferences
// Tipa le 7 preferenze "soft" iniettate nei prompt LLM (tono, ore lavoro, focus
// mattutino, contatti VIP, buffer viaggio, food, routine). Persistite via
// GigiMemory con prefisso `pref:mvp_*` (round-trip CSV per gli array).

struct MVPPreferences: Codable, Equatable {
    var communicationTone: String      // "warm" | "casual" | "professional"
    var workHours: String              // es. "09:00-18:00"
    var morningFocus: Bool             // deep work al mattino
    var vipContacts: [String]          // ["Fede", "Marco", "mamma"]
    var travelBufferMinutes: Int       // minuti buffer per spostamenti
    var foodPreference: String         // es. "vegetariano"
    var routineHints: [String]         // ["palestra 7am", "lunch 13:00"]

    static let empty = MVPPreferences(
        communicationTone: "",
        workHours: "",
        morningFocus: false,
        vipContacts: [],
        travelBufferMinutes: 20,
        foodPreference: "",
        routineHints: []
    )
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

        // MVP soft preferences (sub-issue #50). Tutte prefisso `pref:mvp_*`
        // così `GigiMemory.inferredCategory` ritorna "pref".
        static let mvpTone         = "pref:mvp_tone"
        static let mvpWorkHours    = "pref:mvp_work_hours"
        static let mvpMorningFocus = "pref:mvp_morning_focus"
        static let mvpVip          = "pref:mvp_vip_contacts"
        static let mvpBuffer       = "pref:mvp_travel_buffer_min"
        static let mvpFood         = "pref:mvp_food_preference"
        static let mvpRoutine      = "pref:mvp_routine_hints"
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

    // MARK: - MVP Preferences (sub-issue #50)
    // Solo schema + persistenza. Seed JSON e injection nei prompt LLM
    // arrivano nelle sub 2/3 e 3/3 di #13.

    func loadMVPPreferences() async -> MVPPreferences {
        let m = GigiMemory.shared
        let tone        = await m.recall(MemKey.mvpTone)         ?? ""
        let hours       = await m.recall(MemKey.mvpWorkHours)    ?? ""
        let morningRaw  = await m.recall(MemKey.mvpMorningFocus) ?? "false"
        let vipRaw      = await m.recall(MemKey.mvpVip)          ?? ""
        let bufferRaw   = await m.recall(MemKey.mvpBuffer)       ?? ""
        let food        = await m.recall(MemKey.mvpFood)         ?? ""
        let routineRaw  = await m.recall(MemKey.mvpRoutine)      ?? ""

        return MVPPreferences(
            communicationTone:   tone,
            workHours:           hours,
            morningFocus:        morningRaw == "true",
            vipContacts:         Self.decodeCSV(vipRaw),
            travelBufferMinutes: Int(bufferRaw) ?? 20,
            foodPreference:      food,
            routineHints:        Self.decodeCSV(routineRaw)
        )
    }

    func saveMVPPreferences(_ p: MVPPreferences) async {
        let m = GigiMemory.shared
        let pairs: [(String, String)] = [
            (MemKey.mvpTone,         p.communicationTone),
            (MemKey.mvpWorkHours,    p.workHours),
            (MemKey.mvpMorningFocus, p.morningFocus ? "true" : "false"),
            (MemKey.mvpVip,          Self.encodeCSV(p.vipContacts)),
            (MemKey.mvpBuffer,       String(p.travelBufferMinutes)),
            (MemKey.mvpFood,         p.foodPreference),
            (MemKey.mvpRoutine,      Self.encodeCSV(p.routineHints)),
        ]
        for (key, val) in pairs {
            await m.remember(key: key, value: val)
        }
    }

    // CSV codec: GigiMemory è key-value String puro, niente JSON.
    // Le virgole interne vengono escapate come `\,` per round-trip integro.
    private static func encodeCSV(_ items: [String]) -> String {
        items
            .map { $0.replacingOccurrences(of: "\\", with: "\\\\")
                     .replacingOccurrences(of: ",", with: "\\,") }
            .joined(separator: ",")
    }

    private static func decodeCSV(_ raw: String) -> [String] {
        guard !raw.isEmpty else { return [] }
        var out: [String] = []
        var current = ""
        var escape = false
        for ch in raw {
            if escape {
                current.append(ch)
                escape = false
            } else if ch == "\\" {
                escape = true
            } else if ch == "," {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        out.append(current.trimmingCharacters(in: .whitespaces))
        return out.filter { !$0.isEmpty }
    }

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

#if DEBUG
extension GigiUserProfile {
    // Round-trip test per AC5: save(p) → load() == p su tutti i 7 campi.
    // Trigger via debug commands (es. messaggio chat `__debug_save_mvp_prefs__`).
    @discardableResult
    func _debugMVPRoundTrip() async -> Bool {
        let sample = MVPPreferences(
            communicationTone:   "warm",
            workHours:           "09:00-18:00",
            morningFocus:        true,
            vipContacts:         ["Fede", "Marco, Jr.", "mamma"],
            travelBufferMinutes: 25,
            foodPreference:      "vegetariano",
            routineHints:        ["palestra 7am", "lunch 13:00"]
        )
        await saveMVPPreferences(sample)
        let loaded = await loadMVPPreferences()
        let ok = (loaded == sample)
        print("[GIGI Memory] MVPPreferences round-trip: \(ok ? "OK" : "FAIL") | loaded=\(loaded)")
        return ok
    }
}
#endif
