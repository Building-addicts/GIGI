import SwiftUI

// MARK: - SetupDiagnosticView
//
// The post-bootstrap-pair screen. Runs a 5-second poll against
// /api/setup/diagnostics and renders one row per check, color-coded by
// severity, with copyable action hints. The "Finalize pair" button
// activates once every critical check is green.
//
// Polling is automatic while the view is visible. Tapping a row reveals
// its hint + action; long-pressing the action copies it to the
// clipboard so the user can paste it into a terminal on the PC.
//
// Phase 6.5 — depends on P6.3 (backend endpoint) and P6.4 (client + struct).
//
// Three explicit phase states, one of which is the "live" mode:
//   .loading    initial fetch in flight, no report yet
//   .running    we have a report, polling continues every 5s
//   .error(s)   the most recent fetch failed (network / 401)
//
// On dismiss the view publishes its last successful report into
// `GigiHarnessClient.shared.cacheDiagnostics(_:)` so the rest of the app
// (banner, chat gate) can read `isReady` without re-fetching.

struct SetupDiagnosticView: View {
    @Environment(\.dismiss) private var dismiss

    enum Phase: Equatable {
        case loading
        case running(GigiHarnessClient.DiagnosticsReport)
        case error(String)
    }

    @State private var phase: Phase = .loading
    @State private var pollTask: Task<Void, Never>?
    @State private var expandedCheckId: String?
    @State private var copiedToast: String?
    @State private var isFinalizing = false
    @State private var isManualRefreshing = false
    @State private var nextRefreshIn: Int = 5
    @State private var manuallyCollapsedIds: Set<String> = []   // user-tapped to close

    // Autofix state (P6.11.2)
    @State private var isAutofixing = false
    @State private var autofixProgress: [AutofixStep] = []      // per-step UI rows
    @State private var showSecretRotateConfirm = false
    @State private var pendingAutofixIds: [String] = []
    @State private var needsRepairAfterAutofix = false

    /// Per-step row shown during the .fixing animation.
    struct AutofixStep: Identifiable, Equatable {
        let id: String
        let label: String
        var status: Status
        var detail: String?
        enum Status: Equatable { case pending, running, fixed, needsUser, errored }
    }

    /// Notifies the parent (e.g. SettingsView) that the autofix rotated
    /// the harness secret and the user needs to re-pair.
    var onNeedsRepair: (() -> Void)? = nil

