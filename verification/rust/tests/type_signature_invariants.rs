// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only
#![allow(
    clippy::expect_used,
    clippy::unwrap_used,
    clippy::panic,
    clippy::indexing_slicing
)]
use necoherence::semantic_codegen_runtime::{select_branch, with_member, wrap_decode, wrap_encode};
use necoherence::semantic_composition::*;
use necoherence::semantic_exchange::*;
use necoherence::semantic_types::*;
use necoherence::semantic_validation::*;
use necoherence::signature_admission::*;
use necoherence::type_signatures::*;
use necoherence_composition_solver::composition_search::derive;
use necoherence_composition_solver::wire_admission::verified_signature_derivation;
use necoherence_composition_solver::{closure::*, document::*, enumeration::*, verification::*};
use num_bigint::{BigInt, BigUint};
use std::{fs, process::Command, sync::Arc};

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
fn profile_library_generation_roundtrip() {
    let l = library();
    check_library(&l).unwrap();
    let input = assemble_signature_generation(
        l,
        None,
        vec![SignatureEntrypoint {
            identity: "entry".into(),
            definition: "entry".into(),
        }],
    )
    .unwrap();
    let wire = encode_signature_generation(&input).unwrap();
    let decoded = decode_signature_generation(&wire).unwrap();
    assert_eq!(decoded, input);
    assert_eq!(encode_signature_generation(&decoded).unwrap(), wire);
    let library_wire = encode_type_signatures(&decoded.signatures).unwrap();
    assert_eq!(
        decode_type_signatures(&library_wire).unwrap(),
        *decoded.signatures
    );
    let profile = decoded.signatures.profile.clone();
    let profile_wire = encode_value_profile(&profile).unwrap();
    assert_eq!(decode_value_profile(&profile_wire).unwrap(), profile);
    let graph = check_type_signatures(&decoded.signatures).unwrap();
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
    let diagnostic_wire = encode_diagnostic(&diagnostic).unwrap();
    let diagnostic_json: serde_json::Value = serde_json::from_str(&diagnostic_wire).unwrap();
    assert_eq!(
        diagnostic_json.pointer("/condition"),
        Some(&serde_json::json!({"tag":"WrongValueKind","value":"string"}))
    );
    assert_eq!(
        diagnostic_json.pointer("/value_path"),
        Some(&serde_json::json!([{"tag":"Field","value":"value"}]))
    );
    assert!(matches!(
        decode_signature_generation(
            &wire.replace("ncoh-checked-generation@5", "ncoh-checked-generation@3")
        ),
        Err(GenerationFailure::UnsupportedSchema { .. })
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
    let choice = signature_type_ref("choice");
    assert_eq!(
        select_branch(
            PreparedValidator::new(&graph, FormatWorkspace::empty()).metadata(),
            &choice,
            &JsonValue::Str("ok".into())
        )
        .unwrap(),
        1
    );
    assert!(matches!(
        PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&choice, &JsonValue::Str("ok".into())),
        ValueDecision::Accepted
    ));
    assert!(matches!(
        PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&choice, &JsonValue::Str("bad".into())),
        ValueDecision::Rejected(_)
    ));
    let text = signature_type_ref("text");
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
            PreparedValidator::new(&graph, FormatWorkspace::empty()).accepts_slot(
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
            first: BigUint::from(2u32),
            last: BigUint::from(1u32),
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

fn semantic_graph(nodes: Vec<TypeNodeInput>) -> SemanticGraph {
    let mut declaration = library();
    declaration.nodes = nodes;
    if let Some(tag) = &mut declaration.profile.tag {
        tag.sealed.clear();
    }
    declaration.profile.wrappers.push(Wrapper {
        name: "bytes".into(),
        key: "bytes".into(),
        payload: WrapperPayload::Bytes,
    });
    declaration.profile.bytes_policy = Some(BytesPolicy {
        reference: reference(),
        padding_optional: true,
        alphabet: BytesAlphabet::Either,
        strict_pad_bits: true,
        wrapper: Some("bytes".into()),
    });
    declaration.definitions.clear();
    check_type_signatures(&declaration).unwrap()
}

fn required(graph: &SemanticGraph, name: &str) -> SlotContract {
    SlotContract {
        type_ref: graph
            .nodes
            .iter()
            .find(|node| node.reference.definition_name.as_ref() == name)
            .unwrap()
            .reference
            .clone(),
        required: true,
        nullable: false,
    }
}

fn compatibility(graph: &SemanticGraph, source: &str, destination: &str) -> CompatibilityDecision {
    check_assignable(
        graph,
        &required(graph, source),
        &required(graph, destination),
        32,
    )
}

fn string_shape(maximum: Option<u8>) -> Shape {
    Shape::String(StringSpec {
        format: None,
        lengths: maximum
            .map(|maximum| LengthBound {
                unit: StringLengthUnit::UnicodeScalars,
                minimum: None,
                maximum: Some(maximum.into()),
            })
            .into_iter()
            .collect(),
        wrapper: None,
        const_value: None,
        enum_values: None,
        examples: vec![],
        default_value: None,
    })
}

fn integer_shape(maximum: i64) -> Shape {
    Shape::Integer(IntegerSpec {
        domain: Some("integer".into()),
        minimum: Some((-10).into()),
        maximum: Some(maximum.into()),
        const_value: None,
        enum_values: None,
        default_value: None,
    })
}

fn field_spec(wire_name: &str, type_id: &str, required: bool) -> SignatureField {
    SignatureField {
        wire_name: wire_name.into(),
        slot: SignatureSlot {
            type_id: type_id.into(),
            required,
            nullable: false,
        },
    }
}

#[test]
fn lean_c1_c5_and_i1_i7_inclusion_representatives() {
    let mut formats = semantic_graph(vec![
        TypeNodeInput {
            id: "text".into(),
            shape: Shape::String(StringSpec {
                format: Some(FormatUse::Inline(FormatRule::Text)),
                lengths: vec![],
                wrapper: None,
                const_value: None,
                enum_values: None,
                examples: vec![],
                default_value: None,
            }),
        },
        TypeNodeInput {
            id: "not-a".into(),
            shape: Shape::String(StringSpec {
                format: Some(FormatUse::Named("name".into())),
                lengths: vec![],
                wrapper: None,
                const_value: None,
                enum_values: None,
                examples: vec![],
                default_value: None,
            }),
        },
    ]);
    fixture_item_mut(&mut formats.profile.format_bindings, 0).rule =
        FormatRule::Not(Box::new(FormatRule::Literal("a".into())));
    assert!(matches!(
        compatibility(&formats, "not-a", "not-a"),
        CompatibilityDecision::Compatible(_)
    ));
    let decision = compatibility(&formats, "text", "not-a");
    let certificate = match decision {
        CompatibilityDecision::Incompatible(certificate) => Some(certificate),
        _ => None,
    }
    .expect("text has a counterexample outside the not-a format");
    assert_eq!(
        certificate.value,
        SlotValue::Present(JsonValue::Str("a".into()))
    );

    let products = semantic_graph(vec![
        TypeNodeInput {
            id: "any".into(),
            shape: Shape::Unknown(UnknownKind::Any),
        },
        TypeNodeInput {
            id: "extras-x".into(),
            shape: Shape::Product(SignatureProduct {
                fields: vec![],
                extras: SignatureExtraMembers::Allow {
                    key_format: Some(FormatUse::Inline(FormatRule::Literal("x".into()))),
                    value: SignatureElementContract {
                        type_id: "any".into(),
                        nullable: false,
                    },
                },
            }),
        },
        TypeNodeInput {
            id: "extras-text".into(),
            shape: Shape::Product(SignatureProduct {
                fields: vec![],
                extras: SignatureExtraMembers::Allow {
                    key_format: Some(FormatUse::Inline(FormatRule::Text)),
                    value: SignatureElementContract {
                        type_id: "any".into(),
                        nullable: false,
                    },
                },
            }),
        },
        TypeNodeInput {
            id: "reject".into(),
            shape: Shape::Product(SignatureProduct {
                fields: vec![],
                extras: SignatureExtraMembers::Reject,
            }),
        },
    ]);
    assert!(matches!(
        compatibility(&products, "extras-x", "extras-text"),
        CompatibilityDecision::Compatible(_)
    ));
    assert!(matches!(
        compatibility(&products, "extras-x", "reject"),
        CompatibilityDecision::Incompatible(_)
    ));

    let unions = semantic_graph(vec![
        TypeNodeInput {
            id: "null".into(),
            shape: Shape::Unit,
        },
        TypeNodeInput {
            id: "boolean".into(),
            shape: Shape::Boolean(BooleanSpec {
                const_value: None,
                default_value: None,
            }),
        },
        TypeNodeInput {
            id: "one".into(),
            shape: Shape::TaggedUnion(SignatureUnion {
                branches: vec![SignatureUnionBranch {
                    target: "null".into(),
                    wire_tag: "null".into(),
                    selector: BranchSelector::Kind(ValueKind::Null),
                }],
            }),
        },
        TypeNodeInput {
            id: "two".into(),
            shape: Shape::TaggedUnion(SignatureUnion {
                branches: vec![
                    SignatureUnionBranch {
                        target: "null".into(),
                        wire_tag: "null".into(),
                        selector: BranchSelector::Kind(ValueKind::Null),
                    },
                    SignatureUnionBranch {
                        target: "boolean".into(),
                        wire_tag: "boolean".into(),
                        selector: BranchSelector::Kind(ValueKind::Boolean),
                    },
                ],
            }),
        },
    ]);
    assert!(matches!(
        compatibility(&unions, "one", "two"),
        CompatibilityDecision::Compatible(_)
    ));
    assert!(matches!(
        compatibility(&unions, "two", "one"),
        CompatibilityDecision::Incompatible(_)
    ));

    let leaves = semantic_graph(vec![
        TypeNodeInput {
            id: "int-nine".into(),
            shape: integer_shape(9),
        },
        TypeNodeInput {
            id: "int-ten".into(),
            shape: integer_shape(10),
        },
        TypeNodeInput {
            id: "one-char".into(),
            shape: string_shape(Some(1)),
        },
        TypeNodeInput {
            id: "two-char".into(),
            shape: string_shape(Some(2)),
        },
        TypeNodeInput {
            id: "bytes".into(),
            shape: Shape::Bytes(LengthSpec {
                minimum: None,
                maximum: None,
            }),
        },
        TypeNodeInput {
            id: "ordinary".into(),
            shape: Shape::Unknown(UnknownKind::OrdinaryObject),
        },
    ]);
    assert!(matches!(
        compatibility(&leaves, "int-nine", "int-ten"),
        CompatibilityDecision::Unknown(_)
    ));
    assert!(matches!(
        compatibility(&leaves, "one-char", "two-char"),
        CompatibilityDecision::Compatible(_)
    ));
    for (source, destination) in [
        ("int-ten", "int-nine"),
        ("two-char", "one-char"),
        ("bytes", "ordinary"),
    ] {
        let decision = compatibility(&leaves, source, destination);
        assert!(
            matches!(decision, CompatibilityDecision::Incompatible(_)),
            "{source} -> {destination}: {decision:?}"
        );
    }

    let optional = semantic_graph(vec![
        TypeNodeInput {
            id: "tag".into(),
            shape: Shape::String(StringSpec {
                format: None,
                lengths: vec![],
                wrapper: None,
                const_value: Some("sealed".into()),
                enum_values: None,
                examples: vec![],
                default_value: None,
            }),
        },
        TypeNodeInput {
            id: "empty".into(),
            shape: Shape::Product(SignatureProduct {
                fields: vec![],
                extras: SignatureExtraMembers::Reject,
            }),
        },
        TypeNodeInput {
            id: "optional".into(),
            shape: Shape::Product(SignatureProduct {
                fields: vec![field_spec("kind", "tag", false)],
                extras: SignatureExtraMembers::Reject,
            }),
        },
    ]);
    assert!(matches!(
        compatibility(&optional, "empty", "optional"),
        CompatibilityDecision::Incompatible(_)
    ));
}

#[test]
fn lean_sample_representatives_are_sound_and_report_bounds() {
    let graph = check_type_signatures(&library()).unwrap();
    for name in ["text", "sealed", "choice"] {
        let contract = required(&graph, name);
        let samples = slot_samples(&graph, &SearchBounds::default(), &contract);
        assert!(!samples.values.is_empty());
        for sample in samples.values {
            assert!(matches!(
                PreparedValidator::new(&graph, FormatWorkspace::empty()).accepts_slot(
                    &contract,
                    match &sample {
                        SlotValue::Absent => SlotValue::Absent,
                        SlotValue::Null => SlotValue::Null,
                        SlotValue::Present(value) => SlotValue::Present(value),
                    }
                ),
                ValueDecision::Accepted
            ));
        }
    }
    let bounds = SearchBounds {
        max_sample_length: BigUint::from(1u32),
        ..SearchBounds::default()
    };
    let samples = slot_samples(&graph, &bounds, &required(&graph, "text"));
    assert!(
        samples
            .obligations
            .contains(&necoherence::semantic_composition::SampleObligation::SampleBound)
            || samples.values.iter().all(|sample| match sample {
                SlotValue::Present(JsonValue::Str(value)) => value.len() <= 1,
                _ => true,
            })
    );
}

fn expect_library_predicate(declaration: TypeSignatureLibrary, expected: LibraryPredicate) {
    let actual = check_library(&declaration);
    assert!(
        matches!(
            &actual,
            Err(LibraryCheckFailure::Library(LibraryFailure { predicate, .. }))
                if *predicate == expected
        ),
        "expected {expected:?}, actual {actual:?}"
    );
}

fn product_node(
    id: &str,
    fields: Vec<SignatureField>,
    extras: SignatureExtraMembers,
) -> TypeNodeInput {
    TypeNodeInput {
        id: id.into(),
        shape: Shape::Product(SignatureProduct { fields, extras }),
    }
}

#[test]
fn lean_lb02_lb19_library_predicate_representatives() {
    let mut declaration = library();
    declaration.nodes.push(product_node(
        "product",
        vec![field_spec("x", "text", true), field_spec("x", "text", true)],
        SignatureExtraMembers::Reject,
    ));
    expect_library_predicate(declaration, LibraryPredicate::Lb02);

    let mut declaration = library();
    declaration.nodes.push(product_node(
        "product",
        vec![field_spec("$value", "text", true)],
        SignatureExtraMembers::Reject,
    ));
    expect_library_predicate(declaration, LibraryPredicate::Lb03);

    let mut declaration = library();
    if let Shape::TaggedUnion(union) = &mut fixture_item_mut(&mut declaration.nodes, 3).shape {
        fixture_item_mut(&mut union.branches, 1).wire_tag = "sealed".into();
    }
    expect_library_predicate(declaration, LibraryPredicate::Lb04);

    let mut declaration = library();
    if let Shape::TaggedUnion(union) = &mut fixture_item_mut(&mut declaration.nodes, 3).shape {
        union.branches.insert(
            0,
            SignatureUnionBranch {
                target: "text".into(),
                wire_tag: "fallback".into(),
                selector: BranchSelector::Otherwise,
            },
        );
    }
    expect_library_predicate(declaration, LibraryPredicate::Lb05);

    let mut declaration = library();
    if let Shape::TaggedUnion(union) = &mut fixture_item_mut(&mut declaration.nodes, 3).shape {
        fixture_item_mut(&mut union.branches, 1).wire_tag.clear();
    }
    expect_library_predicate(declaration, LibraryPredicate::Lb06);

    let mut declaration = library();
    declaration.profile.format_bindings.push(FormatBinding {
        name: "tag".into(),
        reference: reference(),
        rule: FormatRule::Literal("sealed".into()),
    });
    declaration.profile.tag.as_mut().unwrap().format = Some("tag".into());
    if let Shape::TaggedUnion(union) = &mut fixture_item_mut(&mut declaration.nodes, 3).shape {
        fixture_item_mut(&mut union.branches, 0).wire_tag = "outside".into();
    }
    expect_library_predicate(declaration, LibraryPredicate::Lb07);

    let mut declaration = library();
    if let Shape::TaggedUnion(union) = &mut fixture_item_mut(&mut declaration.nodes, 3).shape {
        fixture_item_mut(&mut union.branches, 0).target = "text".into();
    }
    expect_library_predicate(declaration, LibraryPredicate::Lb08);

    let mut declaration = library();
    if let Shape::TaggedUnion(union) = &mut fixture_item_mut(&mut declaration.nodes, 3).shape {
        fixture_item_mut(&mut union.branches, 1).selector =
            BranchSelector::MemberShape(vec![("x".into(), MemberTest::Format("missing".into()))]);
    }
    expect_library_predicate(declaration, LibraryPredicate::Lb09);

    let mut declaration = library();
    fixture_item_mut(&mut declaration.nodes, 2).shape = Shape::Sealed {
        tag: "sealed".into(),
        refinements: vec![SealedRefinement {
            key: "missing".into(),
            leaf: SealedLeaf::String(match string_shape(None) {
                Shape::String(spec) => spec,
                _ => StringSpec {
                    format: None,
                    lengths: vec![],
                    wrapper: None,
                    const_value: None,
                    enum_values: None,
                    examples: vec![],
                    default_value: None,
                },
            }),
        }],
    };
    expect_library_predicate(declaration, LibraryPredicate::Lb10);

    let mut declaration = library();
    if let Shape::TaggedUnion(union) = &mut fixture_item_mut(&mut declaration.nodes, 3).shape {
        let branch = fixture_item_mut(&mut union.branches, 0);
        branch.wire_tag = "other".into();
        branch.target = "text".into();
    }
    expect_library_predicate(declaration, LibraryPredicate::Lb11);

    let mut declaration = library();
    declaration.nodes.push(product_node(
        "product",
        vec![],
        SignatureExtraMembers::Allow {
            key_format: Some(FormatUse::Named("missing".into())),
            value: SignatureElementContract {
                type_id: "text".into(),
                nullable: false,
            },
        },
    ));
    expect_library_predicate(declaration, LibraryPredicate::Lb12);

    let mut declaration = library();
    declaration.nodes.push(TypeNodeInput {
        id: "bad-string".into(),
        shape: Shape::String(StringSpec {
            format: None,
            lengths: vec![],
            wrapper: Some("missing".into()),
            const_value: None,
            enum_values: None,
            examples: vec![],
            default_value: None,
        }),
    });
    expect_library_predicate(declaration, LibraryPredicate::Lb13);

    let mut declaration = library();
    declaration.nodes.push(TypeNodeInput {
        id: "bad-integer".into(),
        shape: Shape::Integer(IntegerSpec {
            domain: Some("integer".into()),
            minimum: Some(2.into()),
            maximum: Some(1.into()),
            const_value: None,
            enum_values: None,
            default_value: None,
        }),
    });
    expect_library_predicate(declaration, LibraryPredicate::Lb14);

    let mut declaration = library();
    declaration.nodes.push(TypeNodeInput {
        id: "bad-decimal".into(),
        shape: Shape::Decimal(DecimalSpec {
            minimum: Some(DecimalBound {
                mantissa: 2.into(),
                scale: 0u8.into(),
                exclusive: false,
            }),
            maximum: Some(DecimalBound {
                mantissa: 1.into(),
                scale: 0u8.into(),
                exclusive: false,
            }),
        }),
    });
    expect_library_predicate(declaration, LibraryPredicate::Lb15);

    let mut declaration = library();
    declaration.nodes.push(TypeNodeInput {
        id: "bad-array".into(),
        shape: Shape::Array(SignatureArray {
            item: SignatureElementContract {
                type_id: "text".into(),
                nullable: false,
            },
            minimum: Some(2u8.into()),
            maximum: Some(1u8.into()),
        }),
    });
    expect_library_predicate(declaration, LibraryPredicate::Lb16);

    let mut declaration = library();
    declaration.nodes.push(TypeNodeInput {
        id: "different".into(),
        shape: Shape::String(StringSpec {
            format: None,
            lengths: vec![],
            wrapper: None,
            const_value: Some("different".into()),
            enum_values: None,
            examples: vec![],
            default_value: None,
        }),
    });
    declaration.nodes.push(product_node(
        "tagged-product",
        vec![field_spec("kind", "different", true)],
        SignatureExtraMembers::Reject,
    ));
    if let Shape::TaggedUnion(union) = &mut fixture_item_mut(&mut declaration.nodes, 3).shape {
        let branch = fixture_item_mut(&mut union.branches, 0);
        branch.wire_tag = "other".into();
        branch.target = "tagged-product".into();
    }
    expect_library_predicate(declaration, LibraryPredicate::Lb17);

    let mut declaration = library();
    if let Shape::TaggedUnion(union) = &mut fixture_item_mut(&mut declaration.nodes, 3).shape {
        union.branches = vec![
            SignatureUnionBranch {
                target: "text".into(),
                wire_tag: "first".into(),
                selector: BranchSelector::Kind(ValueKind::String),
            },
            SignatureUnionBranch {
                target: "text".into(),
                wire_tag: "second".into(),
                selector: BranchSelector::Kind(ValueKind::String),
            },
        ];
    }
    expect_library_predicate(declaration, LibraryPredicate::Lb18);

    let mut declaration = library();
    declaration.nodes.push(TypeNodeInput {
        id: "bad-const".into(),
        shape: Shape::String(StringSpec {
            format: Some(FormatUse::Named("name".into())),
            lengths: vec![],
            wrapper: None,
            const_value: Some("bad".into()),
            enum_values: None,
            examples: vec![],
            default_value: None,
        }),
    });
    expect_library_predicate(declaration, LibraryPredicate::Lb19);
}

type CheckedCompositionFixture = (
    Arc<TypeSignatureLibrary>,
    CompositionInput,
    RawComposition,
    Vec<(FunctionRef, Vec<(OutcomeId, OutcomeCause)>)>,
);

fn checked_composition(unique: bool) -> CheckedCompositionFixture {
    let mut declared = library();
    declared.sources.push(SourceIdentity {
        repository: "synthetic".into(),
        revision: "1".into(),
        path: "transform".into(),
        content_digest: "d".repeat(64),
    });
    let declaration = Arc::new(declared);
    let graph = check_type_signatures(&declaration).unwrap();
    let contract = |id: &str| SlotContract {
        type_ref: signature_type_ref(id),
        required: true,
        nullable: false,
    };
    let function = FunctionRef {
        identity: "text-to-sealed".into(),
        revision: "1".into(),
        content_digest: "c".repeat(64),
    };
    let problem = CompositionInput {
        identity: "provider-composition".into(),
        revision: "1".into(),
        basis: SemanticBasis::of(&graph),
        signatures: vec![FunctionSignature {
            reference: function.clone(),
            form: FunctionForm::DeclaredTransform,
            effect: CompositionEffect::PureFunction,
            inputs: vec![InputPort {
                id: PortId("input".into()),
                contract: contract("text"),
                source_constraint: SourceConstraint::InitialOnly {
                    input: InputId("argument".into()),
                    path: vec![],
                },
                resource_requirement: None,
            }],
            outcomes: vec![OutcomeContract {
                id: OutcomeId("success".into()),
                form: necoherence::semantic_composition::OutcomeForm::Success,
                value_ports: vec![OutputPort {
                    id: PortId("output".into()),
                    contract: contract("sealed"),
                    resource_production: None,
                }],
                produced_resources: vec![],
            }],
            resource_inputs: vec![],
            assumption_ref: "declared transform".into(),
            handles_failure: None,
        }],
        initial_inputs: vec![InitialInput {
            id: InputId("argument".into()),
            contract: contract("text"),
            source: InitialSource::Argument,
            resource: None,
        }],
        initial_resources: vec![],
        goal: GoalSpec {
            outputs: vec![GoalPort {
                id: GoalPortId("result".into()),
                contract: contract("sealed"),
                source_constraint: SourceConstraint::AnyCompatible,
            }],
            failures: vec![],
            final_resources: vec![],
        },
        invocation_domain: InvocationDomain {
            identity: "finite".into(),
            revision: "1".into(),
            sites: vec![InvocationSite {
                id: SiteId("provider".into()),
                function: function.clone(),
            }],
            permitted_projections: vec![],
            permitted_constructions: vec![],
            permitted_transforms: vec![function],
            guards: vec![],
        },
        allowed_effects: vec![CompositionEffect::PureFunction],
        explicit_order: vec![],
        selection_policy: Some(if unique {
            SelectionPolicy::RequireUnique
        } else {
            SelectionPolicy::AnyFeasible
        }),
        bounds: SearchBounds {
            max_sample_length: BigUint::from(59u32),
            ..SearchBounds::default()
        },
    };
    let prepared = prepare_direct_composition(
        &graph,
        problem.clone(),
        operation_checker_without_library(),
        operation_meaning_of(&graph),
    )
    .unwrap();
    let decision = derive(&prepared).unwrap();
    let checked = match decision {
        CompositionDecision::Solved(checked, _) => Some(checked),
        _ => None,
    }
    .expect("the representative composition is solved");
    let causes = vec![(
        fixture_item(&problem.signatures, 0).reference.clone(),
        vec![(
            OutcomeId("success".into()),
            OutcomeCause::ValueContract {
                origin: Origin {
                    source: SourceIdentity {
                        repository: "synthetic".into(),
                        revision: "1".into(),
                        path: "transform".into(),
                        content_digest: "d".repeat(64),
                    },
                    locator: vec!["success".into()],
                },
            },
        )],
    )];
    (declaration, problem, checked.raw().clone(), causes)
}

#[test]
fn checked_composition_derivation_roundtrips_through_v5_wire() {
    let (library, problem, derivation, causes) = checked_composition(false);
    let composition =
        signature_composition_from_native(&library, &problem, &derivation, &causes).unwrap();
    assert_eq!(
        decode_signature_problem(&library, &composition["problem"]).unwrap(),
        problem
    );
    assert_eq!(
        composition["problem"].pointer("/bounds/max_sample_length"),
        Some(&serde_json::json!("59"))
    );
    assert!(serde_json::to_string(&composition["derivation"])
        .unwrap()
        .contains("\"max_sample_length\":\"59\""));
    let input =
        assemble_signature_generation((*library).clone(), Some(composition), vec![]).unwrap();
    let wire = encode_signature_generation(&input).unwrap();
    let decoded = decode_signature_generation(&wire).unwrap();
    assert_eq!(decoded, input);
    let context = signature_generation_context(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input),
        &wire,
    )
    .unwrap();
    assert_eq!(context.input(), &input);
}

#[test]
fn forged_composition_basis_is_rejected() {
    let (library, problem, derivation, causes) = checked_composition(false);
    let mut composition =
        signature_composition_from_native(&library, &problem, &derivation, &causes).unwrap();
    *composition["problem"]
        .pointer_mut("/basis/graph_sha256")
        .unwrap() = serde_json::json!("f".repeat(64));
    let input =
        assemble_signature_generation((*library).clone(), Some(composition), vec![]).unwrap();
    let basis = necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input);
    assert!(admit_signature_generation(&basis, input).is_err());
}

