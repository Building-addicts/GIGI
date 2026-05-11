#!/usr/bin/env bash
# setup-oss-demo.sh — GIGI OSS-friendly setup wizard (Phase 2 — GATE 7)
#
# What this script does, in order:
#   1. Banner + OS detect
#   2. Check Node.js >= 20
#   3. Check Claude Code CLI ("claude --version") + auth status
#   4. Check Playwright + Chromium (for MCP harness-browser)
#   5. Detect Ollama install + RAM-based tier proposal
#   6. unset ANTHROPIC_API_KEY (Issue claude-code#45572 mitigation)
#   7. Generate .env.example (no secrets)
#   8. npm install in 03_HARNESS/server
#   9. Smoke test: harness /api/ios/health (if running)
#  10. Final report + next steps
#
# Idempotent: safe to run multiple times. Exits 0 on success, 1+ on failure.
#
# Reference: docs/plans/frolicking-stargazing-pancake.md §3.9
# docs/taskplans_new_gigi/GATE-7-modes-setup-wizard.md §3 Task 7.5

set -uo pipefail

# --- pretty output -----------------------------------------------------------

if [ -t 1 ]; then
  G="\033[32m"; Y="\033[33m"; R="\033[31m"; B="\033[34m"; D="\033[2m"; N="\033[0m"
else
  G=""; Y=""; R=""; B=""; D=""; N=""
fi

ok()    { printf "${G}✓${N} %s\n" "$1"; }
warn()  { printf "${Y}!${N} %s\n" "$1"; }
fail()  { printf "${R}✗${N} %s\n" "$1"; }
info()  { printf "${B}→${N} %s\n" "$1"; }
hr()    { printf "${D}%s${N}\n" "------------------------------------------------------------"; }

# --- locate repo root --------------------------------------------------------

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
HARNESS_DIR="$REPO_ROOT/03_HARNESS"

cd "$REPO_ROOT"

# --- banner ------------------------------------------------------------------

hr
printf "${G}GIGI OSS setup wizard${N}\n"
printf "${D}repo: %s${N}\n" "$REPO_ROOT"
hr

ERRORS=0
WARNINGS=0

# --- 1. OS detect ------------------------------------------------------------

UNAME="$(uname -s 2>/dev/null || echo unknown)"
info "Host OS: $UNAME"

# --- 2. Node.js >=20 ---------------------------------------------------------

if ! command -v node >/dev/null 2>&1; then
  fail "Node.js not found. Install Node 20+ from https://nodejs.org or via nvm."
  ERRORS=$((ERRORS+1))
else
  NODE_VERSION=$(node --version | sed 's/^v//' | cut -d. -f1)
  if [ "$NODE_VERSION" -ge 20 ] 2>/dev/null; then
    ok "Node.js $(node --version)"
  else
    fail "Node.js too old ($(node --version)). Need >=20."
    ERRORS=$((ERRORS+1))
  fi
fi

# --- 3. Claude Code CLI ------------------------------------------------------

if command -v claude >/dev/null 2>&1; then
  CLAUDE_VERSION="$(claude --version 2>/dev/null | head -1 || echo unknown)"
  ok "Claude Code CLI: $CLAUDE_VERSION"
  # Best-effort auth check — `claude --print` with empty input usually errors
  # quickly if not authenticated. Skip if it would hang.
  info "  (skip explicit auth check — run \`claude\` interactively if unsure)"
else
  warn "Claude Code CLI not installed. Path 4 (delegate_cloud) will be unavailable in Minimal/Apple Optimized/Full Power modes."
  warn "  Install: https://claude.com/code · then run \`claude\` to authenticate."
  WARNINGS=$((WARNINGS+1))
fi

# --- 4. Playwright + Chromium ------------------------------------------------

if [ -d "$HARNESS_DIR/browser-pool/node_modules" ] || [ -d "$REPO_ROOT/node_modules/playwright" ]; then
  if command -v npx >/dev/null 2>&1; then
    info "Verifying Chromium for Playwright (MCP harness-browser)..."
    if (cd "$HARNESS_DIR/browser-pool" 2>/dev/null && npx --no-install playwright install chromium >/dev/null 2>&1); then
      ok "Playwright Chromium ready"
    else
      warn "Playwright Chromium may need installation: cd $HARNESS_DIR/browser-pool && npx playwright install chromium"
      WARNINGS=$((WARNINGS+1))
    fi
  fi
else
  warn "Playwright not yet installed in browser-pool. Run \`npm install\` there first."
  WARNINGS=$((WARNINGS+1))
fi

# --- 5. Ollama + RAM-based tier proposal -------------------------------------

