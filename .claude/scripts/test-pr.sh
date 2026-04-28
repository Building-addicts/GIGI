#!/usr/bin/env bash
# Test pre-merge per una PR.
# Uso: bash .claude/scripts/test-pr.sh <PR_NUM>
#
# Architettura "universale":
#   - Lo script orchestra il flusso (gh PR fetch, checklist, verdetto)
#   - I comandi specifici dell'ambiente (SSH/scp/xcodebuild) vivono in
#     .claude/local-build.sh (gitignored, per-dev). Source 4 funzioni:
#       lb_sync_branch, lb_build_ios, lb_package_ipa, lb_cleanup
#
# Pre-requisiti:
#   - gh CLI autenticato
#   - .claude/local-build.sh presente (copia da local-build.sh.example)
#
# Output: review-checklists/pr-N.md generato
# Exit code: 0 = SAFE TO TEST, 1 = BUILD FAILED, 2 = setup error

set -u

PR_NUM="${1:-}"
if [ -z "$PR_NUM" ]; then
  echo "❌ Usage: bash .claude/scripts/test-pr.sh <PR_NUM>"
  exit 2
fi

REPO="Building-addicts/GIGI"
ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
LOCAL_BUILD="$ROOT/.claude/local-build.sh"
CHECKLIST_DIR="$ROOT/review-checklists"
mkdir -p "$CHECKLIST_DIR"

# ─── Pre-flight: gh + local-build.sh ───
if ! command -v gh >/dev/null 2>&1; then
  echo "❌ gh CLI non installato"; exit 2
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "❌ gh non autenticato — esegui: gh auth login"; exit 2
fi
if [ ! -f "$LOCAL_BUILD" ]; then
  echo "❌ .claude/local-build.sh mancante."
  echo "   Setup: cp .claude/local-build.sh.example .claude/local-build.sh"
  echo "   Poi adatta le 4 funzioni (lb_sync_branch, lb_build_ios, lb_package_ipa, lb_cleanup)"
  exit 2
fi

# Source local-build (espone funzioni lb_*)
source "$LOCAL_BUILD"

# Verifica che le 4 funzioni siano definite
for fn in lb_sync_branch lb_build_ios lb_package_ipa lb_cleanup; do
  if ! declare -F "$fn" >/dev/null; then
    echo "❌ Funzione $fn non definita in .claude/local-build.sh"
    exit 2
  fi
done

# ─── Inspect PR ───
echo "[1/6] 📥 Lettura metadata PR #$PR_NUM..."
PR_DATA=$(gh pr view "$PR_NUM" --repo "$REPO" --json title,body,headRefName,author,additions,deletions,changedFiles 2>&1)
if echo "$PR_DATA" | grep -q "Could not resolve"; then
  echo "❌ PR #$PR_NUM non esiste"; exit 2
fi

TITLE=$(echo "$PR_DATA" | python -c "import json,sys; print(json.load(sys.stdin)['title'])")
BRANCH=$(echo "$PR_DATA" | python -c "import json,sys; print(json.load(sys.stdin)['headRefName'])")
AUTHOR=$(echo "$PR_DATA" | python -c "import json,sys; print(json.load(sys.stdin)['author']['login'])")
ADD=$(echo "$PR_DATA" | python -c "import json,sys; print(json.load(sys.stdin)['additions'])")
DEL=$(echo "$PR_DATA" | python -c "import json,sys; print(json.load(sys.stdin)['deletions'])")
FILES=$(echo "$PR_DATA" | python -c "import json,sys; print(json.load(sys.stdin)['changedFiles'])")
BODY=$(echo "$PR_DATA" | python -c "import json,sys; print(json.load(sys.stdin)['body'] or '')")

echo "    Title:  $TITLE"
echo "    Branch: $BRANCH (@$AUTHOR · +$ADD/-$DEL · $FILES file)"

# Esponi PR_NUM e altre var alle funzioni lb_*
export PR_NUM REPO ROOT TITLE BRANCH AUTHOR

