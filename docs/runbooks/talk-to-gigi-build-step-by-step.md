# Talk to GIGI — Step-by-Step Shortcut Build Guide

Manual walk-through to extend the existing `Talk To Gigi` Shortcut with the new
`SYS:` branch. The CALL / SMS / OPEN branches are already wired (per the user's
current Shortcuts.app state). This runbook only adds the SYS catalog.

Target reader: somebody clicking inside Shortcuts.app on iPhone/Mac with the
existing `Talk To Gigi` Shortcut already open.

---

## 0 · Snapshot of the existing Shortcut

For reference, the current structure (already in place) is:

```
Comment: "Talk to GIGI — generated v3..."
Text "no"                                      → Spoken Reset
Set variable Spoken to Spoken Reset
Repeat 50 times
    Dictate text
    If Dictated Text contains "Stop"
        Stop this shortcut
    End If
    Text "no"                                  → Spoken Reset
    Set variable Spoken to Spoken Reset
    Process speech with GIGI (input: Dictated Text)   → "Process speech with GIGI"

    If Process speech with GIGI begins with "CALL:"
        Replace "CALL:" with "" in Process speech with GIGI   → Updated Text
        Call Updated Text
        Stop this shortcut
        Text "yes"                              → Spoken Yes
        Set variable Spoken to Spoken Yes
    Otherwise
    End If

    If Process speech with GIGI begins with "SMS:"
        Replace "SMS:" with "" in Process speech with GIGI    → Updated Text
        Split Updated Text by Custom "|"
        Get First Item from Split Text
        Get Item at Index 2 from Split Text
        Send <Item from List> to <Item from List>
        Stop this shortcut
        Text "yes"                              → Spoken Yes
        Set variable Spoken to Spoken Yes
    Otherwise
    End If

    If Process speech with GIGI begins with "OPEN:"
        Replace "OPEN:" with "" in Process speech with GIGI   → Updated Text
        Open Updated Text
        Stop this shortcut
        Text "yes"                              → Spoken Yes
        Set variable Spoken to Spoken Yes
    Otherwise
    End If

    ◀── INSERT NEW SYS BRANCH HERE ──▶

    If Spoken is "no"
        Speak Process speech with GIGI
    Otherwise
    End If
End Repeat
```

The new SYS branch slots **after the OPEN `End If` and before the `If Spoken is
"no"` block**, mirroring the exact shape of CALL / SMS / OPEN.

> **Important Shortcuts wiring note:** if tapping the blue/yellow `Text` chip in
> `Set Variable Spoken to Text` jumps back to the first `Text` action at the top,
> the variable is wired to an ambiguous/stale Magic Variable. Fix it by inserting
> a fresh `Text` action with literal `no` immediately before that `Set Variable`,
> rename its output `Spoken Reset`, then set `Spoken` to `Spoken Reset`. Do this
> inside the repeat before `Process speech with GIGI`.

---

## 1 · Position the cursor

1. Tap `Talk To Gigi` to open the editor.
2. Scroll until you see the `OPEN` block ending with `Otherwise` then `End If`.
3. Tap directly **after** that `End If` so the search bar at the bottom is the
   next thing that will receive a new action.

If you tap into the wrong place, drag-handle the new actions later — Shortcuts
.app lets you reorder by long-press + drag.

---

## 2 · Master `If` for the SYS prefix

Add this single action:

| Action | Where to find it | Configuration |
|---|---|---|
| **If** | search "if" → tap the first result with the **Y-shape** (filter) icon | Input: `Process speech with GIGI` (Magic Variable, blue chip) · Condition: **begins with** · Text: `SYS:` |

Result inserted into the editor:

```
If Process speech with GIGI begins with "SYS:"
    [empty]
Otherwise
End If
```

Every action in this section goes **between** the `If` and `Otherwise` lines
(inside the body of the If block).

---

## 3 · Strip the prefix and split the marker

Four actions in order, all inside the SYS `If`.

### 3.1 — Replace Text (peel off `SYS:`)

| Field | Value |
|---|---|
| Action | **Replace Text** |
| Find Text | `SYS:` |
| Replace With | (leave empty) |
| Input | `Process speech with GIGI` (Magic Variable) |
| Output rename | tap the result chip → **Rename Variable** → `SYS Payload` |

The leading `SYS:` is gone. The remainder is `<command>:<param>`.

### 3.2 — Split Text (break on `:`)

| Field | Value |
|---|---|
| Action | **Split Text** |
| Text | `SYS Payload` |
| Separator | tap the dropdown → **Custom** |
| Custom Separator | `:` |
| Output rename | `SYS Parts` |

