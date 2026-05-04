# Pre-demo setup state — Sub #72 (extends DEMO_SCRIPT.md)

> Append the section below to `docs/DEMO_SCRIPT.md` after the storyboard from #71. Kept here as a free-standing file in this PR so it can be reviewed before the merge into the main script consolidates it.

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
