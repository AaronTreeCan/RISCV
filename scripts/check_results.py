#!/usr/bin/env python3
"""Exit non-zero if a cocotb results.xml has failures, so `make test` and CI fail loudly."""

import sys
import xml.etree.ElementTree as ET


def main(path: str) -> int:
    try:
        tree = ET.parse(path)
    except (FileNotFoundError, ET.ParseError):
        print(f"FAIL: no test results at {path}. Did the RTL compile? Scroll up for errors.")
        return 1

    tests = list(tree.iter("testcase"))
    failed = [t for t in tests if t.find("failure") is not None or t.find("error") is not None]

    if not tests:
        print(f"FAIL: {path} contains no tests. Is the test module name right?")
        return 1

    for t in failed:
        print(f"FAIL: {t.get('name')}")
    print(f"{len(tests) - len(failed)}/{len(tests)} tests passed ({path})")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: check_results.py <results.xml>")
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
