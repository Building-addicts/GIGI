#!/usr/bin/env bash
# Background worker. Usa il `claude` CLI (Claude Code, autenticato dalla subscription
# del dev) per generare un riassunto di una riga del turno e appenderlo a
# docs/memory/ACTIVITY_LOG.md.
#
# Vincoli di design:
#  - Nessuna ANTHROPIC_API_KEY richiesta — usa la sessione Claude Code locale
#  - `claude -p` esegue una completion one-shot, output su stdout
#  - --model haiku per costo minimo (non drena la quota Sonnet/Opus)
#  - Niente lock file: collisioni multi-sessione accettabili (append atomico riga)

set -u

TRANSCRIPT="${1:-}"
ROOT="${2:-$(pwd)}"
LOG="$ROOT/docs/memory/ACTIVITY_LOG.md"

[ -f "$TRANSCRIPT" ] || exit 0
[ -d "$(dirname "$LOG")" ] || exit 0

# Bail silenzioso se il `claude` CLI non è in PATH (dev senza Claude Code installato)
if ! command -v claude >/dev/null 2>&1; then
  exit 0
fi

# Slice ultime 200 righe del transcript JSONL, capped a 8KB
SLICE="$(tail -n 200 "$TRANSCRIPT" 2>/dev/null | head -c 8000)"
[ -n "$SLICE" ] || exit 0

# Contesto debug: branch + file con modifiche pending
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
TOUCHED="$(git -C "$ROOT" status --porcelain 2>/dev/null | awk '{print $2}' | grep -v '^$' | head -8 | paste -sd ', ' -)"

# Prompt per Haiku (italiano, stile ACTIVITY_LOG esistente).
PROMPT="Hai questo slice JSONL di un turno Claude Code. Scrivi UNA riga in italiano (max 180 char) che descriva l'azione concreta svolta. Stile come queste entry esistenti:
- \"Audited docs after P1.1/P1.2/P1.3. Updated docs/ARCHITETTURA_V3.md (Role cases note + Bridge/ folder in file tree). Annotated 03_HARNESS/docs/api/ios-integration.md...\"
- \"Marked Phase 4 code COMPLETE in docs/TASK_PLAN.md: P4.1-P4.8 -> COMPLETED...\"
- \"Bootstrapped docs/memory/CODE_MAP.md (first creation). Mapped Phase 4 surface...\"

REGOLE:
1. Una sola riga, niente markdown, niente preambolo, niente quotes esterne.
2. Cita i file modificati con backtick (es. \`docs/CLAUDE.md\`).
3. Se il turno e una pura esplorazione/lettura senza modifiche, rispondi esattamente: SKIP
4. Niente \"Ho fatto\", \"Sto facendo\" — usa forma sintetica al passato/participio (es. \"Aggiornato\", \"Creato\", \"Riorganizzato\").

CONTESTO GIT: branch=$BRANCH; files modificati=$TOUCHED

SLICE TRANSCRIPT:
$SLICE"

# Chiamata Claude CLI. --model haiku per costo basso (non consuma quota Sonnet/Opus).
# Timeout 30s di safety net (claude -p è solitamente <5s).
# GIGI_LOG_HOOK_SUPPRESS=1 evita che la `claude -p` qua dentro triggeri un altro
# Stop hook (anti-ricorsione, vedi activity-log.sh).
SUMMARY="$(printf '%s' "$PROMPT" | GIGI_LOG_HOOK_SUPPRESS=1 timeout 30 claude -p --model haiku --output-format text 2>/dev/null)"

# Sanitize: una sola riga, max 220 char
SUMMARY="$(printf '%s' "$SUMMARY" | tr '\n\r' '  ' | sed 's/[[:space:]]\{2,\}/ /g' | head -c 220)"

# Skip esplicito da Haiku oppure output vuoto
[ -n "$SUMMARY" ] || exit 0
[ "$SUMMARY" = "SKIP" ] && exit 0
echo "$SUMMARY" | grep -q "^SKIP$" && exit 0

# Componi riga di log nello stile ACTIVITY_LOG esistente.
STAMP="$(date '+%Y-%m-%d %H:%M')"
LINE="- \`$STAMP\` · auto · $SUMMARY"
if [ -n "$TOUCHED" ]; then
  LINE="$LINE _(branch: \`$BRANCH\` · files: $TOUCHED)_"
else
  LINE="$LINE _(branch: \`$BRANCH\`)_"
fi

# Append atomico
printf '%s\n' "$LINE" >> "$LOG"

# ─────────────────────────────────────────────────────────────────
# AUTOCOMMIT — committa l'ACTIVITY_LOG con il summary di Haiku come messaggio.
# Si committa SOLO se siamo in un branch != main (evita di sporcare main
# direttamente, che è branch-protected). In worktree feature è ok.
# ─────────────────────────────────────────────────────────────────
CURRENT_BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"

if [ -n "$CURRENT_BRANCH" ] && [ "$CURRENT_BRANCH" != "main" ] && [ "$CURRENT_BRANCH" != "HEAD" ]; then
  # Tronca summary a 100 char per il commit message
  COMMIT_MSG="$(printf '%s' "$SUMMARY" | head -c 100)"
  # Commit limitato al solo file ACTIVITY_LOG.md per non includere altre changes pending
  git -C "$ROOT" add "$LOG" 2>/dev/null
  git -C "$ROOT" commit \
    -m "log: $COMMIT_MSG" \
    -- "$LOG" >/dev/null 2>&1 || true
fi
