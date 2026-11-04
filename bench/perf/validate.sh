#!/usr/bin/env bash
# The k6 script (bench/perf/mcp.js) checked against the MCP Inspector, before any
# measure: the ten calls of bench/perf/calls.json, as carol_analyst, once by the
# Inspector CLI and once by k6, each in a fresh session; the ten answers must be the
# same JSON once durations and ids are removed. Then k6 plays them again with one
# session per virtual user, as a load does, and still gets the same answers. Writes
# k6's latencies (p50, p95, p99) to $BENCH_EVIDENCE/k6-validate.metrics.json.
# Removes everything at the end unless KEEP=1. Played by bench/run.sh perf.
#
#   bench/perf/validate.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-akko-bench-k6-validate}"
export COMPOSE_FILE=compose.yaml
K6_IMAGE=${K6_IMAGE:-grafana/k6:1.3.0}
failed=0
ev=${BENCH_EVIDENCE:+$BENCH_EVIDENCE/k6-validate}
ev=${ev:-$(mktemp -d)}
mkdir -p "$ev" && chmod 0777 "$ev" && ev=$(cd "$ev" && pwd)
check() { if [ "$2" = "$3" ]; then printf '  OK    %s\n' "$1"; else printf '  FAIL  %s (got %s, expected %s)\n' "$1" "$2" "$3"; failed=1; fi; }
cleanup() {
  [ -z "${BENCH_EVIDENCE:-}" ] && rm -rf "$ev"
  if [ "${KEEP:-0}" = "1" ]; then echo "KEEP=1: project $COMPOSE_PROJECT_NAME left running"; return; fi
  docker compose --profile tools down -v --remove-orphans >/dev/null 2>&1
  echo "== project $COMPOSE_PROJECT_NAME removed: $(docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" | wc -l) containers left"
}
trap cleanup EXIT
n=$(python3 -c "import json; print(len(json.load(open('bench/perf/calls.json'))))")

k6() { # name, then -e options: runs mcp.js on the project's network
  local name=$1; shift
  docker run --rm --network "${COMPOSE_PROJECT_NAME}_default" --memory 256m \
    -v "$PWD/bench/perf:/bench:ro" -v "$ev:/out" -e TOKENS="$(./token.sh carol_analyst)" \
    -e CALLS_FILE=/bench/calls.json -e ECHO=1 -e SUMMARY="/out/$name-summary.json" "$@" \
    "$K6_IMAGE" run --quiet --console-output "/out/$name-console.txt" /bench/mcp.js > "$ev/$name.out" 2>&1
  echo $?
}
answers() { python3 bench/perf/k6_answers.py "$@"; }

echo "== 1. Start (project $COMPOSE_PROJECT_NAME), k6 $K6_IMAGE"
start=$(date +%s)
if ! docker compose up -d --wait --wait-timeout 420 >/dev/null 2>&1; then
  docker compose ps -a; docker compose logs --tail 40; exit 1
fi
echo "  all services healthy in $(( $(date +%s) - start )) s"
docker pull --quiet "$K6_IMAGE" >/dev/null

echo "== 2. The $n calls by the Inspector, each in its own session"
python3 -c "
import json
for c in json.load(open('bench/perf/calls.json')):
    print(c['tool'] + '\t' + '\t'.join(f'{k}={v}' for k, v in c['arguments'].items()))" |
while IFS=$'\t' read -r tool rest; do
  args=(); IFS=$'\t' read -ra kv <<<"$rest"; for a in "${kv[@]}"; do [ -n "$a" ] && args+=(--tool-arg "$a"); done
  docker compose exec -T inspector mcp-inspector --cli http://mcp:3000/mcp \
    --header "Authorization: Bearer $(./token.sh carol_analyst)" --method tools/call \
    --tool-name "$tool" "${args[@]}" 2>/dev/null </dev/null \
    | python3 bench/perf/k6_answers.py --inspector 2>/dev/null || echo null
done > "$ev/inspector.txt"
check "the Inspector got $n answers" "$(grep -vc '^null$' "$ev/inspector.txt")" "$n"

echo "== 3. The same calls by k6, a fresh session each"
check "k6 ran, a session per call" "$(k6 fresh -e SESSION=iteration -e VUS=1)" "0"
answers "$ev/fresh-console.txt" > "$ev/k6-fresh.txt"
check "k6 got $n answers" "$(grep -vc '^null$' "$ev/k6-fresh.txt")" "$n"
check "k6's answers are the Inspector's, once durations and ids are removed" "$(python3 bench/lib/leaks.py diff "$ev/inspector.txt" "$ev/k6-fresh.txt" > "$ev/diff-fresh.txt"; echo $?)" "0"
echo "  byte for byte, as sent, before any removal: $(paste "$ev/inspector.txt" "$ev/k6-fresh.txt" | awk -F'\t' '$1 == $2' | wc -l)/$n"
check "k6 counted no MCP error" "$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(int(d['metrics'].get('mcp_errors', {}).get('values', {}).get('count', 0)))" "$ev/fresh-summary.json")" "0"

echo "== 4. Again, one session per virtual user, two users"
check "k6 ran, a session per virtual user" "$(k6 kept -e SESSION=vu -e VUS=2 -e ITERATIONS=$(( 2 * n )))" "0"
check "every one of the $(( 2 * n )) answers is the Inspector's answer to its call" "$(answers "$ev/kept-console.txt" --against "$ev/inspector.txt")" "$(( 2 * n )) $(( 2 * n ))"
grep -h 'mcp_call_duration' "$ev/fresh.out" "$ev/kept.out" | sed 's/^/  /'
python3 -c "
import json, sys
out = {}
for name, label in (('fresh', 'k6 ran, a session per call'), ('kept', 'k6 ran, a session per virtual user')):
    try: v = json.load(open(f'{sys.argv[1]}/{name}-summary.json'))['metrics']['mcp_call_duration']['values']
    except (OSError, KeyError): continue
    out[label] = {'calls': int(v['count']), 'p50_ms': round(v['med'], 1), 'p95_ms': round(v['p(95)'], 1), 'p99_ms': round(v['p(99)'], 1)}
if '${BENCH_EVIDENCE:-}': json.dump(out, open('${BENCH_EVIDENCE:-}/${BENCH_SUITE:-k6-validate}.metrics.json', 'w'), indent=2)
print('  ' + json.dumps(out))" "$ev"

[ "$failed" = 0 ] && echo "== K6 VALIDATED" || echo "== SOME CHECKS FAILED"
exit "$failed"
