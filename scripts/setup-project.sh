#!/usr/bin/env bash
# Setup GitHub Project v2 per il lancio GIGI.
# Idempotente: rilanciabile senza danno.
# Zero dipendenze esterne (no jq) — usa solo gh + il suo --jq built-in.
#
# Prerequisito: token gh con scope "project,read:project".
# Se manca:  gh auth refresh -s project,read:project
#
# Uso:  bash scripts/setup-project.sh [TITLE]

set -euo pipefail

OWNER="Building-addicts"
REPO="GIGI"
TITLE="${1:-GIGI — Lancio v1}"

echo "==> Verifica scope token gh"
if ! gh project list --owner "$OWNER" --limit 1 >/dev/null 2>&1; then
  echo "❌ Token senza scope project. Run:  gh auth refresh -s project,read:project"
  exit 1
fi

echo "==> Cerca o crea Project '$TITLE'"
PROJECT_NUM="$(gh project list --owner "$OWNER" --limit 100 --format json \
  --jq ".projects[] | select(.title == \"$TITLE\") | .number" | head -1 || true)"

if [ -z "$PROJECT_NUM" ]; then
  PROJECT_NUM="$(gh project create --owner "$OWNER" --title "$TITLE" --format json \
    --jq '.number')"
  echo "   ✓ Creato Project #$PROJECT_NUM"
else
  echo "   ↺ Esiste già Project #$PROJECT_NUM"
fi

PROJECT_ID="$(gh project view "$PROJECT_NUM" --owner "$OWNER" --format json --jq '.id')"
echo "   project_id=$PROJECT_ID"

# ----- Helper: aggiungi single-select field se non esiste -----
# NB: gh CLI splitta le virgole DENTRO --single-select-options come separatori
# di opzioni multiple. Quindi i nomi opzione NON devono contenere virgole.
# I colori non sono settabili via CLI — vanno impostati in browser (10 sec).
add_single_select_field () {
  local name="$1"
  shift
  # I successivi argomenti sono nomi opzione (uno per arg, niente virgole interne)

  local existing
  existing="$(gh project field-list "$PROJECT_NUM" --owner "$OWNER" --format json \
    --jq ".fields[] | select(.name == \"$name\") | .id" | head -1 || true)"

  if [ -n "$existing" ]; then
    echo "   ↺ Field '$name' già presente"
    return
  fi

  local args=()
  for opt in "$@"; do
    args+=( --single-select-options "$opt" )
  done

  gh project field-create "$PROJECT_NUM" --owner "$OWNER" \
    --name "$name" --data-type SINGLE_SELECT "${args[@]}" >/dev/null
  echo "   ✓ Field '$name' creato"
}

echo "==> Custom fields"
add_single_select_field "Priority" \
  "P0 blocker" "P1 must" "P2 should" "P3 nice"

add_single_select_field "Effort" \
  "S (≤2h)" "M (≤1d)" "L (≤2d)"

add_single_select_field "Area" \
  "iOS" "Harness" "MDM" "Docs" "Infra"

# ----- Linka il repo -----
echo "==> Linka repo $OWNER/$REPO al progetto"
if gh project link "$PROJECT_NUM" --owner "$OWNER" --repo "$OWNER/$REPO" >/dev/null 2>&1; then
  echo "   ✓ Repo linkato"
else
  echo "   ↺ Repo già linkato (o link fallito non bloccante)"
fi

echo ""
echo "✅ Setup base completato."
echo ""
echo "URL Project:  https://github.com/orgs/$OWNER/projects/$PROJECT_NUM"
echo ""
echo "PROSSIMI STEP MANUALI (browser, 5 min):"
echo "  1. Aggiungi colonne Status mancanti (Backlog prima, In review tra In Progress e Done)"
echo "  2. Crea 3 view:"
echo "     - Board     → group by Status"
echo "     - Per dev   → layout Table, group by Assignees, sort by Priority"
echo "     - This week → layout Roadmap, filter Iteration = current"
echo "  3. Iteration field built-in → start date oggi, length 1 settimana"
echo "  4. Settings → Workflows → abilita:"
echo "     - Item added to project → Status = Backlog"
echo "     - Item closed → Status = Done"
echo "     - Pull request merged → Status = Done"
