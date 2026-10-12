// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

//! stdin inspection adapter. Reads one generated query, evaluates it against
//! `necoherence`'s public API, and writes one normalized JSON result.
//! Mirrors `lean_driver/FeatureCheck.lean`'s protocol and surface inventory.

use necoherence::*;
use serde_json::Value as V;
use std::collections::BTreeSet;
use std::io::{Read as _, Write as _};

#[derive(Clone, Debug)]
struct Fail {
    kind: &'static str,
    detail: String,
}

fn fail(kind: &'static str, detail: impl Into<String>) -> Fail {
    Fail {
        kind,
        detail: detail.into(),
    }
}

type D<T> = Result<T, Fail>;

fn shape(detail: impl Into<String>) -> Fail {
    fail("input_shape", detail)
}

fn get_field<'a>(v: &'a V, key: &str) -> D<&'a V> {
    v.as_object()
        .and_then(|o| o.get(key))
        .ok_or_else(|| shape(format!("missing field {key}")))
}

fn as_str(v: &V) -> D<&str> {
    v.as_str().ok_or_else(|| shape("expected string"))
}

fn as_arr(v: &V) -> D<&Vec<V>> {
    v.as_array().ok_or_else(|| shape("expected array"))
}

fn as_bool(v: &V) -> D<bool> {
    v.as_bool().ok_or_else(|| shape("expected bool"))
}

fn str_field(v: &V, key: &str) -> D<String> {
    Ok(as_str(get_field(v, key)?)?.to_string())
}

fn arr_field<'a>(v: &'a V, key: &str) -> D<&'a Vec<V>> {
    as_arr(get_field(v, key)?)
}

fn str_list_field(v: &V, key: &str) -> D<Vec<String>> {
    arr_field(v, key)?
        .iter()
        .map(|x| Ok(as_str(x)?.to_string()))
        .collect()
}

fn nat_of_str(s: &str) -> D<Nat> {
    if s.is_empty() {
        return Err(shape("empty integer"));
    }
    if !s.chars().all(|c| c.is_ascii_digit()) {
        return Err(shape("invalid integer"));
    }
    s.parse::<Nat>().map_err(|_| shape("invalid integer"))
}

fn nat_field(v: &V, key: &str) -> D<Nat> {
    nat_of_str(as_str(get_field(v, key)?)?)
}

fn nat_to_json(n: &Nat) -> V {
    V::String(n.to_string())
}

fn decode_resource_id(v: &V) -> D<ResourceId> {
    Ok(ResourceId {
        kind: str_field(v, "kind")?,
        name: str_field(v, "name")?,
    })
}

fn encode_resource_id(r: &ResourceId) -> V {
    serde_json::json!({"kind": r.kind, "name": r.name})
}

fn decode_revision(v: &V) -> D<Revision> {
    Ok(Revision {
        value: nat_of_str(as_str(v)?)?,
    })
}

fn encode_revision(r: &Revision) -> V {
    nat_to_json(&r.value)
}

fn decode_basis(v: &V) -> D<Basis> {
    Ok(Basis {
        resource: decode_resource_id(get_field(v, "resource")?)?,
        revision: decode_revision(get_field(v, "revision")?)?,
    })
}

fn encode_basis(b: &Basis) -> V {
    serde_json::json!({"resource": encode_resource_id(&b.resource), "revision": encode_revision(&b.revision)})
}

fn decode_world(v: &V) -> D<World> {
    let entries = as_arr(v)?
        .iter()
        .map(|e| {
            Ok((
                decode_resource_id(get_field(e, "resource")?)?,
                decode_revision(get_field(e, "revision")?)?,
            ))
        })
        .collect::<D<Vec<_>>>()?;
    Ok(world_of(entries))
}

fn encode_world(w: &World) -> V {
    V::Array(
        entries(w)
            .iter()
            .map(|(r, rev)| {
                serde_json::json!({"resource": encode_resource_id(r), "revision": encode_revision(rev)})
            })
            .collect(),
    )
}

fn encode_lookup(l: &Lookup) -> V {
    match l {
        Lookup::Found(r) => serde_json::json!({"tag": "found", "revision": encode_revision(r)}),
        Lookup::Unknown(u) => {
            serde_json::json!({"tag": "unknown", "resource": encode_resource_id(&u.resource)})
        }
    }
}

fn decode_command(v: &V) -> D<Command<V>> {
    Ok(Command {
        intent: get_field(v, "intent")?.clone(),
        basis: decode_basis(get_field(v, "basis")?)?,
    })
}

fn encode_command(c: &Command<V>) -> V {
    serde_json::json!({"intent": c.intent, "basis": encode_basis(&c.basis)})
}

fn encode_apply_outcome(o: &Outcome<(V, World), UnknownResource, StaleBasis, Never>) -> V {
    match o {
        Outcome::Applied((intent, w)) => {
            serde_json::json!({"tag": "applied", "intent": intent, "world": encode_world(w)})
        }
        Outcome::Rejected(u) => {
            serde_json::json!({"tag": "rejected", "resource": encode_resource_id(&u.resource)})
        }
        Outcome::Conflicted(k) => {
            serde_json::json!({"tag": "conflicted", "expected": encode_revision(&k.expected), "actual": encode_revision(&k.actual)})
        }
        Outcome::BoundaryFailed(f) => f.elim(),
    }
}

fn op_core_lookup(input: &V) -> D<V> {
    let world = decode_world(get_field(input, "world")?)?;
    let resource = decode_resource_id(get_field(input, "resource")?)?;
    Ok(encode_lookup(&lookup(&world, &resource)))
}

fn op_core_bump(input: &V) -> D<V> {
    let world = decode_world(get_field(input, "world")?)?;
    let resource = decode_resource_id(get_field(input, "resource")?)?;
    Ok(encode_world(&bump(&world, &resource)))
}

fn op_core_command_of(input: &V) -> D<V> {
    let obs = get_field(input, "observation")?;
    let payload = get_field(obs, "payload")?.clone();
    let basis = decode_basis(get_field(obs, "basis")?)?;
    let observed_at = nat_field(obs, "observedAt")?;
    let observation = Observation {
        payload,
        basis,
        observed_at,
    };
    let x = get_field(input, "payload")?.clone();
    Ok(encode_command(&command_of(&observation, x)))
}

fn op_core_apply(input: &V) -> D<V> {
    let world = decode_world(get_field(input, "world")?)?;
    let command = decode_command(get_field(input, "command")?)?;
    Ok(encode_apply_outcome(&apply(&world, command)))
}

enum FunctionForm {
    Identity,
    Const(V),
    GetField(String),
    SetField(String, V),
    Wrap(String),
}

fn decode_function_form(v: &V) -> D<FunctionForm> {
    let kind = str_field(v, "kind")?;
    match kind.as_str() {
        "identity" => Ok(FunctionForm::Identity),
        "const" => Ok(FunctionForm::Const(get_field(v, "value")?.clone())),
        "getField" => Ok(FunctionForm::GetField(str_field(v, "name")?)),
        "setField" => Ok(FunctionForm::SetField(
            str_field(v, "name")?,
            get_field(v, "value")?.clone(),
        )),
        "wrap" => Ok(FunctionForm::Wrap(str_field(v, "tag")?)),
        other => Err(shape(format!("unknown function form kind {other}"))),
    }
}

fn apply_function_form(form: &FunctionForm, x: &V) -> V {
    match form {
        FunctionForm::Identity => x.clone(),
        FunctionForm::Const(v) => v.clone(),
        FunctionForm::GetField(n) => x
            .as_object()
            .and_then(|o| o.get(n))
            .cloned()
            .unwrap_or(V::Null),
        FunctionForm::SetField(n, v) => {
            let mut obj = x.as_object().cloned().unwrap_or_default();
            obj.insert(n.clone(), v.clone());
            V::Object(obj)
        }
        FunctionForm::Wrap(t) => serde_json::json!({"tag": t, "value": x}),
    }
}

fn decode_request(v: &V) -> D<Request<V>> {
    Ok(Request {
        payload: get_field(v, "payload")?.clone(),
        fields: str_list_field(v, "fields")?,
    })
}

struct DeclShape {
    identity: String,
    required: Vec<String>,
    form: FunctionForm,
}

fn decode_decl(v: &V) -> D<DeclShape> {
    Ok(DeclShape {
        identity: str_field(v, "identity")?,
        required: str_list_field(v, "required")?,
        form: decode_function_form(get_field(v, "output")?)?,
    })
}

fn encode_call_result(r: &CallResult<V>) -> V {
    match r {
        CallResult::Ok(v) => serde_json::json!({"tag": "ok", "value": v}),
        CallResult::Failed(f) => {
            serde_json::json!({"tag": "failed", "declaration": f.declaration, "fields": f.fields})
        }
    }
}

fn op_call_immediate_of(input: &V) -> D<V> {
    let decl = decode_decl(input)?;
    let form = decl.form;
    let immediate = immediate_of::<V, V, _>(decl.identity, decl.required, move |x| {
        apply_function_form(&form, x)
    });
    Ok(serde_json::json!({"identity": immediate.identity, "required": immediate.required}))
}

fn op_call_deferred_of(input: &V) -> D<V> {
    let decl = decode_decl(input)?;
    let form = decl.form;
    let deferred = deferred_of::<V, V, _>(decl.identity, decl.required, move |x| {
        apply_function_form(&form, x)
    });
    Ok(serde_json::json!({"identity": deferred.identity, "required": deferred.required}))
}

fn op_call_io(input: &V) -> D<V> {
    let decl = decode_decl(get_field(input, "declaration")?)?;
    let req = decode_request(get_field(input, "request")?)?;
    let immediate = immediate_of::<V, V, _>(decl.identity, decl.required, move |x| {
        apply_function_form(&decl.form, x)
    });
    Ok(encode_call_result(&io(&immediate, &req)))
}

fn op_call_issue(input: &V) -> D<V> {
    let decl = decode_decl(get_field(input, "declaration")?)?;
    let req = decode_request(get_field(input, "request")?)?;
    let deferred = deferred_of::<V, V, _>(decl.identity, decl.required, move |x| {
        apply_function_form(&decl.form, x)
    });
    Ok(encode_call_result(&issue(&deferred, &req)))
}

