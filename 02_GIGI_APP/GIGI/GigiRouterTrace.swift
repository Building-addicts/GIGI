import Foundation

// MARK: - GigiRouterTrace
//
// Structured per-utterance log of every router decision. Each decision is
// recorded as one Entry with tier (memory / nlu_fast / regex / semantic /
// appleFM / fallback), tool dispatched, confidence, optional slot, and
// latency. Entries live in a rolling 1000-deep in-memory buffer and are
// mirrored to a JSONL file in Application Support for post-hoc analysis.
//
// In parallel, every record() call runs the RepromptDetector against the
// previous entry: if the new utterance is semantically close (NLEmbedding
// cosine ≥0.7) to the previous one AND was handled by a different tier,
// the new entry is tagged with `repromptOfId` pointing at the earlier
// turn. In DEBUG builds a tool-event bubble is added to the chat so the
// dev can see the detection visually.
//
// All telemetry is also forwarded fire-and-forget to the harness Live
// Monitor when the harness is paired.
//
// File: ~/Library/Application Support/gigi-router-trace.jsonl
// (visible via Xcode → Devices and Simulators → app container download)

@MainActor
final class GigiRouterTrace {

    static let shared = GigiRouterTrace()

    struct Entry: Codable {
        let id: UUID
        let timestamp: Date
        let utterance: String
        let tier: String
        let tool: String
        let confidence: Float
        let slot: String?
        let path: String?
        let latencyMs: Int
        let repromptOfId: UUID?
    }

    // MARK: - Tuning

    private static let filename = "gigi-router-trace.jsonl"
    private static let maxEntries = 1000
    private static let repromptSimThreshold: Float = 0.7
    private static let repromptMaxAgeSeconds: TimeInterval = 60
    private static let diskDebounceNs: UInt64 = 300_000_000  // 300ms

    // MARK: - State

    private var buffer: [Entry] = []
    private var pendingSaveTask: Task<Void, Never>?

    private init() {
        loadBufferFromDisk()
    }

    // MARK: - Public API

    /// Record a routing decision. Returns the new entry's id (caller may
    /// use it to correlate with downstream events). Auto-detects reprompt
    /// of mis-routing against the previous entry.
    @discardableResult
    func record(utterance: String,
                tier: String,
                tool: String,
                confidence: Float,
                slot: String? = nil,
                path: String? = nil,
                latencyMs: Int = 0) -> UUID {

        let prev = detectReprompt(utterance: utterance, tier: tier)
        let entry = Entry(
            id: UUID(),
            timestamp: Date(),
            utterance: utterance,
            tier: tier,
            tool: tool,
            confidence: confidence,
            slot: slot,
            path: path,
            latencyMs: latencyMs,
            repromptOfId: prev?.id
        )

        buffer.append(entry)
        if buffer.count > Self.maxEntries {
            buffer.removeFirst(buffer.count - Self.maxEntries)
        }
        scheduleSaveToDisk()

        // Harness Live Monitor (fire-and-forget, no-op when not paired).
        GigiHarnessClient.shared.postTelemetry(
            type: "router_trace",
            path: path ?? tier,
            primaryAction: tool,
            userText: utterance,
            elapsedMs: latencyMs
        )

        // DEBUG: surface reprompt detections in the chat so the dev sees
        // them inline without inspecting the JSONL file.
        if let prev = prev {
            #if DEBUG
            let sim = computeSimilarity(utterance, prev.utterance)
            let simStr = String(format: "%.2f", sim)
            let msg = "⚠️ reprompt detected (sim \(simStr) vs '\(prev.utterance.prefix(40))', previous tier=\(prev.tier))"
            GigiDebugLogger.log("GIGI Trace: \(msg)")
            GigiConversationMemory.shared.addToolEvent(name: "reprompt", status: msg)
            #endif
        }

        return entry.id
    }

    /// Most recent entries (newest last). Used by RepromptDetector and
    /// future replay tooling.
    func recent(count: Int = 100) -> [Entry] {
        Array(buffer.suffix(count))
    }

