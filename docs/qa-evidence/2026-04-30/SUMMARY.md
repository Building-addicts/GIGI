# QA Release Gate — SUMMARY (2026-04-30)

**Status:** ⏳ Pending PM execution at 18:00 code freeze
**Issue:** #70 (Sub #17 · 7/7)
**Decision deadline:** 2026-04-30 18:00 CET

## Sub-issue completion checklist

| Sub | Issue | Owner | Status | Evidence |
|---|---|---|---|---|
| 1/7 | #64 | Leo+Fede | ☐ | _link_ |
| 2/7 | #65 | Leo | ☐ | _link_ |
| 3/7 | #66 | Leo | ☐ | _link_ |
| 4/7 | #67 | Leo | ☐ | _link_ |
| 5/7 | #68 | PM    | ☐ | docs/qa-evidence/2026-04-30/T1.* T6.* |
| 6/7 | #69 | Leo+Fede+PM | ☐ | docs/qa-evidence/2026-04-30/H1-3 + edge |

## Scenario outcomes

| Scenario | Pass/Fail | Notes | Evidence |
|---|---|---|---|
| T1.1 cold start onboarding | _ | _ | T1.1-onboarding-cold.md |
| T1.2 Groq key | _ | _ | T1.2-T1.3-api-keys.md |
| T1.3 Gemini key | _ | _ | T1.2-T1.3-api-keys.md |
| T6.1 QR pairing | _ | _ | T6.1-qr-pairing.md |
| T6.2 diag scenario B | _ | _ | T6.2-diag-convergence.md |
| H1 harness offline + fallback | _ | _ | H1-harness-offline-fallback.md |
| H2 harness offline no fallback | _ | _ | H2-harness-offline-no-fallback.md |
| H3 harness unpaired | _ | _ | H3-harness-unpaired.md |
| Edge empty speech | _ | _ | edge-empty-speech.md |
| W2 quiet wake | _ | _ | _ |
| W3 noise wake | _ | _ | _ |
| W4 wake false-positive soak | _ | _ | _ |
| D1 Dynamic Island | _ | _ | _ |
| F1 follow-up | _ | _ | _ |
| F2 follow-up | _ | _ | _ |
| T2.2 Quick Talk | _ | _ | _ |
| T4.1 native action | _ | _ | _ |
| T4.2 native action | _ | _ | _ |

## Open bugs as of freeze time

_to be filled — list sub-issue numbers + label:bug + P0/P1/P2_

## Final smoke test (18:00 CET)

PM voice: "hey gigi che ore sono" on demo iPhone 15 Pro
- [ ] Wake detected within 1s
- [ ] Time spoken back within 5s of wake
- [ ] Pill cycle thinking → speaking → done observed
- [ ] Recording attached: _link_

## Decision

**GO / NO-GO:** _to be filled by PM_
**Rationale (max 5 lines):**

_to be filled_

**If NO-GO — Remediation plan:**
- Owner: _
- ETA: _
- Re-check time: _

## Sign-off

@ArmandoBattaglino · 2026-04-30 _HH:MM_ CET
