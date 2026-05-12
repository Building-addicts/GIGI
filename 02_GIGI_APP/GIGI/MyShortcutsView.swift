import SwiftUI

// MARK: - MyShortcutsView (GATE 14.B.2 lite — Settings → Shortcuts Integration)
//
// User-facing list + editor for Apple Shortcuts that GIGI can invoke. Two
// integration patterns supported:
//
// 1. SYSTEM-PURPOSE Shortcuts — e.g. "GIGI Append to Note" tagged with
//    systemPurpose="append_to_note". GIGI internal handlers (like
//    `addToNote` in GigiActionBridge) look these up by purpose and use
//    the Shortcut to bypass Apple's closed APIs.
//
// 2. ALIAS Shortcuts — e.g. user-installed "accendi torcia" with alias
//    "open torch". GigiRequestRouter intercepts the alias and dispatches
//    `run_shortcut` directly. Lets the user invoke their Shortcuts with
//    natural language without saying "run X".
//
// All user-facing strings in English per CLAUDE.md §Lingua hard rule.

struct MyShortcutsView: View {

    @ObservedObject private var registry = GigiShortcutRegistry.shared
    @State private var editing: RegisteredShortcut?
    @State private var showAddSheet = false

    var body: some View {
        List {
            instructionsSection

            if registry.shortcuts.isEmpty {
                emptyStateSection
            } else {
                shortcutListSection
            }

            suggestedSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("My Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Shortcut", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            ShortcutEditorSheet(shortcut: nil) { saved in
                if let s = saved { registry.register(s) }
                showAddSheet = false
            }
        }
        .sheet(item: $editing) { sc in
            ShortcutEditorSheet(shortcut: sc) { saved in
                if let s = saved { registry.register(s) }
                editing = nil
            }
        }
    }

    // MARK: - Sections

    private var instructionsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Use Apple Shortcuts to extend GIGI past Apple's closed APIs (Notes, Reminders, Health, etc).")
                    .font(.subheadline)
                Text("Register a Shortcut here, optionally with aliases like \"open torch\", and GIGI will invoke it on voice or chat commands.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("How it works")
        }
    }

