#!/usr/bin/env bash
# Avvia Control Panel + bridge (server.js) + Chrome pool in un solo processo guida.
#
# IMPORTANTE: avviare SOLO questo script (o solo panel.js). Non combinare con
# un server.js già in esecuzione: il panel lancia server.js come figlio "bridge";
# una seconda istanza trova bridge.lock e esce → loop "bridge crashed".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

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
  echo "[start-all] Installo dipendenze server/..."
  npm install
fi

# Le deps di browser-pool/ sono in un package.json separato e server.js le importa al boot.
# Senza questa install il bridge crasha con `Cannot find package 'playwright-core'` su fresh clone.
BROWSER_POOL_DIR="$SCRIPT_DIR/../browser-pool"
if [ -d "$BROWSER_POOL_DIR" ] && [ -f "$BROWSER_POOL_DIR/package.json" ] && [ ! -d "$BROWSER_POOL_DIR/node_modules" ]; then
  echo "[start-all] Installo dipendenze browser-pool/..."
  ( cd "$BROWSER_POOL_DIR" && npm install )
fi

echo "[start-all] Panel su porta 7777; il bridge (API iOS :7779) parte automaticamente. Ctrl+C ferma panel, bridge e Chrome avviati da qui."
exec node panel.js
