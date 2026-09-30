#!/usr/bin/env python3
"""Fires the fixture payloads at a running n8n instance and asserts on the
JSON decision returned by each workflow. Exits non-zero if any assertion
fails. Intended to be called from tests/run.sh after the workflows have been
imported, published and the container restarted so the webhooks are live.
"""
import json
import sys
import urllib.request
import urllib.error

BASE_URL = "http://localhost:5679"
FIXTURES_DIR = "tests/fixtures"

failures = []
passed = 0


def post(path, fixture_file):
    with open(f"{FIXTURES_DIR}/{fixture_file}", "rb") as f:
        body = f.read()
    req = urllib.request.Request(
        f"{BASE_URL}/webhook/{path}",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        raw = e.read()
        print(f"  HTTP {e.code} calling {path} with {fixture_file}: {raw[:500]}")
    return json.loads(raw)


def check(label, condition, detail=""):
    global passed
    status = "PASS" if condition else "FAIL"
    line = f"[{status}] {label}"
    if detail:
        line += f" -- {detail}"
    print(line)
    if condition:
        passed += 1
    else:
        failures.append(label)


def get(d, path, default=None):
    cur = d
    for part in path.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return default
    return cur


# ---------------------------------------------------------------------------
# Workflow 2: appointment-booking
# ---------------------------------------------------------------------------
WF2 = "appointment-booking"

r = post(WF2, "booking-confirmed.json")
check("wf2 confirmed: status is confirmed", r.get("status") == "confirmed", f"body={r}")
check("wf2 confirmed: slot matches requested window", get(r, "slot.start") == "2026-10-05T10:00:00.000Z" and get(r, "slot.end") == "2026-10-05T10:30:00.000Z", f"slot={r.get('slot')}")
check("wf2 confirmed: confirmation_text present", bool(r.get("confirmation_text")))

r = post(WF2, "booking-conflict.json")
check("wf2 conflict: status is conflict", r.get("status") == "conflict", f"body={r}")
check("wf2 conflict: 3 alternatives proposed", isinstance(r.get("alternatives"), list) and len(r["alternatives"]) == 3, f"alternatives={r.get('alternatives')}")
first_alt = (r.get("alternatives") or [{}])[0]
check(
    "wf2 conflict: first alternative starts right after the overlapping booking",
    first_alt.get("start") == "2026-10-05T11:00:00.000Z",
    f"alternatives={r.get('alternatives')}",
)

r = post(WF2, "booking-invalid.json")
check("wf2 invalid: status is invalid", r.get("status") == "invalid", f"body={r}")
check("wf2 invalid: errors is a non-empty list", isinstance(r.get("errors"), list) and len(r["errors"]) >= 1, f"errors={r.get('errors')}")
check("wf2 invalid: names the missing name field", any("name" in e for e in r.get("errors", [])))

r = post(WF2, "booking-reschedule.json")
check("wf2 reschedule: status is confirmed once old slot freed", r.get("status") == "confirmed", f"body={r}")

print(f"\n{passed} passed, {len(failures)} failed")
if failures:
    print("Failed checks:")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)
sys.exit(0)
