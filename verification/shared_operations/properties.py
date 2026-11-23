# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

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
    resource = generator.RESOURCE_IDS[1]
    initial = generator.world([(resource, 0)])
    sequence: list[Req] = []
    for length in range(7):
        current = _clone(initial)
        program: list[Req] = []
        for step in range(length):
            revision = 0 if step == 0 else step
            program.append(generator.req("core", "apply", {
                "world": _clone(current),
                "command": generator.command(f"sequence-{length}-{step}", generator.basis(resource, revision)),
            }))


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

    records = bases + [generator.basis(resources[0], 9), None]


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



    require("record_maximum_basis", maximum.get("divergences") == [] and maximum.get("unbased") == "1"
            and maximum.get("dropped") == "3", maximum_request,
            "maximum basis selection, unbased, or dropped count not retained", maximum)


def _by_operation(feature: str, operation: str, limit: int | None = None) -> list[Req]:
    values = _requests(feature, operation)
    return [_clone(x) for x in (values if limit is None else values[:limit])]


def _tag_at(value: Any, path: str) -> str | None:
    node = value
    if path:
        node = node.get(path) if isinstance(node, dict) else None
    tag = node.get("tag") if isinstance(node, dict) else None
    return tag if isinstance(tag, str) else None


def _require_result_tags(property_name: str, requests: list[Req], values: list[Any],
                         expected: dict[str, dict[str, set[str]]]) -> None:
    for operation, positions in expected.items():
        results = [value for request, value in zip(requests, values) if request["operation"] == operation]
        for path, tags in positions.items():
            observed = {_tag_at(value, path) for value in results}
            require(property_name, tags <= observed, operation,
                    f"{operation} did not produce the tags {sorted(tags - observed)} at {path or 'the result'}",
                    sorted(tag for tag in observed if tag))


def _entry(letter: str, phase: str, demand: tuple[int, int, int]) -> Req:
    identity = {"kind": "k", "provenance": f"prov-{letter}", "revision": "0"}
    return {
        "identity": identity,
        "footprint": {"reads": ["r0"], "writes": ["w0"], "effectClass": "pure"},
        "demand": {"pending": str(demand[0]), "inFlight": str(demand[1]), "concurrent": str(demand[2])},
        "phase": phase,
        "meaningPermission": {"tag": "permitted", "identity": identity,
                              "evidence": [{"identifier": "e0", "digest": "d0", "artifactPath": "a0"}]},
        "costSelection": None,
        "executionHandle": None,
    }


def _snapshot(entries: list[Req]) -> Req:
    maximum = {name: {"resource": resource, "maximum": "9"}
               for name, resource in (("pendingMaximum", "pending"), ("inFlightMaximum", "inFlight"),
                                      ("concurrentMaximum", "concurrent"))}
    return {"policy": "fifo", "budget": maximum, "currentIdentity": None, "entries": entries, "revision": "1"}


LARGE_STATE_COUNT = 1000
LARGE_STATE_PHASES = ("pending", "preparing", "publishing", "published", "superseded", "cancelled", "failed")


def _large_identity(index: int) -> Req:
    return {"kind": "k", "provenance": f"large-{index}", "revision": str(index)}


def _large_entry(index: int) -> Req:
    identity = _large_identity(index)
    phase = LARGE_STATE_PHASES[index % len(LARGE_STATE_PHASES)]
    effect_class = "orderedEffect" if index % 3 == 0 else "pure"
    permission_tag = "ordered" if effect_class == "orderedEffect" else "permitted"
    return {
        "identity": identity,
        "footprint": {"reads": [f"r{index % 5}"], "writes": [], "effectClass": effect_class},
        "demand": {"pending": str(index % 4), "inFlight": str(index % 3), "concurrent": str(index % 2)},
        "phase": phase,
        "meaningPermission": {"tag": permission_tag, "identity": identity,
                              "evidence": [{"identifier": "e0", "digest": "d0", "artifactPath": "a0"}]},
        "costSelection": None,
        "executionHandle": f"h{index}" if phase == "publishing" else None,
    }


