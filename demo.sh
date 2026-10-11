#!/usr/bin/env bash
# Plays the sandbox demo: carol and alice ask the same question through MCP and
# get two different answers, dave is refused, and the door refuses a request
# without a valid token. Start the sandbox first: docker compose up -d --wait
#   ./demo.sh           the demo
#   ./demo.sh --check   the same, as assertions (used by tests/smoke.sh)
set -euo pipefail
cd "$(dirname "$0")"
tty=-T
[ -t 1 ] && tty=
exec docker compose --progress quiet run --rm --no-deps $tty client "$@"
