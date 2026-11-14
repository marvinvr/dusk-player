#!/usr/bin/env python3
"""Run hosted unit suites headlessly, sequentially, on disposable simulators."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent


def capture(*args):
    return subprocess.check_output(args, text=True, timeout=60).strip()


def run(command, log, timeout=600):
    print(f"{log.name}: starting", flush=True)
    with log.open("w") as output:
        process = subprocess.Popen(command, cwd=ROOT, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except BaseException as error:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            if isinstance(error, subprocess.TimeoutExpired):
                raise RuntimeError(f"Timed out after {timeout}s: {log}") from error
            raise
    if code:
        raise RuntimeError(f"Command failed ({code}): {log}")
    print(f"{log.name}: passed", flush=True)


def run_platform(platform, output):
    devices = json.loads(capture("xcrun", "simctl", "list", "devices", "available", "--json"))["devices"]
    runtime_prefix = "iOS-" if platform == "ios" else "tvOS-"
    name_prefix = "iPhone" if platform == "ios" else "Apple TV"
    # Reuse only a known-compatible type/runtime pair, never another device's data.
    choices = [(runtime, device) for runtime, group in devices.items()
               if f"SimRuntime.{runtime_prefix}" in runtime
               for device in group if device["name"].startswith(name_prefix)]
    if not choices:
        raise RuntimeError(f"No available {platform} simulator runtime/device type")
    runtime, reference = max(choices, key=lambda pair: tuple(
        int(value) for value in pair[0].split(".")[-1].split("-")[1:]))
    device = capture("xcrun", "simctl", "create", f"Dusk Unit {platform} {uuid.uuid4().hex[:8]}",
                     reference["deviceTypeIdentifier"], runtime)
    print(f"{platform}: disposable simulator {device} ({runtime})", flush=True)
    scheme = "Dusk" if platform == "ios" else "Dusk-tvOS"
    target = "DuskTests" if platform == "ios" else "DuskTests-tvOS"
    destination = f"platform={'iOS' if platform == 'ios' else 'tvOS'} Simulator,id={device}"
    common = ["xcodebuild", "-project", "Dusk.xcodeproj", "-scheme", scheme,
              "-configuration", "Debug", "-destination", destination,
              "-derivedDataPath", str(output / f"dd-{platform}"),
              "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES"]
    testing = ["-parallel-testing-enabled", "NO", "-test-timeouts-enabled", "YES",
               "-maximum-test-execution-time-allowance", "30"]
    try:
        run(["xcrun", "simctl", "bootstatus", device, "-b"], output / f"{platform}-boot.log", 180)
        run(common + ["build-for-testing"], output / f"{platform}-build.log")
        # SKTestSession installs local configuration in storekitd, but a cold
        # host has already selected Sandbox for that process. Prepare with a
        # catalog-only test, then start a new host for purchases. No failed-test
        # retry and no account/confirmation UI is involved.
        preparation = output / f"{platform}-storekit-prepare.log"
        run(common + testing + ["-resultBundlePath", str(output / f"{platform}-prepare.xcresult"),
            f"-only-testing:{target}/SupporterStoreKitTests/catalogHasOneSubscriptionWithTwoPlans()",
            "test-without-building"], preparation, 120)
        if "Test catalogHasOneSubscriptionWithTwoPlans() passed" not in preparation.read_text():
            raise RuntimeError(f"StoreKit preparation did not execute its test: {preparation}")
        run(common + testing + ["-resultBundlePath", str(output / f"{platform}-units.xcresult"),
                               "test-without-building"], output / f"{platform}-units.log")
    finally:
        # Only the simulator created above belongs to this run.
        try:
            subprocess.run(["xcrun", "simctl", "shutdown", device], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=60)
        finally:
            subprocess.run(["xcrun", "simctl", "delete", device], check=True, timeout=60)
        print(f"{platform}: deleted {device}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=["ios", "tvos", "all"], default="all")
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    output = args.output_dir or Path(tempfile.mkdtemp(prefix="dusk-unit-tests-"))
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    print(f"Logs and result bundles: {output}", flush=True)
    for platform in (["ios", "tvos"] if args.platform == "all" else [args.platform]):
        run_platform(platform, output)


if __name__ == "__main__":
    # Turn termination into cleanup through the active run/finally blocks.
    def terminate(_signal, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, terminate)
    try:
        main()
    except (RuntimeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        print(f"Unit verification stopped: {error}", file=sys.stderr)
        sys.exit(1)
