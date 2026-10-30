"""The harness's pure parts: tool formats, column matching, the report, the key check."""

import json
import os
import sys
from types import SimpleNamespace

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import run

SCHEMA = {
    "type": "object",
    "properties": {"text": {"type": "string"}, "catalog": {"type": "string", "default": ""}},
    "required": ["text"],
}
TOOLS = [
    SimpleNamespace(name="search_columns", description="Search columns.", input_schema=SCHEMA),
    SimpleNamespace(name="list_catalogs", description=None, input_schema={}),
]


def test_mistral_tools_wrap_each_schema_as_a_function():
    out = run.mistral_tools(TOOLS)
    assert out[0] == {
        "type": "function",
        "function": {"name": "search_columns", "description": "Search columns.", "parameters": SCHEMA},
    }
    assert out[1]["function"] == {
        "name": "list_catalogs",
        "description": "",
        "parameters": {"type": "object", "properties": {}},
    }


def test_anthropic_tools_carry_the_schema_as_input_schema():
    out = run.anthropic_tools(TOOLS)
    assert out[0] == {"name": "search_columns", "description": "Search columns.", "input_schema": SCHEMA}
    assert out[1] == {"name": "list_catalogs", "description": "", "input_schema": {"type": "object", "properties": {}}}


def test_conversion_leaves_the_server_schema_untouched():
    run.mistral_tools(TOOLS)
    run.anthropic_tools(TOOLS)
    assert TOOLS[1].input_schema == {}


@pytest.mark.parametrize(
    "answer",
    [
        "Use demo.crm.transactions.amount.",
        "SUM(crm.transactions.amount)",
        "transactions.amount, grouped by customer",
        'the column "demo"."crm"."transactions"."amount"',
        "`DEMO`.`CRM`.`TRANSACTIONS`.`AMOUNT`",
    ],
)
def test_answer_names_a_column_in_full_or_by_table(answer):
    assert run.answer_names(answer, "demo.crm.transactions.amount")


@pytest.mark.parametrize(
    "answer",
    [
        "the amount column",
        "t.amount",
        "crm.transactions.amount_eur",
        "other.transactions.amount",
        "crm_archive.transactions_2019.amount",
    ],
)
def test_answer_does_not_name_the_column(answer):
    assert not run.answer_names(answer, "demo.crm.transactions.amount")


def test_an_expected_column_is_four_parts():
    with pytest.raises(ValueError):
        run.split_column("crm.transactions.amount")


def test_search_result_shows_the_column():
    result = json.dumps(
        {
            "matches": [
                {"catalog": "demo", "schema": "crm", "table": "transactions", "column": "amount", "comment": "revenue"}
            ]
        }
    )
    assert run.result_shows({"text": "revenue"}, result, "demo.crm.transactions.amount")
    assert not run.result_shows({"text": "revenue"}, result, "demo.crm.accounts.balance")


def test_describe_schema_shows_a_column_under_its_table_only():
    result = json.dumps(
        {
            "tables": [
                {"table": "accounts", "columns": [{"column": "balance"}, {"column": "customer_id"}]},
                {"table": "transactions", "columns": [{"column": "amount"}]},
            ]
        }
    )
    assert run.result_shows({"catalog": "demo", "schema": "crm"}, result, "demo.crm.accounts.customer_id")
    assert not run.result_shows({"catalog": "demo", "schema": "crm"}, result, "demo.crm.accounts.amount")


def test_describe_table_names_the_table_in_its_arguments():
    result = json.dumps({"columns": ["Column", "Type"], "rows": [["amount", "decimal(12,2)"]]})
    assert run.result_shows({"table": "transactions"}, result, "demo.crm.transactions.amount")
    assert not run.result_shows({"table": "transactions_2019"}, result, "demo.crm.transactions.amount")


def test_a_query_row_that_names_the_table():
    result = json.dumps({"rows": [["crm", "transactions", "amount"], ["crm", "accounts", "balance"]]})
    sql = {"sql": "SELECT table_schema, table_name, column_name FROM demo.information_schema.columns"}
    assert run.result_shows(sql, result, "demo.crm.transactions.amount")
    assert not run.result_shows(sql, result, "demo.crm.transactions.balance")


def test_a_listing_of_tables_shows_no_column():
    result = json.dumps({"tables": ["accounts", "customers", "transactions"], "next_offset": None})
    assert not run.result_shows({"schema": "crm"}, result, "demo.crm.transactions.amount")


