// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT
#![allow(
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::panic,
    clippy::unwrap_used
)]
use neco_quotient_encoding::{canonical_bytes, decode_canonical, JsonValue as Neco};
use necoherence::semantic_refinement::*;
use necoherence::semantic_residual_record::*;
use necoherence::semantic_types::*;
use necoherence::signature_admission::*;
use necoherence::type_signatures::*;
use num_bigint::{BigInt, BigUint};

fn reference() -> ProfileRef {
    ProfileRef {
        identity: "p".into(),
        revision: "1".into(),
        content_digest: "a".repeat(64),
    }
}

fn profile() -> ValueSemanticProfile {
    ValueSemanticProfile {
        reference: reference(),
        source_refs: vec![],
        integer_domains: vec![IntegerDomainBinding {
            name: "integer".into(),
            reference: reference(),
            range: IntegerDomain::Inclusive {
                minimum: BigInt::from(-10),
                maximum: BigInt::from(10),
            },
            forms: vec![IntegerForm::Number, IntegerForm::DecimalString],
        }],
        default_integer_domain: "integer".into(),
        numbers: NumberModel { decimals: true },
        grapheme_rules: None,
        format_bindings: vec![FormatBinding {
            name: "name".into(),
            reference: reference(),
            rule: FormatRule::Not(Box::new(FormatRule::Literal("bad".into()))),
        }],
        wrappers: vec![Wrapper {
            name: "wrapped".into(),
            key: "$value".into(),
            payload: WrapperPayload::Text { format: None },
        }],
        tag: Some(TagModel {
            key: "kind".into(),
            format: None,
            sealed: vec![SealedForm {
                tag: "sealed".into(),
                fields: vec![SealedField {
                    key: "name".into(),
                    required: true,
                    leaf: SealedLeaf::String(StringSpec {
                        format: None,
                        lengths: vec![],
                        wrapper: None,
                        const_value: None,
                        enum_values: None,
                        examples: vec![],
                        default_value: None,
                    }),
                }],
                extras: SealedExtras::Reject,
            }],
        }),
        bytes_policy: None,
    }
}

fn library() -> TypeSignatureLibrary {
    TypeSignatureLibrary {
        schema: "ncoh-type-signatures@1".into(),
        identity: "library".into(),
        revision: "1".into(),
        profile: profile(),
        sources: vec![],
        provenance: vec![],
        groups: vec![],
        annotations: vec![],
        nodes: vec![
            TypeNodeInput {
                id: "text".into(),
                shape: Shape::String(StringSpec {
                    format: Some(FormatUse::Named("name".into())),
                    lengths: vec![LengthBound {
                        unit: StringLengthUnit::UnicodeScalars,
                        minimum: Some(BigUint::from(1u8)),
                        maximum: Some(BigUint::from(8u8)),
                    }],
                    wrapper: None,
                    const_value: None,
                    enum_values: None,
                    examples: vec!["ok".into()],
                    default_value: None,
                }),
            },
            TypeNodeInput {
                id: "never".into(),
                shape: Shape::Never,
            },
            TypeNodeInput {
                id: "sealed".into(),
                shape: Shape::Sealed {
                    tag: "sealed".into(),
                    refinements: vec![],
                },
            },
            TypeNodeInput {
                id: "choice".into(),
                shape: Shape::TaggedUnion(SignatureUnion {
                    branches: vec![
                        SignatureUnionBranch {
                            target: "sealed".into(),
                            wire_tag: "sealed".into(),
                            selector: BranchSelector::InternalTag,
                        },
                        SignatureUnionBranch {
                            target: "text".into(),
                            wire_tag: "text".into(),
                            selector: BranchSelector::Kind(ValueKind::String),
                        },
                    ],
                }),
            },
        ],
        definitions: vec![DefinitionInput {
            id: "entry".into(),
            wire_identity: "entry".into(),
            shape: SignatureDefinitionShape::Value("choice".into()),
        }],
    }
}

fn entry() -> SignatureEntrypoint {
    SignatureEntrypoint {
        identity: "entry".into(),
        definition: "entry".into(),
    }
}

fn checked() -> CheckedSignatureGeneration {
    let generation = assemble_signature_generation(library(), None, vec![entry()]).unwrap();
    admit_signature_generation(
        &ExpectedSignatureBasis::of_input(&generation),
        generation.clone(),
    )
    .unwrap()
}

fn unresolved_input() -> SemanticValueInput {
    SemanticValueInput {
        type_ref: signature_type_ref("additional-text"),
        value: JsonValue::Str("ok".into()),
    }
}

fn obligations_of(evaluation: &SignatureEvaluation) -> Vec<SemanticObligation> {
    match evaluation.outcome() {
        Ok(RefinementOutcome::Residual { residuals, .. }) => residuals.iter().cloned().collect(),
        other => panic!("expected residual, got {other:?}"),
    }
}

fn fixture() -> (
    CheckedSignatureGeneration,
    SemanticValueInput,
    Vec<SemanticObligation>,
) {
    let checked = checked();
    let input = unresolved_input();
    let evaluation = open_signature_evaluation(&checked, input.clone(), "1".into());
    let obligations = obligations_of(&evaluation);
    assert_eq!(obligations.len(), 1);
    (checked, input, obligations)
}

