// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT
#![allow(
    clippy::expect_used,
    clippy::unwrap_used,
    clippy::panic,
    clippy::indexing_slicing
)]
use necoherence::exact_json_view::JsonValueView;
use necoherence::semantic_codegen_runtime::{
    integer_decode, select_branch, with_member, wrap_decode, wrap_encode, RuntimeFailure,
};
use necoherence::semantic_composition::{
    check_assignable, slot_samples, CompatibilityDecision, SearchBounds,
};
use necoherence::semantic_exchange::*;
use necoherence::semantic_types::*;
use necoherence::semantic_validation::*;
use necoherence::signature_admission::*;
use necoherence::type_signatures::*;
use num_bigint::{BigInt, BigUint};

fn validator_of(graph: &SemanticGraph) -> PreparedValidator<'_> {
    PreparedValidator::new(graph, FormatWorkspace::empty())
}

fn required_slot(reference: &TypeRef) -> SlotContract {
    SlotContract {
        type_ref: reference.clone(),
        required: true,
        nullable: false,
    }
}

fn decide_slot_value<'a>(
    graph: &'a SemanticGraph,
    slot: &'a SlotContract,
    value: SlotValue<&'a JsonValue>,
) -> BorrowedValueDecision<'a, 'a> {
    let view = match value {
        SlotValue::Absent => SlotValue::Absent,
        SlotValue::Null => SlotValue::Null,
        SlotValue::Present(value) => SlotValue::Present(JsonValueView::from_json(value)),
    };
    PreparedValidator::new(graph, FormatWorkspace::empty()).decide_view_slot(slot, view)
}

fn decide_present<'a>(
    graph: &'a SemanticGraph,
    slot: &'a SlotContract,
    value: &'a JsonValue,
) -> BorrowedValueDecision<'a, 'a> {
    decide_slot_value(graph, slot, SlotValue::Present(value))
}

fn decide_present_view<'a>(
    graph: &'a SemanticGraph,
    slot: &'a SlotContract,
    value: JsonValueView<'a>,
) -> BorrowedValueDecision<'a, 'a> {
    PreparedValidator::new(graph, FormatWorkspace::empty())
        .decide_view_slot(slot, SlotValue::Present(value))
}

fn fixture_item<T>(items: &[T], index: usize) -> &T {
    items.get(index).expect("fixture item exists")
}

pub(crate) fn fixture_item_mut<T>(items: &mut [T], index: usize) -> &mut T {
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
pub(crate) fn library() -> TypeSignatureLibrary {
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
    let (_, graph) = null_contract_graph();
    let array = signature_type_ref("nullable-text-array");
    assert!(matches!(
        PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&array, &JsonValue::Arr(vec![JsonValue::Null])),
        ValueDecision::Accepted
    ));
}

#[test]
fn non_nullable_string_array_rejects_null_item() {
    let (_, graph) = null_contract_graph();
    let array = signature_type_ref("text-array");
    let decision = PreparedValidator::new(&graph, FormatWorkspace::empty())
        .accepts_value(&array, &JsonValue::Arr(vec![JsonValue::Null]));
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
fn array_index_projection_is_nullable() {
    let (_, graph) = null_contract_graph();
    let source = SlotContract {
        type_ref: signature_type_ref("text-array"),
        required: true,
        nullable: false,
    };
    let validator = validator_of(&graph);
    let projection = necoherence::semantic_composition::project_slot(
        validator.metadata(),
        &source,
        &[PathStep::Index(BigUint::from(0u8))],
        &[],
    )
    .unwrap();
    assert!(projection.destination.nullable);
}

#[test]
fn non_nullable_any_array_and_map_accept_null_values() {
    let (_, graph) = null_contract_graph();
    let array = signature_type_ref("any-array");
    let map = signature_type_ref("any-map");
    assert!(matches!(
        PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&array, &JsonValue::Arr(vec![JsonValue::Null])),
        ValueDecision::Accepted
    ));
    assert!(matches!(
        PreparedValidator::new(&graph, FormatWorkspace::empty()).accepts_value(
            &map,
            &JsonValue::Obj(vec![("value".into(), JsonValue::Null)])
        ),
        ValueDecision::Accepted
    ));
}

