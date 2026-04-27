# GIGI MVP Scope (1 maggio 2026)

> **Source of truth del lancio.** Documento generato dalla deep interview del 2026-04-26 (vedi `.omx/interviews/` + `.omx/specs/`).
> Importato in main da `ck_gigi.md` del branch `origin/ck-point-leo-26.04` il 2026-04-27.
> **Non modificare durante il lancio** — se cambia lo scope, apri ADR in `docs/adr/` che lo _supersedes_.

## Deadline

**Before May 1, 2026**

## MVP Goal

Gigi v1 must be a **convincing demo** of an agentic, voice-based personal AI assistant.

The demo should make this thesis believable:

> Gigi is Siri, but agentic and personal: it remembers the user's preferences, talks actively with the user, enriches basic requests with context, and helps the user do things on the phone after asking permission.

This is a **vision-proving MVP**, not a production-ready assistant.

---

# Core Product Thesis

Gigi should feel like a better Siri, but not merely because it controls more phone settings.

Gigi is better because it can:

- Remember the user's preferences.
- Hold an active voice conversation.
- Understand what the user is trying to do.
- Enrich a simple request with personal context.
- Suggest better actions than the user explicitly asked for.
- Ask permission before executing meaningful actions.
- Help the user move through the day, not just answer isolated commands.

The viewer should leave thinking:

> "This is not just a chatbot or a calendar bot. This is a personal voice agent that can understand me, talk with me, and help me act."

---

# ✅ IN SCOPE — Must Do Before May 1

## 1. Voice Activation

Gigi should be activated by voice.

Minimum demo requirement:

- The user can call or activate Gigi naturally.
- Gigi responds by voice.
- Gigi feels available as an assistant the user can talk to during the day.

## 2. Talking Session

The killer feature for the May 1 demo is an explicit **Talking Session**.

The user should be able to say something like:

> "Gigi, let's open a talking session."

During this session, Gigi should:

- Listen to the user's speech after explicit activation.
- Hold a natural conversation with the user.
- Let the user talk through things to do during the day.
- Extract tasks, needs, or intentions from the conversation.
- Help the user clarify what should happen next.
- Suggest useful actions based on the conversation and known preferences.

For this MVP, Talking Session listens **only to the user's speech after explicit activation**.

It does **not** need ambient/environment listening.

## 3. Preference Memory

Gigi must show memory of user preferences.

This can be a small curated demo memory, but it should be visible in the experience.

Examples:

- Preferred communication style.
- Favorite places or services.
- Work habits.
- Calendar preferences.
- Important people.
- Usual routines.
- Things the user likes or dislikes.

The important demo point is:

> Gigi does not treat every request as generic. It adapts the request to the user's preferences.

## 4. Better-Siri Basic Actions

Gigi should demonstrate basic Siri-like actions, but improved with context and permission.

Example action:

> "Write to Fede on WhatsApp."

Gigi should not simply execute the raw command. It should enrich it.

For example:

1. Understand the user's request.
2. Use memory/preferences/context to improve the message.
3. Draft a better version.
4. Ask the user for permission.
5. Only then send or simulate sending.

The MVP should include at least one basic phone-assistant action such as:

- Drafting or preparing a WhatsApp/message.
- Helping with a calendar-related action.
- Creating or suggesting a reminder.
- Preparing a follow-up task.

## 5. Calendar / Day Planning

Gigi should help the user discuss and organize the day.

It should be able to:

- Talk with the user about what needs to be done today.
- Extract a list of tasks from the conversation.
- Understand calendar-like context.
- Suggest a better day plan.
- Help the user decide what to do next.

This does not need to be a full calendar product. It is the clearest life-management slice for v1.

## 6. Active Help During Conversation

Gigi should not only talk. It should actively help.

During a Talking Session, Gigi should be able to:

- Notice useful next steps.
- Suggest actions.
- Draft messages.
- Propose schedule changes.
- Clarify priorities.
- Help the user turn vague thoughts into concrete tasks.

The user should feel that Gigi is participating in the day, not waiting passively for isolated commands.

## 7. Permission Before Execution

Gigi should ask for confirmation before taking meaningful action.

In scope:

- Drafting.
- Suggesting.
- Preparing.
- Asking permission.
- Simulating execution for the demo.

Gigi can say:

> "I drafted this message using your usual tone. Do you want me to send it?"

This permission step is part of the product identity, not a weakness.

## 8. Demo-Grade Reliability

The demo should be stable enough to present convincingly.

It does not need to survive every real-world edge case.

---

# ❌ OUT OF SCOPE — Explicitly Excluded From v1

## 1. Production Reliability

Gigi v1 is not production-ready.

