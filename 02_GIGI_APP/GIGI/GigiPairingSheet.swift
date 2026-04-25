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
        case scanning
        case validating
        // Stage 2 (Phase 6): bootstrap pair OK → run diagnostics before
        // we tell the rest of the app the harness is "ready".
        case diagnostic(deviceName: String)
        // Stage 3: diagnostic OK + user tapped finalize.
        case success(deviceName: String)
        case failure(message: String)
    }

    @State private var phase: Phase = .scanning

    /// Callback fired on successful pair so the hosting view can refresh
    /// its "paired" indicator without polling Keychain.
    let onPaired: (String) -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch phase {
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
