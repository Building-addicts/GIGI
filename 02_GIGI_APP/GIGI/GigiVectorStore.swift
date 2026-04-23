import Accelerate
import Foundation
import NaturalLanguage

// MARK: - GigiMemoryRecord

struct GigiMemoryRecord: Sendable {
    let key:   String
    let value: String
    var embedding: [Float]?
}

// MARK: - GigiMemoryNamespace

enum GigiMemoryNamespace: String, CaseIterable {
    case contacts    = "contact"
    case preferences = "pref"
    case routines    = "routine"
    case places      = "place"
    case context     = "person"
}

// MARK: - GigiVectorStore
//
// On-device semantic memory search using NLEmbedding (Apple Neural Engine).
// Zero data leaves the device for the embedding step — full privacy.
//
// Strategy:
//   • wordEmbedding(.english): word-level vectors averaged over content words
//     (stop words stripped to improve signal). Accurate for short key/value pairs.
//   • Future upgrade path: NLEmbedding.sentenceEmbedding(.english) for full-sentence queries.
//   • Cosine similarity via vDSP_dotpr (Accelerate framework) — no scalar loops.
//   • similarityThreshold 0.45: NLEmbedding word vectors are inflated vs sentence embeddings;
//     0.45 avoids "forgetting" real matches while still filtering noise.
//   • Embeddings pre-computed once on upsert, serialised to UserDefaults — never recomputed on recall.
//   • Cache capped at 500 entries; stale entries evicted first to stay under 1 MB on disk.

final class GigiVectorStore {
    static let shared = GigiVectorStore()

    // MARK: - Config

    static let similarityThreshold: Float = 0.45
    private let udKey = "gigi.vectorstore.embeddings.v1"
    private let maxCacheEntries = 500
    private let maxCacheBytesOnDisk = 1_048_576  // 1 MB

    // MARK: - NLEmbedding (optional — graceful degradation if unavailable)

    private let embedder: NLEmbedding?
    private var dim: Int { embedder?.dimension ?? 0 }

    // MARK: - State (all mutations go through `queue`)

    private let queue = DispatchQueue(label: "com.gigi.vectorstore", qos: .userInitiated)
    private var _records: [GigiMemoryRecord] = []
    private var _embeddingCache: [String: [Float]] = [:]

    // MARK: - Stop words (English + Italian common filler)

    private let stopWords: Set<String> = [
        // English
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did", "will", "would", "could",
        "should", "may", "might", "can", "to", "of", "in", "on", "at", "by",
        "for", "with", "as", "into", "from", "up", "down", "out", "off",
        "then", "here", "there", "all", "both", "each", "no", "not", "only",
        "so", "than", "too", "very", "and", "but", "or", "if", "this", "that",
        // Italian
        "il", "lo", "la", "i", "gli", "le", "un", "uno", "una",
        "del", "della", "dei", "degli", "delle", "di", "da", "con", "su",
        "per", "tra", "fra", "è", "e", "ma", "o", "se", "anche", "non",
        "mi", "ti", "si", "ci", "vi", "ne", "già", "più",
    ]

    // MARK: - Init

    private init() {
        embedder = NLEmbedding.wordEmbedding(for: .english)
        if embedder == nil {
            print("GigiVectorStore: NLEmbedding unavailable — semantic search disabled")
        }
        loadCacheFromDisk()
    }

    // MARK: - 3.1.7 All records (thread-safe snapshot)

    var allRecords: [GigiMemoryRecord] {
        queue.sync { _records }
    }

    // MARK: - 3.1.6 Preload (async, does not block main thread)

    func preload(namespaces: [GigiMemoryNamespace]) async {
        guard embedder != nil else { return }
        var loaded: [GigiMemoryRecord] = []

        for ns in namespaces {
            let dict = await GigiMemory.shared.recallAll(category: ns.rawValue)
            for (key, value) in dict {
                let cachedVec = queue.sync { _embeddingCache[key] }
                let vec = cachedVec ?? computeEmbedding(key: key, value: value)
                loaded.append(GigiMemoryRecord(key: key, value: value, embedding: vec))
            }
        }

        queue.async { [weak self] in
            guard let self else { return }
            var byKey = Dictionary(uniqueKeysWithValues: self._records.map { ($0.key, $0) })
            for r in loaded { byKey[r.key] = r }
            self._records = Array(byKey.values)
        }

        print("GigiVectorStore: preloaded \(loaded.count) records (\(namespaces.map(\.rawValue).joined(separator: ", ")))")
    }