    private var emptyStateSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("No Shortcuts registered yet")
                    .foregroundColor(.secondary)
                Text("Tap + to add one. Or pick one of the suggested integrations below.")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .padding(.vertical, 4)
        }
    }

    private var shortcutListSection: some View {
        Section {
            ForEach(registry.shortcuts) { sc in
                Button {
                    editing = sc
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "command.square.fill")
                            .foregroundColor(sc.enabled ? .purple : .secondary)
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(sc.name)
                                    .font(.body.weight(.medium))
                                    .foregroundColor(.primary)
                                if !sc.enabled {
                                    Text("DISABLED")
                                        .font(.caption2.weight(.bold))
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.2))
                                        .cornerRadius(4)
                                }
                            }
                            if let purpose = sc.systemPurpose {
                                Text("Purpose: \(purposeLabel(purpose))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if !sc.aliases.isEmpty {
                                Text("Aliases: \(sc.aliases.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            if sc.useCount > 0 {
                                Text("Used \(sc.useCount) time\(sc.useCount == 1 ? "" : "s")")
                                    .font(.caption2)
                                    .foregroundColor(.secondary.opacity(0.7))
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
            .onDelete { offsets in
                for idx in offsets {
                    let sc = registry.shortcuts[idx]
                    registry.unregister(name: sc.name)
                }
            }
        } header: {
            Text("Registered Shortcuts")
        }
    }

    private var suggestedSection: some View {
        Section {
            ForEach(suggestedShortcuts, id: \.name) { suggested in
                let alreadyRegistered = registry.shortcuts.contains { $0.id == suggested.id }
                Button {
                    if !alreadyRegistered {
                        editing = suggested
                    }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: alreadyRegistered ? "checkmark.circle.fill" : "plus.circle")
                            .foregroundColor(alreadyRegistered ? .green : .purple)
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(suggested.name)
                                .font(.body.weight(.medium))
                                .foregroundColor(.primary)
                            Text(suggested.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if alreadyRegistered {
                                Text("Already registered")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .disabled(alreadyRegistered)
            }
        } header: {
            Text("Suggested integrations")
        } footer: {
            Text("Tap a suggestion to register it. You'll still need to create the Shortcut in Apple's Shortcuts app with the exact name.")
                .font(.caption)
        }
    }

    // MARK: - Helpers

    private func purposeLabel(_ raw: String) -> String {
        switch raw {
        case "append_to_note":  return "Append to Note"
        case "create_reminder": return "Create Reminder"
        case "log_health":      return "Log Health Entry"
        case "control_torch":   return "Control Torch"
        default:                return raw
        }
    }

    private var suggestedShortcuts: [RegisteredShortcut] {
        [
            RegisteredShortcut(
                name: "GIGI Append to Note",
                aliases: [],
                description: "Receives 'title|content' text input, finds your Note with that title, and appends the content. Used by GIGI's add_to_note tool.",
                enabled: true,
                systemPurpose: "append_to_note"
            ),
            RegisteredShortcut(
                name: "GIGI Quick Reminder",
                aliases: [],
                description: "Receives 'title|date' text input and creates a Reminder. Used by GIGI's set_reminder tool when iOS native EventKit isn't sufficient.",
                enabled: true,
                systemPurpose: "create_reminder"
            )
        ]
    }
}

// MARK: - ShortcutEditorSheet

private struct ShortcutEditorSheet: View {

    let shortcut: RegisteredShortcut?
    let onSave: (RegisteredShortcut?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var aliasesText: String = ""
    @State private var description: String = ""
    @State private var systemPurpose: String = ""
    @State private var enabled: Bool = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Shortcut name (must match Shortcuts app exactly)", text: $name)
                        .textInputAutocapitalization(.words)
                    Toggle("Enabled", isOn: $enabled)
                } header: {
                    Text("Shortcut")
                } footer: {
                    Text("Must match the EXACT name you used in the Shortcuts app (case-insensitive).")
                        .font(.caption)
                }

                Section {
                    TextField("Aliases, comma-separated", text: $aliasesText, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("Aliases (optional)")
                } footer: {
                    Text("Natural-language phrases that trigger this Shortcut. Example for a 'Torch Toggle' Shortcut: open torch, flashlight on, light it up.")
                        .font(.caption)
                }

                Section {
                    Picker("Purpose", selection: $systemPurpose) {
                        Text("None (alias only)").tag("")
                        Text("Append to Note").tag("append_to_note")
                        Text("Create Reminder").tag("create_reminder")
                        Text("Log Health Entry").tag("log_health")
                        Text("Control Torch").tag("control_torch")
                    }
                } header: {
                    Text("System integration (optional)")
                } footer: {
                    Text("When set, GIGI uses this Shortcut for the matching internal action (e.g. 'Append to Note' wires this Shortcut into the add_to_note tool).")
                        .font(.caption)
                }

                Section {
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("Notes")
                }

                if shortcut == nil {
                    Section {
                        howToCreateInstructions
                    } header: {
                        Text("How to create this Shortcut on your iPhone")
                    }
                }
            }
            .navigationTitle(shortcut == nil ? "New Shortcut" : "Edit Shortcut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onSave(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let sc = shortcut {
                    name = sc.name
                    aliasesText = sc.aliases.joined(separator: ", ")
                    description = sc.description
                    systemPurpose = sc.systemPurpose ?? ""
                    enabled = sc.enabled
                }
            }
        }
    }

    private var howToCreateInstructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            instructionStep(1, "Open the Shortcuts app on this iPhone.")
            instructionStep(2, "Tap + (top right) to create a new Shortcut.")
            instructionStep(3, "Name it EXACTLY as you typed above.")
            instructionStep(4, "Add the actions your Shortcut should run. For 'Append to Note': Get Input → Split Text on '|' → Get Item from List (first = title, second = content) → Find Notes Where Name is title → Append content.")
            instructionStep(5, "Save. Come back here and tap Save.")
        }
        .padding(.vertical, 4)
    }

    private func instructionStep(_ num: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(num).")
                .font(.subheadline.weight(.bold))
                .foregroundColor(.purple)
                .frame(width: 20, alignment: .leading)
            Text(text)
                .font(.subheadline)
        }
    }

    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        let aliases = aliasesText
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let purposeOrNil: String? = systemPurpose.isEmpty ? nil : systemPurpose
        var newShortcut = RegisteredShortcut(
            name: cleanName,
            aliases: aliases,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: enabled,
            systemPurpose: purposeOrNil
        )
        if let existing = shortcut {
            newShortcut.useCount = existing.useCount
            newShortcut.lastUsedAt = existing.lastUsedAt
        }
        onSave(newShortcut)
    }
}

#Preview {
    NavigationStack {
        MyShortcutsView()
    }
    .preferredColorScheme(.dark)
}
