# Changelog

## 0.1.0 (unreleased)

First version: the open source core of akko-mcp-trino in five minutes.

- `docker compose up -d --wait` starts Keycloak, PostgreSQL with fictional data, OPA, Trino over https with JWT authentication and OPA access control, akko-mcp-trino in `jwt` mode, and the MCP Inspector.
- `./demo.sh`: two users, the same question, two answers; a third user refused; `401` without a token and with a forged one.
- `./token.sh`: a user's access token, to connect an MCP host.
- `tests/smoke.sh`: the end-to-end test, with start time and memory.
- CI: `tests/smoke.sh` on every push and pull request to `main`, on `ubuntu-latest`. The arm64 line (`ubuntu-24.04-arm`) is ready, commented out: GitHub's arm runners are free for public repositories only, so it is enabled when the repository goes public.
- `docs/demo.tape` and a workflow started by hand that records the README animation with VHS. `DEMO_PACE` paces the demo's steps for a recording.
- Guide to connect Claude Code, Cursor, VS Code and Claude Desktop.
