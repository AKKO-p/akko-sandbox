"""Write the load test's catalog into Apache Atlas, through its REST API v2, as admin.

What it writes, under the Atlas cluster ATLAS_CLUSTER (sandbox), next to catalogs/seed.py's
demo catalog:

- the glossary Generated, with LOAD_TERMS terms (50,000), each with a definition and the
  status approved, in its additional attribute status. They are written as entities of the
  type AtlasGlossaryTerm anchored to the glossary, through POST /api/atlas/v2/entity/bulk,
  LOAD_BATCH terms a request: Atlas's glossary call, POST /api/atlas/v2/glossary/terms, checks
  each new term's name against every term of its glossary, and its time per request grows
  with the glossary (measured on Atlas 2.4.0: 15 s for the first 500 terms, 212 s for the
  500 past 25,000);
- the database load and LOAD_TABLES tables (3): wide_2000, then wide_2000_2 and so on. Each
  has LOAD_COLUMNS columns (2,000), c0001 to c2000, as Hive entities, each with a steward's
  description (userDescription), created through POST /api/atlas/v2/entity/bulk,
  LOAD_BATCH columns a request. The burst reads wide_2000; the other tables are there to
  overflow the caches when their limits are small;
- LOAD_ATTACHED_TERMS terms a table (2,000), attached to its columns in turn, one term a
  column, through POST /api/atlas/v2/glossary/terms/{guid}/assignedEntities. wide_2000 gets
  the first 2,000 terms, wide_2000_2 the next 2,000, and so on.

It prints the time each step took, measured here. The last write marks the catalog as
complete: the description of the database load. It is not written on the glossary, since
Atlas 2.4.0 reads every term of a glossary to update it (590 s for 50,000 terms, measured).
Nothing is written when Atlas holds a complete catalog; one left half written by a seed that
stopped is an error, which a new Atlas container clears. Only the
standard library is used. The admin password is read from ATLAS_ADMIN_PASSWORD_FILE and never
printed.
"""

import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

URL = os.environ.get("ATLAS_URL", "http://atlas:21000").rstrip("/")
CLUSTER = os.environ.get("ATLAS_CLUSTER", "sandbox")
TERMS = int(os.environ.get("LOAD_TERMS", "50000"))
COLUMNS = int(os.environ.get("LOAD_COLUMNS", "2000"))
ATTACHED = int(os.environ.get("LOAD_ATTACHED_TERMS", "2000"))
TABLES = int(os.environ.get("LOAD_TABLES", "3"))
BATCH = int(os.environ.get("LOAD_BATCH", "500"))
GLOSSARY = "Generated"
SCHEMA = "load"
NAMES = ["wide_2000"] + [f"wide_2000_{n}" for n in range(2, TABLES + 1)]
SEEDED = "Written by tests/load/seed.py, complete."
with open(os.environ["ATLAS_ADMIN_PASSWORD_FILE"]) as f:
    _AUTH = "Basic " + base64.b64encode(f"admin:{f.read().strip()}".encode()).decode()


def call(method, path, body=None, params=None, ok=(200,)):
    url = URL + path + ("?" + urllib.parse.urlencode(params) if params else "")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", _AUTH)
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=600) as res:
            text = res.read().decode()
            status = res.status
    except urllib.error.HTTPError as e:
        text, status = e.read().decode(), e.code
    if status not in ok:
        sys.exit(f"atlas answered {status} to {method} {path}: {text[:300]}")
    return json.loads(text) if text else None


def qualified(name):
    return f"{name}@{CLUSTER}"


def column(i):
    return f"c{i:04d}"


