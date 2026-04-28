#!/usr/bin/env bash
# Request changes su una PR con messaggio strutturato.
# Uso: bash .claude/scripts/reject-pr.sh <PR_NUM> "<motivo>"
#
# Cosa fa:
#   1. Verifica PR esiste ed è OPEN
#   2. Posta review con stato REQUEST_CHANGES + body strutturato
#   3. Posta su #19 LIVE FEED che la PR è stata rejected
#   4. Sposta la checklist in archivio /.rejected/ con timestamp
#
# Body comment strutturato:
#   - Motivo (in italiano, dal parametro)
#   - File/AC che hanno fallito (dalla checklist se presente)
#   - Hint per il dev su come ripartire

set -u

PR_NUM="${1:-}"
REASON="${2:-}"

if [ -z "$PR_NUM" ] || [ -z "$REASON" ]; then
  echo "❌ Usage: bash .claude/scripts/reject-pr.sh <PR_NUM> \"<motivo>\""
  exit 2
fi

REPO="Building-addicts/GIGI"
ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CHECKLIST="$ROOT/review-checklists/pr-$PR_NUM.md"

# ─── Pre-flight ───
if ! command -v gh >/dev/null 2>&1; then
  echo "❌ gh CLI non installato"; exit 2
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "❌ gh non autenticato"; exit 2
fi

# ─── PR exists + OPEN ───
PR_DATA=$(gh pr view "$PR_NUM" --repo "$REPO" --json state,title,author 2>&1)
if echo "$PR_DATA" | grep -q "Could not resolve"; then
  echo "❌ PR #$PR_NUM non esiste"; exit 2
fi

PR_STATE=$(echo "$PR_DATA" | python -c "import json,sys; print(json.load(sys.stdin)['state'])")
PR_TITLE=$(echo "$PR_DATA" | python -c "import json,sys; print(json.load(sys.stdin)['title'])")
PR_AUTHOR=$(echo "$PR_DATA" | python -c "import json,sys; print(json.load(sys.stdin)['author']['login'])")

if [ "$PR_STATE" != "OPEN" ]; then
  echo "❌ PR #$PR_NUM non è OPEN (stato: $PR_STATE)"
  exit 2
fi

# ─── Estrai checkbox falliti dalla checklist (se esiste) ───
FAILED_AC=""
if [ -f "$CHECKLIST" ]; then
  FAILED_AC=$(grep -E '^\s*-\s*\[\s*\]' "$CHECKLIST" | head -10)
fi

# ─── Compose body review ───
COMMENT_FILE=$(mktemp)
cat > "$COMMENT_FILE" <<MD
## ⛔ Changes requested

**Motivo**: $REASON

### Cosa serve fixare prima del prossimo round

$( [ -n "$FAILED_AC" ] && echo "$FAILED_AC" || echo "_(nessuna checklist disponibile, vedi motivo sopra per dettaglio)_" )

### Come riprendere

1. Leggi questo comment e il motivo sopra
2. Fixa il problema sul tuo branch \`$( gh pr view "$PR_NUM" --repo "$REPO" --json headRefName --jq '.headRefName' )\`
3. \`git push\` — il workflow CI ri-scattera, la PR torna in stato "ready for review"
4. Pingami su WhatsApp quando è pronto per il secondo round

cc @$PR_AUTHOR
MD

# ─── Post review REQUEST_CHANGES ───
echo "🔍 PR #$PR_NUM — $PR_TITLE"
echo ""
echo "⛔ Posto Request Changes con motivo: $REASON"
gh pr review "$PR_NUM" --repo "$REPO" --request-changes --body-file "$COMMENT_FILE" 2>&1 | tail -2

# ─── Post su #19 ───
bash "$ROOT/.claude/scripts/post-timeline.sh" "$PR_AUTHOR" "$PR_NUM" standby "PR #$PR_NUM rejected: $REASON" 2>&1 | tail -1 || true

# ─── Archive checklist ───
if [ -f "$CHECKLIST" ]; then
  ARCHIVE_DIR="$ROOT/review-checklists/.rejected"
  mkdir -p "$ARCHIVE_DIR"
  mv "$CHECKLIST" "$ARCHIVE_DIR/pr-$PR_NUM-$(date +%Y%m%d-%H%M%S).md"
  echo "📁 Checklist archiviata in $ARCHIVE_DIR/"
fi

# ─── Cleanup IPA dal drop folder ───
if [ -f "$ROOT/.claude/local-build.sh" ]; then
  source "$ROOT/.claude/local-build.sh"
  if declare -F lb_cleanup >/dev/null; then
    lb_cleanup "$PR_NUM" || true
  fi
fi

rm -f "$COMMENT_FILE"

echo ""
echo "✅ Rejection completata."
echo "   Il dev (@$PR_AUTHOR) riceverà notifica + Discord embed dal workflow."
echo ""
echo "Prossima PR? Esegui: /routine-pr (o test-pr.sh diretto)"
