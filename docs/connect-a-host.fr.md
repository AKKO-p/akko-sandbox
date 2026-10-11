# Brancher un host MCP sur le sandbox

[English](connect-a-host.md)

Le serveur MCP du sandbox écoute sur `http://localhost:3000/mcp`
(streamable HTTP). Il refuse toute requête sans token valide : chaque host en
envoie donc un dans un en-tête `Authorization`.

## 1. Obtenir un token

```bash
./token.sh carol_analyst      # ou alice_admin, dave_viewer
```

Le script demande à Keycloak le token d'accès de l'utilisateur (mot de passe
`demo`) et l'affiche. Un token vaut une heure ; relancez le script quand l'host
répond `401`. Pour changer d'utilisateur, changez de token : le même host
obtient alors d'autres réponses.

Dans les exemples ci-dessous, remplacez `<token>` par la valeur affichée.

## 2. Configurer l'host

### Claude Code

```bash
claude mcp add --transport http akko-sandbox http://localhost:3000/mcp \
  --header "Authorization: Bearer $(./token.sh carol_analyst)"
```

### Cursor

Dans `~/.cursor/mcp.json` (ou `.cursor/mcp.json` dans un projet) :

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

Dans `.vscode/mcp.json`. VS Code demande le token au démarrage du serveur et le
garde hors du fichier :

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

Claude Desktop lance des serveurs locaux depuis son fichier de configuration :
il rejoint donc le sandbox par le pont `mcp-remote` (Node.js requis). Dans
`claude_desktop_config.json` :

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

Redémarrez Claude Desktop à chaque changement de token.

## 3. Poser une question

Demandez par exemple au modèle : *« Quels clients avons-nous, avec leur e-mail
et leur pays ? »* Avec le token de carol, il obtient cinq clients européens et
des adresses masquées ; avec celui d'alice, les dix, en clair. Les descriptions
des outils disent au modèle qu'une valeur masquée ou une ligne absente relève
de la politique d'accès, pas d'une erreur à retenter.

## En cas de problème

| Symptôme | Cause |
|---|---|
| `401` | pas de token, un token expiré (une heure) ou une faute dans l'en-tête |
| `connection refused` | le sandbox ne tourne pas (`docker compose ps`) ou `MCP_PORT` n'est pas `3000` |
| l'host propose une connexion OAuth | il a reçu un `401` et tente de se connecter seul ; donnez-lui un en-tête à la place |
