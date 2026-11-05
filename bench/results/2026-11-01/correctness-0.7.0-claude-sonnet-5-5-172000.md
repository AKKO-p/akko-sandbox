# Bench run 2026-11-01T17:20:00Z-correctness-0.7.0-claude-sonnet-5-5

Rescored on 2026-11-05T00:06:05Z: the report agent/reports/2026-11-01-final-anthropic-0.7.0-4105967.json (added by `6a1f09dd3df6`), scored again by the rules of `5a507463e425`. The run itself is the report's; no host state is recorded.

| Field | Value |
|---|---|
| axis | correctness |
| command | `bench/run.sh correctness --rescore agent/reports/2026-11-01-final-anthropic-0.7.0-4105967.json` |
| scoring commit | `5a507463e425` |
| seed | - |
| server | akko-mcp-trino:0.7.0-4105967 (trino-mcp 0.7.0) |
| server digest | `-` |
| model | claude-sonnet-5-5 |
| host at start | - |
| host at end | - |
| duration | 173 s |
| cost | 0.90 USD |

**5 pass, 0 fail, 0 not run, 0 invalid host.**
Right answers 14/15, 95% Wilson interval 0.70 to 0.99.
Unstable questions (neither 0/N nor N/N): COR-CRM-05.

| Suite | Exit | Duration (s) | Project memory peak (MB) | Host available min (MB) |
|---|---|---|---|---|
| agent/2026-11-01-final-anthropic-0.7.0-4105967.json | 0 | 173 | - | - |

| Case | Variant | Verdict | Check |
|---|---|---|---|
| COR-CRM-01 | carol_analyst | pass | What is the revenue per customer? {"right": 3, "trials": 3} |
| COR-CRM-02 | carol_analyst | pass | Which customer segment holds the largest total account balance? {"right": 3, "trials": 3} |
| COR-CRM-03 | carol_analyst | pass | How much was spent in each spending category in March 2026? {"right": 3, "trials": 3} |
| COR-CRM-04 | carol_analyst | pass | How many accounts are held in each currency? {"right": 3, "trials": 3} |
| COR-CRM-05 | carol_analyst | pass | What was the total amount of the archived transactions booked in 2019? {"right": 2, "trials": 3} |
