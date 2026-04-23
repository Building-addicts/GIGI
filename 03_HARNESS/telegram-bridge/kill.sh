#!/usr/bin/env bash
# Kill tutti i processi Harness (bridge + panel + browser CDP).
# Uso: ./kill.sh

set -uo pipefail

echo "=== Kill Harness processi ==="

pkill -f "node.*bridge\.js"    && echo "bridge.js killed"    || echo "bridge.js non attivo"
pkill -f "node.*panel\.js"     && echo "panel.js killed"     || echo "panel.js non attivo"
pkill -f "node.*server\.js"    && echo "browser-mcp killed"  || echo "browser-mcp non attivo"

# Chrome CDP instances (porte 9224-9226)
for port in 9224 9225 9226; do
  pid=$(lsof -t -i ":$port" 2>/dev/null || true)
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null && echo "Chrome CDP $port killed (pid $pid)"
  fi
done

echo "=== Done ==="
