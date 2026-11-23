// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use crate::verification::*;
use necoherence::semantic_exchange::*;
use necoherence::semantic_types::*;
use necoherence::type_signatures::*;

fn verified_derivation(
    input: &SignatureGenerationInput,
    graph: &SemanticGraph,
) -> Result<Option<(GenerationComposition, RawComposition)>, SignatureCompositionAdmissionFailure> {
    let Some(composition) = &input.composition else {
        return Ok(None);
    };
    let (problem_value, derivation_value) =
        composition_members(composition).map_err(SignatureCompositionAdmissionFailure::Wire)?;
    let (problem, causes) = necoherence::signature_composition_codec::decode_problem(
        &input.signatures,
        problem_value,
        "$.composition.problem",
    )
    .map_err(SignatureCompositionAdmissionFailure::Wire)?;
    let graph_digest = necoherence::signature_admission::canonical_digest(&input.signatures)
        .map_err(|failure| {
            SignatureCompositionAdmissionFailure::Wire(GenerationFailure::Admission(Box::new(
                failure,
            )))
        })?;
    let prepared = prepare_signature_composition(
        &input.signatures,
        &graph_digest,
        graph,
        problem.clone(),
        &causes,
    )
    .map_err(SignatureCompositionAdmissionFailure::CompositionInput)?;
    let problem_json = necoherence::signature_composition_codec::to_exchange(problem_value)
        .map_err(SignatureCompositionAdmissionFailure::Wire)?;
    let derivation_json = necoherence::signature_composition_codec::to_exchange(derivation_value)
        .map_err(SignatureCompositionAdmissionFailure::Wire)?;
    let derivation = crate::derivation_codec::decode_derivation(
        &input.signatures,
        graph,
        &prepared,
        &problem,
        &problem_json,
        &derivation_json,
    )
    .map_err(composition_or_wire)?;
    verify_composition(&prepared, &derivation)
        .map_err(SignatureCompositionAdmissionFailure::Composition)?;
    let plan = derivation.plan.clone();
    drop(prepared);
    Ok(Some((
        GenerationComposition {
            problem,
            plan,
            causes,
        },
        derivation,
    )))
}

pub fn verified_signature_derivation(
    input: &SignatureGenerationInput,
    graph: &SemanticGraph,
) -> Result<Option<(GenerationComposition, RawComposition)>, SignatureCompositionAdmissionFailure> {
    verified_derivation(input, graph)
}
