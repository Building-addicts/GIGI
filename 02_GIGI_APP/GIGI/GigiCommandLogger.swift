import Foundation

// MARK: - QuickTalkLog

struct QuickTalkLog: Codable {
    let id: UUID
    let timestamp: Date
    let transcript: String
    let response: String
    let toolsCalled: [String]
    let outcome: Outcome
    let sttLatencyMs: Int
    let agentLatencyMs: Int
    let ttsLatencyMs: Int
    let channel: GigiChannel

    enum Outcome: String, Codable {
        case success, partial, fallback, fail
    }
}

// MARK: - GigiCommandLogger

final class GigiCommandLogger {
    static let shared = GigiCommandLogger()

    private let maxEntries = 200
    private let logFileName = "gigi_command_log.json"
    private var logURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(logFileName)
    }

    private(set) var entries: [QuickTalkLog] = []

    private init() { load() }

    func log(_ entry: QuickTalkLog) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        persist()
    }

    func recentLogs(limit: Int = 20) -> [QuickTalkLog] {
        Array(entries.prefix(limit))
    }

    private func load() {
        guard let data = try? Data(contentsOf: logURL),
              let decoded = try? JSONDecoder().decode([QuickTalkLog].self, from: data) else { return }
        entries = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: logURL)
    }
}
