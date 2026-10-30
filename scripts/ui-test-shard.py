#!/usr/bin/env python3
"""Prints the xcodebuild -only-testing flags for one shard of the UI tests.

    scripts/ui-test-shard.py INDEX COUNT

Finds every `test...` method of every XCTestCase or UITestCase subclass in
apps/ios/CormorantUITests and deals them out round-robin, so each of COUNT shards gets a share and a
new test lands in one with no config change. Shards split by test rather than by class: each test launches the app on its own,
and one class alone would otherwise set the floor. Exits non-zero if the shard comes out empty,
because xcodebuild with no -only-testing would run the whole suite, and if any `func test` isn't
directly in such a class's body (an extension, a base class), which no shard would run.
"""

import re
import sys
from pathlib import Path

TARGET = "CormorantUITests"
SOURCES = Path(__file__).resolve().parent.parent / "apps/ios" / TARGET

CLASS = re.compile(r"^\s*(?:@\w+\s+)*(?:final\s+)?class\s+(\w+)\s*:\s*(?:XCTestCase|UITestCase)\b")
TEST = re.compile(r"^\s*func\s+(test\w*)\s*\(")
ANY_TEST = re.compile(r"\bfunc\s+test\w*\s*\(")


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


def main() -> None:
    index, count = (int(arg) for arg in sys.argv[1:3])
    if not 0 <= index < count:
        sys.exit(f"shard index {index} is outside 0..<{count}")
    shard = tests()[index::count]
    if not shard:
        sys.exit(f"shard {index} of {count} has no tests")
    print(" ".join(f"-only-testing:{test}" for test in shard))


if __name__ == "__main__":
    main()
