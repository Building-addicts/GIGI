# SPIKE — Background SFSpeechRecognizer from AppIntent

**Status:** ⏳ Pending physical-device execution
**Issue:** #146 (Sub #143 · 3/6)
**Spike file:** `02_GIGI_APP/GIGI/GigiSpeechSpike.swift`

## Goal

Confirm or refute whether `SFSpeechRecognizer.recognitionTask` can transcribe a live audio buffer when iOS launches us via a Shortcut with `openAppWhenRun = false` and the app is fully terminated.

If YES → ship the premium Action Button path (custom DI banner with live waveform).
If NO → fallback to Dictate Text in the Shortcut, run our DI banner in parallel.

## Setup (one-time)

1. Add `audio` to **Background Modes** in `02_GIGI_APP/GIGI/Info.plist` under `UIBackgroundModes`.
2. Build paid-signed IPA via the existing MacInCloud pipeline (`CLAUDE.local.md` §Auto-inject Groq key into IPA).
3. Install on iPhone 17 Pro and iPhone 14 (need both — A17 vs A15 baseband can change BG audio behavior).
4. Add a Shortcut: "Run GIGI Speech Spike" with the AppIntent `GigiSpeechSpike` and a final Speak Text step.

## Scenarios

| ID | App state | Trigger | Expected | Result |
|---|---|---|---|---|
| A | Foreground, focused | Run shortcut from Shortcuts app | Transcript captured 6s | _to be filled_ |
| B | Background, not killed | Run shortcut from Action Button | Transcript captured | _to be filled_ |
| C | Fully terminated | Force-quit + Action Button | Transcript captured | _to be filled_ |

For each scenario, capture:
- Final dialog text (returned by AppIntent — visible in Speak Text)
- Time elapsed (ms)
- Console.app log (filter by GIGI process)

## Logs to attach

- iPhone 17 Pro · scenario A: _link_
- iPhone 17 Pro · scenario B: _link_
- iPhone 17 Pro · scenario C: _link_
- iPhone 14 · scenario A: _link_
- iPhone 14 · scenario B: _link_
- iPhone 14 · scenario C: _link_

## Decision

_to be filled after data lands_

- [ ] Premium path is viable (scenario C passes on both devices)
- [ ] Premium path is NOT viable → fallback to Dictate Text

If fallback: open follow-up sub-issue documenting the fallback flow + UX cost (system Dictate Text overlay shown briefly).

## Cleanup

When the spike is closed: remove `GigiSpeechSpike.swift` and the Shortcut entry. Keep this doc.
