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
  akko-sandbox-agent:local --provider anthropic --repeat 3 --out reports/2026-10-30-anthropic-0.6.1.md
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
| `--repeat` | `1` | trials of each question, each in a fresh session (Anthropic: 3) |
| `--max-steps` | `12` | model turns that may call tools, per trial |
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
  recorded as such, so that a run never mixes two models. Since its answers
  vary from one trial to the next, run it with `--repeat 3` or more.

Two runs compare the server only when the model and these settings are the same.
The report writes them down. Tokens compare one server against another for the
same model, never one provider against another: Anthropic's output tokens include
its thinking, and Codestral has none.

## Trials

`--repeat N` (default 1) asks each question N times, each trial in a fresh
session and a fresh conversation. The JSON keeps every trial. The report gives,
per question, the number of trials, the right answers out of N, and the median
of each figure, with its range when the trials differ: `4 (3-6)` is a median of
4 between 3 and 6. A figure some trials lack (a column never shown) adds the
share that have it: `2 [2/3]`. The totals add up the questions' medians; right
answers count every trial.

## What each trial records

| Field | Meaning |
|---|---|
| Tool calls | every tool call until the final answer, in order |
| First expected column at call | the 1-based call whose result first showed one of the expected columns |
| All expected columns at call | the call by which every expected column had shown at least once |
| Input, output tokens | the provider's own count, summed over the trial's turns (Anthropic: input includes cache reads and writes) |
| Right | the verdict below |
| Named, never shown | an expected column the answer names that no tool result showed: a guess |
| Wall time | from the token request to the final answer |
| Stop | `answered`, `max_steps`, `max_tokens` (the final turn was cut off), `refusal`, or `error: <kind>` (the kind and HTTP status only, never the message) |

The report also gives the model id the API returned (it may differ from the one
requested, such as a `-latest` alias), the server's name and version from its
MCP initialize result with the tools it announced, the server's image, the date,
and each trial's tool calls and final answer in full. The layout is the same
for every run, so that two reports compare line by line.

The server announces no version of its own today, and `server_image` is what the
operator said it ran (`MCP_IMAGE`, with compose.yaml's default when unset), not
what the container runs: the list of tools in `server` is the one figure read
from the server itself. Read both.

### The verdict

A trial is right when, and only when:

1. it ended with a final answer (`answered`): a trial stopped at `--max-steps`,
   cut off, refused or failed is never right, whatever its last text says, and
   text written beside tool calls is never read as an answer;
2. the final answer names every expected column;
3. the final answer names none of the question's `forbidden` columns.

`questions.json` fixes each question's `expected` and `forbidden` columns before
any run, with the reason for each (`why`, `why_forbidden`); they are not changed
after a run to get a result. A forbidden column is a wrong but plausible one,
such as the current transactions' `amount` for the archived year: naming it at
all makes the answer wrong, even beside the right one. The system prompt asks the
model to name every column it relies on, and no other.

The report also lists every other column the answer names (`other`), dotted
names of three or four parts that are neither an expected column nor one of
their tables or schemas. They do not change the verdict: they show a reader an
answer that names more than it needs.

### Matching a column in the final answer

Columns are written `catalog.schema.table.column`. The answer names one
when it contains `catalog.schema.table.column`, `schema.table.column` or
`table.column`, ignoring case and any double quotes or backticks around the
parts. The bare column name is not enough (`amount`), nor an alias (`t.amount`),
nor a name that only ends like it (`other.transactions.amount`), nor a longer
name (`transactions.amount_eur`). The same rule reads expected and forbidden
columns.

### When a column shows in a tool result

The rule reads the JSON the server returns, whatever its keys, the same for
every server version. A result that is an error shows nothing. Otherwise a
result shows a column when:

- it holds the column's qualified name anywhere (`crm.transactions.amount`, as
  in a query plan);
- an object in it says its table (and its schema, when it says one) and holds the
  column's name: a `search_columns` match, a `describe_schema` table. Such an
  object speaks for itself: a match in another table never counts, whatever the
  call's arguments say;
- an array in it holds the table's name and the column's: a row of a query on
  `information_schema`;
- the call's arguments name the table and the result holds the column's name:
  `describe_table` with `table` (and `schema`, when given), or a query whose SQL
  names the table as `catalog.schema.table`, `schema.table` or `table`
  (`SELECT * FROM demo.crm.transactions` shows `amount` in its `columns`), with
  quotes ignored. `demo.crm_archive.transactions_2019` and
  `demo.crm_archive.transactions` are other tables.

A listing of tables shows no column.

## The questions

`questions.json` holds five questions about the sandbox's fictional bank, for
`carol_analyst`, who sees every table of `demo.crm` and `demo.crm_archive`. Each
entry gives the question, the columns that answer it, the wrong but plausible
columns that make an answer wrong, and why. The questions are fixed before any
run and are not changed to get a result.

## Tests

The pure parts (tool formats, matching, the report, the key check, the loop
with fake clients) are unit tested, with no model and no server:

```bash
docker compose run --rm --entrypoint python agent -m pytest -q -p no:cacheprovider tests
```

## Reports

Dated reports go in `reports/`, one Markdown file and its JSON per run, named
`<date>-<provider>-<server>.md`.
