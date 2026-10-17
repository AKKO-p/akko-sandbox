# Changelog

## Unreleased

- akko-mcp-trino 0.6.0, with its safe defaults: the server accepts only tokens issued for it (audience `akko-mcp`) and exchanges each at Keycloak for a token issued for Trino (OAuth 2.0 Token Exchange, RFC 8693); the user's token is never passed on.
- Keycloak: a confidential client `akko-mcp` with standard token exchange, a target client `trino`, and a public client `trino-cli` whose tokens are issued for Trino. Keycloak serves https too, with its own certificate from the sandbox CA, for the token endpoint. Keycloak is healthy once the realm serves its keys.
- The MCP server's client secret is drawn at random on the first start (`certs`), never written in the repository.
- `demo.sh` shows and checks a write refused before Trino, the message of the `401`, and a valid token issued for Trino refused by the server.
- `tests/smoke.sh` checks that Trino refuses a token issued for the MCP server, that the server exchanged tokens at Keycloak, and that its log holds no client secret.
- The policy refuses `ImpersonateUser` towards any name but the one the token proves, except for the accounts listed in `impersonators` (empty here; akko-mcp-trino's own account in its `impersonation` mode). Before, a user calling Trino directly with their own token could act as another user (found on 2026-10-17). `tests/smoke.sh` proves carol cannot act as alice_admin.
- `./token.sh <user> trino-cli` prints a token for Trino itself.
- `MCP_IMAGE` runs another build of the server.

## 0.1.0 (unreleased)

First version: the open source core of akko-mcp-trino in five minutes.

- `docker compose up -d --wait` starts Keycloak, PostgreSQL with fictional data, OPA, Trino over https with JWT authentication and OPA access control, akko-mcp-trino in `jwt` mode, and the MCP Inspector.
- `./demo.sh`: two users, the same question, two answers; a third user refused; `401` without a token and with a forged one.
- `./token.sh`: a user's access token, to connect an MCP host.
- `tests/smoke.sh`: the end-to-end test, with start time and memory.
- CI: `tests/smoke.sh` on every push and pull request to `main`, on `ubuntu-latest`. The arm64 line (`ubuntu-24.04-arm`) is ready, commented out: GitHub's arm runners are free for public repositories only, so it is enabled when the repository goes public.
- `docs/demo.tape` and a workflow started by hand that records the README animation with VHS. `DEMO_PACE` paces the demo's steps for a recording.
- `docs/demo.gif`, the animation at the top of both READMEs.
- Guide to connect Claude Code, Cursor, VS Code and Claude Desktop.
