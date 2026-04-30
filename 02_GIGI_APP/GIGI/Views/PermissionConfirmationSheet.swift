import SwiftUI

// MARK: - PermissionPayload
//
// Generic payload presented to the user before any meaningful action runs.
// One case per category of action that needs explicit approval.

enum PermissionPayload: Identifiable, Equatable {
    case message(contact: String, body: String, platform: String)
    case calendarEvent(title: String, date: String, time: String, contact: String)
    case reminder(text: String, date: String, time: String)
    case followUpTask(text: String)
    case scheduleSwap(summary: String, fromSlot: String, toSlot: String)

    var id: String {
        switch self {
        case .message(let c, let b, let p):           return "msg:\(p):\(c):\(b.prefix(40))"
        case .calendarEvent(let t, let d, let h, _):  return "cal:\(t):\(d):\(h)"
        case .reminder(let t, let d, let h):          return "rem:\(t):\(d):\(h)"
        case .followUpTask(let t):                    return "fut:\(t)"
        case .scheduleSwap(let s, let f, let to):     return "swp:\(s):\(f)->\(to)"
        }
    }

    var headerIcon: String {
        switch self {
        case .message:        return "paperplane.fill"
        case .calendarEvent:  return "calendar.badge.plus"
        case .reminder:       return "bell.badge.fill"
        case .followUpTask:   return "checkmark.circle.fill"
        case .scheduleSwap:   return "arrow.left.arrow.right.circle.fill"
        }
    }

    var headerTitle: String {
        switch self {
        case .message:        return "Send message?"
        case .calendarEvent:  return "Add to calendar?"
        case .reminder:       return "Create reminder?"
        case .followUpTask:   return "Add follow-up task?"
        case .scheduleSwap:   return "Swap schedule slot?"
        }
    }

    var primaryActionLabel: String {
        switch self {
        case .message:        return "Send"
        case .calendarEvent:  return "Add"
        case .reminder:       return "Create"
        case .followUpTask:   return "Add"
        case .scheduleSwap:   return "Swap"
        }
    }
}

// MARK: - ConfirmationResult

enum ConfirmationResult {
    case confirmed(PermissionPayload)
    case edited(PermissionPayload)
    case cancelled

    var label: String {
        switch self {
        case .confirmed: return "confirmed"
        case .edited:    return "edited"
        case .cancelled: return "cancelled"
        }
    }
}

// MARK: - Tool ↔ Payload mapping

extension PermissionPayload {
    /// Build a payload from an LLM tool call. Returns nil if the tool name is not
    /// in the permission-gated set covered by this UI.
    static func from(toolName: String, args: [String: Any]) -> PermissionPayload? {
        func s(_ k: String) -> String { (args[k] as? String) ?? "" }
        switch toolName {
        case "send_message":
            let body = s("body")
            guard !s("contact").isEmpty, !body.isEmpty else { return nil }
            return .message(contact: s("contact"), body: body, platform: s("platform").isEmpty ? "imessage" : s("platform"))
        case "web_whatsapp", "send_whatsapp":
            guard !s("contact").isEmpty, !s("message").isEmpty else { return nil }
            return .message(contact: s("contact"), body: s("message"), platform: "whatsapp")
        case "create_event":
            guard !s("title").isEmpty else { return nil }
            return .calendarEvent(title: s("title"), date: s("date"), time: s("time"), contact: s("contact"))
        case "set_reminder":
            guard !s("text").isEmpty else { return nil }
            return .reminder(text: s("text"), date: s("date"), time: s("time"))
        default:
            return nil
        }
    }

    /// Convert the (possibly edited) payload back into the args dict for tool execution.
    var toolArgs: [String: Any] {
        switch self {
        case .message(let contact, let body, let platform):
            // Cover both send_message and web_whatsapp arg shapes; extra keys are ignored.
            return ["contact": contact, "body": body, "message": body, "platform": platform]
        case .calendarEvent(let title, let date, let time, let contact):
            return ["title": title, "date": date, "time": time, "contact": contact]
        case .reminder(let text, let date, let time):
            return ["text": text, "date": date, "time": time]
        case .followUpTask(let text):
            return ["text": text]
        case .scheduleSwap(let summary, let from, let to):
            return ["summary": summary, "from": from, "to": to]
        }
    }
}

// MARK: - PermissionConfirmationSheet

struct PermissionConfirmationSheet: View {
    let initialPayload: PermissionPayload
    let onResult: (ConfirmationResult) -> Void

    @State private var payload: PermissionPayload
    @State private var isEditing: Bool = false
    @State private var hasEdits: Bool = false
    @Environment(\.dismiss) private var dismiss

    init(payload: PermissionPayload, onResult: @escaping (ConfirmationResult) -> Void) {
        self.initialPayload = payload
        self.onResult = onResult
        self._payload = State(initialValue: payload)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 24)
                .padding(.bottom, 16)

            preview
                .padding(.horizontal, 20)

            Spacer(minLength: 24)

