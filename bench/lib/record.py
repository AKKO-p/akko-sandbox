"""A bench run, written down: the dated result file, its Markdown, and the checks it names.

The scripts of tests/ print one line per check, `  OK    <check>` or
`  FAIL  <check> (got ..., expected ...)`. bench/<axis>/cases.yaml gives each check a
stable id. This module reads a run's evidence folder (written by bench/run.sh), turns
every line into a case with its verdict, and writes
bench/results/YYYY-MM-DD/<axis>-<version>-<model or na>-<HHMMSS>.json and its .md,
checked against bench/schema/result.schema.json.

A check the script prints that cases.yaml does not name fails the run: a new check
gets its id in the same commit. A named check the script did not print is not_run.

    python3 bench/lib/record.py host                       the host's state, as JSON
    python3 bench/lib/record.py suites security             the axis's suites, one per line
    python3 bench/lib/record.py security <evidence dir>     the result of a run of the scripts
    python3 bench/lib/record.py correctness <report.json>   the result of an agent run
    python3 bench/lib/record.py validate <result.json>...   schema check
    python3 bench/lib/record.py cases-add <suite> <log>     append the log's unnamed checks to cases.yaml
"""

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

import yaml

BENCH = Path(__file__).resolve().parent.parent
ROOT = BENCH.parent
SCHEMA = BENCH / "schema" / "result.schema.json"
CHECK_LINE = re.compile(r"^\s+(OK|FAIL)\s+(\S.*?)\s*$")
VERSION = re.compile(r"(\d+)\.(\d+)\.(\d+)")


# ---------------------------------------------------------------------------
# The host and the repository
# ---------------------------------------------------------------------------


def host_state() -> dict:
    """Memory, disk and load of the machine, read from /proc: what the preflight judges."""
    info = {}
    try:
        with open("/proc/meminfo", encoding="ascii") as f:
            for line in f:
                key, value = line.split(":", 1)
                info[key] = int(value.split()[0])  # kB
    except OSError:
        pass
    disk = shutil.disk_usage("/")
    state = {
        "disk_free_gb": round(disk.free / 2**30, 1),
        "disk_used_pct": round(100 * disk.used / disk.total, 1),
        "loadavg": [round(x, 2) for x in os.getloadavg()],
        "cpus": os.cpu_count() or 1,
    }
    if info:
        state["mem_available_gb"] = round(info["MemAvailable"] / 2**20, 1)
        state["mem_total_gb"] = round(info["MemTotal"] / 2**20, 1)
    return state


