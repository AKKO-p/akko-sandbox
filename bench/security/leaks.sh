#!/usr/bin/env bash
# The marker scanner (bench/lib/leaks.py) on the sandbox, end to end: a witness word,
# drawn from a seed, is written into the comment of the table and of the column the
# policy hides from dave_viewer (crm.customers, crm.accounts.balance). dave then plays
# the calls an agent would make, by words that would find them, never by their names.
# The scan of every channel dave's calls reach (the answers, their decoded cursors,
# the server's log, system.runtime.queries under dave, OPA's decision log) must find
# neither the witness words nor the hidden names. Two plays of dave's calls are the
# same once ids are removed (the differential test's own baseline). Then carol, who
# may see them, plays the same calls: the scanner must find every marker in her
# answers, or it cannot fail and proves nothing.
# Removes everything at the end unless KEEP=1. Played by bench/run.sh security.
#
#   bench/security/leaks.sh
#   BENCH_SEED=1311 KEEP=1 bench/security/leaks.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-akko-bench-leaks}"
export COMPOSE_FILE=compose.yaml:tests/compose.v07.yaml
seed=${BENCH_SEED:-1311}
failed=0
ev=${BENCH_EVIDENCE:+$BENCH_EVIDENCE/leaks}
ev=${ev:-$(mktemp -d)}
mkdir -p "$ev" && ev=$(cd "$ev" && pwd)
check() { if [ "$2" = "$3" ]; then printf '  OK    %s\n' "$1"; else printf '  FAIL  %s (got %s, expected %s)\n' "$1" "$2" "$3"; failed=1; fi; }
cleanup() {
  [ -z "${BENCH_EVIDENCE:-}" ] && rm -rf "$ev"
  if [ "${KEEP:-0}" = "1" ]; then echo "KEEP=1: project $COMPOSE_PROJECT_NAME left running"; return; fi
  docker compose --profile tools down -v --remove-orphans >/dev/null 2>&1
  echo "== project $COMPOSE_PROJECT_NAME removed: $(docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" | wc -l) containers left"
}
trap cleanup EXIT

call() { # user, tool, then name=value arguments: the tool's text, one line
  local user=$1 tool=$2; shift 2
  local args=(); for a in "$@"; do args+=(--tool-arg "$a"); done
  docker compose exec -T inspector mcp-inspector --cli http://mcp:3000/mcp \
    --header "Authorization: Bearer $(./token.sh "$user")" --method tools/call \
    --tool-name "$tool" "${args[@]}" 2>/dev/null \
    | python3 -c "import sys,json; print(json.dumps(json.loads(json.load(sys.stdin)['content'][0]['text'])))" 2>/dev/null \
    || echo '{"bench": "no JSON answer"}'
}
trino() { # user, sql: {"columns", "rows"} or {"error"}, straight to Trino with the user's own token
  docker compose exec -T mcp python -c "
import httpx, json, os, sys
base = 'https://%s:%s' % (os.environ['TRINO_HOST'], os.environ['TRINO_PORT'])
kw = dict(headers={'Authorization': 'Bearer ' + sys.argv[1]}, verify='/certs/ca.crt', timeout=60)
r = httpx.post(base + '/v1/statement', content=sys.argv[2], **kw).json()
rows = []
while True:
    if 'error' in r: print(json.dumps({'error': r['error']['errorName']})); break
    rows += r.get('data', [])
    if 'nextUri' not in r: print(json.dumps({'rows': rows})); break
    r = httpx.get(r['nextUri'], **kw).json()" "$(./token.sh "$1" trino-cli)" "$2"
}
psql() { docker compose exec -T postgres psql -U sandbox -d sandbox -tAc "$1"; }
# The calls an agent makes to find a table or a column, by words the hidden comments
# hold (people, companies, current), never by a hidden name.
play() { # user: one JSON answer per line
  local u=$1
  call "$u" list_catalogs
  call "$u" list_schemas catalog=demo
  call "$u" list_tables catalog=demo schema=crm
  call "$u" list_tables catalog=demo schema=crm offset=5
  call "$u" describe_schema catalog=demo schema=crm
  call "$u" describe_schema catalog=demo schema=crm offset=2
  call "$u" describe_table catalog=demo schema=crm table=accounts
  call "$u" search_columns text=people catalog=demo
  call "$u" search_columns text=companies
  call "$u" search_columns text=current catalog=demo
  call "$u" search_columns "text=current currency"
  call "$u" search_columns text=holder
  call "$u" execute_query "sql=SELECT * FROM demo.crm.accounts ORDER BY id LIMIT 3"
  call "$u" execute_query "sql=SELECT table_name FROM demo.information_schema.tables WHERE table_schema = 'crm' ORDER BY 1"
  call "$u" execute_query "sql=SELECT column_name FROM demo.information_schema.columns WHERE table_schema = 'crm' ORDER BY 1"
  call "$u" explain_query "sql=SELECT * FROM demo.crm.accounts"
}
calls=16