After this, `SYS Parts` is a list of two items: command and param.

### 3.3 — Get Item from List (command)

| Field | Value |
|---|---|
| Action | **Get Item from List** |
| List | `SYS Parts` |
| Get | tap the dropdown → **First Item** |
| Output rename | `SYS Command` |

### 3.4 — Get Item from List (param)

| Field | Value |
|---|---|
| Action | **Get Item from List** |
| List | `SYS Parts` |
| Get | tap the dropdown → **Item at Index** |
| Index | `2` |
| Output rename | `SYS Param` |

State so far inside the SYS `If`:

```
Replace "SYS:" with "" in Process speech with GIGI   → SYS Payload
Split SYS Payload by Custom ":"                       → SYS Parts
Get First Item from SYS Parts                         → SYS Command
Get Item at Index 2 from SYS Parts                    → SYS Param
```

---

## 4 · Per-command nested `If`s

All blocks below go **inside the SYS If**, after the four `Get`/`Split`
actions, **in this order**. Each block is a child `If SYS Command Equals "..."`.

> **Reminder:** every `If` action you add includes a default `Otherwise` and
> `End If`. You'll be inserting actions between those automatically — just
> tap inside the body before adding the next action.

### 4.1 · Group A — simple on/off toggles (6 commands)

These six all share the same shape. Build the first one (`torch`) carefully,
then duplicate-and-edit the rest.

#### `torch` → Set Flashlight

| Action | Configuration |
|---|---|
| **If** | Input: `SYS Command` · Condition: **is** · Text: `torch` |
| ↳ **If** (nested) | Input: `SYS Param` · Condition: **is** · Text: `on` |
| ↳ **Set Flashlight** | Turn: **On** |
| ↳ End If (auto) | (already there) |
| ↳ **If** (nested) | Input: `SYS Param` · Condition: **is** · Text: `off` |
| ↳ **Set Flashlight** | Turn: **Off** |
| ↳ End If (auto) | (already there) |
| End If (auto) | (closes the outer "torch" If) |

Visual:

```
If SYS Command is "torch"
    If SYS Param is "on"
        Set Flashlight: On
    Otherwise
    End If
    If SYS Param is "off"
        Set Flashlight: Off
    Otherwise
    End If
Otherwise
End If
```

#### `wifi`, `bluetooth`, `airplane`, `silent`, `lpm`

Same pattern as torch, swap the action:

| SYS Command | Action used | Notes |
|---|---|---|
| `wifi` | **Set Wi-Fi** | takes On/Off |
| `bluetooth` | **Set Bluetooth** | takes On/Off |
| `airplane` | **Set Airplane Mode** | takes On/Off |
| `silent` | **Set Silent Mode** | takes On/Off |
| `lpm` | **Set Low Power Mode** | takes On/Off |

Tip — fast cloning: long-press the entire `If SYS Command is "torch"` block →
**Duplicate**. Edit the duplicated copy: change `"torch"` to `"wifi"`, change
both inner Set Flashlight actions to **Set Wi-Fi**. Repeat for the other four.

### 4.2 · Group B — DND (Set Focus)

iOS 16+ replaced the standalone Do Not Disturb action with **Set Focus**.
Slightly different shape because Set Focus needs an explicit Action.

```
If SYS Command is "dnd"
    If SYS Param is "on"
        Set Focus: Do Not Disturb · Action: Turn On · Until: Turned Off
    Otherwise
    End If
    If SYS Param is "off"
        Set Focus: Do Not Disturb · Action: Turn Off
    Otherwise
    End If
Otherwise
End If
```

Steps:

| Action | Configuration |
|---|---|
| **If** | Input: `SYS Command` · is · `dnd` |
| ↳ **If** | Input: `SYS Param` · is · `on` |
| ↳ **Set Focus** | tap the action picker → choose **Do Not Disturb** · Action: **Turn On** · Until: **Turned Off** |
| ↳ **If** | Input: `SYS Param` · is · `off` |
| ↳ **Set Focus** | Do Not Disturb · Action: **Turn Off** |

If "Set Focus" is not in your library, use **Toggle Focus** as the fallback —
on iOS 26 both work but Set Focus is more deterministic.

### 4.3 · Group C — numeric setters (volume / brightness)

```
If SYS Command is "volume"
    Calculate: SYS Param ÷ 100      → Calculation Result
    Set Volume: Calculation Result
Otherwise
End If

If SYS Command is "brightness"
    Calculate: SYS Param ÷ 100      → Calculation Result
    Set Brightness: Calculation Result
Otherwise
End If
```

