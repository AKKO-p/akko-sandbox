# Tool calls measured, akko-mcp-trino 0.6.1 against 0.7.0, 2026-10-30

**Headline: with Mistral `codestral-latest`, 0.7.0 does not reduce the tool calls.** Both
servers took 32 calls over the five questions. 0.7.0 got fewer right answers (1/5 against 3/5)
and used about twice the input tokens (105,406 against 53,687). The Claude runs did not take
place: the Anthropic key was refused before any model ran (see "Claude" below).

## Setup

| | |
|---|---|
| Sandbox | AKKO-p/akko-sandbox `main` 7a399c7, base compose (catalog `demo` only, default page sizes) plus `agent/compose.agent.yaml`, on a shared Linux host, project `akko-t7` |
| Before | `akkoai/akko-mcp-trino:0.6.1`: 6 tools, announces no version |
| After | `akko-mcp-trino:0.7.0-rc`, built from akko-mcp-trino `main` f487aff (Release 0.7.0, not published): 8 tools, announces `trino-mcp 0.7.0` |
| Persona | `carol_analyst` |
| Questions, rules, prompt | `agent/questions.json`, `agent/README.md`, `run.py` as merged in 7a399c7, unchanged after the results |
| Mistral | `codestral-latest` (the API returned `codestral-latest`), temperature 0, random_seed 0, `--repeat 1`, `--max-steps 12`, `--max-tokens 16000`; no 429, no pause |
| Reports | `2026-10-30-mistral-0.6.1.md` and `2026-10-30-mistral-0.7.0-rc.md`, each with its JSON; key checks `2026-10-30-keycheck-*` (question 1 only, `2026-10-30-keycheck-questions.json`) |

## Mistral, per question

| # | Question | Tool calls 0.6.1 → 0.7.0 | First expected column at call | All expected columns at call | Input tokens | Output tokens | Right |
|---|---|---|---|---|---|---|---|
| 1 | Revenue per customer | 7 → 7 | 6 → 1 | - → 4 | 10,646 → 24,860 | 231 → 232 | no → no |
| 2 | Segment with the largest balance | 7 → 10 | 4 → - | 5 → - | 10,951 → 23,563 | 242 → 279 | no → no |
| 3 | Spending per category, March 2026 | 7 → 1 | 5 → - | 5 → - | 12,549 → 5,480 | 407 → 30 | yes → no |
| 4 | Accounts per currency | 6 → 2 | 5 → 2 | 5 → 2 | 10,422 → 8,625 | 205 → 138 | yes → yes |
| 5 | Archived transactions, 2019 | 5 → 12 (max_steps) | 4 → - | 4 → - | 9,119 → 42,878 | 158 → 369 | yes → no |
| | **Total** | **32 → 32** | | | **53,687 → 105,406** | **1,243 → 1,048** | **3/5 → 1/5** |

With `--repeat 1` each cell is a single trial, so a cell's median and range are the same value.

## What the trials show (read in full)

- **0.6.1** walks the tree on every question: `list_catalogs`, `list_schemas`, `list_tables`,
  `describe_table`, then `execute_query`. It sees the right columns by call 4 to 6 and answers
  all five. Q1 and Q2 are scored wrong because the answer leaves out the join keys
  (`transactions.account_id`, `accounts.customer_id`). In Q1 it joins `customers` on
  `customers.id` without naming the path through `accounts`.
- **0.7.0** starts with `search_columns` every time and stays with it. When the search finds
  the column (Q1 `revenue`, Q4 `currency`), the column shows at call 1 or 2, earlier than on
  0.6.1. Q4 drops from 6 calls to 2. When the search text is a phrase, the search returns
  nothing and the model stops or loops:
  - Q3: one `search_columns` call, then "I could not find any columns with the name or comment
    'spending category'". The question is left unanswered.
  - Q2: ten calls, eight of them `search_columns`, then "I could not find any columns related to
    customer segment or account balance".
  - Q5: twelve `search_columns` calls, cut off at `--max-steps`, no answer.
  - Q1: right columns at call 1, but the answer leaves out `transactions.account_id`, the same
    miss as on 0.6.1.

The model never fell back to `list_tables` or `describe_schema` after an empty search, except
for one `list_catalogs` and one `list_schemas` in Q2.

## Why the search came back empty (diagnostic, no model)

The same `search_columns` call, as `carol_analyst`, on 0.7.0 (`2026-10-30-search-probe.txt`):

| Text | Matches |
|---|---|
| `spending category`, `customer segment`, `account balance`, `archived transactions` | 0 |
| `category`, `spending`, `segment`, `balance`, `revenue` | 1 each, the right column |
| `archived`, `2019`, `transactions_2019` | 0 |
| `amount` | 13 (the current table and the 12 archive years) |

`search_columns` takes its text as one literal substring of a column's name or comment. A phrase
of two words matches nothing unless the comment holds it as written. Table names and table
comments are not searched, so the archive year (`transactions_2019`, "Transactions booked in
2019, archived") is out of its reach. The answer to an empty search says `complete: true` and
gives no matches. Codestral reads that as "the data is not there" instead of listing the tables.
This is a finding about the server's tool, not a scoring artefact. The scoring rules were fixed
before any run.

## Claude

The key check (one question, `--repeat 1`, on 0.7.0) failed before any model ran:
`anthropic.BadRequestError` 400, `invalid_request_error`, message "This API key is not scoped to
a workspace, so this request must include the anthropic-workspace-id header with the ID of the
workspace to use." The provider was stopped as ruled, and no Claude run was made. It needs a key
scoped to a workspace, or a workspace id that the harness passes on (a small harness change, not
made here).

## Caveats

- One trial per question for Mistral. The key check, the same Q1 on 0.7.0 with the same
  settings, took 8 calls where the measured run took 7, so temperature 0 with a fixed seed is not
  fully repeatable. Differences of one or two calls are noise; the empty-search failures are not.
- The harness records which tools were called, not their arguments. The search texts above are a
  diagnostic replay, not the model's exact texts.
