# The sandbox access policy. Trino asks it three questions:
#   allow       may this user do this action?
#   batch       which of these resources may this user see? (the filter operations)
#   rowFilters  which rows of this table may this user see?
#   columnMask  how is this column shown to this user?
# akko-mcp-trino decides none of it: it only sends the query as the user.
package trino

# Who is who. A real deployment reads groups from the token or a directory;
# a plain table keeps the demo readable.
roles := {
	"alice_admin": "admin",
	"carol_analyst": "analyst",
	"dave_viewer": "viewer",
}

user := input.context.identity.user

role := roles[user]

# 1. Known users may use Trino, except what a rule below forbids.
#    Unknown users may do nothing.
default allow := false

allow if {
	role
	not forbidden
}

# 2. Viewers may not open the customers table: it holds personal data.
forbidden if {
	role == "viewer"
	is_customers(input.action.resource.table)
}

# 2a. Viewers may not see account balances: the column is left out of every
#     listing (FilterColumns: information_schema, system.jdbc, SHOW COLUMNS,
#     DESCRIBE) and refused in a query (SelectFromColumns). Trino asks
#     FilterColumns through batch (rule 5), which applies this same rule to each
#     column. Reading information_schema and system.jdbc stays allowed: Trino
#     filters them with this same rule.
forbidden if {
	role == "viewer"
	input.action.operation in {"FilterColumns", "SelectFromColumns"}
	t := input.action.resource.table
	t.catalogName == "demo"
	t.schemaName == "crm"
	t.tableName == "accounts"
	"balance" in t.columns
}

# 2b. Viewers may not use the tpcds catalog, which tests/v07.sh adds: Trino does
#     not even list it to them.
#     The catalog's own operations (AccessCatalog, FilterCatalogs, ShowSchemas,
#     CreateSchema) name it as resource.catalog.name; the operations on one of
#     its schemas or tables name it as resource.schema.catalogName or
#     resource.table.catalogName, which the second rule reads.
forbidden if {
	role == "viewer"
	input.action.resource.catalog.name == "tpcds"
}

forbidden if {
	role == "viewer"
	input.action.resource[_].catalogName == "tpcds"
}

# 2c. Nobody may act under another name. Trino asks ImpersonateUser when a client
#     names a user (X-Trino-User) other than the one its token proves: refused,
#     except for the accounts listed here, such as akko-mcp-trino's own account in
#     its impersonation mode (list it, and give it a role above). The sandbox runs
#     the jwt mode, where no one impersonates, so the list is empty.
impersonators := set()

forbidden if {
	input.action.operation == "ImpersonateUser"
	input.action.resource.user.user != user
	not user in impersonators
}

# 3. Everyone but an admin sees e-mail addresses masked: ***@example.com
columnMask := {"expression": "'***' || substr(email, strpos(email, '@'))"} if {
	role != "admin"
	input.action.resource.column.columnName == "email"
}

# 4. Analysts see European customers only.
rowFilters contains {"expression": "country IN ('DE', 'ES', 'FR', 'IT', 'NL')"} if {
	role == "analyst"
	is_customers(input.action.resource.table)
}

# 5. Batch. Trino filters a listing (catalogs, schemas, tables, columns) with
#    opa.policy.batched-uri: one request carries every resource of the listing in
#    input.action.filterResources, and the answer is the indexes of those the user
#    may see. Without it Trino asks `allow` once per resource, which saturates
#    OPA's request queue on a table of a few hundred columns.
#    Each index is kept when `allow` accepts the same action on that one resource,
#    so the two paths, one question per resource or one for all, cannot disagree:
#    the rules above are written once, over input.action.resource.
batch contains i if {
	input.action.operation != "FilterColumns"
	some i, resource in input.action.filterResources
	allow with input.action.resource as resource
}

# FilterColumns is the one exception in shape: a single resource, the table, whose
# `columns` lists the columns to filter, and the indexes are those of the columns.
# Each column is asked as a table of that one column, as `allow` is asked.
batch contains i if {
	input.action.operation == "FilterColumns"
	count(input.action.filterResources) == 1
	table := input.action.filterResources[0].table
	some i, column in table.columns
	allow with input.action.resource as {"table": object.union(table, {"columns": [column]})}
}

is_customers(t) if {
	t.catalogName == "demo"
	t.schemaName == "crm"
	t.tableName == "customers"
}
