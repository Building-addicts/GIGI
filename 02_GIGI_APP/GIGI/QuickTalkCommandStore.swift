import Foundation

// MARK: - QuickTalkCommand

struct QuickTalkCommand: Codable, Identifiable {
    let id: UUID
    let transcript: String
    let response: String
    let timestamp: Date
    let durationMs: Int
    let success: Bool
}

// MARK: - QuickTalkCommandStore

final class QuickTalkCommandStore {
    static let shared = QuickTalkCommandStore()

    private let key = "gigi.quicktalk.history"
    private let maxCount = 20

    private(set) var commands: [QuickTalkCommand] = []

    private init() {
        load()
    }

    func append(transcript: String, response: String, durationMs: Int, success: Bool) {
        let cmd = QuickTalkCommand(
            id: UUID(),
            transcript: transcript,
            response: response,
            timestamp: Date(),
            durationMs: durationMs,
            success: success
        )
        commands.insert(cmd, at: 0)
        if commands.count > maxCount { commands = Array(commands.prefix(maxCount)) }
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([QuickTalkCommand].self, from: data) else { return }
        commands = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(commands) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
