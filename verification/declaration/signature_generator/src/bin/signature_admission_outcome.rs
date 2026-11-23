// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use neco_quotient_certificate::{Condition, Mismatch, Prerequisite, ProjectionResult, Status};
use necoherence::semantic_exchange::SignatureCompositionAdmissionFailure;
use necoherence::semantic_exchange::{
    decode_expected_signature_basis, decode_signature_generation, GenerationFailure,
};
use necoherence::signature_admission::{
    admit_signature_generation, AdmissionFailure, CheckedSignatureGeneration,
};
use necoherence::type_signatures::{
    ExpectedSignatureBasis, LibraryCheckFailure, SignatureGenerationBasis,
};
use necoherence_composition_solver::wire_admission::verified_signature_derivation;
use necoherence_generator::renderer::{render_signature_exchange_for, RenderFailure, Target};
use serde_json::{json, Value};
use std::io::{self, BufRead, Read, Write};

fn variant_name<T: std::fmt::Debug>(value: &T) -> String {
    let name: String = format!("{value:?}")
        .chars()
        .take_while(|character| character.is_alphanumeric())
        .collect();
    let mut characters = name.chars();
    match characters.next() {
        Some(first) => first.to_lowercase().chain(characters).collect(),
        None => String::new(),
    }
}

fn basis_value(basis: &SignatureGenerationBasis) -> Value {
    json!({
        "signature_schema": basis.signature_schema,
        "library_identity": basis.library_identity,
        "library_revision": basis.library_revision,
        "profile": {
            "identity": basis.profile.identity,
            "revision": basis.profile.revision,
            "content_digest": basis.profile.content_digest,
        },
        "graph_sha256": basis.graph_sha256,
        "provenance_sha256": basis.provenance_sha256,
        "metadata_sha256": basis.metadata_sha256,
        "problem_sha256": basis.problem_sha256,
        "observations_sha256": basis.observations_sha256,
        "entrypoints_sha256": basis.entrypoints_sha256,
    })
}

fn status_name<P>(status: Status<'_, P>) -> &'static str {
    match status {
        Status::Matched => "Matched",
        Status::Mismatched => "Mismatched",
        Status::UncheckedByDecode(_) => "UncheckedByDecode",
        Status::UncheckedBySource(_) => "UncheckedBySource",
    }
}

fn certificate_value(mismatch: &Mismatch<String>) -> Value {
    let conditions = Condition::ALL
        .iter()
        .map(|condition| {
            (
                condition.name().to_owned(),
                json!(status_name(mismatch.status_at(*condition))),
            )
        })
        .collect::<serde_json::Map<_, _>>();
    let checks = mismatch.checks();
    let mut failures = Vec::new();
    if let Prerequisite::Failed(failure) = checks.decode() {
        failures
            .push(json!({"condition": Condition::Decode.name(), "operation": failure.operation}));
    }
    match checks.source() {
        Prerequisite::Failed(failure) => {
            failures.push(
                json!({"condition": Condition::Source.name(), "operation": failure.operation}),
            );
        }
        Prerequisite::Established(source) => {
            if let Some(failure) = source.coordinate().failure() {
                failures.push(json!({"condition": Condition::Coordinate.name(), "operation": failure.operation}));
            }
            if let Some(failure) = source.observations().failure() {
                failures.push(json!({"condition": Condition::Observations.name(), "operation": failure.operation}));
            }
            if let Some(failure) = source.residual().failure() {
                failures.push(json!({"condition": Condition::Residual.name(), "operation": failure.operation}));
            }
        }
    }
    let origin = mismatch.origin();
    let digests = match checks.decode() {
        Prerequisite::Established(digests) => Value::Object(
            digests
                .iter()
                .map(|(name, result)| (name.clone(), json!(projection_label(result))))
                .collect(),
        ),
        Prerequisite::Failed(_) => Value::Null,
    };
    json!({
        "kind": "certificate",
        "conditions": conditions,
        "failures": failures,
        "digests": digests,
        "origin": {
            "rule_revision": origin.rule_revision,
            "source_identity": origin.source_identity,
            "source_revision": origin.source_revision,
        },
        "provenance": mismatch.provenance(),
    })
}

fn projection_label(result: &ProjectionResult) -> &'static str {
    match result {
        ProjectionResult::Matched(_) => "matched",
        ProjectionResult::CertificateOnly(_) => "certificateOnly",
        ProjectionResult::RecomputedOnly(_) => "recomputedOnly",
        ProjectionResult::Different { .. } => "different",
    }
}

