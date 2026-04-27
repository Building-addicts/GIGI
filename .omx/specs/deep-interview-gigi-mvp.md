# Deep Interview Spec — Gigi MVP

## Metadata

- **Interview ID:** 019dcafb-5ced-7a80-958e-098d3cb29d76
- **Profile:** standard
- **Context type:** greenfield
- **Deadline:** before May 1, 2026
- **Context snapshot:** `.omx/context/gigi-mvp-deep-interview-20260426T181134Z.md`
- **Transcript summary:** `.omx/interviews/gigi-mvp-deep-interview-20260426T231612Z.md`
- **Final ambiguity:** ~18%
- **Residual risk:** final success criteria were inferred because the last structured question renderer stalled.

## Intent

Gigi needs a **convincing demo** by May 1, not a production launch. The demo should make the long-term product vision believable: a voice-based agentic personal assistant that is **Siri, but better** because it remembers the user, talks actively, enriches basic requests with preferences/context, and asks permission before meaningful actions.

## Desired Outcome

The May 1 MVP should show one impressive, coherent experience around **Talking Session + memory-enriched assistant actions**. Day planning remains the best representative slice, but the sharper demo thesis is that Gigi can listen after explicit activation, converse with the user, extract what needs doing, remember preferences, and help with selected phone actions after confirmation.

## In Scope

1. **Voice-first interaction**
   - User can ask Gigi to manage or plan their day through a natural voice request.
   - Gigi responds conversationally and explains what it is doing.

2. **Talking Session**
   - User can explicitly activate a mode such as "Gigi, let's open a talking session."
   - Gigi listens only to the user's speech after activation.
   - Gigi converses with the user, extracts tasks, discusses the day, and suggests helpful next actions.

3. **Hero workflow: day planning / schedule orchestration**
   - Gigi understands the user’s current day context.
   - Gigi reasons over calendar-like commitments, priorities, location/time constraints, preferences, and pending tasks.
   - Gigi produces a coherent proposed plan for the day.
   - Gigi can suggest schedule adjustments, reminders, drafted messages, or next actions.

4. **Better-Siri action example**
   - Gigi should demonstrate at least one basic assistant action, such as drafting a WhatsApp/message or preparing a calendar-related action.
   - The action should be improved by preferences/context and require permission before execution.

5. **Minimal agentic behavior**
   - Gigi should appear to decompose the user’s request into steps.
   - Gigi should explain tradeoffs and why it chose a plan.
   - Gigi should maintain enough context during the flow to feel personal and agentic.

6. **Minimal memory/personalization signal**
   - Gigi should use a small set of stored or demo-provided user preferences.
   - Examples: preferred working hours, favorite meeting locations, travel buffer, food/caffeine preference, important contacts, or priority categories.

7. **Minimal proactivity signal**
   - Gigi may suggest useful actions without being asked for every detail.
   - Examples: “You should leave 20 minutes earlier,” “I can draft a message to Fede,” or “This task conflicts with your meeting.”

8. **Suggest-only autonomy**
   - Gigi may recommend, stage, or draft actions.
   - Gigi should not actually send messages, book services, pay, order, or commit externally without explicit confirmation.

9. **Demo-grade integrations or simulations**
   - Real integrations are optional if mocks/simulations make the demo convincing.
   - The experience should prioritize narrative clarity and visible end-to-end flow over backend completeness.

## Out of Scope / Non-goals

1. **Production reliability**
   - No private-alpha or public-launch reliability bar.
   - No requirement to handle all edge cases, failures, retries, or real-world scale.

2. **Whole-life autonomy**
   - Gigi does not need to manage the user’s entire life continuously in v1.
   - The demo only needs one representative slice: day planning.

3. **Complete Siri replacement**
   - Gigi should feel like a better Siri, but v1 does not need every Siri capability.
   - Full phone/system control, all app actions, and every native command are out of scope.

4. **Ambient/environment listening**
   - Talking Session listens only to the user’s speech after explicit activation.
   - Passive listening, room/environment understanding, and background audio interpretation are out of scope.

5. **Real irreversible external actions**
   - No real payments, orders, bookings, ride requests, flight purchases, or unsupervised message sends.
   - These may be mocked, staged, or shown as “ready for confirmation.”

6. **Multiple third-party workflows**
   - No need to support Uber, Uber Eats, flights, playlists, and messaging all as complete workflows.
   - If referenced, they should be examples of future expansion, not v1 commitments.

7. **Complete long-term memory system**
   - The demo can use a small curated preference/context set.
   - It does not need a robust lifelong memory architecture.

8. **Security/compliance hardening**
   - No production-grade privacy, security, consent, data retention, or payment compliance implementation required for May 1.

## Decision Boundaries

Gigi may decide without confirmation:

- How to prioritize the day in the proposed plan.
- Which conflicts or constraints to highlight.
- Which reminders, drafts, or schedule adjustments to suggest.
- Which explanation to give for its recommendations.

Gigi must ask for confirmation before:

- Sending messages.
- Creating or modifying real calendar events.
- Booking or ordering anything.
- Paying or using payment details.
- Requesting rides, flights, food, or any real third-party service.
- Taking actions that would affect another person or external system.

## Constraints

- Deadline is before **May 1, 2026**.
- MVP is a **convincing demo**, not a launch-ready product.
- The core proof is **agentic day planning**, not broad device support.
- Simulated data and mocked integrations are acceptable where they preserve demo credibility.
- The product should still feel voice-native, personal, and agentic.

## Testable Acceptance Criteria

The demo is successful if:

1. A viewer can understand within minutes that Gigi is a voice-based personal AI assistant for life-management delegation.
2. A user can explicitly activate Gigi and open a Talking Session.
3. Gigi listens only after explicit activation.
4. Gigi converses naturally about the user’s day.
5. Gigi extracts tasks or things to do from the conversation.
6. Gigi uses visible personal preferences to enrich its response.
7. Gigi proposes a coherent day plan or useful next action.
8. Gigi demonstrates at least one better-Siri action, such as preparing a message or calendar-related action.
9. Gigi clearly asks permission before meaningful execution.
10. The demo flow does not break during the planned script.
11. The viewer leaves with the impression: “This is Siri, but personal, conversational, and agentic.”

## Assumptions Exposed + Resolutions

- **Assumption:** The MVP must show whole-life management.
  - **Resolution:** Whole-life management is the vision; the MVP shows one representative slice.

- **Assumption:** More categories make the demo stronger.
  - **Resolution:** One strong day-planning workflow is more convincing than several shallow workflows.

- **Assumption:** Agentic means autonomous execution.
  - **Resolution:** For v1, agentic means context-aware reasoning and suggested actions; irreversible execution waits for confirmation.

## Recommended Next Step

Use `ck_gigi.md` as the MVP scope source of truth. If execution planning is needed, hand it to `$ralplan` for architecture/test-shape planning or `$autopilot` for implementation planning.
