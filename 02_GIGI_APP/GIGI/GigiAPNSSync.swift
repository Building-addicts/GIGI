import Foundation
import CryptoKit

// MARK: - GigiAPNSSync
//
// Sincronizza il device token APNS con il backend Harness in modo idempotente.
// Call-sites: AppDelegate (token-received), SettingsView (config-changed),
// GIGIApp scenePhase=.active (did-become-active).
//
// Fingerprint = SHA256(baseURL | secret | token). Se combacia con l'ultima
// sync riuscita → no-op silente (nessuna chiamata rete). Se il fingerprint
// cambia (token nuovo o config cambiata) → tentativo + log con reason.
// Su failure il fingerprint viene azzerato, così la prossima occasione
// (prossimo scenePhase active, o salva in Settings) riprova.

@MainActor
final class GigiAPNSSync {

    static let shared = GigiAPNSSync()
    private init() {}

    private let defaults = UserDefaults.standard
    private let tokenKey = "gigi.apns.deviceToken"
    private let fingerprintKey = "gigi.apns.lastSyncFingerprint"

    // MARK: - Public API

    func setToken(_ token: String) {
        let existing = defaults.string(forKey: tokenKey)
        guard token != existing else { return }
        defaults.set(token, forKey: tokenKey)
        defaults.removeObject(forKey: fingerprintKey)
    }

    func reset() {
        defaults.removeObject(forKey: fingerprintKey)
    }

    func sync(reason: String) async {
        guard let token = defaults.string(forKey: tokenKey), !token.isEmpty else {
            return
        }
        guard GigiHarnessClient.shared.isConfigured else {
            GigiDebugLogger.log("APNS sync: Harness non configurato, rimando (reason=\(reason))")
            return
        }

        let baseURL = GigiKeychain.load(forKey: GigiKeychain.Key.harnessBaseURL) ?? ""
        let secret  = GigiKeychain.load(forKey: GigiKeychain.Key.harnessSecret) ?? ""
        let fp      = Self.fingerprint(baseURL: baseURL, secret: secret, token: token)

        if fp == defaults.string(forKey: fingerprintKey) { return }

        GigiDebugLogger.log("APNS sync: tentativo (reason=\(reason))")
        let bundleId = Bundle.main.bundleIdentifier
        let result = await GigiHarnessClient.shared.pushRegister(apnsToken: token, bundleId: bundleId)

        switch result {
        case .success:
            defaults.set(fp, forKey: fingerprintKey)
            GigiDebugLogger.log("APNS sync: OK (reason=\(reason))")
        case .failure(let e):
            defaults.removeObject(forKey: fingerprintKey)
            GigiDebugLogger.log("APNS sync: FAIL (reason=\(reason)) — \(e)")
        }
    }

    // MARK: - Internals

    private static func fingerprint(baseURL: String, secret: String, token: String) -> String {
        let raw = "\(baseURL)|\(secret)|\(token)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
