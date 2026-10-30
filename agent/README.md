# A real agent against the sandbox

How many tool calls does a model need to find the right column? `run.py` asks a
model a few questions about the sandbox's data, through MCP, as a sandbox user,
and counts. Run it once against one server, once against another, with the same
model and the same settings: the difference comes from the server.

The harness opens an MCP session with the user's token (the same token
`token.sh` prints), gives the model the tools the server announces, unchanged,
and executes the model's tool calls until it gives a final answer or reaches
`--max-steps`. Each question starts in a fresh session and a fresh conversation.

## Run it

On a machine with Docker, from the repository root:

```bash
export COMPOSE_FILE=compose.yaml:agent/compose.agent.yaml
export MCP_IMAGE=akkoai/akko-mcp-trino:0.6.1      # the server to measure
docker compose up -d --wait

# The tools the server announces, in the provider's format. No model, no key.
docker compose run --rm agent --provider mistral --dry-run

# A run. The keys come from a file of yours, never from the repository.
AGENT_ENV_FILE=/path/to/agent.env docker compose run --rm agent \
  --provider mistral --model codestral-latest --persona carol_analyst \
  --questions questions.json --max-steps 12 \
  --out reports/2026-10-30-mistral-0.6.1.md
```

Change `MCP_IMAGE`, `docker compose up -d --wait` again, and run the same command
with another `--out`. Remove everything with
`docker compose --profile tools down -v --remove-orphans`.

The same, without Compose's `run`, on the sandbox's network:

```bash
docker run --rm --network akko-sandbox_default --env-file /path/to/agent.env \
  -e MCP_IMAGE="$MCP_IMAGE" -v "$PWD/agent/reports:/agent/reports" \
  akko-sandbox-agent:local --provider anthropic --out reports/2026-10-30-anthropic-0.6.1.md
```

| Option | Default | Meaning |
|---|---|---|
| `--provider` | (required) | `mistral` or `anthropic` |
| `--model` | `codestral-latest`, `claude-sonnet-5-5` | the model id sent to the provider's API |
| `--persona` | `carol_analyst` | the sandbox user whose token opens the session |
| `--questions` | `questions.json` | the questions and the columns that answer them |
| `--mcp-url` | `$MCP_URL`, `http://mcp:3000/mcp` | the MCP endpoint |
| `--keycloak-url` | `$KEYCLOAK_URL`, `http://keycloak:8080` | where the user's token comes from |
| `--server-image` | `$MCP_IMAGE` | the server's image, written in the report |
| `--max-steps` | `12` | model turns that may call tools, per question |
| `--max-tokens` | `16000` | output tokens per model turn |
| `--out` | (required unless `--dry-run`) | the Markdown report; its JSON is written beside it |
| `--dry-run` | | list the tools in the provider's format, call no model, need no key |

## Keys

`MISTRAL_API_KEY` or `ANTHROPIC_API_KEY`, from the environment, and only the
chosen provider's: the harness checks it before it opens anything and stops,
naming the variable, when it is missing. It never prints, logs nor writes a
key. Compose passes `AGENT_ENV_FILE` to the container's environment only; keep
that file outside the repository, readable by you alone (`chmod 600`).

## Same settings on both sides

The same system prompt, the same tools (as the server describes them), the same
`--max-steps` and `--max-tokens` go to every provider. Tool results go back to
the model as tool results, and the system prompt says they are data, never
instructions.

- **Mistral**: `temperature` 0 and `random_seed` 0, `tool_choice` `auto`.
- **Anthropic**: the current Messages API takes no `temperature` (a request
  with one is refused), so the model samples with its defaults; thinking and
  effort stay at the model's defaults, and every content block of a response,
  thinking included, goes back unchanged. No fallback model: a refusal is
  recorded as such, so that a run never mixes two models.

Two runs compare the server only when the model and these settings are the same.
The report writes them down.

## What each question records

| Field | Meaning |
|---|---|
| Tool calls | every tool call until the final answer, in order |
| First expected column at call | the 1-based call whose result first showed one of the expected columns |
| All expected columns at call | the call by which every expected column had shown at least once |
| Input, output tokens | the provider's own count, summed over the question's turns (Anthropic: input includes cache reads and writes) |
| Answer names every expected column | the matching rule below, on the final answer |
| Wall time | from the token request to the final answer |
| Stop | `answered`, `max_steps`, `refusal`, or `error: <kind>` (the kind only, never the message) |

The report also gives the model id the API returned (it may differ from the one
requested, such as a `-latest` alias), the server's name and version from its
MCP initialize result with the tools it announced, the server's image, the date,
and each question's tool calls and final answer in full. The layout is the same
for every run, so that two reports compare line by line.

### Matching an expected column in the final answer

Expected columns are written `catalog.schema.table.column`. The answer names one
when it contains `catalog.schema.table.column`, `schema.table.column` or
`table.column`, ignoring case and any double quotes or backticks around the
parts. The bare column name is not enough (`amount`), nor an alias (`t.amount`),
nor a name that only ends like it (`other.transactions.amount`), nor a longer
name (`transactions.amount_eur`). The system prompt asks the model to name every
column it relies on in full, the same on every run.

### When a column shows in a tool result

A tool result shows a column when its JSON holds the column's name inside
something that names its table: an object whose `table` is the table (what
`search_columns` and `describe_schema` return), an array that holds the table's
name (a row of a query on `information_schema`), or the whole result when the
call's arguments name the table (`describe_table`). A qualified name
(`transactions.amount`) anywhere in a result counts too. A listing of tables
shows no column.

## The questions

`questions.json` holds five questions about the sandbox's fictional bank, for
`carol_analyst`, who sees every table of `demo.crm` and `demo.crm_archive`. Each
entry gives the question, the columns that answer it, and why. The questions are
fixed before any run and are not changed to get a result.

## Tests

The pure parts (tool formats, matching, the report, the key check, the loop
with fake clients) are unit tested, with no model and no server:

```bash
docker compose run --rm --entrypoint python agent -m pytest -q -p no:cacheprovider tests
```

## Reports

Dated reports go in `reports/`, one Markdown file and its JSON per run, named
`<date>-<provider>-<server>.md`.
