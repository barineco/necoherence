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

fn null_contract_graph() -> (TypeSignatureLibrary, SemanticGraph) {
    let mut library = library();
    library.nodes.extend([
        TypeNodeInput {
            id: "any".into(),
            shape: Shape::Unknown(UnknownKind::Any),
        },
        TypeNodeInput {
            id: "integer".into(),
            shape: Shape::Integer(IntegerSpec {
                domain: None,
                minimum: None,
                maximum: None,
                const_value: None,
                enum_values: None,
                default_value: None,
            }),
        },
        TypeNodeInput {
            id: "nullable-text-array".into(),
            shape: Shape::Array(SignatureArray {
                item: SignatureElementContract {
                    type_id: "text".into(),
                    nullable: true,
                },
                minimum: None,
                maximum: None,
            }),
        },
        TypeNodeInput {
            id: "text-array".into(),
            shape: Shape::Array(SignatureArray {
                item: SignatureElementContract {
                    type_id: "text".into(),
                    nullable: false,
                },
                minimum: None,
                maximum: None,
            }),
        },
        TypeNodeInput {
            id: "any-array".into(),
            shape: Shape::Array(SignatureArray {
                item: SignatureElementContract {
                    type_id: "any".into(),
                    nullable: false,
                },
                minimum: None,
                maximum: None,
            }),
        },
        TypeNodeInput {
            id: "any-map".into(),
            shape: Shape::Product(SignatureProduct {
                fields: vec![],
                extras: SignatureExtraMembers::Allow {
                    key_format: None,
                    value: SignatureElementContract {
                        type_id: "any".into(),
                        nullable: false,
                    },
                },
            }),
        },
        TypeNodeInput {
            id: "integer-map".into(),
            shape: Shape::Product(SignatureProduct {
                fields: vec![],
                extras: SignatureExtraMembers::Allow {
                    key_format: None,
                    value: SignatureElementContract {
                        type_id: "integer".into(),
                        nullable: false,
                    },
                },
            }),
        },
    ]);
    let graph = check_type_signatures(&library).unwrap();
    (library, graph)
}

#[test]
fn nullable_string_array_accepts_null_item() {
    let (library, graph) = null_contract_graph();
    let array = signature_type_ref(&library, &canonical_digest(&library), "nullable-text-array");
    assert!(matches!(
        accepts_value(&graph, &array, &JsonValue::Arr(vec![JsonValue::Null])),
        ValueDecision::Accepted
    ));
}

#[test]
fn non_nullable_string_array_rejects_null_item() {
    let (library, graph) = null_contract_graph();
    let array = signature_type_ref(&library, &canonical_digest(&library), "text-array");
    let decision = accepts_value(&graph, &array, &JsonValue::Arr(vec![JsonValue::Null]));
    assert!(matches!(decision, ValueDecision::Rejected(_)));
    let ValueDecision::Rejected(failure) = decision else {
        return;
    };
    assert_eq!(
        failure.value_path,
        vec![PathStep::Index(BigUint::from(0u8))]
    );
    assert_eq!(failure.reference_trace, vec![array]);
}

#[test]
fn non_nullable_any_array_and_map_accept_null_values() {
    let (library, graph) = null_contract_graph();
    let digest = canonical_digest(&library);
    let array = signature_type_ref(&library, &digest, "any-array");
    let map = signature_type_ref(&library, &digest, "any-map");
    assert!(matches!(
        accepts_value(&graph, &array, &JsonValue::Arr(vec![JsonValue::Null])),
        ValueDecision::Accepted
    ));
    assert!(matches!(
        accepts_value(
            &graph,
            &map,
            &JsonValue::Obj(vec![("value".into(), JsonValue::Null)])
        ),
        ValueDecision::Accepted
    ));
}