#[test]
fn non_nullable_integer_map_rejects_null_value() {
    let (_, graph) = null_contract_graph();
    let map = signature_type_ref("integer-map");
    let decision = PreparedValidator::new(&graph, FormatWorkspace::empty()).accepts_value(
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
fn integer_number_form_reads_exponent_notation_as_lean_does() {
    let (_, graph) = null_contract_graph();
    let integer = signature_type_ref("integer");
    for (text, accepted) in [
        ("1e1", true),
        ("10e0", true),
        ("1.0e1", true),
        ("100e-1", false),
        ("1e2", false),
        ("1.0", false),
    ] {
        let value = necoherence::semantic_codegen_runtime::decode_json(text).unwrap();
        let decision = PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&integer, &value);
        assert_eq!(
            matches!(decision, ValueDecision::Accepted),
            accepted,
            "{text}"
        );
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

pub(crate) fn recursive_ref(name: &str) -> TypeRef {
    let base = check_type_signatures(&library()).unwrap();
    TypeRef::new(
        base.nodes.first().unwrap().reference.source.clone(),
        name,
        vec![],
    )
}

pub(crate) fn recursive_node(name: &str, shape: TypeShape) -> TypeNode {
    TypeNode {
        reference: recursive_ref(name),
        shape,
        description: None,
        attributes: vec![],
        extensions: vec![],
    }
}

pub(crate) fn recursive_product(fields: &[(&str, &str)]) -> TypeShape {
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

pub(crate) fn recursive_graph(nodes: Vec<TypeNode>) -> SemanticGraph {
    SemanticGraph {
        profile: check_type_signatures(&library()).unwrap().profile,
        nodes,
        source_refs: vec![],
    }
}

#[test]
fn value_failures_preserve_observed_slot_kind() {
    let value = recursive_ref("Value");
    let product = recursive_ref("Product");
    let graph = recursive_graph(vec![
        recursive_node("Value", TypeShape::Never),
        recursive_node("Product", recursive_product(&[("value", "Value")])),
    ]);
    assert!(matches!(
        PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&product, &JsonValue::Obj(vec![])),
        ValueDecision::Rejected(ValueFailure {
            condition: ValueCondition::MissingRequired,
            observed: SlotValue::Absent,
            ..
        })
    ));
    assert!(matches!(
        PreparedValidator::new(&graph, FormatWorkspace::empty()).accepts_value(
            &product,
            &JsonValue::Obj(vec![("value".into(), JsonValue::Null)])
        ),
        ValueDecision::Rejected(ValueFailure {
            condition: ValueCondition::NullNotAllowed,
            observed: SlotValue::Null,
            ..
        })
    ));
    assert!(matches!(
        PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&value, &JsonValue::Bool(false)),
        ValueDecision::Rejected(ValueFailure {
            condition: ValueCondition::InvalidDataModel,
            observed: SlotValue::Present(JsonValue::Bool(false)),
            ..
        })
    ));
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
    let root = recursive_ref("Goal");
    for value in [leaf, negated, conjunction, disjunction] {
        assert_eq!(
            PreparedValidator::new(&graph, FormatWorkspace::empty()).accepts_value(&root, &value),
            ValueDecision::Accepted
        );
        let slot_1 = required_slot(&root);
        assert!(matches!(
            decide_present(&graph, &slot_1, &value),
            BorrowedValueDecision::Accepted
        ));
    }
}

#[test]
fn recursive_array_deeper_than_node_count_and_extras() {
    let graph = recursive_graph(vec![recursive_node("Array", recursive_array("Array"))]);
    let mut value = JsonValue::Arr(vec![]);
    for _ in 0..32 {
        value = JsonValue::Arr(vec![value, JsonValue::Arr(vec![])]);
    }
    let root = recursive_ref("Array");
    assert_eq!(
        PreparedValidator::new(&graph, FormatWorkspace::empty()).accepts_value(&root, &value),
        ValueDecision::Accepted
    );
    let slot_2 = required_slot(&root);
    assert!(matches!(
        decide_present(&graph, &slot_2, &value),
        BorrowedValueDecision::Accepted
    ));
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
    let root = recursive_ref("Map");
    assert_eq!(
        PreparedValidator::new(&graph, FormatWorkspace::empty()).accepts_value(&root, &value),
        ValueDecision::Accepted
    );
    let slot_3 = required_slot(&root);
    assert!(matches!(
        decide_present(&graph, &slot_3, &value),
        BorrowedValueDecision::Accepted
    ));
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
            let newest_first = trace.iter().rev().cloned().collect::<Vec<_>>();
            let (root, value, path, expected_trace) = if child {
                let mut expected = newest_first.clone();
                expected.push(recursive_ref("Parent"));
                (
                    "Parent",
                    JsonValue::Obj(vec![("child".into(), observed.clone())]),
                    vec![PathStep::Field("child".into())],
                    expected,
                )
            } else {
                ("A", observed.clone(), vec![], newest_first)
            };
            let decision = PreparedValidator::new(&graph, FormatWorkspace::empty())
                .accepts_value(&recursive_ref(root), &value);
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

#[test]
fn defaults_preserve_order_provenance_and_idempotence() {
    let graph = recursive_graph(vec![
        recursive_node(
            "Flag",
            TypeShape::Boolean(BooleanSpec {
                const_value: None,
                default_value: Some(false),
            }),
        ),
        recursive_node(
            "Alias",
            TypeShape::Alias {
                target: recursive_ref("Flag"),
                reference_text: "Flag".into(),
            },
        ),
        recursive_node("Object", recursive_product(&[("flag", "Alias")])),
        recursive_node("Array", recursive_array("Object")),
    ]);
    let before = JsonValue::Arr(vec![JsonValue::Obj(vec![])]);
    let result =
        materialize_defaults(&validator_of(&graph), &recursive_ref("Array"), &before).unwrap();
    assert_eq!(before, JsonValue::Arr(vec![JsonValue::Obj(vec![])]));
    assert_eq!(
        result.value(),
        &JsonValue::Arr(vec![JsonValue::Obj(vec![(
            "flag".into(),
            JsonValue::Bool(false)
        )])])
    );
    assert_eq!(result.applications().len(), 1);
    let Some(application) = result.applications().first() else {
        return;
    };
    assert_eq!(application.type_ref, recursive_ref("Flag"));
    assert_eq!(
        application.value_path,
        vec![PathStep::Index(0u8.into()), PathStep::Field("flag".into())]
    );
    assert_eq!(application.origin.pointer.last().unwrap(), "default");
    let second = materialize_defaults(
        &validator_of(&graph),
        &recursive_ref("Array"),
        result.value(),
    )
    .unwrap();
    assert_eq!(second.value(), result.value());
    assert!(second.applications().is_empty());
    let mut forged = result.applications().to_vec();
    let Some(application) = forged.first_mut() else {
        return;
    };
    application.value = JsonValue::Bool(true);
    assert!(!check_default_applications(
        &validator_of(&graph),
        &before,
        result.value(),
        &forged
    ));
}

#[test]
fn invalid_default_is_checked_at_resolved_primitive_root_before_product() {
    let graph = recursive_graph(vec![
        recursive_node(
            "Number",
            TypeShape::Integer(IntegerSpec {
                domain: None,
                minimum: Some(1.into()),
                maximum: None,
                const_value: None,
                enum_values: None,
                default_value: Some(0.into()),
            }),
        ),
        recursive_node(
            "Alias",
            TypeShape::Alias {
                target: recursive_ref("Number"),
                reference_text: "Number".into(),
            },
        ),
        recursive_node(
            "Object",
            recursive_product(&[("missing", "Alias"), ("required", "Alias")]),
        ),
    ]);
    let failure = materialize_defaults(
        &validator_of(&graph),
        &recursive_ref("Object"),
        &JsonValue::Obj(vec![]),
    )
    .unwrap_err();
    let DefaultFailure::Evaluation(necoherence::semantic_validation::ValidationFailure::Value(
        failure,
    )) = failure
    else {
        return;
    };
    assert_eq!(failure.type_ref, recursive_ref("Number"));
    assert_eq!(failure.value_path, vec![]);
    assert_eq!(failure.condition, ValueCondition::BelowMinimum);
}

#[test]
fn materialization_admits_reachable_meaning_before_checked_values() {
    let mut shape = recursive_product(&[("optional", "gone")]);
    let TypeShape::Product(spec) = &mut shape else {
        return;
    };
    assert_eq!(spec.fields.len(), 1);
    let Some(field) = spec.fields.first_mut() else {
        return;
    };
    field.slot.required = false;
    let graph = recursive_graph(vec![recursive_node("Root", shape)]);
    let failure = materialize_defaults(
        &validator_of(&graph),
        &recursive_ref("Root"),
        &JsonValue::Obj(vec![]),
    )
    .unwrap_err();
    let DefaultFailure::Evaluation(
        necoherence::semantic_validation::ValidationFailure::Unresolved(obligations),
    ) = failure
    else {
        return;
    };
    assert_eq!(obligations.len(), 1);
    let Some(obligation) = obligations.first() else {
        return;
    };
    assert_eq!(obligation.type_ref, recursive_ref("gone"));
    assert_eq!(obligation.value_path, vec![]);
    assert_eq!(obligation.profile, graph.profile.reference);
    assert_eq!(obligation.reason, SemanticReason::UnresolvedType);

    let text = TypeShape::String(StringSpec {
        format: Some(FormatUse::Named("missing-format".into())),
        lengths: vec![],
        wrapper: None,
        const_value: None,
        enum_values: None,
        examples: vec![],
        default_value: Some("".into()),
    });
    let graph = recursive_graph(vec![
        recursive_node("Text", text),
        recursive_node("Root", recursive_product(&[("label", "Text")])),
    ]);
    for (reference, before) in [
        (recursive_ref("Root"), JsonValue::Obj(vec![])),
        (recursive_ref("Text"), JsonValue::Str("".into())),
    ] {
        let failure = materialize_defaults(&validator_of(&graph), &reference, &before).unwrap_err();
        let DefaultFailure::Evaluation(
            necoherence::semantic_validation::ValidationFailure::Unresolved(obligations),
        ) = failure
        else {
            return;
        };
        assert_eq!(obligations.len(), 1);
        let Some(obligation) = obligations.first() else {
            return;
        };
        assert_eq!(obligation.type_ref, recursive_ref("Text"));
        assert_eq!(
            obligation.origin,
            OccurrenceRef::from(&recursive_ref("Text"))
        );
        assert_eq!(obligation.value_path, vec![]);
        assert_eq!(obligation.profile, graph.profile.reference);
        assert_eq!(
            obligation.reason,
            SemanticReason::UnknownFormat("missing-format".into())
        );
    }
}

#[test]
fn slot_validation_checks_meaning_for_absent_and_null_values() {
    let graph = recursive_graph(vec![recursive_node(
        "Opaque",
        TypeShape::Opaque {
            type_name: "external".into(),
        },
    )]);
    let contract = SlotContract {
        type_ref: recursive_ref("Opaque"),
        required: false,
        nullable: true,
    };
    for value in [SlotValue::Absent, SlotValue::Null] {
        assert!(matches!(
            PreparedValidator::new(&graph, FormatWorkspace::empty()).accepts_slot(&contract, value),
            ValueDecision::Unresolved(ref obligations)
                if matches!(obligations.as_slice(), [obligation]
                    if obligation.reason == SemanticReason::OpaqueType("external".into()))
        ));
    }
}

#[test]
fn sealed_leaf_samples_match_lean() -> std::result::Result<(), Box<dyn std::error::Error>> {
    use serde_json::{json, Value};
    let vectors: Value = serde_json::from_str(include_str!(
        "../../../../verification/declaration/sealed_leaf_sample_vectors.json"
    ))?;
    assert_eq!(
        vectors.get("schema"),
        Some(&json!("sealed-leaf-sample-vectors@1"))
    );
    let profile = vectors.get("profile").ok_or("missing profile")?;
    let cases = vectors
        .get("cases")
        .and_then(Value::as_array)
        .ok_or("missing cases")?;
    assert_eq!(cases.len(), 7);
    for case in cases {
        let case_id = case.get("id").and_then(Value::as_str).ok_or("case id")?;
        let library = decode_type_signatures(
            &json!({
                "schema": "ncoh-type-signatures@1",
                "identity": "sealed-leaf-samples",
                "revision": "1",
                "profile": profile,
                "sources": [],
                "provenance": [],
                "groups": [],
                "annotations": [],
                "nodes": [{"id": "value", "shape": case.get("sealed").ok_or("missing sealed")?}],
                "definitions": []
            })
            .to_string(),
        )?;
        let graph = check_type_signatures(&library)?;
        let slot = SlotContract {
            type_ref: signature_type_ref("value"),
            required: true,
            nullable: false,
        };
        let samples = slot_samples(&graph, &SearchBounds::default(), &slot);
        let mut actual = Vec::new();
        for sample in samples.values {
            let SlotValue::Present(value) = sample else {
                return Err(format!("{case_id}: {sample:?}").into());
            };
            assert!(
                matches!(
                    PreparedValidator::new(&graph, FormatWorkspace::empty())
                        .accepts_value(&slot.type_ref, &value),
                    ValueDecision::Accepted
                ),
                "{case_id}"
            );
            actual.push(serde_json::to_value(&value)?);
        }
        assert_eq!(
            Value::Array(actual),
            case.get("expected").cloned().ok_or("missing expected")?,
            "{case_id}"
        );
    }
    Ok(())
}

fn boolean_node(name: &str) -> TypeNode {
    recursive_node(
        name,
        TypeShape::Boolean(BooleanSpec {
            const_value: None,
            default_value: None,
        }),
    )
}

#[test]
fn required_absent_slot_reports_missing_required_with_absent_observation() {
    let graph = recursive_graph(vec![boolean_node("B")]);
    let slot = SlotContract {
        type_ref: recursive_ref("B"),
        required: true,
        nullable: false,
    };
    let ValueDecision::Rejected(failure) = PreparedValidator::new(&graph, FormatWorkspace::empty())
        .accepts_slot(&slot, SlotValue::Absent)
    else {
        panic!("required absent slot is accepted");
    };
    assert_eq!(failure.condition, ValueCondition::MissingRequired);
    assert_eq!(failure.observed, SlotValue::Absent);
    assert!(failure.value_path.is_empty());
    assert!(failure.reference_trace.is_empty());
    assert_eq!(failure.type_ref, recursive_ref("B"));
}

#[test]
fn non_nullable_null_slot_reports_null_not_allowed_with_null_observation() {
    let graph = recursive_graph(vec![boolean_node("B")]);
    let slot = SlotContract {
        type_ref: recursive_ref("B"),
        required: true,
        nullable: false,
    };
    let ValueDecision::Rejected(failure) = PreparedValidator::new(&graph, FormatWorkspace::empty())
        .accepts_slot(&slot, SlotValue::Null)
    else {
        panic!("null in a non-nullable slot is accepted");
    };
    assert_eq!(failure.condition, ValueCondition::NullNotAllowed);
    assert_eq!(failure.observed, SlotValue::Null);
    assert!(failure.value_path.is_empty());
    assert!(failure.reference_trace.is_empty());
}

#[test]
fn product_missing_required_field_reports_field_path_with_present_null() {
    let graph = recursive_graph(vec![
        recursive_node("P", recursive_product(&[("a", "B")])),
        boolean_node("B"),
    ]);
    let ValueDecision::Rejected(failure) = PreparedValidator::new(&graph, FormatWorkspace::empty())
        .accepts_value(&recursive_ref("P"), &JsonValue::Obj(vec![]))
    else {
        panic!("product with a missing required field is accepted");
    };
    assert_eq!(failure.condition, ValueCondition::MissingRequired);
    assert_eq!(failure.observed, SlotValue::Absent);
    assert_eq!(failure.value_path, vec![PathStep::Field("a".into())]);
    assert_eq!(failure.type_ref, recursive_ref("B"));
    assert!(failure.reference_trace.is_empty());
}

#[test]
fn borrowed_recipe_materializes_the_same_owned_failure() {
    let graph = recursive_graph(vec![recursive_node(
        "A",
        TypeShape::Alias {
            target: recursive_ref("A"),
            reference_text: "loop".into(),
        },
    )]);
    let value = goal_value("loop", None);
    let root = recursive_ref("A");
    let slot_4 = required_slot(&root);
    let BorrowedValueDecision::Rejected(recipe) = decide_present(&graph, &slot_4, &value) else {
        panic!("self alias is not rejected by the borrowed decision");
    };
    let owned =
        PreparedValidator::new(&graph, FormatWorkspace::empty()).accepts_value(&root, &value);
    assert_eq!(recipe.materialize(), owned);
    assert_eq!(recipe.materialize(), owned);
    let ValueDecision::Rejected(failure) = owned else {
        panic!("self alias is accepted by the owned decision");
    };
    assert_eq!(failure.condition, ValueCondition::ReferenceCycle);
    assert_eq!(failure.reference_trace, vec![recursive_ref("A")]);
    assert!(failure.value_path.is_empty());
}

#[test]
fn raw_object_failure_adds_path_steps_without_trace_types() {
    let graph = recursive_graph(vec![recursive_node(
        "U",
        TypeShape::Unknown(UnknownKind::Any),
    )]);
    let value = JsonValue::Obj(vec![(
        "a".into(),
        JsonValue::Obj(vec![
            ("k".into(), JsonValue::Null),
            ("k".into(), JsonValue::Null),
        ]),
    )]);
    let root = recursive_ref("U");
    let slot_5 = required_slot(&root);
    let BorrowedValueDecision::Rejected(recipe) = decide_present(&graph, &slot_5, &value) else {
        panic!("duplicate raw member is accepted");
    };
    let ValueDecision::Rejected(failure) = recipe.materialize() else {
        panic!("materialized raw failure is accepted");
    };
    assert_eq!(
        failure.condition,
        ValueCondition::DuplicateField("k".into())
    );
    assert_eq!(failure.value_path, vec![PathStep::Field("a".into())]);
    assert!(failure.reference_trace.is_empty());
    assert_eq!(
        recipe.materialize(),
        ValueDecision::Rejected(failure.clone())
    );

    let wrapped = JsonValue::Arr(vec![value]);
    let slot_6 = required_slot(&root);
    let BorrowedValueDecision::Rejected(recipe) = decide_present(&graph, &slot_6, &wrapped) else {
        panic!("duplicate raw member inside a raw array is accepted");
    };
    let owned =
        PreparedValidator::new(&graph, FormatWorkspace::empty()).accepts_value(&root, &wrapped);
    assert_eq!(recipe.materialize(), owned);
    let ValueDecision::Rejected(failure) = owned else {
        panic!("materialized raw array failure is accepted");
    };
    assert_eq!(
        failure.condition,
        ValueCondition::DuplicateField("k".into())
    );
    assert_eq!(
        failure.value_path,
        vec![
            PathStep::Index(BigUint::from(0u8)),
            PathStep::Field("a".into())
        ]
    );
    assert!(failure.reference_trace.is_empty());
}

#[test]
fn unresolved_type_recipe_materializes_the_obligation() {
    let graph = recursive_graph(vec![boolean_node("B")]);
    let missing = recursive_ref("Missing");
    let value = JsonValue::Bool(true);
    let slot_7 = required_slot(&missing);
    let BorrowedValueDecision::Unresolved(recipe) = decide_present(&graph, &slot_7, &value) else {
        panic!("missing type is not unresolved");
    };
    let owned = PreparedValidator::new(&graph, FormatWorkspace::empty())
        .accepts_value(&missing, &JsonValue::Bool(true));
    assert_eq!(recipe.materialize(), owned);
    let ValueDecision::Unresolved(obligations) = owned else {
        panic!("missing type is not unresolved in the owned decision");
    };
    assert_eq!(obligations.len(), 1);
    assert_eq!(obligations[0].reason, SemanticReason::UnresolvedType);
    assert!(obligations[0].value_path.is_empty());
}

#[test]
fn unresolved_field_of_virtual_product_materializes_the_obligation() {
    let graph = recursive_graph(vec![recursive_node(
        "P",
        recursive_product(&[("a", "Missing")]),
    )]);
    let product = recursive_ref("P");
    let missing = recursive_ref("Missing");
    let payload = JsonValue::Bool(true);
    let fields = [("a", SlotValue::Present(JsonValueView::from_json(&payload)))];
    let slot_8 = required_slot(&product);
    let BorrowedValueDecision::Unresolved(recipe) =
        decide_present_view(&graph, &slot_8, JsonValueView::object(&fields))
    else {
        panic!("unresolved field is not unresolved");
    };
    let owned_input = JsonValue::Obj(vec![("a".into(), payload.clone())]);
    let owned = PreparedValidator::new(&graph, FormatWorkspace::empty())
        .accepts_value(&product, &owned_input);
    let expected = ValueDecision::Unresolved(vec![SemanticObligation {
        type_ref: missing.clone(),
        origin: (&missing).into(),
        value_path: vec![],
        profile: graph.profile.reference.clone(),
        reason: SemanticReason::UnresolvedType,
    }]);
    let classified = recipe.materialize();
    assert_eq!(
        classified,
        PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&product, &owned_input)
    );
    let ValueDecision::Unresolved(reasons) = classified else {
        panic!("missing meaning")
    };
    assert_eq!(
        reasons,
        meaning_obligations(&graph, std::slice::from_ref(&product))
    );
    assert_eq!(owned, expected);
}

#[test]
fn prepared_meaning_obligations_equal_graph_meaning_obligations() {
    let graph = recursive_graph(vec![
        boolean_node("B"),
        recursive_node("P", recursive_product(&[("a", "Missing")])),
    ]);
    let validator = validator_of(&graph);
    let defined = recursive_ref("B");
    let unresolved = recursive_ref("P");
    let absent = recursive_ref("Absent");
    let cases = [
        vec![defined.clone()],
        vec![unresolved.clone()],
        vec![absent.clone()],
        vec![defined, unresolved, absent],
        vec![],
    ];
    for roots in &cases {
        let expected = meaning_obligations(&graph, roots);
        assert_eq!(validator.metadata().meaning_obligations(roots), expected);
        assert_eq!(validator.meaning_obligations(roots), expected);
    }
    assert!(meaning_obligations(&graph, &cases[0]).is_empty());
    assert!(!meaning_obligations(&graph, &cases[1]).is_empty());
    assert!(!meaning_obligations(&graph, &cases[2]).is_empty());
}

#[test]
fn accepted_value_has_no_recipe_and_absent_slot_recipe_materializes() {
    let graph = recursive_graph(vec![boolean_node("B")]);
    let slot_9 = required_slot(&recursive_ref("B"));
    assert!(matches!(
        decide_present(&graph, &slot_9, &JsonValue::Bool(true)),
        BorrowedValueDecision::Accepted
    ));
    let slot = SlotContract {
        type_ref: recursive_ref("B"),
        required: true,
        nullable: false,
    };
    let BorrowedValueDecision::Rejected(recipe) =
        decide_slot_value(&graph, &slot, SlotValue::Absent)
    else {
        panic!("required absent slot is accepted by the borrowed decision");
    };
    assert_eq!(
        recipe.materialize(),
        PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_slot(&slot, SlotValue::Absent)
    );

    let nullable = SlotContract {
        type_ref: recursive_ref("B"),
        required: true,
        nullable: true,
    };
    assert!(matches!(
        decide_slot_value(&graph, &nullable, SlotValue::Null),
        BorrowedValueDecision::Accepted
    ));
    let optional = SlotContract {
        type_ref: recursive_ref("B"),
        required: false,
        nullable: true,
    };
    assert!(matches!(
        decide_slot_value(&graph, &optional, SlotValue::Absent),
        BorrowedValueDecision::Accepted
    ));
    let flag = JsonValue::Bool(true);
    assert!(matches!(
        decide_slot_value(&graph, &slot, SlotValue::Present(&flag)),
        BorrowedValueDecision::Accepted
    ));
}

pub(crate) fn v2a_library() -> TypeSignatureLibrary {
    let mut library = library();
    library.profile.wrappers.push(Wrapper {
        name: "bytes".into(),
        key: "$bytes".into(),
        payload: WrapperPayload::Bytes,
    });
    library.profile.bytes_policy = Some(BytesPolicy {
        reference: library.profile.reference.clone(),
        padding_optional: true,
        alphabet: BytesAlphabet::Either,
        strict_pad_bits: true,
        wrapper: Some("bytes".into()),
    });
    library.nodes = vec![
        TypeNodeInput {
            id: "plain".into(),
            shape: Shape::String(StringSpec {
                format: None,
                lengths: vec![],
                wrapper: None,
                const_value: None,
                enum_values: None,
                examples: vec![],
                default_value: None,
            }),
        },
        TypeNodeInput {
            id: "konst".into(),
            shape: Shape::String(StringSpec {
                format: None,
                lengths: vec![],
                wrapper: None,
                const_value: Some("k".into()),
                enum_values: None,
                examples: vec![],
                default_value: None,
            }),
        },
        TypeNodeInput {
            id: "flag".into(),
            shape: Shape::Boolean(BooleanSpec {
                const_value: None,
                default_value: None,
            }),
        },
        TypeNodeInput {
            id: "sealed".into(),
            shape: Shape::Sealed {
                tag: "sealed".into(),
                refinements: vec![],
            },
        },
        TypeNodeInput {
            id: "wrapped".into(),
            shape: Shape::String(StringSpec {
                format: None,
                lengths: vec![],
                wrapper: Some("wrapped".into()),
                const_value: None,
                enum_values: None,
                examples: vec![],
                default_value: None,
            }),
        },
        TypeNodeInput {
            id: "bytes".into(),
            shape: Shape::Bytes(LengthSpec {
                minimum: None,
                maximum: None,
            }),
        },
    ];
    library.definitions = vec![];
    library
}

pub(crate) fn v2a_reference(graph: &SemanticGraph, name: &str) -> TypeRef {
    graph
        .nodes
        .iter()
        .find(|node| &*node.reference.definition_name == name)
        .map(|node| node.reference.clone())
        .expect("fixture node exists")
}

#[test]
fn borrowed_paths_without_format_or_codec_keep_their_conditions() {
    let graph = check_type_signatures(&v2a_library()).unwrap();
    let plain = v2a_reference(&graph, "plain");
    let konst = v2a_reference(&graph, "konst");
    let flag = v2a_reference(&graph, "flag");
    let sealed = v2a_reference(&graph, "sealed");
    let text = JsonValue::Str("abc".into());
    let mismatch = JsonValue::Str("x".into());
    let boolean_expected = JsonValue::Str("x".into());
    let duplicate = JsonValue::Obj(vec![
        ("kind".into(), JsonValue::Str("sealed".into())),
        ("name".into(), JsonValue::Str("a".into())),
        ("name".into(), JsonValue::Str("b".into())),
    ]);

    let slot_10 = required_slot(&plain);
    let accepted = decide_present(&graph, &slot_10, &text);
    let slot_11 = required_slot(&konst);
    let konst_decision = decide_present(&graph, &slot_11, &mismatch);
    let slot_12 = required_slot(&flag);
    let kind_decision = decide_present(&graph, &slot_12, &boolean_expected);
    let slot_13 = required_slot(&sealed);
    let dup_decision = decide_present(&graph, &slot_13, &duplicate);
    let slot = SlotContract {
        type_ref: flag.clone(),
        required: true,
        nullable: false,
    };
    let slot_decision = decide_slot_value(&graph, &slot, SlotValue::Absent);

    assert!(matches!(accepted, BorrowedValueDecision::Accepted));
    assert!(matches!(konst_decision, BorrowedValueDecision::Rejected(_)));
    assert!(matches!(kind_decision, BorrowedValueDecision::Rejected(_)));
    assert!(matches!(dup_decision, BorrowedValueDecision::Rejected(_)));
    assert!(matches!(slot_decision, BorrowedValueDecision::Rejected(_)));

    for (decision, expected) in [
        (konst_decision, ValueCondition::ConstMismatch),
        (
            kind_decision,
            ValueCondition::WrongValueKind("boolean".into()),
        ),
        (dup_decision, ValueCondition::DuplicateField("name".into())),
        (slot_decision, ValueCondition::MissingRequired),
    ] {
        let BorrowedValueDecision::Rejected(recipe) = decision else {
            panic!("expected a rejected decision")
        };
        let ValueDecision::Rejected(failure) = recipe.materialize() else {
            panic!("expected an owned rejection")
        };
        assert_eq!(failure.condition, expected);
    }
}

fn format_dfa_fixture() -> FormatRule {
    let base = BigUint::from(1u8) << 64usize;
    let initial = &base + BigUint::from(7u8);
    let accept = &base * BigUint::from(2u8) + BigUint::from(7u8);
    let other = &base * BigUint::from(3u8) + BigUint::from(7u8);
    FormatRule::AsciiDfa(DfaSpec {
        state_count: &base * BigUint::from(4u8),
        initial_state: initial.clone(),
        accepting_states: vec![accept.clone()],
        transitions: vec![
            DfaTransition {
                from_state: initial.clone(),
                first: BigUint::from(b'a'),
                last: BigUint::from(b'a'),
                to_state: accept,
            },
            DfaTransition {
                from_state: initial,
                first: BigUint::from(b'a'),
                last: BigUint::from(b'a'),
                to_state: other,
            },
        ],
    })
}

fn format_sequence_text_literal(n: usize) -> (FormatRule, String) {
    (
        FormatRule::Sequence(vec![FormatRule::Text, FormatRule::Literal("a".into())]),
        "é".repeat(n - 1) + "a",
    )
}

pub(crate) fn format_cases() -> Vec<(&'static str, FormatRule, String, bool)> {
    let identifier = FormatRule::Identifier {
        first_alphabet: "aé".into(),
        rest_alphabet: "aé".into(),
        exact_length: Some(BigUint::from(2u8)),
        min_length: BigUint::from(0u8),
        max_length: None,
        forbidden: vec![],
    };
    let (sequence_8, text_8) = format_sequence_text_literal(8);
    let (sequence_64, text_64) = format_sequence_text_literal(64);
    let tag = FormatRule::LanguageTag {
        grandfathered: vec![],
    };
    vec![
        ("dfa-a-accept", format_dfa_fixture(), "a".into(), true),
        ("dfa-empty-reject", format_dfa_fixture(), "".into(), false),
        ("identifier-two", identifier.clone(), "éa".into(), false),
        ("identifier-one", identifier, "é".into(), false),
        (
            "labels-empty-separator",
            FormatRule::Labels {
                separator: String::new(),
                min_count: BigUint::from(0u8),
                max_count: None,
                total_max: None,
                rule: Box::new(FormatRule::Text),
            },
            "a".into(),
            false,
        ),
        (
            "langtag-case-duplicate",
            tag.clone(),
            "sl-abcdefgh-bcdefghi-ABCDEFGH".into(),
            false,
        ),
        (
            "langtag-distinct",
            tag,
            "sl-abcdefgh-bcdefghi-abcdefgi".into(),
            true,
        ),
        (
            "sequence-literal-unicode",
            FormatRule::Sequence(vec![
                FormatRule::Literal("é".into()),
                FormatRule::Literal("a".into()),
            ]),
            "éa".into(),
            true,
        ),
        ("sequence-text-literal-n8", sequence_8, text_8, true),
        ("sequence-text-literal-n64", sequence_64, text_64, true),
        (
            "timestamp-leap-day",
            FormatRule::Timestamp(CalendarRule {
                allow_second_60: false,
                minimum_year: BigUint::from(1u16),
                maximum_year: BigUint::from(9999u16),
                reject_utc_year_outside_range: false,
            }),
            "2024-02-29T12:34:56Z".into(),
            true,
        ),
        (
            "absolute-uri-https",
            FormatRule::AbsoluteUri { max_bytes: None },
            "https://example.com/path".into(),
            true,
        ),
    ]
}

#[test]
fn format_cases_match_expectations_on_raw_and_prepared_for_each_budget() {
    for (label, rule, text, expected) in format_cases() {
        assert_eq!(
            recognize_format(&rule, None, &text),
            expected,
            "raw {label}"
        );
        let prepared = prepare_format(&rule, None);
        for budget in [0usize, 4, 256, 4096] {
            let mut workspace = FormatWorkspace::try_new(budget).expect("reservation");
            assert_eq!(
                recognize_prepared_format(&prepared, &text, &mut workspace),
                expected,
                "prepared {label} budget {budget}"
            );
        }
    }
}

#[test]
fn same_workspace_does_not_leak_memo_between_inputs() {
    let rule = FormatRule::Literal("ab".into());
    let prepared = prepare_format(&rule, None);
    let mut workspace = FormatWorkspace::try_new(1).expect("reservation");
    assert!(!recognize_prepared_format(&prepared, "cd", &mut workspace));
    assert!(recognize_prepared_format(&prepared, "ab", &mut workspace));
    assert!(!recognize_prepared_format(&prepared, "cd", &mut workspace));
}

pub(crate) fn v3_product_library() -> TypeSignatureLibrary {
    let mut library = v2a_library();
    library.nodes.push(TypeNodeInput {
        id: "product".into(),
        shape: Shape::Product(SignatureProduct {
            fields: vec![
                SignatureField {
                    wire_name: "payload".into(),
                    slot: SignatureSlot {
                        type_id: "plain".into(),
                        required: true,
                        nullable: false,
                    },
                },
                SignatureField {
                    wire_name: "omitted".into(),
                    slot: SignatureSlot {
                        type_id: "flag".into(),
                        required: false,
                        nullable: false,
                    },
                },
                SignatureField {
                    wire_name: "nullable".into(),
                    slot: SignatureSlot {
                        type_id: "flag".into(),
                        required: true,
                        nullable: true,
                    },
                },
            ],
            extras: SignatureExtraMembers::Reject,
        }),
    });
    library
}

fn expected_rejection(
    type_ref: &TypeRef,
    condition: ValueCondition,
    observed: SlotValue,
    path: ValuePath,
    trace: Vec<TypeRef>,
) -> ValueDecision {
    ValueDecision::Rejected(ValueFailure {
        type_ref: type_ref.clone(),
        definition_ref: DefinitionRef {
            source: type_ref.source.clone(),
            name: type_ref.definition_name.clone(),
        },
        origin: type_ref.into(),
        value_path: path,
        condition,
        observed,
        reference_trace: trace,
    })
}

#[test]
fn owned_product_decisions_preserve_metadata() {
    let graph = check_type_signatures(&v3_product_library()).unwrap();
    let product = v2a_reference(&graph, "product");
    let plain = v2a_reference(&graph, "plain");
    let dynamic = "dyn".to_owned();
    let accepted = JsonValue::Obj(vec![
        ("payload".into(), JsonValue::Str(dynamic.clone())),
        ("nullable".into(), JsonValue::Null),
    ]);
    let duplicate = JsonValue::Obj(vec![
        ("payload".into(), JsonValue::Str("a".into())),
        ("payload".into(), JsonValue::Str(dynamic)),
    ]);
    let missing = JsonValue::Obj(vec![("nullable".into(), JsonValue::Null)]);

    assert_eq!(
        PreparedValidator::new(&graph, FormatWorkspace::empty()).accepts_value(&product, &accepted),
        ValueDecision::Accepted
    );
    assert_eq!(
        PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&product, &duplicate),
        expected_rejection(
            &product,
            ValueCondition::DuplicateField("payload".into()),
            SlotValue::Present(duplicate.clone()),
            vec![],
            vec![],
        )
    );
    assert_eq!(
        PreparedValidator::new(&graph, FormatWorkspace::empty()).accepts_value(&product, &missing),
        expected_rejection(
            &plain,
            ValueCondition::MissingRequired,
            SlotValue::Absent,
            vec![PathStep::Field("payload".into())],
            vec![],
        )
    );
}

#[test]
fn virtual_product_view_matches_owned_expectations() {
    let graph = check_type_signatures(&v3_product_library()).unwrap();
    let product = v2a_reference(&graph, "product");
    let plain = v2a_reference(&graph, "plain");
    let payload = JsonValue::Str("dyn".into());
    let other = JsonValue::Str("a".into());
    let null = JsonValue::Null;
    let accepted_fields = [
        (
            "payload",
            SlotValue::Present(JsonValueView::from_json(&payload)),
        ),
        ("omitted", SlotValue::Absent),
        (
            "nullable",
            SlotValue::Present(JsonValueView::from_json(&null)),
        ),
    ];
    let duplicate_fields = [
        (
            "payload",
            SlotValue::Present(JsonValueView::from_json(&other)),
        ),
        (
            "payload",
            SlotValue::Present(JsonValueView::from_json(&payload)),
        ),
    ];
    let missing_fields = [
        ("payload", SlotValue::Absent),
        ("omitted", SlotValue::Absent),
        (
            "nullable",
            SlotValue::Present(JsonValueView::from_json(&null)),
        ),
    ];
    let accepted = JsonValueView::object(&accepted_fields);
    let slot_14 = required_slot(&product);
    assert!(matches!(
        decide_present_view(&graph, &slot_14, accepted),
        BorrowedValueDecision::Accepted
    ));

    let duplicate_owned = JsonValue::Obj(vec![
        ("payload".into(), other.clone()),
        ("payload".into(), payload.clone()),
    ]);
    let slot_15 = required_slot(&product);
    let BorrowedValueDecision::Rejected(recipe) =
        decide_present_view(&graph, &slot_15, JsonValueView::object(&duplicate_fields))
    else {
        panic!("duplicate must be rejected")
    };
    let duplicate_expected = expected_rejection(
        &product,
        ValueCondition::DuplicateField("payload".into()),
        SlotValue::Present(duplicate_owned.clone()),
        vec![],
        vec![],
    );
    assert_eq!(recipe.materialize(), duplicate_expected);
    assert_eq!(
        PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&product, &duplicate_owned),
        duplicate_expected
    );

    let missing_owned = JsonValue::Obj(vec![("nullable".into(), JsonValue::Null)]);
    let slot_16 = required_slot(&product);
    let BorrowedValueDecision::Rejected(recipe) =
        decide_present_view(&graph, &slot_16, JsonValueView::object(&missing_fields))
    else {
        panic!("missing must be rejected")
    };
    let missing_expected = expected_rejection(
        &plain,
        ValueCondition::MissingRequired,
        SlotValue::Absent,
        vec![PathStep::Field("payload".into())],
        vec![],
    );
    assert_eq!(recipe.materialize(), missing_expected);
    assert_eq!(
        PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&product, &missing_owned),
        missing_expected
    );
}

