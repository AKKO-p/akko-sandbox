# Tool calls measured again, akko-mcp-trino 0.6.1 against 0.7.0 (word search), 2026-11-01

The second measurement, after the search change (akko-mcp-trino `main` f55ef00: `search_columns`
by words across columns and tables, table-only hits in `tables`, a `hint` on a complete empty
search). The first measurement (2026-10-30) stays in this folder as history.

**Headline, 3 trials per question:**

- **Claude `claude-sonnet-5-5`: 0.7.0 cuts the tool calls from 8.5 to 4.5 per trial and gets
  every answer right (15/15 against 12/15).** Claude searches one or two words at a time.
- **Mistral `codestral-latest`: 0.7.0 cuts the tool calls from 6.8 to 2.6 per trial, but the right
  answers drop from 9/15 to 6/15.** On Q1 and Q3, every 0.7.0 trial made a single search with
  the whole question, got an empty answer with its `hint`, and stopped.

The Claude passes first failed with `AuthenticationError` 401 on every trial. They were run again
the same day with a new key; the 401 reports are in this branch's history (commit 5a31eac).

## Setup

| | |
|---|---|
| Sandbox | AKKO-p/akko-sandbox `main` f57e044 (the harness records each call's arguments and sends the workspace header), base compose plus `agent/compose.agent.yaml`, project `akko-t7` |
| Before | `akkoai/akko-mcp-trino:0.6.1`: 6 tools, announces no version |
| After | `akko-mcp-trino:0.7.0-f55ef00`, built from akko-mcp-trino `main` f55ef00: 8 tools, announces `trino-mcp 0.7.0` |
| Questions, rules, prompt, limits | unchanged since the first measurement: `agent/questions.json`, persona `carol_analyst`, `--max-steps 12`, `--max-tokens 16000` |
| Mistral | `codestral-latest` (the API returned the same id), temperature 0, random_seed 0, `--repeat 3`; no 429 |
| Claude | `claude-sonnet-5-5` (the API returned the same id), `--repeat 3`, the API's default sampling (it takes no temperature); a one-trial key check first (`2026-11-01-keycheck-anthropic-*`); 1.54 USD for all the trials |

## Totals

| Server × model | Right answers | Mean tool calls | Mean input tokens | Mean output tokens | Forbidden columns named |
|---|---|---|---|---|---|
| 0.6.1 × Mistral | 9/15 | 6.8 | 10,679 | 242 | 0 |
| 0.7.0 × Mistral | 6/15 | 2.6 | 11,651 | 91 | 0 |
| 0.6.1 × Claude | 12/15 | 8.5 | 18,386 | 1,148 | 3 (Q5, a cross-check) |
| 0.7.0 × Claude | 15/15 | 4.5 | 21,543 | 749 | 0 |

## Mistral, per question (3 trials each)

| # | Question | Right 0.6.1 → 0.7.0 | Tool calls, per trial | What 0.7.0 searched |
|---|---|---|---|---|
| 1 | Revenue per customer | 0/3 → 0/3 | 6, 6, 7 → 1, 1, 1 | `revenue customer`: empty, with the hint |
| 2 | Segment with the largest balance | 0/3 → 0/3 | 7, 7, 6 → 12 (max_steps), 3, 3 | `customer segment account balance` (empty), then `customer segment` and `account balance` (both found) |
| 3 | Spending per category, March 2026 | 3/3 → 0/3 | 8, 10, 8 → 1, 1, 1 | `spending category March 2026`: empty, with the hint |
| 4 | Accounts per currency | 3/3 → 3/3 | 8, 8, 6 → 2, 2, 2 | `accounts currency`: found |
| 5 | Archived transactions, 2019 | 3/3 → 3/3 | 5, 5, 5 → 3, 3, 3 | `archived transactions 2019`: the table `transactions_2019` (a table-only hit), then `describe_table` |

## What happened, read by hand

Every 0.7.0 call below was replayed afterwards without a model, as `carol_analyst`, to read the
server's answer (`2026-11-01-replay-0.7.0.txt`). The harness records arguments, not results.

- **Q1 and Q3: one search, an empty answer, and the model stopped.** The model put every word of
  the question in one search: `revenue customer`, and `spending category March 2026`. A column or
  table matches only if it contains every word. No column holds both "revenue" and "customer".
  "March" and "2026" are data values, not metadata. The server answered `matches: []`,
  `tables: []`, `complete: true`, with its fixed `hint`: "Nothing matched every word. Try fewer
  words or other words (a synonym, a column or table name), or browse with list_tables and
  describe_schema." Codestral did not act on the hint. It paraphrased it to the user as the final
  answer, all six times ("I could not find any tables or columns that match ... Please try again
  with fewer or different words"). The server's answer was correct and was not misleading; the
  model stopped early. The same single words find the right column on this server: `revenue`
  gives `transactions.amount`, and `spending category` gives `transactions.category`.
- **Q2, two trials of 3 calls:** the compound search was empty. The next two searches found
  `customers.segment` and `accounts.balance`. The answer names both but leaves out the join key
  `accounts.customer_id`, so it is wrong under the fixed rules. 0.6.1 made the same miss on all
  three trials.
- **Q2, the trial cut at max_steps:** after the two good searches, the model wrote a join on
  `c.customer_id` (customers has `id`). `explain_query` answered `kind: column`,
  `identifier: c.customer_id`. The model then searched `customer_id` five times, which found only
  `accounts.customer_id`. It made up a cursor (`"demo.crm"`), which was refused as `invalid_argument`,
  explained the same wrong SQL twice more, and ran out of steps. It never called `describe_table`
  on `customers`. The server's errors were accurate; they did not suggest describing the table.
- **Q4 and Q5: right and shorter.** Q5 is where the table search pays off: `archived transactions
  2019` returns the table `transactions_2019` with its comment and no columns (a table-only hit).
  The model then calls `describe_table` and `execute_query`, 3 calls against 5 on 0.6.1.
- **0.6.1, Q1 and Q2 wrong on every trial**, for the same reason as in the first measurement: the
  answer leaves out the join keys. Q1 even joins `customers` without naming the path through
  `accounts`.
- No trial named a forbidden column, and no expected column was named without having been shown.

`search_columns` timing per schema is not visible: the harness records the wall time per trial
only (mean 5.1 s on 0.6.1, 4.8 s on 0.7.0), not per call.

## Reading, Mistral

The word search does what it was meant to do: once the model sends the right words, the column
or the table comes back at call 1 or 2, and the trials that use it are shorter. The loss comes
from one behaviour. Codestral sends the whole question as one search and treats an empty
answer, even with the hint, as the end. On 0.6.1 it has no such shortcut, so it walks the tree
and gets Q3 right. The cause is the AND of every word, together with a model that does not
follow the hint. Neither the questions nor the scoring rules explain it.

## Claude, per question (3 trials each)

| # | Question | Right 0.6.1 → 0.7.0 | Tool calls, per trial | What 0.7.0 searched |
|---|---|---|---|---|
| 1 | Revenue per customer | 3/3 → 3/3 | 10, 10, 10 → 6, 6, 6 | `revenue`, then `customer` (both found) |
| 2 | Segment with the largest balance | 3/3 → 3/3 | 8, 8, 8 → 6, 6, 5 | `customer segment`, `account balance` (found); once `exchange rate` (empty) |
| 3 | Spending per category, March 2026 | 3/3 → 3/3 | 7, 7, 7 → 4, 4, 4 | `spending category` (found), then `category amount` (empty, with the hint) |
| 4 | Accounts per currency | 3/3 → 3/3 | 7, 7, 7 → 3, 3, 3 | `account currency` (found) |
| 5 | Archived transactions, 2019 | 0/3 → 3/3 | 10, 10, 11 → 4, 4, 4 | `archived transactions 2019` (the table only), `archived transaction amount` (the twelve archive amounts) |

Claude's search calls were replayed in the same way (`2026-11-01-replay-claude-0.7.0.txt`).

- **Claude never sends the whole question as one search.** It searches one or two words at a
  time and moves on to `describe_table`, then
  `execute_query`. An empty search happened four times, and each time it came after searches
  that had already found the columns: `category amount` in the three Q3 trials, followed by
  `describe_table` on `transactions`, and `exchange rate` once in Q2, before the final answer.
  The hint never had to steer it, and an empty answer never stopped it.
- **Q5 on 0.6.1, 0/3: the answer is right, but the rule marks it wrong.** Claude walks the tree,
  describes `crm_archive.transactions_2019` and finds it empty. Then, to be thorough, it checks
  `demo.crm.transactions` for 2019 rows and several other archive years. The answer gives the
  right result (no 2019 transactions, the sum is NULL). It names
  `demo.crm_archive.transactions_2019.amount` as the column relied on, and lists
  `demo.crm.transactions.amount` among its cross-checks. The fixed rule counts any forbidden column
  named in the final answer, so the three trials are wrong. This is the strictness noted before the
  first run, and here it penalises 0.6.1. On 0.7.0 the search lands on the archive table at once,
  Claude does not look elsewhere, and all three trials are right in 4 calls. With that cross-check
  forgiven, 0.6.1 would score 15/15 as well. The fewer calls on 0.7.0 still hold.
- **Q2:** both versions name the join key `accounts.customer_id`. On 0.7.0 one trial also notes
  that one account (USD, customer 4) has no customer row visible to `carol_analyst` (the policy's
  row filter) and leaves it out, which is correct for that user.
- No expected column was named without having been shown.

## Reading, both models

The word search pays off with a model that searches by words: Claude needs about half the calls
on every question (8.5 → 4.5) and is right on every trial. Codestral sends the whole question as
one search and stops on the empty answer even with the hint, so the shorter path costs it Q3.
Input tokens per trial are a little higher on 0.7.0 for both models (the longer tool
descriptions), and output tokens are lower (fewer turns).