enum AdvanceForm {
    ConsumeImmediately(Vec<V>),
    ReprocessAlways(Vec<V>),
    ConsumeAfter(Nat, Vec<V>),
}

fn decode_advance_form(v: &V) -> D<AdvanceForm> {
    let mode = str_field(v, "mode")?;
    match mode.as_str() {
        "consumeImmediately" => Ok(AdvanceForm::ConsumeImmediately(
            arr_field(v, "outputs")?.clone(),
        )),
        "reprocessAlways" => Ok(AdvanceForm::ReprocessAlways(
            arr_field(v, "outputs")?.clone(),
        )),
        "consumeAfter" => Ok(AdvanceForm::ConsumeAfter(
            nat_field(v, "rounds")?,
            arr_field(v, "outputsPerRound")?.clone(),
        )),
        other => Err(shape(format!("unknown advance mode {other}"))),
    }
}

fn round_of(state: &V) -> Nat {
    state
        .as_object()
        .and_then(|o| o.get("round"))
        .and_then(|v| v.as_str())
        .and_then(|s| s.parse::<Nat>().ok())
        .unwrap_or_else(|| Nat::from(0u8))
}

fn state_with_round(n: &Nat) -> V {
    serde_json::json!({"round": n.to_string()})
}

fn advance_eval(form: &AdvanceForm, state: &V) -> Consumption<V, V> {
    match form {
        AdvanceForm::ConsumeImmediately(outputs) => {
            Consumption::Consumed(state.clone(), outputs.clone())
        }
        AdvanceForm::ReprocessAlways(outputs) => {
            Consumption::Reprocess(state.clone(), outputs.clone())
        }
        AdvanceForm::ConsumeAfter(rounds, outputs) => {
            let r = round_of(state) + Nat::from(1u8);
            let new_state = state_with_round(&r);
            if &r >= rounds {
                Consumption::Consumed(new_state, outputs.clone())
            } else {
                Consumption::Reprocess(new_state, outputs.clone())
            }
        }
    }
}

fn encode_step_failure(f: &StepFailure) -> V {
    match f {
        StepFailure::ReprocessLimitExhausted(n) => {
            serde_json::json!({"tag": "reprocess_limit_exhausted", "applications": nat_to_json(n)})
        }
        StepFailure::CapacityExceeded(c, a) => {
            serde_json::json!({"tag": "capacity_exceeded", "capacity": nat_to_json(c), "attempted": nat_to_json(a)})
        }
    }
}

fn encode_step_transition(t: &StepTransition<V, V>) -> V {
    match t {
        StepTransition::Settled(s, o, n) => {
            serde_json::json!({"tag": "settled", "state": s, "outputs": o, "applications": nat_to_json(n)})
        }
        StepTransition::Failed(s, o, f) => {
            serde_json::json!({"tag": "failed", "state": s, "outputs": o, "failure": encode_step_failure(f)})
        }
    }
}

fn op_step_transition_step(input: &V) -> D<V> {
    let state = get_field(input, "state")?.clone();
    let inp = get_field(input, "input")?.clone();
    let form = decode_advance_form(get_field(input, "advance")?)?;
    let limit_n = nat_field(input, "limit")?;
    let capacity_n = nat_field(input, "capacity")?;
    let limit = PositiveLimit::new(limit_n).ok_or_else(|| shape("limit must be positive"))?;
    let capacity = Capacity { value: capacity_n };
    let result = step(
        state,
        &inp,
        |s, _i| advance_eval(&form, s),
        &limit,
        &capacity,
    );
    Ok(encode_step_transition(&result))
}

fn encode_stage_projection_failed(s: &StageProjectionFailed) -> V {
    serde_json::json!({
        "position": nat_to_json(&s.position),
        "declaration": s.failure.declaration,
        "fields": s.failure.fields,
    })
}

fn decode_fold_req(v: &V) -> D<(DeclShape, V, Nat, Vec<String>)> {
    let step = decode_decl(get_field(v, "step")?)?;
    let seed = get_field(v, "seed")?.clone();
    let count = nat_field(v, "count")?;
    let step_fields = str_list_field(v, "stepFields")?;
    Ok((step, seed, count, step_fields))
}

fn encode_fold_outcome(o: &FoldOutcome<V>) -> V {
    match o {
        FoldOutcome::Trace(states) => serde_json::json!({"tag": "trace", "states": states}),
        FoldOutcome::Stopped(states, stopped) => {
            serde_json::json!({"tag": "stopped", "states": states, "stopped": encode_stage_projection_failed(stopped)})
        }
    }
}

fn op_iteration_fold(input: &V) -> D<V> {
    let (step, seed, count, step_fields) = decode_fold_req(input)?;
    let immediate = immediate_of::<V, V, _>(step.identity, step.required, move |x| {
        apply_function_form(&step.form, x)
    });
    let outcome = fold_output(&immediate, &step_fields, seed, &count);
    Ok(encode_fold_outcome(&outcome))
}

enum StepOutcomeForm {
    Settled,
    Advance(Nat),
}

fn decode_step_outcome_form(v: &V) -> D<StepOutcomeForm> {
    let tag = str_field(v, "tag")?;
    match tag.as_str() {
        "settled" => Ok(StepOutcomeForm::Settled),
        "advance" => Ok(StepOutcomeForm::Advance(nat_field(v, "measure")?)),
        other => Err(shape(format!("unknown step outcome tag {other}"))),
    }
}

fn decode_recurse_table(v: &V) -> D<Vec<(V, StepOutcomeForm)>> {
    as_arr(v)?
        .iter()
        .map(|entry| {
            let payload = get_field(entry, "payload")?.clone();
            let form = decode_step_outcome_form(get_field(entry, "outcome")?)?;
            Ok((payload, form))
        })
        .collect()
}

fn recurse_step_output(
    table: &[(V, StepOutcomeForm)],
    next_form: &FunctionForm,
    state: &V,
) -> StepOutcome<V> {
    match table.iter().find(|(p, _)| p == state) {
        Some((_, StepOutcomeForm::Settled)) => StepOutcome::Settled(state.clone()),
        Some((_, StepOutcomeForm::Advance(m))) => {
            StepOutcome::Advance(apply_function_form(next_form, state), m.clone())
        }
        None => StepOutcome::Settled(state.clone()),
    }
}

type RecurseReqShape = (
    Vec<String>,
    Vec<(V, StepOutcomeForm)>,
    FunctionForm,
    V,
    Vec<String>,
);

fn decode_recurse_req(v: &V) -> D<RecurseReqShape> {
    let required = str_list_field(v, "required")?;
    let table = decode_recurse_table(get_field(v, "table")?)?;
    let next_form = decode_function_form(get_field(v, "next")?)?;
    let seed = get_field(v, "seed")?.clone();
    let step_fields = str_list_field(v, "stepFields")?;
    Ok((required, table, next_form, seed, step_fields))
}

fn encode_recurse_outcome(o: &RecurseOutcome<V>) -> V {
    match o {
        RecurseOutcome::Settled(value, steps) => {
            serde_json::json!({"tag": "settled", "value": value, "steps": nat_to_json(steps)})
        }
        RecurseOutcome::DidNotDecrease(position, state, measure, previous_measure) => {
            serde_json::json!({
                "tag": "did_not_decrease",
                "position": nat_to_json(position),
                "state": state,
                "measure": nat_to_json(measure),
                "previousMeasure": nat_to_json(previous_measure),
            })
        }
        RecurseOutcome::ProjectionFailed(last_state, stopped) => serde_json::json!({
            "tag": "projection_failed",
            "lastState": last_state,
            "stopped": encode_stage_projection_failed(stopped),
        }),
    }
}

fn op_iteration_recurse(input: &V) -> D<V> {
    let (required, table, next_form, seed, step_fields) = decode_recurse_req(input)?;
    let identity = "necoherence.iteration.recurse.adapter.step".to_string();
    let immediate = immediate_of::<V, StepOutcome<V>, _>(identity, required, move |x| {
        recurse_step_output(&table, &next_form, x)
    });
    let outcome = recurse_output(&immediate, &step_fields, seed);
    Ok(encode_recurse_outcome(&outcome))
}

fn json_elements(v: &V) -> Vec<V> {
    v.as_array().cloned().unwrap_or_default()
}

fn closure_elem_to_json(s: &str) -> V {
    serde_json::from_str(s).unwrap_or(V::Null)
}

fn closure_elem_of_json(v: &V) -> String {
    serde_json::to_string(v).unwrap_or_default()
}

type ClosureReqShape = (DeclShape, BTreeSet<String>, BTreeSet<String>, Vec<String>);

fn decode_closure_req(v: &V) -> D<ClosureReqShape> {
    let step = decode_decl(get_field(v, "step")?)?;
    let carrier: BTreeSet<String> = arr_field(v, "carrier")?
        .iter()
        .map(closure_elem_of_json)
        .collect();
    let seed: BTreeSet<String> = arr_field(v, "seed")?
        .iter()
        .map(closure_elem_of_json)
        .collect();
    let step_fields = str_list_field(v, "stepFields")?;
    Ok((step, carrier, seed, step_fields))
}

fn encode_closure_elems(elems: &BTreeSet<String>) -> V {
    V::Array(elems.iter().map(|s| closure_elem_to_json(s)).collect())
}

fn encode_closure_outcome(o: &ClosureOutcome<String>) -> V {
    match o {
        ClosureOutcome::Fixpoint(result, position) => serde_json::json!({
            "tag": "fixpoint", "result": encode_closure_elems(result), "position": nat_to_json(position),
        }),
        ClosureOutcome::Violation(position, current, produced) => serde_json::json!({
            "tag": "violation", "position": nat_to_json(position),
            "current": encode_closure_elems(current), "produced": encode_closure_elems(produced),
        }),
        ClosureOutcome::ProjectionFailed(current, stopped) => serde_json::json!({
            "tag": "projection_failed", "current": encode_closure_elems(current),
            "stopped": encode_stage_projection_failed(stopped),
        }),
    }
}

fn op_iteration_closure(input: &V) -> D<V> {
    let (step, carrier, seed, step_fields) = decode_closure_req(input)?;
    let immediate = immediate_of::<ClosureState<String>, BTreeSet<String>, _>(
        step.identity,
        step.required,
        move |cs: &ClosureState<String>| {
            let elems_json = V::Array(
                cs.elements
                    .iter()
                    .map(|s| closure_elem_to_json(s))
                    .collect(),
            );
            let produced_json = apply_function_form(&step.form, &elems_json);
            json_elements(&produced_json)
                .iter()
                .map(closure_elem_of_json)
                .collect()
        },
    );
    let outcome = closure_output(&immediate, &step_fields, carrier, seed);
    Ok(encode_closure_outcome(&outcome))
}

