// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only
#![allow(clippy::indexing_slicing, clippy::unwrap_used)]

use necoherence::semantic_composition::WitnessFailure;
use necoherence::semantic_exchange::decode_signature_generation;
use necoherence::semantic_exchange::SignatureCompositionAdmissionFailure;
use necoherence::signature_admission::admit_signature_generation;
use necoherence::type_signatures::ExpectedSignatureBasis;
use necoherence_composition_solver::wire_admission::verified_signature_derivation;

#[test]
fn variant_guard_unknown_arm_is_incomplete_branch_coverage() {
    let exchange = include_str!(
        "../../../../packages/rust/adapter/tests/fixtures/variant-guard-incomplete-coverage.json"
    );
    let input = decode_signature_generation(exchange).unwrap();
    let basis = ExpectedSignatureBasis::of_input(&input);

    let checked = admit_signature_generation(&basis, input).unwrap();
    let failure = verified_signature_derivation(checked.input(), checked.graph()).err();
    assert!(matches!(
        &failure,
        Some(SignatureCompositionAdmissionFailure::Composition(
            WitnessFailure::IncompleteBranchCoverage(arm)
        )) if arm == "variant"
    ));
}