def _large_snapshot(policy: str) -> Req:
    maximum = {name: {"resource": resource, "maximum": str(10 ** 6)}
               for name, resource in (("pendingMaximum", "pending"), ("inFlightMaximum", "inFlight"),
                                      ("concurrentMaximum", "concurrent"))}
    entries = [_large_entry(index) for index in range(LARGE_STATE_COUNT)]
    return {"policy": policy, "budget": maximum, "currentIdentity": _large_identity(LARGE_STATE_COUNT - 7),
            "entries": entries, "revision": str(LARGE_STATE_COUNT)}


def _large_index(phase: str, position: str) -> int:
    indices = [index for index in range(LARGE_STATE_COUNT)
               if LARGE_STATE_PHASES[index % len(LARGE_STATE_PHASES)] == phase]
    return indices[0] if position == "first" else indices[-1]


def large_state_requests() -> list[Req]:
    requests: list[Req] = []
    world = [{"resource": {"kind": "res", "name": f"r{index % 900}"}, "revision": str(index)}
             for index in range(LARGE_STATE_COUNT)]
    last = world[-1]
    for operation, extra in (("lookup", {"resource": last["resource"]}), ("bump", {"resource": last["resource"]})):
        requests.append(generator.req("core", operation, {"world": world, **extra}))
    for revision in (last["revision"], "1"):
        command = {"intent": "x", "basis": {"resource": last["resource"], "revision": revision}}
        requests.append(generator.req("core", "apply", {"world": world, "command": command}))
    evidence = {"identifier": "e0", "digest": "d0", "artifactPath": "a0"}
    for policy in ("latestWins", "fifo", "allExecute"):
        snapshot = _large_snapshot(policy)
        fresh = _large_identity(LARGE_STATE_COUNT)
        requests.append(generator.req("request_progression", "submit", {"snapshot": snapshot, "request": {
            "identity": fresh, "footprint": {"reads": [], "writes": [], "effectClass": "pure"},
            "demand": {"pending": "1", "inFlight": "1", "concurrent": "1"},
            "permission": {"tag": "permitted", "identity": fresh, "evidence": [evidence]}}}))
        for position in ("first", "last"):
            pending = _large_identity(_large_index("pending", position))
            for tag in ("executeNow", "remainPending"):
                requests.append(generator.req("request_progression", "decideStart", {
                    "snapshot": snapshot, "accepted": {"identity": pending},
                    "selection": {"tag": tag, "identity": pending, "evidence": evidence, "cost": "1"}}))
            requests.append(generator.req("request_progression", "decideCancel",
                                          {"snapshot": snapshot, "identity": pending}))
            preparing = _large_identity(_large_index("preparing", position))
            requests.append(generator.req("request_progression", "applyStartObservation", {
                "snapshot": snapshot,
                "starting": {"identity": preparing, "command": {
                    "tag": "startCommand", "identity": preparing,
                    "footprint": {"reads": [], "writes": [], "effectClass": "pure"}}},
                "observed": {"tag": "appliedSignal", "signal": {
                    "tag": "started", "identity": preparing, "handle": "started"}}}))
            index = _large_index("publishing", position)
            publishing = _large_identity(index)
            requests.append(generator.req("request_progression", "applyCompletionObservation", {
                "snapshot": snapshot, "running": {"identity": publishing, "handle": f"h{index}"},
                "observed": {"tag": "appliedSignal", "signal": {
                    "tag": "completed", "identity": publishing, "handle": f"h{index}", "value": "v"}}}))
        for name in ("derivePending", "deriveInFlight", "deriveConcurrent"):
            requests.append(generator.req("request_progression", name, {"snapshot": snapshot}))
        retained = [_large_identity(_large_index("pending", "first")), _large_identity(_large_index("preparing", "last"))]
        signalled = _large_index("publishing", "first")
        signal = {"identity": _large_identity(signalled), "handle": f"h{signalled}", "kind": "pendingCompletion"}
        state = {"progression": snapshot, "configuredSafetyLimit": snapshot["budget"],
                 "provenance": {"futureUses": retained, "outstandingSignals": [signal]}}
        for start in (None, {"tag": "executeNow", "identity": fresh, "evidence": evidence, "cost": "1"}):
            requests.append(generator.req("dynamic_admission", "admitDynamicRequest", {
                "state": state,
                "request": {"identity": fresh, "footprint": {"reads": [], "writes": [], "effectClass": "pure"},
                            "demand": {"pending": "1", "inFlight": "1", "concurrent": "1"},
                            "permission": {"tag": "permitted", "identity": fresh, "evidence": [evidence]}},
                "environmentSpecification": {"maxObservationAge": "1"},
                "capacityObservation": {"observed": snapshot["budget"], "observedAt": "0"},
                "observedAt": "0",
                "start": start}))
        terminal = _large_identity(_large_index("published", "last"))
        requests.append(generator.req("dynamic_admission", "elideAdmissionProvenance",
                                      {"state": state, "identity": terminal}))
    return requests


