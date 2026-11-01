#!/usr/bin/env bash
# The final measurement as it ran on 2026-11-01, from the repository root: Trino with
# mem_limit 2048m and MALLOC_ARENA_MAX=2 for both servers (agent/compose.agent.yaml), a fresh
# stack per server, Trino's state checked before and after, its RSS sampled every 10 s; any
# death or restart of Trino invalidates the run and stops it. Needs the 0.7.0 image built as
# akko-mcp-trino:0.7.0-4105967 and the keys in AGENT_ENV_FILE.
export COMPOSE_PROJECT_NAME=akko-t7 COMPOSE_FILE=compose.yaml:agent/compose.agent.yaml
export KEYCLOAK_PORT=18580 MCP_PORT=13100 INSPECTOR_PORT=16374 AGENT_ENV_FILE=/root/secrets/agent.env
d=2026-11-01-final
T=akko-t7-trino-1
mkdir -p rss
cost() { python3 -c "
import json,glob
c=0
for f in glob.glob('agent/reports/$d-anthropic-*.json'):
    for t in json.load(open(f))['trials']: c+=t['input_tokens']*2e-6+t['output_tokens']*10e-6
print(round(c,2))"; }
state() { docker inspect $T --format "running={{.State.Running}} oom={{.State.OOMKilled}} restarts={{.RestartCount}} started={{.State.StartedAt}} mem_limit={{.HostConfig.Memory}} env_arena={{range .Config.Env}}{{if eq (index (split . \"=\") 0) \"MALLOC_ARENA_MAX\"}}{{.}}{{end}}{{end}}"; }
guard() { # the run's pid: stops it if Trino dies or restarts
  local run=$1 out=$2 started=$3
  while kill -0 $run 2>/dev/null; do
    s=$(docker inspect $T --format "{{.State.Running}} {{.State.OOMKilled}} {{.RestartCount}} {{.State.StartedAt}}" 2>/dev/null)
    echo "$(date -u +%H:%M:%S) $(docker stats --no-stream --format "{{.MemUsage}}" $T 2>/dev/null) $s" >> $out
    if [ "$s" != "true false 0 $started" ]; then
      echo "TRINO_DIED: $s"; pkill -P $run; kill $run; docker ps -q --filter name=akko-t7-agent-run | xargs -r docker kill >/dev/null; return 1
    fi
    sleep 10
  done
}
run_one() { # provider model tag
  local started; started=$(docker inspect $T --format "{{.State.StartedAt}}")
  docker compose run --rm -T agent --provider $1 --model $2 --persona carol_analyst \
    --questions questions.json --max-steps 12 --repeat 3 --out reports/$d-$1-$3.md </dev/null 2>&1 | grep -vE "Container|^ *$" &
  local pid=$!
  guard $pid rss/$1-$3.txt "$started" || return 1
  wait $pid
}
for image in akkoai/akko-mcp-trino:0.6.1 akko-mcp-trino:0.7.0-4105967; do
  export MCP_IMAGE=$image; tag=${image##*:}
  docker compose up -d --wait --force-recreate >/dev/null 2>&1 </dev/null || { echo "UP FAILED $image"; exit 1; }
  echo "== $image trino before: $(state)"
  echo "== $image mistral"
  run_one mistral codestral-latest $tag || { echo "STOP: Trino died during mistral $tag"; exit 1; }
  echo "== $image trino after mistral: $(state)"
  spent=$(cost); echo "claude spent so far: $spent USD (plus 1.49 USD discarded)"
  if python3 -c "import sys; sys.exit(0 if $spent + 1.49 > 12.5 else 1)"; then echo "STOP: Claude spend would exceed 25 USD"; break; fi
  echo "== $image anthropic"
  run_one anthropic claude-sonnet-5-5 $tag || { echo "STOP: Trino died during anthropic $tag"; exit 1; }
  echo "== $image trino after anthropic: $(state)"
  echo "claude spent so far: $(cost) USD (plus 1.49 USD discarded)"
done
echo MEASURE4_DONE