def git(*args: str) -> str:
    try:
        return subprocess.run(
            ["git", "-C", str(ROOT), *args], capture_output=True, text=True, check=True
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def commit_info() -> tuple[str, bool]:
    """The sandbox's commit and whether the tree differs from it (results/ and evidence/ aside)."""
    sha = git("rev-parse", "HEAD") or "unknown"
    status = git("status", "--porcelain", "--", ".", ":!bench/results", ":!bench/evidence", ":!bench/baselines")
    return sha, bool(status)


def minor(version: str | None) -> str:
    """0.7 for 0.7.2, the version part of a baseline's name; unknown when nothing says it."""
    m = VERSION.search(version or "")
    return f"{m.group(1)}.{m.group(2)}" if m else "unknown"


def server_version(announced: str | None, image: str | None) -> str | None:
    """The version the server announces, else the one its image tag says."""
    for text in (announced, (image or "").rpartition(":")[2]):
        m = VERSION.search(text or "")
        if m:
            return m.group(0)
    return None


# ---------------------------------------------------------------------------
# Checks and cases
# ---------------------------------------------------------------------------


def normalize(label: str) -> str:
    """A check's name with its numbers folded, so that a count printed in a name (a limit
    the server says, an address) keeps one id: 'exactly 6 words' -> 'exactly # words'."""
    return re.sub(r"\d+", "#", label.strip())


def parse_log(text: str) -> list[tuple[str, str]]:
    """The checks a script printed, in order: (verdict pass or fail, the check's name)."""
    out = []
    for line in text.splitlines():
        m = CHECK_LINE.match(line)
        if not m:
            continue
        label = m.group(2)
        if m.group(1) == "FAIL":
            head, sep, _ = label.partition(" (got ")
            label = head if sep else label
        out.append(("pass" if m.group(1) == "OK" else "fail", label))
    return out


def load_cases(axis: str) -> dict:
    with open(BENCH / axis / "cases.yaml", encoding="utf-8") as f:
        data = yaml.safe_load(f)
    data["cases"] = data.get("cases") or []
    seen = set()
    for c in data["cases"]:
        key = (c["script"], normalize(c["check"]), c.get("nth", 1))
        if c["id"] in seen or key in seen:
            raise ValueError(f"cases.yaml: {c['id']} is not unique")
        seen |= {c["id"], key}
    return data


def match_cases(cases: dict, suite: str, log: str, exit_code: int | None) -> list[dict]:
    """Every case of the suite's script with its verdict in this log, the unnamed checks
    as failures, and the suite's own case: the script ran to its end with status 0."""
    conf = cases["suites"][suite]
    script, variant = conf["script"], conf.get("variant", "direct")
    named = {(normalize(c["check"]), c.get("nth", 1)): c for c in cases["cases"] if c["script"] == script}
    found: dict[str, dict] = {}
    out = []
    count: dict[str, int] = defaultdict(int)
    for verdict, label in parse_log(log):
        n = normalize(label)
        count[n] += 1
        case = named.get((n, count[n]))
        if case is None:
            # A suite whose new checks may touch the reads past the access rules keeps an
            # unnamed check's name out of the public result until someone names it.
            hidden = conf.get("unnamed_private", False)
            row = {"id": conf["unlisted"], "suite": suite, "variant": variant, "verdict": "fail"}
            row["visibility"] = "private" if hidden else "public"
            row.update(check=label, reason="a check cases.yaml does not name: give it an id")
            out.append(row)
            continue
        found[case["id"]] = {"verdict": verdict, "label": label}
    for case in named.values():
        got = found.get(case["id"])
        row = {"id": case["id"], "suite": suite, "variant": variant, "visibility": case.get("visibility", "public")}
        if got is None:
            row.update(verdict="not_run", check=case["check"], reason="not printed by the script")
        else:
            row.update(verdict=got["verdict"], check=got["label"])
        out.append(row)
    ended = exit_code == 0
    out.append(
        {
            "id": conf["run_case"],
            "suite": suite,
            "variant": variant,
            "verdict": "pass" if ended else "fail",
            "visibility": "public",
            "check": f"{conf['script_path']} ran to its end with status 0",
            **({} if ended else {"reason": f"exit status {exit_code}"}),
        }
    )
    return sorted(out, key=lambda r: r["id"])


def cases_add(suite: str, log_path: str, prefix: str | None) -> int:
    """Append to cases.yaml, under the next numbers, the checks of a log it does not name."""
    path = None
    for axis in ("security", "perf", "resilience"):
        p = BENCH / axis / "cases.yaml"
        if p.exists() and suite in yaml.safe_load(p.read_text())["suites"]:
            path = p
            break
    if path is None:
        raise SystemExit(f"no cases.yaml names the suite {suite}")
    data = yaml.safe_load(path.read_text())
    data["cases"] = data.get("cases") or []
    conf = data["suites"][suite]
    script = conf["script"]
    prefix = prefix or conf["family"]
    named = {(normalize(c["check"]), c.get("nth", 1)) for c in data["cases"] if c["script"] == script}
    used = [int(c["id"].rsplit("-", 1)[1]) for c in data["cases"] if c["id"].startswith(prefix + "-")]
    nxt = max(used, default=0) + 1
    count: dict[str, int] = defaultdict(int)
    lines = []
    for _, label in parse_log(Path(log_path).read_text()):
        n = normalize(label)
        count[n] += 1
        if (n, count[n]) in named:
            continue
        lines.append(f"  - id: {prefix}-{nxt:03d}\n    script: {script}\n    check: {json.dumps(label)}\n")
        if count[n] > 1:
            lines[-1] += f"    nth: {count[n]}\n"
        nxt += 1
    with open(path, "a", encoding="utf-8") as f:
        f.writelines(lines)
    print(f"{len(lines)} checks added to {path.relative_to(ROOT)}")
    return 0


# ---------------------------------------------------------------------------
# Memory samples (bench/lib/memsample.sh)
# ---------------------------------------------------------------------------

UNITS = {"b": 1, "kb": 1e3, "kib": 2**10, "mb": 1e6, "mib": 2**20, "gb": 1e9, "gib": 2**30}


def mem_bytes(text: str) -> float:
    m = re.match(r"\s*([\d.]+)\s*([A-Za-z]+)", text)
    if not m:
        return 0.0
    return float(m.group(1)) * UNITS.get(m.group(2).lower(), 1)


def memory_summary(path: Path, project: str) -> dict:
    """Peaks from the sampler's lines: '<epoch>\t<container>\t<usage / limit>' and
    '<epoch>\t__host__\t<MemAvailable kB>'."""
    if not path.exists():
        return {"samples": 0}
    per_container: dict[str, float] = defaultdict(float)
    per_sample: dict[str, float] = defaultdict(float)
    host_min = None
    for line in path.read_text().splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        epoch, name, value = parts[:3]
        if name == "__host__":
            mb = int(value) / 1024
            host_min = mb if host_min is None else min(host_min, mb)
            continue
        b = mem_bytes(value.split("/")[0])
        short = name.removeprefix(project + "-")
        per_container[short] = max(per_container[short], b)
        per_sample[epoch] += b
    out = {
        "samples": len(per_sample),
        "project_peak_mb": round(max(per_sample.values(), default=0) / 2**20, 1),
        "containers_peak_mb": {k: round(v / 2**20, 1) for k, v in sorted(per_container.items())},
    }
    if host_min is not None:
        out["host_available_min_mb"] = round(host_min, 1)
    return out


# ---------------------------------------------------------------------------
# The result file
# ---------------------------------------------------------------------------


def validate(result: dict) -> None:
    import jsonschema

    jsonschema.validate(result, json.loads(SCHEMA.read_text()))


def summarize(cases: list[dict]) -> dict:
    s = {"pass": 0, "fail": 0, "not_run": 0, "invalid_host": 0}
    for c in cases:
        s[c["verdict"]] += 1
    return s


def result_name(result: dict) -> Path:
    when = datetime.datetime.strptime(result["run_id"][:20], "%Y-%m-%dT%H:%M:%SZ")
    model = re.sub(r"[^A-Za-z0-9.-]+", "-", result["model"]["returned"] or "na")
    version = result["server"]["version"] or "unknown"
    return Path(when.strftime("%Y-%m-%d")) / f"{result['axis']}-{version}-{model}-{when.strftime('%H%M%S')}"


def render_md(result: dict) -> str:
    s = result["summary"]
    lines = [
        f"# Bench run {result['run_id']}",
        "",
        *(
            [
                f"Rescored on {result['rescored']['at']}: the report {result['rescored']['from']} "
                f"(added by `{(result['rescored']['source_commit'] or 'unknown')[:12]}`), scored again by the "
                f"rules of `{result['sandbox_commit'][:12]}`. The run itself is the report's; no host state is recorded.",
                "",
            ]
            if result.get("rescored")
            else []
        ),
        "| Field | Value |",
        "|---|---|",
        f"| axis | {result['axis']} |",
        f"| command | `{result['command']}` |",
        f"| {'scoring commit' if result.get('rescored') else 'sandbox commit'} | `{result['sandbox_commit'][:12]}`{' (with local changes)' if result['dirty'] else ''} |",
        f"| seed | {result['seed'] if result['seed'] is not None else '-'} |",
        f"| server | {result['server']['image']} ({result['server']['announced'] or 'no version announced'}) |",
        f"| server digest | `{result['server']['digest'] or '-'}` |",
        f"| model | {result['model']['returned'] or '-'} |",
        f"| host at start | {json.dumps(result['host']['start']) if result['host']['start'] else '-'} |",
        f"| host at end | {json.dumps(result['host']['end']) if result['host']['end'] else '-'} |",
        f"| duration | {result['duration_s']:.0f} s |",
        f"| cost | {'-' if result['cost_usd'] is None else f'{result["cost_usd"]:.2f} USD'} |",
        "",
        f"**{s['pass']} pass, {s['fail']} fail, {s['not_run']} not run, {s['invalid_host']} invalid host.**",
    ]
    if "wilson95" in s:
        lo, hi = s["wilson95"]
        lines.append(f"Right answers {s['right']}/{s['trials']}, 95% Wilson interval {lo:.2f} to {hi:.2f}.")
        if s.get("unstable"):
            lines.append("Unstable questions (neither 0/N nor N/N): " + ", ".join(s["unstable"]) + ".")
    lines += [
        "",
        "| Suite | Exit | Duration (s) | Project memory peak (MB) | Host available min (MB) |",
        "|---|---|---|---|---|",
    ]
    for su in result["suites"]:
        m = su.get("memory", {})
        lines.append(
            f"| {su['name']} | {su['exit_code']} | {su['duration_s']:.0f} | {m.get('project_peak_mb', '-')} | "
            f"{m.get('host_available_min_mb', '-')} |"
        )
    stack = result["stack"]
    if stack:
        lines += ["", "| Image | Digest |", "|---|---|"] + [f"| {k} | `{v or '-'}` |" for k, v in stack.items()]
    lines += ["", "| Case | Variant | Verdict | Check |", "|---|---|---|---|"]
    for c in result["cases"]:
        text = c.get("check", "(private case)" if c["visibility"] == "private" else "")
        if c.get("reason"):
            text += f" ({c['reason']})"
        if c.get("metrics"):
            text += " " + json.dumps(c["metrics"], sort_keys=True)
        lines.append(f"| {c['id']} | {c['variant']} | {c['verdict']} | {text.replace('|', '\\|')} |")
    return "\n".join(lines) + "\n"


def private_split(result: dict) -> list[dict]:
    """The private cases' details, removed from the public result: only id, variant,
    verdict and visibility stay in it (§13 of the bench's design)."""
    kept = []
    for c in result["cases"]:
        if c["visibility"] == "private":
            kept.append(dict(c))
            for k in ("check", "reason", "metrics", "evidence"):
                c.pop(k, None)
    return kept


def write(result: dict, out_root: Path) -> Path:
    private = private_split(result)
    validate(result)
    name = result_name(result)
    path = out_root / f"{name}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(result, indent=2) + "\n")
    (out_root / f"{name}.md").write_text(render_md(result))
    private_dir = os.environ.get("BENCH_PRIVATE_DIR")
    if private and private_dir:
        p = Path(private_dir) / f"{name}.private.json"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps({"run_id": result["run_id"], "cases": private}, indent=2) + "\n")
    print(path)
    return path


