# Bench run 2026-11-04T23:34:20Z-security-0.7.0-na

| Field | Value |
|---|---|
| axis | security |
| command | `bench/run.sh security --suite v071 --image akkoai/akko-mcp-trino:0.7.0` |
| sandbox commit | `43d5247382ca` |
| server | akkoai/akko-mcp-trino:0.7.0 (akko-mcp-trino 0.7.0) |
| server digest | `akkoai/akko-mcp-trino@sha256:5a0d6c472d03d3ac106f110ffd9273ea4dfb7bba8a7a030b4153d70cc0d40b02` |
| model | - |
| host at start | {"disk_free_gb": 1008.3, "disk_used_pct": 45.9, "loadavg": [5.93, 6.91, 7.2], "cpus": 16, "mem_available_gb": 12.8, "mem_total_gb": 62.8} |
| host at end | {"disk_free_gb": 1008.3, "disk_used_pct": 45.9, "loadavg": [3.88, 6.06, 6.88], "cpus": 16, "mem_available_gb": 12.8, "mem_total_gb": 62.8} |
| duration | 82 s |
| cost | 0.00 USD |

**10 pass, 13 fail, 0 not run, 0 invalid host.**

| Suite | Exit | Duration (s) | Project memory peak (MB) | Host available min (MB) |
|---|---|---|---|---|
| v071 | 1 | 80 | 1615.4 | 11503.4 |

| Image | Digest |
|---|---|
| akkoai/akko-mcp-trino:0.7.0 | `akkoai/akko-mcp-trino@sha256:5a0d6c472d03d3ac106f110ffd9273ea4dfb7bba8a7a030b4153d70cc0d40b02` |
| alpine/openssl:3.5.9 | `alpine/openssl@sha256:bf66acee200e5f4959af448eafc9be0634d8ecdf42205873c83cd5ddffb1cdfd` |
| ghcr.io/modelcontextprotocol/inspector:2.9.0 | `ghcr.io/modelcontextprotocol/inspector@sha256:de4f67a6f38a66afcf37b86a89d462cd6068f56e9e5ecfd267382c103492cb90` |
| openpolicyagent/opa:1.21.1-static | `openpolicyagent/opa@sha256:4675ab04ad1627f74741d2d9c5142698c79e18b7b09f192587d31d6dba20838e` |
| postgres:17.11-alpine | `postgres@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24` |
| quay.io/keycloak/keycloak:26.7.5 | `quay.io/keycloak/keycloak@sha256:37dbaf6f0722c9ec246335f36e1ef8b2e6cb960f7c27e0d8c615121a3d475a85` |
| trinodb/trino:482 | `trinodb/trino@sha256:90b35b7c603eaa1f889bf03981a62b75f998ee6c0f851d9f4e341b49a57022b6` |

| Case | Variant | Verdict | Check |
|---|---|---|---|
| SEC-R-000 | direct | fail | tests/v071.sh ran to its end with status 0 (exit status 1) |
| SEC-R-001 | direct | fail | carol: SHOW STATS FOR demo.crm.customers |
| SEC-R-002 | direct | fail | carol: SHOW STATS FOR (SELECT * FROM demo.crm.customers) |
| SEC-R-003 | direct | fail | carol: EXPLAIN SELECT * FROM demo.crm.customers |
| SEC-R-004 | direct | fail | carol: EXPLAIN (TYPE IO) SELECT * FROM demo.crm.customers |
| SEC-R-005 | direct | fail | carol: SHOW CREATE TABLE demo.crm.customers |
| SEC-R-006 | direct | fail | carol: SHOW GRANTS ON TABLE demo.crm.customers |
| SEC-R-007 | direct | fail | carol: SHOW SESSION |
| SEC-R-008 | direct | fail | alice too: SHOW STATS |
| SEC-R-009 | direct | fail | a valid read answers valid |
| SEC-R-010 | direct | fail | no plan, no filter, no mask in it |
| SEC-R-011 | direct | pass | an unknown column says its kind |
| SEC-R-012 | direct | pass | dave cannot check a table he may not read |
| SEC-R-013 | direct | pass | SHOW TABLES |
| SEC-R-014 | direct | pass | SHOW COLUMNS |
| SEC-R-015 | direct | pass | DESCRIBE |
| SEC-R-016 | direct | pass | carol's e-mails stay masked |
| SEC-R-017 | direct | pass | carol sees European customers only |
| SEC-R-018 | direct | pass | (private case) |
| SEC-R-019 | direct | pass | (private case) |
| SEC-R-020 | direct | fail | SHOW CREATE stays refused |
| SEC-R-021 | direct | fail | the start says what is opened |
| SEC-R-022 | direct | pass | --check refuses SHOW STAT (exit 2) |