def test_a_result_that_is_not_json_is_read_as_text():
    assert run.result_shows({}, "see crm.transactions.amount", "demo.crm.transactions.amount")
    assert not run.result_shows({}, "amount", "demo.crm.transactions.amount")


def test_record_hits_and_names():
    r = run.Record(question="q", expected=["demo.crm.a.x", "demo.crm.b.y"], tools=["t1", "t2", "t3"])
    assert (r.calls, r.first_hit, r.all_hit, r.all_named) == (3, None, None, False)
    r.first_seen = {"demo.crm.b.y": 2}
    assert (r.first_hit, r.all_hit) == (2, None)
    r.first_seen["demo.crm.a.x"] = 3
    r.named = {"demo.crm.a.x": True, "demo.crm.b.y": True}
    assert (r.first_hit, r.all_hit, r.all_named) == (2, 3, True)


def test_collapse_folds_repeated_neighbours():
    assert run.collapse(["list_schemas", "describe_table", "describe_table", "describe_table", "list_tables"]) == (
        "list_schemas, describe_table x3, list_tables"
    )
    assert run.collapse([]) == "none"


META = {
    "date": "2026-10-30 12:00 UTC",
    "provider": "mistral",
    "model_requested": "codestral-latest",
    "model_returned": "codestral-2508",
    "server": "akko-mcp-trino 0.7.0",
    "server_image": "akko-mcp-trino:0.7-t7",
    "mcp_url": "http://mcp:3000/mcp",
    "persona": "carol_analyst",
    "questions": "agent/questions.json",
    "max_steps": 12,
    "max_tokens": 16000,
    "sampling": "temperature 0, random_seed 0",
}


def records():
    a = run.Record(
        question="What is the revenue per customer?",
        expected=["demo.crm.transactions.amount"],
        tools=["search_columns", "execute_query"],
        first_seen={"demo.crm.transactions.amount": 1},
        input_tokens=1200,
        output_tokens=80,
        answer="demo.crm.transactions.amount | summed",
        named={"demo.crm.transactions.amount": True},
        seconds=3.25,
        stop="answered",
    )
    b = run.Record(question="Q2", expected=["demo.crm.accounts.currency"], stop="max_steps", seconds=1.0)
    b.named = {"demo.crm.accounts.currency": False}
    return [a, b]


def test_report_lines_and_totals():
    text = run.render_report(META, records())
    assert "| server | akko-mcp-trino 0.7.0 |" in text
    assert "| model_returned | codestral-2508 |" in text
    assert "| server_image | akko-mcp-trino:0.7-t7 |" in text
    assert "| 1 | 2 | 1 | 1 | 1200 | 80 | yes | 3.2 | answered |" in text
    assert "| 2 | 0 | - | - | 0 | 0 | no | 1.0 | max_steps |" in text
    assert "| total | 2 | | | 1200 | 80 | 1/2 | 4.2 | |" in text
    assert "Tools called: search_columns, execute_query" in text
    assert "demo.crm.transactions.amount | summed" in text  # the answer in full, in a code block
    assert "(none)" in text


def test_two_runs_share_the_same_layout():
    other = dict(META, server="akko-mcp-trino 0.6.1")
    a = [line.split("|")[1] for line in run.render_report(META, records()).splitlines() if line.startswith("|")]
    b = [line.split("|")[1] for line in run.render_report(other, records()).splitlines() if line.startswith("|")]
    assert a == b


def test_report_json_has_the_derived_figures():
    data = json.loads(run.report_json(META, records()))
    assert data["meta"]["server"] == "akko-mcp-trino 0.7.0"
    assert data["questions"][0]["calls"] == 2
    assert data["questions"][0]["all_hit"] == 1
    assert data["questions"][1]["all_named"] is False


def test_the_questions_file_of_the_sandbox():
    questions = run.load_questions(os.path.join(os.path.dirname(run.__file__), "questions.json"))
    assert len(questions) == 5
    assert questions[0]["question"] == "What is the revenue per customer?"
    assert "demo.crm.transactions.amount" in questions[0]["expected"]


def test_a_questions_file_with_a_short_column_is_refused(tmp_path):
    path = tmp_path / "q.json"
    path.write_text(json.dumps([{"question": "q", "expected": ["transactions.amount"]}]))
    with pytest.raises(ValueError):
        run.load_questions(str(path))