            actionButtons
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemBackground))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $isEditing) {
            PermissionEditSheet(payload: $payload) { edited in
                hasEdits = true
                payload = edited
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: payload.headerIcon)
                .font(.system(size: 38, weight: .semibold))
                .foregroundColor(.purple)
            Text(payload.headerTitle)
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text("GIGI needs your approval before this runs.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch payload {
            case .message(let contact, let body, let platform):
                row(label: "To", value: contact)
                row(label: "Via", value: platform.capitalized)
                row(label: "Message", value: body, multiline: true)
            case .calendarEvent(let title, let date, let time, let contact):
                row(label: "Title", value: title)
                row(label: "Date", value: date)
                row(label: "Time", value: time)
                if !contact.isEmpty { row(label: "With", value: contact) }
            case .reminder(let text, let date, let time):
                row(label: "Reminder", value: text, multiline: true)
                if !date.isEmpty { row(label: "Date", value: date) }
                if !time.isEmpty { row(label: "Time", value: time) }
            case .followUpTask(let text):
                row(label: "Task", value: text, multiline: true)
            case .scheduleSwap(let summary, let from, let to):
                row(label: "Summary", value: summary, multiline: true)
                row(label: "From", value: from)
                row(label: "To", value: to)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    private func row(label: String, value: String, multiline: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 15))
                .foregroundColor(.primary)
                .lineLimit(multiline ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: Buttons

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                onResult(hasEdits ? .edited(payload) : .confirmed(payload))
                dismiss()
            } label: {
                Text(payload.primaryActionLabel)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.purple)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }

            HStack(spacing: 10) {
                Button {
                    isEditing = true
                } label: {
                    Text("Edit")
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(uiColor: .tertiarySystemBackground))
                        .foregroundColor(.primary)
                        .cornerRadius(10)
                }
                Button {
                    onResult(.cancelled)
                    dismiss()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(uiColor: .tertiarySystemBackground))
                        .foregroundColor(.red)
                        .cornerRadius(10)
                }
            }
        }
    }
}

// MARK: - PermissionEditSheet
//
// Inline-edit modal. Only string fields exposed — DatePicker etc. left out
// for the demo MVP; the LLM round-trip handles structured time parsing already.

private struct PermissionEditSheet: View {
    @Binding var payload: PermissionPayload
    let onSave: (PermissionPayload) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var draft: PermissionPayload

    init(payload: Binding<PermissionPayload>, onSave: @escaping (PermissionPayload) -> Void) {
        self._payload = payload
        self.onSave = onSave
        self._draft = State(initialValue: payload.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                editorSection
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        payload = draft
                        onSave(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var editorSection: some View {
        switch draft {
        case .message(let contact, let body, let platform):
            Section {
                stringField(label: "To", value: contact) { v in
                    draft = .message(contact: v, body: body, platform: platform)
                }
                stringField(label: "Message", value: body, multiline: true) { v in
                    draft = .message(contact: contact, body: v, platform: platform)
                }
                stringField(label: "Platform", value: platform) { v in
                    draft = .message(contact: contact, body: body, platform: v)
                }
            }
        case .calendarEvent(let title, let date, let time, let contact):
            Section {
                stringField(label: "Title", value: title) { v in
                    draft = .calendarEvent(title: v, date: date, time: time, contact: contact)
                }
                stringField(label: "Date", value: date) { v in
                    draft = .calendarEvent(title: title, date: v, time: time, contact: contact)
                }
                stringField(label: "Time", value: time) { v in
                    draft = .calendarEvent(title: title, date: date, time: v, contact: contact)
                }
                stringField(label: "With", value: contact) { v in
                    draft = .calendarEvent(title: title, date: date, time: time, contact: v)
                }
            }
        case .reminder(let text, let date, let time):
            Section {
                stringField(label: "Reminder", value: text, multiline: true) { v in
                    draft = .reminder(text: v, date: date, time: time)
                }
                stringField(label: "Date", value: date) { v in
                    draft = .reminder(text: text, date: v, time: time)
                }
                stringField(label: "Time", value: time) { v in
                    draft = .reminder(text: text, date: date, time: v)
                }
            }
        case .followUpTask(let text):
            Section {
                stringField(label: "Task", value: text, multiline: true) { v in
                    draft = .followUpTask(text: v)
                }
            }
        case .scheduleSwap(let summary, let from, let to):
            Section {
                stringField(label: "Summary", value: summary, multiline: true) { v in
                    draft = .scheduleSwap(summary: v, fromSlot: from, toSlot: to)
                }
                stringField(label: "From", value: from) { v in
                    draft = .scheduleSwap(summary: summary, fromSlot: v, toSlot: to)
                }
                stringField(label: "To", value: to) { v in
                    draft = .scheduleSwap(summary: summary, fromSlot: from, toSlot: v)
                }
            }
        }
    }

    private func stringField(label: String, value: String, multiline: Bool = false, onCommit: @escaping (String) -> Void) -> some View {
        let binding = Binding<String>(
            get: { value },
            set: { onCommit($0) }
        )
        return VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundColor(.secondary)
            if multiline {
                TextField("", text: binding, axis: .vertical)
                    .lineLimit(2...6)
            } else {
                TextField("", text: binding)
            }
        }
    }
}