    /// Absolute JSONL file URL for export. Returns nil if Application
    /// Support directory cannot be resolved.
    static func fileURL() -> URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return dir.appendingPathComponent(filename)
    }

    /// Wipe the in-memory buffer + disk file. Exposed for Settings →
    /// "Clear router trace" or test setup.
    func clear() {
        buffer.removeAll()
        pendingSaveTask?.cancel()
        if let url = Self.fileURL() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Reprompt detection

    /// Returns the previous entry if the new utterance is plausibly a
    /// rephrasing of it after a mis-routing. Heuristic:
    ///   - tier of the new decision differs from the previous one
    ///   - similarity ≥ repromptSimThreshold (NLEmbedding cosine)
    ///   - previous turn happened within repromptMaxAgeSeconds
    ///   - previous turn is not itself a reprompt (avoid chains)
    private func detectReprompt(utterance: String, tier: String) -> Entry? {
        guard let prev = buffer.last else { return nil }
        guard prev.tier != tier else { return nil }
        guard prev.repromptOfId == nil else { return nil }
        guard Date().timeIntervalSince(prev.timestamp) < Self.repromptMaxAgeSeconds else { return nil }
        let sim = computeSimilarity(utterance, prev.utterance)
        guard sim >= Self.repromptSimThreshold else { return nil }
        return prev
    }

    /// Reprompt similarity uses content-word Jaccard, NOT NLEmbedding.
    ///
    /// NLEmbedding word vectors don't index proper nouns (Marco, Einstein,
    /// Tesla, etc.). When the differentiating word in the utterance is OOV,
    /// the embedding collapses to the average of function words only, and
    /// utterances like "Who is Marco" and "Who is Einstein" appear identical
    /// (cosine ~1.00) — a degenerate match that fires the detector on
    /// every distinct entity question.
    ///
    /// Jaccard on the lowercased content-word set (minus a small English+IT
    /// stop-word list) is robust for short queries: it requires concrete
    /// noun/verb overlap to flag a rephrase. Trades some recall (won't catch
    /// "Tesla news" → "Search the web for Tesla news, please") for much
    /// higher precision.
    private func computeSimilarity(_ a: String, _ b: String) -> Float {
        let ta = Self.contentTokens(a)
        let tb = Self.contentTokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let inter = ta.intersection(tb)
        let union = ta.union(tb)
        guard !union.isEmpty else { return 0 }
        return Float(inter.count) / Float(union.count)
    }

    private static let stopWords: Set<String> = [
        // EN
        "a","an","the","is","are","was","were","be","been","being","am",
        "do","does","did","done","doing",
        "have","has","had","having",
        "i","you","he","she","it","we","they","me","him","her","us","them",
        "my","your","his","its","our","their","mine","yours",
        "this","that","these","those","there","here",
        "what","who","whose","whom","which","why","how","when","where",
        "of","in","on","at","to","for","with","by","from","as","up","down",
        "and","or","but","not","no","yes","so","then","than","too","very","just","also",
        "can","could","would","should","may","might","must","shall","will",
        "please","ok","okay","hey","hi","hello",
        // IT
        "il","lo","la","i","gli","le","un","uno","una",
        "è","sei","sono","siamo","siete","era","ero","fui","sarò","sarà",
        "ho","hai","ha","abbiamo","avete","hanno",
        "io","tu","lui","lei","noi","voi","loro",
        "mio","tuo","suo","nostro","vostro","loro",
        "questo","quello","quella","questi","quelli",
        "che","chi","cosa","come","perché","perchè","quando","dove",
        "di","a","da","in","con","su","per","tra","fra",
        "e","o","ma","non","sì","si","così","poi","anche","molto",
        "puoi","potresti","vorrei","devi","deve","deve","dobbiamo",
        "ciao","ehi","ok"
    ]

    /// Lowercased, punctuation-stripped, stop-word-free set of content tokens.
    private static func contentTokens(_ text: String) -> Set<String> {
        let lowered = text.lowercased()
        let stripped = lowered.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == " " ? Character($0) : " " }
        let joined = String(stripped)
        let tokens = joined.split(separator: " ").map(String.init)
        return Set(tokens.filter { !$0.isEmpty && !stopWords.contains($0) })
    }

    // MARK: - Disk JSONL persistence

    /// Debounced full rewrite of the JSONL file. Rewrite-all is simpler
    /// than append-then-rotate and fine for <=1000 entries (~200KB).
    private func scheduleSaveToDisk() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.diskDebounceNs)
            guard !Task.isCancelled else { return }
            self?.writeBufferToDisk()
        }
    }

    private func writeBufferToDisk() {
        guard let url = Self.fileURL() else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var lines: [String] = []
        lines.reserveCapacity(buffer.count)
        for entry in buffer {
            guard let data = try? encoder.encode(entry),
                  let str  = String(data: data, encoding: .utf8) else { continue }
            lines.append(str)
        }
        let body = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            GigiDebugLogger.log("GIGI Trace: disk write error — \(error.localizedDescription)")
        }
    }

    private func loadBufferFromDisk() {
        guard let url = Self.fileURL(),
              FileManager.default.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var restored: [Entry] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(Entry.self, from: data) else { continue }
            restored.append(entry)
        }
        if restored.count > Self.maxEntries {
            restored = Array(restored.suffix(Self.maxEntries))
        }
        buffer = restored
        GigiDebugLogger.log("GIGI Trace: loaded \(buffer.count) entries from disk")
    }
}
