#!/usr/bin/env bash
# Background worker. Appende una riga "no-AI" su docs/memory/ACTIVITY_LOG.md
# basata su dati git (branch + file modificati + ultimo commit message).
#
# Storia: la versione precedente chiamava `claude -p --model haiku` per
# generare un summary AI. Disabilitata il 2026-04-28 perché:
#  - I dev (Leo, Fede) non hanno claude CLI autenticato → fallimenti silenziosi
#  - Le mie sessioni consumavano ~5k token Haiku/giorno per descrizioni
#    già coperte dal commit message conventional
#  - L'auto-timeline workflow GitHub-side (PR/issue events) ora è la fonte
#    primaria di ACTIVITY_LOG, questo hook è un complemento "intra-sessione"
#
# Vincoli di design:
#  - Zero token, zero AI
#  - Pure bash + git
#  - Sempre funzionante indipendentemente da setup dev

set -u

TRANSCRIPT="${1:-}"
ROOT="${2:-$(pwd)}"
LOG="$ROOT/docs/memory/ACTIVITY_LOG.md"

[ -d "$(dirname "$LOG")" ] || exit 0

# Contesto: branch + file modificati + ultimo commit del branch (se esiste)
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
TOUCHED="$(git -C "$ROOT" status --porcelain 2>/dev/null | awk '{print $2}' | grep -v '^$' | head -5 | paste -sd ', ' -)"
LAST_COMMIT_MSG="$(git -C "$ROOT" log -1 --pretty='%s' 2>/dev/null | head -c 80)"

# Pre-filtro: se né file modificati né commit recente, è una sessione di sola
# esplorazione/lettura — skip per non riempire il log di rumore.
if [ -z "$TOUCHED" ] && [ -z "$LAST_COMMIT_MSG" ]; then
  exit 0
fi

# Pre-filtro 2: tail del transcript per cercare side-effect (Edit/Write/Bash).
# Salta se la sessione è puramente Read/Grep/Glob.
if [ -f "$TRANSCRIPT" ]; then
  if ! tail -n 200 "$TRANSCRIPT" 2>/dev/null | grep -qE '"name":"(Edit|Write|NotebookEdit|Bash|MultiEdit)"'; then
    exit 0
  fi
fi

# Compose entry — descrittiva ma deterministica.
STAMP="$(date '+%Y-%m-%dT%H:%M:%S%z')"
SUMMARY="session ended on \`$BRANCH\`"
[ -n "$LAST_COMMIT_MSG" ] && SUMMARY="$SUMMARY (last commit: ${LAST_COMMIT_MSG})"

LINE="- \`$STAMP\` · local · $SUMMARY"
[ -n "$TOUCHED" ] && LINE="$LINE _(modified: $TOUCHED)_"

# Append atomico
printf '%s\n' "$LINE" >> "$LOG"

# ─────────────────────────────────────────────────────────────────
# AUTOCOMMIT — committa l'ACTIVITY_LOG. Solo se siamo su feature branch
# (evita di sporcare main direttamente, che è branch-protected).
# ─────────────────────────────────────────────────────────────────
CURRENT_BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"

if [ -n "$CURRENT_BRANCH" ] && [ "$CURRENT_BRANCH" != "main" ] && [ "$CURRENT_BRANCH" != "HEAD" ]; then
  COMMIT_MSG="log(local): $(printf '%s' "$SUMMARY" | head -c 80)"
  git -C "$ROOT" add "$LOG" 2>/dev/null
  git -C "$ROOT" commit -m "$COMMIT_MSG" -- "$LOG" >/dev/null 2>&1 || true
fi
