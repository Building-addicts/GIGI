# Background SFSpeechRecognizer Spike — issue #146

**Goal**: confirm whether `SFSpeechRecognizer` can capture audio when triggered
by an iOS Shortcut while the GIGI app is fully backgrounded or terminated.
This is the architectural blocker for issue #143 (Action Button → DI →
Orchestrator → Shortcut) — without background capture, the premium UX path
collapses to a fallback using the system `Dictate Text` action.

## Setup

- **Build branch**: `feat/issue-146-bg-speech`
- **Spike entrypoint**: `02_GIGI_APP/GIGI/GigiSpeechSpike.swift`
- **AppIntent name**: `GIGI Speech Spike` (visible in Shortcuts.app picker)
- **`openAppWhenRun`**: `false` (no foreground)
- **Capture duration**: configurable via Shortcut parameter (default 4 s)
- **Findings log**: persisted to App Group container at
  `group.com.gigi.presence/speech-spike.log` so user can retrieve after
  device test (see "How to retrieve log" below)

### Prerequisites already in place

- `Info.plist` `UIBackgroundModes` includes `audio` ✅
- `NSMicrophoneUsageDescription` ✅
- `NSSpeechRecognitionUsageDescription` ✅
- `com.apple.developer.siri` entitlement ✅
- App Group `group.com.gigi.presence` ✅

## How to test on physical device

1. Install build on iPhone via SSH+xcodebuild from MacInCloud (per
   `CLAUDE.local.md`) or via Xcode→Run on connected device.
2. Open Shortcuts.app on the same iPhone.
3. Create a one-action Shortcut: **`GIGI Speech Spike`** (the AppIntent
   appears in the picker once the app is installed and launched once).
4. Long-press the Shortcut tile → "Add to Home Screen" so it can be invoked
   from springboard without opening Shortcuts.app first.
5. Run the 3 scenarios below.
6. After each run, retrieve the findings log (see below) and paste the
   relevant lines into the result tables.

### Retrieve findings log

Two paths:

**A. From iPhone** — Files.app → On My iPhone → GIGI → `speech-spike.log`
(may need `UIFileSharingEnabled` = YES in Info.plist — currently FALSE,
re-enable temporarily if needed).

**B. From Mac** — `xcrun devicectl device process list ...` and pull
container, or simpler: connect device to Mac, use Xcode → Devices and
Simulators → select GIGI app → Download Container → unpack and open
`AppData/Library/Group Containers/group.com.gigi.presence/speech-spike.log`.

## Test scenarios

### Scenario A — App in foreground

Baseline. Should always succeed.

| Field | Result |
|---|---|
| Run started | `<ISO timestamp>` |
| Spoken phrase | `"the quick brown fox"` |
| Transcript returned | `<paste here>` |
| Elapsed time | `<paste here>` |
| Pass / Fail | `<PASS or FAIL>` |
| Notes | |

### Scenario B — App in background, NOT killed

1. Open GIGI app.
2. Press Home button (do NOT swipe up to kill).
3. Open Shortcuts.app, run the spike Shortcut.
4. Speak when the iOS mic indicator appears.

| Field | Result |
|---|---|
| Run started | |
| Spoken phrase | |
| Transcript returned | |
| Elapsed time | |
| Pass / Fail | |
| Error code (if FAIL) | |
| Notes | |

### Scenario C — App fully terminated

1. Open GIGI app, then swipe up from app switcher to KILL.
2. Without re-opening, run the spike Shortcut from Home Screen tile or
   Shortcuts.app.
3. Speak when iOS mic indicator appears.

| Field | Result |
|---|---|
| Run started | |
| Spoken phrase | |
| Transcript returned | |
| Elapsed time | |
| Pass / Fail | |
| Error code (if FAIL) | |
| Notes | |

## Decision matrix

| Scenarios that PASS | Path forward |
|---|---|
| A only | Pragmatic fallback: keep `Dictate Text` system action; descend DI in parallel. UX downgrade. |
| A + B | Premium path viable but only when user keeps GIGI in recent apps. Document caveat in onboarding. |
| A + B + C | Premium path fully unlocked. Proceed with `GigiBeginSessionIntent` design as planned in #147. |

## Known constraints / risks

- iOS may suspend the app after ~30 s in background even with `audio` mode
  declared, unless an `AVAudioSession` is actively recording. The spike
  starts the session immediately on `perform()` so this should hold.
- `SFSpeechRecognizer.supportsOnDeviceRecognition` may be `false` on older
  models (iPhone <12) or first-launch after install (model still downloading).
  Spike falls back to network recognition with a warning logged.
- Shortcut runtime may impose its own timeout (~30 s default per AppIntent
  step). Capture duration of 4 s leaves comfortable headroom.

## Decision (fill after device test)

- [ ] Scenario A pass
- [ ] Scenario B pass
- [ ] Scenario C pass
- [ ] **Final path**: `<premium | hybrid | pragmatic-fallback>`
- [ ] Rationale (1-2 sentences):
- [ ] Sub #147 unblocked / blocked