#[test]
fn decimal_string_integers_follow_the_lean_decimal_integer_contract() {
    let mut library = library();
    library.nodes.push(TypeNodeInput {
        id: "bounded".into(),
        shape: Shape::Integer(IntegerSpec {
            domain: Some("integer".into()),
            minimum: None,
            maximum: None,
            const_value: None,
            enum_values: None,
            default_value: None,
        }),
    });
    let graph = check_type_signatures(&library).unwrap();
    let bounded = signature_type_ref("bounded");
    let text = |value: &str| {
        PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&bounded, &JsonValue::Str(value.into()))
    };
    assert!(matches!(text("5"), ValueDecision::Accepted));
    assert!(matches!(text("1.0e1"), ValueDecision::Accepted));
    assert!(matches!(
        text("1.5e1"),
        ValueDecision::Rejected(ValueFailure {
            condition: ValueCondition::IntegerDomain,
            ..
        })
    ));
    for invalid in ["+5", "05", " 5", "5 ", "1.5e0"] {
        assert!(
            matches!(
                text(invalid),
                ValueDecision::Rejected(ValueFailure {
                    condition: ValueCondition::WrongValueKind(_),
                    ..
                })
            ),
            "{invalid}"
        );
    }
}

#[test]
fn typed_decimal_rejects_a_leading_plus_as_invalid_data_model() {
    let mut library = library();
    library.nodes.push(TypeNodeInput {
        id: "plain-decimal".into(),
        shape: Shape::Decimal(DecimalSpec {
            minimum: None,
            maximum: None,
        }),
    });
    let graph = check_type_signatures(&library).unwrap();
    let decimal = signature_type_ref("plain-decimal");
    assert!(matches!(
        PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&decimal, &JsonValue::Dec("1.5".into())),
        ValueDecision::Accepted
    ));
    assert!(matches!(
        PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&decimal, &JsonValue::Dec(" 1.5 ".into())),
        ValueDecision::Accepted
    ));
    assert!(matches!(
        PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&decimal, &JsonValue::Dec("+1.5".into())),
        ValueDecision::Rejected(ValueFailure {
            condition: ValueCondition::InvalidDataModel,
            ..
        })
    ));
}