#[test]
fn non_nullable_integer_map_rejects_null_value() {
    let (library, graph) = null_contract_graph();
    let map = signature_type_ref(&library, &canonical_digest(&library), "integer-map");
    let decision = accepts_value(
        &graph,
        &map,
        &JsonValue::Obj(vec![("value".into(), JsonValue::Null)]),
    );
    assert!(matches!(decision, ValueDecision::Rejected(_)));
    let ValueDecision::Rejected(failure) = decision else {
        return;
    };
    assert_eq!(failure.value_path, vec![PathStep::Field("value".into())]);
    assert_eq!(failure.reference_trace, vec![map]);
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
    let profile =
        ValueSemanticProfile::from_profile(&decoded.signatures.profile.semantic_profile());
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
    assert_eq!(decode_diagnostic(&diagnostic_wire).unwrap(), diagnostic);
    assert!(matches!(
        decode_signature_generation(
            &wire.replace("ncoh-checked-generation@4", "ncoh-checked-generation@3")
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

fn recursive_ref(name: &str) -> TypeRef {
    let base = check_type_signatures(&library()).unwrap();
    TypeRef::new(
        base.nodes.first().unwrap().reference.source.clone(),
        name,
        vec![],
    )
}

fn recursive_node(name: &str, shape: TypeShape) -> TypeNode {
    TypeNode {
        reference: recursive_ref(name),
        shape,
        description: None,
        attributes: vec![],
        extensions: vec![],
    }
}

fn recursive_product(fields: &[(&str, &str)]) -> TypeShape {
    TypeShape::Product(ProductSpec {
        fields: fields
            .iter()
            .map(|(name, target)| FieldSpec {
                wire_name: (*name).into(),
                slot: SlotContract {
                    type_ref: recursive_ref(target),
                    required: true,
                    nullable: false,
                },
                origin: (&recursive_ref(target)).into(),
            })
            .collect(),
        extras: ExtraMembers::Reject,
    })
}

fn recursive_union(branches: &[(&str, &str)]) -> TypeShape {
    TypeShape::TaggedUnion(UnionSpec {
        branches: branches
            .iter()
            .map(|(tag, target)| UnionBranch {
                target: recursive_ref(target),
                wire_tag: (*tag).into(),
                selector: BranchSelector::InternalTag,
                origin: (&recursive_ref(target)).into(),
            })
            .collect(),
    })
}

fn recursive_array(target: &str) -> TypeShape {
    TypeShape::Array(ArraySpec {
        item: ElementContract {
            type_ref: recursive_ref(target),
            nullable: false,
        },
        min_length: None,
        max_length: None,
    })
}

fn recursive_graph(nodes: Vec<TypeNode>) -> SemanticGraph {
    SemanticGraph {
        profile: check_type_signatures(&library()).unwrap().profile,
        nodes,
        source_refs: vec![],
    }
}

fn goal_value(tag: &str, field: Option<(&str, JsonValue)>) -> JsonValue {
    let mut members = vec![("kind".into(), JsonValue::Str(tag.into()))];
    if let Some((name, value)) = field {
        members.push((name.into(), value));
    }
    JsonValue::Obj(members)
}

#[test]
fn finite_recursive_leaf_not_and_or() {
    let graph = recursive_graph(vec![
        recursive_node(
            "Goal",
            recursive_union(&[
                ("leaf", "leaf"),
                ("not", "not"),
                ("and", "and"),
                ("or", "or"),
            ]),
        ),
        recursive_node("leaf", recursive_product(&[])),
        recursive_node("not", recursive_product(&[("goal", "Goal")])),
        recursive_node("and", recursive_product(&[("goals", "Goals")])),
        recursive_node("or", recursive_product(&[("goals", "Goals")])),
        recursive_node("Goals", recursive_array("Goal")),
    ]);
    let leaf = goal_value("leaf", None);
    let negated = goal_value("not", Some(("goal", leaf.clone())));
    let twice = goal_value("not", Some(("goal", negated.clone())));
    let conjunction = goal_value(
        "and",
        Some(("goals", JsonValue::Arr(vec![leaf.clone(), negated.clone()]))),
    );
    let disjunction = goal_value(
        "or",
        Some(("goals", JsonValue::Arr(vec![twice, leaf.clone()]))),
    );
    for value in [leaf, negated, conjunction, disjunction] {
        assert_eq!(
            accepts_value(&graph, &recursive_ref("Goal"), &value),
            ValueDecision::Accepted
        );
    }
}

#[test]
fn recursive_array_deeper_than_node_count_and_extras() {
    let graph = recursive_graph(vec![recursive_node("Array", recursive_array("Array"))]);
    let mut value = JsonValue::Arr(vec![]);
    for _ in 0..32 {
        value = JsonValue::Arr(vec![value, JsonValue::Arr(vec![])]);
    }
    assert_eq!(
        accepts_value(&graph, &recursive_ref("Array"), &value),
        ValueDecision::Accepted
    );
    let graph = recursive_graph(vec![recursive_node(
        "Map",
        TypeShape::Product(ProductSpec {
            fields: vec![],
            extras: ExtraMembers::Allow {
                key_format: None,
                value: ElementContract {
                    type_ref: recursive_ref("Map"),
                    nullable: false,
                },
            },
        }),
    )]);
    let value = JsonValue::Obj(vec![
        (
            "child".into(),
            JsonValue::Obj(vec![("child".into(), JsonValue::Obj(vec![]))]),
        ),
        ("sibling".into(), JsonValue::Obj(vec![])),
    ]);
    assert_eq!(
        accepts_value(&graph, &recursive_ref("Map"), &value),
        ValueDecision::Accepted
    );
}

#[test]
fn reference_cycles_preserve_failure_fields() {
    let a = recursive_ref("A");
    let b = recursive_ref("B");
    let u = recursive_ref("U");
    let alias = |target| TypeShape::Alias {
        target,
        reference_text: "loop".into(),
    };
    let cases = [
        (vec![recursive_node("A", alias(a.clone()))], vec![a.clone()]),
        (
            vec![
                recursive_node("A", alias(b.clone())),
                recursive_node("B", alias(a.clone())),
            ],
            vec![a.clone(), b],
        ),
        (
            vec![recursive_node("A", recursive_union(&[("loop", "A")]))],
            vec![a.clone()],
        ),
        (
            vec![
                recursive_node("A", alias(u.clone())),
                recursive_node("U", recursive_union(&[("loop", "A")])),
            ],
            vec![a.clone(), u],
        ),
    ];
    let observed = goal_value("loop", None);
    for (nodes, trace) in cases {
        for child in [false, true] {
            let mut nodes = nodes.clone();
            nodes.push(recursive_node(
                "Parent",
                recursive_product(&[("child", "A")]),
            ));
            let graph = recursive_graph(nodes);
            let (root, value, path, expected_trace) = if child {
                let mut expected = vec![recursive_ref("Parent")];
                expected.extend(trace.clone());
                (
                    "Parent",
                    JsonValue::Obj(vec![("child".into(), observed.clone())]),
                    vec![PathStep::Field("child".into())],
                    expected,
                )
            } else {
                ("A", observed.clone(), vec![], trace.clone())
            };
            let decision = accepts_value(&graph, &recursive_ref(root), &value);
            assert!(matches!(decision, ValueDecision::Rejected(_)));
            let ValueDecision::Rejected(failure) = decision else {
                return;
            };
            assert_eq!(failure.type_ref, a);
            assert_eq!(failure.condition, ValueCondition::ReferenceCycle);
            assert_eq!(failure.value_path, path);
            assert_eq!(failure.observed, SlotValue::Present(observed.clone()));
            assert_eq!(failure.reference_trace, expected_trace);
        }
    }
}
