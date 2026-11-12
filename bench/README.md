# The bench: dated results and a regression gate

The bench puts the sandbox's proofs under one discipline. Every measure is a script
that plays again. Every run writes a dated file that says what was measured, on what
and with what. A baseline per pair (server minor version, model) holds what a run must
keep, and a gate fails the run on a regression.

This is step B0, the base: one entry point, the result file and its schema, the gate,
stable ids for the checks the scripts of `tests/` already make, the marker scanner,
the k6 script checked against the MCP Inspector, the memory sampler, and the agent
harness with its Wilson interval and its baseline per pair.

## Run it

On a Linux host with Docker, from the repository root, one run at a time:

```bash
bench/run.sh security                         # every suite of bench/security/cases.yaml
bench/run.sh security --suite smoke,v071      # some of them
bench/run.sh security --image akkoai/akko-mcp-trino:0.8.0 --seed 1311
bench/run.sh perf                             # the k6 script against the Inspector
bench/run.sh correctness --rescore agent/reports/2026-11-01-final-mistral-0.7.0-4105967.json
AGENT_ENV_FILE=/root/secrets/agent.env \
  bench/run.sh correctness --provider mistral --model codestral-latest --repeat 3
```

Exit status: 0 the gate passed, 1 it failed (or no baseline holds for the pair), 3 the
host could not hold the run, 2 a wrong option.

`bench/lib/preflight.sh <axis>` runs first. It reads the memory available, the free
disk, the load and the running compose projects, and refuses below the axis's
thresholds (6 GB of memory at least, `BENCH_MIN_FREE_GB` raises it) or while another
bench run goes on; a lock (`flock` on `BENCH_LOCK`, `/tmp/akko-bench.lock` by default)
keeps two runs from starting together. It stops and removes nothing. A refused
security or perf run still writes its result, every case `invalid_host`, neither green
nor red: play it again later. A refused correctness run writes nothing and exits 3.

The leak suite draws its witness words from `BENCH_SEED` (or `--seed`), drawn at random
when unset; the seed goes into the result and into its command, so that the run plays
again the same.

Each suite is its own compose project, `akko-bench-<suite>`, on host ports 18680,
13200 and 16474, removed at its end. `bench/lib/memsample.sh` samples the project's
containers and the host's available memory every 5 seconds meanwhile.

## What a suite is

| Axis | Suite | Script | Ids |
|---|---|---|---|
| security | `smoke` | `tests/smoke.sh` | `SEC-SMK-*` |
| security | `gateway` | `tests/gateway.sh` | `SEC-GW-*` |
| security | `v07`, `v07-gateway` | `tests/v07.sh`, directly and with `GATEWAY=1` | `SEC-V07-*`, `RES-TRN-*` (Trino stopped) |
| security | `v071`, `v071-gateway` | `tests/v071.sh`, directly and with `GATEWAY=1` | `SEC-R-*` |
| security | `leaks` | `bench/security/leaks.sh` | `SEC-LK-*` |
| perf | `k6-validate` | `bench/perf/validate.sh` | `PRF-K6-*` |
| correctness | the agent | `agent/run.py` | `COR-CRM-01` to `05` |

The scripts of `tests/` stay the source of the checks. `bench/<axis>/cases.yaml` only
names them: each check the script prints as `OK` or `FAIL` gets a stable id, matched by
its name with its numbers folded (a limit the server says, an address) and by its rank
among checks of the same name. A check the script prints and the file does not name
fails the run: give it an id in the same commit,

```bash
python3 bench/lib/record.py cases-add <suite> bench/evidence/<run>/<suite>.log
```

A named check the script did not print is `not_run`. Each suite also has a case of its
own (`SEC-SMK-000`, ...): the script ran to its end with status 0.