def base_result(axis: str, run_id_time: str, command: str, host: dict) -> dict:
    sha, dirty = commit_info()
    return {
        "schema": 1,
        "run_id": "",
        "axis": axis,
        "suites": [],
        "command": command,
        "bench_commit": sha,
        "sandbox_commit": sha,
        "dirty": dirty,
        "server": {"image": None, "digest": None, "announced": None, "version": None},
        "stack": {},
        "model": {"requested": None, "returned": None, "settings": {}},
        "seed": None,
        "host": host,
        "cases": [],
        "summary": {},
        "duration_s": 0,
        "cost_usd": 0,
        "_time": run_id_time,
    }


def finish(result: dict) -> dict:
    t = result.pop("_time")
    result["run_id"] = (
        f"{t}-{result['axis']}-{result['server']['version'] or 'unknown'}-{result['model']['returned'] or 'na'}"
    )
    result["run_id"] = result["run_id"].replace(" ", "-")
    result["summary"] = {**summarize(result["cases"]), **result["summary"]}
    return result


def record_scripts(axis: str, evidence: Path, out_root: Path) -> int:
    """The result of bench/run.sh <axis>, from its evidence folder."""
    run = json.loads((evidence / "run.json").read_text())
    cases = load_cases(axis)
    result = base_result(axis, run["started"], run["command"], {"start": run["host_start"], "end": run["host_end"]})
    if run.get("refused"):
        result["host"]["refused"] = run["refused"]
    result["suites_requested"] = run.get("suites_requested", "all")
    server = run.get("server", {})
    result["server"].update(
        image=server.get("image"),
        digest=server.get("digest"),
        announced=server.get("announced"),
        version=server_version(server.get("announced"), server.get("image")),
    )
    result["stack"] = run.get("stack", {})
    result["seed"] = run.get("seed")
    for su in run["suites"]:
        name = su["name"]
        log_path = evidence / f"{name}.log"
        if run.get("refused") or not log_path.exists():
            conf = cases["suites"][name]
            for c in cases["cases"]:
                if c["script"] == conf["script"]:
                    result["cases"].append(
                        {
                            "id": c["id"],
                            "suite": name,
                            "variant": conf.get("variant", "direct"),
                            "verdict": "invalid_host" if run.get("refused") else "not_run",
                            "visibility": c.get("visibility", "public"),
                            **({} if c.get("visibility") == "private" else {"reason": run.get("refused") or "no log"}),
                        }
                    )
            result["suites"].append({"name": name, "exit_code": None, "duration_s": 0})
            continue
        rows = match_cases(cases, name, log_path.read_text(errors="replace"), su["exit_code"])
        metrics_path = evidence / f"{name}.metrics.json"
        metrics = json.loads(metrics_path.read_text()) if metrics_path.exists() else {}
        for r in rows:
            # The script's metrics, by the name of the check they belong to.
            if r.get("check") in metrics:
                r["metrics"] = metrics[r["check"]]
        result["cases"] += rows
        result["suites"].append(
            {
                "name": name,
                "exit_code": su["exit_code"],
                "duration_s": su["duration_s"],
                "memory": memory_summary(evidence / f"{name}.mem.tsv", su.get("project", "")),
            }
        )
    result["duration_s"] = run.get("duration_s", sum(s["duration_s"] for s in result["suites"]))
    write(finish(result), out_root)
    return 0


