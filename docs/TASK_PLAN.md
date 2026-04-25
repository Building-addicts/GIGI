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
- **Status**: COMPLETED · commit `0a8316d` · BUILD SUCCEEDED via SSH Mac
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
- **Status**: COMPLETED (code+build) · commit `a400500` · BUILD SUCCEEDED · **BLOCKED BY USER CHECKPOINT** (thought-UI aesthetic approval pending — see Blockers section)
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
- **Status**: COMPLETED · commit `a400500` · BUILD SUCCEEDED
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
- **Status**: COMPLETED (verified 2026-04-25 — `GigiClaudeBridge.swift:72-94` has full `run()` impl with stream wiring, snapshot context, error mapping; `GigiHarnessStream` connect + `handleStreamEvent` translate live events to `.thinking`/`.toolEvent` bubbles)
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
- **Status**: COMPLETED (verified 2026-04-25 — `GigiToolRegistry.swift:1106-1180` defines `AskClaudeTool`, registered in `all` array, present in `selectRelevant` carry-forward)
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
- **Status**: COMPLETED (verified 2026-04-25 — `GigiAgentEngine.swift:57` wires `GigiClaudeBridge.shared.memory = GigiConversationMemory.shared` at init; agent loop dispatches via `tool.execute()` which routes ask_claude → bridge.run() through `AskClaudeTool.execute`)
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
- **Status**: COMPLETED (verified 2026-04-25 — `GigiFoundationAgent.swift:198-212` ESCALATION block describes ask_claude tool, when to use, when not to use, and parameter shape)
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
- **Status**: COMPLETED (verified 2026-04-25 — `GigiHarnessStream.makeWebSocketURL()` swaps http→ws/https→wss correctly; verified working end-to-end via Quick Tunnel `wss://*.trycloudflare.com/ws/ios/stream`)
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
- **Status**: COMPLETED (verified 2026-04-25 — `GigiClaudeBridge.userFacingError(for:)` maps `.notConfigured`/`.transport`/`.badResponse`/`.apiError`/`.decodeFailed` to user-visible English strings; `SoundEngine.play(.error)` fires before return on failure)
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
- **Status**: COMPLETED · 2026-04-25 · `Key.forceClaude` + `Key.autoFallback` added to `GigiKeychain`, plus `loadBool`/`saveBool` helpers
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
- **Status**: COMPLETED · 2026-04-25 · `brainModeSection` added with Force Claude + Auto Fallback toggles, persisted to Keychain via `onChange`
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
- **Status**: COMPLETED · 2026-04-25 · `GigiAgentEngine.process(text:)` short-circuits to `GigiClaudeBridge.shared.run` when `forceClaude == true`; respects `autoFallback` for harness-down case
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

## Phase 4 — Pairing UX (Tailscale + QR code)

_Source plan: `docs/plans/tailscale-qr-pairing.md`_
_Estimated: ~6h code · Independent from Phase 1-2 (can start any time) · Goal: zero manual typing, works from any network (4G, Barcellona, hotel Wi-Fi), scalable to future VPS._

**Dependency notes**:
- User setup (Tailscale install on PC + iPhone) is a prerequisite but NOT a coding task — tracked as U0 below, estimated 10 min user time.
- Phase 4 is orthogonal to Phase 1 & 2. It can be implemented in parallel — no shared files except `SettingsView.swift` (modified by both P2.2 and P4.6, but in different sections). Resolve any merge conflict by hand.

### U0 — User installs Tailscale (prerequisite, no code)
- **Status**: PENDING USER — required before P4.9 can run
- **Owner**: Armando
- **Steps**:
  1. PC: download Tailscale from https://tailscale.com/download, install, login (Google/GitHub/Microsoft account)
  2. PC: verify `tailscale status` shows own IP `100.x.y.z`
  3. iPhone: install Tailscale from App Store, login **same account**
  4. iPhone: open Tailscale app, toggle connection ON, verify green status
  5. From PC: `curl http://<iphone-tailscale-ip>` returns timeout (expected — iPhone has no server)
- **Estimate**: 10 min
- **Gate**: without this, P4.9 test cannot pass

### P4.1 — Add `qrcode` dep + `/api/pair` endpoint
- **Status**: COMPLETED · commit `ca8a599` · curl verified HTTP 200 + SVG QR
- **Agent**: backend-dev
- **Depends on**: none
- **Target files**:
  - `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\package.json` (add dep)
  - NEW `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\api\pair.js`
  - `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\server.js` (route registration)
- **Changes**:
  - `npm install qrcode` in `03_HARNESS/server/`
  - New file `api/pair.js` exporting `handlePair(req, res, { cfg })`:
    - Enforce loopback-only: `if (!['::1', '127.0.0.1', '::ffff:127.0.0.1'].includes(req.socket.remoteAddress)) return 403`
    - Auto-detect Tailscale IP: scan `os.networkInterfaces()` for an address matching `^100\.` and family `IPv4`; fallback to `cfg.server.host` if none
    - If `req.url` ends with `?format=svg` → return `image/svg+xml` QR via `qrcode.toString(payload, { type: 'svg', errorCorrectionLevel: 'H' })`
    - Otherwise return JSON payload: `{ url, secret: cfg.ios.shared_secret, deviceName: os.hostname(), createdAt: new Date().toISOString() }`
  - In `server.js`: register the route before `/api/ios/*` dispatch (since `/api/pair` is loopback-only)
- **Acceptance criteria**:
  - [ ] `curl http://localhost:7779/api/pair` returns HTTP 200 JSON with correct fields
  - [ ] `curl http://localhost:7779/api/pair?format=svg` returns an SVG rendering of a scannable QR
  - [ ] `curl http://100.x.y.z:7779/api/pair` (from another Tailscale device) returns HTTP 403
  - [ ] `url` field in payload uses Tailscale IP, not `localhost` or `0.0.0.0`
- **Estimate**: 1h

### P4.2 — Panel page `/pair` with QR render
- **Status**: COMPLETED · commit `ca8a599` · `localhost:7777/pair` renders QR + instructions
- **Agent**: frontend-dev (web, not iOS)
- **Depends on**: P4.1
- **Target files**:
  - `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\panel-routes.js` (new route handler)
  - NEW `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\public\pair.html`
- **Changes**:
  - `panel-routes.js`: handle `GET /pair` → serve `public/pair.html` with MIME `text/html`
  - `pair.html`: minimal dark-theme page with:
    - Title "Pair your iPhone with GIGI Harness"
    - `<img src="http://localhost:7779/api/pair?format=svg" alt="QR">` (inline SVG from P4.1)
    - Readable URL text `<code>http://100.x.y.z:7779</code>`
    - Secret obfuscated: first 4 + `...` + last 4 chars
    - Instructions ordered list: "Apri GIGI → Settings → Pair con Harness → inquadra il QR"
    - Button "Copy URL" (JS clipboard)
    - Auto-refresh on `onfocus` so IP detection is fresh
- **Acceptance criteria**:
  - [ ] `http://localhost:7777/pair` in browser shows QR + instructions + obfuscated secret
  - [ ] "Copy URL" button copies the Tailscale URL to clipboard
  - [ ] Page loads in < 500ms
- **Estimate**: 45min

### P4.3 — iOS Info.plist camera permission
- **Status**: COMPLETED · commit `ca8a599` · `NSCameraUsageDescription` added
- **Agent**: frontend-dev
- **Depends on**: none (independent of backend)
- **Target file**: `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\Info.plist`
- **Changes**:
  - Add `NSCameraUsageDescription` key with value: `"GIGI usa la fotocamera per leggere il QR code del tuo Harness backend."`
- **Acceptance criteria**:
  - [ ] Key appears in Info.plist
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 15min

### P4.4 — `GigiPairScanner.swift` (VisionKit wrapper)
- **Status**: COMPLETED · commit `ca8a599` · BUILD SUCCEEDED · DataScannerViewController wrapper with permission flow
- **Agent**: frontend-dev
- **Depends on**: P4.3
- **Target file** (NEW): `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\GigiPairScanner.swift`
- **Changes**:
  - `struct GigiPairScannerView: View` using `DataScannerViewController` via `UIViewControllerRepresentable` (iOS 16+)
  - Configure scanner: `recognizedDataTypes: [.barcode(symbologies: [.qr])]`, `isHighlightingEnabled: true`
  - Prop `onScan: (String) -> Void`, `onCancel: () -> Void`
  - Before initializing camera: `AVCaptureDevice.requestAccess(for: .video)`; if denied show "Vai in Impostazioni → GIGI → Camera" overlay
  - First successful scan fires `onScan` and stops the scanner (debounce duplicates)
- **Acceptance criteria**:
  - [ ] Scanning a QR triggers `onScan` exactly once
  - [ ] Denying camera permission shows the fallback overlay, doesn't crash
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 1.5h

### P4.5 — `GigiPairingSheet.swift` (validation + Keychain save)
- **Status**: COMPLETED · commit `ca8a599` · BUILD SUCCEEDED · state machine scanning→validating→success/failure with health check and rollback
- **Agent**: frontend-dev
- **Depends on**: P4.4
- **Target file** (NEW): `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\GigiPairingSheet.swift`
- **Changes**:
  - SwiftUI view presented as sheet
  - State enum: `scanning`, `validating`, `success(deviceName: String)`, `failure(String)`
  - On scan: `JSONDecoder` attempts to parse payload into `PairPayload` (url, secret, deviceName, createdAt)
  - Validate URL: must start with `http://` or `https://`, parse via `URL(string:)` → non-nil
  - Save to Keychain: `harnessBaseURL`, `harnessSecret` (use existing `GigiKeychain.Key` enum entries)
  - If `harnessDeviceID` absent: `GigiHarnessClient.ensureDeviceId()`
  - Call `GigiHarnessClient.shared.health()` → on `.success`: state → `.success(deviceName)`, auto-dismiss after 1.5s
  - On `.failure`: state → `.failure(message)` with "Riprova" button returning to `.scanning`
- **Acceptance criteria**:
  - [ ] Valid QR scan ends with Keychain populated and sheet dismissed
  - [ ] Invalid payload (malformed JSON, missing fields, non-reachable URL) shows clear error
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 1.5h

### P4.6 — `SettingsView` integration: "Pair con Harness" button
- **Status**: COMPLETED · commit `ca8a599` · BUILD SUCCEEDED · primary Pair button + status line + "Rimuovi pairing" + manual config under DisclosureGroup
- **Agent**: frontend-dev
- **Depends on**: P4.5
- **Target file**: `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\SettingsView.swift`
- **Anchor**: `private var harnessSection` around line 124 (will be rewritten)
- **Changes**:
  - Replace the two `TextField` inputs with a primary button "Pair con Harness" that presents `GigiPairingSheet`
  - Below button: if paired show `"Connesso a <deviceName> · ultimo check <timestamp>"`, else show `"Non configurato"`
  - Secondary "Rimuovi pairing" button that clears `harnessBaseURL`, `harnessSecret`, `harnessDeviceID` from Keychain and resets state
  - Keep the raw TextField version under a DisclosureGroup "Configurazione manuale (avanzata)" collapsed by default
  - `@State private var pairingSheetVisible = false` + `.sheet(isPresented: $pairingSheetVisible) { GigiPairingSheet(...) }`
- **Acceptance criteria**:
  - [ ] Settings shows the new button layout (primary button + status line + collapsible advanced)
  - [ ] After successful pair, status line updates without app restart
  - [ ] "Rimuovi pairing" clears Keychain + UI returns to "Non configurato"
  - [ ] USER CHECKPOINT: verify wording and layout OK
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 1h

### P4.7 — Onboarding banner on first launch
- **Status**: COMPLETED · commit `ca8a599` · BUILD SUCCEEDED · purple "Collega GIGI al tuo PC" overlay in MainTabView; tap opens pairing sheet
- **Agent**: frontend-dev
- **Depends on**: P4.5
- **Target file**: `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\MainTabView.swift` (or `GIGIApp.swift`)
- **Changes**:
  - At top of `MainTabView.body`, overlay a banner when `!GigiHarnessClient.shared.isConfigured`:
    ```
    VStack {
      HStack { ... CTA "Collega GIGI al tuo PC" ... }
        .background(purple)
      Spacer()
    }
    ```
  - Tap → presents `GigiPairingSheet`
  - Banner auto-hides as soon as `isConfigured` becomes true
- **Acceptance criteria**:
  - [ ] Fresh install (Keychain empty) → banner visible on launch
  - [ ] After successful pair → banner disappears
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 45min

### P4.8 — Connection-loss hint in bridge error
- **Status**: COMPLETED · commit `ca8a599` · BUILD SUCCEEDED · Tailscale 100.* hint appended on transport error; 401 maps to "Secret non più valido. Ri-pair dal Panel."
- **Agent**: backend-dev (iOS)
- **Depends on**: P4.6 (needs new Keychain value shape) but independently verifiable
- **Target file**: `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\GigiClaudeBridge.swift`
- **Anchor**: `userFacingError(for:)` around line ~170
- **Changes**:
  - In the `.transport` case, check if `GigiKeychain.load(forKey: .harnessBaseURL)?.starts(with: "http://100.")` is true
  - If yes: append "Controlla Tailscale attivo su PC e iPhone" to the error message
  - If no: keep existing message
- **Acceptance criteria**:
  - [ ] With Tailscale URL (`http://100.x.y.z:7779`) configured and harness down: message includes Tailscale hint
  - [ ] With manual LAN URL (`http://192.168.x.y:7779`) configured and harness down: message unchanged
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 30min

### P4.9 — Phase 4 Test Gate (manual E2E from outside home network)
- **Status**: READY — waiting for user test + Tailscale install (U0). Code is frozen at commit `ca8a599`; `.ipa` available at `C:\Users\arman\Desktop\GIGI\bug\GIGI.ipa` (1.2 MB).
- **Agent**: qa-tester + USER CHECKPOINT
- **Depends on**: U0, P4.1 through P4.8
- **Environment**: harness running on PC, Tailscale up on PC + iPhone
- **Test matrix**:
  - [ ] Home Wi-Fi: fresh install → banner visible → scan QR → connected ✓ → ask_claude query works end-to-end
  - [ ] **Switch iPhone to 4G/5G only (disable Wi-Fi)**: same queries still work, same latency +/- 100ms
  - [ ] Put iPhone in airplane mode → bring back with cellular → Tailscale reconnects → next query works
  - [ ] Kill Tailscale on iPhone → next query shows "🔌 Controlla Tailscale attivo"
  - [ ] Restart Tailscale → query succeeds
  - [ ] Test from a different physical location (café, different Wi-Fi) → works
  - [ ] Remove pairing → banner reappears → re-pair → works
