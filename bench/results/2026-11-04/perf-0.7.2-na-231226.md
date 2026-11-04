# Bench run 2026-11-04T23:12:26Z-perf-0.7.2-na

| Field | Value |
|---|---|
| axis | perf |
| command | `bench/run.sh perf` |
| sandbox commit | `cd3a973dc353` |
| server | akkoai/akko-mcp-trino:0.7.2 (akko-mcp-trino 0.7.2) |
| server digest | `akkoai/akko-mcp-trino@sha256:2e2880ac15eeb9cecebc5d3af111dda715dd895e7a7e029dc36d787a732b6f81` |
| model | - |
| host at start | {"disk_free_gb": 1008.4, "disk_used_pct": 45.9, "loadavg": [6.32, 6.91, 7.0], "cpus": 16, "mem_available_gb": 13.1, "mem_total_gb": 62.8} |
| host at end | {"disk_free_gb": 1008.4, "disk_used_pct": 45.9, "loadavg": [7.32, 7.02, 7.02], "cpus": 16, "mem_available_gb": 13.1, "mem_total_gb": 62.8} |
| duration | 75 s |
| cost | 0.00 USD |

**8 pass, 0 fail, 0 not run, 0 invalid host.**

| Suite | Exit | Duration (s) | Project memory peak (MB) | Host available min (MB) |
|---|---|---|---|---|
| k6-validate | 0 | 73 | 1510.7 | 11830.9 |

| Image | Digest |
|---|---|
| akkoai/akko-mcp-trino:0.7.2 | `akkoai/akko-mcp-trino@sha256:2e2880ac15eeb9cecebc5d3af111dda715dd895e7a7e029dc36d787a732b6f81` |
| alpine/openssl:3.5.9 | `alpine/openssl@sha256:bf66acee200e5f4959af448eafc9be0634d8ecdf42205873c83cd5ddffb1cdfd` |
| ghcr.io/modelcontextprotocol/inspector:2.9.0 | `ghcr.io/modelcontextprotocol/inspector@sha256:de4f67a6f38a66afcf37b86a89d462cd6068f56e9e5ecfd267382c103492cb90` |
| openpolicyagent/opa:1.21.1-static | `openpolicyagent/opa@sha256:4675ab04ad1627f74741d2d9c5142698c79e18b7b09f192587d31d6dba20838e` |
| postgres:17.11-alpine | `postgres@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24` |
| quay.io/keycloak/keycloak:26.7.5 | `quay.io/keycloak/keycloak@sha256:37dbaf6f0722c9ec246335f36e1ef8b2e6cb960f7c27e0d8c615121a3d475a85` |
| trinodb/trino:482 | `trinodb/trino@sha256:90b35b7c603eaa1f889bf03981a62b75f998ee6c0f851d9f4e341b49a57022b6` |

| Case | Variant | Verdict | Check |
|---|---|---|---|
| PRF-K6-000 | direct | pass | bench/perf/validate.sh ran to its end with status 0 |
| PRF-K6-001 | direct | pass | the Inspector got 10 answers |
| PRF-K6-002 | direct | pass | k6 ran, a session per call {"calls": 10, "p50_ms": 139.3, "p95_ms": 1304.3, "p99_ms": 1797.5} |
| PRF-K6-003 | direct | pass | k6 got 10 answers |
| PRF-K6-004 | direct | pass | k6's answers are the Inspector's, once durations and ids are removed |
| PRF-K6-005 | direct | pass | k6 counted no MCP error |
| PRF-K6-006 | direct | pass | k6 ran, a session per virtual user {"calls": 20, "p50_ms": 141.9, "p95_ms": 1720.3, "p99_ms": 2037.2} |
| PRF-K6-007 | direct | pass | every one of the 20 answers is the Inspector's answer to its call |
