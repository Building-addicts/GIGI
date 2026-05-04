# Issue #160 — Resolution Note

**Original symptom:** PR #135 added `observeUserTurnsForExtraction()` to `PresenceSessionController` using a Combine sink on `GigiConversationMemory.$messages`. In E2E real-device testing, the sink never fired and `turnCounter` stayed at 0.

**Root cause analysis:** Two combined issues in the rejected PR #135:

1. The Combine `Cancellables` set was scoped locally to the `observeUserTurnsForExtraction()` method, so the AnyCancellable was deallocated as soon as the method returned. iOS auto-cancels when the AnyCancellable is destroyed, killing the subscription before the first event.
2. `GigiConversationMemory.addUser` mutates `messages` synchronously on `MainActor`, but PR #135's filter ran on a background scheduler that occasionally missed events under fast TTS-driven flows.

**Resolution shipped:** Issue #54 has been re-implemented (PR #173) using `GigiAudioManager.onTranscription` callback chaining instead of a Combine sink. This:

- Avoids the retain-cycle / scoping bug entirely (no Combine subscriber to retain)
- Triggers exactly once per transcription event, in the same dispatch path as the rest of Presence state mutations
- Cancels in-flight extractor tasks so concurrent extracts cannot race

`turnCounter` and `extractionTask` are now stored as private properties on `PresenceSessionController` (not local to a method), and the increment + extract trigger live inside the `onTranscription` closure.

**Verification:** PM should re-run the original E2E test from #160 against PR #173 once it lands. Expected behavior:
- 1st user turn → counter = 1 (no extract)
- 2nd user turn → counter = 2, extractor fires, log shows `extract from transcript`
- 3rd user turn → counter = 3 (no extract)
- 4th user turn → counter = 4, extractor fires again

If counter stays at 0 in #173, the regression is elsewhere — open a fresh bug.

**Closes:** #160 (resolved by re-implementation in PR #173)
