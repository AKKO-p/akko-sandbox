# Bench run 2026-11-01T17:09:00Z-correctness-0.6.1-codestral-latest

| Field | Value |
|---|---|
| axis | correctness |
| command | `bench/run.sh correctness --rescore agent/reports/2026-11-01-final-mistral-0.6.1.json` |
| sandbox commit | `cd3a973dc353` |
| server | akkoai/akko-mcp-trino:0.6.1 (trino-mcp (no version announced)) |
| server digest | `-` |
| model | codestral-latest |
| host at start | {"disk_free_gb": 1008.2, "disk_used_pct": 45.9, "loadavg": [9.29, 7.05, 6.3], "cpus": 16, "mem_available_gb": 10.6, "mem_total_gb": 62.8} |
| host at end | {"disk_free_gb": 1008.2, "disk_used_pct": 45.9, "loadavg": [9.29, 7.05, 6.3], "cpus": 16, "mem_available_gb": 10.6, "mem_total_gb": 62.8} |
| duration | 86 s |
| cost | - |

**3 pass, 2 fail, 0 not run, 0 invalid host.**
Right answers 10/15, 95% Wilson interval 0.42 to 0.85.
Unstable questions (neither 0/N nor N/N): COR-CRM-02.

| Suite | Exit | Duration (s) | Project memory peak (MB) | Host available min (MB) |
|---|---|---|---|---|
| agent/2026-11-01-final-mistral-0.6.1.json | 0 | 86 | - | - |

| Case | Variant | Verdict | Check |
|---|---|---|---|
| COR-CRM-01 | carol_analyst | fail | What is the revenue per customer? {"right": 0, "trials": 3} |
| COR-CRM-02 | carol_analyst | fail | Which customer segment holds the largest total account balance? {"right": 1, "trials": 3} |
| COR-CRM-03 | carol_analyst | pass | How much was spent in each spending category in March 2026? {"right": 3, "trials": 3} |
| COR-CRM-04 | carol_analyst | pass | How many accounts are held in each currency? {"right": 3, "trials": 3} |
| COR-CRM-05 | carol_analyst | pass | What was the total amount of the archived transactions booked in 2019? {"right": 3, "trials": 3} |
