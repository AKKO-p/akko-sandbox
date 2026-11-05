# Bench run 2026-11-01T17:48:00Z-correctness-0.7.0-codestral-latest

Rescored on 2026-11-05T00:06:06Z: the report agent/reports/2026-11-01-mistral5-0.7.0-4105967.json (added by `6a1f09dd3df6`), scored again by the rules of `5a507463e425`. The run itself is the report's; no host state is recorded.

| Field | Value |
|---|---|
| axis | correctness |
| command | `bench/run.sh correctness --rescore agent/reports/2026-11-01-mistral5-0.7.0-4105967.json` |
| scoring commit | `5a507463e425` |
| seed | - |
| server | akko-mcp-trino:0.7.0-4105967 (trino-mcp 0.7.0) |
| server digest | `-` |
| model | codestral-latest |
| host at start | - |
| host at end | - |
| duration | 293 s |
| cost | - |

**4 pass, 1 fail, 0 not run, 0 invalid host.**
Right answers 19/25, 95% Wilson interval 0.57 to 0.89.
Unstable questions (neither 0/N nor N/N): COR-CRM-02.

| Suite | Exit | Duration (s) | Project memory peak (MB) | Host available min (MB) |
|---|---|---|---|---|
| agent/2026-11-01-mistral5-0.7.0-4105967.json | 0 | 293 | - | - |

| Case | Variant | Verdict | Check |
|---|---|---|---|
| COR-CRM-01 | carol_analyst | fail | What is the revenue per customer? {"right": 0, "trials": 5} |
| COR-CRM-02 | carol_analyst | pass | Which customer segment holds the largest total account balance? {"right": 4, "trials": 5} |
| COR-CRM-03 | carol_analyst | pass | How much was spent in each spending category in March 2026? {"right": 5, "trials": 5} |
| COR-CRM-04 | carol_analyst | pass | How many accounts are held in each currency? {"right": 5, "trials": 5} |
| COR-CRM-05 | carol_analyst | pass | What was the total amount of the archived transactions booked in 2019? {"right": 5, "trials": 5} |
