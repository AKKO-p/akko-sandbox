#!/usr/bin/env bash
# The sandbox behind Trino Gateway, end to end, on a machine with Docker:
# the MCP server reaches Trino only through the gateway, which routes queries to
# two clusters. Checks that a second start is healthy, the two different
# answers, that the server cannot reach a backend directly nor use the
# gateway's admin API, that queries spread over both clusters under the user's
# own name, that a capped result and a cancel both go through the gateway, and
# that the gateway changes nothing to the refusals. Removes
# everything at the end unless KEEP=1. Uses the sandbox's host ports (8080,
# 3000, 6274) unless told otherwise, as below.
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
# What the gateway itself answers to the MCP server, which has no admin account.
gw_api() { # method, path: prints the HTTP status
  docker compose exec -T mcp python -c "
import httpx, sys
print(httpx.request(sys.argv[1], 'https://gateway:8443' + sys.argv[2], json={}, verify='/certs/ca.crt').status_code)" "$1" "$2"
}

echo "== 1. Start (project $COMPOSE_PROJECT_NAME, gateway in front of two clusters)"
start=$(date +%s)
if ! docker compose up -d --wait --wait-timeout 480; then
  docker compose ps -a; docker compose logs --tail 40; exit 1
fi
echo "  all services healthy in $(( $(date +%s) - start )) s"
if ! docker compose --profile tools up -d probe >/dev/null 2>&1; then
  echo "  the probe did not start"; docker compose --profile tools logs probe; exit 1
fi
backends() { docker compose exec -T probe curl -fsS --cacert /certs/ca.crt https://gateway:8443/api/public/backends; }
backends | sed 's/^/  backends: /'; echo
# docker compose up starts the one-shot services again: certs keeps its files,
# gateway-backends registers the clusters again, and everything stays healthy.
check "a second start is healthy" "$(docker compose up -d --wait --wait-timeout 240 >/dev/null 2>&1 && echo yes)" "yes"
check "the second start kept the certificates" "$(docker compose logs certs | grep -c 'certificates already present')" "1"
check "the second start registered both clusters again" "$(docker compose logs gateway-backends | grep -c 'backends registered')" "2"
check "the gateway still knows two clusters" "$(backends | field 'len(d)')" "2"

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
trino_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"${COMPOSE_PROJECT_NAME}_default\").IPAddress}}" "$(docker compose ps -q trino)")
check "the server cannot reach trino by its address ($trino_ip)" "$(reach "$trino_ip" 8080)" "unreachable"
check "the gateway has no plain http port" "$(reach gateway 8080)" "unreachable"
check "the server cannot read the gateway's admin password" "$(docker compose exec -T mcp cat /certs/gateway-admin.secret >/dev/null 2>&1 && echo yes || echo no)" "no"
check "the server cannot change a backend: 403" "$(gw_api POST /gateway/backend/modify/update)" "403"
check "the server cannot deactivate a backend: 403" "$(gw_api POST /gateway/backend/deactivate/trino)" "403"
check "the server cannot read the query history: 403" "$(gw_api POST /webapp/findQueryHistory)" "403"
# The gateway's own http server refuses forwarded headers from a client, so a
# client cannot claim https on the clusters' behalf, nor pose as another address.
xfp() { # header: prints the HTTP status of a query sent with it
  docker compose exec -T mcp python -c "
import httpx, sys
name, value = sys.argv[2].split(': ', 1)
h = {'Authorization': 'Bearer ' + sys.argv[1], name: value}
print(httpx.post('https://gateway:8443/v1/statement', content='SELECT 1', headers=h, verify='/certs/ca.crt').status_code)" "$1" "$2"
}
carol_for_trino=$(./token.sh carol_analyst trino-cli)
check "a client's X-Forwarded-Proto is refused at the gateway: 406" "$(xfp "$carol_for_trino" 'X-Forwarded-Proto: https')" "406"
check "a client's X-Forwarded-For is refused at the gateway: 406" "$(xfp "$carol_for_trino" 'X-Forwarded-For: 10.0.0.1')" "406"

