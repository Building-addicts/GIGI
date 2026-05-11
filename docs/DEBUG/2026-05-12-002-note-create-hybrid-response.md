# Bug 002 — `create_note` returns hybrid response: Claude "/login" error + native success

- **Status**: ✅ fixed
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

- **Commit**: `96ecfbd` (2026-05-12)
- **IPA**: TBD — next build
- **Files changed**: `02_GIGI_APP/GIGI/GigiRequestRouter.swift` (detectFollowUpAction guard + looksLikeClaudeAuthError helper + short-circuit in dispatchDelegateCloud)

### Diagnosis confirmed

Root cause was a cascade in `dispatchDelegateCloud`:
1. Router mis-routed "Create a note titled test with body hello world" to `delegate_cloud` (related bug 003, separate fix).
2. Claude Code spawned → returned `Not logged in · Please run /login` as text content (claude.exe stderr propagated by harness).
3. `collected` = that error string.
4. `detectFollowUpAction(originalText)` matched `create a note` substring → returned `FollowUpAction(action: "create_note")`.
5. GATE 6 fired secondary `dispatchNativeTool(create_note, body: collected)` → bridge created a note with the /login error as body content, returned its success string.
6. Final concatenation: `"\(collected) \(secondarySpeech)"` = the hybrid bubble.

### Two-layer fix applied

**Layer A — detectFollowUpAction guard (research verb required)**:
```swift
private static let researchVerbs = [
    "search", "look up", "find ", "research", "get the", "browse",
    "fetch", "check the web", "tell me about", "what's the latest"
]

guard Self.researchVerbs.contains(where: { t.contains($0) }) else {
    return nil
}
```
Pure native actions like "create a note titled X with body Y" no longer trigger the chain. GATE 6 only fires when a research verb COEXISTS with the action verb (the original intent: "Search Wikipedia for Tesla AND create a note about it").

**Layer B — Claude auth error filter (short-circuit)**:
```swift
private static func looksLikeClaudeAuthError(_ text: String) -> Bool {
    let lower = text.lowercased()
    return lower.contains("not logged in")
        || lower.contains("please run /login")
        || lower.contains("claude /login")
        || lower.hasPrefix("error: not authenticated")
        || lower.hasPrefix("authentication required")
}

if Self.looksLikeClaudeAuthError(collected) {
    return .error("Claude Code on the PC needs to be logged in. Run `claude /login` on the harness host once.")
}
```

Now if Claude returns a CLI auth error, the router short-circuits with a single clean message explaining the one-time setup step. No more verbatim stderr in user-visible bubbles, no concatenation with secondary action.

### Test plan after IPA install

| Input | Expected behavior |
|---|---|
| "Create a note titled test with body hello world" | Pure native → note copied to clipboard + Notes app opens. No Claude involvement, no /login error. |
| "Search Wikipedia for Tesla and create a note about it" | Path 4 Claude research → if Claude logged in: research + create note (chained). |
| Same as above, Claude NOT logged in | Clean error: "Claude Code on the PC needs to be logged in." No hybrid bubble. |
| "Remind me to call mom tomorrow" | Pure native_tool reminder, no GATE 6 chain. |

### Related work

Bug 003 (P0) addresses the root mis-classification (delegate_cloud over-routing). Fixing both together makes the cascade impossible.