def derivation_requests() -> list[Req]:
    snapshot = _snapshot([_entry("p", "pending", (1, 10, 100)), _entry("q", "preparing", (2, 20, 200)),
                          _entry("r", "publishing", (4, 40, 400))])
    return [generator.req("request_progression", name, {"snapshot": snapshot})
            for name in ("derivePending", "deriveInFlight", "deriveConcurrent")]


def check_derivation_coverage(requests: Iterable[Req]) -> None:
    distinguishing: set[str] = set()
    for request in requests:
        if request["feature"] != "request_progression" or not request["operation"].startswith("derive"):
            continue
        entries = request["input"]["snapshot"]["entries"]
        by_phase = {entry["phase"]: tuple(int(entry["demand"][key]) for key in ("pending", "inFlight", "concurrent"))
                    for entry in entries}
        if len(by_phase) != len(entries) or not {"pending", "preparing", "publishing"} <= set(by_phase):
            continue
        pending, preparing, publishing = by_phase["pending"], by_phase["preparing"], by_phase["publishing"]
        total = tuple(left + right for left, right in zip(preparing, publishing))
        if pending not in (preparing, publishing, total) and preparing != publishing and all(
                any(part) for part in (pending, preparing, publishing)):
            distinguishing.add(request["operation"])
    for operation in ("derivePending", "deriveInFlight", "deriveConcurrent"):
        require("request_progression_derivations", operation in distinguishing, operation,
                "no generated snapshot separates the phases by demands that are distinct and not sums of one another")


def check_retention_coverage(requests: Iterable[Req]) -> None:
    terminal_phases = {"published", "superseded", "cancelled", "failed"}
    observed: set[tuple[bool, bool]] = set()
    for request in requests:
        if request["feature"] != "dynamic_admission" or request["operation"] != "elideAdmissionProvenance":
            continue
        state, identity = request["input"]["state"], request["input"]["identity"]
        if not any(entry["identity"] == identity and entry["phase"] in terminal_phases
                   for entry in state["progression"]["entries"]):
            continue
        provenance = state["provenance"]
        observed.add((identity in provenance["futureUses"],
                      any(signal["identity"] == identity for signal in provenance["outstandingSignals"])))
    for case, label in (((True, False), "future use only"), ((False, True), "outstanding signal only"),
                        ((True, True), "future use and outstanding signal"), ((False, False), "neither")):
        require("dynamic_admission_retention_coverage", case in observed, label,
                f"no generated erasure request has a terminal target with {label}", sorted(observed))


def check_provenance_elision(impl: Any) -> None:
    target, other = _entry("a", "published", (0, 0, 0)), _entry("b", "published", (0, 0, 0))
    state = {"progression": _snapshot([target, other]), "configuredSafetyLimit": _snapshot([])["budget"],
             "provenance": {"futureUses": [], "outstandingSignals": []}}
    request = generator.req("dynamic_admission", "elideAdmissionProvenance",
                            {"state": state, "identity": target["identity"]})
    value = _run(impl, "dynamic_admission_provenance", [request])[0]
    require("dynamic_admission_provenance", isinstance(value, dict) and value.get("tag") == "applied", request,
            "elision of a terminal entry was not applied", value)
    entries = value["state"]["progression"]["entries"]
    require("dynamic_admission_provenance", len(entries) == 2, request, "elision changed the number of entries", value)
    erased, kept = entries
    require("dynamic_admission_provenance",
            erased["identity"] == target["identity"] and erased["footprint"]["reads"] == []
            and erased["footprint"]["writes"] == [] and erased["meaningPermission"]["evidence"] == [],
            request, "elided entry retained footprint or evidence", erased)
    require("dynamic_admission_provenance", kept == other, request, "elision changed another entry", kept)
    second_request = generator.req("dynamic_admission", "elideAdmissionProvenance",
                                   {"state": value["state"], "identity": target["identity"]})
    second_value = _run(impl, "dynamic_admission_provenance", [second_request])[0]
    require("dynamic_admission_provenance",
            isinstance(second_value, dict) and second_value.get("tag") == "applied",
            second_request, "second elision of an already elided terminal entry was not applied", second_value)
    require("dynamic_admission_provenance", second_value["state"] == value["state"],
            second_request, "second elision changed the already elided state", second_value)
    require("dynamic_admission_provenance", second_value["witness"] == value["witness"],
            second_request, "second elision changed the witness", second_value)