fn second_obligation(first: &SemanticObligation) -> SemanticObligation {
    SemanticObligation {
        reason: SemanticReason::UnknownFormat("another".into()),
        ..first.clone()
    }
}

fn encode_of(
    checked: &CheckedSignatureGeneration,
    input: &SemanticValueInput,
    obligations: &[SemanticObligation],
) -> Vec<u8> {
    encode_semantic_residual(
        &checked.input().basis,
        &input.type_ref,
        &input.value,
        obligations,
    )
    .unwrap()
}

fn fields_of(bytes: &[u8]) -> Vec<(String, Neco)> {
    match decode_canonical(bytes).unwrap() {
        Neco::Object(fields) => fields,
        other => panic!("expected object, got {other:?}"),
    }
}

fn rebuild(fields: Vec<(String, Neco)>) -> Vec<u8> {
    canonical_bytes(&Neco::Object(fields)).unwrap()
}

fn replace_field(fields: &mut [(String, Neco)], name: &str, value: Neco) {
    let slot = fields.iter_mut().find(|(key, _)| key == name).unwrap();
    slot.1 = value;
}

fn without_field(bytes: &[u8], name: &str) -> Vec<u8> {
    let mut fields = fields_of(bytes);
    fields.retain(|(key, _)| key != name);
    rebuild(fields)
}

#[test]
fn roundtrip_restores_basis_input_and_residuals() {
    let (checked, input, obligations) = fixture();
    let bytes = encode_of(&checked, &input, &obligations);
    let record = decode_semantic_residual(&bytes).unwrap();
    assert_eq!(*record.basis(), checked.input().basis);
    assert_eq!(*record.input(), input);
    assert_eq!(
        *record.residuals(),
        ResidualSet::new(obligations.iter().cloned())
    );
}

#[test]
fn roundtrip_restores_two_residuals() {
    let (checked, input, obligations) = fixture();
    let both = vec![obligations[0].clone(), second_obligation(&obligations[0])];
    let record = decode_semantic_residual(&encode_of(&checked, &input, &both)).unwrap();
    assert_eq!(*record.residuals(), ResidualSet::new(both));
}

#[test]
fn bytes_do_not_depend_on_residual_order_or_repetition() {
    let (checked, input, obligations) = fixture();
    let first = obligations[0].clone();
    let second = second_obligation(&first);
    let forward = encode_of(&checked, &input, &[first.clone(), second.clone()]);
    let backward = encode_of(&checked, &input, &[second.clone(), first.clone()]);
    let repeated = encode_of(
        &checked,
        &input,
        &[first.clone(), second.clone(), first.clone(), second.clone()],
    );
    assert_eq!(forward, backward);
    assert_eq!(forward, repeated);
}

#[test]
fn opened_record_connects_to_refinement_and_resolves_the_residual() {
    let (checked, input, obligations) = fixture();
    let record = decode_semantic_residual(&encode_of(&checked, &input, &obligations)).unwrap();
    let before = open_semantic_residual(&checked, &record, "1".into()).unwrap();
    assert_eq!(*before.input(), input);
    assert!(
        matches!(before.outcome(), Ok(RefinementOutcome::Residual { residuals, .. }) if residuals.len() == 1)
    );
    let node = TypeNode {
        reference: input.type_ref.clone(),
        shape: TypeShape::String(StringSpec {
            format: Some(FormatUse::Named("name".into())),
            lengths: vec![],
            wrapper: None,
            const_value: None,
            enum_values: None,
            examples: vec![],
            default_value: None,
        }),
        description: None,
        attributes: vec![],
        extensions: vec![],
    };
    let information = AdditionalSemanticInformation {
        nodes: vec![node],
        profile: profile().semantic_profile(),
    };
    let (after, _) = refine_signature_evaluation(&before, information, "2".into()).unwrap();
    assert!(matches!(
        after.outcome(),
        Ok(RefinementOutcome::Resolved(SemanticJudgment {
            decision: ValueDecision::Accepted,
            ..
        }))
    ));
}

#[test]
fn record_with_another_basis_is_rejected() {
    let (checked, input, obligations) = fixture();
    let mut basis = checked.input().basis.clone();
    basis.graph_sha256 = "0".repeat(64);
    let record = SemanticResidualRecord::new(basis.clone(), input, ResidualSet::new(obligations));
    match open_semantic_residual(&checked, &record, "1".into()) {
        Err(SemanticResidualFailure::BasisMismatch { recorded, admitted }) => {
            assert_eq!(recorded, basis);
            assert_eq!(admitted, checked.input().basis);
        }
        other => panic!("expected basis mismatch, got {other:?}"),
    }
}

#[test]
fn record_without_an_obligation_is_rejected() {
    let (checked, input, obligations) = fixture();
    let record = SemanticResidualRecord::new(
        checked.input().basis.clone(),
        input,
        ResidualSet::new(Vec::new()),
    );
    match open_semantic_residual(&checked, &record, "1".into()) {
        Err(SemanticResidualFailure::ResidualMismatch {
            recorded,
            evaluated,
        }) => {
            assert!(recorded.is_empty());
            assert_eq!(evaluated, obligations);
        }
        other => panic!("expected residual mismatch, got {other:?}"),
    }
}

