import SwiftUI

// MARK: - ContactDisambiguationBubble
//
// Inline chat bubble for bug #017 contact disambiguation. Rendered by
// ChatView when GigiActionBridge presents a 2+ match contact resolution
// request. The bubble looks like a GIGI message asking "Which Marco?"
// followed by tappable rows showing name + phone number for each
// candidate, plus a Cancel option.
//
// Tapping a row resolves the suspended CheckedContinuation in
// disambiguateContact() and clears the orchestrator state. Tapping
// Cancel resolves with nil → caller surfaces "Call cancelled."
//
// Why inline (not a system sheet):
//   - Maintains conversational tone — feels like GIGI asking a question
//   - User sees phone numbers next to ambiguous names (key disambiguator)
//   - System confirmationDialog cannot render phone subtext
//   - Stays inside the chat flow; the user's next utterance after the
//     pick can immediately follow visually.
//
// Bug-017 v6 — same-first-name handling:
//   Two contacts with identical first name AND no surname are a real
//   user case (two "Fede" entries). The bubble now:
//     - Header collapses to "Which Fede do you mean?" instead of the
//       absurd "Which Fede? Fede or Fede?"
//     - Each row surfaces phone label (Mobile/Home/Work) and, when
//       names tie, organization as a tertiary line
//     - A small ordinal badge (1/2/3) overlaps the avatar so the
//       user can confidently say "the first" / "the second"

struct ContactDisambiguationBubble: View {

    let state: GigiSmartOrchestrator.ContactDisambiguationState

    @ObservedObject private var orchestrator = GigiSmartOrchestrator.shared

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Purple bullet — same visual anchor used by GIGI MessageBubble
            Circle()
                .fill(Color.purple)
                .frame(width: 6, height: 6)
                .padding(.top, 16)

