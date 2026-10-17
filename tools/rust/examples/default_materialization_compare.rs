// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use necoherence::semantic_exchange::*;
use necoherence::semantic_types::*;
use necoherence::semantic_validation::*;
use serde_json::{json, Value};
use std::io::{self, BufRead, Write};

type Error = Box<dyn std::error::Error>;
fn encoded(text: Result<String, GenerationFailure>) -> Result<Value, Error> {
    Ok(serde_json::from_str(&text?)?)
}
fn evaluate(input: &Value) -> Result<Value, Error> {
    let graph = decode_semantic_graph(&input["graph"].to_string())?;
    let reference = decode_type_reference(&input["reference"].to_string())?;
    let before = decode_exact_value(&input["before"].to_string())?;
    let result = match input.get("wire") {
        Some(text) => decode_with_defaults(&graph, &reference, text.as_str().ok_or("wire text")?),
        None => materialize_defaults(&graph, &reference, &before),
    };
    Ok(match result {
        Ok(result) => {
            let second = materialize_defaults(&graph, &reference, result.value())
                .map_err(|error| format!("idempotence: {error:?}"))?;
            let mut row = json!({"id":input["id"],"status":"Accepted","value":encoded(encode_exact_value(result.value()))?,"applications":encoded(encode_default_applications(result.applications()))?,"second_value":encoded(encode_exact_value(second.value()))?,"second_applications":encoded(encode_default_applications(second.applications()))?,"input":encoded(encode_exact_value(&before))?});
            if input["tamper"].as_bool().ok_or("tamper flag")? {
                let first = result.applications().first().ok_or("application")?;
                let mut source = (*first.type_ref.source).clone();
                source.document_id.push_str("-forged");
                let mut forged_source = first.clone();
                forged_source.type_ref.source = source.into();
                let mut pointer = first.origin.pointer.to_vec();
                pointer.push("forged".into());
                let mut forged_origin = first.clone();
                forged_origin.origin.pointer = pointer.into();
                let mut forged_path = first.clone();
                forged_path
                    .value_path
                    .push(PathStep::Field("forged".into()));
                let mut forged_value = first.clone();
                forged_value.value = JsonValue::Bool(true);
                let forged = [forged_source, forged_origin, forged_path, forged_value];
                let certificates = forged
                    .into_iter()
                    .map(|first| {
                        let applications = std::iter::once(first)
                            .chain(result.applications().iter().skip(1).cloned())
                            .collect::<Vec<_>>();
                        check_default_applications(&graph, &before, result.value(), &applications)
                    })
                    .collect::<Vec<_>>();
                row.as_object_mut()
                    .ok_or("accepted row object")?
                    .insert("certificates".into(), json!(certificates));
            }
            row
        }
        Err(DefaultFailure::Wire(reason)) => {
            json!({"id":input["id"],"status":"Wire","classification":if reason.starts_with("DuplicateField:") {"DuplicateField"} else {"Syntax"}})
        }
        Err(DefaultFailure::Rejected(failure)) => {
            let mut row = encoded(encode_diagnostic(&failure))?;
            let fields = row.as_object_mut().ok_or("diagnostic object")?;
            fields.insert("id".into(), input["id"].clone());
            fields.insert("status".into(), json!("Rejected"));
            row
        }
        Err(DefaultFailure::Unresolved(obligations)) => {
            json!({"id":input["id"],"status":"Unresolved","obligations":encoded(encode_semantic_obligations(&obligations))?})
        }
        Err(DefaultFailure::CertificateMismatch(condition)) => {
            json!({"id":input["id"],"status":"CertificateMismatch","condition":condition})
        }
    })
}
fn main() -> Result<(), Error> {
    let mut output = io::stdout().lock();
    for line in io::stdin().lock().lines() {
        let input: Value = serde_json::from_str(&line?)?;
        serde_json::to_writer(&mut output, &evaluate(&input)?)?;
        output.write_all(b"\n")?;
    }
    Ok(())
}
