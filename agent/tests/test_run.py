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


# When a tool result shows a column: every shape the servers return, 0.6.1 and 0.7 alike.

AMOUNT = "demo.crm.transactions.amount"


def test_search_result_shows_the_column():
    match = {"catalog": "demo", "schema": "crm", "table": "transactions", "column": "amount", "comment": "revenue"}
    result = json.dumps({"matches": [match]})
    assert run.result_shows({"text": "revenue"}, result, AMOUNT)
    assert not run.result_shows({"text": "revenue"}, result, "demo.crm.accounts.balance")


def test_a_search_match_in_another_table_never_inherits_the_arguments():
    # search_columns(text="transactions"): the text names the table, but each match says its own.
    match = {"catalog": "demo", "schema": "crm_archive", "table": "transactions_2019", "column": "amount"}
    result = json.dumps({"matches": [match]})
    assert not run.result_shows({"text": "transactions"}, result, AMOUNT)
    other_schema = {"schema": "crm_archive", "table": "transactions", "column": "amount"}
    assert not run.result_shows({"text": "x"}, json.dumps({"matches": [other_schema]}), AMOUNT)


def test_describe_schema_shows_a_column_under_its_table_only():
    result = json.dumps(
        {
            "catalog": "demo",
            "schema": "crm",
            "tables": [
                {"table": "accounts", "columns": [{"column": "balance"}, {"column": "customer_id"}]},
                {"table": "transactions", "columns": [{"column": "amount"}]},
            ],
        }
    )
    assert run.result_shows({"catalog": "demo", "schema": "crm"}, result, "demo.crm.accounts.customer_id")
    assert not run.result_shows({"catalog": "demo", "schema": "crm"}, result, "demo.crm.accounts.amount")


def test_describe_table_names_the_table_in_its_arguments():
    result = json.dumps({"columns": ["Column", "Type"], "rows": [["amount", "decimal(12,2)"]]})
    assert run.result_shows({"catalog": "demo", "schema": "crm", "table": "transactions"}, result, AMOUNT)
    assert run.result_shows({"table": "TRANSACTIONS"}, result, AMOUNT)
    assert not run.result_shows({"schema": "crm", "table": "transactions_2019"}, result, AMOUNT)
    assert not run.result_shows({"schema": "crm_archive", "table": "transactions"}, result, AMOUNT)


@pytest.mark.parametrize(
    "sql",
    [
        "SELECT * FROM demo.crm.transactions LIMIT 5",
        'SELECT * FROM "demo"."crm"."transactions" LIMIT 5',
        "select * from crm.transactions",
        "SELECT * FROM transactions",
        "SELECT t.amount FROM demo.crm.transactions t",
    ],
)
def test_a_query_on_the_table_shows_its_columns(sql):
    result = json.dumps({"columns": ["id", "account_id", "booked_at", "amount", "category"], "rows": [[1, 102]]})
    assert run.result_shows({"sql": sql}, result, AMOUNT)


@pytest.mark.parametrize(
    "sql",
    [
        "SELECT * FROM demo.crm_archive.transactions_2019",
        "SELECT * FROM demo.crm_archive.transactions",
        "SELECT * FROM demo.other.transactions",
        "SELECT * FROM demo.crm.accounts",
    ],
)
def test_a_query_on_another_table_does_not_show_the_column(sql):
    result = json.dumps({"columns": ["id", "booked_at", "amount"], "rows": []})
    assert not run.result_shows({"sql": sql}, result, AMOUNT)


def test_a_query_row_that_names_the_table():
    result = json.dumps({"rows": [["crm", "transactions", "amount"], ["crm", "accounts", "balance"]]})
    sql = {"sql": "SELECT table_schema, table_name, column_name FROM demo.information_schema.columns"}
    assert run.result_shows(sql, result, AMOUNT)
    assert not run.result_shows(sql, result, "demo.crm.transactions.balance")


def test_a_listing_of_tables_shows_no_column():
    result = json.dumps({"tables": ["accounts", "customers", "transactions"], "next_offset": None})
    assert not run.result_shows({"catalog": "demo", "schema": "crm"}, result, AMOUNT)


def test_a_qualified_name_anywhere_in_a_result():
    assert run.result_shows({}, "see crm.transactions.amount", AMOUNT)
    assert run.result_shows({}, json.dumps({"plan": 'ScanProject "demo"."crm"."transactions"."amount"'}), AMOUNT)
    assert not run.result_shows({}, "amount", AMOUNT)
    assert not run.result_shows({}, "crm_archive.transactions_2019.amount", AMOUNT)


# The verdict.


def trial(**kw):
    base = {"question": "q", "expected": [AMOUNT, "demo.crm.accounts.customer_id"], "forbidden": []}
    base.update(kw)
    return run.Record(**base)


