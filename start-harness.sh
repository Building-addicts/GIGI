#!/usr/bin/env bash
# Launcher dalla root del repo GIGI-harness → avvia server + panel nella cartella giusta.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Phase 2 GATE 5 — anti-billing guard (Issue claude-code#45572).
# When ANTHROPIC_API_KEY is set in the environment, the Claude Code CLI
# subprocess may bill API instead of using the subscription. Unset it
# explicitly here so the harness always rides the subscription.
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  echo "[start-harness] WARNING: ANTHROPIC_API_KEY is set — unsetting to force subscription billing."
  echo "[start-harness] If you actually want API billing, export GIGI_ALLOW_API_BILLING=1 to keep the key."
  if [ -z "${GIGI_ALLOW_API_BILLING:-}" ]; then
    unset ANTHROPIC_API_KEY
  fi
fi

exec "$ROOT/03_HARNESS/server/start-all.sh"
