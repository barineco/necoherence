// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use std::io::{self, Write};
use necoherence::semantic_composition::{prepare_composition, CompositionDecision, OutcomeId, SelectionPolicy};
use necoherence_tools::composition_search::derive;
use necoherence::semantic_exchange::{decode_signature_generation, decode_signature_problem, encode_signature_generation, signature_composition_from_native};
use necoherence::signature_admission::{admit_signature_generation, assemble_signature_generation};
use necoherence::type_signatures::SignatureDefinitionShape;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let text = std::fs::read_to_string(std::env::args().nth(2).ok_or("exchange path required")?)?;
    let wire: serde_json::Value = serde_json::from_str(&text)?;
    let input = decode_signature_generation(&text)?;
    let expected = input.basis.clone();
    let checked = admit_signature_generation(&expected, input.clone())?;
    if std::env::args().nth(1).as_deref() == Some("verify") {
        writeln!(io::stdout().lock(), "{}", encode_signature_generation(&input)?)?;
        return Ok(());
    }
    let composition = input.composition.as_ref().ok_or("composition required")?;
    let mut problem = decode_signature_problem(&input.signatures, &composition.problem).map_err(|error| format!("decode problem: {error:?}"))?;
    problem.selection_policy = Some(SelectionPolicy::RequireUnique);
    let prepared = prepare_composition(checked.graph(), problem.clone()).map_err(|error| format!("{error:?}"))?;
    let CompositionDecision::Solved(selected, _) = derive(&prepared).map_err(|error| format!("{error:?}"))? else {
        return Err("RequireUnique must solve".into());
    };
    let definitions = wire["signatures"]["definitions"].as_array().ok_or("definitions required")?;
    let mut declared_causes = Vec::new();
    for definition in &input.signatures.definitions {
        if let SignatureDefinitionShape::Operation(operation) = &definition.shape {
            let original = definitions.iter().find(|row| row["id"].as_str() == Some(&definition.id)).ok_or("definition id required")?;
            let outcomes = original["shape"]["value"]["outcomes"].as_array().ok_or("operation outcomes required")?;
            for outcome in &operation.outcomes {
                let original = outcomes.iter().find(|row| row["id"].as_str() == Some(&outcome.id)).ok_or("outcome id required")?;
                declared_causes.push((original["cause"].clone(), outcome.cause.clone()));
            }
        }
    }
    let causes = problem.signatures.iter().map(|function| {
        let signature = composition.problem["signatures"].as_array().ok_or("signatures required")?.iter().find(|signature| signature["reference"]["identity"].as_str() == Some(function.reference.identity.as_str())).ok_or("resolved function required")?;
        let function = function.reference.clone();
        let outcomes = signature["outcomes"].as_array().ok_or("outcomes required")?.iter().map(|outcome| {
            let cause = declared_causes.iter().find(|(wire, _)| wire == &outcome["cause"]).ok_or("declared test cause required")?.1.clone();
            Ok((OutcomeId(outcome["id"].as_str().ok_or("outcome id required")?.to_owned()), cause))
        }).collect::<Result<Vec<_>, Box<dyn std::error::Error>>>()?;
        Ok((function, outcomes))
    }).collect::<Result<Vec<_>, Box<dyn std::error::Error>>>()?;
    let composition = signature_composition_from_native(&input.signatures, &problem, selected.raw(), &causes).map_err(|error| format!("encode composition: {error:?}"))?;
    let output = assemble_signature_generation((*input.signatures).clone(), Some(composition), input.entrypoints)?;
    writeln!(io::stdout().lock(), "{}", encode_signature_generation(&output)?)?;
    Ok(())
}
