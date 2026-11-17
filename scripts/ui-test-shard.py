#!/usr/bin/env python3
"""Prints the xcodebuild -only-testing flags for one shard of the UI tests, and keeps the quarantine.

    scripts/ui-test-shard.py INDEX COUNT [HEAD_START] [--include-quarantined] [--new TESTS [--only-new]]
    scripts/ui-test-shard.py --record LOG...
    scripts/ui-test-shard.py --check-quarantine [--today YYYY-MM-DD]
    scripts/ui-test-shard.py --new-since REV

Finds every `test...` method of every XCTestCase or UITestCase subclass in
apps/ios/CormorantUITests and deals them out so each of COUNT shards gets about the same run time:
the longest test first, each onto the shard with the least so far, with the times in
scripts/ui-test-durations.txt (seconds per test, from CI). A test the file doesn't know gets the
median, so a new test lands in a shard with no config change. HEAD_START is seconds of other work
the first shard does before its tests (CI's shard 1 also runs the package tests), counted as load it
starts with. Shards split by test rather than by class: each test launches the app on its own, and
one class alone would otherwise set the floor.

Tests in scripts/ui-test-quarantine.txt are left out of the shards unless --include-quarantined
(CI's nightly and by-hand runs). Every entry must name a test that exists, with a date that parses;
`--check-quarantine` also fails, with a GitHub `::error::` per entry, once an entry is
QUARANTINE_DAYS old (`--today` stands in for today, to try it).

`--new-since REV` prints, on one line, the tests that exist now but not at REV (a pull request's new
or renamed tests). `--new TESTS` (space-separated, as printed) weighs those tests for the
NEW_TEST_ITERATIONS extra runs CI gives them, so the shards stay balanced; with `--only-new` it
prints just this shard's share of them, possibly nothing. Pass the same arguments to both calls, so
both deal the same shards.

`--record` rewrites the durations file from xcodebuild logs (`Test Case '...' passed (N seconds)`
lines), such as `gh run view --job ID --log` for each shard of a CI run; a test in no log keeps its
old time, and one that no longer exists is dropped. Refresh it now and then, or when a shard runs
long: the file only steers the split, and a stale one costs balance, never correctness.

Exits non-zero if the shard comes out empty, because xcodebuild with no -only-testing would run the
whole suite, and if any `func test` isn't directly in such a class's body (an extension, a base
class), which no shard would run.
"""

from __future__ import annotations

import datetime
import re
import statistics
import subprocess
import sys
from pathlib import Path

TARGET = "CormorantUITests"
ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "apps/ios" / TARGET
DURATIONS = ROOT / "scripts/ui-test-durations.txt"
QUARANTINE = ROOT / "scripts/ui-test-quarantine.txt"
QUARANTINE_DAYS = 14
# CI runs each new test this many more times after its shard's own run (ci.yml, "New UI tests").
NEW_TEST_ITERATIONS = 10

CLASS = re.compile(r"^\s*(?:@\w+\s+)*(?:final\s+)?class\s+(\w+)\s*:\s*(?:XCTestCase|UITestCase)\b")
TEST = re.compile(r"^\s*func\s+(test\w*)\s*\(")
ANY_TEST = re.compile(r"\bfunc\s+test\w*\s*\(")
# xcodebuild: Test Case '-[CormorantUITests.SpacesTests testTabsMenuOpensManageSpaces]' passed (37.534 seconds).
RESULT = re.compile(r"Test Case '-\[" + TARGET + r"\.(\w+) (test\w*)\]' (?:passed|failed) \(([\d.]+) seconds\)")
# 2026-11-17 CormorantUITests/StatusBarTests/testDarkMode  reason
QUARANTINE_ENTRY = re.compile(r"^(\S+)\s+(\S+)(?:\s+(.*\S))?\s*$")


def parse_tests(sources: dict[str, str], strict: bool = True) -> list[str]:
    """Test IDs in the given Swift sources (file name to text)."""
    found = []
    declared = 0
    for name in sorted(sources):
        current = None
        for line in sources[name].splitlines():
            declared += len(ANY_TEST.findall(line))
            if m := CLASS.match(line):
                current = m.group(1)
            elif current and (m := TEST.match(line)):
                found.append(f"{TARGET}/{current}/{m.group(1)}")
    if strict and len(found) != declared:
        sys.exit(f"found {declared} `func test` declarations but placed {len(found)}; "
                 "put tests directly in an XCTestCase or UITestCase subclass "
                 "or teach this script about them")
    return sorted(set(found))


