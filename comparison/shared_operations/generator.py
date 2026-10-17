# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT


from __future__ import annotations

import itertools
import json
import sys
from typing import Any



DIFFERENTIAL_CHUNK_SIZE = 32





SURFACE: list[tuple[str, list[str]]] = [
    ("core", ["lookup", "bump", "commandOf", "apply"]),
    ("call", ["immediateOf", "deferredOf", "io", "issue"]),
    ("iteration", ["fold", "recurse", "closure"]),
    ("store", ["storeOf", "storeEntries", "observe", "apply", "worldOf"]),
    ("record", ["recordOf", "recordOnBasis", "hasEdge"]),
    ("reconcile", ["reconcile", "coherent"]),
    (
        "request_progression",
        [
            "empty",
            "submit",
            "decideStart",
            "applyStartObservation",
            "applyCompletionObservation",
            "decideCancel",
            "derivePending",
            "deriveInFlight",
            "deriveConcurrent",
        ],
    ),
    ("dynamic_admission", ["elideAdmissionProvenance", "admitDynamicRequest"]),
    ("step_transition", ["step"]),
    ("file_effect", ["normalizePath", "lookupDigest", "setDigest", "track", "read", "replace"]),
]

ALL_OPERATIONS: list[tuple[str, str]] = [
    (feature, op) for feature, ops in SURFACE for op in ops
]






NONNEG_INTS: list[int] = [0, 1, 2, 3, 2**53 - 1, 2**53, 2**63 - 1, 2**63, 2**64, 10**100]
INVALID_INTS: list[str] = ["-1", "1.5", "abc", ""]

RESOURCE_IDS: list[dict[str, str]] = [
    {"kind": "", "name": ""},
    {"kind": "res", "name": "r0"},
    {"kind": "res", "name": "r1"},
    {"kind": "res", "name": "r2"},
    {"kind": "res", "name": "資源\u00e9\U0001f600"},
]

PAYLOADS: list[Any] = [
    None,
    "p0",
    "p1",
    "p2",
    "unicode\u00e9\n\u65e5\u672c\u8a9e\nline2",
]


def nat(n: int) -> str:
    return str(n)


def rid(kind: str, name: str) -> dict[str, str]:
    return {"kind": kind, "name": name}


def basis(resource: dict[str, str], revision: int) -> dict[str, Any]:
    return {"resource": resource, "revision": nat(revision)}


def world(entries: list[tuple[dict[str, str], int]]) -> list[dict[str, Any]]:
    return [{"resource": r, "revision": nat(v)} for r, v in entries]


def command(intent: Any, b: dict[str, Any]) -> dict[str, Any]:
    return {"intent": intent, "basis": b}


def observation(payload: Any, b: dict[str, Any], observed_at: int) -> dict[str, Any]:
    return {"payload": payload, "basis": b, "observedAt": nat(observed_at)}


def zip_cycle(*seqs: list[Any]) -> list[tuple[Any, ...]]:
    n = max(len(s) for s in seqs)
    return [tuple(s[i % len(s)] for s in seqs) for i in range(n)]


def permutations_upto4(items: list[Any]) -> list[tuple[Any, ...]]:
    if len(items) > 4:
        raise ValueError("permutation builder is bounded to 4 elements")
    return list(itertools.permutations(items))







def form_identity() -> dict[str, Any]:
    return {"kind": "identity"}


def form_const(value: Any) -> dict[str, Any]:
    return {"kind": "const", "value": value}


def form_get_field(name: str) -> dict[str, Any]:
    return {"kind": "getField", "name": name}


def form_set_field(name: str, value: Any) -> dict[str, Any]:
    return {"kind": "setField", "name": name, "value": value}


def form_wrap(tag: str) -> dict[str, Any]:
    return {"kind": "wrap", "tag": tag}


def immediate_decl(identity: str, required: list[str], output: dict[str, Any]) -> dict[str, Any]:
    return {"identity": identity, "required": required, "output": output}


def call_request(payload: Any, fields: list[str]) -> dict[str, Any]:
    return {"payload": payload, "fields": fields}


Req = dict[str, Any]


def req(feature: str, operation: str, input_: Any) -> Req:
    return {"feature": feature, "operation": operation, "input": input_}


