# GIGI v0.1.0 — Demo video script (3 minutes)

> **Goal**: 3-min screencast for the README, GitHub release page, and social
> launch posts. Recorded on iPhone 15 Pro + Mac M-series.
> **Format**: 1080p, 30fps, voice-over EN, captions enabled.

---

## Pre-record checklist

- [ ] iPhone 15 Pro+ with iOS 26.2+ and Apple Intelligence enabled
- [ ] Mac with Claude Code installed + `claude --version` working
- [ ] Mac with Ollama installed + `qwen3:14b` pulled (`ollama list` confirms)
- [ ] `ANTHROPIC_API_KEY` UNSET in shell
- [ ] Harness running (`./start-harness.sh`), panel reachable at localhost:7777
- [ ] GIGI app installed via Sideloadly, paired via QR
- [ ] Settings → Modes → "Full Power" selected (badge visible)
- [ ] Test microphone working; HomeKit accessory "kitchen light" set up
- [ ] Phone on silent except for GIGI notifications
- [ ] Screen recording target ~3 minutes

---

## Storyboard

### 0:00 — 0:15 · Cold open

**Visual**: Slow-mo of iPhone on a desk, GIGI icon visible. Mac in background
with terminal showing `./start-harness.sh` running.

**Voice-over**:
> "GIGI is a voice agent for iPhone. It thinks on your hardware. It calls
> your apps. No API keys to pay. Open source. iOS 26."

### 0:15 — 0:45 · Path 1 + Path 2 — native iOS actions

**Demo**: Pick up phone, tap microphone, say in sequence:
1. "Set a timer for one minute" → speech "Timer set for 1 minute" + Lock Screen notification
2. "What's the weather in Milan tomorrow" → speech with forecast
3. "Turn on the kitchen light" → light visibly turns on

**Voice-over** (over visuals):
> "Native iOS actions go through Apple Foundation Models. Sixteen tools.
> Constrained decoding picks the right one, fills the arguments, and the
> bridge dispatches in under a second. Timers, alarms, messages, calls,
> navigation, HomeKit. All on-device."

### 0:45 — 1:30 · Path 3 — local reasoning via Ollama

**Demo**: Switch to Mac, briefly show Activity Monitor or `ollama list`.
Cut back to iPhone. Say:
> "Explain Bayes theorem in three sentences"

Show speech streaming chunk-by-chunk (visible "thinking" indicator).

**Voice-over**:
> "Reasoning that doesn't need the web stays on your LAN. The harness on
> your Mac runs Ollama with Qwen 3 14B. Streaming response. Zero cloud egress.
> Zero API spend."

Cut to Settings → 🦙 Ollama:
> "You pick the model tier that fits your RAM. Lite for older Macs, Default
> for sixteen gigs, Pro for thirty-two."

### 1:30 — 2:30 · Killer demo — Path 4 + 2-turn callback

**Demo**: Phone in hand. Pronounce the killer query:
> "Search Wikipedia for Nikola Tesla and create a note about his most
> important invention"

**Visuals** (timing: ~45-60s of compute):
- iPhone screen: "Starting Claude Code subprocess with MCP harness-browser..."
- Thinking bubbles streaming: "Searching Google for Nikola Tesla...",
  "Opening en.wikipedia.org/wiki/Nikola_Tesla...", "Reading article..."
- Switch to Mac: brief glimpse of Chromium browser navigating Wikipedia in
  the background (Playwright)
- Back to iPhone: speech "Tesla's most important invention was the
  alternating current induction motor, patented in 1888..."
- Speech continues: "Note 'Nikola Tesla' copied to clipboard. Opening Notes
  — paste with long-press."
- Notes app opens. Long-press → Paste → note appears with title + body.

**Voice-over**:
> "Cloud-scale reasoning when you need a real browser. Claude Code subprocess
> on your Mac. MCP-attached headless Chromium. The model navigates, reads,
> extracts. And then — this is the cool part — GIGI auto-chains the result
> into a native iOS action. The note lives on your phone, written by an
> assistant that just read Wikipedia for you."

### 2:30 — 2:50 · Modes + setup

**Visual**: Settings → ⚙️ Modes screen. Tap "Local-First" card.

**Voice-over**:
> "Four operating modes. Local-First keeps everything on your hardware —
> no Claude Code subscription needed. Apple Optimized swaps Ollama for
> the cloud. Full Power gives you all five paths. Minimal lets you start
> with just a Claude subscription, no Mac."

Cut to terminal: `bash scripts/setup-oss-demo.sh` showing the 10-step pretty
output cascade (check Node, check Claude CLI, detect RAM, propose tier...).

**Voice-over**:
> "One script. Ten steps. Less than thirty minutes from `git clone` to
> talking to GIGI. Apache two."

### 2:50 — 3:00 · Outro

**Visual**: Logo + GitHub URL fade-in.

**Voice-over**:
> "Github dot com slash Building-addicts slash GIGI. Built by the
> Building-addicts crew. Free, forever."

---

## Audio cues

- **0:00** — Soft ambient pad start
- **0:15** — Light percussion in (UI sounds)
- **0:45** — Bass drops slightly for "local" emphasis
- **1:30** — Tension build during Claude Code subprocess (subtle ticking)
- **2:00** — Release on note creation (small chime)
- **2:30** — Calm down to ambient
- **2:50** — Outro chord

---

## Caption track (key beats only)

- 0:05 — "GIGI · Voice agent for iPhone"
- 0:20 — "Path 1+2 · Native iOS in <1s"
- 0:50 — "Path 3 · Local LLM, zero cloud"
- 1:35 — "Path 4 · Cloud reasoning + MCP browser"
- 1:50 — "2-turn callback · auto-chain to native action"
- 2:30 — "4 operating modes"
- 2:50 — "Apache 2.0 · OSS"

---

## Fallback shots (in case live demo fails)

- Pre-recorded clean run of the Tesla → note demo (60s clip)
- Settings tour (Modes, Ollama tier picker, Debug overlay) on tripod
- `setup-oss-demo.sh` full run captured in iTerm with asciinema
- B-roll of harness panel (localhost:7777) with WebSocket events streaming

---

## Files to deliver

1. `gigi-v0.1.0-demo-3min.mp4` (1080p H.264, AAC stereo)
2. `gigi-v0.1.0-demo-3min.webm` (VP9 + Opus, web version)
3. Thumbnail `gigi-v0.1.0-thumb.png` (1280x720)
4. Caption SRT in 2 languages: `en.srt`, `it.srt`
5. Asciinema cast of `setup-oss-demo.sh`: `setup-oss-demo.cast`

Upload to:
- GitHub release page
- README badge link
- Twitter/X launch post (use 1m teaser clip)
- LinkedIn launch post (full version)
