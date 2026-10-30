#!/usr/bin/env bash
# The tools of akko-mcp-trino 0.7, end to end, on a machine with Docker:
# search_columns finds a column by its comment, a viewer sees nothing of a table
# or a column the policy hides (not in a match, a page, a description nor an
# error), the listings and describe_schema page with nothing lost nor repeated,
# a search with a short budget says what it did not search and resumes to the
# end, errors say their kind, a policy that refuses system.jdbc gets an error
# that says what to allow, the agent's SQL never reads system, and the server
# logs no token. Records the plans of describe_schema's metadata statements.
# Removes everything at the end unless KEEP=1. GATEWAY=1 runs the same checks
# behind Trino Gateway. Uses the sandbox's host ports unless told otherwise.
#
#   MCP_IMAGE=<0.7 image> tests/v07.sh
#   GATEWAY=1 MCP_IMAGE=<0.7 image> tests/v07.sh
#   COMPOSE_PROJECT_NAME=akko-v07 KEYCLOAK_PORT=18480 MCP_PORT=13000 INSPECTOR_PORT=16274 tests/v07.sh
set -uo pipefail
cd "$(dirname "$0")/.."
if [ "${GATEWAY:-0}" = "1" ]; then
  export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-akko-sandbox-v07-gateway}"
  export COMPOSE_FILE=compose.yaml:gateway/compose.gateway.yaml:tests/compose.v07.yaml
  clusters="trino trino-2"
else
  export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-akko-sandbox-v07}"
  export COMPOSE_FILE=compose.yaml:tests/compose.v07.yaml
  clusters="trino"
fi
failed=0
check() { if [ "$2" = "$3" ]; then printf '  OK    %s\n' "$1"; else printf '  FAIL  %s (got %s, expected %s)\n' "$1" "$2" "$3"; failed=1; fi; }
cleanup() {
  if [ "${KEEP:-0}" = "1" ]; then echo "KEEP=1: project $COMPOSE_PROJECT_NAME left running"; return; fi
  docker compose --profile tools down -v --remove-orphans >/dev/null 2>&1; rm -f .v07-dave
  echo "== project $COMPOSE_PROJECT_NAME removed: $(docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" | wc -l) containers, $(docker volume ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" | wc -l) volumes left"
}
trap cleanup EXIT