Out of scope:

- Public launch reliability.
- Private alpha reliability.
- Full error handling.
- Full retry logic.
- Robust edge-case coverage.
- Always-on dependable daily use.

## 2. Full Whole-Life Autonomy

The long-term vision is for Gigi to help manage the user's life end to end.

That is not required before May 1.

For v1, Gigi only needs to demonstrate the seed of this vision through:

- Preference memory.
- Talking Session.
- Day/task discussion.
- Better-Siri actions with confirmation.

## 3. Ambient Environment Listening

For this MVP, Gigi should not listen to the environment.

Out of scope:

- Passive always-on listening.
- Ambient room understanding.
- Background audio interpretation.
- Detecting context from other people or environmental sounds.

Talking Session listens only to the user's speech after explicit activation.

## 4. Full Phone Control Surface

Gigi should be a better Siri, but the MVP does not need every Siri capability.

Out of scope:

- Complete iOS control.
- Full system settings control.
- Full app management.
- Full replacement of every Siri command.

The demo should show only the phone actions needed to prove the thesis.

## 5. Unconfirmed External Actions

Gigi should not take meaningful external actions without permission.

Out of scope unless explicitly confirmed by the user:

- Sending real messages.
- Modifying real calendar events.
- Booking rides.
- Ordering food.
- Buying anything.
- Sending payments.
- Committing to actions that affect other people.

## 6. Multiple Complete Third-Party Workflows

Gigi does not need to fully support many third-party workflows before May 1.

Out of scope as complete workflows:

- Uber.
- Uber Eats.
- Flights.
- Playlists.
- Full WhatsApp automation.
- Full calendar automation.
- Full multi-app orchestration.

The MVP should show one or two convincing action examples, not a broad integration platform.

## 7. Complete Long-Term Memory Architecture

Gigi needs visible preference memory, not a full lifelong memory system.

A curated memory layer is enough for the demo.

Out of scope:

- Complete memory management.
- Full memory editing UI.
- Deep historical recall.
- Production privacy architecture for memory.

## 8. Security, Privacy, and Compliance Hardening

Out of scope for v1:

- Production-grade privacy controls.
- Full consent system.
- Payment compliance.
- Data retention policy.
- Enterprise-grade security.

These matter later, but they are not May 1 MVP requirements.

---

# MVP Demo Acceptance Criteria

The May 1 demo is successful if:

1. The user can activate Gigi by voice.
2. The user can open a Talking Session.
3. Gigi listens only after explicit activation.
4. The user can converse naturally with Gigi about the day.
5. Gigi extracts tasks or things to do from the conversation.
6. Gigi shows memory of user preferences.
7. Gigi uses those preferences to enrich a request.
8. Gigi suggests a better day plan or useful next action.
9. Gigi can prepare a basic phone-assistant action, such as a message or calendar-related suggestion.
10. Gigi asks permission before executing or simulating meaningful action.
11. The demo feels like "Siri, but personal, conversational, and agentic."
12. The viewer understands the larger vision: Gigi could become the assistant that actively helps manage the user's life.

---

# Recommended Demo Narrative

## Scene 1 — Activate Gigi

The user activates Gigi by voice.

Example:

> "Gigi, let's open a talking session."

## Scene 2 — Talk Through the Day

The user speaks naturally:

> "I have a lot to do today. I need to reply to Fede, prepare for my meeting, and maybe move one thing because I feel overloaded."

Gigi listens and responds conversationally.

## Scene 3 — Extract Tasks

Gigi extracts a clear task list:

- Reply to Fede.
- Prepare for the meeting.
- Review today's schedule.
- Identify what can move.

## Scene 4 — Use Preferences

Gigi applies remembered preferences:

- The user's usual message tone.
- Preferred work blocks.
- Important contacts.
- Calendar habits.

## Scene 5 — Suggest and Help

Gigi suggests a better plan:

> "You usually prefer deep work before calls, so I suggest moving the admin task later and preparing for the meeting first."

## Scene 6 — Better-Siri Action

The user asks:

> "Write to Fede."

Gigi drafts a message enriched by context and preference:

> "I drafted a warmer version based on your usual tone. Do you want me to send it?"

## Scene 7 — Permission

Gigi waits for confirmation before action.

This proves the permission boundary.

---

# Final MVP Boundary

Gigi v1 should be judged as a **convincing agentic voice assistant demo**.

It should not be judged as:

- A production assistant.
- A complete Siri replacement.
- A complete calendar app.
- A full third-party automation platform.
- An always-listening ambient AI.

The correct v1 question is:

> "After watching this demo, do I believe Gigi is a better, more personal Siri that can talk with me, remember me, and actively help me do things?"

