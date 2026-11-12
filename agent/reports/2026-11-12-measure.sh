#!/usr/bin/env bash
# The measurement as it ran on 2026-11-12, from the repository root: akko-mcp-trino 0.7.2
# against 0.8.0 with Apache Atlas, on the same stack and the same data (compose.yaml and
# catalogs/compose.atlas.yaml, seeded once), Mistral then Claude, three trials of each of the
# ten questions (questions.json and questions-context.json). Only the mcp service changes
# between passes. 0.7.2 ignores the Atlas settings, so it serves Trino's metadata only.
# Each provider gets its own key file, and nothing else. Prints FIN code=<n> at the end.
#
#   MCP_08=<image of 0.8.0> AGENT_IMAGE=<the harness's image> agent/reports/2026-11-12-measure.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
export COMPOSE_PROJECT_NAME=akko-agent-v08 COMPOSE_PROFILES=catalogs
export COMPOSE_FILE=compose.yaml:catalogs/compose.atlas.yaml
export KEYCLOAK_PORT=18680 MCP_PORT=13200 INSPECTOR_PORT=16474 ATLAS_PORT=21200
MCP_07=akkoai/akko-mcp-trino:0.7.2
MCP_08=${MCP_08:?the image of 0.8.0}
AGENT_IMAGE=${AGENT_IMAGE:?the harness image}
d=2026-11-12
T=$COMPOSE_PROJECT_NAME-trino-1
code=0
state() { docker inspect "$T" --format "running={{.State.Running}} oom={{.State.OOMKilled}} restarts={{.RestartCount}} started={{.State.StartedAt}}"; }
use() { # the mcp image
  export MCP_IMAGE=$1
  docker compose up -d --wait --wait-timeout 1800 </dev/null >/dev/null 2>&1 || { echo "UP FAILED $1"; docker compose ps -a; return 1; }
  echo "== mcp: $(docker compose exec -T mcp akko-mcp-trino --version 2>&1 | tail -1) ($1)"
  echo "   trino: $(state)"
}
sizes() { # tag: describe_table and describe_schema as carol_analyst, their size in bytes
  docker run --rm --network "${COMPOSE_PROJECT_NAME}_default" --entrypoint python "$AGENT_IMAGE" -c "
import anyio, json, types, run
args = types.SimpleNamespace(keycloak_url='http://keycloak:8080', mcp_url='http://mcp:3000/mcp', persona='carol_analyst')
async def main():
    out = {}
    async with run.mcp_session(args) as (s, init, tools):
        out['server'] = run.server_name(init, tools)
        for t in ('customers', 'accounts', 'transactions'):
            text = run.tool_text(await s.call_tool('describe_table', {'catalog': 'demo', 'schema': 'crm', 'table': t}))
            out['describe_table demo.crm.' + t] = {'bytes': len(text.encode()), 'atlas': 'column_context' in text}
        text = run.tool_text(await s.call_tool('describe_schema', {'catalog': 'demo', 'schema': 'crm'}))
        out['describe_schema demo.crm'] = {'bytes': len(text.encode())}
    print(json.dumps(out, indent=2))
anyio.run(main)" > "agent/reports/$d-describe-sizes-$1.json" || return 1
  cat "agent/reports/$d-describe-sizes-$1.json"
}
pass() { # provider model key-file tag
  echo "== $1 $4: start $(date -u +%H:%M:%S)"
  docker run --rm --network "${COMPOSE_PROJECT_NAME}_default" --env-file "$3" -e MCP_IMAGE="$MCP_IMAGE" \
    -v "$PWD/agent/reports:/agent/reports" "$AGENT_IMAGE" \
    --provider "$1" --model "$2" --persona carol_analyst --questions questions.json questions-context.json \
    --max-steps 12 --max-tokens 16000 --repeat 3 --pause "$5" --out "reports/$d-$1-$4.md" </dev/null || return 1
  echo "== $1 $4: end $(date -u +%H:%M:%S), trino: $(state)"
}
run_all() {
  echo "== start $(date -u +%H:%M:%S), project $COMPOSE_PROJECT_NAME"
  use "$MCP_07" || return 1; sizes 0.7.2 || return 1
  pass mistral codestral-latest /root/secrets/agent.env 0.7.2 2 || return 1
  use "$MCP_08" || return 1; sizes 0.8.0-de71fc2 || return 1
  docker compose exec -T mcp akko-mcp-trino --check 2>&1 | grep -E '^(context|atlas):'
  pass mistral codestral-latest /root/secrets/agent.env 0.8.0-de71fc2 2 || return 1
  use "$MCP_07" || return 1
  pass anthropic claude-sonnet-5-5 /root/secrets/agent-claude.env 0.7.2 0 || return 1
  use "$MCP_08" || return 1
  pass anthropic claude-sonnet-5-5 /root/secrets/agent-claude.env 0.8.0-de71fc2 0 || return 1
}
run_all || code=1
echo "== end $(date -u +%H:%M:%S), trino: $(state)"
echo "FIN code=$code"
