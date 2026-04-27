# GIGI Voice Assistant QA Runbook

Date: 2026-04-26
Source plan: `.omx/plans/voice-assistant-presence-2026-04-26.md`
Scope: verification artifacts only; no app behavior changes.

## Purpose

This runbook turns the voice assistant completion plan into repeatable QA evidence for real-device validation.
It covers wake word, Dynamic Island descent, barge-in, follow-up, harness offline behavior, and audio route interruptions.

Simulator results are acceptable only for build and visual smoke.
Any claim about wake reliability, lock screen behavior, background audio, Dynamic Island attention, route interruptions,
or iOS suspension must be verified on real iPhone hardware.

## Test Evidence Packet

Create one packet per device and iOS build. Each packet should include:

- Device model, iOS version, battery state, Low Power Mode state, Focus mode state, network state, audio route,
  and whether Dynamic Island is available.
- App build identifier, commit SHA, test date/time, tester name, and harness URL/config state.
- Screen recording for Dynamic Island, Lock Screen, barge-in, follow-up, and interruption scenarios.
- Structured app logs exported for each scenario.
- Harness server logs for every harness online/offline scenario.
- Pass/fail notes with the scenario ID from this runbook.

Required evidence fields per voice turn:

| Field | Required value |
|---|---|
| `turnId` | Stable identifier visible across wake, listen, think, speak, follow-up, and ready/off states |
| `presenceState` | Ready, Listening, Thinking, Working, Speaking, Follow-up, Muted, Needs Attention, Off |
| `wakeEvent` | Started, detected, ignored, stopped, failed, or unavailable |
| `activityOwner` | Presence activity, turn activity, none, or recovery surface |
| `audioRoute` | Built-in, speaker, receiver, AirPods, Bluetooth HFP, wired, or changed |
| `speechLifecycle` | Started, finished, cancelled, interrupted, skipped, or empty-blocked |
| `harnessState` | Online, unpaired, offline, unreachable, timeout, local fallback, or user-facing failure |

## Device Matrix

Use at least one device from each required class before release.
Mark missing classes as release blockers unless the product owner explicitly accepts the gap.

| ID | Class | Hardware | iOS | Required scenarios |
|---|---|---|---|---|
| D1 | Dynamic Island primary | iPhone 15 Pro, 16 Pro, or newer real device | Current | All scenarios |
| D2 | Dynamic Island baseline | iPhone 14 Pro real device | Current or previous supported | Wake, descent, throttling, lock, follow-up |
| D3 | No Dynamic Island | iPhone 13 or 14 non-Pro real device | Current | Lock Screen, recovery fallback, audio interruption |
| D4 | Small layout | iPhone SE-class device if supported | Current or previous supported | Layout, compact copy, permissions |
| D5 | Previous iOS | Any supported real device | Previous supported | Presence, ActivityKit, route-change regression |
| S1 | Simulator smoke | iPhone Pro simulator | Current Xcode runtime | Build, launch, widget smoke only |

Audio/network/power overlays to apply across D1 and at least one non-Dynamic-Island device:

| Overlay | Required variants |
|---|---|
| Audio route | Built-in mic/speaker, AirPods, generic Bluetooth HFP, route disconnect, route reconnect |
| Network | Wi-Fi online, harness down, harness unpaired, airplane mode, local-network denied if applicable |
| Power | Normal battery, Low Power Mode, locked charging, locked unplugged |
| App state | Foreground, Home Screen, another app open, Lock Screen 5/15/30/60 minutes |

## Global Setup

1. Install the test build on the device.
2. Enable microphone, speech recognition, Live Activities, notification permissions, and local network permissions where applicable.
3. Enable Presence or Always Available mode.
4. Confirm exactly one GIGI Live Activity is visible when Presence is Ready.
5. Confirm harness state for the scenario: online, offline, unpaired, or unreachable.
6. Start screen recording before each Dynamic Island, Lock Screen, or interruption scenario.
7. Capture app logs and harness logs with timestamps synchronized to the device clock.

## Acceptance Checklist

### W1 - Wake Word Only Runs Under Presence

Setup: Presence disabled, app foreground, no active QuickTalk session.