def test_the_key_comes_from_the_chosen_provider_variable_only():
    assert run.api_key("mistral", {"MISTRAL_API_KEY": "k1", "ANTHROPIC_API_KEY": ""}) == "k1"
    with pytest.raises(SystemExit) as missing:
        run.api_key("anthropic", {"MISTRAL_API_KEY": "secret-value"})
    assert "ANTHROPIC_API_KEY" in str(missing.value)
    assert "secret-value" not in str(missing.value)


def test_arguments_defaults_and_checks():
    args = run.parse_args(["--provider", "anthropic", "--dry-run"])
    assert (args.model, args.persona, args.max_steps) == ("claude-sonnet-5-5", "carol_analyst", 12)
    assert run.parse_args(["--provider", "mistral", "--dry-run"]).model == "codestral-latest"
    assert run.parse_args(["--provider", "mistral", "--model", "m", "--out", "r.md"]).model == "m"
    with pytest.raises(SystemExit):
        run.parse_args(["--provider", "mistral"])  # no --out
    with pytest.raises(SystemExit):
        run.parse_args(["--provider", "mistral", "--dry-run", "--max-steps", "0"])


# The providers' turns and the loop, with fake clients and a fake MCP session:
# no model and no server is called.


class FakeMistralClient:
    def __init__(self, responses):
        self.responses, self.requests = list(responses), []
        self.chat = self

    async def complete_async(self, **kw):
        self.requests.append(kw)
        return self.responses.pop(0)


def mistral_response(content, calls=(), model="codestral-2508"):
    tool_calls = [SimpleNamespace(id=i, function=SimpleNamespace(name=n, arguments=a)) for i, n, a in calls] or None
    message = SimpleNamespace(content=content, tool_calls=tool_calls)
    return SimpleNamespace(
        choices=[SimpleNamespace(message=message, finish_reason="tool_calls" if calls else "stop")],
        usage=SimpleNamespace(prompt_tokens=100, completion_tokens=10),
        model=model,
    )


def mistral_chat(responses):
    chat = run.MistralChat.__new__(run.MistralChat)
    chat.client, chat.model, chat.max_tokens = FakeMistralClient(responses), "codestral-latest", 16000
    chat.sampling = "temperature 0, random_seed 0"
    return chat


def test_mistral_turn_sends_temperature_zero_and_reads_calls():
    import anyio

    chat = mistral_chat(
        [mistral_response("", [("c1", "search_columns", '{"text": "revenue"}'), ("c2", "list_catalogs", "not json")])]
    )
    messages = chat.start("q")
    turn = anyio.run(chat.turn, messages, [{"type": "function"}])
    sent = chat.client.requests[0]
    assert (sent["temperature"], sent["random_seed"], sent["tool_choice"], sent["model"]) == (
        0,
        0,
        "auto",
        "codestral-latest",
    )
    assert messages[0] == {"role": "system", "content": run.SYSTEM_PROMPT}
    assert turn.calls == [("c1", "search_columns", {"text": "revenue"}), ("c2", "list_catalogs", None)]
    assert messages[-1]["tool_calls"][0]["function"] == {"name": "search_columns", "arguments": '{"text": "revenue"}'}
    assert (turn.input_tokens, turn.output_tokens, turn.model) == (100, 10, "codestral-2508")
    chat.give_results(messages, [("c1", "search_columns", "{}", False)])
    assert messages[-1] == {"role": "tool", "tool_call_id": "c1", "name": "search_columns", "content": "{}"}


def test_mistral_turn_joins_text_chunks():
    import anyio

    chat = mistral_chat([mistral_response([SimpleNamespace(text="a "), SimpleNamespace(text="b")])])
    turn = anyio.run(chat.turn, chat.start("q"), [])
    assert (turn.calls, turn.text) == ([], "a b")


class FakeAnthropicClient:
    def __init__(self, responses):
        self.responses, self.requests = list(responses), []
        self.messages = self

    async def create(self, **kw):
        self.requests.append(kw)
        return self.responses.pop(0)


def anthropic_response(blocks, stop="end_turn"):
    usage = SimpleNamespace(
        input_tokens=90, cache_creation_input_tokens=None, cache_read_input_tokens=10, output_tokens=7
    )
    return SimpleNamespace(content=blocks, usage=usage, model="claude-sonnet-5-5", stop_reason=stop)


