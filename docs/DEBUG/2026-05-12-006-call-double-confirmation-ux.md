# Bug 006 — `Call Leo Corte` shows double confirmation: GIGI bubble + iOS native dialog

- **Status**: ✅ fixed
- **Severity**: P1 (clear UX friction on a core action)
- **Discovered**: 2026-05-12 — re-test wave
- **Area**: iOS · GigiActionBridge.makeCall (or equivalent) · UX

## Symptom

User prompt: **"Call Leo Corte"**

What happens:
1. GIGI bubble appears: *"Tap Call to confirm — iOS requires your approval before dialing leo corte."*
2. iOS overlays its NATIVE confirmation alert on top of the chat:

```
┌─────────────────────────────────┐
│  Chiama +39 375 6548643         │  ← blue primary button
├─────────────────────────────────┤
│  Annulla                        │  ← cancel
└─────────────────────────────────┘
```

3. User has to tap the iOS button to actually dial.

## What's wrong

**Double confirmation**:
- GIGI's bubble already says "Tap Call to confirm"
- iOS shows its own alert immediately overlaying the chat
- User confusion: which one is the "real" confirmation? Why are there two?

The chat bubble adds zero information — the iOS native alert is the
authoritative gate (system enforces it for any `tel://` URL opening,
GIGI can't bypass it). The bubble text is therefore redundant noise.

## Evidence

Tester screenshot 2 in 2026-05-12 thread:
- Black GIGI chat with "Set a timer of two" / "Call Leo Corte" history
- iOS native alert centered with phone number + Annulla

## Expected behavior (2 viable UX paths)

### Option A — silent dial (cleanest)
- GIGI dispatches the call action immediately
- iOS shows its native confirm alert (unavoidable for `tel://`)
- GIGI bubble (if any) appears AFTER the call completes: "Called leo corte" or "Call cancelled"
- No "Tap Call to confirm" text shown — the iOS alert IS the confirmation

### Option B — explicit GIGI confirm card
- GIGI shows a custom in-chat card: "Call Leo Corte? (Tap to dial)" with a single Call button
- User taps → opens `tel://` → iOS shows its alert (unavoidable)
- Confirms iOS alert → call dials
- More taps but more explicit; useful when contact resolution is ambiguous

For v1 demo: **Option A** is simpler and matches Siri's behavior. Save Option B for ambiguous contact matches ("which Leo did you mean?").

## Root cause hypothesis

In `GigiActionBridge.swift`, the `make_call` action likely:
1. Resolves the contact name → phone number
2. Opens `tel://+393756548643` URL
3. Returns a string like "Tap Call to confirm — iOS requires your approval before dialing leo corte."

That return string becomes the chat bubble. The fix is to either:
- Return a much shorter / more informative string (e.g., empty or "Calling leo corte")
- OR return after the iOS alert resolves (harder — would need to track URL open completion)

## Proposed fix (Option A — recommended)

In `GigiActionBridge.makeCall` (and `facetimeCall`):

```swift
// Before: returns "Tap Call to confirm — iOS requires your approval..."
// After: returns just "Calling \(contactName)" — iOS handles the rest

private func makeCall(contact: String) async -> String {
    guard let phoneNumber = await resolveContactPhone(contact) else {
        return "I couldn't find \(contact) in your contacts."
    }
    if let url = URL(string: "tel://\(phoneNumber)") {
        await MainActor.run { UIApplication.shared.open(url) }
    }
    // Just acknowledge — iOS will show its system alert; the user accepts
    // or cancels there. No need for GIGI to also explain that.
    return "Calling \(contact)."
}
```

If contact resolution is ambiguous (multiple matches):
```swift
return "Which \(contact) — \(matches.joined(separator: " or "))?"
```

## Edge cases

- Number not in contacts: shorter "I couldn't find X" message (no dial attempt)
- Multiple matches: ask which one (Option B fallback)
- Tester denied tel:// permission: catch the failure, surface a clean error
- VoIP-only number: should still open `tel://` and let iOS handle (which may route to FaceTime Audio if user has it set)

## Files involved

| File | What |
|---|---|
| `02_GIGI_APP/GIGI/GigiActionBridge.swift` (functions: `makeCall`, `facetimeCall`) | Returns the bubble text |
| Possibly `GigiActionBridge.swift` (text constant) | If "Tap Call to confirm" is hardcoded there |

## Resolution

- **Commit**: `cfc8b8e` (2026-05-12)
- **IPA**: TBD — next build (cumulative with bugs 001-004)
- **Files changed**: `02_GIGI_APP/GIGI/GigiActionBridge.swift:348` — return text simplified.

### Change applied

```swift
// Before:
return opened ? "Tap Call to confirm — iOS requires your approval before dialing \(contact)." : "Couldn't start the call."

// After:
return opened ? "Calling \(contact)." : "Couldn't start the call."
```

Now the chat shows a short, informative bubble; the iOS native alert is the
sole confirmation. Matches Siri's UX pattern (Siri says "Calling X" and iOS
shows its native confirm alert — no duplicate text).

`facetimeCall` already had clean copy ("Starting FaceTime with X") and was
left unchanged.

### Test plan

- "Call Leo Corte" → bubble: "Calling leo corte." → iOS native alert appears immediately → user taps Call → dial proceeds. Single confirmation.
- "Call nonexistent contact" → bubble: "Couldn't find nonexistent contact in your contacts." → no iOS alert.
- "Call" (no contact) → bubble: "Who do you want to call?" → no dispatch.
