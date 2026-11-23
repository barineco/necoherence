// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

#![allow(
    dead_code,
    clippy::expect_used,
    clippy::unwrap_used,
    clippy::panic,
    clippy::indexing_slicing
)]

use necoherence::semantic_composition::{CompositionJudgment, PreparedCompositionInput};
use necoherence::semantic_exchange::decode_signature_generation;
use necoherence::semantic_types::RefinementOutcome;
use necoherence::signature_admission::signature_basis;
use necoherence::type_signatures::{Shape, SignatureUnion, TypeNodeInput, TypeSignatureLibrary};
use necoherence_composition_solver::enumeration::{
    action_successors, enumerate_guards, enumerate_invocations,
};
use necoherence_composition_solver::search_state::{initial_state, SearchState};
use serde_json::{json, Value};

const FIXTURE: &str = include_str!("../fixtures/composition-budget-default.json");

fn replace_digest(value: &mut Value, old: &str, new: &str) {
    match value {
        Value::String(text) if text == old => *text = new.to_owned(),
        Value::Array(items) => items
            .iter_mut()
            .for_each(|item| replace_digest(item, old, new)),
        Value::Object(members) => members
            .values_mut()
            .for_each(|item| replace_digest(item, old, new)),
        _ => {}
    }
}

pub fn composition_problem(
    initial_inputs: Value,
    guards: Value,
    failures: Value,
    max_binding_candidates: Option<&str>,
) -> (TypeSignatureLibrary, Value) {
    let mut input = decode_signature_generation(FIXTURE).unwrap();
    let old_graph = input.basis.graph_sha256.clone();
    let mut library = (*input.signatures).clone();
    library.nodes.push(TypeNodeInput {
        id: "empty".into(),
        shape: Shape::TaggedUnion(SignatureUnion {
            branches: Vec::new(),
        }),
    });
    let new_graph = signature_basis(&library, None, &input.entrypoints)
        .unwrap()
        .graph_sha256;
    let mut composition = input.composition.take().unwrap();
    let problem = &mut composition["problem"];
    replace_digest(problem, &old_graph, &new_graph);
    problem["basis"]["graph_sha256"] = json!(new_graph);
    problem["initial_inputs"] = initial_inputs;
    problem["invocation_domain"]["guards"] = guards;
    problem["goal"] = json!({
        "outputs": [{
            "id": "result",
            "contract": {"nullable": false, "required": true, "type_id": "truth"},
            "source_constraint": {"tag": "InitialOnly", "fields": {"input": "flag", "path": []}}
        }],
        "failures": failures,
        "final_resources": []
    });
    if let Some(limit) = max_binding_candidates {
        problem["bounds"]["max_binding_candidates"] = json!(limit);
    }
    problem["invocation_domain"]["sites"] = json!([]);
    problem["invocation_domain"]["permitted_transforms"] = json!([]);
    problem["signatures"]
        .as_array_mut()
        .unwrap()
        .retain(|signature| signature["reference"]["identity"] != "handler");
    (library, composition["problem"].take())
}

pub fn empty_input(id: &str) -> Value {
    json!({
        "id": id,
        "contract": {"nullable": false, "required": true, "type_id": "empty"},
        "source": {"tag": "Argument"},
        "resource": null
    })
}

pub fn flag_input() -> Value {
    json!({
        "id": "flag",
        "contract": {"nullable": false, "required": true, "type_id": "truth"},
        "source": {"tag": "Argument"},
        "resource": null
    })
}

pub fn judged<V, R, S>(outcome: RefinementOutcome<CompositionJudgment<V>, R, S>) -> V {
    match outcome {
        RefinementOutcome::Resolved(value)
        | RefinementOutcome::Residual { value, .. }
        | RefinementOutcome::Stopped { value, .. } => value.value,
    }
}

pub fn successor_states(prepared: &PreparedCompositionInput<'_>) -> Vec<SearchState> {
    let root = initial_state(prepared);
    let mut actions = enumerate_invocations(prepared, &root).values;
    actions.extend(enumerate_guards(prepared, &root).values);
    let mut states = vec![root.clone()];
    for action in &actions {
        for (_, child) in action_successors(prepared, &root, action).unwrap() {
            states.push(child);
        }
    }
    states
}
