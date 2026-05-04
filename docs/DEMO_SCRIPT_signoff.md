# Stability pass sign-off — Sub #75 (final)

> Append at the end of `docs/DEMO_SCRIPT.md` once #71-#74 have merged.

## Stability pass sign-off

Cross-functional gate: every claim in the storyboard must be feasible against the post-QA-gate (#17) build. Caveats land here as transparent footnotes the presenter can mitigate live.

### Reviews

- [ ] **@Leonardo-Corte** (iOS) — read sub 1–4, verify each:
  - Scene 1 wake → pill descent matches fix #9 + #11 behavior.
  - Scene 2 transcripts visible in chat memory + `TalkingSessionTaskListView` overlay (#54 + #55 wired).
  - Scene 4 preferences cited via MVPPreferences round-trip.
  - Scene 6 `DraftMessagePreviewSheet` shows enriched body (#46–#49).
  - Setup state seeding actually reachable via Settings.
  - Plan B steps executable without prep.

- [ ] **@fc200490-sketch** (harness) — read sub 1–4, verify each:
  - Scene 5 day plan tool-callable from harness with calendar + preferences input.
  - Scene 6 enrichment latency under 5 s end-to-end.
  - Plan B Scene 1–3 (offline retries) match H1 evidence from sub #17.
  - No new env vars required beyond what's already in `03_HARNESS/.env`.

### Caveats (none = clean sign-off)

_to be filled by Leo + Fede after their reviews._

> Format example:
> - Leo: "Scene 4 preferences citation occasionally needs 2 turns when the LLM cache is cold — mitigated by setup state warm-up (last item in checklist sub #72)."
> - Fede: "Scene 6 enrichment adds ~3–5 s latency. Acceptable within the 45 s scene budget."

### Final PM sign-off

- [ ] **@ArmandoBattaglino** — merge approval after both reviews above + zero release-blocker caveats.

If any caveat is release-blocker → open a P0 bug, defer the merge of this sub, and re-trigger the sign-off after the bug closes.

### "Cold reading" smoke test

A non-team person (parent, partner, anyone) reads the consolidated `DEMO_SCRIPT.md` for 5 minutes and explains GIGI back. If their explanation matches the 7-scene intent without follow-up questions, the doc is clean.
