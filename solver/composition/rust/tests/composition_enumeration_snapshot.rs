// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

#![allow(
    clippy::expect_used,
    clippy::unwrap_used,
    clippy::panic,
    clippy::indexing_slicing
)]

use std::collections::BTreeSet;

use necoherence::semantic_composition::{
    operation_checker_without_library, operation_meaning_of, prepare_direct_composition,
    PreparedCompositionInput,
};
use necoherence::semantic_exchange::{decode_signature_generation, decode_signature_problem};
use necoherence::signature_admission::check_type_signatures;
use necoherence_composition_solver::closure::CompositionDecision;
use necoherence_composition_solver::composition_search::derive;
use necoherence_composition_solver::enumeration::{
    action_successors, admissible_sites, enumerate_bindings, enumerate_guards,
    enumerate_invocations, enumerate_returns,
};
use necoherence_composition_solver::search_state::{initial_state, SearchState};

const FIXTURE: &str = include_str!("fixtures/composition-budget-default.json");

fn prepare_problem(problem: &serde_json::Value) -> PreparedCompositionInput<'static> {
    let input = Box::leak(Box::new(decode_signature_generation(FIXTURE).unwrap()));
    let graph = Box::leak(Box::new(check_type_signatures(&input.signatures).unwrap()));
    let problem = decode_signature_problem(&input.signatures, problem).unwrap();
    prepare_direct_composition(
        graph,
        problem,
        operation_checker_without_library(),
        operation_meaning_of(graph),
    )
    .unwrap()
}

fn check_enumeration_invariants(prepared: &PreparedCompositionInput<'_>, state: &SearchState) {
    let input = prepared.input();
    for output in &input.goal.outputs {
        let first =
            enumerate_bindings(prepared, state, &output.contract, &output.source_constraint);
        let second =
            enumerate_bindings(prepared, state, &output.contract, &output.source_constraint);
        assert_eq!(first, second);
    }
    for (_, function) in admissible_sites(prepared, state) {
        for port in &function.inputs {
            let first =
                enumerate_bindings(prepared, state, &port.contract, &port.source_constraint);
            let second =
                enumerate_bindings(prepared, state, &port.contract, &port.source_constraint);
            assert_eq!(first, second);
        }
    }
    let invocations = enumerate_invocations(prepared, state);
    assert_eq!(invocations, enumerate_invocations(prepared, state));
    assert_eq!(
        invocations.values.len(),
        invocations
            .values
            .iter()
            .map(|action| format!("{action:?}"))
            .collect::<BTreeSet<_>>()
            .len()
    );
    let guards = enumerate_guards(prepared, state);
    assert_eq!(guards, enumerate_guards(prepared, state));
    assert_eq!(
        guards.values.len(),
        guards
            .values
            .iter()
            .map(|action| format!("{action:?}"))
            .collect::<BTreeSet<_>>()
            .len()
    );
    let returns = enumerate_returns(prepared, state);
    assert_eq!(returns, enumerate_returns(prepared, state));
}

#[test]
fn enumeration_and_derivation_are_deterministic_without_duplicates_and_respect_goal_validity() {
    let input = decode_signature_generation(FIXTURE).unwrap();
    let default = input.composition.as_ref().unwrap()["problem"].clone();
    let mut rejecting = default.clone();
    rejecting["goal"]["outputs"][0]["contract"]["type_id"] = serde_json::json!("unit");
    rejecting["bounds"]["max_expanded_states"] = serde_json::json!("2");

    let default_prepared = prepare_problem(&default);
    let default_root = initial_state(&default_prepared);
    check_enumeration_invariants(&default_prepared, &default_root);
    let actions = enumerate_invocations(&default_prepared, &default_root)
        .values
        .into_iter()
        .chain(enumerate_guards(&default_prepared, &default_root).values)
        .collect::<Vec<_>>();
    for action in &actions {
        let successors = action_successors(&default_prepared, &default_root, action).unwrap();
        assert_eq!(
            successors,
            action_successors(&default_prepared, &default_root, action).unwrap()
        );
        for (_, child) in &successors {
            check_enumeration_invariants(&default_prepared, child);
        }
    }
    assert!(matches!(
        derive(&default_prepared),
        Ok(CompositionDecision::Solved(..))
    ));

    let rejecting_prepared = prepare_problem(&rejecting);
    let rejecting_root = initial_state(&rejecting_prepared);
    check_enumeration_invariants(&rejecting_prepared, &rejecting_root);
    assert!(!matches!(
        derive(&rejecting_prepared),
        Ok(CompositionDecision::Solved(..))
    ));
}
