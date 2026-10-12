// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT
#![allow(clippy::expect_used, clippy::unwrap_used)]
use necoherence::semantic_codegen_runtime::{select_branch, with_member, wrap_decode, wrap_encode};
use necoherence::semantic_composition::{
    check_assignable, slot_samples, CompatibilityDecision, SearchBounds,
};
use necoherence::semantic_exchange::*;
use necoherence::semantic_types::*;
use necoherence::semantic_validation::*;
use necoherence::signature_admission::*;
use necoherence::type_signatures::*;
use num_bigint::{BigInt, BigUint};
use std::sync::Arc;

fn fixture_item<T>(items: &[T], index: usize) -> &T {
    items.get(index).expect("fixture item exists")
}

fn fixture_item_mut<T>(items: &mut [T], index: usize) -> &mut T {
    items.get_mut(index).expect("fixture item exists")
}

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
#[test]
fn profile_library_diagnostic_and_basis_satisfy_both_wire_identities() {
    const PROFILE_DOCUMENT: &str = r#"{"reference":{"identity":"p","revision":"1","content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"source_refs":[],"integer_domains":[{"name":"integer","reference":{"identity":"p","revision":"1","content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"range":{"tag":"Inclusive","fields":{"minimum":"-10","maximum":"10"}},"forms":[{"tag":"Number"},{"tag":"DecimalString"}]}],"default_integer_domain":"integer","numbers":{"decimals":true},"grapheme_rules":null,"format_bindings":[{"name":"name","reference":{"identity":"p","revision":"1","content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"rule":{"tag":"Not","value":{"tag":"Literal","value":"bad"}}}],"wrappers":[{"name":"wrapped","key":"$value","payload":{"tag":"Text","value":null}}],"tag":{"key":"kind","format":null,"sealed":[{"tag":"sealed","fields":[{"key":"name","required":true,"leaf":{"tag":"String","value":{"format":null,"lengths":[],"wrapper":null,"const_value":null,"enum_values":null,"examples":[],"default_value":null}}}],"extras":{"tag":"Reject"}}]},"bytes_policy":null}"#;
    const LIBRARY_DOCUMENT: &str = r#"{"schema":"ncoh-type-signatures@1","identity":"library","revision":"1","profile":{"reference":{"identity":"p","revision":"1","content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"source_refs":[],"integer_domains":[{"name":"integer","reference":{"identity":"p","revision":"1","content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"range":{"tag":"Inclusive","fields":{"minimum":"-10","maximum":"10"}},"forms":[{"tag":"Number"},{"tag":"DecimalString"}]}],"default_integer_domain":"integer","numbers":{"decimals":true},"grapheme_rules":null,"format_bindings":[{"name":"name","reference":{"identity":"p","revision":"1","content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"rule":{"tag":"Not","value":{"tag":"Literal","value":"bad"}}}],"wrappers":[{"name":"wrapped","key":"$value","payload":{"tag":"Text","value":null}}],"tag":{"key":"kind","format":null,"sealed":[{"tag":"sealed","fields":[{"key":"name","required":true,"leaf":{"tag":"String","value":{"format":null,"lengths":[],"wrapper":null,"const_value":null,"enum_values":null,"examples":[],"default_value":null}}}],"extras":{"tag":"Reject"}}]},"bytes_policy":null},"sources":[],"provenance":[],"groups":[],"annotations":[],"nodes":[{"id":"text","shape":{"tag":"String","value":{"format":{"tag":"Named","value":"name"},"lengths":[{"unit":{"tag":"UnicodeScalars"},"minimum":"1","maximum":"8"}],"wrapper":null,"const_value":null,"enum_values":null,"examples":["ok"],"default_value":null}}},{"id":"never","shape":{"tag":"Never"}},{"id":"sealed","shape":{"tag":"Sealed","fields":{"tag":"sealed","refinements":[]}}},{"id":"choice","shape":{"tag":"TaggedUnion","value":{"branches":[{"target":"sealed","wire_tag":"sealed","selector":{"tag":"InternalTag"}},{"target":"text","wire_tag":"text","selector":{"tag":"Kind","value":{"tag":"String"}}}]}}}],"definitions":[{"id":"entry","wire_identity":"entry","shape":{"tag":"Value","value":"choice"}}]}"#;
    const DIAGNOSTIC_DOCUMENT: &str = r#"{"type_ref":{"source":{"repository":"library","revision":"1","path":"type-signatures","content_digest":"94f196594e660ada1272bb9dbb9c599e76e65527d78de0551329cc07caf96b72","document_id":"library","declared_revision":null},"definition_name":"text","pointer":[]},"definition_ref":{"source":{"repository":"library","revision":"1","path":"type-signatures","content_digest":"94f196594e660ada1272bb9dbb9c599e76e65527d78de0551329cc07caf96b72","document_id":"library","declared_revision":null},"name":"text"},"origin":{"source":{"repository":"library","revision":"1","path":"type-signatures","content_digest":"94f196594e660ada1272bb9dbb9c599e76e65527d78de0551329cc07caf96b72","document_id":"library","declared_revision":null},"pointer":[]},"value_path":[{"tag":"Field","value":"value"}],"condition":{"tag":"WrongValueKind","value":"string"},"observed":{"tag":"Present","value":{"tag":"Bool","value":false}},"reference_trace":[{"source":{"repository":"library","revision":"1","path":"type-signatures","content_digest":"94f196594e660ada1272bb9dbb9c599e76e65527d78de0551329cc07caf96b72","document_id":"library","declared_revision":null},"definition_name":"text","pointer":[]}]}"#;
    const BASIS_DOCUMENT: &str = r#"{"signature_schema":"ncoh-type-signatures@1","library_identity":"library","library_revision":"1","profile":{"identity":"p","revision":"1","content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"graph_sha256":"94f196594e660ada1272bb9dbb9c599e76e65527d78de0551329cc07caf96b72","provenance_sha256":"889f7da3d12b8a6f8275f818e53a7a06a6610d6efb5611216203516c3c8768d0","metadata_sha256":"3569712bffea9c9e73522a4aa7aab393ef3d1f2e31a77467b909e68e120b591f","problem_sha256":null,"entrypoints_sha256":"51d63858f4d39b9be2215aa09f1203602ad68aff1b01904d0c38a770d06e80ca"}"#;

    let input = assemble_signature_generation(
        library(),
        None,
        vec![SignatureEntrypoint {
            identity: "entry".into(),
            definition: "entry".into(),
        }],
    )
    .unwrap();
    let profile = ValueSemanticProfile::from_profile(&input.signatures.profile.semantic_profile());
    let graph = check_type_signatures(&input.signatures).unwrap();
    let type_ref = fixture_item(&graph.nodes, 0).reference.clone();
    let diagnostic = ValueFailure {
        type_ref: type_ref.clone(),
        definition_ref: DefinitionRef {
            source: type_ref.source.clone(),
            name: type_ref.definition_name.clone(),
        },
        origin: (&type_ref).into(),
        value_path: vec![PathStep::Field("value".into())],
        condition: ValueCondition::WrongValueKind("string".into()),
        observed: SlotValue::Present(JsonValue::Bool(false)),
        reference_trace: vec![type_ref],
    };

    assert_eq!(
        decode_value_profile(&encode_value_profile(&profile).unwrap()).unwrap(),
        profile
    );
    assert_eq!(
        decode_type_signatures(&encode_type_signatures(&input.signatures).unwrap()).unwrap(),
        *input.signatures
    );
    assert_eq!(
        decode_diagnostic(&encode_diagnostic(&diagnostic).unwrap()).unwrap(),
        diagnostic
    );
    assert_eq!(
        decode_signature_basis(&encode_signature_basis(&input.basis).unwrap()).unwrap(),
        input.basis
    );
    assert_eq!(
        encode_value_profile(&decode_value_profile(PROFILE_DOCUMENT).unwrap()).unwrap(),
        PROFILE_DOCUMENT
    );
    assert_eq!(
        encode_type_signatures(&decode_type_signatures(LIBRARY_DOCUMENT).unwrap()).unwrap(),
        LIBRARY_DOCUMENT
    );
    assert_eq!(
        encode_diagnostic(&decode_diagnostic(DIAGNOSTIC_DOCUMENT).unwrap()).unwrap(),
        DIAGNOSTIC_DOCUMENT
    );
    assert_eq!(
        encode_signature_basis(&decode_signature_basis(BASIS_DOCUMENT).unwrap()).unwrap(),
        BASIS_DOCUMENT
    );
}

