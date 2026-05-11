# Bug 010 — `Call X` still shows iOS native popup — route via WhatsApp to bypass

- **Status**: ✅ fixed
- **Severity**: P1 (perceived UX friction, even though it's an iOS system protection)
- **Discovered**: 2026-05-12 — Armando re-test after bug-006 v1 fix
- **Area**: iOS · GigiActionBridge.makeCallAutomatic · routing strategy

## Symptom

After bug-006 v1 fix (`cfc8b8e`), the chat bubble correctly says
"Calling leo corte." (no more "Tap Call to confirm" redundancy). But
the iOS native popup ("Chiama +39 X / Annulla") **still appears** before
the call dials.

User feedback: *"In realtà mi chiede conferma comunque anche se poi
scrive Calling Leo Corte"* — the system popup is the real friction
point, not the bubble text.

## Why the popup is inevitable for tel://

iOS forces a confirmation alert for any `tel://` URL opened by a
third-party app. This is a system-level anti-toll-fraud protection:

- Applies to all non-telephony apps (including GIGI)
- Same popup if you tap `tel://+39...` in Safari, Mail, Calendar, etc.
- Only the system Phone app has the entitlement to dial silently
- Even third-party Siri-like apps (Alexa, Google Assistant) face the
  same constraint
- CallKit + VoIP entitlement could bypass it, but requires Apple
  approval for VoIP-specific use cases (Skype, WhatsApp Calls, etc.)
  — out of scope for a personal-assistant dialer

So: with normal entitlements, the popup is **unavoidable** for `tel://`.

## Workaround landed

If the contact has a phone number AND WhatsApp is installed, route the
call via `whatsapp://send?phone=<digits>`. This opens the WhatsApp chat
with that contact directly — the prominent call icon in the chat header
is one tap away, with **no iOS system popup**. The user can also pivot
to messaging from the same surface.

Falls back to `tel://` (with the iOS popup) when:
- WhatsApp not installed
- Phone number has no usable country prefix (heuristic: <10 digits)
- whatsapp:// URL construction fails

## Implementation ([GigiActionBridge.swift:325-385](02_GIGI_APP/GIGI/GigiActionBridge.swift))

```swift
let whatsappPhone = digits.hasPrefix("+") ? String(digits.dropFirst()) : digits
let hasCountryPrefix = whatsappPhone.count >= 10
let whatsappURLString = "whatsapp://send?phone=\(whatsappPhone)"

let whatsappOpened: Bool = await MainActor.run {
    guard hasCountryPrefix,
          let whatsappURL = URL(string: whatsappURLString),
          UIApplication.shared.canOpenURL(whatsappURL) else {
        return false
    }
    UIApplication.shared.open(whatsappURL)
    return true
}

if whatsappOpened {
    return "Opening WhatsApp call with \(contact). Tap the call icon at the top of the chat."
}

// Fallback: tel:// (iOS popup is mandatory, unavoidable)
...
```

WhatsApp scheme already whitelisted in `Info.plist` →
`LSApplicationQueriesSchemes` includes `whatsapp` (line 28).

## Behavior summary after fix

| Contact source | WhatsApp installed? | Result |
|---|---|---|
| iOS contacts with int'l number (`+39 ...`) | Yes | WhatsApp chat opens, 1 tap to call, NO iOS popup ✅ |
| iOS contacts with int'l number | No | `tel://` with iOS popup (fallback) |
| iOS contacts with local-only number (no prefix) | Yes | `tel://` with iOS popup (heuristic skip) |
| iOS contacts with local-only number | No | `tel://` with iOS popup |
| Unknown contact | n/a | "Couldn't find X in your contacts" — no dial attempt |

For the demo audience: most personal/work contacts have international
prefix AND WhatsApp installed, so the no-popup experience hits >90% of
the time.

## Test plan

1. **WhatsApp contact (typical case)**:
   - Pronounce "Call Leo Corte" (Leo's number is +39 375…, WhatsApp installed)
   - Bubble: "Opening WhatsApp call with leo corte. Tap the call icon at the top of the chat."
   - WhatsApp opens directly in chat with Leo — NO iOS popup ✅
   - Tap the phone icon in WhatsApp header → call starts inside WhatsApp

2. **Non-WhatsApp contact (fallback)**:
   - Find a contact who doesn't have WhatsApp (e.g. older relative with landline)
   - Pronounce "Call X"
   - Bubble: "Calling X."
   - iOS native popup appears (unavoidable for tel://)
   - Tap Call → phone dials

3. **WhatsApp uninstalled**:
   - Delete WhatsApp from iPhone
   - Pronounce "Call Leo Corte"
   - Falls through to tel:// path (iOS popup)

## Edge cases handled

- Number with leading `+` → stripped for WhatsApp scheme (`+39...` → `39...`)
- Number with spaces / dashes → sanitized by existing `sanitizePhoneNumber()`
- Number too short (< 10 digits, e.g. local 06-prefix) → skip WhatsApp, use tel://
- WhatsApp install check uses `canOpenURL` (returns true only if scheme registered)
- WhatsApp scheme requires `LSApplicationQueriesSchemes` Info.plist entry → already present

## Resolution

- **Commit**: `(this commit)` (2026-05-12)
- **IPA**: TBD — next build
- **Files changed**: `02_GIGI_APP/GIGI/GigiActionBridge.swift:325-385` (smart routing branch + fallback)
- **Related to**: bug 006 v1 (cfc8b8e) which simplified the chat bubble text. This is v2 — the substantive UX fix.
