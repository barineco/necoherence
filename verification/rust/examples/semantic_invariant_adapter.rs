// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

#![allow(clippy::result_large_err)]

use necoherence::semantic_codegen_runtime::RuntimeFailure;
use necoherence::semantic_composition::{
    check_assignable, sample_value_fuel, CompatibilityDecision, SampleObligation, SearchBounds,
};
use necoherence::semantic_exchange::{decode_signature_basis, encode, encode_signature_basis};
use necoherence::semantic_exchange::{
    decode_signature_generation, decode_wire_text_at, encode_exact_value,
    encode_signature_generation, GenerationFailure,
};
use necoherence::semantic_refinement::open_signature_evaluation;
use necoherence::semantic_residual_record::{
    decode_semantic_residual, encode_semantic_residual, SemanticResidualFailure,
};
use necoherence::semantic_types::{
    JsonValue, PathStep, SlotContract, ValueCondition, ValueDecision,
};
use necoherence::semantic_validation::{evaluate_value, FormatWorkspace, PreparedValidator};
use necoherence::signature_admission::SemanticValueInput;
use necoherence::signature_admission::{
    admit_signature_generation, signature_type_ref, AdmissionFailure,
};
use necoherence::type_signatures::LibraryCheckFailure;
use necoherence_verification::required_field::{
    missing_field, required_field, required_lifted_field, required_str, syntax_failure,
};
use num_traits::ToPrimitive;
use std::io::{self, BufRead, Write};