            VStack(alignment: .leading, spacing: 12) {
                // Header — GIGI is asking conversationally
                Text(headerText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)

                Text(subHeaderText)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))

                // Candidate rows — sorted so the previously-chosen contact
                // (memorized in GigiMemory.contact_alias) appears FIRST,
                // marked with a "Last call" badge for one-tap re-selection.
                VStack(spacing: 8) {
                    ForEach(Array(sortedCandidates.enumerated()), id: \.element.id) { index, candidate in
                        Button {
                            choose(candidate)
                        } label: {
                            candidateRow(
                                candidate,
                                ordinal: index + 1,
                                isLastUsed: isLastUsed(candidate)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Cancel option
                Button {
                    cancel()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.purple.opacity(0.22), lineWidth: 1)
            )
            .cornerRadius(14)

            Spacer(minLength: 24)
        }
    }

    // MARK: - Sub-views

    private func candidateRow(
        _ candidate: GigiSmartOrchestrator.ContactCandidate,
        ordinal: Int,
        isLastUsed: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            // Avatar with ordinal badge (1/2/3) bottom-right — anchors the
            // "say 'the first' / 'the second'" affordance when names are
            // visually identical.
            ZStack(alignment: .bottomTrailing) {
                avatarView(for: candidate)
                if needsOrdinalBadge {
                    Text("\(ordinal)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .frame(width: 16, height: 16)
                        .background(Color.purple)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(displayName(for: candidate, ordinal: ordinal))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                    if isLastUsed {
                        Text("Last call")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(.purple)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.18))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.purple.opacity(0.45), lineWidth: 0.5)
                            )
                            .cornerRadius(4)
                    }
                }
                // Subtitle: phone label + number (e.g. "Mobile · +39 380 …")
                Text(phoneLine(for: candidate))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))

                // Tertiary line: organization, only when first-line name
                // collisions exist (otherwise it's noise).
                if allNamesIdentical, let org = candidate.organization {
                    Text(org)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isLastUsed ? Color.purple.opacity(0.10) : Color.white.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isLastUsed ? Color.purple.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .cornerRadius(10)
        .contentShape(Rectangle())
    }

    // MARK: - Sorting

    /// Returns candidates with the previously-chosen contact (state.lastUsedName)
    /// moved to position 0. Stable order for the rest.
    private var sortedCandidates: [GigiSmartOrchestrator.ContactCandidate] {
        guard let last = state.lastUsedName?.lowercased(), !last.isEmpty else {
            return state.candidates
        }
        var ordered = state.candidates
        if let idx = ordered.firstIndex(where: { $0.name.lowercased() == last }), idx != 0 {
            let pinned = ordered.remove(at: idx)
            ordered.insert(pinned, at: 0)
        }
        return ordered
    }

    private func isLastUsed(_ candidate: GigiSmartOrchestrator.ContactCandidate) -> Bool {
        guard let last = state.lastUsedName?.lowercased() else { return false }
        return candidate.name.lowercased() == last
    }

    /// True when every candidate has the exact same lowercased name OR all
    /// candidates have an empty/whitespace-only name. Triggers the fallback
    /// header copy and the ordinal badge.
    private var allNamesIdentical: Bool {
        let names = Set(state.candidates.map {
            $0.name.lowercased().trimmingCharacters(in: .whitespaces)
        })
        return names.count <= 1
    }

    /// Show the ordinal badge whenever the visible labels are ambiguous —
    /// either names tie OR any candidate has an empty name.
    private var needsOrdinalBadge: Bool {
        allNamesIdentical || state.candidates.contains(where: {
            $0.name.trimmingCharacters(in: .whitespaces).isEmpty
        })
    }

    @ViewBuilder
    private func avatarView(for candidate: GigiSmartOrchestrator.ContactCandidate) -> some View {
        if let data = candidate.photoData, let ui = UIImage(data: data) {
            Image(uiImage: ui)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 34, height: 34)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
        } else {
            Text(initials(for: candidate.name.isEmpty ? state.query : candidate.name))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(Color.purple.opacity(0.45))
                .clipShape(Circle())
        }
    }

    // MARK: - Helpers

    /// Header phrasing — adapts to candidate-name shape so we never produce
    /// the absurd "Which Fede? Fede or Fede?" output (real case when two
    /// contacts share the exact same first name AND no surname).
    private var headerText: String {
        let q = state.query.capitalized
        if allNamesIdentical {
            return "Which \(q) do you mean?"
        }
        if state.candidates.count == 2 {
            let names = state.candidates.map { $0.name }.joined(separator: " or ")
            return "Which \(q)? \(names)?"
        }
        return "Which \(q) do you mean?"
    }

    /// Sub-header — explicit affordance for conversational reply.
    /// Designed for voice-first: even if the bubble is visual today, the
    /// copy frames the dialog as something the user can ANSWER (text or
    /// voice when wired). Tap remains a shortcut.
    private var subHeaderText: String {
        if allNamesIdentical {
            return "Say the number or say 'first' / 'second' — or just tap."
        }
        return "Tell me the name (or number), or just tap below."
    }

    /// Primary line for a row — falls back to "<Name> #N" when first names
    /// tie so the visible label is never two identical "Fede" strings.
    private func displayName(
        for candidate: GigiSmartOrchestrator.ContactCandidate,
        ordinal: Int
    ) -> String {
        let raw = candidate.name.isEmpty ? state.query : candidate.name
        guard allNamesIdentical else { return raw }
        return "\(raw) #\(ordinal)"
    }

    /// Phone line — "Mobile · +39 380 654 8643" when a label exists,
    /// otherwise just the prettified number.
    private func phoneLine(for candidate: GigiSmartOrchestrator.ContactCandidate) -> String {
        let pretty = prettyPhone(candidate.phone)
        if let label = candidate.phoneLabel, !label.isEmpty {
            return "\(label) · \(pretty)"
        }
        return pretty
    }

    private func initials(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        let words = trimmed.split(separator: " ").prefix(2)
        let chars = words.compactMap { $0.first }.map(String.init)
        return chars.joined().uppercased()
    }

    /// Format `+393756548643` → `+39 375 654 8643` (best-effort, falls back
    /// to the raw string when the digit count is unfamiliar).
    private func prettyPhone(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        let hasPlus = raw.contains("+")
        let body: String

        switch digits.count {
        case 12:  // Italian / EU style: CC(2) + 3 + 3 + 4
            let cc = String(digits.prefix(2))
            let rest = String(digits.dropFirst(2))
            let p1 = String(rest.prefix(3))
            let p2 = String(rest.dropFirst(3).prefix(3))
            let p3 = String(rest.dropFirst(6))
            body = "\(cc) \(p1) \(p2) \(p3)"
        case 11:  // US/UK style: 1 + 3 + 3 + 4
            let cc = String(digits.prefix(1))
            let rest = String(digits.dropFirst(1))
            let p1 = String(rest.prefix(3))
            let p2 = String(rest.dropFirst(3).prefix(3))
            let p3 = String(rest.dropFirst(6))
            body = "\(cc) \(p1) \(p2) \(p3)"
        case 10:  // bare 10-digit
            let p1 = String(digits.prefix(3))
            let p2 = String(digits.dropFirst(3).prefix(3))
            let p3 = String(digits.dropFirst(6))
            body = "\(p1) \(p2) \(p3)"
        default:
            return raw  // unknown format; return as-is to avoid mangling
        }

        return hasPlus ? "+\(body)" : body
    }

    // MARK: - Actions

    private func choose(_ candidate: GigiSmartOrchestrator.ContactCandidate) {
        // Resolve the suspended continuation BEFORE clearing the state so the
        // bridge's await completes deterministically.
        state.completion(candidate)
        orchestrator.contactDisambiguation = nil
    }

    private func cancel() {
        state.completion(nil)
        orchestrator.contactDisambiguation = nil
    }
}