fn admission_failure_value(failure: &AdmissionFailure) -> Value {
    match failure {
        AdmissionFailure::UnsupportedSchema(actual) => json!({"kind": "schema", "actual": actual}),
        AdmissionFailure::EntrypointsEmpty => json!({"kind": "entrypoints_empty"}),
        AdmissionFailure::EntrypointIdentityEmpty => json!({"kind": "entrypoint_identity_empty"}),
        AdmissionFailure::EntrypointDuplicate(identity) => {
            json!({"kind": "entrypoint_duplicate", "identity": identity})
        }
        AdmissionFailure::EntrypointUnresolved {
            identity,
            definition,
        } => json!({
            "kind": "entrypoint_unresolved",
            "identity": identity,
            "definition": definition,
        }),
        AdmissionFailure::Library(failure) => json!({
            "kind": "declaration",
            "reason": match failure {
                LibraryCheckFailure::Profile(failure) => variant_name(&failure.predicate),
                LibraryCheckFailure::Library(failure) => variant_name(&failure.predicate),
            },
        }),
        AdmissionFailure::Certificate(mismatch) => certificate_value(mismatch),
        AdmissionFailure::CompositionInput(failure) => {
            json!({"kind": "composition", "reason": variant_name(failure)})
        }
        AdmissionFailure::Composition(failure) => {
            json!({"kind": "composition", "reason": variant_name(failure)})
        }
        AdmissionFailure::Wire(failure) => {
            json!({"kind": "composition", "reason": wire_tag(failure)})
        }
        AdmissionFailure::Generation(failure) => generation_failure_value(failure),
        AdmissionFailure::RuleTable(_) => json!({"kind": "rule_table"}),
    }
}

fn generation_failure_value(failure: &GenerationFailure) -> Value {
    match failure {
        GenerationFailure::InvalidJson(_) => json!({"kind": "decode", "reason": "exchange_json"}),
        GenerationFailure::UnsupportedSchema { observed, .. } => {
            json!({"kind": "schema", "actual": observed})
        }
        GenerationFailure::Admission(inner) => admission_failure_value(inner),
        other => json!({"kind": "decode", "reason": format!("exchange.{}", wire_tag(other))}),
    }
}

fn wire_tag(failure: &GenerationFailure) -> String {
    match failure {
        GenerationFailure::Syntax { .. } => "syntax".to_owned(),
        GenerationFailure::UnknownField { .. } => "unknownField".to_owned(),
        GenerationFailure::UnknownTag { .. } => "unknownTag".to_owned(),
        GenerationFailure::UnsupportedSchema { .. } => "unsupportedSchema".to_owned(),
        other => variant_name(other),
    }
}

enum RequestFailure {
    Json,
    Exchange,
    ExpectedBasis,
    ExpectedBasisDecode(GenerationFailure),
}

fn request_failure(failure: &RequestFailure) -> Value {
    let reason = match failure {
        RequestFailure::Json => "request_json".to_owned(),
        RequestFailure::Exchange => "request_exchange".to_owned(),
        RequestFailure::ExpectedBasis => "request_expected_basis".to_owned(),
        RequestFailure::ExpectedBasisDecode(failure) => {
            format!("expected_basis.{}", wire_tag(failure))
        }
    };
    json!({"result": "failed", "failure": {"kind": "request", "reason": reason}})
}

fn request_mode(request: &Value) -> Option<bool> {
    match request.get("mode") {
        None => Some(false),
        Some(Value::String(mode)) if mode == "admission" => Some(false),
        Some(Value::String(mode)) if mode == "propagation" => Some(true),
        Some(_) => None,
    }
}

type Admit = fn(
    &ExpectedSignatureBasis,
    necoherence::type_signatures::SignatureGenerationInput,
) -> necoherence::signature_admission::Result<
    necoherence::signature_admission::CheckedSignatureGeneration,
>;

fn admit_verified(
    expected: &ExpectedSignatureBasis,
    input: necoherence::type_signatures::SignatureGenerationInput,
) -> necoherence::signature_admission::Result<CheckedSignatureGeneration> {
    let checked = admit_signature_generation(expected, input)?;
    verified_signature_derivation(checked.input(), checked.graph()).map_err(
        |error| match error {
            SignatureCompositionAdmissionFailure::Wire(value) => AdmissionFailure::Wire(value),
            SignatureCompositionAdmissionFailure::CompositionInput(value) => {
                AdmissionFailure::CompositionInput(value)
            }
            SignatureCompositionAdmissionFailure::Composition(value) => {
                AdmissionFailure::Composition(value)
            }
        },
    )?;
    Ok(checked)
}