def main():
    if ATTACHED > COLUMNS or ATTACHED * TABLES > TERMS:
        sys.exit("LOAD_ATTACHED_TERMS is above LOAD_COLUMNS, or LOAD_TABLES times it above LOAD_TERMS")
    # Read by qualified name, without relations: the glossary's 50,000 terms are not listed.
    def held(type_name, name):
        found = call("GET", f"/api/atlas/v2/entity/uniqueAttribute/type/{type_name}",
                     params={"attr:qualifiedName": name, "minExtInfo": "true",
                             "ignoreRelationships": "true"}, ok=(200, 404))
        return (found or {}).get("entity")

    database = held("hive_db", qualified(SCHEMA))
    if database and database["attributes"].get("userDescription") == SEEDED:
        print(f"atlas already holds the load catalog: {TERMS} terms, {TABLES} tables of {COLUMNS} columns")
        return
    if database or held("AtlasGlossary", GLOSSARY):
        sys.exit("atlas holds a load catalog a former seed left half written: "
                 "remove the atlas container and start again")
    glossary = call("POST", "/api/atlas/v2/glossary",
                    {"name": GLOSSARY, "shortDescription": "Terms written by the load test"})

    start = time.monotonic()
    guids = []
    for at in range(0, TERMS, BATCH):
        batch = range(at + 1, min(at + BATCH, TERMS) + 1)
        got = call("POST", "/api/atlas/v2/entity/bulk", {"entities": [{
            "typeName": "AtlasGlossaryTerm", "guid": f"-{i}",
            "attributes": {"qualifiedName": f"Generated term {i:05d}@{GLOSSARY}",
                           "name": f"Generated term {i:05d}",
                           "shortDescription": f"Definition of the generated term number {i}",
                           "additionalAttributes": {"status": "approved"}},
            "relationshipAttributes": {"anchor": {"typeName": "AtlasGlossary",
                                                  "guid": glossary["guid"]}}} for i in batch]})
        guids += [got["guidAssignments"][f"-{i}"] for i in batch]
    terms_seconds = time.monotonic() - start
    print(f"terms: {len(guids)} in {terms_seconds:.1f} s, {BATCH} a request "
          f"({len(guids) / terms_seconds:.0f} a second)", flush=True)

    call("POST", "/api/atlas/v2/entity/bulk", {"entities": [{
        "typeName": "hive_db",
        "attributes": {"qualifiedName": qualified(SCHEMA), "name": SCHEMA,
                       "clusterName": CLUSTER, "userDescription": "Tables of the load test"}}]})
    columns_seconds = attach_seconds = 0.0
    for n, name in enumerate(NAMES):
        start = time.monotonic()
        call("POST", "/api/atlas/v2/entity/bulk", {"entities": [{
            "typeName": "hive_table",
            "attributes": {"qualifiedName": qualified(f"{SCHEMA}.{name}"), "name": name,
                           "userDescription": f"A table of {COLUMNS} columns, for the load test"},
            "relationshipAttributes": {"db": {"typeName": "hive_db", "uniqueAttributes":
                                              {"qualifiedName": qualified(SCHEMA)}}}}]})
        table = {"typeName": "hive_table",
                 "uniqueAttributes": {"qualifiedName": qualified(f"{SCHEMA}.{name}")}}
        columns = {}
        for at in range(0, COLUMNS, BATCH):
            batch = range(at + 1, min(at + BATCH, COLUMNS) + 1)
            got = call("POST", "/api/atlas/v2/entity/bulk", {"entities": [{
                "typeName": "hive_column", "guid": f"-{i}",
                "attributes": {"qualifiedName": qualified(f"{SCHEMA}.{name}.{column(i)}"),
                               "name": column(i), "type": "varchar", "position": i - 1,
                               "userDescription": f"Generated column number {i} of the wide table"},
                "relationshipAttributes": {"table": table}} for i in batch]})
            columns.update({int(k[1:]): v for k, v in got["guidAssignments"].items()})
        took = time.monotonic() - start
        columns_seconds += took
        print(f"columns: {name}, {len(columns)} in {took:.1f} s, {BATCH} a request", flush=True)

        start = time.monotonic()
        for i in range(1, ATTACHED + 1):
            call("POST", f"/api/atlas/v2/glossary/terms/{guids[n * ATTACHED + i - 1]}/assignedEntities",
                 [{"guid": columns[i]}], ok=(200, 204))
        took = time.monotonic() - start
        attach_seconds += took
        print(f"attached: {name}, {ATTACHED} terms, one a column, in {took:.1f} s", flush=True)

    call("POST", "/api/atlas/v2/entity/bulk", {"entities": [{
        "typeName": "hive_db",
        "attributes": {"qualifiedName": qualified(SCHEMA), "name": SCHEMA,
                       "clusterName": CLUSTER, "userDescription": SEEDED}}]})
    print(f"atlas seeded for the load test in "
          f"{terms_seconds + columns_seconds + attach_seconds:.1f} s")


if __name__ == "__main__":
    main()