Steps for `volume`:

| Action | Configuration |
|---|---|
| **If** | `SYS Command` is `volume` |
| ↳ **Calculate** | search "calculate" → tap **Calculate** · Operation: **÷** · Operand 1: `SYS Param` · Operand 2: `100` |
| ↳ **Set Volume** | Volume: `Calculation Result` (Magic Variable from previous step) |

Repeat for `brightness` swapping **Set Volume** with **Set Brightness**.

> **iOS variant:** if Set Volume / Set Brightness in your library accepts
> integer 0–100 directly (slider showing percent), skip the Calculate step
> and pass `SYS Param` straight in. iOS 26 still uses 0–1 fractional input
> for both, so the divide-by-100 is the safer default.

### 4.4 · Group D — screenshot

```
If SYS Command is "screenshot"
    Take Screenshot
    Save to Photo Album: Recents
Otherwise
End If
```

| Action | Configuration |
|---|---|
| **If** | `SYS Command` is `screenshot` |
| ↳ **Take Screenshot** | (no parameters; output is the screenshot image) |
| ↳ **Save to Photo Album** | Album: **Recents** · Input: the screenshot Magic Variable from the previous action |

If you want the screenshot announced ("Screenshot saved"), add a **Speak Text**
action with literal text `"Screenshot saved."` after Save.

### 4.5 · Group E — music (4-way switch)

```
If SYS Command is "music"
    If SYS Param is "play"
        Play/Pause Music: Play
    Otherwise End If
    If SYS Param is "pause"
        Play/Pause Music: Pause
    Otherwise End If
    If SYS Param is "next"
        Skip Forward
    Otherwise End If
    If SYS Param is "prev"
        Skip Back
    Otherwise End If
Otherwise
End If
```

Steps:

| Action | Configuration |
|---|---|
| **If** | `SYS Command` is `music` |
| ↳ **If** | `SYS Param` is `play` |
| ↳↳ **Play/Pause Music** (or **Play Music**) | Mode: **Play** |
| ↳ **If** | `SYS Param` is `pause` |
| ↳↳ **Play/Pause Music** | Mode: **Pause** |
| ↳ **If** | `SYS Param` is `next` |
| ↳↳ **Skip Forward** | (no parameters) |
| ↳ **If** | `SYS Param` is `prev` |
| ↳↳ **Skip Back** | (no parameters) |

If your library shows only a single combined "Play/Pause Music" toggle, use it
in both places with the matching **Mode** dropdown.

### 4.6 · Group F — alarm (with dash-to-colon swap)

The Swift side emits the time as `HH-MM` (or `Xam` / `Xpm`) so the marker
survives the split-by-colon parser. The Shortcut converts the `-` back to `:`
before Create Alarm.

```
If SYS Command is "alarm"
    Replace "-" with ":" in SYS Param   → Alarm Time
    Create Alarm: Alarm Time · Repeat: Never · Label: "GIGI"
Otherwise
End If
```

Steps:

| Action | Configuration |
|---|---|
| **If** | `SYS Command` is `alarm` |
| ↳ **Replace Text** | Find: `-` · Replace: `:` · Input: `SYS Param` · Output rename: `Alarm Time` |
| ↳ **Create Alarm** | Time: `Alarm Time` · Repeat: **Never** · Label: `GIGI` |

For phrases like "wake me at 7 pm" the marker is `SYS:alarm:7pm` — there is no
dash, so Replace Text leaves it unchanged and Create Alarm parses `7pm`
directly.

### 4.7 · Group G — weather / battery / location

Each is a one-shot system query that ends with Speak Text reading the result.

#### `weather`

```
If SYS Command is "weather"
    Get Current Weather                              → Current Weather
    Get Details of Weather Conditions: Conditions    → Conditions
    Speak Text: "It's <Conditions> right now."
Otherwise
End If
```

| Action | Configuration |
|---|---|
| **If** | `SYS Command` is `weather` |
| ↳ **Get Current Weather** | (no parameters) |
| ↳ **Get Details of Weather Conditions** | Detail: **Conditions** · Input: `Current Weather` |
| ↳ **Speak Text** | text: tap into the field, type `It's `, insert the **Conditions** Magic Variable, type ` right now.` |

#### `battery`

```
If SYS Command is "battery"
    Get Battery Level                  → Battery Level
    Speak Text: "Battery is at <Battery Level> percent."
Otherwise
End If
```

