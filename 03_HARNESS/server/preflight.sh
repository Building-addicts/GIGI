#!/usr/bin/env bash
# preflight.sh — verifica setup harness pronto (config.json + .env vs example baseline)
#
# Exit codes:
#   0 = ready (config + env presenti, no missing top-level keys)
#   1 = missing required top-level keys in config (.env warning non blocca)
#   2 = file totalmente assente (config.json o .env)
#
# Uso: bash 03_HARNESS/server/preflight.sh  (da qualsiasi cwd dentro il repo)

set -uo pipefail

# --- Colori (disabilitabili via NO_COLOR=1) ---
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  C_OK=""; C_WARN=""; C_ERR=""; C_RESET=""
else
  C_OK=$'\033[0;32m'; C_WARN=$'\033[0;33m'; C_ERR=$'\033[0;31m'; C_RESET=$'\033[0m'
fi

log_ok()   { printf "%s[OK]%s   %s\n"   "$C_OK"   "$C_RESET" "$*"; }
log_warn() { printf "%s[WARN]%s %s\n"   "$C_WARN" "$C_RESET" "$*"; }
log_err()  { printf "%s[ERR]%s  %s\n"   "$C_ERR"  "$C_RESET" "$*" >&2; }

# --- Server dir = dir dello script stesso (robusto a cwd e worktree multipli) ---
SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$SERVER_DIR/server.js" ] && [ ! -f "$SERVER_DIR/panel.js" ]; then
  log_err "$SERVER_DIR doesn't look like the harness server dir (missing server.js / panel.js)."
  log_err "Move preflight.sh back into 03_HARNESS/server/ or run it from there."
  exit 2
fi

# --- OS detect → scegli example baseline ---
OS_RAW=$(uname -s 2>/dev/null || echo "unknown")
case "$OS_RAW" in
  Darwin)
    OS_LABEL="mac"
    EXAMPLE_CONFIG="$SERVER_DIR/config.example.mac.json"
    ;;
  Linux|MINGW*|MSYS*|CYGWIN*)
    OS_LABEL="win-or-linux"
    EXAMPLE_CONFIG="$SERVER_DIR/config.example.json"
    ;;
  *)
    log_warn "Unknown OS '$OS_RAW' — defaulting to config.example.json"
    OS_LABEL="unknown"
    EXAMPLE_CONFIG="$SERVER_DIR/config.example.json"
    ;;
esac

EXAMPLE_ENV="$SERVER_DIR/.env.example"
USER_CONFIG="$SERVER_DIR/config.json"
USER_ENV="$SERVER_DIR/.env"

if [ ! -f "$EXAMPLE_CONFIG" ]; then
  log_err "Example baseline missing: $EXAMPLE_CONFIG"
  exit 2
fi

# --- Estrazione keys ---
extract_json_top_keys() {
  local file="$1"
  local out
  if command -v jq >/dev/null 2>&1; then
    out=$(jq -r 'keys[]' "$file" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$out" ]; then
      echo "$out"
      return 0
    fi
    # jq exists ma è fake/broken o file unparseable → fallback grep
  fi
  grep -E '^  "[a-zA-Z_]+"[[:space:]]*:' "$file" | sed -E 's/^  "([a-zA-Z_]+)".*/\1/'
}

extract_env_keys() {
  local file="$1"
  grep -E '^[A-Z_][A-Z0-9_]*=' "$file" | sed -E 's/=.*//'
}

# --- Header ---
echo
echo "GIGI Harness Preflight"
echo "  OS detected:    $OS_RAW ($OS_LABEL)"
echo "  Server dir:     $SERVER_DIR"
echo "  Config example: $(basename "$EXAMPLE_CONFIG")"
echo "  Env example:    $(basename "$EXAMPLE_ENV")"
echo
printf "  %-15s | %-7s | %s\n" "FILE" "EXISTS" "STATUS / MISSING KEYS"
printf "  %-15s-+-%-7s-+-%s\n" "---------------" "-------" "------------------------------------"

EXIT_CODE=0
MISSING_FILE=0

# --- config.json check ---
if [ ! -f "$USER_CONFIG" ]; then
  printf "  %-15s | %-7s | %s\n" "config.json" "NO" "FILE ABSENT"
  MISSING_FILE=1
else
  required_keys=$(extract_json_top_keys "$EXAMPLE_CONFIG" | sort -u)
  user_keys=$(extract_json_top_keys "$USER_CONFIG" | sort -u)
  if [ -z "$user_keys" ]; then
    printf "  %-15s | %-7s | %s\n" "config.json" "yes" "UNPARSEABLE (invalid JSON?)"
    EXIT_CODE=1
  else
    missing=$(comm -23 <(echo "$required_keys") <(echo "$user_keys") | tr '\n' ',' | sed 's/,$//')
    if [ -z "$missing" ]; then
      printf "  %-15s | %-7s | %s\n" "config.json" "yes" "OK"
    else
      printf "  %-15s | %-7s | MISSING: %s\n" "config.json" "yes" "$missing"
      EXIT_CODE=1
    fi
  fi
fi

# --- .env check ---
if [ ! -f "$USER_ENV" ]; then
  printf "  %-15s | %-7s | %s\n" ".env" "NO" "FILE ABSENT"
  MISSING_FILE=1
else
  required_env=$(extract_env_keys "$EXAMPLE_ENV" | sort -u)
  user_env=$(extract_env_keys "$USER_ENV" | sort -u)
  missing_env=$(comm -23 <(echo "$required_env") <(echo "$user_env") | tr '\n' ',' | sed 's/,$//')
  if [ -z "$missing_env" ]; then
    printf "  %-15s | %-7s | %s\n" ".env" "yes" "OK"
  else
    printf "  %-15s | %-7s | (warn) override missing: %s\n" ".env" "yes" "$missing_env"
  fi
fi

echo

# --- Final verdict ---
if [ "$MISSING_FILE" -eq 1 ]; then
  log_err "Preflight FAIL — required file(s) absent."
  echo
  echo "  Fix: copy from example and edit values."
  if [ ! -f "$USER_CONFIG" ]; then
    echo "    cp \"$EXAMPLE_CONFIG\" \"$USER_CONFIG\""
  fi
  if [ ! -f "$USER_ENV" ]; then
    echo "    cp \"$EXAMPLE_ENV\" \"$USER_ENV\""
  fi
  exit 2
fi

if [ "$EXIT_CODE" -ne 0 ]; then
  log_err "Preflight FAIL — config.json missing required top-level keys."
  echo "  Fix: add the missing keys (compare with $(basename "$EXAMPLE_CONFIG"))."
  exit 1
fi

log_ok "Preflight READY — config + env present and complete."
exit 0