fn generation_with_pr01() -> (SignatureGenerationBasis, SignatureGenerationInput) {
    let mut input = assemble_signature_generation(library(), None, vec![]).unwrap();
    let expected = input.basis.clone();
    Arc::make_mut(&mut input.signatures)
        .profile
        .reference
        .identity
        .clear();
    (expected, input)
}

fn is_pr01(failure: &LibraryCheckFailure) -> bool {
    matches!(
        failure,
        LibraryCheckFailure::Profile(ProfileFailure {
            predicate: ProfilePredicate::Pr01,
            ..
        })
    )
}

#[test]
fn pr01_is_preserved_by_json_wire_and_admission_entries() {
    let mut invalid_profile = profile();
    invalid_profile.reference.identity.clear();
    assert!(matches!(
        decode_value_profile(&encode_value_profile(&invalid_profile).unwrap()),
        Err(GenerationFailure::Profile(ProfileFailure {
            predicate: ProfilePredicate::Pr01,
            ..
        }))
    ));

    let (expected, invalid_input) = generation_with_pr01();
    assert!(matches!(
        decode_signature_generation(&encode_signature_generation(&invalid_input).unwrap()),
        Err(GenerationFailure::Library(ref failure)) if is_pr01(failure)
    ));
    assert!(matches!(
        admit_signature_generation(&expected, invalid_input),
        Err(AdmissionFailure::Library(ref failure)) if is_pr01(failure)
    ));
}

