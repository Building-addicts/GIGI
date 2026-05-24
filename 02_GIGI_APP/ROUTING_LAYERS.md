# GIGI routing layers — contract & audit (2026-05-24)

Audit closing the "5–6 overlapping intent deciders" concern. Conclusion: after
this session's cleanup (ML classifiers removed, Gate 0.5 removed, label
unifications), the routers are a **precision-ordered cascade**, not a
Whac-a-Mole pile. Actual redundancy is small; the layers are mostly
complementary. This file documents each layer's contract so future work does
not re-introduce overlap.

## The ordered decision cascade

`GigiAgentEngine.process` → tier-0 → memory probe → NLU fast-path → `route()`
(FM pipeline). Each stage is more general (and less certain) than the last;
deterministic stages run first, the LLM in the middle, deterministic safety
nets last to catch LLM misroutes.

| # | Layer | Mechanism | Owns (contract) |
|---|-------|-----------|-----------------|
| 1 | State/consent tiers (Proposal, WorldActionConsent, PendingClarification, CloudFollowUp) | conversation state | Multi-turn continuations: confirmations, pending clarifications, cloud follow-ups. Must run first so a short "yes/go" reaches the right open task. |
| 2 | DiscoveryQueryTier | keywords | "what can you do" capability overview. |
| 3 | RegisteredAliasTier | exact match | User-defined aliases. |
| 4 | MathExpressionTier | regex | Pure arithmetic ("42 times 11"). Categorically not a recall. |
| 5 | Build/RunShortcutRegexTier | regex | Shortcut author/run. Build requires a description OR routes to the composer; "build … shortcut" (build verbs) never falls to run. |
| 6 | SemanticRouterTier | NLEmbedding cosine ≥0.80 | **Near-canonical paraphrases** of catalog tools that the rules miss. In practice fires only for phrasings very close to a catalog trigger (battery, "play despacito", timer, flashlight). Abstains otherwise → falls through. |
| 7 | (memory recall probe) | NLU + memory | Authoritative recall of a stored fact ("what's the wifi password"). |
| 8 | NLU fast-path (`GigiNLUEngine` rules, conf ≥0.95 ∧ `fastPathIntents`) | substring/prefix rules | **Deterministic prefixes for unambiguous commands**: ask_time/ask_date, media controls, facetime, remember, and direction-explicit call/navigate/torch. Carries real load that semantic does NOT (ask_time/date, media_next, remember are not in the semantic catalog; call/navigate are catalog entries semantic abstains on). |
| 9 | FMDecisionTier (Apple FM) | on-device LLM | Everything the deterministic layers did not catch: open-ended phrasings, reasoning, delegate_local/cloud routing, slot extraction. |
| 10 | Post-FM override tiers (CloudDowngrade, CompoundCommand, FactAssertion, ReminderUpgrade, MessageWithoutBody, UnresolvedContact, ClarificationDowngrade) | regex on the FM result | **Safety nets for known FM misroutes.** The small on-device FM ignores @Guide few-shots (verified 2026-05-24), so these deterministic gates are how reminder/fact/message-body corrections actually happen. Keep them. |
| 11 | DispatchTier | — | Terminal dispatch. |

## Why the NLU fast-path is NOT redundant with SemanticRouter

Measured on the 49-case golden (tier each case actually resolves at):
semantic catches only near-canonical catalog hits; NLU catches the deterministic
prefix commands semantic does not cover or abstains on. They are complementary.
**Do not remove the NLU fast-path** expecting semantic+FM to cover it — they do
not.

`fastPathIntents` (NLU short-circuits these before FM): ask_time, ask_date,
torch_on, torch_off, make_call, navigate, set_timer, set_alarm, toggle_wifi,
toggle_bluetooth, media_play_pause/next/previous, play_music, open_app,
read_calendar, read_week_calendar, find_free_slot, remember, respond,
facetime, facetime_audio.

## Open reconciliation items (documented, NOT yet fixed — need care)

1. **Flashlight has two representations.** NLU emits direction-explicit
   `torch_on`/`torch_off`; the SemanticRouter catalog + Apple FM use
   `toggle_flashlight`. `GigiActionBridge` handles all three. The FM tool
   passes a `state` arg ("on"/"off"/empty) so the FM path is direction-aware;
   the **semantic path passes no state → blind toggle** (latent bug: "turn off
   the flashlight" when already off turns it on). Reconcile to ONE canonical
   (decide torch_on/off vs toggle_flashlight, preserve direction on every
   path, update `fastPathIntents` + the golden expectation accordingly). Not a
   trivial relabel — direction semantics differ.

2. **Low-value semantic backstops.** The catalog lists make_call, set_timer,
   set_alarm, open_app, navigate, read_calendar, find_free_slot, play_music —
   tools the NLU rules + FM already handle, and on which semantic mostly
   abstains (threshold 0.80). Harmless (threshold-gated) but redundant. Leave
   unless a measured benefit is found; revisit only with golden evidence.

3. **Known FM routing gap (documented):** "I'd love to hear some jazz" →
   delegate_local instead of play_music. Not safely fixable deterministically
   (a hear-some-X trigger over-matches "hear some news/ideas") and FM few-shots
   don't bind on the small model.

## Cleanups already shipped this session (the real redundancy)

- Removed the opaque on-device ML classifiers (MobileBERT never bundled; MaxEnt
  added nothing the rules/semantic/FM did not — measured by A/B).
- Removed Gate 0.5 (`looksLikeBuildShortcut`) — a pre-tier-0 relic; tier-0 now
  catches build phrasings before the NLU torch over-match.
- Unified label `navigation` → `navigate`; word-boundary fixes for call
  triggers (NLU + FallbackRouter); message-body deterministic builder.