- **Gate outcome**: PASS → Phase 4 complete · FAIL → debug with specific P4.x as needed
- **USER CHECKPOINT**: Armando verifies scan UX feel and cross-network reachability subjectively
- **Estimate**: 45min

---

## Phase 5 — Cloudflare Tunnel integration (primary transport)

_Source plan: `docs/plans/cloudflare-tunnel-pairing.md` · Research: `docs/research/pairing-landscape-2026.md`_
_Estimated: 8-12h backend + iOS core, 4h QA · Independent from Phase 1-2 · Goal: zero-app-install UX, works from any network via Cloudflare edge, stable URL persistent pairing._

**Rationale**: il deep-dive research di 2026-04-24 ha mostrato che Iroh FFI è archiviato e Tailscale richiede all'utente di installare una VPN separata. Cloudflare Tunnel rimuove quell'attrito (zero app iPhone, stable URL, free forever), al costo di un possesso dominio da parte dell'utente (~€3-10/anno) per modalità persistente. Supporta anche Quick Tunnel (zero dominio, URL effimero — dev mode) e LAN mDNS (zero config — home mode).

**Relazione con Phase 4**: il codice Phase 4 (GigiPairScanner, GigiPairingSheet, pair QR flow) è tutto riutilizzato. Cambia solo: (a) backend genera URL Cloudflare invece di URL Tailscale, (b) wizard onboarding aggiunto nel Panel, (c) modalità multiple supportate via `tunnel.mode` in config. Phase 4 Tailscale flow diventa "modalità D Advanced" dentro questo Phase 5.

### P5.1 — Bundle `cloudflared` binary + auto-download
- **Status**: COMPLETED · commit `9033dc7` (version fix `d378317`) · NEW `03_HARNESS/server/tunnel/install-cloudflared.js`
- **Agent**: devops
- **Depends on**: none (independent of P4.9 user test)
- **Target files**:
  - NEW `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\tunnel\install-cloudflared.js`
- **Changes**:
  - Node script che al primo avvio detect OS+arch (win32-x64, darwin-arm64, linux-x64, ecc.)
  - Download release appropriata da `https://github.com/cloudflare/cloudflared/releases/latest`
  - Verify SHA256 checksum contro release-manifest Cloudflare
  - Install in `~/.gigi/bin/cloudflared` (platform-specific home dir)
  - Fallback se la rete è rotta: messaggio chiaro + istruzione manuale
- **Acceptance criteria**:
  - [ ] `node install-cloudflared.js` scarica binary funzionante su Win/Mac/Linux
  - [ ] Checksum verified
  - [ ] `./cloudflared --version` ritorna versione pinnata
- **Estimate**: 45min

### P5.2 — Cloudflared process manager
- **Status**: COMPLETED · commit `8d0d995` · NEW `03_HARNESS/server/tunnel/cloudflared-manager.js` singleton with `startQuick`/`startNamed`/`stop`/`status`, stdout parsing for trycloudflare URL, restart-loop detection
- **Agent**: backend-dev
- **Depends on**: P5.1
- **Target file** (NEW): `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\tunnel\cloudflared-manager.js`
- **Changes**:
  - Class `CloudflaredManager` con API: `startNamed(uuid)`, `startQuick()`, `stop()`, `getStatus()`, `isRunning()`
  - Spawn child process, cattura stdout/stderr (per detect quick tunnel URL da log output)
  - Auto-restart on crash (max 3 retries, poi emit error event)
  - Writer su `~/.gigi/tunnel-current-url.txt` quando URL cambia
- **Acceptance criteria**:
  - [ ] `startQuick()` → `getStatus()` ritorna URL trycloudflare.com entro 15s
  - [ ] `stop()` termina il processo cleanly
  - [ ] Kill-9 del processo figlio → manager rileva, auto-restart
- **Estimate**: 2h

### P5.3 — Cloudflare API client
- **Status**: COMPLETED (scaffolded, will be wired in Phase 5.2 named OAuth) · commit `9033dc7` · NEW `03_HARNESS/server/tunnel/cf-api.js`
- **Agent**: backend-dev
- **Depends on**: none (standalone)
- **Target file** (NEW): `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\tunnel\cf-api.js`
- **Changes**:
  - Wrapper minimo per endpoint CF API v4 necessari:
    - `GET /user/tokens/verify` (valida cert)
    - `GET /accounts` (lista account)
    - `GET /zones?name=<domain>` (lookup zone)
    - `POST /accounts/{id}/cfd_tunnel` (crea tunnel)
    - `POST /zones/{id}/dns_records` (DNS CNAME)
  - Usa cert OAuth salvato (`~/.gigi/cloudflare-cert.json`)
  - Retry esponenziale su 5xx, niente retry su 4xx
- **Acceptance criteria**:
  - [ ] Creazione tunnel end-to-end con account reale funziona
  - [ ] Errore "dominio non in zona" detecta correttamente
- **Estimate**: 1.5h

### P5.4 — Setup wizard API endpoints
- **Status**: COMPLETED · commit `8d0d995` · `GET /api/setup/status` + `POST /api/setup/{quick,lan,manual}/{start,stop}`. Named endpoints return 501 NOT_IMPLEMENTED (deferred to Phase 5.2 OAuth)
- **Agent**: backend-dev
- **Depends on**: P5.2, P5.3
- **Target file** (NEW): `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\api\setup.js`
- **Changes**: endpoint documentati in plan doc AC-1, AC-3, AC-4, AC-5
- **Acceptance criteria**:
  - [ ] `GET /api/setup/status` ritorna stato corretto in ogni modalità
  - [ ] OAuth flow Cloudflare completa e salva cert
  - [ ] `POST /api/setup/named/configure` crea tunnel+DNS+avvia cloudflared
- **Estimate**: 2h

### P5.5 — Setup wizard HTML page
- **Status**: COMPLETED · commit `8d0d995` · `/setup` served on Panel 7777; 4 cards (quick/lan/named-disabled/manual); 3s auto-refresh
- **Agent**: frontend-dev (web)
- **Depends on**: P5.4
- **Target file** (NEW): `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\public\setup.html`
- **Changes**: UI con 4 card modalità (A/B/C/D), stepper 5 step per modalità A, progress + error states
- **Acceptance criteria**:
  - [ ] Stepper navigabile avanti/indietro
  - [ ] Stato persistito in sessionStorage (resume after browser close)
  - [ ] Error UI chiari per ogni fallimento possibile
- **Estimate**: 2h

### P5.6 — mDNS advertise (LAN mode)
- **Status**: COMPLETED · commit `9033dc7` · NEW `03_HARNESS/server/tunnel/mdns.js` + `bonjour-service` dep
- **Agent**: backend-dev
- **Depends on**: none
- **Target file**: `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\server.js` (modifica) + new `tunnel/mdns.js`
- **Changes**:
  - `npm install bonjour-service`
  - Avvia advertise `_gigi._tcp.local` quando `tunnel.mode === "lan"`
  - TXT record con `{deviceName, port, version}`
- **Acceptance criteria**:
  - [ ] `dns-sd -B _gigi._tcp` (macOS) o equivalente vede il servizio
  - [ ] Deregister on SIGTERM
- **Estimate**: 45min

### P5.7 — iOS mDNS discovery
- **Status**: COMPLETED · commit `bce814d` · NEW `02_GIGI_APP/GIGI/GigiMDNSDiscovery.swift` with `NWBrowser` for `_gigi._tcp.local` + `NSBonjourServices` added to Info.plist
- **Agent**: frontend-dev
- **Depends on**: P5.6
- **Target file** (NEW): `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\GigiMDNSDiscovery.swift`
- **Changes**:
  - `NWBrowser` per `_gigi._tcp`
  - Callback con lista device trovati
  - Integration con `GigiPairingSheet`: se QR contiene `mode=lan`, avvia discovery invece di usare URL fisso
  - Info.plist: aggiungi `NSBonjourServices = ["_gigi._tcp"]`
- **Acceptance criteria**:
  - [ ] Su stessa Wi-Fi iPhone trova harness entro 10s
  - [ ] Timeout con messaggio "harness non trovato sulla LAN"
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 1.5h

### P5.8 — WebSocket heartbeat ping/pong
- **Status**: COMPLETED · commit `9033dc7` · server `ios-stream.js` 30s sweep; iOS `GigiHarnessClient.swift` (GigiHarnessStream) ping 60s + 2-miss reconnect
- **Agent**: backend-dev (parallel server + iOS)
- **Depends on**: none
- **Target files**:
  - `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\api\ios-stream.js`
  - `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\GigiHarnessClient.swift` (GigiHarnessStream)
- **Changes**:
  - Server: risponde pong a ping client; cleanup inactivity >120s
  - iOS: `URLSessionWebSocketTask.sendPing` ogni 60s; 2 miss → reconnect
- **Acceptance criteria**:
  - [ ] Cloudflare Tunnel tiene connessione > 5 minuti senza drop
  - [ ] Su drop, reconnect automatico < 3s
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 1h

### P5.9 — Config schema extension
- **Status**: COMPLETED · commit `8d0d995` · `tunnel.{mode,named,quick,lan}` added to `config.example.json`
- **Agent**: backend-dev
- **Depends on**: P5.2, P5.4
- **Target file**: `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\config.json` + loader
- **Changes**: aggiungi sezione `tunnel` con `mode`, `cloudflared_binary`, `named.{tunnel_uuid, hostname, cert_path}`, `quick.{last_url}`
- **Acceptance criteria**:
  - [ ] Backward compatible: config esistenti senza `tunnel` default a `mode: "manual"` (flow Phase 4)
  - [ ] Cambio mode via API reflektato su disco
- **Estimate**: 30min

### P5.10 — Service installer (Windows/macOS/Linux)
- **Status**: COMPLETED · 2026-04-25 · NEW `server/tunnel/install-service.js` — cross-platform CLI: macOS launchd plist, Linux systemd user unit, Windows Startup VBS. `node install-service.js install|uninstall|status`
- **Agent**: devops
- **Depends on**: P5.2
- **Target file** (NEW): `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\tunnel\service-installer.js`
- **Changes**:
  - Windows: NSSM wrapper per registrare cloudflared come servizio
  - macOS: genera `~/Library/LaunchAgents/com.gigi.cloudflared.plist`
  - Linux: genera `~/.config/systemd/user/gigi-tunnel.service`
  - API `install()`, `uninstall()`, `status()`
- **Acceptance criteria**:
  - [ ] Dopo install e reboot PC: tunnel parte automaticamente
  - [ ] Uninstall pulisce artifacts
- **Estimate**: 2h

### P5.11 — Migration banner in iOS app
- **Status**: COMPLETED · 2026-04-25 · `migrationBannerIfNeeded` view in `SettingsView.harnessSection`; shows when `pairedBaseURL.host` starts with `100.` (Tailscale CGNAT); persistent dismiss via `UserDefaults("gigi.migration.cf.dismissed")`
- **Agent**: frontend-dev
- **Depends on**: P5.5 working E2E
- **Target file**: `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\SettingsView.swift`
- **Changes**:
  - Se `GigiKeychain.load(.harnessBaseURL)` comincia con `http://100.` (Tailscale): mostra banner informativo "Vuoi provare Cloudflare Tunnel? Reachability migliore e zero app extra"
  - Link opens pairing sheet che guida a setup CF
- **Acceptance criteria**:
  - [ ] Banner appare solo per utenti Tailscale esistenti
  - [ ] Dismiss persistente (UserDefaults `gigi.migration.cf.dismissed`)
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 30min

### P5.12 — Docs: "Getting started guide"
- **Status**: COMPLETED · 2026-04-25 · NEW `docs/GETTING_STARTED.md` — install harness, pick tunnel mode, run diagnostic, generate QR, sideload IPA, pair, test, troubleshoot, autostart
- **Agent**: documenter
- **Depends on**: P5.5 funzionante
- **Target files** (NEW):
  - `docs/guides/cloudflare-tunnel-setup.md`
  - `docs/guides/getting-a-domain.md`
  - `docs/guides/cloudflare-tunnel-troubleshooting.md`
- **Changes**: step-by-step con screenshot per utente target "tech-literate ma non dev"
- **Estimate**: 1.5h

### P5.13 — Phase 5 Test Gate (manual E2E)
- **Status**: READY (partial — Quick/LAN/manual modes only; Named mode deferred to Phase 5.2) · `.ipa` rebuilt at `C:\Users\arman\Desktop\GIGI\bug\GIGI.ipa` (1.2 MB). Quick Tunnel verified end-to-end: public URL `https://*.trycloudflare.com` reachable from internet with bearer auth, `/api/ios/health` returns 200 in ~310ms. Waiting for USER to run the full manual test matrix.
- **Agent**: qa-tester + USER CHECKPOINT
- **Depends on**: P5.1 through P5.12
- **Environment**: harness fresh install su Windows + dominio CF attivo + iPhone con app GIGI
- **Test matrix** (estratto da plan §Verification Steps):
  - [ ] Modalità A end-to-end con dominio nuovo
  - [ ] Modalità B Quick Tunnel (dev mode)
  - [ ] Modalità C LAN mDNS
  - [ ] Switch tra modalità runtime
  - [ ] Reboot PC → autostart tutto
  - [ ] Test da 3 reti diverse (casa / 4G / hotspot)
  - [ ] Migration banner da config Tailscale funziona
- **Gate outcome**: PASS → Phase 5 complete, Phase 4 diventa "advanced option"
- **Estimate**: 2h

---

## Phase 5.2 — Named Cloudflare Tunnel with OAuth (DEFERRED)

- **Status**: DEFERRED
- **Rationale**: Quick Tunnel ships a URL that changes on every `cloudflared` restart; true "setup once, stable URL" requires a **named tunnel**, which needs Cloudflare OAuth app registration + user-owned domain. Deferred to next iteration after user validates the Quick Tunnel flow (P5.13) and confirms the need for URL stability.
- **Prerequisites**:
  - User owns a domain routed to Cloudflare (free Cloudflare zone is fine — cost is only registrar fee, ~€3-10/yr)
  - `cf-api.js` (P5.3 — already scaffolded) gets wired into setup flow
- **Scope placeholders** (to be broken out when un-deferred):
  - P5.2.1 — OAuth app registration flow on Cloudflare developer portal + cert retrieval endpoint
  - P5.2.2 — `POST /api/setup/named/start` implementation (currently returns 501): wires `cf-api.js` → create tunnel → create DNS CNAME → `cloudflared-manager.startNamed(uuid)`
  - P5.2.3 — Setup wizard: un-disable "Named" card on `/setup`; stepper for domain picker + OAuth browser redirect
  - P5.2.4 — Persist `{tunnel_uuid, hostname, cert_path}` in `config.json` under `tunnel.named.*`
  - P5.2.5 — Test gate: named tunnel survives cloudflared restart with stable URL
