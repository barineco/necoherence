# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Per-operation cost of the Rust state families, counted as wasmtime fuel.

For each operation, s(n) is the fuel of k = n operations on a state that holds
n entries, divided by k. The check requires s(10n) <= 2 * s(n) for n = 1000.
An operation that reads every entry costs in proportion to n: it is run once
(k = 1) and the check requires 8 <= s(10n) / s(n) <= 12. The prepared value
validation and expansion run k = 100 times on a graph of n nodes and of 10n nodes; the check
requires s(10n) == s(n). The default materialization runs the same way and the check
requires s(10n) <= 2 * s(n).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

from .implementations import ImplementationError, build, require_executable

GUEST = Path(__file__).resolve().parent / "rust_cost"
WASMTIME_VERSION = "wasmtime 50.0.1"
OPERATIONS = [
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
    "reconcile",
    "file_effect_replace",
    "file_effect_read",
    "file_effect_track",
    "validate_prepared",
    "expand_prepared",
    "defaults_prepared",
    "materialize_prepared",
    "meaning_prepared",
    "meaning_obligated_prepared",
    "validate_rejected_prepared",
    "validate_slot_prepared",
    "validate_product_prepared",
    "validate_product_rejected_prepared",
    "select_branch_prepared",
]
PROPORTIONAL = {"reconcile"}
EQUAL = {"validate_prepared", "expand_prepared", "materialize_prepared", "meaning_prepared", "meaning_obligated_prepared", "defaults_prepared",
         "validate_rejected_prepared", "validate_slot_prepared",
         "validate_product_prepared", "validate_product_rejected_prepared",
         "select_branch_prepared"}
EQUAL_COUNT = 100
PROPORTIONAL_LOWER = 8.0
PROPORTIONAL_UPPER = 12.0
BASE_COUNT = 1000
GROWTH = 10
RATIO_LIMIT = 2.0
RUN_TIMEOUT = 600


def build_guest() -> Path:
    output = build(
        [require_executable("cargo"), "build", "--locked", "--release", "--target", "wasm32-unknown-unknown",
         "--message-format=json"],
        GUEST,
    )
    for message in map(json.loads, output.splitlines()):
        if message.get("reason") == "compiler-artifact" and message.get("target", {}).get("name") == "shared_operations_cost":
            wasm = [name for name in message.get("filenames", []) if name.endswith(".wasm")]
            if wasm:
                return Path(wasm[-1])
    raise ImplementationError("cargo build produced no shared_operations_cost.wasm")


def check_wasmtime(wasmtime: str) -> None:
    version = subprocess.run([wasmtime, "--version"], capture_output=True, text=True, check=True).stdout
    if not version.startswith(WASMTIME_VERSION):
        raise ImplementationError(f"expected {WASMTIME_VERSION}, found {version.strip()}")


def completes(wasmtime: str, wasm: Path, fuel: int, op: int, count: int, k: int) -> bool:
    process = subprocess.run(
        [wasmtime, "run", "-W", f"fuel={fuel}", "--invoke", "run", str(wasm), str(op), str(count), str(k)],
        capture_output=True, text=True, timeout=RUN_TIMEOUT,
    )
    if process.returncode == 0:
        return True
    if "all fuel consumed" in process.stderr:
        return False
    raise ImplementationError(f"run({op}, {count}, {k}) failed:\n{process.stderr[-2000:]}")


def least_fuel(wasmtime: str, wasm: Path, op: int, count: int, k: int, lower: int, tolerance: int) -> int:
    failing = lower
    passing = max(2 * lower, 1 << 20)
    while not completes(wasmtime, wasm, passing, op, count, k):
        failing = passing
        passing *= 2
    while passing - failing > tolerance:
        middle = (failing + passing) // 2
        if completes(wasmtime, wasm, middle, op, count, k):
            passing = middle
        else:
            failing = middle
    return passing


def preparation_fuel(wasmtime: str, wasm: Path, op: int, count: int) -> int:
    return least_fuel(wasmtime, wasm, op, count, 0, 0, 1)


