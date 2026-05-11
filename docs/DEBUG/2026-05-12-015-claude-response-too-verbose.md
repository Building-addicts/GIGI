# Bug 015 — Claude delegate_cloud response too verbose, multi-option enumeration despite system prompt

- **Status**: ✅ fixed
- **Severity**: P2 (TTS UX — long monologue tires user; demo killer is short crisp answers)
- **Discovered**: 2026-05-12 — Armando JustEat test
- **Area**: harness · `.claude-sandbox/CLAUDE.md` operator manual

## Symptom

Claude response to "Order a Kebab using browser":

> "I'll search JustEat for a kebab restaurant using the browser. Browser pool is down. Falling back to WebFetch. A solid pick on Just Eat is The Best Kebab in Finsbury, central London, serving lamb and chicken doner, shish and kofte, plus charcoal-grilled chicken wings with chips and salad. If you want alternatives, Kebab Kid in Fulham is a British Kebab Awards winner, and German Doner Kebab has multiple delivery spots across London. I saved the picks to your notepad."

Issues:
1. **6+ sentences** (operator manual asked 2-3)
2. **Multi-option enumeration** ("The first is X, alternatively Y, and finally Z")
3. **Step narration** ("I'll search…", "Falling back to WebFetch")
4. **Mentions of infra failure** (covered in bug 016)

## Root cause

The previous `.claude-sandbox/CLAUDE.md` instruction was soft:
> "After the work is done, emit a SHORT final text summary in **2-3 sentences**…"

Claude treated "2-3 sentences" as a soft target, not a hard cap. The model also picked the structurally-richest helpful answer (multi-option recommendation) rather than the constraint-respecting one-pick answer.

## Fix

Operator manual rewritten with **STRICT** caps and explicit anti-pattern examples:

```
## Output format — STRICT

After the work is done, emit a SHORT final text summary suitable for
text-to-speech delivery. Constraints (all must hold):

- **Maximum 2 sentences.** Never list multiple options. Pick ONE.
- **No markdown** (no headings, bold, italic, code fences, bullets).
- **No URLs, no links, no footnotes, no "Sources:" section.**
- **No multi-option enumeration** — never say "The first is X, alternatively
  Y, and finally Z". Pick the single best answer and state it definitively.
- **Spell numbers/units conversationally** ("forty thousand dollars",
  NOT "$40,000" with symbols that TTS misreads).
- **Never narrate tool failures to the user.** If `mcp__harness-browser`
  reports "Browser pool is down" or any infra error, silently retry with
  WebSearch / WebFetch / KnowledgeRecall — the user never hears about it.
- **Never narrate your steps.** No "I'll search…", "Let me check…",
  "I found that…". Output starts directly with the answer.
```

Changes from previous version:
- "2-3 sentences" → "Maximum 2 sentences"
- Added "Never list multiple options. Pick ONE."
- Added explicit anti-pattern: "The first is X, alternatively Y…"
- Added "Never narrate tool failures" (closes bug 016 too)
- Added "Never narrate your steps. Output starts directly with the answer."

## Resolution

- **Commit**: `c8b1d1a` (2026-05-12)
- **File**: `03_HARNESS/server/.claude-sandbox/CLAUDE.md`
- **Related**: bug 016 (browser pool narration) also closed by same edit.

### Test plan

| Input | Expected response shape |
|---|---|
| "Order a kebab on JustEat using browser" | 1-2 sentences. ONE restaurant pick. No "I'll search…", no "alternatives". |
| "Search latest Apple stock price" | "Apple is trading at about X dollars today." (was already working) |
| "Tell me about Nikola Tesla in one sentence" | 1 sentence (delegate_local Ollama, already disciplined) |
