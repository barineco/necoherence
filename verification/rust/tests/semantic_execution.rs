// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only
#![allow(
    clippy::expect_used,
    clippy::panic,
    clippy::result_large_err,
    clippy::unwrap_used
)]

use necoherence::semantic_composition as composition;
use necoherence::signature_admission::check_type_signatures;

#[path = "../../../packages/rust/adapter/tests/fixtures/semantic_execution_samples.rs"]
#[allow(dead_code, unused_imports)]
mod samples;
use samples::*;
#[path = "fixtures/semantic_execution_derivation.rs"]
#[allow(dead_code, unused_imports)]
mod derivation_samples;
use derivation_samples::*;

#[test]
fn resource_certificate_mismatch_uses_lean_condition() {
    let library = library();
    let graph = check_type_signatures(&library).unwrap();
    let problem = invocation_problem(
        &graph,
        &bool_contract(),
        composition::CompositionEffect::PureFunction,
    );
    let prepared = composition::prepare_direct_composition(
        &graph,
        problem,
        composition::operation_checker_without_library(),
        composition::operation_meaning_of(&graph),
    )
    .unwrap();
    let mut raw = derivation(&prepared, false);
    raw.witness
        .resource_traces
        .first_mut()
        .unwrap()
        .correspondence
        .execution_order
        .push("forged".into());
    assert_eq!(
        necoherence_composition_solver::verification::verify_composition(&prepared, &raw)
            .err()
            .expect("forged resource is rejected"),
        composition::WitnessFailure::ResourceLoweringMismatch(
            "resource input or correspondence".into()
        )
    );
}