#[test]
fn unique_composition_preserves_closure_evidence() {
    let (library, problem, derivation, causes) = checked_composition(true);
    assert!(matches!(
        derivation.selection.as_ref(),
        SelectionEvidence::Unique { .. }
    ));
    let composition =
        signature_composition_from_native(&library, &problem, &derivation, &causes).unwrap();
    let input =
        assemble_signature_generation((*library).clone(), Some(composition), vec![]).unwrap();
    let wire = encode_signature_generation(&input).unwrap();
    assert_eq!(decode_signature_generation(&wire).unwrap(), input);
}

#[test]
fn unique_composition_ignores_wire_canonical_plan() {
    let (library, problem, derivation, causes) = checked_composition(true);
    let composition =
        signature_composition_from_native(&library, &problem, &derivation, &causes).unwrap();
    let input =
        assemble_signature_generation((*library).clone(), Some(composition), vec![]).unwrap();
    let mut wire: serde_json::Value =
        serde_json::from_str(&encode_signature_generation(&input).unwrap()).unwrap();
    *wire
        .pointer_mut("/composition/derivation/selection/fields/canonical_plan")
        .unwrap() = serde_json::json!("forged");
    let wire = serde_json::to_string(&wire).unwrap();
    let mut decoded = decode_signature_generation(&wire).unwrap();
    decoded.basis = signature_basis(
        &decoded.signatures,
        decoded.composition.as_ref(),
        &decoded.entrypoints,
    )
    .unwrap();
    let wire = encode_signature_generation(&decoded).unwrap();
    let context = signature_generation_context(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&decoded),
        &wire,
    )
    .unwrap();
    assert_eq!(context.input(), &decoded);
}

