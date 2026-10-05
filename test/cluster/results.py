#!/usr/bin/env python3
# test/cluster/results.py
"""Record per-case outcomes and assemble results.json for a live-cluster run. Standard library only.

  results.py record --run-dir DIR --id WAO-INST-NN --status pass|fail|blocked [--notes TEXT] [--log FILE]
      Writes DIR/cases/WAO-INST-NN.json with observed_at = now (UTC). With --log, the case log's
      "FAIL:", "TIMEOUT:", "note:" and "LEFTOVER:" lines are appended to the notes.
  results.py build --run-dir DIR
      Writes DIR/results.json: one entry per case WAO-INST-00..18 (id, status, observed_at, notes).
      A case with no recorded outcome is reported as blocked with notes "not run".

results.json lives under the git-ignored evidence/ directory. Review and sanitize it (no API URLs,
node names, addresses, UIDs or Secret data) before committing a copy anywhere.
"""
import argparse, datetime, json, pathlib, sys

CASE_IDS = [f"WAO-INST-{i:02d}" for i in range(19)]
STATUSES = ("pass", "fail", "blocked")
NOTE_PREFIXES = ("FAIL:", "TIMEOUT:", "note:", "NOTE:", "LEFTOVER:")


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def notes_from_log(path):
    lines = pathlib.Path(path).read_text(errors="replace").splitlines()
    return [line.strip() for line in lines if line.strip().startswith(NOTE_PREFIXES)]


def record(a):
    if a.id not in CASE_IDS:
        raise SystemExit(f"unknown case id {a.id}")
    notes = [a.notes] if a.notes else []
    if a.log:
        notes += notes_from_log(a.log)
    d = pathlib.Path(a.run_dir) / "cases"
    d.mkdir(parents=True, exist_ok=True)
    entry = {"id": a.id, "status": a.status, "observed_at": now(), "notes": "; ".join(notes)}
    (d / f"{a.id}.json").write_text(json.dumps(entry, indent=1) + "\n")


def build(a):
    run = pathlib.Path(a.run_dir)
    out = []
    for cid in CASE_IDS:
        f = run / "cases" / f"{cid}.json"
        if f.exists():
            e = json.loads(f.read_text())
            out.append({k: e[k] for k in ("id", "status", "observed_at", "notes")})
        else:
            out.append({"id": cid, "status": "blocked", "observed_at": now(), "notes": "not run"})
    (run / "results.json").write_text(json.dumps(out, indent=1) + "\n")
    for e in out:
        print(f"{e['id']}  {e['status']:<7}  {e['notes']}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("record")
    r.add_argument("--run-dir", required=True)
    r.add_argument("--id", required=True)
    r.add_argument("--status", required=True, choices=STATUSES)
    r.add_argument("--notes", default="")
    r.add_argument("--log")
    b = sub.add_parser("build")
    b.add_argument("--run-dir", required=True)
    a = ap.parse_args(argv)
    record(a) if a.cmd == "record" else build(a)


if __name__ == "__main__":
    main(sys.argv[1:])
