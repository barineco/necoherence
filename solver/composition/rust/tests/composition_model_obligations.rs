// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

#![allow(
    clippy::expect_used,
    clippy::unwrap_used,
    clippy::panic,
    clippy::indexing_slicing
)]

mod support;

use necoherence::semantic_composition::{
    operation_checker_without_library, operation_meaning_of, prepare_direct_composition,
    UnresolvedObligation,
};
use necoherence::semantic_exchange::decode_signature_problem;
use necoherence::signature_admission::check_type_signatures;
use necoherence_composition_solver::closure::{CompositionDecision, TerminalAssessment};
use necoherence_composition_solver::composition_search::{assess_terminal, derive};
use necoherence_composition_solver::enumeration::enumerate_returns;
use necoherence_composition_solver::search_state::initial_state;
use serde_json::json;
use support::{composition_problem, empty_input, flag_input, judged, successor_states};

#[test]
fn binding_bound_before_a_valueless_supplier_is_the_reported_obligation() {
    let (library, problem) = composition_problem(
        json!([flag_input(), empty_input("empty-input")]),
        json!([]),
        json!([]),
        Some("1"),
    );
    let graph = check_type_signatures(&library).unwrap();
    let problem = decode_signature_problem(&library, &problem).unwrap();
    let prepared = prepare_direct_composition(
        &graph,
        problem,
        operation_checker_without_library(),
        operation_meaning_of(&graph),
    )
    .unwrap();
    let state = initial_state(&prepared);
    let terminals = enumerate_returns(&prepared, &state).values;
    let [terminal] = terminals.as_slice() else {
        panic!("the goal enumerates exactly one terminal");
    };
    let assessment = judged(
        assess_terminal(&prepared, &state, terminal)
            .unwrap()
            .unwrap(),
    );
    assert_eq!(
        assessment,
        TerminalAssessment::Unknown(vec![UnresolvedObligation::BindingBoundExhausted])
    );
    let CompositionDecision::Incomplete {
        evaluation,
        frontier,
        ..
    } = derive(&prepared).unwrap()
    else {
        panic!("a binding bound leaves the derivation incomplete");
    };
    assert_eq!(
        judged(evaluation),
        vec![UnresolvedObligation::BindingBoundExhausted]
    );
    assert!(frontier.is_empty());
}

#[test]
fn value_bearing_source_without_a_satisfying_model_is_branch_bound_exhausted() {
    let (library, problem) = composition_problem(
        json!([flag_input()]),
        json!([{
            "id": "check",
            "source_type": "truth",
            "path": [],
            "kind": {"tag": "Validate", "value": {"nullable": false, "required": true, "type_id": "truth"}}
        }]),
        json!([{
            "id": "rejected",
            "origin": {"tag": "Guard", "fields": {"guard": "check", "arm": {"tag": "Rejected"}}},
            "contract": {"nullable": false, "required": true, "type_id": "truth"},
            "final_resources": []
        }]),
        None,
    );
    let graph = check_type_signatures(&library).unwrap();
    let problem = decode_signature_problem(&library, &problem).unwrap();
    let prepared = prepare_direct_composition(
        &graph,
        problem,
        operation_checker_without_library(),
        operation_meaning_of(&graph),
    )
    .unwrap();
    let rejected = successor_states(&prepared)
        .into_iter()
        .find(|state| state.pending_failure.is_some())
        .expect("the rejected guard arm leads to a pending failure");
    let terminals = enumerate_returns(&prepared, &rejected).values;
    let [terminal] = terminals.as_slice() else {
        panic!("the rejected failure enumerates exactly one terminal");
    };
    let assessment = judged(
        assess_terminal(&prepared, &rejected, terminal)
            .unwrap()
            .unwrap(),
    );
    assert_eq!(
        assessment,
        TerminalAssessment::Unknown(vec![UnresolvedObligation::BranchBoundExhausted])
    );
}