if command -v ollama >/dev/null 2>&1; then
  ok "Ollama installed: $(ollama --version 2>/dev/null | head -1 || echo unknown)"
  # Probe RAM
  RAM_GB=""
  case "$UNAME" in
    Darwin)
      RAM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
      RAM_GB=$(( RAM_BYTES / 1024 / 1024 / 1024 )) ;;
    Linux)
      RAM_KB=$(grep -i memtotal /proc/meminfo 2>/dev/null | awk '{print $2}')
      RAM_GB=$(( RAM_KB / 1024 / 1024 )) ;;
    *)
      RAM_GB="" ;;
  esac

  if [ -n "$RAM_GB" ] && [ "$RAM_GB" -gt 0 ] 2>/dev/null; then
    info "Detected RAM: ${RAM_GB} GB"
    if [ "$RAM_GB" -ge 32 ]; then       TIER="pro";     MODEL="qwen3.6:27b"
    elif [ "$RAM_GB" -ge 16 ]; then     TIER="default"; MODEL="qwen3:14b"
    elif [ "$RAM_GB" -ge 8 ]; then      TIER="standard"; MODEL="qwen3:8b"
    else                                TIER="lite";    MODEL="qwen3:4b"
    fi
    ok "Recommended tier: $TIER ($MODEL)"
    info "  Pull this model: ollama pull $MODEL"
  else
    warn "Could not detect RAM. Manually pick a tier in 03_HARNESS/server/local-llm/config.json"
    WARNINGS=$((WARNINGS+1))
  fi

  # Probe reachability
  if curl -sf --max-time 2 http://localhost:11434/api/version >/dev/null 2>&1; then
    ok "Ollama daemon reachable at localhost:11434"
  else
    warn "Ollama daemon not running. Start with: ollama serve"
    WARNINGS=$((WARNINGS+1))
  fi
else
  warn "Ollama not installed. Path 3 (delegate_local) will be unavailable in Local-First/Full Power modes."
  warn "  Install: https://ollama.com/download · or \`brew install ollama\` on macOS"
  WARNINGS=$((WARNINGS+1))
fi

# --- 6. unset ANTHROPIC_API_KEY ----------------------------------------------

if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  warn "ANTHROPIC_API_KEY is set in this shell — Claude Code may bill API instead of using subscription (Issue claude-code#45572)."
  warn "  Recommended: \`unset ANTHROPIC_API_KEY\` before starting the harness."
  WARNINGS=$((WARNINGS+1))
else
  ok "ANTHROPIC_API_KEY not set (good — Claude Code uses subscription)"
fi

# --- 7. Generate .env.example -----------------------------------------------

ENV_EXAMPLE="$REPO_ROOT/.env.example"
if [ ! -f "$ENV_EXAMPLE" ]; then
  cat > "$ENV_EXAMPLE" <<'EOF'
# GIGI environment variables — copy to .env (gitignored) and fill in.
# Generated by scripts/setup-oss-demo.sh.

# Harness HTTP+WS server port (default 7779). iOS pairs via QR to this.
HARNESS_PORT=7779

# Bearer secret iOS sends in Authorization header. Generate a random one:
#   openssl rand -hex 32
HARNESS_SHARED_SECRET=

# Ollama local URL (Path 3). Default localhost:11434.
OLLAMA_URL=http://127.0.0.1:11434

# Claude Code CLI installation root (auto-detected if claude is on PATH).
# CLAUDE_CODE_HOME=/usr/local/bin

# APNS — only needed for proactive push notifications.
# APNS_KEY_PATH=
# APNS_KEY_ID=
# APNS_TEAM_ID=
# APNS_BUNDLE_ID=io.gigi.app

# Set NO ANTHROPIC_API_KEY here — Claude Code uses subscription, billing
# via API would burn $$. See Issue claude-code#45572.
EOF
  ok "Generated $ENV_EXAMPLE"
else
  ok ".env.example already exists (kept as-is)"
fi

# --- 8. npm install in harness -----------------------------------------------

if [ -f "$HARNESS_DIR/server/package.json" ]; then
  info "Running npm install in 03_HARNESS/server (idempotent)..."
  if (cd "$HARNESS_DIR/server" && npm install --no-audit --no-fund >/dev/null 2>&1); then
    ok "Harness dependencies installed"
  else
    fail "npm install failed in $HARNESS_DIR/server. Run manually to see the error."
    ERRORS=$((ERRORS+1))
  fi
else
  warn "No package.json found at $HARNESS_DIR/server"
  WARNINGS=$((WARNINGS+1))
fi

# --- 9. Smoke test harness health endpoint -----------------------------------

PORT="${HARNESS_PORT:-7779}"
if curl -sf --max-time 2 "http://localhost:$PORT/api/ios/health" >/dev/null 2>&1; then
  ok "Harness already running on port $PORT (smoke health OK)"
else
  info "Harness not running yet. Start it with: ./start-harness.sh"
fi

# --- 10. final report --------------------------------------------------------

hr
if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
  printf "${G}Setup complete — no errors, no warnings.${N}\n"
elif [ "$ERRORS" -eq 0 ]; then
  printf "${Y}Setup complete with $WARNINGS warning(s) — most modes available.${N}\n"
else
  printf "${R}Setup failed with $ERRORS error(s) and $WARNINGS warning(s).${N}\n"
fi
hr
info "Next steps:"
echo "  1. Edit .env (copy from .env.example) and set HARNESS_SHARED_SECRET."
echo "  2. Start the harness:  ./start-harness.sh"
echo "  3. Open GIGI on iPhone, pair via QR (Settings → Harness → Pair)."
echo "  4. In Settings → Modes, pick the operating mode that matches your setup."
hr

if [ "$ERRORS" -gt 0 ]; then exit 1; fi
exit 0
