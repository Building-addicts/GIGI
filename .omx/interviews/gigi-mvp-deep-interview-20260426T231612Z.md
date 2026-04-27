# Gigi MVP Deep Interview Transcript Summary

- **Interview ID:** 019dcafb-5ced-7a80-958e-098d3cb29d76
- **Profile:** standard
- **Context type:** greenfield product/MVP scoping
- **Deadline clarified as:** before May 1, 2026
- **Primary output requested:** `ck_gigi.md`
- **Final ambiguity:** ~18% weighted, with residual risk on success criteria because the final structured prompt stalled.

## Rounds

| Round | Focus | Question | Answer / Interpretation |
| --- | --- | --- | --- |
| 1 | Intent | What is the single most important real-world outcome Gigi must enable by May 1st? | A convincing demo. |
| 2 | Outcome | What is the one “wow” moment? | Handle a complex delegated task end to end, with memory/proactivity/conversation only as minimal supporting evolution. |
| 3 | Scope | What specific complex task should Gigi complete? | Founder framed two categories: Device Support Assistant and Agentic Actions. Agentic actions use context and third-party services to complete goals. |
| 4 | Tradeoff | Primary proof: device support breadth or one agentic workflow? | Agentic Actions with one impressive end-to-end third-party workflow. |
| 5 | Pressure pass | Which single third-party workflow? | Founder stated the larger vision: Gigi should manage the whole life of the user end to end. Interpretation: this is the long-term product vision, not the May 1 MVP surface. |
| 6 | Simplifier | Which life-management slice should represent the whole-life vision? | Day planning / schedule orchestration. |
| 7 | Non-goal | Which capability is out of scope for May 1? | Production reliability. Interpretation: demo robustness only, not private-alpha/public-launch reliability. |
| 8 | Decision boundary | What may Gigi decide without confirmation? | Suggest only. Interpretation: Gigi can propose plans/actions but not create/send/book/pay/commit externally without confirmation. |
| 9 | Success criteria | Structured prompt stalled. | Success criteria inferred from prior answers: convincing demo, visible end-to-end day-planning flow, user delight, and no production reliability requirement. |

## Pressure-Pass Finding

The key pressure pass revisited the “one impressive workflow” answer. The founder’s underlying ambition is whole-life automation, but the MVP cannot credibly implement whole-life autonomy before May 1. The representative slice chosen is **day planning / schedule orchestration**, which can demonstrate context, reasoning, prioritization, and proposed actions without pretending to be production-complete.

## Readiness Gates

- **Non-goals:** explicit enough for MVP artifact; expanded in `ck_gigi.md`.
- **Decision boundaries:** explicit: suggest-only autonomy; no irreversible external commitments without user confirmation.
- **Residual risk:** success criteria were inferred after the final structured question renderer stalled.

## Later Clarifications

After the initial crystallization, the founder reopened the interview and clarified the stronger differentiation:

- Gigi should be **Siri, but better**.
- "Better Siri" does not mean every possible phone-control action.
- It means basic assistant actions improved by memory, preferences, contextual enrichment, active conversation, and permission before execution.
- The killer feature is an explicit **Talking Session**.
- In Talking Session, the user activates Gigi by voice, talks with Gigi about the day, and Gigi extracts tasks / suggests actions / helps the user do selected things.
- For May 1, Talking Session listens only to the user's speech after explicit activation. Ambient/environment listening is out of scope.

The final `ck_gigi.md` supersedes the earlier narrower day-planning-only draft.
