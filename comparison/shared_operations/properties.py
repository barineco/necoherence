# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Runtime-generated invariant inputs and implementation-independent checks.

Every request and permutation is constructed on each invocation. The public
functions accept an ``Implementation`` from ``implementations``.
"""
from __future__ import annotations

import itertools
import json
import math
import sys
import time
from typing import Any, Callable, Iterable, Sequence

from . import generator

Req = dict[str, Any]


def _fail(property_name: str, generated_input: Any, detail: str, actual: Any = None) -> None:
    print(json.dumps({"kind": "invariant_failure", "property": property_name,
                      "generated_input": generated_input, "detail": detail,
                      "actual": actual}, ensure_ascii=False, indent=2), file=sys.stderr)
    raise AssertionError(f"{property_name}: {detail}")


def require(property_name: str, condition: bool, generated_input: Any, detail: str, actual: Any = None) -> None:
    if not condition:
        _fail(property_name, generated_input, detail, actual)


def permutations_upto4(values: Sequence[Any]) -> list[tuple[Any, ...]]:
    """Return every order and assert the bounded factorial cardinality."""
    require("permutation_bound", len(values) <= 4, list(values), "more than four elements")
    result = list(itertools.permutations(values))
    require("permutation_count", len(result) == math.factorial(len(values)), list(values),
            f"expected {math.factorial(len(values))} orders, got {len(result)}")
    return result


def _clone(value: Any) -> Any:
    return json.loads(json.dumps(value, ensure_ascii=False))


def _seeds() -> list[Req]:
    return generator.build_seed_requests()


def _requests(feature: str, operation: str) -> list[Req]:
    found = [r for r in _seeds() if r["feature"] == feature and r["operation"] == operation]
    require("generator_seed", bool(found), {"feature": feature, "operation": operation}, "no operation seed")
    return found


def _request(feature: str, operation: str, predicate: Callable[[Req], bool] | None = None) -> Req:
    values = _requests(feature, operation)
    if predicate:
        values = [value for value in values if predicate(value)]
    require("generator_seed", bool(values), {"feature": feature, "operation": operation}, "no matching seed")
    return _clone(values[0])


def _run(impl: Any, property_name: str, requests: list[Req]) -> list[Any]:
    """Evaluate independent invariant requests in ordered bounded queries.

    Callers that model a state-threaded program invoke this once per dependent
    request, so no dependency is separated from its preceding observation.
    """
    values: list[Any] = []
    chunks = generator.contiguous_request_chunks(requests)
    for chunk_number, (start, chunk) in enumerate(chunks, start=1):
        end = start + len(chunk)
        print(
            f"{impl.name}: invariant {property_name} chunk {chunk_number}/{len(chunks)} "
            f"requests [{start}, {end})",
            file=sys.stderr,
            flush=True,
        )
        query = {"kind": "evaluate", "requests": chunk}
        started = time.monotonic()
        reply = impl.run(json.dumps(query, ensure_ascii=False))
        print(
            f"{impl.name}: invariant {property_name} chunk {chunk_number}/{len(chunks)} "
            f"completed in {time.monotonic() - started:.2f}s",
            file=sys.stderr,
            flush=True,
        )
        results = reply.get("results") if isinstance(reply, dict) else None
        require(property_name, isinstance(results, list) and len(results) == len(chunk), query,
                "adapter did not return one result per generated request", reply)
        values.extend(entry.get("result") if isinstance(entry, dict) else None for entry in results)
    require(property_name, len(values) == len(requests), requests,
            "bounded invariant queries did not preserve result cardinality", values)
    return values


def _canon(value: Any) -> Any:
    return generator.json_canon(value)


def _world(value: Any) -> list[dict[str, Any]] | None:
    if isinstance(value, dict):
        candidate = value.get("world")
        if isinstance(candidate, list):
            return sorted(candidate, key=lambda x: (x["resource"]["kind"], x["resource"]["name"]))
    return None


def generated_sequences() -> list[list[Req]]:
    """Finite state-threaded Core operation programs, including lengths zero–six.

    Each following apply request receives the prior applied world's output as
    its input world.  Reject/conflict cases deliberately retain their prior
    world, which is also the closed-state transition for those outcomes.
    """
    resource = generator.RESOURCE_IDS[1]
    initial = generator.world([(resource, 0)])
    sequence: list[Req] = []
    for length in range(7):
        current = _clone(initial)
        program: list[Req] = []
        for step in range(length):
            revision = 0 if step == 0 else step  # generated conflict after the first bump in model execution
            program.append(generator.req("core", "apply", {
                "world": _clone(current),
                "command": generator.command(f"sequence-{length}-{step}", generator.basis(resource, revision)),
            }))
            # The expected state fed to the next request is bumped only when the
            # basis is current; stale steps preserve state.
            if revision == step:
                current = generator.world([(resource, step + 1)])
        sequence.append(program)
    require("sequence_lengths", [len(p) for p in sequence] == list(range(7)), sequence,
            "operation lengths are not exactly 0..6")
    return sequence


def check_sequence_threading(impl: Any) -> None:
    observed: set[str] = set()
    for program in generated_sequences():
        previous_world: list[dict[str, Any]] | None = None
        for index, request in enumerate(program):
            if previous_world is not None:
                require("sequence_state_threading", request["input"]["world"] == previous_world,
                        {"program": program, "step": index}, "previous output state was not next input")
            value = _run(impl, "sequence_state_threading", [request])[0]
            tag = value.get("tag") if isinstance(value, dict) else None
            if tag:
                observed.add(tag)
            next_world = _world(value)
            if next_world is not None:
                previous_world = next_world
    # Explicit branches close the success/reject/conflict classifications.
    branches = [_clone(r) for r in _requests("core", "apply")
                if r["input"]["command"]["intent"] in {"intent0", "intent1", "intent2"}]
    require("outcome_classification", len(branches) == 3, branches,
            "generated branch inputs do not cover applied/rejected/conflicted")
    branch_values = _run(impl, "outcome_classification", branches)
    observed.update(v.get("tag") for v in branch_values if isinstance(v, dict))
    require("outcome_classification", {"applied", "rejected", "conflicted"}.issubset(observed), branches,
            "success/reject/conflict were not all observed", sorted(observed))


def check_core_permutations(impl: Any) -> None:
    resources = generator.RESOURCE_IDS[:4]
    checked: Any = None
    for size in range(1, 5):
        entries = [(resources[index], index) for index in range(size)]
        orders = permutations_upto4(entries)
        # Apply an independent command to r0 exactly once for every insertion order.
        requests = [generator.req("core", "apply", {"world": generator.world(list(order)),
                    "command": generator.command("independent", generator.basis(resources[0], 0))}) for order in orders]
        values = _run(impl, "core_permutation", requests)
        worlds = [_world(v) for v in values]
        require("core_permutation", all(w is not None for w in worlds), requests, "independent apply did not apply", values)
        normalized = [_canon(w) for w in worlds]
        require("core_final_world", all(w == normalized[0] for w in normalized), requests,
                "final world depends on insertion order", values)
        for order, result_world in zip(orders, worlds):
            changed = {tuple(e["resource"].items()): e["revision"] for e in result_world or []}
            require("core_locality", all(changed[tuple(resource.items())] == str(revision)
                    for resource, revision in order if resource != resources[0]),
                    {"order": order, "result": result_world}, "independent resource changed")
        checked = normalized[0]
    require("core_permutation_coverage", checked is not None, resources, "no permutation was checked")


def check_store_permutations(impl: Any) -> None:
    resources = generator.RESOURCE_IDS[:4]
    for size in range(0, 5):
        entries = [{"resource": resources[i], "revision": str(i), "payload": f"p{i}"} for i in range(size)]
        orders = permutations_upto4(entries)
        world_requests = [generator.req("store", "worldOf", list(order)) for order in orders]
        store_requests = [generator.req("store", "storeEntries", {"store": list(order)}) for order in orders]
        worlds = _run(impl, "store_permutation", world_requests)
        stores = _run(impl, "store_projection", store_requests)
        normalized_worlds = [_canon(sorted(v, key=lambda x: (x["resource"]["kind"], x["resource"]["name"]))) for v in worlds]
        require("store_final_world", all(v == normalized_worlds[0] for v in normalized_worlds), orders,
                "worldOf depends on insertion order", worlds)
        for store, world in zip(stores, worlds):
            projection = [{"resource": e["resource"], "revision": e["revision"]} for e in store]
            require("store_projection_commutes", _canon(sorted(projection, key=str)) == _canon(sorted(world, key=str)),
                    {"store": store, "world": world}, "worldOf is not the store revision projection")


def check_record_reconcile_permutations(impl: Any) -> None:
    resources = generator.RESOURCE_IDS[:4]
    bases: list[Any] = [generator.basis(resources[i], i) for i in range(4)]
    # Duplicate r0 at a higher revision to demonstrate max selection.
    records = bases + [generator.basis(resources[0], 9), None]
    # The declared four-element permutation bound applies to independently
    # reconciled record/basis sets; use 4 records plus separately exercise unbased.
    selected = records[:4]
    values: list[Any] = []
    for order in permutations_upto4(selected):
        request = generator.req("reconcile", "reconcile", {"bases": list(order),
                            "world": generator.world([(resources[i], i) for i in range(4)]), "dropped": "2"})
        values.append(_run(impl, "record_reconcile_permutation", [request])[0])
    require("record_reconcile_order", all(_canon(v) == _canon(values[0]) for v in values), selected,
            "reconciliation depends on record order", values)
    maximum_request = generator.req("reconcile", "reconcile", {"bases": [bases[0], generator.basis(resources[0], 9), None],
                        "world": generator.world([(resources[0], 9)]), "dropped": "3"})
    maximum = _run(impl, "record_maximum_basis", [maximum_request])[0]
    # A current maximum basis is absent from divergences, while an older basis
    # would yield world_ahead.  Reconcile therefore proves max-selection by
    # producing no divergence against revision 9 and retaining both counters.
    require("record_maximum_basis", maximum.get("divergences") == [] and maximum.get("unbased") == "1"
            and maximum.get("dropped") == "3", maximum_request,
            "maximum basis selection, unbased, or dropped count not retained", maximum)


def _by_operation(feature: str, operation: str, limit: int | None = None) -> list[Req]:
    values = _requests(feature, operation)
    return [_clone(x) for x in (values if limit is None else values[:limit])]


def check_progression_admission_step_file(impl: Any) -> None:
    """Property checks spanning policy progression, admission, step, and files."""
    progression = []
    for policy in ("latestWins", "fifo", "allExecute"):
        progression.append(_request("request_progression", "empty", lambda r, p=policy: r["input"]["policy"] == p))
    progression += _by_operation("request_progression", "submit") + _by_operation("request_progression", "decideStart")
    progression += _by_operation("request_progression", "applyStartObservation")
    progression += _by_operation("request_progression", "applyCompletionObservation") + _by_operation("request_progression", "decideCancel")
    progression += _by_operation("request_progression", "derivePending") + _by_operation("request_progression", "deriveInFlight") + _by_operation("request_progression", "deriveConcurrent")
    results = _run(impl, "request_progression", progression)
    rendered = json.dumps(results, ensure_ascii=False).lower()
    for word in ("pending", "cancelcommand", "unknowncompletion"):
        require("request_progression_coverage", word in rendered, progression, f"missing {word} progression observation", results)
    # all three derivations must produce an observable scalar result.
    require("request_progression_derivations", all(results[-i] is not None for i in range(1, 7)), progression,
            "derive pending/in-flight/concurrent missing result", results)

    admissions = _by_operation("dynamic_admission", "elideAdmissionProvenance") + _by_operation("dynamic_admission", "admitDynamicRequest")
    admission_values = _run(impl, "dynamic_admission", admissions)
    admission_text = json.dumps(admission_values, ensure_ascii=False).lower()
    # A stale capacity observation closes as capacityObservationUnavailable;
    # accepted admission remains the complementary branch.
    for word in ("capacityobservationunavailable", "applied"):
        require("dynamic_admission_coverage", word in admission_text, admissions, f"missing {word} admission observation", admission_values)
    require("dynamic_admission_provenance", "futureuses" not in json.dumps(admission_values[0]).lower(), admissions[0],
            "elided admission provenance retained unnecessary value", admission_values[0])

    steps = _by_operation("step_transition", "step")
    step_values = _run(impl, "step_transition", steps)
    step_text = json.dumps(step_values, ensure_ascii=False).lower()
    for word in ("reprocess", "capacity", "settled"):
        require("step_transition_coverage", word in step_text, steps, f"missing {word} step observation", step_values)
    # The immediate two-output seed is ordered o0 then o1 and is an observable order contract.
    ordered = next((v for v in step_values if isinstance(v, dict) and v.get("outputs") == ["o0", "o1"]), None)
    require("step_output_order", ordered is not None, steps, "output order was not preserved", step_values)

    files = _by_operation("file_effect", "normalizePath") + _by_operation("file_effect", "read") + _by_operation("file_effect", "replace")
    file_values = _run(impl, "external_file_state", files)
    file_text = json.dumps(file_values, ensure_ascii=False).lower()
    # Missing reads close as rejected and write failures as boundaryFailed;
    # stale and unobserved states remain explicit result variants.
    for word in ("rejected", "stalebasis", "unobserved", "boundaryfailed"):
        require("external_file_state_coverage", word in file_text, files, f"missing {word} file-state observation", file_values)


def run_implementation_properties(impl: Any) -> None:
    check_sequence_threading(impl)
    check_core_permutations(impl)
    check_store_permutations(impl)
    check_record_reconcile_permutations(impl)
    check_progression_admission_step_file(impl)


def generated_differential_requests() -> list[Req]:
    """One finite shared query covering all operation domains and sequences."""
    requests = generator.build_requests()
    for program in generated_sequences():
        requests.extend(program)
    # Guarantee cancellation, expiration/stale capacity and reprocessing are in
    # the same differential query without retaining expected JSON.
    requests += _by_operation("request_progression", "decideCancel")
    requests += _by_operation("dynamic_admission", "admitDynamicRequest")
    requests += _by_operation("step_transition", "step")
    return requests


def check_pairwise_axis_coverage(requests: Iterable[Req]) -> None:
    text = json.dumps(list(requests), ensure_ascii=False)
    for value in generator.NONNEG_INTS:
        require("pairwise_axis_coverage", generator.nat(value) in text, value, "finite integer axis value absent")
    for value in generator.RESOURCE_IDS:
        require("pairwise_axis_coverage", json.dumps(value, ensure_ascii=False, sort_keys=True) in text, value,
                "resource axis value absent")
    for value in generator.PAYLOADS:
        require("pairwise_axis_coverage", json.dumps(value, ensure_ascii=False) in text, value, "payload axis value absent")


def compare_to_lean(implementations: Sequence[Any], requests: list[Req]) -> int:
    require("six_implementations", len(implementations) == 6, [getattr(i, "name", "?") for i in implementations],
            "expected Lean plus five implementations")
    check_pairwise_axis_coverage(requests)
    chunks = generator.contiguous_request_chunks(requests)
    print(
        f"Differential: {len(requests)} runtime-generated requests in {len(chunks)} "
        f"contiguous chunks of at most {generator.DIFFERENTIAL_CHUNK_SIZE}",
        file=sys.stderr,
        flush=True,
    )
    lean = implementations[0]
    for chunk_number, (start, chunk) in enumerate(chunks, start=1):
        end = start + len(chunk)
        print(f"Differential chunk {chunk_number}/{len(chunks)} requests [{start}, {end}): Lean",
              file=sys.stderr, flush=True)
        query = json.dumps({"kind": "evaluate", "requests": chunk}, ensure_ascii=False)
        started = time.monotonic()
        reference = lean.run(query)
        print(f"Differential chunk {chunk_number}/{len(chunks)} Lean completed in "
              f"{time.monotonic() - started:.2f}s", file=sys.stderr, flush=True)
        base_results = reference.get("results") if isinstance(reference, dict) else None
        require("lean_differential_input", isinstance(base_results, list) and len(base_results) == len(chunk), chunk,
                "Lean did not evaluate shared query", reference)
        for impl in implementations[1:]:
            print(f"Differential chunk {chunk_number}/{len(chunks)} requests [{start}, {end}): {impl.name}",
                  file=sys.stderr, flush=True)
            started = time.monotonic()
            candidate = impl.run(query)
            print(f"Differential chunk {chunk_number}/{len(chunks)} {impl.name} completed in "
                  f"{time.monotonic() - started:.2f}s", file=sys.stderr, flush=True)
            values = candidate.get("results") if isinstance(candidate, dict) else None
            require("differential_result_count", isinstance(values, list) and len(values) == len(chunk), chunk,
                    f"{impl.name} did not evaluate shared query", candidate)
            for offset, (expected, actual) in enumerate(zip(base_results, values)):
                index = start + offset
                require("lean_differential", _canon(expected) == _canon(actual), requests[index],
                        f"Lean differs from {impl.name} at request {index}", {"lean": expected, impl.name: actual})
    return len(chunks)
