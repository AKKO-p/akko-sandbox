#!/usr/bin/env bash
# Prints an access token for a sandbox user, to paste into an MCP host.
#   ./token.sh carol_analyst              a token for the MCP server (client sandbox-mcp)
#   ./token.sh carol_analyst trino-cli    a token for Trino itself, as a Trino client gets one
# Users: alice_admin, carol_analyst, dave_viewer. Password: demo. Valid one hour.
set -euo pipefail
user="${1:?usage: ./token.sh <alice_admin|carol_analyst|dave_viewer>}"
curl -sf "http://localhost:${KEYCLOAK_PORT:-8080}/realms/sandbox/protocol/openid-connect/token" \
  -d grant_type=password -d "client_id=${2:-sandbox-mcp}" -d "username=$user" -d password=demo \
  | sed -E 's/.*"access_token":"([^"]+)".*/\1/'
