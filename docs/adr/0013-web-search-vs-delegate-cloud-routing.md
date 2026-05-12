# ADR-0013: Web research routing — `web_search` (iPhone Safari) vs `delegate_cloud` (Claude harness)

- **Status:** Accepted (2026-05-12, surfaced during GATE 15 testing)
- **Date:** 2026-05-12
- **Deciders:** @ArmandoBattaglino
- **Tags:** ios, routing, web-search, claude-harness, design

## Context

During GATE 15 device testing the semantic router was matching generic
research queries — *"look up best ramen in milan"*, *"find recipes online"*,
*"google for pasta"* — to the `web_search` tool, which opens iPhone
Safari with the query.

The PM clarified this is **not the intended behavior**. By design:

- **Default for any "look up / search / research" intent** — route to
  `delegate_cloud` → harness Claude subprocess with the `harness-browser`
  MCP tool → Claude actually browses, reads pages, and **synthesizes an
  answer inline in the GIGI chat**. The user stays in the conversation.
- **Only on explicit "open Safari / browser / phone" intent** — route to
  `web_search` (this tool) → opens iPhone Safari with the query. User
  leaves the chat.

The architecture is intentional and asymmetric. Most users want an
answer to their question, not a search results page. The harness Claude
path provides the answer; the Safari path is a fallback / power-user
escape hatch for "I want to read raw results myself in Safari".

## Decision

1. **`web_search` tool description** is narrowed to *"open Safari on the
   iPhone with a search query"* with an explicit `DO NOT pick this tool
   for generic research` clause. Trigger keywords: *"open Safari"*,
   *"in Safari"*, *"on my phone"*, *"apri Safari"*, *"su Safari"*,
   *"sul telefono"*.

2. **`GigiSemanticRouter` catalog** for `web_search` is reduced to ~13
   trigger phrases, all containing explicit Safari/phone keywords.
   Generic *"look up X / find X / google X"* phrases are REMOVED from
   the catalog — they fall through to Apple FM, which now correctly
   classifies them as `delegate_cloud`.

3. **`GigiSemanticRouter` slot extraction prefixes** for `web_search`
   are similarly narrowed to *"open safari and search for"*, *"cerca su
   safari per"*, etc. No more *"look up"*, *"google"*, *"find online"*
   in the slot extraction list.

4. Default routing for unmatched research queries → fall-through to
   Apple FM → `delegate_cloud` → harness Claude with `harness-browser`
   MCP → synthesized inline answer.

## Drivers

1. **Stay in conversation** — context retention. Users don't want to
   bounce between apps for every research question.
2. **Synthesis > raw results** — Claude with browser MCP reads pages,
   compares sources, and gives a concise answer (e.g. *"the best ramen
   in Milan according to Eater and TheFork is Casa Ramen Super in
   Porta Genova"*) — far better UX than a Google results page.
3. **Power-user escape hatch preserved** — when the user does want raw
   results, *"open Safari and search X"* still works.
4. **Apple FM router already routes generic web queries to
   `delegate_cloud`** — this was the existing behavior pre-GATE 15. The
   semantic router catalog was over-eager and broke it. Restoring
   intended behavior.

## Alternatives considered

### A — Keep `web_search` broad, let user say "in Safari" to override

This is what we had after GATE 9.C shipped. Problem: users naturally
say *"look up X"* expecting an answer, getting a Safari results page
they didn't want. Friction. Rejected.

### B — Remove `web_search` entirely, always delegate_cloud

Cleaner but removes the escape hatch. Some users do want raw Safari
results (e.g. shopping, comparison) and `harness-browser` MCP can be
slow. Keeping Safari path as explicit-only is a reasonable
compromise. Rejected.

### C — Confidence-based routing within web_search

If Apple FM has high confidence the user wants an answer (vs raw
results), delegate. Otherwise Safari. Too brittle, hard to define
"high confidence" empirically. Rejected.

## Consequences

### ✅ Positive

- Generic research stays in chat — answer synthesized by Claude
- Safari path preserved for explicit opt-in (3-5 trigger phrases EN+IT)
- No tool name change — `web_search` semantics now match the tool name
  (it really does "open Safari with web search query")
- Apple FM router behavior restored to pre-GATE-15 intent

### ⚠️ Trade-offs

- Harness Claude path requires the harness to be paired AND online.
  When unpaired (e.g. demo iPhone offline), `delegate_cloud` will fail
  → user might want Safari fallback. Future ADR could add
  *"if harness unreachable AND query is research-like → suggest Safari
  open"* graceful degradation.
- Latency: Claude with browser MCP can take 5-15s for thorough research
  vs <1s for opening Safari. Users used to Google search instant
  results may be surprised. Mitigated by GIGI's "Thinking" indicator.
- Semantic router catalog asymmetry (rich for run_shortcut, narrow for
  web_search). Different tools deserve different catalog sizes —
  acceptable.

### Behavior summary table

| User utterance | Routing | Result |
|---|---|---|
| *"look up best ramen in milan"* | Apple FM → `delegate_cloud` | Claude researches + answers inline |
| *"find recipes for pasta carbonara"* | Apple FM → `delegate_cloud` | Claude researches + answers inline |
| *"google tiramisu recipe"* | Apple FM → `delegate_cloud` | Claude researches + answers inline |
| *"what's the capital of Chile"* | Apple FM → `delegate_cloud` | Claude answers (Santiago) |
| *"open Safari and search ramen"* | Semantic → `web_search` | Safari opens with "ramen" query |
| *"cerca questo sul telefono in Safari"* | Semantic → `web_search` | Safari opens |
| *"search this on my phone"* | Semantic → `web_search` | Safari opens with last topic |

## Follow-ups

- **Graceful degradation when harness unreachable** — if `delegate_cloud`
  fails with "harness offline", suggest *"want me to open Safari with
  the query instead?"*
- **Telemetry** — track ratio of `delegate_cloud` vs `web_search` over
  time. If Safari path drops to <2% MAU, consider deprecating
  `web_search` entirely (ADR-0015).
- **Update GATE 9 task plan** to reflect this narrower web_search scope
  (currently says "search the web for X" as primary trigger which is
  wrong post-ADR).

## Code locations

| File | Role |
|---|---|
| `02_GIGI_APP/GIGI/GigiSemanticRouter.swift` | Catalog + slot prefixes narrowed for web_search |
| `02_GIGI_APP/GIGI/GigiFoundationToolRegistry.swift` | `FMWebSearchTool.description` narrowed with explicit clause |
| `02_GIGI_APP/GIGI/GigiActionBridge.swift` | `searchWeb()` handler unchanged — still opens Safari |
| `docs/adr/0013-web-search-vs-delegate-cloud-routing.md` | This document |
