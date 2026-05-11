import SwiftUI

// MARK: - ConfirmComputerUseSheet
//
// Confirm gating UI for Path 4 (Claude Code subprocess + computer-use).
// Presented when the harness emits a `confirm_required` event before a
// destructive or visible-side-effect action (form submit, purchase,
// vote, message send via browser, etc.).
//
// User taps:
//   - Approve → POST /api/ios/agent/confirm { runId, approved: true }
//   - Cancel  → POST /api/ios/agent/confirm { runId, approved: false } +
//               POST /api/ios/agent/cancel (request SIGTERM)
//
// Reference: docs/plans/frolicking-stargazing-pancake.md §4.4
// docs/taskplans_new_gigi/GATE-5-path-4-claude-code-subprocess.md §3 Task 5.6

struct ConfirmComputerUseSheet: View {
    let runId: String
    let actionDescription: String
    let screenshotData: Data?
    let onDecision: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var inflight = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundColor(.orange)
                    .font(.title2)
                Text("Confirm action")
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(Color.orange.opacity(0.1))

            // Body
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("GIGI wants to perform an action on your behalf in a real browser. Review and approve only if you trust it.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Action")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Text(actionDescription)
                            .font(.body)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                    }

                    if let data = screenshotData, let uiImage = UIImage(data: data) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Preview")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                )
                        }
                    } else {
                        HStack {
                            Image(systemName: "photo")
                                .foregroundColor(.secondary)
                            Text("No screenshot available for this action.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }

                    if !runId.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "number")
                            Text("Run ID: \(runId)")
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                    }
                }
                .padding()
            }

            // Buttons
            VStack(spacing: 8) {
                Button {
                    inflight = true
                    Task {
                        await GigiHarnessClient.shared.confirmClaudeCode(runId: runId, approved: true)
                        await MainActor.run {
                            onDecision(true)
                            inflight = false
                            dismiss()
                        }
                    }
                } label: {
                    HStack {
                        if inflight { ProgressView().controlSize(.small).tint(.white) }
                        Text(inflight ? "Approving..." : "Approve")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(inflight)

                Button(role: .destructive) {
                    inflight = true
                    Task {
                        await GigiHarnessClient.shared.confirmClaudeCode(runId: runId, approved: false)
                        await GigiHarnessClient.shared.cancelClaudeCode(runId: runId)
                        await MainActor.run {
                            onDecision(false)
                            inflight = false
                            dismiss()
                        }
                    }
                } label: {
                    Text("Cancel")
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.1))
                        .foregroundColor(.red)
                        .cornerRadius(10)
                }
                .disabled(inflight)
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(.systemBackground))
            .shadow(color: .black.opacity(0.05), radius: 8, y: -2)
        }
        .interactiveDismissDisabled(inflight)
    }
}

#Preview {
    ConfirmComputerUseSheet(
        runId: "claude-1715000000-abc123",
        actionDescription: "Click 'Place Order' button on Amazon checkout page. Total: $42.99.",
        screenshotData: nil,
        onDecision: { approved in print("decision: \(approved)") }
    )
}
