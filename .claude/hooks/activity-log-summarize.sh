#!/usr/bin/env bash
# Background worker. Chiama Haiku 4.5 via API Anthropic (no tools, solo completion)
# e appende UNA riga a docs/memory/ACTIVITY_LOG.md.
#
# Vincoli:
#  - Haiku NON ha tool access — riceve solo testo (slice transcript), produce solo testo.
#  - Token spesi minimi: ~3K input + ~50 output → ~$0.005/chiamata.
#  - Niente lock file: collisioni multi-sessione sono accettabili (append atomico
#    riga-per-riga su filesystem locale è safe in pratica).

set -u

TRANSCRIPT="${1:-}"
ROOT="${2:-$(pwd)}"
LOG="$ROOT/docs/memory/ACTIVITY_LOG.md"

[ -f "$TRANSCRIPT" ] || exit 0
[ -d "$(dirname "$LOG")" ] || exit 0

# Bail silenzioso se manca la API key
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  exit 0
fi

# Slice ultimo turno: ultime ~200 righe del transcript JSONL.
# Tronchiamo a 8000 char per evitare prompt enormi (Haiku 4.5 input cap ridicolo
# ma noi vogliamo budget basso).
SLICE="$(tail -n 200 "$TRANSCRIPT" 2>/dev/null | head -c 8000)"
[ -n "$SLICE" ] || exit 0

# Contesto debug: branch git + file con modifiche pending
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
TOUCHED="$(git -C "$ROOT" status --porcelain 2>/dev/null | awk '{print $2}' | grep -v '^$' | head -8 | paste -sd ', ' -)"

# Costruisci prompt per Haiku (italiano, stile ACTIVITY_LOG esistente).
PROMPT_HEADER='Hai questo slice JSONL di un turno Claude Code. Scrivi UNA riga in italiano (max 180 char) che descriva l azione concreta svolta. Stile come queste entry esistenti:
- "Audited docs after P1.1/P1.2/P1.3. Updated docs/ARCHITETTURA_V3.md (Role cases note + Bridge/ folder in file tree). Annotated 03_HARNESS/docs/api/ios-integration.md..."
- "Marked Phase 4 code COMPLETE in docs/TASK_PLAN.md: P4.1-P4.8 -> COMPLETED..."
- "Bootstrapped docs/memory/CODE_MAP.md (first creation). Mapped Phase 4 surface..."

REGOLE:
1. Una sola riga, niente markdown, niente preambolo, niente quotes esterne.
2. Cita i file modificati con backtick (es. `docs/CLAUDE.md`).
3. Se il turno e una pura esplorazione/lettura senza modifiche, rispondi esattamente: SKIP
4. Niente "Ho fatto", "Sto facendo" — usa forma sintetica al passato/participio (es. "Aggiornato", "Creato", "Riorganizzato").

SLICE TRANSCRIPT:
'

PROMPT_FULL="$PROMPT_HEADER

$SLICE

CONTESTO GIT: branch=$BRANCH; files modificati=$TOUCHED"

# Costruzione payload JSON. jq se disponibile, altrimenti escape manuale.
if command -v jq >/dev/null 2>&1; then
  PAYLOAD="$(jq -n --arg p "$PROMPT_FULL" '{
    model: "claude-haiku-4-5-20251001",
    max_tokens: 250,
    messages: [{role:"user", content:$p}]
  }')"
else
  # Fallback: escape minimo (rimuovi backslash, doppi apici, newline → \n).
  ESC="$(printf '%s' "$PROMPT_FULL" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}')"
  PAYLOAD="{\"model\":\"claude-haiku-4-5-20251001\",\"max_tokens\":250,\"messages\":[{\"role\":\"user\",\"content\":\"${ESC}\"}]}"
fi

# Chiamata API (timeout 30s per evitare zombi).
RESP="$(curl -sS --max-time 30 \
  -X POST https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  --data "$PAYLOAD" 2>/dev/null)"

[ -n "$RESP" ] || exit 0

# Estrai testo
if command -v jq >/dev/null 2>&1; then
  SUMMARY="$(echo "$RESP" | jq -r '.content[0].text // empty' 2>/dev/null)"
else
  SUMMARY="$(echo "$RESP" | sed -n 's/.*"text"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | head -c 250)"
fi

# Sanitize: una sola riga, max 200 char
SUMMARY="$(printf '%s' "$SUMMARY" | tr '\n\r' '  ' | sed 's/[[:space:]]\{2,\}/ /g' | head -c 220)"

# Skip esplicito da Haiku (turn esplorativo non rilevante)
[ -n "$SUMMARY" ] || exit 0
[ "$SUMMARY" = "SKIP" ] && exit 0

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
