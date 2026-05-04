# DEMO_SCRIPT.md — GIGI MVP demo (1 May 2026)

> Authoritative reference for the live demo. Sub #71 (1/5) ships the storyboard. Sub #72 ships pre-demo state, #73 plan B, #74 final duration call, #75 cross-functional stability pass.

## Storyboard

7 scenes mapped 1:1 to `docs/MVP_SCOPE.md` §306. Total baseline ≈ 3 min 50 s.

### Scene 1 — Activate

- **Durata target:** 30 s
- **Intent:** show that GIGI is alive on the iPhone, no app foregrounded, hands-free trigger works (MVP AC#1, AC#3).
- **Setup richiesto:** iPhone unlocked on Lock Screen — see Sub #72.
- **Battuta umana:** "Hey GIGI, let's start a talking session."
- **Risposta GIGI attesa:** "Listening — what's on your mind?"
- **Visual cue:** Dynamic Island descends to expanded, banner reads `Listening`, waveform reactive.

### Scene 2 — Talk through the day

- **Durata target:** 45 s
- **Intent:** show natural turn-taking — user thinks aloud, GIGI listens silently and reflects (MVP AC#4).
- **Setup richiesto:** Calendar pre-populated with 3 events (Sub #72).
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
- **Setup richiesto:** MVP preferences seeded (Sub #72).
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

Sub #74 decides whether to expand selected scenes (4 + 5) for the 5–7 min variant.
