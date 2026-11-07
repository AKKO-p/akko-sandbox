"""Write the sandbox's demo catalog into Apache Atlas, through its REST API v2, as admin.

What it writes, under the Atlas cluster ATLAS_CLUSTER (sandbox), the one Trino's catalog demo
maps to in catalogs/compose.atlas.yaml:

- the databases crm and crm_archive, the three crm tables and their columns, as Hive
  entities (hive_db, hive_table, hive_column), each with a steward's description
  (userDescription);
- the glossary Sales, which the MCP server serves, with five terms: Customer (attached to
  crm.customers only), Account, Revenue and its synonym Turnover, Opening date; each with a
  status, in its additional attribute status;
- the glossary Compliance, which the server does not serve, with the term Personal data,
  attached to columns every user sees, and related to Revenue;
- the table crm_archive.transactions_2014, then renamed in Atlas to archive_2014, as a
  rename is recorded: Trino's table of that name is no longer known to Atlas;
- the table crm_archive.transactions_2015, then deleted: Atlas keeps it with the status
  DELETED; and the column crm.customers.segment, deleted too, which the table still lists
  among its columns, with that status;
- the table tiny.nation under the cluster tpch, which no Trino catalog maps to.

Nothing is written when Atlas already holds the glossary Sales. Only the standard library is
used, so any Python 3 runs it. The admin password is read from ATLAS_ADMIN_PASSWORD_FILE and
never printed.
"""

import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

URL = os.environ.get("ATLAS_URL", "http://atlas:21000").rstrip("/")
CLUSTER = os.environ.get("ATLAS_CLUSTER", "sandbox")
UNMAPPED = os.environ.get("ATLAS_UNMAPPED_CLUSTER", "tpch")
with open(os.environ["ATLAS_ADMIN_PASSWORD_FILE"]) as f:
    _AUTH = "Basic " + base64.b64encode(f"admin:{f.read().strip()}".encode()).decode()

DATABASES = {
    "crm": "Customers, their accounts and the movements booked on them",
    "crm_archive": "Movements of past years, one table a year",
}
TABLES = {
    "crm.customers": (
        "Everyone who holds an account: one row per person or company",
        {
            "id": ("integer", "Identifier of the customer"),
            "full_name": ("varchar", "Name of the person or of the company"),
            "email": ("varchar", "Address the bank writes to"),
            "country": ("char(2)", "Country of residence, ISO 3166 code"),
            "segment": ("varchar", "Whether the customer is a person or a company"),
        },
    ),
    "crm.accounts": (
        "Accounts held at the bank: one row per account, in one currency",
        {
            "id": ("integer", "Identifier of the account"),
            "customer_id": ("integer", "The customer who holds the account"),
            "opened_on": ("date", "Day the account was opened"),
            "currency": ("char(3)", "Currency of the account, ISO 4217 code"),
            "balance": ("decimal(12,2)", "What the account holds today, in its currency"),
        },
    ),
    "crm.transactions": (
        "Money in and out of the accounts: one row per movement",
        {
            "id": ("integer", "Identifier of the movement"),
            "account_id": ("integer", "The account the movement is booked on"),
            "booked_at": ("date", "Day the movement was booked"),
            "amount": ("decimal(12,2)", "Amount of the movement, in the account's currency"),
            "category": ("varchar", "What the money was spent on or came from"),
        },
    ),
    "crm_archive.transactions_2014": ("Movements of 2014, before the rename", {}),
    "crm_archive.transactions_2015": ("Movements of 2015, deleted since", {}),
}
GLOSSARIES = {
    "Sales": "Terms of the sales teams",
    "Compliance": "Terms of the compliance officers",
}
# name: glossary, definition, status, the objects it is attached to.
TERMS = {
    "Customer": ("Sales", "A person or a company that holds at least one account", "approved",
                 ["crm.customers"]),
    "Account": ("Sales", "A contract that keeps money for one customer, in one currency",
                "approved", ["crm.accounts"]),
    "Revenue": ("Sales", "Money that comes in from a sale", "approved",
                ["crm.transactions.amount"]),
    "Turnover": ("Sales", "The revenue of a period, added up", "draft", ["crm.transactions"]),
    "Opening date": ("Sales", "The day an account starts", "approved",
                     ["crm.accounts.opened_on"]),
    "Personal data": ("Compliance", "Anything that identifies a person", "approved",
                      ["crm.customers.email", "crm.transactions.amount"]),
}
# term: relation, the terms it names.
RELATIONS = {
    "Account": ("seeAlso", ["Customer"]),
    "Revenue": ("synonyms", ["Turnover"]),
    "Turnover": ("seeAlso", ["Personal data"]),
}


