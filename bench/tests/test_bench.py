"""The bench's own parts, without Docker: reading the checks, the result file and its
schema, the gate, the marker scanner. CI plays them on every pull request."""

import base64
import json
import sys
from pathlib import Path

import pytest

BENCH = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BENCH / "lib"))
sys.path.insert(0, str(BENCH))

import compare  # noqa: E402
import leaks  # noqa: E402
import record  # noqa: E402

LOG = """== 1. Start
  OK    a second start is healthy
  OK    the server cannot reach trino by its address (172.18.0.4)
  FAIL  the gateway still knows two clusters (got 1 (got 2), expected 2)
  OK    the variant is removed
  OK    the variant is removed
== done
"""

CASES = {
    "suites": {
        "gw": {
            "script": "gateway",
            "script_path": "tests/gateway.sh",
            "run_case": "SEC-GW-000",
            "unlisted": "SEC-GW-UNNAMED",
        },
        "gw2": {
            "script": "gateway",
            "variant": "gateway",
            "script_path": "tests/gateway.sh",
            "run_case": "SEC-GW-000",
            "unlisted": "SEC-GW-UNNAMED",
        },
    },
    "cases": [
        {"id": "SEC-GW-001", "script": "gateway", "check": "a second start is healthy"},
        {"id": "SEC-GW-002", "script": "gateway", "check": "the server cannot reach trino by its address (172.18.0.3)"},
        {"id": "SEC-GW-003", "script": "gateway", "check": "the gateway still knows two clusters"},
        {"id": "SEC-GW-004", "script": "gateway", "check": "the variant is removed"},
        {"id": "SEC-GW-005", "script": "gateway", "check": "the variant is removed", "nth": 2},
        {"id": "SEC-GW-006", "script": "gateway", "check": "a check the script no longer prints"},
    ],
}


def test_parse_log_reads_verdicts_and_strips_the_got_part_at_its_first_occurrence():
    assert record.parse_log(LOG)[2] == ("fail", "the gateway still knows two clusters")
    assert [v for v, _ in record.parse_log(LOG)] == ["pass", "pass", "fail", "pass", "pass"]


def test_cases_match_by_folded_numbers_and_rank():
    rows = {r["id"]: r for r in record.match_cases(CASES, "gw", LOG, 0)}
    assert rows["SEC-GW-002"]["verdict"] == "pass"  # another address, the same case
    assert rows["SEC-GW-003"]["verdict"] == "fail"
    assert rows["SEC-GW-004"]["verdict"] == rows["SEC-GW-005"]["verdict"] == "pass"
    assert rows["SEC-GW-006"]["verdict"] == "not_run"
    assert rows["SEC-GW-000"]["verdict"] == "pass"


def test_an_unnamed_check_fails_and_a_failed_script_fails_its_case():
    rows = record.match_cases(CASES, "gw", LOG + "  OK    something new\n", 1)
    unnamed = [r for r in rows if r["id"] == "SEC-GW-UNNAMED"]
    assert unnamed and unnamed[0]["verdict"] == "fail" and unnamed[0]["check"] == "something new"
    assert next(r for r in rows if r["id"] == "SEC-GW-000")["verdict"] == "fail"


def test_variant_and_suite_are_kept():
    rows = record.match_cases(CASES, "gw2", LOG, 0)
    assert {(r["suite"], r["variant"]) for r in rows} == {("gw2", "gateway")}


def test_memory_summary_reads_docker_stats_units():
    text = "1\t__host__\t2097152\n1\tp-trino-1\t1.5GiB / 2GiB\n1\tp-mcp-1\t512MiB / 1GiB\n2\tp-trino-1\t1GiB / 2GiB\n"
    path = Path(__file__).parent / ".mem.tsv"
    path.write_text(text)
    try:
        m = record.memory_summary(path, "p")
    finally:
        path.unlink()
    assert m["project_peak_mb"] == 2048.0 and m["containers_peak_mb"]["trino-1"] == 1536.0
    assert m["host_available_min_mb"] == 2048.0


def _result(cases, axis="security", version="0.7.2", model=None, suites=("gw",)):
    r = record.base_result(axis, "2026-11-04T22:00:00Z", "bench/run.sh security", {"start": {}, "end": {}})
    r["server"].update(image="akkoai/akko-mcp-trino:0.7.2", version=version)
    r["model"]["returned"] = model
    r["suites"] = [{"name": s, "exit_code": 0, "duration_s": 1} for s in suites]
    r["cases"] = cases
    return record.finish(r)


def _case(i, verdict="pass", suite="gw", **kw):
    return {
        "id": f"SEC-GW-{i:03d}",
        "suite": suite,
        "variant": "direct",
        "verdict": verdict,
        "visibility": "public",
        **kw,
    }


def test_a_result_validates_and_private_cases_lose_their_detail(tmp_path, monkeypatch):
    monkeypatch.setenv("BENCH_PRIVATE_DIR", str(tmp_path / "private"))
    r = _result([_case(1, check="public check"), _case(2, check="private check", visibility="private")])
    path = record.write(r, tmp_path)
    assert path.name == "security-0.7.2-na-220000.json"
    saved = json.loads(path.read_text())
    assert saved["run_id"] == "2026-11-04T22:00:00Z-security-0.7.2-na"
    assert saved["cases"][1] == {
        "id": "SEC-GW-002",
        "suite": "gw",
        "variant": "direct",
        "verdict": "pass",
        "visibility": "private",
    }
    assert "private check" not in path.read_text() and "private check" not in path.with_suffix(".md").read_text()
    assert "private check" in next((tmp_path / "private").rglob("*.json")).read_text()
    assert saved["summary"] == {"pass": 2, "fail": 0, "not_run": 0, "invalid_host": 0}


