# GIGI Action Dispatcher — Shortcut Build Guide

Manual build guide for the iOS Shortcut that the GIGI app triggers from
foreground voice / Control Center quick-listen. Receives a marker as
`Shortcut Input`, executes the matching native iOS action.

**Name (mandatory, exact):** `GIGI Action Dispatcher`

The app calls the Shortcut by display name via the
`shortcuts://run-shortcut?name=GIGI%20Action%20Dispatcher` URL scheme.
If the name differs, the app's MarkerDispatcher falls back to direct
URL schemes — the Shortcut layer is silently skipped.

---

## Marker contracts received as `Shortcut Input`

```text
CALL:+393331234567
SMS:+393331234567|I'm running late
OPEN:spotify://
OPEN:whatsapp://send?phone=393331234567&text=hello
OPEN:https://example.com
```

---

## Visual structure

```
┌─────────────────────────────────────────────────┐
│  GIGI Action Dispatcher — full flow             │
└─────────────────────────────────────────────────┘

Shortcut Input  ←  marker handed by GIGI app

1. IF Shortcut Input BEGINS WITH "CALL:"
   ├─ 2. Replace "CALL:" with "" in Shortcut Input  → Phone
   ├─ 3. Call Phone
   └─ 4. End If

5. IF Shortcut Input BEGINS WITH "SMS:"
   ├─ 6. Replace "SMS:" with "" in Shortcut Input  → SMS Payload
   ├─ 7. Split SMS Payload by "|"                  → SMS Parts
   ├─ 8. Item 1 of SMS Parts                       → Recipient
   ├─ 9. Item 2 of SMS Parts                       → Body
   ├─ 10. Send Body to Recipient
   └─ 11. End If

12. IF Shortcut Input BEGINS WITH "OPEN:"
    ├─ 13. Replace "OPEN:" with "" in Shortcut Input  → URL
    ├─ 14. Open URL [URL]
    └─ 15. End If
```

**Total:** 15 actions + 3 auto "End If".

No Repeat loop. No Dictate Text. No Speak Text. The Shortcut runs once
per marker, executes the action, returns.

---

## Step-by-step build (iOS Shortcuts app)

### Setup

1. Open **Shortcuts**.
2. Tap **+** top-right → new empty shortcut.
3. Tap the title at top → type **`GIGI Action Dispatcher`** (exact).
4. Tap the (i) info button → enable **Use as Quick Action** off, **Show in Share Sheet** off, **Show in Apple Watch** off. The Shortcut is meant to be invoked programmatically via URL scheme, not from any user-facing surface.

### ACTION 1 — If Shortcut Input begins with "CALL:"

1. Search **`If`** → tap.
2. **Input** slot → tap → bottom sheet → tap **Shortcut Input**.
3. **Condition** → **Begins With**.
4. **Text** → type `CALL:`.

### ACTION 2 — Replace CALL: with empty

(Inside the If CALL block.)

1. Search **`Replace Text`** → tap.
2. **Find** → type `CALL:`.
3. **Replace With** → leave **empty**.
4. **In Text** → tap → **Shortcut Input**.
5. Expand the action (▶) → **Custom Output Name** → `Phone`.

### ACTION 3 — Call Phone

(Inside the If CALL block, below Replace.)

1. Search **`Call`** (green phone icon, NOT FaceTime).
2. Contact slot → tap → variable **Phone**.

---

### ACTION 4 — If Shortcut Input begins with "SMS:"

(OUTSIDE the If CALL block.)

1. Search **`If`** → tap.
2. **Input** → **Shortcut Input**.
3. **Condition** → **Begins With**.
4. **Text** → `SMS:`.

### ACTION 5 — Replace SMS: with empty

(Inside the If SMS block.)

1. Search **`Replace Text`** → tap.
2. **Find** → `SMS:`.
3. **Replace With** → empty.
4. **In Text** → **Shortcut Input**.
5. Expand → **Custom Output Name** → `SMS Payload`.

### ACTION 6 — Split SMS Payload by "|"

1. Search **`Split Text`** → tap.
2. **Input** → **SMS Payload**.
3. **Separator** → **Custom**.
4. Custom separator → type `|` (single pipe).
5. Expand → **Custom Output Name** → `SMS Parts`.

### ACTION 7 — Item 1 (Recipient)

1. Search **`Get Item`** → tap **Get Item from List**.
2. **Input** → **SMS Parts**.
3. Tap "All Items" → change to **Item at Index**.
4. **Index** → `1`.
5. Expand → **Custom Output Name** → `Recipient`.

### ACTION 8 — Item 2 (Body)

Same as Action 7 but **Index** = `2`, output **`Body`**.

### ACTION 9 — Send Message

1. Search **`Send Message`** → tap.
2. **Message** slot → variable **Body**.
3. **Recipients** slot → variable **Recipient**.

---

### ACTION 10 — If Shortcut Input begins with "OPEN:"

(OUTSIDE the If SMS block.)

1. Search **`If`** → tap.
2. **Input** → **Shortcut Input**.
3. **Condition** → **Begins With**.
4. **Text** → `OPEN:`.

### ACTION 11 — Replace OPEN: with empty

(Inside the If OPEN block.)

1. Search **`Replace Text`**.
2. **Find** → `OPEN:`.
3. **Replace With** → empty.
4. **In Text** → **Shortcut Input**.
5. Expand → **Custom Output Name** → `URL`.

### ACTION 12 — Open URL

1. Search **`Open URL`**.
2. URL slot → variable **URL**.

---

## Final checklist

- [ ] Three top-level If blocks, each closed (`End If` auto-added).
- [ ] No Repeat / Dictate / Speak actions.
- [ ] Shortcut name exactly `GIGI Action Dispatcher` (case-sensitive,
      space between words).
- [ ] **Show in Share Sheet** off, **Use as Quick Action** off.

## Test from Mac terminal (optional, requires iCloud-paired iPhone)

If you have shortcuts CLI on macOS:

```bash
# Time
shortcuts run "GIGI Action Dispatcher" -i "OPEN:https://www.apple.com"
```

Or from another iPhone Shortcut, run a one-shot **Open URL** with:

```
shortcuts://run-shortcut?name=GIGI%20Action%20Dispatcher&input=text&text=OPEN:spotify://
```

---

## Behaviour when input doesn't match any prefix

If Shortcut Input doesn't begin with `CALL:`, `SMS:`, or `OPEN:`, all
three If blocks fall through and the Shortcut exits silently — no error,
no spoken feedback. The GIGI app guarantees only well-formed markers
reach this Shortcut, so no fourth fallback is needed.
