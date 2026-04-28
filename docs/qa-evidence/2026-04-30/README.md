# QA Evidence — 2026-04-30 Pre-Freeze QA Gate (#17)

Cartella evidence packet per la sessione QA gate del **mercoledì 30 aprile 2026 ore 14:45-18:00**, prima del code freeze.

## Sub-issue tracking

| Sub | Issue | Title | Status | Evidence file |
|---|---|---|---|---|
| 1/7 | #64 | QA setup — device matrix + harness live + tunnel verify | sign-off pre-gate | `00-setup.md` |
| 2/7 | #65 | Voice & Wake — W2 quiet + W3 noise + W4 false-positive | pending | `01-voice-wake.md` |
| 3/7 | #66 | Dynamic Island D1 + Follow-up F1/F2 | pending | `02-dynamic-island.md` |
| 4/7 | #67 | Quick Talk + Native actions T2.2 + T4.1 + T4.2 | pending | `03-quick-talk.md` |
| 5/7 | #68 | Onboarding + QR pairing T1.1-T1.3 + T6.1-T6.2 | pending | `04-onboarding.md` |
| 6/7 | #69 | Harness offline H1-H3 + Empty speech edge case | pending | `05-resilience.md` |
| 7/7 | #70 | PM sign-off + evidence consolidation | pending | `06-signoff.md` |

## Tester

| Role | Name | GitHub |
|---|---|---|
| PM (sole tester) | Armando Battaglino | @ArmandoBattaglino |

## Build under test

| Field | Value |
|---|---|
| Build SHA | `e3b1b10` (origin/main al momento del setup) |
| Built on | MacInCloud (`user297422@FF125.macincloud.com`) |
| IPA size | 3.8 MB (Debug-iphoneos) |
| IPA path | `C:/Users/arman/Desktop/GIGI/bug/GIGI.ipa` |
| Build date | 2026-04-28 |

## Device matrix (deviation from runbook)

`docs/VOICE_ASSISTANT_QA.md` §Device Matrix richiede classes D1 + D2 (almeno 2 device Dynamic Island) per il QA gate. **Realtà operativa**: il PM ha **un solo device fisico** (iPhone 15 Pro = D1) e nessun secondo device disponibile.

**Decisione documentata**: si procede con D1 only. AC2 di #64 (iPhone 14 Pro backup) è marcato **N/A** in `00-setup.md`. Ogni scenario successivo che richiede strict D1+D2 sarà marked degraded e segnalato come gap in `06-signoff.md`.