echo "== 4. Queries spread over both clusters, each under the user's own name"
history "DELETE FROM query_history" >/dev/null   # only this run's queries count
counts=$(for _ in 1 2 3 4 5 6 7 8 9 10; do call carol_analyst execute_query "sql=SELECT count(*) AS customers FROM demo.crm.customers" | field 'd["rows"][0][0]'; done | sort | uniq -c | sed 's/^ *//')
check "the 10 queries each counted 5 customers" "$counts" "10 5"
check "the gateway sent queries to trino" "$(history "SELECT count(*) > 0 FROM query_history WHERE backend_url = 'http://trino:8080'")" "t"
check "the gateway sent queries to trino-2" "$(history "SELECT count(*) > 0 FROM query_history WHERE backend_url = 'http://trino-2:8080'")" "t"
check "every routed query carries a user's own name" "$(history "SELECT count(*) FROM query_history WHERE user_name IS NULL OR user_name NOT IN ('carol_analyst', 'alice_admin', 'dave_viewer')")" "0"
check "carol's queries are recorded as carol_analyst" "$(history "SELECT count(*) >= 10 FROM query_history WHERE user_name = 'carol_analyst'")" "t"
history "SELECT '  ' || backend_url || ': ' || count(*) FROM query_history GROUP BY backend_url ORDER BY 1"
# The gateway's history is what the gateway read; each cluster says whom it
# authenticated: carol_analyst, from her verified token.
queries() { # backend, then Python printing one line per query q
  docker compose exec -T probe curl -fsS "http://$1:8080/v1/query" \
    -H "Authorization: Bearer $carol_for_trino" -H "X-Forwarded-Proto: https" \
    | python3 -c "import sys,json; [print($2) for q in json.load(sys.stdin)]"
}
for b in trino trino-2; do
  check "$b ran carol's count as carol_analyst" "$(queries "$b" "q['session']['user'] + ' ' + q['query']" | grep -c '^carol_analyst .*AS customers')" "$(history "SELECT count(*) FROM query_history WHERE backend_url = 'http://$b:8080' AND query_text LIKE '%AS customers%'")"
done

echo "== 5. A result cut at the server's cap comes back through the gateway"
# Every nextUri the server follows points at the gateway: it resolves no backend.
out=$(call alice_admin execute_query "sql=SELECT x FROM UNNEST(sequence(1, 5000)) AS t(x)")
check "100 rows, cut by the server's cap" "$(field 'len(d["rows"])' <<<"$out")" "100"
check "the answer says it was cut" "$(field 'd["truncated"]' <<<"$out")" "True"

echo "== 6. A query past its time budget is cancelled in Trino, through the gateway"
slow="SELECT count(*) FROM UNNEST(sequence(1, 10000)) a(x) CROSS JOIN UNNEST(sequence(1, 10000)) b(y) CROSS JOIN UNNEST(sequence(1, 10000)) c(z)"
t0=$(date +%s)
out=$(call carol_analyst execute_query "sql=$slow")
took=$(( $(date +%s) - t0 ))
echo "  the server answered in $took s: $out"
check "the server says the time budget ran out" "$(field 'd.get("error", "")' <<<"$out")" "the query exceeded its time budget of 30 s and was cancelled"
check "the server waited its 30 s budget" "$( [ "$took" -ge 30 ] && echo yes)" "yes"
sleep 3
# Cancelled by the client: FAILED with USER_CANCELED, on exactly one cluster.
# A query that failed by itself would carry another error, and one left behind
# without a cancel would still be RUNNING.
all_states=$( { queries trino "q['state'] + ' ' + (q.get('errorCode') or {}).get('name', '-') if 'CROSS JOIN' in q.get('query', '') else ''"
  queries trino-2 "q['state'] + ' ' + (q.get('errorCode') or {}).get('name', '-') if 'CROSS JOIN' in q.get('query', '') else ''"; } | grep -v '^$' | sort | uniq -c | sed 's/^ *//')
echo "  carol's slow query on the clusters: ${all_states:-none}"
check "the slow query was cancelled by the client, once" "$all_states" "1 FAILED USER_CANCELED"

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
logs=$(docker compose logs mcp gateway trino trino-2)
check "no token in the server, gateway and Trino logs" "$(grep -c 'eyJ' <<<"$logs")" "0"
check "no client secret in those logs" "$(grep -c "$(docker compose exec -T mcp cat /certs/mcp-client.secret)" <<<"$logs")" "0"
check "no gateway admin password in those logs" "$(grep -c "$(docker compose exec -T gateway cat /certs/gateway-admin.secret)" <<<"$logs")" "0"

[ $failed -eq 0 ] && echo "== GATEWAY OK ==" || { echo "== GATEWAY FAILED =="; exit 1; }
