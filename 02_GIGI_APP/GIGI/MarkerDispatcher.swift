import Foundation
import UIKit

// MARK: - MarkerDispatcher
//
// Executes a `LocalActionRouter` marker by handing the corresponding
// native action to iOS. Used by the foreground orchestrator and by the
// Control Center quick-listen path; the background AppIntent does not
// dispatch here because the user's Shortcut owns the privileged action
// surface in that path.
//
// Strategy is direct iOS URL schemes — `tel:`, `sms:`, `<scheme>://` —
// rather than re-routing through a Shortcut. The user-perceived outcome
// is identical (Apple confirmation UI for calls, native composer for
// SMS, target app for OPEN) and we don't depend on the user having
// installed a particular Shortcut to make in-app voice work.

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

        switch kind {
        case .call(let phone):
            return await dispatchCall(phone: phone)
        case .sms(let phone, let body):
            return await dispatchSMS(phone: phone, body: body)
        case .open(let url):
            return await dispatchOpen(url: url)
        }
    }

    // MARK: - Call

    private static func dispatchCall(phone: String) async -> DispatchResult {
        // The router emits `CALL:<NameOnly>` when contact resolution
        // failed. Refusing to launch a tel:// URL with an alphabetic
        // string keeps us from dialing into garbage.
        guard phone.first == "+" || phone.first?.isNumber == true else {
            return .rejected(spoken: "I couldn't find a phone number for \(phone).")
        }

        // tel:// uses the canonical scheme that triggers Apple's native
        // call confirmation sheet. tel: alone (single colon) opens the
        // dialer without confirmation on some carriers — not desired.
        guard let url = URL(string: "tel://\(phone)") else {
            return .rejected(spoken: "That number doesn't look dialable.")
        }
        guard UIApplication.shared.canOpenURL(url) else {
            return .rejected(spoken: "This device can't place phone calls.")
        }
        await UIApplication.shared.open(url)
        return .launched(spoken: "")
    }

    // MARK: - SMS

    private static func dispatchSMS(phone: String, body: String) async -> DispatchResult {
        // Apple supports both `sms:<number>` and `sms:<number>&body=<text>`.
        // The `&body=` form pre-fills the composer; user still has to tap
        // Send, which is the Apple-compliant flow.
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
    }

    // MARK: - Open

    private static func dispatchOpen(url: URL) async -> DispatchResult {
        // canOpenURL only returns true for schemes whitelisted in
        // LSApplicationQueriesSchemes. The router's scheme list mirrors
        // that whitelist; if a new scheme is added to the router without
        // updating Info.plist, this returns false silently.
        guard UIApplication.shared.canOpenURL(url) else {
            return .rejected(spoken: "I can't open that app from here.")
        }
        await UIApplication.shared.open(url)
        return .launched(spoken: "")
    }
}
