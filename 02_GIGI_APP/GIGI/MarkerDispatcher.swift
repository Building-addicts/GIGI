import Foundation
import UIKit

// MARK: - MarkerDispatcher
//
// Hands a `LocalActionRouter` marker to the user-installed iOS Shortcut
// "GIGI Action Dispatcher", which owns the privileged native action
// surface (Call, Send Message, Open URL). The Shortcut receives the
// marker as `Shortcut Input` and routes it through its own CALL/SMS/
// OPEN branches.
//
// Why through a Shortcut and not direct iOS URL schemes:
//   • Single source of truth for native actions — same Shortcut runs from
//     the Action Button path, the Control Center quick-listen path, and
//     the in-app voice path. Behaviour stays consistent across triggers.
//   • Apple compliance — `Call`, `Send Message`, and `Open URL` actions
//     inside Shortcuts present Apple's stock confirmation sheets. Direct
//     `tel:` / `sms:` URL schemes work too but the Shortcut layer also
//     gives us future flexibility (contact picker fallback, body prompt,
//     telemetry hooks) without touching app code.
//
// If the Shortcut is not installed, dispatch falls back to the direct
// iOS URL schemes so the in-app flow keeps working during onboarding.

@MainActor
enum MarkerDispatcher {

    /// Result of a dispatch attempt. The orchestrator uses this to decide
    /// what to speak (and whether to finalize the turn).
    enum DispatchResult {
        /// Action launched. `spoken` is the short confirmation to TTS while
        /// iOS shows the native confirmation UI (Apple Call / Messages
        /// composer / target app). May be empty if the caller prefers
        /// silence (we never want to speak over an Apple confirm sheet).
        case launched(spoken: String)

        /// Marker recognized but cannot be acted on (unresolved contact,
        /// undialable number, missing target app). `spoken` is what to say
        /// back to the user.
        case rejected(spoken: String)

        /// Marker shape unknown — caller should fall back to its non-marker
        /// path (e.g. speak the marker as text or pass to the agent engine).
        case unknownMarker
    }

    /// Dispatches a marker string. Returns the result so the orchestrator
    /// can finalize the turn appropriately. Safe to call repeatedly with
    /// the same input.
    static func dispatch(marker: String) async -> DispatchResult {
        guard let kind = LocalActionRouter.classify(marker: marker) else {
            return .unknownMarker
        }

        // Pre-validate the marker so we don't hand the Shortcut a
        // malformed input (e.g. `CALL:Mom` when contact resolution failed).
        // The Shortcut's Call action would silently no-op or fail; we'd
        // rather speak a useful error.
        if let prevalidated = preValidate(kind) {
            return prevalidated
        }

        // Primary path: hand the marker to the user's GIGI Action
        // Dispatcher Shortcut. Falls back to a direct iOS URL scheme if
        // the user hasn't installed the Shortcut yet (first-run window
        // before onboarding completes).
        if await runDispatcherShortcut(marker: marker) {
            return .launched(spoken: "")
        }
        return await dispatchDirectURL(kind: kind)
    }

    // MARK: - Pre-validation

    private static func preValidate(_ kind: LocalActionRouter.MarkerKind) -> DispatchResult? {
        switch kind {
        case .call(let phone):
            // Router emits `CALL:<NameOnly>` when contact resolution
            // failed. Don't bother launching the Shortcut for that — the
            // user gets a clearer message from us.
            if phone.first != "+" && !(phone.first?.isNumber ?? false) {
                return .rejected(spoken: "I couldn't find a phone number for \(phone).")
            }
            return nil
        case .sms, .open:
            return nil
        }
    }

    // MARK: - Shortcut dispatch (primary)

    /// Opens the user-installed `GIGI Action Dispatcher` Shortcut and
    /// hands it the marker as `Shortcut Input` via the standard Shortcuts
    /// URL scheme. Returns `true` if the launch succeeded.
    private static func runDispatcherShortcut(marker: String) async -> Bool {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: GigiDispatcherShortcut.shortcutName),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: marker)
        ]
        guard let url = components.url else { return false }
        guard UIApplication.shared.canOpenURL(url) else { return false }
        await UIApplication.shared.open(url)
        return true
    }

    // MARK: - Direct URL fallback

    private static func dispatchDirectURL(kind: LocalActionRouter.MarkerKind) async -> DispatchResult {
        switch kind {
        case .call(let phone):
            guard let url = URL(string: "tel://\(phone)") else {
                return .rejected(spoken: "That number doesn't look dialable.")
            }
            guard UIApplication.shared.canOpenURL(url) else {
                return .rejected(spoken: "This device can't place phone calls.")
            }
            await UIApplication.shared.open(url)
            return .launched(spoken: "")

        case .sms(let phone, let body):
            var components = URLComponents()
            components.scheme = "sms"
            components.path = phone
            if !body.isEmpty {
                components.queryItems = [URLQueryItem(name: "body", value: body)]
            }
            guard let url = components.url else {
                return .rejected(spoken: "I couldn't build the message.")
            }
            guard UIApplication.shared.canOpenURL(url) else {
                return .rejected(spoken: "This device can't send messages.")
            }
            await UIApplication.shared.open(url)
            return .launched(spoken: "")

        case .open(let url):
            guard UIApplication.shared.canOpenURL(url) else {
                return .rejected(spoken: "I can't open that app from here.")
            }
            await UIApplication.shared.open(url)
            return .launched(spoken: "")
        }
    }
}