#[test]
fn typed_decimal_bounds_at_an_equal_value_follow_the_lean_order() {
    let mut library = library();
    let bound = |exclusive| {
        Some(DecimalBound {
            mantissa: BigInt::from(1),
            scale: BigUint::from(0u8),
            exclusive,
        })
    };
    let cases = [
        (bound(false), bound(false), None),
        (
            bound(false),
            bound(true),
            Some(ValueCondition::AboveMaximum),
        ),
        (
            bound(true),
            bound(false),
            Some(ValueCondition::BelowMinimum),
        ),
        (bound(true), bound(true), Some(ValueCondition::BelowMinimum)),
    ];
    let mut ids = Vec::new();
    for (index, (minimum, maximum, _)) in cases.iter().enumerate() {
        let id = format!("bounded-decimal-{index}");
        library.nodes.push(TypeNodeInput {
            id: id.clone(),
            shape: Shape::Decimal(DecimalSpec {
                minimum: minimum.clone(),
                maximum: maximum.clone(),
            }),
        });
        ids.push(id);
    }
    let graph = check_type_signatures(&library).unwrap();
    for (id, (_, _, expected)) in ids.iter().zip(cases.iter()) {
        let node = signature_type_ref(id);
        let actual = PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&node, &JsonValue::Dec("1".into()));
        match expected {
            None => assert!(matches!(actual, ValueDecision::Accepted), "{id}"),
            Some(condition) => assert!(
                matches!(&actual, ValueDecision::Rejected(failure) if &failure.condition == condition),
                "{id}"
            ),
        }
    }
}

