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
                    Text("Mi collego al tuo Harness…")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.8))
                }

            case .success(let device):
                VStack(spacing: 18) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 54))
                        .foregroundColor(.green)
                    Text("Connesso a \(device)")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("Puoi chiudere questa schermata.")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.7))
                }

            case .failure(let message):
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 42))
                        .foregroundColor(.yellow)
                    Text("Pairing fallito")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                    HStack(spacing: 12) {
                        Button("Chiudi") { dismiss() }
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Capsule().stroke(Color.white.opacity(0.2)))
                        Button("Riprova") { phase = .scanning }
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
            await fail("QR illeggibile.")
            return
        }
        let decoded: PairPayload
        do {
            decoded = try JSONDecoder().decode(PairPayload.self, from: data)
        } catch {
            await fail("Formato QR non valido.\nScansionato: \(payload.prefix(80))…")
            return
        }

        // Basic shape validation
        let trimmedURL = decoded.url.trimmingCharacters(in: .whitespaces)
        let trimmedSecret = decoded.secret.trimmingCharacters(in: .whitespaces)
        guard let _ = URL(string: trimmedURL),
              trimmedURL.hasPrefix("http://") || trimmedURL.hasPrefix("https://"),
              !trimmedSecret.isEmpty else {
            await fail("URL o secret non valido nel QR.")
            return
        }

        // Persist in Keychain
        GigiKeychain.save(trimmedURL,    forKey: GigiKeychain.Key.harnessBaseURL)
        GigiKeychain.save(trimmedSecret, forKey: GigiKeychain.Key.harnessSecret)
        _ = GigiHarnessClient.ensureDeviceId() // creates one if missing

        // Verify reachability
        let health = await GigiHarnessClient.shared.health()
        switch health {
        case .success:
            let device = (decoded.deviceName?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "Harness"
            await MainActor.run {
                phase = .success(deviceName: device)
                onPaired(device)
            }
            // Auto-dismiss after a short beat so the user sees the success state.
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run { dismiss() }

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
            return "Configurazione rimossa dopo il salvataggio. Riprova."
        case .transport:
            return "Harness irraggiungibile. Verifica Tailscale attivo su PC e iPhone."
        case .badResponse(let status, _):
            if status == 401 { return "Secret rifiutato dal server (401)." }
            return "Harness ha risposto HTTP \(status)."
        case .apiError(let code, let msg):
            return "\(code): \(msg)"
        case .decodeFailed:
            return "Risposta del server non leggibile."
        }
    }

    @MainActor
    private func fail(_ message: String) async {
        phase = .failure(message: message)
    }
}