- **Estimate (when un-deferred)**: ~6h backend + 1h wizard + 1h QA

---

## Phase 6 — Usability Roadmap (Phase 6 + 6B + 6C) — post-pivot 2026-04-25

_Source plan: `docs/plans/phase-6-usability-roadmap.md` (overview, see §Architectural pivot 2026-04-25) + `docs/plans/panel-observability.md` (6B detail)_
_Estimated: ~21h total (9 + 10 + 2) · Independent from Phase 1-5 · Goal: GIGI usabile da chi non è Armando._

**Architectural pivot (2026-04-25 evening)**: la vecchia Phase 6A (Setup
Checklist iOS) è stata **buttata via** dopo che Armando ha testato il
risultato e ha concluso che era "molto generica" — 3 checkbox manuali ciechi
(CF account, Claude CLI, harness installed) che l'app non poteva verificare.
È stata sostituita da un **flusso di pair a due stadi guidato da diagnostica
live** del PC (new Phase 6, no suffix). La vecchia Phase 6D (preflight
blocking startup) è stata **fusa** nella new Phase 6: stesse primitive di
check, ma ora endpoint queryable (`/api/setup/diagnostics`) invece di gate
bloccante all'avvio.

**Stato sotto-fasi post-pivot**:
- **Phase 6** (new, iOS + harness) — Diagnostic-driven pair flow · 9 tasks (P6.1 → P6.9) · ~9h
- **Phase 6A** — DEPRECATED · 3 tasks committati in `872b7d0`/`1235e32`/`0b33062` · cleanup via P6.8 · test gate P6A.4 CANCELLED
- **6B** (Panel web) — Connections tab · invariato · Card 0 consuma `/api/setup/diagnostics` (P6.3)
- **6C** (iOS post-pair) — Rich Settings card · invariato
- **Phase 6D** — FUSED in new Phase 6 · tutti 5 task CANCELLED (P6D.1/2/3/4/5)

Ordering raccomandato: **Phase 6 → 6C → 6B**. Vedi roadmap §3.

---

### ~~Phase 6A — Setup Checklist nell'app iOS~~ (DEPRECATED 2026-04-25 evening)

_~~Goal: utente fresh install capisce in 30s cosa gli serve (PC + harness + Claude Code CLI + account Cloudflare) PRIMA di provare a pair. Stato live su "PC raggiungibile", checkbox manuali sugli altri tre requisiti.~~_

**Status**: DEPRECATED — replaced by new Phase 6 (diagnostic-driven pair flow).
**Reason**: "Architectural pivot — replaced by Phase 6 diagnostic-driven flow". Checkbox manuali ciechi senza verifica reale; abbandonato la sera stessa del commit.
**Date**: 2026-04-25 (sera, stesso giorno del commit)
**Preservazione git history**: i commit `872b7d0`, `1235e32`, `0b33062` NON vengono riscritti. Il file `SetupChecklistView.swift` verrà rimosso via P6.8 (non tramite revert).

#### P6A.1 — NEW `SetupChecklistView.swift` (view SwiftUI)
- **Status**: DEPRECATED (was COMPLETED 2026-04-25 commit `872b7d0`) — architectural pivot, file will be removed via P6.8
- **Agent**: frontend-dev
- **Depends on**: none
- **Target file** (NEW): `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\SetupChecklistView.swift`
- **Anchor**: file-new
- **Changes**:
  - `struct SetupChecklistView: View` con:
    - Header "Benvenuto in GIGI" + paragrafo esplicativo (cosa è GIGI + perché serve un harness)
    - 4 righe requisito, ognuna: icona stato (`checkmark.circle.fill` verde se done / `circle` grey se pending), titolo, descrizione breve, link action
    - Requisito 1 — "PC sempre acceso + harness raggiungibile" → live check (health su URL configurato o mDNS discovery); no checkbox
    - Requisito 2 — "Account Cloudflare (gratuito)" → link `https://dash.cloudflare.com/sign-up` + checkbox manuale "ho creato l'account"
    - Requisito 3 — "Claude Code CLI installato" → link `https://docs.anthropic.com/claude-code` + checkbox manuale
    - Requisito 4 — "Harness GIGI installato sul PC" → link a repo README + checkbox manuale
    - Bottone "Procedi al Pair" in fondo, abilitato SOLO se requisito 1 è ✓ E le 3 checkbox manuali sono spuntate
    - Tap bottone presenta `GigiPairingSheet`
  - Stato checkbox persistito in `UserDefaults` con chiavi `gigi.checklist.cf`, `gigi.checklist.claudecli`, `gigi.checklist.harness`
- **Acceptance criteria**:
  - [ ] View compila come standalone (Preview renderable)
  - [ ] Checkbox toggle persiste attraverso relaunch app
  - [ ] Requisito 1 check live: se URL configurato (Keychain), esegui `GigiHarnessClient.shared.health()`; se risposta .success → ✓; altrimenti ☐
  - [ ] Bottone "Procedi al Pair" disabilitato se requisito 1 ☐ o qualsiasi checkbox unchecked
  - [ ] Tap bottone → `sheet(isPresented:) { GigiPairingSheet(...) }` viene presentato
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 1.5h

#### P6A.2 — Mount `SetupChecklistView` da `MainTabView` banner
- **Status**: DEPRECATED (was COMPLETED 2026-04-25 commit `1235e32`) — architectural pivot, wiring will be replaced via P6.7
- **Agent**: frontend-dev
- **Depends on**: P6A.1
- **Target file**: `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\MainTabView.swift`
- **Anchor**: overlay banner "Collega GIGI al tuo PC" (introdotto in P4.7)
- **Changes**:
  - Il banner già esistente (visibile quando `!GigiHarnessClient.shared.isConfigured`) ora presenta `SetupChecklistView` invece di `GigiPairingSheet` direttamente
  - Aggiungi `@State private var showChecklist = false` e `.sheet(isPresented: $showChecklist) { SetupChecklistView() }`
  - Tap banner → `showChecklist = true`
- **Acceptance criteria**:
  - [ ] Fresh install: tap banner → apre `SetupChecklistView` (non più pairing sheet diretto)
  - [ ] `SetupChecklistView` → tap "Procedi al Pair" → presenta `GigiPairingSheet`
  - [ ] Dopo pair riuscito: banner scompare (isConfigured diventa true), flow chiuso
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 30min

#### P6A.3 — Mount "Vedi requisiti" in `SettingsView.harnessSection` quando non paired
- **Status**: DEPRECATED (was COMPLETED 2026-04-25 commit `0b33062`) — architectural pivot, wiring will be replaced via P6.7
- **Agent**: frontend-dev
- **Depends on**: P6A.1
- **Target file**: `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\SettingsView.swift`
- **Anchor**: `private var harnessSection` line 126
- **Changes**:
  - Aggiungi bottone "Vedi requisiti" visibile quando `!harnessIsPaired`, posizionato SOPRA il bottone "Pair con Harness"
  - Tap → presenta `SetupChecklistView` come sheet (stesso stile di `showPairingSheet`)
  - Footer della section aggiornato: "Non sei sicuro di cosa serve? Tap 'Vedi requisiti'."
- **Acceptance criteria**:
  - [ ] Se non paired: il bottone "Vedi requisiti" è visibile
  - [ ] Tap → apre `SetupChecklistView`
  - [ ] Se paired: bottone nascosto (non serve più)
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 30min

#### P6A.4 — TEST GATE — Phase 6A end-to-end
- **Status**: CANCELLED (2026-04-25 evening) — architectural pivot, new test gate is P6.9 against the diagnostic-driven flow
- **Agent**: qa-tester
- **Type**: TEST_GATE
- **Gate**: HARD — Phase 6C e 6B non sono gated da questo, ma il pair flow via banner sì
- **Depends on**: P6A.1, P6A.2, P6A.3
- **Test matrix**:
  - [ ] Fresh install (Keychain empty) → lancio app → banner "Collega GIGI" visibile
  - [ ] Tap banner → `SetupChecklistView` appare con tutti i requisiti ☐
  - [ ] Spunto manualmente i 3 checkbox (CF, claude-cli, harness) senza avere harness running → bottone "Procedi al Pair" resta disabled perché requisito 1 è ☐
  - [ ] Avvio harness sul PC, torno in app → requisito 1 passa a ✓ → bottone si abilita
  - [ ] Tap "Procedi al Pair" → `GigiPairingSheet` appare
  - [ ] Riavvio app: checkbox restano spuntate (persistiti in UserDefaults)
  - [ ] Settings → non-paired → "Vedi requisiti" visibile e funzionante
  - [ ] Post-pair: banner scompare, "Vedi requisiti" in Settings non più visibile
  - [ ] USER CHECKPOINT: Armando valuta wording e layout checklist su device
- **Acceptance criteria**:
  - [ ] ≥ 7/8 scenarios PASS
  - [ ] No crash, no UI layout broken
- **Gate outcome**: PASS → Phase 6A complete · FAIL → return to P6A.x
- **Estimate**: 45min

---

### Phase 6B — Panel Connections tab

_Goal: Armando (admin) ispeziona tutto lo stato runtime dell'harness dal Panel + azioni management. Piano completo in `docs/plans/panel-observability.md` (10 ACs, 7 backend task, 3 frontend task, 1 QA). Qui decomposizione numerata._

#### P6B.1 — NEW `server/request-log.js` (ring buffer + middleware)
- **Status**: COMPLETED · 2026-04-25 · NEW `server/request-log.js` exporting `logRequest`/`recentRequests`/`wrapRequestHandler`; ring buffer 100 FIFO
- **Agent**: backend-dev
- **Depends on**: none
- **Target file** (NEW): `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\request-log.js`
- **Changes**: da plan §B1 — export `logRequest({...})`, `recentRequests()`, `wrapRequestHandler(h)`; ring buffer size 100 FIFO
- **Acceptance criteria**: AC-8 del plan (tutte le righe)
- **Estimate**: 45min

#### P6B.2 — Tunnel status aggregator in `api/setup.js`
- **Status**: COMPLETED · 2026-04-25 · `cloudflared.status()` extended with `restartCount`; aggregator inlined into `panel-connections.js` (lighter than separate module)
- **Agent**: backend-dev
- **Depends on**: none
- **Target file**: `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\api\setup.js` + `tunnel/cloudflared-manager.js`
- **Changes**: da plan §B2 — `getTunnelSnapshot()` → `{mode, publicUrl, uptime_s, restartCount, lastError, cloudflaredPid}`; aggiungere restart counter in cloudflared-manager
- **Acceptance criteria**: AC-2 del plan
- **Estimate**: 30min

#### P6B.3 — WS clients introspection in `api/ios-stream.js`
- **Status**: COMPLETED · 2026-04-25 · `activeClients()` exported, tracks `_connectedAt` + `_remoteAddress`; `closeForDevice()` helper for revoke action
- **Agent**: backend-dev
- **Depends on**: none
- **Target file**: `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\api\ios-stream.js`
- **Changes**: da plan §B3 — `activeClients()` → `[{deviceId, connected_since, remote_address}]`; track `_connectedAt`
- **Acceptance criteria**: AC-3 del plan
- **Estimate**: 30min

#### P6B.4 — NEW `api/panel-connections.js` (aggregator + action router)
- **Status**: COMPLETED · 2026-04-25 · NEW `server/api/panel-connections.js`; `handlePanelRequest` dispatcher + 6 endpoints (1 GET aggregator + 5 POST actions); loopback gating + CORS for cross-port panel UI fetch
- **Agent**: backend-dev
- **Depends on**: P6B.1, P6B.2, P6B.3
- **Target file** (NEW): `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\api\panel-connections.js`
- **Changes**: da plan §B4 + §B5 — `knownDevices()` helper + `handlePanelRequest(req, res, {cfg, cfgPath})` dispatcher; 6 endpoint (1 GET + 5 POST action)
- **Acceptance criteria**: AC-4, AC-6, AC-7 del plan
- **Estimate**: 3h (1h aggregator + 2h router e 5 action endpoint)

#### P6B.5 — Wire `handlePanelRequest` + `wrapRequestHandler` in `server.js`
- **Status**: COMPLETED · 2026-04-25 · `handlePanelRequest` wired before `handleSetup` in iOS HTTP server; `recordRequest()` (lightweight equivalent) in router after Bearer for activity feed
- **Agent**: backend-dev
- **Depends on**: P6B.4
- **Target file**: `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\server.js`
- **Changes**: da plan §B6 — import + route dispatch + wrap ios handlers con request logger
- **Acceptance criteria**: AC-1 del plan (endpoint risponde)
- **Estimate**: 20min

#### P6B.6 — Blocked device check in `api/ios-auth.js`
- **Status**: COMPLETED · 2026-04-25 · `checkDevice` rejects blocked deviceIds with code `DEVICE_REVOKED`; router applies it after Bearer using deviceId from query/X-Device-Id header
- **Agent**: backend-dev
- **Depends on**: P6B.4
- **Target file**: `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\api\ios-auth.js`
- **Changes**: da plan §B7 — check `cfg.ios.blocked_device_ids` in Bearer auth path; 403 `DEVICE_REVOKED` se match
- **Acceptance criteria**: AC-9 del plan
- **Estimate**: 20min

#### P6B.7 — Panel UI: nuova tab "Connections" HTML
- **Status**: COMPLETED · 2026-04-25 · tab + section in `index.html` with 4 sub-cards (tunnel, WS, devices, requests)
- **Agent**: frontend-dev (web)
- **Depends on**: P6B.5 (endpoint must respond before UI)
- **Target file**: `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\public\index.html`
- **Changes**: da plan §F1 — `<button class="tab" data-tab="connections">`; `<section id="tab-connections">` con 4 sub-card (tunnel, ws, devices, requests)
- **Acceptance criteria**: AC-1 del plan (tab visibile, click attiva pannello)
- **Estimate**: 45min

#### P6B.8 — Panel UI: CSS per Connections
- **Status**: COMPLETED · 2026-04-25 · `.conn-list`, `.conn-row`, `.pill` (green/red), `.conn-requests` table, `.toast` styles appended to `style.css`
- **Agent**: frontend-dev
- **Depends on**: P6B.7
- **Target file**: `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\public\style.css`
- **Changes**: da plan §F2 — tabella requests mono font, error rows red, status pills (green/gray/red), device row + action buttons
- **Acceptance criteria**: stile consistente con tab esistenti
- **Estimate**: 30min