echo "== 1. Start (project $COMPOSE_PROJECT_NAME), witness words from seed $seed"
start=$(date +%s)
if ! docker compose up -d --wait --wait-timeout 480 >/dev/null 2>&1; then
  docker compose ps -a; docker compose logs --tail 40; exit 1
fi
echo "  all services healthy in $(( $(date +%s) - start )) s"
echo "  server: $(docker compose exec -T mcp akko-mcp-trino --version 2>&1 | tail -1)"
read -r table_word column_word < <(python3 bench/lib/leaks.py markers --seed "$seed" --count 2 | tr '\n' ' ')
psql "COMMENT ON TABLE crm.customers IS 'People and companies who hold an account $table_word'" >/dev/null
psql "COMMENT ON COLUMN crm.accounts.balance IS 'Current balance in the account currency $column_word'" >/dev/null
check "the table's witness word is in Postgres" "$(psql "SELECT obj_description('crm.customers'::regclass)" | grep -c "$table_word")" "1"
check "the column's witness word is in Postgres" "$(psql "SELECT col_description('crm.accounts'::regclass, 5)" | grep -c "$column_word")" "1"
check "alice reads the table's witness word in Trino" "$(trino alice_admin "SELECT comment FROM system.metadata.table_comments WHERE catalog_name = 'demo' AND schema_name = 'crm' AND table_name = 'customers'" | grep -c "$table_word")" "1"

echo "== 2. dave plays the calls twice"
play dave_viewer > "$ev/dave.jsonl"
play dave_viewer > "$ev/dave-again.jsonl"
check "dave got $calls answers, all JSON from the server" "$(grep -c '^{' "$ev/dave.jsonl") $(grep -c '"bench": "no JSON answer"' "$ev/dave.jsonl")" "$calls 0"
check "dave's two plays are the same once ids and durations are removed" "$(python3 bench/lib/leaks.py diff "$ev/dave.jsonl" "$ev/dave-again.jsonl" >"$ev/diff.txt"; echo $?)" "0"
check "dave sees accounts, the scan has something to read" "$(grep -c 'accounts' "$ev/dave.jsonl" | awk '{print ($1 > 0)}')" "1"

echo "== 3. The channels dave's calls reach"
docker compose logs --no-color mcp > "$ev/server.log" 2>&1
docker compose logs --no-color opa > "$ev/opa.log" 2>&1
trino alice_admin "SELECT query FROM system.runtime.queries WHERE user = 'dave_viewer'" > "$ev/runtime-queries.json"
check "the server's log holds an audit line for each of dave's calls" "$(grep -c '"subject":"dave_viewer"' "$ev/server.log")" "$(( 2 * calls ))"
check "system.runtime.queries holds dave's queries" "$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['rows']) > 0)" "$ev/runtime-queries.json")" "True"
check "OPA's decision log holds dave's decisions" "$(grep -c 'dave_viewer' "$ev/opa.log" | awk '{print ($1 > 0)}')" "1"
# The hidden names may be in OPA's input (Trino asks it to filter every table); the
# witness words, which are comments, nowhere.
rules=(--marker "$table_word" --marker "$column_word" --marker customers:opa_log --marker full_name:opa_log
       --marker balance:opa_log --marker "Current balance" --marker "People and companies")
channels=(--channel answers="$ev/dave.jsonl" --channel server_log="$ev/server.log"
          --channel runtime_queries="$ev/runtime-queries.json" --channel opa_log="$ev/opa.log")
python3 bench/lib/leaks.py scan "${rules[@]}" "${channels[@]}" --json "$ev/dave-findings.json" > "$ev/dave-scan.txt"
check "the scan of dave's channels finds no marker" "$(tail -1 "$ev/dave-scan.txt")" "scan: 0 findings, 7 markers, 4 channels"
grep '^LEAK' "$ev/dave-scan.txt" | head -20 | sed 's/^/  /'

echo "== 4. The counter-proof: carol, who may see them, plays the same calls"
play carol_analyst > "$ev/carol.jsonl"
python3 bench/lib/leaks.py scan "${rules[@]}" --channel answers="$ev/carol.jsonl" --json "$ev/carol-findings.json" > "$ev/carol-scan.txt"
for named in "the table's witness word=$table_word" "the column's witness word=$column_word" "customers=customers" \
             "balance=balance" "Current balance=Current balance" "People and companies=People and companies"; do
  check "the scanner finds ${named%%=*} in carol's answers" "$(python3 -c "import json,sys; print(any(f['marker'] == sys.argv[2] for f in json.load(open(sys.argv[1]))))" "$ev/carol-findings.json" "${named#*=}")" "True"
done

[ "$failed" = 0 ] && echo "== LEAKS OK" || echo "== SOME CHECKS FAILED"
exit "$failed"
