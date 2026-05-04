# DEMO_SCRIPT.md — GIGI MVP demo (1 May 2026)

> Authoritative reference for the live demo. Consolidates sub #71 (storyboard), #72 (pre-demo state), #73 (plan B), #74 (final duration call), #75 (cross-functional stability pass).

## Storyboard

7 scenes mapped 1:1 to `docs/MVP_SCOPE.md` §306. Total baseline ≈ 3 min 50 s.

### Scene 1 — Activate

- **Durata target:** 30 s
- **Intent:** show that GIGI is alive on the iPhone, no app foregrounded, hands-free trigger works (MVP AC#1, AC#3).
- **Setup richiesto:** iPhone unlocked on Lock Screen — see Pre-demo setup state.
- **Battuta umana:** "Hey GIGI, let's start a talking session."
- **Risposta GIGI attesa:** "Listening — what's on your mind?"
- **Visual cue:** Dynamic Island descends to expanded, banner reads `Listening`, waveform reactive.

### Scene 2 — Talk through the day

- **Durata target:** 45 s
- **Intent:** show natural turn-taking — user thinks aloud, GIGI listens silently and reflects (MVP AC#4).
- **Setup richiesto:** Calendar pre-populated with 3 events.
- **Battuta umana:** "I have a call with Marco at 11, then I need to write the WhatsApp to Fede about the dinner, and grocery shopping before evening."
- **Risposta GIGI attesa:** "Got it — call at 11, WhatsApp to Fede, groceries before evening. Anything else for today?"
- **Visual cue:** pill flips between `Listening` and brief `Thinking` after each user turn.

### Scene 3 — Extract tasks

- **Durata target:** 30 s
- **Intent:** show that GIGI is paying attention — task list grows live in the right-side overlay during the conversation (MVP AC#5).
- **Setup richiesto:** Talking Session active from Scene 2.
- **Battuta umana:** "Show me what you picked up so far."
- **Risposta GIGI attesa:** "I noted three tasks: call Marco at 11, WhatsApp to Fede, groceries."
- **Visual cue:** `TalkingSessionTaskListView` overlay shows 3 cards with title + deadline badges.

### Scene 4 — Use preferences

- **Durata target:** 30 s
- **Intent:** show that GIGI knows the user — pulls hardcoded MVP preferences (warm tone, deep-work morning, VIP contacts) into the answer (MVP AC#6, AC#7).
- **Setup richiesto:** MVP preferences seeded.
- **Battuta umana:** "Should I do the call or the message first?"
- **Risposta GIGI attesa:** "You prefer deep-work in the morning. Marco is on your VIP list — take the call first, then the message can wait."
- **Visual cue:** none specific; hint of `Gigi remembered: deep-work morning` in chat memory affordance.

### Scene 5 — Suggest a plan

- **Durata target:** 30 s
- **Intent:** show GIGI proposing a concrete day plan that cites preferences + tasks + calendar (MVP AC#8).
- **Setup richiesto:** Day Plan Reasoner online (issues #15, #58 wired).
- **Battuta umana:** "Plan my day."
- **Risposta GIGI attesa:** "9 to 11 deep-work block, call Marco at 11, WhatsApp to Fede after lunch, groceries at 6. Want me to add the deep-work to your calendar?"
- **Visual cue:** GIGI dictates the plan; permission sheet appears at the end of the scene to add the deep-work block.

### Scene 6 — Better-Siri action (WhatsApp)

- **Durata target:** 45 s
- **Intent:** show the explicit Permission Boundary — GIGI drafts, the user reviews and confirms (MVP AC#9, AC#11).
- **Setup richiesto:** Fede contact pinned, WhatsApp Web paired or mock send.
- **Battuta umana:** "Write to Fede that I'll be five minutes late for dinner."
- **Risposta GIGI attesa:** "I drafted a message to Fede. Check the preview to send or edit."
- **Visual cue:** `DraftMessagePreviewSheet` slides up — recipient `To: Fede`, body `Ciao Fede! Arrivo 5 minuti in ritardo per la cena 😊`. User taps Send.

### Scene 7 — Permission boundary

- **Durata target:** 20 s
- **Intent:** close the loop on AC#10 — show that GIGI never acts without user confirmation; cancel path is just as smooth.
- **Setup richiesto:** continuation of Scene 6.
- **Battuta umana:** "Actually, no — cancel that, I'll write it later."
- **Risposta GIGI attesa:** "Cancelled."
- **Visual cue:** sheet collapses; chat shows `Draft to Fede cancelled.` bubble.

## Total baseline

| Scene | Durata |
|---|---|
| 1 — Activate | 30 s |
| 2 — Talk through day | 45 s |
| 3 — Extract tasks | 30 s |
| 4 — Use preferences | 30 s |
| 5 — Suggest plan | 30 s |
| 6 — Better-Siri action | 45 s |
| 7 — Permission boundary | 20 s |
| **Total** | **3 min 50 s** |

---

## Pre-demo setup state

### Device specs

- Hardware: iPhone 15 Pro (paid-signed build).
- iOS: 18.x.
- Battery: ≥ 50 % (charge to full T-30 min).
- Focus mode: OFF.
- Audio route: built-in speaker — NO AirPods (BT flaky risk).
- Notifications: silenced (Do Not Disturb scheduled OFF — but mute ringer manually).

### App state

- GIGI installed, paired with harness.
- Presence ON (Sleeping pill visible on Lock Screen).
- No active turn at start.
- Settings → Brain Mode: Auto fallback ON.

### Preferenze utente seedate (Scene 4)

| Key | Value | Stored as |
|---|---|---|
| Tone | warm professional | MVPPreferences.communicationTone |
| Work hours | 09:00–18:00 | workHours |
| Morning focus | true | morningFocus |
| VIP contacts | Marco, Fede, Sara | vipContacts |
| Travel buffer | 20 min | travelBufferMinutes |
| Routine hint | lunch 13:00 | routineHints |

Seed via Settings → Memory → MVP Preferences (manual entry) or via the debug `seedMVPPreferencesIfNeeded()` call exposed in `GigiUserProfile`.

### Calendario mock (Scene 2, 3, 5)

| Time | Title |
|---|---|
| 10:00–10:45 | Admin tasks (the "movable" one) |
| 11:00–12:00 | Meeting con team |
| 14:00–14:30 | Coffee with Sara |

Add manually in iOS Calendar before T-10 min.

### Contatti VIP (Scene 6)

- Fede — phone valid, WhatsApp installed.
- Marco — phone valid (used in Plan B Scene 6 fallback).

### Harness state

- Mac on, harness running.
- Cloudflare tunnel up — verify last `harnessState=Online` in app log.
- Gemini fallback ENABLED (Settings).

### Pre-go-live checklist (T-5 min, exactly 10 items, each ≤ 30 s)

1. Phone on charger, ≥ 50 % battery.
2. Focus OFF, ringer muted.
3. AirPods disconnected.
4. Open GIGI app, confirm `Sleeping` pill on Lock Screen.
5. Confirm last harness state log is `Online`.
6. Open Calendar, confirm 3 events present.
7. Open Contacts, confirm Fede + Marco present.
8. Settings → Memory → confirm 6 MVP preferences set.
9. Lock screen, walk away, walk back, say "Hey GIGI" once → confirm pill descends → cancel.
10. Hand to presenter.

### "Setup in 10 min" — verification test

PM (or stand-in) takes a freshly-reset device, follows this state from scratch, and reaches go-live readiness in ≤ 10 min. If > 10 min, simplify the seeding step.

---

## Plan B per scena

Each Plan B is executable in ≤ 10 s of awkwardness.

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

### Regola d'oro

**Max 1 retry per scena. After that, switch to Plan B.** Never retry three times consecutively — the audience reads it as "broken".

### Abort clause

If 3 or more scenes fail (any combination), presenter aborts the live flow with:

> "GIGI is in early stage — let me show you the recorded QA tests we ran yesterday."

Then play the consolidated QA evidence video kept at `docs/qa-evidence/2026-04-30/SUMMARY.mp4` (compiled from sub #17 evidence packs). Wrap with a Q&A.

### Tabletop walkthrough

PM + Leo simulate the demo at a table T-1 day. For each scene, intentionally trigger the most likely failure once, run the Plan B, and check that the transition reads natural. Adjust phrasing for any Plan B that feels forced.

---

## Demo duration — final decision

| Variante | Durata | Scene | Pro | Contro |
|---|---|---|---|---|
| Corta | 3 min 50 s | 1–7 baseline | Energica · viewer attento · basso rischio failure cumulato | Poco approfondimento Scene 4–5 |
| Estesa | 5–7 min | 1–7 + multi-turn Scene 2 + callback Scene 5 | Mostra ragionamento · "wow" più diluito | Più rischio fail cumulato · attenzione cala |

### Decision

**Corta — 3 min 50 s.**

Rationale:

1. The 1 May audience is investor-leaning, time-boxed, and prefers "punch + Q&A" over deep-dive.
2. QA gate (#17) measured Scene 2 multi-turn at ~70 % reliability on real device — adding more turns multiplies the failure surface.
3. The cumulative failure probability across 7 scenes is acceptable at the corta budget; the estesa adds 2 extra fail points for marginal narrative gain.
4. Plan B for the corta is fully rehearsed; the estesa would need a second rehearsal pass we do not have time for.

### Time budget after decision

Total target: **3 min 50 s** (matches the storyboard, no expansion beats).

### Cuttable scenes (live overflow plan)

If at runtime the presenter is at minute 3:00 and only at Scene 5, drop in this order:

1. Scene 4 (use preferences) — narrative redundancy with Scene 5.
2. Scene 3 (extract tasks) — visible from the overlay anyway during Scene 2.

**Never cut:** Scene 1 (activate), Scene 6 (Better-Siri action), Scene 7 (permission boundary). These three carry the core differentiation message.

### Rehearsal stopwatch

PM runs the corta variant end-to-end with stopwatch T-1 day. Acceptance: ±20 % of target → 3 min 04 s to 4 min 36 s. Outside that → re-tighten cues.

---

## Stability pass sign-off

Cross-functional gate: every claim in the storyboard must be feasible against the post-QA-gate (#17) build. Caveats land here as transparent footnotes the presenter can mitigate live.

### Reviews

- [ ] **@Leonardo-Corte** (iOS) — read storyboard + setup + plan B + duration sections, verify each:
  - Scene 1 wake → pill descent matches fix #9 + #11 behavior.
  - Scene 2 transcripts visible in chat memory + `TalkingSessionTaskListView` overlay (#54 + #55 wired).
  - Scene 4 preferences cited via MVPPreferences round-trip.
  - Scene 6 `DraftMessagePreviewSheet` shows enriched body (#46–#49).
  - Setup state seeding actually reachable via Settings.
  - Plan B steps executable without prep.

- [ ] **@fc200490-sketch** (harness) — read storyboard + setup + plan B + duration sections, verify each:
  - Scene 5 day plan tool-callable from harness with calendar + preferences input.
  - Scene 6 enrichment latency under 5 s end-to-end.
  - Plan B Scene 1–3 (offline retries) match H1 evidence from sub #17.
  - No new env vars required beyond what's already in `03_HARNESS/.env`.

### Caveats (none = clean sign-off)

_to be filled by Leo + Fede after their reviews._

> Format example:
> - Leo: "Scene 4 preferences citation occasionally needs 2 turns when the LLM cache is cold — mitigated by setup state warm-up (last item in pre-go-live checklist)."
> - Fede: "Scene 6 enrichment adds ~3–5 s latency. Acceptable within the 45 s scene budget."

### Final PM sign-off

- [ ] **@ArmandoBattaglino** — merge approval after both reviews above + zero release-blocker caveats.

If any caveat is release-blocker → open a P0 bug, defer the merge, and re-trigger the sign-off after the bug closes.

### "Cold reading" smoke test

A non-team person (parent, partner, anyone) reads `DEMO_SCRIPT.md` for 5 minutes and explains GIGI back. If their explanation matches the 7-scene intent without follow-up questions, the doc is clean.
