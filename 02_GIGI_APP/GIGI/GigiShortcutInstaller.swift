import Foundation
import UIKit

// MARK: - GigiShortcutInstaller
//
// Presents the generated `.shortcut` files that are bundled with the debug app.
// This avoids stale iCloud links during Xcode/device testing: the app ships the
// exact Shortcut artifacts generated from this branch, and iOS hands them to
// Shortcuts/Files via the document interaction sheet.

@MainActor
final class GigiShortcutInstaller: NSObject, UIDocumentInteractionControllerDelegate {
    static let shared = GigiShortcutInstaller()

    private var controller: UIDocumentInteractionController?

    private override init() {
        super.init()
    }

    @discardableResult
    func presentInstallSheet(resourceName: String) -> Bool {
        guard let data = bundledShortcutData(resourceName: resourceName),
              let presenter = UIApplication.shared.topMostViewController()
        else {
            return false
        }

        let localURL = writeTemporaryImportURL(data: data, resourceName: resourceName)
        let doc = UIDocumentInteractionController(url: localURL)
        doc.delegate = self
        doc.uti = "com.apple.shortcut"
        controller = doc

        let rect = CGRect(
            x: presenter.view.bounds.midX,
            y: presenter.view.bounds.midY,
            width: 1,
            height: 1
        )
        if doc.presentOptionsMenu(from: rect, in: presenter.view, animated: true) {
            return true
        }

        // Some iOS builds do not expose an options menu for `.shortcut` from
        // inside an app. Fall back to opening the file URL directly so the
        // system can hand it to Shortcuts / Files.
        Task { await UIApplication.shared.open(localURL) }
        return true
    }

    private func bundledShortcutData(resourceName: String) -> Data? {
        // `.shortcut` is a plist payload, so Xcode's resource phase may rewrite
        // it. Bundle base64 text instead and reconstruct exact bytes at runtime.
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "shortcutb64", subdirectory: "Shortcuts")
            ?? Bundle.main.url(forResource: resourceName, withExtension: "shortcutb64"),
           let raw = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
           let decoded = Data(base64Encoded: raw) {
            return decoded
        }

        if let url = Bundle.main.url(forResource: resourceName, withExtension: "shortcut", subdirectory: "Shortcuts")
            ?? Bundle.main.url(forResource: resourceName, withExtension: "shortcut") {
            return try? Data(contentsOf: url)
        }
        return nil
    }

    private func writeTemporaryImportURL(data: Data, resourceName: String) -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(resourceName).shortcut")
        try? FileManager.default.removeItem(at: destination)
        do {
            try data.write(to: destination, options: [.atomic])
        } catch {
            GigiDebugLogger.log("Shortcut temp write failed for \(resourceName): \(error.localizedDescription)")
        }
        return destination
    }

    nonisolated func documentInteractionControllerDidDismissOptionsMenu(
        _ controller: UIDocumentInteractionController
    ) {
        Task { @MainActor in self.controller = nil }
    }
}

private extension UIApplication {
    func topMostViewController(
        base: UIViewController? = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController
    ) -> UIViewController? {
        if let nav = base as? UINavigationController {
            return topMostViewController(base: nav.visibleViewController)
        }
        if let tab = base as? UITabBarController, let selected = tab.selectedViewController {
            return topMostViewController(base: selected)
        }
        if let presented = base?.presentedViewController {
            return topMostViewController(base: presented)
        }
        return base
    }
}
