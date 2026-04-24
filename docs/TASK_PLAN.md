# TASK PLAN — Claude Bridge Integration

**Source plan**: `C:\Users\arman\Desktop\GIGI\docs\plans\claude-bridge-integration.md`
**Created**: 2026-04-24
**Owner**: Armando
**Scope**: iOS app (`02_GIGI_APP/GIGI/`) + harness wiring. Harness backend already exposes `POST /api/ios/agent/run` and `/ws/ios/stream` on port 7779 (fasi 10-18 complete).

## Overview

Wire Claude (via existing harness) as a second brain inside GIGI. Groq remains the primary router; a new `ask_claude` tool lets Groq delegate complex tasks to Claude. Claude thoughts stream inline into the chat as italic/grey bubbles (Option A). A Settings toggle lets the user force all requests through Claude. Reverse bridge (Claude pulling iPhone data at runtime) is deferred — Phase 1 pushes context upfront instead.

## Execution Rules

- **Build verification**: every Swift-editing task must be followed by a remote build via `ssh user297422@FF125.macincloud.com` (MacInCloud Mac) — see root `CLAUDE.md` for the filtered xcodebuild command.
- **Phase ordering**: Phase 1 → Phase 2 → (Phase 3 deferred). Do not start Phase 2 before Phase 1 test gate is green.
- **File paths**: all absolute, Windows style (the Mac build uses `scp` or `git pull` to receive changes).
- **USER CHECKPOINT** markers indicate moments that require Armando's visual/subjective approval before continuing.

---

## Phase 1 — MVP: Groq → Claude escalation automatica

_Estimated: 4-6 hours · Covers Steps 1-8 of the source plan · Goal: user says "analizza il mio calendario" → Groq calls `ask_claude` → Claude thoughts stream in chat → final TTS._

### P1.1 — Add `.thinking` and `.toolEvent` roles to conversation memory
- **Agent**: backend-dev (Swift data model, no UI)
- **Depends on**: none
- **Target file**: `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\GigiConversationMemory.swift`
- **Anchor**: line 7 (`enum Role { case user, gigi }`)
- **Changes**:
  - Extend `GigiMessage.Role` → `case user, gigi, thinking, toolEvent`
  - Add `func addThought(_ text: String)` — appends `GigiMessage(role: .thinking, text:)`
  - Add `func addToolEvent(name: String, status: String)` — appends `GigiMessage(role: .toolEvent, text: "\(name): \(status)")`, returns the index/id so status can be updated later
  - Add `func updateToolEvent(id:/index:, status: String)` to mutate an existing tool event bubble (needed for `tool_start` → `tool_result` transition)
- **Acceptance criteria**:
  - [ ] Role enum compiles with 4 cases
  - [ ] `addThought("hello")` appends a message readable via the existing memory getter
  - [ ] Codable/decodable stays intact for persistence (existing tests / JSONEncoder round-trip still works)
  - [ ] Build verify via `ssh user297422@FF125.macincloud.com "cd ~/GIGI/02_GIGI_APP && /usr/bin/xcodebuild -project GIGI.xcodeproj -scheme GIGI -configuration Debug -destination 'generic/platform=iOS' CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED' | head -40"` → BUILD SUCCEEDED
- **Estimate**: 30min

### P1.2 — Render `.thinking` and `.toolEvent` in MessageBubble
- **Agent**: frontend-dev
- **Depends on**: P1.1
- **Target file**: `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\ChatView.swift`
- **Anchor**: `private struct MessageBubble: View` at line 252
- **Changes**:
  - Add `case .thinking` branch in `MessageBubble.body`:
    ```
    HStack {
      Text("💭 \(message.text)")
        .font(.caption2).italic()
        .foregroundColor(.white.opacity(0.6))
      Spacer()
    }
    .padding(.horizontal, 20)
    ```
  - Add `case .toolEvent` branch: `HStack { Image(systemName: "gearshape.fill"); Text(message.text); Spacer() }` with same muted styling
  - Ensure `ChatView` auto-scroll (`ScrollViewReader.scrollTo(...id, anchor: .bottom)`) triggers on these new messages as well
