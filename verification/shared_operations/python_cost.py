# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Per-operation cost of the Python state families.

For each operation, s(n) is the cost of k = n operations on a state that holds
n entries, divided by k. The cost is counted twice: as bytecode instructions
(``sys.monitoring`` INSTRUCTION events) and as the peak of allocated bytes
(``tracemalloc``). The check requires s(10n) <= 2 * s(n) for n = 1000 in both
quantities. The peak is used for the ratio only. An operation that reads every
entry costs in proportion to n: it is run once (k = 1) and the check requires
8 <= s(10n) / s(n) <= 12 in both quantities. The prepared value validation
operations also count the calls (``sys.monitoring`` CALL events) and the check
requires s(10n) == s(n) for the calls.
"""

from __future__ import annotations

import argparse
import gc
import importlib
import json
import os
import subprocess
import sys
import tracemalloc
from collections.abc import Callable
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
BASE_COUNT = 1000
GROWTH = 10
RATIO_LIMIT = 2.0
PROPORTIONAL = {"reconcile"}
PROPORTIONAL_LOWER = 8.0
PROPORTIONAL_UPPER = 12.0
PEAK_SPREAD_LIMIT = 0.01
RUN_TIMEOUT = 900
TOOL_ID = 3
LIMIT = 10**9
CALL_TOOL_ID = 4
EQUAL_CALLS = {"vc_validate_value", "vc_validate_value_rejected", "vc_accepts_slot", "vc_validate_slot"}

Step = Callable[[Any, int], Any]


def _modules() -> dict[str, Any]:
    sys.path.insert(0, str(ROOT / "packages" / "python" / "adapter" / "src"))
    from necoherence import (
        core,
        dynamic_admission as da,
        files,
        network_effect as ne,
        request_progression as rp,
        store,
    )

    return {"core": core, "da": da, "files": files, "ne": ne, "reconcile": importlib.import_module("necoherence.reconcile"), "rp": rp, "store": store}


def _core_cases(n: int) -> dict[str, tuple[Any, Step, int]]:
    core = _modules()["core"]
    last = core.ResourceId("res", f"r{n - 1}")
    unknown = core.ResourceId("res", "absent")
    world = core.world_of((core.ResourceId("res", f"r{i}"), core.Revision(i + 1)) for i in range(n))
    applying = [core.Command(None, core.Basis(last, core.Revision(n + i))) for i in range(n)]
    stale = core.Command(None, core.Basis(last, core.Revision(0)))
    missing = core.Command(None, core.Basis(unknown, core.Revision(0)))

    def apply_step(state: Any, i: int) -> Any:
        return core.apply(state, applying[i]).value[1]

    return {
        "core_lookup": (world, lambda state, i: (core.lookup(state, last), state)[1], n),
        "core_bump": (world, lambda state, i: core.bump(state, last), n),
        "core_apply": (world, apply_step, n),
        "core_apply_conflicted": (world, lambda state, i: (core.apply(state, stale), state)[1], n),
        "core_apply_unknown": (world, lambda state, i: (core.apply(state, missing), state)[1], n),
    }


def _store_cases(n: int) -> dict[str, tuple[Any, Step, int]]:
    modules = _modules()
    core, store = modules["core"], modules["store"]
    last = core.ResourceId("res", f"r{n - 1}")
    state = store.store_of((core.ResourceId("res", f"r{i}"), core.Revision(i + 1), i) for i in range(n))
    applying = [core.Command(i, core.Basis(last, core.Revision(n + i))) for i in range(n)]

    def apply_step(current: Any, i: int) -> Any:
        return store.apply(current, applying[i]).value[1]

    return {
        "store_observe": (state, lambda current, i: (store.observe(current, last), current)[1], n),
        "store_apply": (state, apply_step, n),
    }


def _reconcile_cases(n: int) -> dict[str, tuple[Any, Step, int]]:
    modules = _modules()
    core, reconcile = modules["core"], modules["reconcile"]
    bases = tuple(core.Basis(core.ResourceId("res", f"r{i}"), core.Revision(i + 1)) for i in range(n))
    world = core.world_of((core.ResourceId("res", f"r{i}"), core.Revision(i + 1)) for i in range(n))
    return {"reconcile": (world, lambda state, i: (reconcile.reconcile(bases, state, 0), state)[1], 1)}


def _file_effect_cases(n: int) -> dict[str, tuple[Any, Step, int]]:
    modules = _modules()
    core, files = modules["core"], modules["files"]
    path = lambda i: files.normalize_path(True, (f"f{i}",))
    resource = lambda i: core.ResourceId("file", f"/f{i}")
    digest = lambda i: files.ContentDigest(f"d{i}")
    last = n - 1
    external = files.external_file_state_of(
        ((path(i), files.FileRecord(digest(0), (0, 0, 0, 0))) for i in range(n)), (), ()
    )
    world = core.world_of((resource(i), core.Revision(0)) for i in range(n))
    digests = files.digests_of((resource(i), digest(0)) for i in range(n))
    replacing = [
        core.Command(files.ReplaceContents((1, 1, 1, 1), digest(i + 1)), core.Basis(resource(last), core.Revision(i)))
        for i in range(n)
    ]

    def read_step(held: Any, i: int) -> Any:
        outcome = files.read.output(files.ReadReq(path(last), held[0], held[1], external, i))
        assert isinstance(outcome, core.Applied)
        return (outcome.value.world, outcome.value.digests)

    def replace_step(held: Any, i: int) -> Any:
        outcome = files.replace.output(files.ReplaceReq(replacing[i], path(last), held[0], held[1], held[2], i))
        assert isinstance(outcome, core.Applied)
        return (outcome.value.world, outcome.value.digests, outcome.value.state)

    def track_step(held: Any, i: int) -> Any:
        outcome = files.track.output(files.TrackReq(path(n + i), held, i))
        assert isinstance(outcome, core.Applied)
        return outcome.value.world

    return {
        "file_effect_read": ((world, digests), read_step, n),
        "file_effect_replace": ((world, digests, external), replace_step, n),
        "file_effect_track": (world, track_step, n),
    }


def _admission_cases(n: int) -> dict[str, tuple[Any, Step, int]]:
    modules = _modules()
    da, rp = modules["da"], modules["rp"]
    identity = lambda i: rp.RequestIdentity("k", "p", i)
    evidence = rp.EvidenceVersion("e", "d", "a")
    footprint = rp.RequestFootprint((), (), rp.RequestEffectClass.PURE)
    demand = rp.ResourceDemand(1, 1, 1)
    budget = rp.ResourceBudget(
        rp.ConfiguredSafetyLimit("p", LIMIT),
        rp.ConfiguredSafetyLimit("i", LIMIT),
        rp.ConfiguredSafetyLimit("c", LIMIT),
    )

    def state_of(policy: Any, phase: Any, future_uses: tuple[Any, ...]) -> Any:
        entries = [
            rp.RequestEntry(identity(i), footprint, demand, phase, rp.Permitted(identity(i), ()), None, None)
            for i in range(n)
        ]
        built = rp.snapshot_of(policy, budget, identity(0), entries, n)
        assert isinstance(built, rp.RequestProgressionSnapshot)
        return da.admission_state_of(built, budget, da.AdmissionProvenance(future_uses, ()))

    def admission_input(state: Any, i: int, start: Any) -> Any:
        return da.DynamicAdmissionInput(
            state,
            rp.RequestInput(identity(n + i), footprint, demand, rp.Permitted(identity(n + i), ())),
            da.EnvironmentSpecification(1),
            da.CapacityObservation(budget, 0),
            0,
            start,
        )

    def admitted(state: Any, i: int, start: Any) -> Any:
        outcome = da.admit_dynamic_request(admission_input(state, i, start))
        assert isinstance(outcome, modules["core"].Applied)
        return outcome.value.admission_decision.state

    def elided(state: Any, i: int) -> Any:
        outcome = da.elide_admission_provenance(state, identity(i))
        assert isinstance(outcome, modules["core"].Applied)
        return outcome.value[0]

    return {
        "da_admit_submitted": (
            state_of(rp.RequestPolicy.FIFO, rp.RequestPhase.PENDING, ()),
            lambda state, i: admitted(state, i, None),
            n,
        ),
        "da_admit_executed": (
            state_of(rp.RequestPolicy.ALL_EXECUTE, rp.RequestPhase.PENDING, ()),
            lambda state, i: admitted(state, i, rp.ExecuteNow(identity(n + i), evidence, 0)),
            n,
        ),
        "da_elide_admission_provenance": (
            state_of(rp.RequestPolicy.FIFO, rp.RequestPhase.CANCELLED, tuple(identity(i) for i in range(2 * n, 3 * n))),
            elided,
            n,
        ),
    }


def _progression_cases(n: int) -> dict[str, tuple[Any, Step, int]]:
    rp = _modules()["rp"]
    identity = lambda i: rp.RequestIdentity("k", "p", i)
    evidence = rp.EvidenceVersion("e", "d", "a")
    footprint = rp.RequestFootprint((), (), rp.RequestEffectClass.PURE)
    demand = rp.ResourceDemand(1, 1, 1)
    budget = rp.ResourceBudget(
        rp.ConfiguredSafetyLimit("p", LIMIT),
        rp.ConfiguredSafetyLimit("i", LIMIT),
        rp.ConfiguredSafetyLimit("c", LIMIT),
    )

    def entry(i: int, phase: Any) -> Any:
        handle = rp.ExecutionHandle(f"h{i}") if phase is rp.RequestPhase.PUBLISHING else None
        return rp.RequestEntry(identity(i), footprint, demand, phase, rp.Permitted(identity(i), ()), None, handle)

    def snapshot(policy: Any, phase: Any) -> Any:
        built = rp.snapshot_of(policy, budget, identity(n - 1), [entry(i, phase) for i in range(n)], n)
        assert isinstance(built, rp.RequestProgressionSnapshot)
        return built

    def request(i: int) -> Any:
        return rp.RequestInput(identity(n + i), footprint, demand, rp.Permitted(identity(n + i), ()))

    submissions = [request(i) for i in range(n)]
    accepted = [rp.Accepted(identity(i)) for i in range(n)]
    selections = [rp.ExecuteNow(identity(i), evidence, 1) for i in range(n)]
    startings = [rp.Starting(identity(n - 1 - i), rp.StartCommand(identity(n - 1 - i), footprint)) for i in range(n)]
    started = [
        rp.AppliedSignal(rp.Started(identity(n - 1 - i), rp.ExecutionHandle("started"))) for i in range(n)
    ]
    runnings = [rp.Running(identity(n - 1 - i), rp.ExecutionHandle(f"h{n - 1 - i}")) for i in range(n)]
    completed = [
        rp.AppliedSignal(rp.Completed(identity(n - 1 - i), rp.ExecutionHandle(f"h{n - 1 - i}"), "v"))
        for i in range(n)
    ]
    pending = snapshot(rp.RequestPolicy.FIFO, rp.RequestPhase.PENDING)

    return {
        "rp_submit_fifo": (pending, lambda state, i: rp.submit(state, submissions[i]).snapshot, n),
        "rp_submit_latest_wins": (
            snapshot(rp.RequestPolicy.LATEST_WINS, rp.RequestPhase.PENDING),
            lambda state, i: rp.submit(state, submissions[i]).snapshot,
            n,
        ),
        "rp_decide_start": (
            pending, lambda state, i: rp.decide_start(state, accepted[i], selections[i]).snapshot, n
        ),
        "rp_decide_start_blocked": (
            pending,
            lambda state, i: (rp.decide_start(state, accepted[n - 1], selections[n - 1]), state)[1],
            n,
        ),
        "rp_apply_start_observation": (
            snapshot(rp.RequestPolicy.FIFO, rp.RequestPhase.PREPARING),
            lambda state, i: rp.apply_start_observation(state, startings[i], started[i]).snapshot,
            n,
        ),
        "rp_apply_completion_observation": (
            snapshot(rp.RequestPolicy.FIFO, rp.RequestPhase.PUBLISHING),
            lambda state, i: rp.apply_completion_observation(state, runnings[i], completed[i]).snapshot,
            n,
        ),
        "rp_decide_cancel": (
            pending, lambda state, i: rp.decide_cancel(state, identity(n - 1 - i)).snapshot, n
        ),
        "rp_derive_pending": (pending, lambda state, i: (rp.derive_pending(state), state)[1], n),
        "rp_derive_in_flight": (
            snapshot(rp.RequestPolicy.FIFO, rp.RequestPhase.PREPARING),
            lambda state, i: (rp.derive_in_flight(state), state)[1],
            n,
        ),
        "rp_derive_concurrent": (
            snapshot(rp.RequestPolicy.FIFO, rp.RequestPhase.PUBLISHING),
            lambda state, i: (rp.derive_concurrent(state), state)[1],
            n,
        ),
    }


def _network_cases(n: int) -> dict[str, tuple[Any, Step, int]]:
    modules = _modules()
    ne, rp = modules["ne"], modules["rp"]
    capability = ne.CancellationCapability(ne.OpaqueEvidence("cancel"))
    configuration = ne.HostConfiguration(1024, 1024, capability, None)
    instruction = ne.HttpWireInstruction("GET", "http://127.0.0.1/cost", (), b"")

    def attempt(i: int, ordinal: int = 0) -> Any:
        return ne.AttemptIdentity(rp.RequestIdentity("net", "p", i), ordinal)

    def input_of(i: int, ordinal: int = 0) -> Any:
        return ne.AttemptInput(attempt(i, ordinal), instruction, None, configuration)

    handle = lambda i: rp.ExecutionHandle(f"h{i}")
    effect = ne.Unknown(ne.UnknownEffectReason.CANCELLATION)

    def delivered(i: int, delivery: int) -> Any:
        return ne.DeliveredObservation(
            delivery, ne.CancellationObservation(attempt(i), handle(i), None, effect)
        )

    def record(i: int, disposition: Any, first: Any = None, late: tuple[Any, ...] = ()) -> Any:
        return ne.AttemptRecord(input_of(i), ne.Root(), disposition, first, late)

    def state_of(make: Callable[[int], Any]) -> Any:
        built = ne.network_state_of([make(i) for i in range(n)])
        assert isinstance(built, ne.NetworkState)
        return built

    terminal = ne.NetworkTerminal(ne.Cancelled(), effect)
    prepared_state = state_of(lambda i: record(i, ne.PreparedDisposition()))
    issued_state = state_of(lambda i: record(i, ne.CommandIssued()))
    started_state = state_of(lambda i: record(i, ne.StartedDisposition(handle(i))))
    settled_state = state_of(lambda i: record(i, ne.Settled(handle(i), terminal), delivered(i, 0)))
    prepared = [ne.PreparedAttempt(input_of(i), ne.Root()) for i in range(n)]
    fresh = [input_of(n + i) for i in range(n)]
    witness = lambda i: ne.EffectWitness(attempt(i), ne.EffectWitnessSource.ADAPTER, ne.OpaqueEvidence("peer"))
    retries = [
        ne.RetryRequest(
            ne.RetryAllowed(
                ne.RetryAuthorization(
                    attempt(i).logical, attempt(i), attempt(i, 1), ne.OpaqueEvidence("retry")
                )
            ),
            instruction,
            None,
            configuration,
        )
        for i in range(n)
    ]

    def last_first(i: int) -> int:
        return n - 1 - i

    return {
        "ne_prepare": (prepared_state, lambda state, i: ne.prepare(state, fresh[i]).state, n),
        "ne_send_command": (
            prepared_state, lambda state, i: ne.send_command(state, prepared[last_first(i)]).state, n
        ),
        "ne_observe_start": (
            issued_state,
            lambda state, i: ne.observe_start(
                state, prepared[last_first(i)], ne.Started(attempt(last_first(i)), handle(last_first(i)))
            ).state,
            n,
        ),
        "ne_cancel_command": (
            started_state,
            lambda state, i: (
                ne.cancel_command(state, ne.StartedAttempt(prepared[last_first(i)], handle(last_first(i)))),
                state,
            )[1],
            n,
        ),
        "ne_observe_pending": (
            started_state,
            lambda state, i: (
                ne.observe(state, ne.PendingObservation(attempt(last_first(i)), handle(last_first(i)))),
                state,
            )[1],
            n,
        ),
        "ne_observe_delivered": (
            started_state, lambda state, i: ne.observe(state, delivered(last_first(i), 0)).state, n
        ),
        "ne_observe_late": (
            settled_state, lambda state, i: ne.observe(state, delivered(last_first(i), 1)).state, n
        ),
        "ne_annotate_effect": (
            settled_state,
            lambda state, i: ne.annotate_effect(
                state, ne.EffectObservation(attempt(last_first(i)), ne.NoEffect(witness(last_first(i))))
            ).state,
            n,
        ),
        "ne_retry": (settled_state, lambda state, i: ne.retry(state, retries[last_first(i)]).state, n),
        "ne_read_network_state": (settled_state, lambda state, i: ne.read_network_state(state).state, n),
    }


def _value_cases(n: int) -> dict[str, tuple[Any, Step, int]]:
    sys.path.insert(0, str(ROOT / "packages" / "python" / "adapter" / "src"))
    from necoherence import semantic_composition as sc
    from necoherence.signature_values import ValueContext, variant
    from necoherence.type_signatures import _graph

    reference = {"identity": "cost", "revision": "1", "content_digest": "0" * 64}
    profile = {
        "reference": reference, "source_refs": [], "integer_domains": [], "default_integer_domain": None,
        "numbers": {"decimals": False}, "grapheme_rules": None, "format_bindings": [], "bytes_policy": None,
        "wrappers": [], "tag": None,
    }
    fields = [{"wire_name": "a", "slot": {"type_id": "Bool", "required": True, "nullable": False}}]
    nodes = [
        {"id": "Bool", "shape": variant("Boolean", {"const_value": None})},
        {"id": "Pair", "shape": variant("Product", {"fields": fields, "extras": variant("Reject")})},
        *({"id": f"Filler{i}", "shape": variant("Boolean", {"const_value": None})} for i in range(n)),
    ]
    context = ValueContext(_graph({"profile": profile, "nodes": nodes, "definitions": []}))
    slot = sc.SlotContract(sc.TypeRef(context.reference("Pair")["source"], "Pair", ()), True, False)
    accepted, rejected = {"a": True}, {"a": 1}
    return {
        "vc_validate_value": (context, lambda state, i: (state.validate_value("Pair", accepted), state)[1], n),
        "vc_validate_value_rejected": (context, lambda state, i: (state.validate_value("Pair", rejected), state)[1], n),
        "vc_accepts_slot": (context, lambda state, i: (sc.accepts_slot(state, slot, sc.PresentValue(accepted)), state)[1], n),
        "vc_validate_slot": (context, lambda state, i: (sc.validate_slot(state, slot, sc.PresentValue(accepted)), state)[1], n),
    }


def cases(n: int) -> dict[str, tuple[Any, Step, int]]:
    return {
        **_value_cases(n),
        **_core_cases(n),
        **_store_cases(n),
        **_progression_cases(n),
        **_network_cases(n),
        **_reconcile_cases(n),
        **_file_effect_cases(n),
        **_admission_cases(n),
    }


OPERATIONS = [
    "vc_validate_value",
    "vc_validate_value_rejected",
    "vc_accepts_slot",
    "vc_validate_slot",
    "core_lookup",
    "core_bump",
    "core_apply",
    "core_apply_conflicted",
    "core_apply_unknown",
    "store_observe",
    "store_apply",
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
    "reconcile",
    "file_effect_read",
    "file_effect_replace",
    "file_effect_track",
    "da_admit_submitted",
    "da_admit_executed",
    "da_elide_admission_provenance",
]


def count_instructions(initial: Any, step: Step, k: int, budget: int | None) -> int | None:
    monitoring = sys.monitoring
    counter = [0]

    def on_instruction(code: Any, offset: int) -> None:
        counter[0] += 1

    monitoring.use_tool_id(TOOL_ID, "python_cost")
    monitoring.register_callback(TOOL_ID, monitoring.events.INSTRUCTION, on_instruction)
    state = initial
    total = 0
    gc.disable()
    try:
        for i in range(k):
            counter[0] = 0
            monitoring.set_events(TOOL_ID, monitoring.events.INSTRUCTION)
            state = step(state, i)
            monitoring.set_events(TOOL_ID, 0)
            total += counter[0]
            if budget is not None and total > budget:
                return None
    finally:
        monitoring.set_events(TOOL_ID, 0)
        monitoring.register_callback(TOOL_ID, monitoring.events.INSTRUCTION, None)
        monitoring.free_tool_id(TOOL_ID)
        gc.enable()
    return total


def count_calls(initial: Any, step: Step, k: int) -> int:
    monitoring = sys.monitoring
    counter = [0]

    def on_call(code: Any, offset: int, callable_object: Any, argument: Any) -> None:
        counter[0] += 1

    monitoring.use_tool_id(CALL_TOOL_ID, "python_cost_calls")
    monitoring.register_callback(CALL_TOOL_ID, monitoring.events.CALL, on_call)
    state = initial
    total = 0
    gc.disable()
    try:
        for i in range(k):
            counter[0] = 0
            monitoring.set_events(CALL_TOOL_ID, monitoring.events.CALL)
            state = step(state, i)
            monitoring.set_events(CALL_TOOL_ID, 0)
            total += counter[0]
    finally:
        monitoring.set_events(CALL_TOOL_ID, 0)
        monitoring.register_callback(CALL_TOOL_ID, monitoring.events.CALL, None)
        monitoring.free_tool_id(CALL_TOOL_ID)
        gc.enable()
    return total


def count_peak_bytes(initial: Any, step: Step, k: int, budget: int | None) -> int | None:
    state = initial
    total = 0
    gc.disable()
    tracemalloc.start()
    try:
        for i in range(k):
            tracemalloc.reset_peak()
            before, _ = tracemalloc.get_traced_memory()
            state = step(state, i)
            _, peak = tracemalloc.get_traced_memory()
            total += peak - before
            if budget is not None and total > budget:
                return None
    finally:
        tracemalloc.stop()
        gc.enable()
    return total


def measure(operation: str, n: int, budgets: tuple[int, int] | None) -> dict[str, int | None]:
    initial, step, k = cases(n)[operation]
    instructions = count_instructions(initial, step, k, None if budgets is None else budgets[0])
    peak = count_peak_bytes(initial, step, k, None if budgets is None else budgets[1])
    result: dict[str, int | None] = {"k": k, "instructions": instructions, "peak": peak}
    if operation in EQUAL_CALLS:
        result["calls"] = count_calls(initial, step, k)
    return result


def measure_in_process(operation: str, n: int, budgets: tuple[int, int] | None = None) -> dict[str, int | None]:
    limits = [] if budgets is None else ["--budgets", str(budgets[0]), str(budgets[1])]
    process = subprocess.run(
        [sys.executable, "-m", "verification.shared_operations.python_cost", "--measure", operation, str(n), *limits],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=RUN_TIMEOUT,
        env={**os.environ, "PYTHONHASHSEED": "0"},
    )
    if process.returncode != 0:
        raise SystemExit(f"{operation} n={n} failed:\n{process.stderr[-2000:]}")
    result: dict[str, int | None] = json.loads(process.stdout.strip().splitlines()[-1])
    return result


def check_proportional(name: str, repeat: int) -> list[str]:
    failures: list[str] = []
    small_samples = [measure_in_process(name, BASE_COUNT) for _ in range(repeat)]
    large_samples = [measure_in_process(name, BASE_COUNT * GROWTH) for _ in range(repeat)]
    for quantity in ("instructions", "peak"):
        small = [sample[quantity] / sample["k"] for sample in small_samples]
        large = [sample[quantity] / sample["k"] for sample in large_samples]
        ratio = large[0] / small[0] if small[0] else 0.0
        print(f"{name}\t{quantity}\t{small[0]:.3f}\t{large[0]:.3f}\t{ratio:.3f}", flush=True)
        if not PROPORTIONAL_LOWER <= ratio <= PROPORTIONAL_UPPER:
            failures.append(
                f"{name} {quantity}: s({BASE_COUNT * GROWTH}) / s({BASE_COUNT}) = {ratio:.3f} "
                f"is outside [{PROPORTIONAL_LOWER}, {PROPORTIONAL_UPPER}]"
            )
        if quantity == "instructions":
            if any(value != small[0] for value in small) or any(value != large[0] for value in large):
                failures.append(f"{name} instructions differ across {repeat} runs: {small} {large}")
        else:
            for values in (small, large):
                if (max(values) - min(values)) > PEAK_SPREAD_LIMIT * max(values):
                    failures.append(f"{name} peak spreads over {PEAK_SPREAD_LIMIT:.0%} across runs: {values}")
    return failures


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--operations", nargs="*", default=OPERATIONS, choices=OPERATIONS)
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--measure", nargs=2, metavar=("OPERATION", "COUNT"))
    parser.add_argument("--budgets", nargs=2, type=int, metavar=("INSTRUCTIONS", "PEAK"))
    arguments = parser.parse_args()
    if arguments.measure:
        budgets = None if arguments.budgets is None else (arguments.budgets[0], arguments.budgets[1])
        print(json.dumps(measure(arguments.measure[0], int(arguments.measure[1]), budgets)))
        return
    failures: list[str] = []
    print("operation\tquantity\ts(n)\ts(10n)\tratio")
    for name in arguments.operations:
        if name in PROPORTIONAL:
            failures.extend(check_proportional(name, arguments.repeat))
            continue
        small_samples = [measure_in_process(name, BASE_COUNT) for _ in range(arguments.repeat)]
        first = small_samples[0]
        small_k = first["k"]
        assert small_k is not None
        large_k = BASE_COUNT * GROWTH
        budgets = (
            int(RATIO_LIMIT * (first["instructions"] or 0) / small_k * large_k) + 1,
            int(RATIO_LIMIT * (first["peak"] or 0) / small_k * large_k) + 1,
        )
        large_samples = [measure_in_process(name, BASE_COUNT * GROWTH, budgets) for _ in range(arguments.repeat)]
        if name in EQUAL_CALLS:
            small_calls = [sample["calls"] / small_k for sample in small_samples if sample["calls"] is not None]
            large_calls = [sample["calls"] / large_k for sample in large_samples if sample["calls"] is not None]
            print(f"{name}\tcalls\t{small_calls[0]:.3f}\t{large_calls[0]:.3f}\t{large_calls[0] / small_calls[0]:.3f}", flush=True)
            if any(value != small_calls[0] for value in small_calls + large_calls):
                failures.append(f"{name} calls: s({large_k}) = {large_calls} differs from s({BASE_COUNT}) = {small_calls}")
        for quantity in ("instructions", "peak"):
            small = [sample[quantity] for sample in small_samples]
            large = [sample[quantity] for sample in large_samples]
            small_s = [value / small_k for value in small if value is not None]
            if large[0] is None:
                print(f"{name}\t{quantity}\t{small_s[0]:.3f}\t>{RATIO_LIMIT * small_s[0]:.3f}\t>{RATIO_LIMIT:.3f}", flush=True)
                failures.append(f"{name} {quantity}: s({BASE_COUNT * GROWTH}) exceeds {RATIO_LIMIT} * s({BASE_COUNT})")
                continue
            large_s = [value / (BASE_COUNT * GROWTH) for value in large if value is not None]
            ratio = large_s[0] / small_s[0] if small_s[0] else 0.0
            print(f"{name}\t{quantity}\t{small_s[0]:.3f}\t{large_s[0]:.3f}\t{ratio:.3f}", flush=True)
            if quantity == "instructions":
                if any(value != small_s[0] for value in small_s) or any(value != large_s[0] for value in large_s):
                    failures.append(f"{name} instructions differ across {arguments.repeat} runs: {small_s} {large_s}")
            else:
                for values in (small_s, large_s):
                    if (max(values) - min(values)) > PEAK_SPREAD_LIMIT * max(values):
                        failures.append(f"{name} peak spreads over {PEAK_SPREAD_LIMIT:.0%} across runs: {values}")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
