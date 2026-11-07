-- The context canary (catalogs/compose.atlas.yaml): a table the policy hides from every
-- user (catalogs/policy.rego). akko-mcp-trino serves a data catalog's context to a
-- caller only while Trino does not list this table to them. It holds nothing.
CREATE SCHEMA mcp;
CREATE TABLE mcp.canary (id integer);
