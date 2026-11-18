"""The HR scenario: a team manager, HR and an intern ask about salaries through MCP.

The same steps as demo.py, on fictional employees: each user's token goes to
akko-mcp-trino, which exchanges it for a token issued for Trino; Trino runs the
query as that user and OPA decides what the user may see. The manager sees her
own team, HR sees everyone, the intern is refused, and a write never reaches Trino.

    python demo.py --hr           show the scenario
    python demo.py --hr --check   the same, as assertions (exit 1 on any failure)
"""

import json
import re
import sys

import anyio

from demo import TOOLS, door, paint, step, token  # noqa: F401  (token used by door)
from mcp import ClientSession
from mcp.client.streamable_http import create_mcp_http_client, streamable_http_client
from demo import MCP_URL

ROWS = "SELECT full_name, team, salary, email FROM demo.hr.employees ORDER BY id"
AVERAGE = "SELECT count(*), round(avg(salary)) FROM demo.hr.employees"
SEARCH = {"text": "salary", "catalog": "demo"}
WRITE = "DELETE FROM demo.hr.employees WHERE team = 'Executive'"


async def ask(user: str) -> dict:
    http = create_mcp_http_client(headers={"Authorization": f"Bearer {token(user)}"})
    async with streamable_http_client(MCP_URL, http_client=http) as (read, write, *_):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = sorted(t.name for t in (await session.list_tools()).tools)

            async def run(sql: str) -> dict:
                return json.loads((await session.call_tool("execute_query", {"sql": sql})).content[0].text)

            who = await run("SELECT current_user")
            average = await run(AVERAGE)
            rows = await run(ROWS)
            search = json.loads((await session.call_tool("search_columns", SEARCH)).content[0].text)
            write = await run(WRITE)
    return {
        "user": user,
        "tools": tools,
        "current_user": (who.get("rows") or [[who.get("error", "")]])[0][0],
        "average": (average.get("rows") or [[None, None]])[0],
        "rows": rows.get("rows", []),
        "error": rows.get("error", "") or average.get("error", ""),
        "found": [f"{m['catalog']}.{m['schema']}.{m['table']}.{m['column']}" for m in search.get("matches", [])],
        "search_complete": search.get("complete"),
        "write": write.get("error", ""),
    }


def collect() -> dict:
    return {u: anyio.run(ask, u) for u in ("manager", "hr", "intern")} | {"door": door()}


def money(v) -> str:
    return f"{float(v):>9,.0f}" if v is not None else ""


def show(r: dict) -> None:
    m, h, i = r["manager"], r["hr"], r["intern"]
    step("1. The manager of the Sales team asks: what is the average salary of my team?", pause=False)
    print(f"   {paint('36', AVERAGE)}")
    print()
    step("2. Who does Trino see?", "  SELECT current_user")
    for x in (m, h):
        print(f"   token of {x['user']:<8} ->  Trino runs the query as {paint('1', x['current_user'])}")
    print()
    step("3. The same question, two answers decided by the policy in Trino")
    print(f"   manager  ->  {m['average'][0]} employees, average {money(m['average'][1]).strip()} EUR   (her team only)")
    print(f"   hr       ->  {h['average'][0]} employees, average {money(h['average'][1]).strip()} EUR   (everyone, executives included)")
    print(f"   {paint('36', ROWS)}")
    for row in m["rows"]:
        print(f"   manager  {row[0]:<16} {row[1]:<7} {money(row[2])}  {row[3]}")
    print()
    step("4. The intern asks the same question")
    refusal = re.search(r'message="([^"]+)"', i["error"])
    print(f"   {paint('31', refusal.group(1) if refusal else i['error'] or 'answered (unexpected)')}")
    print()
    step("5. Each one looks for a column about salaries (tool search_columns)")
    for x, code in ((m, "32"), (i, "31")):
        found = ", ".join(x["found"]) or "no match, the search is complete"
        print(f"   {x['user']:<8} ->  {paint(code, found)}")
    print()
    step("6. The intern asks the assistant to remove the executives from the table")
    print(f"   {paint('36', WRITE)}")
    print(f"   {paint('31', i['write'] or 'answered (unexpected)')}")


def check(r: dict) -> int:
    m, h, i, gate = r["manager"], r["hr"], r["intern"], r["door"]
    checks = [
        ("the core's nine tools, no more and no fewer", m["tools"] == h["tools"] == TOOLS),
        ("manager: Trino's current_user is manager", m["current_user"] == "manager"),
        ("hr: Trino's current_user is hr", h["current_user"] == "hr"),
        ("manager: her team only, 5 employees", len(m["rows"]) == 5 and {row[1] for row in m["rows"]} == {"Sales"}),
        ("manager: every e-mail masked", all(row[3].startswith("***@") for row in m["rows"])),
        ("hr: all 12 employees, e-mails in clear", len(h["rows"]) == 12 and all("*" not in row[3] for row in h["rows"])),
        ("two averages: 5 and 12 employees", m["average"][0] == 5 and h["average"][0] == 12),
        ("intern: refused by the policy", not i["rows"] and "Access Denied" in i["error"]),
        ("manager: search_columns finds employees.salary", m["found"] == ["demo.hr.employees.salary"] and m["search_complete"] is True),
        ("intern: the same search finds nothing, and is complete", i["found"] == [] and i["search_complete"] is True),
        ("intern: a write is refused by the server before Trino", "Read-only" in i["write"]),
        ("no token: 401", gate["no_token"] == 401),
        ("forged token: 401", gate["forged"] == 401),
        ("a token issued for Trino: 401 at the MCP server", gate["for_trino"] == 401),
    ]
    for name, ok in checks:
        print(f"  {'OK  ' if ok else 'FAIL'}  {name}")
    failed = [n for n, ok in checks if not ok]
    if failed:
        print(json.dumps(r, indent=2, default=str))
    return 1 if failed else 0


def main(args: list[str]) -> int:
    if "--check" in args:
        return check(collect())
    print(paint("1", "akko-mcp-trino sandbox, HR scenario: three accounts, one question, three outcomes"))
    print("Asking through MCP as manager, hr and intern...")
    print()
    show(collect())
    return 0
