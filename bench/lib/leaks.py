"""The marker scanner: does any channel a user can reach name what is hidden from them?

Every object hidden from a persona carries a witness word, drawn at the start of a run
from a noted seed (quillon_8f3a): a table's or a column's name or comment, a catalog
description, a glossary term, a masked value, a row outside the filter. A witness word
cannot show up by chance. The real names of the hidden objects (customers, balance)
are markers too, in the channels where they must not be.

A channel is a text file: the tool's answers, its errors, a cursor, the server's log,
the audit lines, the Prometheus metrics, system.runtime.queries, OPA's decision log,
Trino Gateway's history, the catalog's access log. Each marker may be allowed in some
channels (OPA's input names every table a filter is asked about); it must be found in
no other. Cursors are decoded before the scan: a base64 token is read as the text it
holds, so a name inside an opaque cursor still counts.

The differential test plays the same calls twice, once with the hidden objects and
once without them: once durations and query ids are removed, the two answers must be
the same, byte for byte, and so their sizes. Then no channel, not even a count, an
order or a status, says that a hidden object exists.

    python3 bench/lib/leaks.py markers --seed 1311 --count 3
    python3 bench/lib/leaks.py scan --marker customers --marker quillon_8f3a:opa_log \\
        --channel answers=dave.jsonl --channel server_log=mcp.log --channel opa_log=opa.log
    python3 bench/lib/leaks.py diff with.jsonl without.jsonl

scan and diff print one line per finding and exit 1 when there is one. tests/context.sh
(0.8, lot 7) calls them, as bench/security/leaks.sh does.
"""

import argparse
import base64
import binascii
import json
import random
import re
import sys
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from pathlib import Path

# Words a witness is made of: plain, rare, never a name in the sandbox's data.
WORDS = (
    "quillon",
    "bartizan",
    "gnomon",
    "astrolabe",
    "ferrule",
    "sextant",
    "tambour",
    "voussoir",
    "plinth",
    "corbel",
    "lunette",
    "oriel",
    "fresnel",
    "orrery",
    "bezel",
    "tholos",
)
# The keys a differential test drops: they change from one run to the next by nature.
VOLATILE_KEYS = re.compile(
    r"(duration|elapsed|seconds|millis|_ms$|^ms$|query_id|queryid|request_id|timestamp|^took)", re.I
)
# Trino's query ids (20261104_221501_00012_abcde) and request ids, anywhere in a string.
VOLATILE_TEXT = (
    re.compile(r"\b\d{8}_\d{6}_\d{5}_[a-z0-9]{5}\b"),
    re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"),
)
TOKEN = re.compile(r"[A-Za-z0-9_\-+/]{16,}={0,2}")


def markers(seed: int, count: int) -> list[str]:
    """count witness words, the same for the same seed: <word>_<4 hex>."""
    rng = random.Random(seed)
    return [f"{rng.choice(WORDS)}_{rng.getrandbits(16):04x}" for _ in range(count)]


def decode_tokens(text: str, decoders: Iterable[Callable[[str], str | None]] = ()) -> str:
    """The text of every base64 token found in text (a cursor, a page token), one per
    line; a decoder given by the caller reads the others (0.8.x encrypted cursors)."""
    out = []
    for token in set(TOKEN.findall(text)):
        for decode in (_b64, *decoders):
            plain = decode(token)
            if plain:
                out.append(plain)
                break
    return "\n".join(sorted(out))


def _b64(token: str) -> str | None:
    raw = token + "=" * (-len(token) % 4)
    for alt in (b"-_", b"+/"):
        try:
            data = base64.b64decode(raw, altchars=alt, validate=True)
        except (binascii.Error, ValueError):
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        if text.isprintable() and any(c.isalpha() for c in text):
            return text
    return None


@dataclass(frozen=True)
class Finding:
    marker: str
    channel: str
    line: int
    excerpt: str

    def __str__(self) -> str:
        return f"LEAK {self.marker!r} in {self.channel}, line {self.line}: {self.excerpt}"