def build_seed_requests() -> list[Req]:
    out: list[Req] = []

    w_basic = world([(RESOURCE_IDS[1], 0), (RESOURCE_IDS[2], 5)])
    w_empty: list[dict[str, Any]] = []
    w_large = world([(r, v) for r, v in zip_cycle(RESOURCE_IDS, NONNEG_INTS)])

    for w in (w_empty, w_basic, w_large):
        out.append(req("core", "lookup", {"world": w, "resource": RESOURCE_IDS[1]}))
    out.append(req("core", "lookup", {"world": w_basic, "resource": RESOURCE_IDS[3]}))

    out.append(req("core", "bump", {"world": w_basic, "resource": RESOURCE_IDS[1]}))
    out.append(req("core", "bump", {"world": w_basic, "resource": RESOURCE_IDS[3]}))
    out.append(req("core", "bump", {"world": w_empty, "resource": RESOURCE_IDS[0]}))

    for pl in PAYLOADS[:3]:
        out.append(
            req(
                "core",
                "commandOf",
                {"observation": observation(pl, basis(RESOURCE_IDS[1], 0), 10), "payload": pl},
            )
        )

    out.append(req("core", "apply", {"world": w_basic, "command": command("intent0", basis(RESOURCE_IDS[1], 0))}))
    out.append(req("core", "apply", {"world": w_basic, "command": command("intent1", basis(RESOURCE_IDS[3], 0))}))
    out.append(req("core", "apply", {"world": w_basic, "command": command("intent2", basis(RESOURCE_IDS[1], 7))}))

    out.append(req("call", "immediateOf", immediate_decl("id.imm.a", ["f0"], form_identity())))
    out.append(req("call", "immediateOf", immediate_decl("id.imm.b", [], form_const("k"))))
    out.append(req("call", "deferredOf", immediate_decl("id.def.a", ["f0", "f1"], form_get_field("f0"))))
    out.append(req("call", "deferredOf", immediate_decl("id.def.b", [], form_wrap("w"))))

    decl_io = immediate_decl("id.io.a", ["a", "b"], form_set_field("out", "v"))
    out.append(req("call", "io", {"declaration": decl_io, "request": call_request({"a": 1, "b": 2}, ["a", "b"])}))
    out.append(req("call", "io", {"declaration": decl_io, "request": call_request({"a": 1}, ["a"])}))

    decl_issue = immediate_decl("id.issue.a", ["x"], form_identity())
    out.append(req("call", "issue", {"declaration": decl_issue, "request": call_request({"x": 1}, ["x"])}))
    out.append(req("call", "issue", {"declaration": decl_issue, "request": call_request({}, [])}))

    fold_step = immediate_decl("id.fold.step", ["n"], form_get_field("n"))
    out.append(req("iteration", "fold", {"step": fold_step, "seed": {"n": 0}, "count": nat(3), "stepFields": ["n"]}))
    fold_step_missing = immediate_decl("id.fold.step.bad", ["missing"], form_identity())
    out.append(
        req("iteration", "fold", {"step": fold_step_missing, "seed": {"n": 0}, "count": nat(2), "stepFields": ["n"]})
    )

    recurse_table_settle = [{"payload": 0, "outcome": {"tag": "settled"}}]
    out.append(
        req(
            "iteration",
            "recurse",
            {"required": [], "table": recurse_table_settle, "next": form_identity(), "seed": 0, "stepFields": []},
        )
    )
    recurse_table_decrease = [
        {"payload": 2, "outcome": {"tag": "advance", "measure": nat(2)}},
        {"payload": 1, "outcome": {"tag": "advance", "measure": nat(1)}},
        {"payload": 0, "outcome": {"tag": "settled"}},
    ]
    out.append(
        req(
            "iteration",
            "recurse",
            {"required": [], "table": recurse_table_decrease, "next": form_const(1), "seed": 2, "stepFields": []},
        )
    )
    recurse_table_bad = [
        {"payload": 5, "outcome": {"tag": "advance", "measure": nat(1)}},
        {"payload": 5, "outcome": {"tag": "advance", "measure": nat(2)}},
    ]
    out.append(
        req(
            "iteration",
            "recurse",
            {"required": [], "table": recurse_table_bad, "next": form_identity(), "seed": 5, "stepFields": []},
        )
    )

    closure_step = {"identity": "id.closure.step", "required": [], "output": form_identity()}
    out.append(
        req("iteration", "closure", {"step": closure_step, "carrier": ["a", "b", "c"], "seed": ["a"], "stepFields": []})
    )
    closure_step_missing = {"identity": "id.closure.step.bad", "required": ["missing"], "output": form_identity()}
    out.append(
        req("iteration", "closure", {"step": closure_step_missing, "carrier": ["a"], "seed": ["a"], "stepFields": []})
    )

    store_entries = [
        {"resource": RESOURCE_IDS[1], "revision": nat(0), "payload": "p0"},
        {"resource": RESOURCE_IDS[2], "revision": nat(3), "payload": "p1"},
    ]
    out.append(req("store", "storeOf", store_entries))
    out.append(req("store", "storeOf", []))
    out.append(req("store", "storeEntries", {"store": store_entries}))
    out.append(req("store", "observe", {"store": store_entries, "resource": RESOURCE_IDS[1]}))
    out.append(req("store", "observe", {"store": store_entries, "resource": RESOURCE_IDS[3]}))
    out.append(req("store", "apply", {"store": store_entries, "command": command("i0", basis(RESOURCE_IDS[1], 0))}))
    out.append(req("store", "apply", {"store": store_entries, "command": command("i1", basis(RESOURCE_IDS[3], 0))}))
    out.append(req("store", "apply", {"store": store_entries, "command": command("i2", basis(RESOURCE_IDS[1], 9))}))
    out.append(req("store", "worldOf", store_entries))
    out.append(req("store", "worldOf", []))

    out.append(req("record", "recordOf", {"declaration": "decl.a", "input": {"x": 1}, "product": {"y": 2}}))
    out.append(
        req(
            "record",
            "recordOnBasis",
            {"declaration": "decl.b", "input": {"x": 1}, "product": {"y": 2}, "basis": basis(RESOURCE_IDS[1], 4)},
        )
    )

    def call_record(decl: str, inp: Any, prod: Any, b: dict[str, Any] | None) -> dict[str, Any]:
        return {"declaration": decl, "input": inp, "product": prod, "basis": b}

    out.append(
        req(
            "record",
            "hasEdge",
            {
                "earlier": call_record("d0", 1, 2, basis(RESOURCE_IDS[1], 0)),
                "later": call_record("d1", 3, 4, basis(RESOURCE_IDS[1], 1)),
            },
        )
    )
    out.append(
        req(
            "record",
            "hasEdge",
            {
                "earlier": call_record("d0", 1, 2, basis(RESOURCE_IDS[1], 0)),
                "later": call_record("d1", 3, 4, basis(RESOURCE_IDS[2], 0)),
            },
        )
    )
    out.append(
        req(
            "record",
            "hasEdge",
            {
                "earlier": call_record("d0", 1, 2, None),
                "later": call_record("d1", 3, 4, basis(RESOURCE_IDS[1], 0)),
            },
        )
    )

    bases_mixed = [basis(RESOURCE_IDS[1], 0), None, basis(RESOURCE_IDS[2], 2)]
    out.append(req("reconcile", "reconcile", {"bases": bases_mixed, "world": w_basic, "dropped": nat(1)}))
    out.append(req("reconcile", "reconcile", {"bases": [], "world": w_empty, "dropped": nat(0)}))
    out.append(
        req(
            "reconcile",
            "reconcile",
            {
                "bases": [basis(RESOURCE_IDS[1], 9), basis(RESOURCE_IDS[3], 0)],
                "world": w_basic,
                "dropped": nat(0),
            },
        )
    )

    divergences_coherent: list[Any] = []
    out.append(req("reconcile", "coherent", {"divergences": divergences_coherent, "unbased": nat(0), "dropped": nat(0)}))
    divergences_incoherent = [
        {"tag": "world_ahead", "resource": RESOURCE_IDS[1], "recorded": nat(0), "actual": nat(1)}
    ]
    out.append(req("reconcile", "coherent", {"divergences": divergences_incoherent, "unbased": nat(0), "dropped": nat(0)}))
    out.append(req("reconcile", "coherent", {"divergences": [], "unbased": nat(1), "dropped": nat(0)}))

    def csl(resource: str, maximum: int) -> dict[str, Any]:
        return {"resource": resource, "maximum": nat(maximum)}

    def budget(p: int, i: int, c: int) -> dict[str, Any]:
        return {
            "pendingMaximum": csl("pending", p),
            "inFlightMaximum": csl("inFlight", i),
            "concurrentMaximum": csl("concurrent", c),
        }

    def identity(kind: str, provenance: str, revision: int) -> dict[str, Any]:
        return {"kind": kind, "provenance": provenance, "revision": nat(revision)}

    def footprint(reads: list[str], writes: list[str], effect_class: str) -> dict[str, Any]:
        return {"reads": reads, "writes": writes, "effectClass": effect_class}

    def demand(pending: int, in_flight: int, concurrent: int) -> dict[str, Any]:
        return {"pending": nat(pending), "inFlight": nat(in_flight), "concurrent": nat(concurrent)}

    def evidence(identifier: str, digest: str, path: str) -> dict[str, Any]:
        return {"identifier": identifier, "digest": digest, "artifactPath": path}

    ev0 = evidence("e0", "d0", "a0")

    def permitted(ident: dict[str, Any]) -> dict[str, Any]:
        return {"tag": "permitted", "identity": ident, "evidence": [ev0]}

    for policy in ("latestWins", "fifo", "allExecute"):
        out.append(req("request_progression", "empty", {"policy": policy, "budget": budget(5, 5, 5)}))

    def snapshot(policy: str, b: dict[str, Any], current: dict[str, Any] | None, entries: list[Any], revision: int) -> dict[str, Any]:
        return {"policy": policy, "budget": b, "currentIdentity": current, "entries": entries, "revision": nat(revision)}

    def request_input(ident: dict[str, Any], fp: dict[str, Any], dem: dict[str, Any], permission: dict[str, Any]) -> dict[str, Any]:
        return {"identity": ident, "footprint": fp, "demand": dem, "permission": permission}

    ident_a = identity("k", "prov-a", 0)
    ident_b = identity("k", "prov-b", 0)
    snap_empty = snapshot("fifo", budget(3, 3, 3), None, [], 0)

    out.append(
        req(
            "request_progression",
            "submit",
            {
                "snapshot": snap_empty,
                "request": request_input(ident_a, footprint(["r0"], [], "pure"), demand(0, 0, 0), permitted(ident_a)),
            },
        )
    )

    def entry(
        ident: dict[str, Any],
        fp: dict[str, Any],
        dem: dict[str, Any],
        phase: str,
        permission: dict[str, Any],
        cost_selection: dict[str, Any] | None,
        handle: str | None,
    ) -> dict[str, Any]:
        return {
            "identity": ident,
            "footprint": fp,
            "demand": dem,
            "phase": phase,
            "meaningPermission": permission,
            "costSelection": cost_selection,
            "executionHandle": handle,
        }

    entry_pending_a = entry(
        ident_a, footprint(["r0"], [], "pure"), demand(1, 0, 0), "pending", permitted(ident_a), None, None
    )
    snap_one_pending = snapshot("fifo", budget(1, 1, 1), None, [entry_pending_a], 1)
    out.append(
        req(
            "request_progression",
            "submit",
            {
                "snapshot": snap_one_pending,
                "request": request_input(ident_b, footprint(["r0"], [], "pure"), demand(1, 0, 0), permitted(ident_b)),
            },
        )
    )

    def cost_selection(tag: str, ident: dict[str, Any], ev: dict[str, Any], cost: int) -> dict[str, Any]:
        return {"tag": tag, "identity": ident, "evidence": ev, "cost": nat(cost)}

    def adapter_signal_started(ident: dict[str, Any], handle: str) -> dict[str, Any]:
        return {"tag": "started", "identity": ident, "handle": handle}

    def adapter_signal_completed(ident: dict[str, Any], handle: str, value: Any) -> dict[str, Any]:
        return {"tag": "completed", "identity": ident, "handle": handle, "value": value}

    def adapter_result_signal(signal: dict[str, Any]) -> dict[str, Any]:
        return {"tag": "appliedSignal", "signal": signal}

    def adapter_result_failure(failure: dict[str, Any]) -> dict[str, Any]:
        return {"tag": "adapterFailed", "failure": failure}

    def accepted(ident: dict[str, Any]) -> dict[str, Any]:
        return {"identity": ident}

    def running(ident: dict[str, Any], handle: str) -> dict[str, Any]:
        return {"identity": ident, "handle": handle}

    snap_start_ok = snapshot("fifo", budget(5, 5, 5), None, [entry_pending_a], 1)
    out.append(
        req(
            "request_progression",
            "decideStart",
            {
                "snapshot": snap_start_ok,
                "accepted": accepted(ident_a),
                "selection": cost_selection("executeNow", ident_a, ev0, 1),
            },
        )
    )
    out.append(
        req(
            "request_progression",
            "decideStart",
            {
                "snapshot": snap_empty,
                "accepted": accepted(ident_a),
                "selection": cost_selection("executeNow", ident_a, ev0, 1),
            },
        )
    )

    starting_a = {
        "identity": ident_a,
        "command": {"tag": "startCommand", "identity": ident_a, "footprint": footprint(["r0"], [], "pure")},
    }
    out.append(
        req(
            "request_progression",
            "applyStartObservation",
            {
                "snapshot": snap_start_ok,
                "starting": starting_a,
                "observed": adapter_result_signal(adapter_signal_started(ident_a, "h0")),
            },
        )
    )
    out.append(
        req(
            "request_progression",
            "applyStartObservation",
            {
                "snapshot": snap_start_ok,
                "starting": starting_a,
                "observed": adapter_result_failure(
                    {"tag": "startAdapterFailure", "identity": ident_a, "detail": "boom"}
                ),
            },
        )
    )

    entry_publishing_a = entry(
        ident_a, footprint(["r0"], [], "pure"), demand(0, 1, 1), "publishing", permitted(ident_a), None, "h0"
    )
    snap_running = snapshot("fifo", budget(5, 5, 5), None, [entry_publishing_a], 2)
    out.append(
        req(
            "request_progression",
            "applyCompletionObservation",
            {
                "snapshot": snap_running,
                "running": running(ident_a, "h0"),
                "observed": adapter_result_signal(adapter_signal_completed(ident_a, "h0", "value0")),
            },
        )
    )
    out.append(
        req(
            "request_progression",
            "applyCompletionObservation",
            {
                "snapshot": snap_running,
                "running": running(ident_a, "h0"),
                "observed": adapter_result_failure(
                    {"tag": "completionAdapterFailure", "identity": ident_a, "handle": "h0", "detail": "boom"}
                ),
            },
        )
    )
    out.append(
        req(
            "request_progression",
            "applyCompletionObservation",
            {
                "snapshot": snap_empty,
                "running": running(ident_a, "h0"),
                "observed": adapter_result_signal(adapter_signal_completed(ident_a, "h0", "value0")),
            },
        )
    )

    out.append(req("request_progression", "decideCancel", {"snapshot": snap_running, "identity": ident_a}))
    out.append(req("request_progression", "decideCancel", {"snapshot": snap_empty, "identity": ident_a}))

    for name in ("derivePending", "deriveInFlight", "deriveConcurrent"):
        out.append(req("request_progression", name, {"snapshot": snap_running}))
        out.append(req("request_progression", name, {"snapshot": snap_empty}))

    def environment_specification(max_age: int) -> dict[str, Any]:
        return {"maxObservationAge": nat(max_age)}

    def capacity_obs(observed: dict[str, Any], observed_at: int) -> dict[str, Any]:
        return {"observed": observed, "observedAt": nat(observed_at)}

    def admission_provenance(future_uses: list[Any], outstanding: list[Any]) -> dict[str, Any]:
        return {"futureUses": future_uses, "outstandingSignals": outstanding}

    def admission_state(progression: dict[str, Any], limit: dict[str, Any], provenance: dict[str, Any]) -> dict[str, Any]:
        return {"progression": progression, "configuredSafetyLimit": limit, "provenance": provenance}

    state_clean = admission_state(snap_empty, budget(5, 5, 5), admission_provenance([], []))
    out.append(req("dynamic_admission", "elideAdmissionProvenance", {"state": state_clean, "identity": ident_a}))

    state_retained = admission_state(snap_empty, budget(5, 5, 5), admission_provenance([ident_b], []))
    out.append(req("dynamic_admission", "elideAdmissionProvenance", {"state": state_retained, "identity": ident_a}))

    admission_input_submit = {
        "state": state_clean,
        "request": request_input(ident_a, footprint(["r0"], [], "pure"), demand(0, 0, 0), permitted(ident_a)),
        "environmentSpecification": environment_specification(100),
        "capacityObservation": capacity_obs(budget(5, 5, 5), 10),
        "observedAt": nat(10),
        "start": None,
    }
    out.append(req("dynamic_admission", "admitDynamicRequest", admission_input_submit))

    admission_input_stale = {
        "state": state_clean,
        "request": request_input(ident_a, footprint(["r0"], [], "pure"), demand(0, 0, 0), permitted(ident_a)),
        "environmentSpecification": environment_specification(1),
        "capacityObservation": capacity_obs(budget(5, 5, 5), 0),
        "observedAt": nat(1000),
        "start": None,
    }
    out.append(req("dynamic_admission", "admitDynamicRequest", admission_input_stale))

    admission_input_start = {
        "state": admission_state(snap_start_ok, budget(5, 5, 5), admission_provenance([], [])),
        "request": request_input(ident_a, footprint(["r0"], [], "pure"), demand(0, 0, 0), permitted(ident_a)),
        "environmentSpecification": environment_specification(100),
        "capacityObservation": capacity_obs(budget(5, 5, 5), 10),
        "observedAt": nat(10),
        "start": cost_selection("executeNow", ident_a, ev0, 1),
    }
    out.append(req("dynamic_admission", "admitDynamicRequest", admission_input_start))

    def advance_consume(outputs: list[Any]) -> dict[str, Any]:
        return {"mode": "consumeImmediately", "outputs": outputs}

    def advance_reprocess(outputs: list[Any]) -> dict[str, Any]:
        return {"mode": "reprocessAlways", "outputs": outputs}

    def advance_consume_after(rounds: int, outputs: list[Any]) -> dict[str, Any]:
        return {"mode": "consumeAfter", "rounds": nat(rounds), "outputsPerRound": outputs}

    def step_input(state: Any, inp: Any, advance: dict[str, Any], limit: int, capacity: int) -> dict[str, Any]:
        return {"state": state, "input": inp, "advance": advance, "limit": nat(limit), "capacity": nat(capacity)}

    out.append(req("step_transition", "step", step_input({}, "x", advance_consume(["o0", "o1"]), 5, 5)))
    out.append(req("step_transition", "step", step_input({}, "x", advance_consume([]), 5, 5)))
    out.append(req("step_transition", "step", step_input({}, "x", advance_reprocess(["o0"]), 1, 5)))
    out.append(req("step_transition", "step", step_input({}, "x", advance_consume_after(3, ["o0"]), 5, 5)))
    out.append(req("step_transition", "step", step_input({}, "x", advance_reprocess(["o0", "o1", "o2"]), 5, 2)))

    def npath(root: bool, segments: list[str]) -> dict[str, Any]:
        return {"root": root, "segments": segments}

    def file_record(d: str, byte_values: list[int]) -> dict[str, Any]:
        return {"digest": d, "bytes": [nat(b) for b in byte_values]}

    def digests(entries: list[tuple[dict[str, str], str]]) -> list[dict[str, Any]]:
        return [{"resource": r, "digest": d} for r, d in entries]

    def external_state(
        files: list[tuple[dict[str, Any], dict[str, Any]]],
        read_failures: list[dict[str, Any]],
        write_failures: list[dict[str, Any]],
    ) -> dict[str, Any]:
        return {
            "files": [{"path": p, "record": r} for p, r in files],
            "readFailures": read_failures,
            "writeFailures": write_failures,
        }

    out.append(req("file_effect", "normalizePath", {"root": True, "raw": ["a", ".", "..", "b", ""]}))
    out.append(req("file_effect", "normalizePath", {"root": False, "raw": ["..", "..", "x"]}))

    digs = digests([(RESOURCE_IDS[1], "digest-0")])
    out.append(req("file_effect", "lookupDigest", {"digests": digs, "resource": RESOURCE_IDS[1]}))
    out.append(req("file_effect", "lookupDigest", {"digests": digs, "resource": RESOURCE_IDS[3]}))

    out.append(req("file_effect", "setDigest", {"digests": digs, "resource": RESOURCE_IDS[1], "digest": "digest-1"}))
    out.append(req("file_effect", "setDigest", {"digests": [], "resource": RESOURCE_IDS[2], "digest": "digest-2"}))

    path_a = npath(True, ["a", "b"])
    out.append(req("file_effect", "track", {"path": path_a, "world": w_empty, "observedAt": nat(1)}))
    out.append(req("file_effect", "track", {"path": path_a, "world": w_basic, "observedAt": nat(2)}))

    file_resource = rid("file", "/a/b")
    fr0 = file_record("digest-file-0", [0, 1, 255])
    state_with_file = external_state([(path_a, fr0)], [], [])
    state_read_failure = external_state([(path_a, fr0)], [path_a], [])

    out.append(
        req(
            "file_effect",
            "read",
            {"path": path_a, "world": world([(file_resource, 0)]), "digests": [], "state": state_with_file, "observedAt": nat(3)},
        )
    )
    out.append(
        req(
            "file_effect",
            "read",
            {"path": path_a, "world": w_empty, "digests": [], "state": external_state([], [], []), "observedAt": nat(3)},
        )
    )
    out.append(
        req(
            "file_effect",
            "read",
            {"path": path_a, "world": world([(file_resource, 0)]), "digests": [], "state": state_read_failure, "observedAt": nat(3)},
        )
    )

    def replace_contents(new_contents: list[int], new_digest: str) -> dict[str, Any]:
        return {"newContents": [nat(b) for b in new_contents], "newDigest": new_digest}

    replace_digs = digests([(file_resource, "digest-file-0")])
    out.append(
        req(
            "file_effect",
            "replace",
            {
                "intent": replace_contents([9, 9], "digest-file-1"),
                "basis": basis(file_resource, 0),
                "path": path_a,
                "world": world([(file_resource, 0)]),
                "digests": replace_digs,
                "state": state_with_file,
                "observedAt": nat(4),
            },
        )
    )
    out.append(
        req(
            "file_effect",
            "replace",
            {
                "intent": replace_contents([9, 9], "digest-file-1"),
                "basis": basis(file_resource, 0),
                "path": npath(True, ["different"]),
                "world": world([(file_resource, 0)]),
                "digests": replace_digs,
                "state": state_with_file,
                "observedAt": nat(4),
            },
        )
    )
    out.append(
        req(
            "file_effect",
            "replace",
            {
                "intent": replace_contents([9, 9], "digest-file-1"),
                "basis": basis(file_resource, 0),
                "path": path_a,
                "world": world([(file_resource, 0)]),
                "digests": [],
                "state": state_with_file,
                "observedAt": nat(4),
            },
        )
    )
    out.append(
        req(
            "file_effect",
            "replace",
            {
                "intent": replace_contents([9, 9], "digest-file-1"),
                "basis": basis(file_resource, 5),
                "path": path_a,
                "world": world([(file_resource, 0)]),
                "digests": replace_digs,
                "state": state_with_file,
                "observedAt": nat(4),
            },
        )
    )
    stale_digs = digests([(file_resource, "digest-mismatch")])
    out.append(
        req(
            "file_effect",
            "replace",
            {
                "intent": replace_contents([9, 9], "digest-file-1"),
                "basis": basis(file_resource, 0),
                "path": path_a,
                "world": world([(file_resource, 0)]),
                "digests": stale_digs,
                "state": state_with_file,
                "observedAt": nat(4),
            },
        )
    )
    out.append(
        req(
            "file_effect",
            "replace",
            {
                "intent": replace_contents([9, 9], "digest-file-1"),
                "basis": basis(file_resource, 0),
                "path": path_a,
                "world": world([(file_resource, 0)]),
                "digests": replace_digs,
                "state": external_state([(path_a, fr0)], [], [path_a]),
                "observedAt": nat(4),
            },
        )
    )

    return out


