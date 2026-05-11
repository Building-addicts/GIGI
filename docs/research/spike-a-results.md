# Spike A — Apple FM Tool Calling Results

> **Status**: Awaiting test runs (template ready for Armando to fill in)
> **Test Set**: `spike-a-test-set.md` (50 queries × 3 runs = 150 total)
> **Pass criteria**: see test-set §"Pass criteria"

## Run setup

- Device: __________
- iOS version: __________ (record exact e.g. "26.3.1")
- Apple Intelligence: enabled / disabled
- Brain Path Override: `appleFM`
- Build SHA: __________
- Date: __________

## Run table

(Fill `path` + `primaryAction` + `slots ok?` + `latency_ms` per run.)

| # | Query (short) | Run 1 path/action | Run 2 path/action | Run 3 path/action | Run1 lat | Run2 lat | Run3 lat | Slots OK | Notes |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Set timer 10m |  |  |  |  |  |  |  |  |
| 2 | Set timer fifteen |  |  |  |  |  |  |  |  |
| 3 | Wake me 7am |  |  |  |  |  |  |  |  |
| 4 | Alarm 6:45 tomorrow |  |  |  |  |  |  |  |  |
| 5 | Remind call Marco |  |  |  |  |  |  |  |  |
| 6 | Remember buy milk |  |  |  |  |  |  |  |  |
| 7 | WhatsApp Sara |  |  |  |  |  |  |  |  |
| 8 | Text Marco meeting |  |  |  |  |  |  |  |  |
| 9 | Call Mum |  |  |  |  |  |  |  |  |
| 10 | Phone Dr Rossi |  |  |  |  |  |  |  |  |
| 11 | Facetime Federico |  |  |  |  |  |  |  |  |
| 12 | Navigate Bologna |  |  |  |  |  |  |  |  |
| 13 | Pharmacy nearest |  |  |  |  |  |  |  |  |
| 14 | Spotify Daft Punk |  |  |  |  |  |  |  |  |
| 15 | Open Spotify |  |  |  |  |  |  |  |  |
| 16 | Weather Milan tom |  |  |  |  |  |  |  |  |
| 17 | Calendar today |  |  |  |  |  |  |  |  |
| 18 | Free slot Thu PM |  |  |  |  |  |  |  |  |
| 19 | Read latest email |  |  |  |  |  |  |  |  |
| 20 | Living room ON |  |  |  |  |  |  |  |  |
| 21 | Kitchen lights OFF |  |  |  |  |  |  |  |  |
| 22 | Bayes 3 sentences |  |  |  |  |  |  |  |  |
| 23 | Summarize lorem |  |  |  |  |  |  |  |  |
| 24 | Rephrase late |  |  |  |  |  |  |  |  |
| 25 | Capital France |  |  |  |  |  |  |  |  |
| 26 | Translate good |  |  |  |  |  |  |  |  |
| 27 | Llama vs Qwen |  |  |  |  |  |  |  |  |
| 28 | Tell joke |  |  |  |  |  |  |  |  |
| 29 | Shorten email |  |  |  |  |  |  |  |  |
| 30 | Define photosynth |  |  |  |  |  |  |  |  |
| 31 | ROI acronym |  |  |  |  |  |  |  |  |
| 32 | Wikipedia Tesla |  |  |  |  |  |  |  |  |
| 33 | Cheapest flight |  |  |  |  |  |  |  |  |
| 34 | WWDC news |  |  |  |  |  |  |  |  |
| 35 | Tesla stock |  |  |  |  |  |  |  |  |
| 36 | Open URL Wiki |  |  |  |  |  |  |  |  |
| 37 | Python sort script |  |  |  |  |  |  |  |  |
| 38 | Fix regex |  |  |  |  |  |  |  |  |
| 39 | Analyze screenshot |  |  |  |  |  |  |  |  |
| 40 | Order pizza |  |  |  |  |  |  |  |  |
| 41 | Book Grill 8pm |  |  |  |  |  |  |  |  |
| 42 | Maybe set later |  |  |  |  |  |  |  |  |
| 43 | Do that thing |  |  |  |  |  |  |  |  |
| 44 | Sad story |  |  |  |  |  |  |  |  |
| 45 | Ehh |  |  |  |  |  |  |  |  |
| 46 | Buy bitcoin |  |  |  |  |  |  |  |  |
| 47 | Hack wifi |  |  |  |  |  |  |  |  |
| 48 | Send eth |  |  |  |  |  |  |  |  |
| 49 | Crack password |  |  |  |  |  |  |  |  |
| 50 | DDoS URL |  |  |  |  |  |  |  |  |

## Summary metrics

Fill in after running all 150 trials.

- **Tool selection accuracy**: __/50 (__%)
- **Slot extraction accuracy** (native_tool subset, 20 queries): __/20 (__%)
- **False reject rate** (non-reject queries classified as reject): __% (__/40)
- **Latency P50 (ms)**: __
- **Latency P95 (ms)**: __

## Decision

PASS / FAIL: __________

Rationale (3-5 sentences):

> ___________________________________

## Q11 decision

After running this Spike A, decide:

- [ ] Pin iOS 26.3 (skip 26.4 as risky)
- [ ] Accept 26.4 with no feature flag (if regression is mild)
- [ ] Conditional feature flag `apple_fm_router_enabled` based on iOS version

Pick one and add justification to `docs/adr/0011-apple-fm-ios-26-4-regression-mitigation.md`.