#[test]
fn legacy_key_tag_and_compatibility_field_are_typed_wire_failures() {
    let input = assemble_signature_generation(library(), None, vec![]).unwrap();
    let document = encode_signature_generation(&input).unwrap();
    let mut old_schema: serde_json::Value = serde_json::from_str(&document).unwrap();
    *old_schema.pointer_mut("/schema").unwrap() =
        serde_json::Value::String("ncoh-checked-generation@3".into());
    assert!(matches!(
        decode_signature_generation(&serde_json::to_string(&old_schema).unwrap()),
        Err(GenerationFailure::UnsupportedSchema { observed })
            if observed == "ncoh-checked-generation@3"
    ));

    let mut old_key: serde_json::Value = serde_json::from_str(&document).unwrap();
    old_key
        .pointer_mut("/signatures/profile")
        .unwrap()
        .as_object_mut()
        .unwrap()
        .insert("representation".into(), serde_json::Value::Null);
    assert!(matches!(
        decode_signature_generation(&serde_json::to_string(&old_key).unwrap()),
        Err(GenerationFailure::UnknownField { path, field })
            if path == "$.signatures.profile" && field == "representation"
    ));

    let mut old_tag: serde_json::Value = serde_json::from_str(&document).unwrap();
    *old_tag.pointer_mut("/signatures/nodes/0/shape").unwrap() = serde_json::json!({"tag": "Cid"});
    assert!(matches!(
        decode_signature_generation(&serde_json::to_string(&old_tag).unwrap()),
        Err(GenerationFailure::UnknownTag { path, tag })
            if path == "$.signatures.nodes[0].shape.tag" && tag == "Cid"
    ));

    let mut compatibility_field: serde_json::Value = serde_json::from_str(&document).unwrap();
    compatibility_field
        .pointer_mut("/signatures/nodes/3/shape/value")
        .unwrap()
        .as_object_mut()
        .unwrap()
        .insert("closed".into(), serde_json::Value::Bool(true));
    assert!(matches!(
        decode_signature_generation(&serde_json::to_string(&compatibility_field).unwrap()),
        Err(GenerationFailure::UnknownField { path, field })
            if path == "$.signatures.nodes[3].shape.value" && field == "closed"
    ));
}
#[test]
fn profile_predicates_and_entry_checks_are_typed() {
    let mut p = profile().semantic_profile();
    p.reference.identity.clear();
    assert_eq!(
        check_profile(&p).unwrap_err().predicate,
        ProfilePredicate::Pr01
    );
    let mut p = profile().semantic_profile();
    p.integer_domains
        .push(fixture_item(&p.integer_domains, 0).clone());
    assert_eq!(
        check_profile(&p).unwrap_err().predicate,
        ProfilePredicate::Pr02
    );
    let mut l = library();
    l.nodes.push(fixture_item(&l.nodes, 0).clone());
    assert!(matches!(
        check_library(&l),
        Err(LibraryCheckFailure::Library(LibraryFailure {
            predicate: LibraryPredicate::Lb01,
            ..
        }))
    ));
}
#[test]
fn wrappers_selectors_values_inclusion_and_samples_follow_declarations() {
    let l = library();
    let graph = check_type_signatures(&l).unwrap();
    let encoded = wrap_encode(&graph.profile, "wrapped", "ok".into()).unwrap();
    assert_eq!(
        wrap_decode(&graph.profile, "wrapped", encoded).unwrap(),
        "ok"
    );
    assert_eq!(
        with_member("kind", "sealed", JsonValue::Obj(vec![])).unwrap(),
        JsonValue::Obj(vec![("kind".into(), JsonValue::Str("sealed".into()))])
    );
    let choice = signature_type_ref(&l, &canonical_digest(&l), "choice");
    assert_eq!(
        select_branch(&graph, &choice, &JsonValue::Str("ok".into())).unwrap(),
        1
    );
    assert!(matches!(
        accepts_value(&graph, &choice, &JsonValue::Str("ok".into())),
        ValueDecision::Accepted
    ));
    assert!(matches!(
        accepts_value(&graph, &choice, &JsonValue::Str("bad".into())),
        ValueDecision::Rejected(_)
    ));
    let text = signature_type_ref(&l, &canonical_digest(&l), "text");
    let slot = SlotContract {
        type_ref: text,
        required: true,
        nullable: false,
    };
    assert!(matches!(
        check_assignable(&graph, &slot, &slot, 16),
        CompatibilityDecision::Compatible(_)
    ));
    let samples = slot_samples(&graph, &SearchBounds::default(), &slot);
    assert!(!samples.values.is_empty());
    for value in samples.values {
        assert!(matches!(
            accepts_slot(
                &graph,
                &slot,
                match &value {
                    SlotValue::Absent => SlotValue::Absent,
                    SlotValue::Null => SlotValue::Null,
                    SlotValue::Present(v) => SlotValue::Present(v),
                }
            ),
            ValueDecision::Accepted
        ));
    }
}