def check_progression_admission_step_file(impl: Any) -> None:
    progression = []
    for policy in ("latestWins", "fifo", "allExecute"):
        progression.append(_request("request_progression", "empty", lambda r, p=policy: r["input"]["policy"] == p))
    progression += _by_operation("request_progression", "submit") + _by_operation("request_progression", "decideStart")
    progression += _by_operation("request_progression", "applyStartObservation")
    progression += _by_operation("request_progression", "applyCompletionObservation") + _by_operation("request_progression", "decideCancel")
    results = _run(impl, "request_progression", progression)
    _require_result_tags("request_progression_coverage", progression, results, {
        "submit": {"": {"accepted", "submitRejected"}, "failure": {"pendingLimitExceeded"}},
        "decideStart": {"": {"execute", "deferred", "rejected"}, "failure": {"unknownRequest", "policyOrderBlocked"}},
        "applyStartObservation": {"": {"publishing", "failed"}, "failure": {"requestNotStarting"}},
        "applyCompletionObservation": {"": {"applied", "superseded", "failed"},
                                       "failure": {"unknownCompletion", "completionAdapterFailureObserved"}},
        "decideCancel": {"": {"cancelCommand", "rejected"}, "failure": {"unknownRequest"}},
    })

    admissions = _by_operation("dynamic_admission", "elideAdmissionProvenance") + _by_operation("dynamic_admission", "admitDynamicRequest")
    admission_values = _run(impl, "dynamic_admission", admissions)
    _require_result_tags("dynamic_admission_coverage", admissions, admission_values, {
        "elideAdmissionProvenance": {"": {"applied", "rejected"},
                                     "failure": {"unknownRequest", "provenanceRetentionRequired"}},
        "admitDynamicRequest": {"": {"applied", "rejected"},
                                "failure": {"capacityObservationUnavailable", "progressionSubmitFailure"}},
    })
    check_provenance_elision(impl)

    steps = _by_operation("step_transition", "step")
    step_values = _run(impl, "step_transition", steps)
    _require_result_tags("step_transition_coverage", steps, step_values, {
        "step": {"": {"settled", "failed"}, "failure": {"reprocess_limit_exhausted", "capacity_exceeded"}},
    })

    ordered = next((v for v in step_values if isinstance(v, dict) and v.get("outputs") == ["o0", "o1"]), None)
    require("step_output_order", ordered is not None, steps, "output order was not preserved", step_values)

    files = _by_operation("file_effect", "normalizePath") + _by_operation("file_effect", "read") + _by_operation("file_effect", "replace")
    file_values = _run(impl, "external_file_state", files)
    _require_result_tags("external_file_state_coverage", files, file_values, {
        "read": {"": {"applied", "rejected", "boundaryFailed"}},
        "replace": {"": {"applied", "rejected", "conflicted", "boundaryFailed"},
                    "rejection": {"resourcePathMismatch", "unobservedContents"},
                    "conflict": {"staleBasis", "externalMutation"}},
    })


def _rp_step(impl: Any, operation: str, inp: dict[str, Any], expected_tag: str | None = None) -> Any:
    request = generator.req("request_progression", operation, inp)
    value = _run(impl, f"rp_threading_{operation}", [request])[0]
    if expected_tag is not None:
        require("request_progression_threading", isinstance(value, dict) and value.get("tag") == expected_tag,
                request, f"expected tag {expected_tag!r}", value)
    return value


