# 🐛 DEBUG — Beta testing findings

Bug ledger from external beta testers (May 2026 wave).
One Markdown file per bug, self-contained: evidence, repro, hypothesis,
proposed fix. Status tag in the header — update when fixed and add a
"Resolved in commit X / IPA Y" footer.

## Conventions

| Field | Meaning |
|---|---|
| **Status** | `open` · `in-progress` · `fixed-pending-verification` · `fixed` · `wontfix` |
| **Severity** | `P0` blocks demo · `P1` user-visible · `P2` annoyance · `P3` polish |
| **Discovered** | Date + tester source |
| **Repro** | Step-by-step to reproduce |
| **Evidence** | Screenshot path, log excerpt, transcript |
| **Root cause** | Hypothesis or confirmed cause |
| **Fix** | Proposed change with file:line reference |

## 🔴 Open bugs (May 2026 wave)

| # | Severity | Title | File |
|---|---|---|---|
| 002 | **P1** | `create_note` returns hybrid response: Claude "/login" error + native success | [2026-05-12-002-note-create-hybrid-response.md](2026-05-12-002-note-create-hybrid-response.md) |
| 003 | **P0** | `Explain bayes theorem` returns "/login" — Claude Code requires login, not Ollama | [2026-05-12-003-ollama-via-claude-login-error.md](2026-05-12-003-ollama-via-claude-login-error.md) |
| 004 | P1 | `Set a timer for two minutes` fails — regex only matches digits, not spelled-out numbers | [2026-05-12-004-timer-spelled-numbers.md](2026-05-12-004-timer-spelled-numbers.md) |

## ✅ Fixed bugs

| # | Severity | Title | Commit | IPA |
|---|---|---|---|---|
| ✅ [001](2026-05-12-001-dashboard-onboarding-copy.md) | P2 | Dashboard onboarding cards copy unclear → soften + dismissible | `b4d922c` | next |

## Workflow

1. Tester discovers issue → screenshot + transcript shared
2. PM (Armando) creates new file `YYYY-MM-DD-NNN-short-slug.md`
3. Fill in template (or copy from existing one)
4. Update this README's open-bugs table
5. When fixed: change status, add commit hash, leave file in place as history

## Useful Sherlock commands

```bash
# Tail live logs while reproducing
curl -s "http://localhost:7777/api/log/tail?lines=200" | tail -30

# Get the Last router decision JSON from iPhone Settings → 🔧 Debug
# (or via UserDefaults key gigi.debug.lastRouterDecision)

# Wipe Claude sandbox to retest without context pollution
curl -s -X POST http://localhost:7777/api/panel/sandbox/reset
```
