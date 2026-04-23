import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - GigiLiveActivityWidget
//
// Solo estensione Widget: nessuna API dell'app (es. UIApplication.shared).
// `GigiActivityAttributes` e `GigiPhase` vivono nel file condiviso nel target.

struct GigiLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GigiActivityAttributes.self) { context in
            LockScreenBannerView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedLeadingView(phase: context.state.phase)
                }
                DynamicIslandExpandedRegion(.center) {
                    ExpandedCenterView(
                        phase: context.state.phase,
                        message: displayMessage(state: context.state, isStale: context.isStale)
                    )
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTrailingView(phase: context.state.phase)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottomView(phase: context.state.phase)
                }
            } compactLeading: {
                CompactLeadingView(phase: context.state.phase)
            } compactTrailing: {
                CompactTrailingView(
                    message: displayMessage(state: context.state, isStale: context.isStale),
                    phase: context.state.phase,
                    isStale: context.isStale
                )
            } minimal: {
                MinimalIslandView(phase: context.state.phase)
            }
            .widgetURL(URL(string: "gigi://listen"))
            .keylineTint(GigiBrand.purple)
        }
    }
}

// MARK: - Stale / copy

private func displayMessage(state: GigiActivityAttributes.ContentState, isStale: Bool) -> String {
    if isStale {
        return "Waiting for updates…"
    }
    let trimmed = state.message.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return state.phase.displayName
    }
    return state.message
}

// MARK: - Design tokens

private enum GigiBrand {
    static let purple = Color(red: 0.58, green: 0.33, blue: 0.98)
    static let successGreen = Color(red: 0.12, green: 0.52, blue: 0.32)
}

// MARK: - Lock Screen / Banner

private struct LockScreenBannerView: View {
    let context: ActivityViewContext<GigiActivityAttributes>

    private var message: String {
        displayMessage(state: context.state, isStale: context.isStale)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            LockScreenIconView(phase: context.state.phase)

            Text(message)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(context.isStale ? 0.55 : 0.92))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)

            LockScreenPhaseIndicator(phase: context.state.phase, isStale: context.isStale)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                }
        }
    }
}

private struct LockScreenIconView: View {
    let phase: GigiPhase

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [GigiBrand.purple.opacity(0.35), GigiBrand.purple.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 46, height: 46)
                .overlay {
                    Circle()
                        .strokeBorder(GigiBrand.purple.opacity(0.35), lineWidth: 1)
                }
            PhaseIconView(phase: phase, size: 22)
        }
    }
}

private struct LockScreenPhaseIndicator: View {
    let phase: GigiPhase
    let isStale: Bool

    var body: some View {
        if isStale {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .symbolEffect(.pulse, options: .repeating.speed(0.55))
        } else {
            switch phase {
            case .listening, .thinking, .executing:
                PhasePillDots(phase: phase)
            case .done:
                PhaseIconView(phase: .done, size: 20)
            }
        }
    }
}

// MARK: - Dynamic Island — Compact

private struct CompactLeadingView: View {
    let phase: GigiPhase

    var body: some View {
        ZStack {
            Circle()
                .fill(GigiBrand.purple.opacity(0.28))
                .frame(width: 24, height: 24)
                .overlay {
                    Circle()
                        .strokeBorder(GigiBrand.purple.opacity(0.45), lineWidth: 0.75)
                }
            PhaseIconView(phase: phase, size: 11, weight: .bold)
        }
        .padding(.leading, 4)
    }
}

private struct CompactTrailingView: View {
    let message: String
    let phase: GigiPhase
    let isStale: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(message)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.opacity)

            if !isStale, phase != .done {
                CompactTrailingPulseDot(color: phase.executingWarmColor)
            }
        }
        .padding(.trailing, 4)
    }
}

private struct CompactTrailingPulseDot: View {
    let color: Color

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 6, weight: .black))
            .foregroundStyle(color)
            .symbolEffect(.pulse, options: .repeating.speed(1.05))
    }
}

private struct MinimalIslandView: View {
    let phase: GigiPhase

    var body: some View {
        PhaseIconView(phase: phase, size: 13)
    }
}

// MARK: - Dynamic Island — Expanded

private struct ExpandedLeadingView: View {
    let phase: GigiPhase

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [GigiBrand.purple.opacity(0.45), GigiBrand.purple.opacity(0.08)],
                        center: .center,
                        startRadius: 2,
                        endRadius: 36
                    )
                )
                .frame(width: 56, height: 56)
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                }
            PhaseIconView(phase: phase, size: 28)
        }
        .padding(.leading, 6)
    }
}