| Action | Configuration |
|---|---|
| **If** | `SYS Command` is `battery` |
| ↳ **Get Battery Level** | (no parameters; returns 0–100) |
| ↳ **Speak Text** | `Battery is at ` + Magic Variable + ` percent.` |

#### `location`

```
If SYS Command is "location"
    Get Current Location               → Current Location
    Get Details of Location: Name      → Location Name
    Speak Text: "You are at <Location Name>."
Otherwise
End If
```

| Action | Configuration |
|---|---|
| **If** | `SYS Command` is `location` |
| ↳ **Get Current Location** | (no parameters) |
| ↳ **Get Details of Location** | Detail: **Name** (or **Street** for full address) · Input: `Current Location` |
| ↳ **Speak Text** | `You are at ` + Magic Variable + `.` |

### 4.8 · Group H — deep-link search (5 commands)

All five share the same shape: build a URL by concatenating a fixed prefix with
`SYS Param` (already percent-encoded by the Swift side), then open it.

#### `spotify`

```
If SYS Command is "spotify"
    Text: "spotify://search?query=" + SYS Param      → Spotify URL
    Open URLs: Spotify URL
Otherwise
End If
```

Steps:

| Action | Configuration |
|---|---|
| **If** | `SYS Command` is `spotify` |
| ↳ **Text** | tap into the field, type `spotify://search?query=`, then insert the `SYS Param` Magic Variable at the end · Output rename: `Spotify URL` |
| ↳ **Open URLs** | URL: `Spotify URL` |

#### `youtube`

Same shape, prefix `youtube://results?q=`:

| Action | Configuration |
|---|---|
| **If** | `SYS Command` is `youtube` |
| ↳ **Text** | `youtube://results?q=` + `SYS Param` → `YouTube URL` |
| ↳ **Open URLs** | URL: `YouTube URL` |

If the YouTube app isn't installed, iOS will silently fail. Fall back to the
web URL by setting the prefix to `https://www.youtube.com/results?search_query=`.

#### `amazon`

Use the web URL — universal, works whether the Amazon app is installed or not
(iOS hands it to the app via Universal Links automatically):

| Action | Configuration |
|---|---|
| **If** | `SYS Command` is `amazon` |
| ↳ **Text** | `https://www.amazon.com/s?k=` + `SYS Param` → `Amazon URL` |
| ↳ **Open URLs** | URL: `Amazon URL` |

#### `maps`

| Action | Configuration |
|---|---|
| **If** | `SYS Command` is `maps` |
| ↳ **Text** | `maps://?q=` + `SYS Param` → `Maps URL` |
| ↳ **Open URLs** | URL: `Maps URL` |

Apple Maps takes over and either drops a search pin or starts navigation if the
destination matches a contact / known address.

#### `instagram`

| Action | Configuration |
|---|---|
| **If** | `SYS Command` is `instagram` |
| ↳ **Text** | `instagram://user?username=` + `SYS Param` → `Instagram URL` |
| ↳ **Open URLs** | URL: `Instagram URL` |

`SYS Param` arrives without the `@` prefix — the Swift side strips it before
encoding.

---

## 5 · Close the SYS branch (mark spoken)

After the last per-command `If` (instagram), still **inside** the master SYS
`If`, add the closing pattern that mirrors CALL / SMS / OPEN:

| Action | Configuration |
|---|---|
| **Stop this shortcut** | (no parameters) |
| **Text** | content: `yes` |
| **Set Variable** | Variable Name: `Spoken` · Input: the previous Text Magic Variable; rename that Text output `Spoken Yes` to avoid wiring it to an older `Text` action |

`Stop this shortcut` ends execution after a SYS marker is consumed (matching
the CALL / SMS / OPEN convention). The Text + Set Variable pair after Stop are
dead code, but kept for symmetry with the other branches.

The master SYS `If` block now looks like:

```
If Process speech with GIGI begins with "SYS:"
    Replace "SYS:" with "" → SYS Payload
    Split SYS Payload by ":" → SYS Parts
    Get First Item from SYS Parts → SYS Command
    Get Item at Index 2 from SYS Parts → SYS Param

    [all per-command If blocks from §4]

    Stop this shortcut
    Text "yes" → Spoken Yes
    Set Variable Spoken to Spoken Yes
Otherwise
End If
```

Followed (already in the existing Shortcut) by:

```
If Spoken is "no"
    Speak Process speech with GIGI
Otherwise
End If
End Repeat
```

---

## 6 · Smoke test

Run the Shortcut from inside the editor (▶ play button bottom right) for each
phrase. Each row should produce the expected device behavior immediately after
GIGI dictation echoes back.

