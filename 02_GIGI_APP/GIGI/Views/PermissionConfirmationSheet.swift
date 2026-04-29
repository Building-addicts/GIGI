import SwiftUI

enum PermissionPayloadKind: String, Codable, Equatable {
    case message
    case calendarEvent
    case reminder
    case followUpTask
    case scheduleSwap
    case externalAction
}

struct PermissionField: Identifiable, Equatable {
    let key: String
    let label: String
    var value: String
    let isMultiline: Bool

    var id: String { key }
}

struct PermissionPayload: Identifiable, Equatable {
    let id: UUID
    let kind: PermissionPayloadKind
    let toolName: String
    let title: String
    let summary: String
    let confirmLabel: String
    var fields: [PermissionField]
    private let baseArgs: [String: String]

    init(
        id: UUID = UUID(),
        kind: PermissionPayloadKind,
        toolName: String,
        title: String,
        summary: String,
        confirmLabel: String = "Confirm",
        fields: [PermissionField],
        baseArgs: [String: String]
    ) {
        self.id = id
        self.kind = kind
        self.toolName = toolName
        self.title = title
        self.summary = summary
        self.confirmLabel = confirmLabel
        self.fields = fields
        self.baseArgs = baseArgs
    }

    var toolArgs: [String: Any] {
        var merged = baseArgs
        for field in fields {
            merged[field.key] = field.value
        }
        if kind == .message {
            if let body = merged["body"], !body.isEmpty { merged["message"] = body }
            if let message = merged["message"], !message.isEmpty { merged["body"] = message }
        }
        if kind == .calendarEvent {
            merged["confirmation_source"] = "permission_sheet"
        }
        return merged
    }

    func updating(fields newFields: [PermissionField]) -> PermissionPayload {
        PermissionPayload(
            id: id,
            kind: kind,
            toolName: toolName,
            title: title,
            summary: summary,
            confirmLabel: confirmLabel,
            fields: newFields,
            baseArgs: baseArgs
        )
    }

    static func make(toolName: String, args: [String: Any]) -> PermissionPayload {
        let stringArgs = args.reduce(into: [String: String]()) { partial, pair in
            if let value = pair.value as? String {
                partial[pair.key] = value
            } else {
                partial[pair.key] = "\(pair.value)"
            }
        }

        func value(_ keys: String..., fallback: String = "") -> String {
            for key in keys {
                if let found = stringArgs[key], !found.isEmpty { return found }
            }
            return fallback
        }

        switch toolName {
        case "send_message", "send_whatsapp", "web_whatsapp":
            let contact = value("contact", fallback: "Recipient")
            let body = value("body", "message")
            let platform = value("platform", fallback: toolName == "web_whatsapp" ? "whatsapp" : "imessage")
            return PermissionPayload(
                kind: .message,
                toolName: toolName,
                title: "Send message?",
                summary: "To \(contact) via \(platform)",
                confirmLabel: "Send",
                fields: [
                    PermissionField(key: "contact", label: "To", value: contact, isMultiline: false),
                    PermissionField(key: "body", label: "Message", value: body, isMultiline: true),
                    PermissionField(key: "platform", label: "Platform", value: platform, isMultiline: false)
                ],
                baseArgs: stringArgs
            )

        case "create_event", "create_calendar_event":
            let title = value("title", fallback: "Calendar event")
            let date = value("date", fallback: "today")
            let time = value("time", fallback: "12:00")
            return PermissionPayload(
                kind: .calendarEvent,
                toolName: toolName,
                title: "Create calendar event?",
                summary: "\(title) - \(date) \(time)",
                confirmLabel: "Create",
                fields: [
                    PermissionField(key: "title", label: "Title", value: title, isMultiline: false),
                    PermissionField(key: "date", label: "Date", value: date, isMultiline: false),
                    PermissionField(key: "time", label: "Time", value: time, isMultiline: false),
                    PermissionField(key: "contact", label: "Guest", value: value("contact"), isMultiline: false)
                ],
                baseArgs: stringArgs
            )

        case "set_reminder", "create_reminder":
            let text = value("text", "title", "raw", fallback: "Reminder")
            return PermissionPayload(
                kind: .reminder,
                toolName: toolName,
                title: "Create reminder?",
                summary: text,
                confirmLabel: "Create",
                fields: [
                    PermissionField(key: "text", label: "Reminder", value: text, isMultiline: true),
                    PermissionField(key: "date", label: "Date", value: value("date"), isMultiline: false),
                    PermissionField(key: "time", label: "Time", value: value("time"), isMultiline: false)
                ],
                baseArgs: stringArgs
            )

        case "create_follow_up_task":
            let title = value("title", "task", "text", fallback: "Follow-up task")
            return PermissionPayload(
                kind: .followUpTask,
                toolName: toolName,
                title: "Create follow-up task?",
                summary: title,
                confirmLabel: "Create",
                fields: [
                    PermissionField(key: "title", label: "Task", value: title, isMultiline: true),
                    PermissionField(key: "due", label: "Due", value: value("due", "date"), isMultiline: false)
                ],
                baseArgs: stringArgs
            )

        case "swap_schedule_slot":
            return PermissionPayload(
                kind: .scheduleSwap,
                toolName: toolName,
                title: "Swap schedule slot?",
                summary: value("summary", "reason", fallback: "Review the schedule change before applying it."),
                confirmLabel: "Apply",
                fields: [
                    PermissionField(key: "from", label: "Move from", value: value("from", "source"), isMultiline: false),
                    PermissionField(key: "to", label: "Move to", value: value("to", "target"), isMultiline: false),
                    PermissionField(key: "reason", label: "Reason", value: value("reason"), isMultiline: true)
                ],
                baseArgs: stringArgs
            )

        default:
            return PermissionPayload(
                kind: .externalAction,
                toolName: toolName,
                title: "Approve action?",
                summary: "GIGI needs your approval before continuing.",
                fields: stringArgs.keys.sorted().map {
                    PermissionField(key: $0, label: $0.replacingOccurrences(of: "_", with: " ").capitalized, value: stringArgs[$0] ?? "", isMultiline: false)
                },
                baseArgs: stringArgs
            )
        }
    }
}

