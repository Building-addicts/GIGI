# Shortcuts Integration Runbook — GATE 14.B.2 lite

> How to create the Apple Shortcuts that GIGI invokes to bypass Apple's
> closed APIs (Notes write, Reminders custom flows, etc.) and to add
> natural-language aliases for your own Shortcuts.

## Architecture

GIGI cannot write directly to system apps like Notes, Reminders Plus,
Health, or Files via 3rd-party SDK (sandboxed). The architectural
pattern (ADR-0013 + GATE 14.B.2): the user creates a Shortcut in
Apple's Shortcuts app using Shortcuts' privileged access; GIGI
invokes the Shortcut via
`shortcuts://x-callback-url/run-shortcut?name=<NAME>&input=text&text=<PAYLOAD>`.

The Shortcuts app comes to the foreground for ~1-2s during execution
(iOS sandbox limit — no background invocation for 3rd-party apps).

## Where to manage in GIGI

**Settings → ⚡️ Shortcuts Integration → My Shortcuts**

You can:

- Register a Shortcut by name
- Add aliases (natural-language phrases that route to it)
- Tag a Shortcut with a **system purpose** so GIGI internals use it
  (e.g. `append_to_note` wires the Shortcut into GIGI's `add_to_note`
  tool)
- Enable / disable / delete

## Recommended Shortcuts

### 1. GIGI Append to Note

**Purpose**: `append_to_note` — wires into GIGI's `add_to_note` tool.

**Input format**: text containing `<note_title>|<content>` (pipe-separated).

**Actions**:

1. Add **Get Input from Shortcut** (text)
2. Add **Split Text** → on `|` character → result: list
3. Add **Get Item from List** → first item → save as `noteTitle`
4. Add **Get Item from List** → second item → save as `noteContent`
5. Add **Find Notes Where** → Name → is → `noteTitle` → Limit 1
6. Add **Append to Note** → `noteContent` → Get Item from List → First
   Item of Notes found
7. (Optional) Add **Show Notification** → "GIGI added: \(noteContent)"
   for visual feedback

**Save as**: `GIGI Append to Note` (exact name — case-insensitive
matching but typos break it).

**Test from the Shortcuts app** before registering in GIGI:
- Tap the Shortcut → enter test input: `Test|Hello from GIGI`
- Open Notes → verify the note "Test" has "Hello from GIGI" appended

**Register in GIGI**:
- Settings → My Shortcuts → "+" → name `GIGI Append to Note`
- Purpose dropdown → `Append to Note`
- Save

Now `add_to_note` in GIGI invokes this Shortcut instead of the share
sheet fallback. 0-tap append.

### 2. GIGI Quick Reminder (optional)

**Purpose**: `create_reminder` — alternative path when EventKit's
default reminder UX isn't enough (e.g. with location triggers).

**Input format**: `<title>|<date>`.

**Actions**: Get Input → Split on `|` → Add New Reminder with title +
due date.

### 3. Alias-only Shortcuts

If you already have Shortcuts you use frequently (e.g. "Modo Lavoro",
"Cinema Scene"), register them in GIGI with natural-language aliases
so you can invoke them WITHOUT saying "run X":

- Settings → My Shortcuts → "+"
- Name: `Modo Lavoro` (your existing Shortcut)
- Aliases (comma-separated): `start working`, `work mode`, `let's work`,
  `lavorare`, `attiva modo lavoro`
- Purpose: leave as "None (alias only)"
- Save

Now when you say *"let's work"*, GIGI's router matches the alias and
dispatches `run_shortcut` with name `Modo Lavoro` — no need for the
literal `run` verb prefix.

## How the router uses your registry

GigiRequestRouter checks registries in this priority order:

1. **Registered alias match** — exact match against your declared
   aliases (case-insensitive, punctuation-stripped)
2. **Discovery intercept** — `"what can you do?"` etc.
3. **Math tier-0** — `"47 times 23"`
4. **Explicit verb tier-0** — `"run X"` / `"esegui X"`
5. **Semantic router** — embedding fast-path for catalog tools
6. **Apple FM constrained decoding** — fall-through, ~150ms

Alias is highest priority because it's the user's explicit declaration.

## Roadmap (GATE 14 full)

Polish coming in GATE 14 weeks 6 work:

- **AI-suggested aliases**: Apple FM proposes 5 aliases when you add
  a Shortcut
- **Semantic alias match**: instead of literal-equality alias match,
  GigiSemanticRouter checks if utterance is semantically close to any
  registered alias (handles paraphrases the user didn't list)
- **CloudKit sync**: registered Shortcuts sync across your devices
- **iCloud share links** for pre-built recommended Shortcuts (one-tap
  install instead of manual creation)

For today (GATE 14.B.2 lite): manual creation in Shortcuts app +
manual registration in GIGI Settings. ~5 minutes per Shortcut, lasts
forever.