- **Acceptance criteria**:
  - [ ] Preview/simulator renders a thinking message in italic grey with 💭 prefix
  - [ ] Tool event renders with gear icon
  - [ ] Scroll follows new thinking bubbles
  - [ ] USER CHECKPOINT: verify thought UI aesthetic OK (Armando reviews a screenshot)
  - [ ] Build verify via ssh user297422@FF125.macincloud.com → BUILD SUCCEEDED
- **Estimate**: 45min

### P1.3 — Create `GigiClaudeBridge.swift` coordinator (skeleton + context snapshot)
- **Agent**: backend-dev
- **Depends on**: P1.1
- **Target file** (NEW): `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\GigiClaudeBridge.swift`
- **Changes**:
  - `@MainActor final class GigiClaudeBridge` with `static let shared`
  - Properties: `private var stream: GigiHarnessStream?`, `private weak var memory: GigiConversationMemory?` (set by AgentEngine)
  - Stub method `func run(task: String, context: String?) async -> ToolResult` returning `.success("stub")` for now — real streaming handled in P1.4
  - Implement `private func buildContextSnapshot() async -> String` per Step 7 of source plan:
    - Load user profile via `GigiUserProfile.shared.load()` (name/email/preferences)
    - Call `ReadWeekCalendarTool().execute(args: [:])` → inline JSON of next 7 days
    - `GigiMemory.shared.recentMemories(limit: 10)` → key/value list
    - Optional: current location via existing `CLLocationManager` helper (skip if unauthorized — don't prompt here)
    - Format per Appendix B of source plan (USER SNAPSHOT / CALENDAR / RECENT MEMORIES / LOCATION headers), cap ~2000 tokens (~8KB) — truncate calendar first if over budget
- **Acceptance criteria**:
  - [ ] File compiles, singleton accessible from anywhere in the app
  - [ ] `buildContextSnapshot()` returns a non-empty string under 8KB in dev
  - [ ] No calls yet to harness (stub only) — ensures isolation
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 1h

### P1.4 — Wire `GigiClaudeBridge.run` to streaming harness + memory
- **Agent**: backend-dev
- **Depends on**: P1.3, P1.2
- **Target file**: `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\GigiClaudeBridge.swift`
- **Changes**:
  - Replace the stub body of `run(task:context:)`:
    1. Build `let snapshot = await buildContextSnapshot()`
    2. Compose `taskWithContext = "\(snapshot)\n\nTASK: \(task)\(context.map { "\n\nEXTRA: \($0)" } ?? "")"`
    3. If `stream == nil` — instantiate `GigiHarnessStream()` (same config as `GigiHarnessClient`), subscribe callback
    4. Callback handles `claude_event` payloads:
       - `type=thought` → `memory?.addThought(event.content)`
       - `type=tool_start` → store returned event-id, call `memory?.addToolEvent(name: event.tool, status: "running")`
       - `type=tool_result` → `memory?.updateToolEvent(id:, status: "done")`
       - `type=speech` / `type=done` → resume the suspended `async` call and return `ToolResult.success(finalText)`
    5. Invoke `GigiHarnessClient.shared.agentRun(text: taskWithContext, stream: true)` and await completion event
  - Map errors from `agentRun` to `ToolResult.failure(...)` per AC-5 of plan (notConfigured / transport / badResponse)
- **Acceptance criteria**:
  - [ ] When harness running, calling `GigiClaudeBridge.shared.run(task: "ciao", context: nil)` emits ≥1 `.thinking` bubble via memory
  - [ ] Final `.success` contains non-empty string
  - [ ] When harness unreachable: returns `.failure`, memory receives no `.thinking` messages, `isThinking` flag cleared
  - [ ] `SoundEngine.play(.error)` fires on failure (AC-5)
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 2h

### P1.5 — Register `AskClaudeTool` in `GigiToolRegistry`
- **Agent**: backend-dev
- **Depends on**: P1.4
- **Target file**: `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\GigiToolRegistry.swift`
- **Anchors**: `protocol GigiTool` at line 70 · `class GigiToolRegistry` around line 1102 · `let all: [any GigiTool] = [` at line 1105
- **Changes**:
  - Add `struct AskClaudeTool: GigiTool` (insert before `class GigiToolRegistry`):
    - `name = "ask_claude"`
    - `tags = ["analizza", "ricerca", "prenota", "trova", "computer", "deep", "complex"]`
    - `declaration = FunctionDeclaration(name: "ask_claude", description: "Delegate to Claude for complex reasoning, web research, computer-use browsing, analysis of large data", parameters: [task: String required, context: String?])`
    - `requiresConfirmation = false`
    - `execute(args:)` → extracts `task`, optional `context`, delegates to `await GigiClaudeBridge.shared.run(task:, context:)`, returns the `ToolResult`
  - Append `AskClaudeTool()` to the `all` array at line 1105+
- **Acceptance criteria**:
  - [ ] `GigiToolRegistry.shared.all.contains { $0.name == "ask_claude" }` is true
  - [ ] The tool's declaration JSON schema round-trips via the existing encoder used by `GigiCloudService`
  - [ ] Meta-classifier `selectRelevant(for:)` includes the tool for a prompt containing "analizza"
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 30min

### P1.6 — Intercept `ask_claude` in `GigiAgentEngine` execution loop
- **Agent**: backend-dev
- **Depends on**: P1.5
- **Target file**: `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\GigiAgentEngine.swift`
- **Anchor**: `private func agentLoop(` at line 85; function-call handling block (~lines 165-215 per source plan)
- **Changes**:
  - In `agentLoop`, before calling `executeParallel(response.functionCalls)`, partition calls: `let (claudeCalls, other) = response.functionCalls.partitioned { $0.name == "ask_claude" }`
  - Run `claudeCalls` sequentially via `await GigiClaudeBridge.shared.run(...)` (Claude stream is long; do NOT parallelise)
  - Run `other` via existing `executeParallel(other)`
  - Merge both result arrays into `toolResultTuples` preserving order expected by the next LLM turn
  - Wire `GigiClaudeBridge.shared.memory = self.memory` (or similar setter) during init / first use so bridge can append thoughts
- **Acceptance criteria**:
  - [ ] A Groq response with `functionCalls: [ask_claude]` triggers `GigiClaudeBridge.run`, no parallel execution
  - [ ] Mixed response `[ask_claude, make_call]` runs Claude then call, results threaded back into agent loop
  - [ ] `costEstimate` includes Claude result's `tokenEstimate`
  - [ ] No regression in non-Claude flow (existing parallel tool runs unchanged)
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 1h

### P1.7 — Update Groq prompt (`agentToolPrompt`) with `ask_claude` capabilities + heuristics
- **Agent**: backend-dev (prompt engineering)
- **Depends on**: P1.5
- **Target file**: `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\GigiFoundationAgent.swift`
- **Anchor**: `static let agentToolPrompt = """` at line 184
- **Changes**:
  - Add to the CAPABILITIES list:
    ```
    ask_claude       → Delegate to Claude for complex reasoning, web research,
                       computer-use browsing, analysis of large data.
                       Use when: user asks for analysis, research, booking,
                       or any task too complex for direct tool calls.
                       (task = full description of what Claude should do;
                        context = optional extra info)
    ```
  - Add DECISION HEURISTICS block:
    ```
    - If action fits a direct tool (make_call, navigate, homekit_*) → use that tool
    - If user asks "analyze", "find", "book", "research", "figure out" → ask_claude
    - If user asks multi-step task (>3 sub-tasks) → ask_claude
    ```
- **Acceptance criteria**:
  - [ ] 5 test prompts run locally (without executing the tool) show Groq selects `ask_claude` for "analizza", "trova slot", "prenotami"; selects native tools for "chiama mamma", "che ora è"
  - [ ] No prompt token blowup (stay within existing budget)
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 45min

### P1.8 — Sanity-check WebSocket URL build for streaming
- **Agent**: qa-tester
- **Depends on**: P1.4
- **Target file (read-only)**: `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\GigiHarnessClient.swift`
- **Anchor**: `makeWebSocketURL()` around line 356 (inside `GigiHarnessStream`)
- **Checks**:
  - Confirm that with `baseURL = http://192.168.1.67:7779` → resulting WS URL is `ws://192.168.1.67:7779/ws/ios/stream?deviceId=...&token=...`
  - Confirm that HTTPS base → WSS (scheme swap logic exists)
  - Manual test: start harness, connect stream without running a task → server logs `ws connected`, no 4xx
- **Acceptance criteria**:
  - [ ] Confirmed WS URL shape matches harness expectations (see `03_HARNESS/server/api/ios-stream.js`)
  - [ ] Bug report filed if mismatch found, routed to debugger agent
- **Estimate**: 30min

### P1.9 — Error-path UX polish (AC-5 messages)
- **Agent**: frontend-dev
- **Depends on**: P1.4
- **Target file**: `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\GigiClaudeBridge.swift`
- **Changes**:
  - Ensure error `ToolResult.failure` messages user-visible match AC-5 verbatim:
    - `.notConfigured` → "Configura URL+secret in Settings → Harness"
    - `.transport` → "Harness irraggiungibile. Verifica che il server sia acceso"
    - `.badResponse(status)` → "Harness errore HTTP \(status)"
  - Also ensure `SoundEngine.play(.error)` and `isThinking = false` are called before return
- **Acceptance criteria**:
  - [ ] Simulating each error path (harness down, wrong secret, 500 response) shows the exact Italian message as a chat message
  - [ ] Error earcon plays
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 30min

### P1.10 — Phase 1 Test Gate (manual E2E)
- **Agent**: qa-tester
- **Depends on**: P1.1 through P1.9
- **Environment**: harness running locally on `192.168.1.67:7779`, iPhone paired, secret configured in Settings → Harness → status green
- **Test matrix** (from source plan "Verification Steps"):
  - [ ] "Ciao GIGI, come stai?" → pure Groq, zero escalation, no `.thinking` bubbles
  - [ ] "Chiama mamma" → `make_call` local tool, zero escalation
  - [ ] "Analizza il mio calendario della settimana e trovami slot per sport" → escalation → ≥ 3 `.thinking` bubbles visible → final answer < 60s → TTS reads only the final answer (no thought narration)
  - [ ] "Prenotami un tavolo a Nobu per domani alle 20" → escalation → if computer-use configured → Playwright runs; otherwise Claude returns reasoned plan
  - [ ] Kill harness (Ctrl-C on Mac), repeat calendar query → "Harness non raggiungibile" message + error earcon
  - [ ] Restart harness, retry → works again
  - [ ] Wake-word voice flow with calendar query → mic re-arms only AFTER final answer, not during thoughts
- **Gate outcome**: PASS → unlock Phase 2 · FAIL → return to specific task ID with bug report to debugger agent
- **USER CHECKPOINT**: Armando signs off on thought-UI rhythm and final answer quality
- **Estimate**: 1h

---

## Phase 2 — Force Claude toggle

_Estimated: 1-2 hours · Covers Steps 9-11 of the source plan · Goal: Settings toggle bypasses Groq entirely._

### P2.1 — Add Keychain keys for Brain Mode
- **Agent**: backend-dev
- **Depends on**: P1.10 (Phase 1 gate green)
- **Target file**: `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\GigiKeychain.swift`
- **Anchor**: `enum Key` at line 67
- **Changes**:
  - Add `case forceClaude` and `case claudeAutoFallback` to the `Key` enum
  - Provide `static func loadBool(_ key: Key) -> Bool` helper if not already present (read "1"/"0" string)
- **Acceptance criteria**:
  - [ ] `GigiKeychain.save(.forceClaude, "1")` + `loadBool(.forceClaude) == true`
  - [ ] Fresh install → both keys return `false`
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 20min

### P2.2 — Add Brain Mode section to SettingsView
- **Agent**: frontend-dev
- **Depends on**: P2.1
- **Target file**: `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\SettingsView.swift`
- **Anchor**: `private var harnessSection` at line 124, `harnessSection` call at line 35 — insert a new section after it
- **Changes**:
  - Add `@State private var forceClaude = GigiKeychain.loadBool(.forceClaude)`
  - Add `@State private var autoFallback = GigiKeychain.loadBool(.claudeAutoFallback)`
  - Add `private var brainModeSection: some View` with two toggles:
    - "Force Claude for all requests" (bound to `$forceClaude`, `.onChange` → save to Keychain)
    - "Auto-fallback to Groq if Claude fails" (bound to `$autoFallback`, `.onChange` → save, default OFF)
  - Header: "🧠 Brain Mode"
  - Mount `brainModeSection` in the `body` right after `harnessSection` at line 35
- **Acceptance criteria**:
  - [ ] Section visible in Settings under "🧠 Brain Mode"
  - [ ] Toggling either switch persists across app relaunch
  - [ ] USER CHECKPOINT: verify wording/placement OK
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 30min

### P2.3 — Bypass Groq when Force Claude is on
- **Agent**: backend-dev
- **Depends on**: P2.2
- **Target file**: `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\GigiAgentEngine.swift`
- **Anchor**: top of `process(text:)` (~line 57 per source plan)
- **Changes**:
  - At function entry:
    ```
    if GigiKeychain.loadBool(.forceClaude) {
      let result = await GigiClaudeBridge.shared.run(task: text, context: nil)
      return AgentResult(speech: result.value ?? "", executedTools: ["ask_claude"], isFollowUp: false, costEstimate: 0, requiresConfirm: nil)
    }
    ```
  - If `result` is `.failure` and `claudeAutoFallback == true` → continue to the normal Groq flow below (log fallback)
  - If `result` is `.failure` and `autoFallback == false` → return `AgentResult(speech: errorMessage, ...)` directly (no Groq call)
- **Acceptance criteria**:
  - [ ] With toggle ON + harness reachable → "Che ora è?" goes through Claude (logs confirm `agentRun` called, no Groq call)
  - [ ] With toggle ON + harness down + autoFallback OFF → error message shown, no Groq call
  - [ ] With toggle ON + harness down + autoFallback ON → Groq responds normally
  - [ ] With toggle OFF → behaves exactly like Phase 1
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 40min

### P2.4 — Phase 2 Test Gate
- **Agent**: qa-tester
- **Depends on**: P2.1, P2.2, P2.3
- **Test matrix** (from source plan):
  - [ ] Settings → Brain Mode → activate Force Claude → "Che ora è?" → goes directly to Claude (chat shows thoughts, takes longer)
  - [ ] Deactivate → same query → Groq responds immediately via `ask_time` tool
  - [ ] Force Claude ON + harness off + autoFallback OFF → clear error in chat
  - [ ] Force Claude ON + harness off + autoFallback ON → Groq responds silently (maybe log line only)
- **Gate outcome**: PASS → Phase 2 complete, Phase 3 remains deferred · FAIL → return to P2.x
- **Estimate**: 30min

---

## Phase 3 — Reverse Bridge (DEFERRED)

_Source plan Steps 12-14. **Not decomposed into tasks.** Rationale from source plan: "Phase 3 is deferrable — with Phase 1 context push, Claude already has sufficient data for most tasks. Re-evaluate after 2-4 weeks of usage."_

Placeholder scope for future decomposition:
- WebSocket protocol `iphone_query` / `iphone_query_result`
- iOS handler `GigiReverseBridge.swift` (NEW file)
- Harness MCP tools `ios_contacts_find`, `ios_calendar_query`, `ios_memory_query`, `ios_location_current`, `ios_homekit_list`

**Trigger to un-defer**: when Phase 1-2 show Claude asking the user for data it should have access to, in ≥ 20% of escalations.

---

## Test Gates

| Gate | Agent | Blocks | Criteria |
|---|---|---|---|
| **P1.10** — Phase 1 E2E | qa-tester | Phase 2 start | All 6 scenarios pass in source plan §Verification Steps |
| **P2.4** — Phase 2 E2E | qa-tester | Phase 3 (if un-deferred) | Force Claude toggle behaves per AC-3 |

---

## Parallel Opportunities

These task pairs have no direct dependency and can run in parallel if two agents are available:

- **P1.2** (frontend rendering) ∥ **P1.3** (bridge skeleton) — both only depend on P1.1
- **P1.5** (tool registry) ∥ **P1.7** (prompt update) — independent files, both depend on P1.4 only loosely (P1.7 can even start right after P1.1 if prompt wording doesn't rely on bridge shape)
- **P1.8** (WS URL sanity) ∥ **P1.9** (error polish) — both post-P1.4, independent
- **P2.1** (keychain) ∥ (nothing else in Phase 2 — P2.2 depends on P2.1)

No cross-phase parallelism: P2.x must wait for P1.10 gate.

---

## Next Action

**TASK P1.1 — Add `.thinking` and `.toolEvent` roles to conversation memory**
- **Agent**: backend-dev
- **Why first**: zero dependencies, foundational for every subsequent UI/bridge task, 30 min scope. Blocks P1.2 (UI rendering) and P1.3 (bridge skeleton). Once P1.1 is green on the remote Mac build, the two parallel tracks (UI in P1.2 + bridge in P1.3) can start simultaneously.
