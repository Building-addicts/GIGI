import Foundation

// MARK: - M0: Voice Architecture Contracts
// Shared value types used by all channels: iOS Quick Talk, iOS Presence, Telegram, WhatsApp.

// MARK: - Session State

enum GigiVoiceSessionState: String, Codable, Equatable {
    case idle
    case listening
    case transcribing
    case thinking
    case confirming
    case acting
    case speaking
    case muted
    case interrupted
    case error
}

// MARK: - Channel

enum GigiChannel: String, Codable, Equatable {
    case iosQuickTalk  = "ios_quicktalk"
    case iosPresence   = "ios_presence"
    case telegram      = "telegram"
    case whatsapp      = "whatsapp"
}

enum GigiAudioMode: String, Codable, Equatable {
    case none, listening, speaking, muted
}

// MARK: - Session

struct GigiVoiceSession: Codable, Identifiable {
    let id: UUID
    let userId: String
    let channel: GigiChannel
    let deviceId: String?
    let chatId: String?
    let phone: String?
    var state: GigiVoiceSessionState
    var audioMode: GigiAudioMode
    var lastTranscript: String?
    var shortMemory: [String]
    var pendingConfirmation: String?
    var activeToolCall: String?
    let createdAt: Date
    var lastSeenAt: Date
    var expiresAt: Date

    static func makeIOS(deviceId: String, channel: GigiChannel = .iosQuickTalk) -> GigiVoiceSession {
        let now = Date()
        return GigiVoiceSession(
            id: UUID(),
            userId: deviceId,
            channel: channel,
            deviceId: deviceId,
            chatId: nil,
            phone: nil,
            state: .idle,
            audioMode: .none,
            lastTranscript: nil,
            shortMemory: [],
            pendingConfirmation: nil,
            activeToolCall: nil,
            createdAt: now,
            lastSeenAt: now,
            expiresAt: now.addingTimeInterval(3600)
        )
    }
}

// MARK: - Confirmation Policy

enum GigiConfirmationPolicy: String, Codable {
    case send           // sending messages to others
    case delete         // deleting data
    case modify         // modifying calendar/contacts
    case externalAction // purchases, bookings, orders
    case never          // never requires confirmation
}

// MARK: - Metrics

struct GigiMetrics {
    var sttLatencyMs: Double = 0
    var agentLatencyMs: Double = 0
    var ttsLatencyMs: Double = 0
    var taskCompletionSuccess: Bool = false
    var fallbackUsed: Bool = false
    var channel: GigiChannel = .iosQuickTalk
    var sessionId: UUID = UUID()
}

// MARK: - Priority Intent Matrix

enum GigiPriorityIntent: String, CaseIterable {
    case note       = "note"
    case reminder   = "reminder"
    case calendar   = "calendar"
    case message    = "message"
    case search     = "search"
    case followUp   = "follow_up"
    case stop       = "stop"
    case mute       = "mute"
    case confirm    = "confirm"

    var requiresConfirmationPolicy: GigiConfirmationPolicy {
        switch self {
        case .message:  return .send
        case .calendar: return .modify
        case .stop, .mute, .confirm, .note, .reminder, .search, .followUp:
            return .never
        }
    }
}
