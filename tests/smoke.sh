#!/usr/bin/env bash
# Smoke test of the sandbox, end to end, on a machine with Docker:
# starts the compose project, plays the demo, checks the two different answers,
# current_user, the refusals (401 at the door, 401 at Trino without a token or
# with a token issued for the MCP server), the token exchange, the audit line,
# and measures start time and memory. Removes everything at the
# end unless KEEP=1.
#
#   tests/smoke.sh
#   COMPOSE_PROJECT_NAME=akko-sandbox-test KEYCLOAK_PORT=18480 MCP_PORT=13000 INSPECTOR_PORT=16274 tests/smoke.sh
set -uo pipefail
cd "$(dirname "$0")/.."
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-akko-sandbox-smoke}"
failed=0
check() { if [ "$2" = "$3" ]; then printf '  OK    %s\n' "$1"; else printf '  FAIL  %s (got %s, expected %s)\n' "$1" "$2" "$3"; failed=1; fi; }
stats() { docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' $(docker compose ps -q) | sed "s/^$COMPOSE_PROJECT_NAME-//"; }
cleanup() {
  if [ "${KEEP:-0}" = "1" ]; then echo "KEEP=1: project $COMPOSE_PROJECT_NAME left running"; return; fi
  docker compose --profile tools down -v --remove-orphans >/dev/null 2>&1
  echo "== project $COMPOSE_PROJECT_NAME removed: $(docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" | wc -l) containers, $(docker volume ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" | wc -l) volumes left"
}
trap cleanup EXIT

echo "== 1. Start (project $COMPOSE_PROJECT_NAME)"
start=$(date +%s)
if ! docker compose up -d --wait --wait-timeout 420; then
  docker compose ps -a; docker compose logs --tail 40; exit 1
fi
echo "  all services healthy in $(( $(date +%s) - start )) s"
docker compose ps --format '  {{.Service}}: {{.Status}}'

echo "== 2. Memory at rest"
stats | sed 's/^/  /'

echo "== 3. The demo, as shown"
./demo.sh

echo "== 4. The demo, as assertions (memory sampled meanwhile)"
( for _ in 1 2 3; do stats; done > .smoke-stats ) &
sampler=$!
./demo.sh --check || failed=1
wait $sampler
echo "  peak memory during the demo:"
awk '{print $1, $2}' .smoke-stats | sort -k1,1 -k2,2h | awk '{peak[$1]=$2} END {for (c in peak) print "  " c, peak[c]}' | sort
rm -f .smoke-stats

echo "== 5. Trino verifies tokens itself, the server exchanges them, and logs none"
trino_status() {
  docker compose exec -T mcp python -c "
import httpx, sys
h = {'Authorization': 'Bearer ' + sys.argv[1]} if sys.argv[1] else {}
print(httpx.post('https://trino:8443/v1/statement', content='SELECT 1', headers=h, verify='/certs/ca.crt').status_code)" "$1"
}
check "Trino over https without a token: 401" "$(trino_status '')" "401"
check "Trino refuses a token issued for the MCP server: 401" "$(trino_status "$(./token.sh carol_analyst)")" "401"
logs=$(docker compose logs mcp)
check "no token in the server log" "$(grep -c 'eyJ' <<<"$logs")" "0"
check "no client secret in the server log" "$(grep -c "$(docker compose exec -T mcp cat /certs/mcp-client.secret)" <<<"$logs")" "0"
check "the server exchanged tokens at Keycloak" "$(grep -q 'POST https://keycloak:8443/realms/sandbox/protocol/openid-connect/token "HTTP/1.1 200' <<<"$logs" && echo yes)" "yes"
check "the audit line names carol_analyst" "$(grep -q 'carol_analyst' <<<"$logs" && echo yes)" "yes"

echo "== 6. The MCP Inspector reaches the server with a bearer header"
inspect() {
  docker compose exec -T inspector mcp-inspector --cli http://mcp:3000/mcp \
    --header "Authorization: Bearer $(./token.sh "$1")" --method tools/call --tool-name execute_query \
    --tool-arg "sql=SELECT count(*) FROM demo.crm.customers" | grep -o 'rows[^]]*]]' | head -1 | tr -dc '0-9'
}
check "Inspector as carol_analyst: 5 customers" "$(inspect carol_analyst)" "5"
check "Inspector as alice_admin: 10 customers" "$(inspect alice_admin)" "10"

[ $failed -eq 0 ] && echo "== SMOKE OK ==" || { echo "== SMOKE FAILED =="; exit 1; }
