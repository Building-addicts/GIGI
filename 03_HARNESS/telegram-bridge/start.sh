#!/usr/bin/env bash
# Avvia telegram-bridge su macOS/Linux.
# Uso: ./start.sh  (da dentro 03_HARNESS/telegram-bridge/)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f config.json ]; then
  echo "ERRORE: config.json non trovato. Copia da config.example.mac.json e compila." >&2
  exit 1
fi

if [ ! -d node_modules ]; then
  echo "Installo dipendenze..."
  npm install
fi

exec node bridge.js