def test_anthropic_turn_sends_no_sampling_and_keeps_every_block():
    import anyio

    chat = run.AnthropicChat.__new__(run.AnthropicChat)
    thinking = SimpleNamespace(type="thinking", thinking="")
    use = SimpleNamespace(type="tool_use", id="t1", name="describe_schema", input={"catalog": "demo", "schema": "crm"})
    chat.client = FakeAnthropicClient([anthropic_response([thinking, use], "tool_use")])
    chat.model, chat.max_tokens = "claude-sonnet-5-5", 16000
    messages = chat.start("q")
    turn = anyio.run(chat.turn, messages, [{"name": "x"}])
    sent = chat.client.requests[0]
    assert sent["system"] == run.SYSTEM_PROMPT and "temperature" not in sent
    assert messages[-1] == {"role": "assistant", "content": [thinking, use]}
    assert turn.calls == [("t1", "describe_schema", {"catalog": "demo", "schema": "crm"})]
    assert (turn.input_tokens, turn.output_tokens, turn.stop) == (100, 7, "tool_use")
    chat.give_results(messages, [("t1", "describe_schema", "{}", True)])
    assert messages[-1]["content"] == [{"type": "tool_result", "tool_use_id": "t1", "content": "{}", "is_error": True}]


class FakeSession:
    def __init__(self, results):
        self.results, self.calls = results, []

    async def call_tool(self, name, arguments):
        self.calls.append((name, arguments))
        return SimpleNamespace(content=[SimpleNamespace(text=self.results[name])], is_error=False)


def fake_mcp(session):
    import contextlib

    init = SimpleNamespace(server_info=SimpleNamespace(name="akko-mcp-trino", version="0.7.0"))
    tools = [SimpleNamespace(name="search_columns", description="", input_schema=SCHEMA)]

    @contextlib.asynccontextmanager
    async def opened(args):
        yield session, init, tools

    return opened


def loop_args(max_steps=12):
    return SimpleNamespace(provider="mistral", max_steps=max_steps)


def test_ask_counts_calls_first_sight_and_the_answer(monkeypatch):
    import anyio

    found = json.dumps({"matches": [{"table": "transactions", "column": "amount"}]})
    session = FakeSession({"search_columns": found})
    monkeypatch.setattr(run, "mcp_session", fake_mcp(session))
    chat = mistral_chat(
        [
            mistral_response("", [("c1", "search_columns", '{"text": "revenue"}')]),
            mistral_response("", [("c2", "search_columns", '{"text": "customer"}')]),
            mistral_response("SUM(demo.crm.transactions.amount)"),
        ]
    )
    item = {"question": "q", "expected": ["demo.crm.transactions.amount"]}
    record, model, server = anyio.run(run.ask, loop_args(), chat, item)
    assert (record.calls, record.first_hit, record.all_named, record.stop) == (2, 1, True, "answered")
    assert (record.input_tokens, record.output_tokens) == (300, 30)
    assert (model, server) == ("codestral-2508", "akko-mcp-trino 0.7.0, 1 tools: search_columns")
    assert session.calls == [("search_columns", {"text": "revenue"}), ("search_columns", {"text": "customer"})]


def test_ask_stops_at_max_steps_and_refuses_bad_arguments(monkeypatch):
    import anyio

    session = FakeSession({"search_columns": "{}"})
    monkeypatch.setattr(run, "mcp_session", fake_mcp(session))
    chat = mistral_chat(
        [
            mistral_response("", [("c1", "search_columns", "{bad")]),
            mistral_response("", [("c2", "search_columns", "{}")]),
        ]
    )
    item = {"question": "q", "expected": ["demo.crm.transactions.amount"]}
    record, _, _ = anyio.run(run.ask, loop_args(max_steps=1), chat, item)
    assert (record.calls, record.stop, record.all_named) == (1, "max_steps", False)
    assert session.calls == []  # arguments that are not JSON never reach the server
    assert chat.client.requests[1]["messages"][-2]["content"] == json.dumps(
        {"error": "the arguments are not a JSON object"}
    )


def test_ask_records_an_error_by_its_kind_only(monkeypatch):
    import contextlib

    import anyio

    @contextlib.asynccontextmanager
    async def broken(args):
        raise ConnectionError("http://user:secret@host")
        yield

    monkeypatch.setattr(run, "mcp_session", broken)
    record, _, _ = anyio.run(run.ask, loop_args(), mistral_chat([]), {"question": "q", "expected": ["demo.crm.a.b"]})
    assert record.stop == "error: ConnectionError"


def test_a_server_without_a_version_says_so():
    init = SimpleNamespace(server_info=SimpleNamespace(name="trino-mcp", version=""))
    assert run.server_name(init, TOOLS) == "trino-mcp (no version announced), 2 tools: list_catalogs, search_columns"
