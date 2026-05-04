# Follow-up #162 — `Process speech with GIGI` action visibility in Shortcuts editor

**Status:** ⏳ Pending physical-device verification
**Issue:** #162
**Parent:** #102

## Symptom (PM observation post-#103 merge)

When trying to build the "Talk to GIGI" Shortcut from the onboarding step 5, the action **"Process speech with GIGI"** (= `GigiBackgroundTalkIntent`) does not appear in the Shortcuts editor's "Add Action" search results.

PM exact words: _"Nell'app il shortcut è come se non fosse dinamico, non prendessi dinamicamente quello che viene appena installato"_.

## Verification protocol

Run on **two devices** (iPhone 14 PeterPan + iPhone 17 Pro) to disentangle device-specific quirks from a real registration bug.

For each device:

1. Install the latest paid-signed IPA (post-#103 merge).
2. **Launch GIGI once**, hit any in-app screen so AppIntents register, then exit.
3. **Force-quit Shortcuts** (swipe up on it from the App Switcher).
4. Re-open Shortcuts → New Shortcut → Add Action.
5. Search field: type "process speech".
6. Expected: "Process speech with GIGI" appears in results.

Record:

| Device | Result step 6 | After reboot? |
|---|---|---|
| iPhone 14 PeterPan | _to fill_ | _to fill_ |
| iPhone 17 Pro | _to fill_ | _to fill_ |

If step 6 fails on both devices even after a reboot, the registration is genuinely missing — not a quirk.

## Possible root causes if reproduced

1. `GigiBackgroundTalkIntent` is intentionally NOT in `GigiAppShortcuts.appShortcuts`. Apple still indexes the intent for action search via the AppIntents framework — but only if the file is in the main app target AND the AppIntents metadata is generated at build time (`AppIntentMetadata.json` in the bundle).
2. Possibility: target membership of `GigiBackgroundTalkIntent.swift` is wrong (widget extension instead of main app). Verify in Xcode → File Inspector → Target Membership.
3. Possibility: missing `LocalizedStringResource` table — without a Localizable.strings entry, Spotlight may skip the intent for action search even though it exists.

## Mitigation if root cause is real

- Adding `GigiBackgroundTalkIntent` as a phrase-less entry in `GigiAppShortcuts.appShortcuts` would force registration. Caveat: AppShortcuts requires no-input intents or a parameterized phrase — would need to declare a `text: String` parameter prompt, which is what we deliberately avoided.
- Alternative: ship a pre-built `.shortcut` file via deep-link onboarding. Tap the link → iOS imports the Shortcut wholesale, no manual action search required.

## Why merged anyway

PR #103 was merged because:

- Action Button hardware path is the primary trigger for the demo.
- Shortcut visibility is a one-time onboarding annoyance, not a runtime breakage.
- Verification protocol above is mechanical and fits the QA gate window.

If this follow-up reproduces the issue on both devices, open a P1 bug pre-demo.
