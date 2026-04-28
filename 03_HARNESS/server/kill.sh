#!/usr/bin/env bash
# Kill tutti i processi GIGI harness (server + panel + browser pool + Chrome CDP).
# Cross-platform: Linux/Mac usa pkill; Win Git Bash (MINGW/MSYS/CYGWIN) delega a kill.ps1.
# Uso: ./kill.sh

set -uo pipefail

echo "=== Kill GIGI harness ==="

OS_RAW=$(uname -s 2>/dev/null || echo "unknown")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$OS_RAW" in
  MINGW*|MSYS*|CYGWIN*)
    # Windows: delego a kill.ps1 (gestisce filtraggio CommandLine senza killare altri node.exe)
    if command -v powershell.exe >/dev/null 2>&1; then
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$SCRIPT_DIR/kill.ps1")" 2>&1 | head -20
    else
      # Fallback: trova PID via netstat sulle porte note + taskkill
      for port in 7777 7778 7779; do
        pid=$(netstat -ano 2>/dev/null | grep -E ":$port\\b" | grep LISTENING | awk '{print $NF}' | head -1)
        if [ -n "$pid" ]; then
          taskkill //F //PID "$pid" >/dev/null 2>&1 && echo "port $port (pid $pid) killed" || echo "port $port (pid $pid) kill failed"
        fi
      done
    fi
    ;;
  *)
    # Linux/Mac: pkill matching CommandLine
    pkill -f "node.*server\\.js"               && echo "server.js killed"      || echo "server.js non attivo"
    pkill -f "node.*panel\\.js"                && echo "panel.js killed"       || echo "panel.js non attivo"
    pkill -f "node.*browser-pool/server"       && echo "browser-pool killed"   || echo "browser-pool non attivo"

    # Chrome CDP instances (porte 9224-9226)
    for port in 9224 9225 9226; do
      pid=$(lsof -t -i ":$port" 2>/dev/null || true)
      if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null && echo "Chrome CDP $port killed (pid $pid)"
      fi
    done
    ;;
esac

echo "=== Done ==="
