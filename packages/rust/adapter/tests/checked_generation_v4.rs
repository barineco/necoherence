// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT
#![allow(clippy::indexing_slicing, clippy::unwrap_used)]

use necoherence::semantic_composition::CompositionInputFailure;
use necoherence::semantic_exchange::{decode_signature_generation, GenerationFailure};
use necoherence::signature_admission::{admit_signature_generation, AdmissionFailure};
use necoherence::type_signatures::ExpectedSignatureBasis;

fn decode_fixture(
    exchange: &str,
) -> (
    ExpectedSignatureBasis,
    necoherence::type_signatures::SignatureGenerationInput,
) {
    let input = decode_signature_generation(exchange).unwrap();
    (ExpectedSignatureBasis::of_input(&input), input)
}

#[test]
fn external_supplement_with_unresolved_type_is_an_unresolved_type() {
    let exchange = include_str!("fixtures/external-supplement-unresolved-type.json");
    let (basis, input) = decode_fixture(exchange);
    assert!(matches!(
        admit_signature_generation(&basis, input),
        Err(AdmissionFailure::CompositionInput(
            CompositionInputFailure::UnresolvedType(_)
        ))
    ));
}

#[test]
fn composition_numbers_are_hashed_in_lean_json_compress_form() {
    let exchange = include_str!("fixtures/composition-numbers-lean-normalized.json");
    let (basis, input) = decode_fixture(exchange);
    assert!(matches!(
        admit_signature_generation(&basis, input),
        Err(AdmissionFailure::Wire(GenerationFailure::Syntax { .. }))
    ));
}