fn decode_store_entry(v: &V) -> D<(ResourceId, Revision, V)> {
    Ok((
        decode_resource_id(get_field(v, "resource")?)?,
        decode_revision(get_field(v, "revision")?)?,
        get_field(v, "payload")?.clone(),
    ))
}

fn decode_store(v: &V) -> D<Store<V>> {
    let entries = as_arr(v)?
        .iter()
        .map(decode_store_entry)
        .collect::<D<Vec<_>>>()?;
    Ok(store_of(entries))
}

fn encode_store(s: &Store<V>) -> V {
    V::Array(
        store_entries(s)
            .map(|(r, rev, payload)| {
                serde_json::json!({"resource": encode_resource_id(r), "revision": encode_revision(rev), "payload": payload})
            })
            .collect(),
    )
}

fn encode_observe(o: &Observed<V>) -> V {
    match o {
        Observed::Found(r, a) => {
            serde_json::json!({"tag": "found", "revision": encode_revision(r), "payload": a})
        }
        Observed::Unknown(u) => {
            serde_json::json!({"tag": "unknown", "resource": encode_resource_id(&u.resource)})
        }
    }
}

fn encode_store_apply_outcome(o: &Outcome<(V, Store<V>), UnknownResource, StaleBasis, Never>) -> V {
    match o {
        Outcome::Applied((intent, s)) => {
            serde_json::json!({"tag": "applied", "intent": intent, "store": encode_store(s)})
        }
        Outcome::Rejected(u) => {
            serde_json::json!({"tag": "rejected", "resource": encode_resource_id(&u.resource)})
        }
        Outcome::Conflicted(k) => {
            serde_json::json!({"tag": "conflicted", "expected": encode_revision(&k.expected), "actual": encode_revision(&k.actual)})
        }
        Outcome::BoundaryFailed(f) => f.elim(),
    }
}

fn op_store_store_of(input: &V) -> D<V> {
    Ok(encode_store(&decode_store(input)?))
}

fn op_store_store_entries(input: &V) -> D<V> {
    let s = decode_store(get_field(input, "store")?)?;
    Ok(encode_store(&s))
}

fn op_store_observe(input: &V) -> D<V> {
    let s = decode_store(get_field(input, "store")?)?;
    let resource = decode_resource_id(get_field(input, "resource")?)?;
    Ok(encode_observe(&observe(&s, &resource)))
}

fn op_store_apply(input: &V) -> D<V> {
    let s = decode_store(get_field(input, "store")?)?;
    let command = decode_command(get_field(input, "command")?)?;
    Ok(encode_store_apply_outcome(&store::apply(&s, command)))
}

fn op_store_world_of(input: &V) -> D<V> {
    let s = decode_store(input)?;
    Ok(encode_world(&world_of_store(&s)))
}

fn decode_call_record(v: &V) -> D<CallRecord<V, V>> {
    let declaration = str_field(v, "declaration")?;
    let input = get_field(v, "input")?.clone();
    let product = get_field(v, "product")?.clone();
    let basis_j = get_field(v, "basis")?;
    let basis = if basis_j.is_null() {
        None
    } else {
        Some(decode_basis(basis_j)?)
    };
    Ok(CallRecord {
        declaration,
        input,
        product,
        basis,
    })
}

fn op_record_record_of(input: &V) -> D<V> {
    let declaration = str_field(input, "declaration")?;
    let ins = get_field(input, "input")?.clone();
    let product = get_field(input, "product")?.clone();
    let r = record_of(declaration, ins, product);
    Ok(serde_json::json!({
        "declaration": r.declaration, "input": r.input, "product": r.product,
        "basis": r.basis.as_ref().map(encode_basis).unwrap_or(V::Null),
    }))
}

fn op_record_record_on_basis(input: &V) -> D<V> {
    let declaration = str_field(input, "declaration")?;
    let ins = get_field(input, "input")?.clone();
    let product = get_field(input, "product")?.clone();
    let basis = decode_basis(get_field(input, "basis")?)?;
    let r = record_on_basis(declaration, ins, product, basis);
    Ok(serde_json::json!({
        "declaration": r.declaration, "input": r.input, "product": r.product,
        "basis": r.basis.as_ref().map(encode_basis).unwrap_or(V::Null),
    }))
}

fn op_record_has_edge(input: &V) -> D<V> {
    let earlier = decode_call_record(get_field(input, "earlier")?)?;
    let later = decode_call_record(get_field(input, "later")?)?;
    Ok(serde_json::json!({"holds": has_edge(&earlier, &later)}))
}

fn encode_divergence(d: &Divergence) -> V {
    match d {
        Divergence::WorldAhead {
            resource,
            recorded,
            actual,
        } => serde_json::json!({
            "tag": "world_ahead", "resource": encode_resource_id(resource),
            "recorded": encode_revision(recorded), "actual": encode_revision(actual),
        }),
        Divergence::WorldBehind {
            resource,
            recorded,
            actual,
        } => serde_json::json!({
            "tag": "world_behind", "resource": encode_resource_id(resource),
            "recorded": encode_revision(recorded), "actual": encode_revision(actual),
        }),
        Divergence::UnknownToWorld { resource, recorded } => serde_json::json!({
            "tag": "unknown_to_world", "resource": encode_resource_id(resource), "recorded": encode_revision(recorded),
        }),
    }
}

fn encode_reconciliation(r: &Reconciliation) -> V {
    let sorted = sorted_divergences(r);
    serde_json::json!({
        "divergences": sorted.iter().map(encode_divergence).collect::<Vec<_>>(),
        "unbased": nat_to_json(&r.unbased), "dropped": nat_to_json(&r.dropped),
    })
}

fn decode_option_basis(v: &V) -> D<Option<Basis>> {
    if v.is_null() {
        Ok(None)
    } else {
        Ok(Some(decode_basis(v)?))
    }
}

fn op_reconcile_reconcile(input: &V) -> D<V> {
    let bases = arr_field(input, "bases")?
        .iter()
        .map(decode_option_basis)
        .collect::<D<Vec<_>>>()?;
    let world = decode_world(get_field(input, "world")?)?;
    let dropped = nat_field(input, "dropped")?;
    Ok(encode_reconciliation(&reconcile(&bases, &world, dropped)))
}

fn op_reconcile_coherent(input: &V) -> D<V> {
    let divergences = arr_field(input, "divergences")?
        .iter()
        .map(|j| {
            let tag = str_field(j, "tag")?;
            match tag.as_str() {
                "world_ahead" => Ok(Divergence::WorldAhead {
                    resource: decode_resource_id(get_field(j, "resource")?)?,
                    recorded: decode_revision(get_field(j, "recorded")?)?,
                    actual: decode_revision(get_field(j, "actual")?)?,
                }),
                "world_behind" => Ok(Divergence::WorldBehind {
                    resource: decode_resource_id(get_field(j, "resource")?)?,
                    recorded: decode_revision(get_field(j, "recorded")?)?,
                    actual: decode_revision(get_field(j, "actual")?)?,
                }),
                "unknown_to_world" => Ok(Divergence::UnknownToWorld {
                    resource: decode_resource_id(get_field(j, "resource")?)?,
                    recorded: decode_revision(get_field(j, "recorded")?)?,
                }),
                other => Err(shape(format!("unknown divergence tag {other}"))),
            }
        })
        .collect::<D<Vec<_>>>()?;
    let unbased = nat_field(input, "unbased")?;
    let dropped = nat_field(input, "dropped")?;
    let r = Reconciliation {
        divergences,
        unbased,
        dropped,
    };
    Ok(serde_json::json!({"coherent": coherent(&r)}))
}

fn decode_policy(v: &V) -> D<RequestPolicy> {
    match as_str(v)? {
        "latestWins" => Ok(RequestPolicy::LatestWins),
        "fifo" => Ok(RequestPolicy::Fifo),
        "allExecute" => Ok(RequestPolicy::AllExecute),
        other => Err(shape(format!("unknown policy {other}"))),
    }
}

fn encode_policy(p: RequestPolicy) -> V {
    V::String(
        match p {
            RequestPolicy::LatestWins => "latestWins",
            RequestPolicy::Fifo => "fifo",
            RequestPolicy::AllExecute => "allExecute",
        }
        .to_string(),
    )
}

fn decode_phase(v: &V) -> D<RequestPhase> {
    match as_str(v)? {
        "pending" => Ok(RequestPhase::Pending),
        "preparing" => Ok(RequestPhase::Preparing),
        "publishing" => Ok(RequestPhase::Publishing),
        "published" => Ok(RequestPhase::Published),
        "superseded" => Ok(RequestPhase::Superseded),
        "cancelled" => Ok(RequestPhase::Cancelled),
        "failed" => Ok(RequestPhase::Failed),
        other => Err(shape(format!("unknown phase {other}"))),
    }
}

fn encode_phase(p: RequestPhase) -> V {
    V::String(
        match p {
            RequestPhase::Pending => "pending",
            RequestPhase::Preparing => "preparing",
            RequestPhase::Publishing => "publishing",
            RequestPhase::Published => "published",
            RequestPhase::Superseded => "superseded",
            RequestPhase::Cancelled => "cancelled",
            RequestPhase::Failed => "failed",
        }
        .to_string(),
    )
}

fn decode_effect_class(v: &V) -> D<RequestEffectClass> {
    match as_str(v)? {
        "pure" => Ok(RequestEffectClass::Pure),
        "orderedEffect" => Ok(RequestEffectClass::OrderedEffect),
        other => Err(shape(format!("unknown effect class {other}"))),
    }
}

fn encode_effect_class(c: RequestEffectClass) -> V {
    V::String(
        match c {
            RequestEffectClass::Pure => "pure",
            RequestEffectClass::OrderedEffect => "orderedEffect",
        }
        .to_string(),
    )
}

fn decode_identity(v: &V) -> D<RequestIdentity> {
    Ok(RequestIdentity {
        kind: str_field(v, "kind")?,
        provenance: str_field(v, "provenance")?,
        revision: nat_field(v, "revision")?,
    })
}