def _check_rp_budget_and_count(impl: Any, snapshot: dict[str, Any], expected_count: int, context: Any) -> None:
    entries = snapshot.get("entries")
    require("request_progression_entry_count", isinstance(entries, list) and len(entries) == expected_count,
            context, f"expected {expected_count} entries, got {len(entries) if isinstance(entries, list) else None}", snapshot)
    budget = snapshot["budget"]
    derived = _run(impl, "rp_budget_derive", [
        generator.req("request_progression", "derivePending", {"snapshot": snapshot}),
        generator.req("request_progression", "deriveInFlight", {"snapshot": snapshot}),
        generator.req("request_progression", "deriveConcurrent", {"snapshot": snapshot}),
    ])
    require("request_progression_budget_pending",
            int(derived[0]["pending"]) <= int(budget["pendingMaximum"]["maximum"]),
            context, "derivePending exceeds pendingMaximum", derived[0])
    require("request_progression_budget_in_flight",
            int(derived[1]["inFlight"]) <= int(budget["inFlightMaximum"]["maximum"]),
            context, "deriveInFlight exceeds inFlightMaximum", derived[1])
    require("request_progression_budget_concurrent",
            int(derived[2]["concurrent"]) <= int(budget["concurrentMaximum"]["maximum"]),
            context, "deriveConcurrent exceeds concurrentMaximum", derived[2])


