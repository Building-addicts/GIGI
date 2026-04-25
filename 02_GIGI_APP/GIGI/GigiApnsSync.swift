import Foundation
import CryptoKit

// MARK: - GigiApnsSync
//
// Gestisce la sincronizzazione del device token APNS verso il backend Harness.
//
// Problema che risolve:
//   iOS consegna il device token via didRegisterForRemoteNotificationsWithDeviceToken
//   una sola volta (poi lo cacha). Se in quel momento l'Harness non è configurato,
//   o la rete è giù, o l'utente cambia backend in un secondo momento, il token
//   resta "in memoria" e va perso alla chiusura dell'app.
//
// Strategia "eventually consistent":
//   - Il token viene persistito in Keychain appena arriva (onTokenReceived).
//   - Un "fingerprint" SHA256 della coppia (baseURL, secret) rappresenta
//     l'identità del backend. Quando il sync ha successo, salviamo il fingerprint
//     corrente in harnessApnsSyncedTo.
//   - Ad ogni trigger (token nuovo, config cambiata, app-attiva) confrontiamo il
//     fingerprint corrente con quello salvato: se diverso → sync; se uguale → no-op.
//   - Il sync usa il retry esponenziale interno di GigiHarnessClient (0.5s → 2s):
//     se fallisce, harnessApnsSyncedTo resta invariato e il prossimo trigger
//     (es. didBecomeActive dopo che la rete torna) riprova.
//
// Thread-safety: @MainActor — tutte le chiamate Keychain/HTTP sono serializzate.

@MainActor
enum GigiApnsSync {

    // MARK: - Trigger pubblici

    /// Invocato dal GigiAppDelegate quando iOS consegna un device token fresco.
    /// Salva il token e tenta subito la sync.
    static func onTokenReceived(_ tokenHex: String) {
        GigiKeychain.save(tokenHex, forKey: GigiKeychain.Key.harnessApnsToken)
        // Token nuovo → invalida l'ultimo stato di sync così il prossimo sync scatta.
        GigiKeychain.delete(forKey: GigiKeychain.Key.harnessApnsSyncedTo)
        Task { await syncIfNeeded(reason: "token-received") }
    }

    /// Invocato dalla SettingsView dopo che l'utente salva/cambia URL o secret.
    /// La nuova config ha un fingerprint diverso → forza il sync.
    static func onConfigChanged() {
        GigiKeychain.delete(forKey: GigiKeychain.Key.harnessApnsSyncedTo)
        Task { await syncIfNeeded(reason: "config-changed") }
    }

    /// Invocato dal GigiAppDelegate ad ogni applicationDidBecomeActive.
    /// No-op se il fingerprint combacia (retry opportunistico dopo rete instabile).
    static func onAppDidBecomeActive() {
        Task { await syncIfNeeded(reason: "app-active") }
    }

    /// Invocato quando l'utente fa logout dal backend (pulizia totale).
    static func onLogout() {
        GigiKeychain.delete(forKey: GigiKeychain.Key.harnessApnsToken)
        GigiKeychain.delete(forKey: GigiKeychain.Key.harnessApnsSyncedTo)
    }

    // MARK: - Implementazione

    private static func syncIfNeeded(reason: String) async {
        guard let token = GigiKeychain.load(forKey: GigiKeychain.Key.harnessApnsToken),
              !token.isEmpty else {
            // Nessun token locale → niente da sincronizzare. Non è un errore:
            // potrebbe essere che l'utente ha negato il permesso push.
            return
        }
        guard GigiHarnessClient.shared.isConfigured else {
            GigiDebugLogger.log("APNS sync: Harness non configurato, rimando (reason=\(reason))")
            return
        }

        let expected = currentConfigFingerprint()
        let lastSynced = GigiKeychain.load(forKey: GigiKeychain.Key.harnessApnsSyncedTo) ?? ""
        if lastSynced == expected {
            return  // già in sync con questo backend + questo token
        }

        GigiDebugLogger.log("APNS sync: tentativo (reason=\(reason))")
        let bundleId = Bundle.main.bundleIdentifier
        let result = await GigiHarnessClient.shared.pushRegister(
            apnsToken: token, bundleId: bundleId
        )
        switch result {
        case .success:
            GigiKeychain.save(expected, forKey: GigiKeychain.Key.harnessApnsSyncedTo)
            GigiDebugLogger.log("APNS sync: OK (reason=\(reason))")
        case .failure(let e):
            // Non tocchiamo harnessApnsSyncedTo → al prossimo trigger ritenterà.
            GigiDebugLogger.log("APNS sync: fallito (reason=\(reason)): \(e)")
        }
    }

    /// Fingerprint opaca di (baseURL, secret) via SHA256.
    /// Stabile tra launch (a differenza di Swift.hashValue, che randomizza il seed).
    private static func currentConfigFingerprint() -> String {
        let url = GigiKeychain.load(forKey: GigiKeychain.Key.harnessBaseURL) ?? ""
        let secret = GigiKeychain.load(forKey: GigiKeychain.Key.harnessSecret) ?? ""
        let data = Data((url + "|" + secret).utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