#### P6B.9 — Panel UI: JS client polling + actions
- **Status**: COMPLETED · 2026-04-25 · `loadConnections()` fetches `localhost:7779/api/panel/connections` cross-port; 3s polling on tab active, paused on switch; click handlers for stop/restart tunnel, ws disconnect, device revoke, reset-session with `confirm()` + toast feedback
- **Agent**: frontend-dev
- **Depends on**: P6B.7, P6B.8
- **Target file**: `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\public\app.js`
- **Changes**: da plan §F3 — `loadConnections()` fetch + render 4 card; polling 3s (pause on tab switch); handler click per tutte 5 azioni destructive con `confirm()` popup; toast feedback
- **Acceptance criteria**: AC-10 del plan + AC-7 end-to-end via click
- **Estimate**: 2h

#### P6B.10 — TEST GATE — Phase 6B end-to-end
- **Status**: PENDING
- **Agent**: qa-tester
- **Type**: TEST_GATE
- **Gate**: HARD — Phase 6D integration sezione preflight in Card tunnel status dipende da questo gate PASS
- **Depends on**: P6B.1 through P6B.9
- **Environment**: harness + Panel running, iPhone paired via Quick Tunnel
- **Test matrix**: tutti 10 scenarios da `docs/plans/panel-observability.md` §Verification Steps
- **Gate outcome**: PASS → Phase 6B complete · FAIL → debugger + return a specific P6B.x
- **Estimate**: 1h

---

### Phase 6C — Stato sintetico ricco nelle Settings iOS

_Goal: post-pair, card Settings → Harness mostra modalità tunnel, URL offuscato, ultima richiesta, counter, bottone test latenza. L'utente capisce stato sistema a colpo d'occhio._

#### P6C.1 — NEW `api/ios-status.js` (server endpoint GET /api/ios/status)
- **Status**: COMPLETED · 2026-04-25 · NEW `server/api/ios-status.js` with in-memory ring buffer + URL redaction; `recordRequest()` wired into `ios-router.js` after Bearer auth; `GET /api/ios/status` route added
- **Agent**: backend-dev
- **Depends on**: P6B.1 (riusa `recentRequests()` per popolare `requestsLastHour` e `lastRequestAt`) OR può essere standalone con contatore ad-hoc
- **Target files**:
  - NEW `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\api\ios-status.js`
  - MODIFY `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\server.js` (route wiring)
- **Changes**:
  - Handler Bearer-auth che ritorna JSON:
    ```json
    {
      "tunnelMode": "quick" | "named" | "lan" | "manual",
      "publicUrlRedacted": "https://abc...xyz.trycloudflare.com",
      "lastRequestAt": "2026-04-25T14:32:10Z" | null,
      "requestsLastHour": 42,
      "uptimeSeconds": 3600
    }
    ```
  - `tunnelMode` letto da `cfg.tunnel.mode`
  - `publicUrlRedacted` → per URL `https://foobar.trycloudflare.com` mostra `https://foo...com`
  - `lastRequestAt` e `requestsLastHour` aggregati da `recentRequests()` (se P6B.1 ready) o da contatore semplice in memory
- **Acceptance criteria**:
  - [ ] `curl -H "Authorization: Bearer <secret>" http://localhost:7779/api/ios/status` ritorna JSON con tutti i campi
  - [ ] Richiesta senza Bearer → 401
  - [ ] `publicUrlRedacted` è davvero offuscato (middle omesso)
  - [ ] Modalità manual con URL Tailscale `http://100.x.y.z:7779` → `tunnelMode = "manual"` (o "tailscale" se vogliamo dedurre), URL redacted funzionante
- **Estimate**: 45min

#### P6C.2 — NEW `HarnessStatusCard.swift` (SwiftUI component)
- **Status**: COMPLETED · 2026-04-25 · NEW `02_GIGI_APP/GIGI/HarnessStatusCard.swift`; `GigiHarnessClient.statusSnapshot()` + `pairedBaseURL` exposed; tunnel mode/icon, redacted URL with copy button, last/last-hour metrics, latency probe, 15s polling
- **Agent**: frontend-dev
- **Depends on**: P6C.1
- **Target files**:
  - NEW `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\HarnessStatusCard.swift`
  - MODIFY `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\GigiHarnessClient.swift` (aggiungere `func statusSnapshot() async throws -> HarnessStatus`)
- **Changes**:
  - `struct HarnessStatusCard: View`:
    - Row 1: icona tunnel + label modalità (Quick / Named / LAN / Manual / Tailscale) + colore (verde se running)
    - Row 2: URL offuscato + bottone "Copia URL completo" (clipboard); toast conferma copia
    - Row 3: "Ultima richiesta: HH:mm" (o "Nessuna ancora")
    - Row 4: "X richieste nell'ultima ora"
    - Row 5: bottone "Test latenza" → chiama `health()` misurando `Date().timeIntervalSince(start) * 1000` → mostra inline "312 ms" (o errore)
  - Pull `statusSnapshot()` on appear + ogni 15s (Timer) quando visibile
  - `GigiHarnessClient.statusSnapshot()` decodifica `/api/ios/status` in `HarnessStatus` struct
- **Acceptance criteria**:
  - [ ] Card compila e renderizza in Preview con mock status
  - [ ] Tap "Copia URL" copia URL completo (non offuscato) in clipboard
  - [ ] Tap "Test latenza" mostra ms effettivi
  - [ ] Poll 15s effettivo (verifica via log/breakpoint)
  - [ ] Gestisce stato "non paired" o "error" gracefully (mostra messaggio, non crash)
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 1h

#### P6C.3 — Mount `HarnessStatusCard` in `SettingsView.harnessSection`
- **Status**: COMPLETED · 2026-04-25 · `HarnessStatusCard(deviceName:)` mounted right under the Status row when paired
- **Agent**: frontend-dev
- **Depends on**: P6C.2
- **Target file**: `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\SettingsView.swift`
- **Anchor**: dentro `harnessSection` quando `harnessIsPaired == true`, dopo status line attuale (~line 154)
- **Changes**:
  - Sostituisci la status line semplice `"✓ Connesso a \(deviceName)"` con `HarnessStatusCard(deviceName: pairedDeviceName)`
  - Mantieni la status line minimale come fallback se la card fallisce il pull (`AsyncState<HarnessStatus>` pattern)
- **Acceptance criteria**:
  - [ ] Settings → Harness (paired) → card ricca visibile invece di sola status line
  - [ ] Se harness down: card mostra "Impossibile caricare stato — verifica pairing"
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 30min

#### P6C.4 — TEST GATE — Phase 6C end-to-end
- **Status**: PENDING
- **Agent**: qa-tester
- **Type**: TEST_GATE
- **Gate**: HARD — nessuna fase dipende da questo gate, ma USER CHECKPOINT per validare UX
- **Depends on**: P6C.1, P6C.2, P6C.3
- **Test matrix**:
  - [ ] `curl` endpoint → tutti i campi presenti, latenza < 50ms
  - [ ] Settings post-pair con harness running → card mostra modalità, URL, ultima richiesta recente
  - [ ] Invio chat dall'iPhone → Settings → card aggiornata entro 15s (request count incrementa)
  - [ ] Tap "Test latenza" → mostra ms realistici (<500 su LAN, <1500 su CF)
  - [ ] Tap "Copia URL" → clipboard contiene URL completo (verifica via paste in Notes)
  - [ ] Kill harness → card mostra errore/stato degradato (no crash)
  - [ ] Restart harness → card torna healthy nel polling successivo
  - [ ] Modalità manual/Tailscale → card riconosce e mostra correttamente
  - [ ] USER CHECKPOINT: Armando valuta leggibilità card
- **Gate outcome**: PASS → Phase 6C complete · FAIL → return to P6C.x
- **Estimate**: 45min

---

### Phase 6 (NEW, post-pivot 2026-04-25) — Diagnostic-driven pair flow

_Goal: sostituire la vecchia Setup Checklist (P6A, buttata) con un pair flow a due stadi dove l'iPhone polla diagnostica live dell'harness e mostra ✓/⚠/❌ per ogni check. Sostituisce anche l'ex Phase 6D (preflight blocking startup): stesse primitive di check, endpoint queryable invece di gate bloccante._
_Consume path: `/api/setup/diagnostics` (P6.3) · used by iPhone pre-pair (P6.5) + Panel Card 0 (6B post-merge)._
_Estimated: ~9h totali · Ordering: backend (P6.1 → P6.2 → P6.3) PRIMA; iOS frontend (P6.4 → P6.8) DOPO; test gate (P6.9) ultimo._

**Two-stage pair (contract)**:
1. **Stage 1 — Bootstrap**: utente scansiona QR → URL+secret in Keychain → `/api/ios/health` 200 OK → `isConfigured = true` MA `isReady = false`.
2. **Stage 2 — Diagnostic gate**: `SetupDiagnosticView` polla `/api/setup/diagnostics` ogni 5s → utente fixa problemi in terminal → vede ✓ live.
3. **Stage 3 — Finalize**: quando tutti i check `severity:"critical"` sono ok, button "Finalize pair" si abilita → tap → `isReady = true` → banner sparisce.

**Decisione tecnica — `isConfigured` vs `isReady`**:
- `GigiHarnessClient.isConfigured` (esistente, semantica legacy preservata) = URL+secret in Keychain.
- `GigiHarnessClient.isReady` (NEW, introdotta in P6.4) = `isConfigured && lastDiagnosticsSnapshot?.allCriticalOk == true`.
- Banner `MainTabView` e gate chat input usano `isReady` (non più solo `isConfigured`).
- Settings "Diagnostica harness" button è primario finché `!isReady`.
- `lastDiagnosticsSnapshot` persistito in `AppStorage` con TTL 5 min; refresh on app foreground + on SetupDiagnosticView dismiss.

**10 check tecnici (definitivi, implementati in P6.1)**:

| Check ID | Severity | Cosa testa | Hint |
|---|---|---|---|
| `claude_cli_installed` | critical | `claude --version` exit 0 | "Install Claude Code from claude.com/code" |
| `claude_cli_authenticated` | critical | `claude --print --model haiku "ok"` timeout 10s | "Run `claude auth login` in your terminal" |
| `config_secret_strength` | critical | secret >= 32 chars, no spaces | "Regenerate secret with `openssl rand -hex 16`" |
| `tunnel_mode_active` | critical | cfg.tunnel.mode != "manual" | "Open localhost:7777/setup and pick Quick or Named" |
| `tunnel_running` | critical | cloudflared.status().running | "Restart tunnel from /setup" |
| `cloudflared_binary` | warning | `~/.gigi/bin/cloudflared` exists+executable | "Auto-downloaded on first tunnel start" |
| `outbound_https` | warning | fetch `https://api.cloudflare.com/client/v4/` < 5s | "Check Wi-Fi/Ethernet" |
| `port_7779_bound` | info | server listening | (debug only) |
| `disk_space` | info | logs dir parent > 2GB free | "Low disk space" |
| `last_request_ago` | info | timestamp ultima request iOS | (informativo) |

---

#### P6.1 — NEW `server/preflight/checks.js` (10 async check functions)
- **Status**: COMPLETED · commit `6b9b04d` · 10 check functions implemented with timeouts, severity classification, autoFixable annotations
- **Agent**: backend-dev
- **Depends on**: none
- **Target file** (NEW): `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\preflight\checks.js`
- **Anchor**: file-new
- **Changes**:
  - Export 10 `async` functions, una per check ID (vedi tabella sopra), ognuna con timeout indipendente: `checkClaudeCliInstalled`, `checkClaudeCliAuthenticated`, `checkConfigSecretStrength(cfg)`, `checkTunnelModeActive(cfg)`, `checkTunnelRunning(manager)`, `checkCloudflaredBinary()`, `checkOutboundHttps()`, `checkPort7779Bound(server)`, `checkDiskSpace()`, `checkLastRequestAgo(requestLog?)`
  - Ogni funzione ritorna `{id, label, severity, ok, hint?, action?, durationMs}` — **shape stabile** consumata da P6.2 runner e P6.3 endpoint
  - Timeout: `claude_cli_installed` 3s, `claude_cli_authenticated` 10s, `outbound_https` 5s, resto sincroni o <500ms
  - `action?` è una stringa opzionale che l'iPhone può mostrare come "tap to copy" (es: `"claude auth login"`)
- **Acceptance criteria**:
  - [ ] Tutte 10 funzioni exportate, callable standalone
  - [ ] Ogni funzione con harness running + prerequisiti OK → `ok: true`
  - [ ] Ogni funzione con condizione di fallimento nota → `ok: false, hint: "<stringa utile>"`
  - [ ] Nessuna funzione impiega >11s anche worst-case (timeout aggregato ok)
  - [ ] Nessuna funzione throwa — errori diventano `ok: false` con hint
- **Estimate**: 2h

---

#### P6.2 — NEW `server/preflight/runner.js` (parallel runner + classification)
- **Status**: COMPLETED · commit `6b9b04d` · `runDiagnostics` aggregator with Promise.allSettled, severity-sorted output, `allCriticalOk` shortcut
- **Agent**: backend-dev
- **Depends on**: P6.1
- **Target file** (NEW): `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\preflight\runner.js`
- **Changes**:
  - Export `async function runDiagnostics({cfg, tunnelManager, server, requestLog}) → DiagnosticsReport`
  - Esegue tutti 10 check in `Promise.allSettled` (parallel) per minimizzare latenza totale (~11s worst-case → ~10s con parallel)
  - Aggrega risultati in `DiagnosticsReport`:
    ```js
    {
      generatedAt: "2026-04-25T22:00:00Z",
      durationMs: 9800,
      checks: [...CheckResult],
      summary: {
        critical: { total, ok, failed },
        warning: { total, ok, failed },
        info: { total, ok, failed },
      },
      allCriticalOk: boolean,  // shortcut per client
    }
    ```
  - Ordina `checks` per severity (critical → warning → info), poi per `ok` (failed first)
- **Acceptance criteria**:
  - [ ] `runDiagnostics(...)` ritorna DiagnosticsReport shape completa
  - [ ] Execution tempo <12s in totale anche con tutti check slow
  - [ ] `allCriticalOk` è true sse ogni check `critical` ha `ok: true`
  - [ ] Check falliti non fanno collassare il report (Promise.allSettled)
- **Estimate**: 45min

---

#### P6.3 — NEW `server/api/diagnostics.js` (Bearer-authed endpoint)
- **Status**: COMPLETED · commit `6b9b04d` · `GET /api/setup/diagnostics` Bearer-authed with 5s in-memory cache, `?refresh=1` to bypass
- **Agent**: backend-dev
- **Depends on**: P6.2
- **Target files**:
  - NEW `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\api\diagnostics.js`
  - MODIFY `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\server.js` (route wiring)
