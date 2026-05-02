import Foundation
import Combine

struct ExtractedTask: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var deadline: String?
    var vipContact: String?
    var createdAt: Date = Date()

    enum CodingKeys: String, CodingKey { case title, deadline, vipContact }
}

@MainActor
final class GigiTaskExtractor: ObservableObject {
    static let shared = GigiTaskExtractor()

    @Published private(set) var tasks: [ExtractedTask] = []
    @Published private(set) var isExtracting = false

    private var inFlight = false

    private init() {}

    func extract(from transcript: String) async {
        guard !inFlight, transcript.count > 20 else { return }
        inFlight = true
        isExtracting = true
        defer {
            inFlight = false
            isExtracting = false
        }

        do {
            let raw = try await GigiCloudService.shared.extractTasksRaw(transcript: transcript)
            let cleaned = stripCodeFences(raw)
            guard let data = cleaned.data(using: .utf8) else { return }
            let decoded = try JSONDecoder().decode([ExtractedTask].self, from: data)
            mergeDedup(decoded)
            GigiDebugLogger.log("GigiTaskExtractor extracted \(decoded.count) raw, total \(tasks.count) after dedup")
        } catch {
            GigiDebugLogger.log("GigiTaskExtractor error: \(error.localizedDescription)")
        }
    }

    func clear() {
        tasks.removeAll()
    }

    // MARK: - Private

    private func mergeDedup(_ incoming: [ExtractedTask]) {
        for t in incoming {
            let titleLower = t.title.lowercased()
            let isDup = tasks.contains { existing in
                jaccard(existing.title.lowercased(), titleLower) > 0.7
            }
            if !isDup { tasks.append(t) }
        }
    }

    private func jaccard(_ a: String, _ b: String) -> Double {
        let sa = Set(a.split(separator: " ").map(String.init))
        let sb = Set(b.split(separator: " ").map(String.init))
        if sa.isEmpty && sb.isEmpty { return 1.0 }
        let union = sa.union(sb).count
        guard union > 0 else { return 0.0 }
        return Double(sa.intersection(sb).count) / Double(union)
    }

    private func stripCodeFences(_ s: String) -> String {
        s.replacingOccurrences(of: "```json", with: "")
         .replacingOccurrences(of: "```", with: "")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
