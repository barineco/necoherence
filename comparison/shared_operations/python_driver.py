# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Stdin inspection adapter, for testing only.

Reads one generated query from stdin, evaluates it against
``necoherence``'s public computable definitions, and writes one normalized
JSON result to stdout. Mirrors ``lean_driver/FeatureCheck.lean``'s protocol
exactly.

Protocol:
- ``{"kind":"surface"}`` -> ``{"kind":"surface","features":[...]}``, the
  finite feature/operation inventory in a fixed order.
- ``{"kind":"evaluate","requests":[{"feature":..,"operation":..,"input":..},...]}``
  -> ``{"kind":"results","results":[{"feature":..,"operation":..,"result":..},...]}``
  in input order.
- Any JSON syntax failure, unrecognized query shape, unknown feature or
  operation, or per-request input shape failure closes the whole reply as
  ``{"kind":"invalid","failure":{"kind":"...","detail":"..."}}``. Logical
  domain failures (rejected, conflicted, boundary-failed, and the like) are
  carried inside a request's own ``result`` value instead.
- Every operation named on the surface evaluates the matching necoherence
  definition; the dispatcher has no unimplemented branch for a known
  feature/operation pair.

Non-negative integers are exchanged as decimal-digit JSON strings. Negative
signs, decimal points, non-decimal characters, and the empty string are all
input-shape failures.

