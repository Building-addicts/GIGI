# GIGI

> Voice agent for iPhone that delegates to a Node.js harness on your Mac.
> Apple Foundation Models routes every utterance through 5 paths (native iOS
> action / local Ollama reasoning / cloud Claude Code with MCP browser /
> clarification / refuse). 100% Swift app, no API keys to pay, Apache 2.0.

```
┌──────────────────────────────────────────────────────────────────────┐
│                          GIGI v0.1.0-rc                              │
│       Apple FM router upfront · 5-path · OSS-friendly · iOS 26+      │
└──────────────────────────────────────────────────────────────────────┘
```

## What it does

You hold the GIGI app on your iPhone and talk to it. Behind the scenes:

1. **Path 1 — NLU fast-path** (24 intents, on-device, ~80ms).
   "What time is it" → speech answer in <500ms.

2. **Path 2 — Apple Foundation Models Tool calling** (16 tools, iOS 26+).
   "Set a timer for 5 minutes" → Apple FM picks `set_timer`, extracts duration,
   schedules iOS notification. <1.5s round-trip.

3. **Path 3 — Ollama on your Mac** (Qwen 3 14B default, tier-based).
   "Explain Bayes theorem in three sentences" → harness streams a response
   from a local model. 7-15s. Zero cloud, zero API.

4. **Path 4 — Claude Code subprocess + MCP browser** (subscription, no API key).
   "Search Wikipedia for Tesla and create a note about his most important
   invention" → Claude Code spawns on your Mac, navigates Wikipedia, returns
   summary; then GIGI auto-creates the note via Apple FM `create_note` tool.
   The killer demo. 30-90s.

5. **Path 5 — Clarification / refusal**.
   "Maybe set something" → "When would you like me to set it?"
   "Buy bitcoin" → "I can't make financial transactions for you."

The Apple FM **router** (constrained `@Generable` schema) decides which path
to use for every utterance, based on cost-aware rules: complexity ≤40 and no
browser/code/vision → Ollama; else → Claude Code.

## Quick start (≤30 min)

```bash
git clone https://github.com/Building-addicts/GIGI.git
cd GIGI
bash scripts/setup-oss-demo.sh    # 10-step OSS wizard
```

The wizard checks Node 20+, Claude Code CLI, Playwright + Chromium, Ollama +
your RAM (proposes a model tier), `ANTHROPIC_API_KEY` (unsets it to avoid
silent API billing), generates `.env.example`, runs `npm install`, and pings
the harness health endpoint. Idempotent — re-run anytime.

Then:

```bash
cp .env.example .env
# Set HARNESS_SHARED_SECRET (openssl rand -hex 32)
./start-harness.sh
```

Open the GIGI app on your iPhone (iPhone 15 Pro+ recommended for Apple
Intelligence support, iOS 26.2+). Pair via QR (Settings → Harness → Pair).
Pick an operating mode (Settings → Modes). Talk.

## Operating modes

| Mode              | Paths active           | Requirements                                |
|-------------------|------------------------|---------------------------------------------|
| **Minimal**       | NLU + Claude Code      | Claude Code subscription                    |
| **Local-First**   | NLU + Apple FM + Ollama| Apple Intelligence + Ollama on harness      |
| **Apple Optimized** | NLU + Apple FM + Claude | Apple Intelligence + Claude Code subscription |
| **Full Power**    | All 5 paths            | All three above                             |

The mode is auto-detected at boot and proposed in onboarding. You can switch
any time in Settings → ⚙️ Modes; the router picks up the change without an
app restart.

## Architecture

```
iPhone (Swift / SwiftUI)
├── GigiAgentEngine.process(text)
│   ├── DEBUG: Brain Path Override (auto / appleFM / ollama / claude)
│   ├── Gate 1: NLU fast-path (24 intents)
│   └── Gate 2: GigiRequestRouter.route(text, history)  ← Phase 2
│         ├── Apple FM router → FoundationRouterDecision (or
│         │                       GigiFallbackRouter keyword fallback)
│         ├── Mode gate (current mode disables paths)
│         └── Dispatch:
│             ├── native_tool       → Apple FM Tool calling (Path 2)
│             │                       OR GigiActionBridge.execute (slot path)
│             ├── delegate_local    → GigiHarnessClient.runLocalLLM → Ollama
│             ├── delegate_cloud    → GigiHarnessClient.runClaudeCode → Claude Code
│             │                       + 2-turn callback if "research + action"
│             ├── ask_clarification → speak directSpeech
│             └── reject            → speak directSpeech
│
└── Settings: pairing, modes, debug, Ollama tier, etc.

Mac harness (Node.js 20+, ES modules)
├── server/
│   ├── server.js          - HTTP+WS on :7779, panel admin :7777
│   ├── claude-runner.js   - spawnClaude / runClaude with MCP support
│   ├── api/
│   │   ├── ios-router.js  - Bearer-auth + CORS dispatcher
│   │   ├── ios-agent.js   - POST /agent/run (legacy bridge)
│   │   ├── ios-claude-agent.js - POST /agent/claude SSE (Path 4)
│   │   ├── ios-local-llm.js    - POST /local-llm/generate SSE (Path 3)
│   │   ├── ios-memory.js  - put/query/delete LLM memory
│   │   └── ios-stream.js  - WS /ws/ios/stream broadcast
│   └── local-llm/
│       └── ollama-client.js - HTTP wrapper for local Ollama daemon
├── browser-pool/          - Playwright Chrome pool (MCP harness-browser)
├── apns/                  - Apple Push Notifications
└── memory/                - long-term memory store
```

