# The sandbox access policy. Trino asks it three questions:
#   allow       may this user do this action?
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

# 2b. Nobody may act under another name. Trino asks ImpersonateUser when a client
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

is_customers(t) if {
	t.catalogName == "demo"
	t.schemaName == "crm"
	t.tableName == "customers"
}
