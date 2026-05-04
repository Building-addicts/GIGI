# H2 — Harness Offline + Fallback Disabled

**Status:** ⏳ Pending PM execution
**Issue:** #69

## Setup
- Settings → toggle Gemini fallback OFF
- Kill harness on Mac

## Steps
1. iPhone wake + a tool-dependent query (e.g. "send a WhatsApp to Fede")
2. Observe: clean user-facing failure ("Servizio non disponibile, riprova" or eq.)
3. Confirm NO crash, NO `mDataByteSize (0)` buffer-empty error in log

## AC
- [ ] AC2: clean error message displayed
- [ ] AC2: no crash
- [ ] AC2: no buffer-empty error in app log

## Failure rule
Any crash here = release blocker P0.

## Evidence
- [ ] Screen recording: _link_
- [ ] App log filtered: _link_
