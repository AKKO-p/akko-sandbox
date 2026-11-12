#!/usr/bin/env bash
# The context from a data catalog of akko-mcp-trino 0.8 at scale, on a machine with Docker,
# against a real Apache Atlas 2.4.0 (catalogs/compose.atlas.yaml). Three tables of 2,000
# columns, wide.load.wide_2000, wide_2000_2 and wide_2000_3, in Trino's memory connector,
# which Atlas describes column by column; a glossary of 50,000 generated terms, loaded through
# Atlas's bulk API, 2,000 of them attached to the columns of each table.
#
# 1. Start, and read the server's settings back from its --check.
# 2. The tables in Trino, the catalog in Atlas.
# 3. The server's default time budgets (5 s), four calls of describe_table in a row with its
#    caches empty: what each call serves, and how long Atlas takes to read the table.
# 4. With the run's time budgets, one call that fills the caches.
# 5. 50 calls of describe_table at once, as carol_analyst, after the caches expired: the
#    server's memory stays under its three cache limits plus 256 MiB; Atlas reads the table
#    once and each term once, as its own audit log counts; more calls than the read slots
#    waited on that read or sent it, by the server's cache lookups; the windows of at least
#    90 % of the calls overlap it; every answer keeps its context under MCP_CONTEXT_RESPONSE_CHARS
#    and says it was cut.
# 6. The statements each tool runs in Trino, read from Trino's own query history.
# 7. Small cache limits (512 KiB for tables, 256 KiB for terms), and the three tables read in
#    turn: the caches stay under their limits, the first table and its terms are evicted and
#    read again, the last one is still cached, and the memory stays under the new bound.
#
# tests/compose.load.yaml sets the caches' lifetimes and limits; the script reads them back
# from the server. Removes everything at the end unless KEEP=1. Uses the sandbox's host ports
# unless told otherwise. The Atlas image is built when it is absent; after a change to
# catalogs/atlas, rebuild it with docker compose build atlas. A KEEP=1 run is rerun on the
# same Atlas, without seeding it again.
#
#   MCP_IMAGE=<image of 0.8> tests/load.sh
#   COMPOSE_PROJECT_NAME=akko-load KEYCLOAK_PORT=18680 MCP_PORT=13200 INSPECTOR_PORT=16474 ATLAS_PORT=21200 tests/load.sh
#
# Each check can be made to fail. LOAD_CALLS (50) and LOAD_SPREAD_SECONDS (0) change the burst;
# LOAD_BURST_ONLY=1 stops after it, for a witness run. LOAD_OPA_MEMORY=64m gives OPA the
# sandbox's own limit.
# With LOAD_CACHE_BYTES=1 LOAD_TERMS_CACHE_BYTES=1, nothing is cached: in a burst at once,
# the calls that reach the context while the table is read wait on that read, and those
# that reach it after the read ended read it again (twice for 50 calls, measured); a burst
# spread out makes Atlas read the table once per call. LOAD_MEMORY_MARGIN_MB (256, in MiB) and
# LOAD_RESPONSE_LIMIT (the server's) change the bounds the answers are checked against;
# LOAD_RESPONSE_CHARS changes the server's own limit.
set -uo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.." || exit 1
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
# sampler of the server's memory, and the calls a burst still has in flight.
sampler=""
bursting=0
cleanup() {
  if [ -n "$sampler" ]; then kill "$sampler" 2>/dev/null; wait "$sampler" 2>/dev/null; echo "== end of run: the memory sampler stopped"; fi
  if [ "$bursting" = 1 ]; then
    docker compose exec -T history python -c "
import os, signal
for p in filter(str.isdigit, os.listdir('/proc')):
    try:
        if b'burst.py' in open('/proc/%s/cmdline' % p, 'rb').read(): os.kill(int(p), signal.SIGTERM)
    except OSError: pass" >/dev/null 2>&1
    echo "== end of run: the calls in flight stopped"
  fi
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
import sys, json, collections
rows = [json.loads(l) for l in sys.stdin if l.strip().startswith('{')]
try: print(eval(sys.argv[1], {'json': json, 'collections': collections}, {'rows': rows}))
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
# The arguments of describe_table for one table of the schema load.
table_args() { printf '{"catalog": "wide", "schema": "load", "table": "%s"}' "$1"; }
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
# What Atlas holds, read as admin inside its container (the password never leaves it).
atlas_get() { # path, then a Python expression on the JSON answer, as d
  docker compose exec -T atlas sh -c 'curl -fsS --cacert /certs/ca.crt -u "admin:$(cat /secrets/admin.secret)" "https://127.0.0.1:21000$0"' "$1" | field "$2"
}
# Atlas's audit log writes one line for each request it served, after the login:
#   <log time> [...] INFO [AuditFilter.java:140] <start, UTC>|<user>|<address>|<method>|<URL>|<status>|<ms>
# mark writes a marker into it, a request as admin, named for this run; audit_between prints
# the server's requests between two markers, once the second one is written.
run_id="$$-$(date +%s)"
mark() {
  docker compose exec -T atlas sh -c 'curl -fsS -o /dev/null --cacert /certs/ca.crt -u "admin:$(cat /secrets/admin.secret)" "https://127.0.0.1:21000/api/atlas/admin/version?load_marker=$0"' "$1-$run_id" \
    || { echo "  Atlas did not answer the marker $1" >&2; exit 1; }
}
audit_between() { # first marker, second marker
  for _ in $(seq 1 30); do
    docker compose exec -T atlas cat /data/logs/audit.log 2>/dev/null > "$scratch/audit.log"
    grep -q "load_marker=$2-$run_id|" "$scratch/audit.log" && break
    sleep 1
  done
  # A slice without both markers would be empty, and a check of no read would pass on it.
  for m in "$1" "$2"; do
    grep -q "load_marker=$m-$run_id|" "$scratch/audit.log" || { echo "  the marker $m is missing from Atlas's audit log" >&2; exit 1; }
  done
  awk -v a="load_marker=$1-$run_id|" -v b="load_marker=$2-$run_id|" 'index($0, a) {on = 1; next} index($0, b) {on = 0} on' "$scratch/audit.log" | grep '|mcp_reader|'
}
# The server's reads of one table, and of glossary terms, in audit lines read from stdin.
table_reads() { grep -cE "uniqueAttribute/type/[a-z_]+\\?(.*&)?attr_[0-9]+%3AqualifiedName=load\\.$1%40sandbox(&|\\||$)"; }
term_reads() { grep -o 'glossary/term/[0-9a-f-]*' | sort | uniq -c | awk '{n += $1; d += 1} END {print n + 0, d + 0}'; }
# The time Atlas took for each read of one table, in the audit lines read from stdin.
read_times() { grep -E "qualifiedName=load\\.$1%40sandbox(&|\\||$)" | awk -F'|' '{printf "%s%.2f s", sep, $NF / 1000; sep = ", "} END {print ""}'; }
# The sum of one metric of the server, over its labels.
metric() { docker compose exec -T mcp python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:3001/metrics').read().decode())" 2>/dev/null | awk -v m="$1" 'index($0, m) == 1 {n += $NF} END {printf "%d\n", n}'; }
# Seconds since the epoch, with a fraction.
now() { python3 -c "import time; print(time.time())"; }
# Waits until the caches filled at $1 (epoch seconds) have all expired: their lifetime is
# drawn within ten percent of it, so 1.1 times it, and 2 s more.
wait_expiry() { python3 -c "import sys, time; time.sleep(max(0, float(sys.argv[1]) + 1.1 * float(sys.argv[2]) + 2 - time.time()))" "$1" "$ttl"; }
# The server's settings, as its --check prints them.
read_settings() {
  checked=$(docker compose exec -T mcp akko-mcp-trino --check 2>&1)
  setting() { sed -nE "s/^$1: .*$2.*/\\1/p" <<<"$checked"; }
  ttl=$(setting context 'ttl ([0-9.]+) s')
  cache_bytes=$(setting context 'caches ([0-9]+) \+ [0-9]+ bytes')
  terms_cache_bytes=$(setting context 'caches [0-9]+ \+ ([0-9]+) bytes')
  response_chars=$(setting context 'response ([0-9]+) characters')
  in_flight=$(setting context ' ([0-9]+) reads in flight')
  visibility_bytes=$(setting visibility 'cache ([0-9]+) bytes')
}
# Restarts the server with the settings given as LOAD_*=value, the others as the run has them.
restart_mcp() {
  if ! env "$@" docker compose up -d --no-deps --wait --wait-timeout 300 mcp >/dev/null 2>&1; then
    echo "  the server did not start again"; docker compose logs --tail 20 mcp; exit 1
  fi
  read_settings
  mcp_id=$(docker compose ps -q mcp)
}
# The server's memory, by docker stats, about once a second, until stop_sampler.
start_sampler() {
  ( while true; do docker stats --no-stream --format '{{.MemUsage}}' "$mcp_id" 2>/dev/null | cut -d/ -f1; done ) > "$scratch/memory" &
  sampler=$!
}
stop_sampler() { kill "$sampler" 2>/dev/null; wait "$sampler" 2>/dev/null; sampler=""; }
# The bytes docker stats prints, in MiB: the number of samples and the largest.
mib() { python3 -c "
import re, sys
units = {'B': 1 / 1048576, 'KiB': 1 / 1024, 'MiB': 1, 'GiB': 1024}
values = [float(m.group(1)) * units[m.group(2)] for m in (re.match(r'([0-9.]+)(B|KiB|MiB|GiB)', l.strip()) for l in sys.stdin) if m]
print('%d %.1f' % (len(values), max(values)) if values else '0 0')"; }
# Checks the server's memory against its three cache limits plus the margin, in MiB.
check_memory() {
  local samples top peak bound
  peak=$(docker compose exec -T mcp cat /sys/fs/cgroup/memory.peak 2>/dev/null | tr -d '\r')
  read -r samples top <<<"$(mib < "$scratch/memory")"
  bound=$(python3 -c "import sys; print('%.1f' % (sum(map(int, sys.argv[1:4])) / 1048576 + int(sys.argv[4])))" "$cache_bytes" "$terms_cache_bytes" "$visibility_bytes" "$margin_mb")
  echo "  the server's memory: at most $top MiB in $samples samples of docker stats; cgroup peak since start $(python3 -c "import sys; print('%.1f MiB' % (int(sys.argv[1]) / 1048576))" "${peak:-0}"); bound $bound MiB (the three caches + $margin_mb MiB)"
  check "  docker stats sampled it, at least 5 times" "$([ "$samples" -ge 5 ] && echo yes || echo no)" "yes"
  check "the server's memory stayed under the bound, by docker stats" "$(python3 -c "import sys; print(float(sys.argv[1]) < float(sys.argv[2]))" "$top" "$bound")" "True"
  check "  and by its cgroup's peak since it started" "$(python3 -c "import sys; print(0 < int(sys.argv[1]) / 1048576 < float(sys.argv[2]))" "${peak:-0}" "$bound")" "True"
  check "  the server was neither restarted nor killed" "$(docker inspect -f '{{.RestartCount}} {{.State.OOMKilled}} {{.State.Running}}' "$mcp_id")" "0 false true"
}

echo "== 1. Start (project $COMPOSE_PROJECT_NAME, ${MCP_IMAGE:-default image})"
echo "  host: $(getconf _NPROCESSORS_ONLN) processors, $(awk '/^MemTotal:/ {printf "%.1f GiB", $2 / 1048576}' /proc/meminfo 2>/dev/null) of memory; $(available)"
if ! diff <(grep -v '^#' trino/etc/catalog/demo.properties) <(grep -v '^#' tests/load/catalog/demo.properties) >/dev/null; then
  echo "  tests/load/catalog/demo.properties differs from trino/etc/catalog/demo.properties"; exit 1
fi
start=$(date +%s)
if ! docker compose up -d --wait --wait-timeout 900; then
  docker compose ps -a; docker compose logs --tail 40 mcp atlas atlas-seed; exit 1
fi
echo "  all services healthy in $(( $(date +%s) - start )) s"
docker compose --profile catalogs --profile tools up -d history >/dev/null 2>&1 || { echo "  the checks' client did not start"; exit 1; }
for s in mcp atlas trino opa keycloak postgres; do
  echo "  $s: $(docker inspect -f '{{.Config.Image}} {{.Image}}' "$(docker compose ps -q $s)" | cut -c1-90)"
done
echo "  server: $(docker compose exec -T mcp akko-mcp-trino --version 2>&1 | tail -1)"
read_settings
mcp_id=$(docker compose ps -q mcp)
grep '^context:\|^visibility:\|^atlas: catalogs\|^atlas: glossaries\|^atlas: timeouts\|^atlas: term reads' <<<"$checked" | sed 's/^/  /'
check "the server read its settings: lifetime, the three cache limits, the response limit, the reads in flight" "$([ -n "$ttl" ] && [ -n "$cache_bytes" ] && [ -n "$terms_cache_bytes" ] && [ -n "$visibility_bytes" ] && [ -n "$response_chars" ] && [ -n "$in_flight" ] && echo yes || echo no)" "yes"
echo "  MCP_CONTEXT_CACHE_BYTES=$cache_bytes MCP_CONTEXT_TERMS_CACHE_BYTES=$terms_cache_bytes MCP_VISIBILITY_CACHE_BYTES=$visibility_bytes MCP_CONTEXT_TTL_SECONDS=$ttl MCP_CONTEXT_RESPONSE_CHARS=$response_chars MCP_CONTEXT_MAX_CONCURRENCY=$in_flight"
# The burst tests that calls waiting on a read in flight take no read slot: it must be
# larger than the slots, unless LOAD_CALLS makes it smaller on purpose.
if [ -z "${LOAD_CALLS:-}" ]; then
  check "the burst is larger than the reads in flight: $calls calls, $in_flight reads" "$([ "$calls" -gt "${in_flight:-0}" ] && echo yes || echo no)" "yes"
fi

echo "== 2. The wide tables, in Trino and in Atlas"
tables="wide_2000 wide_2000_2 wide_2000_3"
columns=$(python3 -c "print(', '.join('c%04d varchar' % i for i in range(1, 2001)))")
values=$(python3 -c "print(', '.join(\"concat('v%04d-', CAST(n AS varchar))\" % i for i in range(1, 2001)))")
sql "CREATE SCHEMA IF NOT EXISTS wide.load" >/dev/null
for t in $tables; do
  if [ "$(sql "SELECT count(*) FROM wide.information_schema.tables WHERE table_schema = 'load' AND table_name = '$t'")" != "[[1]]" ]; then
    sql "CREATE TABLE wide.load.$t ($columns)" >/dev/null
    sql "INSERT INTO wide.load.$t SELECT $values FROM UNNEST(sequence(1, 20)) AS t(n)" >/dev/null
  fi
  check "Trino: wide.load.$t, 2000 columns, 20 rows" "$(sql "SELECT count(*) FROM wide.information_schema.columns WHERE table_schema = 'load' AND table_name = '$t'") $(sql "SELECT count(*) FROM wide.load.$t")" "[[2000]] [[20]]"
done
echo "  before the seed: $(available)"
start=$(date +%s)
if ! docker compose --profile catalogs --profile tools run --rm --no-deps load-seed 2>&1 | sed 's/^/  seed: /'; then
  echo "  the seed failed"; exit 1
fi
echo "  the seed took $(( $(date +%s) - start )) s end to end"
echo "  after the seed: $(available)"

echo "== 3. The server's default time budgets, with its caches empty"
# Measured before anything else reads the tables, Atlas's own check below included.
restart_mcp LOAD_CONTEXT_TIMEOUT_SECONDS=5 LOAD_ATLAS_TIMEOUT_SECONDS=5
echo "  $(grep '^context:' <<<"$checked" | cut -d, -f1); $(grep '^atlas: timeouts' <<<"$checked")"
mark probe-start
for i in 1 2 3 4; do
  burst describe_table "$(table_args wide_2000)" 1 > "$scratch/probe"
  echo "  call $i: $(rows '"%.2f s, atlas %s" % (rows[0]["end"] - rows[0]["start"], json.loads(rows[0]["text"])["context_sources"].get("atlas", "-"))' < "$scratch/probe")"
done
mark probe-end
audit_between probe-start probe-end > "$scratch/audit"
echo "  Atlas's reads of wide_2000, by its audit log: $(read_times wide_2000 < "$scratch/audit")"
restart_mcp

echo "== 2 (continued). The catalog in Atlas"
glossary=$(atlas_get /api/atlas/v2/glossary '[g["guid"] for g in d if g["name"] == "Generated"][0]')
check "Atlas: the glossary Generated holds 50000 terms" "$(atlas_get "/api/atlas/v2/glossary/$glossary" 'len(d.get("terms", []))')" "50000"
for t in $tables; do
  check "Atlas: $t lists 2000 columns, each described, 2000 with one term" "$(atlas_get "/api/atlas/v2/entity/uniqueAttribute/type/hive_table?attr:qualifiedName=load.$t@sandbox" '(len(d["entity"]["attributes"]["columns"]), sum(1 for e in d["referredEntities"].values() if e["typeName"] == "hive_column" and e["attributes"].get("userDescription")), sum(1 for e in d["referredEntities"].values() if e["typeName"] == "hive_column" and len(e.get("relationshipAttributes", {}).get("meanings") or []) == 1))')" "(2000, 2000, 2000)"
done

echo "== 4. One call, which fills the caches"
args=$(table_args wide_2000)
mark first-start
burst describe_table "$args" 1 > "$scratch/first"
mark first-end
filled=$(rows 'rows[0]["end"]' < "$scratch/first")
audit_between first-start first-end > "$scratch/audit"
echo "  describe_table answered in $(rows 'round(rows[0]["end"] - rows[0]["start"], 2)' < "$scratch/first") s, caches empty; Atlas read the table in $(read_times wide_2000 < "$scratch/audit")"
out=$(rows 'rows[0]["text"]' < "$scratch/first")
attached=$(field 'len(d["rows"])' <<<"$out")
attached=${attached:-0}
check "carol, describe_table wide_2000: 2000 columns, the context of Atlas, cut" "$(field '(len(d["rows"]), d["context_sources"], d["context_truncated"])' <<<"$out")" "(2000, {'atlas': 'partial'}, True)"
check "  each column described or listed as undescribed, once" "$(field 'sorted(list(d["column_context"]) + d["undescribed_columns"]) == [r[0] for r in d["rows"]]' <<<"$out")" "True"
check "  each column described carries its description and its own term of Generated" "$(field 'all(c["description"] == "Generated column number %d of the wide table" % int(n[1:]) and [t["name"] for t in c["terms"]] == ["Generated term %05d" % int(n[1:])] for n, c in d["column_context"].items())' <<<"$out")" "True"
echo "  $(field '"%d columns described, %d undescribed, %d terms, context of %d characters" % (len(d["column_context"]), len(d["undescribed_columns"]), len(d["terms"]), len(json.dumps({k: d[k] for k in ("table", "column_context", "terms")})))' <<<"$out")"
echo "  the server's caches hold $(metric mcp_trino_context_cache_bytes) bytes (mcp_trino_context_cache_bytes)"

echo "== 5. $calls calls of describe_table at once, after the caches expired"
echo "  waiting for the caches to expire: $ttl s, drawn within ten percent, from the end of the first call"
wait_expiry "$filled"
echo "  before the burst: $(available)"
start_sampler
sleep 2
misses=$(metric 'mcp_trino_context_cache_lookups_total{provider="atlas",result="miss"}')
hits=$(metric 'mcp_trino_context_cache_lookups_total{provider="atlas",result="hit"}')
mark burst-start
bursting=1
burst describe_table "$args" "$calls" "$spread" > "$scratch/burst"
bursting=0
mark burst-end
sleep 2
stop_sampler
audit_between burst-start burst-end > "$scratch/audit"
echo "  the burst took $(rows 'round(max(r["end"] for r in rows) - min(r["start"] for r in rows), 2)' < "$scratch/burst") s; each call $(rows '"%.2f s to %.2f s" % (min(r["end"] - r["start"] for r in rows), max(r["end"] - r["start"] for r in rows))' < "$scratch/burst"); the calls started within $(rows '"%.2f s" % (max(r["start"] for r in rows) - min(r["start"] for r in rows))' < "$scratch/burst")"
misses=$(( $(metric 'mcp_trino_context_cache_lookups_total{provider="atlas",result="miss"}') - misses ))
hits=$(( $(metric 'mcp_trino_context_cache_lookups_total{provider="atlas",result="hit"}') - hits ))
# Each call looks up the table once, then once each term attached to the columns its answer
# lists: a call that finds the table missing either sends the read or waits on the one in
# flight; a call that finds it cached is a hit for all of them. Each column of the wide table
# holds one term (section 2 checks it), so the terms are the columns the first call listed.
per_call=$((1 + attached))
echo "  the server's cache lookups during the burst: $misses misses, $hits hits, $per_call a call (the table and $attached terms)"
echo "  $((misses / per_call)) calls waited on the read in flight or sent it, $((hits / per_call)) served from the cache"
# Calls that waited on the read take no read slot: the burst tests it only if more calls than
# the slots met the read in flight.
if [ -z "${LOAD_CALLS:-}" ]; then
  check "  more calls met the read in flight than there are read slots: $((misses / per_call)) > $in_flight" "$([ $((misses / per_call)) -gt "${in_flight:-0}" ] && echo yes || echo no)" "yes"
fi
check "$calls answers, none an error" "$(rows '(len(rows), [r["i"] for r in rows if r["error"] or "error" in json.loads(r["text"])])' < "$scratch/burst")" "($calls, [])"
echo "  the source of the context, answers by status: $(rows 'dict(sorted(collections.Counter(json.loads(r["text"])["context_sources"].get("atlas", "-") for r in rows).items()))' < "$scratch/burst")"
check_memory
mapfile -t containers < <(docker compose ps -aq)
check "no service was killed for lack of memory" "$(docker inspect -f '{{.Name}} {{.State.OOMKilled}}' "${containers[@]}" | grep -c ' true$')" "0"
check "Atlas read the table once for the whole burst (its audit log)" "$(table_reads wide_2000 < "$scratch/audit")" "1"
check "  and each of the 2000 terms once: reads, distinct terms" "$(term_reads < "$scratch/audit")" "2000 2000"
check "  and nothing else" "$(grep -vE "qualifiedName=load\\.wide_2000%40sandbox(&|\\||$)|glossary/term/" "$scratch/audit" | grep -c .)" "0"
# Atlas's first read of the table, from its start (UTC, in the audit line) to its end (start
# plus its time). A call's window, from its request to its answer, overlaps it when the call
# started before the read ended and ended after the read started. A window counts the call's
# whole time, Trino's DESCRIBE included, so a call served from the cache can overlap too.
overlap=$(python3 -c "
import datetime, json, re, sys
lines = [l for l in open(sys.argv[1]) if re.search(r'qualifiedName=load\.wide_2000%40sandbox(&|\||$)', l)]
calls = [json.loads(l) for l in open(sys.argv[2]) if l.startswith('{')]
if not lines: print('0 no read'); sys.exit()
fields = lines[0].split('AuditFilter.java:140] ', 1)[1].strip().split('|')
start = datetime.datetime.strptime(fields[0], '%Y-%m-%dT%H:%M:%S.%fZ').replace(tzinfo=datetime.timezone.utc).timestamp()
end = start + int(fields[-1]) / 1000
first = min(c['start'] for c in calls)
n = sum(1 for c in calls if c['start'] < end and c['end'] > start)
print(n, 'from %.2f s to %.2f s after the first call started' % (start - first, end - first))" "$scratch/audit" "$scratch/burst")
need=$(( (calls * 9 + 9) / 10 ))
echo "  Atlas's read of the table: ${overlap#* }; the windows of ${overlap%% *} of the $calls calls overlap it"
check "  the windows of at least $need of the $calls calls overlap that read (90 %)" "$([ "${overlap%% *}" -ge "$need" ] && echo yes || echo no)" "yes"
limit=${LOAD_RESPONSE_LIMIT:-$response_chars}
size='len(json.dumps({k: json.loads(r["text"])[k] for k in ("table", "column_context", "terms")}))'
echo "  the context of each answer: $(rows "'%d to %d characters' % (min($size for r in rows), max($size for r in rows))" < "$scratch/burst"), limit $limit"
check "every context under the limit" "$(rows "[r['i'] for r in rows if $size > $limit]" < "$scratch/burst")" "[]"
check "  and every answer says it was cut, its source partial" "$(rows 'sorted({(json.loads(r["text"])["context_truncated"], len(json.loads(r["text"])["undescribed_columns"]) > 0, json.dumps(json.loads(r["text"])["context_sources"])) for r in rows})' < "$scratch/burst")" "[(True, True, '{\"atlas\": \"partial\"}')]"
check "  and the same context in each" "$(rows 'len({json.dumps({k: json.loads(r["text"])[k] for k in ("table", "column_context", "terms", "undescribed_columns")}, sort_keys=True) for r in rows})' < "$scratch/burst")" "1"

if [ "${LOAD_BURST_ONLY:-0}" = 1 ]; then
  echo "  LOAD_BURST_ONLY=1: sections 6 and 7 left out"
  [ $failed -eq 0 ] && echo "== LOAD OK ==" || { echo "== LOAD FAILED =="; exit 1; }
  exit 0
fi

echo "== 6. The statements of each tool in Trino, from its query history"
# Each tool once with the caches expired, then once again at once, as carol_analyst; the
# statements are those of her queries that Trino did not hold before the call, read 1 s
# after the answer.
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
    sleep 1
    history > "$scratch/after"
    error=$(rows 'rows[0]["error"] or json.loads(rows[0]["text"]).get("error")' < "$scratch/one")
    new=$(python3 -c "
import json, sys
before = {json.loads(l).get('query_id') for l in open(sys.argv[1])}
new = [r for r in map(json.loads, open(sys.argv[2])) if r.get('user') == 'carol_analyst' and r['query_id'] not in before]
print(len(new), sum(1 for r in new if 'mcp-gate' in (r['tags'] or [])), ','.join(sorted({r['source'] or '-' for r in new})))" "$scratch/before" "$scratch/after")
    read -r n gate source <<<"$new"
    measured[$tool.$when]="$n ($gate mcp-gate)"
    check "$tool, $when: answered; its statements are in Trino's history, all from source trino-mcp" "$error $([ "${n:-0}" -gt 0 ] && echo yes || echo no) $source" "None yes trino-mcp"
    echo "  $tool, $when: $n statements, $gate of them tagged mcp-gate"
  done
done
echo "  | Tool | Caches expired | Right after |"
echo "  |---|---|---|"
for tool in describe_table describe_schema search_columns profile_table; do
  echo "  | \`$tool\` | ${measured[$tool.cold]} | ${measured[$tool.warm]} |"
done

echo "== 7. Small cache limits, overflowed by the three tables"
# Lifetimes of 600 s, so that nothing expires during this section: an entry missing at the
# end was evicted.
restart_mcp LOAD_CACHE_BYTES=524288 LOAD_TERMS_CACHE_BYTES=262144 LOAD_TTL_SECONDS=600
echo "  MCP_CONTEXT_CACHE_BYTES=$cache_bytes MCP_CONTEXT_TERMS_CACHE_BYTES=$terms_cache_bytes MCP_CONTEXT_TTL_SECONDS=$ttl"
check "the server runs with the small limits" "$cache_bytes $terms_cache_bytes $ttl" "524288 262144 600"
start_sampler
sleep 2
held=""
for t in $tables; do
  burst describe_table "$(table_args "$t")" 1 > "$scratch/one"
  held="$held $(metric mcp_trino_context_cache_bytes)"
  echo "  $t: $(rows '"%.2f s, atlas %s" % (rows[0]["end"] - rows[0]["start"], json.loads(rows[0]["text"])["context_sources"].get("atlas", "-"))' < "$scratch/one"); the caches hold $(echo $held | awk '{print $NF}') bytes"
done
mark again-last
burst describe_table "$(table_args wide_2000_3)" 1 > "$scratch/one"
mark again-first
burst describe_table "$(table_args wide_2000)" 1 > "$scratch/one"
mark again-end
held="$held $(metric mcp_trino_context_cache_bytes)"
sleep 2
stop_sampler
check "the caches held at most their two limits, $((cache_bytes + terms_cache_bytes)) bytes, after each call" "$(python3 -c "import sys; print(max(map(int, sys.argv[2:])) <= int(sys.argv[1]))" "$((cache_bytes + terms_cache_bytes))" $held)" "True"
audit_between again-last again-first > "$scratch/audit"
check "wide_2000_3, read last, is still cached: Atlas does not read it again" "$(table_reads wide_2000_3 < "$scratch/audit")" "0"
audit_between again-first again-end > "$scratch/audit"
check "wide_2000, read first, was evicted: Atlas reads it again" "$(table_reads wide_2000 < "$scratch/audit")" "1"
echo "  and its terms: $(term_reads < "$scratch/audit" | awk '{print $1 " reads, " $2 " distinct terms"}')"
check "  and its terms too, all 2000" "$(term_reads < "$scratch/audit")" "2000 2000"
check_memory
echo "  at the end: $(available)"

[ $failed -eq 0 ] && echo "== LOAD OK ==" || { echo "== LOAD FAILED =="; exit 1; }