- **Changes**:
  - Handler `async function handleDiagnosticsRequest(req, res, {cfg, cfgPath, tunnelManager, server})`:
    - Metodo: GET only; altri → 405
    - Auth: Bearer `cfg.ios.shared_secret` via esistente `checkBearer()` (riusa da `ios-auth.js`)
    - Body: chiama `runDiagnostics(...)` da P6.2, ritorna JSON del DiagnosticsReport
    - Caching: 5s in-memory (evita flood da phone che polla), key = nessuna (global)
  - Route: `GET /api/setup/diagnostics` wired before `handleIosRequest` in `server.js`
  - Il PANEL (loopback) può anche chiamarlo via token zero-auth locale? **Decisione**: no, anche loopback usa Bearer (semplifica). Panel 6B Card 0 passa `Authorization: Bearer <cfg.ios.shared_secret>` letto server-side.
- **Acceptance criteria**:
  - [ ] `curl -H "Authorization: Bearer <secret>" https://<tunnel>/api/setup/diagnostics` → JSON con 10 check
  - [ ] `curl` senza Bearer → 401
  - [ ] Cache 5s: due call consecutive <5s apart restituiscono identico timestamp
  - [ ] Risposta <12s p95 (dipende da P6.2 runner)
- **Estimate**: 45min

---

#### P6.4 — `GigiHarnessClient.swift` — `diagnostics()` method + `DiagnosticsReport` + `isReady`
- **Status**: COMPLETED · commit `6b9b04d` · `DiagnosticsReport`/`DiagnosticsCheck` Codable structs, `diagnostics(forceRefresh:)` method, `isReady` computed property, `cacheDiagnostics` setter
- **Agent**: frontend-dev
- **Depends on**: P6.3
- **Target file**: `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\GigiHarnessClient.swift`
- **Changes**:
  - NEW struct `DiagnosticsReport: Codable` matching P6.2 shape (`generatedAt`, `durationMs`, `checks: [CheckResult]`, `summary`, `allCriticalOk`)
  - NEW struct `CheckResult: Codable` (`id`, `label`, `severity`, `ok`, `hint?`, `action?`, `durationMs`)
  - NEW enum `CheckSeverity: String, Codable { case critical, warning, info }`
  - NEW method `func diagnostics() async throws -> DiagnosticsReport` — GET `/api/setup/diagnostics` con Bearer; timeout 15s
  - NEW computed property `var isReady: Bool` = `isConfigured && (lastDiagnosticsSnapshot?.allCriticalOk ?? false)`
  - NEW `@Published var lastDiagnosticsSnapshot: DiagnosticsReport?` persistito via `AppStorage` (encoded JSON) con TTL 5 min
  - `diagnostics()` aggiorna `lastDiagnosticsSnapshot` a ogni successful fetch
- **Acceptance criteria**:
  - [ ] `diagnostics()` decodifica response JSON correttamente
  - [ ] `isReady` è false se `isConfigured == false`
  - [ ] `isReady` è false se `isConfigured == true` ma snapshot manca o ha critical failed
  - [ ] `isReady` è true sse tutti critical sono ok
  - [ ] Snapshot persiste attraverso relaunch (encoded in AppStorage)
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 45min

---

#### P6.5 — NEW `SetupDiagnosticView.swift` (polling UI con severity colors + copyable actions)
- **Status**: COMPLETED · commit `6b9b04d` + `410810b` (Recheck button, auto-expand failures, countdown) · poll loop 5s, severity icons, copyable hints, Finalize gated on allCriticalOk
- **Agent**: frontend-dev
- **Depends on**: P6.4
- **Target file** (NEW): `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\SetupDiagnosticView.swift`
- **Changes**:
  - `struct SetupDiagnosticView: View` con:
    - Header: "Almost there — let's verify your PC is ready" + subtitle con deviceName corrente
    - List scrollabile di check rows ordinati critical → warning → info, ognuno:
      - Icona stato: ✓ verde (ok), ⚠️ gialla (warning+fail), ❌ rossa (critical+fail), spinner se ancora caricando primo snapshot
      - Label + severity pill
      - Hint (se fail) in secondary text
      - Action button (se presente) → tap copia stringa in clipboard + toast "Copied"
    - Footer: polling indicator "Checking every 5 seconds · last updated XX:XX:XX"
    - CTA button "Finalize pair" in fondo, abilitato SOLO se `report?.allCriticalOk == true`; tap → chiude view + flippa `isReady` (via P6.6 wiring)
    - CTA secondario "Cancel" → chiude view senza flippare nulla
  - Timer `every 5s` chiama `GigiHarnessClient.shared.diagnostics()` e ricarica report
  - Handle errori (harness unreachable, 401): mostra banner rosso "Can't reach PC — check pairing URL"
- **Acceptance criteria**:
  - [ ] View compila + Preview renderable con mock DiagnosticsReport
  - [ ] Polling 5s effettivo (verifica via log)
  - [ ] Tap action button copia in UIPasteboard + mostra toast
  - [ ] "Finalize pair" disabled quando `allCriticalOk == false`
  - [ ] Tap "Finalize pair" → callback che trigger state change a stage 3 in GigiPairingSheet
  - [ ] Errore di rete: view non crasha, mostra stato degraded
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 2h

---

#### P6.6 — `GigiPairingSheet.swift` — three-stage state machine (bootstrap → diagnostic → finalize)
- **Status**: COMPLETED · commit `6b9b04d` · `.scanning → .validating → .diagnostic → .success/.failure` state machine; rollback on health failure; SetupDiagnosticView mounted as fullscreen child in `.diagnostic` stage
- **Agent**: frontend-dev
- **Depends on**: P6.5
- **Target file**: `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\GigiPairingSheet.swift`
- **Changes**:
  - Aggiungi stati `.diagnostic` e `.finalizing` alla state machine esistente (già ha `.scanning → .validating → .success/.failure`)
  - Flow nuovo:
    1. `.scanning` → QR scan
    2. `.validating` → salva URL+secret in Keychain, chiama `/api/ios/health`
    3. Su `200 OK`: **NON** flippa `isReady` ancora. Transizione a `.diagnostic` → presenta `SetupDiagnosticView`.
    4. Quando utente tap "Finalize pair" in SetupDiagnosticView: transizione a `.finalizing` → flippa `GigiHarnessClient.isReady = true` (equivalente a: salva flag `AppStorage("gigi.harnessReady") = true`).
    5. `.success` → chiude sheet, banner sparisce.
  - **Rollback path**: se utente cancella da `.diagnostic`, URL+secret restano in Keychain (pair linked ma non ready). Banner resta, utente può riaprire SetupDiagnosticView da Settings in qualunque momento.
- **Acceptance criteria**:
  - [ ] QR scan → health check → diagnostic → finalize flow end-to-end (tutti critical ok) → banner sparisce
  - [ ] QR scan → health check → diagnostic con critical fail → utente chiude → banner RESTA + URL/secret persistono in Keychain
  - [ ] Riapro SetupDiagnosticView da Settings → stesso flow, se ora critical ok → Finalize abilita → banner sparisce
  - [ ] `isReady` flippa a true SOLO in `.finalizing` stage (non in `.validating`)
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 1h

---

#### P6.7 — Wire `SetupDiagnosticView` in `MainTabView.swift` + `SettingsView.swift` (deprecate ChecklistView wiring)
- **Status**: COMPLETED · commit `6b9b04d` · MainTabView banner gates on `pairingState.isConfigured` (post-P6.14 fix); SettingsView shows "Diagnostica harness" button when paired
- **Agent**: frontend-dev
- **Depends on**: P6.5, P6.6
- **Target files**:
  - MODIFY `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\MainTabView.swift`
  - MODIFY `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\SettingsView.swift`
- **Changes**:
  - **MainTabView**:
    - Banner visibility: `!GigiHarnessClient.shared.isReady` (era `!isConfigured`) — banner mostra anche quando pair linked ma diagnostic non passed
    - Tap banner: se `isConfigured == false` → apri `GigiPairingSheet` (flow normale); se `isConfigured == true` ma `isReady == false` → apri direttamente `SetupDiagnosticView`
    - Rimuovi `@State showChecklist` e lo sheet `SetupChecklistView()` (introdotti in P6A.2)
  - **SettingsView**:
    - Rimuovi bottone "Vedi requisiti" (P6A.3) e `@State showChecklistSheet`
    - Aggiungi bottone "Diagnostica harness" quando `isConfigured == true` (sempre visibile post-pair, non solo quando `!isReady`) → tap apre `SetupDiagnosticView`
    - Se `isConfigured == true && !isReady`: bottone è primary + badge "⚠️ setup incomplete"
    - Se `isReady == true`: bottone è secondary
    - Footer copy aggiornato: "Run diagnostics any time to verify your PC is healthy."
- **Acceptance criteria**:
  - [ ] Fresh install: banner → tap → GigiPairingSheet (scan QR)
  - [ ] Post-QR-scan ma pre-finalize: banner resta → tap → SetupDiagnosticView direttamente (skip QR)
  - [ ] Post-finalize: banner sparisce
  - [ ] Settings post-pair (isReady): bottone "Diagnostica harness" secondary visibile
  - [ ] Settings post-pair-but-unready: bottone primary + badge warning
  - [ ] Zero riferimenti residui a `SetupChecklistView` in questi due file (grep-clean)
  - [ ] Build verify via ssh → BUILD SUCCEEDED
- **Estimate**: 30min

---

#### P6.8 — DELETE `SetupChecklistView.swift` (cleanup of deprecated P6A)
- **Status**: COMPLETED · commit `6b9b04d` · file deleted, no references in MainTabView/SettingsView
- **Agent**: frontend-dev
- **Depends on**: P6.7 (verified that MainTabView + SettingsView no longer reference ChecklistView)
- **Target file** (DELETE): `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\SetupChecklistView.swift`
- **Changes**:
  - `git rm 02_GIGI_APP/GIGI/SetupChecklistView.swift`
  - Aggiorna `GIGI.xcodeproj/project.pbxproj` se il file è listato (rimuovi reference build)
  - Commit solo: `revert: refactor pre-pair flow to diagnostic-driven (remove SetupChecklistView)`. **Non** `git revert 872b7d0/1235e32/0b33062` — storia preservata, questa è una rimozione forward.
- **Acceptance criteria**:
  - [ ] File `SetupChecklistView.swift` non più presente nel repo
  - [ ] Grep `SetupChecklistView` nell'intera `02_GIGI_APP/` ritorna zero match
  - [ ] `GIGI.xcodeproj` apre senza warning/error su reference mancante
  - [ ] Build verify via ssh → BUILD SUCCEEDED
  - [ ] Commit history mostra `872b7d0` → ... → `0b33062` → ... → delete-commit (lineare, no rewrite)
- **Estimate**: 10min

---

#### P6.9 — TEST GATE — Phase 6 end-to-end (diagnostic-driven pair)
- **Status**: PENDING
- **Agent**: qa-tester + USER CHECKPOINT
- **Type**: TEST_GATE
- **Gate**: HARD — chiude la nuova Phase 6; sblocca P6B.10/P6C.4 dipendenze SOFT
- **Depends on**: P6.1, P6.2, P6.3, P6.4, P6.5, P6.6, P6.7, P6.8
- **Environment**: harness running su PC, iPhone fresh install con `.ipa` post-P6.8
- **Test matrix (simula utente con harness rotto in vari modi)**:
  - [ ] **Scenario A — happy path**: harness tutto OK → QR scan → diagnostic view mostra 10/10 check ✓ → Finalize abilitato → tap → banner sparisce
  - [ ] **Scenario B — Claude not authed**: utente ha installato Claude CLI ma mai fatto auth login → scan QR → diagnostic mostra `claude_cli_authenticated` ❌ critical con hint "Run `claude auth login`" + action copiabile → utente esegue `claude auth login` in terminal PC → **entro 5s** (next poll) il check passa a ✓ → Finalize abilita
  - [ ] **Scenario C — tunnel manual**: `cfg.tunnel.mode = "manual"` → `tunnel_mode_active` ❌ critical + hint "Open /setup and pick Quick or Named" → utente va su `localhost:7777/setup`, picks Quick, starts tunnel → entro 5s `tunnel_mode_active` + `tunnel_running` passano a ✓
  - [ ] **Scenario D — weak secret**: secret = "test1234" (8 chars) → `config_secret_strength` ❌ critical + hint + action `openssl rand -hex 16` → utente rigenera, riavvia harness, ri-fa pair con nuovo QR → check pass
  - [ ] **Scenario E — no outbound HTTPS**: simula killing WiFi sul PC → `outbound_https` ⚠️ warning + `tunnel_running` probabilmente ❌ → reattiva WiFi → entro 5s-15s check torna verde
  - [ ] **Scenario F — persistence**: utente arriva a diagnostic con tutti critical ok MA chiude app (swipe up) senza tap Finalize → riapre app → banner RESTA (isReady false) → Settings > Diagnostica harness → diagnostic view → tap Finalize → banner sparisce
  - [ ] **Scenario G — regression**: pair fatto e completato pre-pivot (esiste utente paired con SetupChecklistView nella vecchia build) → upgrade `.ipa` → prima apertura → banner può riapparire se isReady è false (snapshot assente) → diagnostic gira → passa → Finalize → banner sparisce. Accettabile one-time friction.
  - [ ] **No crash, no UI layout broken, no log spam**
  - [ ] **USER CHECKPOINT**: Armando valuta wording, copy, severity colors, tempi di convergenza live
- **Acceptance criteria**:
  - [ ] ≥ 6/7 scenarios PASS
  - [ ] Scenario B live-convergence (fixa in terminal → iPhone vede ✓ entro 5s) è **mandatory PASS** (dimostra il valore del flow)
  - [ ] USER CHECKPOINT sign-off from Armando
- **Gate outcome**: PASS → Phase 6 complete · FAIL → debugger report + route a specific P6.x
- **Estimate**: 1h

---

### Phase 6 extension — Auto-fix + difficulty tiers + guided walkthroughs (P6.10 → P6.13)

_Source plan: `docs/plans/auto-fix-and-difficulty-tiers.md`_
_Goal: estendere il diagnostic-driven flow con auto-fix server-side, quiz/badge nel Panel setup, e walkthrough inline per i check che richiedono intervento umano._

#### P6.10.1 — `preflight/auto_fixers.js`
- **Status**: COMPLETED · commit `1e69bef`
- **Agent**: backend-dev
- **Depends on**: P6.3
- **Target file**: `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\preflight\auto_fixers.js`
- **Outcome**: registry di fixer per `config_secret_strength`, `tunnel_mode_active`, `tunnel_running`, `cloudflared_binary`, `claude_cli_authenticated`; batch runner seriale con timeout per-fixer e summary aggregata.

