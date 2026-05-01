# Talk to GIGI — SYS Branch Build Guide

Companion to `talk-to-gigi-universal-shortcut.md`. This runbook describes the
new `SYS:` marker family and the Shortcut branches that consume it.

The Swift side (`GigiBackgroundTalkIntent.swift` / `LocalAnswer.parseSystemAction`)
emits `SYS:<command>:<param>` strings. The iOS Shortcut routes them to native
device actions so the harness never has to handle on-device hardware.

## Where the SYS branch lives

Add the SYS routing **after the `OPEN:` branch and before the default Speak Text
branch**, inside the same `Repeat` loop as CALL/SMS/OPEN.

Top-level shape:

```
If GIGI Result begins with "SYS:"
    Replace "SYS:" with ""              → SYS Payload
    Split SYS Payload by ":"            → SYS Parts
    Get Item 1 from SYS Parts           → SYS Command
    Get Item 2 from SYS Parts           → SYS Param
    [nested IF tree on SYS Command]
    Set Variable Spoken = "yes"
End If
```

`Spoken = "yes"` matters: it suppresses the trailing default Speak Text branch,
so the user does not hear iOS read out the marker string verbatim.

## Apple actions used (master list)

| Command | Apple Shortcut action | Param input |
|---|---|---|
| `torch` | Set Flashlight | Turn = On / Off |
| `volume` | Set Volume | Volume = SYS Param % |
| `brightness` | Set Brightness | Brightness = SYS Param % |
| `wifi` | Set Wi-Fi | Wi-Fi = On / Off |
| `bluetooth` | Set Bluetooth | Bluetooth = On / Off |
| `airplane` | Set Airplane Mode | Airplane Mode = On / Off |
| `dnd` | Set Focus → Do Not Disturb | Action = Turn On / Turn Off |
| `silent` | Set Silent Mode | Silent Mode = On / Off |
| `lpm` | Set Low Power Mode | Low Power Mode = On / Off |
| `screenshot` | Take Screenshot + Save to Photo Album | — |
| `music` | Play / Pause / Skip Forward / Skip Back | command |
| `battery` | Get Battery Level + Speak | — (handled in-app, normally not reached here) |
| `weather` | Get Current Weather + Speak | Conditions string |
| `location` | Get Current Location + Speak | Address string |
| `alarm` | Create Alarm | Time = SYS Param (`HH-MM`, dash converted to colon) |
| `spotify` | Open URL `spotify://search?query=…` | URL-encoded query |
| `youtube` | Open URL `youtube://results?q=…` | URL-encoded query |
| `amazon` | Open URL `https://www.amazon.com/s?k=…` | URL-encoded query |
| `maps` | Open URL `maps://?q=…` | URL-encoded destination |
| `instagram` | Open URL `instagram://user?username=…` | URL-encoded handle |

`battery` is listed for completeness — the Swift side answers it locally so the
Shortcut almost never sees `SYS:battery:`. Leave the branch in for fallback.

### Why the param is split-safe

The Shortcut peels the marker apart with **Split Text by `:`**, then takes
**Item 1** as the command and **Item 2** as the param. Two precautions on the
Swift side guarantee this is lossless:

- `urlQueryValue` percent-encodes `:` and `|` along with the usual URL-unsafe
  characters, so a query like `track:abc` becomes `track%3Aabc` in the marker
  and survives the splitter intact (the platform decodes it back when the
  Open URL fires).
- `alarm` swaps the `:` between hours and minutes for `-` (so the marker is
  `SYS:alarm:07-30`, not `SYS:alarm:07:30`). The SYS branch swaps it back
  before handing the value to Create Alarm.

If you add a new command whose param can contain `:` or `|`, route it through
`urlQueryValue` in `toMarker()` and add the matching decode step here.

## Build steps in Shortcuts.app

1. Open the existing `Talk to GIGI` Shortcut (the v3 build with CALL/SMS/OPEN).
2. Click after the `OPEN:` `End If`. Insert a new `If` action.
3. Configure that `If`:
   - **Input**: `GIGI Result` (variable from the App Intent run)
   - **Condition**: `begins with`
   - **Text**: `SYS:`
4. Inside the new `If` block, add these actions in order:

### 4.1 — Strip prefix and split

| # | Action | Configuration |
|---|---|---|
| 1 | **Replace Text** | Find: `SYS:` · Replace: empty · Input: `GIGI Result` · Rename output: `SYS Payload` |
| 2 | **Split Text** | Input: `SYS Payload` · Separator: Custom · Custom: `:` · Rename output: `SYS Parts` |
| 3 | **Get Item from List** | List: `SYS Parts` · Get: Item at Index · Index: `1` · Rename output: `SYS Command` |
| 4 | **Get Item from List** | List: `SYS Parts` · Get: Item at Index · Index: `2` · Rename output: `SYS Param` |

### 4.2 — Per-command nested IFs

Add one `If` per command from the table below. Place them in this order:
on/off toggles first, numeric setters next, music last (because music has its
own four-way branch). Each `If` uses **Input = SYS Command, Condition = Equals**.

