// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

#![allow(clippy::result_large_err)]

use necoherence::semantic_exchange::*;
use necoherence::semantic_types::*;
use necoherence::semantic_validation::*;
use necoherence_verification::default_materialization_wire::{check_wire_text, WireTextFailure};
use necoherence_verification::semantic_graph_codec::decode_semantic_graph;
use serde_json::{json, Value};
use std::io::{self, BufRead, Write};

#[derive(Debug)]
enum AdapterFailure {
    Wire(GenerationFailure),
    Duplicate,
    Syntax,
    Input(&'static str),
    Generation(GenerationFailure),
    Json(serde_json::Error),
    Io(io::Error),
    Idempotence(DefaultFailure),
}

impl AdapterFailure {
    fn into_row(self, id: Value) -> Value {
        let (classification, path) = match self {
            Self::Wire(GenerationFailure::Syntax { path, .. }) => ("Syntax", path),
            Self::Wire(GenerationFailure::UnknownField { path, .. }) => ("UnknownField", path),
            Self::Wire(GenerationFailure::UnknownTag { path, .. }) => ("UnknownTag", path),
            Self::Wire(GenerationFailure::UnsupportedSchema { path, .. }) => {
                ("UnsupportedSchema", path)
            }
            Self::Syntax => ("Syntax", "$".to_owned()),
            Self::Duplicate => ("DuplicateField", "$".to_owned()),
            other => {
                let message = other.message();
                return json!({"id": id, "status": "Error", "message": message});
            }
        };
        json!({"id": id, "status": "Wire", "classification": classification, "path": path})
    }

    fn message(&self) -> String {
        match self {
            Self::Wire(failure) | Self::Generation(failure) => failure.to_string(),
            Self::Duplicate => "DuplicateField".into(),
            Self::Syntax => "Syntax".into(),
            Self::Input(name) => (*name).to_owned(),
            Self::Json(failure) => failure.to_string(),
            Self::Io(failure) => failure.to_string(),
            Self::Idempotence(failure) => format!("idempotence: {failure:?}"),
        }
    }
}

fn encoded(text: Result<String, GenerationFailure>) -> Result<Value, AdapterFailure> {
    let text = text.map_err(AdapterFailure::Generation)?;
    serde_json::from_str(&text).map_err(AdapterFailure::Json)
}

fn required<'a>(input: &'a Value, key: &str) -> Result<&'a Value, AdapterFailure> {
    necoherence_verification::required_field::required_field(input, "$", key)
        .map_err(AdapterFailure::Wire)
}

fn decode_case(input: &Value) -> Result<(SemanticGraph, TypeRef, JsonValue, bool), AdapterFailure> {
    let graph = decode_semantic_graph(&required(input, "graph")?.to_string(), "$.graph")
        .map_err(AdapterFailure::Wire)?;
    let reference: TypeRef =
        decode_wire_text_at(&required(input, "reference")?.to_string(), "$.reference")
            .map_err(AdapterFailure::Wire)?;
    let before: JsonValue =
        decode_wire_text_at(&required(input, "before")?.to_string(), "$.before")
            .map_err(AdapterFailure::Wire)?;
    let tamper = input["tamper"].as_bool().ok_or_else(|| {
        AdapterFailure::Wire(GenerationFailure::Syntax {
            path: "$.tamper".into(),
            message: "Bool expected".into(),
        })
    })?;
    Ok((graph, reference, before, tamper))
}

fn evaluate(input: &Value) -> Result<Value, AdapterFailure> {
    let id = input.get("id").cloned().unwrap_or(Value::Null);
    let (graph, reference, before, tamper) = decode_case(input)?;
    let validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
    let result = match input.get("wire") {
        Some(text) => {
            let text = text.as_str().ok_or(AdapterFailure::Input("wire text"))?;
            match check_wire_text(&before, text) {
                Ok(()) => decode_with_defaults(&validator, &reference, text),
                Err(WireTextFailure::DuplicateField) => return Err(AdapterFailure::Duplicate),
                Err(WireTextFailure::Syntax) => return Err(AdapterFailure::Syntax),
                Err(WireTextFailure::Differs) => {
                    return Err(AdapterFailure::Input("wire and exact input differ"))
                }
                Err(WireTextFailure::Spelling(message)) => {
                    return Err(AdapterFailure::Generation(GenerationFailure::Encoding(
                        message,
                    )))
                }
            }
        }
        None => materialize_defaults(&validator, &reference, &before),
    };
    Ok(match result {
        Ok(result) => {
            let second = materialize_defaults(&validator, &reference, result.value())
                .map_err(AdapterFailure::Idempotence)?;
            let mut row = json!({"id":id,"status":"Accepted","value":encoded(encode_exact_value(result.value()))?,"applications":encoded(encode_default_applications(result.applications()))?,"second_value":encoded(encode_exact_value(second.value()))?,"second_applications":encoded(encode_default_applications(second.applications()))?,"input":encoded(encode_exact_value(&before))?});
            if tamper {
                let first = result
                    .applications()
                    .first()
                    .ok_or(AdapterFailure::Input("application"))?;
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
                        check_default_applications(
                            &validator,
                            &before,
                            result.value(),
                            &applications,
                        )
                    })
                    .collect::<Vec<_>>();
                row.as_object_mut()
                    .ok_or(AdapterFailure::Input("accepted row object"))?
                    .insert("certificates".into(), json!(certificates));
            }
            row
        }
        Err(DefaultFailure::Wire(failure)) => return Err(AdapterFailure::Generation(failure)),
        Err(DefaultFailure::Evaluation(ValidationFailure::Value(failure))) => {
            let mut row = encoded(encode_diagnostic(&failure))?;
            let fields = row
                .as_object_mut()
                .ok_or(AdapterFailure::Input("diagnostic object"))?;
            fields.insert("id".into(), id);
            fields.insert("status".into(), json!("Rejected"));
            row
        }
        Err(DefaultFailure::Evaluation(ValidationFailure::Unresolved(reasons))) => {
            let status = if reasons.is_empty() {
                "Failed"
            } else {
                "Unresolved"
            };
            json!({"id":id,"status":status,"obligations":encoded(encode_semantic_obligations(&reasons))?})
        }
        Err(DefaultFailure::Evaluation(ValidationFailure::CertificateMismatch(condition))) => {
            json!({"id":id,"status":"CertificateMismatch","condition":condition})
        }
        Err(DefaultFailure::CertificateMismatch(condition)) => {
            json!({"id":id,"status":"CertificateMismatch","condition":condition})
        }
    })
}

fn main() -> Result<(), AdapterFailure> {
    let mut output = io::stdout().lock();
    for line in io::stdin().lock().lines() {
        let line = line.map_err(AdapterFailure::Io)?;
        let input: Value = serde_json::from_str(&line).map_err(AdapterFailure::Json)?;
        let id = input.get("id").cloned().unwrap_or(Value::Null);
        let row = evaluate(&input).unwrap_or_else(|failure| failure.into_row(id));
        serde_json::to_writer(&mut output, &row).map_err(AdapterFailure::Json)?;
        output.write_all(b"\n").map_err(AdapterFailure::Io)?;
    }
    Ok(())
}