# An MCP tool call through the Inspector CLI, as $1, printing the tool's JSON.
call() { # user, tool, then name=value arguments
  local user=$1 tool=$2; shift 2
  local args=(); for a in "$@"; do args+=(--tool-arg "$a"); done
  docker compose exec -T inspector mcp-inspector --cli http://mcp:3000/mcp \
    --header "Authorization: Bearer $(./token.sh "$user")" --method tools/call \
    --tool-name "$tool" "${args[@]}" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['content'][0]['text'])" 2>/dev/null
}
# A Python expression on the JSON read from stdin, as d; prints nothing on bad JSON.
field() { python3 -c "
import sys, json
try: d = json.load(sys.stdin)
except ValueError: sys.exit(0)
try: print(eval(sys.argv[1], {}, {'d': d}))
except Exception: pass" "$1"; }
# Straight to Trino (or to the gateway, which the server is told of), from the MCP
# server's container, with a user's own token for Trino: prints
# {"columns", "rows"} or {"error": Trino's error name}.
trino() { # user, sql
  docker compose exec -T mcp python -c "
import httpx, json, os, sys
base = 'https://%s:%s' % (os.environ['TRINO_HOST'], os.environ['TRINO_PORT'])
kw = dict(headers={'Authorization': 'Bearer ' + sys.argv[1]}, verify='/certs/ca.crt', timeout=60)
r = httpx.post(base + '/v1/statement', content=sys.argv[2], **kw).json()
cols, rows = None, []
while True:
    if 'error' in r: print(json.dumps({'error': r['error']['errorName']})); break
    cols = cols or [c['name'] for c in r.get('columns') or []] or None
    rows += r.get('data', [])
    if 'nextUri' not in r: print(json.dumps({'columns': cols, 'rows': rows})); break
    r = httpx.get(r['nextUri'], **kw).json()" "$(./token.sh "$1" trino-cli)" "$2"
}
# Every page of a listing tool, as $1: prints one JSON line per page.
walk() { # user, tool, then name=value arguments
  local user=$1 tool=$2 offset=0 page n=0; shift 2
  while [ -n "$offset" ] && [ "$offset" != "None" ] && [ $n -lt 20 ]; do
    page=$(call "$user" "$tool" "$@" "offset=$offset"); echo "$page"
    offset=$(field 'd["next_offset"]' <<<"$page"); n=$((n + 1))
  done
}
# Every answer of a search, resumed by its cursor, as $1: prints one JSON line per call.
search_all() { # user, then name=value arguments
  local user=$1 cursor="" answer n=0; shift
  while [ $n -lt 40 ]; do
    if [ -n "$cursor" ]; then answer=$(call "$user" search_columns "$@" "cursor=$cursor"); else answer=$(call "$user" search_columns "$@"); fi
    echo "$answer"; n=$((n + 1))
    cursor=$(field 'd["next_cursor"] or ""' <<<"$answer")
    [ -n "$cursor" ] || break
  done
}
# A Python expression on the JSON lines read from stdin, as pages.
pages() { python3 -c "
import sys, json
pages = []
for line in sys.stdin:
    try: pages.append(json.loads(line))
    except ValueError: pages.append({})
try: print(eval(sys.argv[1], {}, {'pages': pages}))
except Exception as e: print('error:', type(e).__name__)" "$1"; }
names() { field 'sorted({m["table"] for m in d["matches"]})'; }
opa() { # method, policy id, then curl options: OPA's policy API
  local method=$1 id=$2; shift 2
  docker compose exec -T opa-admin curl -fsS -o /dev/null -w '%{http_code}' -X "$method" "http://opa:8181/v1/policies/$id" "$@"
}

echo "== 1. Start (project $COMPOSE_PROJECT_NAME, clusters: $clusters)"
start=$(date +%s)
if ! docker compose up -d --wait --wait-timeout 480; then
  docker compose ps -a; docker compose logs --tail 40; exit 1
fi
echo "  all services healthy in $(( $(date +%s) - start )) s"
docker compose --profile tools up -d opa-admin >/dev/null 2>&1 || { echo "  opa-admin did not start"; exit 1; }
echo "  server: $(docker compose exec -T mcp akko-mcp-trino --version 2>&1 | tail -1)"
archive=$(python3 -c "print([f'transactions_{y}' for y in range(2014, 2026)])")

echo "== 2. A column found by a word of its comment"
out=$(call carol_analyst search_columns text=revenue catalog=demo)
check "carol, 'revenue' in demo: transactions.amount" "$(field '[(m["schema"], m["table"], m["column"]) for m in d["matches"]]' <<<"$out")" "[('crm', 'transactions', 'amount')]"
check "carol: the match carries its comment" "$(field 'd["matches"][0]["comment"]' <<<"$out")" "Booked amount in the account currency: the revenue of a sale"
check "carol: the search of demo is complete" "$(field '(d["complete"], d["not_searched"], d["next_cursor"])' <<<"$out")" "(True, [], None)"
everywhere=$(call carol_analyst search_columns text=revenue)
check "carol, 'revenue' in every catalog: the same match, complete" "$(field '([(m["catalog"], m["table"], m["column"]) for m in d["matches"]], d["complete"])' <<<"$everywhere")" "([('demo', 'transactions', 'amount')], True)"
schemas_all=$(field 'd["schemas_searched"]' <<<"$everywhere")
echo "  schemas searched in every catalog: $schemas_all"
amount=$(search_all carol_analyst text=amount catalog=demo)
check "carol, 'amount' in demo: 13 columns, over the row cap, resumed to the end" "$(pages '(len({(m["schema"], m["table"], m["column"]) for p in pages for m in p["matches"]}), sum(len(p["matches"]) for p in pages), pages[-1]["complete"])' <<<"$amount")" "(13, 13, True)"
check "  the first answer stopped at the row cap" "$(pages '[g["reason"] for g in pages[0]["not_searched"]][:1]' <<<"$amount")" "['row_cap']"

echo "== 3. dave_viewer sees nothing of crm.customers, nor of accounts.balance"
# What dave gets, kept for the checks at the end of this section; never what he
# asks by name himself (a refused SELECT balance, the tpcds catalog), which Trino
# may repeat in its error.
: > .v07-dave
d() { call dave_viewer "$@" | tee -a .v07-dave; }
out=$(d search_columns text=full_name catalog=demo)
check "dave, 'full_name': no match, complete" "$(field '(d["matches"], d["complete"])' <<<"$out")" "([], True)"
check "dave, 'customer' in demo: accounts only" "$(d search_columns text=customer catalog=demo | names)" "['accounts']"
check "carol, 'customer' in demo: accounts and customers" "$(call carol_analyst search_columns text=customer catalog=demo | names)" "['accounts', 'customers']"
out=$(d search_columns text=email)
check "dave, 'email' in every catalog: no match, complete, nothing left" "$(field '(d["matches"], d["complete"], d["not_searched"])' <<<"$out")" "([], True, [])"
check "dave's catalogs: tpcds is not one" "$(d list_catalogs | field 'd["catalogs"]')" "['demo', 'tpch']"
check "carol's catalogs: tpcds too" "$(call carol_analyst list_catalogs | field 'd["catalogs"]')" "['demo', 'tpcds', 'tpch']"
check "carol, 'email' in every catalog: tpcds searched" "$(call carol_analyst search_columns text=email | field '"tpcds" in {m["catalog"] for m in d["matches"]}')" "True"
out=$(d describe_schema catalog=demo schema=crm)
check "dave, describe_schema crm: accounts and transactions" "$(field '[t["table"] for t in d["tables"]]' <<<"$out")" "['accounts', 'transactions']"
check "dave, describe_schema crm: accounts without balance" "$(field '[c["column"] for t in d["tables"] if t["table"] == "accounts" for c in t["columns"]]' <<<"$out")" "['id', 'customer_id', 'opened_on', 'currency']"
out=$(walk carol_analyst describe_schema catalog=demo schema=crm)
check "carol, describe_schema crm by pages: three tables, balance with its comment" "$(pages '([t["table"] for p in pages for t in p["tables"]], [c["comment"] for p in pages for t in p["tables"] for c in t["columns"] if c["column"] == "balance"])' <<<"$out")" "(['accounts', 'customers', 'transactions'], ['Current balance in the account currency'])"
out=$(walk dave_viewer list_tables catalog=demo schema=crm | tee -a .v07-dave)
check "dave, list_tables crm by pages: accounts and transactions" "$(pages '[t for p in pages for t in p["tables"]]' <<<"$out")" "['accounts', 'transactions']"
check "dave, 'balance' in demo: no match" "$(d search_columns text=balance catalog=demo | field 'd["matches"]')" "[]"
check "carol, 'balance' in demo: accounts.balance" "$(call carol_analyst search_columns text=balance catalog=demo | field '[(m["table"], m["column"]) for m in d["matches"]]')" "[('accounts', 'balance')]"
out=$(d describe_table catalog=demo schema=crm table=accounts)
check "dave, describe_table accounts: four columns, none cut" "$(field '([r[0] for r in d["rows"]], d["truncated"])' <<<"$out")" "(['id', 'customer_id', 'opened_on', 'currency'], False)"
check "alice, describe_table accounts: five, balance too" "$(call alice_admin describe_table catalog=demo schema=crm table=accounts | field '[r[0] for r in d["rows"]]')" "['id', 'customer_id', 'opened_on', 'currency', 'balance']"
check "dave, SELECT balance: refused by the policy" "$(call dave_viewer execute_query 'sql=SELECT balance FROM demo.crm.accounts' | field 'd["kind"]')" "permission"
check "dave, SELECT count(*) of accounts: 12" "$(d execute_query 'sql=SELECT count(*) FROM demo.crm.accounts' | field 'd["rows"]')" "[[12]]"
check "dave, an unknown column of accounts: kind column" "$(d execute_query 'sql=SELECT nope FROM demo.crm.accounts' | field 'd["kind"]')" "column"
check "dave, describe_schema of a schema that does not exist: kind schema" "$(d describe_schema catalog=demo schema=nosuch | field 'd["kind"]')" "schema"
check "dave, describe_schema of tpcds, which he names: kind permission" "$(call dave_viewer describe_schema catalog=tpcds schema=tiny | field 'd["kind"]')" "permission"
for word in customers full_name segment email 'People and companies' balance 'Current balance' tpcds; do
  check "nothing dave got names '$word'" "$(grep -ci -- "$word" .v07-dave)" "0"
done
check "every answer dave got is JSON ($(grep -c . .v07-dave) answers)" "$(grep -c . .v07-dave)" "$(grep -c '^{' .v07-dave)"
rm -f .v07-dave
echo "  dave, SELECT * of accounts, Trino's message: $(call dave_viewer execute_query 'sql=SELECT * FROM demo.crm.accounts' | field 'd["error"]')"
# The same column, straight in Trino, with dave's own token: the policy filters
# every listing and refuses the read; alice sees it everywhere.
for who in dave_viewer alice_admin; do
  [ $who = dave_viewer ] && want="['id', 'customer_id', 'opened_on', 'currency']" || want="['id', 'customer_id', 'opened_on', 'currency', 'balance']"
  check "$who in Trino, information_schema.columns" "$(trino $who "SELECT column_name FROM demo.information_schema.columns WHERE table_schema = 'crm' AND table_name = 'accounts' ORDER BY ordinal_position" | field '[r[0] for r in d["rows"]]')" "$want"
  check "$who in Trino, system.jdbc.columns" "$(trino $who "SELECT column_name FROM system.jdbc.columns WHERE table_cat = 'demo' AND table_schem = 'crm' AND table_name = 'accounts' ORDER BY ordinal_position" | field '[r[0] for r in d["rows"]]')" "$want"
  check "$who in Trino, SHOW COLUMNS" "$(trino $who "SHOW COLUMNS FROM demo.crm.accounts" | field '[r[0] for r in d["rows"]]')" "$want"
  check "$who in Trino, DESCRIBE" "$(trino $who "DESCRIBE demo.crm.accounts" | field '[r[0] for r in d["rows"]]')" "$want"
done
check "dave in Trino, SELECT balance: PERMISSION_DENIED" "$(trino dave_viewer "SELECT balance FROM demo.crm.accounts" | field 'd["error"]')" "PERMISSION_DENIED"
check "dave in Trino, SELECT *: PERMISSION_DENIED" "$(trino dave_viewer "SELECT * FROM demo.crm.accounts" | field 'd["error"]')" "PERMISSION_DENIED"

echo "== 4. list_tables on crm_archive, page by page"
out=$(walk carol_analyst list_tables catalog=demo schema=crm_archive)
check "three pages of five at most" "$(pages '[len(p["tables"]) for p in pages]' <<<"$out")" "[5, 5, 2]"
check "every table once, in order" "$(pages '[t for p in pages for t in p["tables"]]' <<<"$out")" "$archive"
check "truncated exactly when next_offset is set" "$(pages '[(p["truncated"], p["next_offset"]) for p in pages]' <<<"$out")" "[(True, 5), (True, 10), (False, None)]"

echo "== 5. describe_schema on crm_archive, page by page"
out=$(walk carol_analyst describe_schema catalog=demo schema=crm_archive)
check "four pages of three whole tables" "$(pages '[(len(p["tables"]), p["shortened"], p["next_offset"]) for p in pages]' <<<"$out")" "[(3, True, 3), (3, True, 6), (3, True, 9), (3, False, None)]"
check "every table once, in order" "$(pages '[t["table"] for p in pages for t in p["tables"]]' <<<"$out")" "$archive"
check "every table whole: its three columns" "$(pages '{tuple(c["column"] for c in t["columns"]) for p in pages for t in p["tables"]}' <<<"$out")" "{('id', 'booked_at', 'amount')}"
check "every table with its comment" "$(pages 'all(t["comment"] == "Transactions booked in %s, archived" % t["table"][-4:] for p in pages for t in p["tables"])' <<<"$out")" "True"
check "a page of an offset past the end: empty, the last" "$(call carol_analyst describe_schema catalog=demo schema=crm_archive offset=40 | field '(d["tables"], d["next_offset"])')" "([], None)"

echo "== 6. A search within a short budget says what it left, and resumes to the end"
budget="${V07_SHORT_BUDGET:-3}" reserve="${V07_SHORT_RESERVE:-2}"
if ! V07_CALL_TIMEOUT_SECONDS=$budget V07_SEARCH_RESERVE_SECONDS=$reserve docker compose up -d --no-deps --wait --wait-timeout 120 mcp >/dev/null 2>&1; then
  echo "  the server did not start with a $budget s budget"; failed=1
fi
echo "  call budget $budget s, reserve $reserve s"
out=$(search_all carol_analyst text=revenue)
pages '"\n".join("  call %d: %d schemas, complete %s, not searched: %s" % (i + 1, p["schemas_searched"], p["complete"], ", ".join("%s.%s (%s)" % (g["catalog"], g["schema"] or "*", g["reason"]) for g in p["not_searched"])) for i, p in enumerate(pages))' <<<"$out"
check "the first answer is not complete" "$(pages 'pages[0]["complete"]' <<<"$out")" "False"
check "  it names what it left, for lack of time" "$(pages 'bool(pages[0]["not_searched"]) and {g["reason"] for g in pages[0]["not_searched"]} == {"time_budget"}' <<<"$out")" "True"
check "  the last catalog, tpch, is among them" "$(pages '"tpch" in {g["catalog"] for g in pages[0]["not_searched"]}' <<<"$out")" "True"
check "  and it gives a cursor" "$(pages 'pages[0]["next_cursor"] is not None' <<<"$out")" "True"
check "resumed by its cursor, the search ends complete" "$(pages '(len(pages) > 1, pages[-1]["complete"], pages[-1]["next_cursor"])' <<<"$out")" "(True, True, None)"
check "  every schema searched once over the calls" "$(pages 'sum(p["schemas_searched"] for p in pages)' <<<"$out")" "$schemas_all"
check "  the same match as with the whole budget" "$(pages '[(m["catalog"], m["table"], m["column"]) for p in pages for m in p["matches"]]' <<<"$out")" "[('demo', 'transactions', 'amount')]"
docker compose up -d --no-deps --wait --wait-timeout 120 mcp >/dev/null 2>&1 || { echo "  the server did not start again"; failed=1; }

echo "== 7. Errors say their kind"
out=$(call carol_analyst execute_query 'sql=SELECT revenue FROM demo.crm.transactions')
check "an unknown column: kind column, identifier revenue" "$(field '(d["kind"], d.get("identifier"))' <<<"$out")" "('column', 'revenue')"
check "  error keeps Trino's message" "$(field '"revenue" in d["error"]' <<<"$out")" "True"
check "dave, a refused table: kind permission" "$(call dave_viewer execute_query 'sql=SELECT count(*) FROM demo.crm.customers' | field 'd["kind"]')" "permission"
check "a text too short: kind invalid_argument" "$(call carol_analyst search_columns text=ab | field 'd["kind"]')" "invalid_argument"
check "an offset below 0: kind invalid_argument" "$(call carol_analyst list_tables catalog=demo schema=crm offset=-1 | field 'd["kind"]')" "invalid_argument"

echo "== 8. A policy that refuses system.jdbc: the error says what to allow"
check "the variant of the policy is loaded" "$(opa PUT v07-no-jdbc -H 'Content-Type: text/plain' --data-binary 'package trino

forbidden if {
	input.action.resource.table.catalogName == "system"
	input.action.resource.table.schemaName == "jdbc"
}')" "200"
for args in "describe_schema catalog=demo schema=crm" "search_columns text=revenue catalog=demo"; do
  # shellcheck disable=SC2086
  out=$(call carol_analyst $args)
  check "${args%% *}: an error that names system.jdbc.columns and asks to allow it" "$(field '"system.jdbc.columns" in d["error"] and "the access control must allow reading them" in d["error"]' <<<"$out")" "True"
  check "  of kind permission or table" "$(field 'd["kind"] in ("permission", "table")' <<<"$out")" "True"
  check "  and no other answer" "$(field 'sorted(set(d) - {"error", "kind", "identifier"})' <<<"$out")" "[]"
done
check "the variant is removed" "$(opa DELETE v07-no-jdbc)" "200"
check "describe_schema answers again" "$(call carol_analyst describe_schema catalog=demo schema=crm | field '[t["table"] for t in d["tables"]]')" "['accounts', 'customers']"

echo "== 9. The agent's SQL never reads system"
for sql in "SELECT * FROM system.runtime.queries" "SELECT * FROM system.jdbc.columns" "SHOW TABLES FROM system.jdbc"; do
  out=$(call dave_viewer execute_query "sql=$sql")
  check "refused before Trino: $sql" "$(field '("rows" in d, d.get("kind"))' <<<"$out")" "(False, 'read_only')"
done

echo "== 10. The plans of describe_schema's metadata statements on crm_archive"
# The filter of a page's statements, as the server builds it (table_name IN (...)), and
# the same with one table (table_name = ...), run as alice straight in Trino:
# the plan, then how many rows the scan reads, crm_archive holding 12 tables of
# 3 columns. Recorded, not checked.
in_list=$(python3 -c "print(', '.join(\"'transactions_%d'\" % y for y in range(2014, 2018)))")
for view in "jdbc.columns WHERE table_cat = 'demo' AND table_schem" "metadata.table_comments WHERE catalog_name = 'demo' AND schema_name"; do
  for tables in "IN ($in_list)" "= 'transactions_2014'"; do
    sql="SELECT * FROM system.$view = 'crm_archive' AND table_name $tables"
    echo "  $sql"
    trino alice_admin "EXPLAIN $sql" | field 'd["rows"][0][0]' | grep -E 'ScanFilter|TableScan' | sed 's/^ */    plan: /'
    trino alice_admin "EXPLAIN ANALYZE $sql" | field 'd["rows"][0][0]' | grep -E '^ +Input: .*Filtered' | sed 's/^ */    scan: /'
  done
done

echo "== 11. Trino stopped: kind unavailable"
# shellcheck disable=SC2086
docker compose stop $clusters >/dev/null 2>&1
check "execute_query: kind unavailable" "$(call carol_analyst execute_query 'sql=SELECT 1' | field 'd["kind"]')" "unavailable"
check "describe_schema: kind unavailable" "$(call carol_analyst describe_schema catalog=demo schema=crm | field 'd["kind"]')" "unavailable"

echo "== 12. No token in the logs"
logs=$(docker compose logs mcp)
check "no token in the server log" "$(grep -c 'eyJ' <<<"$logs")" "0"
check "no client secret in the server log" "$(grep -c "$(docker compose exec -T mcp cat /certs/mcp-client.secret)" <<<"$logs")" "0"

[ $failed -eq 0 ] && echo "== V07 OK ==" || { echo "== V07 FAILED =="; exit 1; }
