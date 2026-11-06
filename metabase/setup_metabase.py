#!/usr/bin/env python3
"""Dashboard-as-code for Metabase (tested against v0.50.36).

Reads metabase/dashboard.json + metabase/cards/*.sql and, through the
Metabase REST API:
  1. completes first-time setup (admin user) or logs in
  2. registers the warehouse as the read-only `bi_reader` user, limited to the `bi` schema
  3. creates the collection, then (re)builds every card and the dashboard,
     with the "Fund" filter wired to each card that uses {{fund}}

Idempotent: re-running archives the previous version of the dashboard and its
cards and builds them again, so changing a .sql file or dashboard.json and
re-running is all that is needed. Standard library only.

Usage:  python3 metabase/setup_metabase.py
Env:    MB_URL, MB_ADMIN_EMAIL, MB_ADMIN_PASSWORD, DW_HOST, DW_PORT, DW_DB, DW_USER, DW_PASSWORD
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
MB_URL = os.environ.get("MB_URL", "http://localhost:3000").rstrip("/")
ADMIN_EMAIL = os.environ.get("MB_ADMIN_EMAIL", "admin@demo.local")
ADMIN_PASSWORD = os.environ.get("MB_ADMIN_PASSWORD", "Demo-Passw0rd!")
DW = {  # as seen from the Metabase container (docker compose network)
    "host": os.environ.get("DW_HOST", "postgres"),
    "port": int(os.environ.get("DW_PORT", "5432")),
    "dbname": os.environ.get("DW_DB", "credit_dw"),
    "user": os.environ.get("DW_USER", "bi_reader"),
    "password": os.environ.get("DW_PASSWORD", "bi_reader_pw"),
}
DB_NAME = "Credit DW (bi views)"

_session: str | None = None


def api(method: str, path: str, body=None, ok_missing=False):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(MB_URL + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if _session:
        req.add_header("X-Metabase-Session", _session)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        if ok_missing and e.code == 404:
            return None
        sys.exit(f"Metabase API {method} {path} failed: {e.code} {e.read().decode()[:500]}")


def wait_for_metabase(timeout_s=300):
    print(f"Waiting for Metabase at {MB_URL} ...", end="", flush=True)
    start = time.time()
    while time.time() - start < timeout_s:
        try:
            with urllib.request.urlopen(MB_URL + "/api/health", timeout=5) as r:
                if json.loads(r.read()).get("status") == "ok":
                    print(" ready")
                    return
        except Exception:
            pass
        print(".", end="", flush=True)
        time.sleep(5)
    sys.exit("\nMetabase did not become healthy in time.")


def login_or_setup():
    global _session
    props = api("GET", "/api/session/properties")
    if not props.get("has-user-setup"):
        print("First run: creating admin user", ADMIN_EMAIL)
        res = api("POST", "/api/setup", {
            "token": props["setup-token"],
            "user": {"first_name": "Demo", "last_name": "Admin", "email": ADMIN_EMAIL,
                     "password": ADMIN_PASSWORD, "site_name": "Credit Portfolio Demo"},
            "prefs": {"site_name": "Credit Portfolio Demo", "site_locale": "en", "allow_tracking": False},
        })
        _session = res["id"]
    else:
        _session = api("POST", "/api/session", {"username": ADMIN_EMAIL, "password": ADMIN_PASSWORD})["id"]


def ensure_database() -> int:
    dbs = api("GET", "/api/database")
    dbs = dbs.get("data", dbs) if isinstance(dbs, dict) else dbs
    for db in dbs:
        if db["name"] == DB_NAME:
            return db["id"]
    print("Registering warehouse connection (user bi_reader, schema bi)")
    db = api("POST", "/api/database", {
        "engine": "postgres", "name": DB_NAME, "is_full_sync": True,
        "details": {**DW, "ssl": False, "schema-filters-type": "inclusion", "schema-filters-patterns": "bi"},
    })
    return db["id"]


def ensure_collection(name: str) -> int:
    for c in api("GET", "/api/collection"):
        if c.get("name") == name and not c.get("archived"):
            return c["id"]
    return api("POST", "/api/collection", {"name": name, "color": "#192C50"})["id"]


def archive_previous(collection_id: int, dashboard_name: str):
    items = api("GET", f"/api/collection/{collection_id}/items")
    items = items.get("data", items) if isinstance(items, dict) else items
    n = 0
    for it in items:
        if it["model"] == "dashboard" and it["name"] == dashboard_name:
            api("PUT", f"/api/dashboard/{it['id']}", {"archived": True}); n += 1
        elif it["model"] == "card":
            api("PUT", f"/api/card/{it['id']}", {"archived": True}); n += 1
    if n:
        print(f"Archived {n} items from the previous build")


def build_card(spec: dict, db_id: int, collection_id: int, filter_ids: set[str]) -> tuple[int, bool]:
    with open(os.path.join(HERE, spec["sql"])) as fh:
        sql = fh.read()
    tags = {f: {"id": str(uuid.uuid4()), "name": f, "display-name": f.title(), "type": "text"}
            for f in filter_ids if "{{" + f + "}}" in sql}
    viz = dict(spec.get("visualization_settings", {}))
    fmt = spec.get("format")
    if fmt:
        col = json.dumps(["name", fmt["column"]])
        viz.setdefault("column_settings", {})[col] = {
            k: v for k, v in {"prefix": fmt.get("prefix"), "suffix": fmt.get("suffix"),
                              "decimals": fmt.get("decimals")}.items() if v is not None}
    card = api("POST", "/api/card", {
        "name": spec["name"], "display": spec["display"], "collection_id": collection_id,
        "visualization_settings": viz,
        "dataset_query": {"type": "native", "database": db_id,
                          "native": {"query": sql, "template-tags": tags}},
    })
    return card["id"], bool(tags)


def main():
    with open(os.path.join(HERE, "dashboard.json")) as fh:
        cfg = json.load(fh)
    wait_for_metabase()
    login_or_setup()
    db_id = ensure_database()
    coll_id = ensure_collection(cfg["dashboard"]["collection"])
    archive_previous(coll_id, cfg["dashboard"]["name"])

    params = [{
        "id": f["id"], "name": f["name"], "slug": f["slug"], "type": f["type"], "sectionId": "string",
        "values_query_type": "list", "values_source_type": "static-list",
        "values_source_config": {"values": f["values"]},
    } for f in cfg["filters"]]
    filter_ids = {f["id"] for f in cfg["filters"]}

    dash = api("POST", "/api/dashboard", {
        "name": cfg["dashboard"]["name"], "description": cfg["dashboard"]["description"],
        "collection_id": coll_id, "parameters": params,
    })

    dashcards = []
    for i, spec in enumerate(cfg["cards"], start=1):
        lay = spec["layout"]
        dc = {"id": -i, "row": lay["row"], "col": lay["col"], "size_x": lay["size_x"], "size_y": lay["size_y"],
              "parameter_mappings": [], "series": []}
        if spec.get("type") == "text":
            dc.update(card_id=None, visualization_settings={
                "virtual_card": {"name": None, "display": "text", "visualization_settings": {},
                                 "dataset_query": {}, "archived": False},
                "text": spec["text"]})
        else:
            card_id, uses_filter = build_card(spec, db_id, coll_id, filter_ids)
            dc.update(card_id=card_id, visualization_settings={})
            if uses_filter:
                dc["parameter_mappings"] = [{"parameter_id": f, "card_id": card_id,
                                             "target": ["variable", ["template-tag", f]]} for f in filter_ids]
            print(f"  card  {spec['name']}")
        dashcards.append(dc)

    api("PUT", f"/api/dashboard/{dash['id']}", {"dashcards": dashcards, "parameters": params})
    print(f"\nDashboard ready: {MB_URL}/dashboard/{dash['id']}")
    print(f"Login: {ADMIN_EMAIL} / {ADMIN_PASSWORD}")


if __name__ == "__main__":
    main()