def replace_input(seed: Req, input_: Any) -> Req:
    return req(seed["feature"], seed["operation"], input_)


def build_requests() -> list[Req]:
    seeds = build_seed_requests()
    out = list(seeds)
    lookup = next(s for s in seeds if (s["feature"], s["operation"]) == ("core", "lookup"))
    command_seed = next(s for s in seeds if (s["feature"], s["operation"]) == ("core", "commandOf"))
    apply_seed = next(s for s in seeds if (s["feature"], s["operation"]) == ("core", "apply"))

    for index, (number, resource) in enumerate(zip_cycle(NONNEG_INTS, RESOURCE_IDS)):
        out.append(replace_input(lookup, {"world": world([(resource, number)]), "resource": resource}))
        out.append(replace_input(command_seed, {"observation": observation(PAYLOADS[index % len(PAYLOADS)], basis(resource, number), number), "payload": PAYLOADS[(index + 1) % len(PAYLOADS)]}))
        out.append(replace_input(apply_seed, {"world": world([(resource, number)]), "command": command("generated", basis(resource, number))}))


    for size in range(5):
        entries = [(RESOURCE_IDS[i], NONNEG_INTS[i]) for i in range(size)]
        for ordered in permutations_upto4(entries):
            out.append(replace_input(lookup, {"world": world(list(ordered)), "resource": RESOURCE_IDS[0]}))

    admission_seed = next(s for s in seeds if (s["feature"], s["operation"]) == ("dynamic_admission", "admitDynamicRequest"))
    for observed_at, age in zip_cycle(NONNEG_INTS, NONNEG_INTS[1:] + NONNEG_INTS[:1]):
        value = json.loads(json.dumps(admission_seed["input"]))
        value["environmentSpecification"]["maxObservationAge"] = nat(age)
        value["capacityObservation"]["observedAt"] = nat(observed_at)
        value["observedAt"] = nat(observed_at + age)
        out.append(replace_input(admission_seed, value))
    return out


