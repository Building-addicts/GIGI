import Foundation
import Combine

// MARK: - GigiShortcutRegistry (GATE 14.B.2 lite)
//
// User-declared registry of Apple Shortcuts that GIGI can invoke. Solves
// two architectural needs:
//
// 1. **Limit-case bridging** — Apple closes write APIs for certain system
//    apps (Notes, Reminders, Health). The agreed architecture is: GIGI
//    invokes a user-installed Shortcut via `shortcuts://x-callback-url`
//    that uses Shortcuts.app's privileged access to do the write.
//    Example: `GIGI Append to Note` Shortcut takes "title|content" input,
//    splits on '|', finds the matching Note, appends content.
//
// 2. **Natural-language aliasing** — Apple doesn't expose the user's
//    Shortcuts library to 3rd-party apps. So the user declares their
//    Shortcuts here with EN/IT aliases (e.g. "accendi torcia" registered
//    with alias "open torch"). Router intercept matches aliases at route
//    time and invokes `run_shortcut` with the canonical name.
//
// Storage: UserDefaults JSON for now (defer CloudKit to GATE 14 full).
// Persists across app launches. Single device — no cross-device sync.
//
// All user-facing strings English per CLAUDE.md §Lingua hard rule.
// "Alias" entries themselves can be any language (user input).

@MainActor
final class GigiShortcutRegistry: ObservableObject {

    static let shared = GigiShortcutRegistry()

    private let storeKey = "gigi.shortcuts.registry.v1"

    @Published var shortcuts: [RegisteredShortcut] = []

    private init() {
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([RegisteredShortcut].self, from: data) else {
            shortcuts = []
            return
        }
        shortcuts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(shortcuts) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }

    // MARK: - CRUD

    func register(_ shortcut: RegisteredShortcut) {
        if let idx = shortcuts.firstIndex(where: { $0.id == shortcut.id }) {
            shortcuts[idx] = shortcut
        } else {
            shortcuts.append(shortcut)
        }
        save()
    }

    func unregister(name: String) {
        let key = name.lowercased()
        shortcuts.removeAll { $0.id == key }
        save()
    }

    func setEnabled(name: String, enabled: Bool) {
        let key = name.lowercased()
        if let idx = shortcuts.firstIndex(where: { $0.id == key }) {
            shortcuts[idx].enabled = enabled
            save()
        }
    }

    // MARK: - Matching

    /// Returns the registered enabled Shortcut whose name OR any alias
    /// matches the utterance (case-insensitive, whitespace + punctuation
    /// stripped). Returns nil if no match.
    func matchAlias(_ utterance: String) -> RegisteredShortcut? {
        let normalized = normalize(utterance)
        guard !normalized.isEmpty else { return nil }
        for shortcut in shortcuts where shortcut.enabled {
            if normalize(shortcut.name) == normalized { return shortcut }
            for alias in shortcut.aliases where normalize(alias) == normalized {
                return shortcut
            }
        }
        return nil
    }

    /// Returns the enabled Shortcut wired to a specific `systemPurpose`
    /// (e.g. "append_to_note", "create_reminder", "log_health_entry").
    /// GIGI internal handlers call this to find the user's chosen
    /// Shortcut for a specific integration point.
    func find(byPurpose purpose: String) -> RegisteredShortcut? {
        shortcuts.first { $0.systemPurpose == purpose && $0.enabled }
    }

    private func normalize(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet.punctuationCharacters)
            .joined()
    }

    // MARK: - Telemetry

    func recordUse(name: String) {
        let key = name.lowercased()
        if let idx = shortcuts.firstIndex(where: { $0.id == key }) {
            shortcuts[idx].useCount += 1
            shortcuts[idx].lastUsedAt = Date()
            save()
        }
    }
}

// MARK: - RegisteredShortcut

struct RegisteredShortcut: Codable, Identifiable, Equatable {

    var id: String { name.lowercased() }

    /// Exact Shortcut name as saved in the user's Shortcuts library.
    /// GIGI invokes via `shortcuts://x-callback-url/run-shortcut?name=<this>`.
    var name: String

    /// Natural-language phrases that should trigger this Shortcut at
    /// route time. Examples: "open torch", "flashlight on", "torcia
    /// please". Case-insensitive, punctuation-stripped match.
    var aliases: [String]

    /// User-readable description shown in Settings. Optional.
    var description: String

    /// Whether this Shortcut is actively used by GIGI. Toggle in Settings.
    var enabled: Bool

    /// Optional integration tag — when set, GIGI internal handlers can
    /// find this Shortcut by purpose instead of by name. Recognized:
    ///   - "append_to_note" — receives "title|content" input, appends
    ///     content to a Note matching title
    ///   - "create_reminder" — receives "title|date" input
    ///   - "log_health_entry" — receives "type|value" input
    ///   - "control_torch" — receives "on"/"off" input
    /// Custom purposes are user-defined.
    var systemPurpose: String?

    var createdAt: Date
    var lastUsedAt: Date?
    var useCount: Int

    init(name: String,
         aliases: [String] = [],
         description: String = "",
         enabled: Bool = true,
         systemPurpose: String? = nil) {
        self.name = name
        self.aliases = aliases
        self.description = description
        self.enabled = enabled
        self.systemPurpose = systemPurpose
        self.createdAt = Date()
        self.lastUsedAt = nil
        self.useCount = 0
    }
}