#[test]
fn data_numbers_without_number_or_integral_forms_follow_the_lean_data_contract() {
    let mut library = library();
    library.nodes.push(TypeNodeInput {
        id: "any".into(),
        shape: Shape::Unknown(UnknownKind::Any),
    });
    fixture_item_mut(&mut library.profile.integer_domains, 0).forms =
        vec![IntegerForm::DecimalString];
    for decimals in [true, false] {
        library.profile.numbers.decimals = decimals;
        let graph = check_type_signatures(&library).unwrap();
        let any = signature_type_ref("any");
        assert!(matches!(
            PreparedValidator::new(&graph, FormatWorkspace::empty())
                .accepts_value(&any, &JsonValue::Num(BigInt::from(1))),
            ValueDecision::Rejected(ValueFailure {
                condition: ValueCondition::IntegerDomain,
                ..
            })
        ));
        for text in ["1.5", " 1.5 "] {
            let actual = PreparedValidator::new(&graph, FormatWorkspace::empty())
                .accepts_value(&any, &JsonValue::Dec(text.into()));
            if decimals {
                assert!(matches!(actual, ValueDecision::Accepted), "{text}");
            } else {
                assert!(
                    matches!(
                        actual,
                        ValueDecision::Rejected(ValueFailure {
                            condition: ValueCondition::InvalidDataModel,
                            ..
                        })
                    ),
                    "{text}"
                );
            }
        }
    }
}

