# Agent run, 2026-10-30 17:52 UTC

| Setting | Value |
|---|---|
| provider | anthropic |
| model_requested | claude-sonnet-5-5 |
| model_returned |  |
| server | trino-mcp 0.7.0, 8 tools: describe_schema, describe_table, execute_query, explain_query, list_catalogs, list_schemas, list_tables, search_columns |
| server_image | akko-mcp-trino:0.7.0-rc |
| mcp_url | http://mcp:3000/mcp |
| persona | carol_analyst |
| questions | reports/keycheck-questions.json |
| repeat | 1 |
| max_steps | 12 |
| max_tokens | 16000 |
| sampling | API defaults (the Messages API takes no temperature); output tokens include thinking, so tokens compare server against server for one model, never across providers |

| # | Trials | Right answers | Tool calls | First expected column at call | All expected columns at call | Input tokens | Output tokens | Wall time (s) | Named, never shown | Stop |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 1 | 0/1 | 0 | - | - | 0 | 0 | 0.9 | 0/1 | error: BadRequestError 400 |
| total | 1 | 0/1 | 0 | | | 0 | 0 | 0.9 | 0/1 | |

Totals add up each question's median; right answers and trials count every trial.

## 1. What is the revenue per customer?

### Trial 1: 0 tool calls, error: BadRequestError 400, not right

Tools called: none

| Column | Kind | First shown at call | Named in the answer |
|---|---|---|---|
| `demo.crm.transactions.amount` | expected | - | no |
| `demo.crm.transactions.account_id` | expected | - | no |
| `demo.crm.accounts.customer_id` | expected | - | no |

No final answer. Last text:

```text
(none)
```