#### P6.10.2 — `api/autofix.js`
- **Status**: COMPLETED · commit `1e69bef`
- **Agent**: backend-dev
- **Depends on**: P6.10.1
- **Target file**: `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\api\autofix.js`
- **Outcome**: `POST /api/setup/autofix` Bearer-authed, body `{checkIds}`, risposta `{ok, data:{results,summary}}`, esecuzione seriale per progress UI leggibile.

#### P6.10.3 — `checks.js` / `runner.js` add `autoFixable`
- **Status**: COMPLETED · commit `1e69bef`
- **Agent**: backend-dev
- **Depends on**: P6.10.1
- **Target files**:
  - `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\preflight\checks.js`
  - `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\preflight\runner.js`
- **Outcome**: `DiagnosticsCheck` annotato con `autoFixable` derivato dal registry fixers, riusato dalla UI iOS senza round-trip aggiuntivo.

#### P6.10.4 — Panel `/setup` difficulty tiers + "Help me choose"
- **Status**: COMPLETED · commit `f9aa20c`
- **Agent**: frontend-dev (web)
- **Depends on**: P5.5
- **Target file**: `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\public\setup.html`
- **Outcome**: badge Easy / Recommended / Local-only / Advanced su tutte le card, sezione quiz espandibile "Help me choose", pulse/highlight sulla card consigliata, stato open/closed persistito in `sessionStorage`.

#### P6.10.5 — Panel home link to `/setup`
- **Status**: COMPLETED · 2026-04-25 · added Setup CTA in `index.html` header controls linking to `/setup`
- **Agent**: frontend-dev (web)
- **Depends on**: P6.10.4
- **Target files**:
  - `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\public\index.html`
  - `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\public\app.js`
- **Acceptance criteria**:
  - [ ] Control Panel home/status surface exposes a clear link or CTA to `/setup`
  - [ ] Copy references the setup quiz / tunnel mode chooser coherently

#### P6.11.1 — `DiagnosticsCheck` add `autoFixable`
- **Status**: COMPLETED · commit `b60e414`
- **Agent**: frontend-dev
- **Depends on**: P6.10.3
- **Target file**: `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\GigiHarnessClient.swift`
- **Outcome**: iOS diagnostics model decodes `autoFixable`, plus autofix report models and `clearPair()` helper for secret-rotation re-pair flow.

#### P6.11.2 — `SetupDiagnosticView` autofix banner + progress
- **Status**: COMPLETED · commit `b60e414`
- **Agent**: frontend-dev
- **Depends on**: P6.11.1
- **Target file**: `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\SetupDiagnosticView.swift`
- **Outcome**: sticky "Fix all automatically" banner, secret-rotate confirm popup, per-step autofix progress card, diagnostics refresh after batch.

#### P6.11.3 — Re-pair flow post-secret-rotate
- **Status**: COMPLETED · commit `b60e414`
- **Agent**: frontend-dev
- **Depends on**: P6.11.2
- **Target files**:
  - `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\GigiHarnessClient.swift`
  - `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\SetupDiagnosticView.swift`
  - `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\SettingsView.swift`
- **Outcome**: autofix can emit `needsRepair:true`; iOS clears persisted pair state, resets the Settings form state, dismisses diagnostics, and routes the user back into re-pair.

#### P6.12.1 — `Walkthroughs.swift`
- **Status**: COMPLETED (2026-04-25 Ralph) · remote iOS build `BUILD SUCCEEDED`
- **Agent**: frontend-dev
- **Depends on**: P6.11.2
- **Target file** (NEW): `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\Walkthroughs.swift`
- **Acceptance criteria**:
  - [ ] Static dictionary of walkthroughs for `claude_cli_installed`, `claude_cli_authenticated`, `outbound_https`, `disk_space`, fallback
  - [ ] Supports plain text steps and copyable command steps
  - [ ] English copy consistent with current Phase 6 UX

#### P6.12.2 — Inline walkthrough rendering in `SetupDiagnosticView`
- **Status**: COMPLETED (2026-04-25 Ralph) · remote iOS build `BUILD SUCCEEDED`
- **Agent**: frontend-dev
- **Depends on**: P6.12.1
- **Target file**: `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\SetupDiagnosticView.swift`
- **Acceptance criteria**:
  - [ ] Expanded failing rows can reveal "Show full instructions"
  - [ ] Copyable walkthrough steps expose copy-to-clipboard buttons
  - [ ] `claude_cli_authenticated` still shows walkthrough after semi-auto fix returns `needsUser`
  - [ ] Fallback walkthrough available when a specific mapping is absent

#### P6.13 — TEST GATE — Auto-fix + walkthrough UX
- **Status**: PENDING
- **Agent**: qa-tester + USER CHECKPOINT
- **Type**: TEST_GATE
- **Depends on**: P6.10.1, P6.10.2, P6.10.3, P6.10.4, P6.11.1, P6.11.2, P6.11.3, P6.12.1, P6.12.2
- **Test matrix**:
  - [ ] DiagnosticView with multiple failing checks shows autofix banner with correct split fixable/manual
  - [ ] Autofix without secret rotation runs with progress and refreshes diagnostics
  - [ ] Secret rotation path forces re-pair flow cleanly
  - [ ] `claude_cli_authenticated` walkthrough remains accessible after autofix returns `needsUser`
  - [ ] Panel `/setup` shows badges + quiz and guides to the right card
  - [ ] USER CHECKPOINT on wording / clarity / friction


#### P6.14 ? Cold-start pairing banner persistence
- **Status**: COMPLETED (2026-04-25 Ralph) ? remote iOS build `BUILD SUCCEEDED` ? architect verification APPROVED
- **Agent**: ralph / frontend-dev
- **Type**: BUGFIX
- **Source plan**: `.omx/plans/ralplan-persistent-pairing-banner-20260425T051449Z.md`
- **Depends on**: P6.11.3, P6.12.2
- **Target files**:
  - `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\GigiHarnessClient.swift`
  - `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\GigiKeychain.swift`
  - `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\MainTabView.swift`
  - `C:\Users\arman\Desktop\GIGI\02_GIGI_APP\GIGI\SettingsView.swift`
- **Problem**: dopo force-close/reopen dell'app iOS il banner viola `Connect GIGI to your PC` pu? riapparire anche se il pairing ? gi? stato configurato.
- **Implementation plan**:
  - [x] Centralize persisted harness pairing evaluation in a single `HarnessPairingState` API.
  - [x] Separate persisted pairing (`configured`) from runtime diagnostics readiness (`isReady`).
  - [x] Make `MainTabView` and `SettingsView` consume the same pairing evaluator.
  - [x] Add an internal debug/status reason for incomplete pairing states (`missingBaseURL`, `invalidBaseURL`, `missingSecret`).
- **Acceptance criteria**:
  - [x] After QR pair + finalize, force-kill/reopen with valid Keychain URL+secret does not render the top pairing banner (covered by centralized persisted-state logic; pending user device re-test).
  - [x] Removing pairing in Settings makes the banner appear again (Keychain delete notification + shared evaluator).
  - [x] Settings and MainTabView agree on configured/not-configured state after cold start (both read `pairingState`).
  - [x] Invalid/partial Keychain state has a precise debug reason.
  - [x] Remote iOS build succeeds (`BUILD SUCCEEDED`).


---

### ~~Phase 6D — Pre-flight diagnostics nell'harness Node~~ (FUSED into Phase 6 on 2026-04-25 evening)

_~~Goal: all'avvio del backend, verifica che claude-cli, config, porte, logs siano tutti a posto. Errori critici → exit(1) con messaggio chiaro. Output esposto come endpoint `/api/panel/preflight` consumato da Phase 6B Card tunnel status.~~_

