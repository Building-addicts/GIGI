import Foundation
import CloudKit

// MARK: - GigiMemory
//
// Persistent user profile backed by iCloud private database.
// In-memory cache ensures instant reads — CloudKit syncs asynchronously.
//
// Key conventions:
//   contact:<name>   → phone number / relationship  (e.g. "contact:Marco" = "+39 333 123 4567, fratello")
//   routine:<name>   → time + days                  (e.g. "routine:sveglia" = "7:30, weekdays")
//   pref:<name>      → preference value             (e.g. "pref:ristorante" = "giapponese")
//   place:<name>     → address                      (e.g. "place:casa" = "Via Roma 5, Milano")
//   person:<name>    → name resolution              (e.g. "person:mamma" = "Giovanna Rossi")

final class GigiMemory {
    static let shared = GigiMemory()

    /// Default container Xcode uses: `iCloud.<CFBundleIdentifier>`. Must match Signing & Capabilities → iCloud.
    private static var cloudContainerID: String {
        guard let bid = Bundle.main.bundleIdentifier, !bid.isEmpty else { return "" }
        return "iCloud.\(bid)"
    }

    private var container: CKContainer?
    private var db: CKDatabase? { container?.privateCloudDatabase }
    private var cache: [String: String] = [:]
    /// Mirrors CloudKit `useCount` for keys in `cache` (best-effort for `mostUsed` offline).
    private var useCountByKey: [String: Int64] = [:]
    private var iCloudAvailable = false
    private var bootstrapped = false

    // MARK: - Local disk persistence (CloudKit-independent)
    //
    // CloudKit container deployment is pending (see bootstrap() bypass), so
    // memory used to evaporate on app restart. The disk layer persists the
    // RAM cache to a JSON file in Application Support, independent of any
    // CloudKit availability. When CloudKit is later enabled, the disk file
    // remains the source of truth at launch and CloudKit overlays via loadAll().

    private struct DiskRow: Codable {
        let value: String
        let useCount: Int64
    }

    private var pendingSaveTask: Task<Void, Never>?
    private static let diskFilename = "gigi-memory.json"
    private static let diskSaveDebounceNs: UInt64 = 500_000_000  // 500ms

    private init() {
        GigiDebugLogger.log("GigiMemory init started")
        // CKContainer(identifier:) raises an uncatchable Objective-C exception
        // ("You must call …with a container identifier registered in your
        // application's entitlements") when the iCloud entitlement is missing
        // — which happens on the Simulator without an iCloud account, or
        // when Sideloadly with a free Apple ID strips the iCloud capability.
        // Defer container creation to bootstrap() and guard it with
        // FileManager.ubiquityIdentityToken (non-crashing API that returns
        // nil exactly when CKContainer would crash).
        container = nil
        Task { await bootstrap() }
        GigiDebugLogger.log("GigiMemory init finished")
    }

    /// Maps key prefix to `GigiMemory.category` values (contact, routine, pref, place, context).
    private static func inferredCategory(forKey key: String) -> String {
        let k = key.lowercased()
        if k.hasPrefix("contact:") { return "contact" }
        if k.hasPrefix("routine:") { return "routine" }
        if k.hasPrefix("pref:") { return "pref" }
        if k.hasPrefix("place:") { return "place" }
        if k.hasPrefix("person:") { return "context" }
        return "context"
    }

    // MARK: - Disk persistence helpers

