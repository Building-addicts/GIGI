# Edge T10.3 — Empty Speech / Silence Post-Wake

**Status:** ⏳ Pending PM execution
**Issue:** #69

## Steps
1. Wake "Hey GIGI"
2. Stay silent for 6 seconds (VAD timeout) OR force STT to return empty string
3. Observe: pill transitions directly to .done

## AC
- [ ] AC4: pill .done without errors
- [ ] AC4: log clean — NO `mDataByteSize (0)` audio error
- [ ] AC4: `speech.didStart` not invoked with empty utterance

## Evidence
- [ ] Screen recording: _link_
- [ ] App log filter `speechLifecycle`: _link_

## Reference
- DEBUG_DI_ANALYSIS.md item C
- TEST_PLAN.md T10.3