Steps:
1. Say "Hey GIGI" three times in quiet conditions.
2. Background the app and repeat.
3. Re-enable Presence and confirm Ready state appears.
4. Say "Hey GIGI" once.

Pass:
- Wake monitoring is inactive while Presence is disabled.
- No Listening state appears before Presence is enabled.
- With Presence enabled, wake starts one turn within 2 seconds in quiet conditions.

Fail:
- Wake continues outside Presence.
- Mic monitoring remains active after Presence is disabled.
- Wake requires opening the app manually while the process is alive and eligible.

### W2 - Quiet Room Wake Reliability

Setup: Presence Ready, device idle, quiet room, screen unlocked or Home Screen.

Steps:
1. Perform 10 wake attempts with "Hey GIGI".
2. Space attempts 5 to 10 seconds apart.
3. Return to Ready between attempts.

Pass:
- 10/10 detections start Listening within 2 seconds.
- No duplicate turn activity or stale Live Activity remains.

Fail:
- Any missed detection in quiet conditions.
- Any stuck Listening, Thinking, Working, Speaking, Done, or duplicate activity.

### W3 - Moderate Noise Wake Reliability

Setup: Presence Ready, moderate speech/media noise at normal room volume.

Steps:
1. Perform 10 wake attempts with "Hey GIGI".
2. Record time from final wake syllable to Listening state.

Pass:
- At least 8/10 detections start Listening within 3 seconds.
- Failures surface Ready or Needs Attention, not a stuck state.

Fail:
- Fewer than 8 detections.
- Wake failure leaves the app in silent or misleading Ready state without recovery evidence.

### W4 - False Positive Soak

Setup: Presence Ready, no intentional wake phrase.

Steps:
1. Run 30 minutes of normal conversation and media.
2. Include phrases with "Luigi" and unrelated "Gigi" mentions.
3. Do not say "Hey GIGI", "Ehi GIGI", or "OK GIGI".

Pass:
- Zero unintended Listening events.
- If bare "gigi" remains enabled, every wake caused by bare "gigi" is counted as a false positive
  unless the product decision explicitly allows it.

Fail:
- Any unintended wake event.
- Any Live Activity attention event without a deliberate wake/tap/recovery action.

### W5 - Lock Duration Wake and Recovery

Setup: Presence Ready, device locked, screen off.

Steps:
1. Lock the device for 5 minutes, then say "Hey GIGI".
2. Repeat after 15, 30, and 60 minutes.
3. For every miss, tap the Live Activity or supported recovery surface.

Pass:
- If iOS keeps the process eligible, wake starts Listening within 2 seconds.
- If iOS pauses or suspends the app, the visible surface is state-true and actionable.
- Recovery tap opens listening or a clear recovery path.

Fail:
- Silent failure with stale Ready copy.
- Recovery opens a dead or duplicate session.

### D1 - Dynamic Island Descent on Wake

Setup: Dynamic Island device, Presence Ready, app in background or another app open.

Steps:
1. Say "Hey GIGI".
2. Observe compact/minimal island and expanded state.
3. Repeat 10 times spaced 5 to 10 seconds apart.

Pass:
- Dynamic Island or Lock Screen Live Activity enters Listening within 2 seconds.
- Wake uses the visible attention/descent path, not only a silent content update.
- Exactly one active GIGI surface owns the turn.
- Presence restores to Ready or Follow-up after each turn.

Fail:
- Duplicate activities, stale activities, stuck Done, no visible descent/attention, or missing Presence restore.

### D2 - Dynamic Island Controls

Setup: Presence Ready on Dynamic Island device.

Steps:
1. Expand the Live Activity.
2. Tap Mute.
3. Say "Hey GIGI".
4. Tap Unmute.
5. Say "Hey GIGI".
6. Tap Stop.

Pass:
- Mute keeps Presence visible but disables wake/listening.
- Unmute requires explicit user action.
- Stop ends Presence and removes always-available behavior.

Fail:
- Accidental island tap unmutes.
- Stop leaves wake, VAD, or Live Activity running.

### B1 - Tap Barge-In While Speaking

Setup: Presence enabled; prompt GIGI for a long spoken answer.

Steps:
1. While TTS is speaking, use the supported tap/barge-in entry point.
2. Speak a new command.
3. Verify the next answer uses prior conversation context.

