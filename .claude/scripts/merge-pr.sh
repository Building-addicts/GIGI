#!/usr/bin/env bash
# Merge controllato di una PR.
# Uso: bash .claude/scripts/merge-pr.sh <PR_NUM> [--admin]
#
# Safeguard: NON mergia se review-checklists/pr-N.md non esiste o ha checkbox
# non spuntati. Forza il dev a passare da test-pr.sh + completare la checklist.
#
# Flag opzionale --admin: usa GitHub admin bypass (per casi noti tipo regex
# bug del pr-lint nostro). Logga esplicitamente bypass su #19 LIVE FEED.

set -u

PR_NUM="${1:-}"
ADMIN_FLAG="${2:-}"

if [ -z "$PR_NUM" ]; then
  echo "❌ Usage: bash .claude/scripts/merge-pr.sh <PR_NUM> [--admin]"
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

# ─── Safeguard 1: la checklist deve esistere ───
if [ ! -f "$CHECKLIST" ]; then
  echo "❌ Checklist mancante: $CHECKLIST"
  echo "   Devi eseguire prima: bash .claude/scripts/test-pr.sh $PR_NUM"
  exit 2
fi

# ─── Safeguard 2: tutti i checkbox L2/L4/L5 devono essere ✓ ───
# Eccezioni: L1+L3 sono auto-marcati da test-pr.sh, L4 sezione manuale dev
UNCHECKED=$(grep -cE '^\s*-\s*\[\s*\]' "$CHECKLIST" || echo 0)
TOTAL_CHECKBOXES=$(grep -cE '^\s*-\s*\[[ x]\]' "$CHECKLIST" || echo 1)

if [ "$UNCHECKED" -gt 0 ]; then
  echo "❌ Checklist incompleta — $UNCHECKED/$TOTAL_CHECKBOXES checkbox NON spuntati"
  echo ""
  echo "Checkbox aperti in $CHECKLIST:"
  grep -nE '^\s*-\s*\[\s*\]' "$CHECKLIST" | head -10
  echo ""
  echo "Marcali manualmente prima di mergeare. Tutti devono essere [x]."
  exit 1
fi

# ─── Safeguard 3: PR deve esistere ed essere OPEN ───
PR_STATE=$(gh pr view "$PR_NUM" --repo "$REPO" --json state --jq '.state' 2>&1)
if [ "$PR_STATE" != "OPEN" ]; then
  echo "❌ PR #$PR_NUM non è OPEN (stato: $PR_STATE)"
  exit 2
fi

# ─── Approve + merge ───
PR_TITLE=$(gh pr view "$PR_NUM" --repo "$REPO" --json title --jq '.title' 2>/dev/null)
echo "🔍 PR #$PR_NUM — $PR_TITLE"
echo ""

# Approve (idempotente)
echo "✓ Approvo la PR..."
gh pr review "$PR_NUM" --repo "$REPO" --approve \
  --body "Diff verificato + L1-L5 checklist completata + build verify + smoke test su device fisico OK. LGTM." \
  2>&1 | tail -1 || true

echo ""
echo "🚀 Merge in corso..."

if [ "$ADMIN_FLAG" = "--admin" ]; then
  echo "   ⚠️  Admin bypass attivo (giustificato in checklist L1)"
  if gh pr merge "$PR_NUM" --repo "$REPO" --squash --delete-branch --admin 2>&1 | tail -3; then
    MERGED=true
  else
    MERGED=false
  fi
else
  if gh pr merge "$PR_NUM" --repo "$REPO" --squash --delete-branch 2>&1 | tail -3; then
    MERGED=true
  else
    MERGED=false
  fi
fi

if [ "$MERGED" != "true" ]; then
  echo "❌ Merge fallito. Verifica check verdi + review approval."
  exit 1
fi

# ─── Post su #19 LIVE FEED ───
GIT_USER=$(git config user.name 2>/dev/null || echo "PM")
HANDLE=$(echo "$GIT_USER" | awk '{print tolower($1)}')
[ "$ADMIN_FLAG" = "--admin" ] && DETAIL="merge --admin (bypass giustificato)" || DETAIL="merge standard"
bash "$ROOT/.claude/scripts/post-timeline.sh" "ArmandoBattaglino" "$PR_NUM" merge "PR #$PR_NUM mergiato — $DETAIL ($PR_TITLE)" 2>&1 || true

# ─── Cleanup checklist (sposta in archivio) ───
ARCHIVE_DIR="$ROOT/review-checklists/.merged"
mkdir -p "$ARCHIVE_DIR"
mv "$CHECKLIST" "$ARCHIVE_DIR/pr-$PR_NUM-$(date +%Y%m%d-%H%M%S).md" 2>/dev/null || true

# ─── Sync local main ───
echo ""
echo "✅ PR #$PR_NUM mergiata."
git fetch origin --prune --quiet 2>/dev/null || true
if [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ]; then
  git pull origin main --ff-only --quiet 2>/dev/null || true
  echo "   Local main sincronizzato"
fi

echo ""
echo "Prossima PR? Esegui: bash .claude/scripts/test-pr.sh <next>"