See `docs/plans/frolicking-stargazing-pancake.md` and
`docs/taskplans_new_gigi/INDEX.md` for the full design.

## Hardware requirements

- **iPhone**: 15 Pro / 15 Pro Max / 16 series / 17 series. iOS 26.2+ recommended.
  Apple Intelligence enabled (Settings → Apple Intelligence & Siri → on).
  Earlier iPhones still work via the keyword fallback router but lose Path 2.
- **Mac**: Apple Silicon recommended (M1/M2/M3/M4). 16GB+ RAM for default
  Ollama tier (Qwen 3 14B). 32GB+ for the pro tier (Qwen 3.6 27B).
- **Network**: iPhone + Mac on the same LAN, OR Cloudflare Tunnel
  (instructions in `docs/runbooks/`).

## Privacy

- **Path 1** (NLU): 100% on-device.
- **Path 2** (Apple FM): runs on-device or via Apple Private Cloud Compute (PCC).
  Apple's PCC is opaque to the app — GIGI cannot certify a query stayed local.
  That's why "Local-First Mode" is the honest name (not "Privacy Max").
- **Path 3** (Ollama): 100% on your LAN. Nothing leaves the Mac.
- **Path 4** (Claude Code): goes to Anthropic via your Claude Code
  subscription. The harness `start-harness.sh` `unset`s `ANTHROPIC_API_KEY`
  to prevent silent API billing (Issue claude-code#45572).

No telemetry. No analytics. No third-party SDKs at runtime.

## OSS demo recipe (Tesla → note)

The "wow" moment. Pronounce:

> "Search Wikipedia for Nikola Tesla and create a note about his most
> important invention"

What happens:

1. Apple FM router → `path: delegate_cloud, capabilities: [browser, web_search]`
2. Path 4 spawns Claude Code on the Mac with MCP `harness-browser`
3. Claude Code navigates Wikipedia, extracts the invention, returns summary
4. Multi-step callback detection fires (because of "create a note" in original)
5. Path 2 Apple FM `create_note` dispatched with title="Nikola Tesla", body=summary
6. Notes app opens on the iPhone, summary on clipboard, user pastes

Total latency: 30-90s. See `docs/research/gate-6-killer-demo.md` for the
full script + 4 other scenarios (weather → reminder, news → email, recipe
→ reminder, score → note).

## What's implemented (2026-05-12)

Phase 2 + Phase 4 scaffold landed during the May 11-12 overnight sprint:

- ✅ `FoundationRouterDecision` + `ActionSlots` @Generable schemas
- ✅ `GigiRequestRouter` 5-path dispatch + slot mapping + mode gating
- ✅ `GigiFallbackRouter` keyword-based router for non-Apple-FM devices
- ✅ 16 `FM*Tool` Apple FM Tool struct (Q2 + create_note for killer demo)
- ✅ Ollama Path 3: `ollama-client.js` + `ios-local-llm.js` SSE + iOS consumer
- ✅ Claude Code Path 4: `ios-claude-agent.js` subprocess + MCP wiring
- ✅ Modes UI: `ModesSelectionView`, `GigiModeDetector`, Settings → Modes
- ✅ Multi-step callback (GATE 6): "research + action" patterns auto-chain
- ✅ Setup wizard: `scripts/setup-oss-demo.sh` 10-step idempotent
- ✅ `@anthropic-ai/sdk` removed (was burning API per turn) — Claude Code subscription only
- ✅ `unset ANTHROPIC_API_KEY` in `start-harness.sh` (Issue claude-code#45572)

What's still pending (post-v0.1.0):

- 📋 Spike A — Apple FM iOS 26.x regression empirical test (50 queries × 3 runs)
- 📋 Spike B — Qwen 3 14B BFCL accuracy + loop rate validation
- 📋 GATE 6 device E2E (5 scenarios)
- 📋 Confirm gating UI integration (ConfirmComputerUseSheet wired client-side
  but the harness scaffold doesn't emit `confirm_required` events yet —
  needs Claude CLI feature)

## Documentation

- `docs/HOW_GIGI_WILL_WORK.md` — narrative PM-friendly walkthrough (Italian)
- `docs/plans/frolicking-stargazing-pancake.md` — master 5-path plan
- `docs/taskplans_new_gigi/INDEX.md` — 8 GATE task plans + status
- `docs/adr/` — architectural decisions (0001-0012)
- `docs/research/` — empirical validation skeletons + integration tests
- `docs/HANDOFF_2026-05-12.md` — implementation handoff from the overnight sprint
- `03_HARNESS/CLAUDE.md` + `03_HARNESS/README.md` — harness details

## Contributing

See `CONTRIBUTING.md`. PRs welcome on the `armando-rework` branch.

## License

Apache 2.0. See `LICENSE`.

## Acknowledgements

- Apple Foundation Models team for the `@Generable` Tool protocol API
- Ollama team for the Qwen 3 ecosystem support
- Anthropic for Claude Code CLI + MCP
- The Building-addicts team (@ArmandoBattaglino, @leozz37, @federicoanderlini)
