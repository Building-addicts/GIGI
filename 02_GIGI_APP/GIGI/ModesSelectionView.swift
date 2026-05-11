import SwiftUI

// MARK: - ModesSelectionView
//
// Settings → Modes → user picks one of the 4 operating modes:
//   - Minimal         (Path 1 + Path 4)
//   - Local-First     (Path 1 + Path 2 + Path 3)
//   - Apple Optimized (Path 1 + Path 2 + Path 4)
//   - Full Power      (all 5 paths)
//
// Each card shows: name, summary, requirement checklist (✅/❌), privacy hint,
// latency hint, action button (Select / Setup). The active mode has a
// "ACTIVE" badge. Tapping Select persists the mode via `GigiModeDetector`
// and dismisses; the router picks it up on the next utterance without a
// restart.
//
// Reference: docs/plans/frolicking-stargazing-pancake.md §3.9
// ADR-0009 — Hardware targets and modes.

struct ModesSelectionView: View {
    @StateObject private var detector = GigiModeDetector.shared
    @AppStorage("gigi.user.mode") private var selectedRaw: String = GigiMode.fullPower.rawValue
    @State private var availabilities: [ModeAvailability] = []
    @State private var isRefreshing = false
    @Environment(\.dismiss) private var dismiss

    private var selectedMode: GigiMode {
        GigiMode(rawValue: selectedRaw) ?? .fullPower
    }

    var body: some View {
        List {
            Section {
                Text("GIGI runs in 4 operating modes. Pick the one that matches the hardware and services you have available.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            ForEach(GigiMode.allCases) { mode in
                modeCard(for: mode)
            }

            Section {
                Button {
                    Task {
                        isRefreshing = true
                        detector.invalidate()
                        availabilities = await detector.detectAvailableModes(force: true)
                        isRefreshing = false
                    }
                } label: {
                    HStack {
                        if isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Re-check availability")
                    }
                }
            }
        }
        .navigationTitle("Operating Mode")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            availabilities = await detector.detectAvailableModes()
        }
    }

    @ViewBuilder
    private func modeCard(for mode: GigiMode) -> some View {
        let availability = availabilities.first(where: { $0.mode == mode })
        let isAvailable = availability?.isAvailable ?? false
        let isSelected = selectedMode == mode

        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon(for: mode))
                        .font(.title3)
                        .foregroundColor(.accentColor)
                    Text(mode.displayName)
                        .font(.headline)
                    Spacer()
                    if isSelected {
                        Text("ACTIVE")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.2))
                            .foregroundColor(.green)
                            .clipShape(Capsule())
                    }
                }

                Text(mode.summary)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(mode.requirements, id: \.self) { req in
                        HStack(spacing: 6) {
                            Image(systemName: requirementSatisfied(req, availability: availability)
                                  ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(requirementSatisfied(req, availability: availability) ? .green : .red)
                            Text(req)
                                .font(.caption)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Label(mode.latencyHint, systemImage: "clock")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Label(mode.privacyHint, systemImage: "lock.shield")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }

                if let notes = availability?.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .italic()
                }

                Button {
                    if isAvailable {
                        detector.setMode(mode)
                        selectedRaw = mode.rawValue
                        dismiss()
                    }
                } label: {
                    Text(isSelected ? "Selected" : (isAvailable ? "Select" : "Setup required"))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(buttonBackground(isSelected: isSelected, isAvailable: isAvailable))
                        .foregroundColor(buttonForeground(isSelected: isSelected, isAvailable: isAvailable))
                        .cornerRadius(8)
                }
                .disabled(!isAvailable || isSelected)
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
        }
    }

    private func requirementSatisfied(_ req: String, availability: ModeAvailability?) -> Bool {
        guard let availability else { return false }
        if availability.isAvailable { return true }
        return !availability.missing.contains(req)
    }

    private func icon(for mode: GigiMode) -> String {
        switch mode {
        case .minimal:        return "circle.dashed"
        case .localFirst:     return "lock.shield.fill"
        case .appleOptimized: return "applelogo"
        case .fullPower:      return "bolt.fill"
        }
    }

    private func buttonBackground(isSelected: Bool, isAvailable: Bool) -> Color {
        if isSelected { return Color.green.opacity(0.18) }
        if isAvailable { return Color.accentColor }
        return Color.gray.opacity(0.18)
    }

    private func buttonForeground(isSelected: Bool, isAvailable: Bool) -> Color {
        if isSelected { return .green }
        if isAvailable { return .white }
        return .secondary
    }
}

#Preview {
    NavigationStack {
        ModesSelectionView()
    }
}
