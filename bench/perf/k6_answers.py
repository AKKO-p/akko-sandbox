"""The answers k6 printed (ECHO=1 in bench/perf/mcp.js), read from its console file.

python3 bench/perf/k6_answers.py <console.txt>                 the texts in call order
python3 bench/perf/k6_answers.py <console.txt> --against <ref>  "<same> <total>": the
    answers equal to the reference's answer to their call, once durations and ids
    are removed (bench/lib/leaks.py), over all answers
mcp-inspector --cli ... | python3 bench/perf/k6_answers.py --inspector
    the Inspector's answer, on one line in the same form
"""

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))

import leaks

MSG = re.compile(r'\bmsg="((?:[^"\\]|\\.)*)"')


def rows(path: Path) -> list[dict]:
    """Each echoed answer: a raw JSON line, or the msg field of k6's logfmt line."""
    out = []
    for line in path.read_text(errors="replace").splitlines():
        m = MSG.search(line)
        text = json.loads(f'"{m.group(1)}"') if m else line
        try:
            row = json.loads(text)
        except ValueError:
            continue
        if isinstance(row, dict) and "index" in row:
            out.append(row)
    return out


def one_line(text: str | None) -> str:
    """An answer on one line, as bench/perf/validate.sh writes the Inspector's."""
    if text is None:
        return "null"
    try:
        return json.dumps(json.loads(text), ensure_ascii=False)
    except ValueError:
        return json.dumps(text, ensure_ascii=False)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("console", type=Path, nargs="?")
    p.add_argument("--against", type=Path)
    p.add_argument("--inspector", action="store_true")
    args = p.parse_args()
    if args.inspector:
        print(one_line(json.load(sys.stdin)["content"][0]["text"]))
        return 0
    got = rows(args.console)
    if args.against:
        ref = [leaks.canonical(line) for line in args.against.read_text().splitlines()]
        same = sum(r["index"] < len(ref) and leaks.canonical(one_line(r["text"])) == ref[r["index"]] for r in got)
        print(same, len(got))
        return 0
    for r in sorted(got, key=lambda r: r["index"]):
        print(one_line(r["text"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