enum PermissionConfirmationResult: Equatable {
    case confirmed(PermissionPayload)
    case edited(PermissionPayload)
    case cancelled
}

struct PermissionConfirmationSheet: View {
    let payload: PermissionPayload
    let onResult: (PermissionConfirmationResult) -> Void

    @State private var fields: [PermissionField]
    @State private var isEditing = false

    init(
        payload: PermissionPayload,
        onResult: @escaping (PermissionConfirmationResult) -> Void
    ) {
        self.payload = payload
        self.onResult = onResult
        _fields = State(initialValue: payload.fields)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach($fields) { $field in
                            fieldRow($field)
                        }
                    }
                    .padding(.vertical, 4)
                }

                actionBar
            }
            .padding(20)
            .navigationTitle("Review action")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onResult(.cancelled) }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .background(Color(.systemBackground))
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.purple)
                .frame(width: 34, height: 34)
                .background(Color.purple.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(payload.title)
                    .font(.headline)
                Text(payload.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: Binding<PermissionField>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.wrappedValue.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if isEditing {
                if field.wrappedValue.isMultiline {
                    TextEditor(text: field.value)
                        .frame(minHeight: 88)
                        .padding(8)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    TextField(field.wrappedValue.label, text: field.value)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                Text(field.wrappedValue.value.isEmpty ? "-" : field.wrappedValue.value)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                isEditing.toggle()
            } label: {
                Label(isEditing ? "Preview" : "Edit", systemImage: isEditing ? "eye" : "pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                let updated = payload.updating(fields: fields)
                onResult(isEditing ? .edited(updated) : .confirmed(updated))
            } label: {
                Label(payload.confirmLabel, systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var iconName: String {
        switch payload.kind {
        case .message: return "message.fill"
        case .calendarEvent: return "calendar.badge.plus"
        case .reminder: return "checklist"
        case .followUpTask: return "arrow.triangle.branch"
        case .scheduleSwap: return "arrow.left.arrow.right"
        case .externalAction: return "hand.raised.fill"
        }
    }
}
