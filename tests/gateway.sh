#!/usr/bin/env bash
# The sandbox behind Trino Gateway, end to end, on a machine with Docker:
# the MCP server reaches Trino only through the gateway, which routes queries to
# two clusters. Checks the two different answers, that the server cannot reach
# a backend directly, that queries spread over both clusters under the user's
# own name, that results longer than one page and a cancel both go through the
# gateway, and that the gateway changes nothing to the refusals. Removes
# everything at the end unless KEEP=1.
#
#   tests/gateway.sh
#   COMPOSE_PROJECT_NAME=akko-gw KEYCLOAK_PORT=18480 MCP_PORT=13000 INSPECTOR_PORT=16274 tests/gateway.sh
set -uo pipefail
cd "$(dirname "$0")/.."
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-akko-sandbox-gateway}"
export COMPOSE_FILE=compose.yaml:gateway/compose.gateway.yaml
failed=0
check() { if [ "$2" = "$3" ]; then printf '  OK    %s\n' "$1"; else printf '  FAIL  %s (got %s, expected %s)\n' "$1" "$2" "$3"; failed=1; fi; }
cleanup() {
  if [ "${KEEP:-0}" = "1" ]; then echo "KEEP=1: project $COMPOSE_PROJECT_NAME left running"; return; fi
  docker compose --profile tools down -v --remove-orphans >/dev/null 2>&1
  echo "== project $COMPOSE_PROJECT_NAME removed: $(docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" | wc -l) containers left"
}
trap cleanup EXIT

# An MCP tool call through the Inspector CLI, as $1, printing the tool's JSON.
call() { # user, tool, then name=value arguments
  local user=$1 tool=$2; shift 2
  local args=(); for a in "$@"; do args+=(--tool-arg "$a"); done
  docker compose exec -T inspector mcp-inspector --cli http://mcp:3000/mcp \
    --header "Authorization: Bearer $(./token.sh "$user")" --method tools/call \
    --tool-name "$tool" "${args[@]}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['content'][0]['text'])"
}
field() { python3 -c "import sys,json; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {'d': d}))" "$1"; }
history() { docker compose exec -T gateway-db psql -U gateway -d gateway -tAc "$1"; }

echo "== 1. Start (project $COMPOSE_PROJECT_NAME, gateway in front of two clusters)"
start=$(date +%s)
if ! docker compose up -d --wait --wait-timeout 480; then
  docker compose ps -a; docker compose logs --tail 40; exit 1
fi
docker compose --profile tools up -d probe >/dev/null 2>&1
echo "  all services healthy in $(( $(date +%s) - start )) s"
docker compose exec -T probe curl -fsS http://gateway:8080/api/public/backends | sed 's/^/  backends: /'; echo

echo "== 2. The demo, as assertions, through the gateway"
./demo.sh --check || failed=1

echo "== 3. The server can reach the gateway only"
reach() { docker compose exec -T mcp python -c "
import socket, sys
try:
    socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=3).close(); print('reachable')
except OSError: print('unreachable')" "$1" "$2"; }
check "the server reaches the gateway" "$(reach gateway 8443)" "reachable"
check "the server cannot reach trino" "$(reach trino 8080)" "unreachable"
check "the server cannot reach trino-2" "$(reach trino-2 8080)" "unreachable"

echo "== 4. Queries spread over both clusters, each under the user's own name"
for _ in 1 2 3 4 5 6 7 8 9 10; do call carol_analyst execute_query "sql=SELECT count(*) FROM demo.crm.customers" >/dev/null; done
check "the gateway sent queries to trino" "$(history "SELECT count(*) > 0 FROM query_history WHERE backend_url = 'http://trino:8080'")" "t"
check "the gateway sent queries to trino-2" "$(history "SELECT count(*) > 0 FROM query_history WHERE backend_url = 'http://trino-2:8080'")" "t"
check "every routed query carries a user's own name" "$(history "SELECT count(*) FROM query_history WHERE user_name NOT IN ('carol_analyst', 'alice_admin', 'dave_viewer')")" "0"
check "carol's queries are recorded as carol_analyst" "$(history "SELECT count(*) >= 10 FROM query_history WHERE user_name = 'carol_analyst'")" "t"
history "SELECT '  ' || backend_url || ': ' || count(*) FROM query_history GROUP BY backend_url ORDER BY 1"