fn expect_profile(profile: VersionedSemanticProfile, expected: ProfilePredicate) {
    assert_eq!(check_profile(&profile).unwrap_err().predicate, expected);
}

#[test]
fn every_profile_predicate_matches_the_lean_representative() {
    let valid = profile().semantic_profile();
    let mut p = valid.clone();
    p.reference.identity.clear();
    expect_profile(p, ProfilePredicate::Pr01);
    let mut p = valid.clone();
    p.integer_domains
        .push(fixture_item(&p.integer_domains, 0).clone());
    expect_profile(p, ProfilePredicate::Pr02);
    let mut p = valid.clone();
    fixture_item_mut(&mut p.integer_domains, 0).range = IntegerDomain::Inclusive {
        minimum: 2.into(),
        maximum: 1.into(),
    };
    expect_profile(p, ProfilePredicate::Pr03);
    let mut p = valid.clone();
    fixture_item_mut(&mut p.integer_domains, 0).forms.clear();
    expect_profile(p, ProfilePredicate::Pr04);
    let mut p = valid.clone();
    p.default_integer_domain = "missing".into();
    expect_profile(p, ProfilePredicate::Pr05);
    let mut p = valid.clone();
    p.format_bindings
        .push(fixture_item(&p.format_bindings, 0).clone());
    expect_profile(p, ProfilePredicate::Pr06);
    let mut p = valid.clone();
    fixture_item_mut(&mut p.format_bindings, 0).rule = FormatRule::Identifier {
        first_alphabet: String::new(),
        rest_alphabet: "ab".into(),
        exact_length: None,
        min_length: 1u8.into(),
        max_length: Some(4u8.into()),
        forbidden: vec![],
    };
    expect_profile(p, ProfilePredicate::Pr07);
    let mut p = valid.clone();
    p.wrappers.push(Wrapper {
        name: "second".into(),
        key: "$value".into(),
        payload: WrapperPayload::Text { format: None },
    });
    expect_profile(p, ProfilePredicate::Pr08);
    let mut p = valid.clone();
    fixture_item_mut(&mut p.wrappers, 0).payload = WrapperPayload::Text {
        format: Some("missing".into()),
    };
    expect_profile(p, ProfilePredicate::Pr09);
    let mut p = valid.clone();
    p.bytes_policy = Some(BytesPolicy {
        reference: reference(),
        padding_optional: true,
        alphabet: BytesAlphabet::Either,
        strict_pad_bits: true,
        wrapper: Some("wrapped".into()),
    });
    expect_profile(p, ProfilePredicate::Pr10);
    let mut p = valid.clone();
    p.tag.as_mut().unwrap().key = "$value".into();
    expect_profile(p, ProfilePredicate::Pr11);
    let mut p = valid.clone();
    p.tag.as_mut().unwrap().format = Some("missing".into());
    expect_profile(p, ProfilePredicate::Pr12);
    let mut p = valid.clone();
    let sealed = fixture_item(&p.tag.as_ref().unwrap().sealed, 0).clone();
    p.tag.as_mut().unwrap().sealed.push(sealed);
    expect_profile(p, ProfilePredicate::Pr13);
    let mut p = valid.clone();
    let field = fixture_item(&fixture_item(&p.tag.as_ref().unwrap().sealed, 0).fields, 0).clone();
    fixture_item_mut(&mut p.tag.as_mut().unwrap().sealed, 0)
        .fields
        .push(field);
    expect_profile(p, ProfilePredicate::Pr14);
    let mut p = valid.clone();
    fixture_item_mut(
        &mut fixture_item_mut(&mut p.tag.as_mut().unwrap().sealed, 0).fields,
        0,
    )
    .leaf = SealedLeaf::Integer(IntegerSpec {
        domain: Some("missing".into()),
        minimum: None,
        maximum: None,
        const_value: None,
        enum_values: None,
        default_value: None,
    });
    expect_profile(p, ProfilePredicate::Pr15);
    let mut p = valid;
    p.grapheme_rules = Some(GraphemeRules {
        reference: reference(),
        properties: vec![GraphemeRange {
            first: 2,
            last: 1,
            property: GraphemeProperty::Other,
        }],
        extended_pictographic: vec![],
        indic_conjunct: vec![],
        component: GraphemeComponent {
            unicode_version: "16.0.0".into(),
            uax29_revision: "45".into(),
            cluster_profile: "extended".into(),
        },
        table_sha256: String::new(),
        sources: vec![],
    });
    expect_profile(p, ProfilePredicate::Pr16);
}

