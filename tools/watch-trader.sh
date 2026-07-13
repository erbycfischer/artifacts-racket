#!/usr/bin/env bash
# Waits for an Artifacts token to appear (env var or ~/.artifacts/token), then
# launches the trader bot. Runs in PRETEND mode by default: real login + real
# character movement + real market reads, but orders are simulated (no gold
# moves) so you can watch your character in the 3D visualizer safely.
#
# Usage:
#   ./tools/watch-trader.sh            # pretend mode, waits up to 10 min
#   PRETEND=0 ./tools/watch-trader.sh  # real orders (spends gold)
#   DRY_RUN=1 ./tools/watch-trader.sh  # synthetic characters, no token needed
#   ITERATIONS=5 ./tools/watch-trader.sh
#
# If you already have a token, skip the wait and run the bot directly:
#   ARTIFACTS_PRETEND=1 racket examples/trader-bot.rkt

set -u

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOKEN_FILE="${HOME}/.artifacts/token"
TIMEOUT_SECONDS="${WATCH_TIMEOUT:-600}"
PRETEND="${PRETEND:-1}"
DRY_RUN="${DRY_RUN:-0}"
ITERATIONS="${ITERATIONS:-}"

echo "watch-trader: repo=${REPO_DIR}"
echo "watch-trader: waiting up to ${TIMEOUT_SECONDS}s for a token (env ARTIFACTS_API_TOKEN / ${TOKEN_FILE}) ..."

have_token() {
  [ -n "${ARTIFACTS_API_TOKEN:-}" ] || [ -n "${ARTIFACTS_TOKEN:-}" ] || [ -f "$TOKEN_FILE" ]
}

elapsed=0
while [ "$elapsed" -lt "$TIMEOUT_SECONDS" ]; do
  if have_token; then
    echo "watch-trader: token detected after ${elapsed}s; launching trader bot ..."
    cd "$REPO_DIR" || exit 1
    export ARTIFACTS_PRETEND="$PRETEND"
    export ARTIFACTS_DRY_RUN="$DRY_RUN"
    [ -n "$ITERATIONS" ] && export ARTIFACTS_ITERATIONS="$ITERATIONS"
    exec racket examples/trader-bot.rkt
  fi
  sleep 3
  elapsed=$((elapsed + 3))
done

echo "watch-trader: timeout — no token appeared. Create one with:"
echo "  racket tools/gen-token.rkt login <user> <pass>"
exit 1