    private static func diskURL() -> URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return dir.appendingPathComponent(diskFilename)
    }

    /// Synchronous JSON load. Called once at the very start of bootstrap()
    /// BEFORE any CloudKit gate, so persistence works on Simulator, sideload
    /// with free Apple ID, and any device with iCloud disabled.
    private func loadCacheFromDisk() {
        guard let url = Self.diskURL(),
              FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let rows = try JSONDecoder().decode([String: DiskRow].self, from: data)
            for (k, row) in rows {
                cache[k] = row.value
                useCountByKey[k] = row.useCount
            }
            GigiDebugLogger.log("GIGI Memory: loaded \(rows.count) row(s) from disk")
        } catch {
            GigiDebugLogger.log("GIGI Memory: disk load error — \(error.localizedDescription)")
        }
    }

    /// Debounced async write. Coalesces bursts of mutations (e.g. CloudKit
    /// bulk hydrate) into a single file rewrite.
    private func scheduleSaveToDisk() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.diskSaveDebounceNs)
            guard !Task.isCancelled else { return }
            self?.writeCacheToDisk()
        }
    }

    private func writeCacheToDisk() {
        guard let url = Self.diskURL() else { return }
        var rows: [String: DiskRow] = [:]
        for (k, v) in cache {
            rows[k] = DiskRow(value: v, useCount: useCountByKey[k] ?? 0)
        }
        do {
            let data = try JSONEncoder().encode(rows)
            try data.write(to: url, options: [.atomic])
            GigiDebugLogger.log("GIGI Memory: persisted \(rows.count) row(s) to disk")
        } catch {
            GigiDebugLogger.log("GIGI Memory: disk save error — \(error.localizedDescription)")
        }
    }

    // MARK: - Bootstrap

    /// Suspends until bootstrap() has finished (success, fallback, or failure).
    /// Safe to call repeatedly — no-op once ready. Required before reading
    /// CloudKit-persisted keys at app launch (e.g. seed idempotency markers),
    /// since cache is empty until loadAll() inside bootstrap() populates it.
    func awaitReady() async {
        while !bootstrapped {
            try? await Task.sleep(nanoseconds: 25_000_000) // 25ms
        }
    }

    private func bootstrap() async {
        defer { bootstrapped = true }
        // 0. Always hydrate cache from local disk first — independent of
        // iCloud entitlements, bundle ID rewrites, or container deployment.
        // This is the source of truth at launch; CloudKit (when available)
        // overlays via loadAll() further down.
        loadCacheFromDisk()
        // 1. We need a non-empty container identifier.
        guard !Self.cloudContainerID.isEmpty else {
            GigiDebugLogger.log("GIGI Memory: no bundle ID — local-only mode")
            return
        }
        // 2. Detect Sideloadly bundle-ID rewrite (it appends .<TEAMID>).
        // Original: com.killsiri.GIGI (3 parts) → resigned: com.killsiri.GIGI.X3KM3AL65P (4 parts).
        // The iCloud entitlement registered in the app is for the ORIGINAL
        // container "iCloud.com.killsiri.GIGI", but cloudContainerID derived
        // from Bundle.main becomes "iCloud.com.killsiri.GIGI.X3KM3AL65P" — mismatch
        // → CKContainer(identifier:) raises an uncatchable NSException.
        // Skip CloudKit entirely on resigned builds (free Apple ID sideload).
        let bid = Bundle.main.bundleIdentifier ?? ""
        let bundleParts = bid.split(separator: ".").count
        if bundleParts > 3 {
            GigiDebugLogger.log("GIGI Memory: bundle ID resigned (\(bid), \(bundleParts) parts) — local-only mode")
            return
        }
        // 3. ubiquityIdentityToken is the safe gate: returns non-nil only when
        // iCloud is available AND the app has the iCloud entitlement.
        // Returns nil (without raising) on Simulator with no iCloud account.
        guard FileManager.default.ubiquityIdentityToken != nil else {
            GigiDebugLogger.log("GIGI Memory: iCloud unavailable (no ubiquity token) — local-only mode")
            return
        }
        // TEMPORARY BYPASS (rework armando-rework, 2026-05-08):
        // CKContainer(identifier:) raises an uncatchable NSException when the
        // container `iCloud.com.killsiri.GIGI` is listed in entitlements but
        // NOT yet created/deployed in CloudKit Dashboard for team R5N92QSPQ6.
        // The app crashes at launch on first install. We skip the CKContainer
        // init entirely; memory falls back to RAM-cache local-only mode.
        // Remove this guard once the container is verified to exist in
        // https://icloud.developer.apple.com → Containers.
        GigiDebugLogger.log("GIGI Memory: CloudKit container init bypassed (rework v1) — local-only mode")
        return

        // 4. Now safe to construct the container.
        let container = CKContainer(identifier: Self.cloudContainerID)
        self.container = container
        do {
            let status = try await container.accountStatus()
            iCloudAvailable = (status == .available)
            if iCloudAvailable {
                await loadAll()
                GigiDebugLogger.log("GIGI Memory: CloudKit ready (\(cache.count) records cached) ✓")
            } else {
                GigiDebugLogger.log("GIGI Memory: iCloud not available (status: \(status.rawValue)) — using local cache only")
            }
        } catch {
            GigiDebugLogger.log("GIGI Memory: bootstrap error — \(error.localizedDescription)")
        }
    }

    // MARK: - Remember

    /// Persists a memory row. `category` defaults from the key prefix (`contact:`, `pref:`, …).
    func remember(key: String, value: String, category: String? = nil) async {
        let normalizedKey = key.lowercased().trimmingCharacters(in: .whitespaces)
        let cat = (category?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.inferredCategory(forKey: normalizedKey)
        cache[normalizedKey] = value
        guard iCloudAvailable else {
            useCountByKey[normalizedKey] = (useCountByKey[normalizedKey] ?? 0) + 1
            scheduleSaveToDisk()
            return
        }

        let recordID = CKRecord.ID(recordName: normalizedKey)
        do {
            // Fetch existing record if present (to preserve useCount)
            let existing = try? await db?.record(for: recordID)
            let record   = existing ?? CKRecord(recordType: "GigiMemory", recordID: recordID)
            record["key"]       = normalizedKey
            record["value"]     = value
            record["category"]  = cat
            record["lastUsed"]  = Date()
            let newCount = ((record["useCount"] as? Int64) ?? 0) + 1
            record["useCount"]  = newCount
            useCountByKey[normalizedKey] = newCount
            scheduleSaveToDisk()
            guard let db = db else { return }
            try await db.save(record)
            GigiDebugLogger.log("GIGI Memory: saved '\(normalizedKey)' [\(cat)] = '\(value.prefix(40))'")
        } catch {
            if let ck = error as? CKError, ck.code == .quotaExceeded {
                iCloudAvailable = false
                GigiDebugLogger.log("GIGI Memory: iCloud quota exceeded — falling back to local cache only. Free up iCloud storage to re-enable.")
            } else {
                GigiDebugLogger.log("GIGI Memory: save error — \(error.localizedDescription)")
            }
        }
        // Keep vector store in sync (async, non-blocking)
        GigiVectorStore.shared.upsert(key: normalizedKey, value: value)
    }

    // MARK: - Key parsing & resolution (orchestrator / NLU)

    /// Entity-aware recall: search the cache for an entry whose key
    /// content-tokens overlap with the query text. Used to catch recalls
    /// that NLU triggers can't anticipate ("what my password", "tell me
    /// the wifi password", "the netflix password please") — any phrasing
    /// where the user names a known entity counts as recall.
    ///
    /// Returns the best (key, value) by Jaccard score, or nil if no
    /// cache entry passes the threshold.
    func findByContentMatch(in text: String) async -> (key: String, value: String)? {
        let qTokens = Self.contentTokens(text)
        guard !qTokens.isEmpty else { return nil }
        var best: (key: String, value: String, score: Float)?
        for (k, v) in cache {
            if k.hasPrefix("contact_alias:") { continue }
            let keySuffix = k.split(separator: ":", maxSplits: 1).last.map(String.init)?.lowercased() ?? k.lowercased()
            let kTokens = Self.contentTokens(keySuffix)
            guard !kTokens.isEmpty else { continue }
            let inter = Float(qTokens.intersection(kTokens).count)
            let union = Float(qTokens.union(kTokens).count)
            let jaccard = inter / union
            // Require ALL of the key's tokens to appear in the query — so
            // "what my password" (qTokens={password}) finds key
            // "my password" (kTokens={password}) but NOT key
            // "my password for netflix" (kTokens={password, netflix}).
            // Prevents over-matching on partial overlaps.
            let keyCovered = qTokens.intersection(kTokens).count == kTokens.count
            guard keyCovered, jaccard >= 0.5 else { continue }
            if best == nil || jaccard > best!.score {
                best = (k, v, jaccard)
            }
        }
        return best.map { ($0.key, $0.value) }
    }

    private static let recallStopWords: Set<String> = [
        // EN
        "a","an","the","is","are","was","were","be","my","your","his","her","their","our","its",
        "of","in","on","at","to","for","with","by","from","as",
        "i","you","he","she","it","we","they","me","him","us","them",
        "this","that","these","those","there","here",
        "what","whats","who","whos","whose","which","why","how","when","where",
        "and","or","but","not","no","yes",
        "tell","know","about","mean","means"
    ]

    /// Lowercased, punctuation-stripped, stop-word-free token set. Used by
    /// `recallFuzzy` to do Jaccard matching that survives reordering
    /// ("my password for netflix" ↔ "my netflix password" both reduce to
    /// {password, netflix}).
    fileprivate static func contentTokens(_ text: String) -> Set<String> {
        let lowered = text.lowercased()
        let stripped = lowered.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == " " ? Character($0) : " "
        }
        let tokens = String(stripped).split(separator: " ").map(String.init)
        return Set(tokens.filter { !$0.isEmpty && !recallStopWords.contains($0) })
    }

    /// Flip first-person to second-person so GIGI speaks back from its
    /// own perspective. The user says "my password is hi124"; GIGI must
    /// say "your password is hi124" — otherwise it sounds like a message
    /// addressed to the user. Word-by-word transform, EN + IT.
    static func flipFirstPerson(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let punct: Set<Character> = [".", ",", ";", ":", "!", "?"]
        let flipped: [String] = words.map { word in
            // Preserve trailing punctuation and case heuristically.
            var trailing = ""
            var coreEnd = word.endIndex
            while coreEnd > word.startIndex {
                let prev = word.index(before: coreEnd)
                if punct.contains(word[prev]) {
                    trailing = String(word[prev]) + trailing
                    coreEnd = prev
                } else { break }
            }
            let core = word[word.startIndex..<coreEnd]
            let lower = core.lowercased()
            let mapped: String?
            switch lower {
            case "my":      mapped = "your"
            case "mine":    mapped = "yours"
            case "i":       mapped = "you"
            case "me":      mapped = "you"
            case "myself":  mapped = "yourself"
            case "i'm":     mapped = "you're"
            case "i've":    mapped = "you've"
            case "i'll":    mapped = "you'll"
            case "i'd":     mapped = "you'd"
            // IT
            case "mio":     mapped = "tuo"
            case "mia":     mapped = "tua"
            case "miei":    mapped = "tuoi"
            case "mie":     mapped = "tue"
            case "io":      mapped = "tu"
            case "mi":      mapped = "ti"
            default:        mapped = nil
            }
            guard let m = mapped else { return word }
            // Preserve capitalization of the first letter if the original was capitalized.
            let cased = core.first?.isUppercase == true
                ? m.prefix(1).uppercased() + m.dropFirst()
                : m
            return cased + trailing
        }
        return flipped.joined(separator: " ")
    }

    /// `contact:<name>` unless `contact` already contains `:`.
    static func contactKey(forName name: String) -> String {
        let slug = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else { return "" }
        return slug.contains(":") ? slug : "contact:\(slug)"
    }

    /// From NLU params: explicit `contact`+`body`, or body alone like "Marco è mio fratello".
    static func parseRememberKeyValue(contact: String, body: String) -> (key: String, value: String)? {
        let c = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.isEmpty, !b.isEmpty {
            let key = c.contains(":") ? c.lowercased() : Self.contactKey(forName: c)
            guard !key.isEmpty else { return nil }
            return (key, b)
        }
        guard !b.isEmpty else { return nil }
        let separators = [" è ", " È ", " e' ", " è", " = ", " is "]
        for sep in separators {
            guard let range = b.range(of: sep, options: .caseInsensitive) else { continue }
            var left = String(b[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let right = String(b[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if left.lowercased().hasPrefix("che ") {
                left = String(left.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard left.count >= 1, right.count >= 1 else { continue }
            let key = left.contains(":") ? left.lowercased() : Self.contactKey(forName: left)
            guard !key.isEmpty else { continue }
            return (key, right)
        }
        return ("pref:note", b)
    }

    /// Tries exact key, `contact:`, `person:`, then fuzzy prefix match.
    func recallResolving(_ rawQuery: String) async -> String? {
        let trimmed = rawQuery
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .init(charactersIn: "?.,;:!"))
        guard !trimmed.isEmpty else { return nil }
        let base = trimmed
            .replacingOccurrences(of: "^contact:", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^person:", with: "", options: .regularExpression)
        let candidates = [trimmed, Self.contactKey(forName: base), "person:\(base)"]
        var seen = Set<String>()
        for k in candidates where !k.isEmpty {
            if seen.insert(k).inserted, let v = await recall(k), !v.isEmpty { return v }
        }
        let fuzzy = await recallFuzzy(base)
        return fuzzy.first?.1
    }

    /// After a successful call, bumps `lastUsed` / `useCount` for `contact:<name>` if a row exists.
    func touchContactIfKnown(_ contactName: String) async {
        let key = Self.contactKey(forName: contactName)
        guard !key.isEmpty else { return }

        if cache[key] != nil {
            if iCloudAvailable {
                guard let db = db else { return }
                let recordID = CKRecord.ID(recordName: key)
                if let record = try? await db.record(for: recordID) {
                    await touch(record: record)
                }
            } else {
                useCountByKey[key] = (useCountByKey[key] ?? 0) + 1
                scheduleSaveToDisk()
            }
            return
        }

        guard iCloudAvailable else { return }
        let recordID = CKRecord.ID(recordName: key)
        guard let db = db else { return }
        guard let record = try? await db.record(for: recordID) else { return }
        if let v = record["value"] as? String {
            cache[key] = v
            useCountByKey[key] = (record["useCount"] as? Int64) ?? 0
            scheduleSaveToDisk()
        }
        await touch(record: record)
    }

    // MARK: - Contact alias (bug #017 — disambiguation memory)
    //
    // When the user says "Call Marco" and there are 2+ Marcos, GIGI presents
    // a sheet; after the user picks, the chosen full name is stored here so
    // the next "Call Marco" goes through silently. Alias key shape:
    //   "contact_alias:marco" → "Marco Rossi"
    // The full name is then re-resolved via Contacts (handles renames).

    func rememberContactAlias(query: String, name: String) async {
        let key = "contact_alias:\(query.lowercased().trimmingCharacters(in: .whitespaces))"
        await remember(key: key, value: name, category: "contact_alias")
    }

    func recallContactAlias(for query: String) async -> String? {
        let key = "contact_alias:\(query.lowercased().trimmingCharacters(in: .whitespaces))"
        return await recall(key)
    }

    func forgetContactAlias(query: String) async {
        let key = "contact_alias:\(query.lowercased().trimmingCharacters(in: .whitespaces))"
        cache.removeValue(forKey: key)
        useCountByKey.removeValue(forKey: key)
        scheduleSaveToDisk()
        // iCloud-side cleanup not done here (best-effort local only — alias
        // will simply be re-prompted on next ambiguity).
    }

    // MARK: - Recall

    func recall(_ key: String) async -> String? {
        let normalizedKey = key.lowercased().trimmingCharacters(in: .whitespaces)

        // Instant from cache
        if let cached = cache[normalizedKey] { return cached }

        // Try CloudKit if not in cache
        guard iCloudAvailable else { return nil }
        let recordID = CKRecord.ID(recordName: normalizedKey)
        do {
            guard let db = db else { return nil }
            let record  = try await db.record(for: recordID)
            let value   = record["value"] as? String ?? ""
            cache[normalizedKey] = value
            useCountByKey[normalizedKey] = (record["useCount"] as? Int64) ?? useCountByKey[normalizedKey] ?? 0
            scheduleSaveToDisk()
            // Update lastUsed
            Task { await self.touch(record: record) }
            return value.isEmpty ? nil : value
        } catch { return nil }
    }

    /// Returns the use count for a key (instant, from cache — no CloudKit round-trip).
    func useCount(for key: String) async -> Int {
        Int(useCountByKey[key.lowercased().trimmingCharacters(in: .whitespaces)] ?? 0)
    }

    // MARK: - Fuzzy recall (search by prefix or partial key)

    func recallFuzzy(_ query: String) async -> [(key: String, value: String)] {
        let q = query.lowercased()
        let qTokens = Self.contentTokens(q)
        // Score each cache entry: bidirectional substring (catches exact
        // prefix/suffix) PLUS Jaccard on content tokens (catches different
        // word order like "my password for netflix" vs "my netflix
        // password"). Best-scoring entries returned in descending order.
        var scored: [(key: String, value: String, score: Float)] = []
        for (k, v) in cache {
            if k.hasPrefix("contact_alias:") { continue }
            let keyLower = k.lowercased()
            let keySuffix = k.split(separator: ":", maxSplits: 1).last.map(String.init)?.lowercased() ?? keyLower
            let kTokens = Self.contentTokens(keySuffix)
            var score: Float = 0
            if keyLower.contains(q) || q.contains(keySuffix) { score += 1.0 }
            if !qTokens.isEmpty && !kTokens.isEmpty {
                let inter = Float(qTokens.intersection(kTokens).count)
                let union = Float(qTokens.union(kTokens).count)
                score += inter / union   // Jaccard 0…1
            }
            if score >= 0.5 {
                scored.append((k, v, score))
            }
        }
        if !scored.isEmpty {
            scored.sort { $0.score > $1.score }
            return scored.map { ($0.key, $0.value) }
        }
        // Then: CloudKit full-text (limited, only if cache empty)
        guard iCloudAvailable else { return [] }
        do {
            let pred    = NSPredicate(format: "key BEGINSWITH %@", q)
            let ckQuery = CKQuery(recordType: "GigiMemory", predicate: pred)
            guard let db = db else { return [] }
            let result  = try await db.records(matching: ckQuery, resultsLimit: 10)
            let hits: [(String, String)] = result.matchResults.compactMap { _, res in
                guard let record = try? res.get(),
                      let key   = record["key"]   as? String,
                      let value = record["value"] as? String else { return nil }
                self.cache[key] = value
                return (key, value)
            }
            if !hits.isEmpty { scheduleSaveToDisk() }
            return hits
        } catch { return [] }
    }

    // MARK: - Recall all by category

    func recallAll(category: String) async -> [String: String] {
        let prefix = category.lowercased() + ":"
        // From cache first
        let cached = Dictionary(uniqueKeysWithValues: cache.filter { $0.key.hasPrefix(prefix) })
        if !cached.isEmpty { return cached }
        // CloudKit fallback
        guard iCloudAvailable else { return [:] }
        do {
            let pred    = NSPredicate(format: "key BEGINSWITH %@", prefix)
            let ckQuery = CKQuery(recordType: "GigiMemory", predicate: pred)
            guard let db = db else { return [:] }
            let result  = try await db.records(matching: ckQuery, resultsLimit: 50)
            var out: [String: String] = [:]
            for (_, res) in result.matchResults {
                if let record = try? res.get(),
                   let k = record["key"] as? String,
                   let v = record["value"] as? String {
                    out[k] = v; cache[k] = v
                }
            }
            if !out.isEmpty { scheduleSaveToDisk() }
            return out
        } catch { return [:] }
    }

    // MARK: - Forget

    func forget(_ key: String) async {
        let normalizedKey = key.lowercased().trimmingCharacters(in: .whitespaces)
        cache.removeValue(forKey: normalizedKey)
        useCountByKey.removeValue(forKey: normalizedKey)
        scheduleSaveToDisk()
        guard iCloudAvailable else { return }
        let recordID = CKRecord.ID(recordName: normalizedKey)
        guard let db = db else { return }
        _ = try? await db.deleteRecord(withID: recordID)
        GigiDebugLogger.log("GIGI Memory: forgot '\(normalizedKey)'")
    }

    // MARK: - Context string for LLM injection

    /// Returns the most relevant memories as a compact string for LLM context injection.
    func contextString(for text: String) async -> String {
        guard !cache.isEmpty else { return "" }
        let lower = text.lowercased()

        // Contacts / prefs / places mentioned in the text. Only inject what
        // is actually relevant — dumping unrelated keys (e.g. "marco = brother"
        // when the user asks about Einstein) confuses the FM router into
        // ask_clarification on the wrong subject (echoes the irrelevant name).
        var relevant: [(String, String)] = []
        for (key, value) in cache {
            let keyName = key.components(separatedBy: ":").dropFirst().joined(separator: ":")
            guard !keyName.isEmpty else { continue }
            if lower.contains(keyName) {
                relevant.append((key, value))
            }
        }

        guard !relevant.isEmpty else { return "" }
        let lines = relevant.prefix(8).map { key, value -> String in
            if key.hasPrefix("contact:") {
                let name = String(key.dropFirst("contact:".count))
                return "- \(name) = \(value)"
            }
            if key.hasPrefix("pref:") {
                let name = String(key.dropFirst("pref:".count))
                return "- \(name) = \(value)"
            }
            return "- \(key): \(value)"
        }
        .joined(separator: "\n")
        return "User memory:\n\(lines)"
    }

    // MARK: - Load all (cache warm-up at startup)

    // CloudKit does not support BEGINSWITH "" or key >= "" on STRING fields.
    // Query each category prefix separately — all valid BEGINSWITH predicates.
    private static let categoryPrefixes = ["contact:", "routine:", "pref:", "place:", "person:"]

    private func loadAll() async {
        guard let db = db else { return }
        var anyHydrated = false
        for prefix in Self.categoryPrefixes {
            do {
                let pred   = NSPredicate(format: "key BEGINSWITH %@", prefix)
                let query  = CKQuery(recordType: "GigiMemory", predicate: pred)
                let result = try await db.records(matching: query, resultsLimit: 50)
                for (_, res) in result.matchResults {
                    if let record = try? res.get(),
                       let k = record["key"] as? String,
                       let v = record["value"] as? String {
                        cache[k] = v
                        useCountByKey[k] = (record["useCount"] as? Int64) ?? 0
                        anyHydrated = true
                    }
                }
            } catch {
                GigiDebugLogger.log("GIGI Memory: loadAll('\(prefix)') error — \(error.localizedDescription)")
            }
        }
        if anyHydrated { scheduleSaveToDisk() }
    }

    // MARK: - Most used

    /// Keys with highest `useCount` (sorted from local cache mirror of CloudKit counters).
    func mostUsed(limit: Int) async -> [(String, String)] {
        let lim = max(1, min(limit, 100))
        guard !cache.isEmpty else { return [] }
        let sorted = cache.keys.sorted {
            (useCountByKey[$0] ?? 0) > (useCountByKey[$1] ?? 0)
        }
        return sorted.prefix(lim).compactMap { k in cache[k].map { (k, $0) } }
    }

    // MARK: - Private helpers

    private func touch(record: CKRecord) async {
        record["lastUsed"] = Date()
        let next = ((record["useCount"] as? Int64) ?? 0) + 1
        record["useCount"] = next
        if let k = record["key"] as? String {
            useCountByKey[k] = next
            scheduleSaveToDisk()
        }
        guard let db = db else { return }
        _ = try? await db.save(record)
    }
}
