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

# ─── Idempotent restart (2026-05-12) ──────────────────────────────────
# If a previous instance left ports occupied, kill it and restart clean.
# Without this the user has to manually find + taskkill stale processes.
#
# Ports we own:
#   7777 = panel admin (web UI)
#   7778 = RPC loopback (panel↔server)
#   7779 = iOS HTTP+WS (bridge)
# Plus cloudflared.exe and any orphan node.exe holding bridge.lock.

kill_port() {
  local PORT="$1"
  local PID=""
  # Try Linux/Mac first (lsof), then Windows (netstat -ano)
  if command -v lsof >/dev/null 2>&1; then
    PID=$(lsof -ti :"$PORT" 2>/dev/null | head -1)
  fi
  if [ -z "$PID" ] && command -v netstat >/dev/null 2>&1; then
    # Windows netstat -ano format: "  TCP    0.0.0.0:7777    0.0.0.0:0    LISTENING    12345"
    PID=$(netstat -ano 2>/dev/null | awk -v p=":$PORT" '$2 ~ p && /LISTENING/ {print $NF}' | head -1)
  fi
  if [ -n "$PID" ] && [ "$PID" != "0" ]; then
    echo "[start-all] Killing stale PID $PID on port $PORT..."
    if command -v taskkill >/dev/null 2>&1; then
      taskkill //F //PID "$PID" >/dev/null 2>&1 || true
    else
      kill -9 "$PID" 2>/dev/null || true
    fi
  fi
}

for PORT in 7777 7778 7779; do
  kill_port "$PORT"
done

# Kill any stale cloudflared subprocess (Windows + Mac/Linux)
if command -v taskkill >/dev/null 2>&1; then
  taskkill //F //IM cloudflared.exe >/dev/null 2>&1 || true
fi
if command -v pkill >/dev/null 2>&1; then
  pkill -9 -f cloudflared 2>/dev/null || true
fi

# Cleanup stale lock files
rm -f logs/bridge.lock logs/panel.lock 2>/dev/null

# Give the OS a moment to release the ports
sleep 1

echo "[start-all] Panel su porta 7777; il bridge (API iOS :7779) parte automaticamente. Ctrl+C ferma panel, bridge e Chrome avviati da qui."
exec node panel.js
