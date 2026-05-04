# Plan B per scena — Sub #73 (extends DEMO_SCRIPT.md)

> Append after the setup section from #72. Each Plan B is executable in ≤ 10 s of awkwardness.

## Plan B per scena

### Scene 1 — Activate fallback

Failure mode: wake word doesn't fire on first try.
Plan B: presenter says "Hey GIGI" a second time (max 1 retry). If still no descent → tap manually on the pill area to start the session. Continue the demo verbally.

### Scene 2 — Talk-through fallback

Failure modes: STT mishears; pill stuck in Listening; harness offline.
Plan B: rephrase slowly with simpler nouns. If transcript is wrong, presenter says "let me say that more clearly". If two retries fail → switch to a pre-recorded clip on a secondary tablet (kept ready under the desk).

### Scene 3 — Extract tasks fallback

Failure mode: task list overlay stays empty.
Plan B: explicit ask — "Summarize what I have to do today". This forces the LLM through a different code path that does not rely on incremental extraction.

### Scene 4 — Use preferences fallback

Failure mode: GIGI does not cite a preference.
Plan B: skip Scene 4. Presenter narrates: "GIGI has my preferences seeded — for time I'll show you the day plan instead" → jump straight into Scene 5.

### Scene 5 — Suggest plan fallback

Failure mode: GIGI returns a generic "I'd suggest doing your tasks" answer.
Plan B: accept the generic. Presenter comments: "Even with a basic answer, you can see GIGI is reasoning over the calendar — the next iteration personalizes it further."

### Scene 6 — Better-Siri WhatsApp fallback

Failure modes: draft sheet does not appear; WhatsApp not opening.
Plan B: switch to a phone call instead — say "Actually, let me just call Marco real quick" → demo the call confirmation surface (T4.1 from the QA plan). Same Permission Boundary point lands.

### Scene 7 — Permission boundary fallback

Failure mode: GIGI executes the action without showing the sheet.
Plan B: rare. Presenter says "you saw GIGI ask me earlier — sometimes it confirms verbally instead of via a sheet, depending on the action type." Move on.

## Regola d'oro

**Max 1 retry per scena. After that, switch to Plan B.** Never retry three times consecutively — the audience reads it as "broken".

## Abort clause

If 3 or more scenes fail (any combination), presenter aborts the live flow with:

> "GIGI is in early stage — let me show you the recorded QA tests we ran yesterday."

Then play the consolidated QA evidence video kept at `docs/qa-evidence/2026-04-30/SUMMARY.mp4` (compiled from sub #17 evidence packs). Wrap with a Q&A.

## Tabletop walkthrough

PM + Leo simulate the demo at a table T-1 day. For each scene, intentionally trigger the most likely failure once, run the Plan B, and check that the transition reads natural. Adjust phrasing for any Plan B that feels forced.
