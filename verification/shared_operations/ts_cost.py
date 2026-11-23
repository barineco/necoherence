# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Per-operation cost of the TypeScript state families.

For each operation, s(n) is the cost of k = n operations on a state that holds
n entries, divided by k. Two quantities are measured, each in its own process:
the number of calls of functions in the built package (V8 precise coverage with
the optimizing tiers off), and the bytes sampled by the V8 heap profiler. The
check requires s(10n) <= 2 * s(n) for n = 1000 in both quantities. The call
count must repeat exactly; the sampled bytes must repeat within 1 percent.

The value validation operations (vv_ prefix) run in measure_validation.mts. For
them, n is the number of nodes of the type graph held by the prepared context,
the operation is repeated a fixed number of times, and the call count must be
equal at n and 10n: s(10n) == s(n). The sampled bytes keep the ratio limit.
"""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path

from .implementations import ImplementationError, require_executable

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "packages" / "typescript" / "adapter"
MEASURE = Path(__file__).resolve().parent / "ts_cost" / "measure.mjs"
MEASURE_VALIDATION = Path(__file__).resolve().parent / "ts_cost" / "measure_validation.mts"
NODE_FLAGS = ["--no-opt", "--no-sparkplug", "--no-maglev"]
OPERATIONS = [
    "core_lookup",
    "core_bump",
    "core_apply",
    "core_apply_conflicted",
    "core_apply_unknown",
    "store_observe",
    "store_apply",
    "reconcile",
    "rp_submit_fifo",
    "rp_submit_latest_wins",
    "rp_decide_start",
    "rp_decide_start_blocked",
    "rp_apply_start_observation",
    "rp_apply_completion_observation",
    "rp_decide_cancel",
    "rp_derive_pending",
    "rp_derive_in_flight",
    "rp_derive_concurrent",
    "ne_prepare",
    "ne_send_command",
    "ne_observe_start",
    "ne_cancel_command",
    "ne_observe_pending",
    "ne_observe_delivered",
    "ne_observe_late",
    "ne_annotate_effect",
    "ne_retry",
    "ne_read_network_state",
    "file_effect_read",
    "file_effect_replace",
    "file_effect_track",
    "da_admit_submitted",
    "da_admit_executed",
    "da_elide_admission_provenance",
    "vv_validate_value",
    "vv_accepts_slot",
]
EQUAL_CALL_OPERATIONS = {"vv_validate_value", "vv_accepts_slot"}
BASE_COUNT = 1000
GROWTH = 10
RATIO_LIMIT = 2.0
SAMPLE_SPREAD_LIMIT = 0.01
RUN_TIMEOUT = 600


def measure(node: str, quantity: str, operation: str, count: int) -> float:
    process = subprocess.run(
        [node, *NODE_FLAGS, str(MEASURE_VALIDATION if operation in EQUAL_CALL_OPERATIONS else MEASURE), quantity, operation, str(count)],
        capture_output=True, text=True, timeout=RUN_TIMEOUT, cwd=str(ADAPTER),
    )
    if process.returncode != 0:
        raise ImplementationError(f"{quantity} {operation} {count} failed:\n{process.stderr[-2000:]}")
    return float(json.loads(process.stdout.strip().splitlines()[-1])["perOperation"])


def repeated(node: str, quantity: str, operation: str, count: int, repeat: int) -> float:
    values = [measure(node, quantity, operation, count) for _ in range(repeat)]
    low, high = min(values), max(values)
    if quantity == "calls" and low != high:
        raise SystemExit(f"{operation} n={count}: call counts differ across runs: {values}")
    if quantity == "bytes" and high > 0 and (high - low) / high >= SAMPLE_SPREAD_LIMIT:
        raise SystemExit(f"{operation} n={count}: sampled bytes spread >= {SAMPLE_SPREAD_LIMIT}: {values}")
    return sum(values) / len(values)


def check_prepared(node: str) -> None:
    process = subprocess.run(
        [node, *NODE_FLAGS, str(MEASURE_VALIDATION), "prepared", "vv_prepared_once", str(BASE_COUNT)],
        capture_output=True, text=True, timeout=RUN_TIMEOUT, cwd=str(ADAPTER),
    )
    if process.returncode != 0:
        raise ImplementationError(f"prepared check failed:\n{process.stderr[-2000:]}")
    report = json.loads(process.stdout.strip().splitlines()[-1])
    print(f"vv_prepared_once\tcalls\t{json.dumps(report['observed'], sort_keys=True)}", flush=True)
    if report["failures"]:
        raise SystemExit("vv_prepared_once:\n" + "\n".join(report["failures"]))


def ratio_of(small: float, large: float) -> float:
    if small == 0:
        return 0.0 if large == 0 else float("inf")
    return large / small


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--operations", nargs="*", default=OPERATIONS, choices=OPERATIONS)
    parser.add_argument("--repeat", type=int, default=1)
    arguments = parser.parse_args()
    node = require_executable("node")
    print("operation\tquantity\ts(n)\ts(10n)\tratio")
    for name in arguments.operations:
        for quantity in ("calls", "bytes"):
            small = repeated(node, quantity, name, BASE_COUNT, arguments.repeat)
            large = repeated(node, quantity, name, BASE_COUNT * GROWTH, arguments.repeat)
            ratio = ratio_of(small, large)
            print(f"{name}\t{quantity}\t{small:.3f}\t{large:.3f}\t{ratio:.3f}", flush=True)
            if name in EQUAL_CALL_OPERATIONS and quantity == "calls" and small != large:
                raise SystemExit(f"{name} {quantity}: s(n) = {small} differs from s(10n) = {large}")
            if ratio > RATIO_LIMIT:
                raise SystemExit(f"{name} {quantity}: s(10n)/s(n) = {ratio:.3f} exceeds {RATIO_LIMIT}")
    check_prepared(node)
    print(f"all {len(arguments.operations)} operations satisfy s(10n) <= {RATIO_LIMIT} * s(n) in both quantities")


if __name__ == "__main__":
    main()