fn encode_identity(i: &RequestIdentity) -> V {
    serde_json::json!({"kind": i.kind, "provenance": i.provenance, "revision": nat_to_json(&i.revision)})
}

fn decode_footprint(v: &V) -> D<RequestFootprint> {
    Ok(RequestFootprint {
        reads: str_list_field(v, "reads")?,
        writes: str_list_field(v, "writes")?,
        effect_class: decode_effect_class(get_field(v, "effectClass")?)?,
    })
}

fn encode_footprint(f: &RequestFootprint) -> V {
    serde_json::json!({"reads": f.reads, "writes": f.writes, "effectClass": encode_effect_class(f.effect_class)})
}

fn decode_demand(v: &V) -> D<ResourceDemand> {
    Ok(ResourceDemand {
        pending: nat_field(v, "pending")?,
        in_flight: nat_field(v, "inFlight")?,
        concurrent: nat_field(v, "concurrent")?,
    })
}

fn encode_demand(d: &ResourceDemand) -> V {
    serde_json::json!({"pending": nat_to_json(&d.pending), "inFlight": nat_to_json(&d.in_flight), "concurrent": nat_to_json(&d.concurrent)})
}

fn decode_safety_limit(v: &V) -> D<ConfiguredSafetyLimit> {
    Ok(ConfiguredSafetyLimit {
        resource: str_field(v, "resource")?,
        maximum: nat_field(v, "maximum")?,
    })
}

fn encode_safety_limit(l: &ConfiguredSafetyLimit) -> V {
    serde_json::json!({"resource": l.resource, "maximum": nat_to_json(&l.maximum)})
}

fn decode_budget(v: &V) -> D<ResourceBudget> {
    Ok(ResourceBudget {
        pending_maximum: decode_safety_limit(get_field(v, "pendingMaximum")?)?,
        in_flight_maximum: decode_safety_limit(get_field(v, "inFlightMaximum")?)?,
        concurrent_maximum: decode_safety_limit(get_field(v, "concurrentMaximum")?)?,
    })
}

fn encode_budget(b: &ResourceBudget) -> V {
    serde_json::json!({
        "pendingMaximum": encode_safety_limit(&b.pending_maximum),
        "inFlightMaximum": encode_safety_limit(&b.in_flight_maximum),
        "concurrentMaximum": encode_safety_limit(&b.concurrent_maximum),
    })
}

fn decode_evidence(v: &V) -> D<EvidenceVersion> {
    Ok(EvidenceVersion {
        identifier: str_field(v, "identifier")?,
        digest: str_field(v, "digest")?,
        artifact_path: str_field(v, "artifactPath")?,
    })
}

fn encode_evidence(e: &EvidenceVersion) -> V {
    serde_json::json!({"identifier": e.identifier, "digest": e.digest, "artifactPath": e.artifact_path})
}

fn decode_denial(v: &V) -> D<PermissionDenial> {
    Ok(PermissionDenial::Denial(as_str(v)?.to_string()))
}

fn encode_denial(p: &PermissionDenial) -> V {
    let PermissionDenial::Denial(s) = p;
    V::String(s.clone())
}

fn decode_meaning_permission(v: &V) -> D<MeaningPermission> {
    let tag = str_field(v, "tag")?;
    match tag.as_str() {
        "permitted" => {
            let identity = decode_identity(get_field(v, "identity")?)?;
            let evidence = arr_field(v, "evidence")?
                .iter()
                .map(decode_evidence)
                .collect::<D<Vec<_>>>()?;
            Ok(MeaningPermission::Permitted(identity, evidence))
        }
        "ordered" => {
            let identity = decode_identity(get_field(v, "identity")?)?;
            let evidence = arr_field(v, "evidence")?
                .iter()
                .map(decode_evidence)
                .collect::<D<Vec<_>>>()?;
            Ok(MeaningPermission::Ordered(identity, evidence))
        }
        "denied" => {
            let identity = decode_identity(get_field(v, "identity")?)?;
            let reason = decode_denial(get_field(v, "reason")?)?;
            Ok(MeaningPermission::Denied(identity, reason))
        }
        other => Err(shape(format!("unknown meaning permission tag {other}"))),
    }
}

fn encode_meaning_permission(m: &MeaningPermission) -> V {
    match m {
        MeaningPermission::Permitted(identity, evidence) => serde_json::json!({
            "tag": "permitted", "identity": encode_identity(identity),
            "evidence": evidence.iter().map(encode_evidence).collect::<Vec<_>>(),
        }),
        MeaningPermission::Ordered(identity, evidence) => serde_json::json!({
            "tag": "ordered", "identity": encode_identity(identity),
            "evidence": evidence.iter().map(encode_evidence).collect::<Vec<_>>(),
        }),
        MeaningPermission::Denied(identity, reason) => serde_json::json!({
            "tag": "denied", "identity": encode_identity(identity), "reason": encode_denial(reason),
        }),
    }
}

fn decode_handle(v: &V) -> D<ExecutionHandle> {
    Ok(ExecutionHandle {
        value: as_str(v)?.to_string(),
    })
}

fn encode_handle(h: &ExecutionHandle) -> V {
    V::String(h.value.clone())
}

fn decode_cost_selection(v: &V) -> D<CostSelection> {
    let tag = str_field(v, "tag")?;
    let identity = decode_identity(get_field(v, "identity")?)?;
    let evidence = decode_evidence(get_field(v, "evidence")?)?;
    let cost = nat_field(v, "cost")?;
    match tag.as_str() {
        "executeNow" => Ok(CostSelection::ExecuteNow(identity, evidence, cost)),
        "remainPending" => Ok(CostSelection::RemainPending(identity, evidence, cost)),
        other => Err(shape(format!("unknown cost selection tag {other}"))),
    }
}

fn encode_cost_selection(c: &CostSelection) -> V {
    match c {
        CostSelection::ExecuteNow(identity, evidence, cost) => serde_json::json!({
            "tag": "executeNow", "identity": encode_identity(identity),
            "evidence": encode_evidence(evidence), "cost": nat_to_json(cost),
        }),
        CostSelection::RemainPending(identity, evidence, cost) => serde_json::json!({
            "tag": "remainPending", "identity": encode_identity(identity),
            "evidence": encode_evidence(evidence), "cost": nat_to_json(cost),
        }),
    }
}

fn decode_request_entry(v: &V) -> D<RequestEntry> {
    let identity = decode_identity(get_field(v, "identity")?)?;
    let footprint = decode_footprint(get_field(v, "footprint")?)?;
    let demand = decode_demand(get_field(v, "demand")?)?;
    let phase = decode_phase(get_field(v, "phase")?)?;
    let meaning_permission = decode_meaning_permission(get_field(v, "meaningPermission")?)?;
    let cost_j = get_field(v, "costSelection")?;
    let cost_selection = if cost_j.is_null() {
        None
    } else {
        Some(decode_cost_selection(cost_j)?)
    };
    let handle_j = get_field(v, "executionHandle")?;
    let execution_handle = if handle_j.is_null() {
        None
    } else {
        Some(decode_handle(handle_j)?)
    };
    Ok(RequestEntry {
        identity,
        footprint,
        demand,
        phase,
        meaning_permission,
        cost_selection,
        execution_handle,
    })
}

fn encode_request_entry(e: &RequestEntry) -> V {
    serde_json::json!({
        "identity": encode_identity(&e.identity), "footprint": encode_footprint(&e.footprint),
        "demand": encode_demand(&e.demand), "phase": encode_phase(e.phase),
        "meaningPermission": encode_meaning_permission(&e.meaning_permission),
        "costSelection": e.cost_selection.as_ref().map(encode_cost_selection).unwrap_or(V::Null),
        "executionHandle": e.execution_handle.as_ref().map(encode_handle).unwrap_or(V::Null),
    })
}

fn decode_snapshot(v: &V) -> D<RequestProgressionSnapshot> {
    let policy = decode_policy(get_field(v, "policy")?)?;
    let budget = decode_budget(get_field(v, "budget")?)?;
    let current_j = get_field(v, "currentIdentity")?;
    let current_identity = if current_j.is_null() {
        None
    } else {
        Some(decode_identity(current_j)?)
    };
    let entries = arr_field(v, "entries")?
        .iter()
        .map(decode_request_entry)
        .collect::<D<Vec<_>>>()?;
    let revision = nat_field(v, "revision")?;
    Ok(RequestProgressionSnapshot {
        policy,
        budget,
        current_identity,
        entries,
        revision,
    })
}

fn encode_snapshot(s: &RequestProgressionSnapshot) -> V {
    serde_json::json!({
        "policy": encode_policy(s.policy), "budget": encode_budget(&s.budget),
        "currentIdentity": s.current_identity.as_ref().map(encode_identity).unwrap_or(V::Null),
        "entries": s.entries.iter().map(encode_request_entry).collect::<Vec<_>>(),
        "revision": nat_to_json(&s.revision),
    })
}

fn decode_request_input(v: &V) -> D<RequestInput> {
    Ok(RequestInput {
        identity: decode_identity(get_field(v, "identity")?)?,
        footprint: decode_footprint(get_field(v, "footprint")?)?,
        demand: decode_demand(get_field(v, "demand")?)?,
        permission: decode_meaning_permission(get_field(v, "permission")?)?,
    })
}

fn decode_accepted(v: &V) -> D<Accepted> {
    Ok(Accepted {
        identity: decode_identity(get_field(v, "identity")?)?,
    })
}

fn encode_accepted(a: &Accepted) -> V {
    serde_json::json!({"identity": encode_identity(&a.identity)})
}

fn decode_running(v: &V) -> D<Running> {
    Ok(Running {
        identity: decode_identity(get_field(v, "identity")?)?,
        handle: decode_handle(get_field(v, "handle")?)?,
    })
}

fn encode_running(r: &Running) -> V {
    serde_json::json!({"identity": encode_identity(&r.identity), "handle": encode_handle(&r.handle)})
}

fn encode_adapter_command(c: &AdapterCommand) -> V {
    match c {
        AdapterCommand::StartCommand(identity, footprint) => serde_json::json!({
            "tag": "startCommand", "identity": encode_identity(identity), "footprint": encode_footprint(footprint),
        }),
        AdapterCommand::CancelCommand(identity, handle) => serde_json::json!({
            "tag": "cancelCommand", "identity": encode_identity(identity), "handle": encode_handle(handle),
        }),
    }
}

