# Bench run 2026-11-05T00:06:13Z-security-0.7.2-na

| Field | Value |
|---|---|
| axis | security |
| command | `bench/run.sh security --seed 1311` |
| sandbox commit | `5a507463e425` |
| seed | 1311 |
| server | akkoai/akko-mcp-trino:0.7.2 (akko-mcp-trino 0.7.2) |
| server digest | `akkoai/akko-mcp-trino@sha256:2e2880ac15eeb9cecebc5d3af111dda715dd895e7a7e029dc36d787a732b6f81` |
| model | - |
| host at start | {"disk_free_gb": 1008.2, "disk_used_pct": 45.9, "loadavg": [5.85, 5.04, 4.32], "cpus": 16, "mem_available_gb": 12.8, "mem_total_gb": 62.8} |
| host at end | {"disk_free_gb": 1008.1, "disk_used_pct": 45.9, "loadavg": [14.02, 13.07, 10.53], "cpus": 16, "mem_available_gb": 12.7, "mem_total_gb": 62.8} |
| duration | 1257 s |
| cost | 0.00 USD |

**451 pass, 0 fail, 0 not run, 0 invalid host.**

| Suite | Exit | Duration (s) | Project memory peak (MB) | Host available min (MB) |
|---|---|---|---|---|
| smoke | 0 | 88 | 1664.1 | 11096.5 |
| gateway | 0 | 161 | 3215.6 | 9796.3 |
| v07 | 0 | 280 | 2230.2 | 10683.2 |
| v07-gateway | 0 | 347 | 3680.2 | 9468.9 |
| v071 | 0 | 84 | 1529.7 | 11557.1 |
| v071-gateway | 0 | 109 | 2579.1 | 10466.5 |
| leaks | 0 | 185 | 2256.8 | 10493.3 |

| Image | Digest |
|---|---|
| akkoai/akko-mcp-trino:0.7.2 | `akkoai/akko-mcp-trino@sha256:2e2880ac15eeb9cecebc5d3af111dda715dd895e7a7e029dc36d787a732b6f81` |
| alpine/openssl:3.5.9 | `alpine/openssl@sha256:bf66acee200e5f4959af448eafc9be0634d8ecdf42205873c83cd5ddffb1cdfd` |
| curlimages/curl:8.23.0 | `curlimages/curl@sha256:3fb7e13e5d179a845c97d78204f3f1064d1907037f26a3ebf91710571151fd93` |
| ghcr.io/modelcontextprotocol/inspector:2.9.0 | `ghcr.io/modelcontextprotocol/inspector@sha256:de4f67a6f38a66afcf37b86a89d462cd6068f56e9e5ecfd267382c103492cb90` |
| openpolicyagent/opa:1.21.1-static | `openpolicyagent/opa@sha256:4675ab04ad1627f74741d2d9c5142698c79e18b7b09f192587d31d6dba20838e` |
| postgres:17.11-alpine | `postgres@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24` |
| quay.io/keycloak/keycloak:26.7.5 | `quay.io/keycloak/keycloak@sha256:37dbaf6f0722c9ec246335f36e1ef8b2e6cb960f7c27e0d8c615121a3d475a85` |
| trinodb/trino:482 | `trinodb/trino@sha256:90b35b7c603eaa1f889bf03981a62b75f998ee6c0f851d9f4e341b49a57022b6` |
| trinodb/trino-gateway:22 | `trinodb/trino-gateway@sha256:85bfd9d9560937a9220c314e448f24a2ebc4c289f69c35dababd27bee7b5f87e` |