private struct ExpandedCenterView: View {
    let phase: GigiPhase
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(phase.displayName)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .contentTransition(.opacity)

            Text(message)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

private struct ExpandedTrailingView: View {
    let phase: GigiPhase

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("GIGI")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(GigiBrand.purple)
            Capsule()
                .fill(phase.phaseRibbonTint.opacity(0.85))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
        }
        .padding(.trailing, 8)
    }
}

private struct ExpandedBottomView: View {
    let phase: GigiPhase

    var body: some View {
        PhaseProgressRibbon(phase: phase)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
    }
}

// MARK: - Shared visuals

private struct PhasePillDots: View {
    let phase: GigiPhase

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(phase.phaseRibbonTint)
                    .frame(width: 5, height: 5)
                    .opacity(0.35 + Double(i) * 0.28)
            }
        }
    }
}

private struct PhaseProgressRibbon: View {
    let phase: GigiPhase

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 5)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [phase.phaseRibbonTint, phase.phaseRibbonTint.opacity(0.65)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: ribbonWidth(total: w), height: 5)
            }
        }
        .frame(height: 5)
    }

    private func ribbonWidth(total: CGFloat) -> CGFloat {
        switch phase {
        case .listening: return total * 0.28
        case .thinking: return total * 0.52
        case .executing: return total * 0.78
        case .done: return total
        }
    }
}

// MARK: - PhaseIconView (solo SF Symbol Effects — ActivityKit-safe)

/// Icona di fase per Lock Screen e Dynamic Island: animazioni **solo** via `.symbolEffect` (iOS 17+).
/// Nessun `@State`, `Timer`, `withAnimation` o `rotationEffect` per motion continuo.
private struct PhaseIconView: View {
    let phase: GigiPhase
    var size: CGFloat = 22
    var weight: Font.Weight = .semibold

    var body: some View {
        Image(systemName: phase.phaseSystemImage)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(phase.phaseIconForeground)
            .contentTransition(.symbolEffect(.replace))
            .modifier(PhaseIconSymbolEffectModifier(phase: phase))
    }
}

private struct PhaseIconSymbolEffectModifier: ViewModifier {
    let phase: GigiPhase

    func body(content: Content) -> some View {
        switch phase {
        case .listening:
            content
                .symbolEffect(.pulse, options: .repeating)
        case .thinking:
            content
                .symbolEffect(.bounce, options: .repeating.speed(0.82))
        case .executing:
            content
                .symbolEffect(.variableColor.iterative, options: .repeating.speed(0.72))
        case .done:
            content
        }
    }
}

// MARK: - GigiPhase (UI mapping per Live Activity)

private extension GigiPhase {
    /// SF Symbol per la fase (Live Activity).
    var phaseSystemImage: String {
        switch self {
        case .listening: return "mic.fill"
        case .thinking: return "brain.head.profile"
        case .executing: return "gearshape.fill"
        case .done: return "checkmark.circle.fill"
        }
    }

    /// Colore piatto per capsule / punti (ribbon): coerente con la fase.
    var phaseRibbonTint: Color {
        switch self {
        case .listening: return GigiBrand.purple
        case .thinking: return GigiBrand.purple
        case .executing: return Color.orange
        case .done: return GigiBrand.successGreen
        }
    }

    /// Arancio/giallo per accenti warm in executing (es. dot compatto).
    var executingWarmColor: Color {
        switch self {
        case .executing: return Color(red: 1.0, green: 0.72, blue: 0.2)
        default: return phaseRibbonTint
        }
    }

    /// Stile icona: viola, gradiente viola/blu in thinking, gradiente arancio/giallo in executing, verde in done.
    var phaseIconForeground: AnyShapeStyle {
        switch self {
        case .listening:
            AnyShapeStyle(GigiBrand.purple)
        case .thinking:
            AnyShapeStyle(
                LinearGradient(
                    colors: [GigiBrand.purple, Color(red: 0.25, green: 0.45, blue: 0.95)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .executing:
            AnyShapeStyle(
                LinearGradient(
                    colors: [Color.orange, Color.yellow],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        case .done:
            AnyShapeStyle(GigiBrand.successGreen)
        }
    }
}
