#!/usr/bin/env python3
"""Tallies UI test failures: across recent CI runs, or in one run's xcodebuild logs.

    scripts/flake-report.py [--limit N] [--days D] [--min M] [--branch NAME] [--repo OWNER/REPO]
    scripts/flake-report.py --summary [--title TEXT] LOG...

The first form reads the last N runs of the CI workflow (default 100, main and every branch) with
`gh`, every attempt of them that failed (a run re-run to green included), fetches the logs of their
failed or timed-out UI test jobs and counts, per UI test and failure message, the attempts it failed
in. Then it prints the tests that failed in at least M attempts (default 2) in the last D days
(default 14) as candidates for scripts/ui-test-quarantine.txt, ready to paste, and marks those
already quarantined or gone. Failures on one branch alone are more likely a real break on that
branch than a flaky test, so the branches are listed too. Needs `gh` signed in; for people and
agents, not CI.

`--summary` prints a Markdown table of the failed tests in xcodebuild logs (test, failed runs of
it, message), for CI to append to $GITHUB_STEP_SUMMARY. A missing log is skipped. A test that
started and never finished (a hang, or the job's timeout) counts as failed. If a log ends without a
TEST EXECUTE verdict, its last lines are shown too. Prints nothing when every log passed.
"""

from __future__ import annotations

import argparse
import collections
import concurrent.futures
import datetime
import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

TARGET = "CormorantUITests"
# /path/StatusBarTests.swift:243: error: -[CormorantUITests.StatusBarTests testDarkMode] : XCTAssertTrue failed - ...
ERROR = re.compile(r"error: -\[" + TARGET + r"\.(\w+) (test\w*)\] : (.*)$")
# Test Case '-[CormorantUITests.StatusBarTests testDarkMode]' failed (79.557 seconds).
CASE = re.compile(r"Test Case '-\[" + TARGET + r"\.(\w+) (test\w*)\]' (started|passed|failed)")
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
# A job log's timestamp before each line, after `gh run view --log` style job and step columns if any.
GH_PREFIX = re.compile(r"^(?:[^\t]*\t[^\t]*\t)?\ufeff?(?:\d{4}-\d\d-\d\dT[\d:.]+Z )?")
NO_MESSAGE = "(no failure message in the log)"
UNFINISHED = "still running when the log ended: a hang, or the job's timeout"


def failures(text: str) -> tuple[dict[str, list[str]], collections.Counter, collections.Counter]:
    """Per failed test, its messages in order (one per failure); and per test, runs passed and failed."""
    messages: dict[str, list[str]] = collections.defaultdict(list)
    passed: collections.Counter = collections.Counter()
    failed: collections.Counter = collections.Counter()
    pending: dict[str, list[str]] = collections.defaultdict(list)
    running: set[str] = set()
    for raw in text.splitlines():
        line = GH_PREFIX.sub("", ANSI.sub("", raw), count=1).rstrip()
        if m := ERROR.search(line):
            pending[f"{TARGET}/{m.group(1)}/{m.group(2)}"].append(m.group(3).strip() or NO_MESSAGE)
        elif m := CASE.search(line):
            test = f"{TARGET}/{m.group(1)}/{m.group(2)}"
            if m.group(3) == "started":
                running.add(test)
                continue
            running.discard(test)
            if m.group(3) == "passed":
                passed[test] += 1
                pending.pop(test, None)
            else:
                failed[test] += 1
                # UITestCase stops a test at its first failure: the first error is the one.
                found = pending.pop(test, [])
                messages[test].append(found[0] if found else NO_MESSAGE)
    # A test with no `Test Case ... passed/failed` line: the run was cut off mid-test. (CI's job logs
    # leave out the `started` lines; xcodebuild's own log has them.)
    for test in sorted(running | set(pending)):
        failed[test] += 1
        found = pending.get(test)
        messages[test].append(found[0] + " (the run ended before the test did)" if found else UNFINISHED)
    return messages, passed, failed


def cell(text: str) -> str:
    return text.replace("|", "\\|").replace("\n", " ")


def summary(logs: list[Path], title: str) -> None:
    rows = []
    unexplained = []
    for log in logs:
        if not log.exists():
            continue
        text = log.read_text(errors="replace")
        messages, passed, failed = failures(text)
        for test in sorted(messages):
            runs = passed[test] + failed[test]
            counted = collections.Counter(messages[test])
            message = "<br>".join(cell(m) + (f" (×{n})" if n > 1 else "") for m, n in counted.items())
            rows.append(f"| `{test.split('/', 1)[1]}` | {failed[test]} of {runs} | {message} |")
        if text.strip() and ("TEST EXECUTE" not in text or not messages and "TEST EXECUTE SUCCEEDED" not in text):
            tail = "\n".join(text.rstrip().splitlines()[-25:])
            unexplained.append(f"`{log.name}` ends without passing; its last lines:\n\n```\n{tail}\n```")
    if not rows and not unexplained:
        return
    print(f"### {title}\n")
    if rows:
        print("| Test | Failed | Message |\n| --- | --- | --- |")
        print("\n".join(rows))
        print()
    for note in unexplained:
        print(note + "\n")


