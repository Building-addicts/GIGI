import SwiftUI

// MARK: - Payload model

/// Generic payload for any "meaningful" action that must be confirmed by the user
/// before execution (#77). Each case carries the minimum fields that the sheet
/// renders + that the orchestrator/dispatcher uses to actually perform the action
/// once the user confirms.
enum PermissionPayload: Equatable {
    case message(contact: String, platform: String, body: String, raw: String)
    case calendarEvent(title: String, date: String, time: String, location: String?)
    case reminder(text: String, date: String?, time: String?)
    case followUpTask(title: String, dueDate: String?)
    case scheduleSwap(from: String, to: String, reason: String)

    var headerTitle: String {
        switch self {
        case .message(let c, _, _, _):       return "To: \(c)"
        case .calendarEvent(let t, _, _, _): return t
        case .reminder(let t, _, _):         return t
        case .followUpTask(let t, _):        return t
        case .scheduleSwap(let from, let to, _): return "\(from) → \(to)"
        }
    }

    var badge: String {
        switch self {
        case .message(_, let p, _, _): return p.capitalized
        case .calendarEvent:           return "Calendar"
        case .reminder:                return "Reminder"
        case .followUpTask:            return "Task"
        case .scheduleSwap:            return "Schedule"
        }
    }

    var primaryBody: String {
        switch self {
        case .message(_, _, let body, _):     return body
        case .calendarEvent(_, let d, let t, let loc):
            return "\(d) at \(t)" + (loc.map { " · \($0)" } ?? "")
        case .reminder(_, let d, let t):
            return [d, t].compactMap { $0 }.joined(separator: " ")
        case .followUpTask(_, let due):
            return due ?? "No deadline"
        case .scheduleSwap(_, _, let reason):
            return reason
        }
    }
}

enum ConfirmationResult: Equatable {
    case confirmed(PermissionPayload)
    case cancelled
}

// MARK: - View

/// Generic Confirm/Edit/Cancel sheet. Drives all "meaningful" confirmations
/// (#77). DraftMessagePreviewSheet remains as a thin wrapper that builds a
/// `.message` payload so existing call-sites continue to work.
struct PermissionConfirmationSheet: View {
    @Binding var payload: PermissionPayload
    var onResult: (ConfirmationResult) -> Void

    @State private var editedBody: String = ""
    @State private var isEditing = false
    @FocusState private var bodyFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(payload.headerTitle)
                        .font(.headline)
                    Spacer()
                    Text(payload.badge)
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
                        onResult(.cancelled)
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
                        var updated = payload
                        if case .message(let c, let p, _, let raw) = updated {
                            updated = .message(contact: c, platform: p, body: editedBody, raw: raw)
                        }
                        onResult(.confirmed(updated))
                    } label: {
                        Text("Confirm").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 8)

                Spacer()
            }
            .padding()
            .navigationTitle("Confirm action")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                editedBody = payload.primaryBody
            }
        }
        .presentationDetents([.medium, .large])
    }
}
