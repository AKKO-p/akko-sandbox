# Brancher un hôte MCP sur le bac à sable

[English](connect-a-host.md)

Le serveur MCP du bac à sable écoute sur `http://localhost:3000/mcp`
(streamable HTTP). Il refuse toute requête sans jeton valide : chaque hôte en
envoie donc un dans un en-tête `Authorization`.

## 1. Obtenir un jeton

```bash
./token.sh carol_analyst      # ou alice_admin, dave_viewer
```

Le script demande à Keycloak le jeton d'accès de l'utilisateur (mot de passe
`demo`) et l'affiche. Un jeton vaut une heure ; relancez le script quand l'hôte
répond `401`. Pour changer d'utilisateur, changez de jeton : le même hôte
obtient alors d'autres réponses.

Dans les exemples ci-dessous, remplacez `<token>` par la valeur affichée.

## 2. Configurer l'hôte

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

Dans `.vscode/mcp.json`. VS Code demande le jeton au démarrage du serveur et le
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
il rejoint donc le bac à sable par le pont `mcp-remote` (Node.js requis). Dans
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

Redémarrez Claude Desktop à chaque changement de jeton.

## 3. Poser une question

Demandez par exemple au modèle : *« Quels clients avons-nous, avec leur e-mail
et leur pays ? »* Avec le jeton de carol, il obtient cinq clients européens et
des adresses masquées ; avec celui d'alice, les dix, en clair. Les descriptions
des outils disent au modèle qu'une valeur masquée ou une ligne absente relève
de la politique d'accès, pas d'une erreur à retenter.

## En cas de problème

| Symptôme | Cause |
|---|---|
| `401` | pas de jeton, un jeton expiré (une heure) ou une faute dans l'en-tête |
| `connection refused` | le bac à sable ne tourne pas (`docker compose ps`) ou `MCP_PORT` n'est pas `3000` |
| l'hôte propose une connexion OAuth | il a reçu un `401` et tente de se connecter seul ; donnez-lui un en-tête à la place |
