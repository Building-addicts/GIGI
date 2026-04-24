import AVFoundation
import SwiftUI
import Vision
import VisionKit

// MARK: - GigiPairScannerView
//
// SwiftUI-friendly wrapper around VisionKit's `DataScannerViewController`.
// Recognizes QR codes only (no generic barcodes). Fires `onScan` once per
// successful read and then stops scanning until the view re-appears.
//
// Camera permission is requested on first presentation. If denied, an
// overlay with a "Vai in Impostazioni" button replaces the scanner.
//
// Minimum iOS target: 17 (DataScanner available since iOS 16, we use iOS 17
// APIs for `.openURL` from the overlay).

struct GigiPairScannerView: View {
    let onScan: (String) -> Void
    let onCancel: () -> Void

    @State private var permission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var requestInFlight = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch permission {
            case .authorized:
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    DataScannerRepresentable(onScan: onScan)
                } else {
                    unavailable("This device doesn't support QR scanning.")
                }
            case .denied, .restricted:
                deniedOverlay
            case .notDetermined:
                waitingOverlay
                    .task { await requestPermission() }
            @unknown default:
                waitingOverlay
            }

            // Cancel button — always available on top
            VStack {
                HStack {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                Spacer()
            }

            VStack {
                Spacer()
                Text("Point your camera at the QR shown on localhost:7777/pair")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(.bottom, 36)
            }
        }
    }

    // MARK: Permission flow

    private func requestPermission() async {
        guard !requestInFlight else { return }
        requestInFlight = true
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        await MainActor.run {
            permission = granted ? .authorized : .denied
            requestInFlight = false
        }
    }

    // MARK: Overlays

    private var waitingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("Requesting camera access…")
                .foregroundColor(.white.opacity(0.8))
                .font(.footnote)
        }
    }

    private var deniedOverlay: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.fill.badge.ellipsis")
                .font(.system(size: 42))
                .foregroundColor(.white.opacity(0.7))
            Text("Camera access denied")
                .font(.headline)
                .foregroundColor(.white)
            Text("To scan the QR, open iOS Settings → GIGI → Camera and enable access.")
                .font(.footnote)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Capsule().fill(Color.purple))
            }
        }
        .padding(24)
    }

    private func unavailable(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundColor(.yellow)
            Text(text)
                .font(.footnote)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

// MARK: - UIKit bridge

private struct DataScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private var fired = false
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !fired else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let payload = code.payloadStringValue, !payload.isEmpty {
                    fired = true
                    dataScanner.stopScanning()
                    onScan(payload)
                    return
                }
            }
        }
    }
}