fn admission_outcome(expected: &ExpectedSignatureBasis, exchange: &str, admit: Admit) -> Value {
    let input = match decode_signature_generation(exchange) {
        Ok(input) => input,
        Err(failure) => {
            return json!({"result": "failed", "failure": generation_failure_value(&failure)});
        }
    };
    match admit(expected, input) {
        Ok(checked) => {
            let basis = checked.input().basis.clone();
            let mut entrypoints = checked.input().entrypoints.clone();
            entrypoints.sort_by(|left, right| left.identity.cmp(&right.identity));
            let entrypoints = entrypoints
                .iter()
                .map(|entrypoint| {
                    json!({"identity": entrypoint.identity, "definition": entrypoint.definition})
                })
                .collect::<Vec<_>>();
            let composition = checked
                .composition()
                .map(|_| json!({"problem_sha256": basis.problem_sha256}));
            json!({
                "result": "accepted",
                "checked": {
                    "basis": basis_value(&basis),
                    "library": {
                        "identity": basis.library_identity,
                        "revision": basis.library_revision,
                    },
                    "entrypoints": entrypoints,
                    "composition": composition,
                },
            })
        }
        Err(failure) => json!({
            "result": "failed",
            "failure": admission_failure_value(&failure),
        }),
    }
}

fn context_boundary(expected: &ExpectedSignatureBasis, exchange: &str) -> Value {
    let input = match decode_signature_generation(exchange) {
        Ok(input) => input,
        Err(failure) => {
            return json!({"result": "failed", "failure": generation_failure_value(&failure)});
        }
    };
    match admit_verified(expected, input) {
        Ok(_) => json!({"result": "accepted"}),
        Err(failure) => json!({
            "result": "failed",
            "failure": generation_failure_value(&GenerationFailure::Admission(Box::new(failure))),
        }),
    }
}

fn generator_boundary(expected: &ExpectedSignatureBasis, exchange: &str) -> Value {
    match render_signature_exchange_for(&Target::Rust, expected, exchange) {
        Ok(_) => json!({"result": "accepted"}),
        Err(RenderFailure::Admission(failure)) => {
            json!({"result": "failed", "failure": admission_failure_value(&failure)})
        }
        Err(RenderFailure::Generation(failure)) => {
            json!({"result": "failed", "failure": generation_failure_value(&failure)})
        }
        Err(failure) => json!({
            "result": "failed",
            "failure": {"kind": "rendering", "reason": variant_name(&failure)},
        }),
    }
}

fn outcome(line: &str) -> Value {
    let Ok(request) = serde_json::from_str::<Value>(line) else {
        return request_failure(&RequestFailure::Json);
    };
    let Some(exchange) = request.get("exchange").and_then(Value::as_str) else {
        return request_failure(&RequestFailure::Exchange);
    };
    let Some(expected_value) = request.get("expected_basis") else {
        return request_failure(&RequestFailure::ExpectedBasis);
    };
    let expected = match decode_expected_signature_basis(&expected_value.to_string()) {
        Ok(expected) => expected,
        Err(failure) => return request_failure(&RequestFailure::ExpectedBasisDecode(failure)),
    };
    let Some(propagate) = request_mode(&request) else {
        return json!({"result": "failed", "failure": {"kind": "request", "reason": "request_mode"}});
    };
    if !propagate {
        return admission_outcome(&expected, exchange, admit_signature_generation);
    }
    let admission = admission_outcome(&expected, exchange, admit_verified);
    json!({
        "admission": admission,
        "boundaries": {
            "generation": context_boundary(&expected, exchange),
            "generator": generator_boundary(&expected, exchange),
        },
    })
}

fn panic_message(payload: Box<dyn std::any::Any + Send>) -> String {
    match payload.downcast::<String>() {
        Ok(message) => *message,
        Err(payload) => match payload.downcast::<&str>() {
            Ok(message) => (*message).to_owned(),
            Err(_) => "panic".to_owned(),
        },
    }
}

fn guarded_outcome(line: &str) -> Value {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| outcome(line))) {
        Ok(value) => value,
        Err(payload) => json!({"error": panic_message(payload)}),
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut output = io::stdout().lock();
    let mut arguments = std::env::args().skip(1);
    if arguments.next().as_deref() == Some("--batch") && arguments.next().is_none() {
        std::panic::set_hook(Box::new(|_| {}));
        for line in io::stdin().lock().lines() {
            serde_json::to_writer(&mut output, &guarded_outcome(&line?))?;
            output.write_all(b"\n")?;
        }
    } else {
        let mut text = String::new();
        io::stdin().lock().read_to_string(&mut text)?;
        serde_json::to_writer(&mut output, &outcome(&text))?;
        output.write_all(b"\n")?;
    }
    Ok(())
}
