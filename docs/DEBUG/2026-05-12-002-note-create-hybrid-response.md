# Bug 002 — `create_note` returns hybrid response: Claude "/login" error + native success

- **Status**: open
- **Severity**: **P1** (user-visible garbage at start of response)
- **Discovered**: 2026-05-12 — beta tester wave
- **Area**: iOS · GigiAgentEngine / GigiRequestRouter · response composition

## Symptom

User prompt: **"Create a note titled test with body hello world"**

GIGI bubble response (literal):
> Not logged in · Please run /login Note titled 'test' with body 'hello world' has been created and copied to the clipboard. The Notes app will open, and you can paste the note with a long-press.

Two messages glued together with NO separator:
1. `Not logged in · Please run /login` — Claude Code CLI authentication error
2. `Note titled 'test' with body 'hello world' has been created and copied to the clipboard. The Notes app will open, and you can paste the note with a long-press.` — native `create_note` success

## Evidence

iPhone screenshot 2 in tester thread — clearly shows the concatenated text in one bubble.

## Repro

1. Beta tester host: `claude` CLI installed but NOT logged in (`/login` never run)
2. iPhone: pronounce or type "Create a note titled test with body hello world"
3. Single response bubble contains BOTH messages glued

## Root cause hypothesis

Two paths likely fired in sequence or in parallel:

**Hypothesis A — fallback chain**:
- Apple FM router classified as `native_tool` with `primaryAction=create_note` ✓
- `GigiActionBridge.createNote()` ran successfully → returned the success string
- But ALSO something triggered a Claude Code call (maybe a parallel `delegate_local` fallback, or a confirmation chain, or the orchestrator decided to "enrich" with a brain response)
- Claude returned "/login" error
- Both strings got concatenated into the final TTS / bubble text

**Hypothesis B — orchestrator double-dispatch**:
- `GigiAgentEngine.process()` may be running TWO dispatches: action bridge + a brain "speech" generation for the TTS preamble
- The brain dispatch failed with /login, returned its error string
- The action dispatch succeeded
- Both got into the same response bubble

**Hypothesis C — Claude prefix injection**:
- Maybe the harness always asks Claude for a "natural language confirmation" wrapper around native_tool actions
- Claude failed → returned its error as the wrapper
- Native string appended after

Need to grep `GigiAgentEngine.process` and `GigiSmartOrchestrator.handleResult` for double-dispatch or response composition.

## Proposed investigation

```bash
grep -nE "createNote|create_note" 02_GIGI_APP/GIGI/Gigi*.swift
grep -nE "Not logged in|/login" 02_GIGI_APP/GIGI 03_HARNESS/server -r
```

The "/login" string comes from Claude Code CLI when no auth — it's a CLI stderr line that the harness propagates. Need to find where the harness response is appended to the native action result.

## Proposed fix (after diagnosis)

- If Hypothesis A or C: suppress brain enrichment when path=native_tool (the bridge's return string IS the response — don't wrap with Claude)
- Or: filter Claude error messages from response composition (the `Not logged in` should become a single banner notification, not glued to user-facing bubble)

## Side issue surfaced

This also reveals that **the harness has Claude Code CLI installed but not logged in**. Need to document this prerequisite in the beta tester onboarding:

```
# Once-per-machine on the harness host:
claude /login
# Follow the OAuth prompt in browser to authenticate
```

Add a "Claude Code login required" check to `/api/panel/stack-status` so it appears in the live monitor stack cards.

## Files involved

| File | What |
|---|---|
| `02_GIGI_APP/GIGI/GigiAgentEngine.swift` | Dispatcher |
| `02_GIGI_APP/GIGI/GigiSmartOrchestrator.swift` | Response composition |
| `02_GIGI_APP/GIGI/GigiActionBridge.swift:142-146` | `create_note` action |
| `03_HARNESS/server/claude-runner.js` | Where /login error originates |

## Resolution

_(empty)_
