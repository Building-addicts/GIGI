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
| 005 | P1 (TBC) | `Set a timer for two minutes` still failing — IPA installed check OR regression | [2026-05-12-005-timer-two-minutes-regression-or-not-installed.md](2026-05-12-005-timer-two-minutes-regression-or-not-installed.md) |
| 008 | P2 | `Hellllo` (typo greeting) misclassified as `send_message` — character-repetition not in router patterns | [2026-05-12-008-hellllo-misclassified-send-message.md](2026-05-12-008-hellllo-misclassified-send-message.md) |
| 011 | P2 | `Order on JustEat` → dismissive reject instead of opening app/website (missing `web_order_food` native handler) | [2026-05-12-011-just-eat-reject-too-dismissive.md](2026-05-12-011-just-eat-reject-too-dismissive.md) |

## ✅ Fixed bugs

| # | Severity | Title | Commit | IPA |
|---|---|---|---|---|
| ✅ [001](2026-05-12-001-dashboard-onboarding-copy.md) | P2 | Dashboard onboarding cards copy unclear → soften + dismissible | `b4d922c` | next |
| ✅ [002](2026-05-12-002-note-create-hybrid-response.md) | P1 | `create_note` hybrid response → GATE 6 requires research verb + auth-error short-circuit | `96ecfbd` | next |
| ✅ [003](2026-05-12-003-ollama-via-claude-login-error.md) | **P0** | knowledge Q&A mis-routed → FM verb anchors + iOS downgrade + fail-soft to Ollama | `f1ef170` | next |
| ✅ [004](2026-05-12-004-timer-spelled-numbers.md) | P1 | `timer for two minutes` → wordToNumber pre-pass (EN 0-99 + IT) | `d1c75e9` | next |
| ✅ [006](2026-05-12-006-call-double-confirmation-ux.md) | P1 | `Call X` double confirm → bubble simplified to "Calling X." | `cfc8b8e` | next |
| ✅ [010](2026-05-12-010-call-bypass-ios-popup-via-whatsapp.md) | P1 | `Call X` iOS popup bypass → smart route via WhatsApp when installed, tel:// fallback | TBD | next |

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
