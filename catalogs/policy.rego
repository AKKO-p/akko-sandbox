# The rules the catalogs profile adds to the sandbox's policy (opa/policy.rego), in the same
# package. catalogs/compose.atlas.yaml loads this file next to it; without the profile, OPA
# never reads it, and the sandbox's policy is the one the other checks were measured with.
package trino

# Analysts may not see when an account was opened: the column is left out of every listing
# and refused in a query, as rule 2a of opa/policy.rego does for viewers. The context of a
# data catalog must lose it too (tests/context.sh).
forbidden if {
	role == "analyst"
	input.action.operation in {"FilterColumns", "SelectFromColumns"}
	t := input.action.resource.table
	t.catalogName == "demo"
	t.schemaName == "crm"
	t.tableName == "accounts"
	"opened_on" in t.columns
}

# Nobody may see the canary, admins included: akko-mcp-trino serves a data catalog's
# context to a caller only while Trino hides this table from them (catalogs/canary.sql).
forbidden if {
	t := input.action.resource.table
	t.catalogName == "demo"
	t.schemaName == "mcp"
	t.tableName == "canary"
}

# Analysts do not see salary payments among the transactions.
rowFilters contains {"expression": "category <> 'salary'"} if {
	role == "analyst"
	t := input.action.resource.table
	t.catalogName == "demo"
	t.schemaName == "crm"
	t.tableName == "transactions"
}
