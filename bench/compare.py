"""The bench's gate: a result against the baseline of its pair, or two results side by side.

    python3 bench/compare.py gate <result.json>        exit 0 pass, 1 fail, 3 invalid host
    python3 bench/compare.py baseline <result.json>    writes it as the baseline of its pair
    python3 bench/compare.py diff <before.json> <after.json>   the table, case by case

A baseline is bench/baselines/<axis>/<server minor>-<model or na>.json. For the
scripts' axes it holds each case's verdict, suite by suite; the gate fails on a case
that passed and does not now (fail or not_run), on one that now passes and did not (an
improvement the baseline must take in the same commit), and on a case the baseline does
not hold. A run of every suite must play every suite of the baseline; a run of some
suites (--suite) is compared on those only. A case played on a host the preflight
refused (invalid_host) is neither green nor red: the run is played again.

A baseline of the scripts' axes holds no failure and no case not run, unless
BENCH_BASELINE_ACCEPT_FAILURES gives the reason, written into it. A run of some suites
updates those suites of the baseline and keeps the others.

For correctness it holds the right answers per question; the rule is agent/run.py's
gate().
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path

BENCH = Path(__file__).resolve().parent
sys.path.insert(0, str(BENCH.parent / "agent"))

import run as agent  # noqa: E402 - agent/run.py, the correctness gate

VERSION = re.compile(r"(\d+)\.(\d+)")


def pair(result: dict) -> tuple[str, str]:
    m = VERSION.match(result["server"]["version"] or "")
    return (f"{m.group(1)}.{m.group(2)}" if m else "unknown", result["model"]["returned"] or "na")


def baseline_path(result: dict) -> Path:
    server, model = pair(result)
    return BENCH / "baselines" / result["axis"] / f"{server}-{re.sub(r'[^A-Za-z0-9.-]+', '-', model)}.json"


def key(case: dict) -> str:
    return f"{case['id']}@{case['variant']}"


def correctness_summary(result: dict) -> dict:
    rows = [
        {
            "id": c["id"],
            "question": c.get("check", ""),
            "right": c["metrics"]["right"],
            "trials": c["metrics"]["trials"],
        }
        for c in result["cases"]
    ]
    return {"questions": rows, "right": sum(q["right"] for q in rows), "trials": sum(q["trials"] for q in rows)}


def make_baseline(result: dict, previous: dict | None = None, accept_failures: str = "") -> dict:
    """The baseline a result makes; a run of some suites only replaces those suites of the
    previous baseline. Raises ValueError on a failure or a case not run that no reason
    accepts."""
    server, model = pair(result)
    base = {"axis": result["axis"], "from_run": result["run_id"], "pair": {"server": server, "model": model}}
    if result["axis"] == "correctness":
        base["tolerance"] = 0  # until an A/A run of the pair measures its spread
        base["summary"] = correctness_summary(result)
        return base
    bad = sorted(
        f"{c['suite']} {key(c)}: {c['verdict']}" for c in result["cases"] if c["verdict"] in ("fail", "not_run")
    )
    if bad and not accept_failures:
        raise ValueError("the run holds failures or cases not run: " + "; ".join(bad[:10]))
    suites: dict[str, dict] = {}
    for c in result["cases"]:
        suites.setdefault(c["suite"], {})[key(c)] = c["verdict"]
    played = {s["name"] for s in result["suites"]}
    merged, origin = {}, {}
    if previous and result.get("suites_requested", "all") != "all":
        merged, origin = dict(previous.get("suites", {})), dict(previous.get("suites_from", {}))
    for name in played:
        merged[name] = dict(sorted(suites.get(name, {}).items()))
        origin[name] = result["run_id"]
    base["suites"] = dict(sorted(merged.items()))
    base["suites_from"] = dict(sorted(origin.items()))
    if bad:
        base["accepted_failures"] = accept_failures
    return base


def gate_scripts(base: dict, result: dict) -> tuple[str, list[str]]:
    reasons, failed, invalid = [], False, False
    played = {s["name"] for s in result["suites"]}
    if result.get("suites_requested", "all") == "all":
        for suite in sorted(set(base["suites"]) - played):
            failed = True
            reasons.append(f"{suite}: in the baseline, not played")
    got: dict[str, dict[str, str]] = {}
    for c in result["cases"]:
        got.setdefault(c["suite"], {})[key(c)] = c["verdict"]
    for suite in sorted(played):
        if suite not in base["suites"]:
            failed = True
            reasons.append(f"{suite}: not in the baseline")
            continue
        want, have = base["suites"][suite], got.get(suite, {})
        for k in sorted(set(want) | set(have)):
            w, h = want.get(k), have.get(k, "not_run")
            if h == "invalid_host":
                invalid = True
            elif w is None:
                failed = True
                reasons.append(f"{suite} {k}: {h}, not in the baseline: name it there in the same commit")
            elif w == "pass" and h != "pass":
                failed = True
                reasons.append(f"{suite} {k}: {h}, passed in the baseline")
            elif w != "pass" and h == "pass":
                failed = True
                reasons.append(f"{suite} {k}: passes now, {w} in the baseline: update the baseline in the same commit")
            elif w != "pass":
                reasons.append(f"{suite} {k}: {h}, as in the baseline")
    if failed:
        return "fail", reasons
    return ("invalid_host" if invalid else "pass"), reasons


def gate(result_path: Path) -> int:
    result = json.loads(result_path.read_text())
    path = baseline_path(result)
    if not path.exists():
        print(
            f"gate: fail: no baseline {path.relative_to(BENCH.parent)} for this pair; write one with BENCH_UPDATE_BASELINE=true"
        )
        return 1
    base = json.loads(path.read_text())
    if result["axis"] == "correctness":
        verdict, reasons = agent.gate(base["summary"], correctness_summary(result), int(base.get("tolerance", 0)))
    else:
        verdict, reasons = gate_scripts(base, result)
    print(f"gate: {verdict} against {path.relative_to(BENCH.parent)}")
    for r in reasons:
        print(f"  {r}")
    return {"pass": 0, "invalid_host": 3}.get(verdict, 1)


def write_baseline(result_path: Path) -> int:
    result = json.loads(result_path.read_text())
    if result["summary"].get("invalid_host"):
        print("baseline: refused: the result holds cases played on a host the preflight refused")
        return 1
    path = baseline_path(result)
    previous = json.loads(path.read_text()) if path.exists() else None
    try:
        base = make_baseline(result, previous, os.environ.get("BENCH_BASELINE_ACCEPT_FAILURES", "").strip())
    except ValueError as e:
        print(f"baseline: refused: {e}; set BENCH_BASELINE_ACCEPT_FAILURES to the reason to accept them")
        return 1
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(base, indent=2) + "\n")
    print(f"baseline: {path.relative_to(BENCH.parent)} written from {result['run_id']}")
    return 0


def diff(before_path: Path, after_path: Path) -> int:
    a, b = (json.loads(p.read_text()) for p in (before_path, after_path))
    print(f"| Case | {a['run_id']} | {b['run_id']} |")
    print("|---|---|---|")

    def cell(c: dict | None) -> str:
        if c is None:
            return "-"
        m = c.get("metrics", {})
        return f"{m['right']}/{m['trials']}" if "right" in m else c["verdict"]

    ca, cb = {key(c): c for c in a["cases"]}, {key(c): c for c in b["cases"]}
    changed = 0
    for k in sorted(set(ca) | set(cb)):
        x, y = cell(ca.get(k)), cell(cb.get(k))
        changed += x != y
        print(f"| {k} | {x} | {y} |")
    for r, label in ((a, a["run_id"]), (b, b["run_id"])):
        s = r["summary"]
        if "wilson95" in s:
            print(
                f"\n{label}: {s['right']}/{s['trials']} right, 95% Wilson {s['wilson95'][0]:.2f} to {s['wilson95'][1]:.2f}"
            )
    print(f"\n{changed} cases differ")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("gate").add_argument("result", type=Path)
    sub.add_parser("baseline").add_argument("result", type=Path)
    d = sub.add_parser("diff")
    d.add_argument("before", type=Path)
    d.add_argument("after", type=Path)
    args = p.parse_args(argv)
    if args.cmd == "gate":
        return gate(args.result)
    if args.cmd == "baseline":
        return write_baseline(args.result)
    return diff(args.before, args.after)


if __name__ == "__main__":
    sys.exit(main())