fn decode_adapter_signal(v: &V) -> D<AdapterSignal<V>> {
    let tag = str_field(v, "tag")?;
    match tag.as_str() {
        "started" => Ok(AdapterSignal::Started(
            decode_identity(get_field(v, "identity")?)?,
            decode_handle(get_field(v, "handle")?)?,
        )),
        "completed" => Ok(AdapterSignal::Completed(
            decode_identity(get_field(v, "identity")?)?,
            decode_handle(get_field(v, "handle")?)?,
            get_field(v, "value")?.clone(),
        )),
        "cancelledAtAdapter" => Ok(AdapterSignal::CancelledAtAdapter(
            decode_identity(get_field(v, "identity")?)?,
            decode_handle(get_field(v, "handle")?)?,
        )),
        other => Err(shape(format!("unknown adapter signal tag {other}"))),
    }
}

fn decode_adapter_failure(v: &V) -> D<AdapterFailure> {
    let tag = str_field(v, "tag")?;
    match tag.as_str() {
        "startAdapterFailure" => Ok(AdapterFailure::StartAdapterFailure(
            decode_identity(get_field(v, "identity")?)?,
            str_field(v, "detail")?,
        )),
        "completionAdapterFailure" => Ok(AdapterFailure::CompletionAdapterFailure(
            decode_identity(get_field(v, "identity")?)?,
            decode_handle(get_field(v, "handle")?)?,
            str_field(v, "detail")?,
        )),
        "cancellationAdapterFailure" => Ok(AdapterFailure::CancellationAdapterFailure(
            decode_identity(get_field(v, "identity")?)?,
            decode_handle(get_field(v, "handle")?)?,
            str_field(v, "detail")?,
        )),
        other => Err(shape(format!("unknown adapter failure tag {other}"))),
    }
}

fn decode_adapter_result(v: &V) -> D<AdapterResult<AdapterSignal<V>, AdapterFailure>> {
    let tag = str_field(v, "tag")?;
    match tag.as_str() {
        "appliedSignal" => Ok(AdapterResult::AppliedSignal(decode_adapter_signal(
            get_field(v, "signal")?,
        )?)),
        "adapterFailed" => Ok(AdapterResult::AdapterFailed(decode_adapter_failure(
            get_field(v, "failure")?,
        )?)),
        other => Err(shape(format!("unknown adapter result tag {other}"))),
    }
}

fn encode_submit_failure(f: &SubmitFailure) -> V {
    match f {
        SubmitFailure::DuplicateIdentity(identity) => {
            serde_json::json!({"tag": "duplicateIdentity", "identity": encode_identity(identity)})
        }
        SubmitFailure::PendingLimitExceeded(demand, budget) => serde_json::json!({
            "tag": "pendingLimitExceeded", "demand": encode_demand(demand), "budget": encode_budget(budget),
        }),
    }
}

fn encode_submit_result(r: &SubmitResult) -> V {
    match r {
        SubmitResult::Accepted(snapshot, accepted) => serde_json::json!({
            "tag": "accepted", "snapshot": encode_snapshot(snapshot), "accepted": encode_accepted(accepted),
        }),
        SubmitResult::SubmitRejected(snapshot, failure) => serde_json::json!({
            "tag": "submitRejected", "snapshot": encode_snapshot(snapshot), "failure": encode_submit_failure(failure),
        }),
    }
}

fn decode_starting(v: &V) -> D<Starting> {
    Ok(Starting {
        identity: decode_identity(get_field(v, "identity")?)?,
        command: decode_adapter_command(get_field(v, "command")?)?,
    })
}
fn encode_starting(s: &Starting) -> V {
    serde_json::json!({"identity": encode_identity(&s.identity), "command": encode_adapter_command(&s.command)})
}
fn decode_adapter_command(v: &V) -> D<AdapterCommand> {
    match str_field(v, "tag")?.as_str() {
        "startCommand" => Ok(AdapterCommand::StartCommand(
            decode_identity(get_field(v, "identity")?)?,
            decode_footprint(get_field(v, "footprint")?)?,
        )),
        "cancelCommand" => Ok(AdapterCommand::CancelCommand(
            decode_identity(get_field(v, "identity")?)?,
            decode_handle(get_field(v, "handle")?)?,
        )),
        other => Err(shape(format!("unknown adapter command tag {other}"))),
    }
}
fn encode_start_decision_failure(f: &StartDecisionFailure) -> V {
    match f {
        StartDecisionFailure::UnknownRequest(i) => {
            serde_json::json!({"tag":"unknownRequest","identity":encode_identity(i)})
        }
        StartDecisionFailure::RequestNotPending(i) => {
            serde_json::json!({"tag":"requestNotPending","identity":encode_identity(i)})
        }
        StartDecisionFailure::PolicyOrderBlocked(i) => {
            serde_json::json!({"tag":"policyOrderBlocked","identity":encode_identity(i)})
        }
        StartDecisionFailure::PermissionDenied(i, r) => {
            serde_json::json!({"tag":"permissionDenied","identity":encode_identity(i),"reason":encode_denial(r)})
        }
        StartDecisionFailure::PermissionIdentityMismatch(a, b) => {
            serde_json::json!({"tag":"permissionIdentityMismatch","identity":encode_identity(a),"other":encode_identity(b)})
        }
        StartDecisionFailure::PermissionNotOrdered(i) => {
            serde_json::json!({"tag":"permissionNotOrdered","identity":encode_identity(i)})
        }
        StartDecisionFailure::CostSelectionIdentityMismatch(a, b) => {
            serde_json::json!({"tag":"costSelectionIdentityMismatch","identity":encode_identity(a),"other":encode_identity(b)})
        }
        StartDecisionFailure::InFlightLimitExceeded(d, b) => {
            serde_json::json!({"tag":"inFlightLimitExceeded","demand":encode_demand(d),"budget":encode_budget(b)})
        }
        StartDecisionFailure::ConcurrentLimitExceeded(d, b) => {
            serde_json::json!({"tag":"concurrentLimitExceeded","demand":encode_demand(d),"budget":encode_budget(b)})
        }
    }
}
fn encode_start_decision_result(r: &StartDecisionResult) -> V {
    match r {
        StartDecisionResult::Execute(s, starting, command) => {
            serde_json::json!({"tag":"execute","snapshot":encode_snapshot(s),"starting":encode_starting(starting),"command":encode_adapter_command(command)})
        }
        StartDecisionResult::Deferred(s, a) => {
            serde_json::json!({"tag":"deferred","snapshot":encode_snapshot(s),"accepted":encode_accepted(a)})
        }
        StartDecisionResult::Rejected(s, f) => {
            serde_json::json!({"tag":"rejected","snapshot":encode_snapshot(s),"failure":encode_start_decision_failure(f)})
        }
    }
}
fn encode_start_observation_failure(f: &StartObservationFailure) -> V {
    match f {
        StartObservationFailure::UnknownRequest(i) => {
            serde_json::json!({"tag":"unknownRequest","identity":encode_identity(i)})
        }
        StartObservationFailure::RequestNotStarting(i) => {
            serde_json::json!({"tag":"requestNotStarting","identity":encode_identity(i)})
        }
        StartObservationFailure::StartIdentityMismatch(a, b) => {
            serde_json::json!({"tag":"startIdentityMismatch","identity":encode_identity(a),"other":encode_identity(b)})
        }
        StartObservationFailure::StartSignalMismatch(i) => {
            serde_json::json!({"tag":"startSignalMismatch","identity":encode_identity(i)})
        }
        StartObservationFailure::StartAdapterFailureObserved(i, d) => {
            serde_json::json!({"tag":"startAdapterFailureObserved","identity":encode_identity(i),"detail":d})
        }
    }
}
fn encode_start_observation_result(r: &StartObservationResult) -> V {
    match r {
        StartObservationResult::Publishing(s, running) => {
            serde_json::json!({"tag":"publishing","snapshot":encode_snapshot(s),"running":encode_running(running)})
        }
        StartObservationResult::Failed(s, f) => {
            serde_json::json!({"tag":"failed","snapshot":encode_snapshot(s),"failure":encode_start_observation_failure(f)})
        }
    }
}
fn encode_completion_observation_failure(f: &CompletionObservationFailure) -> V {
    match f {
        CompletionObservationFailure::UnknownCompletion(i) => {
            serde_json::json!({"tag":"unknownCompletion","identity":encode_identity(i)})
        }
        CompletionObservationFailure::CompletionNotRunning(i) => {
            serde_json::json!({"tag":"completionNotRunning","identity":encode_identity(i)})
        }
        CompletionObservationFailure::HandleMismatch(i) => {
            serde_json::json!({"tag":"handleMismatch","identity":encode_identity(i)})
        }
        CompletionObservationFailure::CompletionIdentityMismatch(a, b) => {
            serde_json::json!({"tag":"completionIdentityMismatch","identity":encode_identity(a),"other":encode_identity(b)})
        }
        CompletionObservationFailure::CompletionSignalMismatch(i) => {
            serde_json::json!({"tag":"completionSignalMismatch","identity":encode_identity(i)})
        }
        CompletionObservationFailure::CompletionAdapterFailureObserved(i, d) => {
            serde_json::json!({"tag":"completionAdapterFailureObserved","identity":encode_identity(i),"detail":d})
        }
        CompletionObservationFailure::CancellationAdapterFailureObserved(i, d) => {
            serde_json::json!({"tag":"cancellationAdapterFailureObserved","identity":encode_identity(i),"detail":d})
        }
    }
}
fn encode_completion_observation_result(r: &CompletionObservationResult<V>) -> V {
    match r {
        CompletionObservationResult::Applied(s, i, v) => {
            serde_json::json!({"tag":"applied","snapshot":encode_snapshot(s),"identity":encode_identity(i),"value":v})
        }
        CompletionObservationResult::Superseded(s, i) => {
            serde_json::json!({"tag":"superseded","snapshot":encode_snapshot(s),"identity":encode_identity(i)})
        }
        CompletionObservationResult::Cancelled(s, i) => {
            serde_json::json!({"tag":"cancelled","snapshot":encode_snapshot(s),"identity":encode_identity(i)})
        }
        CompletionObservationResult::Failed(s, f) => {
            serde_json::json!({"tag":"failed","snapshot":encode_snapshot(s),"failure":encode_completion_observation_failure(f)})
        }
    }
}
fn encode_cancel_failure(f: &CancelFailure) -> V {
    match f {
        CancelFailure::UnknownRequest(i) => {
            serde_json::json!({"tag":"unknownRequest","identity":encode_identity(i)})
        }
        CancelFailure::RequestAlreadyTerminal(i) => {
            serde_json::json!({"tag":"requestAlreadyTerminal","identity":encode_identity(i)})
        }
        CancelFailure::MissingExecutionHandle(i) => {
            serde_json::json!({"tag":"missingExecutionHandle","identity":encode_identity(i)})
        }
    }
}
fn encode_cancel_decision_result(r: &CancelDecisionResult) -> V {
    match r {
        CancelDecisionResult::Cancelled(s, i) => {
            serde_json::json!({"tag":"cancelled","snapshot":encode_snapshot(s),"identity":encode_identity(i)})
        }
        CancelDecisionResult::CancelCommand(s, running, command) => {
            serde_json::json!({"tag":"cancelCommand","snapshot":encode_snapshot(s),"running":encode_running(running),"command":encode_adapter_command(command)})
        }
        CancelDecisionResult::Rejected(s, f) => {
            serde_json::json!({"tag":"rejected","snapshot":encode_snapshot(s),"failure":encode_cancel_failure(f)})
        }
    }
}