#[test]
fn typed_decimal_exponent_limit_is_invalid_data_in_both_signs() {
    let mut library = library();
    library.nodes.push(TypeNodeInput {
        id: "decimal-max-zero".into(),
        shape: Shape::Decimal(DecimalSpec {
            minimum: None,
            maximum: Some(DecimalBound {
                mantissa: BigInt::from(0),
                scale: BigUint::from(0u8),
                exclusive: false,
            }),
        }),
    });
    library.nodes.push(TypeNodeInput {
        id: "decimal-min-one".into(),
        shape: Shape::Decimal(DecimalSpec {
            minimum: Some(DecimalBound {
                mantissa: BigInt::from(1),
                scale: BigUint::from(0u8),
                exclusive: false,
            }),
            maximum: None,
        }),
    });
    let graph = check_type_signatures(&library).unwrap();
    let max_zero = signature_type_ref("decimal-max-zero");
    let min_one = signature_type_ref("decimal-min-one");
    for text in [
        "1e10000",
        "1E+10000",
        "0e10000",
        "1e-10000",
        "1e5000000000",
        "1e-99999999999999999999",
    ] {
        for reference in [&max_zero, &min_one] {
            assert!(
                matches!(
                    PreparedValidator::new(&graph, FormatWorkspace::empty())
                        .accepts_value(reference, &JsonValue::Dec(text.into())),
                    ValueDecision::Rejected(ValueFailure {
                        condition: ValueCondition::InvalidDataModel,
                        ..
                    })
                ),
                "{text}"
            );
        }
    }
    assert!(matches!(
        PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&max_zero, &JsonValue::Dec("1e9999".into())),
        ValueDecision::Rejected(ValueFailure {
            condition: ValueCondition::AboveMaximum,
            ..
        })
    ));
    assert!(matches!(
        PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&min_one, &JsonValue::Dec("1e-9999".into())),
        ValueDecision::Rejected(ValueFailure {
            condition: ValueCondition::BelowMinimum,
            ..
        })
    ));
    assert!(matches!(
        PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&max_zero, &JsonValue::Dec("0".into())),
        ValueDecision::Accepted
    ));
    assert!(matches!(
        PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&min_one, &JsonValue::Dec("1".into())),
        ValueDecision::Accepted
    ));
}