def check_request_progression_threading(impl: Any) -> list[Any]:
    evidence = [{"identifier": "e0", "digest": "d0", "artifactPath": "a0"}]
    ident = lambda name, rev=0: {"kind": "k", "provenance": name, "revision": str(rev)}
    perm = lambda i, ordered=False: {"tag": "ordered" if ordered else "permitted", "identity": i, "evidence": evidence}
    fp = lambda ordered=False: {"reads": ["r0"], "writes": [], "effectClass": "orderedEffect" if ordered else "pure"}
    dem = lambda p, i, c: {"pending": str(p), "inFlight": str(i), "concurrent": str(c)}
    mk_req = lambda i, ordered=False, d=(1, 1, 1): {
        "identity": i, "footprint": fp(ordered), "demand": dem(*d), "permission": perm(i, ordered),
    }
    mk_sel = lambda i, tag="executeNow": {"tag": tag, "identity": i, "evidence": evidence[0], "cost": "1"}
    mk_budget = lambda p, i, c: {
        "pendingMaximum": {"resource": "pending", "maximum": str(p)},
        "inFlightMaximum": {"resource": "inFlight", "maximum": str(i)},
        "concurrentMaximum": {"resource": "concurrent", "maximum": str(c)},
    }
    trace: list[Any] = []

    empties = _run(impl, "rp_threading_empty", [
        generator.req("request_progression", "empty", {"policy": "fifo", "budget": mk_budget(2, 2, 2)}),
        generator.req("request_progression", "empty", {"policy": "allExecute", "budget": mk_budget(5, 5, 5)}),
        generator.req("request_progression", "empty", {"policy": "latestWins", "budget": mk_budget(2, 2, 2)}),
    ])
    trace.extend(empties)

    # 1. FIFO: submit -> decideStart(blocked/deferred/execute) -> applyStartObservation(publishing) -> applyCompletionObservation(applied)
    s = empties[0]
    _check_rp_budget_and_count(impl, s, 0, "fifo.empty")
    id0, id1 = ident("fifo-0"), ident("fifo-1")
    r = _rp_step(impl, "submit", {"snapshot": s, "request": mk_req(id0)}, "accepted")
    trace.append(r); s, a0 = r["snapshot"], r["accepted"]
    _check_rp_budget_and_count(impl, s, 1, "fifo.submit0")

    r = _rp_step(impl, "submit", {"snapshot": s, "request": mk_req(id1)}, "accepted")
    trace.append(r); s, a1 = r["snapshot"], r["accepted"]
    _check_rp_budget_and_count(impl, s, 2, "fifo.submit1")

    r = _rp_step(impl, "decideStart", {"snapshot": s, "accepted": a1, "selection": mk_sel(id1)}, "rejected")
    require("fifo_policy_order_blocked", r.get("failure", {}).get("tag") == "policyOrderBlocked", r, "expected policyOrderBlocked", r)
    trace.append(r); s = r["snapshot"]
    _check_rp_budget_and_count(impl, s, 2, "fifo.blocked1")

    r = _rp_step(impl, "decideStart", {"snapshot": s, "accepted": a0, "selection": mk_sel(id0, "remainPending")}, "deferred")
    trace.append(r); s = r["snapshot"]
    _check_rp_budget_and_count(impl, s, 2, "fifo.deferred0")

    r = _rp_step(impl, "decideStart", {"snapshot": s, "accepted": a0, "selection": mk_sel(id0)}, "execute")
    trace.append(r); s, st0 = r["snapshot"], r["starting"]
    _check_rp_budget_and_count(impl, s, 2, "fifo.execute0")

    r = _rp_step(impl, "applyStartObservation", {
        "snapshot": s, "starting": st0,
        "observed": {"tag": "appliedSignal", "signal": {"tag": "started", "identity": id0, "handle": "h0"}},
    }, "publishing")
    trace.append(r); s, run0 = r["snapshot"], r["running"]
    _check_rp_budget_and_count(impl, s, 2, "fifo.publishing0")

    r = _rp_step(impl, "decideStart", {"snapshot": s, "accepted": a1, "selection": mk_sel(id1)}, "execute")
    trace.append(r); s = r["snapshot"]
    _check_rp_budget_and_count(impl, s, 2, "fifo.execute1")

    r = _rp_step(impl, "applyCompletionObservation", {
        "snapshot": s, "running": run0,
        "observed": {"tag": "appliedSignal", "signal": {"tag": "completed", "identity": id0, "handle": "h0", "value": "v0"}},
    }, "applied")
    trace.append(r); s = r["snapshot"]
    _check_rp_budget_and_count(impl, s, 2, "fifo.applied0")

    # 2. AllExecute + OrderedEffect: orderedEffect serialized while pure starts freely
    s = empties[1]
    o0, o1, p2 = ident("ord-0"), ident("ord-1"), ident("pure-2")
    r = _rp_step(impl, "submit", {"snapshot": s, "request": mk_req(o0, ordered=True)}, "accepted")
    trace.append(r); s, ao0 = r["snapshot"], r["accepted"]
    r = _rp_step(impl, "submit", {"snapshot": s, "request": mk_req(o1, ordered=True)}, "accepted")
    trace.append(r); s, ao1 = r["snapshot"], r["accepted"]
    r = _rp_step(impl, "submit", {"snapshot": s, "request": mk_req(p2, ordered=False)}, "accepted")
    trace.append(r); s, ap2 = r["snapshot"], r["accepted"]
    _check_rp_budget_and_count(impl, s, 3, "allExecute.submits")

    r = _rp_step(impl, "decideStart", {"snapshot": s, "accepted": ao1, "selection": mk_sel(o1)}, "rejected")
    require("ordered_effect_policy_order_blocked", r.get("failure", {}).get("tag") == "policyOrderBlocked", r, "expected policyOrderBlocked", r)
    trace.append(r); s = r["snapshot"]

    r = _rp_step(impl, "decideStart", {"snapshot": s, "accepted": ap2, "selection": mk_sel(p2)}, "execute")
    trace.append(r); s = r["snapshot"]

    r = _rp_step(impl, "decideStart", {"snapshot": s, "accepted": ao0, "selection": mk_sel(o0)}, "execute")
    trace.append(r); s, sto0 = r["snapshot"], r["starting"]
    r = _rp_step(impl, "applyStartObservation", {
        "snapshot": s, "starting": sto0,
        "observed": {"tag": "appliedSignal", "signal": {"tag": "started", "identity": o0, "handle": "ho0"}},
    }, "publishing")
    trace.append(r); s, runo0 = r["snapshot"], r["running"]
    r = _rp_step(impl, "applyCompletionObservation", {
        "snapshot": s, "running": runo0,
        "observed": {"tag": "appliedSignal", "signal": {"tag": "completed", "identity": o0, "handle": "ho0", "value": "vo0"}},
    }, "applied")
    trace.append(r); s = r["snapshot"]
    r = _rp_step(impl, "decideStart", {"snapshot": s, "accepted": ao1, "selection": mk_sel(o1)}, "execute")
    trace.append(r); s = r["snapshot"]
    _check_rp_budget_and_count(impl, s, 3, "allExecute.ordered1")

    # 3. LatestWins + Pending budget rejection: superseding pending & stale completion
    s = empties[2]
    l0, l1, l2 = ident("lw-0"), ident("lw-1"), ident("lw-2")
    r = _rp_step(impl, "submit", {"snapshot": s, "request": mk_req(l0, d=(1, 1, 1))}, "accepted")
    trace.append(r); s, al0 = r["snapshot"], r["accepted"]
    r = _rp_step(impl, "decideStart", {"snapshot": s, "accepted": al0, "selection": mk_sel(l0)}, "execute")
    trace.append(r); s, stl0 = r["snapshot"], r["starting"]
    r = _rp_step(impl, "applyStartObservation", {
        "snapshot": s, "starting": stl0,
        "observed": {"tag": "appliedSignal", "signal": {"tag": "started", "identity": l0, "handle": "hl0"}},
    }, "publishing")
    trace.append(r); s, runl0 = r["snapshot"], r["running"]

    r = _rp_step(impl, "submit", {"snapshot": s, "request": mk_req(l1, d=(3, 0, 0))}, "submitRejected")
    require("budget_pending_limit_exceeded", r.get("failure", {}).get("tag") == "pendingLimitExceeded", r, "expected pendingLimitExceeded", r)
    trace.append(r); s = r["snapshot"]
    _check_rp_budget_and_count(impl, s, 1, "latestWins.rejected_budget")

    r = _rp_step(impl, "submit", {"snapshot": s, "request": mk_req(l1, d=(1, 1, 1))}, "accepted")
    trace.append(r); s, al1 = r["snapshot"], r["accepted"]
    r = _rp_step(impl, "submit", {"snapshot": s, "request": mk_req(l2, d=(1, 1, 1))}, "accepted")
    trace.append(r); s = r["snapshot"]
    _check_rp_budget_and_count(impl, s, 3, "latestWins.superseded_pending")

    r = _rp_step(impl, "decideStart", {"snapshot": s, "accepted": al1, "selection": mk_sel(l1)}, "rejected")
    require("latest_wins_pending_superseded", r.get("failure", {}).get("tag") == "requestNotPending", r, "expected requestNotPending", r)
    trace.append(r); s = r["snapshot"]

    r = _rp_step(impl, "applyCompletionObservation", {
        "snapshot": s, "running": runl0,
        "observed": {"tag": "appliedSignal", "signal": {"tag": "completed", "identity": l0, "handle": "hl0", "value": "stale"}},
    }, "superseded")
    trace.append(r); s = r["snapshot"]
    _check_rp_budget_and_count(impl, s, 3, "latestWins.stale_completion")
    return trace