Pass:
- TTS stops immediately.
- State transitions Speaking -> Listening without showing Done.
- Old TTS never resumes.
- New transcript becomes the next user turn with context preserved.

Fail:
- Done flashes before Listening.
- Cancelled TTS triggers normal completion/follow-up as if it finished.
- New transcript loses the previous conversation context.

### B2 - Voice Barge-In While Speaking

Setup: Presence enabled; active audio path supports voice-triggered interruption only if the implementation documents it.

Steps:
1. Prompt GIGI for a long spoken answer.
2. While TTS speaks, say "GIGI" or the supported interruption phrase.
3. Speak a new command.

Pass:
- If voice barge-in is supported on the active path, TTS stops and Listening opens as fast as possible.
- If not supported, logs and product copy identify tap/Live Activity as the supported interruption path.

Fail:
- Product claims voice barge-in works but device evidence shows no interruption.
- Old TTS resumes after interruption.

### F1 - Follow-Up Window Captures Speech

Setup: Presence enabled, harness online or local fallback available.

Steps:
1. Ask a question that gets a non-empty TTS answer.
2. Wait for TTS to finish.
3. Speak a follow-up within 8 seconds without saying wake word.

Pass:
- State changes to Follow-up or Listening without showing Done while the mic is open.
- Follow-up speech is captured as the next turn.
- Context from the prior answer is preserved.

Fail:
- Wake word is required inside the follow-up window.
- Done appears while the follow-up mic is open.

### F2 - Follow-Up Timeout Returns to Ready

Setup: Presence enabled.

Steps:
1. Ask a question that gets a non-empty TTS answer.
2. Stay silent for the full follow-up window.

Pass:
- After about 8 seconds of silence, GIGI returns to Ready/wake standby.
- Presence remains active.

Fail:
- Presence ends.
- Mic keeps recording indefinitely.
- Live Activity remains in Follow-up/Listening after timeout.

### H1 - Harness Offline With Fallback Allowed

Setup: Harness paired previously; Force Claude off or Auto Fallback on; stop the harness server or block network.

Steps:
1. Start a voice turn.
2. Ask a simple local-capable question or command.

Pass:
- GIGI responds locally where possible or gives a clear spoken failure.
- No empty TTS is sent.
- Island exits Thinking/Working and returns to Follow-up or Ready.

Fail:
- Stuck Thinking/Working.
- Crash.
- Empty spoken response.
- Error copy requires developer knowledge.

### H2 - Harness Offline With Fallback Disabled

Setup: Force Claude on and Auto Fallback off; harness stopped/unreachable.

Steps:
1. Start a voice turn.
2. Ask a harness-dependent task.

Pass:
- GIGI surfaces a clear user-facing error within the configured timeout budget.
- TTS is non-empty if spoken.
- Presence remains recoverable.

Fail:
- Spinner or Thinking state persists past timeout.
- Failure is logged only in console and not visible/actionable to the user.

### H3 - Harness Unpaired

Setup: Clear or invalidate harness pairing/config.

Steps:
1. Start a voice turn.
2. Ask a harness-dependent task.

Pass:
- GIGI reports pairing/setup required in short user-facing copy.
- No crash and no empty TTS.
- Presence returns to Ready/Follow-up.

Fail:
- Stuck Working/Thinking.
- Generic "bad response" or raw transport details shown to the user.

### A1 - AirPods Disconnect Mid-Listening

Setup: AirPods connected, Presence Ready.

Steps:
1. Say "Hey GIGI" and begin speaking a command.
2. Put AirPods in the case or disconnect Bluetooth mid-capture.

Pass:
- Capture stops safely or route falls back.
- User sees actionable copy if capture cannot continue.
- No audio state loop appears in logs.

Fail:
- Stuck Listening.
- Mic remains active with no route.
- Repeated route-change/retry loop.

### A2 - AirPods Disconnect Mid-Speaking

Setup: AirPods connected; prompt GIGI for a long spoken answer.

Steps:
1. Disconnect AirPods during TTS.
2. Observe route fallback and state recovery.

Pass:
- TTS stops or continues on the expected fallback route.
- Follow-up opens only if audio state is valid.
- Presence remains recoverable.