#[test]
fn unique_closure_with_unknown_invocation_site_is_rejected_by_diagnostics() {
    let (library, problem, derivation, causes) = checked_composition(true);
    let composition =
        signature_composition_from_native(&library, &problem, &derivation, &causes).unwrap();
    let input =
        assemble_signature_generation((*library).clone(), Some(composition), vec![]).unwrap();
    let mut wire: serde_json::Value =
        serde_json::from_str(&encode_signature_generation(&input).unwrap()).unwrap();
    *wire
        .pointer_mut("/composition/derivation/selection/fields/closure/states/0/choices/0/choice/fields/invocation/site")
        .unwrap() = serde_json::json!("absent-site");
    let wire = serde_json::to_string(&wire).unwrap();
    let mut decoded = decode_signature_generation(&wire).unwrap();
    decoded.basis = signature_basis(
        &decoded.signatures,
        decoded.composition.as_ref(),
        &decoded.entrypoints,
    )
    .unwrap();
    let checked = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&decoded),
        decoded,
    )
    .unwrap();
    let failure = match verified_signature_derivation(checked.input(), checked.graph()) {
        Err(SignatureCompositionAdmissionFailure::Wire(failure)) => Some(failure),
        _ => None,
    };
    assert_eq!(
        failure,
        Some(GenerationFailure::Syntax {
            path: "$".into(),
            message: "diagnostic variant mismatch".into(),
        })
    );
}

