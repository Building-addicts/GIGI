import Foundation

// MARK: - GigiConfirmationPolicyEngine
//
// Evaluates whether an AgentResult requires user confirmation.
// Per-tool `requiresConfirmation` flag takes priority over category policy.

@MainActor
final class GigiConfirmationPolicyEngine {
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

    // Returns a ConfirmRequest if this result requires approval, nil otherwise.
    func evaluate(result: AgentResult, utterance: String) -> ConfirmRequest? {
        guard let existing = result.requiresConfirm else { return nil }
        return existing
    }

    // Checks if a tool name requires confirmation according to the policy matrix.
    func requiresConfirmation(toolName: String) -> Bool {
        guard let policy = policyOverrides[toolName] else { return false }
        return policy != .never
    }

    func setPolicy(_ policy: GigiConfirmationPolicy, forTool tool: String) {
        policyOverrides[tool] = policy
    }
}
