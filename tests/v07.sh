#!/usr/bin/env bash
# The tools of akko-mcp-trino 0.7, end to end, on a machine with Docker:
# search_columns finds a column by its comment, a viewer sees nothing of a table
# or a column the policy hides (not in a match, a page, a description nor an
# error), the listings and describe_schema page with nothing lost nor repeated,
# a search with a short budget says what it did not search and resumes to the
# end, errors say their kind, a policy that refuses system.jdbc gets an error
# that says what to allow, the agent's SQL never reads system, and the server
# logs no token. Checks that describe_schema's metadata statements read only
# the page's tables.
# Removes everything at the end unless KEEP=1. GATEWAY=1 runs the same checks
# behind Trino Gateway. Uses the sandbox's host ports unless told otherwise.
#
#   tests/v07.sh                 the sandbox's image, 0.8.0
#   GATEWAY=1 tests/v07.sh
#   MCP_IMAGE=<image> tests/v07.sh     another build of the server
#   COMPOSE_PROJECT_NAME=akko-v07 KEYCLOAK_PORT=18480 MCP_PORT=13000 INSPECTOR_PORT=16274 tests/v07.sh
set -uo pipefail
cd "$(dirname "$0")/.."
if [ "${GATEWAY:-0}" = "1" ]; then
  export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-akko-sandbox-v07-gateway}"
  export COMPOSE_FILE=compose.yaml:gateway/compose.gateway.yaml:tests/compose.v07.yaml:tests/compose.v07.gateway.yaml
  clusters="trino trino-2"
else
  export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-akko-sandbox-v07}"
  export COMPOSE_FILE=compose.yaml:tests/compose.v07.yaml
  clusters="trino"
fi
failed=0
# Scratch files: dave's answers, the calls made, the server's logs. Removed at the end.
scratch=$(mktemp -d)
check() { if [ "$2" = "$3" ]; then printf '  OK    %s\n' "$1"; else printf '  FAIL  %s (got %s, expected %s)\n' "$1" "$2" "$3"; failed=1; fi; }
cleanup() {
  rm -rf "$scratch"
  if [ "${KEEP:-0}" = "1" ]; then echo "KEEP=1: project $COMPOSE_PROJECT_NAME left running"; return; fi
  docker compose --profile tools down -v --remove-orphans >/dev/null 2>&1
  echo "== project $COMPOSE_PROJECT_NAME removed: $(docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" | wc -l) containers, $(docker volume ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" | wc -l) volumes left"
}
trap cleanup EXIT

