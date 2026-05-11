# Bug 016 — Browser pool failure ("Browser pool is down") leaked to user-facing response

- **Status**: ✅ fixed (UX layer — infra deferred to v1.1)
- **Severity**: P1 (visible infra leak in demo)
- **Discovered**: 2026-05-12 — Armando JustEat test
- **Area**: harness · `.claude-sandbox/CLAUDE.md` · also browser-pool config gap

## Symptom

User asks "Order a Kebab using browser". GIGI reply contains the literal phrase:

> *"I'll search JustEat for a kebab restaurant using the browser. **Browser pool is down. Falling back to WebFetch.** A solid pick on Just Eat is…"*

The infra failure (browser pool not running) is narrated to the user as if it were part of the answer.

## Two layers

### Infra (deferred to v1.1)

`03_HARNESS/server/config.json` has:
```json
"browser": { "enabled": false, ... }
```

The browser pool (Playwright/Puppeteer headless Chromium on port 9224) is intentionally disabled. When Claude tries to call `mcp__harness-browser__*` tools, the MCP server reports the connection isn't available. Claude then narrates the situation to the user.

Enabling browser pool requires:
1. Running browser-pool server (`03_HARNESS/browser-pool/server-playwright.js`)
2. Chrome CDP on port 9224
3. Profile slot management for parallel sessions
4. Wiring browser-pool MCP server into Claude's `--mcp-config`

This is **architecturally clean but infra-heavy work** — deferred to v1.1.

### UX (fixed in this commit)

Until the browser pool is enabled, Claude should **silently** fall back to WebSearch/WebFetch and never narrate the failure to the user.

Operator manual update in `.claude-sandbox/CLAUDE.md`:
```
- **Never narrate tool failures to the user.** If `mcp__harness-browser`
  reports "Browser pool is down" or any infra error, silently retry with
  WebSearch / WebFetch / KnowledgeRecall — the user never hears about it.
- **Never narrate your steps.** No "I'll search…", "Let me check…",
  "I found that…". Output starts directly with the answer.

…

- **harness-browser MCP** (only if loaded by request) — full headless
  Chromium navigation, click, type, screenshot. Use for sites that require
  JS execution or login.
  **When the harness reports the browser pool is down ("Browser pool is
  down"), silently switch to WebSearch — DO NOT mention this in the user
  response.**
```

## Resolution

- **Commit**: `c8b1d1a` (2026-05-12)
- **File**: `03_HARNESS/server/.claude-sandbox/CLAUDE.md`
- **Related**: bug 015 (verbose response) — same edit closes both.
- **Deferred**: bug 016 v2 — wire actual browser-pool server. Tracker in v1.1.

### Test plan

After IPA install + harness restart (so the new operator manual loads on next Claude session spawn):

| Input | Expected response |
|---|---|
| "Order a kebab on JustEat using browser" | Claude attempts browser, hits down, silently falls back to WebSearch. Response contains ONLY the kebab pick — NO "Browser pool is down" mention. |
| "Find latest news about X" | Same: silent fallback, no infra leak. |

If "Browser pool is down" still appears in user-visible response after install: regression in operator manual loading. Check `.claude-sandbox/CLAUDE.md` is the CWD's CLAUDE.md (sandbox dir override).
