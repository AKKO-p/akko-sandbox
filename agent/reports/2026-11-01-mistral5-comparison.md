# Mistral, five trials per question, and the invalid-tool rule, 2026-11-01

Two follow-ups to the final measurement (`2026-11-01-final-comparison.md`).

1. A grading gap. Mistral 0.7.0 Q4 trial 3 was scored right, but it never ran a query. Its second
   "tool" name was the SQL text itself, and its answer invented the counts. The harness now
   scores a trial that calls a tool the server does not list as wrong (`Invalid tool`), on every
   server alike. The four final reports are scored again by this rule
   (`2026-11-01-final-rescored-*`).
2. A Mistral-only run with five trials per question on both servers, under the same guarded
   stack, scored by the new rule from the start.

## The invalid-tool rule

The trial, as recorded: call 1 `search_columns("accounts currency")`. Call 2 has the tool name
`{"sql": "SELECT currency, COUNT(*) AS account_count FROM demo.crm.accounts GROUP BY currency", "max_rows": 1000}`
and arguments that are a made-up result
(`{"columns": ["currency", "account_count"], "rows": [["EUR", 100], ["USD", 150], ["GBP", 50]], ...}`).
The answer is "There are 100 accounts in EUR, 150 in USD, and 50 in GBP". The truth is EUR 6,
USD 2, and 1 each for JPY, BRL, GBP and CAD. It was scored right only because it names
`demo.crm.accounts.currency`.

**What the harness sent back for the unknown call:** it forwarded the call to the server, as for
any call. The server answered with an MCP error, `is_error: true`, text
`Unknown tool: {"sql": "SELECT currency, ...", "max_rows": 1000}`. 0.6.1 and 0.7.0 give the same
answer (`2026-11-01-unknown-tool-probe.txt`, replayed without a model). The harness passed that
text to Mistral as the tool message, and Mistral then answered with its invented numbers.

**The rule:** a trial is wrong if any call names a tool the server does not list. The report
counts such trials (`Invalid tool`) and marks the call. The list is the one the server announced
in that session (`announced`). A report written before the list was recorded takes it from its
`server` line. `run.py --rescore REPORT.json --out NEW.md` applies the current rules to a stored
report. Unit tests cover the rule, the report column, the loop, rescoring, and the final Mistral
0.7.0 report scored again (84 tests).

### The four final runs, scored again

| Server × model | Right (was) | Right (now) | Invalid tool | max_tokens | Mean calls | Mean input tokens | Forbidden cited |
|---|---|---|---|---|---|---|---|
| 0.6.1 × Mistral | 10/15 | 10/15 | 0 | 0 | 5.9 | 9,957 | 0 |
| 0.7.0 × Mistral | 10/15 | **9/15** | 1 (Q4 trial 3) | 1 (Q2 trial 1) | 3.1 | 14,254 | 0 |
| 0.6.1 × Claude | 14/15 | 14/15 | 0 | 0 | 8.5 | 18,337 | 3 (one trial) |
| 0.7.0 × Claude | 14/15 | 14/15 | 0 | 0 | 4.9 | 25,853 | 2 (one trial) |

No other trial in the four runs, nor in the five-trial run below, calls an unlisted tool.

## Mistral, five trials per question

`codestral-latest`, temperature 0, random_seed 0, `--repeat 5`, `--max-steps 12`,
`--max-tokens 16000`, the same questions, rules and prompt. The stack is
`compose.yaml` plus `agent/compose.agent.yaml`, with Trino at `mem_limit: 2048m` and
`MALLOC_ARENA_MAX=2`, recreated for each server. Trino was checked before and after each run
(running, `OOMKilled=false`, `RestartCount=0`, same start time) and sampled every 10 s, with peaks
of 878 MiB on 0.6.1 and 890 MiB on 0.7.0. It never died or restarted. Script:
`2026-11-01-mistral5-measure.sh`; log: `2026-11-01-mistral5-run.log`.