def compare_request_progression_threading(implementations: Sequence[Any]) -> None:
    require("six_implementations", len(implementations) == 6, [getattr(i, "name", "?") for i in implementations],
            "expected Lean plus five implementations")
    reference = check_request_progression_threading(implementations[0])
    for impl in implementations[1:]:
        candidate = check_request_progression_threading(impl)
        require("rp_threading_length", len(candidate) == len(reference), len(candidate),
                f"{impl.name} trace length differs from Lean", len(reference))
        for step_index, (expected, actual) in enumerate(zip(reference, candidate)):
            require("rp_threading_differential", _canon(expected) == _canon(actual), step_index,
                    f"Lean differs from {impl.name} in chained request_progression at step {step_index}",
                    {"lean": expected, impl.name: actual})


def run_implementation_properties(impl: Any) -> None:
    check_sequence_threading(impl)
    check_core_permutations(impl)
    check_store_permutations(impl)
    check_record_reconcile_permutations(impl)
    check_progression_admission_step_file(impl)
    check_request_progression_threading(impl)


def generated_differential_requests() -> list[Req]:
    requests = generator.build_requests()
    for program in generated_sequences():
        requests.extend(program)


    requests += _by_operation("request_progression", "decideCancel")
    requests += _by_operation("dynamic_admission", "admitDynamicRequest")
    requests += _by_operation("step_transition", "step")
    requests += derivation_requests()
    requests += large_state_requests()
    return requests


def compare_to_lean(implementations: Sequence[Any], requests: list[Req]) -> int:
    require("six_implementations", len(implementations) == 6, [getattr(i, "name", "?") for i in implementations],
            "expected Lean plus five implementations")
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
