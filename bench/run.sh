#!/usr/bin/env bash
# The bench's one entry point: plays an axis, writes its dated result in
# bench/results/YYYY-MM-DD/, and holds it against the baseline of its pair (server
# minor version, model). Exit 0 when the gate passes, 1 on a regression, an
# improvement not written into the baseline, a case not run or not named, 3 when the
# host cannot hold the run (the preflight refused: nothing was started).
#
#   bench/run.sh security [--suite smoke,v07,...] [--image <ref>] [--seed <n>]
#   bench/run.sh perf [--image <ref>]
#   bench/run.sh correctness --rescore agent/reports/<report>.json
#   bench/run.sh correctness --provider mistral --model codestral-latest [--repeat 3] [--image <ref>]
#   BENCH_UPDATE_BASELINE=true bench/run.sh ...    writes the result as the baseline of its pair
#
# BENCH_SEED (or --seed) draws the leak suite's witness words; drawn at random when
# unset, always written in the result. BENCH_RESULTS_DIR and BENCH_EVIDENCE_DIR move
# bench/results and bench/evidence; BENCH_LOCK is the lock one run holds at a time.
#
# Runs on a Linux host with Docker, one run at a time. Each suite is its own compose
# project, akko-bench-<suite>, removed at its end; nothing else is stopped or
# removed. Model keys are read only from AGENT_ENV_FILE (default
# /root/secrets/agent.env), passed to the agent's container, never printed.
set -uo pipefail
cd "$(dirname "$0")/.."
bench=bench
axis=${1:?usage: bench/run.sh <security|perf|correctness> [options]}
shift
suites="" image="" rescore="" provider="" model="" repeat=3 seed=${BENCH_SEED:-}
while [ $# -gt 0 ]; do
  case "$1" in
    --suite) suites=${2//,/ }; shift 2 ;;
    --image) image=$2; shift 2 ;;
    --rescore) rescore=$2; shift 2 ;;
    --provider) provider=$2; shift 2 ;;
    --model) model=$2; shift 2 ;;
    --repeat) repeat=$2; shift 2 ;;
    --seed) seed=$2; shift 2 ;;
    *) echo "bench/run.sh: unknown option $1"; exit 2 ;;
  esac
done
results_dir=${BENCH_RESULTS_DIR:-$bench/results}
evidence_dir=${BENCH_EVIDENCE_DIR:-$bench/evidence}
export BENCH_SEED=${seed:-$(( (RANDOM << 15) | RANDOM ))}
command="bench/run.sh $axis${suites:+ --suite ${suites// /,}}${image:+ --image $image}${rescore:+ --rescore $rescore}${provider:+ --provider $provider}${model:+ --model $model}"
[ "$axis" = correctness ] && [ -z "$rescore" ] && command+=" --repeat $repeat"
[ "$axis" = correctness ] || command+=" --seed $BENCH_SEED"

gate() { # result file: the baseline written, or the gate played
  local result=$1
  [ -n "$result" ] && [ -f "$result" ] || { echo "bench: no result written"; return 1; }
  if [ "${BENCH_UPDATE_BASELINE:-false}" = "true" ]; then
    python3 $bench/compare.py baseline "$result"
  else
    python3 $bench/compare.py gate "$result"
  fi
}

# One bench run at a time on the host: the lock, held until the script exits.
lock() {
  exec 9> "${BENCH_LOCK:-/tmp/akko-bench.lock}"
  flock -n 9
}

# --- correctness: agent/run.py, rescored or run --------------------------------
if [ "$axis" = correctness ]; then
  if [ -n "$rescore" ]; then
    # record.py scores the report's trials again by agent/run.py's current rules.
    result=$(python3 $bench/lib/record.py correctness "$rescore" --rescored --command "$command" --out "$results_dir" | tail -1) || exit 1
    gate "$result"; exit $?
  fi
  [ -n "$provider" ] || { echo "bench/run.sh correctness: --provider or --rescore"; exit 2; }
  lock || { echo "bench: refused: another bench run holds the lock"; exit 3; }
  $bench/lib/preflight.sh correctness || exit $?
  host_start=$(python3 $bench/lib/record.py host)
  export COMPOSE_PROJECT_NAME=akko-bench-correctness COMPOSE_FILE=compose.yaml:agent/compose.agent.yaml
  export KEYCLOAK_PORT=18680 MCP_PORT=13200 INSPECTOR_PORT=16474 AGENT_ENV_FILE=${AGENT_ENV_FILE:-/root/secrets/agent.env}
  [ -n "$image" ] && export MCP_IMAGE=$image
  name=reports/$(date -u +%Y-%m-%d-%H%M%S)-bench-$provider-${model:-default}
  trap 'rm -f "agent/$name.path"; docker compose --profile tools down -v --remove-orphans >/dev/null 2>&1' EXIT
  docker compose up -d --wait --wait-timeout 420 >/dev/null 2>&1 </dev/null || { echo "bench: the sandbox did not start"; exit 1; }
  docker compose run --rm -T agent --provider "$provider" ${model:+--model "$model"} --persona carol_analyst \
    --questions questions.json --max-steps 12 --repeat "$repeat" --out "$name.md" </dev/null || exit 1
  BENCH_HOST="{\"start\": $host_start, \"end\": $(python3 $bench/lib/record.py host)}" \
    python3 $bench/lib/record.py correctness "agent/$name.json" --command "$command" --out "$results_dir" > "agent/$name.path" || exit 1
  gate "$(tail -1 "agent/$name.path")"; exit $?
