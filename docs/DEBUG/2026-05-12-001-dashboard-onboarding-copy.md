# Bug 001 — Dashboard onboarding cards copy unclear

- **Status**: open
- **Severity**: P2 (cosmetic, but first impression for testers)
- **Discovered**: 2026-05-12 — beta tester wave (Armando's friends)
- **Area**: iOS · DashboardView · onboarding empty-state

## Symptom

On first launch, Dashboard tab shows two cards stacked vertically:

1. **"Connect GIGI to your PC"** — "Tap to set up & pair" (purple gradient with QR icon)
2. **"Groq key required"** — "Go to Settings → AI Brain to add your free API key." (orange key icon)

Tester reaction: confused because:
- They don't know what Groq is
- They don't know why a key is "required" if other things might work
- The copy implies the app is broken without it, but it's optional

## Evidence

iPhone screenshot (top one in tester thread):
- Time `20:43`, fresh install of `GIGI-7ffbb92.ipa` or later
- Both cards visible side by side
- No paired status badge yet

## Repro

1. Install fresh IPA (or wipe app data)
2. Open GIGI → Dashboard tab
3. Both cards appear before any setup

## Root cause hypothesis

The DashboardView renders empty-state cards based on:
- `harness paired?` → if no, show "Connect to PC" card
- `groqKey set?` → if no, show "Groq key required" card

The Groq card was added when Groq was the primary cloud LLM. After the
5-path router (Apple FM + Ollama + Claude Code), Groq is **optional**
(was deescalated in v1.1 scope). The "required" wording is now wrong.

## Proposed fix

1. **Copy**: rename "Groq key required" → "Optional: set Groq API key for cloud reasoning". Subtitle: "Free tier at console.groq.com. Skip if you'll use Apple Intelligence + local Ollama only."
2. **Visual**: change the orange key icon to a softer info icon (info.circle).
3. **Dismissible**: add a small "x" to permanently dismiss the Groq card once seen.
4. **Order**: keep "Connect to PC" first (essential for harness paths 3+4). Groq card second.

Optional cleanup: split Dashboard onboarding into a single multi-step
card "Set up GIGI (3 steps): 1. Pair with PC · 2. Pick an AI brain · 3.
Try a command." Less noisy.

## Files involved

| File | What |
|---|---|
| `02_GIGI_APP/GIGI/DashboardView.swift` | Renders cards |
| iOS Settings → AI Brain section | Where the key lives |

## Repro on dev

```bash
# Wipe app data on iPhone via Settings → General → iPhone Storage → GIGI → Offload App + Reinstall
# OR delete app + reinstall fresh IPA
```

## Resolution

_(empty — to be filled when fixed)_