#[test]
fn typed_integer_sign_and_exponent_limit_follow_the_guard_order() {
    let mut library = library();
    library.nodes.push(TypeNodeInput {
        id: "bounded".into(),
        shape: Shape::Integer(IntegerSpec {
            domain: Some("integer".into()),
            minimum: None,
            maximum: None,
            const_value: None,
            enum_values: None,
            default_value: None,
        }),
    });
    let graph = check_type_signatures(&library).unwrap();
    let bounded = signature_type_ref("bounded");
    let text = |value: String| {
        PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&bounded, &JsonValue::Str(value))
    };
    assert!(matches!(
        text("1e-99999999999999999999".into()),
        ValueDecision::Rejected(ValueFailure {
            condition: ValueCondition::WrongValueKind(_),
            ..
        })
    ));
    assert!(matches!(
        text("0e10000".into()),
        ValueDecision::Rejected(ValueFailure {
            condition: ValueCondition::WrongValueKind(_),
            ..
        })
    ));
    assert!(matches!(
        text("1e10000".into()),
        ValueDecision::Rejected(ValueFailure {
            condition: ValueCondition::IntegerDomain,
            ..
        })
    ));
}

#[test]
fn integral_decimal_exponent_limit_is_the_lean_integer_boundary() {
    let mut library = library();
    fixture_item_mut(&mut library.profile.integer_domains, 0)
        .forms
        .push(IntegerForm::IntegralDecimal);
    let graph = check_type_signatures(&library).unwrap();
    let profile = &graph.profile;
    assert!(integer_decode(profile, None, JsonValue::Dec("1e9999".into())).is_ok());
    assert!(integer_decode(profile, None, JsonValue::Dec("1e10000".into())).is_err());
    assert!(integer_decode(profile, None, JsonValue::Dec("1e1000000000".into())).is_err());
}

#[test]
fn unbounded_integral_decimal_data_follows_the_exponent_limit() {
    let mut library = library();
    library.nodes.push(TypeNodeInput {
        id: "any".into(),
        shape: Shape::Unknown(UnknownKind::Any),
    });
    let binding = fixture_item_mut(&mut library.profile.integer_domains, 0);
    binding.range = IntegerDomain::Unbounded;
    binding.forms.push(IntegerForm::IntegralDecimal);
    let graph = check_type_signatures(&library).unwrap();
    let any = signature_type_ref("any");
    assert!(matches!(
        PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&any, &JsonValue::Dec("1e9999".into())),
        ValueDecision::Accepted
    ));
    assert!(matches!(
        PreparedValidator::new(&graph, FormatWorkspace::empty())
            .accepts_value(&any, &JsonValue::Dec("1e10000".into())),
        ValueDecision::Rejected(ValueFailure {
            condition: ValueCondition::InvalidDataModel,
            ..
        })
    ));
}

fn decimal_free_and_unit_graph() -> SemanticGraph {
    let mut library = library();
    library.nodes.push(TypeNodeInput {
        id: "decimal-free".into(),
        shape: Shape::Decimal(DecimalSpec {
            minimum: None,
            maximum: None,
        }),
    });
    library.nodes.push(TypeNodeInput {
        id: "decimal-unit".into(),
        shape: Shape::Decimal(DecimalSpec {
            minimum: Some(DecimalBound {
                mantissa: BigInt::from(0),
                scale: BigUint::from(0u8),
                exclusive: false,
            }),
            maximum: Some(DecimalBound {
                mantissa: BigInt::from(1),
                scale: BigUint::from(0u8),
                exclusive: false,
            }),
        }),
    });
    check_type_signatures(&library).unwrap()
}

