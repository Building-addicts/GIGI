import SwiftUI

// MARK: - ShortcutProposalState (GATE 15 Step 2 — Plan Phase)
//
// Held on `GigiSmartOrchestrator.shortcutProposal` while a proposal card
// is on screen. `confirm` is fired when the user taps "Build Shortcut";
// `cancel` is fired on tap "Cancel" OR when the user just lets the
// 5-min server-side TTL run out. Both close paths clear the orchestrator
// state, so only one card can be visible at a time.

struct ShortcutAction: Identifiable, Equatable {
    let id = UUID()
    /// Cherri vocabulary action name (e.g. "torchOn", "waitSeconds").
    let name: String
    /// Pretty label for the user (e.g. "Turn flashlight on").
    let label: String
    /// SF Symbol or emoji used in the bullet column.
    let emoji: String
}

struct ShortcutProposalState: Identifiable, Equatable {
    let id = UUID()
    let planId: String
    let title: String
    let summary: String
    let actions: [ShortcutAction]
    /// Trigger phrases the registry will learn after install (Step 4).
    let aliases: [String]
    /// Canonical intent identifier (e.g. "torch_on") used as registry key.
    let systemPurpose: String
    /// User confirmed — start the Build Phase. Card removes itself.
    let onConfirm: () -> Void
    /// User dismissed — evict the plan server-side. Card removes itself.
    let onCancel: () -> Void

    static func == (lhs: ShortcutProposalState, rhs: ShortcutProposalState) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - ShortcutProposalCard (SwiftUI view)

struct ShortcutProposalCard: View {
    let state: ShortcutProposalState
    @State private var isBuilding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // ── Header ────────────────────────────────────────────────
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Proposed Shortcut")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                        .textCase(.uppercase)
                        .tracking(0.6)
                    Text(state.title)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                Spacer()
            }

            // ── Summary ──────────────────────────────────────────────
            if !state.summary.isEmpty {
                Text(state.summary)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // ── Action list ──────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(state.actions.enumerated()), id: \.offset) { idx, action in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(idx + 1).")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.45))
                            .frame(width: 22, alignment: .trailing)
                        Text(action.emoji)
                            .font(.system(size: 14))
                            .frame(width: 22, alignment: .center)
                        Text(action.label)
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.vertical, 4)

            // ── CTAs ──────────────────────────────────────────────────
            HStack(spacing: 10) {
                Button {
                    state.onCancel()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )
                }
                .disabled(isBuilding)

                Button {
                    isBuilding = true
                    state.onConfirm()
                } label: {
                    HStack(spacing: 6) {
                        if isBuilding {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "hammer.fill")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        Text(isBuilding ? "Building..." : "Build Shortcut")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(LinearGradient(
                                colors: [.purple, .pink],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                    )
                }
                .disabled(isBuilding)
            }

            // GATE 15 Step 0.5 — conversational consent hint.
            if !isBuilding {
                Text("Or say \u{201C}yes\u{201D} to build, \u{201C}no\u{201D} to cancel")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(white: 0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.purple.opacity(0.35), lineWidth: 1)
                )
        )
    }
}

// MARK: - Action pretty-printer
//
// Maps Cherri action names + params to a user-facing English sentence
// shown on the card. Must stay in sync with the harness vocabulary in
// `03_HARNESS/server/api/ios-build-shortcut.js`.

enum ShortcutActionRenderer {

    /// Convert a `[{action, params}]` payload from `/compose-shortcut/plan`
    /// into the typed list used by the card.
    static func render(actions: [[String: Any]]) -> [ShortcutAction] {
        actions.compactMap { dict in
            let name = (dict["action"] as? String) ?? ""
            let params = (dict["params"] as? [String: Any]) ?? [:]
            let (label, emoji) = describe(action: name, params: params)
            return ShortcutAction(name: name, label: label, emoji: emoji)
        }
    }

    private static func describe(action: String, params: [String: Any]) -> (String, String) {
        switch action {
        case "torchOn":
            return ("Turn flashlight on", "🔦")
        case "torchOff":
            return ("Turn flashlight off", "🌑")
        case "waitSeconds":
            let s = paramString(params["seconds"]) ?? "?"
            return ("Wait \(s) second\(s == "1" ? "" : "s")", "⏱️")
        case "showResult":
            let t = paramString(params["text"]) ?? ""
            return ("Show: \(quote(t))", "💬")
        case "showNotification":
            let t = paramString(params["text"]) ?? ""
            return ("Notify: \(quote(t))", "🔔")
        case "speakText":
            let t = paramString(params["text"]) ?? ""
            return ("Say: \(quote(t))", "🗣️")
        case "setClipboard":
            let t = paramString(params["text"]) ?? ""
            return ("Copy to clipboard: \(quote(t))", "📋")
        case "setBrightness":
            let b = paramString(params["brightness"]) ?? "?"
            let pct = percentString(from: b)
            return ("Set screen brightness to \(pct)", "🔆")
        case "setVolume":
            let l = paramString(params["level"]) ?? "?"
            let pct = percentString(from: l)
            return ("Set volume to \(pct)", "🔊")
        case "playMusic":
            return ("Play music", "▶️")
        case "pauseMusic":
            return ("Pause music", "⏸️")
        case "skipForward":
            return ("Skip to next track", "⏭️")
        case "skipBackward":
            return ("Skip to previous track", "⏮️")
        case "openApp":
            let id = paramString(params["appID"]) ?? "an app"
            return ("Open \(friendlyApp(bundleID: id))", "📱")
        default:
            return ("Run \(action)", "⚙️")
        }
    }

    private static func paramString(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func quote(_ s: String) -> String {
        s.isEmpty ? "(empty)" : "\u{201C}\(s)\u{201D}"
    }

    private static func percentString(from raw: String) -> String {
        if let d = Double(raw) {
            let pct = d <= 1.0 ? d * 100 : d
            return "\(Int(pct.rounded()))%"
        }
        return raw
    }

    private static func friendlyApp(bundleID id: String) -> String {
        switch id {
        case "com.spotify.client":    return "Spotify"
        case "com.apple.mobilesafari": return "Safari"
        case "com.apple.MobileSMS":   return "Messages"
        case "com.apple.Maps":        return "Maps"
        case "com.google.chrome.ios": return "Chrome"
        case "com.instagram.app":     return "Instagram"
        case "com.apple.mobilemail":  return "Mail"
        case "com.apple.Music":       return "Music"
        case "com.apple.MobileNotes": return "Notes"
        default:
            // strip leading "com.<something>." to get a hint
            let parts = id.split(separator: ".")
            if let last = parts.last, last.count > 2 {
                return String(last).capitalized
            }
            return id
        }
    }
}