#### `torch` → Set Flashlight

```
If SYS Command Equals "torch"
    If SYS Param Equals "on"
        Set Flashlight: Turn On
    End If
    If SYS Param Equals "off"
        Set Flashlight: Turn Off
    End If
End If
```

#### `wifi`, `bluetooth`, `airplane`, `silent`, `lpm` → Set <radio>

Each follows the same shape as torch with its own action:

```
If SYS Command Equals "wifi"
    If SYS Param Equals "on"  → Set Wi-Fi: Turn On  End If
    If SYS Param Equals "off" → Set Wi-Fi: Turn Off End If
End If
```

Repeat for `bluetooth` (Set Bluetooth), `airplane` (Set Airplane Mode), `silent`
(Set Silent Mode), `lpm` (Set Low Power Mode). All five take the same
`on` / `off` pair.

#### `dnd` → Set Focus

```
If SYS Command Equals "dnd"
    If SYS Param Equals "on"
        Set Focus: Do Not Disturb · Action: Turn On · Until: Turned Off
    End If
    If SYS Param Equals "off"
        Set Focus: Do Not Disturb · Action: Turn Off
    End If
End If
```

iOS 16+ replaced the standalone DND action with Focus. Pick the `Do Not Disturb`
focus profile in the picker.

#### `volume` → Set Volume

```
If SYS Command Equals "volume"
    Calculate: SYS Param ÷ 100   → Volume Fraction
    Set Volume: Volume Fraction
End If
```

The Set Volume action takes a number 0–1 in plist form. The Calculate action
converts the percent SYS Param produces.

If on your iOS version Set Volume shows a percent slider that accepts integer
0–100 directly, skip the Calculate step and pass `SYS Param` straight in.

#### `brightness` → Set Brightness

Same shape as `volume`. Use Set Brightness instead.

#### `screenshot` → Take Screenshot + Save

```
If SYS Command Equals "screenshot"
    Take Screenshot
    Save to Photo Album: Recents
End If
```

#### `music` → Play / Pause / Skip Forward / Skip Back

```
If SYS Command Equals "music"
    If SYS Param Equals "play"
        Play Music
    End If
    If SYS Param Equals "pause"
        Pause Music
    End If
    If SYS Param Equals "next"
        Skip Forward
    End If
    If SYS Param Equals "prev"
        Skip Back
    End If
End If
```

Apple's actions are named "Play / Pause Music" (single combined action with a
`Play` / `Pause` setting in some iOS versions) and "Skip Forward / Skip Back".
If your Shortcuts library shows a single "Play / Pause Music" toggle action,
use it twice with the matching mode.

#### `weather` → Get Current Weather + Speak

```
If SYS Command Equals "weather"
    Get Current Weather: Conditions
    Speak Text: "<conditions string>"
End If
```

Use the Magic Variable from Get Current Weather as the Speak input.

#### `location` → Get Current Location + Speak

```
If SYS Command Equals "location"
    Get Current Location
    Get Details of Location: Name (or Street)
    Speak Text: "You are at <address>."
End If
```

#### `alarm` → Create Alarm

```
If SYS Command Equals "alarm"
    Replace Text: Find "-" Replace ":" Input SYS Param   → Alarm Time
    Create Alarm: Time = Alarm Time · Repeat = Never · Label = "GIGI"
End If
```

`SYS Param` arrives as `HH-MM` (e.g. `07-30`) — the Swift side converts the
colon to a dash so the SYS marker survives the split-by-colon parser. The first
Replace Text step puts the colon back before Create Alarm consumes it.

For phrases with am/pm ("wake me at 7 pm") `SYS Param` arrives as `7pm` — no
dash, no colon — and Create Alarm parses it directly.

#### `battery` (rarely reached)

```
If SYS Command Equals "battery"
    Get Battery Level
    Speak Text: "Battery is at <level>%."
End If
```

#### `spotify` → Open URL (search)

```
If SYS Command Equals "spotify"
    URL: "spotify://search?query=" + SYS Param
    Open URLs: <URL>
End If
```

`SYS Param` is already percent-encoded by the Swift side (`urlQueryValue`).
Concatenate with the prefix using a Text action; pipe the result into Open URLs.

#### `youtube` → Open URL (search)

```
If SYS Command Equals "youtube"
    URL: "youtube://results?q=" + SYS Param
    Open URLs: <URL>
End If
```

If the YouTube app isn't installed, the Open URL falls back to mobile Safari at
`https://www.youtube.com/results?search_query=…` — adjust the prefix to taste.

#### `amazon` → Open URL (search)

```
If SYS Command Equals "amazon"
    URL: "https://www.amazon.com/s?k=" + SYS Param
    Open URLs: <URL>
End If
```

The native `amzn://` deep link only works on devices with the Amazon app. Using
the web URL keeps the action universal. If the Amazon app is installed, iOS
hands the link to it via Universal Links anyway.

#### `maps` → Open URL (navigate)

```
If SYS Command Equals "maps"
    URL: "maps://?q=" + SYS Param
    Open URLs: <URL>
End If
```