#[test]
fn decimal_text_from_the_exchange_route_is_accepted_as_lean_decode_exact_does() {
    let graph = decimal_free_and_unit_graph();
    let free = signature_type_ref("decimal-free");
    let unit = signature_type_ref("decimal-unit");
    for text in ["0.0", "-0.0", "0e-100", "0.000e-100"] {
        let exchange = format!(r#"{{"tag":"Decimal","text":"{text}"}}"#);
        let value = decode_exact_value(&exchange).unwrap();
        assert_eq!(value, JsonValue::Dec(text.into()), "{text}");
        assert!(
            matches!(
                PreparedValidator::new(&graph, FormatWorkspace::empty())
                    .accepts_value(&free, &value),
                ValueDecision::Accepted
            ),
            "{text}"
        );
        assert!(
            matches!(
                PreparedValidator::new(&graph, FormatWorkspace::empty())
                    .accepts_value(&unit, &value),
                ValueDecision::Accepted
            ),
            "{text}"
        );
    }
    let above = decode_exact_value(r#"{"tag":"Decimal","text":"1.5"}"#).unwrap();
    assert!(matches!(
        PreparedValidator::new(&graph, FormatWorkspace::empty()).accepts_value(&unit, &above),
        ValueDecision::Rejected(ValueFailure {
            condition: ValueCondition::AboveMaximum,
            ..
        })
    ));
}

#[test]
fn raw_json_zero_decimal_is_accepted_as_decimal_text_as_lean_from_json_does() {
    let graph = decimal_free_and_unit_graph();
    let free = signature_type_ref("decimal-free");
    let unit = signature_type_ref("decimal-unit");
    for text in ["0.0", "0e-100", "0.000e-100"] {
        let value = necoherence::semantic_codegen_runtime::decode_json(text).unwrap();
        assert_eq!(value, JsonValue::Dec("0".into()), "{text}");
        assert!(
            matches!(
                PreparedValidator::new(&graph, FormatWorkspace::empty())
                    .accepts_value(&free, &value),
                ValueDecision::Accepted
            ),
            "{text}"
        );
        assert!(
            matches!(
                PreparedValidator::new(&graph, FormatWorkspace::empty())
                    .accepts_value(&unit, &value),
                ValueDecision::Accepted
            ),
            "{text}"
        );
    }
    for text in ["0", "0e11"] {
        let value = necoherence::semantic_codegen_runtime::decode_json(text).unwrap();
        assert_eq!(value, JsonValue::Num(0.into()), "{text}");
        for reference in [&free, &unit] {
            assert!(
                matches!(
                    PreparedValidator::new(&graph, FormatWorkspace::empty()).accepts_value(reference, &value),
                    ValueDecision::Rejected(ValueFailure {
                        condition: ValueCondition::WrongValueKind(ref kind),
                        ..
                    }) if kind == "decimal"
                ),
                "{text}"
            );
        }
    }
}

#[test]
fn data_decimal_exponent_limit_is_invalid_data_model_before_the_integer_domain() {
    let mut library = library();
    library.nodes.push(TypeNodeInput {
        id: "any".into(),
        shape: Shape::Unknown(UnknownKind::Any),
    });
    fixture_item_mut(&mut library.profile.integer_domains, 0)
        .forms
        .push(IntegerForm::IntegralDecimal);
    let graph = check_type_signatures(&library).unwrap();
    let any = signature_type_ref("any");
    for text in ["1e10000", "0e10000", "1E+10000", "1e-10000"] {
        assert!(
            matches!(
                PreparedValidator::new(&graph, FormatWorkspace::empty())
                    .accepts_value(&any, &JsonValue::Dec(text.into())),
                ValueDecision::Rejected(ValueFailure {
                    condition: ValueCondition::InvalidDataModel,
                    ..
                })
            ),
            "{text}"
        );
    }
}

#[test]
fn runtime_integer_decode_maps_the_owned_projection_to_typed_failures() {
    let graph = check_type_signatures(&library()).unwrap();
    let profile = &graph.profile;
    assert_eq!(
        integer_decode(profile, None, JsonValue::Str("1.0e1".into())).unwrap(),
        BigInt::from(10)
    );
    assert_eq!(
        integer_decode(profile, None, JsonValue::Str("0e9999".into())).unwrap(),
        BigInt::from(0)
    );
    assert!(matches!(
        integer_decode(profile, None, JsonValue::Str("0e10000".into())),
        Err(RuntimeFailure::Representation(ref name)) if name == "integer"
    ));
    assert!(matches!(
        integer_decode(profile, None, JsonValue::Str("+5".into())),
        Err(RuntimeFailure::Representation(ref name)) if name == "integer"
    ));
    assert!(matches!(
        integer_decode(profile, Some("missing"), JsonValue::Str("5".into())),
        Err(RuntimeFailure::Representation(ref name)) if name == "integer domain"
    ));
}

#[test]
fn sealed_leaves_follow_the_lean_leaf_contract() {
    use serde_json::{json, Value};
    type SealedCase = (
        &'static str,
        Value,
        bool,
        bool,
        JsonValue,
        Option<ValueCondition>,
    );
    let vectors: Value = serde_json::from_str(include_str!(
        "../../../../verification/declaration/sealed_leaf_sample_vectors.json"
    ))
    .unwrap();
    let mut profile: Value = vectors["profile"].clone();
    profile["numbers"] = json!({"decimals": true});
    profile["integer_domains"][0]["forms"] =
        json!([{"tag": "Number"}, {"tag": "IntegralDecimal"}, {"tag": "DecimalString"}]);
    profile["tag"] = json!({
        "key": "$type",
        "format": null,
        "sealed": [
            {"tag": "integer-form", "fields": [
                {"key": "count", "required": true, "leaf": {"tag": "Integer", "value": {
                    "domain": null, "minimum": null, "maximum": null,
                    "const_value": null, "enum_values": null, "default_value": null}}}
            ], "extras": {"tag": "Reject"}},
            {"tag": "string-form", "fields": [
                {"key": "label", "required": true, "leaf": {"tag": "String", "value": {
                    "format": {"tag": "Named", "value": "seven"}, "lengths": [], "wrapper": null,
                    "const_value": null, "enum_values": null, "examples": ["7"], "default_value": null}}}
            ], "extras": {"tag": "Reject"}}
        ]
    });
    let sealed = |tag: &str| json!({"tag": "Sealed", "fields": {"tag": tag, "refinements": []}});
    let object = |tag: &str, key: &str, value: JsonValue| {
        JsonValue::Obj(vec![
            ("$type".into(), JsonValue::Str(tag.into())),
            (key.into(), value),
        ])
    };
    let wrong_integer = || Some(ValueCondition::WrongValueKind("integer".into()));
    let cases: [SealedCase; 8] = [
        (
            "dec-integer-kind",
            sealed("integer-form"),
            false,
            false,
            object("integer-form", "count", JsonValue::Dec("5".into())),
            wrong_integer(),
        ),
        (
            "str-integer-kind",
            sealed("integer-form"),
            false,
            false,
            object("integer-form", "count", JsonValue::Str("5".into())),
            wrong_integer(),
        ),
        (
            "num-integer-accepted",
            sealed("integer-form"),
            false,
            false,
            object("integer-form", "count", JsonValue::Num(5.into())),
            None,
        ),
        (
            "dec-integer-domain-missing-kind",
            sealed("integer-form"),
            false,
            true,
            object("integer-form", "count", JsonValue::Dec("5".into())),
            wrong_integer(),
        ),
        (
            "num-integer-domain-missing",
            sealed("integer-form"),
            false,
            true,
            object("integer-form", "count", JsonValue::Num(5.into())),
            Some(ValueCondition::IntegerDomain),
        ),
        (
            "sealed-string-format-missing",
            sealed("string-form"),
            true,
            false,
            object("string-form", "label", JsonValue::Str("abc".into())),
            Some(ValueCondition::Format("seven".into())),
        ),
        (
            "sealed-string-format-present",
            sealed("string-form"),
            false,
            false,
            object("string-form", "label", JsonValue::Str("abc".into())),
            Some(ValueCondition::Format("seven".into())),
        ),
        (
            "sealed-string-format-missing-with-matching-text",
            sealed("string-form"),
            true,
            false,
            object("string-form", "label", JsonValue::Str("7".into())),
            Some(ValueCondition::Format("seven".into())),
        ),
    ];
    for (id, shape, drop_format, drop_domain, value, expected) in cases {
        let library = decode_type_signatures(
            &json!({
                "schema": "ncoh-type-signatures@1",
                "identity": "sealed-leaf-contract",
                "revision": "1",
                "profile": profile.clone(),
                "sources": [], "provenance": [], "groups": [], "annotations": [],
                "nodes": [{"id": "value", "shape": shape}],
                "definitions": []
            })
            .to_string(),
        )
        .unwrap();
        let mut graph = check_type_signatures(&library).unwrap();
        if drop_format {
            graph.profile.format_bindings.retain(|f| f.name != "seven");
        }
        if drop_domain {
            graph.profile.integer_domains.clear();
        }
        let node = signature_type_ref("value");
        let actual =
            PreparedValidator::new(&graph, FormatWorkspace::empty()).accepts_value(&node, &value);
        match expected {
            None => assert!(
                matches!(actual, ValueDecision::Accepted),
                "{id}: {actual:?}"
            ),
            Some(condition) => assert!(
                matches!(&actual, ValueDecision::Rejected(failure) if failure.condition == condition),
                "{id}: {actual:?}"
            ),
        }
    }
}

pub(crate) fn missing_named_format_inputs() -> (SemanticGraph, TypeRef, SemanticGraph, TypeRef) {
    use serde_json::{json, Value};
    let vectors: Value = serde_json::from_str(include_str!(
        "../../../../verification/declaration/sealed_leaf_sample_vectors.json"
    ))
    .unwrap();
    let mut profile: Value = vectors["profile"].clone();
    profile["format_bindings"] = json!([
        {"name": "seven", "reference": profile["format_bindings"][0]["reference"].clone(),
         "rule": {"tag": "Literal", "value": "7"}},
        {"name": "pval-missing-format", "reference": profile["format_bindings"][0]["reference"].clone(),
         "rule": {"tag": "Literal", "value": "7"}}
    ]);
    profile["tag"] = json!({"key": "$tag", "format": "seven", "sealed": []});
    let string_shape = json!({"tag": "String", "value": {
        "format": {"tag": "Named", "value": "pval-missing-format"}, "lengths": [], "wrapper": null,
        "const_value": null, "enum_values": null, "examples": ["ok"], "default_value": null}});
    let unknown_shape = json!({"tag": "Unknown", "value": {"tag": "Any"}});
    let build = |shape: Value| {
        decode_type_signatures(
            &json!({
                "schema": "ncoh-type-signatures@1",
                "identity": "pval-missing-format",
                "revision": "1",
                "profile": profile.clone(),
                "sources": [], "provenance": [], "groups": [], "annotations": [],
                "nodes": [{"id": "value", "shape": shape}],
                "definitions": []
            })
            .to_string(),
        )
        .unwrap()
    };

    let library = build(string_shape);
    let mut string_graph = check_type_signatures(&library).unwrap();
    string_graph
        .profile
        .format_bindings
        .retain(|f| f.name != "pval-missing-format");
    assert!(string_graph.profile.format("pval-missing-format").is_none());
    let string_ref = signature_type_ref("value");

    let library = build(unknown_shape);
    let mut tag_graph = check_type_signatures(&library).unwrap();
    tag_graph
        .profile
        .format_bindings
        .retain(|f| f.name != "pval-missing-format");
    tag_graph.profile.tag.as_mut().unwrap().format = Some("pval-missing-format".into());
    assert!(tag_graph.profile.format("pval-missing-format").is_none());
    let tag_ref = signature_type_ref("value");
    (string_graph, string_ref, tag_graph, tag_ref)
}

#[test]
fn missing_named_formats_follow_the_lean_contract() {
    let (string_graph, string_ref, tag_graph, type_ref) = missing_named_format_inputs();
    let actual = PreparedValidator::new(&string_graph, FormatWorkspace::empty())
        .accepts_value(&string_ref, &JsonValue::Str("ok".into()));
    assert!(
        matches!(
            &actual,
            ValueDecision::Unresolved(obligations)
                if obligations.iter().any(|obligation| obligation.reason
                    == SemanticReason::UnknownFormat("pval-missing-format".into()))
        ),
        "{actual:?}"
    );

    let value = JsonValue::Obj(vec![("$tag".into(), JsonValue::Str("v".into()))]);
    let actual = PreparedValidator::new(&tag_graph, FormatWorkspace::empty())
        .accepts_value(&type_ref, &value);
    let expected = ValueDecision::Rejected(ValueFailure {
        definition_ref: DefinitionRef {
            source: type_ref.source.clone(),
            name: "value".into(),
        },
        origin: OccurrenceRef::from(&type_ref),
        type_ref,
        value_path: vec![PathStep::Field("$tag".into())],
        condition: ValueCondition::InvalidTag,
        observed: SlotValue::Present(JsonValue::Str("v".into())),
        reference_trace: vec![],
    });
    assert_eq!(actual, expected);
}
