# Bug 005 — `Set a timer for two minutes` still fails after wordToNumber fix

- **Status**: open · awaiting tester confirmation of installed IPA build
- **Severity**: P1 (if real regression) · P3 (if just IPA not installed)
- **Discovered**: 2026-05-12 — re-test wave after bug-004 fix
- **Area**: iOS · GigiActionBridge · parseTimerDuration · OR install pipeline

## Symptom

After commit `d1c75e9` (wordToNumber pre-pass for parseTimerDuration), the
tester sent screenshots showing the SAME failure mode:

- "Set a timer **of** two" → "How long should the timer run? Say something like '10 minutes'."
- "Set a timer **for** two minutes" → "How long should the timer run? Say something like '10 minutes'."

## Why this might NOT be a regression

The most likely explanation is that the tester is still on a pre-`d1c75e9`
IPA (`GIGI-28bd428.ipa` or earlier). The new build `GIGI-d1c75e9.ipa` was
generated at 23:40 and may not have been installed yet at the time of this
screenshot.

## How to confirm

1. iPhone Settings → About GIGI (or app info section): note the build number / git SHA stamp if visible.
2. OR: trigger a query that exercises a `d1c75e9`-only code path (e.g.,
   "Explain Bayes theorem" should go to delegate_local via the Layer A FM
   prompt fix). If it still goes to delegate_cloud → all 4 bug fixes are
   missing → IPA is old.
3. OR: install `C:\Users\arman\Desktop\GIGI\bug\GIGI-d1c75e9.ipa` and retest.

## If still failing on the d1c75e9 build

Diagnose further by looking at:

- **Apple FM tool invocation path**: respondWithTools may return the
  "How long should the timer run?" sentence WITHOUT actually calling
  `FMSetTimerTool.call()`. That string is `setTimer`'s clarification
  fallback (`return "How long should the timer run? Say something like '10 minutes'."`)
  in `GigiActionBridge.swift`, called only when `parseTimerDuration(input)` returns 0.

  But Apple FM might be generating that same sentence from its own
  reasoning, not from the bridge. To distinguish, check
  `Settings → Last router decision (JSON)`:
    - `path=native_tool`, `primaryAction=set_timer`, `slots.duration=...`
      → router did its job; bridge failed to parse
    - `path=ask_clarification` → router never invoked set_timer

- **Live monitor**: if `[ios-request]` for the prompt appears with NO
  `local-llm` follow-up, it means the path stayed on-device. Check the
  JSON for what Apple FM decided.

- **Apple FM Tool calling toggle**: if `Use Apple FM Tool calling (Path 2)`
  is OFF in Settings, slots flow through the bridge and `setTimer(input:)`
  uses `intent.params["text"]` — verify the wordToNumber fix actually
  fires on that param.

## Possible root causes (in order of likelihood)

1. **IPA `d1c75e9` not installed** → install latest IPA. Most likely.
2. **respondWithTools returns clarification WITHOUT calling the tool**: Apple
   FM may not be confident enough to invoke `FMSetTimerTool` with
   `duration="two minutes"` because the argument doesn't pass its
   `@Guide(description: "Duration in natural language. Examples: '5 minutes', ...")`
   pattern. Solution: tighten the @Guide example list to include
   "two minutes", "ten seconds", etc.
3. **Wrong dispatch path**: the request goes through the legacy fast-path
   `deterministicFastPath` (line 100 of GigiAgentEngine) which uses
   `GigiNLUEngine.classify(text)` — that classifier may use its own
   duration regex that doesn't run normalizeWordNumerals.

## Files involved

| File | What |
|---|---|
| `02_GIGI_APP/GIGI/GigiActionBridge.swift:467+` | parseTimerDuration with new normalizeWordNumerals (d1c75e9) |
| `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift:40-62` | FMSetTimerTool @Guide for duration arg |
| `02_GIGI_APP/GIGI/GigiNLUEngine.swift:656+` | Deterministic fast-path NLU for set_timer — may have own regex |
| `02_GIGI_APP/GIGI/GigiAgentEngine.swift:100` | deterministicFastPath wraparound |

## Resolution

_(empty — pending tester confirmation of IPA build)_
