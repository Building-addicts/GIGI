import Foundation
import Contacts

// MARK: - GigiContactsEngine (T-19)
//
// Fuzzy contact resolution from CNContactStore. Understands nicknames, relationships,
// partial names, and common relationship aliases. Disambiguation via TTS + follow-up.

@MainActor
final class GigiContactsEngine {
    static let shared = GigiContactsEngine()

    private let store = CNContactStore()
    private var cache: [CNContact] = []
    private var cacheLoaded = false

    // Relationship map: common aliases → relationship key
    private let relationshipMap: [String: String] = [
        "mamma": "mother", "mama": "mother", "mam": "mother", "mom": "mother",
        "papà": "father", "papa": "father", "dad": "father",
        "fratello": "brother", "bro": "brother",
        "sorella": "sister", "sis": "sister",
        "nonno": "grandfather", "grandpa": "grandfather",
        "nonna": "grandmother", "grandma": "grandmother",
        "moglie": "spouse", "marito": "spouse", "wife": "spouse", "husband": "spouse",
        "fidanzata": "partner", "fidanzato": "partner", "girlfriend": "partner", "boyfriend": "partner",
        "figlio": "child", "figlia": "child", "son": "child", "daughter": "child",
        "zio": "uncle", "zia": "aunt",
    ]

    private init() {}

    // MARK: - Public API

    /// Resolves a natural language name/relationship to a phone number string.
    /// Returns (phoneNumber, displayName) or nil if not found/ambiguous.
    func resolve(_ query: String) async -> (phone: String, name: String)? {
        await ensureCache()
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        GigiDebugLogger.log("GIGI Contacts.resolve: query='\(query)' normalized='\(q)' cacheSize=\(cache.count)")

        // 1. Check long-term memory first (fastest, most reliable)
        if let memorized = await GigiMemory.shared.recallResolving(q) {
            // Memory value might be "fratello, +39 333 123 4567" — extract phone
            if let phone = extractPhone(from: memorized) {
                let name = extractName(from: memorized, fallback: query)
                return (phone, name)
            }
        }

        // 2. Relationship words
        for (word, _) in relationshipMap {
            if q == word || q.hasPrefix(word + " ") || q.hasSuffix(" " + word) {
                if let contact = findByRelationshipLabel(word) {
                    return phoneAndName(from: contact)
                }
            }
        }

        // 3. Exact + fuzzy name match
        let matches = findByName(q)
        if matches.count == 1 {
            return phoneAndName(from: matches[0])
        }
        if matches.count > 1 {
            // Return the most-used one (prefer contacts with more calls in memory)
            let sorted = await sortByMemoryUsage(matches)
            return phoneAndName(from: sorted[0])
        }

        // 4. Nickname search (notes require extra Contacts entitlement on recent iOS)
        if let contact = findByNickname(q) {
            return phoneAndName(from: contact)
        }

        return nil
    }

    /// Returns all contacts matching a query — for disambiguation UI.
    func disambiguate(_ query: String) async -> [(phone: String, name: String)] {
        await ensureCache()
        let q = query.lowercased()
        return findByName(q).compactMap { phoneAndName(from: $0) }
    }

    // MARK: - Cache management

    private func ensureCache() async {
        guard !cacheLoaded else { return }
        let s = store
        let authStatus = CNContactStore.authorizationStatus(for: .contacts)
        GigiDebugLogger.log("GIGI Contacts.ensureCache: starting · auth=\(authStatus.rawValue) [0=notDetermined 1=restricted 2=denied 3=authorized 4=limited]")

        let contacts: [CNContact] = await Task.detached(priority: .userInitiated) {
            // Omit CNContactNoteKey — iOS 18+ requires separate authorization; causes CNError 102 Unauthorized Keys.
            let keys: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactNicknameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactRelationsKey as CNKeyDescriptor,
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var result: [CNContact] = []
            var enumerateError: Error?
            do {
                try s.enumerateContacts(with: request) { contact, _ in
                    if !contact.phoneNumbers.isEmpty { result.append(contact) }
                }
            } catch {
                enumerateError = error
            }
            if let err = enumerateError {
                Self.bgLog("GIGI Contacts.ensureCache ERROR enumerate: \(err.localizedDescription)")
            }
            Self.bgLog("GIGI Contacts.ensureCache loaded \(result.count) contacts with phone numbers")
            return result
        }.value
        cache = contacts
        cacheLoaded = true
        // Sample first 5 names for quick visual debug
        let preview = contacts.prefix(5).map { "\($0.givenName) \($0.familyName)" }.joined(separator: " | ")
        GigiDebugLogger.log("GIGI Contacts cache sample: \(preview)")
    }

