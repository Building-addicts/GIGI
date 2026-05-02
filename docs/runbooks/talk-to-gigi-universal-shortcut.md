# Talk to GIGI Universal Shortcut

Target Shortcut name: `gigi-talk-to-gigi-v3`

This is the canonical Action Button / Back Tap Shortcut contract for the MVP demo.
GIGI is the brain: it returns a marker. Shortcuts is the arm: it executes the
native iOS action without opening the GIGI app.

## Top-Level Loop

1. `Repeat` 50 times.
2. `Dictate Text`.
3. `If Dictated Text contains stop` -> `Exit Shortcut`.
4. Run App Intent `Process speech with GIGI` with `Text = Dictated Text`.
5. Save its output as `GIGI Result`.
6. Route `GIGI Result` by prefix in this order:
   - `CALL:`
   - `SMS:`
   - `OPEN:`
   - default spoken answer

## CALL Branch

Contract:

```text
CALL:+393331234567
```

Actions:

1. Replace `CALL:` in `GIGI Result` with empty text.
2. Trim whitespace.
3. `Call` the resulting value.

Notes:

- GIGI tries to resolve natural contacts first, so `call mom` should usually
  produce a phone number, not a name.
- If GIGI cannot resolve a contact, it may still return `CALL:Mom`; in that
  case add an optional fallback before `Call`: `Find Contacts` where name
  contains the stripped value, `Choose from List` if more than one, then `Call`.

## SMS Branch

Contract:

```text
SMS:+393331234567|I'm late
```

Actions:

1. Replace `SMS:` in `GIGI Result` with empty text.
2. Split Text by `|`.
3. First item = recipient.
4. Second item = message body.
5. `Send Message` body to recipient.

Notes:

- iOS may show its own confirmation UI. That is expected and Apple-compliant.
- If body is empty, ask for text in the Shortcut before `Send Message`.

## OPEN Branch

Contract:

```text
OPEN:spotify://
OPEN:whatsapp://send?phone=393331234567&text=I'm%20late
OPEN:https://example.com
```

Actions:

1. Replace `OPEN:` in `GIGI Result` with empty text.
2. `Open URL` with the stripped value.

## Default Branch

If no marker matches:

1. `Speak Text` with `GIGI Result`.

## Demo Test Set

- `what time is it` -> spoken answer.
- `call mom` -> `CALL:+number` -> native Call action.
- `text Fede saying I'm late` -> `SMS:+number|I'm late` -> Send Message.
- `WhatsApp Fede saying I'm late` -> `OPEN:whatsapp://send?...`.
- `open Spotify` -> `OPEN:spotify://`.
- `stop` -> Exit Shortcut.