def gh(*args: str) -> str:
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def shard_module():
    """scripts/ui-test-shard.py, for the current tests and the quarantine."""
    spec = importlib.util.spec_from_file_location("ui_test_shard", Path(__file__).with_name("ui-test-shard.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def report(limit: int, days: int, minimum: int, branch: str | None, slug: str | None) -> None:
    repo = ["--repo", slug] if slug else []
    query = ["run", "list", "--workflow", "ci.yml", "--limit", str(limit),
             "--json", "databaseId,attempt,status,conclusion,headBranch,url"] + repo
    if branch:
        query += ["--branch", branch]
    runs = json.loads(gh(*query))
    # Every attempt that can hold a failure: a run re-run to green still failed before, and clicking
    # re-run is how a flaky test hides. The latest attempt of a run still going is left for later.
    attempts = []
    for run in runs:
        last = run["attempt"] if run["status"] == "completed" and run["conclusion"] != "success" else run["attempt"] - 1
        attempts += [(run, n) for n in range(1, last + 1)]
    print(f"{len(runs)} CI runs, {len(attempts)} attempts that didn't pass or were re-run; reading their "
          "UI test jobs' logs...", file=sys.stderr)

    def fetch(item: tuple[dict, int]) -> list[tuple[dict, int, str, str]]:
        """The attempt's failed or cancelled (timed-out) UI test jobs: (run, attempt, started, log)."""
        run, attempt = item
        found = []
        try:
            jobs = json.loads(gh("run", "view", str(run["databaseId"]), "--attempt", str(attempt),
                                 "--json", "jobs", *repo))["jobs"]
        except (RuntimeError, KeyError, ValueError) as error:
            print(f"skipped run {run['databaseId']} attempt {attempt}: {error}", file=sys.stderr)
            return found
        for job in jobs:
            if "UI tests" in job["name"] and job["conclusion"] in ("failure", "cancelled", "timed_out"):
                # The API, not `gh run view --job ID --log`, which gives the run's latest attempt
                # whatever the job.
                path = f"repos/{slug or '{owner}/{repo}'}/actions/jobs/{job['databaseId']}/logs"
                try:
                    found.append((run, attempt, job["startedAt"], gh("api", "--allow-escape-sequences", path)))
                except RuntimeError as error:
                    print(f"skipped {job['name']} of run {run['databaseId']} attempt {attempt} "
                          f"(logs expire): {error}", file=sys.stderr)
        return found

    # Per test, the attempts it failed in (run, attempt, started), and per message, how many.
    tests: dict[str, dict[tuple[int, int], tuple[dict, int, str]]] = collections.defaultdict(dict)
    by_message: dict[tuple[str, str], set] = collections.defaultdict(set)
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        for found in pool.map(fetch, attempts):
            for run, attempt, started, log in found:
                messages, _, _ = failures(log)
                for test, found_messages in messages.items():
                    key = (run["databaseId"], attempt)
                    tests[test].setdefault(key, (run, attempt, started))
                    for message in found_messages:
                        by_message[(test, message)].add(key)

    if not tests:
        return print("No failed UI tests in those runs.")
    print(f"Failed UI tests in the last {len(runs)} CI runs (attempts failed, then by message):\n")
    for test in sorted(tests, key=lambda t: (-len(tests[t]), t)):
        print(f"{len(tests[test]):3}  {test}")
        for (t, message), keys in sorted(by_message.items(), key=lambda item: -len(item[1])):
            if t == test:
                print(f"       {len(keys):3}  {message}")

    since = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)
    candidates = []
    for test, failed_in in tests.items():
        recent = [entry for entry in failed_in.values()
                  if datetime.datetime.fromisoformat(entry[2].replace("Z", "+00:00")) >= since]
        if len(recent) >= minimum:
            candidates.append((test, sorted(recent, key=lambda entry: entry[2], reverse=True)))
    print(f"\nQuarantine candidates (failed in {minimum}+ attempts in the last {days} days):\n")
    if not candidates:
        return print("  none")
    shard = shard_module()
    current = shard.tests()
    entries, _ = shard.quarantine(current)
    already = {test: date for _, date, test, _ in entries}
    today = datetime.date.today().isoformat()
    for test, recent in sorted(candidates, key=lambda c: (-len(c[1]), c[0])):
        branches = collections.Counter(run["headBranch"] for run, _, _ in recent)
        where = ", ".join(f"{b} ×{n}" if n > 1 else b for b, n in branches.most_common())
        if test in already:
            status = f"  (already quarantined since {already[test]})"
        elif test not in current:
            status = "  (no longer in the source)"
        else:
            status = ""
        print(f"  {today} {test}  failed in {len(recent)} attempts ({where}){status}")
        run, attempt, _ = recent[0]
        print(f"      latest: {run['url']}/attempts/{attempt}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--summary", action="store_true", help="Markdown table of the failures in LOGs")
    parser.add_argument("--title", default="Failed UI tests")
    parser.add_argument("logs", nargs="*", type=Path)
    parser.add_argument("--limit", type=int, default=100, help="CI runs to read (default 100)")
    parser.add_argument("--days", type=int, default=14, help="window for quarantine candidates (default 14)")
    parser.add_argument("--min", type=int, default=2, help="failed attempts that make a candidate (default 2)")
    parser.add_argument("--branch", help="only this branch's runs")
    parser.add_argument("--repo", help="OWNER/REPO, if not this checkout's")
    args = parser.parse_args()
    if args.summary:
        return summary(args.logs, args.title)
    if args.logs:
        parser.error("LOGs go with --summary")
    report(args.limit, args.days, args.min, args.branch, args.repo)


if __name__ == "__main__":
    main()