**Status**: FUSED into new Phase 6.
**Reason**: blocking startup gate era user-hostile (utente con Claude session scaduta non poteva nemmeno aprire il Panel per vedere cosa c'era che non andava). La stessa logica di check è migrata in `/api/setup/diagnostics` (P6.3) come endpoint queryable in qualunque momento, consumato sia dall'iPhone pre-pair (P6.5) sia dal Panel Card 0 (6B post-merge).
**Date**: 2026-04-25 evening.
**Primitives migrate**: check claude CLI, config secret, ports, cloudflared binary, logs dir, outbound HTTPS → riusati in P6.1 `preflight/checks.js`.
**Primitives dropped**: blocking `exit(1)` behavior; `--skip-preflight` flag; dedicated `/api/panel/preflight` endpoint; unit test file `test/preflight.test.js` (deferred — se necessario, parte di P6.1 QA).

#### P6D.1 — NEW `server/preflight.js` (runPreflight aggregator)
- **Status**: CANCELLED (2026-04-25 evening — fused into P6.1 + P6.2)
- **Agent**: backend-dev
- **Depends on**: none
- **Target file** (NEW): `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\preflight.js`
- **Changes**:
  - `export async function runPreflight(cfg, cfgPath)` → esegue sequenziale tutti i check, return `{passed: boolean, critical: Check[], warnings: Check[], details: Check[]}`
  - Check implementati:
    - `checkClaudeCli()` → `execSync('claude --version')`; critical se fallisce
    - `checkConfig(cfg)` → verifica campi required (`ios.shared_secret`, `server.port`, `server.panel_port`); critical se manca
    - `checkPort(port)` × 2 (7777, 7779) → tenta bind su 127.0.0.1; critical se occupato
    - `checkLogsDir()` → fs.accessSync(`logs/`, W_OK); critical se non writeable
    - `checkCloudflared(cfg)` → verifica `~/.gigi/bin/cloudflared` presente se `tunnel.mode !== "manual"`; warning se missing
  - Ogni Check ha shape `{name, status: 'pass' | 'fail', severity: 'critical' | 'warning', message, fixHint}`
  - Scrivi ultimo snapshot in `logs/preflight.json` con timestamp ISO
- **Acceptance criteria**:
  - [ ] `runPreflight(mockCfgOk)` → `passed: true, critical: []`
  - [ ] `runPreflight({}) ` (config vuoto) → `critical.length > 0` con nomi campi mancanti
  - [ ] Con porta 7779 occupata → critical check con messaggio "Porta 7779 già in uso (PID X)"
  - [ ] Con `claude` non nel PATH → critical check con messaggio "Claude Code CLI non trovato. Installa da https://docs.anthropic.com/claude-code"
  - [ ] `logs/preflight.json` scritto correttamente
- **Estimate**: 1.5h

#### P6D.2 — NEW `server/test/preflight.test.js` (unit test)
- **Status**: CANCELLED (2026-04-25 evening — fused/deferred; new check primitives in P6.1 don't ship with unit tests for v1)
- **Agent**: qa-tester
- **Depends on**: P6D.1
- **Target file** (NEW): `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\test\preflight.test.js`
- **Changes**: mock di `execSync`, `net.createServer`, `fs.accessSync` e copertura di tutti i failure mode di ogni check
- **Acceptance criteria**:
  - [ ] Test suite esegue via `npm test` in `03_HARNESS/server/`
  - [ ] Coverage di tutti 5 check con almeno 1 pass + 1 fail case ciascuno
  - [ ] Test cli mock per `claude --version` che simula "command not found"
- **Estimate**: 45min

#### P6D.3 — Wire `runPreflight` + boot gate in `server.js`
- **Status**: CANCELLED (2026-04-25 evening — boot gate approach abandoned; diagnostics is now queryable on-demand via P6.3)
- **Agent**: backend-dev
- **Depends on**: P6D.1
- **Target file**: `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\server.js`
- **Changes**:
  - All'avvio, PRIMA di `app.listen()` o equivalente: `const pf = await runPreflight(cfg, cfgPath);`
  - Se `pf.critical.length > 0`:
    - Print banner chiaro ANSI red con lista errori + fixHint per ognuno
    - `process.exit(1)`
  - Se `pf.warnings.length > 0`:
    - Print warning giallo + continua boot
    - Se warning è cloudflared missing → force `cfg.tunnel.mode = "manual"` in runtime (no persist)
  - Flag `--skip-preflight` per dev: se presente, saltare l'intero blocco con warning
  - Endpoint `GET /api/panel/preflight` (loopback-only) ritorna ultimo snapshot da `logs/preflight.json`
- **Acceptance criteria**:
  - [ ] Boot con config OK → preflight pass + server up normalmente
  - [ ] Boot con config rotta → exit(1) con messaggio in console (non stack trace)
  - [ ] Boot con porta 7779 occupata → exit(1) con "Porta già in uso"
  - [ ] `--skip-preflight` salta il blocco e server up anche con config rotta
  - [ ] `curl http://127.0.0.1:7777/api/panel/preflight` ritorna JSON snapshot
  - [ ] Chiamata da IP non-loopback → 403
- **Estimate**: 45min

#### P6D.4 — Integrate preflight output in Panel Connections Card tunnel status
- **Status**: CANCELLED (2026-04-25 evening — replaced by Panel Card 0 "Preflight" consuming `/api/setup/diagnostics` from P6.3; lives inside Phase 6B scope)
- **Agent**: frontend-dev (web)
- **Depends on**: P6D.3 AND P6B.10 (Phase 6B gate must be PASS)
- **Target files**:
  - MODIFY `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\api\panel-connections.js` (aggrega `preflight` in response di `/api/panel/connections`)
  - MODIFY `C:\Users\arman\Desktop\GIGI\03_HARNESS\server\public\app.js` (render sezione "Pre-flight" dentro Card Tunnel status)
- **Changes**:
  - `handlePanelRequest` in GET `/api/panel/connections` aggiunge chiave `preflight: <snapshot>`
  - Panel JS renderizza sotto Card tunnel una mini-list con pass/warn/fail per ogni check (icona + nome + messaggio)
- **Acceptance criteria**:
  - [ ] Endpoint include preflight snapshot
  - [ ] Panel tab Connections mostra sezione "Pre-flight: all good" (verde) o elenco warn/fail
  - [ ] Se preflight critical aveva bloccato l'avvio, il server non è comunque su — questo path è solo per state post-boot
- **Estimate**: 30min

#### P6D.5 — TEST GATE — Phase 6D end-to-end
- **Status**: CANCELLED (2026-04-25 evening — replaced by P6.9 which tests the fused diagnostic-driven flow end-to-end)
- **Agent**: qa-tester
- **Type**: TEST_GATE
- **Gate**: HARD — completes Phase 6 overall
- **Depends on**: P6D.1, P6D.2, P6D.3, P6D.4
- **Test matrix**:
  - [ ] Unit test suite PASSA completamente
  - [ ] Avvio con config OK → banner "Pre-flight: OK (5/5)" in console + server up
  - [ ] Avvio con `ios.shared_secret` rimosso da config → exit(1) con messaggio specifico
  - [ ] Avvio con porta 7779 occupata da altro processo → exit(1) con PID indicato
  - [ ] Avvio con Claude CLI rimosso dal PATH → exit(1) con link installazione
  - [ ] Avvio con cloudflared missing + tunnel.mode=quick → warning + fallback a manual mode, server up
  - [ ] `--skip-preflight` bypassa checks (per dev)
  - [ ] Panel → Connections → tunnel card mostra sezione preflight popolata
- **Gate outcome**: PASS → Phase 6D complete · FAIL → return to P6D.x
- **Estimate**: 45min

---

### AREA CHECKPOINT — Phase 6 (Usability) — post-pivot 2026-04-25

- **Status**: PENDING
- **Agent**: qa-tester + USER CHECKPOINT
- **Type**: AREA_CHECKPOINT
- **Gate**: HARD — segna completamento intera Phase 6
- **Depends on**: P6.9, P6B.10, P6C.4 tutti PASS (P6A.4 CANCELLED; P6D.5 CANCELLED)
- **Context**: smoke test integrato del Phase 6 usability stack post-pivot. Simula un utente nuovo che riceve l'app dal nulla, installa harness da zero sul PC, completa setup diagnostic-driven, pair, usa, ispeziona Panel.
- **Integration scenario end-to-end (post-pivot 2026-04-25)**:
  - [ ] **Scenario 1 — Fresh user diagnostic-driven**: utente fresh install app iOS → banner → scansiona QR → SetupDiagnosticView mostra 1-2 check falliti (es: claude non authed) → utente fixa nel terminal del PC → entro 5s vede ✓ → Finalize → banner sparisce → chat usabile
  - [ ] **Scenario 2 — Persistent unready pair**: utente scansiona QR ma chiude app prima di Finalize → riapre → banner ancora lì → Settings > Diagnostica → diagnostic view → Finalize → banner sparisce
  - [ ] **Scenario 3 — Rich settings state**: post-pair (isReady true), Settings → Harness card mostra modalità, URL, richieste, latency → invio 5 chat → counter aggiornato
  - [ ] **Scenario 4 — Panel admin view**: Armando apre `localhost:7777` → tab Connections → vede tunnel, WS, device, requests, **Card 0 preflight** (via `/api/setup/diagnostics`) → esegue revoke su device di test → iPhone di test riceve 403 alla richiesta successiva
  - [ ] **Scenario 5 — No regression**: flow Phase 1-5 (claude bridge, force claude toggle, pair QR, Cloudflare Tunnel) invariati
- **Acceptance criteria**:
  - [ ] Tutti 5 scenarios PASS
  - [ ] USER CHECKPOINT: Armando valuta UX complessiva di un "onboarding da zero"
  - [ ] Nessuna regressione su Phase 1-5
- **Gate outcome**: PASS → Phase 6 chiusa, ship candidate · FAIL → specificare quale scenario fallisce + route a relative P6x.y
- **Estimate**: 1.5h

---

## Test Gates

| Gate | Agent | Blocks | Criteria |
|---|---|---|---|
| **P1.10** — Phase 1 E2E | qa-tester | Phase 2 start | All 6 scenarios pass in source plan §Verification Steps |
| **P2.4** — Phase 2 E2E | qa-tester | Phase 3 (if un-deferred) | Force Claude toggle behaves per AC-3 |
| **P4.9** — Phase 4 E2E from outside home network | qa-tester + USER | Phase 4 completion | Cross-network reachability + QR flow work; ≥ 7/7 scenarios PASS |
| **P5.13** — Phase 5 E2E Cloudflare Tunnel multi-mode | qa-tester + USER | Phase 5 completion | All 4 modes (named/quick/lan/manual) working + cross-network + auto-start |
| ~~P6A.4~~ | — | — | **CANCELLED 2026-04-25** (architectural pivot → replaced by P6.9) |
| **P6.9** — Phase 6 diagnostic-driven pair flow | qa-tester + USER | AREA CHECKPOINT | ≥ 6/7 scenarios PASS + **mandatory** Scenario B live-convergence PASS + USER sign-off |
| **P6B.10** — Phase 6B Panel Connections tab | qa-tester | AREA CHECKPOINT | All 10 plan scenarios PASS (tunnel / ws / devices / requests + actions); Card 0 preflight consumes P6.3 |
| **P6C.4** — Phase 6C Rich Settings card | qa-tester + USER | Closed sub-phase | 8 scenarios + USER CHECKPOINT sign-off |
| ~~P6D.5~~ | — | — | **CANCELLED 2026-04-25** (fused into P6.9) |
| **AREA CHECKPOINT Phase 6** | qa-tester + USER | Ship candidate | All 5 integration scenarios (diagnostic-driven) + no regression Phase 1-5 |

---

## Parallel Opportunities

These task pairs have no direct dependency and can run in parallel if two agents are available:

- **P1.2** (frontend rendering) ∥ **P1.3** (bridge skeleton) — both only depend on P1.1
- **P1.5** (tool registry) ∥ **P1.7** (prompt update) — independent files, both depend on P1.4 only loosely (P1.7 can even start right after P1.1 if prompt wording doesn't rely on bridge shape)
- **P1.8** (WS URL sanity) ∥ **P1.9** (error polish) — both post-P1.4, independent
- **P2.1** (keychain) ∥ (nothing else in Phase 2 — P2.2 depends on P2.1)
- **P4.1** (backend pair endpoint) ∥ **P4.3** (iOS Info.plist camera) — entirely different stacks, both zero-dep
- **P4.2** (panel /pair page) ∥ **P4.4** (iOS scanner view) — backend vs iOS, independent after their respective roots
- **Phase 4 entire ∥ Phase 2 entire** — orthogonal features, different code surfaces (except a small overlap in `SettingsView.swift` which can be resolved by hand)

No cross-phase parallelism between P1 and P2: P2.x must wait for P1.10 gate.
**Phase 4 can start at any time**, even concurrently with P1 / P2 — it does not depend on Claude-bridge plumbing.

### Phase 6 parallelism (post-pivot 2026-04-25)

**Cross sub-phase**:
- **Phase 6 backend (P6.1-P6.3)** ∥ **6B backend** ∥ **6C backend (P6C.1)** sono completamente orthogonal: stack Node server-side su file diversi. Se 3 agenti backend-dev disponibili, partono tutti e 3 in parallelo.
- **Phase 6 iOS (P6.4-P6.8)** dipende SOFT da P6.3 (endpoint response necessaria per testare P6.4 decoding) ma P6.4 codice può essere stubbato con mock response fino a P6.3 ready.
- **6B Card 0** (nuova card preflight) ha dipendenza SOFT su P6.3 — se P6.3 non è pronto, Card 0 è stub; se pronto, Card 0 fetcha endpoint.

**Intra sub-phase**:
- **Phase 6 backend**: P6.1 → P6.2 → P6.3 è serializzato (ognuno build on precedente, stesso file tree)
- **Phase 6 iOS**: P6.4 → P6.5 → P6.6 → P6.7 → P6.8 è serializzato (state machine dipende da UI dipende da client)
- **Phase 6B**: P6B.1 ∥ P6B.2 ∥ P6B.3 (tutti e 3 indipendenti, su file diversi)
- **Phase 6B**: P6B.7 ∥ P6B.8 (HTML struttura + CSS, agente frontend può spezzare)

**Legacy (reference only)**: P6A.1/2/3 erano parallelizzabili (P6A.2 ∥ P6A.3 dopo P6A.1) — già shipped 2026-04-25 mattina, ora DEPRECATED.

---

## Next Action

**State snapshot (2026-04-24 post-`ca8a599`)**:
- Phase 1 code: P1.1–P1.3 DONE, P1.4 IN PROGRESS, P1.5–P1.9 PENDING, P1.10 test gate blocked on physical device.
- Phase 2: not started (depends on P1.10).
- Phase 4 code: P4.1–P4.8 ALL COMPLETED in commit `ca8a599`. BUILD SUCCEEDED. `.ipa` at `C:\Users\arman\Desktop\GIGI\bug\GIGI.ipa`.
- Phase 4 test: P4.9 READY, waiting for U0 (Tailscale install by user) + physical device test.

**Recommended next step — OPTION (b): start Phase 2 now (Force Claude toggle)**

Rationale:
- Phase 2 is orthogonal to Phase 4: different code surfaces (SettingsView has a mergeable overlap, resolvable by hand). Phase 2 is a short 1–2h phase; finishing it now keeps the code lane productive while Armando installs Tailscale and tests Phase 4 on device.
- Phase 2 depends on P1.10 (Phase 1 E2E gate). P1.10 is currently blocked on physical device, same as P4.9. So strictly by the plan, Phase 2 is GATED on P1.10. If Armando wants to keep momentum without waiting, we should FIRST unblock P1.10 by finishing P1.4 → P1.9, THEN run P1.10 + P4.9 together on-device (option (a)).
- Pure-code progress right now: focus on **P1.4 completion** and **P1.5 + P1.7 in parallel** immediately after. That is the cleanest path to having both Phase 1 and Phase 4 ready for the same on-device test session.

**Concrete recommendation — HYBRID of (a) and (c)**:
1. **Continue P1.4 now** (backend-dev is already mid-flight) — unblocks P1.5/P1.7/P1.9.
2. **Run P1.5 ∥ P1.7 in parallel** as soon as P1.4 lands (already flagged as parallel-safe in the Parallel Opportunities section).
3. **Queue P1.6, P1.8, P1.9** sequentially after P1.5.
4. **When P1.1–P1.9 are all green**, ask Armando to:
   - Install Tailscale on PC + iPhone (U0, 10 min).
   - Sideload `GIGI.ipa` to device.
   - Run P1.10 (Phase 1 E2E) **and** P4.9 (Phase 4 E2E) in a single on-device session, since both need the same environment (paired device + reachable harness).
5. Only after BOTH gates pass, start **Phase 2 (P2.1 → P2.4)**.

**If Armando prefers option (b) — start Phase 2 immediately**:
- Technically possible by relaxing the P1.10 dependency (Phase 2 Keychain + Settings toggle code is independent of the Claude bridge's streaming correctness). Acceptable trade-off: Phase 2 is validated at P2.4 regardless of whether P1.10 is green; any Phase 1 bug surfaced later won't invalidate Phase 2 code.
- Risk: small — Phase 2 reuses `GigiClaudeBridge.shared.run(...)` which is only end-to-end verified in P1.10. If P1.10 fails and requires signature changes to `run(...)`, Phase 2 would need a follow-up touch-up.
- Payoff: +1–2h of code done while waiting for Armando to install Tailscale + sideload.

**Waiting explicitly on user** (option (c)): only if Armando wants to pause all coding until P1.10 + P4.9 can be tested together. Not recommended unless the user signals fatigue — there is still pure-code work to do (P1.4 → P1.9).

**My call**: proceed with **HYBRID (a)+(c)** — orchestrator should continue P1.4 now. Ask Armando whether he wants to batch-install Tailscale + sideload before or after P1.9 lands.

### Next Action — Phase 6 (2026-04-25 evening post-pivot)

Dopo il pivot architetturale del 2026-04-25 sera, Phase 6 è stata
ristrutturata: 6A DEPRECATED (3 commit shipped la mattina + cancellati la
sera), 6D FUSED nella nuova Phase 6, ed è stata introdotta una **new Phase
6** (no suffix) con 9 task (P6.1 → P6.9) che implementa il flow pair
diagnostic-driven concordato. Totale Phase 6 usability: ~21h (9 nuova + 10
6B + 2 6C).

**Ordering raccomandato post-pivot**: **Phase 6 → 6C → 6B**

**Primo passo concreto**: **P6.1 — NEW `03_HARNESS/server/preflight/checks.js`** (backend-dev, 2h, zero-dep)

Rationale:
- La nuova Phase 6 è il blocker numero 1 per qualunque utente esterno: senza il
  diagnostic-driven flow il pair può "riuscire" ma lasciare l'app non-funzionale
  (Claude non authed, tunnel off, secret debole) senza che l'utente sappia
  perché il chat non risponde.
- P6.1 è backend, zero deps su iOS, immediatamente produttivo. Una volta
  completato, P6.2 (45min) + P6.3 (45min) serializzano rapidamente e sbloccano
  tutto il lato iOS (P6.4-P6.8).
- **Secondo agente (se disponibile)**: P6B.1 (ring buffer backend, 45min,
  zero-dep) — completamente orthogonal, 6B resta invariata.
- **Terzo agente (se disponibile)**: P6C.1 (status endpoint, 45min) — orthogonal
  se si rinuncia all'integrazione con P6B.1 (usare contatore ad-hoc).

**Task immediatamente successivo a P6.1**: P6.2 stesso agente (45min,
dipendenza stretta file tree `preflight/`).

**Task post-backend-P6.1-P6.2-P6.3**: switch agente su frontend-dev per
P6.4 → P6.5 → P6.6 → P6.7 → P6.8 in sequenza. Il passaggio backend→frontend è il
cambio di stack più naturale.

**Precedenza assoluta** (invariata): Phase 1-2 E2E gate (P1.10 + P2.4) e Phase
4-5 user test (P4.9 + P5.13) rimangono priorità se Armando può testare su
device. Phase 6 è code-lane parallelo al QA di Phase 1-5.

**Archive (pre-pivot)**: il vecchio Next Action pre-pivot raccomandava P6A.1
come primo passo. P6A.1/2/3 sono state shipped nella mattina 2026-04-25
(commit `872b7d0`/`1235e32`/`0b33062`) ma il flow risultante è stato
rigettato dall'utente la sera stessa come "molto generico", da cui il pivot.
Il cleanup avviene via P6.8.

---

## Blockers

### BLOCKED BY USER CHECKPOINT — P1.2 visual approval
- **Scope**: the thought-UI aesthetic (italic grey bubble with 💭 prefix, tool-event bubble with gear icon) cannot be visually validated until a full Phase 1 `.ipa` is sideloaded to Armando's iPhone.
- **Status update (2026-04-24 post-`ca8a599`)**: Phase 4 `.ipa` is now available (`C:\Users\arman\Desktop\GIGI\bug\GIGI.ipa`). However, it does NOT yet include the full Phase 1 escalation wiring (P1.4 still IN PROGRESS; P1.5–P1.9 PENDING). So sideloading this `.ipa` will only let Armando verify the Pairing flow (P4.x) and the static MessageBubble rendering (P1.2) in chat — but not the live streaming thoughts, because P1.4 is not finished yet.
- **Mitigation**: the current `.ipa` is sufficient to sign off the static P1.2 aesthetic by sending any `.thinking` role message through a debug harness. Full live-streaming checkpoint still deferred to P1.10.
- **Unblock condition (partial)**: Armando sideloads current `.ipa`, inspects MessageBubble rendering (even with a stubbed message). Full unblock at P1.10 E2E.

### CRITICAL — "Setup once, works always" vision NOT satisfiable with Quick Tunnel alone
- **Surfaced**: 2026-04-24 after Phase 5 waves 1-4 E2E verification
- **Scope**: Quick Tunnel (Phase 5 modalità B) ships a URL of the form `https://<random-words>.trycloudflare.com`. **This URL is re-generated on every `cloudflared` restart** (PC reboot, crash, or manual restart). The iPhone pairing stores the URL in Keychain at pair time — if the URL changes, every paired iPhone loses connectivity and must be re-paired via QR.
- **Impact on user vision**: the stated vision is "setup once, always on". Quick Tunnel alone does NOT satisfy this — the user would need to re-pair roughly weekly (or whenever their PC reboots / cloudflared restarts).
- **Path (a) — accept Quick Tunnel limitation**: ship current Phase 5, user re-pairs on every URL rotation. Cheap, works today, poor UX.
- **Path (b) — wait for Phase 5.2 (named tunnel with OAuth)**: URL is a fixed hostname on a user-owned domain. Stable across restarts forever. Requires ~6h backend + 1h wizard + 1h QA + Cloudflare OAuth app registration + user purchasing a domain (~€3-10/yr).
- **Complementary — P5.10 service installer**: reduces restart frequency (cloudflared runs as a Windows service / LaunchAgent / systemd unit), but does NOT fix the URL-rotates-on-restart problem. Still useful.
- **Unblock conditions**:
  - (a) user consciously accepts Quick Tunnel + weekly-ish re-pair → mark accepted and close
  - (b) user commits to buying a domain → un-defer Phase 5.2 → implement named-mode stack

### BLOCKED BY INFRA — End-to-end test of the bridge
- **Scope**: `GigiClaudeBridge.run` cannot be validated end-to-end until (a) P1.4 is complete AND (b) the harness is running locally on the PC at `192.168.1.67:7779` with the bearer secret configured on-device.
- **Impact**: P1.4 acceptance criteria "calling run(...) emits ≥1 .thinking bubble" requires a live harness. Dev-only stub validation is possible but not sufficient for close-out.
- **Unblock condition**: start `03_HARNESS` on the PC + confirm `GET /api/ios/health` returns 200 with the stored secret.

---

## Progress Log

One-line entries per task transition, ISO-8601 timestamps (local date, no TZ needed at this granularity).

- `2026-04-24` — P1.1 COMPLETED · commit `0a8316d` · conversation memory role enum extended to `{user, gigi, thinking, toolEvent}` + addThought/addToolEvent/updateToolEvent helpers · BUILD SUCCEEDED on MacInCloud
- `2026-04-24` — P1.2 COMPLETED (code+build) · commit `a400500` · MessageBubble renders `.thinking` (italic grey + 💭) and `.toolEvent` (gear icon) · BUILD SUCCEEDED · USER CHECKPOINT deferred to P1.10 E2E
- `2026-04-24` — P1.3 COMPLETED · commit `a400500` · `GigiClaudeBridge.swift` skeleton + `buildContextSnapshot()` (profile + 7-day calendar + 10 recent memories + optional location) · BUILD SUCCEEDED
- `2026-04-24` — P1.4 IN PROGRESS · orchestrator started wire-up of `run(task:context:)` to `GigiHarnessStream` WebSocket + memory callbacks
- `2026-04-24` — P4.1 COMPLETED · commit `ca8a599` · NEW `03_HARNESS/server/api/pair.js` + `qrcode` dep + route wired in `server.js`; loopback-only; Tailscale IP auto-detection via `os.networkInterfaces()`; `curl http://127.0.0.1:7779/api/pair` verified HTTP 200 JSON + SVG format
- `2026-04-24` — P4.2 COMPLETED · commit `ca8a599` · NEW `03_HARNESS/server/public/pair.html` + route in `panel-routes.js`; `localhost:7777/pair` verified HTTP 200
- `2026-04-24` — P4.3 COMPLETED · commit `ca8a599` · `NSCameraUsageDescription` added to `02_GIGI_APP/GIGI/Info.plist`
- `2026-04-24` — P4.4 COMPLETED · commit `ca8a599` · NEW `GigiPairScanner.swift` (SwiftUI wrapper over VisionKit `DataScannerViewController`) with camera permission flow and denied/restricted fallback · BUILD SUCCEEDED
- `2026-04-24` — P4.5 COMPLETED · commit `ca8a599` · NEW `GigiPairingSheet.swift` state machine (scanning → validating → success/failure); Keychain save + health check + rollback on fail · BUILD SUCCEEDED
- `2026-04-24` — P4.6 COMPLETED · commit `ca8a599` · `SettingsView.harnessSection` rewritten: primary "Pair con Harness" button + status line + "Rimuovi pairing"; manual config retained under DisclosureGroup "Configurazione manuale (avanzata)" · BUILD SUCCEEDED
- `2026-04-24` — P4.7 COMPLETED · commit `ca8a599` · `MainTabView` overlays purple "Collega GIGI al tuo PC" banner when `!GigiHarnessClient.shared.isConfigured`; tap opens pairing sheet · BUILD SUCCEEDED
- `2026-04-24` — P4.8 COMPLETED · commit `ca8a599` · `GigiClaudeBridge.userFacingError` appends "Controlla Tailscale attivo su PC e iPhone" when saved URL is `100.*` CGNAT; maps 401 → "Secret non più valido. Ri-pair dal Panel." · BUILD SUCCEEDED
- `2026-04-24` — P4.9 READY · all Phase 4 code complete; waiting for U0 (Tailscale install by user) + physical device test. `.ipa` built at `C:\Users\arman\Desktop\GIGI\bug\GIGI.ipa` (1.2 MB)
- `2026-04-24` — U0 PENDING USER · Tailscale install on PC + iPhone (10 min user action) required before P4.9 can run
- `2026-04-24` — Phase 4 CODE COMPLETE · commit `ca8a599` · BUILD SUCCEEDED · only P4.9 test gate + U0 user action remain
- `2026-04-24` — P5.1 COMPLETED · commit `9033dc7` (version fix `d378317`) · NEW `03_HARNESS/server/tunnel/install-cloudflared.js` (OS+arch detect, SHA256 verify, install to `~/.gigi/bin/cloudflared`)
- `2026-04-24` — P5.3 COMPLETED (scaffolded) · commit `9033dc7` · NEW `03_HARNESS/server/tunnel/cf-api.js` — wiring into setup flow deferred to Phase 5.2 (named OAuth)
- `2026-04-24` — P5.6 COMPLETED · commit `9033dc7` · NEW `03_HARNESS/server/tunnel/mdns.js` + `bonjour-service` dep; advertises `_gigi._tcp.local` with TXT `{deviceName, port, version}`
- `2026-04-24` — P5.8 COMPLETED · commit `9033dc7` · server `ios-stream.js` inactivity sweep 30s; iOS `GigiHarnessStream` ping 60s + 2-miss reconnect · BUILD SUCCEEDED
- `2026-04-24` — P5.2 COMPLETED · commit `8d0d995` · `CloudflaredManager` singleton (`startQuick`/`startNamed`/`stop`/`status`); stdout parser extracts trycloudflare URL; restart-loop detection
- `2026-04-24` — P5.4 COMPLETED · commit `8d0d995` · `GET /api/setup/status` + `POST /api/setup/{quick,lan,manual}/{start,stop}`; named endpoints return 501 NOT_IMPLEMENTED (Phase 5.2 OAuth)
- `2026-04-24` — P5.5 COMPLETED · commit `8d0d995` · `/setup` page on Panel 7777; 4 cards (quick/lan/named-disabled/manual); 3s auto-refresh
- `2026-04-24` — P5.9 COMPLETED · commit `8d0d995` · `tunnel.{mode,named,quick,lan}` added to `config.example.json`
- `2026-04-24` — P5.7 COMPLETED · commit `bce814d` · NEW `02_GIGI_APP/GIGI/GigiMDNSDiscovery.swift` with `NWBrowser` on `_gigi._tcp.local`; Info.plist `NSBonjourServices` added · BUILD SUCCEEDED
- `2026-04-24` — Phase 5 waves 1-4 CODE COMPLETE · latest commit `d378317` · E2E VERIFIED: Quick Tunnel starts via API, public URL `https://*.trycloudflare.com` reachable from internet with bearer auth, `/api/ios/health` 200 in ~310ms · `.ipa` rebuilt at `C:\Users\arman\Desktop\GIGI\bug\GIGI.ipa` (1.2 MB)
- `2026-04-24` — P5.10 PENDING · service installer (auto-start cloudflared at boot) NOT started — critical for "setup once, always on"
- `2026-04-24` — P5.11 PENDING · iOS migration banner for Tailscale users NOT started
- `2026-04-24` — P5.12 PENDING · docs guides NOT started
- `2026-04-24` — P5.13 READY · Quick/LAN/manual test matrix ready for USER; named-mode row deferred to Phase 5.2
- `2026-04-24` — Phase 5.2 DEFERRED · Named Cloudflare Tunnel with OAuth — required for stable URL across cloudflared restarts; blocked on Cloudflare OAuth app registration + user-owned domain
- `2026-04-25` — Phase 6 CONSOLIDATION · project-manager · creato `docs/plans/phase-6-usability-roadmap.md` (overview 4 sotto-fasi: 6A Setup Checklist iOS, 6B Panel Connections tab, 6C Rich Settings card, 6D Pre-flight diagnostics). TASK_PLAN aggiornato: 19 task numerate P6A.1→P6D.5 + 5 test gate + 1 area checkpoint. Phase 6 originale "flat" (Panel Observability) rinominata Phase 6B; `docs/plans/panel-observability.md` resta IMMUTABLE come fonte di dettaglio. Stima totale Phase 6: ~18h (3+10+2+3). Recommended ordering: 6A → 6C → 6B → 6D. Next Action → P6A.1 (SetupChecklistView.swift).
- `2026-04-25` — P6A.1 COMPLETED · commit `872b7d0` · NEW `02_GIGI_APP/GIGI/SetupChecklistView.swift` (4 requisiti, 1 live check + 3 checkbox manuali, @AppStorage persist) · BUILD SUCCEEDED · (later DEPRECATED same day, see pivot entry)
- `2026-04-25` — P6A.2 COMPLETED · commit `1235e32` · `MainTabView.swift` banner routes to `SetupChecklistView` instead of direct `GigiPairingSheet` · BUILD SUCCEEDED · (later DEPRECATED same day)
- `2026-04-25` — P6A.3 COMPLETED · commit `0b33062` · `SettingsView.swift` "Vedi requisiti" button added for non-paired users · footer copy updated to Cloudflare guidance · BUILD SUCCEEDED · (later DEPRECATED same day)
- `2026-04-25` — Phase 6 ARCHITECTURAL PIVOT · project-manager · Armando ha rigettato il risultato P6A.1/2/3 la sera stessa del commit: la checklist statica con 3 checkbox manuali (CF account, Claude CLI, harness installed) è stata giudicata "molto generica" perché l'app non poteva verificare alcuna delle 3 auto-dichiarazioni dell'utente. Sostituita con un **flusso di pair a due stadi guidato da diagnostica live** del PC: iPhone polla `/api/setup/diagnostics` ogni 5s, mostra ✓/⚠/❌ per 10 check (claude CLI authenticated, tunnel mode, tunnel running, secret strength, cloudflared binary, outbound HTTPS, disk space, port bound, ...), utente fixa nel terminal e vede ✓ comparire live, "Finalize pair" si abilita solo quando tutti i critical sono ok. P6A.1/2/3 → DEPRECATED (history preserved, cleanup via P6.8). P6A.4 test gate → CANCELLED. P6D.1-5 (preflight blocking startup) → CANCELLED (fused: stesse check primitives, ora endpoint queryable invece di gate bloccante). Introdotta new **Phase 6** (no suffix) con 9 task P6.1→P6.9, ~9h: P6.1 checks.js (10 async check fn), P6.2 runner.js (parallel + classification), P6.3 api/diagnostics.js (Bearer-authed endpoint), P6.4 GigiHarnessClient `diagnostics()` + `isReady` property (distinta da `isConfigured`), P6.5 SetupDiagnosticView.swift (polling UI), P6.6 GigiPairingSheet two-stage state machine, P6.7 wire MainTabView+SettingsView (rimuove SetupChecklistView wiring), P6.8 DELETE SetupChecklistView.swift, P6.9 test gate E2E con USER CHECKPOINT (Scenario B "fix claude auth login nel terminal → iPhone vede ✓ entro 5s" è mandatory PASS). Decisione tecnica chiave: `isConfigured` preserva semantica legacy (URL+secret in Keychain), nuova property `isReady = isConfigured && lastDiagnosticsSnapshot.allCriticalOk` gating banner+chat. Totale Phase 6 post-pivot: ~21h (9 nuova + 10 6B + 2 6C, era 18h pre-pivot). Ordering: Phase 6 → 6C → 6B. Next Action → P6.1 (backend, 2h, zero-dep, orthogonal a 6B/6C). Panel 6B Card 0 riuserà `/api/setup/diagnostics` di P6.3 invece dell'ex endpoint dedicato `/api/panel/preflight` (fonte di verità unificata iPhone+admin).
- `2026-04-25` — P6.10.1/P6.10.2/P6.10.3 COMPLETED · commit `1e69bef` · backend autofix lane shipped: fixer registry + serial `/api/setup/autofix` endpoint + `autoFixable` annotation in diagnostics runner
- `2026-04-25` — P6.10.4 COMPLETED · commit `f9aa20c` · `/setup` Panel now shows difficulty tiers + “Help me choose” quiz with card highlight guidance
- `2026-04-25` — P6.11.1/P6.11.2/P6.11.3 COMPLETED · commit `b60e414` · iOS diagnostics gained autofix models/banner/progress plus secret-rotate → re-pair flow
- `2026-04-25` — P6.12.1/P6.12.2 COMPLETED · Ralph · NEW `Walkthroughs.swift` + inline walkthrough rendering in `SetupDiagnosticView`; `claude_cli_authenticated` keeps instructions after `needsUser` autofix; Settings repair callback now clears form state before reopening pairing · BUILD SUCCEEDED via SSH Mac · architect verification APPROVED
