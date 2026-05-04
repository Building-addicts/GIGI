import SwiftUI

/// Send/Edit/Cancel preview sheet for draft messages (#47).
/// Shown above ChatView when GigiSmartOrchestrator publishes pendingDraft.
struct DraftMessagePreviewSheet: View {
    @ObservedObject var orchestrator = GigiSmartOrchestrator.shared
    @State private var editedBody: String = ""
    @State private var isEditing = false
    @FocusState private var bodyFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let d = orchestrator.pendingDraft {
                    HStack {
                        Text("To: \(d.contact)")
                            .font(.headline)
                        Spacer()
                        Text(d.platform.capitalized)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.green.opacity(0.2)))
                    }

                    TextEditor(text: $editedBody)
                        .focused($bodyFocused)
                        .frame(minHeight: 120)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                        .disabled(!isEditing)

                    HStack(spacing: 12) {
                        Button(role: .destructive) {
                            orchestrator.cancelDraft()
                        } label: {
                            Text("Cancel").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            isEditing.toggle()
                            bodyFocused = isEditing
                        } label: {
                            Text(isEditing ? "Done" : "Edit").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            orchestrator.pendingDraft?.body = editedBody
                            Task { _ = await orchestrator.sendDraft() }
                        } label: {
                            Text("Send").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 8)

                    Spacer()
                }
            }
            .padding()
            .navigationTitle("Draft preview")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                editedBody = orchestrator.pendingDraft?.body ?? ""
            }
        }
        .presentationDetents([.medium, .large])
    }
}
