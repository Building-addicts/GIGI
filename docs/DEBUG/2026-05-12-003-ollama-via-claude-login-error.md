# Bug 003 — `Explain bayes theorem` returns "/login" — knowledge Q&A routed to Claude Code instead of Ollama

- **Status**: ✅ fixed
- **Severity**: **P0** (knowledge Q&A is the most-used demo case; failure here breaks first impression)
- **Discovered**: 2026-05-12 — beta tester wave
- **Area**: iOS · Apple FM router classification

## Symptom

User prompt: **"Explain bayes theorem in three sentences"**

GIGI response:
> Not logged in · Please run /login

That's it. No Ollama call, no Claude success — just the Claude CLI login error verbatim.

## Evidence

iPhone screenshot 3 in tester thread.

## What SHOULD happen

Apple FM router rules say short knowledge / explanation tasks → `path=delegate_local` (Ollama, free, local, no auth):

```
Input shape: reasoning/knowledge/paraphrase request → output shape:
  path=delegate_local, complexity=15-40, capabilities=[], ...
```

"Explain bayes theorem in three sentences" is a textbook delegate_local query — complexity ~28, no tools needed.

## What ACTUALLY happened

Apple FM router classified it as `path=delegate_cloud` → iOS spawned Claude Code subprocess → Claude CLI returned "/login" stderr because the tester's harness host isn't authenticated → that error bubbled all the way up to the iPhone.

## Root cause hypothesis

Combination of:

1. **Apple FM router bias toward delegate_cloud** — recurring pattern in this session. After the radical few-shot prompt rewrite (commit `7ffbb92`), the model has less concrete signal for differentiating local vs cloud reasoning. "Explain X" might be matching the `Input shape: web research / code task / vision task → delegate_cloud` rule loosely.

2. **No "knowledge Q&A" example in the new few-shot** — the original prompt had "Explain Bayes theorem in three sentences → delegate_local" as a literal example. Removing it (to stop verbatim leakage, see bug 002 archive) removed the signal.

3. **Stateless router fix `28bd428` is helping** but the underlying prompt still over-routes to delegate_cloud for ambiguous reasoning prompts.

## Repro

1. Beta tester host: claude.exe installed but NOT logged in
2. iPhone: prompt "Explain bayes theorem in three sentences"
3. Reply: "Not logged in · Please run /login"
4. Check `Settings → Last router decision (JSON)` — likely shows `path=delegate_cloud`

## Proposed fix (two-layer)

### Fix A — strengthen Apple FM prompt to differentiate

In `GigiFoundationAgent.swift` router system prompt, the
`Input shape: reasoning/knowledge/paraphrase request → delegate_local`
shape currently has no anchor verbs. Strengthen with explicit verb list:

```
Input shape: short factual answer or explanation (verbs: "explain",
"what is", "who was", "tell me about", "summarize", "rephrase",
"translate", "define") → ALWAYS delegate_local. complexity=15-40.
This is the most common path — pick it when there is no need for
fresh web data, tools, or code execution. Examples to ROUTE here
(do NOT copy these strings, just route): "explain bayes theorem",
"who was nikola tesla", "what is the capital of france".
```

### Fix B — defensive fallback in iOS

When `path=delegate_cloud` AND the prompt doesn't contain web-search
verbs (search, look up, find online, browse, latest, current, today,
this week), iOS could DOWNGRADE to delegate_local instead of spawning
Claude Code. Heuristic-only safety net for when Apple FM mis-classifies.

### Fix C — fail-soft on Claude Code login error

If harness returns "/login" or similar auth error, iOS should:
- Surface a clear banner: "Claude Code needs setup on your PC — running on local AI instead"
- Auto-fallback to delegate_local Ollama for the same prompt

Currently the error is rendered verbatim to the user, who has no idea what `/login` means.

## Files involved

| File | What |
|---|---|
| `02_GIGI_APP/GIGI/GigiFoundationAgent.swift:240-280` | Router few-shot (Fix A) |
| `02_GIGI_APP/GIGI/GigiRequestRouter.swift:283-295` | delegate_cloud dispatch (Fix B) |
| `02_GIGI_APP/GIGI/GigiRequestRouter.swift` | Error handling for "/login" (Fix C) |

## Workaround for beta testers

Run `claude /login` on the harness host once. The auth persists in the
Claude Code CLI's keychain. This makes the bug invisible but doesn't fix
the misclassification.

## Resolution

- **Commit**: `f1ef170` (2026-05-12)
- **IPA**: TBD — next build
- **Files changed**:
  - `02_GIGI_APP/GIGI/GigiFoundationAgent.swift` (Layer A — FM router prompt with explicit verb anchors)
  - `02_GIGI_APP/GIGI/GigiRequestRouter.swift` (Layer B downgrade + Layer C fail-soft + helpers)

### All 3 layers implemented in one commit

**Layer A — FM router prompt strengthened**
- Replaced vague "reasoning/knowledge/paraphrase" shape with explicit verb anchor list (explain / what is / who was / tell me about / summarize / rephrase / translate / define / describe / list / give me an example / how does X work).
- Added "Default to delegate_local when in doubt" tie-breaker.
- Restricted delegate_cloud to ONLY when web/code/image verbs are explicitly present.
- Added anti-bias rule: "If a knowledge question contains a public figure or topic name but NO web/code/image verb, choose delegate_local."

**Layer B — iOS defensive downgrade** ([GigiRequestRouter.swift:98-110](02_GIGI_APP/GIGI/GigiRequestRouter.swift))
```swift
if effectivePath == "delegate_cloud"
    && !Self.hasWebOrCodeOrImageVerb(text)
    && decision.requiredCapabilities.isEmpty {
    effectivePath = "delegate_local"  // downgraded
}
```
Even if Apple FM still mis-routes, the dispatcher catches it before spawning Claude. Static `hasWebOrCodeOrImageVerb` helper checks for curated web/code/image verbs in the user text.

**Layer C — Fail-soft on Claude /login**
Bug 002's clean error message is now replaced with a soft retry: if Claude returns auth error, the router synthesizes a delegate_local decision (path=local, capabilities=[], delegatePrompt=originalText) and re-dispatches to Ollama. The tester sees an answer instead of any error.

### Test plan after IPA install

| Input | Expected behavior |
|---|---|
| "Explain Bayes theorem" | delegate_local (FM directly thanks to Layer A) → Ollama answer in EN |
| "Who was Marie Curie in one sentence" | delegate_local → Ollama answer |
| If Apple FM still mis-routes one of the above | Layer B downgrades → still ends up at Ollama |
| "Search the web for Tesla stock" | delegate_cloud → Claude (or fallback if /login: Layer C retries Ollama with same prompt) |
| "Set a timer for 2 minutes" | native_tool, unchanged |

### Defense in depth

The three layers form a cascade: A reduces mis-routing at the source, B catches what A misses, C catches what B can't (legitimate delegate_cloud routing but Claude offline). With all three, the user-visible "/login" error path is closed.

### Side recommendation (not in this commit)

Add `claudeCode.needsLogin` to `/api/panel/stack-status` so the live monitor + iOS Settings can show a clear setup hint. Beta tester onboarding should mention `claude /login` as a one-time host setup step.