def tests() -> list[str]:
    return parse_tests({path.name: path.read_text() for path in SOURCES.glob("*.swift")})


def tests_at(rev: str) -> list[str]:
    """Test IDs in the UI test sources at a git revision; none if it has no such folder."""
    folder = SOURCES.relative_to(ROOT).as_posix()
    listed = subprocess.run(["git", "ls-tree", "--name-only", f"{rev}:{folder}"], cwd=ROOT,
                            capture_output=True, text=True)
    if listed.returncode != 0:
        if subprocess.run(["git", "rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}"], cwd=ROOT,
                          capture_output=True).returncode != 0:
            sys.exit(f"no such revision: {rev}")
        return []
    sources = {}
    for name in listed.stdout.split("\n"):
        if name.endswith(".swift"):
            sources[name] = subprocess.run(["git", "show", f"{rev}:{folder}/{name}"], cwd=ROOT, check=True,
                                           capture_output=True, text=True).stdout
    return parse_tests(sources, strict=False)


def durations() -> dict[str, float]:
    """Seconds per test from the durations file; empty if there is none."""
    known = {}
    if DURATIONS.exists():
        for line in DURATIONS.read_text().splitlines():
            if line.startswith("#") or not line.strip():
                continue
            seconds, test = line.split()
            known[test] = float(seconds)
    return known