| Voice | Marker emitted | Expected behavior |
|---|---|---|
| "turn on the flashlight" | `SYS:torch:on` | Flashlight turns on |
| "turn off flashlight" | `SYS:torch:off` | Flashlight turns off |
| "set volume to 30" | `SYS:volume:30` | System volume → 30 % |
| "set brightness to 80" | `SYS:brightness:80` | Brightness → 80 % |
| "turn off wifi" | `SYS:wifi:off` | Wi-Fi off |
| "turn on bluetooth" | `SYS:bluetooth:on` | Bluetooth on |
| "airplane mode" | `SYS:airplane:on` | Airplane Mode on |
| "do not disturb" | `SYS:dnd:on` | DND focus on |
| "silent mode" | `SYS:silent:on` | Ringer muted |
| "low power mode" | `SYS:lpm:on` | LPM on |
| "take a screenshot" | `SYS:screenshot:` | Screenshot saved to Recents |
| "play music" | `SYS:music:play` | Music resumes |
| "pause" | `SYS:music:pause` | Music pauses |
| "next track" | `SYS:music:next` | Next song |
| "previous track" | `SYS:music:prev` | Previous song |
| "set alarm at 7:30" | `SYS:alarm:7-30` | Alarm 7:30 created |
| "wake me at 8 am" | `SYS:alarm:8am` | Alarm 08:00 created |
| "what's the weather" | `SYS:weather:` | Conditions spoken |
| "what's the battery" | (in-app) | "Battery is at X%" |
| "where am i" | `SYS:location:` | Address spoken |
| "play queen on spotify" | `SYS:spotify:queen` | Spotify search opens |
| "watch lofi on youtube" | `SYS:youtube:lofi` | YouTube search opens |
| "search shoes on amazon" | `SYS:amazon:shoes` | Amazon search opens |
| "navigate to Times Square" | `SYS:maps:Times%20Square` | Apple Maps routes |
| "instagram user marco" | `SYS:instagram:marco` | Instagram profile opens |
| "hello" (alone) | (no marker) | "Hi! What can I help with?" |
| "hello turn on the flashlight" | `SYS:torch:on` | Flashlight on (greeting NOT shadowed) |

---

## 7 · Export and share

1. Three-dot menu on `Talk to GIGI` → **Share** → **Copy iCloud Link**.
2. Paste link into the issue thread (#132).
3. Update `GigiHardwareShortcut.iCloudDownloadURL` in
   `02_GIGI_APP/GIGI/GigiConfig.swift`.

---

## 8 · Troubleshooting

- **iOS speaks the marker out loud (e.g. "S Y S colon torch colon on")**:
  the SYS branch did not run. Check the master `If` uses **begins with** and
  the literal text `SYS:`. Also check `Stop this shortcut` runs before the
  default `If Spoken is "no" → Speak` block.

- **Calculate refuses `SYS Param`**: wrap it in **Get Numbers from Input**
  first to coerce text to number, then pipe into Calculate.

- **Set Focus action is missing**: on iOS 16+ it is under **Set Focus**, not
  **Set Do Not Disturb**. Pick Set Focus and select the **Do Not Disturb**
  profile in its picker.

- **Volume / Brightness skip the Calculate step**: depends on iOS Shortcuts
  version. If the slider in the action takes 0–100 directly, drop the
  divide-by-100 and pass `SYS Param` straight in.

- **Alarm time is wrong (e.g. set for `7-30` literally)**: the Replace Text
  step in Group F is missing. Make sure it converts `-` to `:` before
  Create Alarm.

- **Spotify / YouTube / Amazon link doesn't open**: confirm the prefix is
  exact (no trailing space). For YouTube specifically, fall back to
  `https://www.youtube.com/results?search_query=` if the YouTube app
  isn't installed.

- **Execution jumps/highlights the first `Spoken` / first `Text` action and does
  not continue to `Process speech with GIGI`**: the `Spoken` reset is wired to
  an old generic Magic Variable named `Text`. Insert a new **Text** action with
  literal `no` immediately before the in-loop **Set Variable Spoken** action,
  rename that Text output to `Spoken Reset`, then set `Spoken` to `Spoken Reset`.
  After that, `Process speech with GIGI` must be the very next action at the same
  indentation level inside `Repeat 50 times`.

- **Greeting overrides intent** (e.g. "hello turn on flashlight" responds
  "Hi!" only): this is a Swift-side bug, not a Shortcut bug. Make sure your
  build includes the `isExactGreeting` fix in `GigiBackgroundTalkIntent.swift`.