# ─── 2. Sync branch (delega a local-build) ───
echo ""
echo "[2/6] 🔄 lb_sync_branch $PR_NUM..."
if ! lb_sync_branch "$PR_NUM"; then
  echo "❌ Sync fallito (vedi output sopra)"; exit 2
fi

# ─── 3. Build verify (delega a local-build) ───
echo ""
echo "[3/6] 🔨 lb_build_ios $PR_NUM..."
BUILD_OUT=$(lb_build_ios "$PR_NUM" 2>&1)
echo "$BUILD_OUT"

if echo "$BUILD_OUT" | grep -q "BUILD FAILED"; then
  echo ""
  echo "❌ BUILD FAILED — la PR introduce errori di compilazione"
  echo "   Action: bash .claude/scripts/reject-pr.sh $PR_NUM \"build failed\""
  lb_cleanup "$PR_NUM" || true
  exit 1
fi
if ! echo "$BUILD_OUT" | grep -q "BUILD SUCCEEDED"; then
  echo "⚠️ Output ambiguo (no SUCCESS/FAILED) — verifica manualmente"
  exit 1
fi

# ─── 4. Packaging IPA (delega a local-build) ───
echo ""
echo "[4/6] 📦 lb_package_ipa $PR_NUM..."
if ! lb_package_ipa "$PR_NUM"; then
  echo "⚠️ Packaging IPA fallito — installa manualmente"
fi

# ─── 5. Genera checklist ───
echo ""
echo "[5/6] 📋 Genero checklist..."
CHECKLIST="$CHECKLIST_DIR/pr-$PR_NUM.md"
AC_LINES=$(echo "$BODY" | grep -E '^\s*-\s*\[\s*[ x]?\s*\]' | head -10)

cat > "$CHECKLIST" <<MD
# PR #$PR_NUM Review Checklist

**Title**: $TITLE
**Author**: @$AUTHOR
**Branch**: \`$BRANCH\`
**Diff**: +$ADD/-$DEL · $FILES file

---

## L1 — Automated CI checks
- [x] Validate PR title + body
- [x] move-card / notify / post

## L2 — Code review (Armando)
- [ ] Diff è chirurgico, no surprise file
- [ ] \`Closes #N\` presente nel body
- [ ] Convenzioni rispettate (Conventional Commits, lingua app inglese)

## L3 — Build verify (auto da test-pr.sh)
- [x] BUILD SUCCEEDED via lb_build_ios
- [x] IPA packaged via lb_package_ipa

## L4 — Smoke test su iPhone fisico
- [ ] App lancia senza crash
- [ ] Feature toccata dalla PR funziona alla prima interazione
- [ ] Nessuna regressione visibile su flussi esistenti

## L5 — Acceptance Criteria del body PR
$( [ -n "$AC_LINES" ] && echo "$AC_LINES" || echo "- [ ] Nessun AC esplicito nel body — verifica visivamente la feature" )

---

## Decisione finale

- [ ] **TUTTI L1-L5 ✓** → eseguo: \`bash .claude/scripts/merge-pr.sh $PR_NUM\`
- [ ] **Almeno uno ✗** → eseguo: \`bash .claude/scripts/reject-pr.sh $PR_NUM "<motivo>"\`
- [ ] **Posticipo** → riprovo domani
MD

echo "    ✓ Checklist: $CHECKLIST"

# ─── 6. Verdetto + cleanup ───
echo ""
echo "[6/6] ✅ TEST PRE-MERGE COMPLETATO"
echo ""
echo "   📋 Checklist: $CHECKLIST"
echo ""
echo "Prossimi step (manuali):"
echo "   1. Sideload IPA + test su iPhone fisico"
echo "   2. Marca i checkbox L4+L5 in $CHECKLIST"
echo "   3. Tutti ✓ → bash .claude/scripts/merge-pr.sh $PR_NUM"
echo "      Uno ✗   → bash .claude/scripts/reject-pr.sh $PR_NUM \"motivo\""
echo ""
echo "Cleanup branch (auto via lb_cleanup):"
lb_cleanup "$PR_NUM" || true