def test_record_hits():
    r = trial(tools=["t1", "t2", "t3"])
    assert (r.calls, r.first_hit, r.all_hit, r.right) == (3, None, None, False)
    r.first_seen = {"demo.crm.accounts.customer_id": 2}
    assert (r.first_hit, r.all_hit) == (2, None)
    r.first_seen[AMOUNT] = 3
    assert (r.first_hit, r.all_hit) == (2, 3)


def test_a_final_answer_that_names_every_expected_column_is_right():
    r = trial(stop="answered")
    r.score("SUM(demo.crm.transactions.amount) by demo.crm.accounts.customer_id")
    assert r.right and r.forbidden_named == [] and r.other_named == []


def test_a_trial_stopped_at_max_steps_is_never_right():
    r = trial(stop="max_steps", last_text="demo.crm.transactions.amount and demo.crm.accounts.customer_id")
    assert r.named == {} and not r.right
    r.score(r.last_text)  # even scored by mistake, the stop decides
    assert not r.right


def test_a_forbidden_column_makes_the_answer_wrong():
    r = trial(stop="answered", forbidden=["demo.crm.accounts.balance"])
    r.score("demo.crm.transactions.amount, demo.crm.accounts.customer_id, plus demo.crm.accounts.balance")
    assert r.forbidden_named == ["demo.crm.accounts.balance"] and not r.right


def test_other_columns_are_recorded_without_changing_the_verdict():
    r = trial(stop="answered")
    r.score(
        "Join demo.crm.transactions to demo.crm.accounts: SUM(demo.crm.transactions.amount) "
        "by demo.crm.accounts.customer_id, demo.crm.customers.full_name; see t.amount, e.g. this."
    )
    assert r.other_named == ["demo.crm.customers.full_name"]
    assert r.right


def test_the_archive_question_refuses_the_current_table_and_other_years():
    q5 = run.load_questions(QUESTIONS)[4]
    r = run.Record(question=q5["question"], expected=q5["expected"], forbidden=q5["forbidden"], stop="answered")
    r.score("SUM(demo.crm_archive.transactions_2019.amount)")
    assert r.right
    r.score("SUM(demo.crm_archive.transactions_2019.amount) + SUM(demo.crm.transactions.amount)")
    assert r.forbidden_named == [AMOUNT] and not r.right
    r.score("SUM(demo.crm_archive.transactions_2019.amount) + SUM(crm_archive.transactions_2020.amount)")
    assert not r.right


def test_a_guess_is_marked_named_never_shown():
    r = trial(stop="answered", first_seen={AMOUNT: 1})
    r.score("demo.crm.transactions.amount, demo.crm.accounts.customer_id")
    assert r.right and r.never_shown == ["demo.crm.accounts.customer_id"]


def test_collapse_folds_repeated_neighbours():
    assert run.collapse(["list_schemas", "describe_table", "describe_table", "describe_table", "list_tables"]) == (
        "list_schemas, describe_table x3, list_tables"
    )
    assert run.collapse([]) == "none"


def test_spread_gives_median_and_range():
    assert run.spread([4, 4, 4], 3) == "4"
    assert run.spread([3, 6, 4], 3) == "4 (3-6)"
    assert run.spread([2, None, 4], 3) == "3 (2-4) [2/3]"
    assert run.spread([None], 1) == "-"


META = {
    "date": "2026-10-30 12:00 UTC",
    "provider": "anthropic",
    "model_requested": "claude-sonnet-5-5",
    "model_returned": "claude-sonnet-5-5",
    "server": "akko-mcp-trino 0.7.0",
    "server_image": "akko-mcp-trino:0.7-t7",
    "mcp_url": "http://mcp:3000/mcp",
    "persona": "carol_analyst",
    "questions": "agent/questions.json",
    "repeat": 3,
    "max_steps": 12,
    "max_tokens": 16000,
    "sampling": "API defaults",
}


def records():
    out = []
    for n, (calls, hit, tokens, right) in enumerate(
        [(2, 1, 1200, True), (4, 2, 1800, True), (3, None, 1500, False)], 1
    ):
        r = run.Record(
            question="What is the revenue per customer?",
            expected=[AMOUNT],
            forbidden=["demo.crm.accounts.balance"],
            trial=n,
            tools=["search_columns"] * calls,
            first_seen={AMOUNT: hit} if hit else {},
            input_tokens=tokens,
            output_tokens=80,
            seconds=3.0,
            stop="answered",
        )
        r.score("demo.crm.transactions.amount | summed" if right else "demo.crm.accounts.balance")
        out.append(r)
    b = run.Record(question="Q2", expected=["demo.crm.accounts.currency"], stop="max_steps", seconds=1.0, trial=1)
    b.last_text = "still looking at demo.crm.accounts.currency"
    out.append(b)
    return out


