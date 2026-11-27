#!/usr/bin/env python3
"""G1 (docs/jellyfin/05-plan.md §3): every unit suite green and no fewer test
cases than the baseline.

  units.py check  [--platform ios|tvos|all]   # run scripts/test_units.py, then compare counts
  units.py record [--platform ios|tvos|all]   # store the counts in baseline/units.json
  units.py check --results DIR                # only compare an existing test_units.py output dir

The total and the passed count per platform must not drop (skipped tests
are fine, a test that becomes skipped is not). Per-suite drops are printed so a
renamed suite can be told from a deleted test; a sweep may rename suites and
tests, never remove them.
"""
import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASELINE = Path(__file__).resolve().parent / "baseline" / "units.json"


def test_cases(xcresult):
    tree = json.loads(subprocess.check_output(
        ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(xcresult)], text=True, timeout=300))
    suites, failed, passed = {}, [], [0]

    def walk(node, suite):
        kind = node.get("nodeType")
        if kind == "Test Suite":
            suite = node.get("name", suite)
        if kind == "Test Case":
            suites[suite] = suites.get(suite, 0) + 1
            if node.get("result") in ("Passed", "Expected Failure"):
                passed[0] += 1
            elif node.get("result") != "Skipped":
                failed.append(f"{suite}/{node.get('name')}: {node.get('result')}")
            return
        for child in node.get("children", []):
            walk(child, suite)

    for node in tree.get("testNodes", []):
        walk(node, "?")
    return suites, failed, passed[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=["check", "record"])
    parser.add_argument("--platform", choices=["ios", "tvos", "all"], default="all")
    parser.add_argument("--results", type=Path, help="existing scripts/test_units.py --output-dir")
    args = parser.parse_args()
    platforms = ["ios", "tvos"] if args.platform == "all" else [args.platform]

    results = args.results
    if not results:
        results = Path(tempfile.mkdtemp(prefix="dusk-g1-"))
        code = subprocess.call([sys.executable, str(ROOT / "scripts" / "test_units.py"), "--platform", args.platform,
                                "--output-dir", str(results)], cwd=ROOT)
        if code:
            print(f"G1 FAILED: test_units.py exited {code} (logs in {results})")
            sys.exit(1)

    baseline = json.loads(BASELINE.read_text()) if BASELINE.exists() else {}
    problems = []
    for platform in platforms:
        xcresult = results / f"{platform}-units.xcresult"
        if not xcresult.exists():
            problems.append(f"{platform}: no result bundle at {xcresult}")
            continue
        suites, failed, passed = test_cases(xcresult)
        total = sum(suites.values())
        print(f"{platform}: {total} test cases in {len(suites)} suites, {passed} passed, "
              f"{total - passed - len(failed)} skipped, {len(failed)} failed")
        problems += [f"{platform}: {line}" for line in failed]
        if args.mode == "record":
            baseline[platform] = {"total": total, "passed": passed, "suites": dict(sorted(suites.items()))}
            continue
        expected = baseline.get(platform)
        if not expected:
            problems.append(f"{platform}: no baseline in {BASELINE}")
            continue
        if total < expected["total"]:
            problems.append(f"{platform}: {total} test cases, baseline has {expected['total']}")
        # Skips are allowed (env-gated suites, recorders) but may not grow at the expense of passes.
        if passed < expected["passed"]:
            problems.append(f"{platform}: {passed} passed, baseline has {expected['passed']} (more skipped?)")
        for suite, count in expected["suites"].items():
            if suites.get(suite, 0) < count:
                print(f"  note: {platform} {suite}: {suites.get(suite, 0)} < baseline {count} (renamed or removed?)")

    if args.mode == "record":
        if problems:
            print("not recording, failures:\n" + "\n".join(problems))
            sys.exit(1)
        BASELINE.write_text(json.dumps(baseline, indent=2) + "\n")
        print(f"recorded {BASELINE}")
        return
    if problems:
        print("G1 FAILED:\n" + "\n".join(problems))
        sys.exit(1)
    print("G1: green, test case count not lower than baseline")


if __name__ == "__main__":
    main()
