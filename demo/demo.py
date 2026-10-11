"""The sandbox demo: one question through MCP, asked by two users, two answers.

Each user gets a token from Keycloak, the official MCP client sends it to
akko-mcp-trino, which verifies it and passes it to Trino. Trino verifies it
again, runs the query as that user, and OPA decides what the user may see.

    python demo.py           show the demo
    python demo.py --check   the same, as assertions (exit 1 on any failure)
"""

import json
import os
import re
import sys
import time

import anyio
import httpx
from mcp import ClientSession
from mcp.client.streamable_http import create_mcp_http_client, streamable_http_client

TOKEN_URL = os.environ["KEYCLOAK_URL"] + "/realms/sandbox/protocol/openid-connect/token"
MCP_URL = os.environ["MCP_URL"]
PASSWORD = "demo"  # the sandbox's demo password, the same for every user
QUESTION = "SELECT full_name, email, country FROM demo.crm.customers ORDER BY id"
EUROPE = {"DE", "ES", "FR", "IT", "NL"}
TOOLS = ["describe_table", "execute_query", "explain_query", "list_catalogs", "list_schemas", "list_tables"]

COLOR = sys.stdout.isatty()
PACE = float(os.environ.get("DEMO_PACE") or 0)  # seconds between steps, for a recording


def paint(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m" if COLOR else text


def token(user: str) -> str:
    r = httpx.post(
        TOKEN_URL,
        data={"grant_type": "password", "client_id": "sandbox-mcp", "username": user, "password": PASSWORD},
        timeout=20,
    )
    r.raise_for_status()
    return r.json()["access_token"]


async def ask(user: str) -> dict:
    """Open an MCP session as `user`, list the tools, ask who Trino sees, ask the question."""
    http = create_mcp_http_client(headers={"Authorization": f"Bearer {token(user)}"})
    async with streamable_http_client(MCP_URL, http_client=http) as (read, write, *_):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = sorted(t.name for t in (await session.list_tools()).tools)

            async def run(sql: str) -> dict:
                result = await session.call_tool("execute_query", {"sql": sql})
                return json.loads(result.content[0].text)

            who = await run("SELECT current_user")
            answer = await run(QUESTION)
    return {
        "user": user,
        "tools": tools,
        "current_user": (who.get("rows") or [[who.get("error", "")]])[0][0],
        "rows": answer.get("rows", []),
        "error": answer.get("error", ""),
    }


def door() -> dict:
    """The MCP endpoint without a token, and with a token whose signature is forged."""
    forged = token("carol_analyst").rsplit(".", 1)[0] + ".Zm9yZ2VkLXNpZ25hdHVyZQ"
    return {
        "no_token": httpx.post(MCP_URL, json={}, timeout=10).status_code,
        "forged": httpx.post(MCP_URL, json={}, headers={"Authorization": f"Bearer {forged}"}, timeout=10).status_code,
    }


def collect() -> dict:
    return {
        "carol": anyio.run(ask, "carol_analyst"),
        "alice": anyio.run(ask, "alice_admin"),
        "dave": anyio.run(ask, "dave_viewer"),
        "door": door(),
    }


def side_by_side(left: dict, right: dict) -> None:
    width = 48

    def cell(row: list) -> str:
        name, email, country = row
        return f"{name:<15} {email:<27} {country}"

    def line(a: str, b: str, left_code: str = "", right_code: str = "") -> None:
        a = a.ljust(width)
        print(f"   {paint(left_code, a) if left_code else a} {paint(right_code, b) if right_code else b}")

    line(left["user"], right["user"], "1;33", "1;32")
    line("-" * (width - 2), "-" * (width - 2))
    rows_l, rows_r = left["rows"], right["rows"]
    for i in range(max(len(rows_l), len(rows_r))):
        line(cell(rows_l[i]) if i < len(rows_l) else "", cell(rows_r[i]) if i < len(rows_r) else "")
    line(f"{len(rows_l)} rows, e-mails masked, Europe only", f"{len(rows_r)} rows, nothing hidden", "33", "32")


def step(title: str, detail: str = "") -> None:
    time.sleep(PACE)
    print(paint("1", title) + detail, flush=True)


def show(r: dict) -> None:
    carol, alice, dave, gate = r["carol"], r["alice"], r["dave"], r["door"]
    step("1. The same question, sent through MCP (tool execute_query) by each user")
    print(f"   {paint('36', QUESTION)}")
    print()
    step("2. Who does Trino see?", "  SELECT current_user")
    for x in (carol, alice):
        print(f"   token of {x['user']:<14} ->  Trino runs the query as {paint('1', x['current_user'])}")
    print()
    step("3. Two answers, decided by the policy in Trino")
    side_by_side(carol, alice)
    print()
    step("4. dave_viewer asks the same question")
    refusal = re.search(r'message="([^"]+)"', dave["error"])
    print(f"   {paint('31', refusal.group(1) if refusal else dave['error'] or 'answered (unexpected)')}")
    print()
    step("5. At the door")
    print(f"   no token           ->  HTTP {paint('31', str(gate['no_token']))}")
    print(f"   forged signature   ->  HTTP {paint('31', str(gate['forged']))}")


def check(r: dict) -> int:
    carol, alice, dave, gate = r["carol"], r["alice"], r["dave"], r["door"]
    emails = {k: [row[1] for row in r[k]["rows"]] for k in ("carol", "alice")}
    countries = {k: {row[2] for row in r[k]["rows"]} for k in ("carol", "alice")}
    checks = [
        ("six tools, no more", carol["tools"] == TOOLS and alice["tools"] == TOOLS),
        ("carol: Trino's current_user is carol_analyst", carol["current_user"] == "carol_analyst"),
        ("alice: Trino's current_user is alice_admin", alice["current_user"] == "alice_admin"),
        ("carol: an answer, every e-mail masked", bool(emails["carol"]) and all(e.startswith("***@") for e in emails["carol"])),
        ("carol: European customers only", bool(countries["carol"]) and countries["carol"] <= EUROPE),
        ("alice: every e-mail in clear", bool(emails["alice"]) and all("@" in e and "*" not in e for e in emails["alice"])),
        ("alice: every customer, Europe and beyond", len(alice["rows"]) == 10 and not countries["alice"] <= EUROPE),
        ("two accounts, two different answers", carol["rows"] != alice["rows"]),
        ("dave: refused by the policy", not dave["rows"] and "Access Denied" in dave["error"]),
        ("no token: 401", gate["no_token"] == 401),
        ("forged token: 401", gate["forged"] == 401),
    ]
    for name, ok in checks:
        print(f"  {'OK  ' if ok else 'FAIL'}  {name}")
    failed = [n for n, ok in checks if not ok]
    if failed:
        print(json.dumps(r, indent=2))
    return 1 if failed else 0


def main() -> int:
    if "--check" in sys.argv[1:]:
        return check(collect())
    print(paint("1", "akko-mcp-trino sandbox: two accounts, one question, two answers"))
    print("Asking through MCP as carol_analyst, alice_admin and dave_viewer...")
    print()
    show(collect())
    return 0


if __name__ == "__main__":
    sys.exit(main())
