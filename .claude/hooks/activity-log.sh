#!/usr/bin/env bash
# Stop hook — pre-filter cheap, spawn Haiku worker async, return immediately.
# Output ends up in docs/memory/ACTIVITY_LOG.md.
#
# Lo scopo:
#  - non bloccare la chiusura del turno (return < 50ms)
#  - non chiamare Haiku se nel turno non c'è stata vera attività operativa
#  - se attività rilevata: spawn worker in background che chiama Haiku via API
#    diretta (no tools, solo completion → garantisce token-budget minimo e
#    impossibilità di letture extra)

set -u

# Leggi JSON da stdin (Claude Code passa { transcript_path, session_id, cwd, stop_hook_active })
INPUT="$(cat)"

# Evita ricorsione: se siamo già dentro un hook che ha bloccato il flusso, esci
if echo "$INPUT" | grep -q '"stop_hook_active":[[:space:]]*true'; then
  exit 0
fi

# Estrai transcript_path (jq se disponibile, altrimenti grep+sed)
if command -v jq >/dev/null 2>&1; then
  TRANSCRIPT="$(echo "$INPUT" | jq -r '.transcript_path // empty')"
else
  TRANSCRIPT="$(echo "$INPUT" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
fi

[ -n "${TRANSCRIPT:-}" ] || exit 0
[ -f "$TRANSCRIPT" ]    || exit 0

# Pre-filtro: nei messaggi recenti del transcript, almeno un tool con side-effect?
# (Edit, Write, NotebookEdit, Bash). Read/Grep/Glob NON contano come "attività".
TURN_TAIL="$(tail -n 800 "$TRANSCRIPT")"
if ! echo "$TURN_TAIL" | grep -qE '"name"[[:space:]]*:[[:space:]]*"(Edit|Write|NotebookEdit|Bash)"'; then
  exit 0
fi

# Project root (passato da Claude Code via env, fallback su pwd)
ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Spawn worker in background. nohup + disown per detach completo.
# stdout/stderr → /dev/null. Il worker non ha accesso allo stdin del padre.
nohup bash "$ROOT/.claude/hooks/activity-log-summarize.sh" "$TRANSCRIPT" "$ROOT" >/dev/null 2>&1 &
disown 2>/dev/null || true

exit 0