fn expect_meaning(
    mut semantic_profile: VersionedSemanticProfile,
    shape: TypeShape,
    expected: MeaningObligation,
) {
    let base = check_type_signatures(&library()).unwrap();
    let reference = fixture_item(&base.nodes, 0).reference.clone();
    if matches!(expected, MeaningObligation::Mo06) {
        fixture_item_mut(&mut semantic_profile.wrappers, 0).payload = WrapperPayload::Bytes;
    }
    let graph = SemanticGraph {
        profile: semantic_profile,
        nodes: vec![TypeNode {
            reference: reference.clone(),
            shape,
            description: None,
            attributes: vec![],
            extensions: vec![],
        }],
        source_refs: vec![],
    };
    assert_eq!(
        check_meaning_defined(&graph, &[reference])
            .unwrap_err()
            .predicate,
        expected
    );
}

#[test]
fn every_meaning_obligation_matches_the_lean_representative() {
    let valid = profile().semantic_profile();
    let string = |format, wrapper, lengths| {
        TypeShape::String(StringSpec {
            format,
            lengths,
            wrapper,
            const_value: None,
            enum_values: None,
            examples: vec![],
            default_value: None,
        })
    };
    expect_meaning(
        valid.clone(),
        string(Some(FormatUse::Named("missing".into())), None, vec![]),
        MeaningObligation::Mo01,
    );
    let mut p = valid.clone();
    p.grapheme_rules = None;
    expect_meaning(
        p,
        string(
            None,
            None,
            vec![LengthBound {
                unit: StringLengthUnit::Graphemes,
                minimum: Some(1u8.into()),
                maximum: None,
            }],
        ),
        MeaningObligation::Mo02,
    );
    expect_meaning(
        valid.clone(),
        TypeShape::Bytes(LengthSpec {
            minimum: None,
            maximum: None,
        }),
        MeaningObligation::Mo03,
    );
    expect_meaning(
        valid.clone(),
        TypeShape::Integer(IntegerSpec {
            domain: Some("missing".into()),
            minimum: None,
            maximum: None,
            const_value: None,
            enum_values: None,
            default_value: None,
        }),
        MeaningObligation::Mo04,
    );
    expect_meaning(
        valid.clone(),
        string(None, Some("missing".into()), vec![]),
        MeaningObligation::Mo05,
    );
    expect_meaning(
        valid.clone(),
        string(None, Some("wrapped".into()), vec![]),
        MeaningObligation::Mo06,
    );
    expect_meaning(
        valid.clone(),
        TypeShape::Sealed {
            tag: "missing".into(),
            refinements: vec![],
        },
        MeaningObligation::Mo07,
    );
    let mut p = valid.clone();
    p.numbers.decimals = false;
    expect_meaning(
        p,
        TypeShape::Decimal(DecimalSpec {
            minimum: None,
            maximum: None,
        }),
        MeaningObligation::Mo08,
    );
    expect_meaning(
        valid.clone(),
        TypeShape::Integer(IntegerSpec {
            domain: Some("integer".into()),
            minimum: Some((-11).into()),
            maximum: None,
            const_value: None,
            enum_values: None,
            default_value: None,
        }),
        MeaningObligation::Mo09,
    );
    expect_meaning(
        valid.clone(),
        TypeShape::Opaque {
            type_name: "external".into(),
        },
        MeaningObligation::Mo10,
    );
    let mut p = valid;
    p.tag = None;
    let base = check_type_signatures(&library()).unwrap();
    expect_meaning(
        p,
        TypeShape::TaggedUnion(UnionSpec {
            branches: vec![UnionBranch {
                target: fixture_item(&base.nodes, 0).reference.clone(),
                wire_tag: "other".into(),
                selector: BranchSelector::InternalTag,
                origin: (&fixture_item(&base.nodes, 0).reference).into(),
            }],
        }),
        MeaningObligation::Mo11,
    );
}