def scan(
    channels: dict[str, str],
    rules: dict[str, set[str]],
    decoders: Iterable[Callable[[str], str | None]] = (),
) -> list[Finding]:
    """Every marker found, case folded, in a channel it is not allowed in. rules maps a
    marker to the channels it may be in. The decoded tokens of a channel are scanned as
    the channel itself, under the name <channel>:decoded."""
    findings = []
    decoders = tuple(decoders)
    for name, text in channels.items():
        views = [(name, text)]
        decoded = decode_tokens(text, decoders)
        if decoded:
            views.append((f"{name}:decoded", decoded))
        for view, body in views:
            for n, line in enumerate(body.splitlines(), 1):
                folded = line.casefold()
                for marker, allowed in rules.items():
                    if name in allowed:
                        continue
                    i = folded.find(marker.casefold())
                    if i >= 0:
                        findings.append(Finding(marker, view, n, line[max(0, i - 40) : i + len(marker) + 40]))
    return findings


def normalize(value):
    """A JSON value without what changes by nature from a run to the next."""
    if isinstance(value, dict):
        return {k: normalize(v) for k, v in value.items() if not VOLATILE_KEYS.search(k)}
    if isinstance(value, list):
        return [normalize(v) for v in value]
    if isinstance(value, str):
        for pattern in VOLATILE_TEXT:
            value = pattern.sub("<id>", value)
        return value
    return value


def canonical(line: str) -> str:
    """One answer, normalized and written back in one form, its keys in the order the
    server sent them; a line that is not JSON is compared as text, its ids removed."""
    try:
        return json.dumps(normalize(json.loads(line)), ensure_ascii=False)
    except ValueError:
        return normalize(line.rstrip("\n"))


def differential(with_hidden: list[str], without_hidden: list[str]) -> list[str]:
    """The differences between two plays of the same calls: their number, then each
    answer and its size."""
    out = []
    if len(with_hidden) != len(without_hidden):
        out.append(f"DIFF the plays hold {len(with_hidden)} and {len(without_hidden)} answers")
    for i, (a, b) in enumerate(zip(with_hidden, without_hidden, strict=False), 1):
        ca, cb = canonical(a), canonical(b)
        if ca != cb:
            out.append(f"DIFF answer {i}: {len(ca.encode())} and {len(cb.encode())} bytes: {ca[:120]} | {cb[:120]}")
    return out


def parse_rule(text: str) -> tuple[str, set[str]]:
    marker, _, allowed = text.partition(":")
    return marker, {a for a in allowed.split(",") if a}


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("markers")
    m.add_argument("--seed", type=int, required=True)
    m.add_argument("--count", type=int, default=1)
    s = sub.add_parser("scan")
    s.add_argument("--marker", action="append", default=[], help="WORD or WORD:channel,channel where it is allowed")
    s.add_argument("--channel", action="append", default=[], help="NAME=FILE")
    s.add_argument("--json", type=Path, help="the findings, as JSON")
    d = sub.add_parser("diff")
    d.add_argument("with_hidden", type=Path)
    d.add_argument("without_hidden", type=Path)
    args = p.parse_args(argv)
    if args.cmd == "markers":
        print("\n".join(markers(args.seed, args.count)))
        return 0
    if args.cmd == "diff":
        found = differential(args.with_hidden.read_text().splitlines(), args.without_hidden.read_text().splitlines())
        print("\n".join(found) or "diff: the same answers")
        return 1 if found else 0
    if not args.marker or not args.channel:
        p.error("scan needs at least one --marker and one --channel")
    rules = dict(parse_rule(r) for r in args.marker)
    channels = {}
    for c in args.channel:
        name, _, path = c.partition("=")
        channels[name] = Path(path).read_text(errors="replace") if Path(path).exists() else ""
    found = scan(channels, rules)
    for f in found:
        print(f)
    if args.json:
        args.json.write_text(json.dumps([f.__dict__ for f in found], indent=2) + "\n")
    print(f"scan: {len(found)} findings, {len(rules)} markers, {len(channels)} channels")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
