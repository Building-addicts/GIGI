#!/usr/bin/env bash
# Posta un commento timeline su issue #19 LIVE FEED del repo Building-addicts/GIGI.
# Fire-and-forget: il main Claude del dev lo invoca con `nohup ... &` e procede.
# Zero AI involved (task puramente meccanico). Zero token spesi.
#
# Uso (dal main Claude del dev, via Bash tool):
#   nohup bash "$CLAUDE_PROJECT_DIR/.claude/scripts/post-timeline.sh" \
#     <dev_handle> <issue_num> <event> "<details>" >/dev/null 2>&1 &
#   disown
#
# event ∈ { start, build_ok, build_fail, ac_verified, bug, pr_opened, merge, standby }

set -u

DEV_HANDLE="${1:?dev_handle required}"
ISSUE_NUM="${2:?issue_num required}"
EVENT="${3:?event required}"
DETAILS="${4:-}"

# Mappa evento → emoji
case "$EVENT" in
  start)        EMOJI="🚀" ;;
  build_ok)     EMOJI="✅" ;;
  build_fail)   EMOJI="❌" ;;
  ac_verified)  EMOJI="🟢" ;;
  bug)          EMOJI="🐛" ;;
  pr_opened)    EMOJI="📤" ;;
  merge)        EMOJI="🎉" ;;
  standby)      EMOJI="⏸️" ;;
  *)            EMOJI="•" ;;
esac

STAMP="$(date '+%H:%M')"
BODY="[${STAMP}] @${DEV_HANDLE} · #${ISSUE_NUM}
${EMOJI} ${DETAILS}"

# Posta comment. Output silenziato. Se gh non auth, exit silenzioso.
gh issue comment 19 --repo Building-addicts/GIGI --body "$BODY" >/dev/null 2>&1