fn closure_failure_after_pointer_edit(
    pointer: &str,
    value: serde_json::Value,
) -> Option<GenerationFailure> {
    let (library, problem, derivation, causes) = checked_composition(true);
    let composition =
        signature_composition_from_native(&library, &problem, &derivation, &causes).unwrap();
    let input =
        assemble_signature_generation((*library).clone(), Some(composition), vec![]).unwrap();
    let mut wire: serde_json::Value =
        serde_json::from_str(&encode_signature_generation(&input).unwrap()).unwrap();
    *wire.pointer_mut(pointer).unwrap() = value;
    let mut decoded = decode_signature_generation(&serde_json::to_string(&wire).unwrap()).unwrap();
    decoded.basis = signature_basis(
        &decoded.signatures,
        decoded.composition.as_ref(),
        &decoded.entrypoints,
    )
    .unwrap();
    let checked = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&decoded),
        decoded,
    )
    .unwrap();
    match verified_signature_derivation(checked.input(), checked.graph()) {
        Err(SignatureCompositionAdmissionFailure::Wire(failure)) => Some(failure),
        _ => None,
    }
}

#[test]
fn closure_root_beyond_the_states_is_an_index_failure() {
    assert_eq!(
        closure_failure_after_pointer_edit(
            "/composition/derivation/selection/fields/closure/root",
            serde_json::json!("999"),
        ),
        Some(GenerationFailure::Syntax {
            path: "$".into(),
            message: "closure root index".into(),
        })
    );
}

#[test]
fn closure_successor_beyond_the_states_is_an_index_failure() {
    assert_eq!(
        closure_failure_after_pointer_edit(
            "/composition/derivation/selection/fields/closure/states/0/choices/0/children/0",
            serde_json::json!("999"),
        ),
        Some(GenerationFailure::Syntax {
            path: "$".into(),
            message: "closure successor index".into(),
        })
    );
}

#[test]
fn canonical_plan_key_sorts_only_whole_linear_pure_plans() {
    let (library, mut problem, derivation, _) = checked_composition(true);
    let PlanNode::Invoke {
        invocation,
        arms,
        empty_outcomes,
    } = &derivation.plan.root.node
    else {
        panic!("invocation root required")
    };
    assert!(empty_outcomes.is_empty());
    let (outcome, terminal) = fixture_item(arms, 0).clone();
    let first = invocation.clone();
    let mut second = invocation.clone();
    second.site = SiteId("provider-2".into());
    problem.invocation_domain.sites.push(InvocationSite {
        id: second.site.clone(),
        function: second.function.clone(),
    });
    let graph = check_type_signatures(&library).unwrap();
    let prepared = prepare_direct_composition(
        &graph,
        problem,
        operation_checker_without_library(),
        operation_meaning_of(&graph),
    )
    .unwrap();
    let invoke = |invocation: InvocationPlan, child: PlanTree| PlanTree {
        rank: BigUint::from(0u8),
        node: PlanNode::Invoke {
            invocation,
            arms: vec![(outcome.clone(), child)],
            empty_outcomes: vec![],
        },
    };
    let first_second = invoke(first.clone(), invoke(second.clone(), terminal.clone()));
    let second_first = invoke(second.clone(), invoke(first.clone(), terminal.clone()));
    assert_eq!(
        canonical_plan_key(&prepared, &first_second),
        canonical_plan_key(&prepared, &second_first)
    );
    let guarded = |child: PlanTree| PlanTree {
        rank: BigUint::from(0u8),
        node: PlanNode::Guard {
            guard: GuardId("guard".into()),
            inspected: ValueRef {
                producer: ProducerRef::Initial(InputId("argument".into())),
                path: vec![],
            },
            arms: vec![(GuardArm::Present, child)],
        },
    };
    let first_second_guard = invoke(
        first.clone(),
        invoke(second.clone(), guarded(terminal.clone())),
    );
    let second_first_guard = invoke(second, invoke(first, guarded(terminal)));
    assert_ne!(
        canonical_plan_key(&prepared, &first_second_guard),
        canonical_plan_key(&prepared, &second_first_guard)
    );
}

#[test]
fn composition_sample_bound_is_mandatory_and_canonical() {
    let (library, problem, derivation, causes) = checked_composition(false);
    let composition =
        signature_composition_from_native(&library, &problem, &derivation, &causes).unwrap();
    for invalid in [
        serde_json::json!(59),
        serde_json::json!("-1"),
        serde_json::json!("059"),
    ] {
        let mut wire = composition["problem"].clone();
        *wire.pointer_mut("/bounds/max_sample_length").unwrap() = invalid;
        assert!(decode_signature_problem(&library, &wire).is_err());
    }
    let mut wire = composition["problem"].clone();
    wire.get_mut("bounds")
        .unwrap()
        .as_object_mut()
        .unwrap()
        .remove("max_sample_length");
    assert!(decode_signature_problem(&library, &wire).is_err());
}

#[test]
fn finite_composition_samples_use_the_public_caller_bound() {
    for length in [7usize, 17, 59] {
        let text = "x".repeat(length);
        let mut declaration = library();
        declaration.nodes = vec![TypeNodeInput {
            id: "finite".into(),
            shape: Shape::String(StringSpec {
                format: None,
                lengths: vec![],
                wrapper: None,
                const_value: Some(text.clone()),
                enum_values: None,
                examples: vec![],
                default_value: None,
            }),
        }];
        declaration.definitions.clear();
        let graph = check_type_signatures(&declaration).unwrap();
        let contract = required(&graph, "finite");
        let (_, mut problem, _, _) = checked_composition(false);
        problem.basis = SemanticBasis::of(&graph);
        problem.signatures.clear();
        problem.invocation_domain.sites.clear();
        problem.invocation_domain.permitted_transforms.clear();
        problem.initial_inputs = vec![InitialInput {
            id: InputId("finite".into()),
            contract: contract.clone(),
            source: InitialSource::Argument,
            resource: None,
        }];
        problem.goal.outputs = vec![GoalPort {
            id: GoalPortId("finite".into()),
            contract: contract.clone(),
            source_constraint: SourceConstraint::AnyCompatible,
        }];
        problem.bounds.max_sample_length = BigUint::from(length);
        let prepared = prepare_direct_composition(
            &graph,
            problem.clone(),
            operation_checker_without_library(),
            operation_meaning_of(&graph),
        )
        .unwrap();
        let checked = match derive(&prepared).unwrap() {
            CompositionDecision::Solved(checked, _) => Some(checked),
            _ => None,
        }
        .expect("finite witness at its length");
        for maximum in [length - 1, length] {
            problem.bounds.max_sample_length = BigUint::from(maximum);
            let wire =
                signature_composition_from_native(&declaration, &problem, checked.raw(), &[])
                    .unwrap();
            let native = decode_signature_problem(&declaration, &wire["problem"]).unwrap();
            let sampled = slot_samples(&graph, &native.bounds, &contract);
            let prepared = prepare_direct_composition(
                &graph,
                native,
                operation_checker_without_library(),
                operation_meaning_of(&graph),
            )
            .unwrap();
            if maximum == length {
                assert!(sampled
                    .values
                    .contains(&SlotValue::Present(JsonValue::Str(text.clone()))));
                let CompositionDecision::Solved(checked, _) = derive(&prepared).unwrap() else {
                    panic!("the sampled initial inhabitation witness must derive");
                };
                verify_composition(&prepared, checked.raw()).unwrap();
            } else {
                assert!(sampled.values.is_empty());
                assert!(sampled.obligations.contains(&SampleObligation::SampleBound));
                let CompositionDecision::Incomplete { evaluation, .. } = derive(&prepared).unwrap()
                else {
                    panic!("an argument without a sampled value stays incomplete");
                };
                let obligations = match evaluation {
                    RefinementOutcome::Resolved(value)
                    | RefinementOutcome::Residual { value, .. }
                    | RefinementOutcome::Stopped { value, .. } => value.value,
                };
                assert!(matches!(
                    obligations.as_slice(),
                    [UnresolvedObligation::Inhabitation { .. }]
                ));
            }
        }
    }
}