# An MCP tool call through the Inspector CLI, as $1, printing the tool's JSON.
call() { # user, tool, then name=value arguments
  local user=$1 tool=$2; shift 2
  local args=(); for a in "$@"; do args+=(--tool-arg "$a"); done
  echo "$user $tool" >> "$scratch/calls"
  docker compose exec -T inspector mcp-inspector --cli http://mcp:3000/mcp \
    --header "Authorization: Bearer $(./token.sh "$user")" --method tools/call \
    --tool-name "$tool" "${args[@]}" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['content'][0]['text'])" 2>/dev/null
}
# A Python expression on the JSON read from stdin, as d; prints nothing on bad JSON.
field() { python3 -c "
import os, sys, json
try: d = json.load(sys.stdin)
except ValueError: sys.exit(0)
try: print(eval(sys.argv[1], {'os': os}, {'d': d}))
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
# The most words a search takes, as the server itself says in --check.
search_words_limit() { docker compose exec -T mcp akko-mcp-trino --check 2>&1 | sed -n 's/.* \([0-9][0-9]*\) words at most.*/\1/p' | head -1; }
names() { field 'sorted({m["table"] for m in d["matches"]})'; }
# The server's log so far, kept before its container is created again.
keep_logs() { docker compose logs --no-color mcp >> "$scratch/mcp.log" 2>&1; }
# How many queries the engine received whose text holds $1: the gateway's
# history behind the gateway, Trino's own list of queries otherwise.
received() {
  local q="'"; set -- "${1//$q/$q$q}"   # a literal in the statement below
  if [ "${GATEWAY:-0}" = "1" ]; then
    docker compose exec -T gateway-db psql -U gateway -d gateway -tAc "SELECT count(*) FROM query_history WHERE query_text LIKE '%$1%'"
  else
    trino alice_admin "SELECT count(*) FROM system.runtime.queries WHERE user <> 'alice_admin' AND query LIKE '%$1%'" | field 'd["rows"][0][0]'
  fi
}
opa() { # method, policy id, then curl options: OPA's policy API
  local method=$1 id=$2; shift 2
  docker compose exec -T opa-admin curl -fsS -o /dev/null -w '%{http_code}' -X "$method" "http://opa:8181/v1/policies/$id" "$@"
}

echo "== 1. Start (project $COMPOSE_PROJECT_NAME, clusters: $clusters)"
# The checks' catalog folder holds the sandbox's demo catalog as it is.
if ! diff <(grep -v '^#' trino/etc/catalog/demo.properties) <(grep -v '^#' tests/v07/catalog/demo.properties) >/dev/null; then
  echo "  tests/v07/catalog/demo.properties differs from trino/etc/catalog/demo.properties"; exit 1
fi
start=$(date +%s)
if ! docker compose up -d --wait --wait-timeout 480; then
  docker compose ps -a; docker compose logs --tail 40; exit 1
fi
echo "  all services healthy in $(( $(date +%s) - start )) s"
docker compose --profile tools up -d opa-admin >/dev/null 2>&1 || { echo "  opa-admin did not start"; exit 1; }
echo "  server: $(docker compose exec -T mcp akko-mcp-trino --version 2>&1 | tail -1)"
archive=$(python3 -c "print([f'transactions_{y}' for y in range(2014, 2026)])")
# How many schemas each catalog holds, from Trino itself, as alice: what a
# search of every catalog must have searched.
declare -A schemas
for c in demo tpch tpcds; do
  schemas[$c]=$(trino alice_admin "SELECT count(*) FROM $c.information_schema.schemata WHERE schema_name <> 'information_schema'" | field 'd["rows"][0][0]')
done
echo "  schemas: demo ${schemas[demo]}, tpch ${schemas[tpch]}, tpcds ${schemas[tpcds]}"

echo "== 2. A column found by a word of its comment"
out=$(call carol_analyst search_columns text=revenue catalog=demo)
check "carol, 'revenue' in demo: transactions.amount" "$(field '[(m["schema"], m["table"], m["column"]) for m in d["matches"]]' <<<"$out")" "[('crm', 'transactions', 'amount')]"
check "carol: the match carries its comment" "$(field 'd["matches"][0]["comment"]' <<<"$out")" "Booked amount in the account currency: the revenue of a sale"
check "carol: the search of demo is complete" "$(field '(d["complete"], d["not_searched"], d["next_cursor"])' <<<"$out")" "(True, [], None)"
everywhere=$(call carol_analyst search_columns text=revenue)
check "carol, 'revenue' in every catalog: the same match, complete" "$(field '([(m["catalog"], m["table"], m["column"]) for m in d["matches"]], d["complete"])' <<<"$everywhere")" "([('demo', 'transactions', 'amount')], True)"
schemas_all=$(( schemas[demo] + schemas[tpch] + schemas[tpcds] ))
check "  every schema of demo, tpch and tpcds searched" "$(field 'd["schemas_searched"]' <<<"$everywhere")" "$schemas_all"
amount=$(search_all carol_analyst text=amount catalog=demo)
check "carol, 'amount' in demo: 13 columns, over the row cap, resumed to the end" "$(pages '(len({(m["schema"], m["table"], m["column"]) for p in pages for m in p["matches"]}), sum(len(p["matches"]) for p in pages), pages[-1]["complete"])' <<<"$amount")" "(13, 13, True)"
check "  the first answer stopped at the row cap" "$(pages '[g["reason"] for g in pages[0]["not_searched"]][:1]' <<<"$amount")" "['row_cap']"

echo "== 3. dave_viewer sees nothing of crm.customers, nor of accounts.balance"
# What dave gets, kept for the checks at the end of this section; never what he
# asks by name himself (a refused SELECT balance, the tpcds catalog), which Trino
# repeats in its error. Each of his answers has its twin for carol or alice.
# Each call is counted in dave_calls, each page of a tee'd walk or search in dave_pages
# (dave_count adds them), so that the count of his answers is derived, never written.
d() { echo >> "$scratch/dave_calls"; call dave_viewer "$@" | tee -a "$scratch/dave"; }
dave_pages() { grep -c . <<<"$1" >> "$scratch/dave_pages"; }
dave_count() { cat "$scratch/dave_calls" "$scratch/dave_pages" 2>/dev/null | awk '/^$/ {n++; next} {n += $1} END {print n + 0}'; }
match() { field '[(m["table"], m["column"]) for m in d["matches"]]'; }
for word in full_name email segment; do
  check "dave, '$word' in demo: no match, complete" "$(d search_columns text=$word catalog=demo | field '(d["matches"], d["complete"])')" "([], True)"
  check "carol, '$word' in demo: customers.$word" "$(call carol_analyst search_columns text=$word catalog=demo | match)" "[('customers', '$word')]"
done
check "carol: segment comes with its comment" "$(call carol_analyst search_columns text=segment catalog=demo | field 'd["matches"][0]["comment"]')" "Retail or business customer"
check "dave, 'customer' in demo: accounts only" "$(d search_columns text=customer catalog=demo | names)" "['accounts']"
# A table found by its own name or comment is in `tables`, with no list of its columns;
# its columns come in `matches` only for a word of their own name or comment.
customer=$(search_all carol_analyst text=customer catalog=demo)
check "carol, 'customer' in demo: tables accounts and customers, across the cursor" "$(pages 'sorted({t["table"] for p in pages for t in p["tables"]})' <<<"$customer")" "['accounts', 'customers']"
check "  the columns listed hold the word in their own name or comment: accounts.customer_id, customers.segment" "$(pages 'sorted({(m["table"], m["column"]) for p in pages for m in p["matches"]})' <<<"$customer")" "[('accounts', 'customer_id'), ('customers', 'segment')]"
check "  the search is complete, with no hint: something was found" "$(pages '(pages[-1]["complete"], any("hint" in p for p in pages))' <<<"$customer")" "(True, False)"
check "dave, 'customer' in demo: the table accounts only, customers is not his" "$(d search_columns text=customer catalog=demo | field 'sorted(t["table"] for t in d["tables"])')" "['accounts']"
# A catalog he may not see and one he may, in the same search: the one he may
# is searched, every schema of it; the other appears nowhere.
out=$(d search_columns text=email)
check "dave, 'email' in every catalog: no match, complete, nothing left" "$(field '(d["matches"], d["complete"], d["not_searched"])' <<<"$out")" "([], True, [])"
check "  every schema of demo and tpch searched" "$(field 'd["schemas_searched"]' <<<"$out")" "$(( schemas[demo] + schemas[tpch] ))"
out=$(search_all dave_viewer text=mktsegment | tee -a "$scratch/dave"); dave_pages "$out"
check "dave, 'mktsegment' in every catalog: tpch.customer in each tpch schema" "$(pages '(sorted({(m["catalog"], m["table"], m["column"]) for p in pages for m in p["matches"]}), sum(len(p["matches"]) for p in pages), pages[-1]["complete"])' <<<"$out")" "([('tpch', 'customer', 'mktsegment')], ${schemas[tpch]}, True)"
check "dave, 'mktsegment': the table tpch.customer in tables too" "$(pages 'sorted({(t["catalog"], t["table"]) for p in pages for t in p["tables"]})' <<<"$out")" "[('tpch', 'customer')]"
check "  every schema of demo and tpch searched once" "$(pages 'sum(p["schemas_searched"] for p in pages)' <<<"$out")" "$(( schemas[demo] + schemas[tpch] ))"
check "dave's catalogs: tpcds is not one" "$(d list_catalogs | field 'd["catalogs"]')" "['demo', 'tpch']"
check "carol's catalogs: tpcds too" "$(call carol_analyst list_catalogs | field 'd["catalogs"]')" "['demo', 'tpcds', 'tpch']"
check "carol, 'email' in every catalog: demo and tpcds" "$(call carol_analyst search_columns text=email | field 'sorted({m["catalog"] for m in d["matches"]})')" "['demo', 'tpcds']"

echo "== 3b. Search by words: tables, a table's comment, several words, no result, too many words"
# crm.transactions is commented 'Movements booked on the accounts' (postgres/init.sql):
# 'movements' is in that comment and in no column's name or comment.
for who in carol_analyst dave_viewer; do
  if [ $who = dave_viewer ]; then out=$(d search_columns text=movements catalog=demo); else out=$(call $who search_columns text=movements catalog=demo); fi
  check "$who, 'movements': the table transactions, none of its columns" "$(field '([(t["schema"], t["table"], t["comment"]) for t in d["tables"]], d["matches"], d["complete"], "hint" in d)' <<<"$out")" "([('crm', 'transactions', 'Movements booked on the accounts')], [], True, False)"
done
# Two words: one in the table's comment, one in a column's name. The column answers,
# and it alone: the other columns of the table hold neither word of their own.
out=$(call carol_analyst search_columns text="movements amount" catalog=demo)
check "carol, 'movements amount': the column transactions.amount, and its table" "$(field '([(m["table"], m["column"]) for m in d["matches"]], [t["table"] for t in d["tables"]], d["complete"])' <<<"$out")" "([('transactions', 'amount')], ['transactions'], True)"
# Nothing matches: a complete empty answer says what to try; one with results does not.
out=$(call carol_analyst search_columns text=zzqxv catalog=demo)
check "carol, a word nothing holds: empty, complete, with a hint" "$(field '(d["matches"], d["tables"], d["complete"], bool(d.get("hint")))' <<<"$out")" "([], [], True, True)"
# A complete search of several words that found nothing goes on to a pass by word: each word
# alone gives its tables and columns, marked partial, with the words that found them.
single=$(call carol_analyst search_columns text=zzqxv catalog=demo)
nohit_hint=$(field 'd["hint"]' <<<"$single")
out=$(call carol_analyst search_columns text="movements zzqxv" catalog=demo)
check "carol, 'movements zzqxv': no table holds both words, so the pass by word: the table transactions, found by 'movements'" "$(field '([(t["table"], t["words"]) for t in d["tables"]], d["matches"], d["partial"], d["complete"])' <<<"$out")" "([('transactions', ['movements'])], [], True, True)"
check "  its hint is not the one of a search that found nothing" "$(NOHIT="$nohit_hint" field 'bool(d["hint"]) and d["hint"] != os.environ["NOHIT"]' <<<"$out")" "True"
out=$(call carol_analyst search_columns text="zzqxv qqwxj" catalog=demo)
check "carol, two words nothing holds: empty, complete, the hint of a search that found nothing" "$(NOHIT="$nohit_hint" field '(d["matches"], d["tables"], d["complete"], d["hint"] == os.environ["NOHIT"])' <<<"$out")" "([], [], True, True)"
# The question as an agent puts it, values included: the words of names and comments found
# alone, the values (a month, a year) found nothing.
spend=$(search_all carol_analyst text="spending category March 2026" catalog=demo)
check "carol, 'spending category March 2026': transactions.category, found by 'spending' and 'category'" "$(pages '[(m["table"], m["column"], sorted(m["words"])) for p in pages for m in p["matches"]]' <<<"$spend")" "[('transactions', 'category', ['category', 'spending'])]"
check "  partial, complete, the table transactions with it" "$(pages '(all(p["partial"] for p in pages), pages[-1]["complete"], sorted({t["table"] for p in pages for t in p["tables"]}))' <<<"$spend")" "(True, True, ['transactions'])"
check "  'march' and '2026' found nothing: no row names them" "$(pages 'sorted({w.lower() for p in pages for r in p["matches"] + p["tables"] for w in r["words"]} & {"march", "2026"})' <<<"$spend")" "[]"
check "  every schema of demo searched by the pass by word" "$(pages 'sum(p["schemas_searched"] for p in pages)' <<<"$spend")" "${schemas[demo]}"
# What the pass by word shows him: what he sees, no more. 'balance' and 'segment' are in
# columns he does not see (accounts.balance, customers.segment), 'revenue' in one he does.
for word in balance segment; do
  out=$(call carol_analyst search_columns text="revenue $word" catalog=demo)
  check "carol, 'revenue $word': both columns, each by its word" "$(field 'sorted((m["table"], m["column"], m["words"][0]) for m in d["matches"])' <<<"$out")" "$([ $word = balance ] && echo "[('accounts', 'balance', 'balance'), ('transactions', 'amount', 'revenue')]" || echo "[('customers', 'segment', 'segment'), ('transactions', 'amount', 'revenue')]")"
  out=$(d search_columns text="revenue $word" catalog=demo)
  check "dave, 'revenue $word': transactions.amount only, partial" "$(field '(sorted((m["table"], m["column"], m["words"][0]) for m in d["matches"]), sorted(t["table"] for t in d["tables"]), d["partial"])' <<<"$out")" "([('transactions', 'amount', 'revenue')], ['transactions'], True)"
done
# A wrong column in his own SQL: the advice names the tables of that SQL, and only them.
out=$(call carol_analyst execute_query 'sql=SELECT a.nosuchcol FROM demo.crm.accounts a')
check "carol, a wrong column of accounts: kind column, describe_table on accounts only" "$(field '(d["kind"], "describe_table" in d["hint"], "accounts" in d["hint"], "customers" in d["hint"] or "transactions" in d["hint"])' <<<"$out")" "('column', True, True, False)"
out=$(call carol_analyst execute_query 'sql=SELECT nosuchcol FROM demo.crm.accounts a, demo.crm.transactions t')
check "carol, a wrong column over two tables: both named, no other" "$(field '("accounts" in d["hint"], "transactions" in d["hint"], "customers" in d["hint"])' <<<"$out")" "(True, True, False)"
out=$(call dave_viewer execute_query 'sql=SELECT a.nosuchcol FROM demo.crm.accounts a')
check "dave, a wrong column of accounts: the advice names accounts" "$(field '(d["kind"], "describe_table" in d["hint"], "accounts" in d["hint"], "customers" in d["hint"])' <<<"$out")" "('column', True, True, False)"
# He names a table the policy hides next to one he sees. Trino reports the column first:
# the advice names the tables of his SQL that he sees, never the hidden one, and no column.
out=$(call dave_viewer execute_query 'sql=SELECT a.nosuchcol FROM demo.crm.accounts a JOIN demo.crm.customers c ON a.customer_id = c.id')
check "dave, a wrong column qualified by the visible table, next to customers: kind column, advice on accounts alone" "$(field '(d["kind"], d["hint"].count("demo.crm."), "demo.crm.accounts" in d["hint"], "customers" in d["hint"])' <<<"$out")" "('column', 1, True, False)"
out=$(call dave_viewer execute_query 'sql=SELECT nosuchcol FROM demo.crm.accounts a, demo.crm.customers c')
check "dave, a column in neither: the advice names accounts, the table he sees, never customers" "$(field '(d["kind"], d["hint"].count("demo.crm."), "demo.crm.accounts" in d["hint"], "customers" in d["hint"], "transactions" in d["hint"])' <<<"$out")" "('column', 1, True, False, False)"
# A column hidden from him in a table he sees: named, it is refused by the policy (no
# advice); next to a column that does not exist, the advice is on the visible table and
# lists no column.
out=$(call dave_viewer execute_query 'sql=SELECT a.balance FROM demo.crm.accounts a')
check "dave, the hidden column named: kind permission, no advice" "$(field '(d["kind"], "hint" in d)' <<<"$out")" "('permission', False)"
out=$(call dave_viewer execute_query 'sql=SELECT balance, nosuchcol FROM demo.crm.accounts')
check "dave, a hidden column and an unknown one: kind column, advice on accounts, no column named in it" "$(field '(d["kind"], d["hint"].count("demo.crm."), "demo.crm.accounts" in d["hint"], "balance" in d["hint"], d["identifier"])' <<<"$out")" "('column', 1, True, False, 'nosuchcol')"
# The limit of words: `limit` words are searched, one more is refused, before any query
# reaches the engine. The witness first: the engine does receive the words of a search.
limit=$(search_words_limit)
check "the server says how many words a search takes (--check)" "$([[ $limit =~ ^[1-9][0-9]*$ ]] && echo yes)" "yes"
words_of() { python3 -c "print(' '.join(f'$1{i}x' for i in range($2)))"; }
queries() { local n; n=$(received "$1"); [[ $n =~ ^[0-9]+$ ]] && echo "$n" || echo "received failed"; }
out=$(call carol_analyst search_columns text="$(words_of okword "$limit")" catalog=demo)
check "carol, exactly $limit words: searched, no error, nothing found, complete" "$(field '("error" not in d, d["matches"], d["complete"])' <<<"$out")" "(True, [], True)"
check "  the engine received queries with these words (the witness of the count below)" "$([ "$(queries okword0x)" != 0 ] && [ "$(queries okword0x)" != "received failed" ] && echo yes)" "yes"
out=$(call carol_analyst search_columns text="$(words_of refusedw "$((limit + 1))")" catalog=demo)
check "carol, $((limit + 1)) words: refused, the error names the words and the limit, no matches" "$(field '(d.get("error", "").count("words") > 0 and "'"$limit"'" in d.get("error", ""), "matches" in d)' <<<"$out")" "(True, False)"
check "  refused before any query: the engine received none with these words" "$(queries refusedw0x)" "0"
out=$(walk dave_viewer describe_schema catalog=demo schema=crm | tee -a "$scratch/dave"); dave_pages "$out"
check "dave, describe_schema crm by pages: one page, accounts and transactions" "$(pages '[([t["table"] for t in p["tables"]], p["shortened"], p["next_offset"]) for p in pages]' <<<"$out")" "[(['accounts', 'transactions'], False, None)]"
check "dave, describe_schema crm: accounts without balance" "$(pages '[c["column"] for p in pages for t in p["tables"] if t["table"] == "accounts" for c in t["columns"]]' <<<"$out")" "['id', 'customer_id', 'opened_on', 'currency']"
out=$(walk carol_analyst describe_schema catalog=demo schema=crm)
check "carol, describe_schema crm by pages: two pages, three tables" "$(pages '[([t["table"] for t in p["tables"]], p["shortened"], p["next_offset"]) for p in pages]' <<<"$out")" "[(['accounts', 'customers'], True, 2), (['transactions'], False, None)]"
check "carol: balance with its comment" "$(pages '[c["comment"] for p in pages for t in p["tables"] for c in t["columns"] if c["column"] == "balance"]' <<<"$out")" "['Current balance in the account currency']"
check "carol: customers with its comment and its columns" "$(pages '[(t["comment"], [c["column"] for c in t["columns"]]) for p in pages for t in p["tables"] if t["table"] == "customers"]' <<<"$out")" "[('People and companies who hold an account', ['id', 'full_name', 'email', 'country', 'segment'])]"
out=$(walk dave_viewer list_tables catalog=demo schema=crm | tee -a "$scratch/dave"); dave_pages "$out"
check "dave, list_tables crm by pages: accounts and transactions" "$(pages '[(p["tables"], p["next_offset"]) for p in pages]' <<<"$out")" "[(['accounts', 'transactions'], None)]"
check "carol, list_tables crm: customers too" "$(call carol_analyst list_tables catalog=demo schema=crm | field 'd["tables"]')" "['accounts', 'customers', 'transactions']"
check "dave, 'balance' in demo: no match" "$(d search_columns text=balance catalog=demo | field 'd["matches"]')" "[]"
check "carol, 'balance' in demo: accounts.balance" "$(call carol_analyst search_columns text=balance catalog=demo | match)" "[('accounts', 'balance')]"
out=$(d describe_table catalog=demo schema=crm table=accounts)
check "dave, describe_table accounts: four columns, none cut" "$(field '([r[0] for r in d["rows"]], d["truncated"])' <<<"$out")" "(['id', 'customer_id', 'opened_on', 'currency'], False)"
check "alice, describe_table accounts: five, balance too" "$(call alice_admin describe_table catalog=demo schema=crm table=accounts | field '[r[0] for r in d["rows"]]')" "['id', 'customer_id', 'opened_on', 'currency', 'balance']"
# hide-inaccessible-columns: SELECT * leaves the hidden column out, and names it nowhere.
out=$(d execute_query 'sql=SELECT * FROM demo.crm.accounts ORDER BY id')
check "dave, SELECT * of accounts: an answer without balance" "$(field '(d["columns"], d["row_count"])' <<<"$out")" "(['id', 'customer_id', 'opened_on', 'currency'], 5)"
check "alice, SELECT * of accounts: balance too" "$(call alice_admin execute_query 'sql=SELECT * FROM demo.crm.accounts ORDER BY id' | field 'd["columns"]')" "['id', 'customer_id', 'opened_on', 'currency', 'balance']"
check "dave, SELECT balance: refused by the policy" "$(call dave_viewer execute_query 'sql=SELECT balance FROM demo.crm.accounts' | field 'd["kind"]')" "permission"
check "alice, SELECT balance: an answer" "$(call alice_admin execute_query 'sql=SELECT sum(balance) > 0 FROM demo.crm.accounts' | field 'd["rows"]')" "[[True]]"
check "dave, SELECT count(*) of accounts: 12" "$(d execute_query 'sql=SELECT count(*) FROM demo.crm.accounts' | field 'd["rows"]')" "[[12]]"
check "dave, an unknown column of accounts: kind column" "$(d execute_query 'sql=SELECT nope FROM demo.crm.accounts' | field 'd["kind"]')" "column"
check "dave, describe_schema of a schema that does not exist: kind schema" "$(d describe_schema catalog=demo schema=nosuch | field 'd["kind"]')" "schema"
check "dave, describe_schema of tpcds, which he names: kind permission" "$(call dave_viewer describe_schema catalog=tpcds schema=tiny | field 'd["kind"]')" "permission"
check "carol, describe_schema of tpcds.tiny: its tables" "$(call carol_analyst describe_schema catalog=tpcds schema=tiny | field 'len(d["tables"]) > 0')" "True"

# I1: search_columns with a named schema checks that the caller sees it. A schema
# that does not exist and one the policy hides answer the same kind schema, never
# an empty search said to be complete; a catalog he may not use keeps Trino's error.
check "dave, search_columns demo.crm_missing: kind schema, not found or not visible" "$(call dave_viewer search_columns text=amount catalog=demo schema=crm_missing | field '(d["kind"], d["error"], "complete" in d)')" "('schema', 'Schema demo.crm_missing not found or not visible', False)"
check "the variant that hides crm_archive from viewers is loaded" "$(opa PUT v07-hide-archive -H 'Content-Type: text/plain' --data-binary 'package trino

forbidden if {
	role == "viewer"
	input.action.resource[_].catalogName == "demo"
	input.action.resource[_].schemaName == "crm_archive"
}')" "200"
check "dave, search_columns demo.crm_archive, hidden: the same answer as a missing schema" "$(call dave_viewer search_columns text=amount catalog=demo schema=crm_archive | field '(d["kind"], d["error"], "complete" in d)')" "('schema', 'Schema demo.crm_archive not found or not visible', False)"
# The row cap (5) is shared by tables and columns: the twelve tables come first, over several pages, then the twelve columns.
check "carol, search_columns demo.crm_archive, visible to her: the twelve tables and their amount columns, across the cursor" "$(search_all carol_analyst text=amount catalog=demo schema=crm_archive | pages '(sorted({t["table"] for p in pages for t in p["tables"]}), sorted({(m["table"], m["column"]) for p in pages for m in p["matches"]}), pages[-1]["complete"], any("kind" in p for p in pages))')" "(['transactions_2014', 'transactions_2015', 'transactions_2016', 'transactions_2017', 'transactions_2018', 'transactions_2019', 'transactions_2020', 'transactions_2021', 'transactions_2022', 'transactions_2023', 'transactions_2024', 'transactions_2025'], [('transactions_2014', 'amount'), ('transactions_2015', 'amount'), ('transactions_2016', 'amount'), ('transactions_2017', 'amount'), ('transactions_2018', 'amount'), ('transactions_2019', 'amount'), ('transactions_2020', 'amount'), ('transactions_2021', 'amount'), ('transactions_2022', 'amount'), ('transactions_2023', 'amount'), ('transactions_2024', 'amount'), ('transactions_2025', 'amount')], True, False)"
check "carol, crm_archive: the first page is incomplete and holds tables only (the row cap is shared)" "$(search_all carol_analyst text=amount catalog=demo schema=crm_archive | pages '(pages[0]["complete"], pages[0]["matches"], len(pages[0]["tables"]) > 0)')" "(False, [], True)"
check "the variant is removed" "$(opa DELETE v07-hide-archive)" "200"
check "dave, crm_archive again: the first page is incomplete and holds tables only" "$(search_all dave_viewer text=amount catalog=demo schema=crm_archive | pages '(pages[0]["complete"], pages[0]["matches"], len(pages[0]["tables"]) > 0)')" "(False, [], True)"
check "dave, search_columns demo.crm_archive again: the same tables and columns" "$(search_all dave_viewer text=amount catalog=demo schema=crm_archive | pages '(sorted({t["table"] for p in pages for t in p["tables"]}), sorted({(m["table"], m["column"]) for p in pages for m in p["matches"]}), pages[-1]["complete"], any("kind" in p for p in pages))')" "(['transactions_2014', 'transactions_2015', 'transactions_2016', 'transactions_2017', 'transactions_2018', 'transactions_2019', 'transactions_2020', 'transactions_2021', 'transactions_2022', 'transactions_2023', 'transactions_2024', 'transactions_2025'], [('transactions_2014', 'amount'), ('transactions_2015', 'amount'), ('transactions_2016', 'amount'), ('transactions_2017', 'amount'), ('transactions_2018', 'amount'), ('transactions_2019', 'amount'), ('transactions_2020', 'amount'), ('transactions_2021', 'amount'), ('transactions_2022', 'amount'), ('transactions_2023', 'amount'), ('transactions_2024', 'amount'), ('transactions_2025', 'amount')], True, False)"
check "carol, search_columns demo.crm, visible: complete, transactions.amount" "$(call carol_analyst search_columns text=revenue catalog=demo schema=crm | field '([(m["table"], m["column"]) for m in d["matches"]], (d["schemas_searched"], d["complete"]) == (1, True))')" "([('transactions', 'amount')], True)"
check "dave, search_columns tpcds.tiny, a catalog he may not use: Trino's kind permission" "$(call dave_viewer search_columns text=amount catalog=tpcds schema=tiny | field 'd["kind"]')" "permission"
check "carol, search_columns tpcds.tiny, which she may use: matches, complete" "$(call carol_analyst search_columns text=amount catalog=tpcds schema=tiny | field '(len(d["matches"]) > 0, d["schemas_searched"], d["complete"], "kind" in d)')" "(True, 1, True, False)"
# Trino asks OPA through the batch rule, not one question per column: the decision
# log of OPA holds batch decisions, for the operations the rule names only.
check "OPA's log: Trino asked trino/batch" "$(docker compose logs opa 2>/dev/null | grep -c '"path":"trino/batch"' | awk '{print ($1 > 0)}')" "1"
# segment as a name of its own: tpch's mktsegment, which dave may see, holds it.
for word in customers full_name '"segment"' email 'People and companies' 'Retail or business' balance 'Current balance' tpcds; do
  check "nothing dave got names '$word'" "$(grep -ci -- "$word" "$scratch/dave")" "0"
done
check "dave got every answer asked of him, all JSON" "$(grep -c '^{' "$scratch/dave") $(grep -c . "$scratch/dave")" "$(dave_count) $(dave_count)"
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
check "dave in Trino, SELECT *: every column but balance" "$(trino dave_viewer "SELECT * FROM demo.crm.accounts" | field 'd["columns"]')" "['id', 'customer_id', 'opened_on', 'currency']"

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
keep_logs
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
keep_logs
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
check "search_columns answers again" "$(call carol_analyst search_columns text=revenue catalog=demo | match)" "[('transactions', 'amount')]"

echo "== 9. The agent's SQL never reads system"
# Each statement carries a marker, so the engine's own record shows whether it
# came; one allowed statement with the marker comes, and only that one.
for sql in "SELECT * FROM system.runtime.queries WHERE query_id = 'v07-guard'" "SELECT * FROM system.jdbc.columns WHERE table_name = 'v07-guard'" "SHOW TABLES FROM system.jdbc LIKE 'v07-guard'"; do
  out=$(call dave_viewer execute_query "sql=$sql")
  check "refused by the server: $sql" "$(field '("rows" in d, d.get("kind"))' <<<"$out")" "(False, 'read_only')"
done
check "an allowed statement with the marker: an answer" "$(call dave_viewer execute_query "sql=SELECT 'v07-guard' AS marker" | field 'd["rows"]')" "[['v07-guard']]"
check "the engine received that one only" "$(received v07-guard)" "1"

echo "== 10. describe_schema's metadata statements on crm_archive read the page only"
# crm_archive holds 12 tables of 3 columns. For a page of 4 tables, the server
# reads each table by its own equality, in one UNION ALL (Trino pushes an
# equality on table_name into its metadata views, never a list). Run as alice
# straight in Trino: the rows the scans read, with the server's form, then with
# table_name IN (...) for reference, which reads the whole schema.
page=(transactions_2014 transactions_2015 transactions_2016 transactions_2017)
check "the server sent that form in section 5" "$( [ "$(received "table_name = 'transactions_2014' UNION ALL")" -gt 0 ] 2>/dev/null && echo yes)" "yes"
scanned() { # sql: prints the rows read by every scan of its plan, summed
  trino alice_admin "EXPLAIN ANALYZE $1" | field 'd["rows"][0][0]' \
    | python3 -c "import re, sys; print(sum(int(n) for n in re.findall(r'Input: ([0-9]+) rows? \\([^)]*\\), Filtered', sys.stdin.read())))"
}
for view in "jdbc.columns WHERE table_cat = 'demo' AND table_schem" "metadata.table_comments WHERE catalog_name = 'demo' AND schema_name"; do
  select="SELECT * FROM system.$view = 'crm_archive'"
  union="SELECT * FROM ($(for t in "${page[@]}"; do printf '%s' "${sep:-}$select AND table_name = '$t'"; sep=" UNION ALL "; done)) ORDER BY table_name"; unset sep
  in_list="$select AND table_name IN ($(printf "'%s', " "${page[@]}" | sed 's/, $//'))"
  [ "${view%%.*}" = jdbc ] && want=12 || want=4
  check "system.${view%% *}, the server's form: $want rows read" "$(scanned "$union")" "$want"
  echo "  for reference, table_name IN (...): $(scanned "$in_list") rows read"
done

echo "== 10b. OPA's batch rule: only the operations it names"
# Behind the gateway Trino sends no FilterViewQueryOwnedBy, so the check is on what lies outside the list.
check "OPA's log: every batch operation is one the rule names" "$(docker compose logs opa 2>/dev/null | grep '"path":"trino/batch"' | grep -o '"operation":"[A-Za-z]*"' | sort -u | grep -Ev '"(FilterCatalogs|FilterSchemas|FilterTables|FilterColumns|FilterViewQueryOwnedBy)"' | wc -l)" "0"
check "OPA's log: the batch rule saw FilterCatalogs, FilterSchemas, FilterTables and FilterColumns" "$(docker compose logs opa 2>/dev/null | grep '"path":"trino/batch"' | grep -o '"operation":"[A-Za-z]*"' | sort -u | grep -Ec '"(FilterCatalogs|FilterSchemas|FilterTables|FilterColumns)"')" "4"
check "OPA's log: no FilterColumns asked one column at a time at allow" "$(docker compose logs opa 2>/dev/null | grep '"path":"trino/allow"' | grep -c '"operation":"FilterColumns"')" "0"

echo "== 11. Trino stopped: kind unavailable"
# shellcheck disable=SC2086
docker compose stop $clusters >/dev/null 2>&1
check "execute_query: kind unavailable" "$(call carol_analyst execute_query 'sql=SELECT 1' | field 'd["kind"]')" "unavailable"
check "describe_schema: kind unavailable" "$(call carol_analyst describe_schema catalog=demo schema=crm | field 'd["kind"]')" "unavailable"

echo "== 12. No token in the logs"
# Every server container of the run: the two before a new start in section 6,
# and this one. Each tool call leaves one audit line: the log holds them all.
keep_logs
calls=$(grep -c . "$scratch/calls")
check "the server's log holds an audit line for each of the $calls tool calls" "$(grep -c '"tool":"' "$scratch/mcp.log")" "$calls"
check "  dave's and carol's among them" "$(grep -c '"subject":"dave_viewer"' "$scratch/mcp.log" | grep -qv '^0$' && grep -c '"subject":"carol_analyst"' "$scratch/mcp.log" | grep -qv '^0$' && echo yes)" "yes"
check "no token in the server log" "$(grep -c 'eyJ' "$scratch/mcp.log")" "0"
check "no client secret in the server log" "$(grep -c "$(docker compose exec -T mcp cat /certs/mcp-client.secret)" "$scratch/mcp.log")" "0"

[ $failed -eq 0 ] && echo "== V07 OK ==" || { echo "== V07 FAILED =="; exit 1; }
