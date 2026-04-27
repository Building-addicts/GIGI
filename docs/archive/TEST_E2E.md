# GIGI E2E Test — Physical iPhone

> Target: iPhone with iOS 17+ on LAN with Mac running harness.

## Prerequisites

| Requirement | Check |
|---|---|
| Xcode build succeeds (no errors) | `Product → Build` |
| Groq API key in Config.xcconfig | `GROQ_API_KEY=gsk_...` |
| Harness running on Mac (`./start-harness.sh`) | `curl http://<MAC_IP>:7779/health` → `{"ok":true}` |
| iPhone on same LAN as Mac | Ping Mac IP from iPhone settings |

---

## 1. Fresh Install Onboarding

1. Delete app from device or reset `UserDefaults` via debug menu (Settings → Debug → Reset Onboarding).
2. Launch app.
3. **Welcome** → tap Continue.
4. **Permissions** → tap "Request all permissions" → grant Mic, Contacts, Calendar, Notifications.
5. **API Keys** → paste Groq key (`gsk_...`) → Gemini key optional → Continue.
6. **Mac Harness** (two paths):
   - **QR path**: run `./start-harness.sh` on Mac (prints QR), tap "Scan QR from Mac terminal", aim camera → fields auto-fill → "Connected ✓".
   - **Manual path**: type `http://<MAC_IP>:7779` + secret → "Test & save" → "Connected ✓".
7. **Profile** → fill name, email, phone, address → Continue.
8. **Wake Word** → toggle ON → Continue.
9. **Done** screen appears. `UserDefaults["gigi.onboarding.complete"] == true`.

**Expected**: Dashboard shows **BRAIN ON** green badge.

---

## 2. Voice Command — Basic

1. Say **"Jarvis"** (or tap mic button).
2. Say "What time is it?"
3. **Expected**: GIGI responds with current time via TTS (no spinner hang).

---

## 3. Voice Command — Call

1. Say "Call [contact name in Contacts]".
2. **Expected**: Phone app opens, call initiates. Confirm in Contacts that name resolves correctly.

---

## 4. Voice Command — Calendar

1. Say "Add meeting tomorrow at 3pm".
2. Open Calendar app.
3. **Expected**: Event "meeting" appears tomorrow at 15:00.

---

## 5. Harness Agent Round-trip

> Requires harness running.

1. Say "Ask the harness to tell me today's memory summary."
2. Watch harness `logs/bridge.log` (`tail -f 03_HARNESS/server/logs/bridge.log`).
3. **Expected**: Request appears in log, Claude responds, GIGI reads answer aloud.

---

## 6. APNS Push

> Requires harness with valid `apns.key_path` in config.json.

1. Background the app (swipe home).
2. In harness panel (`http://localhost:7777`) → Watchers → trigger "Morning Briefing" manually.
3. **Expected**: Push notification appears on iPhone lock screen within 5s.
4. Tap notification → app opens to Dashboard.

---

## 7. Wake Word

1. Lock screen or put phone face-down.
2. Say "Jarvis" (default) or "Hey GIGI" (if custom ppn configured).
3. **Expected**: App activates, mic opens, listening indicator shows.

---

## 8. Dashboard Status Badges

| Scenario | Expected badge |
|---|---|
| Groq key set + test passes | `BRAIN ON` (green) |
| No Groq key | `BRAIN OFF` (red) + orange "Groq key required" banner |
| WhatsApp linked | WhatsApp card shows green checkmark |

---

## 9. Memory Persistence

1. Say "Remember that my favorite restaurant is Nobu."
2. Kill and relaunch app.
3. Say "What's my favorite restaurant?"
4. **Expected**: GIGI answers "Nobu" without external lookup.

---

## 10. Regression Checklist

- [ ] Settings → Save Groq key → connection test passes
- [ ] Settings → QR scan harness → fills URL+secret
- [ ] Onboarding → QR scan harness → auto-connects
- [ ] WhatsApp link sheet → QR loads → chat list detected
- [ ] HomeKit accessories list (if home configured)
- [ ] Live Activity shows on Dynamic Island during active session

---

## Known Limitations

- Realtime voice (Gemini Live) requires `GEMINI_API_KEY` — falls back to TTS if absent.
- Wake word custom model (`HeyGIGI.ppn`) must be built via Picovoice Console.
- Computer-use requires `anthropic.api_key` in harness config.json.
