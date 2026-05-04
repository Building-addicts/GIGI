# GIGI Shortcut generators

This directory contains the deterministic source of truth for the generated
Shortcuts.

## DI-first split model

The user-facing trigger is `GIGI Listen`: a tiny hardware-trigger Shortcut that
opens `gigi://listen`. It does not dictate text and does not route commands.
GIGI foregrounds into the Dynamic Island listening flow, captures speech in-app,
and the orchestrator decides what to do.

The hidden privileged executor is `GIGI Execute`: it accepts a preformatted
marker from the app and runs native iOS Shortcut actions. It contains no Dictate
Text, no Begin Session, and no Orchestrator action. Marker examples:
`SYS:torch:on`, `CALL:+15551234567`, `SMS:+15551234567|I'm late`,
`OPEN:spotify://`, `SPEAK:...`, and `STOP:`.

Product boundary: the user is talking to GIGI. The Shortcut is only the
Apple-native execution arm; capture, parsing, and command planning stay in the
GIGI app/orchestrator layer.

`Talk to GIGI` remains as the legacy all-in-one generated Shortcut for import
debugging, but it is not the desired Back Tap / Action Button UX because it uses
iOS Dictate Text.

## Generate

From the repo root:

```bash
python3 scripts/shortcuts/build_gigi_listen.py
python3 scripts/shortcuts/build_gigi_execute.py
python3 scripts/shortcuts/build_talk_to_gigi.py
```

Default outputs:

- `artifacts/shortcuts/GIGI-Listen.shortcut` — bind this to Back Tap / Action Button.
- `artifacts/shortcuts/GIGI-Execute.shortcut` — hidden marker executor invoked by the app.
- `artifacts/shortcuts/Talk-to-GIGI.shortcut` — importable Shortcut plist payload.
- `artifacts/shortcuts/Talk-to-GIGI.toml` — readable/debug representation.
- `artifacts/shortcuts/catalog.json` — generated command registry.
- `artifacts/shortcuts/catalog.md` — generated command matrix.

The script prints the action count and SHA-256 of the `.shortcut` output. Running
it twice with the same inputs should produce the same hash.

## Dependency

The generator depends on `shortcuts-py` being available to `python3`:

```bash
python3 -c "import shortcuts"
```

If that import fails, install/activate the tooling environment that provides
`shortcuts-py` before generating.

## AppIntent-backed native-action families

The prototype library in this environment does not expose all Apple Shortcuts
actions needed by the full catalog. For those families, the generated Shortcut
creates explicit branches that call `GigiExecuteSystemCommandIntent` with the
original marker, then speaks the executor result:

- `SYS:alarm:<HH-MM>` — notification-backed alarm.
- `SYS:timer:<minutes>` — notification-backed timer.
- `SYS:reminder:<body>` — EventKit reminder.
- `SYS:weather:` — weather lookup.
- `SYS:location:` — current location / reverse geocode.
- `SYS:event:<payload>` — EventKit calendar event.

`SYS:volume:<0-100>` and `SYS:brightness:<0-100>` are generated with dynamic
Shortcut variables, but those typed numeric fields must be validated by importing
on a physical device because `shortcuts-py` only models static floats for them.

Implemented native or URL-backed branches include torch, Wi-Fi, Bluetooth,
airplane mode, DND, silent mode, Low Power Mode, screenshot, music controls,
battery speech, CALL, SMS, OPEN, Spotify, YouTube, Amazon, Maps, Instagram,
SPEAK, ERROR, STOP, and default speech fallback.
