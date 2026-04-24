#!/usr/bin/env bash
# Launcher dalla root del repo GIGI-harness → avvia server + panel nella cartella giusta.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$ROOT/03_HARNESS/server/start-all.sh"
