import SwiftUI

// MARK: - GigiPairingSheet
//
// End-to-end flow:
//   1. User scans the QR produced by the harness at localhost:7777/pair.
//   2. The QR payload is a JSON with { url, secret, deviceName, createdAt }.
//   3. We parse → validate → save in Keychain → ping /api/ios/health.
//   4. On success we dismiss and leave Settings with a green "paired" status.
//   5. On failure we show a short error + "Riprova" button that returns
//      to scanning.
//
// The iOS app reads the stored values via GigiHarnessClient.cfg, no app
// restart required.

struct GigiPairingSheet: View {
    @Environment(\.dismiss) private var dismiss

    enum Phase {
        case macSetup
        case scanning
        case validating
        // Stage 2 (Phase 6): bootstrap pair OK → run diagnostics before
        // we tell the rest of the app the harness is "ready".
        case diagnostic(deviceName: String)
        // Stage 3: diagnostic OK + user tapped finalize.
        case success(deviceName: String)
        case failure(message: String)
    }

    @State private var phase: Phase = .macSetup

    /// Callback fired on successful pair so the hosting view can refresh
    /// its "paired" indicator without polling Keychain.
    let onPaired: (String) -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch phase {
            case .macSetup:
                MacSetupView(onReady: { phase = .scanning }, onCancel: { dismiss() })

            case .scanning:
                GigiPairScannerView(
                    onScan: handleScan(_:),
                    onCancel: { dismiss() }
                )

            case .validating:
                VStack(spacing: 16) {
                    ProgressView().tint(.purple).scaleEffect(1.3)
                    Text("Connecting to your harness…")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.8))
                }

            case .diagnostic(let device):
                // Stage 2 — present the diagnostic view as a fullscreen
                // child. Once the user taps Finalize, we transition to
                // .success which dismisses our sheet entirely.
                SetupDiagnosticView {
                    phase = .success(deviceName: device)
                    onPaired(device)
                }

            case .success(let device):
                VStack(spacing: 18) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 54))
                        .foregroundColor(.green)
                    Text("Connected to \(device)")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("You can close this screen.")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.7))
                }

            case .failure(let message):
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 42))
                        .foregroundColor(.yellow)
                    Text("Pairing failed")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                    HStack(spacing: 12) {
                        Button("Close") { dismiss() }
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Capsule().stroke(Color.white.opacity(0.2)))
                        Button("Retry") { phase = .scanning }
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Capsule().fill(Color.purple))
                    }
                }
                .padding(24)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Scan handling

    private func handleScan(_ payload: String) {
        phase = .validating
        Task { await process(payload) }
    }

    private struct PairPayload: Decodable {
        let url: String
        let secret: String
        let deviceName: String?
        let createdAt: String?
    }

    private func process(_ payload: String) async {
        guard let data = payload.data(using: .utf8) else {
            await fail("QR unreadable.")
            return
        }
        let decoded: PairPayload
        do {
            decoded = try JSONDecoder().decode(PairPayload.self, from: data)
        } catch {
            await fail("Invalid QR format.\nScanned: \(payload.prefix(80))…")
            return
        }

        // Basic shape validation
        let trimmedURL = decoded.url.trimmingCharacters(in: .whitespaces)
        let trimmedSecret = decoded.secret.trimmingCharacters(in: .whitespaces)
        guard let _ = URL(string: trimmedURL),
              trimmedURL.hasPrefix("http://") || trimmedURL.hasPrefix("https://"),
              !trimmedSecret.isEmpty else {
            await fail("Invalid URL or secret in the QR.")
            return
        }

        // Persist in Keychain
        GigiKeychain.save(trimmedURL,    forKey: GigiKeychain.Key.harnessBaseURL)
        GigiKeychain.save(trimmedSecret, forKey: GigiKeychain.Key.harnessSecret)
        _ = GigiHarnessClient.ensureDeviceId() // creates one if missing

        // Verify reachability — this is the bootstrap pair (Stage 1).
        // On success we DO NOT call onPaired yet; we transition to
        // Stage 2 (.diagnostic) and let the user finalize after the
        // diagnostic view confirms all critical checks are green.
        let health = await GigiHarnessClient.shared.health()
        switch health {
        case .success:
            let device = (decoded.deviceName?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "Harness"
            await MainActor.run {
                phase = .diagnostic(deviceName: device)
            }

        case .failure(let err):
            // Rollback on health failure so a bad pair doesn't leave stale keys.
            GigiKeychain.delete(forKey: GigiKeychain.Key.harnessBaseURL)
            GigiKeychain.delete(forKey: GigiKeychain.Key.harnessSecret)
            await fail(userMessage(for: err))
        }
    }

    private func userMessage(for err: GigiHarnessClient.Error) -> String {
        switch err {
        case .notConfigured:
            return "Configuration removed after save. Please retry."
        case .transport:
            // Generic transport failure — the tunnel/URL in the QR is unreachable.
            // Most common cause: URL scanned from an old QR after cloudflared
            // restarted (Quick Tunnel URLs are ephemeral). Second cause: PC off.
            return "Harness unreachable. Make sure the harness is running and regenerate the QR from localhost:7777/setup."
        case .badResponse(let status, _):
            if status == 401 { return "Secret rejected by the server (401). Regenerate the QR." }
            return "Harness returned HTTP \(status)."
        case .apiError(let code, let msg):
            return "\(code): \(msg)"
        case .decodeFailed:
            return "Server response unreadable."
        }
    }

    @MainActor
    private func fail(_ message: String) async {
        phase = .failure(message: message)
    }
}