fn op_request_progression_empty(input: &V) -> D<V> {
    let policy = decode_policy(get_field(input, "policy")?)?;
    let budget = decode_budget(get_field(input, "budget")?)?;
    Ok(encode_snapshot(&empty(policy, budget)))
}

fn op_request_progression_submit(input: &V) -> D<V> {
    let snapshot = decode_snapshot(get_field(input, "snapshot")?)?;
    let request = decode_request_input(get_field(input, "request")?)?;
    Ok(encode_submit_result(&submit(&snapshot, &request)))
}

fn op_request_progression_decide_start(input: &V) -> D<V> {
    let snapshot = decode_snapshot(get_field(input, "snapshot")?)?;
    let accepted = decode_accepted(get_field(input, "accepted")?)?;
    let selection = decode_cost_selection(get_field(input, "selection")?)?;
    Ok(encode_start_decision_result(&decide_start(
        &snapshot, &accepted, &selection,
    )))
}
fn op_request_progression_apply_start_observation(input: &V) -> D<V> {
    let snapshot = decode_snapshot(get_field(input, "snapshot")?)?;
    let starting = decode_starting(get_field(input, "starting")?)?;
    let observed = decode_adapter_result(get_field(input, "observed")?)?;
    Ok(encode_start_observation_result(&apply_start_observation(
        &snapshot, &starting, &observed,
    )))
}
fn op_request_progression_apply_completion_observation(input: &V) -> D<V> {
    let snapshot = decode_snapshot(get_field(input, "snapshot")?)?;
    let running = decode_running(get_field(input, "running")?)?;
    let observed = decode_adapter_result(get_field(input, "observed")?)?;
    Ok(encode_completion_observation_result(
        &apply_completion_observation(&snapshot, &running, &observed),
    ))
}
fn op_request_progression_decide_cancel(input: &V) -> D<V> {
    let snapshot = decode_snapshot(get_field(input, "snapshot")?)?;
    let identity = decode_identity(get_field(input, "identity")?)?;
    Ok(encode_cancel_decision_result(&decide_cancel(
        &snapshot, &identity,
    )))
}

fn op_request_progression_derive_pending(input: &V) -> D<V> {
    let snapshot = decode_snapshot(get_field(input, "snapshot")?)?;
    Ok(encode_demand(&derive_pending(&snapshot)))
}

fn op_request_progression_derive_in_flight(input: &V) -> D<V> {
    let snapshot = decode_snapshot(get_field(input, "snapshot")?)?;
    Ok(encode_demand(&derive_in_flight(&snapshot)))
}

fn op_request_progression_derive_concurrent(input: &V) -> D<V> {
    let snapshot = decode_snapshot(get_field(input, "snapshot")?)?;
    Ok(encode_demand(&derive_concurrent(&snapshot)))
}

fn decode_environment_specification(v: &V) -> D<EnvironmentSpecification> {
    Ok(EnvironmentSpecification {
        max_observation_age: nat_field(v, "maxObservationAge")?,
    })
}

fn decode_capacity_observation(v: &V) -> D<CapacityObservation> {
    Ok(CapacityObservation {
        observed: decode_budget(get_field(v, "observed")?)?,
        observed_at: nat_field(v, "observedAt")?,
    })
}

fn decode_signal_kind(v: &V) -> D<SignalKind> {
    match as_str(v)? {
        "pendingCompletion" => Ok(SignalKind::PendingCompletion),
        "pendingCancellation" => Ok(SignalKind::PendingCancellation),
        other => Err(shape(format!("unknown signal kind {other}"))),
    }
}

fn encode_signal_kind(k: SignalKind) -> V {
    V::String(
        match k {
            SignalKind::PendingCompletion => "pendingCompletion",
            SignalKind::PendingCancellation => "pendingCancellation",
        }
        .to_string(),
    )
}

fn decode_admission_signal(v: &V) -> D<AdmissionSignal> {
    Ok(AdmissionSignal {
        identity: decode_identity(get_field(v, "identity")?)?,
        handle: decode_handle(get_field(v, "handle")?)?,
        kind: decode_signal_kind(get_field(v, "kind")?)?,
    })
}

fn encode_admission_signal(s: &AdmissionSignal) -> V {
    serde_json::json!({"identity": encode_identity(&s.identity), "handle": encode_handle(&s.handle), "kind": encode_signal_kind(s.kind)})
}

fn decode_admission_provenance(v: &V) -> D<AdmissionProvenance> {
    let future_uses = arr_field(v, "futureUses")?
        .iter()
        .map(decode_identity)
        .collect::<D<Vec<_>>>()?;
    let outstanding_signals = arr_field(v, "outstandingSignals")?
        .iter()
        .map(decode_admission_signal)
        .collect::<D<Vec<_>>>()?;
    Ok(AdmissionProvenance {
        future_uses,
        outstanding_signals,
    })
}

fn encode_admission_provenance(p: &AdmissionProvenance) -> V {
    serde_json::json!({
        "futureUses": p.future_uses.iter().map(encode_identity).collect::<Vec<_>>(),
        "outstandingSignals": p.outstanding_signals.iter().map(encode_admission_signal).collect::<Vec<_>>(),
    })
}

fn decode_admission_state(v: &V) -> D<DynamicAdmissionState> {
    Ok(DynamicAdmissionState {
        progression: decode_snapshot(get_field(v, "progression")?)?,
        configured_safety_limit: decode_budget(get_field(v, "configuredSafetyLimit")?)?,
        provenance: decode_admission_provenance(get_field(v, "provenance")?)?,
    })
}

fn encode_admission_state(s: &DynamicAdmissionState) -> V {
    serde_json::json!({
        "progression": encode_snapshot(&s.progression),
        "configuredSafetyLimit": encode_budget(&s.configured_safety_limit),
        "provenance": encode_admission_provenance(&s.provenance),
    })
}

fn decode_admission_input(v: &V) -> D<DynamicAdmissionInput> {
    let state = decode_admission_state(get_field(v, "state")?)?;
    let request = decode_request_input(get_field(v, "request")?)?;
    let environment_specification =
        decode_environment_specification(get_field(v, "environmentSpecification")?)?;
    let capacity_observation = decode_capacity_observation(get_field(v, "capacityObservation")?)?;
    let observed_at = nat_field(v, "observedAt")?;
    let start_j = get_field(v, "start")?;
    let start = if start_j.is_null() {
        None
    } else {
        Some(decode_cost_selection(start_j)?)
    };
    Ok(DynamicAdmissionInput {
        state,
        request,
        environment_specification,
        capacity_observation,
        observed_at,
        start,
    })
}

fn encode_admission_failure(f: &DynamicAdmissionFailure) -> V {
    match f {
        DynamicAdmissionFailure::CapacityObservationUnavailable(age, max_age) => {
            serde_json::json!({
                "tag": "capacityObservationUnavailable", "age": nat_to_json(age), "maxAge": nat_to_json(max_age),
            })
        }
        DynamicAdmissionFailure::ResourceCoordinateMismatch(configured, observed) => {
            serde_json::json!({
                "tag": "resourceCoordinateMismatch", "configuredResource": configured, "observedResource": observed,
            })
        }
        DynamicAdmissionFailure::ConfiguredSafetyLimitExceeded(resource, occupied, allowed) => {
            serde_json::json!({
                "tag": "configuredSafetyLimitExceeded", "resource": resource,
                "occupied": nat_to_json(occupied), "allowed": nat_to_json(allowed),
            })
        }
        DynamicAdmissionFailure::MeaningDenied(identity, reason) => serde_json::json!({
            "tag": "meaningDenied", "identity": encode_identity(identity), "reason": encode_denial(reason),
        }),
        DynamicAdmissionFailure::PermissionIdentityMismatch(a, b) => serde_json::json!({
            "tag": "permissionIdentityMismatch", "requestIdentity": encode_identity(a), "permissionIdentity": encode_identity(b),
        }),
        DynamicAdmissionFailure::AdapterBindingUnavailable(identity) => serde_json::json!({
            "tag": "adapterBindingUnavailable", "identity": encode_identity(identity),
        }),
        DynamicAdmissionFailure::BindingSelectionMismatch(identity) => serde_json::json!({
            "tag": "bindingSelectionMismatch", "identity": encode_identity(identity),
        }),
        DynamicAdmissionFailure::ProgressionSubmitFailure(failure) => serde_json::json!({
            "tag": "progressionSubmitFailure", "failure": encode_submit_failure(failure),
        }),
        DynamicAdmissionFailure::ProgressionStartFailure(failure) => serde_json::json!({
            "tag": "progressionStartFailure", "failure": encode_start_decision_failure(failure),
        }),
        DynamicAdmissionFailure::ProvenanceRetentionRequired(identity) => serde_json::json!({
            "tag": "provenanceRetentionRequired", "identity": encode_identity(identity),
        }),
        DynamicAdmissionFailure::UnknownRequest(identity) => serde_json::json!({
            "tag": "unknownRequest", "identity": encode_identity(identity),
        }),
        DynamicAdmissionFailure::RequestNotTerminal(identity) => serde_json::json!({
            "tag": "requestNotTerminal", "identity": encode_identity(identity),
        }),
    }
}

