#!/usr/bin/env bash
# tests/context.sh interrupted as Ctrl-C does it, at the points where it changes the sandbox,
# on a machine with Docker: once without KEEP, while Atlas is paused, then with KEEP=1 while
# the allow-all policy is loaded, while Atlas is paused, while the reader's secret is wrong,
# and while Atlas is stopped. After each, the state is read from outside the script: the end
# of the run must have removed the allow-all policy, resumed or started Atlas and put the
# reader's secret back, and without KEEP removed the project. Removes the kept project at
# the end. Takes the same variables as tests/context.sh.
#
#   MCP_IMAGE=<image of 0.8> tests/interrupt.sh
set -uo pipefail
cd "$(dirname "$0")/.."
export COMPOSE_PROFILES=catalogs
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-akko-sandbox-interrupt}"
export COMPOSE_FILE=compose.yaml:catalogs/compose.atlas.yaml:tests/compose.v08.yaml
failed=0
check() { if [ "$2" = "$3" ]; then printf '  OK    %s\n' "$1"; else printf '  FAIL  %s (got %s, expected %s)\n' "$1" "$2" "$3"; failed=1; fi; }
logs=$(mktemp -d)
cleanup() {
  rm -rf "$logs"
  docker compose --profile catalogs --profile tools down -v --remove-orphans >/dev/null 2>&1
  echo "== project $COMPOSE_PROJECT_NAME removed: $(docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" | wc -l) containers left"
}
trap cleanup EXIT

# Runs tests/context.sh in a session of its own and sends SIGINT to its whole process group
# once a line shows, as Ctrl-C does in a terminal. A command started with & in a script
# ignores SIGINT, and a shell cannot trap a signal ignored at its start: the wrapper gives
# SIGINT its default action back first. Prints the run's own end lines and its exit code.
interrupt() { # name, line to wait for, seconds after it, then variables for the script
  local log="$logs/$1.log" pattern=$2 after=$3; shift 3
  : > "$log"
  setsid env "$@" python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
    bash tests/context.sh >> "$log" 2>&1 &
  local pid=$!
  until grep -q -- "$pattern" "$log" || ! kill -0 "$pid" 2>/dev/null; do sleep 1; done
  sleep "$after"
  kill -INT -- "-$pid" 2>/dev/null
  wait "$pid"; local code=$?
  echo "  SIGINT $after s after: $pattern"
  grep -E '^== end of run|^KEEP=1:|^== project' "$log" | sed 's/^/  the run said: /'
  echo "  exit code $code"
}
# What a kept sandbox holds, read from outside the script, once Atlas is healthy again.
state() {
  for _ in $(seq 120); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -aq atlas)" 2>/dev/null)" = healthy ] && break; sleep 5
  done
  docker compose --profile catalogs --profile tools up -d opa-admin >/dev/null 2>&1
  check "  OPA holds the sandbox's policy and the profile's, nothing else" \
    "$(docker compose exec -T opa-admin curl -fsS http://opa:8181/v1/policies | python3 -c 'import sys, json; print(sorted(p["id"] for p in json.load(sys.stdin)["result"]))')" \
    "['policy/catalogs.rego', 'policy/policy.rego']"
  check "  Atlas runs, not paused, healthy" "$(docker inspect -f '{{.State.Status}} {{.State.Paused}} {{.State.Health.Status}}' "$(docker compose ps -aq atlas)")" "running false healthy"
  check "  no kept secret left in the volume" "$(docker compose run --rm --no-deps -T -u 0 --entrypoint /bin/sh atlas-secrets -c 'ls /secrets/reader.kept 2>/dev/null | wc -l' 2>/dev/null | tr -d ' ')" "0"
  check "  Atlas accepts the reader's secret that the server reads" "$(docker compose exec -T atlas sh -c 'curl -s -o /dev/null -w %{http_code} -u mcp_reader:$(cat /secrets/reader.secret) http://localhost:21000/api/atlas/admin/version')" "200"
}

echo "== 1. Without KEEP, while Atlas is paused for the slow call"
interrupt slow "with Atlas healthy: atlas ok" 2
check "  the project is removed" "$(docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" | wc -l | tr -d ' ')" "0"

echo "== 2. KEEP=1, while the allow-all policy is loaded"
interrupt allow-all "the allow-all variant of the policy is loaded" 1 KEEP=1
state
echo "== 3. KEEP=1, while Atlas is paused for the slow call"
interrupt keep-slow "with Atlas healthy: atlas ok" 2 KEEP=1
state
echo "== 4. KEEP=1, while the reader's secret is wrong"
interrupt keep-secret "carol, call 1 with a refused account" 1 KEEP=1
state
echo "== 5. KEEP=1, while Atlas is stopped"
interrupt keep-stopped "== 10. Atlas stopped" 3 KEEP=1
state

[ $failed -eq 0 ] && echo "== INTERRUPT OK ==" || { echo "== INTERRUPT FAILED =="; exit 1; }