Fail:
- Old TTS resumes unexpectedly.
- Follow-up opens while the route is invalid.
- Done flashes after interruption/cancel.

### A3 - Phone Call or System Interruption

Setup: Presence Ready.

Steps:
1. Start Listening or Speaking.
2. Trigger a phone call, FaceTime call, Siri, alarm, or another system audio interruption.
3. End the interruption.

Pass:
- GIGI pauses, cancels, or recovers with state-true copy.
- No crash.
- On resume, Presence returns to Ready or Needs Attention with a user action.

Fail:
- Audio state loop.
- Stale Speaking/Listening after interruption ended.
- Wake engine silently dies while UI says Ready.

### A4 - Low Power and Locked Charging

Setup: Presence Ready; test Low Power Mode on/off, locked charging, and locked unplugged.

Steps:
1. Run W5 lock duration checks under each power state.
2. Capture wake availability and recovery behavior.

Pass:
- Any OS-limited state is visible as Needs Attention or recovery copy.
- No claim is made that wake is always available if iOS suppresses it.

Fail:
- Stale Ready copy when wake is unavailable.
- Background-limited behavior is undocumented in the evidence packet.

## Structured Log Review Procedure

Review logs after every scenario before marking it passed.

1. Filter logs by `turnId`.
2. Confirm there is exactly one active turn owner unless the scenario explicitly tests recovery from a duplicate/stale activity bug.
3. Confirm state order is valid:
   - Wake path: Ready -> Listening -> Thinking/Working -> Speaking -> Follow-up -> Ready.
   - Silent follow-up path: Speaking -> Follow-up -> Ready.
   - Barge-in path: Speaking -> Listening, with no Done between them.
   - Failure path: Listening/Thinking/Working -> Needs Attention or spoken fallback -> Ready/Follow-up.
4. Confirm every TTS lifecycle event distinguishes finish from cancel.
5. Confirm `didCancel` does not run the normal post-TTS completion path during barge-in.
6. Confirm route-change/interruption logs have a start event, a handled outcome, and either recovery or user-visible Needs Attention.
7. Confirm harness failures map to one of: local fallback, clear pairing error, clear offline error,
   clear timeout, or explicit unsupported state.
8. Confirm no empty string reaches TTS.
9. Confirm Live Activity request/update/end events are paired and no duplicate GIGI activity remains.
10. Record unresolved log gaps as test failures, not as passed-with-notes.

Minimum event sequence examples:

```text
turnId=... presence=Ready wake=detected activity=presence
turnId=... state=Listening activity=turn audioRoute=...
turnId=... transcript.final="..."
turnId=... state=Thinking harness=online
turnId=... tts.started textLength>0
turnId=... state=Speaking
turnId=... tts.finished
turnId=... state=Follow-up
turnId=... followup.timeout
turnId=... state=Ready activity=presence
```

```text
turnId=... state=Speaking tts.started
turnId=... interruption.source=tap
turnId=... tts.cancelled reason=bargeIn
turnId=... state=Listening
turnId=... transcript.final="..."
```

## Release Gate

The voice assistant release is not verified until:

- D1 passes all scenarios.
- D2 or D3 passes wake, Dynamic Island/Lock Screen, follow-up, harness offline, and audio interruption scenarios.
- W2, W3, and W4 meet numeric acceptance targets.
- W5 has evidence for 5, 15, 30, and 60 minute lock checks.
- All harness offline/unpaired scenarios exit Thinking/Working and avoid empty TTS.
- Every failure path has user-actionable copy.
- Known iOS suspension limits are documented in the evidence packet.

## Verification Commands

Markdown/file checks from the repository root:

```sh
test -f docs/VOICE_ASSISTANT_QA.md
grep -n "Source plan" docs/VOICE_ASSISTANT_QA.md
grep -n "Wake Word" docs/VOICE_ASSISTANT_QA.md
grep -n "Dynamic Island" docs/VOICE_ASSISTANT_QA.md
grep -n "Barge-In" docs/VOICE_ASSISTANT_QA.md
grep -n "Follow-Up" docs/VOICE_ASSISTANT_QA.md
grep -n "Harness Offline" docs/VOICE_ASSISTANT_QA.md
grep -n "Structured Log Review Procedure" docs/VOICE_ASSISTANT_QA.md
```