    // MARK: - 3.1.5 Semantic search

    func relevantMemories(for text: String, topK: Int = 5) -> [GigiMemoryRecord] {
        guard embedder != nil else { return [] }
        let queryVec = embed(text)
        guard !queryVec.isEmpty else { return [] }

        let snapshot = queue.sync { _records }

        let scored: [(GigiMemoryRecord, Float)] = snapshot.compactMap { rec in
            guard let e = rec.embedding, !e.isEmpty else { return nil }
            let sim = cosineSimilarity(queryVec, e)
            guard sim >= GigiVectorStore.similarityThreshold else { return nil }
            return (rec, sim)
        }

        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(topK)
            .map(\.0)
    }

    // MARK: - Upsert (call after GigiMemory.remember)

    func upsert(key: String, value: String) {
        guard embedder != nil else { return }
        let vec = computeEmbedding(key: key, value: value)
        let rec = GigiMemoryRecord(key: key, value: value, embedding: vec)
        queue.async { [weak self] in
            guard let self else { return }
            if let idx = self._records.firstIndex(where: { $0.key == key }) {
                self._records[idx] = rec
            } else {
                self._records.append(rec)
            }
        }
    }

    // MARK: - 3.1.3 Embedding

    /// Text → Float32 vector via mean pooling over content words (stop words removed).
    func embed(_ text: String) -> [Float] {
        guard let embedder, dim > 0 else { return [] }

        let words = text
            .lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count > 1 && !stopWords.contains($0) }

        guard !words.isEmpty else { return [] }

        var sum = [Float](repeating: 0, count: dim)
        var count = 0

        for word in words {
            guard let doubleVec = embedder.vector(for: word) else { continue }
            let floatVec = doubleVec.map(Float.init)
            vDSP_vadd(sum, 1, floatVec, 1, &sum, 1, vDSP_Length(dim))
            count += 1
        }

        guard count > 0 else { return [] }

        // Mean pooling: divide sum by word count
        var n = Float(count)
        vDSP_vsdiv(sum, 1, &n, &sum, 1, vDSP_Length(dim))
        return sum
    }

    // MARK: - 3.1.4 Cosine similarity (Accelerate)

    func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let n = vDSP_Length(a.count)
        var dot:  Float = 0
        var magA: Float = 0
        var magB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot,  n)
        vDSP_dotpr(a, 1, a, 1, &magA, n)
        vDSP_dotpr(b, 1, b, 1, &magB, n)
        let denom = sqrt(magA) * sqrt(magB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    // MARK: - Embedding cache helpers

    @discardableResult
    private func computeEmbedding(key: String, value: String) -> [Float]? {
        let vec = embed("\(key) \(value)")
        guard !vec.isEmpty else { return nil }
        queue.async { [weak self] in
            guard let self else { return }
            self._embeddingCache[key] = vec
            self.saveCacheToDisk()
        }
        return vec
    }

    private func loadCacheFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: udKey),
              let dict = try? JSONDecoder().decode([String: [Float]].self, from: data) else { return }
        queue.async { [weak self] in self?._embeddingCache = dict }
        print("GigiVectorStore: loaded \(dict.count) cached embeddings from disk")
    }

    private func saveCacheToDisk() {
        // Called from queue. Evict then write on a background thread.
        evictStaleEntriesIfNeeded()
        let snapshot = _embeddingCache
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            if data.count > self.maxCacheBytesOnDisk {
                print("GigiVectorStore: cache \(data.count / 1024) KB > 1 MB — skipping disk write (will retry after eviction)")
                return
            }
            UserDefaults.standard.set(data, forKey: self.udKey)
        }
    }

    /// Evicts cache entries that are no longer backed by a live record, then trims to maxCacheEntries.
    /// Must be called from `queue`.
    private func evictStaleEntriesIfNeeded() {
        guard _embeddingCache.count > maxCacheEntries else { return }

        let liveKeys = Set(_records.map(\.key))

        // Pass 1: drop entries not present in any loaded record
        for key in _embeddingCache.keys where !liveKeys.contains(key) {
            _embeddingCache.removeValue(forKey: key)
        }

        // Pass 2: if still over limit, drop arbitrary entries until under cap
        if _embeddingCache.count > maxCacheEntries {
            let overflow = _embeddingCache.count - maxCacheEntries
            for key in _embeddingCache.keys.prefix(overflow) {
                _embeddingCache.removeValue(forKey: key)
            }
            print("GigiVectorStore: evicted \(overflow) entries — cache now \(_embeddingCache.count)")
        }
    }
}
