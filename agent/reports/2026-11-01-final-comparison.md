# Final measurement, akko-mcp-trino 0.6.1 against 0.7.0 (4105967), 2026-11-01

The third measurement, after the per-word pass (akko-mcp-trino `main` 4105967, PR #31: a
multi-word search with no full match returns the partial matches per word, value advice in the
tool description, a column hint on `kind: column` errors). The two earlier measurements stay in
this folder as history.

**Headline: on both models, 0.7.0 is exactly as correct as 0.6.1 and uses fewer tool calls.**

| Server × model | Right answers | Mean tool calls | Mean input tokens | Mean output tokens | Forbidden columns cited |
|---|---|---|---|---|---|
| 0.6.1 × Mistral | 10/15 | 5.9 | 9,957 | 228 | 0 |
| 0.7.0 × Mistral | 10/15 | 3.1 | 14,254 | 1,206 (148 without the max_tokens trial) | 0 |
| 0.6.1 × Claude | 14/15 | 8.5 | 18,337 | 1,113 | 3 (one trial) |
| 0.7.0 × Claude | 14/15 | 4.9 | 25,853 | 834 | 2 (one trial) |

No wrong trial on 0.7.0 is caused by a server answer that is wrong, misleading or missing (see the
classification below).

## Setup

| | |
|---|---|
| Sandbox | AKKO-p/akko-sandbox `main` 6dd0554; compose files `compose.yaml` and `agent/compose.agent.yaml` (this branch's version, which runs Trino with `mem_limit: 2048m` and `MALLOC_ARENA_MAX=2`, as `tests/compose.v07.yaml` does); the v07 overlays themselves were not used, since they also change the catalogs and the page sizes |
| Before | `akkoai/akko-mcp-trino:0.6.1`: 6 tools, announces no version |
| After | `akko-mcp-trino:0.7.0-4105967`, built on the Linux host from akko-mcp-trino `main` 4105967: 8 tools, announces `trino-mcp 0.7.0` |
| Script | `2026-11-01-final-measure.sh`, its log `2026-11-01-final-run.log` |
| Stack | recreated for each server (`up --force-recreate`); Trino checked before and after each run (running, `OOMKilled=false`, `RestartCount=0`, same start time, 2048 MiB, `MALLOC_ARENA_MAX=2`), its memory sampled every 10 s (`2026-11-01-final-trino-rss-*.txt`); a guard would have stopped the run at any death or restart. It never triggered. |
| Questions, rules, prompt, limits | unchanged since the first measurement; persona `carol_analyst`, `--max-steps 12`, `--max-tokens 16000` for every run |
| Mistral | `codestral-latest` (as returned), temperature 0, random_seed 0, `--repeat 3` |
| Claude | `claude-sonnet-5-5` (as returned), API default sampling, `--repeat 3`; 1.62 USD |

Trino's peak memory per run: 0.6.1 849 MiB (Mistral) and 864 MiB (Claude); 0.7.0 912 MiB
(Mistral) and 1.52 GiB (Claude). A first attempt of this measurement, on the sandbox's default
1280 MB Trino, ended with Trino OOM-killed during the 0.7.0 Claude run. Its results were
discarded whole (1.49 USD of Claude spend).

## Per question (3 trials each)

| # | Mistral 0.6.1 → 0.7.0, right (calls) | Claude 0.6.1 → 0.7.0, right (calls) |
|---|---|---|
| 1 Revenue per customer | 0/3 (6, 6, 6) → 0/3 (3, 3, 4) | 3/3 (11, 10, 10) → 3/3 (6, 6, 6) |
| 2 Segment, largest balance | 1/3 (7, 7, 7) → 1/3 (1, 4, 4) | 3/3 (8, 8, 8) → 3/3 (5, 5, 8) |
| 3 Spending per category, March 2026 | 3/3 (6, 6, 7) → 3/3 (4, 4, 5) | 3/3 (7, 7, 7) → 3/3 (4, 4, 4) |
| 4 Accounts per currency | 3/3 (6, 5, 5) → 3/3 (2, 2, 2) | 3/3 (7, 7, 7) → 3/3 (3, 3, 3) |
| 5 Archived transactions, 2019 | 3/3 (5, 5, 5) → 3/3 (3, 3, 3) | 2/3 (10, 10, 10) → 2/3 (6, 6, 4) |

**Mistral Q3 is fixed:** 0/3 in the second measurement, 3/3 now. Two trials searched
`spending category` (without the date) and one `spending category March 2026`, which now
returns the partial match on `category`. Each trial then ran `describe_table`, `explain_query`
and `execute_query` with the right columns.

## Every wrong trial, read by hand

The harness records each call's arguments, not its result; the 0.7.0 calls below were replayed
afterwards without a model, as `carol_analyst` (`2026-11-01-final-replay-0.7.0.txt`).

### Mistral Q1, 0/3 on both versions

The question needs the amount (`transactions.amount`) and the path from a transaction to its
customer: `transactions.account_id` to `accounts.id`, and `accounts.customer_id` to
`customers.id`. Expected columns: `demo.crm.transactions.amount`,
`demo.crm.transactions.account_id`, `demo.crm.accounts.customer_id`.

- **0.6.1, trials 1 to 3 (6 calls each).** `list_catalogs`, `list_schemas`, `list_tables(crm)`,
  `describe_table(customers)`, `describe_table(transactions)`, then
  `SELECT c.id, c.full_name, SUM(t.amount) ... FROM demo.crm.customers c JOIN demo.crm.transactions t ON c.id = t.account_id`.
  It joins a customer id to an account id and never looks at `accounts`. The answer: "The revenue
  per customer is calculated by summing the amount from the transactions table for each customer
  in the customers table. ... demo.crm.customers.id, demo.crm.customers.full_name,
  demo.crm.transactions.amount". The number is wrong (the wrong join). **Model.**
- **0.7.0, trials 1 and 2 (3 calls).** `search_columns("revenue customer")`. The server answers
  `partial: true` with `transactions.amount` (word `revenue`), `accounts.customer_id` and
  `customers.segment` (word `customer`), and the three tables, plus the hint "pick the right one,
  or search again with a single word ..., then call describe_table on the table". Every expected
  column except `account_id` is in that answer, and `accounts.customer_id` is listed. The model
  describes `transactions` and `customers`, never `accounts`, runs no query, and answers
  "demo.crm.transactions.amount, demo.crm.customers.id". The answer is incomplete, with no path
  from a transaction to a customer. The server's answer was right and held the join column.
  **Model.**
- **0.7.0, trial 3 (4 calls).** The same search and descriptions, then `explain_query` on the
  right three-table join (`customers c JOIN accounts a ON c.id = a.customer_id JOIN transactions t ON a.id = t.account_id`).
  The answer lists only `demo.crm.customers.id`, `demo.crm.customers.full_name` and
  `demo.crm.transactions.amount`, and says "The query joins the customers, accounts, and
  transactions tables". The SQL is right. The answer is scored wrong because it does not name the
  join columns it relied on. **Grader (fixed rule: join keys must be named).**

Is the Q1 rule right? For the 0.6.1 trials and 0.7.0 trials 1 and 2 it is: the answer is wrong or
incomplete. For 0.7.0 trial 3 it is strict: the model wrote the right join and left its columns
out of the list. The rule was fixed before the first run and stays; read on the SQL alone, Mistral
0.7.0 would be 1/3 on Q1 and 0.6.1 0/3.

### Mistral Q2

Expected: `demo.crm.customers.segment`, `demo.crm.accounts.balance`, `demo.crm.accounts.customer_id`.

- **0.6.1, trials 1 and 2 (7 calls).** Tree walk, three `describe_table`, then the right query
  (`... FROM demo.crm.accounts a JOIN demo.crm.customers c ON a.customer_id = c.id ...`). The
  answer: "The customer segment that holds the largest total account balance is the business
  segment, with a total balance of 17620.75. ... demo.crm.accounts.balance,
  demo.crm.customers.segment". The value is right, but the join key it relied on is not named.
  **Grader (join key not named).**
- **0.7.0, trial 1, `max_tokens` after 1 call.** `search_columns("customer segment account balance")`
  answered in 1,699 characters: `partial: true`, with `accounts.balance`, `customers.segment`,
  `accounts.customer_id`, `transactions.account_id` and `transactions.amount`, each with its
  words, plus the hint. That is a small, correct answer that holds every expected column. Codestral
  then wrote "The customer segment with the largest total account balance is retail." and repeated
  the list "demo.crm.customers.segment, demo.crm.accounts.balance, demo.crm.accounts.customer_id,
  demo.crm.transactions.account_id, demo.crm.transactions.amount, ..." until the cap: 16,014
  output tokens, 63,170 characters, 123 s. This is a generation loop. The server's response was
  neither large nor misleading (the "retail" claim was made without any query). `--max-tokens` is
  16,000 for every run of every version. **Model.**
- **0.7.0, trial 2 (4 calls).** The same search, then `explain_query` with `c.customer_id`.
  The server answers `kind: column`, `identifier: c.customer_id`, and the new hint "Read the
  columns of demo.crm.customers with describe_table, then write the query again with a column it
  has". The model follows it: `describe_table(customers)`, then the right join explained. The
  answer is "demo.crm.customers.segment, demo.crm.accounts.balance": the right columns, without
  the join key. **Grader (join key not named),** as on 0.6.1. The column hint worked here.

### Claude Q5, trial 2 wrong on both versions

Expected: `demo.crm_archive.transactions_2019.amount`. Forbidden: `demo.crm.transactions.amount`
and the `amount` of every other archive year. The value is right on both versions: the 2019
archive table is empty, so the sum is NULL. The forbidden columns come from Claude's cross-checks.

- **0.6.1:** "The archived transactions booked in 2019 add up to nothing, because there aren't
  any. ... I also checked two other places ... The answer relies on these columns:
  demo.crm_archive.transactions_2019.amount, ..., demo.crm.transactions.amount, ...,
  demo.crm_archive.transactions_2018.amount, ..., demo.crm_archive.transactions_2020.amount, ...".
  **Grader (forbidden columns cited as cross-checks; the value is right).**
- **0.7.0:** after `search_columns("archived transactions")` (the twelve archive tables) and
  `search_columns("archive amount")` (the twelve archive `amount` columns), it queries 2019, then
  checks 2018 and 2020 for 2019 dates. "The archived transactions booked in 2019 have no total,
  because the archive table for 2019 has no rows. ... I also checked the 2018 and 2020 archive
  tables ... Columns relied on: demo.crm_archive.transactions_2019.amount, ...,
  demo.crm_archive.transactions_2018.amount, ..., demo.crm_archive.transactions_2020.amount, ...".
  It explicitly did not query the live table. The search answers listed the other years' tables,
  which is correct: they are all archived transactions. **Grader (forbidden columns cited as
  cross-checks; the value is right).**

## Classification of every wrong trial

| Model | Version | Question, trial | Cause | Why |
|---|---|---|---|---|
| Mistral | 0.6.1 | Q1, 1 to 3 | model | wrong join (`customers.id = transactions.account_id`), `accounts` never read |
| Mistral | 0.6.1 | Q2, 1 and 2 | grader | right query and value; join key `accounts.customer_id` not named |
| Mistral | 0.7.0 | Q1, 1 and 2 | model | no query, no path to the customer, although the search listed `accounts.customer_id` |
| Mistral | 0.7.0 | Q1, 3 | grader | right three-table join explained; join keys not named |
| Mistral | 0.7.0 | Q2, 1 | model | generation loop up to `max_tokens` after a 1,699-character correct search answer |
| Mistral | 0.7.0 | Q2, 2 | grader | right query after the column hint; join key not named |
| Claude | 0.6.1 | Q5, 2 | grader | right value; forbidden columns cited as cross-checks |
| Claude | 0.7.0 | Q5, 2 | grader | right value; forbidden columns cited as cross-checks |

**Server-caused wrong answers on 0.7.0: none.** Every 0.7.0 response in these trials was
replayed. The searches returned the expected columns (with `partial` and the hint when no single
column held every word), and the column error pointed to the right table to describe.

## Cost

Claude: 1.62 USD for this measurement, plus 1.49 USD for the discarded attempt (Trino
OOM-killed), so 3.11 USD in all for the final measurement, well under the 25 USD cap. Mistral
spend is not counted here.
