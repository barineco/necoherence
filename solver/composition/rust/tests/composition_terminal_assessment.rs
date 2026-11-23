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
    ReturnPlan, UnresolvedObligation,
};
use necoherence::semantic_exchange::{decode_signature_generation, decode_signature_problem};
use necoherence::semantic_types::RefinementOutcome;
use necoherence::signature_admission::check_type_signatures;
use necoherence_composition_solver::closure::TerminalAssessment;
use necoherence_composition_solver::composition_search::assess_terminal;
use necoherence_composition_solver::search_state::initial_state;

const FIXTURE: &str = include_str!("fixtures/composition-budget-default.json");

#[test]
fn terminal_failing_the_terminal_check_is_unknown_branch_bound_as_lean_reports() {
    let input = decode_signature_generation(FIXTURE).unwrap();
    let graph = check_type_signatures(&input.signatures).unwrap();
    let composition = input.composition.as_ref().unwrap();
    let problem = decode_signature_problem(&input.signatures, &composition["problem"]).unwrap();
    let prepared = prepare_direct_composition(
        &graph,
        problem,
        operation_checker_without_library(),
        operation_meaning_of(&graph),
    )
    .unwrap();
    let state = initial_state(&prepared);
    let evaluation = assess_terminal(&prepared, &state, &ReturnPlan::Success(Vec::new()))
        .unwrap()
        .unwrap();
    let assessment = match evaluation {
        RefinementOutcome::Resolved(value)
        | RefinementOutcome::Residual { value, .. }
        | RefinementOutcome::Stopped { value, .. } => value.value,
    };
    assert_eq!(
        assessment,
        TerminalAssessment::Unknown(vec![UnresolvedObligation::BranchBoundExhausted])
    );
}