Some reads, such as SHOW STATS or EXPLAIN, can show facts beyond a row filter or a
column mask; refused by default. A case marked `visibility: private` keeps only its id
and verdict in the public result; its name and detail go to `BENCH_PRIVATE_DIR` when it
is set, never to `bench/results/`. The schema refuses a private case that carries more.
No case is private today. A suite marked `unnamed_private` (the read allow-list's) keeps
a check it prints that `cases.yaml` does not name yet out of the public result too.

## The result

`bench/results/YYYY-MM-DD/<axis>-<version>-<model or na>-<HHMMSS>.json`, and its `.md`
beside it, checked against [`schema/result.schema.json`](schema/result.schema.json) by
`bench/lib/record.py` when written and by CI. A run records the date, the sandbox's
commit (and whether the tree had local changes), the server's image, digest and the
version it announces, every image the suites ran by digest, the model requested and
returned, the host's memory, disk and load at the start and the end, each suite's exit
status, duration and memory peak, and every case with its verdict: `pass`, `fail`,
`not_run` or `invalid_host`. The raw logs go to `bench/evidence/<run>/`, kept on the
host for 30 days and not versioned, so a result names no log file.

A result that scores an earlier agent report again (`--rescore`) says so: `rescored`
names the report, the commit that added it and when it was scored again, and its host
block is empty, since the machine of the rescore says nothing of the run.

What is committed: the runs a baseline comes from, and the runs a pull request cites.
Other runs stay on the host with their evidence.

## The gate

`bench/compare.py gate <result>` holds a result against
`bench/baselines/<axis>/<server minor>-<model or na>.json`. For the scripts, the gate
fails on a case that passed in the baseline and does not now, on a case the baseline
does not hold, and on a case that now passes and did not: an improvement the baseline
must take in the same commit. A run of every suite must play every suite of the
baseline; a `--suite` run is compared on its suites only. A baseline changes only by

```bash
BENCH_UPDATE_BASELINE=true bench/run.sh <axis> ...
```

in the pull request that says why. A security or perf baseline holds no `fail` and no
`not_run`, unless `BENCH_BASELINE_ACCEPT_FAILURES` gives the reason, written into the
baseline. A `--suite` run replaces those suites of the baseline and keeps the others.
`bench/compare.py diff <before> <after>` prints two results side by side, case by case.

For correctness, the baseline holds the right answers per question, and the rule is
`gate()` of [`agent/run.py`](../agent/run.py), which `agent/run.py --baseline` applies
too: fail when the total falls below the baseline's by more than its `tolerance` (0
until an A/A run of the pair measures its natural spread), or when a question falls
from N/N to under N/2; review by hand when the total is lower within the tolerance, or
when any question lost right answers, even if others gained; improvement when a
question gains and none loses. Every question that lost or gained is listed. Each report gives the 95% Wilson interval of its right
answers and lists the unstable questions (neither 0/N nor N/N). A pair is the server's
minor version and the model id the API returned: a `-latest` model that changes under
the same name opens a new pair, it is never a regression of the server.

## The marker scanner

[`lib/leaks.py`](lib/leaks.py) answers one question: does any channel a user's calls
reach name what is hidden from them? Each hidden object carries a witness word drawn
from a noted seed (`leaks.py markers --seed 1311`), and the hidden objects' real names
are markers too. `leaks.py scan` reads each channel (answers, errors, cursors decoded,
the server's log, `system.runtime.queries`, OPA's decision log, Trino Gateway's
history, a catalog's access log) and reports every marker found where it is not
allowed. A channel whose file is missing stops the scan (exit 2): a channel never
collected must not read as a clean one. `leaks.py diff` compares two plays of the same calls once durations and query
ids are removed: the differential test.

`bench/security/leaks.sh` plays it on the sandbox: the witness words go into the
comments of the table and the column the policy hides from `dave_viewer`; dave's calls
search by the words those comments hold; nothing in his channels may name them; and
`carol_analyst`, who may see them, plays the same calls, so that the scanner must find
every marker in her answers, or it proves nothing.

## k6 and the memory sampler

[`perf/mcp.js`](perf/mcp.js) drives MCP tool calls under k6 (`grafana/k6:1.3.0`, run
as a container on the project's network) over the server's streamable HTTP:
`initialize`, `notifications/initialized` with the `Mcp-Session-Id`, then `tools/call`;
one token per virtual user, a session per call or per user, latencies per tool.
`bench/perf/validate.sh` checks it against the MCP Inspector before any measure: the
ten calls of `perf/calls.json` give the same answers by both, once durations and ids
are removed, with a session per call and with a session kept per user.
[`lib/memsample.sh`](lib/memsample.sh) samples a compose project's memory in the
background; `bench/lib/record.py` reads its peaks.

## Tests

```bash
pip install -r bench/requirements.txt
python3 -m pytest -q bench/tests
python3 bench/lib/record.py validate bench/results/*/*.json
```

CI plays both on every pull request. The test of `bench/run.sh` itself (a refused run
writes its seed and its suites) reads `/proc`: it runs on Linux, in CI and on the bench
host, and fails elsewhere.

## Not in B0

The guard corpus, fuzzing, the identity cases, the full differential test and Atlas
(B1); Toxiproxy (B2); the other question sets, the execution oracle and its rule that a
new "valid but wrong" answer fails, the A/A run that sets the correctness tolerance, and
the guard that stops a correctness run when Trino dies or restarts, as the 2026-11-01
measure did (B3); scale (B4); compatibility (B5); publication (B6).