def call(method, path, body=None, params=None, ok=(200,)):
    url = URL + path + ("?" + urllib.parse.urlencode(params) if params else "")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", _AUTH)
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as res:
            text = res.read().decode()
            status = res.status
    except urllib.error.HTTPError as e:
        text, status = e.read().decode(), e.code
    if status not in ok:
        sys.exit(f"atlas answered {status} to {method} {path}: {text[:300]}")
    return json.loads(text) if text else None


def qualified(name, cluster=CLUSTER):
    return f"{name}@{cluster}"


def ref(type_name, name, cluster=CLUSTER):
    return {"typeName": type_name, "uniqueAttributes": {"qualifiedName": qualified(name, cluster)}}


def create(entities):
    call("POST", "/api/atlas/v2/entity/bulk", {"entities": entities})


def guid(type_name, name, cluster=CLUSTER):
    found = call("GET", f"/api/atlas/v2/entity/uniqueAttribute/type/{type_name}",
                 params={"attr:qualifiedName": qualified(name, cluster)})
    return found["entity"]["guid"]


def entity_type(name):
    return "hive_column" if name.count(".") == 2 else "hive_table"


def main():
    if any(g.get("name") == "Sales" for g in call("GET", "/api/atlas/v2/glossary") or []):
        print("atlas already holds the demo catalog")
        return
    create([{"typeName": "hive_db",
             "attributes": {"qualifiedName": qualified(db), "name": db, "clusterName": CLUSTER,
                            "userDescription": text}} for db, text in DATABASES.items()])
    create([{"typeName": "hive_table",
             "attributes": {"qualifiedName": qualified(t), "name": t.split(".")[1],
                            "userDescription": text},
             "relationshipAttributes": {"db": ref("hive_db", t.split(".")[0])}}
            for t, (text, _) in TABLES.items()])
    create([{"typeName": "hive_column",
             "attributes": {"qualifiedName": qualified(f"{t}.{c}"), "name": c, "type": kind,
                            "position": i, "userDescription": text},
             "relationshipAttributes": {"table": ref("hive_table", t)}}
            for t, (_, columns) in TABLES.items()
            for i, (c, (kind, text)) in enumerate(columns.items())])

    glossaries = {name: call("POST", "/api/atlas/v2/glossary",
                             {"name": name, "shortDescription": text})["guid"]
                  for name, text in GLOSSARIES.items()}
    terms = {}
    for name, (glossary, definition, status, _) in TERMS.items():
        terms[name] = call("POST", "/api/atlas/v2/glossary/term", {
            "name": name, "anchor": {"glossaryGuid": glossaries[glossary]},
            "shortDescription": definition, "additionalAttributes": {"status": status},
        })["guid"]
    for name, (relation, targets) in RELATIONS.items():
        term = call("GET", f"/api/atlas/v2/glossary/term/{terms[name]}")
        term[relation] = [{"termGuid": terms[t]} for t in targets]
        call("PUT", f"/api/atlas/v2/glossary/term/{terms[name]}", term)
    for name, (_, _, _, objects) in TERMS.items():
        call("POST", f"/api/atlas/v2/glossary/terms/{terms[name]}/assignedEntities",
             [{"guid": guid(entity_type(o), o)} for o in objects], ok=(200, 204))

    # A rename, as Atlas records it: the same entity under a new qualified name.
    call("PUT", "/api/atlas/v2/entity/uniqueAttribute/type/hive_table",
         {"entity": {"typeName": "hive_table",
                     "attributes": {"qualifiedName": qualified("crm_archive.archive_2014"),
                                    "name": "archive_2014"}}},
         params={"attr:qualifiedName": qualified("crm_archive.transactions_2014")})
    # A deletion: Atlas keeps the entity, with the status DELETED.
    call("DELETE", "/api/atlas/v2/entity/uniqueAttribute/type/hive_table",
         params={"attr:qualifiedName": qualified("crm_archive.transactions_2015")})
    call("DELETE", "/api/atlas/v2/entity/uniqueAttribute/type/hive_column",
         params={"attr:qualifiedName": qualified("crm.customers.segment")})
    # A cluster no Trino catalog maps to.
    create([{"typeName": "hive_db",
             "attributes": {"qualifiedName": qualified("tiny", UNMAPPED), "name": "tiny",
                            "clusterName": UNMAPPED}}])
    create([{"typeName": "hive_table",
             "attributes": {"qualifiedName": qualified("tiny.nation", UNMAPPED),
                            "name": "nation", "userDescription": "Nations of the benchmark"},
             "relationshipAttributes": {"db": ref("hive_db", "tiny", UNMAPPED)}}])
    print(f"atlas seeded: {len(TABLES) + 1} tables, {len(TERMS)} terms in "
          f"{len(GLOSSARIES)} glossaries")


if __name__ == "__main__":
    main()