fn encode_admission_decision(d: &AdmissionDecision) -> V {
    match d {
        AdmissionDecision::Submitted(state, accepted) => serde_json::json!({
            "tag": "submitted", "state": encode_admission_state(state), "accepted": encode_accepted(accepted),
        }),
        AdmissionDecision::Started(state, result) => serde_json::json!({
            "tag": "started", "state": encode_admission_state(state), "result": encode_start_decision_result(result),
        }),
        AdmissionDecision::Coalesced(state, identity) => serde_json::json!({
            "tag": "coalesced", "state": encode_admission_state(state), "identity": encode_identity(identity),
        }),
    }
}

fn encode_provenance_erasure_witness(w: &ProvenanceErasureWitness) -> V {
    match w {
        ProvenanceErasureWitness::Erased(identity) => {
            serde_json::json!({"tag": "erased", "identity": encode_identity(identity)})
        }
        ProvenanceErasureWitness::Retained(identity, reason) => serde_json::json!({
            "tag": "retained", "identity": encode_identity(identity), "reason": reason,
        }),
    }
}

fn encode_coalescing_witness(w: &CoalescingWitness) -> V {
    match w {
        CoalescingWitness::Coalesced(identity) => {
            serde_json::json!({"tag": "coalesced", "identity": encode_identity(identity)})
        }
        CoalescingWitness::NotCoalesced(reason) => {
            serde_json::json!({"tag": "notCoalesced", "reason": reason})
        }
    }
}

fn encode_admission_result(r: &DynamicAdmissionResult) -> V {
    serde_json::json!({
        "effectiveBudget": encode_budget(&r.effective_budget),
        "admissionDecision": encode_admission_decision(&r.admission_decision),
        "futureUseSet": r.future_use_set.identities.iter().map(encode_identity).collect::<Vec<_>>(),
        "outstandingSignalSet": r.outstanding_signal_set.signals.iter().map(encode_admission_signal).collect::<Vec<_>>(),
        "provenanceErasureWitness": r.provenance_erasure_witness.as_ref().map(encode_provenance_erasure_witness).unwrap_or(V::Null),
        "coalescingWitness": encode_coalescing_witness(&r.coalescing_witness),
    })
}

fn encode_admission_outcome(o: &Outcome2<DynamicAdmissionResult, DynamicAdmissionFailure>) -> V {
    match o {
        Outcome2::Applied(r) => {
            serde_json::json!({"tag": "applied", "value": encode_admission_result(r)})
        }
        Outcome2::Rejected(f) => {
            serde_json::json!({"tag": "rejected", "failure": encode_admission_failure(f)})
        }
    }
}

fn encode_elision_outcome(
    o: &Outcome2<(DynamicAdmissionState, ProvenanceErasureWitness), DynamicAdmissionFailure>,
) -> V {
    match o {
        Outcome2::Applied((state, witness)) => serde_json::json!({
            "tag": "applied", "state": encode_admission_state(state), "witness": encode_provenance_erasure_witness(witness),
        }),
        Outcome2::Rejected(f) => {
            serde_json::json!({"tag": "rejected", "failure": encode_admission_failure(f)})
        }
    }
}

fn op_dynamic_admission_elide_admission_provenance(input: &V) -> D<V> {
    let state = decode_admission_state(get_field(input, "state")?)?;
    let identity = decode_identity(get_field(input, "identity")?)?;
    Ok(encode_elision_outcome(&elide_admission_provenance(
        &state, &identity,
    )))
}

fn op_dynamic_admission_admit_dynamic_request(input: &V) -> D<V> {
    let admission_input = decode_admission_input(input)?;
    Ok(encode_admission_outcome(&admit_dynamic_request(
        &admission_input,
    )))
}

fn decode_normalized_path(v: &V) -> D<NormalizedPath> {
    Ok(NormalizedPath {
        root: as_bool(get_field(v, "root")?)?,
        segments: str_list_field(v, "segments")?,
    })
}

fn encode_normalized_path(p: &NormalizedPath) -> V {
    serde_json::json!({"root": p.root, "segments": p.segments})
}

fn decode_content_digest(v: &V) -> D<ContentDigest> {
    Ok(ContentDigest {
        value: as_str(v)?.to_string(),
    })
}

fn encode_content_digest(d: &ContentDigest) -> V {
    V::String(d.value.clone())
}

fn decode_byte(v: &V) -> D<u8> {
    let s = as_str(v)?;
    let n = nat_of_str(s)?;
    let n_u32: u32 = n
        .to_string()
        .parse()
        .map_err(|_| shape("byte out of range"))?;
    if n_u32 < 256 {
        Ok(n_u32 as u8)
    } else {
        Err(shape("byte out of range"))
    }
}

fn encode_byte(b: u8) -> V {
    V::String(b.to_string())
}

fn decode_bytes(v: &V) -> D<Vec<u8>> {
    as_arr(v)?.iter().map(decode_byte).collect()
}

fn encode_bytes(bs: &[u8]) -> V {
    V::Array(bs.iter().map(|b| encode_byte(*b)).collect())
}

fn decode_file_record(v: &V) -> D<FileRecord> {
    Ok(FileRecord {
        digest: decode_content_digest(get_field(v, "digest")?)?,
        bytes: decode_bytes(get_field(v, "bytes")?)?,
    })
}

fn decode_external_file_state(v: &V) -> D<ExternalFileState> {
    let files = arr_field(v, "files")?
        .iter()
        .map(|e| {
            Ok((
                decode_normalized_path(get_field(e, "path")?)?,
                decode_file_record(get_field(e, "record")?)?,
            ))
        })
        .collect::<D<Vec<_>>>()?;
    let read_failures = arr_field(v, "readFailures")?
        .iter()
        .map(decode_normalized_path)
        .collect::<D<Vec<_>>>()?;
    let write_failures = arr_field(v, "writeFailures")?
        .iter()
        .map(decode_normalized_path)
        .collect::<D<Vec<_>>>()?;
    Ok(ExternalFileState::new(files, read_failures, write_failures))
}

fn encode_file_record(r: &FileRecord) -> V {
    serde_json::json!({"digest": encode_content_digest(&r.digest), "bytes": encode_bytes(&r.bytes)})
}

fn encode_external_file_state(s: &ExternalFileState) -> V {
    serde_json::json!({
        "files": s.files().iter().map(|(path, record)| {
            serde_json::json!({"path": encode_normalized_path(path), "record": encode_file_record(record)})
        }).collect::<Vec<_>>(),
        "readFailures": s.read_failures.iter().map(encode_normalized_path).collect::<Vec<_>>(),
        "writeFailures": s.write_failures.iter().map(encode_normalized_path).collect::<Vec<_>>(),
    })
}

fn decode_digests(v: &V) -> D<Digests> {
    let entries = as_arr(v)?
        .iter()
        .map(|e| {
            Ok((
                decode_resource_id(get_field(e, "resource")?)?,
                decode_content_digest(get_field(e, "digest")?)?,
            ))
        })
        .collect::<D<Vec<_>>>()?;
    Ok(Digests::new(entries))
}

fn encode_digests(d: &Digests) -> V {
    V::Array(
        d.entries()
            .iter()
            .map(|(r, digest)| serde_json::json!({"resource": encode_resource_id(r), "digest": encode_content_digest(digest)}))
            .collect(),
    )
}

fn encode_digest_lookup(l: &DigestLookup) -> V {
    match l {
        DigestLookup::Found(d) => {
            serde_json::json!({"tag": "found", "digest": encode_content_digest(d)})
        }
        DigestLookup::Unobserved(u) => {
            serde_json::json!({"tag": "unobserved", "resource": encode_resource_id(&u.resource)})
        }
    }
}

fn encode_observation<A>(encode_payload: impl Fn(&A) -> V, o: &Observation<A>) -> V {
    serde_json::json!({"payload": encode_payload(&o.payload), "basis": encode_basis(&o.basis), "observedAt": nat_to_json(&o.observed_at)})
}

fn encode_file_snapshot(s: &FileSnapshot) -> V {
    serde_json::json!({"path": encode_normalized_path(&s.path), "contents": encode_bytes(&s.contents), "digest": encode_content_digest(&s.digest)})
}

fn encode_track_result(r: &TrackResult) -> V {
    match r {
        Outcome::Applied(t) => serde_json::json!({
            "tag": "applied", "observation": encode_observation(encode_revision, &t.observation), "world": encode_world(&t.world),
        }),
        Outcome::Rejected(f) => f.elim(),
        Outcome::Conflicted(f) => f.elim(),
        Outcome::BoundaryFailed(f) => f.elim(),
    }
}

fn encode_read_result(r: &ReadResult) -> V {
    match r {
        Outcome::Applied(r) => serde_json::json!({
            "tag": "applied", "observation": encode_observation(encode_file_snapshot, &r.observation),
            "world": encode_world(&r.world), "digests": encode_digests(&r.digests),
        }),
        Outcome::Rejected(u) => {
            serde_json::json!({"tag": "rejected", "resource": encode_resource_id(&u.resource)})
        }
        Outcome::Conflicted(f) => f.elim(),
        Outcome::BoundaryFailed(f) => {
            serde_json::json!({"tag": "boundaryFailed", "path": encode_normalized_path(&f.path)})
        }
    }
}

fn decode_replace_contents(v: &V) -> D<ReplaceContents> {
    Ok(ReplaceContents {
        new_contents: decode_bytes(get_field(v, "newContents")?)?,
        new_digest: decode_content_digest(get_field(v, "newDigest")?)?,
    })
}

fn encode_replace_rejection(r: &ReplaceRejection) -> V {
    match r {
        ReplaceRejection::ResourcePathMismatch(m) => serde_json::json!({
            "tag": "resourcePathMismatch", "resource": encode_resource_id(&m.resource), "path": encode_normalized_path(&m.path),
        }),
        ReplaceRejection::UnknownResource(u) => {
            serde_json::json!({"tag": "unknownResource", "resource": encode_resource_id(&u.resource)})
        }
        ReplaceRejection::UnobservedContents(u) => {
            serde_json::json!({"tag": "unobservedContents", "resource": encode_resource_id(&u.resource)})
        }
    }
}