def contiguous_request_chunks(requests: list[Req]) -> list[tuple[int, list[Req]]]:
    return [
        (start, requests[start:start + DIFFERENTIAL_CHUNK_SIZE])
        for start in range(0, len(requests), DIFFERENTIAL_CHUNK_SIZE)
    ]


def coverage_failure(message: str, input_: Any) -> None:
    print(json.dumps({"kind": "generator_coverage_failure", "message": message, "generated_input": input_}, ensure_ascii=False, indent=2), file=sys.stderr)
    raise SystemExit(1)


def check_all_operations_covered(requests: list[Req]) -> None:
    covered = {(r["feature"], r["operation"]) for r in requests}
    missing = [op for op in ALL_OPERATIONS if op not in covered]
    if missing:
        coverage_failure("operation not generated", missing)


def check_domain_coverage(requests: list[Req]) -> None:
    text = json.dumps(requests, ensure_ascii=False, sort_keys=True)
    for number in NONNEG_INTS:
        if nat(number) not in text:
            coverage_failure("integer not generated", number)
    for resource in RESOURCE_IDS:
        if json.dumps(resource, ensure_ascii=False, sort_keys=True) not in text:
            coverage_failure("resource not generated", resource)
    for payload in PAYLOADS:
        if json.dumps(payload, ensure_ascii=False) not in text:
            coverage_failure("payload not generated", payload)


