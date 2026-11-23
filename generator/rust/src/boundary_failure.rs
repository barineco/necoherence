// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use crate::renderer::RenderFailure;
use neco_quotient_certificate::{Condition, Mismatch, Prerequisite, ProjectionResult, Status};
use necoherence::semantic_exchange::GenerationFailure;
use necoherence::signature_admission::AdmissionFailure;
use necoherence::type_signatures::LibraryCheckFailure;
use serde_json::{json, Value};

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

pub fn generator_failure_value(failure: &RenderFailure) -> Value {
    match failure {
        RenderFailure::Admission(failure) => admission_failure_value(failure),
        RenderFailure::Generation(failure) => generation_failure_value(failure),
        other => json!({"kind": "rendering", "reason": variant_name(other)}),
    }
}
