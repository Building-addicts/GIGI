# GATE 6 — Killer demo "Tesla → note" scenarios

> **Status**: scaffold ready (2026-05-12). Multi-step callback wired in `GigiRequestRouter.dispatchDelegateCloud`. Demo scripts ready for device testing.
> **Trigger pattern**: any utterance containing both a research/lookup verb (search, find, check, navigate, look up) AND a save/share verb (create a note, save it, remind me, draft an email).

## Architecture (2-turn callback)

```
User utterance: "Search Wikipedia for Nikola Tesla and create a note about his most important invention"

       │
       ▼
GigiAgentEngine.process(text)
       │
       ├─ NLU fast-path → MISS (compound intent)
       │
       └─ GigiRequestRouter.route(text, history)
              │
              ├─ Apple FM router → FoundationRouterDecision {
              │     path: "delegate_cloud"
              │     capabilities: [browser, web_search]
              │     complexity: 65
              │     delegatePrompt: "Open Wikipedia, find Nikola Tesla's most important invention, return a concise summary."
              │   }
              │
              └─ dispatchDelegateCloud
                    │
                    ├─ TURN 1: GigiHarnessClient.runClaudeCode(prompt, mcpServers=[harness-browser])
                    │            │
                    │            └─ Claude Code subprocess navigates Wikipedia → returns
                    │               summary "Tesla's most important invention was the alternating
                    │               current induction motor, patented in 1888..."
                    │
                    ├─ detectFollowUpAction(originalText) → "create_note"
                    │
                    ├─ TURN 2: makeSecondaryDecision(action: create_note,
                    │            title: "Nikola Tesla",  body: <summary>)
                    │
                    └─ dispatchNativeTool → FMCreateNoteTool.call →
                          GigiActionBridge.createNote → clipboard + Notes app opens

Final speech: "<summary>. Note 'Nikola Tesla' copied to clipboard. Opening Notes — paste with long-press."
```

Total budget: **<90s** end-to-end. Claude Code subprocess: 20-60s. Path 2 dispatch: <500ms. TTS speech overlay.

## 5 demo scenarios

### 1. Tesla → note (primary)

**Voice command**:
> "Search Wikipedia for Nikola Tesla and create a note about his most important invention"

**Expected**:
- Router: `delegate_cloud`, capabilities=[browser, web_search]
- Claude Code spawns with MCP harness-browser
- Navigates wikipedia.org/wiki/Nikola_Tesla
- Returns summary mentioning "alternating current induction motor"
- 2-turn callback → FMCreateNoteTool → "Nikola Tesla" note copied to clipboard, Notes opens
- Latency target: 30-60s

**Failure mode**: if Wikipedia 404 / network issue → speech reports error + Notes does NOT open.

### 2. Weather → reminder

**Voice command**:
> "Check the weather forecast for Milan tomorrow and remind me to bring an umbrella if it rains"

**Expected**:
- Router: `delegate_cloud`, capabilities=[browser, web_search]
- Claude Code fetches forecast → returns "Rain expected in Milan tomorrow, 70% probability"
- 2-turn callback → set_reminder slot.taskText="Bring umbrella" body=summary
- Reminders app entry created
- Latency target: 25-50s

**Note**: simpler variant uses native `weather` tool directly → user manually decides. Multi-step variant tests conditional reasoning.

### 3. News → email draft

**Voice command**:
> "Search for latest WWDC announcements and draft an email summarizing them"

**Expected**:
- Router: `delegate_cloud`, capabilities=[browser, web_search]
- Claude Code fetches recent WWDC news → returns 3-bullet summary
- 2-turn callback → send_message slot.body=summary (email composer opens with mailto://)
- User picks recipient + sends
- Latency target: 30-60s

### 4. Recipe → reminder ingredients

**Voice command**:
> "Find a pasta carbonara recipe and remind me to buy the ingredients"

**Expected**:
- Router: `delegate_cloud`, capabilities=[browser]
- Claude Code finds recipe → returns ingredient list
- 2-turn callback → set_reminder taskText="Buy carbonara ingredients" body=list
- Latency target: 30-60s

### 5. Score → note

**Voice command**:
> "Check the latest Inter Milan score and save it to a note"

**Expected**:
- Router: `delegate_cloud`, capabilities=[browser, web_search]
- Claude Code fetches live score
- 2-turn callback → create_note with title="Inter Milan score" body=result
- Latency target: 25-45s

## Run table (fill on device)

| # | Scenario | Latency total (s) | TURN 1 latency | Path 2 dispatch | Note/reminder created? | Quality (1-5) | PASS / FAIL |
|---|---|---|---|---|---|---|---|
| 1 | Tesla → note |  |  |  |  |  |  |
| 2 | Weather → reminder |  |  |  |  |  |  |
| 3 | News → email |  |  |  |  |  |  |
| 4 | Recipe → reminder |  |  |  |  |  |  |
| 5 | Score → note |  |  |  |  |  |  |

## Pass criteria

- **4/5 scenarios** complete the full 2-turn flow successfully (one slow-network / Wikipedia 404 / etc. allowed)
- All latencies **<90s** (Claude Code subprocess + Path 2 dispatch + TTS)
- Note / reminder / email payload contains the research summary (not generic placeholder)
- Console.app log shows the callback trace:
  ```
  GIGI Router → delegate_cloud: prompt=... caps=[browser, web_search]
  GIGI ClaudeEvent thought: ...
  GIGI ClaudeEvent tool_use: mcp__harness-browser__browser_navigate
  GIGI Router: delegate_cloud done in XXXXms
  GIGI Router: 2-turn callback detected → create_note with summary len=N
  GIGI Router → native_tool[FM]: action=create_note latencyMs=...
  ```

## Failure modes to test

| # | Action | Expected behavior |
|---|---|---|
| F1 | Kill Ollama + Claude Code mid-Turn 1 | router catches, speaks error, no Path 2 callback |
| F2 | Send query without follow-up verb ("Search Wikipedia for X" only) | router → delegate_cloud → summary spoken, NO callback (correct: no follow-up keyword) |
| F3 | Network down | first Turn 1 fails, error spoken, NO callback |
| F4 | Cancel mid-Turn 1 (long-press cancel button) | subprocess SIGTERM, cancel event spoken |

## Decision

After running: `PASS / FAIL`:

> ___________________________________

## Known limitations (recorded for GATE 8)

1. **`create_note` UX** — Notes app doesn't accept URL scheme body. We copy to clipboard + open Notes; user must paste. Long-press paste works but adds friction. A Shortcuts-based `GIGI Create Note` shortcut could automate; documented as opt-in setup.
2. **Email draft UX** — uses `mailto:` URL scheme which opens Mail compose. Recipient is empty unless extracted upfront.
3. **2-turn detection is keyword-based** — verbs like "and X then Y" might not match. Could add a 16th `FoundationRouterDecision` field `followUpAction: String?` for Apple FM to pre-extract.
4. **Multi-step chain depth** — currently exactly 2 turns. 3+ chains (research → process → save → notify) need additional architecture.