#[derive(Debug)]
enum AdapterFailure {
    Wire(GenerationFailure),
    Generation(GenerationFailure),
    Admission(Box<AdmissionFailure>),
    Runtime(Box<RuntimeFailure>),
    Json(serde_json::Error),
    Io(io::Error),
    Invariant(&'static str),
    Residual(Box<SemanticResidualFailure>),
}

impl From<SemanticResidualFailure> for AdapterFailure {
    fn from(failure: SemanticResidualFailure) -> Self {
        Self::Residual(Box::new(failure))
    }
}

impl From<GenerationFailure> for AdapterFailure {
    fn from(failure: GenerationFailure) -> Self {
        match failure {
            GenerationFailure::Syntax { .. }
            | GenerationFailure::UnknownField { .. }
            | GenerationFailure::UnknownTag { .. }
            | GenerationFailure::UnsupportedSchema { .. } => Self::Wire(failure),
            other => Self::Generation(other),
        }
    }
}

impl From<AdmissionFailure> for AdapterFailure {
    fn from(failure: AdmissionFailure) -> Self {
        Self::Admission(Box::new(failure))
    }
}

impl From<RuntimeFailure> for AdapterFailure {
    fn from(failure: RuntimeFailure) -> Self {
        Self::Runtime(Box::new(failure))
    }
}

impl From<serde_json::Error> for AdapterFailure {
    fn from(failure: serde_json::Error) -> Self {
        Self::Json(failure)
    }
}

impl From<io::Error> for AdapterFailure {
    fn from(failure: io::Error) -> Self {
        Self::Io(failure)
    }
}

fn wire_row(classification: &str, path: &str) -> serde_json::Value {
    serde_json::json!({
        "status": "Rejected",
        "failure_kind": "Wire",
        "classification": classification,
        "path": path,
    })
}

fn library_row(check: LibraryCheckFailure) -> serde_json::Value {
    let (predicate, location) = match check {
        LibraryCheckFailure::Profile(failure) => {
            (format!("{:?}", failure.predicate), failure.location)
        }
        LibraryCheckFailure::Library(failure) => {
            (format!("{:?}", failure.predicate), failure.location)
        }
    };
    serde_json::json!({"status": "Rejected", "predicate": predicate.to_uppercase(), "path": location})
}

impl AdapterFailure {
    fn into_row(self) -> serde_json::Value {
        let message = match self {
            Self::Wire(GenerationFailure::Syntax { path, .. }) => return wire_row("Syntax", &path),
            Self::Wire(GenerationFailure::UnknownField { path, .. }) => {
                return wire_row("UnknownField", &path)
            }
            Self::Wire(GenerationFailure::UnknownTag { path, .. }) => {
                return wire_row("UnknownTag", &path)
            }
            Self::Wire(GenerationFailure::UnsupportedSchema { path, .. }) => {
                return wire_row("UnsupportedSchema", &path)
            }
            Self::Wire(other) | Self::Generation(other) => other.to_string(),
            Self::Admission(failure) => match *failure {
                AdmissionFailure::Library(check) => return library_row(check),
                other => other.to_string(),
            },
            Self::Runtime(failure) => failure.to_string(),
            Self::Json(failure) => failure.to_string(),
            Self::Io(failure) => failure.to_string(),
            Self::Invariant(message) => message.to_owned(),
            Self::Residual(failure) => format!("{failure:?}"),
        };
        serde_json::json!({"status":"Error","message":message})
    }
}

fn condition(v: &ValueCondition) -> String {
    format!("{v:?}")
}
fn path(path: &[PathStep]) -> Vec<serde_json::Value> {
    path.iter()
        .map(|step| match step {
            PathStep::Field(name) => serde_json::json!(name),
            PathStep::Index(index) => index.to_u64().map_or_else(
                || serde_json::json!(index.to_string()),
                |value| serde_json::json!(value),
            ),
            PathStep::Variant(tag) => serde_json::json!(format!("variant:{tag}")),
        })
        .collect()
}
fn type_ref(reference: &necoherence::semantic_types::TypeRef) -> serde_json::Value {
    serde_json::json!({
        "source": {
            "repository": reference.source.repository,
            "revision": reference.source.revision,
            "path": reference.source.path,
            "content_digest": reference.source.content_digest,
            "document_id": reference.source.document_id,
            "declared_revision": reference.source.declared_revision.as_ref().map(ToString::to_string),
        },
        "definition_name": reference.definition_name.as_ref(),
        "pointer": reference.pointer.as_ref(),
    })
}
fn natural_field(value: &serde_json::Value, key: &str) -> Result<usize, GenerationFailure> {
    required_str(value, "$", key)?
        .parse()
        .map_err(|_| syntax_failure(&format!("$.{key}"), "natural number required"))
}
fn exact_json(value: &serde_json::Value, path: &str) -> Result<JsonValue, GenerationFailure> {
    let tag = required_str(value, path, "tag")?;
    match tag {
        "Null" => Ok(JsonValue::Null),
        "Bool" => required_field(value, path, "value")?
            .as_bool()
            .map(JsonValue::Bool)
            .ok_or_else(|| syntax_failure(&format!("{path}.value"), "Bool expected")),
        "Integer" => required_str(value, path, "value")?
            .parse()
            .map(JsonValue::Num)
            .map_err(|_| syntax_failure(&format!("{path}.value"), "expected canonical integer")),
        "Decimal" => required_str(value, path, "text").map(|text| JsonValue::Dec(text.to_owned())),
        "String" => required_str(value, path, "value").map(|text| JsonValue::Str(text.to_owned())),
        "Array" => required_field(value, path, "items")?
            .as_array()
            .ok_or_else(|| syntax_failure(&format!("{path}.items"), "array expected"))?
            .iter()
            .enumerate()
            .map(|(index, item)| exact_json(item, &format!("{path}.items[{index}]")))
            .collect::<Result<Vec<_>, _>>()
            .map(JsonValue::Arr),
        "Object" => required_field(value, path, "members")?
            .as_array()
            .ok_or_else(|| syntax_failure(&format!("{path}.members"), "array expected"))?
            .iter()
            .enumerate()
            .map(
                |(index, member)| -> Result<(String, JsonValue), GenerationFailure> {
                    let member_path = format!("{path}.members[{index}]");
                    let key = required_str(member, &member_path, "key")?;
                    let item = required_field(member, &member_path, "value")?;
                    Ok((
                        key.to_owned(),
                        exact_json(item, &format!("{member_path}.value"))?,
                    ))
                },
            )
            .collect::<Result<Vec<_>, _>>()
            .map(|mut members: Vec<(String, JsonValue)>| {
                members.sort_by(|left, right| left.0.cmp(&right.0));
                JsonValue::Obj(members)
            }),
        other => Err(GenerationFailure::UnknownTag {
            path: format!("{path}.tag"),
            tag: other.to_owned(),
        }),
    }
}
fn canonicalize_text_wrapper_payloads(
    exchange: &mut serde_json::Value,
) -> Result<(), GenerationFailure> {
    let signatures = required_field(exchange, "$", "signatures")?;
    let profile = required_field(signatures, "$.signatures", "profile")?;
    required_field(profile, "$.signatures.profile", "wrappers")?;
    let wrappers = exchange
        .pointer_mut("/signatures/profile/wrappers")
        .and_then(serde_json::Value::as_array_mut)
        .ok_or_else(|| syntax_failure("$.signatures.profile.wrappers", "array expected"))?;
    for (index, wrapper) in wrappers.iter_mut().enumerate() {
        let payload_path = format!("$.signatures.profile.wrappers[{index}].payload");
        let Some(payload) = wrapper
            .get_mut("payload")
            .and_then(serde_json::Value::as_object_mut)
        else {
            continue;
        };
        if payload.get("tag").and_then(serde_json::Value::as_str) != Some("Text")
            || payload.contains_key("value")
        {
            continue;
        }
        let fields = payload
            .get("fields")
            .ok_or_else(|| missing_field(&payload_path, "fields"))?;
        let format = required_field(fields, &format!("{payload_path}.fields"), "format")?.clone();
        payload.remove("fields");
        payload.insert("value".into(), format);
    }
    Ok(())
}

fn semantic_classification_json(
    result: necoherence::semantic_types::SemanticEvaluation,
) -> Result<serde_json::Value, AdapterFailure> {
    use necoherence::semantic_exchange::{
        encode_evaluation_provenance, encode_semantic_obligations,
    };
    use necoherence::semantic_types::{ReasonDisposition, RefinementOutcome};
    let (status, provenance, decision, residuals, stops) = match result {
        Ok(RefinementOutcome::Residual { value, residuals }) => (
            "Residual",
            value.provenance,
            value.decision,
            residuals,
            vec![],
        ),
        Ok(RefinementOutcome::Stopped {
            value,
            residuals,
            cause,
        }) => (
            "Stopped",
            value.provenance,
            value.decision,
            residuals,
            cause,
        ),
        Err(failure) => {
            let stops = match &failure.decision {
                ValueDecision::Unresolved(reasons) => reasons
                    .iter()
                    .filter(|item| item.reason.disposition() == ReasonDisposition::Stopped)
                    .cloned()
                    .collect(),
                _ => vec![],
            };
            (
                "Failed",
                failure.provenance,
                failure.decision,
                failure.residuals,
                stops,
            )
        }
        Ok(RefinementOutcome::Resolved(value)) => (
            "Resolved",
            value.provenance,
            value.decision,
            necoherence::semantic_types::ResidualSet::new([]),
            vec![],
        ),
    };
    let ValueDecision::Unresolved(obligations) = decision else {
        return Err(AdapterFailure::Invariant("unresolved decision required"));
    };
    let failures = obligations
        .iter()
        .filter(|item| item.reason.disposition() == ReasonDisposition::Failed)
        .cloned()
        .collect::<Vec<_>>();
    let encode = |values: &[necoherence::semantic_types::SemanticObligation]| -> Result<serde_json::Value, AdapterFailure> {
        Ok(serde_json::from_str(&encode_semantic_obligations(values)?)?)
    };
    let provenance: serde_json::Value =
        serde_json::from_str(&encode_evaluation_provenance(&provenance)?)?;
    Ok(
        serde_json::json!({"status":status,"obligations":encode(&obligations)?,"residuals":encode(&residuals.iter().cloned().collect::<Vec<_>>())?,"stops":encode(&stops)?,"failures":encode(&failures)?,"provenance":provenance}),
    )
}

fn hex_bytes(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2)
        || !text.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
    {
        return None;
    }
    text.as_bytes()
        .chunks(2)
        .map(|pair| {
            std::str::from_utf8(pair)
                .ok()
                .and_then(|digits| u8::from_str_radix(digits, 16).ok())
        })
        .collect()
}