#[test]
fn canonical_cid_samples_obey_32_58_59_bounds() {
    let mut declaration = library();
    declaration.profile = decode_value_profile(include_str!(
        "../../../verification/presets/atproto-data-model/profile.json"
    ))
    .unwrap();
    declaration.nodes = vec![TypeNodeInput {
        id: "cid".into(),
        shape: Shape::String(StringSpec {
            format: Some(FormatUse::Named("cid".into())),
            lengths: vec![],
            wrapper: None,
            const_value: None,
            enum_values: None,
            examples: vec![],
            default_value: None,
        }),
    }];
    declaration.definitions.clear();
    let graph = check_type_signatures(&declaration).unwrap();
    let contract = required(&graph, "cid");
    for maximum in [32u32, 58, 59] {
        let bounds = SearchBounds {
            max_sample_length: BigUint::from(maximum),
            ..SearchBounds::default()
        };
        let sampled = slot_samples(&graph, &bounds, &contract);
        if maximum < 59 {
            assert!(sampled.values.is_empty());
            assert!(sampled.obligations.contains(&SampleObligation::SampleBound));
        } else {
            assert!(!sampled.values.is_empty());
            for value in &sampled.values {
                assert!(
                    matches!(value, SlotValue::Present(JsonValue::Str(text)) if text.len() == 59)
                );
                assert!(matches!(
                    PreparedValidator::new(&graph, FormatWorkspace::empty())
                        .accepts_slot(&contract, borrowed_slot(value)),
                    ValueDecision::Accepted
                ));
            }
        }
    }
}

fn generated_carrier_library() -> TypeSignatureLibrary {
    let mut declaration = library();
    if let Shape::String(spec) = &mut declaration
        .nodes
        .iter_mut()
        .find(|node| node.id == "text")
        .unwrap()
        .shape
    {
        spec.default_value = Some("ok".into());
    }
    declaration.nodes.extend([
        TypeNodeInput {
            id: "wrapped_text".into(),
            shape: Shape::String(StringSpec {
                format: None,
                lengths: vec![],
                wrapper: Some("wrapped".into()),
                const_value: None,
                enum_values: None,
                examples: vec!["ok".into()],
                default_value: None,
            }),
        },
        TypeNodeInput {
            id: "decimal".into(),
            shape: Shape::Decimal(DecimalSpec {
                minimum: None,
                maximum: None,
            }),
        },
        TypeNodeInput {
            id: "product".into(),
            shape: Shape::Product(SignatureProduct {
                fields: vec![field_spec("value", "text", true)],
                extras: SignatureExtraMembers::Reject,
            }),
        },
        TypeNodeInput {
            id: "ordered_product".into(),
            shape: Shape::Product(SignatureProduct {
                fields: vec![
                    field_spec("first", "text", true),
                    field_spec("second", "text", true),
                ],
                extras: SignatureExtraMembers::Allow {
                    key_format: None,
                    value: SignatureElementContract {
                        type_id: "text".into(),
                        nullable: false,
                    },
                },
            }),
        },
    ]);
    let source = SourceIdentity {
        repository: "synthetic".into(),
        revision: "1".into(),
        path: "operation".into(),
        content_digest: "b".repeat(64),
    };
    let origin = Origin {
        source: source.clone(),
        locator: vec!["outcome".into()],
    };
    declaration.sources.push(source);
    declaration.annotations.push(Annotation {
        target: AnnotationTarget::Library,
        key: "exact".into(),
        value: JsonValue::Dec("9007199254740993".into()),
    });
    declaration.definitions.push(DefinitionInput {
        id: "operation".into(),
        wire_identity: "effect".into(),
        shape: SignatureDefinitionShape::Operation(OperationContract {
            effect: EffectPoint::HttpRequestResponse,
            inputs: vec![],
            outcomes: vec![
                SignatureOutcome {
                    id: "ok".into(),
                    form: necoherence::type_signatures::OutcomeForm::Success,
                    cause: OutcomeCause::ValueContract {
                        origin: origin.clone(),
                    },
                    value_ports: vec![],
                    produced_resources: vec![],
                },
                SignatureOutcome {
                    id: "external".into(),
                    form: necoherence::type_signatures::OutcomeForm::DeclaredFailure,
                    cause: OutcomeCause::ExternalCondition {
                        specification: origin,
                    },
                    value_ports: vec![SignaturePort {
                        id: "reason".into(),
                        contract: SignatureSlot {
                            type_id: "text".into(),
                            required: true,
                            nullable: false,
                        },
                    }],
                    produced_resources: vec![],
                },
            ],
        }),
    });
    declaration
}

fn pr01_library_failure(failure: &LibraryCheckFailure) -> bool {
    matches!(
        failure,
        LibraryCheckFailure::Profile(ProfileFailure {
            predicate: ProfilePredicate::Pr01,
            ..
        })
    )
}

fn operation_entrypoints() -> Vec<SignatureEntrypoint> {
    vec![SignatureEntrypoint {
        identity: "operation".into(),
        definition: "operation".into(),
    }]
}

#[test]
fn pr01_stops_renderer_and_codegen_before_source_generation() {
    let mut input =
        assemble_signature_generation(generated_carrier_library(), None, operation_entrypoints())
            .unwrap();
    let expected = necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input);
    Arc::make_mut(&mut input.signatures)
        .profile
        .reference
        .identity
        .clear();
    let document = encode_signature_generation(&input).unwrap();

    assert!(matches!(
        necoherence_generator::renderer::render_signature_exchange_for(
            &necoherence_generator::renderer::Target::Rust,
            &expected,
            &document
        ),
        Err(necoherence_generator::renderer::RenderFailure::Admission(ref failure))
            if matches!(
                failure.as_ref(),
                AdmissionFailure::Library(library) if pr01_library_failure(library)
            )
    ));
}

#[test]
fn generator_rejects_library_with_undefined_meaning() {
    let mut declaration = library();
    if let Shape::String(spec) = &mut declaration
        .nodes
        .iter_mut()
        .find(|node| node.id == "text")
        .unwrap()
        .shape
    {
        spec.lengths = vec![LengthBound {
            unit: StringLengthUnit::Graphemes,
            minimum: None,
            maximum: Some(BigUint::from(8u8)),
        }];
    }
    assert!(matches!(
        necoherence_generator::renderer::render_library(&declaration),
        Err(necoherence_generator::renderer::RenderFailure::UndefinedMeaning(ref failure))
            if failure.predicate == MeaningObligation::Mo02
    ));
}