def amortized_fuel(wasmtime: str, wasm: Path, op: int, count: int, k: int | None = None) -> float:
    k = count if k is None else k
    preparation = preparation_fuel(wasmtime, wasm, op, count)
    total = least_fuel(wasmtime, wasm, op, count, k, preparation, max(1, k // 1000))
    return (total - preparation) / k


def bounded_fuel(wasmtime: str, wasm: Path, op: int, count: int, limit: float) -> float | None:
    k = count
    preparation = preparation_fuel(wasmtime, wasm, op, count)
    budget = preparation + int(limit * k)
    if not completes(wasmtime, wasm, budget, op, count, k):
        return None
    total = least_fuel(wasmtime, wasm, op, count, k, preparation, max(1, k // 1000))
    return (total - preparation) / k


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--operations", nargs="*", default=OPERATIONS, choices=OPERATIONS)
    parser.add_argument("--repeat", type=int, default=1)
    arguments = parser.parse_args()
    wasmtime = require_executable("wasmtime")
    check_wasmtime(wasmtime)
    wasm = build_guest()
    failures: list[str] = []
    print("operation\ts(n)\ts(10n)\tratio")
    for name in arguments.operations:
        op = OPERATIONS.index(name)
        if name in PROPORTIONAL:
            samples = [
                (
                    amortized_fuel(wasmtime, wasm, op, BASE_COUNT, 1),
                    amortized_fuel(wasmtime, wasm, op, BASE_COUNT * GROWTH, 1),
                )
                for _ in range(arguments.repeat)
            ]
            small, large = samples[0]
            print(f"{name}\t{small:.3f}\t{large:.3f}\t{large / small:.3f}", flush=True)
            if not PROPORTIONAL_LOWER <= large / small <= PROPORTIONAL_UPPER:
                failures.append(
                    f"{name}: s({BASE_COUNT * GROWTH}) / s({BASE_COUNT}) = {large / small:.3f} "
                    f"is outside [{PROPORTIONAL_LOWER}, {PROPORTIONAL_UPPER}]"
                )
            if any(sample != samples[0] for sample in samples):
                failures.append(f"{name}: fuel differs across {arguments.repeat} runs: {samples}")
            continue
        if name in EQUAL:
            samples = [
                (
                    amortized_fuel(wasmtime, wasm, op, BASE_COUNT, EQUAL_COUNT),
                    amortized_fuel(wasmtime, wasm, op, BASE_COUNT * GROWTH, EQUAL_COUNT),
                )
                for _ in range(arguments.repeat)
            ]
            small, large = samples[0]
            print(f"{name}\t{small:.3f}\t{large:.3f}\t{large / small:.3f}", flush=True)
            if small != large:
                failures.append(f"{name}: s({BASE_COUNT * GROWTH}) = {large:.3f} differs from s({BASE_COUNT}) = {small:.3f}")
            if any(sample != samples[0] for sample in samples):
                failures.append(f"{name}: fuel differs across {arguments.repeat} runs: {samples}")
            continue
        samples = []
        for _ in range(arguments.repeat):
            small = amortized_fuel(wasmtime, wasm, op, BASE_COUNT)
            large = bounded_fuel(wasmtime, wasm, op, BASE_COUNT * GROWTH, RATIO_LIMIT * small)
            samples.append((small, large))
        small, large = samples[0]
        if large is None:
            print(f"{name}\t{small:.3f}\t>{RATIO_LIMIT * small:.3f}\t>{RATIO_LIMIT:.3f}", flush=True)
            failures.append(f"{name}: s({BASE_COUNT * GROWTH}) exceeds {RATIO_LIMIT} * s({BASE_COUNT}) = {RATIO_LIMIT * small:.3f}")
            continue
        print(f"{name}\t{small:.3f}\t{large:.3f}\t{large / small:.3f}", flush=True)
        if any(sample != samples[0] for sample in samples):
            failures.append(f"{name}: fuel differs across {arguments.repeat} runs: {samples}")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