def test_report_lines_and_totals():
    text = run.render_report(META, records())
    assert "| server | akko-mcp-trino 0.7.0 |" in text
    assert "| server_image | akko-mcp-trino:0.7-t7 |" in text
    assert "| repeat | 3 |" in text
    assert (
        "| 1 | 3 | 2/3 | 3 (2-4) | 1.5 (1-2) [2/3] | 1.5 (1-2) [2/3] | 1500 (1200-1800) | 80 | 3 | 0/3 | 0/3 | answered x3 |"
        in text
    )
    assert "| 2 | 1 | 0/1 | 0 | - | - | 0 | 0 | 1 | 0/1 | 0/1 | max_steps |" in text
    assert "| total | 4 | 2/4 | 3 | | | 1500 | 80 | 4.0 | 0/4 | 0/4 | |" in text
    assert "### Trial 3: 3 tool calls, answered, not right" in text
    assert "| `demo.crm.accounts.balance` | forbidden | | yes |" in text
    assert "demo.crm.transactions.amount \\| summed" not in text  # code blocks keep the answer as written
    assert "demo.crm.transactions.amount | summed" in text
    assert "No final answer. Last text:" in text and "still looking at demo.crm.accounts.currency" in text


def test_two_runs_share_the_same_layout():
    other = dict(META, server="akko-mcp-trino 0.6.1", repeat=1)
    a = [line.split("|")[1] for line in run.render_report(META, records()).splitlines() if line.startswith("|")]
    b = [line.split("|")[1] for line in run.render_report(other, records()).splitlines() if line.startswith("|")]
    assert a == b


def test_report_json_keeps_every_trial():
    data = json.loads(run.report_json(META, records()))
    assert data["meta"]["repeat"] == 3
    assert [t["trial"] for t in data["trials"]] == [1, 2, 3, 1]
    assert data["trials"][0]["calls"] == 2 and data["trials"][0]["right"] is True
    assert data["trials"][2]["forbidden_named"] == ["demo.crm.accounts.balance"]
    assert data["trials"][3]["right"] is False


QUESTIONS = os.path.join(os.path.dirname(run.__file__), "questions.json")


def test_the_questions_file_of_the_sandbox():
    questions = run.load_questions(QUESTIONS)
    assert len(questions) == 5
    assert questions[0]["question"] == "What is the revenue per customer?"
    assert AMOUNT in questions[0]["expected"]
    assert all(q["forbidden"] for q in questions)
    assert AMOUNT in questions[4]["forbidden"]


@pytest.mark.parametrize(
    "entry",
    [
        {"question": "q", "expected": ["transactions.amount"], "forbidden": []},
        {"question": "q", "expected": [AMOUNT]},
        {"question": "q", "expected": [AMOUNT], "forbidden": [AMOUNT.upper()]},
    ],
)
def test_a_questions_file_is_checked(tmp_path, entry):
    path = tmp_path / "q.json"
    path.write_text(json.dumps([entry]))
    with pytest.raises((ValueError, TypeError)):
        run.load_questions(str(path))


def test_the_key_comes_from_the_chosen_provider_variable_only():
    assert run.api_key("mistral", {"MISTRAL_API_KEY": "k1", "ANTHROPIC_API_KEY": ""}) == "k1"
    with pytest.raises(SystemExit) as missing:
        run.api_key("anthropic", {"MISTRAL_API_KEY": "secret-value"})
    assert "ANTHROPIC_API_KEY" in str(missing.value)
    assert "secret-value" not in str(missing.value)


def test_arguments_defaults_and_checks():
    args = run.parse_args(["--provider", "anthropic", "--dry-run"])
    assert (args.model, args.persona, args.max_steps, args.repeat) == ("claude-sonnet-5-5", "carol_analyst", 12, 1)
    assert run.parse_args(["--provider", "mistral", "--dry-run"]).model == "codestral-latest"
    assert run.parse_args(["--provider", "mistral", "--model", "m", "--out", "r.md", "--repeat", "3"]).repeat == 3
    for bad in (["--provider", "mistral"], ["--provider", "mistral", "--dry-run", "--max-steps", "0"]):
        with pytest.raises(SystemExit):
            run.parse_args(bad)
    with pytest.raises(SystemExit):
        run.parse_args(["--provider", "mistral", "--dry-run", "--repeat", "0"])


def test_both_clients_build_as_the_harness_builds_them():
    # No network: the clients are built, never called. The parameters the turns send exist.
    import inspect

    mistral = run.MistralChat("not-a-key", "codestral-latest", 16000)
    params = inspect.signature(mistral.client.chat.complete_async).parameters
    for name in ("model", "messages", "tools", "tool_choice", "temperature", "random_seed", "max_tokens"):
        assert name in params
    claude = run.AnthropicChat("not-a-key", "claude-sonnet-5-5", 16000)
    params = inspect.signature(claude.client.messages.create).parameters
    for name in ("model", "max_tokens", "system", "tools", "messages"):
        assert name in params
    assert "temperature" not in params
    assert "anthropic-workspace-id" not in claude.client.default_headers