This module is a test-only inspection surface. It is not part of the
package's public export.
"""

from __future__ import annotations

import importlib
import json
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "python" / "src"))

# Bypass the root export, which shadows some submodule names with functions.
_call = importlib.import_module("necoherence.call")
_core = importlib.import_module("necoherence.core")
_admission = importlib.import_module("necoherence.dynamic_admission")
_files = importlib.import_module("necoherence.files")
_iteration = importlib.import_module("necoherence.iteration")
_reconcile = importlib.import_module("necoherence.reconcile")
_record = importlib.import_module("necoherence.record")
_rp = importlib.import_module("necoherence.request_progression")
_store = importlib.import_module("necoherence.store")
_transition = importlib.import_module("necoherence.transition")


class DecodeFailure(Exception):
    def __init__(self, kind: str, detail: str) -> None:
        super().__init__(detail)
        self.kind = kind
        self.detail = detail


def fail_shape(detail: str) -> DecodeFailure:
    return DecodeFailure("input_shape", detail)


# --- JSON accessors ---------------------------------------------------------


def obj_val(j: Any, k: str) -> Any:
    if not isinstance(j, dict) or k not in j:
        raise fail_shape(f"missing field {k}")
    return j[k]


def as_str(j: Any) -> str:
    if not isinstance(j, str):
        raise fail_shape("expected string")
    return j


def as_arr(j: Any) -> list[Any]:
    if not isinstance(j, list):
        raise fail_shape("expected array")
    return j


def nat_of_str(s: str) -> int:
    if s == "":
        raise fail_shape("empty integer")
    if not s.isdigit():
        raise fail_shape("invalid integer")
    return int(s)


def nat_field(j: Any, k: str) -> int:
    return nat_of_str(as_str(obj_val(j, k)))


def str_field(j: Any, k: str) -> str:
    return as_str(obj_val(j, k))


def arr_field(j: Any, k: str) -> list[Any]:
    return as_arr(obj_val(j, k))


def opt_field(j: Any, k: str) -> Any:
    v = obj_val(j, k)
    return None if v is None else v


def nat_to_json(n: int) -> str:
    return str(n)


# --- Core encoders/decoders --------------------------------------------------


def decode_resource_id(j: Any) -> _core.ResourceId:
    return _core.ResourceId(kind=str_field(j, "kind"), name=str_field(j, "name"))


def encode_resource_id(r: _core.ResourceId) -> dict[str, Any]:
    return {"kind": r.kind, "name": r.name}


def decode_revision(j: Any) -> _core.Revision:
    return _core.Revision(nat_of_str(as_str(j)))


def encode_revision(r: _core.Revision) -> str:
    return nat_to_json(r.value)


def decode_basis(j: Any) -> _core.Basis:
    return _core.Basis(
        resource=decode_resource_id(obj_val(j, "resource")),
        revision=decode_revision(obj_val(j, "revision")),
    )


def encode_basis(b: _core.Basis) -> dict[str, Any]:
    return {"resource": encode_resource_id(b.resource), "revision": encode_revision(b.revision)}


def decode_world(j: Any) -> _core.World:
    arr = as_arr(j)
    entries = tuple(
        (decode_resource_id(obj_val(e, "resource")), decode_revision(obj_val(e, "revision")))
        for e in arr
    )
    return _core.World(entries)


def encode_world_entry(p: tuple[_core.ResourceId, _core.Revision]) -> dict[str, Any]:
    return {"resource": encode_resource_id(p[0]), "revision": encode_revision(p[1])}


def encode_world(w: _core.World) -> list[Any]:
    return [encode_world_entry(e) for e in w.entries]


def encode_lookup(lookup: _core.Revision | _core.UnknownResource) -> dict[str, Any]:
    if isinstance(lookup, _core.UnknownResource):
        return {"tag": "unknown", "resource": encode_resource_id(lookup.resource)}
    return {"tag": "found", "revision": encode_revision(lookup)}


def decode_command(j: Any) -> _core.Command[Any]:
    return _core.Command(intent=obj_val(j, "intent"), basis=decode_basis(obj_val(j, "basis")))


def encode_command(c: _core.Command[Any]) -> dict[str, Any]:
    return {"intent": c.intent, "basis": encode_basis(c.basis)}


def encode_apply_outcome(o: Any) -> dict[str, Any]:
    if isinstance(o, _core.Applied):
        intent, world = o.value
        return {"tag": "applied", "intent": intent, "world": encode_world(world)}
    if isinstance(o, _core.Rejected):
        return {"tag": "rejected", "resource": encode_resource_id(o.reason.resource)}
    if isinstance(o, _core.Conflicted):
        return {
            "tag": "conflicted",
            "expected": encode_revision(o.conflict.expected),
            "actual": encode_revision(o.conflict.actual),
        }
    raise AssertionError("apply never boundary-fails")


# --- Core operations ---------------------------------------------------------


def op_core_lookup(input: Any) -> Any:
    world = decode_world(obj_val(input, "world"))
    resource = decode_resource_id(obj_val(input, "resource"))
    return encode_lookup(_core.lookup(world, resource))


def op_core_bump(input: Any) -> Any:
    world = decode_world(obj_val(input, "world"))
    resource = decode_resource_id(obj_val(input, "resource"))
    return encode_world(_core.bump(world, resource))


def op_core_command_of(input: Any) -> Any:
    obs_j = obj_val(input, "observation")
    payload = obj_val(obs_j, "payload")
    basis = decode_basis(obj_val(obs_j, "basis"))
    observed_at = nat_field(obs_j, "observedAt")
    o = _core.Observation(payload=payload, basis=basis, observed_at=observed_at)
    x = obj_val(input, "payload")
    return encode_command(_core.command_of(o, x))


def op_core_apply(input: Any) -> Any:
    world = decode_world(obj_val(input, "world"))
    command = decode_command(obj_val(input, "command"))
    return encode_apply_outcome(_core.apply(world, command))


# --- Call encoders/decoders --------------------------------------------------


def decode_function_form(j: Any) -> Any:
    kind = str_field(j, "kind")
    if kind == "identity":
        return ("identity",)
    if kind == "const":
        return ("const", obj_val(j, "value"))
    if kind == "getField":
        return ("getField", str_field(j, "name"))
    if kind == "setField":
        return ("setField", str_field(j, "name"), obj_val(j, "value"))
    if kind == "wrap":
        return ("wrap", str_field(j, "tag"))
    raise fail_shape(f"unknown function form kind {kind}")


def apply_function_form(form: tuple[Any, ...], x: Any) -> Any:
    tag = form[0]
    if tag == "identity":
        return x
    if tag == "const":
        return form[1]
    if tag == "getField":
        return x.get(form[1]) if isinstance(x, dict) else None
    if tag == "setField":
        base = dict(x) if isinstance(x, dict) else {}
        base[form[1]] = form[2]
        return base
    if tag == "wrap":
        return {"tag": form[1], "value": x}
    raise AssertionError("unreachable function form")


def decode_request(j: Any) -> _call.Request[Any]:
    payload = obj_val(j, "payload")
    fields = tuple(as_str(f) for f in arr_field(j, "fields"))
    return _call.Request(payload=payload, fields=fields)


def decode_immediate(j: Any) -> _call.Immediate[Any, Any]:
    identity = str_field(j, "identity")
    required = tuple(as_str(f) for f in arr_field(j, "required"))
    form = decode_function_form(obj_val(j, "output"))
    return _call.immediate_of(identity, required, lambda x: apply_function_form(form, x))


def decode_deferred(j: Any) -> _call.Deferred[Any, Any]:
    identity = str_field(j, "identity")
    required = tuple(as_str(f) for f in arr_field(j, "required"))
    form = decode_function_form(obj_val(j, "output"))
    return _call.deferred_of(identity, required, lambda x: apply_function_form(form, x))


def encode_call_result(r: _call.CallResult[Any]) -> dict[str, Any]:
    if isinstance(r, _call.CallFailed):
        return {
            "tag": "failed",
            "declaration": r.failure.declaration,
            "fields": list(r.failure.fields),
        }
    return {"tag": "ok", "value": r.value}


# --- Call operations ----------------------------------------------------


def op_call_immediate_of(input: Any) -> Any:
    decl = decode_immediate(input)
    return {"identity": decl.identity, "required": list(decl.required)}


def op_call_deferred_of(input: Any) -> Any:
    decl = decode_deferred(input)
    return {"identity": decl.identity, "required": list(decl.required)}


def op_call_io(input: Any) -> Any:
    decl = decode_immediate(obj_val(input, "declaration"))
    req = decode_request(obj_val(input, "request"))
    return encode_call_result(_call.io(decl, req))


def op_call_issue(input: Any) -> Any:
    decl = decode_deferred(obj_val(input, "declaration"))
    req = decode_request(obj_val(input, "request"))
    return encode_call_result(_call.issue(decl, req))


# --- Step transition encoders/decoders --------------------------------------


def decode_advance_form(j: Any) -> Any:
    mode = str_field(j, "mode")
    if mode == "consumeImmediately":
        return ("consumeImmediately", arr_field(j, "outputs"))
    if mode == "reprocessAlways":
        return ("reprocessAlways", arr_field(j, "outputs"))
    if mode == "consumeAfter":
        rounds = nat_field(j, "rounds")
        outputs = arr_field(j, "outputsPerRound")
        return ("consumeAfter", rounds, outputs)
    raise fail_shape(f"unknown advance mode {mode}")


def round_of(state: Any) -> int:
    if isinstance(state, dict) and isinstance(state.get("round"), str) and state["round"].isdigit():
        return int(state["round"])
    return 0


def state_with_round(n: int) -> dict[str, Any]:
    return {"round": str(n)}


def advance_eval(form: tuple[Any, ...], state: Any, _input: Any) -> Any:
    tag = form[0]
    if tag == "consumeImmediately":
        return _transition.Consumed(state=state, outputs=tuple(form[1]))
    if tag == "reprocessAlways":
        return _transition.Reprocess(state=state, outputs=tuple(form[1]))
    if tag == "consumeAfter":
        rounds, outputs = form[1], form[2]
        r = round_of(state) + 1
        new_state = state_with_round(r)
        if r >= rounds:
            return _transition.Consumed(state=new_state, outputs=tuple(outputs))
        return _transition.Reprocess(state=new_state, outputs=tuple(outputs))
    raise AssertionError("unreachable advance form")


def encode_step_failure(f: Any) -> dict[str, Any]:
    if isinstance(f, _transition.ReprocessLimitExhausted):
        return {"tag": "reprocess_limit_exhausted", "applications": nat_to_json(f.applications)}
    return {
        "tag": "capacity_exceeded",
        "capacity": nat_to_json(f.capacity),
        "attempted": nat_to_json(f.attempted),
    }


def encode_step_transition(r: Any) -> dict[str, Any]:
    if isinstance(r, _transition.StepSettled):
        return {
            "tag": "settled",
            "state": r.state,
            "outputs": list(r.outputs),
            "applications": nat_to_json(r.applications),
        }
    return {
        "tag": "failed",
        "state": r.state,
        "outputs": list(r.outputs),
        "failure": encode_step_failure(r.failure),
    }


# --- Step transition operation -----------------------------------------


def op_step_transition_step(input: Any) -> Any:
    state = obj_val(input, "state")
    inp = obj_val(input, "input")
    form = decode_advance_form(obj_val(input, "advance"))
    limit_n = nat_field(input, "limit")
    capacity_n = nat_field(input, "capacity")
    if limit_n <= 0:
        raise fail_shape("limit must be positive")
    limit = _transition.PositiveLimit(limit_n)
    capacity = _transition.Capacity(capacity_n)
    return encode_step_transition(
        _transition.step(state, inp, lambda s, i: advance_eval(form, s, i), limit, capacity)
    )


# --- Iteration encoders/decoders --------------------------------------------


def encode_stage_projection_failed(s: _iteration.StageProjectionFailed) -> dict[str, Any]:
    return {
        "position": nat_to_json(s.position),
        "declaration": s.failure.declaration,
        "fields": list(s.failure.fields),
    }


def decode_fold_req(j: Any) -> _iteration.FoldReq[Any]:
    step = decode_immediate(obj_val(j, "step"))
    seed = obj_val(j, "seed")
    count = nat_field(j, "count")
    step_fields = tuple(as_str(f) for f in arr_field(j, "stepFields"))
    return _iteration.FoldReq(step=step, seed=seed, count=count, step_fields=step_fields)


def encode_fold_outcome(o: Any) -> dict[str, Any]:
    if isinstance(o, _iteration.FoldTrace):
        return {"tag": "trace", "states": list(o.states)}
    return {
        "tag": "stopped",
        "states": list(o.states),
        "stopped": encode_stage_projection_failed(o.stopped),
    }


def decode_step_outcome_form(j: Any) -> Any:
    tag = str_field(j, "tag")
    if tag == "settled":
        return ("settled",)
    if tag == "advance":
        return ("advance", nat_field(j, "measure"))
    raise fail_shape(f"unknown step outcome tag {tag}")


def decode_recurse_table(j: Any) -> list[tuple[Any, Any]]:
    arr = as_arr(j)
    return [(obj_val(e, "payload"), decode_step_outcome_form(obj_val(e, "outcome"))) for e in arr]


def _json_eq(a: Any, b: Any) -> bool:
    return a == b


def recurse_step_output(
    table: list[tuple[Any, Any]], next_of: Any, state: Any
) -> _iteration.StepOutcome[Any]:
    for payload, form in table:
        if _json_eq(payload, state):
            if form[0] == "settled":
                return _iteration.Settled(state=state)
            return _iteration.Continue(state=next_of(state), measure=form[1])
    return _iteration.Settled(state=state)


def decode_recurse_req(j: Any) -> _iteration.RecurseReq[Any]:
    required = tuple(as_str(f) for f in arr_field(j, "required"))
    table = decode_recurse_table(obj_val(j, "table"))
    next_form = decode_function_form(obj_val(j, "next"))
    seed = obj_val(j, "seed")
    step_fields = tuple(as_str(f) for f in arr_field(j, "stepFields"))
    identity = "necoherence.iteration.recurse.adapter.step"
    step = _call.immediate_of(
        identity,
        required,
        lambda state: recurse_step_output(
            table, lambda x: apply_function_form(next_form, x), state
        ),
    )
    return _iteration.RecurseReq(step=step, seed=seed, step_fields=step_fields)


def encode_recurse_outcome(o: Any) -> dict[str, Any]:
    if isinstance(o, _iteration.RecurseSettled):
        return {"tag": "settled", "value": o.value, "steps": nat_to_json(o.steps)}
    if isinstance(o, _iteration.RecurseDidNotDecrease):
        return {
            "tag": "did_not_decrease",
            "position": nat_to_json(o.position),
            "state": o.state,
            "measure": nat_to_json(o.measure),
            "previousMeasure": nat_to_json(o.previous_measure),
        }
    return {
        "tag": "projection_failed",
        "lastState": o.last_state,
        "stopped": encode_stage_projection_failed(o.stopped),
    }


def _closure_elem_to_json(s: str) -> Any:
    try:
        return json.loads(s)
    except json.JSONDecodeError:
        return None


def _closure_elem_of_json(j: Any) -> str:
    return json.dumps(j, separators=(",", ":"), sort_keys=True)


def _json_elements(j: Any) -> list[Any]:
    return j if isinstance(j, list) else []


def decode_closure_req(j: Any) -> _iteration.ClosureReq[str]:
    step_j = obj_val(j, "step")
    identity = str_field(step_j, "identity")
    required = tuple(as_str(f) for f in arr_field(step_j, "required"))
    form = decode_function_form(obj_val(step_j, "output"))

    def output(cs: _iteration.ClosureState[str]) -> frozenset[str]:
        elems_json = [_closure_elem_to_json(e) for e in cs.elements]
        produced_json = apply_function_form(form, elems_json)
        return frozenset(_closure_elem_of_json(e) for e in _json_elements(produced_json))

    step: _call.Immediate[_iteration.ClosureState[str], frozenset[str]] = _call.immediate_of(
        identity, required, output
    )
    carrier = frozenset(_closure_elem_of_json(e) for e in arr_field(j, "carrier"))
    seed = frozenset(_closure_elem_of_json(e) for e in arr_field(j, "seed"))
    step_fields = tuple(as_str(f) for f in arr_field(j, "stepFields"))
    return _iteration.ClosureReq(step=step, carrier=carrier, seed=seed, step_fields=step_fields)


def encode_closure_elems(elems: frozenset[str]) -> list[Any]:
    return [_closure_elem_to_json(e) for e in sorted(elems)]


def encode_closure_outcome(o: Any) -> dict[str, Any]:
    if isinstance(o, _iteration.ClosureFixpoint):
        return {
            "tag": "fixpoint",
            "result": encode_closure_elems(o.elements),
            "position": nat_to_json(o.steps),
        }
    if isinstance(o, _iteration.ClosureViolation):
        return {
            "tag": "violation",
            "position": nat_to_json(o.position),
            "current": encode_closure_elems(o.current),
            "produced": encode_closure_elems(o.produced),
        }
    return {
        "tag": "projection_failed",
        "current": encode_closure_elems(o.last),
        "stopped": encode_stage_projection_failed(o.stopped),
    }


# --- Iteration operations -----------------------------------------------


_ITERATION_FOLD_FIELDS = ("step", "seed", "count", "step_fields")
_ITERATION_RECURSE_FIELDS = ("step", "seed", "step_fields")
_ITERATION_CLOSURE_FIELDS = ("step", "carrier", "seed", "step_fields")


def op_iteration_fold(input: Any) -> Any:
    req = decode_fold_req(input)
    result = _call.io(_iteration.fold, _call.Request(payload=req, fields=_ITERATION_FOLD_FIELDS))
    assert isinstance(result, _call.CallOk)
    return encode_fold_outcome(result.value)


def op_iteration_recurse(input: Any) -> Any:
    req = decode_recurse_req(input)
    result = _call.io(
        _iteration.recurse, _call.Request(payload=req, fields=_ITERATION_RECURSE_FIELDS)
    )
    assert isinstance(result, _call.CallOk)
    return encode_recurse_outcome(result.value)


def op_iteration_closure(input: Any) -> Any:
    req = decode_closure_req(input)
    result = _call.io(
        _iteration.closure, _call.Request(payload=req, fields=_ITERATION_CLOSURE_FIELDS)
    )
    assert isinstance(result, _call.CallOk)
    return encode_closure_outcome(result.value)


# --- Store encoders/decoders -------------------------------------------


def decode_store_entry(j: Any) -> tuple[_core.ResourceId, _core.Revision, Any]:
    resource = decode_resource_id(obj_val(j, "resource"))
    revision = decode_revision(obj_val(j, "revision"))
    payload = obj_val(j, "payload")
    return resource, revision, payload


def decode_store(j: Any) -> _store.Store[Any]:
    arr = as_arr(j)
    return _store.store_of([decode_store_entry(e) for e in arr])


def encode_store_entry(e: tuple[_core.ResourceId, _core.Revision, Any]) -> dict[str, Any]:
    return {"resource": encode_resource_id(e[0]), "revision": encode_revision(e[1]), "payload": e[2]}


def encode_store(s: _store.Store[Any]) -> list[Any]:
    return [encode_store_entry(e) for e in _store.store_entries(s)]


def encode_observe(o: Any) -> dict[str, Any]:
    if isinstance(o, _store.Found):
        return {"tag": "found", "revision": encode_revision(o.revision), "payload": o.payload}
    return {"tag": "unknown", "resource": encode_resource_id(o.unknown.resource)}


def encode_store_apply_outcome(o: Any) -> dict[str, Any]:
    if isinstance(o, _core.Applied):
        intent, store = o.value
        return {"tag": "applied", "intent": intent, "store": encode_store(store)}
    if isinstance(o, _core.Rejected):
        return {"tag": "rejected", "resource": encode_resource_id(o.reason.resource)}
    return {
        "tag": "conflicted",
        "expected": encode_revision(o.conflict.expected),
        "actual": encode_revision(o.conflict.actual),
    }


# --- Store operations -----------------------------------------------------


def op_store_store_of(input: Any) -> Any:
    return encode_store(decode_store(input))


def op_store_store_entries(input: Any) -> Any:
    return encode_store(decode_store(obj_val(input, "store")))


def op_store_observe(input: Any) -> Any:
    s = decode_store(obj_val(input, "store"))
    resource = decode_resource_id(obj_val(input, "resource"))
    return encode_observe(_store.observe(s, resource))


def op_store_apply(input: Any) -> Any:
    s = decode_store(obj_val(input, "store"))
    command = decode_command(obj_val(input, "command"))
    return encode_store_apply_outcome(_store.apply(s, command))


def op_store_world_of(input: Any) -> Any:
    return encode_world(_store.world_of_store(decode_store(input)))


# --- Record encoders/decoders -----------------------------------------


def decode_call_record(j: Any) -> _record.CallRecord[Any, Any]:
    declaration = str_field(j, "declaration")
    input_ = obj_val(j, "input")
    product = obj_val(j, "product")
    basis_j = obj_val(j, "basis")
    basis: Any = _record.NoBasis() if basis_j is None else decode_basis(basis_j)
    return _record.CallRecord(declaration=declaration, input=input_, product=product, basis=basis)


def encode_call_record(r: _record.CallRecord[Any, Any]) -> dict[str, Any]:
    basis = None if isinstance(r.basis, _record.NoBasis) else encode_basis(r.basis)
    return {"declaration": r.declaration, "input": r.input, "product": r.product, "basis": basis}


# --- Record operations ------------------------------------------------


def op_record_record_of(input: Any) -> Any:
    declaration = str_field(input, "declaration")
    ins = obj_val(input, "input")
    product = obj_val(input, "product")
    return encode_call_record(_record.record_of(declaration, ins, product))


def op_record_record_on_basis(input: Any) -> Any:
    declaration = str_field(input, "declaration")
    ins = obj_val(input, "input")
    product = obj_val(input, "product")
    basis = decode_basis(obj_val(input, "basis"))
    return encode_call_record(_record.record_on_basis(declaration, ins, product, basis))


def op_record_has_edge(input: Any) -> Any:
    earlier = decode_call_record(obj_val(input, "earlier"))
    later = decode_call_record(obj_val(input, "later"))
    return {"holds": _record.has_edge(earlier, later)}


# --- Reconcile encoders/decoders ---------------------------------------


def _divergence_resource(d: Any) -> _core.ResourceId:
    return d.resource


def encode_divergence(d: Any) -> dict[str, Any]:
    if isinstance(d, _reconcile.WorldAhead):
        return {
            "tag": "world_ahead",
            "resource": encode_resource_id(d.resource),
            "recorded": encode_revision(d.recorded),
            "actual": encode_revision(d.actual),
        }
    if isinstance(d, _reconcile.WorldBehind):
        return {
            "tag": "world_behind",
            "resource": encode_resource_id(d.resource),
            "recorded": encode_revision(d.recorded),
            "actual": encode_revision(d.actual),
        }
    return {
        "tag": "unknown_to_world",
        "resource": encode_resource_id(d.resource),
        "recorded": encode_revision(d.recorded),
    }


def encode_reconciliation(r: _reconcile.Reconciliation) -> dict[str, Any]:
    sorted_divergences = sorted(
        r.divergences, key=lambda d: (_divergence_resource(d).kind, _divergence_resource(d).name)
    )
    return {
        "divergences": [encode_divergence(d) for d in sorted_divergences],
        "unbased": nat_to_json(r.unbased),
        "dropped": nat_to_json(r.dropped),
    }


def decode_option_basis(j: Any) -> _core.Basis | None:
    return None if j is None else decode_basis(j)


# --- Reconcile operations ------------------------------------------------


def op_reconcile_reconcile(input: Any) -> Any:
    bases = tuple(decode_option_basis(b) for b in arr_field(input, "bases"))
    world = decode_world(obj_val(input, "world"))
    dropped = nat_field(input, "dropped")
    return encode_reconciliation(_reconcile.reconcile(bases, world, dropped))


def op_reconcile_coherent(input: Any) -> Any:
    divergences = []
    for j in arr_field(input, "divergences"):
        tag = str_field(j, "tag")
        if tag == "world_ahead":
            divergences.append(
                _reconcile.WorldAhead(
                    resource=decode_resource_id(obj_val(j, "resource")),
                    recorded=decode_revision(obj_val(j, "recorded")),
                    actual=decode_revision(obj_val(j, "actual")),
                )
            )
        elif tag == "world_behind":
            divergences.append(
                _reconcile.WorldBehind(
                    resource=decode_resource_id(obj_val(j, "resource")),
                    recorded=decode_revision(obj_val(j, "recorded")),
                    actual=decode_revision(obj_val(j, "actual")),
                )
            )
        elif tag == "unknown_to_world":
            divergences.append(
                _reconcile.UnknownToWorld(
                    resource=decode_resource_id(obj_val(j, "resource")),
                    recorded=decode_revision(obj_val(j, "recorded")),
                )
            )
        else:
            raise fail_shape(f"unknown divergence tag {tag}")
    unbased = nat_field(input, "unbased")
    dropped = nat_field(input, "dropped")
    r = _reconcile.Reconciliation(divergences=tuple(divergences), unbased=unbased, dropped=dropped)
    return {"coherent": _reconcile.coherent(r)}


# --- Request progression encoders/decoders ----------------------------


def decode_request_policy(j: Any) -> _rp.RequestPolicy:
    s = as_str(j)
    for policy in _rp.RequestPolicy:
        if policy.value == s:
            return policy
    raise fail_shape(f"unknown policy {s}")


def encode_request_policy(p: _rp.RequestPolicy) -> str:
    return p.value


def decode_request_phase(j: Any) -> _rp.RequestPhase:
    s = as_str(j)
    for phase in _rp.RequestPhase:
        if phase.value == s:
            return phase
    raise fail_shape(f"unknown phase {s}")


def encode_request_phase(p: _rp.RequestPhase) -> str:
    return p.value


def decode_effect_class(j: Any) -> _rp.RequestEffectClass:
    s = as_str(j)
    for ec in _rp.RequestEffectClass:
        if ec.value == s:
            return ec
    raise fail_shape(f"unknown effect class {s}")


def encode_effect_class(e: _rp.RequestEffectClass) -> str:
    return e.value


def decode_request_identity(j: Any) -> _rp.RequestIdentity:
    return _rp.RequestIdentity(
        kind=str_field(j, "kind"),
        provenance=str_field(j, "provenance"),
        revision=nat_field(j, "revision"),
    )


def encode_request_identity(i: _rp.RequestIdentity) -> dict[str, Any]:
    return {"kind": i.kind, "provenance": i.provenance, "revision": nat_to_json(i.revision)}


def decode_request_footprint(j: Any) -> _rp.RequestFootprint:
    return _rp.RequestFootprint(
        reads=tuple(as_str(x) for x in arr_field(j, "reads")),
        writes=tuple(as_str(x) for x in arr_field(j, "writes")),
        effect_class=decode_effect_class(obj_val(j, "effectClass")),
    )


def encode_request_footprint(f: _rp.RequestFootprint) -> dict[str, Any]:
    return {
        "reads": list(f.reads),
        "writes": list(f.writes),
        "effectClass": encode_effect_class(f.effect_class),
    }


def decode_resource_demand(j: Any) -> _rp.ResourceDemand:
    return _rp.ResourceDemand(
        pending=nat_field(j, "pending"),
        in_flight=nat_field(j, "inFlight"),
        concurrent=nat_field(j, "concurrent"),
    )


def encode_resource_demand(d: _rp.ResourceDemand) -> dict[str, Any]:
    return {
        "pending": nat_to_json(d.pending),
        "inFlight": nat_to_json(d.in_flight),
        "concurrent": nat_to_json(d.concurrent),
    }


def decode_configured_safety_limit(j: Any) -> _rp.ConfiguredSafetyLimit:
    return _rp.ConfiguredSafetyLimit(resource=str_field(j, "resource"), maximum=nat_field(j, "maximum"))


def encode_configured_safety_limit(l: _rp.ConfiguredSafetyLimit) -> dict[str, Any]:
    return {"resource": l.resource, "maximum": nat_to_json(l.maximum)}


def decode_resource_budget(j: Any) -> _rp.ResourceBudget:
    return _rp.ResourceBudget(
        pending_maximum=decode_configured_safety_limit(obj_val(j, "pendingMaximum")),
        in_flight_maximum=decode_configured_safety_limit(obj_val(j, "inFlightMaximum")),
        concurrent_maximum=decode_configured_safety_limit(obj_val(j, "concurrentMaximum")),
    )


def encode_resource_budget(b: _rp.ResourceBudget) -> dict[str, Any]:
    return {
        "pendingMaximum": encode_configured_safety_limit(b.pending_maximum),
        "inFlightMaximum": encode_configured_safety_limit(b.in_flight_maximum),
        "concurrentMaximum": encode_configured_safety_limit(b.concurrent_maximum),
    }


def decode_evidence_version(j: Any) -> _rp.EvidenceVersion:
    return _rp.EvidenceVersion(
        identifier=str_field(j, "identifier"),
        digest=str_field(j, "digest"),
        artifact_path=str_field(j, "artifactPath"),
    )


def encode_evidence_version(e: _rp.EvidenceVersion) -> dict[str, Any]:
    return {"identifier": e.identifier, "digest": e.digest, "artifactPath": e.artifact_path}


def decode_permission_denial(j: Any) -> _rp.PermissionDenial:
    return _rp.PermissionDenial(reason=as_str(j))


def encode_permission_denial(p: _rp.PermissionDenial) -> str:
    return p.reason


def decode_meaning_permission(j: Any) -> _rp.MeaningPermission:
    tag = str_field(j, "tag")
    if tag == "permitted":
        identity = decode_request_identity(obj_val(j, "identity"))
        evidence = tuple(decode_evidence_version(e) for e in arr_field(j, "evidence"))
        return _rp.Permitted(identity, evidence)
    if tag == "ordered":
        identity = decode_request_identity(obj_val(j, "identity"))
        evidence = tuple(decode_evidence_version(e) for e in arr_field(j, "evidence"))
        return _rp.Ordered(identity, evidence)
    if tag == "denied":
        identity = decode_request_identity(obj_val(j, "identity"))
        reason = decode_permission_denial(obj_val(j, "reason"))
        return _rp.Denied(identity, reason)
    raise fail_shape(f"unknown meaning permission tag {tag}")


def encode_meaning_permission(p: _rp.MeaningPermission) -> dict[str, Any]:
    if isinstance(p, _rp.Permitted):
        return {
            "tag": "permitted",
            "identity": encode_request_identity(p.identity),
            "evidence": [encode_evidence_version(e) for e in p.evidence],
        }
    if isinstance(p, _rp.Ordered):
        return {
            "tag": "ordered",
            "identity": encode_request_identity(p.identity),
            "evidence": [encode_evidence_version(e) for e in p.evidence],
        }
    return {
        "tag": "denied",
        "identity": encode_request_identity(p.identity),
        "reason": encode_permission_denial(p.reason),
    }


def decode_execution_handle(j: Any) -> _rp.ExecutionHandle:
    return _rp.ExecutionHandle(as_str(j))


def encode_execution_handle(h: _rp.ExecutionHandle) -> str:
    return h.value


def decode_cost_selection(j: Any) -> _rp.CostSelection:
    tag = str_field(j, "tag")
    identity = decode_request_identity(obj_val(j, "identity"))
    evidence = decode_evidence_version(obj_val(j, "evidence"))
    cost = nat_field(j, "cost")
    if tag == "executeNow":
        return _rp.ExecuteNow(identity, evidence, cost)
    if tag == "remainPending":
        return _rp.RemainPending(identity, evidence, cost)
    raise fail_shape(f"unknown cost selection tag {tag}")


def encode_cost_selection(c: _rp.CostSelection) -> dict[str, Any]:
    tag = "executeNow" if isinstance(c, _rp.ExecuteNow) else "remainPending"
    return {
        "tag": tag,
        "identity": encode_request_identity(c.identity),
        "evidence": encode_evidence_version(c.evidence),
        "cost": nat_to_json(c.cost),
    }


def decode_request_entry(j: Any) -> _rp.RequestEntry:
    identity = decode_request_identity(obj_val(j, "identity"))
    footprint = decode_request_footprint(obj_val(j, "footprint"))
    demand = decode_resource_demand(obj_val(j, "demand"))
    phase = decode_request_phase(obj_val(j, "phase"))
    meaning_permission = decode_meaning_permission(obj_val(j, "meaningPermission"))
    cost_selection_j = obj_val(j, "costSelection")
    cost_selection = None if cost_selection_j is None else decode_cost_selection(cost_selection_j)
    handle_j = obj_val(j, "executionHandle")
    handle = None if handle_j is None else decode_execution_handle(handle_j)
    return _rp.RequestEntry(
        identity=identity,
        footprint=footprint,
        demand=demand,
        phase=phase,
        meaning_permission=meaning_permission,
        cost_selection=cost_selection,
        execution_handle=handle,
    )


def encode_request_entry(e: _rp.RequestEntry) -> dict[str, Any]:
    return {
        "identity": encode_request_identity(e.identity),
        "footprint": encode_request_footprint(e.footprint),
        "demand": encode_resource_demand(e.demand),
        "phase": encode_request_phase(e.phase),
        "meaningPermission": encode_meaning_permission(e.meaning_permission),
        "costSelection": None if e.cost_selection is None else encode_cost_selection(e.cost_selection),
        "executionHandle": None if e.execution_handle is None else encode_execution_handle(e.execution_handle),
    }


def decode_snapshot(j: Any) -> _rp.RequestProgressionSnapshot:
    policy = decode_request_policy(obj_val(j, "policy"))
    budget = decode_resource_budget(obj_val(j, "budget"))
    current_identity_j = obj_val(j, "currentIdentity")
    current_identity = None if current_identity_j is None else decode_request_identity(current_identity_j)
    entries = tuple(decode_request_entry(e) for e in arr_field(j, "entries"))
    revision = nat_field(j, "revision")
    return _rp.RequestProgressionSnapshot(
        policy=policy, budget=budget, current_identity=current_identity, entries=entries, revision=revision
    )


def encode_snapshot(s: _rp.RequestProgressionSnapshot) -> dict[str, Any]:
    return {
        "policy": encode_request_policy(s.policy),
        "budget": encode_resource_budget(s.budget),
        "currentIdentity": None if s.current_identity is None else encode_request_identity(s.current_identity),
        "entries": [encode_request_entry(e) for e in s.entries],
        "revision": nat_to_json(s.revision),
    }


def decode_request_input(j: Any) -> _rp.RequestInput:
    return _rp.RequestInput(
        identity=decode_request_identity(obj_val(j, "identity")),
        footprint=decode_request_footprint(obj_val(j, "footprint")),
        demand=decode_resource_demand(obj_val(j, "demand")),
        permission=decode_meaning_permission(obj_val(j, "permission")),
    )


def decode_accepted(j: Any) -> _rp.Accepted:
    return _rp.Accepted(decode_request_identity(obj_val(j, "identity")))


def encode_accepted(a: _rp.Accepted) -> dict[str, Any]:
    return {"identity": encode_request_identity(a.identity)}


def decode_starting(j: Any) -> _rp.Starting:
    return _rp.Starting(
        identity=decode_request_identity(obj_val(j, "identity")),
        command=decode_adapter_command(obj_val(j, "command")),
    )


def encode_starting(s: _rp.Starting) -> dict[str, Any]:
    return {"identity": encode_request_identity(s.identity), "command": encode_adapter_command(s.command)}


def decode_adapter_command(j: Any) -> _rp.AdapterCommand:
    tag = str_field(j, "tag")
    if tag == "startCommand":
        return _rp.StartCommand(
            identity=decode_request_identity(obj_val(j, "identity")),
            footprint=decode_request_footprint(obj_val(j, "footprint")),
        )
    if tag == "cancelCommand":
        return _rp.CancelCommand(
            identity=decode_request_identity(obj_val(j, "identity")),
            handle=decode_execution_handle(obj_val(j, "handle")),
        )
    fail(f"unknown adapter command tag {tag}")


def decode_running(j: Any) -> _rp.Running:
    return _rp.Running(
        identity=decode_request_identity(obj_val(j, "identity")),
        handle=decode_execution_handle(obj_val(j, "handle")),
    )


def encode_running(r: _rp.Running) -> dict[str, Any]:
    return {"identity": encode_request_identity(r.identity), "handle": encode_execution_handle(r.handle)}


def encode_adapter_command(c: _rp.AdapterCommand) -> dict[str, Any]:
    if isinstance(c, _rp.StartCommand):
        return {
            "tag": "startCommand",
            "identity": encode_request_identity(c.identity),
            "footprint": encode_request_footprint(c.footprint),
        }
    return {
        "tag": "cancelCommand",
        "identity": encode_request_identity(c.identity),
        "handle": encode_execution_handle(c.handle),
    }


def decode_adapter_signal(j: Any) -> _rp.AdapterSignal[Any]:
    tag = str_field(j, "tag")
    if tag == "started":
        return _rp.Started(
            identity=decode_request_identity(obj_val(j, "identity")),
            handle=decode_execution_handle(obj_val(j, "handle")),
        )
    if tag == "completed":
        return _rp.Completed(
            identity=decode_request_identity(obj_val(j, "identity")),
            handle=decode_execution_handle(obj_val(j, "handle")),
            value=obj_val(j, "value"),
        )
    if tag == "cancelledAtAdapter":
        return _rp.CancelledAtAdapter(
            identity=decode_request_identity(obj_val(j, "identity")),
            handle=decode_execution_handle(obj_val(j, "handle")),
        )
    raise fail_shape(f"unknown adapter signal tag {tag}")


def decode_adapter_failure(j: Any) -> _rp.AdapterFailure:
    tag = str_field(j, "tag")
    if tag == "startAdapterFailure":
        return _rp.StartAdapterFailure(
            identity=decode_request_identity(obj_val(j, "identity")), detail=str_field(j, "detail")
        )
    if tag == "completionAdapterFailure":
        return _rp.CompletionAdapterFailure(
            identity=decode_request_identity(obj_val(j, "identity")),
            handle=decode_execution_handle(obj_val(j, "handle")),
            detail=str_field(j, "detail"),
        )
    if tag == "cancellationAdapterFailure":
        return _rp.CancellationAdapterFailure(
            identity=decode_request_identity(obj_val(j, "identity")),
            handle=decode_execution_handle(obj_val(j, "handle")),
            detail=str_field(j, "detail"),
        )
    raise fail_shape(f"unknown adapter failure tag {tag}")


def decode_adapter_result(j: Any) -> _rp.AdapterResult[Any]:
    tag = str_field(j, "tag")
    if tag == "appliedSignal":
        return _rp.AppliedSignal(decode_adapter_signal(obj_val(j, "signal")))
    if tag == "adapterFailed":
        return _rp.AdapterFailed(decode_adapter_failure(obj_val(j, "failure")))
    raise fail_shape(f"unknown adapter result tag {tag}")


def encode_submit_failure(f: _rp.SubmitFailure) -> dict[str, Any]:
    if isinstance(f, _rp.DuplicateIdentity):
        return {"tag": "duplicateIdentity", "identity": encode_request_identity(f.identity)}
    return {
        "tag": "pendingLimitExceeded",
        "demand": encode_resource_demand(f.demand),
        "budget": encode_resource_budget(f.budget),
    }


def encode_submit_result(r: _rp.SubmitResult) -> dict[str, Any]:
    if isinstance(r, _rp.SubmitAccepted):
        return {"tag": "accepted", "snapshot": encode_snapshot(r.snapshot), "accepted": encode_accepted(r.accepted)}
    return {"tag": "submitRejected", "snapshot": encode_snapshot(r.snapshot), "failure": encode_submit_failure(r.failure)}


def encode_start_decision_failure(f: _rp.StartDecisionFailure) -> dict[str, Any]:
    if isinstance(f, _rp.UnknownRequest):
        return {"tag": "unknownRequest", "identity": encode_request_identity(f.identity)}
    if isinstance(f, _rp.RequestNotPending):
        return {"tag": "requestNotPending", "identity": encode_request_identity(f.identity)}
    if isinstance(f, _rp.PolicyOrderBlocked):
        return {"tag": "policyOrderBlocked", "identity": encode_request_identity(f.identity)}
    if isinstance(f, _rp.PermissionDenied):
        return {"tag": "permissionDenied", "identity": encode_request_identity(f.identity), "reason": encode_permission_denial(f.reason)}
    if isinstance(f, _rp.PermissionIdentityMismatch):
        return {"tag": "permissionIdentityMismatch", "identity": encode_request_identity(f.identity), "other": encode_request_identity(f.other)}
    if isinstance(f, _rp.PermissionNotOrdered):
        return {"tag": "permissionNotOrdered", "identity": encode_request_identity(f.identity)}
    if isinstance(f, _rp.CostSelectionIdentityMismatch):
        return {"tag": "costSelectionIdentityMismatch", "identity": encode_request_identity(f.identity), "other": encode_request_identity(f.other)}
    if isinstance(f, _rp.InFlightLimitExceeded):
        return {"tag": "inFlightLimitExceeded", "demand": encode_resource_demand(f.demand), "budget": encode_resource_budget(f.budget)}
    return {"tag": "concurrentLimitExceeded", "demand": encode_resource_demand(f.demand), "budget": encode_resource_budget(f.budget)}


def encode_start_decision_result(r: _rp.StartDecisionResult) -> dict[str, Any]:
    if isinstance(r, _rp.Execute):
        return {"tag": "execute", "snapshot": encode_snapshot(r.snapshot), "starting": encode_starting(r.starting), "command": encode_adapter_command(r.command)}
    if isinstance(r, _rp.Deferred):
        return {"tag": "deferred", "snapshot": encode_snapshot(r.snapshot), "accepted": encode_accepted(r.accepted)}
    return {"tag": "rejected", "snapshot": encode_snapshot(r.snapshot), "failure": encode_start_decision_failure(r.failure)}


def encode_start_observation_failure(f: _rp.StartObservationFailure) -> dict[str, Any]:
    if isinstance(f, _rp.UnknownRequest):
        return {"tag": "unknownRequest", "identity": encode_request_identity(f.identity)}
    if isinstance(f, _rp.RequestNotStarting):
        return {"tag": "requestNotStarting", "identity": encode_request_identity(f.identity)}
    if isinstance(f, _rp.StartIdentityMismatch):
        return {"tag": "startIdentityMismatch", "identity": encode_request_identity(f.identity), "other": encode_request_identity(f.other)}
    if isinstance(f, _rp.StartSignalMismatch):
        return {"tag": "startSignalMismatch", "identity": encode_request_identity(f.identity)}
    return {"tag": "startAdapterFailureObserved", "identity": encode_request_identity(f.identity), "detail": f.detail}


def encode_start_observation_result(r: _rp.StartObservationResult) -> dict[str, Any]:
    if isinstance(r, _rp.Publishing):
        return {"tag": "publishing", "snapshot": encode_snapshot(r.snapshot), "running": encode_running(r.running)}
    return {"tag": "failed", "snapshot": encode_snapshot(r.snapshot), "failure": encode_start_observation_failure(r.failure)}


def encode_completion_observation_failure(f: _rp.CompletionObservationFailure) -> dict[str, Any]:
    if isinstance(f, _rp.UnknownCompletion):
        return {"tag": "unknownCompletion", "identity": encode_request_identity(f.identity)}
    if isinstance(f, _rp.CompletionNotRunning):
        return {"tag": "completionNotRunning", "identity": encode_request_identity(f.identity)}
    if isinstance(f, _rp.HandleMismatch):
        return {"tag": "handleMismatch", "identity": encode_request_identity(f.identity)}
    if isinstance(f, _rp.CompletionIdentityMismatch):
        return {"tag": "completionIdentityMismatch", "identity": encode_request_identity(f.identity), "other": encode_request_identity(f.other)}
    if isinstance(f, _rp.CompletionSignalMismatch):
        return {"tag": "completionSignalMismatch", "identity": encode_request_identity(f.identity)}
    if isinstance(f, _rp.CompletionAdapterFailureObserved):
        return {"tag": "completionAdapterFailureObserved", "identity": encode_request_identity(f.identity), "detail": f.detail}
    return {"tag": "cancellationAdapterFailureObserved", "identity": encode_request_identity(f.identity), "detail": f.detail}


def encode_completion_observation_result(r: _rp.CompletionObservationResult[Any]) -> dict[str, Any]:
    if isinstance(r, _rp.AppliedResult):
        return {"tag": "applied", "snapshot": encode_snapshot(r.snapshot), "identity": encode_request_identity(r.identity), "value": r.value}
    if isinstance(r, _rp.SupersededResult):
        return {"tag": "superseded", "snapshot": encode_snapshot(r.snapshot), "identity": encode_request_identity(r.identity)}
    if isinstance(r, _rp.CancelledResult):
        return {"tag": "cancelled", "snapshot": encode_snapshot(r.snapshot), "identity": encode_request_identity(r.identity)}
    return {"tag": "failed", "snapshot": encode_snapshot(r.snapshot), "failure": encode_completion_observation_failure(r.failure)}


def encode_cancel_failure(f: _rp.CancelFailure) -> dict[str, Any]:
    if isinstance(f, _rp.CancelUnknownRequest):
        return {"tag": "unknownRequest", "identity": encode_request_identity(f.identity)}
    if isinstance(f, _rp.RequestAlreadyTerminal):
        return {"tag": "requestAlreadyTerminal", "identity": encode_request_identity(f.identity)}
    return {"tag": "missingExecutionHandle", "identity": encode_request_identity(f.identity)}


def encode_cancel_decision_result(r: _rp.CancelDecisionResult) -> dict[str, Any]:
    if isinstance(r, _rp.CancelledWithoutAdapter):
        return {"tag": "cancelled", "snapshot": encode_snapshot(r.snapshot), "identity": encode_request_identity(r.identity)}
    if isinstance(r, _rp.CancelIssued):
        return {"tag": "cancelCommand", "snapshot": encode_snapshot(r.snapshot), "running": encode_running(r.running), "command": encode_adapter_command(r.command)}
    return {"tag": "rejected", "snapshot": encode_snapshot(r.snapshot), "failure": encode_cancel_failure(r.failure)}


# --- Request progression operations -------------------------------------


def op_request_progression_empty(input: Any) -> Any:
    policy = decode_request_policy(obj_val(input, "policy"))
    budget = decode_resource_budget(obj_val(input, "budget"))
    return encode_snapshot(_rp.empty(policy, budget))


def op_request_progression_submit(input: Any) -> Any:
    snapshot = decode_snapshot(obj_val(input, "snapshot"))
    request = decode_request_input(obj_val(input, "request"))
    return encode_submit_result(_rp.submit(snapshot, request))


def op_request_progression_decide_start(input: Any) -> Any:
    snapshot = decode_snapshot(obj_val(input, "snapshot"))
    accepted = decode_accepted(obj_val(input, "accepted"))
    selection = decode_cost_selection(obj_val(input, "selection"))
    return encode_start_decision_result(_rp.decide_start(snapshot, accepted, selection))


def op_request_progression_apply_start_observation(input: Any) -> Any:
    snapshot = decode_snapshot(obj_val(input, "snapshot"))
    starting = decode_starting(obj_val(input, "starting"))
    observed = decode_adapter_result(obj_val(input, "observed"))
    return encode_start_observation_result(_rp.apply_start_observation(snapshot, starting, observed))


def op_request_progression_apply_completion_observation(input: Any) -> Any:
    snapshot = decode_snapshot(obj_val(input, "snapshot"))
    running = decode_running(obj_val(input, "running"))
    observed = decode_adapter_result(obj_val(input, "observed"))
    return encode_completion_observation_result(_rp.apply_completion_observation(snapshot, running, observed))


def op_request_progression_decide_cancel(input: Any) -> Any:
    snapshot = decode_snapshot(obj_val(input, "snapshot"))
    identity = decode_request_identity(obj_val(input, "identity"))
    return encode_cancel_decision_result(_rp.decide_cancel(snapshot, identity))


def op_request_progression_derive_pending(input: Any) -> Any:
    snapshot = decode_snapshot(obj_val(input, "snapshot"))
    return encode_resource_demand(_rp.derive_pending(snapshot))


def op_request_progression_derive_in_flight(input: Any) -> Any:
    snapshot = decode_snapshot(obj_val(input, "snapshot"))
    return encode_resource_demand(_rp.derive_in_flight(snapshot))


def op_request_progression_derive_concurrent(input: Any) -> Any:
    snapshot = decode_snapshot(obj_val(input, "snapshot"))
    return encode_resource_demand(_rp.derive_concurrent(snapshot))


# --- Dynamic admission encoders/decoders --------------------------------


def decode_environment_specification(j: Any) -> _admission.EnvironmentSpecification:
    return _admission.EnvironmentSpecification(nat_field(j, "maxObservationAge"))


def decode_capacity_observation(j: Any) -> _admission.CapacityObservation:
    return _admission.CapacityObservation(
        observed=decode_resource_budget(obj_val(j, "observed")), observed_at=nat_field(j, "observedAt")
    )


def decode_signal_kind(j: Any) -> _admission.SignalKind:
    s = as_str(j)
    for k in _admission.SignalKind:
        if k.value == s:
            return k
    raise fail_shape(f"unknown signal kind {s}")


def decode_admission_signal(j: Any) -> _admission.AdmissionSignal:
    return _admission.AdmissionSignal(
        identity=decode_request_identity(obj_val(j, "identity")),
        handle=decode_execution_handle(obj_val(j, "handle")),
        kind=decode_signal_kind(obj_val(j, "kind")),
    )


def decode_admission_provenance(j: Any) -> _admission.AdmissionProvenance:
    future_uses = tuple(decode_request_identity(x) for x in arr_field(j, "futureUses"))
    signals = tuple(decode_admission_signal(x) for x in arr_field(j, "outstandingSignals"))
    return _admission.AdmissionProvenance(future_uses=future_uses, outstanding_signals=signals)


def encode_admission_provenance(p: _admission.AdmissionProvenance) -> dict[str, Any]:
    return {
        "futureUses": [encode_request_identity(i) for i in p.future_uses],
        "outstandingSignals": [
            {
                "identity": encode_request_identity(s.identity),
                "handle": encode_execution_handle(s.handle),
                "kind": s.kind.value,
            }
            for s in p.outstanding_signals
        ],
    }


def decode_dynamic_admission_state(j: Any) -> _admission.DynamicAdmissionState:
    return _admission.DynamicAdmissionState(
        progression=decode_snapshot(obj_val(j, "progression")),
        configured_safety_limit=decode_resource_budget(obj_val(j, "configuredSafetyLimit")),
        provenance=decode_admission_provenance(obj_val(j, "provenance")),
    )


def encode_dynamic_admission_state(s: _admission.DynamicAdmissionState) -> dict[str, Any]:
    return {
        "progression": encode_snapshot(s.progression),
        "configuredSafetyLimit": encode_resource_budget(s.configured_safety_limit),
        "provenance": encode_admission_provenance(s.provenance),
    }


def decode_dynamic_admission_input(j: Any) -> _admission.DynamicAdmissionInput:
    state = decode_dynamic_admission_state(obj_val(j, "state"))
    request = decode_request_input(obj_val(j, "request"))
    env = decode_environment_specification(obj_val(j, "environmentSpecification"))
    capacity_observation = decode_capacity_observation(obj_val(j, "capacityObservation"))
    observed_at = nat_field(j, "observedAt")
    start_j = obj_val(j, "start")
    start = None if start_j is None else decode_cost_selection(start_j)
    return _admission.DynamicAdmissionInput(
        state=state,
        request=request,
        environment_specification=env,
        capacity_observation=capacity_observation,
        observed_at=observed_at,
        start=start,
    )


def encode_dynamic_admission_failure(f: Any) -> dict[str, Any]:
    if isinstance(f, _admission.CapacityObservationUnavailable):
        return {"tag": "capacityObservationUnavailable", "age": nat_to_json(f.age), "maxAge": nat_to_json(f.max_age)}
    if isinstance(f, _admission.ResourceCoordinateMismatch):
        return {
            "tag": "resourceCoordinateMismatch",
            "configuredResource": f.configured_resource,
            "observedResource": f.observed_resource,
        }
    if isinstance(f, _admission.ConfiguredSafetyLimitExceeded):
        return {
            "tag": "configuredSafetyLimitExceeded",
            "resource": f.resource,
            "occupied": nat_to_json(f.occupied),
            "allowed": nat_to_json(f.allowed),
        }
    if isinstance(f, _admission.MeaningDenied):
        return {"tag": "meaningDenied", "identity": encode_request_identity(f.identity), "reason": encode_permission_denial(f.reason)}
    if isinstance(f, _admission.DynamicPermissionIdentityMismatch):
        return {
            "tag": "permissionIdentityMismatch",
            "requestIdentity": encode_request_identity(f.request_identity),
            "permissionIdentity": encode_request_identity(f.permission_identity),
        }
    if isinstance(f, _admission.AdapterBindingUnavailable):
        return {"tag": "adapterBindingUnavailable", "identity": encode_request_identity(f.identity)}
    if isinstance(f, _admission.BindingSelectionMismatch):
        return {"tag": "bindingSelectionMismatch", "identity": encode_request_identity(f.identity)}
    if isinstance(f, _admission.ProgressionSubmitFailure):
        return {"tag": "progressionSubmitFailure", "failure": encode_submit_failure(f.failure)}
    if isinstance(f, _admission.ProgressionStartFailure):
        return {"tag": "progressionStartFailure", "failure": encode_start_decision_failure(f.failure)}
    if isinstance(f, _admission.ProvenanceRetentionRequired):
        return {"tag": "provenanceRetentionRequired", "identity": encode_request_identity(f.identity)}
    if isinstance(f, _admission.DynamicUnknownRequest):
        return {"tag": "unknownRequest", "identity": encode_request_identity(f.identity)}
    return {"tag": "requestNotTerminal", "identity": encode_request_identity(f.identity)}


def encode_admission_decision(d: Any) -> dict[str, Any]:
    if isinstance(d, _admission.Submitted):
        return {"tag": "submitted", "state": encode_dynamic_admission_state(d.state), "accepted": encode_accepted(d.accepted)}
    if isinstance(d, _admission.Started):
        return {"tag": "started", "state": encode_dynamic_admission_state(d.state), "result": encode_start_decision_result(d.result)}
    return {"tag": "coalesced", "state": encode_dynamic_admission_state(d.state), "identity": encode_request_identity(d.identity)}


def encode_provenance_erasure_witness(w: Any) -> dict[str, Any]:
    if isinstance(w, _admission.Erased):
        return {"tag": "erased", "identity": encode_request_identity(w.identity)}
    return {"tag": "retained", "identity": encode_request_identity(w.identity), "reason": w.reason}


def encode_coalescing_witness(w: Any) -> dict[str, Any]:
    if isinstance(w, _admission.CoalescedWitness):
        return {"tag": "coalesced", "identity": encode_request_identity(w.identity)}
    return {"tag": "notCoalesced", "reason": w.reason}


def encode_dynamic_admission_result(r: _admission.DynamicAdmissionResult) -> dict[str, Any]:
    return {
        "effectiveBudget": encode_resource_budget(r.effective_budget),
        "admissionDecision": encode_admission_decision(r.admission_decision),
        "futureUseSet": [encode_request_identity(i) for i in r.future_use_set.identities],
        "outstandingSignalSet": [
            {
                "identity": encode_request_identity(s.identity),
                "handle": encode_execution_handle(s.handle),
                "kind": s.kind.value,
            }
            for s in r.outstanding_signal_set.signals
        ],
        "provenanceErasureWitness": (
            None if r.provenance_erasure_witness is None else encode_provenance_erasure_witness(r.provenance_erasure_witness)
        ),
        "coalescingWitness": encode_coalescing_witness(r.coalescing_witness),
    }


def encode_dynamic_admission_outcome(o: Any) -> dict[str, Any]:
    if isinstance(o, _core.Applied):
        return {"tag": "applied", "value": encode_dynamic_admission_result(o.value)}
    return {"tag": "rejected", "failure": encode_dynamic_admission_failure(o.reason)}


def encode_elision_outcome(o: Any) -> dict[str, Any]:
    if isinstance(o, _core.Applied):
        state, witness = o.value
        return {"tag": "applied", "state": encode_dynamic_admission_state(state), "witness": encode_provenance_erasure_witness(witness)}
    return {"tag": "rejected", "failure": encode_dynamic_admission_failure(o.reason)}


# --- Dynamic admission operations ----------------------------------------


def op_dynamic_admission_elide_admission_provenance(input: Any) -> Any:
    state = decode_dynamic_admission_state(obj_val(input, "state"))
    identity = decode_request_identity(obj_val(input, "identity"))
    return encode_elision_outcome(_admission.elide_admission_provenance(state, identity))


def op_dynamic_admission_admit_dynamic_request(input: Any) -> Any:
    admission_input = decode_dynamic_admission_input(input)
    return encode_dynamic_admission_outcome(_admission.admit_dynamic_request(admission_input))


# --- File effect encoders/decoders --------------------------------------


def decode_normalized_path(j: Any) -> _files.NormalizedPath:
    root = obj_val(j, "root")
    if not isinstance(root, bool):
        raise fail_shape("expected bool root")
    segments = tuple(as_str(s) for s in arr_field(j, "segments"))
    return _files.NormalizedPath(root=root, segments=segments)


def encode_normalized_path(p: _files.NormalizedPath) -> dict[str, Any]:
    return {"root": p.root, "segments": list(p.segments)}


def decode_content_digest(j: Any) -> _files.ContentDigest:
    return _files.ContentDigest(as_str(j))


def encode_content_digest(d: _files.ContentDigest) -> str:
    return d.value


def decode_byte(j: Any) -> int:
    n = nat_of_str(as_str(j))
    if n >= 256:
        raise fail_shape("byte out of range")
    return n


def encode_byte(b: int) -> str:
    return nat_to_json(b)


def decode_bytes_(j: Any) -> tuple[int, ...]:
    return tuple(decode_byte(x) for x in as_arr(j))


def encode_bytes_(bs: tuple[int, ...]) -> list[Any]:
    return [encode_byte(b) for b in bs]


def decode_file_record(j: Any) -> _files.FileRecord:
    digest = decode_content_digest(obj_val(j, "digest"))
    bs = decode_bytes_(obj_val(j, "bytes"))
    return _files.FileRecord(digest=digest, bytes=bs)


def encode_file_record(r: _files.FileRecord) -> dict[str, Any]:
    return {"digest": encode_content_digest(r.digest), "bytes": encode_bytes_(r.bytes)}


def decode_external_file_state(j: Any) -> _files.ExternalFileState:
    files = tuple(
        (decode_normalized_path(obj_val(e, "path")), decode_file_record(obj_val(e, "record")))
        for e in arr_field(j, "files")
    )
    read_failures = tuple(decode_normalized_path(p) for p in arr_field(j, "readFailures"))
    write_failures = tuple(decode_normalized_path(p) for p in arr_field(j, "writeFailures"))
    return _files.ExternalFileState(files=files, read_failures=read_failures, write_failures=write_failures)


def encode_external_file_state(s: _files.ExternalFileState) -> dict[str, Any]:
    return {
        "files": [{"path": encode_normalized_path(p), "record": encode_file_record(r)} for p, r in s.files],
        "readFailures": [encode_normalized_path(p) for p in s.read_failures],
        "writeFailures": [encode_normalized_path(p) for p in s.write_failures],
    }


def decode_digests(j: Any) -> _files.Digests:
    arr = as_arr(j)
    entries = tuple(
        (decode_resource_id(obj_val(e, "resource")), decode_content_digest(obj_val(e, "digest"))) for e in arr
    )
    return _files.Digests(entries)


def encode_digests(d: _files.Digests) -> list[Any]:
    return [{"resource": encode_resource_id(r), "digest": encode_content_digest(g)} for r, g in d.entries]


def encode_digest_lookup(d: Any) -> dict[str, Any]:
    if isinstance(d, _files.UnobservedContents):
        return {"tag": "unobserved", "resource": encode_resource_id(d.resource)}
    return {"tag": "found", "digest": encode_content_digest(d)}


def encode_observation(encode_payload: Any, o: _core.Observation[Any]) -> dict[str, Any]:
    return {"payload": encode_payload(o.payload), "basis": encode_basis(o.basis), "observedAt": nat_to_json(o.observed_at)}


def encode_file_snapshot(s: _files.FileSnapshot) -> dict[str, Any]:
    return {
        "path": encode_normalized_path(s.path),
        "contents": encode_bytes_(s.contents),
        "digest": encode_content_digest(s.digest),
    }


def encode_track_result(r: Any) -> dict[str, Any]:
    return {
        "tag": "applied",
        "observation": encode_observation(encode_revision, r.value.observation),
        "world": encode_world(r.value.world),
    }


def encode_read_result(r: Any) -> dict[str, Any]:
    if isinstance(r, _core.Applied):
        return {
            "tag": "applied",
            "observation": encode_observation(encode_file_snapshot, r.value.observation),
            "world": encode_world(r.value.world),
            "digests": encode_digests(r.value.digests),
        }
    if isinstance(r, _core.Rejected):
        return {"tag": "rejected", "resource": encode_resource_id(r.reason.resource)}
    return {"tag": "boundaryFailed", "path": encode_normalized_path(r.failure.path)}


def decode_replace_contents(j: Any) -> _files.ReplaceContents:
    new_contents = decode_bytes_(obj_val(j, "newContents"))
    new_digest = decode_content_digest(obj_val(j, "newDigest"))
    return _files.ReplaceContents(new_contents=new_contents, new_digest=new_digest)


def encode_replace_rejection(r: Any) -> dict[str, Any]:
    if isinstance(r, _files.ResourcePathMismatch):
        return {"tag": "resourcePathMismatch", "resource": encode_resource_id(r.resource), "path": encode_normalized_path(r.path)}
    if isinstance(r, _core.UnknownResource):
        return {"tag": "unknownResource", "resource": encode_resource_id(r.resource)}
    return {"tag": "unobservedContents", "resource": encode_resource_id(r.resource)}


def encode_replace_conflict(c: Any) -> dict[str, Any]:
    if isinstance(c, _core.StaleBasis):
        return {"tag": "staleBasis", "expected": encode_revision(c.expected), "actual": encode_revision(c.actual)}
    return {"tag": "externalMutation", "expected": encode_content_digest(c.expected), "actual": encode_content_digest(c.actual)}


def encode_replace_result(r: Any) -> dict[str, Any]:
    if isinstance(r, _core.Applied):
        return {
            "tag": "applied",
            "observation": encode_observation(encode_file_snapshot, r.value.observation),
            "world": encode_world(r.value.world),
            "digests": encode_digests(r.value.digests),
            "state": encode_external_file_state(r.value.state),
        }
    if isinstance(r, _core.Rejected):
        return {"tag": "rejected", "rejection": encode_replace_rejection(r.reason)}
    if isinstance(r, _core.Conflicted):
        return {"tag": "conflicted", "conflict": encode_replace_conflict(r.conflict)}
    return {"tag": "boundaryFailed", "path": encode_normalized_path(r.failure.path)}


# --- File effect operations -----------------------------------------------


def op_file_effect_normalize_path(input: Any) -> Any:
    root = obj_val(input, "root")
    if not isinstance(root, bool):
        raise fail_shape("expected bool root")
    raw = tuple(as_str(s) for s in arr_field(input, "raw"))
    return encode_normalized_path(_files.normalize_path(root, raw))


def op_file_effect_lookup_digest(input: Any) -> Any:
    digests = decode_digests(obj_val(input, "digests"))
    resource = decode_resource_id(obj_val(input, "resource"))
    return encode_digest_lookup(_files.lookup_digest(digests, resource))


def op_file_effect_set_digest(input: Any) -> Any:
    digests = decode_digests(obj_val(input, "digests"))
    resource = decode_resource_id(obj_val(input, "resource"))
    digest = decode_content_digest(obj_val(input, "digest"))
    return encode_digests(_files.set_digest(digests, resource, digest))


def op_file_effect_track(input: Any) -> Any:
    path = decode_normalized_path(obj_val(input, "path"))
    world = decode_world(obj_val(input, "world"))
    observed_at = nat_field(input, "observedAt")
    req = _files.TrackReq(path=path, world=world, observed_at=observed_at)
    result = _call.io(_files.track, _call.Request(payload=req, fields=_files.track.required))
    assert isinstance(result, _call.CallOk)
    return encode_track_result(result.value)


def op_file_effect_read(input: Any) -> Any:
    path = decode_normalized_path(obj_val(input, "path"))
    world = decode_world(obj_val(input, "world"))
    digests = decode_digests(obj_val(input, "digests"))
    state = decode_external_file_state(obj_val(input, "state"))
    observed_at = nat_field(input, "observedAt")
    req = _files.ReadReq(
        path=path, world=world, digests=digests, state=state, observed_at=observed_at
    )
    result = _call.io(_files.read, _call.Request(payload=req, fields=_files.read.required))
    assert isinstance(result, _call.CallOk)
    return encode_read_result(result.value)


def op_file_effect_replace(input: Any) -> Any:
    intent = decode_replace_contents(obj_val(input, "intent"))
    basis = decode_basis(obj_val(input, "basis"))
    command = _core.Command(intent=intent, basis=basis)
    path = decode_normalized_path(obj_val(input, "path"))
    world = decode_world(obj_val(input, "world"))
    digests = decode_digests(obj_val(input, "digests"))
    state = decode_external_file_state(obj_val(input, "state"))
    observed_at = nat_field(input, "observedAt")
    req = _files.ReplaceReq(
        command=command,
        path=path,
        world=world,
        digests=digests,
        state=state,
        observed_at=observed_at,
    )
    result = _call.io(_files.replace, _call.Request(payload=req, fields=_files.replace.required))
    assert isinstance(result, _call.CallOk)
    return encode_replace_result(result.value)


# --- Surface inventory -------------------------------------------------


SURFACE_ENTRIES: list[tuple[str, list[str]]] = [
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

KNOWN_FEATURES = [f for f, _ in SURFACE_ENTRIES]


def surface_json() -> dict[str, Any]:
    return {
        "kind": "surface",
        "features": [{"feature": f, "operations": list(ops)} for f, ops in SURFACE_ENTRIES],
    }


DISPATCH: dict[tuple[str, str], Any] = {
    ("core", "lookup"): op_core_lookup,
    ("core", "bump"): op_core_bump,
    ("core", "commandOf"): op_core_command_of,
    ("core", "apply"): op_core_apply,
    ("call", "immediateOf"): op_call_immediate_of,
    ("call", "deferredOf"): op_call_deferred_of,
    ("call", "io"): op_call_io,
    ("call", "issue"): op_call_issue,
    ("iteration", "fold"): op_iteration_fold,
    ("iteration", "recurse"): op_iteration_recurse,
    ("iteration", "closure"): op_iteration_closure,
    ("store", "storeOf"): op_store_store_of,
    ("store", "storeEntries"): op_store_store_entries,
    ("store", "observe"): op_store_observe,
    ("store", "apply"): op_store_apply,
    ("store", "worldOf"): op_store_world_of,
    ("record", "recordOf"): op_record_record_of,
    ("record", "recordOnBasis"): op_record_record_on_basis,
    ("record", "hasEdge"): op_record_has_edge,
    ("reconcile", "reconcile"): op_reconcile_reconcile,
    ("reconcile", "coherent"): op_reconcile_coherent,
    ("request_progression", "empty"): op_request_progression_empty,
    ("request_progression", "submit"): op_request_progression_submit,
    ("request_progression", "decideStart"): op_request_progression_decide_start,
    ("request_progression", "applyStartObservation"): op_request_progression_apply_start_observation,
    ("request_progression", "applyCompletionObservation"): op_request_progression_apply_completion_observation,
    ("request_progression", "decideCancel"): op_request_progression_decide_cancel,
    ("request_progression", "derivePending"): op_request_progression_derive_pending,
    ("request_progression", "deriveInFlight"): op_request_progression_derive_in_flight,
    ("request_progression", "deriveConcurrent"): op_request_progression_derive_concurrent,
    ("dynamic_admission", "elideAdmissionProvenance"): op_dynamic_admission_elide_admission_provenance,
    ("dynamic_admission", "admitDynamicRequest"): op_dynamic_admission_admit_dynamic_request,
    ("step_transition", "step"): op_step_transition_step,
    ("file_effect", "normalizePath"): op_file_effect_normalize_path,
    ("file_effect", "lookupDigest"): op_file_effect_lookup_digest,
    ("file_effect", "setDigest"): op_file_effect_set_digest,
    ("file_effect", "track"): op_file_effect_track,
    ("file_effect", "read"): op_file_effect_read,
    ("file_effect", "replace"): op_file_effect_replace,
}


def dispatch(feature: str, operation: str, input: Any) -> Any:
    fn = DISPATCH.get((feature, operation))
    if fn is not None:
        return fn(input)
    if feature in KNOWN_FEATURES:
        raise DecodeFailure("unknown_operation", f"{feature}.{operation}")
    raise DecodeFailure("unknown_feature", feature)


def process_request(j: Any) -> dict[str, Any]:
    feature = str_field(j, "feature")
    operation = str_field(j, "operation")
    input = obj_val(j, "input")
    result = dispatch(feature, operation, input)
    return {"feature": feature, "operation": operation, "result": result}


def decode_query(j: Any) -> dict[str, Any]:
    if not isinstance(j, dict) or not isinstance(j.get("kind"), str):
        raise DecodeFailure("query_shape", "missing or invalid top-level kind")
    kind = j["kind"]
    if kind == "surface":
        return surface_json()
    if kind == "evaluate":
        requests = j.get("requests")
        if not isinstance(requests, list):
            raise DecodeFailure("query_shape", "missing or invalid requests array")
        results = [process_request(r) for r in requests]
        return {"kind": "results", "results": results}
    raise DecodeFailure("query_shape", f"unknown query kind {kind}")


def render_invalid(f: DecodeFailure) -> dict[str, Any]:
    return {"kind": "invalid", "failure": {"kind": f.kind, "detail": f.detail}}


def main() -> None:
    content = sys.stdin.read()
    try:
        parsed = json.loads(content)
    except json.JSONDecodeError as exc:
        print(json.dumps(render_invalid(DecodeFailure("json_syntax", str(exc))), separators=(",", ":")))
        return
    try:
        result = decode_query(parsed)
    except DecodeFailure as exc:
        print(json.dumps(render_invalid(exc), separators=(",", ":")))
        return
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