    // Background-safe logger (Task.detached can't call MainActor-only types).
    nonisolated private static func bgLog(_ msg: String) {
        // GigiDebugLogger is class-level (no actor) so safe to call from any context.
        GigiDebugLogger.log(msg)
    }

    func invalidateCache() {
        cacheLoaded = false
        cache = []
    }

    // MARK: - Search helpers

    private func findByName(_ query: String) -> [CNContact] {
        let q = query.lowercased()
        var exact: [CNContact] = []
        var partial: [CNContact] = []

        for c in cache {
            let fullName = "\(c.givenName) \(c.familyName)".lowercased().trimmingCharacters(in: .whitespaces)
            let given = c.givenName.lowercased()
            let family = c.familyName.lowercased()

            if fullName == q || given == q || family == q {
                exact.append(c)
            } else if fullName.contains(q) || given.contains(q) || family.contains(q) {
                partial.append(c)
            } else if levenshteinDistance(q, fullName) <= 2 || levenshteinDistance(q, given) <= 1 {
                partial.append(c)
            }
        }

        return exact.isEmpty ? partial : exact
    }

    private func findByRelationshipLabel(_ query: String) -> CNContact? {
        let q = query.lowercased()
        for c in cache {
            for rel in c.contactRelations {
                let label = (rel.label ?? "").lowercased()
                if label.contains(q) {
                    return c
                }
                // Check mapped relationships
                if let mapped = relationshipMap[q], label.contains(mapped) {
                    return c
                }
            }
        }
        return nil
    }

    private func findByNickname(_ query: String) -> CNContact? {
        let q = query.lowercased()
        for c in cache {
            if c.nickname.lowercased().contains(q) { return c }
        }
        return nil
    }

    private func phoneAndName(from contact: CNContact) -> (phone: String, name: String)? {
        guard let phone = contact.phoneNumbers.first?.value.stringValue else { return nil }
        let name = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }.joined(separator: " ")
        return (sanitize(phone), name)
    }

    private func sanitize(_ phone: String) -> String {
        phone.filter { "0123456789+*#".contains($0) }
    }

    private func extractPhone(from text: String) -> String? {
        let pattern = #"[\+\d][\d\s\-\(\)]{6,}"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        let raw = String(text[range])
        let digits = raw.filter { "0123456789+".contains($0) }
        return digits.count >= 7 ? digits : nil
    }

    private func extractName(from text: String, fallback: String) -> String {
        // "fratello, +39 333..." → take the part before the comma/phone
        if let commaIdx = text.firstIndex(of: ",") {
            let name = String(text[text.startIndex..<commaIdx]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return fallback
    }

    private func sortByMemoryUsage(_ contacts: [CNContact]) async -> [CNContact] {
        var scored: [(CNContact, Int)] = []
        for c in contacts {
            let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let key = "contact:\(name.lowercased())"
            let count = await GigiMemory.shared.useCount(for: key)
            scored.append((c, count))
        }
        return scored.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    // MARK: - Levenshtein distance

    private func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }
        for i in 1...m {
            for j in 1...n {
                dp[i][j] = a[i-1] == b[j-1]
                    ? dp[i-1][j-1]
                    : 1 + min(dp[i-1][j], dp[i][j-1], dp[i-1][j-1])
            }
        }
        return dp[m][n]
    }
}
