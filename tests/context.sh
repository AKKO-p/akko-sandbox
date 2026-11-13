#!/usr/bin/env bash
# The context from a data catalog of akko-mcp-trino 0.8, end to end, on a machine with
# Docker, against a real Apache Atlas 2.4.0 (catalogs/compose.atlas.yaml): carol_analyst
# gets Atlas's descriptions and the glossary Sales in describe_table and describe_schema;
# dave_viewer gets nothing about crm.customers, in his answers, the audit, his query
# history and OPA's decision log; a column the policy refuses leaves the context, the grain
# and the joins; a related term is named only next to an object the caller sees; nothing of
# the glossary Compliance comes out; a renamed table is not_found, an unmapped catalog
# not_mapped, a deleted entity never served; profile_table agrees with execute_query under a
# column mask and a row filter; a visible canary serves nothing; a stopped, slow or refused
# Atlas leaves the call answering in time, its connection closed and Atlas's late answer
# reaching no one, and a refused account is not asked again until its secret changes.
# Whatever happens, the end of the run removes the allow-all policy, resumes Atlas and puts
# the reader's secret back.
# Removes everything at the end unless KEEP=1. GATEWAY=1 runs the same checks behind Trino
# Gateway, two clusters sharing the same access control. Uses the sandbox's host ports
# unless told otherwise.
#
#   MCP_IMAGE=<image of 0.8> tests/context.sh
#   MCP_IMAGE=<image of 0.8> GATEWAY=1 tests/context.sh
#   COMPOSE_PROJECT_NAME=akko-ctx KEYCLOAK_PORT=18480 MCP_PORT=13000 INSPECTOR_PORT=16274 ATLAS_PORT=21100 tests/context.sh
set -uo pipefail
cd "$(dirname "$0")/.."
export COMPOSE_PROFILES=catalogs
if [ "${GATEWAY:-0}" = "1" ]; then
  export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-akko-sandbox-context-gateway}"
  export COMPOSE_FILE=compose.yaml:gateway/compose.gateway.yaml:catalogs/compose.atlas.yaml:tests/compose.v08.yaml:tests/compose.v08.gateway.yaml
  clusters="trino trino-2"
else
  export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-akko-sandbox-context}"
  export COMPOSE_FILE=compose.yaml:catalogs/compose.atlas.yaml:tests/compose.v08.yaml
  clusters="trino"