fn encode_replace_conflict(c: &ReplaceConflict) -> V {
    match c {
        ReplaceConflict::StaleBasis(s) => serde_json::json!({
            "tag": "staleBasis", "expected": encode_revision(&s.expected), "actual": encode_revision(&s.actual),
        }),
        ReplaceConflict::ExternalMutation(m) => serde_json::json!({
            "tag": "externalMutation", "expected": encode_content_digest(&m.expected), "actual": encode_content_digest(&m.actual),
        }),
    }
}

fn encode_replace_result(r: &ReplaceResult) -> V {
    match r {
        Outcome::Applied(r) => serde_json::json!({
            "tag": "applied", "observation": encode_observation(encode_file_snapshot, &r.observation),
            "world": encode_world(&r.world), "digests": encode_digests(&r.digests),
            "state": encode_external_file_state(&r.state),
        }),
        Outcome::Rejected(r) => {
            serde_json::json!({"tag": "rejected", "rejection": encode_replace_rejection(r)})
        }
        Outcome::Conflicted(c) => {
            serde_json::json!({"tag": "conflicted", "conflict": encode_replace_conflict(c)})
        }
        Outcome::BoundaryFailed(f) => {
            serde_json::json!({"tag": "boundaryFailed", "path": encode_normalized_path(&f.path)})
        }
    }
}

fn op_file_effect_normalize_path(input: &V) -> D<V> {
    let root = as_bool(get_field(input, "root")?)?;
    let raw = str_list_field(input, "raw")?;
    Ok(encode_normalized_path(&normalize_path(root, &raw)))
}

fn op_file_effect_lookup_digest(input: &V) -> D<V> {
    let digests = decode_digests(get_field(input, "digests")?)?;
    let resource = decode_resource_id(get_field(input, "resource")?)?;
    Ok(encode_digest_lookup(&lookup_digest(&digests, &resource)))
}

fn op_file_effect_set_digest(input: &V) -> D<V> {
    let digests = decode_digests(get_field(input, "digests")?)?;
    let resource = decode_resource_id(get_field(input, "resource")?)?;
    let digest = decode_content_digest(get_field(input, "digest")?)?;
    Ok(encode_digests(&set_digest(&digests, &resource, &digest)))
}

fn op_file_effect_track(input: &V) -> D<V> {
    let path = decode_normalized_path(get_field(input, "path")?)?;
    let world = decode_world(get_field(input, "world")?)?;
    let observed_at = nat_field(input, "observedAt")?;
    Ok(encode_track_result(&track(&TrackReq {
        path,
        world,
        observed_at,
    })))
}

fn op_file_effect_read(input: &V) -> D<V> {
    let path = decode_normalized_path(get_field(input, "path")?)?;
    let world = decode_world(get_field(input, "world")?)?;
    let digests = decode_digests(get_field(input, "digests")?)?;
    let state = decode_external_file_state(get_field(input, "state")?)?;
    let observed_at = nat_field(input, "observedAt")?;
    Ok(encode_read_result(&read(&ReadReq {
        path,
        world,
        digests,
        state,
        observed_at,
    })))
}

fn op_file_effect_replace(input: &V) -> D<V> {
    let intent = decode_replace_contents(get_field(input, "intent")?)?;
    let basis = decode_basis(get_field(input, "basis")?)?;
    let command = Command { intent, basis };
    let path = decode_normalized_path(get_field(input, "path")?)?;
    let world = decode_world(get_field(input, "world")?)?;
    let digests = decode_digests(get_field(input, "digests")?)?;
    let state = decode_external_file_state(get_field(input, "state")?)?;
    let observed_at = nat_field(input, "observedAt")?;
    Ok(encode_replace_result(&replace(&ReplaceReq {
        command,
        path,
        world,
        digests,
        state,
        observed_at,
    })))
}

fn surface_entries() -> Vec<(&'static str, Vec<&'static str>)> {
    vec![
        ("core", vec!["lookup", "bump", "commandOf", "apply"]),
        ("call", vec!["immediateOf", "deferredOf", "io", "issue"]),
        ("iteration", vec!["fold", "recurse", "closure"]),
        (
            "store",
            vec!["storeOf", "storeEntries", "observe", "apply", "worldOf"],
        ),
        ("record", vec!["recordOf", "recordOnBasis", "hasEdge"]),
        ("reconcile", vec!["reconcile", "coherent"]),
        (
            "request_progression",
            vec![
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
        (
            "dynamic_admission",
            vec!["elideAdmissionProvenance", "admitDynamicRequest"],
        ),
        ("step_transition", vec!["step"]),
        (
            "file_effect",
            vec![
                "normalizePath",
                "lookupDigest",
                "setDigest",
                "track",
                "read",
                "replace",
            ],
        ),
    ]
}

fn known_features() -> Vec<&'static str> {
    surface_entries().into_iter().map(|(f, _)| f).collect()
}

fn surface_json() -> V {
    serde_json::json!({
        "kind": "surface",
        "features": surface_entries().into_iter().map(|(feature, ops)| {
            serde_json::json!({"feature": feature, "operations": ops})
        }).collect::<Vec<_>>(),
    })
}

fn dispatch(feature: &str, operation: &str, input: &V) -> D<V> {
    match (feature, operation) {
        ("core", "lookup") => op_core_lookup(input),
        ("core", "bump") => op_core_bump(input),
        ("core", "commandOf") => op_core_command_of(input),
        ("core", "apply") => op_core_apply(input),
        ("call", "immediateOf") => op_call_immediate_of(input),
        ("call", "deferredOf") => op_call_deferred_of(input),
        ("call", "io") => op_call_io(input),
        ("call", "issue") => op_call_issue(input),
        ("iteration", "fold") => op_iteration_fold(input),
        ("iteration", "recurse") => op_iteration_recurse(input),
        ("iteration", "closure") => op_iteration_closure(input),
        ("store", "storeOf") => op_store_store_of(input),
        ("store", "storeEntries") => op_store_store_entries(input),
        ("store", "observe") => op_store_observe(input),
        ("store", "apply") => op_store_apply(input),
        ("store", "worldOf") => op_store_world_of(input),
        ("record", "recordOf") => op_record_record_of(input),
        ("record", "recordOnBasis") => op_record_record_on_basis(input),
        ("record", "hasEdge") => op_record_has_edge(input),
        ("reconcile", "reconcile") => op_reconcile_reconcile(input),
        ("reconcile", "coherent") => op_reconcile_coherent(input),
        ("request_progression", "empty") => op_request_progression_empty(input),
        ("request_progression", "submit") => op_request_progression_submit(input),
        ("request_progression", "decideStart") => op_request_progression_decide_start(input),
        ("request_progression", "applyStartObservation") => {
            op_request_progression_apply_start_observation(input)
        }
        ("request_progression", "applyCompletionObservation") => {
            op_request_progression_apply_completion_observation(input)
        }
        ("request_progression", "decideCancel") => op_request_progression_decide_cancel(input),
        ("request_progression", "derivePending") => op_request_progression_derive_pending(input),
        ("request_progression", "deriveInFlight") => op_request_progression_derive_in_flight(input),
        ("request_progression", "deriveConcurrent") => {
            op_request_progression_derive_concurrent(input)
        }
        ("dynamic_admission", "elideAdmissionProvenance") => {
            op_dynamic_admission_elide_admission_provenance(input)
        }
        ("dynamic_admission", "admitDynamicRequest") => {
            op_dynamic_admission_admit_dynamic_request(input)
        }
        ("step_transition", "step") => op_step_transition_step(input),
        ("file_effect", "normalizePath") => op_file_effect_normalize_path(input),
        ("file_effect", "lookupDigest") => op_file_effect_lookup_digest(input),
        ("file_effect", "setDigest") => op_file_effect_set_digest(input),
        ("file_effect", "track") => op_file_effect_track(input),
        ("file_effect", "read") => op_file_effect_read(input),
        ("file_effect", "replace") => op_file_effect_replace(input),
        (f, op) => {
            if known_features().contains(&f) {
                Err(fail("unknown_operation", format!("{f}.{op}")))
            } else {
                Err(fail("unknown_feature", f.to_string()))
            }
        }
    }
}

fn process_request(v: &V) -> D<V> {
    let feature = str_field(v, "feature")?;
    let operation = str_field(v, "operation")?;
    let input = get_field(v, "input")?;
    let result = dispatch(&feature, &operation, input)?;
    Ok(serde_json::json!({"feature": feature, "operation": operation, "result": result}))
}

fn top_kind(v: &V) -> D<String> {
    v.as_object()
        .and_then(|o| o.get("kind"))
        .and_then(|k| k.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| fail("query_shape", "missing or invalid top-level kind"))
}

fn decode_query(v: &V) -> D<V> {
    let kind = top_kind(v)?;
    match kind.as_str() {
        "surface" => Ok(surface_json()),
        "evaluate" => {
            let requests = v
                .as_object()
                .and_then(|o| o.get("requests"))
                .and_then(|r| r.as_array())
                .ok_or_else(|| fail("query_shape", "missing or invalid requests array"))?;
            let results = requests
                .iter()
                .map(process_request)
                .collect::<D<Vec<_>>>()?;
            Ok(serde_json::json!({"kind": "results", "results": results}))
        }
        other => Err(fail("query_shape", format!("unknown query kind {other}"))),
    }
}

fn render_invalid(f: &Fail) -> V {
    serde_json::json!({"kind": "invalid", "failure": {"kind": f.kind, "detail": f.detail}})
}

fn main() {
    let mut content = String::new();
    let stdin_ok = std::io::stdin().read_to_string(&mut content).is_ok();
    let out = if !stdin_ok {
        render_invalid(&fail("json_syntax", "failed to read stdin"))
    } else {
        match serde_json::from_str::<V>(&content) {
            Err(e) => render_invalid(&fail("json_syntax", e.to_string())),
            Ok(j) => match decode_query(&j) {
                Ok(result) => result,
                Err(f) => render_invalid(&f),
            },
        }
    };
    let mut stdout = std::io::stdout();
    let _ = writeln!(stdout, "{out}");
}