def quarantine(existing: list[str]) -> tuple[list[tuple[int, datetime.date, str, str]], list[str]]:
    """The quarantine file's entries (line, date, test, reason) and its problems, each an error message."""
    entries, problems, seen = [], [], set()
    if not QUARANTINE.exists():
        return entries, problems
    known = set(existing)
    for number, line in enumerate(QUARANTINE.read_text().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = QUARANTINE_ENTRY.match(line)
        if not m:
            problems.append(f"line {number}: expected `YYYY-MM-DD {TARGET}/Class/testName  reason`")
            continue
        when, test, reason = m.groups()
        try:
            if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", when):
                raise ValueError
            date = datetime.date.fromisoformat(when)
        except ValueError:
            problems.append(f"line {number}: '{when}' isn't a date (YYYY-MM-DD)")
            continue
        if test not in known:
            problems.append(f"line {number}: no test {test} in {SOURCES.relative_to(ROOT)}; "
                            "remove the entry if the test is gone")
            continue
        if not reason:
            problems.append(f"line {number}: say why {test} is quarantined, after its name")
            continue
        if test in seen:
            problems.append(f"line {number}: {test} is already quarantined above")
            continue
        seen.add(test)
        entries.append((number, date, test, reason))
    return entries, problems


def quarantined(existing: list[str]) -> set[str]:
    entries, problems = quarantine(existing)
    if problems:
        sys.exit(f"{QUARANTINE.relative_to(ROOT)}: " + "; ".join(problems))
    return {test for _, _, test, _ in entries}


def check_quarantine(today: datetime.date) -> None:
    """GitHub annotations for every bad or expired entry; exits non-zero if there are any."""
    path = QUARANTINE.relative_to(ROOT)
    entries, problems = quarantine(tests())
    failed = bool(problems)
    for problem in problems:
        number, _, message = problem.partition(": ")
        print(f"::error file={path},{number.replace(' ', '=')}::{message}")
    for number, date, test, reason in entries:
        age = (today - date).days
        if age < 0:
            failed = True
            print(f"::error file={path},line={number}::{test} is dated {date}, after today ({today}); "
                  "date an entry the day it's quarantined")
        elif age >= QUARANTINE_DAYS:
            failed = True
            print(f"::error file={path},line={number}::{test} has been quarantined for {age} days, "
                  f"since {date} (the limit is {QUARANTINE_DAYS}): fix it, move what it checks to a "
                  f"lower-level test, or delete it. Quarantined because: {reason}")
        else:
            expires = date + datetime.timedelta(days=QUARANTINE_DAYS)
            level = "warning" if (expires - today).days <= 3 else "notice"
            print(f"::{level} file={path},line={number}::{test} is quarantined (since {date}); CI fails "
                  f"from {expires} unless it's fixed, moved or deleted: {reason}")
    if failed:
        sys.exit(1)
    print(f"{len(entries)} quarantined UI test{'' if len(entries) == 1 else 's'}, none past its "
          f"{QUARANTINE_DAYS} days")


def shards(tests: list[str], count: int, known: dict[str, float], head_start: float = 0,
           new: frozenset[str] = frozenset()) -> list[list[str]]:
    """Longest first, each onto the lightest shard; ties (and unknown tests) go by name, so the split
    is the same on every runner. A new test weighs its extra runs too."""
    default = statistics.median(known.values()) if known else 1.0
    weight = {test: known.get(test, default) * (1 + NEW_TEST_ITERATIONS if test in new else 1)
              for test in tests}
    loads = [head_start] + [0.0] * (count - 1)
    result: list[list[str]] = [[] for _ in range(count)]
    for test in sorted(tests, key=lambda t: (-weight[t], t)):
        index = min(range(count), key=lambda i: (loads[i], i))
        loads[index] += weight[test]
        result[index].append(test)
    return [sorted(shard) for shard in result]


def record(logs: list[Path]) -> None:
    measured = {}
    for log in logs:
        for m in RESULT.finditer(log.read_text(errors="replace")):
            measured[f"{TARGET}/{m.group(1)}/{m.group(2)}"] = float(m.group(3))
    if not measured:
        sys.exit("no `Test Case ... (N seconds)` lines in the logs given")
    current = tests()
    known = durations() | measured
    lines = ["# Seconds each UI test took in CI, for scripts/ui-test-shard.py to balance the shards with.",
             "# Refresh: scripts/ui-test-shard.py --record LOG... (xcodebuild logs, e.g. `gh run view --job ID --log`).",
             ""]
    lines += [f"{known[test]:.1f} {test}" for test in current if test in known]
    DURATIONS.write_text("\n".join(lines) + "\n")
    missing = [test for test in current if test not in known]
    print(f"recorded {len(measured)} tests; {len(missing)} with no time yet" + (": " + " ".join(missing) if missing else ""))


def usage() -> None:
    sys.exit(__doc__.split("\n\n")[1])


def main() -> None:
    args = sys.argv[1:]
    if args[:1] == ["--record"]:
        return record([Path(arg) for arg in args[1:]])
    if args[:1] == ["--check-quarantine"]:
        if args[1:2] == ["--today"] and len(args) == 3:
            return check_quarantine(datetime.date.fromisoformat(args[2]))
        if len(args) != 1:
            usage()
        return check_quarantine(datetime.datetime.now(datetime.timezone.utc).date())
    if args[:1] == ["--new-since"]:
        if len(args) != 2:
            usage()
        base = set(tests_at(args[1]))
        return print(" ".join(test for test in tests() if test not in base))

    include_quarantined = only_new = False
    new: frozenset[str] = frozenset()
    positional = []
    while args:
        arg = args.pop(0)
        if arg == "--include-quarantined":
            include_quarantined = True
        elif arg == "--only-new":
            only_new = True
        elif arg == "--new" and args:
            new = frozenset(args.pop(0).split())
        elif arg.startswith("-") and not re.fullmatch(r"-?\d+(\.\d+)?", arg):
            usage()
        else:
            positional.append(arg)
    if not 2 <= len(positional) <= 3:
        usage()
    index, count = int(positional[0]), int(positional[1])
    head_start = float(positional[2]) if len(positional) > 2 else 0
    if not 0 <= index < count:
        sys.exit(f"shard index {index} is outside 0..<{count}")
    every = tests()
    skipped = set() if include_quarantined else quarantined(every)
    if include_quarantined:
        quarantined(every)  # still a mistyped entry fails
    gated = [test for test in every if test not in skipped]
    shard = shards(gated, count, durations(), head_start, new & set(gated))[index]
    if only_new:
        return print(" ".join(f"-only-testing:{test}" for test in shard if test in new))
    if not shard:
        sys.exit(f"shard {index} of {count} has no tests")
    print(" ".join(f"-only-testing:{test}" for test in shard))


if __name__ == "__main__":
    main()