    /// Called when the user taps "Finalize pair". The hosting sheet
    /// (GigiPairingSheet) listens for this to flip its own state.
    let onFinalize: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                content
                if let toast = copiedToast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(.footnote.weight(.medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(Color.black.opacity(0.85)))
                            .padding(.bottom, 80)
                    }
                    .transition(.opacity)
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }
                        .foregroundColor(.secondary)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
    }

    // MARK: - Phase rendering

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 16) {
                ProgressView().tint(.purple).scaleEffect(1.3)
                Text("Checking your PC…")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
            }
        case .running(let report):
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryHeader(report: report)
                    autofixBanner(report: report)
                    if isAutofixing { autofixProgressCard }
                    checkList(report: report)
                    finalizeButton(report: report)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
            .alert("Rotate secret?", isPresented: $showSecretRotateConfirm) {
                Button("Cancel", role: .cancel) {
                    pendingAutofixIds = []
                }
                Button("Rotate & re-pair", role: .destructive) {
                    Task { await runAutofix(pendingAutofixIds) }
                }
            } message: {
                Text("This will generate a new harness secret and disconnect this iPhone. You'll need to scan a fresh QR right after to re-pair.")
            }
        case .error(let msg):
            VStack(spacing: 18) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 42))
                    .foregroundColor(.yellow)
                Text("Couldn't reach the harness")
                    .font(.headline)
                    .foregroundColor(.white)
                Text(msg)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Retry") {
                    Task { await fetchOnce(force: true) }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(Capsule().fill(Color.purple))
            }
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private func summaryHeader(report: GigiHarnessClient.DiagnosticsReport) -> some View {
        let s = report.summary
        let allOk = s.allCriticalOk
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: allOk ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(allOk ? .green : .yellow)
                Text(allOk ? "All checks pass" : "Some checks need attention")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
            }
            HStack(spacing: 14) {
                badge(label: "critical", ok: s.counts.critical.ok, total: s.counts.critical.total, color: .pink)
                badge(label: "warning",  ok: s.counts.warning.ok,  total: s.counts.warning.total,  color: .yellow)
                badge(label: "info",     ok: s.counts.info.ok,     total: s.counts.info.total,     color: .blue)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await manualRefresh() }
                } label: {
                    HStack(spacing: 6) {
                        if isManualRefreshing {
                            ProgressView().scaleEffect(0.7).tint(.purple)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption.weight(.semibold))
                        }
                        Text(isManualRefreshing ? "Checking…" : "Recheck now")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundColor(.purple)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().stroke(Color.purple.opacity(0.5), lineWidth: 1))
                }
                .disabled(isManualRefreshing)

                Spacer()

                Text("Next auto-refresh in \(nextRefreshIn)s")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.white.opacity(0.45))
            }
            .padding(.top, 4)

            Text("Tap any red row for the fix, or fix on the PC and it'll turn green here automatically.")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.55))
                .padding(.top, 2)
        }
        .padding(16)
        .background(Color.white.opacity(0.04))
        .cornerRadius(12)
    }

    private func badge(label: String, ok: Int, total: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(ok)/\(total)")
                .font(.headline.monospacedDigit())
                .foregroundColor(.white)
            Text(label)
                .font(.caption2)
                .foregroundColor(color.opacity(0.85))
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.12))
        .cornerRadius(8)
    }

    // MARK: - Autofix banner

    @ViewBuilder
    private func autofixBanner(report: GigiHarnessClient.DiagnosticsReport) -> some View {
        // Filter checks that are currently failing AND auto-fixable.
        let fixable = report.checks.filter { !$0.ok && ($0.autoFixable ?? false) }
        let manual  = report.checks.filter { !$0.ok && !($0.autoFixable ?? false) }
        if fixable.isEmpty || isAutofixing { return AnyView(EmptyView()) as Any as! AnyView }

        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 18))
                        .foregroundColor(.purple)
                    Text("\(fixable.count) issue\(fixable.count == 1 ? "" : "s") can be fixed automatically")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                }
                if !manual.isEmpty {
                    Text("After auto-fix, \(manual.count) issue\(manual.count == 1 ? "" : "s") will still need you.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.55))
                }
                Button {
                    pendingAutofixIds = fixable.map(\.id)
                    if pendingAutofixIds.contains("config_secret_strength") {
                        showSecretRotateConfirm = true
                    } else {
                        Task { await runAutofix(pendingAutofixIds) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .font(.footnote.weight(.semibold))
                        Text("Fix all automatically")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(LinearGradient(colors: [.purple, Color.purple.opacity(0.78)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing))
                    .cornerRadius(11)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(Color.purple.opacity(0.1))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.purple.opacity(0.4), lineWidth: 1)
            )
        )
    }

    private var autofixProgressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView().scaleEffect(0.7).tint(.purple)
                Text("Fixing…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
            }
            ForEach(autofixProgress) { step in
                HStack(spacing: 8) {
                    Group {
                        switch step.status {
                        case .pending:
                            Image(systemName: "clock").foregroundColor(.white.opacity(0.4))
                        case .running:
                            ProgressView().scaleEffect(0.55).tint(.purple)
                        case .fixed:
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        case .needsUser:
                            Image(systemName: "person.fill.questionmark").foregroundColor(.yellow)
                        case .errored:
                            Image(systemName: "xmark.octagon.fill").foregroundColor(.pink)
                        }
                    }
                    .font(.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.label)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.85))
                        if let d = step.detail {
                            Text(d)
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .cornerRadius(10)
    }

    // MARK: - Autofix execution

    private func runAutofix(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        // Build the per-step rows from the current report (to preserve labels)
        let labelMap: [String: String] = {
            if case .running(let report) = phase {
                return Dictionary(uniqueKeysWithValues: report.checks.map { ($0.id, $0.label) })
            }
            return [:]
        }()
        await MainActor.run {
            autofixProgress = ids.map {
                AutofixStep(id: $0, label: labelMap[$0] ?? $0, status: .pending, detail: nil)
            }
            isAutofixing = true
        }

        // Optimistically flip the first item to running so the UI shows
        // motion immediately even before the backend's batched response.
        if !ids.isEmpty {
            await MainActor.run {
                if !autofixProgress.isEmpty { autofixProgress[0].status = .running }
            }
        }

        let result = await GigiHarnessClient.shared.autofix(checkIds: ids)

        await MainActor.run {
            switch result {
            case .success(let report):
                for r in report.results {
                    if let idx = autofixProgress.firstIndex(where: { $0.id == r.id }) {
                        if r.fixed {
                            autofixProgress[idx].status = .fixed
                            autofixProgress[idx].detail = r.detail
                        } else if r.needsUser != nil {
                            autofixProgress[idx].status = .needsUser
                            autofixProgress[idx].detail = r.needsUser
                        } else {
                            autofixProgress[idx].status = .errored
                            autofixProgress[idx].detail = r.error ?? "unknown error"
                        }
                    }
                }
                if report.results.contains(where: { $0.needsRepair == true }) {
                    needsRepairAfterAutofix = true
                }
            case .failure(let err):
                for i in autofixProgress.indices {
                    if autofixProgress[i].status == .pending || autofixProgress[i].status == .running {
                        autofixProgress[i].status = .errored
                        autofixProgress[i].detail = String(describing: err).prefix(120).description
                    }
                }
            }
        }

        // After 2s, refresh diagnostics and clear the progress card.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await MainActor.run {
            isAutofixing = false
            autofixProgress = []
            pendingAutofixIds = []
        }
        if needsRepairAfterAutofix {
            await MainActor.run {
                GigiHarnessClient.shared.clearPair()
                onNeedsRepair?()
                dismiss()
            }
            return
        }
        await fetchOnce(force: true)
    }

    // MARK: - Check rows

    private func checkList(report: GigiHarnessClient.DiagnosticsReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(report.checks) { check in
                checkRow(check)
            }
        }
    }

    @ViewBuilder
    private func checkRow(_ check: GigiHarnessClient.DiagnosticsCheck) -> some View {
        let icon = check.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        let iconColor = check.ok ? Color.green : severityColor(check.severity)
        let canExpand = !check.ok && (check.hint != nil || check.action != nil)
        // Failing rows are expanded by default so the user sees the action
        // immediately. Tapping collapses it (we remember that explicit choice
        // in `manuallyCollapsedIds`). Tapping a never-expanded row that
        // becomes failing later won't be in the manuallyCollapsed set, so it
        // also auto-expands.
        let isExpanded: Bool = {
            if !canExpand { return false }
            if expandedCheckId == check.id { return true }
            if manuallyCollapsedIds.contains(check.id) { return false }
            return !check.ok
        }()

        VStack(alignment: .leading, spacing: 8) {
            Button {
                guard canExpand else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isExpanded {
                        manuallyCollapsedIds.insert(check.id)
                        if expandedCheckId == check.id { expandedCheckId = nil }
                    } else {
                        manuallyCollapsedIds.remove(check.id)
                        expandedCheckId = check.id
                    }
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 18))
                        .foregroundColor(iconColor)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.label)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.white)
                        Text(check.severity.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(severityColor(check.severity).opacity(0.7))
                    }
                    Spacer()
                    if canExpand {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    if let hint = check.hint {
                        Text(hint)
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let action = check.action {
                        Button {
                            UIPasteboard.general.string = action
                            withAnimation { copiedToast = "Action copied" }
                            Task {
                                try? await Task.sleep(nanoseconds: 1_400_000_000)
                                await MainActor.run { withAnimation { copiedToast = nil } }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                                Text(action)
                                    .font(.system(.footnote, design: .monospaced))
                                    .multilineTextAlignment(.leading)
                                Spacer()
                            }
                            .foregroundColor(.purple)
                            .padding(10)
                            .background(Color.purple.opacity(0.08))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.purple.opacity(0.3), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 32)
            }
        }
        .padding(12)
        .background(Color.white.opacity(check.ok ? 0.03 : 0.06))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(check.ok ? Color.green.opacity(0.2) : iconColor.opacity(0.3), lineWidth: 1)
        )
    }

    private func severityColor(_ s: String) -> Color {
        switch s {
        case "critical": return .pink
        case "warning":  return .yellow
        case "info":     return .blue
        default:         return .gray
        }
    }

    // MARK: - Finalize

    @ViewBuilder
    private func finalizeButton(report: GigiHarnessClient.DiagnosticsReport) -> some View {
        let canFinalize = report.summary.allCriticalOk

        Button {
            isFinalizing = true
            GigiHarnessClient.shared.cacheDiagnostics(report)
            // The parent (GigiPairingSheet) is responsible for dismissing
            // the sheet — we just notify it. When SetupDiagnosticView is
            // presented standalone (e.g. from Settings to re-check), the
            // parent receiver still calls dismiss() in its callback.
            onFinalize()
        } label: {
            HStack {
                Spacer()
                if isFinalizing {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "checkmark.seal.fill")
                    Text("Finalize pair").font(.body.weight(.semibold))
                }
                Spacer()
            }
            .padding(.vertical, 14)
            .background(canFinalize ? Color.purple : Color.purple.opacity(0.25))
            .foregroundColor(.white)
            .cornerRadius(14)
        }
        .disabled(!canFinalize || isFinalizing)
        .padding(.top, 4)

        if !canFinalize {
            Text("Fix the critical checks above to enable.")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        pollTask = Task {
            // Initial fetch fast (no delay)
            await MainActor.run { nextRefreshIn = 5 }
            await fetchOnce(force: false)
            while !Task.isCancelled {
                // 5-second countdown, ticking every second so the user sees
                // a real timer instead of an opaque "wait" state.
                for tick in stride(from: 5, through: 1, by: -1) {
                    if Task.isCancelled { return }
                    await MainActor.run { nextRefreshIn = tick }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                if Task.isCancelled { break }
                await fetchOnce(force: false)
            }
        }
    }

    /// Manual refresh — bypasses the cache + restarts the countdown so
    /// the next auto-refresh comes 5s after this one (not stacked on top
    /// of the previous one).
    private func manualRefresh() async {
        guard !isManualRefreshing else { return }
        await MainActor.run { isManualRefreshing = true }
        await fetchOnce(force: true)
        await MainActor.run { isManualRefreshing = false }
        // Restart the polling so the countdown resets cleanly.
        startPolling()
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func fetchOnce(force: Bool) async {
        let result = await GigiHarnessClient.shared.diagnostics(forceRefresh: force)
        await MainActor.run {
            switch result {
            case .success(let report):
                phase = .running(report)
                GigiHarnessClient.shared.cacheDiagnostics(report)
            case .failure(let err):
                phase = .error(String(describing: err))
            }
        }
    }
}
