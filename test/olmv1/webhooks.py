#!/usr/bin/env python3
"""Run the experiment 0001 admission-webhook matrix for one operator.

Reads samples/matrix.yaml, runs each row's verb with --dry-run=server, compares the API server's
answer to the expectation, and writes results JSON plus a summary table. Nothing is persisted by
the dry-run calls. For UPDATE/DELETE rows the target object must exist; inert objects (templates,
the NHC sample whose selector matches no node) are created for real first and deleted at the end.
Remediation requests, NodeMaintenance and SBR config are never created for real (rows are `skip`).

Usage: webhooks.py KEY [--quick] [--keep]
  --quick  one admit and one reject per webhook (used after a manager restart)
  --keep   do not delete the inert objects created for UPDATE/DELETE rows
Environment: KUBECONFIG (required), OC (default oc), RUN_DIR (default evidence/<date>-olmv1-0001).
"""
import datetime
import json
import os
import pathlib
import subprocess
import sys

import yaml

HERE = pathlib.Path(__file__).resolve().parent
SAMPLES = HERE / "samples"
OC = os.environ.get("OC", "oc")
KUBECONFIG = os.environ["KUBECONFIG"]
RUN_DIR = pathlib.Path(os.environ.get("RUN_DIR") or (HERE.parent.parent / "evidence" / f"{datetime.date.today().isoformat()}-olmv1-0001"))
(RUN_DIR / "raw").mkdir(parents=True, exist_ok=True)

# Samples that may be created for real to satisfy UPDATE/DELETE preconditions: inert by construction.
INERT_CREATABLE = {"nhc-valid.yaml", "snrtemplate-valid.yaml", "fartemplate-valid.yaml", "mdrtemplate-valid.yaml"}


def oc(*args, stdin=None):
    cmd = [OC, "--kubeconfig", KUBECONFIG, "--request-timeout=30s", *args]
    p = subprocess.run(cmd, input=stdin, capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


def load_sample(name):
    return yaml.safe_load(open(SAMPLES / name))


def obj_ref(doc, ns):
    kind = doc["kind"]
    name = doc["metadata"]["name"]
    nsarg = []
    if doc["metadata"].get("namespace"):
        nsarg = ["-n", doc["metadata"]["namespace"]]
    return kind, name, nsarg


def exists(doc, ns):
    kind, name, nsarg = obj_ref(doc, ns)
    code, out, err = oc("get", f"{kind}/{name}", *nsarg, "-o", "name")
    return code == 0


def run_row(row, ns, created):
    sample = row["sample"]
    doc = load_sample(sample)
    verb = row["verb"]
    if row["expected"] == "skip":
        return {"outcome": "skip", "stderr": "", "stdout": ""}
    if verb == "create":
        code, out, err = oc("create", "--dry-run=server", "-f", str(SAMPLES / sample))
    elif verb == "update":
        # the valid sample of the same CRD must exist; create it for real if it is inert
        valid = sample.replace("-invalid-name", "-valid").replace("-invalid", "-valid")
        vdoc = load_sample(valid)
        if not exists(vdoc, ns):
            if valid in INERT_CREATABLE:
                c, o, e = oc("create", "-f", str(SAMPLES / valid))
                if c != 0:
                    return {"outcome": "precondition-failed", "stderr": e, "stdout": o}
                created.append(vdoc)
            else:
                return {"outcome": "precondition-failed", "stderr": f"{valid} does not exist and is not inert-creatable", "stdout": ""}
        code, out, err = oc("apply", "--dry-run=server", "-f", str(SAMPLES / sample))
    elif verb == "delete":
        if not exists(doc, ns):
            return {"outcome": "precondition-failed", "stderr": "object does not exist", "stdout": ""}
        code, out, err = oc("delete", "--dry-run=server", "-f", str(SAMPLES / sample))
    else:
        return {"outcome": "bad-verb", "stderr": "", "stdout": ""}

    admitted = code == 0
    text = (out + "\n" + err)
    denied_by_webhook = "admission webhook" in err and "denied the request" in err
    tls_or_timeout = any(s in err.lower() for s in ("tls", "timeout", "no endpoints available", "connection refused", "context deadline"))
    exp = row["expected"]
    if exp == "admit":
        outcome = "pass" if admitted else ("fail-webhook-unreachable" if tls_or_timeout else "fail-rejected")
    else:  # reject
        if admitted:
            outcome = "fail-admitted"
        elif denied_by_webhook and (not row.get("expected_substring") or row["expected_substring"] in err):
            outcome = "pass"
        elif denied_by_webhook:
            outcome = "pass-different-message"
        elif tls_or_timeout:
            outcome = "fail-webhook-unreachable"
        else:
            outcome = "fail-rejected-not-by-webhook"  # e.g. schema/CEL error, not the operator's handler
    return {"outcome": outcome, "exit_code": code, "stdout": out, "stderr": err}


def main():
    key = sys.argv[1]
    quick = "--quick" in sys.argv
    keep = "--keep" in sys.argv
    matrix = yaml.safe_load(open(SAMPLES / "matrix.yaml"))
    ns = matrix["namespace"]
    rows = [r for r in matrix["rows"] if r["operator"] == key]
    if quick:
        seen = set(); picked = []
        for r in rows:
            k = (r["webhook"], r["expected"])
            if r["expected"] in ("admit", "reject") and r["verb"] == "create" and k not in seen:
                seen.add(k); picked.append(r)
        rows = picked
    created = []
    results = []
    for r in rows:
        res = run_row(r, ns, created)
        results.append({**r, **res})
        print(f"{res['outcome']:28} {r['verb']:6} {r['sample']:28} expected={r['expected']:6} webhook={r['webhook']}")
    if not keep:
        for doc in reversed(created):
            kind, name, nsarg = obj_ref(doc, ns)
            oc("delete", f"{kind}/{name}", *nsarg, "--ignore-not-found")
    tag = "quick" if quick else "full"
    stamp = datetime.datetime.now(datetime.UTC).strftime("%Y%m%dT%H%M%SZ")
    out = RUN_DIR / f"webhooks-{key}-{tag}-{stamp}.json"
    json.dump(results, open(out, "w"), indent=1)
    counts = {}
    for r in results:
        counts[r["outcome"]] = counts.get(r["outcome"], 0) + 1
    print(f"summary {key} ({tag}): {counts}")
    with open(RUN_DIR / "outcomes.tsv", "a") as f:
        verdict = "PASS" if all(r["outcome"] in ("pass", "pass-different-message", "skip") for r in results) else "FAIL"
        f.write(f"{stamp}\t0001-03-{key}-{tag}\t{verdict}\t{json.dumps(counts)}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
