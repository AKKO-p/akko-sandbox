#!/usr/bin/env bash
# The read allow-list of akko-mcp-trino 0.7.1 and later, end to end, on a machine with
# Docker. Some reads, such as SHOW STATS or EXPLAIN, can show facts beyond a row filter
# or a column mask. By default the server refuses them, explain_query only checks a statement, and the reads an
# agent needs still work, under the same rules. Once the administrator opens them by
# MCP_EXTRA_READ_COMMANDS, they run, and the server says so at start.
# Removes everything at the end unless KEEP=1. GATEWAY=1 runs the same checks behind
# Trino Gateway, two clusters.
#
#   tests/v071.sh                the sandbox's image, 0.8.0
#   GATEWAY=1 tests/v071.sh
set -uo pipefail
cd "$(dirname "$0")/.."
if [ "${GATEWAY:-0}" = "1" ]; then
  export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-akko-sandbox-v071-gateway}"
  export COMPOSE_FILE=compose.yaml:gateway/compose.gateway.yaml:tests/compose.v071.yaml
else
  export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-akko-sandbox-v071}"
  export COMPOSE_FILE=compose.yaml:tests/compose.v071.yaml
fi
failed=0
check() { if [ "$2" = "$3" ]; then printf '  OK    %s\n' "$1"; else printf '  FAIL  %s (got %s, expected %s)\n' "$1" "$2" "$3"; failed=1; fi; }
cleanup() {
  if [ "${KEEP:-0}" = "1" ]; then echo "KEEP=1: project $COMPOSE_PROJECT_NAME left running"; return; fi
  docker compose --profile tools down -v --remove-orphans >/dev/null 2>&1
  echo "== project $COMPOSE_PROJECT_NAME removed: $(docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" | wc -l) containers left"
}
trap cleanup EXIT
call() { # user, tool, then name=value arguments
  local user=$1 tool=$2; shift 2
  local args=(); for a in "$@"; do args+=(--tool-arg "$a"); done
  docker compose exec -T inspector mcp-inspector --cli http://mcp:3000/mcp \
    --header "Authorization: Bearer $(./token.sh "$user")" --method tools/call \
    --tool-name "$tool" "${args[@]}" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['content'][0]['text'])" 2>/dev/null
}
field() { python3 -c "
import sys, json
try: d = json.load(sys.stdin)
except ValueError: sys.exit(0)
try: print(eval(sys.argv[1], {}, {'d': d}))
except Exception: pass" "$1"; }
run() { call "$1" execute_query "sql=$2"; }

echo "== starting the sandbox (${MCP_IMAGE:-default image}), nothing opened"
MCP_EXTRA_READ_COMMANDS= docker compose up -d --wait >/dev/null 2>&1 || { echo "the sandbox did not start"; exit 1; }

echo "== reads past the access rules are refused"
for sql in "SHOW STATS FOR demo.crm.customers" \
           "SHOW STATS FOR (SELECT * FROM demo.crm.customers)" \
           "EXPLAIN SELECT * FROM demo.crm.customers" \
           "EXPLAIN (TYPE IO) SELECT * FROM demo.crm.customers" \
           "SHOW CREATE TABLE demo.crm.customers" \
           "SHOW GRANTS ON TABLE demo.crm.customers" \
           "SHOW SESSION"; do
  check "carol: $sql" "$(run carol_analyst "$sql" | field 'd.get("kind")')" "read_only"
done
check "alice too: SHOW STATS" "$(run alice_admin "SHOW STATS FOR demo.crm.customers" | field 'd.get("kind")')" "read_only"

echo "== explain_query checks without a plan"
ok=$(call carol_analyst explain_query "sql=SELECT country, count(*) FROM demo.crm.customers GROUP BY country")
check "a valid read answers valid" "$(field 'd' <<<"$ok")" "{'valid': True}"
check "the answer holds nothing but valid" "$(field 'sorted(d)' <<<"$ok")" "['valid']"
check "an unknown column says its kind" "$(call carol_analyst explain_query "sql=SELECT nope FROM demo.crm.customers" | field 'd.get("kind")')" "column"
# The policy hides the table from dave: Trino answers that it does not exist.
check "dave cannot check a table he may not read" "$(call dave_viewer explain_query "sql=SELECT * FROM demo.crm.customers" | field 'd.get("kind")')" "table"

echo "== what an agent needs still works, under the same rules"
check "SHOW TABLES" "$(run carol_analyst "SHOW TABLES FROM demo.crm" | field '"customers" in str(d["rows"])')" "True"
check "SHOW COLUMNS" "$(run carol_analyst "SHOW COLUMNS FROM demo.crm.customers" | field 'd["row_count"] > 0')" "True"
check "DESCRIBE" "$(run carol_analyst "DESCRIBE demo.crm.customers" | field 'd["row_count"] > 0')" "True"
check "carol's e-mails stay masked" "$(run carol_analyst "SELECT DISTINCT substr(email, 1, 3) FROM demo.crm.customers" | field 'd["rows"]')" "[['***']]"
check "carol sees European customers only" "$(run carol_analyst "SELECT count(*) FROM demo.crm.customers WHERE country NOT IN ('DE','ES','FR','IT','NL')" | field 'd["rows"][0][0]')" "0"

echo "== once opened by the administrator, they run and the server says so"
MCP_EXTRA_READ_COMMANDS="SHOW STATS, EXPLAIN" docker compose up -d --wait --force-recreate mcp >/dev/null 2>&1 || { echo "the server did not restart"; exit 1; }
check "SHOW STATS runs" "$(run carol_analyst "SHOW STATS FOR demo.crm.customers" | field '"row_count" in d')" "True"
check "explain_query prints the plan" "$(call carol_analyst explain_query "sql=SELECT * FROM demo.crm.customers" | field '"plan" in d')" "True"
check "SHOW CREATE stays refused" "$(run carol_analyst "SHOW CREATE TABLE demo.crm.customers" | field 'd.get("kind")')" "read_only"
check "the start says what is opened" "$(docker compose logs --no-color mcp 2>&1 | grep -c "MCP_EXTRA_READ_COMMANDS=EXPLAIN, SHOW STATS")" "1"

echo "== an unknown name refuses to start"
check "--check refuses SHOW STAT (exit 2)" "$(docker compose exec -T -e MCP_EXTRA_READ_COMMANDS="SHOW STAT" mcp akko-mcp-trino --check >/dev/null 2>&1; echo $?)" "2"

[ "$failed" = 0 ] && echo "== ALL OK" || echo "== SOME CHECKS FAILED"
exit "$failed"
