#!/usr/bin/env bash
# Avvia GIGI harness server su macOS/Linux.
# Uso: ./start.sh  (da dentro 03_HARNESS/server/)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Carica .env se presente (VPS-ready)
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

CONFIG_FILE="${HARNESS_CONFIG:-$SCRIPT_DIR/config.json}"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERRORE: config non trovato a $CONFIG_FILE. Copia da config.example.mac.json e compila." >&2
  exit 1
fi

if [ ! -d node_modules ]; then
  echo "Installo dipendenze..."
  npm install
fi

exec node server.js