#[test]
fn generated_representative_carriers_and_codecs_compile_and_roundtrip() {
    const RUNNER: &str = r##"
fn read_checked<T:WireValue>(cx:&Context<'_>,value:rt::JsonValue)->Result<T,rt::RuntimeFailure>{cx.checked_for::<T>(value).and_then(|value|T::read_wire(cx,value))}
fn roundtrip<T: WireValue + PartialEq + std::fmt::Debug>(
    context: &Context<'_>,
    value: T,
) {
    let wire = value.write_wire(context).unwrap();
    assert_eq!(read_checked::<T>(context, wire).unwrap(), value);
}

fn encode_never(
    context: &Context<'_>,
    value: never,
) -> Result<rt::JsonValue, rt::RuntimeFailure> {
    value.write_wire(context)
}

struct Owner { mode: u8, effects: usize }
impl Owner {
    fn binding(
        &mut self,
        _: &Context<'_>,
    ) -> necoherence::semantic_execution::NetworkBinding<EffectInput, EffectResult> {
        let (label, value) = match self.mode {
            0 => ("external", EffectResult::Outcome1(EffectOutcome1 {
                reason: Some(rt::JsonValue::Str("outside".into())),
            })),
            1 => ("ok", EffectResult::Outcome0(EffectOutcome0 {})),
            _ => ("external", EffectResult::Outcome0(EffectOutcome0 {})),
        };
        necoherence::semantic_execution::NetworkBinding {
            transport: necoherence::semantic_execution::NetworkTransport {
                encode: std::sync::Arc::new(|attempt| Ok(attempt.clone())),
                decode: std::sync::Arc::new(|_| panic!("completed result must not be decoded")),
            },
            prepare: std::sync::Arc::new(move |_| Ok(
                necoherence::semantic_execution::BindingPreparedCall::Completed(
                    necoherence::semantic_composition::OutcomeId(label.into()),
                    value.clone(),
                )
            )),
        }
    }
}

fn main() {
    let generation = initialize().unwrap();
    generation.input();
    let context = Context::new(&generation);
    let reference = &graph(&generation).nodes.iter().find(|node| node.reference.definition_name.as_ref() == "product").unwrap().reference;
    assert!(decode::<product>(&context, reference, "{}").is_err());
    let defaulted = decode_with_defaults::<product>(&context, reference, "{}").unwrap();
    assert_eq!(defaulted.value().value, Some(rt::JsonValue::Str("ok".into())));
    assert_eq!(defaulted.encode().unwrap(), "{\"value\":\"ok\"}");
    let mut incomplete_graph = graph(&generation).clone();
    let text_reference = incomplete_graph.nodes.iter().find(|node| node.reference.definition_name.as_ref() == "text").unwrap().reference.clone();
    if let necoherence::semantic_types::TypeShape::String(spec) = &mut incomplete_graph.nodes.iter_mut().find(|node| node.reference == text_reference).unwrap().shape {
        spec.format = Some(necoherence::semantic_types::FormatUse::Named("undeclared-default-format".into()));
    }
    let incomplete_context = Context::from_graph(&incomplete_graph);
    let failure = decode_with_defaults::<product>(&incomplete_context, reference, "{}").err().unwrap();
    let rt::RuntimeFailure::Defaults(necoherence::semantic_validation::DefaultFailure::Evaluation(necoherence::semantic_validation::ValidationFailure::Unresolved(reasons))) = failure else { panic!("classified default residual") };
    assert_eq!(reasons.len(), 1);
    assert_eq!(reasons[0].type_ref, text_reference);
    assert_eq!(reasons[0].reason, necoherence::semantic_types::SemanticReason::UnknownFormat("undeclared-default-format".into()));
    assert_eq!(reasons[0].origin, necoherence::semantic_types::OccurrenceRef::from(&text_reference));
    let ordered_reference = &graph(&generation).nodes.iter().find(|node| node.reference.definition_name.as_ref() == "ordered_product").unwrap().reference;
    let ordered = decode_with_defaults::<ordered_product>(&context, ordered_reference, r#"{"2":"extraA","second":"kept","1":"extraB"}"#).unwrap();
    assert_eq!(ordered.value().first, Some(rt::JsonValue::Str("ok".into())));
    assert_eq!(ordered.value().second, Some(rt::JsonValue::Str("kept".into())));
    assert_eq!(ordered.value().extras.len(), 2);
    assert_eq!(ordered.applications().len(), 1);
    assert_eq!(necoherence::exact_json::bounded_json_parse(&ordered.encode().unwrap()), necoherence::exact_json::bounded_json_parse(r#"{"1":"extraB","2":"extraA","first":"ok","second":"kept"}"#));
    assert_eq!(rt::encode_json(ordered.write_wire()).unwrap(), ordered.encode().unwrap());
    assert_eq!(graph(&generation).nodes.len(), 8);
    assert_eq!(
        annotations(&generation),
        &[necoherence::type_signatures::Annotation {
            target: necoherence::type_signatures::AnnotationTarget::Library,
            key: "exact".into(),
            value: rt::JsonValue::Dec("9007199254740993".into()),
        }]
    );
    roundtrip(&context, wrapped_text("ok".into()));
    roundtrip(&context, decimal("1.25".into()));
    roundtrip(
        &context,
        product {
            value: Some(rt::JsonValue::Str("ok".into())),
        },
    );
    let sealed_wire = sealed(rt::JsonValue::Obj(vec![
        ("name".into(), rt::JsonValue::Str("ok".into())),
    ]))
    .write_wire(&context)
    .unwrap();
    let sealed_value = read_checked::<sealed>(&context, sealed_wire.clone()).unwrap();
    assert_eq!(sealed_value.write_wire(&context).unwrap(), sealed_wire);
    roundtrip(
        &context,
        choice::text(rt::JsonValue::Str("ok".into())),
    );
    assert!(read_checked::<product>(&context, rt::JsonValue::Obj(vec![("extra".into(), rt::JsonValue::Bool(true))]),
    )
    .is_err());
    assert!(matches!(
        read_checked::<never>(&context, rt::JsonValue::Null),
        Err(rt::RuntimeFailure::Representation(ref condition)) if condition == "never"
    ));
    let mut owner = Owner { mode: 0, effects: 0 };
    let necoherence::semantic_execution::BindingPreparedCall::Completed(outcome, result) =
        effect_prepare(owner.binding(&context), EffectInput {}).unwrap()
    else {
        panic!("external completion was not prepared")
    };
    assert_eq!(outcome.0, "external");
    assert_eq!(result.outcome_id(), "external");
    assert_eq!(owner.effects, 0);
    owner.mode = 1;
    assert!(effect_prepare(owner.binding(&context), EffectInput {}).is_err());
    owner.mode = 2;
    assert!(matches!(
        effect_prepare(owner.binding(&context), EffectInput {}),
        Err(necoherence::semantic_execution::ExecutionFailure::InvalidPlan(ref condition))
            if condition == "undeclared external completion"
    ));
    assert_eq!(owner.effects, 0);
    let _never_encoder: fn(
        &Context<'_>,
        never,
    ) -> Result<rt::JsonValue, rt::RuntimeFailure> = encode_never;
}
"##;

    let declaration = generated_carrier_library();
    let input =
        assemble_signature_generation(declaration.clone(), None, operation_entrypoints()).unwrap();
    let generated = render_admitted(&input);
    let profile_document = encode_value_profile(&declaration.profile).unwrap();
    let program = format!(
        "{generated}\n{}",
        RUNNER.replace("__PROFILE__", &profile_document)
    );
    let project =
        std::env::temp_dir().join(format!("necoherence-generated-rust-{}", std::process::id()));
    if project.exists() {
        fs::remove_dir_all(&project).unwrap();
    }
    fs::create_dir_all(project.join("src")).unwrap();
    let necoherence_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../packages/rust/adapter")
        .canonicalize()
        .unwrap();
    fs::write(
        project.join("Cargo.toml"),
        format!(
            "[package]\nname = \"generated-roundtrip\"\nversion = \"0.0.0\"\nedition = \"2021\"\n\n[workspace]\n\n[dependencies]\nnecoherence = {{ path = {:?} }}\n{}",
            necoherence_path,
            certificate_patch()
        ),
    )
    .unwrap();
    fs::write(project.join("src/main.rs"), program).unwrap();
    let output = Command::new(env!("CARGO"))
        .args(["run", "--quiet", "--manifest-path"])
        .arg(project.join("Cargo.toml"))
        .env("CARGO_TARGET_DIR", project.join("target"))
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "stdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    fs::remove_dir_all(project).unwrap();
}

#[test]
fn operation_extension_accepts_only_external_supplements() {
    let origin = Origin {
        source: SourceIdentity {
            repository: "synthetic".into(),
            revision: "1".into(),
            path: "operation".into(),
            content_digest: "b".repeat(64),
        },
        locator: vec!["outcome".into()],
    };
    let success = SignatureOutcome {
        id: "success".into(),
        form: necoherence::type_signatures::OutcomeForm::Success,
        cause: OutcomeCause::ValueContract {
            origin: origin.clone(),
        },
        value_ports: vec![],
        produced_resources: vec![],
    };
    let base = OperationContract {
        effect: EffectPoint::DataOnly,
        inputs: vec![],
        outcomes: vec![success.clone()],
    };
    let external = SignatureOutcome {
        id: "external".into(),
        form: necoherence::type_signatures::OutcomeForm::DeclaredFailure,
        cause: OutcomeCause::ExternalCondition {
            specification: origin.clone(),
        },
        value_ports: vec![SignaturePort {
            id: "reason".into(),
            contract: SignatureSlot {
                type_id: "text".into(),
                required: true,
                nullable: false,
            },
        }],
        produced_resources: vec![],
    };
    let mut supplied = base.clone();
    supplied.outcomes.push(external);
    assert!(!operation_extension_valid(&base, &supplied, &library()));
    supplied.outcomes.pop();
    supplied.outcomes.push(SignatureOutcome {
        id: "forged".into(),
        form: necoherence::type_signatures::OutcomeForm::Success,
        cause: OutcomeCause::ValueContract { origin },
        value_ports: vec![],
        produced_resources: vec![],
    });
    assert!(!operation_extension_valid(&base, &supplied, &library()));
}

const RUST_2021_FIELD_KEYWORDS: &[&str] = &[
    "as", "break", "const", "continue", "crate", "else", "enum", "extern", "false", "fn", "for",
    "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
    "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where",
    "while", "async", "await", "dyn", "abstract", "become", "box", "do", "final", "macro",
    "override", "priv", "typeof", "unsized", "virtual", "yield", "try",
];

fn keyword_field_library(fields: &[&str]) -> TypeSignatureLibrary {
    let mut declaration = generated_carrier_library();
    declaration.nodes.extend([
        TypeNodeInput {
            id: "keyword_bool".into(),
            shape: Shape::Boolean(BooleanSpec {
                const_value: None,
                default_value: Some(false),
            }),
        },
        product_node(
            "keyword_product",
            fields
                .iter()
                .map(|field| field_spec(field, "keyword_bool", true))
                .collect(),
            SignatureExtraMembers::Reject,
        ),
    ]);
    let operation = declaration
        .definitions
        .iter_mut()
        .find_map(|definition| match &mut definition.shape {
            SignatureDefinitionShape::Operation(operation) if definition.id == "operation" => {
                Some(operation)
            }
            _ => None,
        })
        .expect("operation fixture");
    let ports: Vec<_> = fields
        .iter()
        .map(|field| SignaturePort {
            id: (*field).into(),
            contract: SignatureSlot {
                type_id: "keyword_bool".into(),
                required: true,
                nullable: false,
            },
        })
        .collect();
    operation.inputs = ports.clone();
    fixture_item_mut(&mut operation.outcomes, 0).value_ports = ports;
    declaration
}

fn certificate_patch() -> String {
    String::new()
}

fn run_field_consumer(identity: &str, source: &str, runner: &str) {
    let project = std::env::temp_dir().join(format!(
        "necoherence-field-{identity}-{}",
        std::process::id()
    ));
    if project.exists() {
        fs::remove_dir_all(&project).unwrap();
    }
    fs::create_dir_all(project.join("src")).unwrap();
    let runtime = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../packages/rust/adapter")
        .canonicalize()
        .unwrap();
    fs::write(project.join("Cargo.toml"), format!(
        "[package]\nname=\"field-consumer\"\nversion=\"0.0.0\"\nedition=\"2021\"\n[workspace]\n[dependencies]\nnecoherence={{path={runtime:?}}}\n{}",
        certificate_patch()
    )).unwrap();
    fs::write(project.join("src/main.rs"), format!(
        "#![allow(non_camel_case_types,non_snake_case,unused_variables,unused_imports,dead_code)]\n{source}\n{runner}"
    )).unwrap();
    let output = Command::new(env!("CARGO"))
        .args(["run", "--quiet", "--manifest-path"])
        .arg(project.join("Cargo.toml"))
        .env("CARGO_TARGET_DIR", project.join("target"))
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "stdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    fs::remove_dir_all(project).unwrap();
}

fn mismatched_reference_consumer(identity: &str, body: &str) {
    let mut declaration = keyword_field_library(&["label"]);
    declaration.nodes.push(product_node(
        "keyword_empty",
        vec![],
        SignatureExtraMembers::Reject,
    ));
    let input = assemble_signature_generation(declaration, None, operation_entrypoints()).unwrap();
    let source = render_admitted(&input);
    let runner = format!(
        r##"
fn main() {{
    let generation = initialize().unwrap();
    let context = Context::new(&generation);
    let empty = &graph(&generation).nodes.iter().find(|node| node.reference.definition_name.as_ref() == "keyword_empty").unwrap().reference;
    {body}
}}
"##
    );
    run_field_consumer(identity, &source, &runner);
}

#[test]
fn generated_decode_rejects_a_value_the_type_itself_rejects_under_another_reference() {
    mismatched_reference_consumer(
        "mismatch-decode",
        r#"assert!(decode::<keyword_empty>(&context, empty, "{}").is_ok());
    assert!(matches!(decode::<keyword_product>(&context, empty, "{}"), Err(rt::RuntimeFailure::Validation(_))));"#,
    );
}

#[test]
fn generated_decode_with_defaults_rejects_a_value_the_type_itself_rejects_under_another_reference()
{
    mismatched_reference_consumer(
        "mismatch-defaults",
        r#"assert!(decode_with_defaults::<keyword_empty>(&context, empty, "{}").is_ok());
    assert!(matches!(decode_with_defaults::<keyword_product>(&context, empty, "{}"), Err(rt::RuntimeFailure::Validation(_))));"#,
    );
}

#[test]
fn generated_keyword_fields_preserve_type_label_wire_and_defaults() {
    let declaration = keyword_field_library(&["type", "label"]);
    let input = assemble_signature_generation(declaration, None, operation_entrypoints()).unwrap();
    let source = render_admitted(&input);
    assert!(source.contains("pub field_type:Option<rt::JsonValue>"));
    assert!(source.contains("pub label:Option<rt::JsonValue>"));
    assert!(source.contains("pub struct keyword_product"));
    assert!(source.contains("pub struct EffectInput"));
    assert!(source.contains("pub struct EffectOutcome0"));
    assert!(source.contains("pub fn effect_prepare"));
    assert!(!source.contains("pub fn effect_call"));
    run_field_consumer(
        "type-label",
        &source,
        r##"
fn read_checked<T:WireValue>(cx:&Context<'_>,value:rt::JsonValue)->Result<T,rt::RuntimeFailure>{cx.checked_for::<T>(value).and_then(|value|T::read_wire(cx,value))}
fn main() {
    let generation = initialize().unwrap();
    let context = Context::new(&generation);
    let reference = &graph(&generation).nodes.iter().find(|node| node.reference.definition_name.as_ref() == "keyword_product").unwrap().reference;
    let value = keyword_product { field_type: Some(rt::JsonValue::Bool(true)), label: Some(rt::JsonValue::Bool(false)) };
    let wire = value.write_wire(&context).unwrap();
    assert_eq!(rt::encode_json(&wire).unwrap(), r#"{"type":true,"label":false}"#);
    assert_eq!(read_checked::<keyword_product>(&context, wire).unwrap(), value);
    assert!(decode::<keyword_product>(&context, reference, "{}").is_err());
    let defaulted = decode_with_defaults::<keyword_product>(&context, reference, "{}").unwrap();
    assert_eq!(defaulted.value().field_type, Some(rt::JsonValue::Bool(false)));
    assert_eq!(defaulted.value().label, Some(rt::JsonValue::Bool(false)));
    assert_eq!(defaulted.applications().len(), 2);
    assert_eq!(defaulted.encode().unwrap(), r#"{"type":false,"label":false}"#);
    let explicit = decode_with_defaults::<keyword_product>(&context, reference, r#"{"type":true,"label":false}"#).unwrap();
    assert_eq!(explicit.value(), &value);
    assert!(explicit.applications().is_empty());
    let input = EffectInput { field_type: Some(rt::JsonValue::Bool(true)), label: None };
    let output = EffectOutcome0 { field_type: input.field_type, label: input.label };
    assert_eq!(output.field_type, Some(rt::JsonValue::Bool(true)));
}
"##,
    );
}

#[test]
fn accepted_rust_2021_keyword_fields_and_nonkeywords_compile() {
    let controls = [
        "label",
        "union",
        "macro_rules",
        "raw",
        "safe",
        "gen",
        "Type",
        "user-name",
        "1st-type",
    ];
    let fields: Vec<_> = RUST_2021_FIELD_KEYWORDS
        .iter()
        .copied()
        .chain(controls)
        .collect();
    let input = assemble_signature_generation(
        keyword_field_library(&fields),
        None,
        operation_entrypoints(),
    )
    .unwrap();
    let mut source = render_admitted(&input);
    let mut members = String::new();
    let mut expected = String::new();
    for field in &fields {
        let candidate = field.replace(|character: char| !character.is_ascii_alphanumeric(), "_");
        let candidate = if candidate.starts_with(|character: char| character.is_ascii_digit()) {
            format!("_{candidate}")
        } else {
            candidate
        };
        let native = if RUST_2021_FIELD_KEYWORDS.contains(field) {
            format!("field_{candidate}")
        } else {
            candidate
        };
        assert!(
            source.contains(&format!("pub {native}:Option<rt::JsonValue>")),
            "{field}"
        );
        members.push_str(&format!("{native}:Some(rt::JsonValue::Bool(false)),"));
        expected.push_str(&format!("({field:?}.into(),rt::JsonValue::Bool(false)),"));
    }
    let prefixed = assemble_signature_generation(
        keyword_field_library(&["field_type"]),
        None,
        operation_entrypoints(),
    )
    .unwrap();
    let prefixed = render_admitted(&prefixed);
    assert!(prefixed.contains("pub field_type:Option<rt::JsonValue>"));
    assert!(!prefixed.contains("pub field_field_type:"));
    source.push_str(&format!("\nmod prefixed_control {{ {prefixed} pub fn exercise() {{let _ = keyword_product {{field_type:None}};}} }}\n"));
    let runner = format!(
        "fn read_checked<T:WireValue>(cx:&Context<'_>,value:rt::JsonValue)->Result<T,rt::RuntimeFailure>{{cx.checked_for::<T>(value).and_then(|value|T::read_wire(cx,value))}}fn main() {{let generation=initialize().unwrap();let context=Context::new(&generation);\
         let value=keyword_product{{{members}}};let wire=value.write_wire(&context).unwrap();\
         assert_eq!(wire,rt::JsonValue::Obj(vec![{expected}]));\
         assert_eq!(read_checked::<keyword_product>(&context, wire).unwrap(),value);\
         let _=EffectInput{{{members}}};let _=EffectOutcome0{{{members}}};prefixed_control::exercise();}}"
    );
    run_field_consumer("all-keywords", &source, &runner);
}
fn single_output_problem(
    declaration: &TypeSignatureLibrary,
    output_type: &str,
    bounds: SearchBounds,
) -> CompositionInput {
    let graph = check_type_signatures(declaration).unwrap();
    let contract = SlotContract {
        type_ref: signature_type_ref(output_type),
        required: true,
        nullable: false,
    };
    let function = FunctionRef {
        identity: "single-output".into(),
        revision: "1".into(),
        content_digest: "d".repeat(64),
    };
    let site = SiteId("site".into());
    let outcome = OutcomeId("success".into());
    let port = PortId("value".into());
    CompositionInput {
        identity: "single-output-composition".into(),
        revision: "1".into(),
        basis: SemanticBasis::of(&graph),
        signatures: vec![FunctionSignature {
            reference: function.clone(),
            form: FunctionForm::DeclaredTransform,
            effect: CompositionEffect::PureFunction,
            inputs: vec![],
            outcomes: vec![OutcomeContract {
                id: outcome.clone(),
                form: necoherence::semantic_composition::OutcomeForm::Success,
                value_ports: vec![OutputPort {
                    id: port.clone(),
                    contract: contract.clone(),
                    resource_production: None,
                }],
                produced_resources: vec![],
            }],
            resource_inputs: vec![],
            assumption_ref: "single output fixture".into(),
            handles_failure: None,
        }],
        initial_inputs: vec![],
        initial_resources: vec![],
        goal: GoalSpec {
            outputs: vec![GoalPort {
                id: GoalPortId("result".into()),
                contract,
                source_constraint: SourceConstraint::ProducedBy {
                    site: site.clone(),
                    outcome,
                    port,
                    path: vec![],
                },
            }],
            failures: vec![],
            final_resources: vec![],
        },
        invocation_domain: InvocationDomain {
            identity: "finite".into(),
            revision: "1".into(),
            sites: vec![InvocationSite {
                id: site,
                function: function.clone(),
            }],
            permitted_projections: vec![],
            permitted_constructions: vec![],
            permitted_transforms: vec![function],
            guards: vec![],
        },
        allowed_effects: vec![CompositionEffect::PureFunction],
        explicit_order: vec![],
        selection_policy: Some(SelectionPolicy::AnyFeasible),
        bounds,
    }
}

#[test]
fn required_constant_beyond_sample_bound_is_inhabitation_as_lean_reports() {
    let mut declaration = library();
    let expected = "large-required-constant".repeat(8);
    declaration.nodes.push(TypeNodeInput {
        id: "oversized-constant".into(),
        shape: Shape::String(StringSpec {
            format: None,
            lengths: vec![],
            wrapper: None,
            const_value: Some(expected.clone()),
            enum_values: None,
            examples: vec![],
            default_value: None,
        }),
    });
    let graph = check_type_signatures(&declaration).unwrap();
    let bounds = SearchBounds {
        max_expanded_states: BigUint::from(16u32),
        max_binding_candidates: BigUint::from(32u32),
        max_type_obligations: BigUint::from(16u32),
        max_branch_nodes: BigUint::from(32u32),
        resource_bounds: None,
        max_sample_length: BigUint::from(8u32),
    };
    let contract = SlotContract {
        type_ref: signature_type_ref("oversized-constant"),
        required: true,
        nullable: false,
    };
    let samples = slot_samples(&graph, &bounds, &contract);
    assert!(samples.values.is_empty());
    assert!(samples.obligations.contains(&SampleObligation::SampleBound));
    assert!(matches!(
        PreparedValidator::new(&graph, FormatWorkspace::empty()).accepts_slot(
            &contract,
            borrowed_slot(&SlotValue::Present(JsonValue::Str(expected.clone())))
        ),
        ValueDecision::Accepted
    ));
    let problem = single_output_problem(&declaration, "oversized-constant", bounds);
    let prepared = prepare_direct_composition(
        &graph,
        problem,
        operation_checker_without_library(),
        operation_meaning_of(&graph),
    )
    .unwrap();
    let CompositionDecision::Incomplete { evaluation, .. } = derive(&prepared).unwrap() else {
        panic!("the oversized required constant has no sampled value and stays incomplete");
    };
    let obligations = match evaluation {
        RefinementOutcome::Resolved(value)
        | RefinementOutcome::Residual { value, .. }
        | RefinementOutcome::Stopped { value, .. } => value.value,
    };
    assert!(matches!(
        obligations.as_slice(),
        [UnresolvedObligation::Inhabitation { .. }]
    ));
}

#[test]
fn derive_reports_branch_bound_when_depth_fuel_stops_before_child() {
    let mut declaration = library();
    declaration.nodes.extend([
        TypeNodeInput {
            id: "small-constant".into(),
            shape: Shape::String(StringSpec {
                format: None,
                lengths: vec![],
                wrapper: None,
                const_value: Some("ok".into()),
                enum_values: None,
                examples: vec![],
                default_value: None,
            }),
        },
        TypeNodeInput {
            id: "deep-output".into(),
            shape: Shape::Product(SignatureProduct {
                fields: vec![SignatureField {
                    wire_name: "required".into(),
                    slot: SignatureSlot {
                        type_id: "small-constant".into(),
                        required: true,
                        nullable: false,
                    },
                }],
                extras: SignatureExtraMembers::Reject,
            }),
        },
    ]);
    let graph = check_type_signatures(&declaration).unwrap();
    let problem = single_output_problem(
        &declaration,
        "deep-output",
        SearchBounds {
            max_expanded_states: BigUint::from(16u32),
            max_binding_candidates: BigUint::from(32u32),
            max_type_obligations: BigUint::from(1u32),
            max_branch_nodes: BigUint::from(32u32),
            resource_bounds: None,
            max_sample_length: BigUint::from(32u32),
        },
    );
    let prepared = prepare_direct_composition(
        &graph,
        problem,
        operation_checker_without_library(),
        operation_meaning_of(&graph),
    )
    .unwrap();
    let CompositionDecision::Incomplete { evaluation, .. } = derive(&prepared).unwrap() else {
        panic!("depth fuel exhausted before the accepted child candidate must remain unknown");
    };
    let obligations = match evaluation {
        necoherence::semantic_types::RefinementOutcome::Resolved(value)
        | necoherence::semantic_types::RefinementOutcome::Residual { value, .. }
        | necoherence::semantic_types::RefinementOutcome::Stopped { value, .. } => value.value,
    };
    assert!(obligations.contains(&UnresolvedObligation::BranchBoundExhausted));
}

#[test]
fn public_derivation_solves_all_optional_nested_products_and_union_branches() {
    let mut declaration = library();
    let mut child = "text".to_owned();
    for level in 0..4 {
        let id = format!("optional-level-{level}");
        declaration.nodes.push(TypeNodeInput {
            id: id.clone(),
            shape: Shape::Product(SignatureProduct {
                fields: (0..12)
                    .map(|field| SignatureField {
                        wire_name: format!("field-{field}"),
                        slot: SignatureSlot {
                            type_id: child.clone(),
                            required: false,
                            nullable: false,
                        },
                    })
                    .collect(),
                extras: SignatureExtraMembers::Reject,
            }),
        });
        child = id;
    }
    declaration.nodes.push(TypeNodeInput {
        id: "nested-choice".into(),
        shape: Shape::TaggedUnion(SignatureUnion {
            branches: vec![
                SignatureUnionBranch {
                    target: child,
                    wire_tag: "nested".into(),
                    selector: BranchSelector::Kind(ValueKind::Object),
                },
                SignatureUnionBranch {
                    target: "text".into(),
                    wire_tag: "text".into(),
                    selector: BranchSelector::Kind(ValueKind::String),
                },
            ],
        }),
    });
    declaration.nodes.push(TypeNodeInput {
        id: "optional-output".into(),
        shape: Shape::Product(SignatureProduct {
            fields: vec![SignatureField {
                wire_name: "nested".into(),
                slot: SignatureSlot {
                    type_id: "nested-choice".into(),
                    required: false,
                    nullable: false,
                },
            }],
            extras: SignatureExtraMembers::Reject,
        }),
    });
    let graph = check_type_signatures(&declaration).unwrap();
    let problem = single_output_problem(&declaration, "optional-output", SearchBounds::default());
    let contract = problem.signatures[0].outcomes[0].value_ports[0]
        .contract
        .clone();
    let prepared = prepare_direct_composition(
        &graph,
        problem,
        operation_checker_without_library(),
        operation_meaning_of(&graph),
    )
    .unwrap();
    let CompositionDecision::Solved(checked, _) = derive(&prepared).unwrap() else {
        panic!("the all-optional nested output must derive");
    };
    verify_composition(&prepared, checked.raw()).unwrap();
    for trace in &checked.raw().witness.resource_traces {
        assert_eq!(trace.value_sources.len(), 1);
        for (_, value) in &trace.value_sources {
            assert_eq!(value, &SlotValue::Present(JsonValue::Obj(vec![])));
            assert_eq!(
                PreparedValidator::new(&graph, FormatWorkspace::empty())
                    .accepts_slot(&contract, borrowed_slot(value)),
                ValueDecision::Accepted,
            );
        }
    }
}

fn render_admitted(input: &SignatureGenerationInput) -> String {
    let document = encode_signature_generation(input).unwrap();
    necoherence_generator::renderer::render_signature_exchange_for(
        &necoherence_generator::renderer::Target::Rust,
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(input),
        &document,
    )
    .unwrap()
}
