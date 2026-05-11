# GATE 2 — Router upfront integration test (10 query)

> **Status**: template (to be filled in on device)
> **Purpose**: verify `GigiRequestRouter.route()` end-to-end on a real iPhone with Apple FM enabled. Lighter than Spike A — 10 queries × 1 run = 10 trials, focused on dispatch accuracy and log fidelity rather than statistical confidence.
> **Pre-req**: GATE 0 build verified, IPA installed, harness paired, Brain Path Override = `auto`.

## Test set

| # | Query | Expected path | Expected action / capabilities | Expected dispatch |
|---|---|---|---|---|
| 1 | "Set a timer for 5 minutes" | native_tool | set_timer + slots.duration="5 minutes" | NLU fast-path hit (skip router); notifica iOS 5min |
| 2 | "What time is it" | (NLU fast-path) | ask_time | NLU fast-path hit; speak "It's HH:MM" in <500ms |
| 3 | "Send a message to Marco on WhatsApp saying I'll be late" | native_tool | send_message + slots.contact=Marco + slots.platform=whatsapp + slots.body | WhatsApp opens with body precompiled |
| 4 | "Explain Bayes theorem in three sentences" | delegate_local | complexity ~25-35, no browser | dispatchDelegateLocal → Ollama (or error fallback to legacy bridge if Ollama not running) |
| 5 | "Search Wikipedia for Nikola Tesla" | delegate_cloud | capabilities=[browser, web_search] | dispatchDelegateCloud → Claude Code scaffold → legacy GigiClaudeBridge fallback |
| 6 | "Write a Python script to sort a list" | delegate_cloud | capabilities=[code], complexity ~45 | dispatchDelegateCloud → Claude bridge |
| 7 | "Maybe set something for later" | ask_clarification | directSpeech non-empty | speak "What would you like me to set..." |
| 8 | "Buy bitcoin" | reject | directSpeech non-empty | speak "I can't make financial transactions for you." |
| 9 | "Turn on the kitchen light" | native_tool | homekit_on + slots.taskText="kitchen light" | HomeKit accessory toggled |
| 10 | "Tell me a joke" | delegate_local | complexity ~20, no caps | dispatchDelegateLocal → Ollama (or fallback) |

## Run table (fill on device)

| # | Actual path | Actual action / caps | Latency (s) | Speech response (1 line) | PASS / FAIL | Notes |
|---|---|---|---|---|---|---|
| 1 |  |  |  |  |  |  |
| 2 |  |  |  |  |  |  |
| 3 |  |  |  |  |  |  |
| 4 |  |  |  |  |  |  |
| 5 |  |  |  |  |  |  |
| 6 |  |  |  |  |  |  |
| 7 |  |  |  |  |  |  |
| 8 |  |  |  |  |  |  |
| 9 |  |  |  |  |  |  |
| 10 |  |  |  |  |  |  |

## Pass criteria

- **8/10** correct path classification (router can sometimes pick delegate_local vs delegate_cloud differently — that's acceptable as long as the user response is reasonable)
- **No crashes**, no `nil` deref, no infinite spinner
- Console.app log shows `GIGI Router: path=... action=... complexity=... caps=...` for every non-NLU turn
- NLU fast-path queries (#1, #2) show `GIGI fast-path: <intent>` log entry and skip the router

## How to read the logs

Open Console.app on Mac, connect iPhone via USB. Filter:

- `subsystem:io.gigi` (if structured logging is enabled)
- Or text filter `GIGI Router:` / `GIGI fast-path:` / `GIGI Foundation:`

Settings → Debug → "Last router decision (JSON)" shows the JSON of the latest decision (cached after each turn).

## Decision

After running: `PASS / FAIL`:

> ___________________________________

If FAIL, log the failure rows in a sub-issue with label `bug` + assignee `@ArmandoBattaglino`, cc parent `GATE-2`.
