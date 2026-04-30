import Combine
import Foundation
import SwiftUI

// MARK: - GigiConfirmationPolicyEngine
//
// Owns the "permission before execution" boundary:
// - Per-tool policy matrix for legacy voice-confirmation flow.
// - Async sheet-driven approval surface used by the iOS UI (issue #77).

@MainActor
final class GigiConfirmationPolicyEngine: ObservableObject {
    static let shared = GigiConfirmationPolicyEngine()

    // Override policy per tool name. Populated at init with sensible defaults.
    private(set) var policyOverrides: [String: GigiConfirmationPolicy] = [
        // Sending
        "send_message":        .send,
        "send_whatsapp":       .send,
        "web_whatsapp":        .send,
        // Booking / orders
        "web_book_restaurant": .externalAction,
        "web_order_food":      .externalAction,
        "computer_use":        .externalAction,
        // Calendar modification
        "create_event":        .modify,
        // Destructive
        "homekit_lock":        .modify,
        "homekit_unlock":      .modify,
    ]

    // MARK: - Sheet-driven approval (issue #77)

    /// Currently presented payload. SwiftUI binds `.sheet(item:)` to this.
    @Published var presentedPayload: PermissionPayload?

    private var pendingContinuation: CheckedContinuation<ConfirmationResult, Never>?

    /// Suspends until the user confirms / edits / cancels via the sheet.
    /// Cancellation of the surrounding task resolves to `.cancelled` to keep
    /// the engine state consistent.
    func requestConfirmation(payload: PermissionPayload) async -> ConfirmationResult {
        // Defensive: collapse any stale request before starting a new one.
        if let prior = pendingContinuation {
            pendingContinuation = nil
            prior.resume(returning: .cancelled)
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<ConfirmationResult, Never>) in
            pendingContinuation = cont
            presentedPayload = payload
        }
    }

    /// Called by the sheet's button handlers.
    func resolve(_ result: ConfirmationResult) {
        let cont = pendingContinuation
        pendingContinuation = nil
        presentedPayload = nil
        cont?.resume(returning: result)
    }

    // MARK: - Legacy voice-confirmation policy

    /// Returns a ConfirmRequest if this result requires approval, nil otherwise.
    func evaluate(result: AgentResult, utterance: String) -> ConfirmRequest? {
        guard let existing = result.requiresConfirm else { return nil }
        return existing
    }

    /// Checks if a tool name requires confirmation according to the policy matrix.
    func requiresConfirmation(toolName: String) -> Bool {
        guard let policy = policyOverrides[toolName] else { return false }
        return policy != .never
    }

    func setPolicy(_ policy: GigiConfirmationPolicy, forTool tool: String) {
        policyOverrides[tool] = policy
    }
}