| Case | Variant | Verdict | Check |
|---|---|---|---|
| SEC-SMK-000 | direct | pass | tests/smoke.sh ran to its end with status 0 |
| SEC-SMK-001 | direct | pass | the core's tools, no more |
| SEC-SMK-002 | direct | pass | carol: Trino's current_user is carol_analyst |
| SEC-SMK-003 | direct | pass | alice: Trino's current_user is alice_admin |
| SEC-SMK-004 | direct | pass | carol: an answer, every e-mail masked |
| SEC-SMK-005 | direct | pass | carol: European customers only |
| SEC-SMK-006 | direct | pass | alice: every e-mail in clear |
| SEC-SMK-007 | direct | pass | alice: every customer, Europe and beyond |
| SEC-SMK-008 | direct | pass | two accounts, two different answers |
| SEC-SMK-009 | direct | pass | dave: refused by the policy |
| SEC-SMK-010 | direct | pass | carol: search_columns finds customers.email |
| SEC-SMK-011 | direct | pass | dave: the same search finds nothing, and is complete |
| SEC-SMK-012 | direct | pass | a write: refused by the server before Trino |
| SEC-SMK-013 | direct | pass | no token: 401 |
| SEC-SMK-014 | direct | pass | no token: the 401 says what to send |
| SEC-SMK-015 | direct | pass | forged token: 401 |
| SEC-SMK-016 | direct | pass | a token issued for Trino: 401 at the MCP server |
| SEC-SMK-017 | direct | pass | Trino over https without a token: 401 |
| SEC-SMK-018 | direct | pass | Trino refuses a token issued for the MCP server: 401 |
| SEC-SMK-019 | direct | pass | Trino, carol's own token, as carol: 5 customers |
| SEC-SMK-020 | direct | pass | Trino, carol's own token, as alice_admin: refused |
| SEC-SMK-021 | direct | pass | no token in the server log |
| SEC-SMK-022 | direct | pass | no client secret in the server log |
| SEC-SMK-023 | direct | pass | the server exchanged tokens at Keycloak |
| SEC-SMK-024 | direct | pass | the audit line names carol_analyst |
| SEC-SMK-025 | direct | pass | Inspector as carol_analyst: 5 customers |
| SEC-SMK-026 | direct | pass | Inspector as alice_admin: 10 customers |
| SEC-GW-000 | direct | pass | tests/gateway.sh ran to its end with status 0 |
| SEC-GW-001 | direct | pass | a second start is healthy |
| SEC-GW-002 | direct | pass | the second start kept the certificates |
| SEC-GW-003 | direct | pass | the second start registered both clusters again |
| SEC-GW-004 | direct | pass | the gateway still knows two clusters |
| SEC-GW-005 | direct | pass | the core's tools, no more |
| SEC-GW-006 | direct | pass | carol: Trino's current_user is carol_analyst |
| SEC-GW-007 | direct | pass | alice: Trino's current_user is alice_admin |
| SEC-GW-008 | direct | pass | carol: an answer, every e-mail masked |
| SEC-GW-009 | direct | pass | carol: European customers only |
| SEC-GW-010 | direct | pass | alice: every e-mail in clear |
| SEC-GW-011 | direct | pass | alice: every customer, Europe and beyond |
| SEC-GW-012 | direct | pass | two accounts, two different answers |
| SEC-GW-013 | direct | pass | dave: refused by the policy |
| SEC-GW-014 | direct | pass | carol: search_columns finds customers.email |
| SEC-GW-015 | direct | pass | dave: the same search finds nothing, and is complete |
| SEC-GW-016 | direct | pass | a write: refused by the server before Trino |
| SEC-GW-017 | direct | pass | no token: 401 |
| SEC-GW-018 | direct | pass | no token: the 401 says what to send |
| SEC-GW-019 | direct | pass | forged token: 401 |
| SEC-GW-020 | direct | pass | a token issued for Trino: 401 at the MCP server |
| SEC-GW-021 | direct | pass | the server reaches the gateway |
| SEC-GW-022 | direct | pass | the server cannot reach trino |
| SEC-GW-023 | direct | pass | the server cannot reach trino-2 |
| SEC-GW-024 | direct | pass | the server cannot reach trino by its address (172.19.0.8) |
| SEC-GW-025 | direct | pass | the gateway has no plain http port |
| SEC-GW-026 | direct | pass | the server cannot read the gateway's admin password |
| SEC-GW-027 | direct | pass | the server cannot change a backend: 403 |
| SEC-GW-028 | direct | pass | the server cannot deactivate a backend: 403 |
| SEC-GW-029 | direct | pass | the server cannot read the query history: 403 |
| SEC-GW-030 | direct | pass | a client's X-Forwarded-Proto is refused at the gateway: 406 |
| SEC-GW-031 | direct | pass | a client's X-Forwarded-For is refused at the gateway: 406 |
| SEC-GW-032 | direct | pass | the 10 queries each counted 5 customers |
| SEC-GW-033 | direct | pass | the gateway sent queries to trino |
| SEC-GW-034 | direct | pass | the gateway sent queries to trino-2 |
| SEC-GW-035 | direct | pass | every routed query carries a user's own name |
| SEC-GW-036 | direct | pass | carol's queries are recorded as carol_analyst |
| SEC-GW-037 | direct | pass | trino ran carol's count as carol_analyst |
| SEC-GW-038 | direct | pass | trino-2 ran carol's count as carol_analyst |
| SEC-GW-039 | direct | pass | 100 rows, cut by the server's cap |
| SEC-GW-040 | direct | pass | the answer says it was cut |
| SEC-GW-041 | direct | pass | the server says the time budget ran out |
| SEC-GW-042 | direct | pass | the server waited its 30 s budget |
| SEC-GW-043 | direct | pass | the slow query was cancelled by the client, once |
| SEC-GW-044 | direct | pass | gateway without a token: 401 |
| SEC-GW-045 | direct | pass | gateway with a token issued for the MCP server: 401 |
| SEC-GW-046 | direct | pass | gateway, carol's own token, as carol: 5 customers |
| SEC-GW-047 | direct | pass | gateway, carol's own token, as alice_admin: refused |
| SEC-GW-048 | direct | pass | no token in the server, gateway and Trino logs |
| SEC-GW-049 | direct | pass | no client secret in those logs |
| SEC-GW-050 | direct | pass | no gateway admin password in those logs |
| SEC-GW-051 | direct | pass | empty password: the gateway does not start |
| SEC-GW-052 | direct | pass | no password file: the gateway does not start |
| RES-TRN-001 | direct | pass | execute_query: kind unavailable |
| RES-TRN-002 | direct | pass | describe_schema: kind unavailable |
| SEC-V07-000 | direct | pass | tests/v07.sh ran to its end with status 0 |
| SEC-V07-001 | direct | pass | carol, 'revenue' in demo: transactions.amount |
| SEC-V07-002 | direct | pass | carol: the match carries its comment |
| SEC-V07-003 | direct | pass | carol: the search of demo is complete |
| SEC-V07-004 | direct | pass | carol, 'revenue' in every catalog: the same match, complete |
| SEC-V07-005 | direct | pass | every schema of demo, tpch and tpcds searched |
| SEC-V07-006 | direct | pass | carol, 'amount' in demo: 13 columns, over the row cap, resumed to the end |
| SEC-V07-007 | direct | pass | the first answer stopped at the row cap |
| SEC-V07-008 | direct | pass | dave, 'full_name' in demo: no match, complete |
| SEC-V07-009 | direct | pass | carol, 'full_name' in demo: customers.full_name |
| SEC-V07-010 | direct | pass | dave, 'email' in demo: no match, complete |
| SEC-V07-011 | direct | pass | carol, 'email' in demo: customers.email |
| SEC-V07-012 | direct | pass | dave, 'segment' in demo: no match, complete |
| SEC-V07-013 | direct | pass | carol, 'segment' in demo: customers.segment |
| SEC-V07-014 | direct | pass | carol: segment comes with its comment |
| SEC-V07-015 | direct | pass | dave, 'customer' in demo: accounts only |
| SEC-V07-016 | direct | pass | carol, 'customer' in demo: tables accounts and customers, across the cursor |
| SEC-V07-017 | direct | pass | the columns listed hold the word in their own name or comment: accounts.customer_id, customers.segment |
| SEC-V07-018 | direct | pass | the search is complete, with no hint: something was found |
| SEC-V07-019 | direct | pass | dave, 'customer' in demo: the table accounts only, customers is not his |
| SEC-V07-020 | direct | pass | dave, 'email' in every catalog: no match, complete, nothing left |
| SEC-V07-021 | direct | pass | every schema of demo and tpch searched |
| SEC-V07-022 | direct | pass | dave, 'mktsegment' in every catalog: tpch.customer in each tpch schema |
| SEC-V07-023 | direct | pass | dave, 'mktsegment': the table tpch.customer in tables too |
| SEC-V07-024 | direct | pass | every schema of demo and tpch searched once |
| SEC-V07-025 | direct | pass | dave's catalogs: tpcds is not one |
| SEC-V07-026 | direct | pass | carol's catalogs: tpcds too |
| SEC-V07-027 | direct | pass | carol, 'email' in every catalog: demo and tpcds |
| SEC-V07-028 | direct | pass | carol_analyst, 'movements': the table transactions, none of its columns |
| SEC-V07-029 | direct | pass | dave_viewer, 'movements': the table transactions, none of its columns |
| SEC-V07-030 | direct | pass | carol, 'movements amount': the column transactions.amount, and its table |
| SEC-V07-031 | direct | pass | carol, a word nothing holds: empty, complete, with a hint |
| SEC-V07-032 | direct | pass | carol, 'movements zzqxv': no table holds both words, so the pass by word: the table transactions, found by 'movements' |
| SEC-V07-033 | direct | pass | its hint is not the one of a search that found nothing |
| SEC-V07-034 | direct | pass | carol, two words nothing holds: empty, complete, the hint of a search that found nothing |
| SEC-V07-035 | direct | pass | carol, 'spending category March 2026': transactions.category, found by 'spending' and 'category' |
| SEC-V07-036 | direct | pass | partial, complete, the table transactions with it |
| SEC-V07-037 | direct | pass | 'march' and '2026' found nothing: no row names them |
| SEC-V07-038 | direct | pass | every schema of demo searched by the pass by word |
| SEC-V07-039 | direct | pass | carol, 'revenue balance': both columns, each by its word |
| SEC-V07-040 | direct | pass | dave, 'revenue balance': transactions.amount only, partial |
| SEC-V07-041 | direct | pass | carol, 'revenue segment': both columns, each by its word |
| SEC-V07-042 | direct | pass | dave, 'revenue segment': transactions.amount only, partial |
| SEC-V07-043 | direct | pass | carol, a wrong column of accounts: kind column, describe_table on accounts only |
| SEC-V07-044 | direct | pass | carol, a wrong column over two tables: both named, no other |
| SEC-V07-045 | direct | pass | dave, a wrong column of accounts: the advice names accounts |
| SEC-V07-046 | direct | pass | dave, a wrong column qualified by the visible table, next to customers: kind column, advice on accounts alone |
| SEC-V07-047 | direct | pass | dave, a column in neither: the advice names accounts, the table he sees, never customers |
| SEC-V07-048 | direct | pass | dave, the hidden column named: kind permission, no advice |
| SEC-V07-049 | direct | pass | dave, a hidden column and an unknown one: kind column, advice on accounts, no column named in it |
| SEC-V07-050 | direct | pass | the server says how many words a search takes (--check) |
| SEC-V07-051 | direct | pass | carol, exactly 8 words: searched, no error, nothing found, complete |
| SEC-V07-052 | direct | pass | the engine received queries with these words (the witness of the count below) |
| SEC-V07-053 | direct | pass | carol, 9 words: refused, the error names the words and the limit, no matches |
| SEC-V07-054 | direct | pass | refused before any query: the engine received none with these words |
| SEC-V07-055 | direct | pass | dave, describe_schema crm by pages: one page, accounts and transactions |
| SEC-V07-056 | direct | pass | dave, describe_schema crm: accounts without balance |
| SEC-V07-057 | direct | pass | carol, describe_schema crm by pages: two pages, three tables |
| SEC-V07-058 | direct | pass | carol: balance with its comment |
| SEC-V07-059 | direct | pass | carol: customers with its comment and its columns |
| SEC-V07-060 | direct | pass | dave, list_tables crm by pages: accounts and transactions |
| SEC-V07-061 | direct | pass | carol, list_tables crm: customers too |
| SEC-V07-062 | direct | pass | dave, 'balance' in demo: no match |
| SEC-V07-063 | direct | pass | carol, 'balance' in demo: accounts.balance |
| SEC-V07-064 | direct | pass | dave, describe_table accounts: four columns, none cut |
| SEC-V07-065 | direct | pass | alice, describe_table accounts: five, balance too |
| SEC-V07-066 | direct | pass | dave, SELECT * of accounts: an answer without balance |
| SEC-V07-067 | direct | pass | alice, SELECT * of accounts: balance too |
| SEC-V07-068 | direct | pass | dave, SELECT balance: refused by the policy |
| SEC-V07-069 | direct | pass | alice, SELECT balance: an answer |
| SEC-V07-070 | direct | pass | dave, SELECT count(*) of accounts: 12 |
| SEC-V07-071 | direct | pass | dave, an unknown column of accounts: kind column |
| SEC-V07-072 | direct | pass | dave, describe_schema of a schema that does not exist: kind schema |
| SEC-V07-073 | direct | pass | dave, describe_schema of tpcds, which he names: kind permission |
| SEC-V07-074 | direct | pass | carol, describe_schema of tpcds.tiny: its tables |
| SEC-V07-075 | direct | pass | dave, search_columns demo.crm_missing: kind schema, not found or not visible |
| SEC-V07-076 | direct | pass | the variant that hides crm_archive from viewers is loaded |
| SEC-V07-077 | direct | pass | dave, search_columns demo.crm_archive, hidden: the same answer as a missing schema |
| SEC-V07-078 | direct | pass | carol, search_columns demo.crm_archive, visible to her: the twelve tables and their amount columns, across the cursor |
| SEC-V07-079 | direct | pass | carol, crm_archive: the first page is incomplete and holds tables only (the row cap is shared) |
| SEC-V07-080 | direct | pass | the variant is removed |
| SEC-V07-081 | direct | pass | dave, crm_archive again: the first page is incomplete and holds tables only |
| SEC-V07-082 | direct | pass | dave, search_columns demo.crm_archive again: the same tables and columns |
| SEC-V07-083 | direct | pass | carol, search_columns demo.crm, visible: complete, transactions.amount |
| SEC-V07-084 | direct | pass | dave, search_columns tpcds.tiny, a catalog he may not use: Trino's kind permission |
| SEC-V07-085 | direct | pass | carol, search_columns tpcds.tiny, which she may use: matches, complete |
| SEC-V07-086 | direct | pass | OPA's log: Trino asked trino/batch |
| SEC-V07-087 | direct | pass | nothing dave got names 'customers' |
| SEC-V07-088 | direct | pass | nothing dave got names 'full_name' |
| SEC-V07-089 | direct | pass | nothing dave got names '"segment"' |
| SEC-V07-090 | direct | pass | nothing dave got names 'email' |
| SEC-V07-091 | direct | pass | nothing dave got names 'People and companies' |
| SEC-V07-092 | direct | pass | nothing dave got names 'Retail or business' |
| SEC-V07-093 | direct | pass | nothing dave got names 'balance' |
| SEC-V07-094 | direct | pass | nothing dave got names 'Current balance' |
| SEC-V07-095 | direct | pass | nothing dave got names 'tpcds' |
| SEC-V07-096 | direct | pass | dave got every answer asked of him, all JSON |
| SEC-V07-097 | direct | pass | dave_viewer in Trino, information_schema.columns |
| SEC-V07-098 | direct | pass | dave_viewer in Trino, system.jdbc.columns |
| SEC-V07-099 | direct | pass | dave_viewer in Trino, SHOW COLUMNS |
| SEC-V07-100 | direct | pass | dave_viewer in Trino, DESCRIBE |
| SEC-V07-101 | direct | pass | alice_admin in Trino, information_schema.columns |
| SEC-V07-102 | direct | pass | alice_admin in Trino, system.jdbc.columns |
| SEC-V07-103 | direct | pass | alice_admin in Trino, SHOW COLUMNS |
| SEC-V07-104 | direct | pass | alice_admin in Trino, DESCRIBE |
| SEC-V07-105 | direct | pass | dave in Trino, SELECT balance: PERMISSION_DENIED |
| SEC-V07-106 | direct | pass | dave in Trino, SELECT *: every column but balance |
| SEC-V07-107 | direct | pass | three pages of five at most |
| SEC-V07-108 | direct | pass | every table once, in order |
| SEC-V07-109 | direct | pass | truncated exactly when next_offset is set |
| SEC-V07-110 | direct | pass | four pages of three whole tables |
| SEC-V07-111 | direct | pass | every table once, in order |
| SEC-V07-112 | direct | pass | every table whole: its three columns |
| SEC-V07-113 | direct | pass | every table with its comment |
| SEC-V07-114 | direct | pass | a page of an offset past the end: empty, the last |
| SEC-V07-115 | direct | pass | the first answer is not complete |
| SEC-V07-116 | direct | pass | it names what it left, for lack of time |
| SEC-V07-117 | direct | pass | the last catalog, tpch, is among them |
| SEC-V07-118 | direct | pass | and it gives a cursor |
| SEC-V07-119 | direct | pass | resumed by its cursor, the search ends complete |
| SEC-V07-120 | direct | pass | every schema searched once over the calls |
| SEC-V07-121 | direct | pass | the same match as with the whole budget |
| SEC-V07-122 | direct | pass | an unknown column: kind column, identifier revenue |
| SEC-V07-123 | direct | pass | error keeps Trino's message |
| SEC-V07-124 | direct | pass | dave, a refused table: kind permission |
| SEC-V07-125 | direct | pass | a text too short: kind invalid_argument |
| SEC-V07-126 | direct | pass | an offset below 0: kind invalid_argument |
| SEC-V07-127 | direct | pass | the variant of the policy is loaded |
| SEC-V07-128 | direct | pass | describe_schema: an error that names system.jdbc.columns and asks to allow it |
| SEC-V07-129 | direct | pass | of kind permission or table |
| SEC-V07-130 | direct | pass | and no other answer |
| SEC-V07-131 | direct | pass | search_columns: an error that names system.jdbc.columns and asks to allow it |
| SEC-V07-132 | direct | pass | of kind permission or table |
| SEC-V07-133 | direct | pass | and no other answer |
| SEC-V07-134 | direct | pass | the variant is removed |
| SEC-V07-135 | direct | pass | describe_schema answers again |
| SEC-V07-136 | direct | pass | search_columns answers again |
| SEC-V07-137 | direct | pass | refused by the server: SELECT * FROM system.runtime.queries WHERE query_id = 'v07-guard' |
| SEC-V07-138 | direct | pass | refused by the server: SELECT * FROM system.jdbc.columns WHERE table_name = 'v07-guard' |
| SEC-V07-139 | direct | pass | refused by the server: SHOW TABLES FROM system.jdbc LIKE 'v07-guard' |
| SEC-V07-140 | direct | pass | an allowed statement with the marker: an answer |
| SEC-V07-141 | direct | pass | the engine received that one only |
| SEC-V07-142 | direct | pass | the server sent that form in section 5 |
| SEC-V07-143 | direct | pass | system.jdbc.columns, the server's form: 12 rows read |
| SEC-V07-144 | direct | pass | system.metadata.table_comments, the server's form: 4 rows read |
| SEC-V07-145 | direct | pass | OPA's log: every batch operation is one the rule names |
| SEC-V07-146 | direct | pass | OPA's log: the batch rule saw FilterCatalogs, FilterSchemas, FilterTables and FilterColumns |
| SEC-V07-147 | direct | pass | OPA's log: no FilterColumns asked one column at a time at allow |
| SEC-V07-150 | direct | pass | the server's log holds an audit line for each of the 120 tool calls |
| SEC-V07-151 | direct | pass | dave's and carol's among them |
| SEC-V07-152 | direct | pass | no token in the server log |
| SEC-V07-153 | direct | pass | no client secret in the server log |
| RES-TRN-001 | gateway | pass | execute_query: kind unavailable |
| RES-TRN-002 | gateway | pass | describe_schema: kind unavailable |
| SEC-V07-000 | gateway | pass | tests/v07.sh ran to its end with status 0 |
| SEC-V07-001 | gateway | pass | carol, 'revenue' in demo: transactions.amount |
| SEC-V07-002 | gateway | pass | carol: the match carries its comment |
| SEC-V07-003 | gateway | pass | carol: the search of demo is complete |
| SEC-V07-004 | gateway | pass | carol, 'revenue' in every catalog: the same match, complete |
| SEC-V07-005 | gateway | pass | every schema of demo, tpch and tpcds searched |
| SEC-V07-006 | gateway | pass | carol, 'amount' in demo: 13 columns, over the row cap, resumed to the end |
| SEC-V07-007 | gateway | pass | the first answer stopped at the row cap |
| SEC-V07-008 | gateway | pass | dave, 'full_name' in demo: no match, complete |
| SEC-V07-009 | gateway | pass | carol, 'full_name' in demo: customers.full_name |
| SEC-V07-010 | gateway | pass | dave, 'email' in demo: no match, complete |
| SEC-V07-011 | gateway | pass | carol, 'email' in demo: customers.email |
| SEC-V07-012 | gateway | pass | dave, 'segment' in demo: no match, complete |
| SEC-V07-013 | gateway | pass | carol, 'segment' in demo: customers.segment |
| SEC-V07-014 | gateway | pass | carol: segment comes with its comment |
| SEC-V07-015 | gateway | pass | dave, 'customer' in demo: accounts only |
| SEC-V07-016 | gateway | pass | carol, 'customer' in demo: tables accounts and customers, across the cursor |
| SEC-V07-017 | gateway | pass | the columns listed hold the word in their own name or comment: accounts.customer_id, customers.segment |
| SEC-V07-018 | gateway | pass | the search is complete, with no hint: something was found |
| SEC-V07-019 | gateway | pass | dave, 'customer' in demo: the table accounts only, customers is not his |
| SEC-V07-020 | gateway | pass | dave, 'email' in every catalog: no match, complete, nothing left |
| SEC-V07-021 | gateway | pass | every schema of demo and tpch searched |
| SEC-V07-022 | gateway | pass | dave, 'mktsegment' in every catalog: tpch.customer in each tpch schema |
| SEC-V07-023 | gateway | pass | dave, 'mktsegment': the table tpch.customer in tables too |
| SEC-V07-024 | gateway | pass | every schema of demo and tpch searched once |
| SEC-V07-025 | gateway | pass | dave's catalogs: tpcds is not one |
| SEC-V07-026 | gateway | pass | carol's catalogs: tpcds too |
| SEC-V07-027 | gateway | pass | carol, 'email' in every catalog: demo and tpcds |
| SEC-V07-028 | gateway | pass | carol_analyst, 'movements': the table transactions, none of its columns |
| SEC-V07-029 | gateway | pass | dave_viewer, 'movements': the table transactions, none of its columns |
| SEC-V07-030 | gateway | pass | carol, 'movements amount': the column transactions.amount, and its table |
| SEC-V07-031 | gateway | pass | carol, a word nothing holds: empty, complete, with a hint |
| SEC-V07-032 | gateway | pass | carol, 'movements zzqxv': no table holds both words, so the pass by word: the table transactions, found by 'movements' |
| SEC-V07-033 | gateway | pass | its hint is not the one of a search that found nothing |
| SEC-V07-034 | gateway | pass | carol, two words nothing holds: empty, complete, the hint of a search that found nothing |
| SEC-V07-035 | gateway | pass | carol, 'spending category March 2026': transactions.category, found by 'spending' and 'category' |
| SEC-V07-036 | gateway | pass | partial, complete, the table transactions with it |
| SEC-V07-037 | gateway | pass | 'march' and '2026' found nothing: no row names them |
| SEC-V07-038 | gateway | pass | every schema of demo searched by the pass by word |
| SEC-V07-039 | gateway | pass | carol, 'revenue balance': both columns, each by its word |
| SEC-V07-040 | gateway | pass | dave, 'revenue balance': transactions.amount only, partial |
| SEC-V07-041 | gateway | pass | carol, 'revenue segment': both columns, each by its word |
| SEC-V07-042 | gateway | pass | dave, 'revenue segment': transactions.amount only, partial |
| SEC-V07-043 | gateway | pass | carol, a wrong column of accounts: kind column, describe_table on accounts only |
| SEC-V07-044 | gateway | pass | carol, a wrong column over two tables: both named, no other |
| SEC-V07-045 | gateway | pass | dave, a wrong column of accounts: the advice names accounts |
| SEC-V07-046 | gateway | pass | dave, a wrong column qualified by the visible table, next to customers: kind column, advice on accounts alone |
| SEC-V07-047 | gateway | pass | dave, a column in neither: the advice names accounts, the table he sees, never customers |
| SEC-V07-048 | gateway | pass | dave, the hidden column named: kind permission, no advice |
| SEC-V07-049 | gateway | pass | dave, a hidden column and an unknown one: kind column, advice on accounts, no column named in it |
| SEC-V07-050 | gateway | pass | the server says how many words a search takes (--check) |
| SEC-V07-051 | gateway | pass | carol, exactly 8 words: searched, no error, nothing found, complete |
| SEC-V07-052 | gateway | pass | the engine received queries with these words (the witness of the count below) |
| SEC-V07-053 | gateway | pass | carol, 9 words: refused, the error names the words and the limit, no matches |
| SEC-V07-054 | gateway | pass | refused before any query: the engine received none with these words |
| SEC-V07-055 | gateway | pass | dave, describe_schema crm by pages: one page, accounts and transactions |
| SEC-V07-056 | gateway | pass | dave, describe_schema crm: accounts without balance |
| SEC-V07-057 | gateway | pass | carol, describe_schema crm by pages: two pages, three tables |
| SEC-V07-058 | gateway | pass | carol: balance with its comment |
| SEC-V07-059 | gateway | pass | carol: customers with its comment and its columns |
| SEC-V07-060 | gateway | pass | dave, list_tables crm by pages: accounts and transactions |
| SEC-V07-061 | gateway | pass | carol, list_tables crm: customers too |
| SEC-V07-062 | gateway | pass | dave, 'balance' in demo: no match |
| SEC-V07-063 | gateway | pass | carol, 'balance' in demo: accounts.balance |
| SEC-V07-064 | gateway | pass | dave, describe_table accounts: four columns, none cut |
| SEC-V07-065 | gateway | pass | alice, describe_table accounts: five, balance too |
| SEC-V07-066 | gateway | pass | dave, SELECT * of accounts: an answer without balance |
| SEC-V07-067 | gateway | pass | alice, SELECT * of accounts: balance too |
| SEC-V07-068 | gateway | pass | dave, SELECT balance: refused by the policy |
| SEC-V07-069 | gateway | pass | alice, SELECT balance: an answer |
| SEC-V07-070 | gateway | pass | dave, SELECT count(*) of accounts: 12 |
| SEC-V07-071 | gateway | pass | dave, an unknown column of accounts: kind column |
| SEC-V07-072 | gateway | pass | dave, describe_schema of a schema that does not exist: kind schema |
| SEC-V07-073 | gateway | pass | dave, describe_schema of tpcds, which he names: kind permission |
| SEC-V07-074 | gateway | pass | carol, describe_schema of tpcds.tiny: its tables |
| SEC-V07-075 | gateway | pass | dave, search_columns demo.crm_missing: kind schema, not found or not visible |
| SEC-V07-076 | gateway | pass | the variant that hides crm_archive from viewers is loaded |
| SEC-V07-077 | gateway | pass | dave, search_columns demo.crm_archive, hidden: the same answer as a missing schema |
| SEC-V07-078 | gateway | pass | carol, search_columns demo.crm_archive, visible to her: the twelve tables and their amount columns, across the cursor |
| SEC-V07-079 | gateway | pass | carol, crm_archive: the first page is incomplete and holds tables only (the row cap is shared) |
| SEC-V07-080 | gateway | pass | the variant is removed |
| SEC-V07-081 | gateway | pass | dave, crm_archive again: the first page is incomplete and holds tables only |
| SEC-V07-082 | gateway | pass | dave, search_columns demo.crm_archive again: the same tables and columns |
| SEC-V07-083 | gateway | pass | carol, search_columns demo.crm, visible: complete, transactions.amount |
| SEC-V07-084 | gateway | pass | dave, search_columns tpcds.tiny, a catalog he may not use: Trino's kind permission |
| SEC-V07-085 | gateway | pass | carol, search_columns tpcds.tiny, which she may use: matches, complete |
| SEC-V07-086 | gateway | pass | OPA's log: Trino asked trino/batch |
| SEC-V07-087 | gateway | pass | nothing dave got names 'customers' |
| SEC-V07-088 | gateway | pass | nothing dave got names 'full_name' |
| SEC-V07-089 | gateway | pass | nothing dave got names '"segment"' |
| SEC-V07-090 | gateway | pass | nothing dave got names 'email' |
| SEC-V07-091 | gateway | pass | nothing dave got names 'People and companies' |
| SEC-V07-092 | gateway | pass | nothing dave got names 'Retail or business' |
| SEC-V07-093 | gateway | pass | nothing dave got names 'balance' |
| SEC-V07-094 | gateway | pass | nothing dave got names 'Current balance' |
| SEC-V07-095 | gateway | pass | nothing dave got names 'tpcds' |
| SEC-V07-096 | gateway | pass | dave got every answer asked of him, all JSON |
| SEC-V07-097 | gateway | pass | dave_viewer in Trino, information_schema.columns |
| SEC-V07-098 | gateway | pass | dave_viewer in Trino, system.jdbc.columns |
| SEC-V07-099 | gateway | pass | dave_viewer in Trino, SHOW COLUMNS |
| SEC-V07-100 | gateway | pass | dave_viewer in Trino, DESCRIBE |
| SEC-V07-101 | gateway | pass | alice_admin in Trino, information_schema.columns |
| SEC-V07-102 | gateway | pass | alice_admin in Trino, system.jdbc.columns |
| SEC-V07-103 | gateway | pass | alice_admin in Trino, SHOW COLUMNS |
| SEC-V07-104 | gateway | pass | alice_admin in Trino, DESCRIBE |
| SEC-V07-105 | gateway | pass | dave in Trino, SELECT balance: PERMISSION_DENIED |
| SEC-V07-106 | gateway | pass | dave in Trino, SELECT *: every column but balance |
| SEC-V07-107 | gateway | pass | three pages of five at most |
| SEC-V07-108 | gateway | pass | every table once, in order |
| SEC-V07-109 | gateway | pass | truncated exactly when next_offset is set |
| SEC-V07-110 | gateway | pass | four pages of three whole tables |
| SEC-V07-111 | gateway | pass | every table once, in order |
| SEC-V07-112 | gateway | pass | every table whole: its three columns |
| SEC-V07-113 | gateway | pass | every table with its comment |
| SEC-V07-114 | gateway | pass | a page of an offset past the end: empty, the last |
| SEC-V07-115 | gateway | pass | the first answer is not complete |
| SEC-V07-116 | gateway | pass | it names what it left, for lack of time |
| SEC-V07-117 | gateway | pass | the last catalog, tpch, is among them |
| SEC-V07-118 | gateway | pass | and it gives a cursor |
| SEC-V07-119 | gateway | pass | resumed by its cursor, the search ends complete |
| SEC-V07-120 | gateway | pass | every schema searched once over the calls |
| SEC-V07-121 | gateway | pass | the same match as with the whole budget |
| SEC-V07-122 | gateway | pass | an unknown column: kind column, identifier revenue |
| SEC-V07-123 | gateway | pass | error keeps Trino's message |
| SEC-V07-124 | gateway | pass | dave, a refused table: kind permission |
| SEC-V07-125 | gateway | pass | a text too short: kind invalid_argument |
| SEC-V07-126 | gateway | pass | an offset below 0: kind invalid_argument |
| SEC-V07-127 | gateway | pass | the variant of the policy is loaded |
| SEC-V07-128 | gateway | pass | describe_schema: an error that names system.jdbc.columns and asks to allow it |
| SEC-V07-129 | gateway | pass | of kind permission or table |
| SEC-V07-130 | gateway | pass | and no other answer |
| SEC-V07-131 | gateway | pass | search_columns: an error that names system.jdbc.columns and asks to allow it |
| SEC-V07-132 | gateway | pass | of kind permission or table |
| SEC-V07-133 | gateway | pass | and no other answer |
| SEC-V07-134 | gateway | pass | the variant is removed |
| SEC-V07-135 | gateway | pass | describe_schema answers again |
| SEC-V07-136 | gateway | pass | search_columns answers again |
| SEC-V07-137 | gateway | pass | refused by the server: SELECT * FROM system.runtime.queries WHERE query_id = 'v07-guard' |
| SEC-V07-138 | gateway | pass | refused by the server: SELECT * FROM system.jdbc.columns WHERE table_name = 'v07-guard' |
| SEC-V07-139 | gateway | pass | refused by the server: SHOW TABLES FROM system.jdbc LIKE 'v07-guard' |
| SEC-V07-140 | gateway | pass | an allowed statement with the marker: an answer |
| SEC-V07-141 | gateway | pass | the engine received that one only |
| SEC-V07-142 | gateway | pass | the server sent that form in section 5 |
| SEC-V07-143 | gateway | pass | system.jdbc.columns, the server's form: 12 rows read |
| SEC-V07-144 | gateway | pass | system.metadata.table_comments, the server's form: 4 rows read |
| SEC-V07-145 | gateway | pass | OPA's log: every batch operation is one the rule names |
| SEC-V07-146 | gateway | pass | OPA's log: the batch rule saw FilterCatalogs, FilterSchemas, FilterTables and FilterColumns |
| SEC-V07-147 | gateway | pass | OPA's log: no FilterColumns asked one column at a time at allow |
| SEC-V07-150 | gateway | pass | the server's log holds an audit line for each of the 125 tool calls |
| SEC-V07-151 | gateway | pass | dave's and carol's among them |
| SEC-V07-152 | gateway | pass | no token in the server log |
| SEC-V07-153 | gateway | pass | no client secret in the server log |
| SEC-R-000 | direct | pass | tests/v071.sh ran to its end with status 0 |
| SEC-R-001 | direct | pass | carol: SHOW STATS FOR demo.crm.customers |
| SEC-R-002 | direct | pass | carol: SHOW STATS FOR (SELECT * FROM demo.crm.customers) |
| SEC-R-003 | direct | pass | carol: EXPLAIN SELECT * FROM demo.crm.customers |
| SEC-R-004 | direct | pass | carol: EXPLAIN (TYPE IO) SELECT * FROM demo.crm.customers |
| SEC-R-005 | direct | pass | carol: SHOW CREATE TABLE demo.crm.customers |
| SEC-R-006 | direct | pass | carol: SHOW GRANTS ON TABLE demo.crm.customers |
| SEC-R-007 | direct | pass | carol: SHOW SESSION |
| SEC-R-008 | direct | pass | alice too: SHOW STATS |
| SEC-R-009 | direct | pass | a valid read answers valid |
| SEC-R-010 | direct | pass | the answer holds nothing but valid |
| SEC-R-011 | direct | pass | an unknown column says its kind |
| SEC-R-012 | direct | pass | dave cannot check a table he may not read |
| SEC-R-013 | direct | pass | SHOW TABLES |
| SEC-R-014 | direct | pass | SHOW COLUMNS |
| SEC-R-015 | direct | pass | DESCRIBE |
| SEC-R-016 | direct | pass | carol's e-mails stay masked |
| SEC-R-017 | direct | pass | carol sees European customers only |
| SEC-R-018 | direct | pass | SHOW STATS runs |
| SEC-R-019 | direct | pass | explain_query prints the plan |
| SEC-R-020 | direct | pass | SHOW CREATE stays refused |
| SEC-R-021 | direct | pass | the start says what is opened |
| SEC-R-022 | direct | pass | --check refuses SHOW STAT (exit 2) |
| SEC-R-000 | gateway | pass | tests/v071.sh ran to its end with status 0 |
| SEC-R-001 | gateway | pass | carol: SHOW STATS FOR demo.crm.customers |
| SEC-R-002 | gateway | pass | carol: SHOW STATS FOR (SELECT * FROM demo.crm.customers) |
| SEC-R-003 | gateway | pass | carol: EXPLAIN SELECT * FROM demo.crm.customers |
| SEC-R-004 | gateway | pass | carol: EXPLAIN (TYPE IO) SELECT * FROM demo.crm.customers |
| SEC-R-005 | gateway | pass | carol: SHOW CREATE TABLE demo.crm.customers |
| SEC-R-006 | gateway | pass | carol: SHOW GRANTS ON TABLE demo.crm.customers |
| SEC-R-007 | gateway | pass | carol: SHOW SESSION |
| SEC-R-008 | gateway | pass | alice too: SHOW STATS |
| SEC-R-009 | gateway | pass | a valid read answers valid |
| SEC-R-010 | gateway | pass | the answer holds nothing but valid |
| SEC-R-011 | gateway | pass | an unknown column says its kind |
| SEC-R-012 | gateway | pass | dave cannot check a table he may not read |
| SEC-R-013 | gateway | pass | SHOW TABLES |
| SEC-R-014 | gateway | pass | SHOW COLUMNS |
| SEC-R-015 | gateway | pass | DESCRIBE |
| SEC-R-016 | gateway | pass | carol's e-mails stay masked |
| SEC-R-017 | gateway | pass | carol sees European customers only |
| SEC-R-018 | gateway | pass | SHOW STATS runs |
| SEC-R-019 | gateway | pass | explain_query prints the plan |
| SEC-R-020 | gateway | pass | SHOW CREATE stays refused |
| SEC-R-021 | gateway | pass | the start says what is opened |
| SEC-R-022 | gateway | pass | --check refuses SHOW STAT (exit 2) |
| SEC-LK-000 | direct | pass | bench/security/leaks.sh ran to its end with status 0 |
| SEC-LK-001 | direct | pass | the table's witness word is in Postgres |
| SEC-LK-002 | direct | pass | the column's witness word is in Postgres |
| SEC-LK-003 | direct | pass | alice reads the table's witness word in Trino |
| SEC-LK-004 | direct | pass | dave got 16 answers, all JSON from the server |
| SEC-LK-005 | direct | pass | dave's two plays are the same once ids and durations are removed |
| SEC-LK-006 | direct | pass | dave sees accounts, the scan has something to read |
| SEC-LK-007 | direct | pass | the server's log holds an audit line for each of dave's calls |
| SEC-LK-008 | direct | pass | system.runtime.queries holds dave's queries |
| SEC-LK-009 | direct | pass | OPA's decision log holds dave's decisions |
| SEC-LK-010 | direct | pass | the scan of dave's channels finds no marker |
| SEC-LK-011 | direct | pass | the scanner finds the table's witness word in carol's answers |
| SEC-LK-012 | direct | pass | the scanner finds the column's witness word in carol's answers |
| SEC-LK-013 | direct | pass | the scanner finds customers in carol's answers |
| SEC-LK-014 | direct | pass | the scanner finds balance in carol's answers |
| SEC-LK-015 | direct | pass | the scanner finds Current balance in carol's answers |
| SEC-LK-016 | direct | pass | the scanner finds People and companies in carol's answers |