def test_the_schema_refuses_a_private_case_with_its_name():
    import jsonschema

    r = _result([_case(1, check="x", visibility="private")])
    with pytest.raises(jsonschema.ValidationError):
        record.validate(r)


def _gate(tmp_path, monkeypatch, base_cases, cases, suites=("gw",)):
    monkeypatch.setattr(compare, "BENCH", tmp_path)
    (tmp_path / "baselines" / "security").mkdir(parents=True)
    base = compare.make_baseline(_result(base_cases))
    (tmp_path / "baselines" / "security" / "0.7-na.json").write_text(json.dumps(base))
    p = tmp_path / "r.json"
    p.write_text(json.dumps(_result(cases, suites=suites)))
    return compare.gate(p)


def test_gate_passes_on_the_same_verdicts(tmp_path, monkeypatch):
    assert _gate(tmp_path, monkeypatch, [_case(1), _case(2, "fail")], [_case(1), _case(2, "fail")]) == 0


def test_gate_fails_on_a_regression(tmp_path, monkeypatch):
    assert _gate(tmp_path, monkeypatch, [_case(1)], [_case(1, "fail")]) == 1


def test_gate_fails_on_a_case_not_run(tmp_path, monkeypatch):
    assert _gate(tmp_path, monkeypatch, [_case(1), _case(2)], [_case(1)]) == 1


def test_gate_fails_on_a_case_the_baseline_does_not_hold(tmp_path, monkeypatch):
    assert _gate(tmp_path, monkeypatch, [_case(1)], [_case(1), _case(2)]) == 1


def test_gate_fails_on_an_undocumented_progress(tmp_path, monkeypatch):
    assert _gate(tmp_path, monkeypatch, [_case(1, "fail")], [_case(1)]) == 1


def test_gate_compares_only_the_suites_played(tmp_path, monkeypatch):
    base = [_case(1), _case(2, suite="other")]
    assert _gate(tmp_path, monkeypatch, base, [_case(1)], suites=("gw",)) == 0


def test_gate_says_invalid_host(tmp_path, monkeypatch):
    assert _gate(tmp_path, monkeypatch, [_case(1)], [_case(1, "invalid_host")]) == 3


def test_gate_without_a_baseline_fails(tmp_path, monkeypatch):
    monkeypatch.setattr(compare, "BENCH", tmp_path)
    p = tmp_path / "r.json"
    p.write_text(json.dumps(_result([_case(1)])))
    assert compare.gate(p) == 1


def test_markers_are_the_same_for_a_seed_and_differ_between_seeds():
    assert leaks.markers(1311, 3) == leaks.markers(1311, 3)
    assert leaks.markers(1311, 3) != leaks.markers(1312, 3)
    assert all("_" in m and len(m.split("_")[1]) == 4 for m in leaks.markers(7, 5))


def test_scan_respects_allowed_channels_and_folds_case():
    found = leaks.scan(
        {"answers": '{"t": "Customers"}', "opa_log": "customers", "server_log": "nothing"},
        {"customers": {"opa_log"}},
    )
    assert [(f.marker, f.channel) for f in found] == [("customers", "answers")]


def test_scan_reads_inside_a_base64_cursor():
    cursor = base64.urlsafe_b64encode(json.dumps({"after": "crm.customers", "o": 5}).encode()).decode().rstrip("=")
    found = leaks.scan({"answers": json.dumps({"next_cursor": cursor})}, {"customers": set()})
    assert [f.channel for f in found] == ["answers:decoded"]


def test_scan_takes_a_decoder_for_other_cursors():
    found = leaks.scan(
        {"answers": "cursor XYZXYZXYZXYZXYZXYZ"},
        {"quillon_0001": set()},
        decoders=[lambda t: "quillon_0001" if t.startswith("XYZ") else None],
    )
    assert found and found[0].channel == "answers:decoded"


def test_differential_ignores_durations_and_ids_but_not_counts_nor_order():
    a = [json.dumps({"rows": [[1]], "elapsed_ms": 3, "error": "query_id=20261104_222858_00019_efn4a"})]
    b = [json.dumps({"rows": [[1]], "elapsed_ms": 9, "error": "query_id=20261104_222903_00041_efn4a"})]
    assert leaks.differential(a, b) == []
    assert leaks.differential(a, [json.dumps({"rows": [[1], [2]]})])
    assert leaks.differential([json.dumps({"a": 1, "b": 2})], [json.dumps({"b": 2, "a": 1})])
    assert leaks.differential(a, a + a)


def test_every_cases_file_loads_with_unique_ids():
    for axis in ("security", "perf"):
        data = record.load_cases(axis)
        for name, conf in data["suites"].items():
            assert (BENCH.parent / conf["script_path"]).exists(), name


def test_committed_results_are_valid():
    for path in (BENCH / "results").rglob("*.json"):
        record.validate(json.loads(path.read_text()))