fi

# --- security, perf: the scripts, one compose project each ---------------------
case "$axis" in security|perf) ;; *) echo "bench/run.sh: unknown axis $axis"; exit 2 ;; esac
all=$(python3 $bench/lib/record.py suites "$axis") || exit 2
if [ -n "$suites" ]; then
  requested=$(printf '%s\n' $suites | jq -R . | jq -s -c .)
else
  requested='"all"'
  suites=$(cut -f1 <<<"$all" | tr '\n' ' ')
fi
for s in $suites; do grep -q "^$s	" <<<"$all" || { echo "bench/run.sh: no suite $s in $axis"; exit 2; }; done

started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
evidence=$evidence_dir/${started//:/}-$axis
mkdir -p "$evidence" && evidence=$(cd "$evidence" && pwd)
t0=$(date +%s)
host_start=$(python3 $bench/lib/record.py host)
refused=""
if ! lock; then
  refused="another bench run holds the lock"
elif ! $bench/lib/preflight.sh "$axis" | tee "$evidence/preflight.txt"; then
  refused=$(sed -n 's/^preflight: refused: //p' "$evidence/preflight.txt")
  [ -n "$refused" ] || exit 2
fi
export KEYCLOAK_PORT=18680 MCP_PORT=13200 INSPECTOR_PORT=16474
[ -n "$image" ] && export MCP_IMAGE=$image
server_image=${MCP_IMAGE:-$(sed -n 's/.*image: \${MCP_IMAGE:-\([^}]*\)}.*/\1/p' compose.yaml | head -1)}

suite_rows=()
images=()
for s in $suites; do
  IFS=$'\t' read -r _ script compose_file env <<<"$(grep "^$s	" <<<"$all")"
  project=akko-bench-$s
  if [ -n "$refused" ]; then suite_rows+=("$s	$project	-	0"); continue; fi
  while read -r img; do images+=("$img"); done < <(COMPOSE_FILE=$compose_file docker compose --profile tools config --images 2>/dev/null)
  echo "== $s: $script, project $project ($(free -g | awk '/^Mem:/ {print $7}') GB available)"
  $bench/lib/memsample.sh "$project" "$evidence/$s.mem.tsv" 5 9>&- &
  sampler=$!
  s0=$(date +%s)
  # shellcheck disable=SC2086
  env COMPOSE_PROJECT_NAME="$project" BENCH_EVIDENCE="$evidence" BENCH_SUITE="$s" $env \
    timeout 3600 bash "$script" > "$evidence/$s.log" 2>&1 </dev/null 9>&-
  rc=$?
  kill "$sampler" 2>/dev/null; wait "$sampler" 2>/dev/null
  # The script removes its project; this makes sure, for this project only.
  COMPOSE_PROJECT_NAME=$project COMPOSE_FILE=$compose_file docker compose --profile tools down -v --remove-orphans >/dev/null 2>&1
  suite_rows+=("$s	$project	$rc	$(( $(date +%s) - s0 ))")
  echo "   exit $rc in $(( $(date +%s) - s0 )) s: $(grep -c '^ *OK ' "$evidence/$s.log") OK, $(grep -c '^ *FAIL ' "$evidence/$s.log") FAIL"
done

# The images the suites ran, by digest; the server's version as it says it.
stack_json=$(for img in $(printf '%s\n' "${images[@]}" | sort -u); do
  digest=$(docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}{{.Id}}{{end}}' "$img" 2>/dev/null || echo "")
  jq -n --arg k "$img" --arg v "$digest" '{($k): (if $v == "" then null else $v end)}'
done | jq -s 'add // {}')
announced=$([ -z "$refused" ] && docker run --rm "$server_image" akko-mcp-trino --version 2>/dev/null | head -1)
server_digest=$(jq -r --arg k "$server_image" '.[$k] // empty' <<<"$stack_json")
printf '%s\n' "${suite_rows[@]}" | jq -R -s --argjson hs "$host_start" --argjson he "$(python3 $bench/lib/record.py host)" \
  --arg started "$started" --arg command "$command" --arg refused "$refused" --arg image "$server_image" \
  --arg digest "$server_digest" --arg announced "$announced" --argjson stack "$stack_json" \
  --argjson duration "$(( $(date +%s) - t0 ))" --argjson seed "$BENCH_SEED" --argjson requested "$requested" '
  {started: $started, command: $command, seed: $seed, suites_requested: $requested, host_start: $hs, host_end: $he, duration_s: $duration,
   refused: (if $refused == "" then null else $refused end),
   server: {image: $image, digest: (if $digest == "" then null else $digest end), announced: (if $announced == "" then null else $announced end)},
   stack: $stack,
   suites: [split("\n")[] | select(length > 0) | split("\t") |
            {name: .[0], project: .[1], exit_code: (if .[2] == "-" then null else (.[2] | tonumber) end), duration_s: (.[3] | tonumber)}]}' \
  > "$evidence/run.json"
result=$(python3 $bench/lib/record.py security "$evidence" --axis "$axis" --out "$results_dir" | tail -1) || exit 1
echo "== result: $result"
sed -n '/^\*\*/p' "${result%.json}.md"
[ -n "$refused" ] && { echo "bench: the host refused the run: $refused"; exit 3; }
gate "$result"
