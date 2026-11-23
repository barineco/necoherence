// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

#![allow(
    clippy::expect_used,
    clippy::unwrap_used,
    clippy::panic,
    clippy::indexing_slicing
)]

use necoherence::semantic_composition::{
    operation_checker_without_library, operation_meaning_of, prepare_direct_composition,
    SearchBounds, UnresolvedObligation,
};
use necoherence::semantic_exchange::{decode_signature_generation, decode_signature_problem};
use necoherence::semantic_types::RefinementOutcome;
use necoherence::signature_admission::check_type_signatures;
use necoherence_composition_solver::closure::CompositionDecision;
use necoherence_composition_solver::composition_search::derive;
use necoherence_composition_solver::search_state::SearchState;
use necoherence_composition_solver::verification::TraceStep;
use num_bigint::BigUint;

const FIXTURE: &str = include_str!("fixtures/composition-budget-default.json");

fn over_budget_decision(
    bounds: impl FnOnce(&mut SearchBounds),
) -> (Vec<UnresolvedObligation>, Vec<SearchState>) {
    let input = decode_signature_generation(FIXTURE).unwrap();
    let graph = check_type_signatures(&input.signatures).unwrap();
    let composition = input.composition.as_ref().unwrap();
    let mut problem = decode_signature_problem(&input.signatures, &composition["problem"]).unwrap();
    bounds(&mut problem.bounds);
    let prepared = prepare_direct_composition(
        &graph,
        problem,
        operation_checker_without_library(),
        operation_meaning_of(&graph),
    )
    .unwrap();
    let CompositionDecision::Incomplete {
        evaluation,
        frontier,
        ..
    } = derive(&prepared).unwrap()
    else {
        panic!("the input over the search budget must remain incomplete");
    };
    let obligations = match evaluation {
        RefinementOutcome::Resolved(value)
        | RefinementOutcome::Residual { value, .. }
        | RefinementOutcome::Stopped { value, .. } => value.value,
    };
    (obligations, frontier)
}

fn frontier_labels(frontier: &[SearchState]) -> Vec<String> {
    frontier
        .iter()
        .map(|state| {
            state
                .trace
                .iter()
                .map(|step| match step {
                    TraceStep::Invocation {
                        invocation,
                        outcome,
                    } => format!("{}:{}", invocation.site.0, outcome.0),
                    TraceStep::Guard { guard, .. } => format!("guard:{}", guard.0),
                })
                .collect::<Vec<_>>()
                .join(",")
        })
        .collect()
}

#[test]
fn exhausted_expansion_budget_keeps_root_successors_as_frontier() {
    let (obligations, frontier) =
        over_budget_decision(|bounds| bounds.max_expanded_states = BigUint::from(0u32));
    assert_eq!(
        obligations,
        [
            UnresolvedObligation::StateBoundExhausted,
            UnresolvedObligation::StateBoundExhausted,
            UnresolvedObligation::StateBoundExhausted,
        ]
    );
    assert_eq!(
        frontier_labels(&frontier),
        ["operation:success", "operation:refused"]
    );
}

#[test]
fn one_expansion_takes_the_first_successor_and_keeps_its_sibling_in_frontier() {
    let (obligations, frontier) =
        over_budget_decision(|bounds| bounds.max_expanded_states = BigUint::from(1u32));
    assert_eq!(
        obligations,
        [
            UnresolvedObligation::StateBoundExhausted,
            UnresolvedObligation::StateBoundExhausted,
        ]
    );
    assert_eq!(frontier_labels(&frontier), ["operation:refused"]);
}

#[test]
fn popped_duplicates_and_expansions_share_one_fuel_before_frontier() {
    let (obligations, frontier) =
        over_budget_decision(|bounds| bounds.max_expanded_states = BigUint::from(2u32));
    assert_eq!(
        obligations,
        [
            UnresolvedObligation::StateBoundExhausted,
            UnresolvedObligation::StateBoundExhausted,
        ]
    );
    assert_eq!(
        frontier_labels(&frontier),
        ["operation:refused,handler:handled"]
    );
}

#[test]
fn binding_overflow_reports_the_binding_bound_and_keeps_pending_states() {
    let (obligations, frontier) =
        over_budget_decision(|bounds| bounds.max_binding_candidates = BigUint::from(1u32));
    assert_eq!(
        obligations,
        [
            UnresolvedObligation::BindingBoundExhausted,
            UnresolvedObligation::StateBoundExhausted,
            UnresolvedObligation::StateBoundExhausted,
        ]
    );
    assert_eq!(
        frontier_labels(&frontier),
        ["operation:refused,handler:handled"]
    );
}

#[test]
fn branch_overflow_reports_the_branch_bound_and_keeps_pending_states() {
    let (obligations, frontier) =
        over_budget_decision(|bounds| bounds.max_branch_nodes = BigUint::from(1u32));
    assert_eq!(
        obligations,
        [
            UnresolvedObligation::BranchBoundExhausted,
            UnresolvedObligation::StateBoundExhausted,
            UnresolvedObligation::StateBoundExhausted,
        ]
    );
    assert_eq!(frontier_labels(&frontier), ["operation:refused"]);
}
