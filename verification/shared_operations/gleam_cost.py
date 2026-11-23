# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Per-operation cost of the Gleam state families, counted as function calls.

For each operation, the cost is the number of calls of the functions of the
adapter modules (the modules under necoherence in the build output) made by one
operation, read from the Erlang trace call_count of every function of those
modules before and after k operations applied in turn to a state of size n,
divided by k. For the value operations (vc_*), the state is a prepared graph
of n filler types besides the checked type. For the typed mapping operations
(tm_*), which read their whole input, the cost is the calls of one call per
1/1000 input element. The count does not depend on the process, so the cost of
the repeated measurements, each in a separate process, must be identical. For
n = 1000 and 10n, the cost of the value operations must be equal, the cost of
the operation reconcile, which reads all of its n bases in one call, must have
a ratio in [PROPORTIONAL_LOWER, PROPORTIONAL_UPPER], and the cost of every
other operation must have a ratio of at most RATIO_LIMIT.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from fractions import Fraction
from pathlib import Path

from .implementations import ImplementationError, build, require_executable

HARNESS = Path(__file__).resolve().parent / "gleam_cost"
OPERATIONS = [
    "vc_validate_value",
    "vc_validate_value_rejected",
    "vc_select_branch",
    "vc_select_branch_rejected",
    "vc_named_wrapper",
    "vc_accepts_slot",
    "vc_validate_slot",
    "core_lookup",
    "core_bump",
    "core_apply",
    "core_apply_conflicted",
    "core_apply_unknown",
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
    "da_admit_submitted",
    "da_admit_executed",
    "da_elide_admission_provenance",
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
    "store_observe",
    "store_apply",
    "file_effect_read",
    "file_effect_replace",
    "file_effect_track",
    "reconcile",
    "tm_validate",
    "tm_derive_enabled",
    "tm_binding_bound",
]
PROPORTIONAL = {"reconcile"}
EQUAL = {
    "vc_validate_value",
    "vc_validate_value_rejected",
    "vc_select_branch",
    "vc_select_branch_rejected",
    "vc_named_wrapper",
    "vc_accepts_slot",
    "vc_validate_slot",
}
PROPORTIONAL_LOWER = 8.0
PROPORTIONAL_UPPER = 12.0
BASE_COUNT = 1000
GROWTH = 10
RATIO_LIMIT = 2.0
RUN_TIMEOUT = 600


def build_harness() -> list[str]:
    build([require_executable("gleam"), "build", "--warnings-as-errors"], HARNESS)
    code_paths = sorted(str(path) for path in (HARNESS / "build" / "dev" / "erlang").glob("*/ebin") if path.is_dir())
    if not code_paths:
        raise ImplementationError("Gleam Erlang build produced no ebin directories")
    return code_paths


def adapter_modules(code_paths: list[str]) -> list[str]:
    modules = sorted(
        path.stem
        for directory in code_paths
        if Path(directory).parent.name == "necoherence"
        for path in Path(directory).glob("necoherence@*.beam")
    )
    if not modules:
        raise ImplementationError("Gleam Erlang build produced no necoherence modules")
    return modules


def measured_calls(code_paths: list[str], modules: list[str], operation: str, count: int) -> Fraction:
    command = [require_executable("erl"), "-noshell"]
    for path in code_paths:
        command.extend(["-pa", path])
    command.extend(["-eval", "gleam_cost:main(), halt().", "-extra", operation, str(count), *modules])
    process = subprocess.run(command, capture_output=True, text=True, timeout=RUN_TIMEOUT)
    if process.returncode != 0 or not process.stdout.strip():
        raise ImplementationError(f"{operation} {count} failed:\n{process.stderr[-2000:]}")
    result = json.loads(process.stdout.strip().splitlines()[-1])
    if result["calls"] < 0:
        raise ImplementationError(f"{operation} is not a known operation")
    return Fraction(result["calls"], result["steps"])


def statistic(
    code_paths: list[str], modules: list[str], operation: str, count: int, repeat: int
) -> tuple[Fraction, bool]:
    samples = [measured_calls(code_paths, modules, operation, count) for _ in range(repeat)]
    return samples[0], len(set(samples)) == 1


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--operations", nargs="*", default=OPERATIONS, choices=OPERATIONS)
    parser.add_argument("--repeat", type=int, default=3)
    arguments = parser.parse_args()
    code_paths = build_harness()
    modules = adapter_modules(code_paths)
    failures: list[str] = []
    print(f"adapter modules: {len(modules)}")
    print("operation\tc(n)\tc(10n)\tratio\tidentical")
    for name in arguments.operations:
        small, small_identical = statistic(code_paths, modules, name, BASE_COUNT, arguments.repeat)
        large, large_identical = statistic(code_paths, modules, name, BASE_COUNT * GROWTH, arguments.repeat)
        ratio = large / small
        print(f"{name}\t{small}\t{large}\t{float(ratio):.6f}\t{small_identical and large_identical}", flush=True)
        if not small_identical or not large_identical:
            failures.append(f"{name}: the call count differs across {arguments.repeat} processes")
        if name in PROPORTIONAL:
            if not PROPORTIONAL_LOWER <= ratio <= PROPORTIONAL_UPPER:
                failures.append(
                    f"{name}: c({BASE_COUNT * GROWTH}) / c({BASE_COUNT}) = {float(ratio):.6f} "
                    f"is outside [{PROPORTIONAL_LOWER}, {PROPORTIONAL_UPPER}]"
                )
        elif name in EQUAL:
            if large != small:
                failures.append(f"{name}: c({BASE_COUNT * GROWTH}) = {large} differs from c({BASE_COUNT}) = {small}")
        elif ratio > RATIO_LIMIT:
            failures.append(
                f"{name}: c({BASE_COUNT * GROWTH}) / c({BASE_COUNT}) = {float(ratio):.6f} exceeds {RATIO_LIMIT:.6f}"
            )
    if failures:
        print("\n".join(failures), file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
