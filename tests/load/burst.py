"""Calls one tool of the MCP server N times at once, each call from a session of its own.

Run by tests/load.sh in the history container, on the back network:

    python burst.py <url> <tool> '<arguments as JSON>' <n> [<seconds between two starts>]

The token is read from the variable TOKEN, never printed. Every session is opened first, each
on a connection of its own; then the calls start together, or one every <seconds> when that
is above 0. Prints one JSON object per call: its number, when it started and ended (Unix
time), and the text of the tool's answer, or the error. Speaks the Streamable HTTP transport
of MCP with httpx only, so that nothing but the image's own libraries is needed.
"""

import asyncio
import json
import os
import sys
import time

import httpx

URL, TOOL, ARGS, N = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), int(sys.argv[4])
SPREAD = float(sys.argv[5]) if len(sys.argv) > 5 else 0.0
TIMEOUT = 300.0


def message(response: httpx.Response) -> dict:
    """The JSON-RPC message of an answer, sent as JSON or as one server-sent event."""
    response.raise_for_status()
    if response.headers.get("content-type", "").startswith("text/event-stream"):
        for line in response.text.splitlines():
            if line.startswith("data:"):
                found = json.loads(line[5:])
                if "id" in found:
                    return found
        raise ValueError("no answer in the event stream")
    return response.json()


async def session(client: httpx.AsyncClient) -> dict:
    headers = {
        "Authorization": "Bearer " + os.environ["TOKEN"],
        "Accept": "application/json, text/event-stream",
        "Content-Type": "application/json",
    }
    answer = await client.post(URL, headers=headers, json={
        "jsonrpc": "2.0", "id": 0, "method": "initialize",
        "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                   "clientInfo": {"name": "akko-sandbox-load", "version": "1"}}})
    version = message(answer)["result"]["protocolVersion"]
    headers["MCP-Protocol-Version"] = version
    if "mcp-session-id" in answer.headers:
        headers["Mcp-Session-Id"] = answer.headers["mcp-session-id"]
    await client.post(URL, headers=headers,
                      json={"jsonrpc": "2.0", "method": "notifications/initialized"})
    return headers


async def one(i: int, client: httpx.AsyncClient, headers: dict, go: asyncio.Event) -> dict:
    await go.wait()
    await asyncio.sleep(i * SPREAD)
    start = time.time()
    try:
        answer = await client.post(URL, headers=headers, json={
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": TOOL, "arguments": ARGS}})
        found = message(answer)
        text = found["result"]["content"][0]["text"] if "result" in found else None
        error = None if "result" in found else json.dumps(found.get("error"))
    except Exception as exc:  # noqa: BLE001 - reported as the call's error
        text, error = None, type(exc).__name__
    return {"i": i, "start": start, "end": time.time(), "text": text, "error": error}


async def main() -> None:
    clients = [httpx.AsyncClient(timeout=TIMEOUT) for _ in range(N)]
    try:
        sessions = await asyncio.gather(*(session(c) for c in clients))
        go = asyncio.Event()
        calls = [asyncio.create_task(one(i, c, h, go))
                 for i, (c, h) in enumerate(zip(clients, sessions))]
        go.set()
        for done in await asyncio.gather(*calls):
            print(json.dumps(done))
    finally:
        await asyncio.gather(*(c.aclose() for c in clients))


asyncio.run(main())