echo "== 5. A result longer than one page comes back through the gateway"
out=$(call alice_admin execute_query "sql=SELECT x FROM UNNEST(sequence(1, 5000)) AS t(x)")
check "100 rows, cut by the server's cap" "$(field 'len(d["rows"])' <<<"$out")" "100"
check "the answer says it was cut" "$(field 'd["truncated"]' <<<"$out")" "True"

echo "== 6. A query past its time budget is cancelled in Trino, through the gateway"
slow="SELECT count(*) FROM UNNEST(sequence(1, 10000)) a(x) CROSS JOIN UNNEST(sequence(1, 10000)) b(y) CROSS JOIN UNNEST(sequence(1, 10000)) c(z)"
out=$(call carol_analyst execute_query "sql=$slow")
check "the server answers with an error" "$(field '"error" in d' <<<"$out")" "True"
sleep 3
carol_for_trino=$(./token.sh carol_analyst trino-cli)
states() { # backend: the state of carol's cross join queries there, one per line
  docker compose exec -T probe curl -fsS "http://$1:8080/v1/query" \
    -H "Authorization: Bearer $carol_for_trino" -H "X-Forwarded-Proto: https" \
    | python3 -c "import sys,json; [print(q['state']) for q in json.load(sys.stdin) if 'CROSS JOIN' in q.get('query', '')]"
}
all_states=$( { states trino; states trino-2; } | sort | uniq -c | sed 's/^ *//')
echo "  carol's slow query on the clusters: ${all_states:-none}"
check "the slow query reached a cluster" "$( [ -n "$all_states" ] && echo yes)" "yes"
check "no slow query is still running" "$(grep -c -E 'RUNNING|QUEUED|PLANNING|STARTING' <<<"$all_states")" "0"

echo "== 7. The gateway changes nothing to the refusals"
gw_status() {
  docker compose exec -T mcp python -c "
import httpx, sys
h = {'Authorization': 'Bearer ' + sys.argv[1]} if sys.argv[1] else {}
print(httpx.post('https://gateway:8443/v1/statement', content='SELECT 1', headers=h, verify='/certs/ca.crt').status_code)" "$1"
}
check "gateway without a token: 401" "$(gw_status '')" "401"
check "gateway with a token issued for the MCP server: 401" "$(gw_status "$(./token.sh carol_analyst)")" "401"
gw_as() { # token, X-Trino-User or empty: prints the row count, or the error
  docker compose exec -T mcp python -c "
import httpx, sys
h = {'Authorization': 'Bearer ' + sys.argv[1]}
if sys.argv[2]: h['X-Trino-User'] = sys.argv[2]
kw = dict(headers=h, verify='/certs/ca.crt', timeout=30)
r = httpx.post('https://gateway:8443/v1/statement', content='SELECT count(*) FROM demo.crm.customers', **kw).json()
rows = []
while True:
    if 'error' in r: print(r['error']['message']); break
    rows += r.get('data', [])
    if 'nextUri' not in r: print(rows[0][0] if rows else 'no rows'); break
    assert r['nextUri'].startswith('https://gateway:8443/'), r['nextUri']
    r = httpx.get(r['nextUri'], **kw).json()" "$1" "$2"
}
check "gateway, carol's own token, as carol: 5 customers" "$(gw_as "$carol_for_trino" '')" "5"
check "gateway, carol's own token, as alice_admin: refused" "$(gw_as "$carol_for_trino" alice_admin)" "Access Denied: User carol_analyst cannot impersonate user alice_admin"
logs=$(docker compose logs mcp)
check "no token in the server log" "$(grep -c 'eyJ' <<<"$logs")" "0"

[ $failed -eq 0 ] && echo "== GATEWAY OK ==" || { echo "== GATEWAY FAILED =="; exit 1; }
