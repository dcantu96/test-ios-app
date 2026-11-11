#!/usr/bin/env python3
"""How long a CI run took, job by job and step by step.

    python3 scripts/ci-timing.py [RUN_ID]      # default: the latest run on the current branch

Needs the GitHub CLI (gh). "Wall" is from the run's creation (the push) to its last job finishing; that's the
number to make small. Queue is how long a job waited for a runner.
"""
import datetime as dt
import json
import subprocess
import sys

REPO = "dcantu96/test-ios-app"


def gh(*args):
    return json.loads(subprocess.check_output(["gh", *args]))


def ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")) if s and not s.startswith("0001") else None


def main():
    if len(sys.argv) > 1:
        run_id = sys.argv[1]
    else:
        branch = subprocess.check_output(["git", "branch", "--show-current"], text=True).strip()
        run_id = gh("run", "list", "-R", REPO, "--branch", branch, "--limit", "1", "--json", "databaseId")[0]["databaseId"]
    run = gh("run", "view", str(run_id), "-R", REPO, "--json", "createdAt,status,conclusion,jobs,displayTitle,headSha")
    created = ts(run["createdAt"])
    print(f"run {run_id} ({run['headSha'][:7]}) {run['status']} {run['conclusion'] or ''}: {run['displayTitle']}")
    end = created
    for job in run["jobs"]:
        start, done = ts(job["startedAt"]), ts(job["completedAt"])
        if not start:
            print(f"  {job['name']}: not started")
            continue
        end = max(end, done or start)
        took = f"{(done - start).total_seconds():.0f}s" if done else "running"
        print(f"  {job['name']}: {took} (starts at +{(start - created).total_seconds():.0f}s, ends at +{((done or start) - created).total_seconds():.0f}s) {job['conclusion'] or ''}")
        for st in job["steps"]:
            a, b = ts(st["startedAt"]), ts(st["completedAt"])
            if a and b and (b - a).total_seconds() >= 1:
                print(f"      {(b - a).total_seconds():5.0f}s  {st['name']}")
    print(f"  wall: {(end - created).total_seconds():.0f}s from push to last job done")


if __name__ == "__main__":
    main()
