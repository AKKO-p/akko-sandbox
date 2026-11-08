#!/usr/bin/env bash
# The context from a data catalog of akko-mcp-trino 0.8 at scale, on a machine with Docker,
# against a real Apache Atlas 2.4.0 (catalogs/compose.atlas.yaml). One table of 2,000
# columns, wide.load.wide_2000, in Trino's memory connector, which Atlas describes column by
# column; a glossary of 50,000 generated terms, loaded through Atlas's bulk API, 2,000 of them
# attached to the columns. Then 50 calls of describe_table at once, as carol_analyst, at the
# expiry of the caches: the server's memory stays under its two cache limits plus 256 MB,
# Atlas reads the table once and each term once for the whole burst, as its own audit log
# counts, and every answer keeps its context under MCP_CONTEXT_RESPONSE_CHARS and says it was
# cut. Last, the statements each tool runs in Trino, read from Trino's own query history.
# tests/compose.load.yaml sets the caches' lifetimes and limits; the script reads them back
# from the server.
# Removes everything at the end unless KEEP=1. Uses the sandbox's host ports unless told
# otherwise.
#
#   MCP_IMAGE=<image of 0.8> tests/load.sh
#   COMPOSE_PROJECT_NAME=akko-load KEYCLOAK_PORT=18680 MCP_PORT=13200 INSPECTOR_PORT=16474 ATLAS_PORT=21200 tests/load.sh
#
# Each check can be seen to fail. LOAD_CALLS (50) and LOAD_SPREAD_SECONDS (0) change the burst;
# with LOAD_CACHE_BYTES=1 LOAD_TERMS_CACHE_BYTES=1, nothing is cached, and a burst spread out
# makes Atlas read the table once per call. LOAD_MEMORY_MARGIN_MB (256) and
# LOAD_RESPONSE_LIMIT (the server's) change the bounds the answers are checked against.
# LOAD_MAX_CONCURRENCY=32, the server's default, leaves the calls past 32 without context.
set -uo pipefail
cd "$(dirname "$0")/.."
export COMPOSE_PROFILES=catalogs
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-akko-sandbox-load}"
export COMPOSE_FILE=compose.yaml:catalogs/compose.atlas.yaml:tests/compose.load.yaml
calls=${LOAD_CALLS:-50}
spread=${LOAD_SPREAD_SECONDS:-0}
margin_mb=${LOAD_MEMORY_MARGIN_MB:-256}
failed=0
# Scratch files: the answers, the memory samples, the logs read. Removed at the end, unless
# KEEP=1.
scratch=$(mktemp -d)
check() { if [ "$2" = "$3" ]; then printf '  OK    %s\n' "$1"; else printf '  FAIL  %s (got %s, expected %s)\n' "$1" "$2" "$3"; failed=1; fi; }
# What the run starts, stopped at the end whatever happens, KEEP=1 and Ctrl-C included: the
# sampler of the server's memory.
sampler=""
cleanup() {
  if [ -n "$sampler" ]; then kill "$sampler" 2>/dev/null; wait "$sampler" 2>/dev/null; echo "== end of run: the memory sampler stopped"; fi
  if [ "${KEEP:-0}" = "1" ]; then echo "KEEP=1: project $COMPOSE_PROJECT_NAME left running, the answers and samples kept in $scratch"; return; fi
  rm -rf "$scratch"
  docker compose --profile catalogs --profile tools down -v --remove-orphans >/dev/null 2>&1
  echo "== project $COMPOSE_PROJECT_NAME removed: $(docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" | wc -l) containers, $(docker volume ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" | wc -l) volumes left"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# A Python expression on the JSON read from stdin, as d; prints nothing on bad JSON.
field() { python3 -c "
import os, sys, json
try: d = json.load(sys.stdin)
except ValueError: sys.exit(0)
try: print(eval(sys.argv[1], {'os': os, 'json': json}, {'d': d}))
except Exception: pass" "$1"; }
# A Python expression on the JSON lines read from stdin, as rows.
rows() { python3 -c "
import sys, json
rows = [json.loads(l) for l in sys.stdin if l.strip().startswith('{')]
try: print(eval(sys.argv[1], {'json': json}, {'rows': rows}))
except Exception as e: print('error:', type(e).__name__)" "$1"; }
# The memory the host still has for new work, from the kernel; empty off Linux.
available() { awk '/^MemAvailable:/ {printf "%.1f GiB available on the host\n", $2 / 1048576}' /proc/meminfo 2>/dev/null; }
# One statement in Trino as alice_admin, from the back network; prints its rows as JSON.
sql() {
  docker compose exec -T history python -c "
import httpx, json, sys
kw = dict(headers={'Authorization': 'Bearer ' + sys.argv[1]}, verify='/certs/ca.crt', timeout=300)
r = httpx.post('https://trino:8443/v1/statement', content=sys.argv[2], **kw).json()
data = []
while True:
    data += r.get('data', [])
    if 'nextUri' not in r: break
    r = httpx.get(r['nextUri'], **kw).json()
print(json.dumps({'error': r['error']['errorName']} if 'error' in r else data))
" "$(./token.sh alice_admin trino-cli)" "$1"
}
# Calls of one tool as carol_analyst through tests/load/burst.py, one JSON line per call.
burst() { # tool, arguments as JSON, number of calls, seconds between two starts
  docker compose exec -T -e TOKEN="$(./token.sh carol_analyst)" history python /load/burst.py http://mcp:3000/mcp "$@"
}
# Every query Trino holds, as the admin reads it: system.runtime.queries (user, source,
# query) and the client tags of the same query in the coordinator's /v1/query.
history() {
  docker compose exec -T history python -c "
import httpx, json, sys
kw = dict(headers={'Authorization': 'Bearer ' + sys.argv[1]}, verify='/certs/ca.crt', timeout=60)
base = 'https://trino:8443'
tags = {q['queryId']: q['session'].get('clientTags', []) for q in httpx.get(base + '/v1/query', **kw).json()}
r = httpx.post(base + '/v1/statement', content='SELECT query_id, \"user\", source, query FROM system.runtime.queries', **kw).json()
while True:
    for qid, user, source, query in r.get('data', []):
        print(json.dumps({'query_id': qid, 'user': user, 'source': source, 'query': query, 'tags': tags.get(qid)}))
    if 'nextUri' not in r: break
    r = httpx.get(r['nextUri'], **kw).json()
if 'error' in r: print(json.dumps({'error': r['error']['errorName']}))
" "$(./token.sh alice_admin trino-cli)"
}
# Atlas's audit log: each request it served, one line each, after the login.
audit() { docker compose exec -T atlas cat /data/logs/audit.log 2>/dev/null; }
# What Atlas holds, read as admin inside its container (the password never leaves it).
atlas_get() { # path, then a Python expression on the JSON answer, as d
  docker compose exec -T atlas sh -c 'curl -fsS -u "admin:$(cat /secrets/admin.secret)" "http://127.0.0.1:21000$0"' "$1" | field "$2"
}
# Seconds since the epoch, with a fraction.
now() { python3 -c "import time; print(time.time())"; }
# Waits until the caches filled at $1 (epoch seconds) have all expired: their lifetime is
# drawn within ten percent of it, so 1.1 times it, and 2 s more.
wait_expiry() { python3 -c "import sys, time; time.sleep(max(0, float(sys.argv[1]) + 1.1 * float(sys.argv[2]) + 2 - time.time()))" "$1" "$ttl"; }

echo "== 1. Start (project $COMPOSE_PROJECT_NAME, ${MCP_IMAGE:-default image})"
echo "  host: $(getconf _NPROCESSORS_ONLN) processors, $(awk '/^MemTotal:/ {printf "%.1f GiB", $2 / 1048576}' /proc/meminfo 2>/dev/null) of memory; $(available)"
if ! diff <(grep -v '^#' trino/etc/catalog/demo.properties) <(grep -v '^#' tests/load/catalog/demo.properties) >/dev/null; then
  echo "  tests/load/catalog/demo.properties differs from trino/etc/catalog/demo.properties"; exit 1
fi
start=$(date +%s)
if ! docker compose up -d --build --wait --wait-timeout 900; then
  docker compose ps -a; docker compose logs --tail 40 mcp atlas atlas-seed; exit 1
fi
echo "  all services healthy in $(( $(date +%s) - start )) s"
docker compose --profile catalogs --profile tools up -d history >/dev/null 2>&1 || { echo "  the checks' client did not start"; exit 1; }
for s in mcp atlas trino; do
  echo "  $s: $(docker inspect -f '{{.Config.Image}} {{.Image}}' "$(docker compose ps -q $s)" | cut -c1-90)"
done
echo "  server: $(docker compose exec -T mcp akko-mcp-trino --version 2>&1 | tail -1)"
checked=$(docker compose exec -T mcp akko-mcp-trino --check 2>&1)
grep '^context:\|^visibility:\|^atlas: catalogs\|^atlas: glossaries\|^atlas: timeouts\|^atlas: term reads' <<<"$checked" | sed 's/^/  /'
# The settings the run is checked against, as the server prints them.
setting() { sed -nE "s/^context: .*$1.*/\\1/p" <<<"$checked"; }
ttl=$(setting 'ttl ([0-9.]+) s')
cache_bytes=$(setting 'caches ([0-9]+) \+ [0-9]+ bytes')
terms_cache_bytes=$(setting 'caches [0-9]+ \+ ([0-9]+) bytes')
response_chars=$(setting 'response ([0-9]+) characters')
check "the server read its settings: lifetime, the two cache limits, the response limit" "$([ -n "$ttl" ] && [ -n "$cache_bytes" ] && [ -n "$terms_cache_bytes" ] && [ -n "$response_chars" ] && echo yes)" "yes"
echo "  MCP_CONTEXT_CACHE_BYTES=$cache_bytes MCP_CONTEXT_TERMS_CACHE_BYTES=$terms_cache_bytes MCP_CONTEXT_TTL_SECONDS=$ttl MCP_CONTEXT_RESPONSE_CHARS=$response_chars"

echo "== 2. The wide table, in Trino and in Atlas"
columns=$(python3 -c "print(', '.join('c%04d varchar' % i for i in range(1, 2001)))")
values=$(python3 -c "print(', '.join(\"concat('v%04d-', CAST(n AS varchar))\" % i for i in range(1, 2001)))")
sql "CREATE SCHEMA IF NOT EXISTS wide.load" >/dev/null
if [ "$(sql "SELECT count(*) FROM wide.information_schema.tables WHERE table_schema = 'load' AND table_name = 'wide_2000'")" != "[[1]]" ]; then
  sql "CREATE TABLE wide.load.wide_2000 ($columns)" >/dev/null
  sql "INSERT INTO wide.load.wide_2000 SELECT $values FROM UNNEST(sequence(1, 20)) AS t(n)" >/dev/null
fi
check "Trino: wide.load.wide_2000, 2000 columns, 20 rows" "$(sql "SELECT count(*) FROM wide.information_schema.columns WHERE table_schema = 'load' AND table_name = 'wide_2000'") $(sql "SELECT count(*) FROM wide.load.wide_2000")" "[[2000]] [[20]]"
echo "  before the seed: $(available)"
start=$(date +%s)
docker compose --profile catalogs --profile tools run --rm --no-deps load-seed 2>&1 | sed 's/^/  seed: /'
echo "  the seed took $(( $(date +%s) - start )) s end to end"
echo "  after the seed: $(available)"
glossary=$(atlas_get /api/atlas/v2/glossary '[g["guid"] for g in d if g["name"] == "Generated"][0]')
check "Atlas: the glossary Generated holds 50000 terms" "$(atlas_get "/api/atlas/v2/glossary/$glossary" 'len(d.get("terms", []))')" "50000"
check "Atlas: wide_2000 lists 2000 columns, each described, 2000 with one term" "$(atlas_get '/api/atlas/v2/entity/uniqueAttribute/type/hive_table?attr:qualifiedName=load.wide_2000@sandbox' '(len(d["entity"]["attributes"]["columns"]), sum(1 for e in d["referredEntities"].values() if e["typeName"] == "hive_column" and e["attributes"].get("userDescription")), sum(1 for e in d["referredEntities"].values() if e["typeName"] == "hive_column" and len(e.get("relationshipAttributes", {}).get("meanings") or []) == 1))')" "(2000, 2000, 2000)"

echo "== 3. One call, which fills the caches"
args='{"catalog": "wide", "schema": "load", "table": "wide_2000"}'
burst describe_table "$args" 1 > "$scratch/first"
filled=$(rows 'rows[0]["end"]' < "$scratch/first")
echo "  describe_table answered in $(rows 'round(rows[0]["end"] - rows[0]["start"], 2)' < "$scratch/first") s, caches empty"
out=$(rows 'rows[0]["text"]' < "$scratch/first")
check "carol, describe_table wide_2000: 2000 columns, the context of Atlas, cut" "$(field '(len(d["rows"]), d["context_sources"], d["context_truncated"])' <<<"$out")" "(2000, {'atlas': 'partial'}, True)"
check "  each column described or listed as undescribed, once" "$(field 'sorted(list(d["column_context"]) + d["undescribed_columns"]) == [r[0] for r in d["rows"]]' <<<"$out")" "True"
check "  each column described carries its description and its own term of Generated" "$(field 'all(c["description"] == "Generated column number %d of the wide table" % int(n[1:]) and [t["name"] for t in c["terms"]] == ["Generated term %05d" % int(n[1:])] for n, c in d["column_context"].items())' <<<"$out")" "True"
echo "  $(field '"%d columns described, %d undescribed, %d terms, context of %d characters" % (len(d["column_context"]), len(d["undescribed_columns"]), len(d["terms"]), len(json.dumps({k: d[k] for k in ("table", "column_context", "terms")})))' <<<"$out")"
# The cache's own count: what the server holds for Atlas, by its metrics.
metrics() { docker compose exec -T mcp python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:3001/metrics').read().decode())" 2>/dev/null | grep "$1" | grep -v '^#'; }
echo "  the server's metrics: $(metrics 'context_cache_bytes' | tr '\n' ' ')"

echo "== 4. $calls calls of describe_table at once, at the caches' expiry"
echo "  waiting for the caches to expire: $ttl s, drawn within ten percent, from the end of the first call"
wait_expiry "$filled"
echo "  before the burst: $(available)"
mcp_id=$(docker compose ps -q mcp)
# The server's memory, by docker stats, about once a second while the burst runs.
( while true; do docker stats --no-stream --format '{{.MemUsage}}' "$mcp_id" 2>/dev/null | cut -d/ -f1; done ) > "$scratch/memory" &
sampler=$!
sleep 2
audit_before=$(audit | wc -l)
burst describe_table "$args" "$calls" "$spread" > "$scratch/burst"
sleep 2
kill "$sampler" 2>/dev/null; wait "$sampler" 2>/dev/null; sampler=""
peak=$(docker compose exec -T mcp cat /sys/fs/cgroup/memory.peak 2>/dev/null | tr -d '\r')
audit | tail -n +$((audit_before + 1)) | grep '|mcp_reader|' > "$scratch/audit"
echo "  the burst took $(rows 'round(max(r["end"] for r in rows) - min(r["start"] for r in rows), 2)' < "$scratch/burst") s; each call $(rows '"%.2f s to %.2f s" % (min(r["end"] - r["start"] for r in rows), max(r["end"] - r["start"] for r in rows))' < "$scratch/burst")"
check "$calls answers, none an error" "$(rows '(len(rows), [r["i"] for r in rows if r["error"] or "error" in json.loads(r["text"])])' < "$scratch/burst")" "($calls, [])"
# The bytes docker stats prints, in MiB.
mib() { python3 -c "
import re, sys
units = {'B': 1 / 1048576, 'KiB': 1 / 1024, 'MiB': 1, 'GiB': 1024}
values = [float(m.group(1)) * units[m.group(2)] for m in (re.match(r'([0-9.]+)(B|KiB|MiB|GiB)', l.strip()) for l in sys.stdin) if m]
print('%d %.1f' % (len(values), max(values)) if values else '0 0')"; }
read -r samples top <<<"$(mib < "$scratch/memory")"
bound=$(python3 -c "import sys; print('%.1f' % ((int(sys.argv[1]) + int(sys.argv[2])) / 1048576 + int(sys.argv[3])))" "$cache_bytes" "$terms_cache_bytes" "$margin_mb")
echo "  the server's memory: at most $top MiB in $samples samples of docker stats; cgroup peak since start $(python3 -c "import sys; print('%.1f MiB' % (int(sys.argv[1]) / 1048576))" "${peak:-0}"); bound $bound MiB (the two caches + $margin_mb MB)"
check "  docker stats sampled the burst, at least 5 times" "$([ "$samples" -ge 5 ] && echo yes)" "yes"
check "the server's memory stayed under the bound, by docker stats" "$(python3 -c "import sys; print(float(sys.argv[1]) < float(sys.argv[2]))" "$top" "$bound")" "True"
check "  and by its cgroup's peak since it started" "$(python3 -c "import sys; print(0 < int(sys.argv[1]) / 1048576 < float(sys.argv[2]))" "${peak:-0}" "$bound")" "True"
check "  the server was neither restarted nor killed" "$(docker inspect -f '{{.RestartCount}} {{.State.OOMKilled}} {{.State.Running}}' "$mcp_id")" "0 false true"
check "no service was killed for lack of memory" "$(docker inspect -f '{{.Name}} {{.State.OOMKilled}}' $(docker compose ps -aq) | grep -c ' true$')" "0"
tables=$(grep -c 'uniqueAttribute/type/[a-z_]*?attr_0%3AqualifiedName=load\.wide_2000%40sandbox' "$scratch/audit")
check "Atlas read the table once for the whole burst (its audit log)" "$tables" "1"
check "  and each of the 2000 terms once: reads, distinct terms" "$(grep -o 'glossary/term/[0-9a-f-]*' "$scratch/audit" | sort | uniq -c | awk '{n += $1; d += 1} END {print n + 0, d + 0}')" "2000 2000"
check "  and nothing else" "$(grep -v 'uniqueAttribute/type/\|glossary/term/' "$scratch/audit" | grep -c .)" "0"
limit=${LOAD_RESPONSE_LIMIT:-$response_chars}
size='len(json.dumps({k: json.loads(r["text"])[k] for k in ("table", "column_context", "terms")}))'
echo "  the context of each answer: $(rows "'%d to %d characters' % (min($size for r in rows), max($size for r in rows))" < "$scratch/burst"), limit $limit"
check "every context under the limit" "$(rows "[r['i'] for r in rows if $size > $limit]" < "$scratch/burst")" "[]"
check "  and every answer says it was cut, its source partial" "$(rows 'sorted({(json.loads(r["text"])["context_truncated"], len(json.loads(r["text"])["undescribed_columns"]) > 0, json.dumps(json.loads(r["text"])["context_sources"])) for r in rows})' < "$scratch/burst")" "[(True, True, '{\"atlas\": \"partial\"}')]"
check "  and the same context in each" "$(rows 'len({json.dumps({k: json.loads(r["text"])[k] for k in ("table", "column_context", "terms", "undescribed_columns")}, sort_keys=True) for r in rows})' < "$scratch/burst")" "1"

echo "== 5. The statements of each tool in Trino, from its query history"
# Each tool once with the caches expired, then once again at once, as carol_analyst; the
# statements are those of her queries that Trino did not hold before the call.
declare -A measured
for tool in describe_table describe_schema search_columns profile_table; do
  case $tool in
    describe_table) a=$args ;;
    describe_schema) a='{"catalog": "wide", "schema": "load"}' ;;
    search_columns) a='{"text": "c1999", "catalog": "wide"}' ;;
    profile_table) a=$args ;;
  esac
  wait_expiry "$(now)"
  for when in cold warm; do
    history > "$scratch/before"
    burst "$tool" "$a" 1 > "$scratch/one"
    history > "$scratch/after"
    error=$(rows 'rows[0]["error"] or json.loads(rows[0]["text"]).get("error")' < "$scratch/one")
    new=$(python3 -c "
import json, sys
before = {json.loads(l).get('query_id') for l in open(sys.argv[1])}
new = [r for r in map(json.loads, open(sys.argv[2])) if r.get('user') == 'carol_analyst' and r['query_id'] not in before]
print(len(new), sum(1 for r in new if 'mcp-gate' in (r['tags'] or [])), ','.join(sorted({r['source'] or '-' for r in new})))" "$scratch/before" "$scratch/after")
    read -r n gate source <<<"$new"
    measured[$tool.$when]="$n ($gate mcp-gate)"
    check "$tool, $when: answered, and its statements are in Trino's history" "$error $([ "${n:-0}" -gt 0 ] && echo yes)" "None yes"
    echo "  $tool, $when: $n statements, $gate of them tagged mcp-gate, source $source"
  done
done
echo "  | Tool | Caches expired | Right after |"
echo "  |---|---|---|"
for tool in describe_table describe_schema search_columns profile_table; do
  echo "  | \`$tool\` | ${measured[$tool.cold]} | ${measured[$tool.warm]} |"
done
echo "  at the end: $(available)"

[ $failed -eq 0 ] && echo "== LOAD OK ==" || { echo "== LOAD FAILED =="; exit 1; }
