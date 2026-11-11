#!/usr/bin/env python3
"""Prints the xcodebuild -only-testing flags for one shard of the UI tests.

    scripts/ui-test-shard.py INDEX COUNT [HEAD_START]
    scripts/ui-test-shard.py --record LOG...

Finds every `test...` method of every XCTestCase or UITestCase subclass in
apps/ios/CormorantUITests and deals them out so each of COUNT shards gets about the same run time:
the longest test first, each onto the shard with the least so far, with the times in
scripts/ui-test-durations.txt (seconds per test, from CI). A test the file doesn't know gets the
median, so a new test lands in a shard with no config change. HEAD_START is seconds of other work
the first shard does before its tests (CI's shard 1 also runs the package tests), counted as load it
starts with. Shards split by test rather than by class: each test launches the app on its own, and
one class alone would otherwise set the floor.

`--record` rewrites the durations file from xcodebuild logs (`Test Case '...' passed (N seconds)`
lines), such as `gh run view --job ID --log` for each shard of a CI run; a test in no log keeps its
old time, and one that no longer exists is dropped. Refresh it now and then, or when a shard runs
long: the file only steers the split, and a stale one costs balance, never correctness.

Exits non-zero if the shard comes out empty, because xcodebuild with no -only-testing would run the
whole suite, and if any `func test` isn't directly in such a class's body (an extension, a base
class), which no shard would run.
"""

import re
import statistics
import sys
from pathlib import Path

TARGET = "CormorantUITests"
ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "apps/ios" / TARGET
DURATIONS = ROOT / "scripts/ui-test-durations.txt"

CLASS = re.compile(r"^\s*(?:@\w+\s+)*(?:final\s+)?class\s+(\w+)\s*:\s*(?:XCTestCase|UITestCase)\b")
TEST = re.compile(r"^\s*func\s+(test\w*)\s*\(")
ANY_TEST = re.compile(r"\bfunc\s+test\w*\s*\(")
# xcodebuild: Test Case '-[CormorantUITests.SpacesTests testTabsMenuOpensManageSpaces]' passed (37.534 seconds).
RESULT = re.compile(r"Test Case '-\[" + TARGET + r"\.(\w+) (test\w*)\]' (?:passed|failed) \(([\d.]+) seconds\)")


def tests() -> list[str]:
    found = []
    declared = 0
    for path in sorted(SOURCES.glob("*.swift")):
        current = None
        for line in path.read_text().splitlines():
            declared += len(ANY_TEST.findall(line))
            if m := CLASS.match(line):
                current = m.group(1)
            elif current and (m := TEST.match(line)):
                found.append(f"{TARGET}/{current}/{m.group(1)}")
    if len(found) != declared:
        sys.exit(f"found {declared} `func test` declarations but placed {len(found)}; "
                 "put tests directly in an XCTestCase or UITestCase subclass "
                 "or teach this script about them")
    return sorted(found)


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


def shards(tests: list[str], count: int, known: dict[str, float], head_start: float = 0) -> list[list[str]]:
    """Longest first, each onto the lightest shard; ties (and unknown tests) go by name, so the split
    is the same on every runner."""
    default = statistics.median(known.values()) if known else 1.0
    weight = {test: known.get(test, default) for test in tests}
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


def main() -> None:
    if sys.argv[1:2] == ["--record"]:
        return record([Path(arg) for arg in sys.argv[2:]])
    index, count = (int(arg) for arg in sys.argv[1:3])
    head_start = float(sys.argv[3]) if len(sys.argv) > 3 else 0
    if not 0 <= index < count:
        sys.exit(f"shard index {index} is outside 0..<{count}")
    shard = shards(tests(), count, durations(), head_start)[index]
    if not shard:
        sys.exit(f"shard {index} of {count} has no tests")
    print(" ".join(f"-only-testing:{test}" for test in shard))


if __name__ == "__main__":
    main()