// MARK: - MacSetupView

private struct MacSetupStep: Identifiable {
    let id: Int
    let emoji: String
    let title: String
    let subtitle: String
    let command: String
    let note: String?
    let onceOnly: Bool
}

private struct MacSetupView: View {
    let onReady: () -> Void
    let onCancel: () -> Void

    @State private var copiedId: Int? = nil

    private let steps: [MacSetupStep] = [
        MacSetupStep(id: 1,
            emoji: "🧹",
            title: "Stop any old processes",
            subtitle: "Clears stale server processes and lock files.",
            command: #"pkill -f "node server.js" 2>/dev/null; pkill -f "node panel.js" 2>/dev/null; echo "✓ Clean""#,
            note: nil, onceOnly: false),
        MacSetupStep(id: 2,
            emoji: "📂",
            title: "Navigate to the server folder",
            subtitle: "Open Terminal on your Mac, then paste this.",
            command: "cd /path/to/GIGI-harness/03_HARNESS/server",
            note: "Use the real folder where you downloaded the project. The Mac /start page shows the exact path when the panel is running.", onceOnly: false),
        MacSetupStep(id: 3,
            emoji: "📦",
            title: "Install dependencies",
            subtitle: "Only required the first time — takes ~30 seconds.",
            command: "npm install",
            note: nil, onceOnly: true),
        MacSetupStep(id: 4,
            emoji: "🚀",
            title: "Start the server",
            subtitle: "Keep the Terminal window open while you use GIGI.",
            command: "node panel.js",
            note: "You should see: iOS HTTP+WS: http://0.0.0.0:7779", onceOnly: false),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // Header
                VStack(alignment: .leading, spacing: 6) {
                    Text("Start your Mac server")
                        .font(.title2.weight(.bold))
                        .foregroundColor(.white)
                    Text("Run these 4 commands in Terminal on your Mac, then come back here to scan the QR.")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 24)

                // Steps
                VStack(spacing: 12) {
                    ForEach(steps) { step in
                        stepCard(step)
                    }
                }
                .padding(.horizontal, 16)

                // Expected output hint
                VStack(alignment: .leading, spacing: 6) {
                    Text("Expected Terminal output (step 4)")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.4))
                    Text("Control Panel: http://localhost:7777\n[bridge] GIGI harness server started\n[bridge] iOS HTTP+WS: http://0.0.0.0:<configured-port>")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(red: 0.4, green: 0.85, blue: 0.55))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(10)
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)

                // CTA
                VStack(spacing: 12) {
                    Button(action: onReady) {
                        Label("Server is running — scan QR", systemImage: "qrcode.viewfinder")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.purple)
                            .foregroundColor(.white)
                            .cornerRadius(14)
                    }
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 36)
            }
        }
        .background(Color(red: 0.04, green: 0.04, blue: 0.08).ignoresSafeArea())
    }

    @ViewBuilder
    private func stepCard(_ step: MacSetupStep) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 12) {
                Text(step.emoji)
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(10)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(step.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                        if step.onceOnly {
                            Text("ONCE")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Color.purple.opacity(0.9))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.purple.opacity(0.15))
                                .cornerRadius(5)
                        }
                    }
                    Text(step.subtitle)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.45))
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Command block
            HStack(alignment: .top, spacing: 0) {
                Text(step.command)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundColor(Color(red: 0.6, green: 1.0, blue: 0.7))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 14)
                    .padding(.vertical, 10)

                Button(action: { copyCommand(step) }) {
                    Text(copiedId == step.id ? "✓" : "Copy")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(copiedId == step.id ? .green : Color.white.opacity(0.4))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(7)
                }
                .padding(.trailing, 10)
                .padding(.top, 8)
            }
            .background(Color.black.opacity(0.5))
            .cornerRadius(10)
            .padding(.horizontal, 14)
            .padding(.bottom, step.note != nil ? 8 : 14)

            // Note
            if let note = step.note {
                Text(note)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .background(Color.white.opacity(0.04))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func copyCommand(_ step: MacSetupStep) {
        UIPasteboard.general.string = step.command
        withAnimation { copiedId = step.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { if copiedId == step.id { copiedId = nil } }
        }
    }
}