fi
failed=0
# Scratch files: dave's answers, the calls made, the server's logs. Removed at the end.
scratch=$(mktemp -d)
check() { if [ "$2" = "$3" ]; then printf '  OK    %s\n' "$1"; else printf '  FAIL  %s (got %s, expected %s)\n' "$1" "$2" "$3"; failed=1; fi; }
# What the run changed, undone at the end whatever happens, KEEP=1 and Ctrl-C included:
# the allow-all policy, a paused or stopped Atlas, a replaced reader secret.
allow_all=0 paused=0 stopped=0 secret_kept=0
cleanup() {
  restored() { if [ "$1" = 0 ]; then echo "== end of run: $2"; else echo "== end of run: FAILED, $3"; fi; }
  if [ $allow_all = 1 ]; then [ "$(opa DELETE v08-allow-all)" = 200 ]; restored $? "the allow-all policy removed" "the allow-all policy may still be loaded"; fi
  if [ $paused = 1 ]; then docker compose unpause atlas >/dev/null 2>&1; restored $? "Atlas resumed" "Atlas may still be paused"; fi
  if [ $secret_kept = 1 ]; then reader_secret 'cp reader.kept reader.secret && rm reader.kept'; restored $? "the reader's secret put back" "the reader's secret is still the wrong one"; fi
  if [ $stopped = 1 ] && [ "${KEEP:-0}" = "1" ]; then docker compose start atlas >/dev/null 2>&1; restored $? "Atlas started again" "Atlas is still stopped"; fi
  rm -rf "$scratch"
  if [ "${KEEP:-0}" = "1" ]; then echo "KEEP=1: project $COMPOSE_PROJECT_NAME left running"; return; fi
  docker compose --profile catalogs --profile tools down -v --remove-orphans >/dev/null 2>&1
  echo "== project $COMPOSE_PROJECT_NAME removed: $(docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" | wc -l) containers, $(docker volume ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" | wc -l) volumes left"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
try: print(eval(sys.argv[1], {'os': os, 'json': json}, {'d': d}))
except Exception: pass" "$1"; }
# The names of the terms of a describe_table answer, sorted.
term_names() { field 'sorted(t["name"] for t in d.get("terms", {}).values()) if isinstance(d.get("terms"), dict) else sorted(t["name"] for t in d.get("terms", []))'; }
# The server's log: the containers before a new start (kept_logs, saved by keep_logs
# before each one), then the current one, in $scratch/mcp.log.
keep_logs() { docker compose logs --no-color mcp >> "$scratch/kept_logs" 2>&1; }
read_logs() { { cat "$scratch/kept_logs" 2>/dev/null; docker compose logs --no-color mcp 2>&1; } > "$scratch/mcp.log"; }
opa() { # method, policy id, then curl options: OPA's policy API
  local method=$1 id=$2; shift 2
  docker compose exec -T opa-admin curl -fsS -o /dev/null -w '%{http_code}' -X "$method" "http://opa:8181/v1/policies/$id" "$@"
}
# Every query each cluster holds, as the admin reads it from the back network, one JSON
# object per query: the cluster, Trino's system.runtime.queries (user, query) and the
# client tags of the same query in the coordinator's /v1/query.
history() {
  docker compose exec -T history python -c "
import httpx, json, sys
token, clusters, gateway = sys.argv[1], sys.argv[2].split(), sys.argv[3] == '1'
for c in clusters:
    if gateway:   # the clusters' http port, behind the gateway that ends TLS
        base, kw = 'http://%s:8080' % c, dict(headers={'Authorization': 'Bearer ' + token, 'X-Forwarded-Proto': 'https'}, timeout=60)
    else:
        base, kw = 'https://%s:8443' % c, dict(headers={'Authorization': 'Bearer ' + token}, verify='/certs/ca.crt', timeout=60)
    tags = {q['queryId']: q['session'].get('clientTags', []) for q in httpx.get(base + '/v1/query', **kw).json()}
    r = httpx.post(base + '/v1/statement', content='SELECT query_id, \"user\", query FROM system.runtime.queries', **kw).json()
    while True:
        for qid, user, query in r.get('data', []):
            print(json.dumps({'cluster': c, 'query_id': qid, 'user': user, 'query': query, 'tags': tags.get(qid)}))
        if 'nextUri' not in r: break
        nxt = r['nextUri']
        if gateway: nxt = 'http://' + nxt.split('://', 1)[1]
        r = httpx.get(nxt, **kw).json()
    if 'error' in r: print(json.dumps({'cluster': c, 'error': r['error']['errorName']}))
" "$(./token.sh alice_admin trino-cli)" "$clusters" "${GATEWAY:-0}"
}
# A Python expression on the JSON lines read from stdin, as rows.
rows() { python3 -c "
import sys, json
rows = [json.loads(l) for l in sys.stdin if l.strip().startswith('{')]
try: print(eval(sys.argv[1], {}, {'rows': rows}))
except Exception as e: print('error:', type(e).__name__)" "$1"; }
# Atlas's own logs: each Basic login it refused (logins.log), each request it served
# (audit.log).
refused_logins() { docker compose exec -T atlas cat /data/logs/logins.log 2>/dev/null | grep -c 'Failed to process authentication request'; }
reader_requests() { docker compose exec -T atlas cat /data/logs/audit.log 2>/dev/null | grep -c '|mcp_reader|'; }
atlas_customers_reads() { docker compose exec -T atlas cat /data/logs/audit.log 2>/dev/null | grep '|mcp_reader|' | grep -c 'crm\.customers'; }
# The TCP connections of a container, read from inside its network namespace (which works
# while the container is paused), one JSON object per connection that is not listening: its
# local and remote ip:port, IPv4 and IPv4-mapped IPv6 alike, the TCP state (01 established,
# 05 FIN_WAIT2, 08 CLOSE_WAIT), the bytes not read yet, and the inode (0 once no process
# holds the socket any more).
sockets() { # container id
  docker run --rm --label "com.docker.compose.project=$COMPOSE_PROJECT_NAME" --label com.docker.compose.service=sockets \
    --network "container:$1" --entrypoint python "${MCP_IMAGE:-akkoai/akko-mcp-trino:0.8.0}" -c "
import ipaddress, json, socket, struct
def address(field):
    raw, port = field.split(':')
    data = bytes.fromhex(raw)
    data = b''.join(data[i:i + 4][::-1] for i in range(0, len(data), 4))
    ip = ipaddress.ip_address(data)
    if ip.version == 6 and ip.ipv4_mapped: ip = ip.ipv4_mapped
    return '%s:%d' % (ip, int(port, 16))
for table in ('/proc/net/tcp', '/proc/net/tcp6'):
    for line in open(table).readlines()[1:]:
        f = line.split()
        if f[3] != '0A':
            print(json.dumps({'local': address(f[1]), 'remote': address(f[2]), 'state': f[3],
                              'unread': int(f[4].split(':')[1], 16), 'inode': int(f[9])}))"
}
# The reader's password file, which the MCP server reads: kept, replaced, put back.
reader_secret() { # sh command run in /secrets as root, then a value it reads as $W
  docker compose run --rm --no-deps -T -u 0 -e W="${2:-}" --entrypoint /bin/sh atlas-secrets -c "cd /secrets && $1" >/dev/null 2>&1
}

echo "== 1. Start (project $COMPOSE_PROJECT_NAME, clusters: $clusters, ${MCP_IMAGE:-default image})"
start=$(date +%s)
if ! docker compose up -d --build --wait --wait-timeout 900; then
  docker compose ps -a; docker compose logs --tail 40 mcp atlas atlas-seed; exit 1
fi
echo "  all services healthy in $(( $(date +%s) - start )) s"
echo "  host: $(getconf _NPROCESSORS_ONLN) processors"
docker compose --profile catalogs --profile tools up -d opa-admin history >/dev/null 2>&1 || { echo "  the checks' clients did not start"; exit 1; }
echo "  server: $(docker compose exec -T mcp akko-mcp-trino --version 2>&1 | tail -1)"
# A server kept from an earlier run (KEEP=1) holds that run's lines: only this run's count.
read_logs; audit_before=$(grep -c '"tool":"' "$scratch/mcp.log")
echo "  seed: $(docker compose logs --no-color atlas-seed 2>&1 | grep -o 'atlas seeded.*\|atlas already.*' | tail -1)"
echo "  memory at rest, by service (docker stats):"
docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' $(docker compose ps -q) | sed "s/^$COMPOSE_PROJECT_NAME-/    /" | sort
checked=$(docker compose exec -T mcp akko-mcp-trino --check 2>&1)
check "--check: the context comes from atlas, then file" "$(grep -c '^context: atlas, file (' <<<"$checked")" "1"
check "--check: Atlas answers, version 2.4.0" "$(grep -c '^atlas: answers, version 2.4.0' <<<"$checked")" "1"
check "--check: a canary is set, never named" "$(grep '^visibility:' <<<"$checked" | grep -c 'canary set')$(grep -c 'mcp.canary' <<<"$checked")" "10"

echo "== 2. carol_analyst gets Atlas's context, under her rights"
out=$(call carol_analyst describe_table catalog=demo schema=crm table=transactions)
check "carol, describe_table transactions: both sources ok" "$(field 'd["context_sources"]' <<<"$out")" "{'atlas': 'ok', 'file': 'ok'}"
check "  the table's description, from Atlas" "$(field '(d["table"]["description"], d["table"]["sources"]["description"])' <<<"$out")" "('Money in and out of the accounts: one row per movement', 'atlas')"
check "  amount: its description and the term Revenue" "$(field '(d["column_context"]["amount"]["description"], [t["name"] for t in d["column_context"]["amount"]["terms"]])' <<<"$out")" "(\"Amount of the movement, in the account's currency\", ['Revenue'])"
check "  the terms of the answer: Revenue and Turnover, both of Sales" "$(field 'sorted((t["name"], t["glossary"]) for t in d["terms"].values())' <<<"$out")" "[('Revenue', 'Sales'), ('Turnover', 'Sales')]"
check "  each term with its status" "$(field 'sorted((t["name"], t["status"]) for t in d["terms"].values())' <<<"$out")" "[('Revenue', 'approved'), ('Turnover', 'draft')]"
check "  Revenue names its synonym Turnover, attached to the table" "$(field '[(r["name"], r["relation"]) for t in d["terms"].values() if t["name"] == "Revenue" for r in t.get("related", [])]' <<<"$out")" "[('Turnover', 'synonym')]"
check "  nothing of the glossary Compliance, attached to amount too" "$(grep -c 'Compliance\|Personal data\|identifies a person' <<<"$out")" "0"
check "  the row filter's column is described like any other" "$(field 'd["column_context"]["category"]["description"]' <<<"$out")" "What the money was spent on or came from"
echo "  her answer, the context of amount:"
field 'json.dumps({"column_context": {"amount": d["column_context"]["amount"]}, "terms": d["terms"], "context_sources": d["context_sources"]}, indent=2)' <<<"$out" | sed 's/^/    /'
out=$(call carol_analyst describe_schema catalog=demo schema=crm)
check "carol, describe_schema crm: Atlas's description of each table" "$(field 'sorted((t["table"], t.get("description", {}).get("text"), t.get("description", {}).get("source")) for t in d["tables"])' <<<"$out")" "[('accounts', 'Accounts: one row per account, in one currency, held by one customer', 'atlas'), ('customers', 'Everyone who holds an account: one row per person or company', 'atlas'), ('transactions', 'Money in and out of the accounts: one row per movement', 'atlas')]"
check "  both sources ok" "$(field 'd["context_sources"]' <<<"$out")" "{'atlas': 'ok', 'file': 'ok'}"
out=$(call carol_analyst describe_table catalog=demo schema=crm table=customers)
check "carol, describe_table customers: the term Customer, attached to it" "$(term_names <<<"$out")" "['Customer']"
check "  email: its description, masked data or not, and no term of Compliance" "$(field '(d["column_context"]["email"]["description"], "terms" in d["column_context"]["email"])' <<<"$out")" "('Address the company writes to', False)"
check "  segment, whose Atlas column is deleted: no context" "$(field '("segment" in d["column_context"], "Whether the customer" in json.dumps(d))' <<<"$out")" "(False, False)"

echo "== 3. The column the policy refuses to carol leaves the context, the grain and the joins"
out=$(call carol_analyst describe_table catalog=demo schema=crm table=accounts)
check "carol, describe_table accounts: no opened_on, in the columns or the context" "$(field '([r[0] for r in d["rows"]], sorted(d["column_context"]))' <<<"$out")" "(['id', 'customer_id', 'currency', 'balance'], ['balance', 'currency', 'customer_id', 'id'])"
check "  no grain: it held opened_on" "$(field 'd["table"].get("grain")' <<<"$out")" "None"
check "  the join to customers, which she sees" "$(field '[(j["columns"], j["table"], j["target_columns"]) for j in d["table"].get("joins", [])]' <<<"$out")" "[(['customer_id'], 'demo.crm.customers', ['id'])]"
check "  the term of opened_on is not named" "$(grep -c 'Opening date\|Day the account was opened' <<<"$out")" "0"
check "  Account does not name Customer: not attached to this answer" "$(field '[t.get("related", []) for t in d["terms"].values() if t["name"] == "Account"]' <<<"$out")" "[[]]"
check "  the terms: Account only" "$(term_names <<<"$out")" "['Account']"
out=$(call alice_admin describe_table catalog=demo schema=crm table=accounts)
check "alice, describe_table accounts: opened_on and its term" "$(field '(sorted(d["column_context"]), [t["name"] for t in d["column_context"]["opened_on"]["terms"]])' <<<"$out")" "(['balance', 'currency', 'customer_id', 'id', 'opened_on'], ['Opening date'])"
check "  the grain, whole" "$(field 'd["table"].get("grain")' <<<"$out")" "['customer_id', 'opened_on']"
out=$(call carol_analyst describe_table catalog=demo schema=crm table=transactions)
check "carol, describe_table transactions: the join through opened_on is dropped, the other kept" "$(field '[(j["columns"], j["table"], j["target_columns"]) for j in d["table"].get("joins", [])]' <<<"$out")" "[(['account_id'], 'demo.crm.accounts', ['id'])]"
out=$(call alice_admin describe_table catalog=demo schema=crm table=transactions)
check "alice, describe_table transactions: both joins" "$(field 'len(d["table"].get("joins", []))' <<<"$out")" "2"

echo "== 4. dave_viewer gets nothing about crm.customers"
# What dave gets, kept for the checks at the end of this section; never what he asks by
# name himself, which Trino repeats in its error. A marker first, so that his query history
# is seen to cover the whole section.
d() { echo >> "$scratch/dave_calls"; call dave_viewer "$@" | tee -a "$scratch/dave"; echo >> "$scratch/dave"; }
customers_read=$(atlas_customers_reads)
marker="v08-dave-$(date +%s)-$$"
d execute_query "sql=SELECT '$marker' AS marker" >/dev/null
out=$(d describe_table catalog=demo schema=crm table=accounts)
check "dave, describe_table accounts: no balance, both sources ok" "$(field '(sorted(d["column_context"]), d["context_sources"])' <<<"$out")" "(['currency', 'customer_id', 'id', 'opened_on'], {'atlas': 'ok', 'file': 'ok'})"
check "  no join: its target is customers" "$(field 'd["table"].get("joins")' <<<"$out")" "None"
check "  the grain, whole: he sees both its columns" "$(field 'd["table"].get("grain")' <<<"$out")" "['customer_id', 'opened_on']"
check "  the terms: Account and Opening date, Account naming no related term" "$(field 'sorted((t["name"], len(t.get("related", []))) for t in d["terms"].values())' <<<"$out")" "[('Account', 0), ('Opening date', 0)]"
out=$(d describe_table catalog=demo schema=crm table=transactions)
check "dave, describe_table transactions: the context, both joins to accounts" "$(field '(d["context_sources"], len(d["table"].get("joins", [])))' <<<"$out")" "({'atlas': 'ok', 'file': 'ok'}, 2)"
out=$(d describe_schema catalog=demo schema=crm)
check "dave, describe_schema crm: accounts and transactions, described" "$(field 'sorted((t["table"], "description" in t) for t in d["tables"])' <<<"$out")" "[('accounts', True), ('transactions', True)]"
d list_tables catalog=demo schema=crm >/dev/null
d search_columns text=account catalog=demo >/dev/null
check "dave, profile_table accounts, every column: no balance" "$(d profile_table catalog=demo schema=crm table=accounts mode=full | field '[c["column"] for c in d["columns"]]')" "['id', 'customer_id', 'opened_on', 'currency']"
for word in customers '"Customer"' full_name email segment balance 'Everyone who holds' 'person or company' 'holds at least one' Compliance 'Personal data' 'identifies a person'; do
  check "nothing dave got names $word, in any case" "$(grep -ci -- "$word" "$scratch/dave")" "0"
done
check "dave got every answer asked of him, all JSON" "$(grep -c '^{' "$scratch/dave")" "$(wc -l < "$scratch/dave_calls" | tr -d ' ')"
read_logs
dave_audit=$(grep '"tool":"' "$scratch/mcp.log" | tail -n +$((audit_before + 1)) | grep '"subject":"dave_viewer"')
dave_n=$(wc -l < "$scratch/dave_calls" | tr -d ' ')
check "his audit lines, one per call, with fingerprint-audit's fields" "$(grep -c '"sql_sha256"' <<<"$dave_audit") $(grep -c '"metadata_served"' <<<"$dave_audit")" "$dave_n $dave_n"
check "  they name no hidden object" "$(grep -ci 'customers\|balance\|full_name\|email\|segment' <<<"$dave_audit")" "0"
check "  metadata_served names what he was served: accounts and transactions" "$(grep -o '"metadata_served":\[[^]]*\]' <<<"$dave_audit" | grep -o 'demo\.crm\.[a-z_]*' | sort -u | tr '\n' ' ')" "demo.crm.accounts demo.crm.transactions "
history > "$scratch/history"
check "every cluster's history was read" "$(rows 'sorted({r["cluster"] for r in rows if "error" not in r}), [r for r in rows if "error" in r]' < "$scratch/history")" "($(python3 -c "import sys; print(sorted(sys.argv[1:]))" $clusters), [])"
check "his history holds the marker: it covers the section" "$(rows 'sum(1 for r in rows if r.get("user") == "dave_viewer" and "'"$marker"'" in r["query"])' < "$scratch/history")" "1"
check "  none of his queries names a hidden object" "$(rows '[r["query"] for r in rows if r.get("user") == "dave_viewer" and any(w in r["query"] for w in ("customers", "balance", "full_name", "email", "segment"))]' < "$scratch/history")" "[]"
# The visibility filter's statements, by their form: the catalogs, the schemas and the tables
# of a quoted catalog, a quoted DESCRIBE, a select check. The tools quote their names too, so
# a quoted form alone does not tell a tool from the filter: the tag mcp-gate does.
gate='^(SHOW CATALOGS|SELECT schema_name FROM "[^"]+"\.information_schema\.schemata|SELECT table_name FROM "[^"]+"\.information_schema\.tables WHERE table_schema = |DESCRIBE "|EXPLAIN \(TYPE VALIDATE\))'
check "  every statement marked mcp-gate has the form of the visibility filter" "$(GATE="$gate" rows 'sum(1 for r in rows if r.get("user") == "dave_viewer" and "mcp-gate" in (r["tags"] or []) and not __import__("re").match(__import__("os").environ["GATE"], r["query"]))' < "$scratch/history")" "0"
check "  his other statements were seen, and none carries mcp-gate" "$(GATE="$gate" rows 'sorted({"mcp-gate" in (r["tags"] or []) for r in rows if r.get("user") == "dave_viewer" and not __import__("re").match(__import__("os").environ["GATE"], r["query"])})' < "$scratch/history")" "[False]"
check "  among them the canary check and the proof of the join's target" "$(rows '(any("'"'"'canary'"'"'" in r["query"] for r in rows if r.get("user") == "dave_viewer" and "mcp-gate" in (r["tags"] or [])), any(r["query"].startswith("DESCRIBE \"") for r in rows if r.get("user") == "dave_viewer" and "mcp-gate" in (r["tags"] or [])))' < "$scratch/history")" "(True, True)"
docker compose logs --no-color opa 2>/dev/null | sed 's/^[^{]*//' > "$scratch/opa"
opa_dave=$(python3 -c "
import json, sys
n = other = 0
for line in open(sys.argv[1]):
    try: e = json.loads(line)
    except ValueError: continue
    i = e.get('input') or {}
    if (i.get('context') or {}).get('identity', {}).get('user') != 'dave_viewer' or 'customers' not in json.dumps(i): continue
    n += 1
    a = i.get('action', {})
    names = [(r.get('table') or {}).get('tableName') for r in a.get('filterResources', [])]
    if e.get('path') != 'trino/batch' or a.get('operation') != 'FilterTables' or 'customers' not in names or names.index('customers') in (e.get('result') or []):
        other += 1
print(n, other)" "$scratch/opa")
echo "  OPA's log: ${opa_dave% *} decisions for dave name customers"
check "  each of them Trino's own listing filter (FilterTables), which refused it" "$([ "${opa_dave% *}" -gt 0 ] 2>/dev/null && echo "${opa_dave#* }")" "0"
# Last, a search for a word only crm.customers holds. The word is his own, so the statements
# of the search carry it: they are not in the history checks above.
out=$(call dave_viewer search_columns text=email catalog=demo)
check "dave, search_columns email: no match, complete, and nothing about customers" "$(field '(d["matches"], d["complete"])' <<<"$out") $(grep -ci 'customers' <<<"$out")" "([], True) 0"
check "Atlas was asked nothing about crm.customers during his calls (audit.log)" "$(( $(atlas_customers_reads) - customers_read ))" "0"

echo "== 5. A renamed table, an unmapped catalog, a deleted entity"
out=$(call carol_analyst describe_table catalog=demo schema=crm_archive table=transactions_2014)
check "carol, transactions_2014, renamed in Atlas: atlas not_found, nothing served" "$(field '(d["context_sources"]["atlas"], d["table"], d["column_context"], d["terms"])' <<<"$out")" "('not_found', {}, {}, {})"
out=$(call carol_analyst describe_table catalog=tpch schema=tiny table=nation)
check "carol, tpch.tiny.nation, a catalog no Atlas cluster maps: not_mapped, nothing served" "$(field '(d["context_sources"], d["table"])' <<<"$out")" "({'atlas': 'not_mapped', 'file': 'not_mapped'}, {})"
out=$(call carol_analyst describe_table catalog=demo schema=crm_archive table=transactions_2015)
check "carol, transactions_2015, deleted in Atlas: atlas not_found, nothing served" "$(field '(d["context_sources"]["atlas"], d["table"])' <<<"$out")" "('not_found', {})"
out=$(call carol_analyst describe_schema catalog=demo schema=crm_archive)
check "carol, describe_schema crm_archive: no description from Atlas" "$(field '[t["table"] for t in d["tables"] if "description" in t]' <<<"$out")" "[]"
check "  the texts of the renamed and the deleted entity never come out" "$(grep -c 'before the rename\|deleted since' <<<"$out")" "0"

echo "== 6. profile_table agrees with execute_query, under a mask and a row filter"
for who in carol_analyst alice_admin; do
  p=$(call $who profile_table catalog=demo schema=crm table=customers 'columns=["email"]' mode=full)
  q=$(call $who execute_query 'sql=SELECT count(*), min(email), max(email) FROM demo.crm.customers')
  check "$who, customers.email (masked but for alice): rows, min, max as execute_query" "$(field '[d["rows"], d["columns"][0]["min"], d["columns"][0]["max"]]' <<<"$p")" "$(field 'd["rows"][0]' <<<"$q" | grep . || echo "no answer from execute_query")"
  p=$(call $who profile_table catalog=demo schema=crm table=transactions 'columns=["amount"]' mode=full)
  q=$(call $who execute_query 'sql=SELECT count(*), min(amount), max(amount) FROM demo.crm.transactions')
  check "$who, transactions.amount (rows filtered on category for carol): rows, min, max as execute_query" "$(field '[d["rows"], d["columns"][0]["min"], d["columns"][0]["max"]]' <<<"$p")" "$(field 'd["rows"][0]' <<<"$q" | grep . || echo "no answer from execute_query")"
  eval "rows_$who=\$(field 'd[\"rows\"]' <<<\"\$p\")"
done
check "the row filter applies to carol's profile: fewer rows than alice's" "$([ "${rows_carol_analyst:-0}" -lt "${rows_alice_admin:-0}" ] 2>/dev/null && echo yes)" "yes"
check "carol's masked e-mails: the profile shows the mask" "$(call carol_analyst profile_table catalog=demo schema=crm table=customers 'columns=["email"]' mode=full | field 'd["columns"][0]["min"][:3]')" "***"

echo "== 7. A visible canary serves nothing"
read_logs; log_lines_before=$(wc -l < "$scratch/mcp.log")
allow_all=1
check "the allow-all variant of the policy is loaded" "$(opa PUT v08-allow-all -H 'Content-Type: text/plain' --data-binary 'package trino

allow if true')" "200"
out=$(call carol_analyst describe_table catalog=demo schema=crm table=transactions)
check "carol, describe_table transactions: every source not_checked, no context" "$(field '(d["context_sources"], d["table"], d["column_context"], d["terms"])' <<<"$out")" "({'atlas': 'not_checked', 'file': 'not_checked'}, {}, {}, {})"
check "  the columns still come" "$(field 'len(d["rows"])' <<<"$out")" "5"
check "a second call under the variant: not_checked again" "$(call carol_analyst describe_table catalog=demo schema=crm table=accounts | field 'd["context_sources"]')" "{'atlas': 'not_checked', 'file': 'not_checked'}"
read_logs
warning=$(tail -n +$((log_lines_before + 1)) "$scratch/mcp.log" | grep 'WARNING' | grep 'canary')
check "the server warns at each of the two calls that see the canary" "$(grep -c . <<<"$warning")" "2"
check "  and names no user and no table" "$(grep -ci 'carol\|demo\|mcp\.canary\|transactions\|accounts' <<<"$warning")" "0"
check "the variant is removed" "$(opa DELETE v08-allow-all)" "200"
allow_all=0
check "carol gets the context again" "$(call carol_analyst describe_table catalog=demo schema=crm table=transactions | field 'd["context_sources"]')" "{'atlas': 'ok', 'file': 'ok'}"

echo "== 8. A slow Atlas: the call answers in time, and Atlas's late answer finds no reader"
# ATLAS_TIMEOUT_SECONDS is 30 s here (tests/compose.v08.yaml): only the context deadline can
# end the read in time. The call may take that deadline, plus the 0.25 s the chain waits past
# it and the 0.5 s reply margin of the provider contract (akko-mcp-trino's catalog-context
# docs and its ContextContract), more than the same call with Atlas healthy.
deadline=$(docker compose exec -T mcp printenv MCP_CONTEXT_TIMEOUT_SECONDS | tr -d '\r')
seconds() { python3 -c "import time; print(time.time())"; }
t0=$(seconds); out=$(call carol_analyst describe_table catalog=demo schema=crm table=transactions); t1=$(seconds)
baseline=$(python3 -c "import sys; print(round(float(sys.argv[2]) - float(sys.argv[1]), 2))" "$t0" "$t1")
check "carol, describe_table transactions with Atlas healthy: atlas ok" "$(field 'd["context_sources"]["atlas"]' <<<"$out")" "ok"
atlas_id=$(docker compose ps -q atlas) mcp_id=$(docker compose ps -q mcp)
sockets "$atlas_id" > "$scratch/atlas.before"; sockets "$mcp_id" > "$scratch/mcp.before"
# The witness that the probe finds what is there: the server's pooled connection to Atlas,
# seen from both ends, the same four ip:port. V08_WITNESS_PORT_SHIFT (0) moves the port the
# server's side is looked up under, to see this witness fail, and the checks below that rest
# on it lose their meaning.
shift_port=${V08_WITNESS_PORT_SHIFT:-0}
# What the server holds of a connection Atlas sees: the server's sockets whose local ip:port
# is Atlas's remote one and whose remote ip:port is Atlas's local one, as (state, inode).
server_side() { # file of the server's sockets, file of Atlas's sockets, filter on Atlas's side
  python3 -c "
import json, sys
rows = lambda path: [json.loads(l) for l in open(path) if l.strip()]
shift = int(sys.argv[4])
def moved(addr):
    host, port = addr.rsplit(':', 1)
    return '%s:%d' % (host, int(port) + shift)
for a in rows(sys.argv[2]):
    if a['local'].endswith(':21000') and not a['remote'].startswith('127.') and eval(sys.argv[3], {}, {'r': a}):
        print([(s['state'], s['inode']) for s in rows(sys.argv[1]) if s['local'] == moved(a['remote']) and s['remote'] == a['local']])" "$1" "$2" "$3" "$shift_port"
}
check "the probe sees the server's pooled connection to Atlas from both ends, held by the server" "$(server_side "$scratch/mcp.before" "$scratch/atlas.before" 'r["state"] == "01"' | python3 -c "
import ast, sys
found = [ast.literal_eval(l) for l in sys.stdin if l.strip()]
print(bool(found) and all(len(f) == 1 and f[0][0] == '01' and f[0][1] > 0 for f in found))")" "True"
served_before=$(reader_requests)
paused=1; docker compose pause atlas >/dev/null 2>&1
t0=$(seconds); out=$(call carol_analyst describe_table catalog=demo schema=crm table=transactions); t1=$(seconds)
elapsed=$(python3 -c "import sys; print(round(float(sys.argv[2]) - float(sys.argv[1]), 2))" "$t0" "$t1")
echo "  describe_table answered in $elapsed s with Atlas frozen, $baseline s with Atlas healthy; the context deadline is $deadline s"
check "carol, describe_table transactions with Atlas frozen: atlas unavailable, file ok" "$(field 'd["context_sources"]' <<<"$out")" "{'atlas': 'unavailable', 'file': 'ok'}"
# The joins need statements the spent deadline no longer allows: none is served.
check "  the columns and the file's grain still come" "$(field '(len(d["rows"]), d["table"].get("grain"))' <<<"$out")" "(5, ['id'])"
# A call that did not wait for Atlas would take about the healthy time; this one takes the
# deadline at least. (The frozen call skips the reads and proofs that follow a healthy read,
# so its time past the healthy one can be a little less than the deadline.)
check "  the call took at least the deadline, $deadline s, end to end" "$(python3 -c "import sys; print(float(sys.argv[1]) >= float(sys.argv[2]))" "$elapsed" "$deadline")" "True"
check "  and no longer: at most the deadline + 0.25 s + 0.5 s more than with Atlas healthy" "$(python3 -c "import sys; e, b, d = map(float, sys.argv[1:]); print(e - b <= d + 0.25 + 0.5)" "$elapsed" "$baseline" "$deadline")" "True"
sockets "$atlas_id" > "$scratch/atlas.during"
# The connection that holds the request is the one with bytes Atlas has not read.
check "Atlas's side: one connection holds the request unread, and the client closed it (CLOSE_WAIT)" "$(rows '[r["state"] for r in rows if r["local"].endswith(":21000") and r["unread"] > 0]' < "$scratch/atlas.during")" "['08']"
check "  it is a connection of the pool, open before the pause" "$(python3 -c "
import json, sys
rows = lambda path: [json.loads(l) for l in open(path) if l.strip()]
before = {(r['local'], r['remote']) for r in rows(sys.argv[1]) if r['state'] == '01'}
held = [(r['local'], r['remote']) for r in rows(sys.argv[2]) if r['unread'] > 0]
print(len(held) == 1 and held[0] in before)" "$scratch/atlas.before" "$scratch/atlas.during")" "True"
# The same connection, from the server's side, while Atlas is still frozen: the server has
# let go of it. Its socket is gone, or in FIN_WAIT2 with no process holding it (inode 0), so
# the kernel answers anything Atlas sends later with a reset.
sockets "$mcp_id" > "$scratch/mcp.during"
check "  the server no longer holds it: its socket is gone, or in FIN_WAIT2 with no process" "$(server_side "$scratch/mcp.during" "$scratch/atlas.during" 'r["unread"] > 0' | python3 -c "
import ast, sys
found = [ast.literal_eval(l) for l in sys.stdin if l.strip()]
print('no connection held the request' if len(found) != 1 else all(s == '05' and inode == 0 for s, inode in found[0]))")" "True"
# HTTP cannot withdraw a request already sent: the data catalog may still read and answer it,
# and that answer reaches no one. Once Atlas is resumed, what it served is printed, as its
# audit log says. Its answer finds no reader: Atlas no longer holds that connection, and the
# server has no socket left for it.
held=$(python3 -c "
import json, sys
held = [r['local'] + '|' + r['remote'] for r in map(json.loads, filter(str.strip, open(sys.argv[1]))) if r['local'].endswith(':21000') and r['unread'] > 0]
print(held[0] if len(held) == 1 else '')" "$scratch/atlas.during")
docker compose unpause atlas >/dev/null 2>&1; paused=0
sleep 5
docker compose exec -T atlas cat /data/logs/audit.log 2>/dev/null | grep '|mcp_reader|' | tail -n +$((served_before + 1)) \
  | awk -F'|' '{print "  Atlas, resumed, served: " $4 " " $5 ", status " $6}'
sockets "$atlas_id" > "$scratch/atlas.after"; sockets "$mcp_id" > "$scratch/mcp.after"
check "Atlas resumed: it no longer holds the connection of the cut read" "$([ -n "$held" ] && HELD="$held" rows '[r["state"] for r in rows if r["local"] + "|" + r["remote"] == __import__("os").environ["HELD"]]' < "$scratch/atlas.after" || echo "no single connection held the request")" "[]"
check "  and the server has no socket for it: Atlas's answer finds no reader" "$([ -n "$held" ] && python3 -c "
import json, sys
local, remote = sys.argv[2].split('|')
host, port = remote.rsplit(':', 1)
mine = '%s:%d' % (host, int(port) + int(sys.argv[3]))
print([r['state'] for r in map(json.loads, filter(str.strip, open(sys.argv[1]))) if r['local'] == mine and r['remote'] == local])" "$scratch/mcp.after" "$held" "$shift_port" || echo "no single connection held the request")" "[]"
n=0; until [ "$(call carol_analyst describe_table catalog=demo schema=crm table=accounts | field 'd["context_sources"]["atlas"]')" = ok ] || [ $n -ge 12 ]; do n=$((n + 1)); sleep 5; done
check "Atlas back: the context comes again" "$(call carol_analyst describe_table catalog=demo schema=crm table=accounts | field 'd["context_sources"]')" "{'atlas': 'ok', 'file': 'ok'}"

echo "== 9. A refused account: one attempt, then nothing until its secret changes"
# Two wrong passwords, drawn here, never printed: the log is searched for them at the end.
wrong1=$(python3 -c "import secrets; print(secrets.token_hex(24))")
wrong2=$(python3 -c "import secrets; print(secrets.token_hex(24))")
secret_kept=1
reader_secret 'cp reader.secret reader.kept && printf "%s\n" "$W" > reader.secret' "$wrong1" || echo "  the reader's secret was not replaced"
keep_logs
# A new server process, with no session open at Atlas.
docker compose up -d --no-deps --force-recreate --wait --wait-timeout 120 mcp >/dev/null 2>&1 || { echo "  the server did not start again"; failed=1; }
before=$(refused_logins)
read_logs; refused_logged=$(grep -c 'atlas refused the account' "$scratch/mcp.log")
for i in 1 2 3; do
  check "carol, call $i with a refused account: atlas refused, file ok" "$(call carol_analyst describe_table catalog=demo schema=crm table=accounts | field 'd["context_sources"]')" "{'atlas': 'refused', 'file': 'ok'}"
done
check "Atlas refused one login, no more" "$(( $(refused_logins) - before ))" "1"
read_logs
check "the server logs it once: atlas refused the account" "$(( $(grep -c 'atlas refused the account' "$scratch/mcp.log") - refused_logged ))" "1"
reader_secret 'printf "%s\n" "$W" > reader.secret' "$wrong2"
check "the secret changes, still wrong: refused, after one more login" "$(call carol_analyst describe_table catalog=demo schema=crm table=accounts | field 'd["context_sources"]["atlas"]') $(( $(refused_logins) - before ))" "refused 2"
check "  and no more after it" "$(call carol_analyst describe_table catalog=demo schema=crm table=accounts | field 'd["context_sources"]["atlas"]') $(( $(refused_logins) - before ))" "refused 2"
served=$(reader_requests)
reader_secret 'cp reader.kept reader.secret && rm reader.kept'; secret_kept=0
check "the right secret back: the context comes at the next call" "$(call carol_analyst describe_table catalog=demo schema=crm table=accounts | field 'd["context_sources"]')" "{'atlas': 'ok', 'file': 'ok'}"
check "  Atlas served the reader again, and refused nothing more" "$([ "$(reader_requests)" -gt "$served" ] && echo yes) $(( $(refused_logins) - before ))" "yes 2"

echo "== 10. Atlas stopped: unavailable, the call still answers"
read_logs; unreachable_before=$(grep -c 'atlas unreachable' "$scratch/mcp.log"); unavailable_before=$(grep -c 'atlas is unavailable' "$scratch/mcp.log")
stopped=1; docker compose stop atlas >/dev/null 2>&1
out=$(call carol_analyst describe_table catalog=demo schema=crm table=transactions)
check "carol, describe_table transactions: atlas unavailable, file ok" "$(field 'd["context_sources"]' <<<"$out")" "{'atlas': 'unavailable', 'file': 'ok'}"
check "  the columns and the joins still come" "$(field '(len(d["rows"]), len(d["table"].get("joins", [])))' <<<"$out")" "(5, 1)"
read_logs
check "since the stop, the provider logs atlas unreachable, the server atlas is unavailable" "$(( $(grep -c 'atlas unreachable' "$scratch/mcp.log") > unreachable_before )) $(( $(grep -c 'atlas is unavailable' "$scratch/mcp.log") > unavailable_before ))" "1 1"

echo "== 11. No token and no secret in the server's log"
read_logs
calls=$(grep -c . "$scratch/calls")
check "the server's log holds an audit line for each of the $calls tool calls" "$(( $(grep -c '"tool":"' "$scratch/mcp.log") - audit_before ))" "$calls"
check "no token in the server log" "$(grep -c 'eyJ' "$scratch/mcp.log")" "0"
check "no client secret in the server log" "$(grep -c "$(docker compose exec -T mcp cat /certs/mcp-client.secret)" "$scratch/mcp.log")" "0"
check "no Atlas password in the server log, the right one or the two wrong ones" "$(grep -c "$(docker compose exec -T mcp cat /atlas-secrets/reader.secret)\|$wrong1\|$wrong2" "$scratch/mcp.log")" "0"

[ $failed -eq 0 ] && echo "== CONTEXT OK ==" || { echo "== CONTEXT FAILED =="; exit 1; }