def test_the_workspace_id_is_sent_as_a_header_only_when_set():
    scoped = run.AnthropicChat("not-a-key", "claude-sonnet-5-5", 16000, {"ANTHROPIC_WORKSPACE_ID": "wrkspc_1"})
    assert scoped.client.default_headers["anthropic-workspace-id"] == "wrkspc_1"
    for env in ({}, {"ANTHROPIC_WORKSPACE_ID": ""}):
        assert "anthropic-workspace-id" not in run.AnthropicChat("k", "m", 1, env).client.default_headers


def test_the_workspace_id_comes_from_the_process_environment(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_WORKSPACE_ID", "wrkspc_2")
    assert run.AnthropicChat("k", "m", 1).client.default_headers["anthropic-workspace-id"] == "wrkspc_2"
    monkeypatch.delenv("ANTHROPIC_WORKSPACE_ID")
    assert "anthropic-workspace-id" not in run.AnthropicChat("k", "m", 1).client.default_headers


def test_the_report_records_each_call_arguments():
    r = run.Record(question="Q", expected=[AMOUNT], stop="answered")
    r.tools = ["search_columns", "describe_table", "search_tables"]
    r.arguments = [{"query": "x" * 300, "limit": 5}, {"table": "demo.crm.transactions"}, None]
    data = json.loads(run.report_json(META, [r]))
    assert data["trials"][0]["arguments"] == r.arguments
    text = run.render_report(META, [r])
    assert "| 1 | `search_columns` | " + "x" * 200 + " |" in text and "x" * 201 not in text
    assert "| 2 | `describe_table` |  |" in text  # not a search: no text
    assert "| 3 | `search_tables` |  |" in text


def test_an_error_is_recorded_by_kind_and_status_only():
    class Upstream(Exception):
        response = type("R", (), {"status_code": 429})()

    assert run.error_kind(Upstream("https://user:secret@host")) == "error: Upstream 429"
    assert run.error_kind(ExceptionGroup("g", [ConnectionError("secret")])) == "error: ConnectionError"
    assert run.error_kind(ExceptionGroup("g", [ValueError(), KeyError()])) == "error: ExceptionGroup"


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
    assert (record.calls, record.first_hit, record.right, record.stop) == (2, 1, True, "answered")
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
    assert (record.calls, record.stop, record.right) == (1, "max_steps", False)
    assert session.calls == []  # arguments that are not JSON never reach the server
    assert chat.client.requests[1]["messages"][-2]["content"] == json.dumps(
        {"error": "the arguments are not a JSON object"}
    )


def test_ask_never_scores_interim_text_at_max_steps(monkeypatch):
    import anyio

    session = FakeSession({"search_columns": "{}"})
    monkeypatch.setattr(run, "mcp_session", fake_mcp(session))
    interim = "Let me check demo.crm.transactions.amount first."
    chat = mistral_chat(
        [
            mistral_response(interim, [("c1", "search_columns", '{"text": "a"}')]),
            mistral_response(interim, [("c2", "search_columns", '{"text": "b"}')]),
        ]
    )
    item = {"question": "q", "expected": [AMOUNT], "forbidden": []}
    record, _, _ = anyio.run(run.ask, loop_args(max_steps=1), chat, item)
    assert (record.stop, record.answer, record.last_text, record.named) == ("max_steps", "", interim, {})
    assert not record.right
    assert "No final answer. Last text:" in run.render_report(META, [record])


def test_ask_records_a_cut_off_answer_as_max_tokens(monkeypatch):
    import anyio

    monkeypatch.setattr(run, "mcp_session", fake_mcp(FakeSession({})))
    cut = mistral_response("demo.crm.transactions.amount and")
    cut.choices[0].finish_reason = "length"
    record, _, _ = anyio.run(run.ask, loop_args(), mistral_chat([cut]), {"question": "q", "expected": [AMOUNT]})
    assert (record.stop, record.right) == ("max_tokens", False)


def test_an_error_result_shows_no_column(monkeypatch):
    import anyio

    class Failing(FakeSession):
        async def call_tool(self, name, arguments):
            return SimpleNamespace(content=[SimpleNamespace(text='{"columns": ["amount"]}')], is_error=True)

    monkeypatch.setattr(run, "mcp_session", fake_mcp(Failing({})))
    chat = mistral_chat(
        [
            mistral_response("", [("c1", "execute_query", '{"sql": "SELECT amount FROM demo.crm.transactions"}')]),
            mistral_response("demo.crm.transactions.amount"),
        ]
    )
    record, _, _ = anyio.run(run.ask, loop_args(), chat, {"question": "q", "expected": [AMOUNT]})
    assert record.first_seen == {} and record.never_shown == [AMOUNT]


def test_run_repeats_each_question_in_fresh_trials(monkeypatch):
    import anyio

    monkeypatch.setattr(run, "mcp_session", fake_mcp(FakeSession({})))
    chat = mistral_chat([mistral_response("demo.crm.transactions.amount") for _ in range(4)])
    args = SimpleNamespace(
        provider="mistral",
        max_steps=12,
        max_tokens=10,
        repeat=2,
        model="m",
        server_image="img",
        mcp_url="u",
        persona="p",
        questions="f",
    )
    items = [{"question": "q1", "expected": [AMOUNT], "forbidden": []}, {"question": "q2", "expected": [AMOUNT]}]
    meta, records = anyio.run(run.run, args, chat, items)
    assert [(r.question, r.trial) for r in records] == [("q1", 1), ("q1", 2), ("q2", 1), ("q2", 2)]
    assert meta["repeat"] == 2 and all(r.right for r in records)
    assert len(chat.client.requests) == 4  # one conversation per trial
    assert all(len(req["messages"]) == 3 for req in chat.client.requests)


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


# Fix round 2: fairness of the sighting rule and of the recorded names.


@pytest.mark.parametrize("table", ["crm.transactions", "demo.crm.transactions", '"demo"."crm"."transactions"'])
def test_a_qualified_table_argument_names_the_table(table):
    result = json.dumps({"columns": ["Column", "Type"], "rows": [["amount", "decimal(12,2)"]]})
    assert run.result_shows({"catalog": "demo", "table": table}, result, AMOUNT)


@pytest.mark.parametrize(
    "arguments",
    [
        {"table": "crm_archive.transactions"},
        {"table": "demo.crm_archive.transactions"},
        {"table": "crm.transactions_2019"},
        {"schema": "crm_archive", "table": "crm.transactions"},
    ],
)
def test_a_qualified_table_argument_for_another_table(arguments):
    result = json.dumps({"columns": ["Column", "Type"], "rows": [["amount", "decimal(12,2)"]]})
    assert not run.result_shows(arguments, result, AMOUNT)


@pytest.mark.parametrize(
    "result",
    [
        {"error": "Column 'demo.crm.transactions.amount' cannot be resolved", "kind": "column"},
        {"error": "line 1:8: Column 'amount' cannot be resolved", "kind": "column", "columns": ["amount"]},
    ],
)
def test_an_error_result_shows_nothing_even_unflagged(result):
    sql = {"sql": "SELECT amount FROM demo.crm.transactions"}
    assert not run.result_shows(sql, json.dumps(result), AMOUNT)


def test_nested_objects_inherit_their_parent_schema():
    archive = json.dumps(
        {
            "catalog": "demo",
            "schema": "crm_archive",
            "tables": [{"table": "accounts", "columns": [{"column": "balance"}]}],
        }
    )
    assert not run.result_shows({"catalog": "demo", "schema": "crm_archive"}, archive, "demo.crm.accounts.balance")
    current = archive.replace("crm_archive", "crm")
    assert run.result_shows({"catalog": "demo", "schema": "crm"}, current, "demo.crm.accounts.balance")


def test_other_names_leave_out_forbidden_columns_and_tables():
    r = trial(stop="answered", forbidden=["demo.crm.accounts.balance"])
    r.score(
        "SUM(demo.crm.transactions.amount) by demo.crm.accounts.customer_id, joining demo.crm.customers "
        "and crm.customers.full_name; not demo.crm.accounts.balance"
    )
    assert r.forbidden_named == ["demo.crm.accounts.balance"]
    assert r.other_named == ["crm.customers.full_name"]


# A call to a tool the server does not list makes the trial wrong, on every server alike.

TOOL_LIST = ["describe_table", "execute_query", "search_columns"]
FAKE = '{"sql": "SELECT currency, COUNT(*) FROM demo.crm.accounts GROUP BY currency"}'


def test_a_made_up_tool_name_makes_the_trial_wrong():
    r = run.Record(question="q", expected=["demo.crm.accounts.currency"], announced=TOOL_LIST, stop="answered")
    r.tools = ["search_columns", FAKE]
    r.score("demo.crm.accounts.currency")
    assert r.invalid_tools == [FAKE] and not r.right
    r.tools = ["search_columns", "execute_query"]
    assert r.invalid_tools == [] and r.right


def test_without_the_server_list_no_tool_is_judged():
    r = run.Record(question="q", expected=[AMOUNT], tools=["anything"], stop="answered")
    r.score(AMOUNT)
    assert r.invalid_tools == [] and r.right


def test_the_report_counts_and_marks_invalid_tools():
    good = run.Record(question="q", expected=[AMOUNT], announced=TOOL_LIST, tools=["search_columns"], stop="answered")
    good.score(AMOUNT)
    bad = run.Record(question="q", expected=[AMOUNT], announced=TOOL_LIST, tools=[FAKE], stop="answered", trial=2)
    bad.score(AMOUNT)
    text = run.render_report(META, [good, bad])
    assert "| Invalid tool |" in text
    assert "| 1 | 2 | 1/2 |" in text and "| 1/2 | answered x2 |" in text
    assert "### Trial 2: 1 tool calls, answered, not right, invalid tool" in text
    assert "(not a tool the server lists)" in text
    assert json.loads(run.report_json(META, [bad]))["trials"][0]["invalid_tools"] == [FAKE]


def test_ask_records_the_tools_the_server_lists(monkeypatch):
    import anyio

    session = FakeSession({"search_columns": "{}", FAKE: '{"error": "Unknown tool"}'})
    monkeypatch.setattr(run, "mcp_session", fake_mcp(session))
    chat = mistral_chat(
        [mistral_response("", [("c1", FAKE, '{"max_rows": 10}')]), mistral_response("demo.crm.transactions.amount")]
    )
    record, _, _ = anyio.run(run.ask, loop_args(), chat, {"question": "q", "expected": [AMOUNT]})
    assert record.announced == ["search_columns"]
    assert record.invalid_tools == [FAKE] and record.stop == "answered" and not record.right


def test_the_server_line_gives_the_tools():
    assert run.announced_tools("trino-mcp 0.7.0, 2 tools: a, b") == ["a", "b"]
    assert run.announced_tools("") == []


def test_a_report_scored_again_by_the_current_rules():
    data = {
        "meta": dict(META, server="trino-mcp 0.7.0, 3 tools: " + ", ".join(TOOL_LIST)),
        "trials": [
            {
                "question": "q",
                "expected": [AMOUNT],
                "forbidden": [],
                "trial": 1,
                "tools": ["search_columns", FAKE],
                "answer": AMOUNT,
                "stop": "answered",
                "right": True,
                "calls": 2,
            },
            {
                "question": "q",
                "expected": [AMOUNT],
                "forbidden": [],
                "trial": 2,
                "tools": ["search_columns"],
                "answer": "",
                "last_text": AMOUNT,
                "stop": "max_steps",
                "right": False,
            },
        ],
    }
    first, second = run.records_from_json(data)
    assert first.announced == TOOL_LIST and first.invalid_tools == [FAKE] and not first.right
    assert first.named == {AMOUNT: True}
    assert not second.right and second.named == {}


FINAL = os.path.join(os.path.dirname(run.__file__), "reports", "2026-11-01-final-mistral-0.7.0-4105967.json")


@pytest.mark.skipif(not os.path.exists(FINAL), reason="the final measurement's report is not in this tree")
def test_the_final_mistral_report_scored_again():
    with open(FINAL, encoding="utf-8") as f:
        records = run.records_from_json(json.load(f))
    invalid = [(r.question[:8], r.trial) for r in records if r.invalid_tools]
    assert invalid == [("How many", 3)]
    assert sum(r.right for r in records) == 9


def test_rescore_writes_both_files(tmp_path):
    src = tmp_path / "in.json"
    src.write_text(
        json.dumps(
            {"meta": META, "trials": [{"question": "q", "expected": [AMOUNT], "stop": "answered", "answer": AMOUNT}]}
        )
    )
    out = tmp_path / "out.md"
    assert run.main(["--rescore", str(src), "--out", str(out)]) == 0
    assert "| 1 | 1 | 1/1 |" in out.read_text()
    assert json.loads((tmp_path / "out.json").read_text())["trials"][0]["right"] is True


def test_rescore_and_provider_arguments():
    for bad in (["--rescore", "x.json"], ["--dry-run"]):
        with pytest.raises(SystemExit):
            run.parse_args(bad)
    assert run.parse_args(["--rescore", "x.json", "--out", "y.md"]).rescore == "x.json"


def test_wilson_interval_of_twelve_out_of_fifteen():
    assert run.wilson(12, 15) == (0.5481, 0.9295)
    assert run.wilson(0, 0) == (0.0, 1.0)
    lo, hi = run.wilson(15, 15)
    assert hi == 1.0 and 0.79 < lo < 0.8


def _summary(*rights, trials=3):
    rows = [
        {"id": f"COR-CRM-{i:02d}", "question": f"q{i}", "right": r, "trials": trials} for i, r in enumerate(rights, 1)
    ]
    return {"questions": rows, "right": sum(rights), "trials": trials * len(rights)}


def test_gate_passes_on_the_same_counts():
    assert run.gate(_summary(3, 2, 3), _summary(3, 2, 3)) == ("pass", [])


def test_gate_fails_below_the_tolerance_and_reviews_within_it():
    assert run.gate(_summary(3, 2, 3), _summary(3, 1, 2))[0] == "fail"
    assert run.gate(_summary(3, 2, 3), _summary(3, 1, 3), tolerance=1)[0] == "review"


def test_gate_fails_when_a_question_falls_from_all_to_under_half():
    verdict, reasons = run.gate(_summary(3, 0, 3), _summary(1, 2, 3), tolerance=5)
    assert verdict == "fail" and any("COR-CRM-01: 3/3" in r for r in reasons)


def test_gate_asks_to_document_an_improvement():
    assert run.gate(_summary(3, 1, 3), _summary(3, 2, 3))[0] == "improvement"


def test_gate_never_lets_an_improvement_hide_a_drop():
    verdict, reasons = run.gate(_summary(3, 2, 1), _summary(2, 2, 2))
    assert verdict == "review"
    assert any(r.startswith("COR-CRM-01: 3/3 in the baseline, 2/3 now") for r in reasons)
    assert any(r.startswith("COR-CRM-03: 1/3") for r in reasons)


def test_gate_lists_a_drop_even_at_an_equal_total():
    verdict, reasons = run.gate(_summary(3, 1), _summary(2, 2))
    assert verdict == "review" and any("COR-CRM-01" in r for r in reasons)


def test_gate_refuses_other_trials():
    assert run.gate(_summary(3, 1), _summary(3, 1, trials=5))[0] == "not_comparable"


def test_pair_from_the_announced_version_else_the_image_tag():
    assert run.pair({"server": "trino-mcp 0.7.0, 8 tools: a", "model_returned": "codestral-latest"}) == {
        "server": "0.7",
        "model": "codestral-latest",
    }
    meta = {"server": "trino-mcp (no version announced)", "server_image": "akkoai/akko-mcp-trino:0.6.1"}
    assert run.pair({**meta, "model_requested": "m"}) == {"server": "0.6", "model": "m"}


def test_summary_names_questions_by_their_id_and_lists_the_unstable():
    def rec(q, right):
        r = run.Record(question=q, expected=["demo.crm.t.c"], stop="answered")
        r.named = {"demo.crm.t.c": right}
        return r

    records = [rec("a", True), rec("a", False), rec("b", True), rec("b", True)]
    s = run.summary(records, [{"id": "COR-CRM-01", "question": "a"}, {"id": "COR-CRM-02", "question": "b"}])
    assert [(q["id"], q["right"], q["trials"]) for q in s["questions"]] == [("COR-CRM-01", 1, 2), ("COR-CRM-02", 2, 2)]
    assert s["right"] == 3 and s["trials"] == 4 and s["unstable"] == ["COR-CRM-01"]


def test_report_json_holds_the_pair_and_the_summary():
    r = run.Record(question="a", expected=["demo.crm.t.c"], stop="answered")
    r.named = {"demo.crm.t.c": True}
    data = json.loads(run.report_json({"server": "trino-mcp 0.7.2", "model_returned": "m"}, [r]))
    assert data["meta"]["pair"] == {"server": "0.7", "model": "m"}
    assert data["summary"]["right"] == 1 and data["summary"]["wilson95"][1] == 1.0


# A 429 from the provider is waited out and counted, never scored.


class RateLimited(Exception):
    def __init__(self, headers=None, status=429):
        super().__init__("https://user:secret@host")
        self.status_code = status
        self.raw_response = SimpleNamespace(headers=headers or {})


def test_retry_after_reads_seconds_or_a_date_and_nothing_else():
    assert run.retry_after(RateLimited({"retry-after": "7"})) == 7.0
    assert run.retry_after(RateLimited({"Retry-After": "Thu, 12 Nov 2026 10:00:30 GMT"}), now=1794477600.0) == 30.0
    assert run.retry_after(RateLimited({})) is None
    assert run.retry_after(RateLimited({"retry-after": "soon"})) is None
    assert run.retry_after(ValueError()) is None


def test_the_wait_honours_retry_after_else_grows_and_is_capped():
    assert run.rate_limit_wait(RateLimited({"retry-after": "3"}), 0) == 3.0
    assert [run.rate_limit_wait(RateLimited(), a) for a in (0, 1, 2)] == [5.0, 10.0, 20.0]
    assert run.rate_limit_wait(RateLimited(), 10) == run.RATE_LIMIT_WAIT_MAX
    assert run.rate_limit_wait(RateLimited({"retry-after": "900"}), 0) == run.RATE_LIMIT_WAIT_MAX
    assert run.rate_limit_wait(RateLimited(status=500), 0) is None
    assert run.rate_limit_wait(ConnectionError(), 0) is None


class Flaky(FakeMistralClient):
    """Answers 429 the first `failures` times, then as FakeMistralClient."""

    def __init__(self, responses, failures, headers=None):
        super().__init__(responses)
        self.failures, self.headers, self.sent = failures, headers, 0

    async def complete_async(self, **kw):
        self.sent += 1
        if self.failures:
            self.failures -= 1
            raise RateLimited(self.headers)
        return await super().complete_async(**kw)


def test_ask_waits_out_429_and_scores_the_same_turn(monkeypatch):
    import anyio

    waits = []

    async def fake_sleep(seconds):
        waits.append(seconds)

    monkeypatch.setattr(run, "sleep", fake_sleep)
    monkeypatch.setattr(run, "mcp_session", fake_mcp(FakeSession({})))
    chat = mistral_chat([])
    chat.client = Flaky([mistral_response("demo.crm.transactions.amount")], 2, {"retry-after": "4"})
    record, _, _ = anyio.run(run.ask, loop_args(), chat, {"question": "q", "expected": [AMOUNT]})
    assert (record.stop, record.right, record.rate_limited) == ("answered", True, 2)
    assert waits == [4.0, 4.0] and chat.client.sent == 3
    assert len(chat.client.requests[0]["messages"]) == 3  # system, question, answer: nothing sent twice


def test_pause_comes_before_each_turn(monkeypatch):
    import anyio

    waits = []

    async def fake_sleep(seconds):
        waits.append(seconds)

    monkeypatch.setattr(run, "sleep", fake_sleep)
    monkeypatch.setattr(run, "mcp_session", fake_mcp(FakeSession({"search_columns": "{}"})))
    chat = mistral_chat([mistral_response("", [("c1", "search_columns", '{"text": "a"}')]), mistral_response(AMOUNT)])
    args = SimpleNamespace(provider="mistral", max_steps=12, pause=1.5)
    record, _, _ = anyio.run(run.ask, args, chat, {"question": "q", "expected": [AMOUNT]})
    assert waits == [1.5, 1.5] and record.rate_limited == 0


def test_a_trial_that_ends_on_429_is_run_again_not_scored(monkeypatch):
    import anyio

    async def fake_sleep(seconds):
        pass

    monkeypatch.setattr(run, "sleep", fake_sleep)
    monkeypatch.setattr(run, "mcp_session", fake_mcp(FakeSession({})))
    chat = mistral_chat([])
    chat.client = Flaky([mistral_response(AMOUNT)], run.RATE_LIMIT_TRIES)
    args = SimpleNamespace(
        provider="mistral",
        max_steps=12,
        max_tokens=10,
        repeat=1,
        model="m",
        server_image="img",
        mcp_url="u",
        persona="p",
        questions=["f", "g"],
    )
    meta, records = anyio.run(run.run, args, chat, [{"question": "q", "expected": [AMOUNT], "forbidden": []}])
    assert len(records) == 1 and records[0].right
    assert records[0].rate_limited == run.RATE_LIMIT_TRIES == meta["rate_limited"]
    assert meta["questions"] == "f, g"


def test_another_error_is_not_retried(monkeypatch):
    import anyio

    monkeypatch.setattr(run, "mcp_session", fake_mcp(FakeSession({})))
    chat = mistral_chat([])
    chat.client = Flaky([mistral_response(AMOUNT)], 1)
    chat.client.complete_async = None  # any call fails with TypeError

    record, _, _ = anyio.run(run.ask, loop_args(), chat, {"question": "q", "expected": [AMOUNT]})
    assert (record.stop, record.rate_limited) == ("error: TypeError", 0)


def test_several_questions_files_read_as_one_list(tmp_path):
    a, b = tmp_path / "a.json", tmp_path / "b.json"
    a.write_text(json.dumps([{"id": "A-1", "question": "qa", "expected": [AMOUNT], "forbidden": []}]))
    b.write_text(json.dumps([{"id": "B-1", "question": "qb", "expected": [AMOUNT], "forbidden": []}]))
    assert [q["id"] for q in run.load_questions([str(a), str(b)])] == ["A-1", "B-1"]
    with pytest.raises(ValueError):
        run.load_questions([str(a), str(a)])
    args = run.parse_args(["--provider", "mistral", "--out", "r.md", "--questions", str(a), str(b), "--pause", "2"])
    assert (args.questions, args.pause) == ([str(a), str(b)], 2.0)
    with pytest.raises(SystemExit):
        run.parse_args(["--provider", "mistral", "--out", "r.md", "--pause", "-1"])


def test_the_context_questions_file_of_the_sandbox():
    path = os.path.join(os.path.dirname(QUESTIONS), "questions-context.json")
    questions = run.load_questions([QUESTIONS, path])
    assert [q["id"] for q in questions][5:] == ["CTX-01", "CTX-02", "CTX-03", "CTX-04", "CTX-05"]
    assert all(q["forbidden"] for q in questions)