| # | Question | Right 0.6.1 → 0.7.0 | Invalid tool | max_tokens | Mean calls 0.6.1 → 0.7.0 (per trial) | Mean input tokens 0.6.1 → 0.7.0 |
|---|---|---|---|---|---|---|
| 1 | Revenue per customer | 0/5 → 0/5 | 0 → 0 | 0 → 0 | 6.0 (6, 6, 6, 6, 6) → 2.8 (6, 1, 1, 1, 5) | 9,103 → 13,749 |
| 2 | Segment, largest balance | 0/5 → 4/5 | 0 → 0 | 0 → 1 | 6.2 (7, 6, 6, 6, 6) → 3.4 (4, 4, 1, 4, 4) | 11,400 → 16,308 |
| 3 | Spending per category, March 2026 | 5/5 → 5/5 | 0 → 0 | 0 → 0 | 6.2 → 3.8 | 10,967 → 16,679 |
| 4 | Accounts per currency | 5/5 → 5/5 | 0 → 0 | 0 → 0 | 5.4 → 1.8 | 9,495 → 9,400 |
| 5 | Archived transactions, 2019 | 5/5 → 5/5 | 0 → 0 | 0 → 0 | 5.0 → 3.0 | 9,119 → 14,598 |
| | **Total** | **15/25 → 19/25** | **0 → 0** | **0 → 1** | **5.8 → 3.0** | **10,017 → 14,146** |

No forbidden column was cited in either run.

- Q1, wrong on both servers. On 0.6.1 every trial makes the same wrong join
  (`customers.id = transactions.account_id`). On 0.7.0 three trials stop after the one search
  `revenue customer` and answer "demo.crm.accounts.customer_id, demo.crm.customers.segment,
  demo.crm.transactions.amount": no `transactions.account_id`, and no query.
- Q2 is the difference. 0.6.1 writes the right query but never names the join key (0/5). 0.7.0
  is right 4/5. Its fifth trial is the same generation loop as in the final run: one search,
  then the column list repeated up to `max_tokens`.
- Q4 on 0.7.0, trial 5 answered after one search with the right column and no numbers. It
  invented nothing, and it calls no unlisted tool.

### Both Mistral runs together

| Mistral | Final run, 3 trials (rescored) | This run, 5 trials | Together |
|---|---|---|---|
| 0.6.1 | 10/15 | 15/25 | 25/40 |
| 0.7.0 | 9/15 | 19/25 | 28/40 |

Mistral's results swing more between runs than the gap between the servers: Q2 was 1/3 → 1/3 in
the final run, and 0/5 → 4/5 here. Neither run shows 0.7.0 below 0.6.1 by more than one trial,
and together 0.7.0 is three trials ahead.

## Why 0.7.0 sends more input tokens with fewer calls

Each model turn resends the system prompt, every tool definition, and the whole conversation so
far. The tool definitions and every tool response were measured on both servers, by replaying
the calls of these runs without a model (`2026-11-01-tool-sizes-*.json`, in characters of the
JSON the provider receives):

| | 0.6.1 | 0.7.0 |
|---|---|---|
| Tool definitions, all tools, per turn | 4,897 characters (6 tools) | 12,502 characters (8 tools) |
| of which `search_columns` | | 4,079 |
| `describe_schema` | | 1,625 |
| the six shared tools | 4,897 | 6,798 |
| Mean turns per Mistral trial | 6.8 | 4.0 |
| Definitions sent per trial | 33,100 | 49,500 |
| Tool results sent per trial (each result is resent on every later turn) | 2,600 | 4,900 |
| of which `search_columns` | | 3,600 (mean response 1,351 characters, up to 4,580) |
| Measured mean input tokens per Mistral trial | 10,017 | 14,146 |

**The weight is in the tool definitions, sent on every turn: 2.6 times larger on 0.7.0.** That
growth outweighs the 40 % fewer turns. The `search_columns` description alone is 4,079
characters. The six shared tools went from 4,897 to 6,798 characters, their descriptions
longer in 0.7. Tool results add little in comparison; on 0.7.0 most of them are `search_columns`
answers. Divided by about four characters a token, the two lines add up to the measured counts:
0.6.1 (33.1k + 2.6k) / 4 ≈ 8.9k tokens against 10.0k measured, 0.7.0 (49.5k + 4.9k) / 4 ≈ 13.6k
against 14.1k (the rest is the system prompt, the question and the model's own turns). Claude
follows the same pattern (18.3k → 25.9k). A server-side lever exists: shorter tool descriptions,
`search_columns` first, would cut the input on every turn without changing a result.