# ---------------------------------------------------------------------------
# Correctness: an agent/run.py report
# ---------------------------------------------------------------------------

# USD per token (input, output), as the 2026-11-01 measure counted them. A model not
# listed here gets no cost rather than a made-up one.
PRICES = {"claude-sonnet-5-5": (2e-6, 10e-6)}


def record_correctness(
    report_path: Path, out_root: Path, command: str, questions_path: Path, rescored: bool = False
) -> Path:
    """The result of an agent run. rescored: the report is an earlier one scored again, so
    the result holds no host state (the machine of the rescore says nothing of the run)
    and says where the report comes from."""
    sys.path.insert(0, str(ROOT / "agent"))
    import run as agent

    data = json.loads(report_path.read_text())
    meta = data["meta"]
    records = agent.records_from_json(data)
    questions = agent.load_questions(str(questions_path))
    summary = agent.summary(records, questions)
    started = datetime.datetime.strptime(meta["date"], "%Y-%m-%d %H:%M UTC").strftime("%Y-%m-%dT%H:%M:%SZ")
    host = {"start": {}, "end": {}}
    if not rescored and os.environ.get("BENCH_HOST"):
        host = json.loads(os.environ["BENCH_HOST"])
    result = base_result("correctness", started, command, host)
    if rescored:
        source = report_path.resolve()
        rel = str(source.relative_to(ROOT)) if source.is_relative_to(ROOT) else str(report_path)
        result["rescored"] = {
            "from": rel,
            "source_commit": git("log", "-1", "--diff-filter=A", "--format=%H", "--", rel) or None,
            "at": datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
    announced = meta.get("server", "").split(",")[0] or None
    result["server"].update(
        image=meta.get("server_image") or None,
        announced=announced,
        version=server_version(announced, meta.get("server_image")),
    )
    result["model"] = {
        "requested": meta.get("model_requested"),
        "returned": meta.get("model_returned") or None,
        "settings": {
            k: meta[k] for k in ("provider", "persona", "repeat", "max_steps", "max_tokens", "sampling") if k in meta
        },
    }
    for q in summary["questions"]:
        result["cases"].append(
            {
                "id": q["id"],
                "suite": "agent",
                "variant": meta.get("persona", "carol_analyst"),
                # A question is a pass when most of its trials are right; the gate reads the counts.
                "verdict": "pass" if 2 * q["right"] > q["trials"] else "fail",
                "visibility": "public",
                "check": q["question"],
                "metrics": {"right": q["right"], "trials": q["trials"]},
            }
        )
    result["summary"] = {k: summary[k] for k in ("right", "trials", "wilson95", "unstable")}
    result["duration_s"] = round(sum(r.seconds for r in records), 1)
    price = PRICES.get(meta.get("model_returned", ""))
    result["cost_usd"] = (
        round(sum(r.input_tokens * price[0] + r.output_tokens * price[1] for r in records), 2) if price else None
    )
    result["suites"] = [{"name": f"agent/{report_path.name}", "exit_code": 0, "duration_s": result["duration_s"]}]
    return write(finish(result), out_root)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("host")
    s = sub.add_parser("suites")
    s.add_argument("axis")
    s = sub.add_parser("security")
    s.add_argument("evidence", type=Path)
    s.add_argument("--axis", default="security")
    s.add_argument("--out", type=Path, default=BENCH / "results")
    s = sub.add_parser("correctness")
    s.add_argument("report", type=Path)
    s.add_argument("--questions", type=Path, default=ROOT / "agent" / "questions.json")
    s.add_argument("--command", default="")
    s.add_argument("--rescored", action="store_true", help="the report is an earlier one, scored again")
    s.add_argument("--out", type=Path, default=BENCH / "results")
    s = sub.add_parser("validate")
    s.add_argument("files", nargs="+", type=Path)
    s = sub.add_parser("cases-add")
    s.add_argument("suite")
    s.add_argument("log")
    s.add_argument("--prefix")
    args = p.parse_args(argv)
    if args.cmd == "host":
        print(json.dumps(host_state()))
    elif args.cmd == "suites":
        for name, conf in load_cases(args.axis)["suites"].items():
            env = " ".join(f"{k}={v}" for k, v in (conf.get("env") or {}).items())
            print(f"{name}\t{conf['script_path']}\t{conf.get('compose_file', '')}\t{env}")
    elif args.cmd == "security":
        return record_scripts(args.axis, args.evidence, args.out)
    elif args.cmd == "correctness":
        record_correctness(args.report, args.out, args.command or " ".join(sys.argv), args.questions, args.rescored)
        return 0
    elif args.cmd == "validate":
        for f in args.files:
            validate(json.loads(f.read_text()))
            print(f"{f}: valid")
    elif args.cmd == "cases-add":
        return cases_add(args.suite, args.log, args.prefix)
    return 0


if __name__ == "__main__":
    sys.exit(main())
