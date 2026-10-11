# Connect an MCP host to the sandbox

[Français](connect-a-host.fr.md)

The sandbox's MCP server listens at `http://localhost:3000/mcp` (streamable
HTTP). It refuses any request without a valid token, so every host sends one in
an `Authorization` header.

## 1. Get a token

```bash
./token.sh carol_analyst      # or alice_admin, dave_viewer
```

The script asks Keycloak for the user's access token (password `demo`) and
prints it. A token is valid for one hour; run the script again when the host
says `401`. Switch users by switching tokens: the same host then gets other answers.

In the examples below, replace `<token>` with the printed value.

## 2. Configure the host

### Claude Code

```bash
claude mcp add --transport http akko-sandbox http://localhost:3000/mcp \
  --header "Authorization: Bearer $(./token.sh carol_analyst)"
```

### Cursor

In `~/.cursor/mcp.json` (or `.cursor/mcp.json` in a project):

```json
{
  "mcpServers": {
    "akko-sandbox": {
      "url": "http://localhost:3000/mcp",
      "headers": {"Authorization": "Bearer <token>"}
    }
  }
}
```

### VS Code

In `.vscode/mcp.json`. VS Code asks for the token when it starts the server and
keeps it out of the file:

```json
{
  "inputs": [
    {"type": "promptString", "id": "sandbox-token", "description": "Token from ./token.sh", "password": true}
  ],
  "servers": {
    "akko-sandbox": {
      "type": "http",
      "url": "http://localhost:3000/mcp",
      "headers": {"Authorization": "Bearer ${input:sandbox-token}"}
    }
  }
}
```

### Claude Desktop

Claude Desktop starts local servers from its configuration file, so it reaches
the sandbox through the `mcp-remote` bridge (Node.js required). In
`claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "akko-sandbox": {
      "command": "npx",
      "args": ["-y", "mcp-remote@0.14.3", "http://localhost:3000/mcp", "--header", "Authorization:${AUTH_HEADER}"],
      "env": {"AUTH_HEADER": "Bearer <token>"}
    }
  }
}
```

Restart Claude Desktop after each change of token.

## 3. Ask

Ask the model, for example: *"Which customers do we have, with their e-mail and
country?"* With carol's token it gets five European customers and masked
addresses; with alice's, all ten in clear. The tool descriptions tell the model
that a masked value or a missing row is the access policy, not an error to retry.

## If it does not work

| Symptom | Cause |
|---|---|
| `401` | no token, an expired token (one hour), or a typo in the header |
| `connection refused` | the sandbox is not running (`docker compose ps`) or `MCP_PORT` is not `3000` |
| the host proposes an OAuth login | it received `401` and tries to sign in by itself; give it a header instead |
