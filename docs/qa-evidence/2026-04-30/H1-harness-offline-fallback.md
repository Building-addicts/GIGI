# H1 — Harness Offline + Fallback Gemini

**Status:** ⏳ Pending PM execution
**Issue:** #69 (Sub #17 · 6/7)

## Setup
- Active session iPhone, harness running on Mac, fallback Gemini enabled in Settings

## Steps
1. Start a normal voice session
2. Fede kills harness (Ctrl+C)
3. iPhone wake + "che ore sono?" (or any time-of-day style query)
4. Observe: offline banner on pill, Gemini local fallback responds within 8s
5. Restart harness — recovery should be automatic

## AC
- [ ] AC1: offline banner visible
- [ ] AC1: Gemini fallback answers within 8s
- [ ] AC1: harness recovery automatic on restart

## Evidence
- [ ] Screen recording iPhone: _link_
- [ ] Harness log (kill + restart): _link_
- [ ] App log (filter harnessState + speechLifecycle): _link_
- [ ] Recovery timer in seconds: _to be filled_

## Note
H1 fail = demo a rischio se Wi-Fi event flaky.