def build_invalid_queries() -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []

    out.append({"__raw__": "{not json", "expected_kind": "json_syntax"})
    out.append({"__raw__": "", "expected_kind": "json_syntax"})

    out.append({"query": {}, "expected_kind": "query_shape"})
    out.append({"query": {"kind": "bogus"}, "expected_kind": "query_shape"})
    out.append({"query": {"kind": "evaluate"}, "expected_kind": "query_shape"})
    out.append({"query": {"kind": "evaluate", "requests": "not-array"}, "expected_kind": "query_shape"})

    out.append(
        {
            "query": {"kind": "evaluate", "requests": [req("no_such_feature", "op", {})]},
            "expected_kind": "unknown_feature",
        }
    )
    out.append(
        {
            "query": {"kind": "evaluate", "requests": [req("core", "no_such_op", {})]},
            "expected_kind": "unknown_operation",
        }
    )

    fold_step = immediate_decl("invalid.fold.step", ["n"], form_get_field("n"))
    out.append(
        {
            "query": {
                "kind": "evaluate",
                "requests": [req("iteration", "fold", {
                    "step": fold_step,
                    "seed": {"n": 0},
                    "count": "-1",
                    "stepFields": ["n"],
                })],
            },
            "expected_kind": "input_shape",
        }
    )
    out.append(
        {
            "query": {
                "kind": "evaluate",
                "requests": [req("iteration", "recurse", {
                    "required": [],
                    "table": [{"payload": 1, "outcome": {"tag": "advance", "measure": "-1"}}],
                    "next": form_const(0),
                    "seed": 1,
                    "stepFields": [],
                })],
            },
            "expected_kind": "input_shape",
        }
    )

    for bad in INVALID_INTS:
        out.append(
            {
                "query": {
                    "kind": "evaluate",
                    "requests": [req("core", "lookup", {"world": [], "resource": {"kind": "res", "name": "x"}})],
                },
                "corrupt_revision": bad,
                "expected_kind": "input_shape",
            }
        )
    out.append(
        {
            "query": {"kind": "evaluate", "requests": [req("core", "lookup", {"world": []})]},
            "expected_kind": "input_shape",
        }
    )
    out.append(
        {
            "query": {"kind": "evaluate", "requests": [req("core", "lookup", {"world": "not-array", "resource": RESOURCE_IDS[1]})]},
            "expected_kind": "input_shape",
        }
    )

    return out


def render_invalid_query(entry: dict[str, Any]) -> str:
    if "__raw__" in entry:
        return entry["__raw__"]
    query = json.loads(json.dumps(entry["query"]))
    if "corrupt_revision" in entry:
        query["requests"][0]["input"] = {
            "world": [{"resource": {"kind": "res", "name": "x"}, "revision": entry["corrupt_revision"]}],
            "resource": {"kind": "res", "name": "x"},
        }
    return json.dumps(query)



def json_canon(value: Any) -> Any:
    if isinstance(value, dict):
        return {k: json_canon(v) for k, v in sorted(value.items())}
    if isinstance(value, list):
        return [json_canon(v) for v in value]
    return value