fn evaluate(line: io::Result<String>) -> Result<serde_json::Value, AdapterFailure> {
    let line = line?;
    let case: serde_json::Value = serde_json::from_str(&line)?;
    let id = serde_json::Value::String(required_str(&case, "$", "id")?.to_owned());
    let kind = required_str(&case, "$", "kind")?;
    if kind == "classification" {
        if case.get("domain").and_then(serde_json::Value::as_str) == Some("composition") {
            use necoherence::semantic_composition::{
                classified_atoms, classify_unresolved_obligations,
            };
            use necoherence::semantic_exchange::encode_unresolved_obligations;
            use necoherence::semantic_types::RefinementOutcome;
            let obligations: Vec<necoherence::semantic_composition::UnresolvedObligation> =
                decode_wire_text_at(
                    &required_field(&case, "$", "obligations")?.to_string(),
                    "$.obligations",
                )?;
            let encode = |values: Vec<necoherence::semantic_composition::UnresolvedObligation>| -> Result<serde_json::Value, AdapterFailure> {
                Ok(serde_json::from_str(&encode_unresolved_obligations(&values)?)?)
            };
            let provenance: necoherence::semantic_composition::CompositionProvenance =
                decode_wire_text_at(
                    &required_field(&case, "$", "provenance")?.to_string(),
                    "$.provenance",
                )?;
            let atoms = classified_atoms(&obligations);
            let atoms_with =
                |disposition: necoherence::semantic_types::ReasonDisposition| -> Vec<_> {
                    atoms
                        .iter()
                        .filter(|(_, class)| *class == disposition)
                        .map(|(reason, _)| reason.clone())
                        .collect()
                };
            let (status, provenance, obligations, residuals, stops, failures) =
                match classify_unresolved_obligations(provenance, obligations) {
                    Ok(RefinementOutcome::Residual { value, residuals }) => (
                        "Residual",
                        value.provenance,
                        value.value,
                        residuals,
                        vec![],
                        vec![],
                    ),
                    Ok(RefinementOutcome::Stopped {
                        value,
                        residuals,
                        cause,
                    }) => (
                        "Stopped",
                        value.provenance,
                        value.value,
                        residuals,
                        cause,
                        vec![],
                    ),
                    Err(failure) => (
                        "Failed",
                        failure.provenance,
                        failure.obligations,
                        failure.residuals,
                        atoms_with(necoherence::semantic_types::ReasonDisposition::Stopped),
                        atoms_with(necoherence::semantic_types::ReasonDisposition::Failed),
                    ),
                    Ok(RefinementOutcome::Resolved(_)) => {
                        return Err(AdapterFailure::Invariant("unresolved input resolved"))
                    }
                };
            let provenance: serde_json::Value = serde_json::from_str(
                &necoherence::semantic_exchange::encode_composition_provenance(&provenance)?,
            )?;
            return Ok(
                serde_json::json!({"id":id,"domain":"composition","status":status,"obligations":encode(obligations)?,"provenance":provenance,"residuals":encode(residuals.iter().cloned().collect())?,"stops":encode(stops)?,"failures":encode(failures)?}),
            );
        }
        if case.get("entry").and_then(serde_json::Value::as_str) == Some("value") {
            let graph =
                necoherence_verification::semantic_graph_codec::decode_public_validation_graph(
                    &required_field(&case, "$", "graph")?.to_string(),
                    "$.graph",
                )?;
            let reference: necoherence::semantic_types::TypeRef = decode_wire_text_at(
                &required_field(&case, "$", "reference")?.to_string(),
                "$.reference",
            )?;
            let value = required_lifted_field(&case, "$", "value")?;
            let value = necoherence::semantic_codegen_runtime::decode_json(&value.to_string())?;
            let mut row = semantic_classification_json(evaluate_value(
                &mut PreparedValidator::new(&graph, FormatWorkspace::empty()),
                &reference,
                &value,
            ))?;
            row.as_object_mut()
                .ok_or(AdapterFailure::Invariant("classification object"))?
                .insert("id".into(), id);
            return Ok(row);
        }
        use necoherence::semantic_types::classify_value_decision;
        let obligations: Vec<necoherence::semantic_types::SemanticObligation> =
            decode_wire_text_at(
                &required_field(&case, "$", "obligations")?.to_string(),
                "$.obligations",
            )?;
        let provenance: necoherence::semantic_types::EvaluationProvenance = decode_wire_text_at(
            &required_field(&case, "$", "provenance")?.to_string(),
            "$.provenance",
        )?;
        let mut row = semantic_classification_json(classify_value_decision(
            provenance,
            ValueDecision::Unresolved(obligations),
        ))?;
        row.as_object_mut()
            .ok_or(AdapterFailure::Invariant("classification object"))?
            .insert("id".into(), id);
        return Ok(row);
    }
    if kind == "wire" {
        let value = required_lifted_field(&case, "$", "value")?;
        let input = decode_signature_generation(&value.to_string())?;
        let encoded = encode_signature_generation(&input)?;
        return Ok(serde_json::json!({
            "id": id,
            "status": "Accepted",
            "encoded": serde_json::from_str::<serde_json::Value>(&encoded)?
        }));
    }
    if kind == "residual_record_decode" {
        let text = required_str(&case, "$", "bytes")?;
        let bytes = hex_bytes(text)
            .ok_or_else(|| syntax_failure("$.bytes", "lowercase hexadecimal expected"))?;
        let record = decode_semantic_residual(&bytes)?;
        return Ok(serde_json::json!({
            "id": id,
            "status": "decoded",
            "obligation_count": record.residuals().len(),
            "basis": serde_json::from_str::<serde_json::Value>(&encode_signature_basis(record.basis())?)?,
            "input": {
                "type_ref": serde_json::from_str::<serde_json::Value>(&encode(&record.input().type_ref)?)?,
                "value": serde_json::from_str::<serde_json::Value>(&encode_exact_value(&record.input().value)?)?,
            },
        }));
    }
    let mut exchange = required_field(&case, "$", "exchange")?.clone();
    if !exchange.is_string() {
        canonicalize_text_wrapper_payloads(&mut exchange)?;
    }
    let text = exchange
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| exchange.to_string());
    let input = decode_signature_generation(&text)?;
    let checked = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input),
        input.clone(),
    )?;
    let graph = checked.graph();
    if kind == "admit" {
        return Ok(serde_json::json!({"id":id,"status":"Accepted"}));
    }
    let type_id = required_str(&case, "$", "type_id")?;
    let reference = signature_type_ref(type_id);
    if kind == "residual_record" {
        use necoherence::semantic_types::RefinementOutcome;
        let value = exact_json(required_lifted_field(&case, "$", "value")?, "$.value")?;
        let basis = decode_signature_basis(&required_field(&case, "$", "basis")?.to_string())?;
        let evaluation = open_signature_evaluation(
            &checked,
            SemanticValueInput {
                type_ref: reference.clone(),
                value: value.clone(),
            },
            "1".into(),
        );
        let obligations: Vec<_> = match evaluation.outcome() {
            Ok(RefinementOutcome::Resolved(_)) => vec![],
            Ok(RefinementOutcome::Residual { residuals, .. })
            | Ok(RefinementOutcome::Stopped { residuals, .. }) => {
                residuals.iter().cloned().collect()
            }
            Err(failure) => failure.residuals.iter().cloned().collect(),
        };
        if obligations.is_empty() {
            return Ok(serde_json::json!({"id":id,"status":"not-unresolved"}));
        }
        let bytes = encode_semantic_residual(&basis, &reference, &value, &obligations)?;
        let text: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
        return Ok(serde_json::json!({"id":id,"status":"encoded","bytes":text}));
    }
    if kind == "value" {
        let value = exact_json(required_lifted_field(&case, "$", "value")?, "$.value")?;
        use necoherence::semantic_types::RefinementOutcome;
        let mut validator = PreparedValidator::new(graph, FormatWorkspace::empty());
        let (status, decision) = match evaluate_value(&mut validator, &reference, &value) {
            Ok(RefinementOutcome::Resolved(value)) => ("Accepted", value.decision),
            Ok(RefinementOutcome::Residual { value, .. }) => ("Residual", value.decision),
            Ok(RefinementOutcome::Stopped { value, .. }) => ("Stopped", value.decision),
            Err(failure) => ("Failed", failure.decision),
        };
        return Ok(match decision {
            ValueDecision::Accepted => serde_json::json!({"id":id,"status":"Accepted"}),
            ValueDecision::Rejected(f) => {
                let trace: Vec<_> = f
                    .reference_trace
                    .iter()
                    .map(|reference| reference.definition_name.as_ref())
                    .collect();
                serde_json::json!({"id":id,"status":"Rejected","type_ref":type_ref(&f.type_ref),"condition":condition(&f.condition),"path":path(&f.value_path),"trace":trace})
            }
            ValueDecision::Unresolved(o) => {
                serde_json::json!({"id":id,"status":"Unresolved","classification":{"status":status},"obligations":format!("{o:?}")})
            }
        });
    }
    if kind == "samples" {
        let fuel_bound = natural_field(&case, "max_type_obligations")?;
        let maximum = natural_field(&case, "max_sample_length")?;
        let bounds = SearchBounds {
            max_type_obligations: num_bigint::BigUint::from(fuel_bound),
            max_sample_length: num_bigint::BigUint::from(maximum),
            ..SearchBounds::default()
        };
        let samples = sample_value_fuel(
            graph,
            &bounds,
            fuel_bound.min(graph.nodes.len() + 1),
            &[],
            &reference,
        );
        let mut validator = PreparedValidator::new(graph, FormatWorkspace::empty());
        let accepted = samples.values.iter().all(|value| {
            matches!(
                evaluate_value(&mut validator, &reference, value),
                Ok(necoherence::semantic_types::RefinementOutcome::Resolved(outcome))
                    if matches!(outcome.decision, ValueDecision::Accepted)
            )
        });
        let values = samples
            .values
            .iter()
            .map(|value| -> Result<serde_json::Value, AdapterFailure> {
                Ok(serde_json::from_str(&encode_exact_value(value)?)?)
            })
            .collect::<Result<Vec<_>, AdapterFailure>>()?;
        return Ok(serde_json::json!({
            "id": id,
            "status": if accepted { "Accepted" } else { "Rejected" },
            "sample_bound": samples.obligations.contains(&SampleObligation::SampleBound),
            "sample_count": values.len(),
            "values": values,
        }));
    }
    let slot = SlotContract {
        type_ref: reference,
        required: true,
        nullable: false,
    };
    let destination = required_str(&case, "$", "destination_type_id")?;
    let d = SlotContract {
        type_ref: signature_type_ref(destination),
        required: true,
        nullable: false,
    };
    Ok(match check_assignable(graph, &slot, &d, 64) {
        CompatibilityDecision::Compatible(certificate) => {
            let checked = certificate;
            let rule = checked
                .pairs
                .get(
                    usize::try_from(&checked.root)
                        .map_err(|_| AdapterFailure::Invariant("inclusion root"))?,
                )
                .ok_or(AdapterFailure::Invariant("inclusion root"))?
                .rule;
            serde_json::json!({"id":id,"status":"Compatible","rule":format!("{rule:?}")})
        }
        CompatibilityDecision::Incompatible(c) => {
            serde_json::json!({"id":id,"status":"Incompatible","condition":condition(&c.destination_failure.condition)})
        }
        CompatibilityDecision::Unknown(o) => {
            serde_json::json!({"id":id,"status":"Unknown","obligations":format!("{o:?}")})
        }
    })
}
fn main() -> Result<(), AdapterFailure> {
    let stdout = io::stdout();
    let mut output = stdout.lock();
    for line in io::stdin().lock().lines() {
        let value = evaluate(line).unwrap_or_else(AdapterFailure::into_row);
        serde_json::to_writer(&mut output, &value)?;
        output.write_all(b"\n")?;
    }
    Ok(())
}
