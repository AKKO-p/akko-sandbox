#!/usr/bin/env bash
# Mistral only, five trials per question, on 0.6.1 and 0.7.0 (4105967): Trino with
# mem_limit 2048m and MALLOC_ARENA_MAX=2 for both (agent/compose.agent.yaml), a fresh stack
# per server, Trino's state checked before and after, its RSS sampled every 10 s; any death
# or restart of Trino invalidates the run and stops it.
cd /root/akko-t7
export COMPOSE_PROJECT_NAME=akko-t7 COMPOSE_FILE=compose.yaml:agent/compose.agent.yaml
export KEYCLOAK_PORT=18580 MCP_PORT=13100 INSPECTOR_PORT=16374 AGENT_ENV_FILE=/root/secrets/agent.env
d=2026-11-01-mistral5
T=akko-t7-trino-1
mkdir -p rss
state() { docker inspect $T --format "running={{.State.Running}} oom={{.State.OOMKilled}} restarts={{.RestartCount}} started={{.State.StartedAt}} mem_limit={{.HostConfig.Memory}} env_arena={{range .Config.Env}}{{if eq (index (split . \"=\") 0) \"MALLOC_ARENA_MAX\"}}{{.}}{{end}}{{end}}"; }
guard() { # the run's pid: stops it if Trino dies or restarts
  local run=$1 out=$2 started=$3
  while kill -0 $run 2>/dev/null; do
    s=$(docker inspect $T --format "{{.State.Running}} {{.State.OOMKilled}} {{.RestartCount}} {{.State.StartedAt}}" 2>/dev/null)
    echo "$(date -u +%H:%M:%S) $(docker stats --no-stream --format "{{.MemUsage}}" $T 2>/dev/null) $s" >> $out
    if [ "$s" != "true false 0 $started" ]; then
      echo "TRINO_DIED: $s"; kill $run; docker ps -q --filter name=akko-t7-agent-run | xargs -r docker kill >/dev/null; return 1
    fi
    sleep 10
  done
}
for image in akkoai/akko-mcp-trino:0.6.1 akko-mcp-trino:0.7.0-4105967; do
  export MCP_IMAGE=$image; tag=${image##*:}
  docker compose up -d --wait --force-recreate >/dev/null 2>&1 </dev/null || { echo "UP FAILED $image"; exit 1; }
  echo "== $image trino before: $(state)"
  started=$(docker inspect $T --format "{{.State.StartedAt}}")
  docker compose run --rm -T agent --provider mistral --model codestral-latest --persona carol_analyst \
    --questions questions.json --max-steps 12 --max-tokens 16000 --repeat 5 --out reports/$d-$tag.md </dev/null 2>&1 | grep -vE "Container|^ *$" &
  pid=$!
  guard $pid rss/mistral-$tag.txt "$started" || { echo "STOP: Trino died during $tag"; exit 1; }
  wait $pid
  echo "== $image trino after: $(state)"
done
echo MEASURE5_DONE
