#!/usr/bin/env bash
# Esegue le 3 azioni atomiche su AC fallito:
#   1. Crea sub-issue (assegnata al dev + ArmandoBattaglino)
#   2. Comment sulla issue parent
#   3. Comment su #19 LIVE FEED
#
# Fire-and-forget: il main Claude del dev lo invoca con `nohup ... &` e procede.
# Zero AI involved. Zero token spesi.
#
# Uso (dal main Claude del dev, via Bash tool):
#   nohup bash "$CLAUDE_PROJECT_DIR/.claude/scripts/track-bug.sh" \
#     <parent_issue> <ac_number> <dev_handle> <area> \
#     "<ac_description>" "<dev_words>" "<suspected_files>" "<pr_num_or_empty>" \
#     >/dev/null 2>&1 &
#   disown

set -u

# ─── Pre-flight: gh deve essere installato + autenticato ───
if ! command -v gh >/dev/null 2>&1; then
  echo "⚠️  track-bug.sh: \`gh\` CLI non installato. Installa da https://cli.github.com" >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "⚠️  track-bug.sh: \`gh\` non autenticato. Esegui: gh auth login" >&2
  exit 1
fi

PARENT="${1:?parent_issue required}"
AC_NUM="${2:?ac_number required}"
DEV_HANDLE="${3:?dev_handle required}"
AREA="${4:?area required (ios|harness|mdm|docs|infra)}"
AC_DESC="${5:-}"
DEV_WORDS="${6:-}"
SUSPECTED_FILES="${7:-}"
PR_NUM="${8:-}"

REPO="Building-addicts/GIGI"

# 1. Sub-issue body
SUB_BODY="**Parent**: #${PARENT}

**AC fallito**: AC#${AC_NUM} — ${AC_DESC}

**Cosa ha visto il dev** (parole esatte): \"${DEV_WORDS}\"

**File ipotizzati coinvolti**:
${SUSPECTED_FILES}
"

if [ -n "$PR_NUM" ]; then
  SUB_BODY="${SUB_BODY}
**PR di tentativo**: #${PR_NUM}
"
fi

SUB_BODY="${SUB_BODY}
cc @ArmandoBattaglino — bug urgente trovato in test E2E"

SUB_TITLE="[BUG] #${PARENT} AC#${AC_NUM} — ${AC_DESC:0:60}"

# 1. Crea sub-issue, cattura URL
SUB_URL="$(gh issue create --repo "$REPO" \
  --title "$SUB_TITLE" \
  --label "bug,priority:P0,type:fix,area:${AREA}" \
  --assignee "${DEV_HANDLE},ArmandoBattaglino" \
  --body "$SUB_BODY" 2>/dev/null | tail -1)"

# Estrai numero sub-issue dall'URL
SUB_NUM="$(echo "$SUB_URL" | grep -oE '/issues/[0-9]+$' | grep -oE '[0-9]+$')"

if [ -z "$SUB_NUM" ]; then
  exit 1
fi

# 2. Comment sulla parent
gh issue comment "$PARENT" --repo "$REPO" \
  --body "🐛 Sub-issue #${SUB_NUM} aperta per AC#${AC_NUM} fallito ($(date '+%H:%M')). cc @ArmandoBattaglino visibility." \
  >/dev/null 2>&1

# 3. Comment su #19 LIVE FEED
STAMP="$(date '+%H:%M')"
gh issue comment 19 --repo "$REPO" \
  --body "[${STAMP}] @${DEV_HANDLE} · #${PARENT}
🐛 sub-issue #${SUB_NUM} aperta per AC#${AC_NUM} fallito" \
  >/dev/null 2>&1

# Output finale (catturato dal main Claude se non in background)
echo "sub_issue_num=${SUB_NUM}"
