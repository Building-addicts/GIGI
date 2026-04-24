import SwiftUI

// MARK: - SetupChecklistView
//
// Pre-pair education screen. The user lands here BEFORE seeing the QR
// scanner, so they understand what GIGI needs to function:
//   1. A PC (or VPS) running the GIGI Harness — checked LIVE via /health
//   2. A Cloudflare account (free) — manual checkbox
//   3. Claude Code CLI installed on that PC — manual checkbox
//   4. The Harness app installed and running — manual checkbox
//
// Checkbox state persists in UserDefaults so users don't have to re-check
// after relaunching. Requirement 1 is auto-detected (no checkbox); the
// "Procedi al Pair" button enables only when req 1 is live ✓ and the
// other 3 are checked.
//
// Phase 6A.1 — depends on: nothing.

struct SetupChecklistView: View {
    @Environment(\.dismiss) private var dismiss

    // MARK: - Persisted manual checks
    @AppStorage("gigi.checklist.cf")        private var cfDone = false
    @AppStorage("gigi.checklist.claudecli") private var claudeCliDone = false
    @AppStorage("gigi.checklist.harness")   private var harnessInstallDone = false

    // MARK: - Live state
    @State private var harnessLive: HarnessLiveState = .unknown
    @State private var isCheckingHarness = false
    @State private var showPairing = false

    enum HarnessLiveState {
        case unknown        // hai ancora un Keychain senza URL: skip live check
        case checking
        case reachable
        case unreachable(String)
    }

    private var canProceed: Bool {
        if case .reachable = harnessLive { return cfDone && claudeCliDone && harnessInstallDone }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    requirementCard(
                        index: 1,
                        title: "A PC (or VPS) running the GIGI Harness",
                        body: "GIGI talks to Claude through a small backend (\"harness\") running on your computer. When the PC is on and the harness is running, the app can reach it from anywhere via Cloudflare Tunnel.",
                        state: req1State,
                        action: req1Action
                    )

                    requirementCard(
                        index: 2,
                        title: "Cloudflare account (free)",
                        body: "Cloudflare provides the tunnel that exposes your PC to the app, even on cellular. Free forever for personal use.",
                        state: cfDone ? .done : .pending,
                        action: .button(
                            label: cfDone ? "Done ✓" : "Open Cloudflare sign-up",
                            tint: .purple,
                            handler: {
                                if let url = URL(string: "https://dash.cloudflare.com/sign-up") {
                                    UIApplication.shared.open(url)
                                }
                                cfDone = true
                            }
                        )
                    )

                    requirementCard(
                        index: 3,
                        title: "Claude Code CLI on the PC",
                        body: "The harness calls your local Claude Code to process tasks. You need an active Claude Pro/Max subscription.",
                        state: claudeCliDone ? .done : .pending,
                        action: .button(
                            label: claudeCliDone ? "Done ✓" : "Open Claude Code docs",
                            tint: .purple,
                            handler: {
                                if let url = URL(string: "https://docs.anthropic.com/claude-code") {
                                    UIApplication.shared.open(url)
                                }
                                claudeCliDone = true
                            }
                        )
                    )

                    requirementCard(
                        index: 4,
                        title: "GIGI Harness installed",
                        body: "On your PC: start the harness with `bin/1_START_ALL.bat` (Windows) or `node server.js` from `03_HARNESS/server`. Then open `http://localhost:7777/setup` in your browser to configure the tunnel.",
                        state: harnessInstallDone ? .done : .pending,
                        action: .toggle(label: "I installed and started the harness", isOn: $harnessInstallDone)
                    )

                    proceedButton

                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("GIGI Setup")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }.foregroundColor(.secondary)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await refreshHarnessLive() }
        .sheet(isPresented: $showPairing) {
            GigiPairingSheet { _ in
                // After successful pair the banner in MainTabView disappears
                // and this sheet's parent will dismiss us.
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Welcome to GIGI 👋")
                .font(.title2.weight(.bold))
                .foregroundColor(.white)
            Text("You need four things before scanning the pairing QR. Check that each one is ready below.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    // MARK: - Requirement card

    enum ReqState { case done, pending }

    enum CardAction {
        case button(label: String, tint: Color, handler: () -> Void)
        case toggle(label: String, isOn: Binding<Bool>)
        case live(label: String, isLoading: Bool, retry: () async -> Void)
    }

    private func requirementCard(index: Int, title: String, body: String, state: ReqState, action: CardAction) -> some View {
        let icon = state == .done ? "checkmark.circle.fill" : "circle"
        let iconColor: Color = state == .done ? .green : .white.opacity(0.35)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(iconColor)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(index). \(title)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                    Text(body)
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            actionView(action)
                .padding(.leading, 40)
        }
        .padding(16)
        .background(Color.white.opacity(0.05))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(state == .done ? Color.green.opacity(0.3) : Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func actionView(_ action: CardAction) -> some View {
        switch action {
        case .button(let label, let tint, let handler):
            Button(action: handler) {
                Text(label)
                    .font(.footnote.weight(.medium))
                    .foregroundColor(tint)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().stroke(tint.opacity(0.4), lineWidth: 1))
            }
        case .toggle(let label, let isOn):
            Toggle(label, isOn: isOn)
                .tint(.purple)
                .font(.footnote)
        case .live(let label, let isLoading, let retry):
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().scaleEffect(0.7).tint(.white)
                }
                Text(label)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Button("Recheck") {
                    Task { await retry() }
                }
                .font(.footnote)
                .foregroundColor(.purple)
                .disabled(isLoading)
            }
        }
    }

    // MARK: - Requirement 1 (live harness check)

    private var req1State: ReqState {
        if case .reachable = harnessLive { return .done }
        return .pending
    }

    private var req1Action: CardAction {
        switch harnessLive {
        case .unknown:
            return .live(
                label: "Configure a URL/secret first (Settings → Harness → Manual configuration, or scan a QR).",
                isLoading: isCheckingHarness,
                retry: { await refreshHarnessLive() }
            )
        case .checking:
            return .live(label: "Checking reachability…", isLoading: true, retry: {})
        case .reachable:
            return .live(label: "Harness reachable ✓", isLoading: false, retry: { await refreshHarnessLive() })
        case .unreachable(let why):
            return .live(label: "Not reachable: \(why)", isLoading: isCheckingHarness, retry: { await refreshHarnessLive() })
        }
    }

    private func refreshHarnessLive() async {
        guard GigiHarnessClient.shared.isConfigured else {
            await MainActor.run { harnessLive = .unknown }
            return
        }
        await MainActor.run { isCheckingHarness = true; harnessLive = .checking }
        let result = await GigiHarnessClient.shared.health()
        await MainActor.run {
            isCheckingHarness = false
            switch result {
            case .success: harnessLive = .reachable
            case .failure(let err): harnessLive = .unreachable(String(describing: err).prefix(80).description)
            }
        }
    }

    // MARK: - Proceed button

    private var proceedButton: some View {
        Button {
            showPairing = true
        } label: {
            HStack {
                Spacer()
                Text("Continue to pair")
                    .font(.body.weight(.semibold))
                Image(systemName: "qrcode.viewfinder")
                Spacer()
            }
            .padding(.vertical, 14)
            .background(canProceed ? Color.purple : Color.purple.opacity(0.25))
            .foregroundColor(.white)
            .cornerRadius(14)
        }
        .disabled(!canProceed)
        .padding(.top, 8)

        // The disabled-state hint
    }
}