Apple Maps takes over the Open URL. If the destination matches a contact,
Apple's URL handler turns it into routing; otherwise a search pin is dropped.

#### `instagram` → Open URL (profile)

```
If SYS Command Equals "instagram"
    URL: "instagram://user?username=" + SYS Param
    Open URLs: <URL>
End If
```

`SYS Param` is the bare handle (no `@`). The Swift side strips the `@` and any
trailing `.` before encoding.

### 4.3 — Mark as spoken

After the last per-command IF, **before** the SYS `End If`, add:

| Action | Configuration |
|---|---|
| Set Variable | Variable Name: `Spoken` · Input: literal text `yes` |

This stops the default Speak Text fallback from speaking the marker string.

### 4.4 — Close the SYS branch

Close the master `If GIGI Result begins with "SYS:"` block. Confirm the action
list ends with: `... End If` (SYS), then the existing `If Spoken Equals "no"`
default Speak block, then `End Repeat`.


> Current core build note: Swift is intentionally aligned to the Shortcut branches
> built for issue #132 core. It emits `SYS:` only for torch, volume, brightness,
> wifi, bluetooth, airplane, dnd, silent, lpm, screenshot, music, battery
> fallback, weather, location, and alarm. Deep-link search commands
> (`spotify`, `youtube`, `amazon`, `maps`, `instagram`) stay documented below
> as follow-up Shortcut branches, but Swift should not emit them until those
> branches are actually present; otherwise the final SYS `Stop this shortcut`
> would make the request fail silently.

## Voice phrase test matrix

After importing the updated Shortcut, test from Action Button on a physical
iPhone. Each row is one Acceptance Criterion in issue #132.

| AC | Voice | Expected marker | Expected effect |
|---|---|---|---|
| 1 | "turn on the flashlight" | `SYS:torch:on` | Flashlight turns on |
| 1 | "turn off flashlight" | `SYS:torch:off` | Flashlight turns off |
| 2 | "set volume to 30" | `SYS:volume:30` | System volume → 30 % |
| 3 | "set brightness to 80" | `SYS:brightness:80` | Display brightness → 80 % |
| 4 | "turn off wifi" | `SYS:wifi:off` | Wi-Fi disabled |
| 5 | "do not disturb" | `SYS:dnd:on` | DND focus enabled |
| 6 | "take a screenshot" | `SYS:screenshot:` | Screenshot saved to Recents |
| 7a | "play music" | `SYS:music:play` | Apple Music resumes |
| 7b | "pause" | `SYS:music:pause` | Music pauses |
| 7c | "next track" | `SYS:music:next` | Skips to next song |
| 8 | "what's the battery" | (in-app answer; marker only on fallback) | GIGI says "Battery is at X%" |
| — | "set alarm at 7:30" | `SYS:alarm:7-30` | Alarm created for 7:30 |
| — | "wake me at 8 am" | `SYS:alarm:8am` | Alarm created for 08:00 |
| — | "low power mode" | `SYS:lpm:on` | LPM enabled |
| — | "airplane mode" | `SYS:airplane:on` | Airplane Mode enabled |
| — | "turn off bluetooth" | `SYS:bluetooth:off` | Bluetooth disabled |
| — | "silent mode" | `SYS:silent:on` | Ringer muted |
| — | "what's the weather" | `SYS:weather:` | Spoken conditions |
| — | "where am i" | `SYS:location:` | Spoken address |
| — | "play queen on spotify" | `SYS:spotify:queen` | Spotify search opens |
| — | "watch lofi on youtube" | `SYS:youtube:lofi` | YouTube search opens |
| — | "search shoes on amazon" | `SYS:amazon:shoes` | Amazon search opens |
| — | "navigate to Times Square" | `SYS:maps:Times%20Square` | Apple Maps routes |
| — | "instagram user marco" | `SYS:instagram:marco` | Instagram profile opens |
| — | "hello" (alone) | (no marker) | GIGI says "Hi! What can I help with?" |
| — | "hello turn on the flashlight" | `SYS:torch:on` | Greeting NOT shadowed; flashlight on |
| 11 | "tell me a joke" | (no SYS marker) | Falls through to harness |

## Export and share

1. In Shortcuts.app, three-dot menu on `Talk to GIGI` → Share → iCloud Link.
2. Paste the link into the issue thread.
3. Update `GigiHardwareShortcut.iCloudDownloadURL` in `02_GIGI_APP/GIGI/GigiConfig.swift`.

## Troubleshooting

- **iOS speaks the marker out loud**: the SYS branch did not run, or the
  `Spoken = yes` Set Variable is missing. Check that the master `If` uses
  `begins with "SYS:"` and not `equals`.
- **Calculate refuses SYS Param**: wrap it in a `Get Numbers from Input` first
  to coerce the text item to a number, then pipe into Calculate.
- **DND action missing**: on iOS 16+ it is under "Set Focus", not "Set Do Not
  Disturb". Pick the Focus action and select the Do Not Disturb profile.
- **Volume / Brightness skip the Calculate**: depends on iOS Shortcuts version.
  If the slider in the action takes 0–100 directly, drop the divide-by-100.