#[test]
fn record_with_an_added_obligation_is_rejected() {
    let (checked, input, obligations) = fixture();
    let extra = second_obligation(&obligations[0]);
    let record = SemanticResidualRecord::new(
        checked.input().basis.clone(),
        input,
        ResidualSet::new([obligations[0].clone(), extra.clone()]),
    );
    match open_semantic_residual(&checked, &record, "1".into()) {
        Err(SemanticResidualFailure::ResidualMismatch {
            recorded,
            evaluated,
        }) => {
            assert!(recorded.contains(&extra));
            assert_eq!(evaluated, obligations);
        }
        other => panic!("expected residual mismatch, got {other:?}"),
    }
}

#[test]
fn bytes_missing_a_field_are_rejected_for_each_field() {
    let (checked, input, obligations) = fixture();
    let bytes = encode_of(&checked, &input, &obligations);
    for name in ["schema", "basis", "input", "residuals"] {
        match decode_semantic_residual(&without_field(&bytes, name)) {
            Err(SemanticResidualFailure::MissingField(missing)) => assert_eq!(missing, name),
            other => panic!("expected missing {name}, got {other:?}"),
        }
    }
}

#[test]
fn input_missing_a_field_is_rejected() {
    let (checked, input, obligations) = fixture();
    let bytes = encode_of(&checked, &input, &obligations);
    for name in ["type_ref", "value"] {
        let mut fields = fields_of(&bytes);
        let Neco::Object(mut inner) = fields
            .iter()
            .find(|(key, _)| key == "input")
            .unwrap()
            .1
            .clone()
        else {
            panic!("input is an object");
        };
        inner.retain(|(key, _)| key != name);
        replace_field(&mut fields, "input", Neco::Object(inner));
        match decode_semantic_residual(&rebuild(fields)) {
            Err(SemanticResidualFailure::MissingField(missing)) => assert_eq!(missing, name),
            other => panic!("expected missing {name}, got {other:?}"),
        }
    }
}

#[test]
fn bytes_with_an_unknown_field_are_rejected() {
    let (checked, input, obligations) = fixture();
    let bytes = encode_of(&checked, &input, &obligations);
    let mut fields = fields_of(&bytes);
    fields.push(("extra".into(), Neco::Null));
    match decode_semantic_residual(&rebuild(fields)) {
        Err(SemanticResidualFailure::UnknownField(name)) => assert_eq!(name, "extra"),
        other => panic!("expected unknown field, got {other:?}"),
    }
}

#[test]
fn input_with_an_unknown_field_is_rejected() {
    let (checked, input, obligations) = fixture();
    let bytes = encode_of(&checked, &input, &obligations);
    let mut fields = fields_of(&bytes);
    let Neco::Object(mut inner) = fields
        .iter()
        .find(|(key, _)| key == "input")
        .unwrap()
        .1
        .clone()
    else {
        panic!("input is an object");
    };
    inner.push(("extra".into(), Neco::Null));
    replace_field(&mut fields, "input", Neco::Object(inner));
    assert!(matches!(
        decode_semantic_residual(&rebuild(fields)),
        Err(SemanticResidualFailure::UnknownField(name)) if name == "extra"
    ));
}

#[test]
fn bytes_with_another_schema_are_rejected() {
    let (checked, input, obligations) = fixture();
    let bytes = encode_of(&checked, &input, &obligations);
    let mut fields = fields_of(&bytes);
    replace_field(&mut fields, "schema", Neco::String("other.v2".into()));
    match decode_semantic_residual(&rebuild(fields)) {
        Err(SemanticResidualFailure::UnsupportedSchema(schema)) => assert_eq!(schema, "other.v2"),
        other => panic!("expected unsupported schema, got {other:?}"),
    }
}

#[test]
fn reversed_residuals_are_rejected_as_not_normalized() {
    let (checked, input, obligations) = fixture();
    let both = [obligations[0].clone(), second_obligation(&obligations[0])];
    let bytes = encode_of(&checked, &input, &both);
    let mut fields = fields_of(&bytes);
    let Neco::Array(mut items) = fields
        .iter()
        .find(|(key, _)| key == "residuals")
        .unwrap()
        .1
        .clone()
    else {
        panic!("residuals is an array");
    };
    assert_eq!(items.len(), 2);
    items.reverse();
    replace_field(&mut fields, "residuals", Neco::Array(items));
    assert!(matches!(
        decode_semantic_residual(&rebuild(fields)),
        Err(SemanticResidualFailure::ResidualsNotNormalized)
    ));
}

#[test]
fn bytes_that_are_not_canonical_are_rejected() {
    let (checked, input, obligations) = fixture();
    let mut bytes = encode_of(&checked, &input, &obligations);
    bytes.insert(0, b' ');
    assert!(matches!(
        decode_semantic_residual(&bytes),
        Err(SemanticResidualFailure::Encoding(_))
    ));
}
