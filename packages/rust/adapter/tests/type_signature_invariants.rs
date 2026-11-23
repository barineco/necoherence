// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT
#![allow(clippy::expect_used, clippy::indexing_slicing, clippy::unwrap_used)]
use necoherence::inclusion;
use necoherence::semantic_codegen_runtime::{select_branch, with_member, wrap_decode, wrap_encode};
use necoherence::semantic_composition as composition;
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
fn admission_failure_variants_match_schema_basis_and_digest() {
    let entrypoints = vec![SignatureEntrypoint {
        identity: "entry".into(),
        definition: "entry".into(),
    }];
    let input = assemble_signature_generation(library(), None, entrypoints).unwrap();

    let mut changed = input.clone();
    changed.schema = "ncoh-checked-generation@3".into();
    assert!(matches!(
        admit_signature_generation(
            &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input),
            changed
        ),
        Err(AdmissionFailure::UnsupportedSchema(_))
    ));

    let mut expected = input.basis.clone();
    expected.graph_sha256 = "0".repeat(64);
    assert!(matches!(
        admit_signature_generation(
            &necoherence::type_signatures::ExpectedSignatureBasis {
                basis: expected,
                observations: None,
            },
            input.clone()
        ),
        Err(AdmissionFailure::Certificate(_))
    ));

    let mut changed = input.clone();
    Arc::make_mut(&mut changed.signatures).revision = "changed".into();
    assert!(matches!(
        admit_signature_generation(
            &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input),
            changed
        ),
        Err(AdmissionFailure::Certificate(_))
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
fn duplicate_produced_resource_ids_in_an_outcome_are_lb01() {
    let mut l = library_declaring_operation_source();
    let production = |id: &str| SignatureResourceProduction {
        id: id.into(),
        token_type: "text".into(),
        revision: BigUint::from(1u8),
        quantity: BigUint::from(1u8),
        provenance: "fixture".into(),
    };
    let operation = |produced_resources: Vec<SignatureResourceProduction>| {
        SignatureDefinitionShape::Operation(OperationContract {
            effect: EffectPoint::DataOnly,
            inputs: vec![],
            outcomes: vec![SignatureOutcome {
                id: "failure".into(),
                form: OutcomeForm::DeclaredFailure,
                cause: OutcomeCause::ValueContract {
                    origin: Origin {
                        source: lean_operation_source(),
                        locator: vec!["failure".into()],
                    },
                },
                value_ports: vec![],
                produced_resources,
            }],
        })
    };
    l.definitions[0].shape = operation(vec![production("stock"), production("stock")]);
    assert!(matches!(
        check_library(&l),
        Err(LibraryCheckFailure::Library(LibraryFailure {
            predicate: LibraryPredicate::Lb01,
            ..
        }))
    ));
    l.definitions[0].shape = operation(vec![production("stock"), production("stock-2")]);
    assert_eq!(check_library(&l).err(), None);
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

#[test]
fn internal_tag_identity_admits_distinct_tags_and_preserves_other_selectors() {
    let mut subject = library();
    if let Some(tag) = &mut subject.profile.tag {
        tag.key = "$type".into();
        tag.format = None;
    }
    let product = SignatureProduct {
        fields: vec![SignatureField {
            wire_name: "$type".into(),
            slot: SignatureSlot {
                type_id: "text".into(),
                required: true,
                nullable: false,
            },
        }],
        extras: SignatureExtraMembers::Reject,
    };
    for target in ["a", "b"] {
        subject.nodes.push(TypeNodeInput {
            id: target.into(),
            shape: Shape::Product(product.clone()),
        });
    }
    let branches = vec![
        SignatureUnionBranch {
            target: "a".into(),
            wire_tag: "com.example.a".into(),
            selector: BranchSelector::InternalTag,
        },
        SignatureUnionBranch {
            target: "b".into(),
            wire_tag: "com.example.b".into(),
            selector: BranchSelector::InternalTag,
        },
    ];
    if let Shape::String(spec) = &mut fixture_item_mut(&mut subject.nodes, 0).shape {
        spec.lengths.clear();
    }
    fixture_item_mut(&mut subject.nodes, 3).shape = Shape::TaggedUnion(SignatureUnion {
        branches: branches.clone(),
    });
    check_library(&subject).unwrap();
    let graph = check_type_signatures(&subject).unwrap();
    let choice = signature_type_ref("choice");
    for (index, tag) in ["com.example.a", "com.example.b"].iter().enumerate() {
        let value = JsonValue::Obj(vec![("$type".into(), JsonValue::Str((*tag).into()))]);
        assert_eq!(
            select_branch(
                PreparedValidator::new(&graph, FormatWorkspace::empty()).metadata(),
                &choice,
                &value
            )
            .unwrap(),
            index
        );
    }
    assert!(select_branch(
        PreparedValidator::new(&graph, FormatWorkspace::empty()).metadata(),
        &choice,
        &JsonValue::Obj(vec![("$type".into(), JsonValue::Str("unknown".into()))])
    )
    .is_err());
    for selector in [
        BranchSelector::Kind(ValueKind::Null),
        BranchSelector::MemberShape(vec![("key".into(), MemberTest::Absent)]),
    ] {
        let mut duplicate = subject.clone();
        fixture_item_mut(&mut duplicate.nodes, 3).shape = Shape::TaggedUnion(SignatureUnion {
            branches: branches
                .iter()
                .map(|branch| SignatureUnionBranch {
                    selector: selector.clone(),
                    ..branch.clone()
                })
                .collect(),
        });
        assert!(
            matches!(check_library(&duplicate), Err(LibraryCheckFailure::Library(failure)) if failure.predicate == LibraryPredicate::Lb18)
        );
    }
    let mut duplicate_tag = subject.clone();
    if let Shape::TaggedUnion(union) = &mut fixture_item_mut(&mut duplicate_tag.nodes, 3).shape {
        let wire_tag = fixture_item(&union.branches, 0).wire_tag.clone();
        fixture_item_mut(&mut union.branches, 1).wire_tag = wire_tag;
    }
    assert!(
        matches!(check_library(&duplicate_tag), Err(LibraryCheckFailure::Library(failure)) if failure.predicate == LibraryPredicate::Lb04)
    );
    let mut preset = subject.clone();
    preset.profile = decode_value_profile(include_str!(
        "../../../../verification/presets/atproto-data-model/profile.json"
    ))
    .unwrap();
    preset.nodes.retain(|node| node.id != "sealed");
    if let Shape::String(spec) = &mut fixture_item_mut(&mut preset.nodes, 0).shape {
        spec.format = None;
    }
    check_library(&preset).unwrap();
    let preset_graph = check_type_signatures(&preset).unwrap();
    let preset_choice = signature_type_ref("choice");
    for (index, tag) in ["com.example.a", "com.example.b"].iter().enumerate() {
        let value = JsonValue::Obj(vec![("$type".into(), JsonValue::Str((*tag).into()))]);
        assert_eq!(
            select_branch(
                PreparedValidator::new(&preset_graph, FormatWorkspace::empty()).metadata(),
                &preset_choice,
                &value
            )
            .unwrap(),
            index
        );
    }
}

fn composition_fixture() -> (TypeSignatureLibrary, composition::CompositionInput) {
    let mut library = library();
    library.nodes.extend([
        TypeNodeInput {
            id: "boolean".into(),
            shape: Shape::Boolean(BooleanSpec {
                const_value: None,
                default_value: None,
            }),
        },
        TypeNodeInput {
            id: "record".into(),
            shape: Shape::Product(SignatureProduct {
                fields: vec![SignatureField {
                    wire_name: "flag".into(),
                    slot: SignatureSlot {
                        type_id: "boolean".into(),
                        required: true,
                        nullable: false,
                    },
                }],
                extras: SignatureExtraMembers::Reject,
            }),
        },
    ]);
    let basis = signature_basis(&library, None, &[]).unwrap();
    let basis: serde_json::Value =
        serde_json::from_str(&encode_signature_basis(&basis).unwrap()).unwrap();
    let slot = serde_json::json!({
        "type_id": "boolean", "required": true, "nullable": false
    });
    let problem = serde_json::json!({
        "identity": "composition", "revision": "2", "basis": basis,
        "signatures": [],
        "initial_inputs": [{
            "id": "initial", "contract": slot, "source": {"tag": "Argument"},
            "resource": null
        }],
        "initial_resources": [],
        "goal": {
            "outputs": [{
                "id": "output", "contract": slot,
                "source_constraint": {
                    "tag": "InitialOnly", "fields": {"input": "initial", "path": []}
                }
            }],
            "failures": [], "final_resources": []
        },
        "invocation_domain": {
            "identity": "domain", "revision": "3", "sites": [],
            "permitted_projections": [], "permitted_constructions": [],
            "permitted_transforms": [], "guards": []
        },
        "allowed_effects": [], "explicit_order": [],
        "selection_policy": {"tag": "AnyFeasible"},
        "bounds": {
            "max_expanded_states": "16", "max_binding_candidates": "16",
            "max_type_obligations": "16", "max_branch_nodes": "16",
            "resource_bounds": null, "max_sample_length": "59"
        }
    });
    let native = decode_signature_problem(&library, &problem).unwrap();
    (library, native)
}

#[test]
fn assignable_certificate_contains_the_verified_pair_graph() {
    let (library, problem) = composition_fixture();
    let graph = check_type_signatures(&library).unwrap();
    let slot = fixture_item(&problem.initial_inputs, 0).contract.clone();
    let decision = composition::check_assignable(&graph, &slot, &slot, 16);
    assert!(
        matches!(decision, composition::CompatibilityDecision::Compatible(_)),
        "expected compatible decision, got {decision:?}"
    );
    let composition::CompatibilityDecision::Compatible(checked) = decision else {
        return;
    };
    let certificate = &checked;
    assert_eq!(certificate.root, BigUint::from(0u8));
    assert_eq!(certificate.pairs.len(), 1);
    let root = fixture_item(
        &certificate.pairs,
        usize::try_from(&certificate.root).unwrap(),
    );
    assert_eq!(root.pair.source, slot);
    assert_eq!(root.pair.destination, slot);
    assert_eq!(root.rule, composition::InclusionRule::SameDefinedType);
    composition::verify_empty_types(&graph, &certificate.empty_types).unwrap();
}

#[test]
fn function_input_source_constraint_is_an_invalid_signature() {
    let (library, mut problem) = composition_fixture();
    let graph = check_type_signatures(&library).unwrap();
    let slot = fixture_item(&problem.initial_inputs, 0).contract.clone();
    let reference = composition::FunctionRef {
        identity: "pure".into(),
        revision: "1".into(),
        content_digest: "digest".into(),
    };
    problem.signatures.push(composition::FunctionSignature {
        reference: reference.clone(),
        form: composition::FunctionForm::Pure,
        effect: composition::CompositionEffect::PureFunction,
        inputs: vec![composition::InputPort {
            id: composition::PortId("input".into()),
            contract: slot,
            source_constraint: composition::SourceConstraint::InitialOnly {
                input: composition::InputId("missing".into()),
                path: vec![],
            },
            resource_requirement: None,
        }],
        outcomes: vec![composition::OutcomeContract {
            id: composition::OutcomeId("success".into()),
            form: composition::OutcomeForm::Success,
            value_ports: vec![],
            produced_resources: vec![],
        }],
        resource_inputs: vec![],
        assumption_ref: "assumption".into(),
        handles_failure: None,
    });
    assert_eq!(
        composition::prepare_direct_composition(
            &graph,
            problem,
            composition::operation_checker_without_library(),
            composition::operation_meaning_of(&graph)
        )
        .err()
        .expect("the operation identity is rejected"),
        composition::CompositionInputFailure::InvalidSignature {
            function: reference,
            reason: composition::InvalidSignatureReason::InputSourceConstraint,
        }
    );
}

#[test]
#[allow(clippy::indexing_slicing, clippy::panic)]
fn operation_invocation_identity_outside_its_contract_is_rejected_by_signature_preparation() {
    let input =
        decode_signature_generation(include_str!("fixtures/composition-budget-default.json"))
            .unwrap();
    let composition = input.composition.as_ref().unwrap();
    let mut problem = composition["problem"].clone();
    problem["signatures"][0]["reference"]["identity"] = serde_json::json!("OtherOperation");
    problem["signatures"][1]["handles_failure"]["fields"]["function"]["identity"] =
        serde_json::json!("OtherOperation");
    let Err(failure) = decode_signature_problem(&input.signatures, &problem) else {
        panic!("the invocation identity outside the operation contract is rejected");
    };
    assert!(
        matches!(
            failure,
            AdmissionFailure::CompositionInput(composition::CompositionInputFailure::InvalidSignature {
                ref reason,
                ..
            }) if *reason == composition::InvalidSignatureReason::OperationIdentityBasis
        ),
        "{failure:?}"
    );
}

#[test]
fn bounded_product_counterexample_candidates_preserve_sample_bound() {
    let (mut library, _) = composition_fixture();
    library.nodes.extend([
        TypeNodeInput {
            id: "extras-source".into(),
            shape: Shape::Product(SignatureProduct {
                fields: vec![],
                extras: SignatureExtraMembers::Allow {
                    key_format: None,
                    value: SignatureElementContract {
                        type_id: "boolean".into(),
                        nullable: false,
                    },
                },
            }),
        },
        TypeNodeInput {
            id: "field-destination".into(),
            shape: Shape::Product(SignatureProduct {
                fields: vec![SignatureField {
                    wire_name: "long-key".into(),
                    slot: SignatureSlot {
                        type_id: "boolean".into(),
                        required: false,
                        nullable: false,
                    },
                }],
                extras: SignatureExtraMembers::Reject,
            }),
        },
    ]);
    let graph = check_type_signatures(&library).unwrap();
    let source = signature_type_ref("extras-source");
    let destination = signature_type_ref("field-destination");
    for maximum in [0u32, 1] {
        let samples = composition::inclusion_samples_bounded(
            &graph,
            &source,
            &destination,
            &composition::SearchBounds {
                max_sample_length: BigUint::from(maximum),
                ..Default::default()
            },
        );
        let present = samples.values.iter().any(|value| {
            matches!(value,
            JsonValue::Obj(members) if members.iter().any(|(key, _)| key == "long-key"))
        });
        assert_eq!(present, maximum == 1);
        if maximum == 0 {
            assert!(samples
                .obligations
                .contains(&composition::SampleObligation::SampleBound));
        }
        assert!(samples.values.iter().all(|value| PreparedValidator::new(
            &graph,
            FormatWorkspace::empty()
        )
        .accepts_value(&source, value)
            == ValueDecision::Accepted));
    }
}

fn union_fixture() -> (TypeSignatureLibrary, SemanticGraph) {
    let (mut library, _) = composition_fixture();
    let selector = BranchSelector::MemberShape(vec![("k".into(), MemberTest::Absent)]);
    library.nodes.extend([
        TypeNodeInput {
            id: "true-only".into(),
            shape: Shape::Boolean(BooleanSpec {
                const_value: Some(true),
                default_value: None,
            }),
        },
        TypeNodeInput {
            id: "source-union".into(),
            shape: Shape::TaggedUnion(SignatureUnion {
                branches: vec![SignatureUnionBranch {
                    target: "true-only".into(),
                    wire_tag: "k".into(),
                    selector: selector.clone(),
                }],
            }),
        },
        TypeNodeInput {
            id: "destination-union".into(),
            shape: Shape::TaggedUnion(SignatureUnion {
                branches: vec![SignatureUnionBranch {
                    target: "boolean".into(),
                    wire_tag: "k".into(),
                    selector,
                }],
            }),
        },
    ]);
    let graph = check_type_signatures(&library).unwrap();
    (library, graph)
}

fn present_slot(id: &str) -> SlotContract {
    composition::present_contract(signature_type_ref(id))
}

#[test]
fn source_union_pairs_branches_whose_member_shape_selectors_are_equal() {
    let (_, graph) = union_fixture();
    let source = present_slot("source-union");
    let destination = present_slot("destination-union");
    let decision = composition::check_assignable(&graph, &source, &destination, 16);
    assert!(
        matches!(decision, composition::CompatibilityDecision::Compatible(_)),
        "expected compatible decision, got {decision:?}"
    );
    let composition::CompatibilityDecision::Compatible(checked) = decision else {
        return;
    };
    let certificate = &checked;
    let root = fixture_item(
        &certificate.pairs,
        usize::try_from(&certificate.root).unwrap(),
    );
    assert_eq!(root.rule, composition::InclusionRule::SourceUnion);
    assert_eq!(root.children.len(), 1);
}

#[test]
fn product_presence_failure_is_reported_as_a_presence_obligation() {
    let (mut library, _) = composition_fixture();
    let product = |nullable| {
        Shape::Product(SignatureProduct {
            fields: vec![SignatureField {
                wire_name: "flag".into(),
                slot: SignatureSlot {
                    type_id: "boolean".into(),
                    required: true,
                    nullable,
                },
            }],
            extras: SignatureExtraMembers::Reject,
        })
    };
    library.nodes.extend([
        TypeNodeInput {
            id: "nullable-flag".into(),
            shape: product(true),
        },
        TypeNodeInput {
            id: "plain-flag".into(),
            shape: product(false),
        },
    ]);
    let graph = check_type_signatures(&library).unwrap();
    let source = present_slot("nullable-flag");
    let destination = present_slot("plain-flag");
    let decision = composition::check_assignable_bounded(
        &graph,
        &source,
        &destination,
        &SearchBounds {
            max_sample_length: BigUint::from(0u32),
            ..SearchBounds::default()
        },
    );
    assert!(
        matches!(decision, composition::CompatibilityDecision::Unknown(_)),
        "expected unknown decision, got {decision:?}"
    );
    let composition::CompatibilityDecision::Unknown(obligations) = decision else {
        return;
    };
    assert_eq!(obligations.len(), 1);
    assert_eq!(
        fixture_item(&obligations, 0).reason,
        composition::TypeObligationReason::Presence
    );
}

#[test]
fn null_rejection_of_an_extras_type_is_decided_by_one_expansion_step() {
    let (mut library, _) = composition_fixture();
    let product = |value: &str, optional_field: bool| {
        Shape::Product(SignatureProduct {
            fields: if optional_field {
                vec![SignatureField {
                    wire_name: "x".into(),
                    slot: SignatureSlot {
                        type_id: value.into(),
                        required: false,
                        nullable: false,
                    },
                }]
            } else {
                vec![]
            },
            extras: SignatureExtraMembers::Allow {
                key_format: None,
                value: SignatureElementContract {
                    type_id: value.into(),
                    nullable: false,
                },
            },
        })
    };
    library.nodes.extend([
        TypeNodeInput {
            id: "text-alias".into(),
            shape: Shape::Alias {
                target: "text".into(),
            },
        },
        TypeNodeInput {
            id: "direct-source".into(),
            shape: product("text", false),
        },
        TypeNodeInput {
            id: "direct-destination".into(),
            shape: product("text", true),
        },
        TypeNodeInput {
            id: "alias-source".into(),
            shape: product("text-alias", false),
        },
        TypeNodeInput {
            id: "alias-destination".into(),
            shape: product("text-alias", true),
        },
    ]);
    let graph = check_type_signatures(&library).unwrap();
    let bounds = SearchBounds {
        max_sample_length: BigUint::from(0u32),
        ..SearchBounds::default()
    };
    let decide = |source: &str, destination: &str| {
        composition::check_assignable_bounded(
            &graph,
            &present_slot(source),
            &present_slot(destination),
            &bounds,
        )
    };
    let direct = decide("direct-source", "direct-destination");
    assert!(
        matches!(direct, composition::CompatibilityDecision::Compatible(_)),
        "expected compatible decision, got {direct:?}"
    );
    let aliased = decide("alias-source", "alias-destination");
    assert!(
        matches!(aliased, composition::CompatibilityDecision::Unknown(_)),
        "expected unknown decision, got {aliased:?}"
    );
    let composition::CompatibilityDecision::Unknown(obligations) = aliased else {
        return;
    };
    assert_eq!(
        fixture_item(&obligations, 0).reason,
        composition::TypeObligationReason::Presence
    );
}

fn prepare_failure(
    library: &TypeSignatureLibrary,
    problem: composition::CompositionInput,
) -> composition::CompositionInputFailure {
    let graph = check_type_signatures(library).unwrap();
    let outcome = composition::prepare_direct_composition(
        &graph,
        problem,
        composition::operation_checker_without_library(),
        composition::operation_meaning_of(&graph),
    );
    outcome.err().expect("composition input is rejected")
}

#[test]
fn composition_input_identities_must_be_unique_and_non_empty() {
    let (library, problem) = composition_fixture();
    let graph = check_type_signatures(&library).unwrap();
    assert!(composition::prepare_direct_composition(
        &graph,
        problem.clone(),
        composition::operation_checker_without_library(),
        composition::operation_meaning_of(&graph)
    )
    .is_ok());
    let mut duplicated = problem.clone();
    let first = fixture_item(&duplicated.initial_inputs, 0).clone();
    duplicated.initial_inputs.push(first);
    assert_eq!(
        prepare_failure(&library, duplicated),
        composition::CompositionInputFailure::DuplicateIdentity {
            kind: "input".into(),
            identity: "initial".into(),
        }
    );
    let mut unnamed = problem;
    fixture_item_mut(&mut unnamed.initial_inputs, 0).id = composition::InputId(String::new());
    assert_eq!(
        prepare_failure(&library, unnamed),
        composition::CompositionInputFailure::DuplicateIdentity {
            kind: "input".into(),
            identity: String::new(),
        }
    );
}

#[test]
fn composition_goal_and_types_are_checked_against_the_graph() {
    let (library, problem) = composition_fixture();
    let mut empty_goal = problem.clone();
    empty_goal.goal.outputs.clear();
    assert_eq!(
        prepare_failure(&library, empty_goal),
        composition::CompositionInputFailure::EmptyGoal
    );
    let mut missing_type = problem.clone();
    let absent = signature_type_ref("boolean");
    let missing = TypeRef::new(absent.source.clone(), "missing", vec![]);
    fixture_item_mut(&mut missing_type.goal.outputs, 0)
        .contract
        .type_ref = missing.clone();
    assert_eq!(
        prepare_failure(&library, missing_type),
        composition::CompositionInputFailure::UnresolvedType(missing)
    );
    let mut undefined_path = problem.clone();
    fixture_item_mut(&mut undefined_path.goal.outputs, 0).source_constraint =
        composition::SourceConstraint::InitialOnly {
            input: composition::InputId("initial".into()),
            path: vec![PathStep::Field("flag".into())],
        };
    assert_eq!(
        prepare_failure(&library, undefined_path),
        composition::CompositionInputFailure::GoalSourceConstraintUndefined {
            port: composition::GoalPortId("output".into()),
            constraint: composition::SourceConstraint::InitialOnly {
                input: composition::InputId("initial".into()),
                path: vec![PathStep::Field("flag".into())],
            },
        }
    );
    let mut unknown_input = problem.clone();
    fixture_item_mut(&mut unknown_input.goal.outputs, 0).source_constraint =
        composition::SourceConstraint::InitialOnly {
            input: composition::InputId("absent".into()),
            path: vec![],
        };
    assert_eq!(
        prepare_failure(&library, unknown_input),
        composition::CompositionInputFailure::GoalSourceConstraintUndefined {
            port: composition::GoalPortId("output".into()),
            constraint: composition::SourceConstraint::InitialOnly {
                input: composition::InputId("absent".into()),
                path: vec![],
            },
        }
    );
    let mut anywhere = problem;
    fixture_item_mut(&mut anywhere.goal.outputs, 0).source_constraint =
        composition::SourceConstraint::AnyCompatible;
    let graph = check_type_signatures(&library).unwrap();
    assert!(composition::prepare_direct_composition(
        &graph,
        anywhere,
        composition::operation_checker_without_library(),
        composition::operation_meaning_of(&graph)
    )
    .is_ok());
}

#[test]
fn composition_variant_paths_are_defined_through_the_projection_assumptions() {
    let (library, mut problem) = composition_fixture();
    let choice = signature_type_ref("choice");
    fixture_item_mut(&mut problem.initial_inputs, 0)
        .contract
        .type_ref = choice.clone();
    fixture_item_mut(&mut problem.goal.outputs, 0)
        .contract
        .type_ref = choice;
    let graph = check_type_signatures(&library).unwrap();
    for (tag, defined) in [("sealed", true), ("text", false), ("absent", false)] {
        let mut candidate = problem.clone();
        fixture_item_mut(&mut candidate.goal.outputs, 0).source_constraint =
            composition::SourceConstraint::InitialOnly {
                input: composition::InputId("initial".into()),
                path: vec![PathStep::Variant(tag.into())],
            };
        assert_eq!(
            composition::prepare_direct_composition(
                &graph,
                candidate,
                composition::operation_checker_without_library(),
                composition::operation_meaning_of(&graph)
            )
            .is_ok(),
            defined,
            "{tag}"
        );
    }
}

#[test]
fn composition_failure_origins_and_terminal_lots_must_be_declared() {
    let (library, problem) = composition_fixture();
    let mut origin = problem.clone();
    origin.goal.failures.push(composition::FailureEmbedding {
        id: composition::FailureEmbeddingId("failure".into()),
        origin: composition::FailureOrigin::Guard {
            guard: composition::GuardId("absent".into()),
            arm: composition::GuardArm::Rejected,
        },
        contract: fixture_item(&problem.goal.outputs, 0).contract.clone(),
        final_resources: vec![],
    });
    assert_eq!(
        prepare_failure(&library, origin),
        composition::CompositionInputFailure::FailureEmbeddingOriginUndefined {
            embedding: composition::FailureEmbeddingId("failure".into()),
            origin: composition::FailureOrigin::Guard {
                guard: composition::GuardId("absent".into()),
                arm: composition::GuardArm::Rejected,
            },
        }
    );
    let mut lot = problem;
    lot.goal.final_resources.push(composition::ResourceGoal {
        lot: composition::ResourceLotRef::Initial(composition::LotId("absent".into())),
        multiplicity: BigUint::from(1u8),
        revision: BigUint::from(0u8),
    });
    assert_eq!(
        prepare_failure(&library, lot),
        composition::CompositionInputFailure::InvalidResourceDeclaration(
            "terminal resource lot".into()
        )
    );
}

#[test]
fn composition_explicit_order_requires_distinct_declared_sites() {
    let (library, mut problem) = composition_fixture();
    let site = composition::SiteId("absent".into());
    problem.explicit_order.push((site.clone(), site));
    assert_eq!(
        prepare_failure(&library, problem),
        composition::CompositionInputFailure::ExplicitSiteOrderInvalid {
            before: composition::SiteId("absent".into()),
            after: composition::SiteId("absent".into()),
        }
    );
}

#[test]
fn composition_construction_rules_reject_cycles_through_nested_fields() {
    let (mut library, problem) = composition_fixture();
    let record_with = |field: &str, target: &str| {
        Shape::Product(SignatureProduct {
            fields: vec![SignatureField {
                wire_name: field.into(),
                slot: SignatureSlot {
                    type_id: target.into(),
                    required: true,
                    nullable: false,
                },
            }],
            extras: SignatureExtraMembers::Reject,
        })
    };
    library.nodes.extend([
        TypeNodeInput {
            id: "left".into(),
            shape: record_with("next", "right"),
        },
        TypeNodeInput {
            id: "right".into(),
            shape: record_with("next", "left"),
        },
    ]);
    let left = signature_type_ref("left");
    let right = signature_type_ref("right");
    let rule = |identity: &str, type_ref: &TypeRef, nested: &str| composition::ConstructionRule {
        identity: identity.into(),
        type_ref: type_ref.clone(),
        nested_fields: vec![("next".into(), nested.into())],
        field_constraints: vec![],
    };
    let mut cyclic = problem.clone();
    cyclic.invocation_domain.permitted_constructions = vec![
        rule("left-rule", &left, "right-rule"),
        rule("right-rule", &right, "left-rule"),
    ];
    assert_eq!(
        prepare_failure(&library, cyclic),
        composition::CompositionInputFailure::CyclicConstruction {
            identity: "left-rule".into(),
        }
    );
    let mut missing_rule = problem;
    missing_rule.invocation_domain.permitted_constructions =
        vec![rule("left-rule", &left, "absent-rule")];
    assert_eq!(
        prepare_failure(&library, missing_rule),
        composition::CompositionInputFailure::NestedConstructionMismatch {
            identity: "left-rule".into(),
            field: "next".into(),
            nested: "absent-rule".into(),
            type_ref: right,
        }
    );
}

fn resource_lowering_library() -> TypeSignatureLibrary {
    TypeSignatureLibrary {
        schema: "ncoh-type-signatures@1".into(),
        identity: "resource-lowering-library".into(),
        revision: "1".into(),
        profile: ValueSemanticProfile {
            reference: reference(),
            source_refs: vec![],
            integer_domains: vec![IntegerDomainBinding {
                name: "integer".into(),
                reference: reference(),
                range: IntegerDomain::Inclusive {
                    minimum: BigInt::from(-10),
                    maximum: BigInt::from(10),
                },
                forms: vec![IntegerForm::Number],
            }],
            default_integer_domain: "integer".into(),
            numbers: NumberModel { decimals: false },
            grapheme_rules: None,
            format_bindings: vec![],
            wrappers: vec![],
            tag: None,
            bytes_policy: None,
        },
        sources: vec![],
        provenance: vec![],
        groups: vec![],
        annotations: vec![],
        nodes: vec![TypeNodeInput {
            id: "boolean".into(),
            shape: Shape::Boolean(BooleanSpec {
                const_value: None,
                default_value: None,
            }),
        }],
        definitions: vec![],
    }
}

fn boolean_slot() -> SlotContract {
    composition::present_contract(signature_type_ref("boolean"))
}

fn resource_lowering_fixture(
    mutate: impl FnOnce(&mut composition::CompositionInput),
) -> (SemanticGraph, composition::CompositionInput) {
    let graph = check_type_signatures(&resource_lowering_library()).unwrap();
    let mut problem = composition::CompositionInput {
        identity: "resource-lowering".into(),
        revision: "1".into(),
        basis: composition::SemanticBasis::of(&graph),
        signatures: vec![],
        initial_inputs: vec![composition::InitialInput {
            id: composition::InputId("initial".into()),
            contract: boolean_slot(),
            source: composition::InitialSource::Argument,
            resource: None,
        }],
        initial_resources: vec![],
        goal: composition::GoalSpec {
            outputs: vec![composition::GoalPort {
                id: composition::GoalPortId("output".into()),
                contract: boolean_slot(),
                source_constraint: composition::SourceConstraint::InitialOnly {
                    input: composition::InputId("initial".into()),
                    path: vec![],
                },
            }],
            failures: vec![],
            final_resources: vec![],
        },
        invocation_domain: composition::InvocationDomain {
            identity: "resource-lowering-domain".into(),
            revision: "1".into(),
            sites: vec![],
            permitted_projections: vec![],
            permitted_constructions: vec![],
            permitted_transforms: vec![],
            guards: vec![],
        },
        allowed_effects: vec![composition::CompositionEffect::PureFunction],
        explicit_order: vec![],
        selection_policy: None,
        bounds: SearchBounds::default(),
    };
    mutate(&mut problem);
    (graph, problem)
}

fn lowering_lot(id: &str, revision: u8) -> composition::ResourceLot {
    composition::ResourceLot {
        id: composition::LotId(id.into()),
        token_type: signature_type_ref("boolean"),
        producer: composition::ResourceProducer::Initial {
            identity: "producer".into(),
            revision: "1".into(),
        },
        revision: BigUint::from(revision),
        quantity: BigUint::from(1u8),
        provenance: "fixture".into(),
    }
}

#[test]
fn preparation_rejects_the_resource_declarations_behind_unreachable_lowering_reasons_as_lean_does()
{
    let library = resource_lowering_library();
    let (_, mut invocation_lot) = resource_lowering_fixture(|_| {});
    invocation_lot
        .initial_resources
        .push(composition::ResourceLot {
            producer: composition::ResourceProducer::InvocationOutcome {
                site: composition::SiteId("producer-site".into()),
                outcome: composition::OutcomeId("success".into()),
            },
            ..lowering_lot("lot", 1)
        });
    assert_eq!(
        prepare_failure(&library, invocation_lot),
        composition::CompositionInputFailure::InvalidResourceDeclaration(
            "initial lot has an invocation producer".into()
        )
    );
    let (_, mut backing) = resource_lowering_fixture(|_| {});
    backing.initial_inputs[0].resource = Some(composition::LotId("absent".into()));
    assert_eq!(
        prepare_failure(&library, backing),
        composition::CompositionInputFailure::InvalidResourceDeclaration(
            "initial backing lot".into()
        )
    );
    let (_, mut terminal) = resource_lowering_fixture(|_| {});
    terminal
        .goal
        .final_resources
        .push(composition::ResourceGoal {
            lot: composition::ResourceLotRef::Initial(composition::LotId("absent".into())),
            multiplicity: BigUint::from(1u8),
            revision: BigUint::from(0u8),
        });
    assert_eq!(
        prepare_failure(&library, terminal),
        composition::CompositionInputFailure::InvalidResourceDeclaration(
            "terminal resource lot".into()
        )
    );
    let (_, mut duplicate) = resource_lowering_fixture(|_| {});
    duplicate.initial_resources.push(lowering_lot("lot", 1));
    duplicate.initial_resources.push(lowering_lot("lot", 1));
    assert!(matches!(
        prepare_failure(&library, duplicate),
        composition::CompositionInputFailure::DuplicateIdentity { .. }
    ));
}

fn lean_operation_source() -> SourceIdentity {
    SourceIdentity {
        repository: "synthetic".into(),
        revision: "1".into(),
        path: "operation".into(),
        content_digest: "b".repeat(64),
    }
}

fn library_declaring_operation_source() -> TypeSignatureLibrary {
    let mut library = library();
    library.sources = vec![lean_operation_source()];
    library
}

fn text_port(id: &str) -> SignaturePort {
    SignaturePort {
        id: id.into(),
        contract: SignatureSlot {
            type_id: "text".into(),
            required: true,
            nullable: false,
        },
    }
}

#[test]
fn operation_without_success_outcome_is_a_lean_valid_operation() {
    let library = library_declaring_operation_source();
    let origin = Origin {
        source: lean_operation_source(),
        locator: vec!["failure".into()],
    };
    let base = OperationContract {
        effect: EffectPoint::DataOnly,
        inputs: vec![],
        outcomes: vec![SignatureOutcome {
            id: "failure".into(),
            form: OutcomeForm::DeclaredFailure,
            cause: OutcomeCause::ValueContract { origin },
            value_ports: vec![],
            produced_resources: vec![],
        }],
    };
    assert!(operation_extension_valid(&base, &base, &library));
}

#[test]
fn operation_check_leaves_produced_resource_identity_to_preparation() {
    let library = library_declaring_operation_source();
    let origin = Origin {
        source: lean_operation_source(),
        locator: vec!["failure".into()],
    };
    let production = || SignatureResourceProduction {
        id: "p".into(),
        token_type: "text".into(),
        revision: BigUint::from(1u8),
        quantity: BigUint::from(1u8),
        provenance: "produced".into(),
    };
    let base = OperationContract {
        effect: EffectPoint::DataOnly,
        inputs: vec![],
        outcomes: vec![SignatureOutcome {
            id: "failure".into(),
            form: OutcomeForm::DeclaredFailure,
            cause: OutcomeCause::ValueContract { origin },
            value_ports: vec![],
            produced_resources: vec![production(), production()],
        }],
    };
    assert!(operation_extension_valid(&base, &base, &library));
}

#[test]
fn external_supplement_origin_must_be_declared_by_library_sources() {
    let library = library_declaring_operation_source();
    let declared = Origin {
        source: lean_operation_source(),
        locator: vec!["success".into()],
    };
    let base = OperationContract {
        effect: EffectPoint::DataOnly,
        inputs: vec![],
        outcomes: vec![SignatureOutcome {
            id: "success".into(),
            form: OutcomeForm::Success,
            cause: OutcomeCause::ValueContract { origin: declared },
            value_ports: vec![],
            produced_resources: vec![],
        }],
    };
    let supplement = |source: SourceIdentity| {
        let mut supplied = base.clone();
        supplied.outcomes.push(SignatureOutcome {
            id: "external".into(),
            form: OutcomeForm::DeclaredFailure,
            cause: OutcomeCause::ExternalCondition {
                specification: Origin {
                    source,
                    locator: vec!["external".into()],
                },
            },
            value_ports: vec![text_port("reason")],
            produced_resources: vec![],
        });
        supplied
    };
    let undeclared = SourceIdentity {
        repository: "undeclared".into(),
        ..lean_operation_source()
    };
    assert!(!operation_extension_valid(
        &base,
        &supplement(undeclared),
        &library
    ));
    assert!(operation_extension_valid(
        &base,
        &supplement(lean_operation_source()),
        &library
    ));
}

#[test]
fn checked_graph_leaves_library_sources_to_provenance() {
    let library = library_declaring_operation_source();
    let graph = check_type_signatures(&library).unwrap();
    assert!(graph.source_refs.is_empty());
}

#[test]
fn checked_alias_reference_text_is_empty_as_lean() {
    let mut library = library_declaring_operation_source();
    library.nodes.push(TypeNodeInput {
        id: "alias".into(),
        shape: Shape::Alias {
            target: "text".into(),
        },
    });
    let graph = check_type_signatures(&library).unwrap();
    assert!(graph
        .nodes
        .iter()
        .any(|node| matches!(&node.shape, TypeShape::Alias { reference_text, .. } if reference_text.is_empty())));
    assert!(!graph
        .nodes
        .iter()
        .any(|node| matches!(&node.shape, TypeShape::Alias { reference_text, .. } if reference_text == "text")));
}

#[test]
fn alias_source_rejects_unfold_destination_rule_before_child_coverage_as_lean_does() {
    let mut library = library_declaring_operation_source();
    library.nodes.extend([
        TypeNodeInput {
            id: "alias-to-text".into(),
            shape: Shape::Alias {
                target: "text".into(),
            },
        },
        TypeNodeInput {
            id: "alias-to-never".into(),
            shape: Shape::Alias {
                target: "never".into(),
            },
        },
    ]);
    let graph = check_type_signatures(&library).unwrap();
    let source = present_slot("alias-to-text");
    let destination = present_slot("alias-to-never");
    let entry = composition::PairEntry {
        pair: composition::TypePair {
            source: source.clone(),
            destination: destination.clone(),
            source_tag: None,
        },
        source_shape: graph.find_type(&source.type_ref).unwrap().shape.clone(),
        destination_shape: graph
            .find_type(&destination.type_ref)
            .unwrap()
            .shape
            .clone(),
        rule: composition::InclusionRule::UnfoldDestination,
        children: vec![],
    };
    let certificate = composition::InclusionCertificate {
        basis: composition::SemanticBasis::of(&graph),
        source: source.clone(),
        destination: destination.clone(),
        empty_types: vec![],
        pairs: vec![entry],
        root: BigUint::from(0u8),
    };
    assert!(matches!(
        inclusion::verify_inclusion(&graph, &source, &destination, &certificate),
        Err(composition::InclusionFailure::RuleMismatch(0))
    ));
}

#[test]
fn alias_destination_recurses_into_the_child_row_before_later_rows_as_lean_does() {
    let mut library = library_declaring_operation_source();
    library.nodes.push(TypeNodeInput {
        id: "alias-to-never".into(),
        shape: Shape::Alias {
            target: "never".into(),
        },
    });
    let graph = check_type_signatures(&library).unwrap();
    let text = present_slot("text");
    let alias_to_never = present_slot("alias-to-never");
    let alias_to_text = present_slot("alias-to-text");
    let never = present_slot("never");
    let shape = |slot: &SlotContract| graph.find_type(&slot.type_ref).unwrap().shape.clone();
    let pair = |source: &SlotContract, destination: &SlotContract| composition::TypePair {
        source: source.clone(),
        destination: destination.clone(),
        source_tag: None,
    };
    let entries = vec![
        composition::PairEntry {
            pair: pair(&text, &alias_to_never),
            source_shape: shape(&text),
            destination_shape: shape(&alias_to_never),
            rule: composition::InclusionRule::UnfoldDestination,
            children: vec![BigUint::from(2u8)],
        },
        composition::PairEntry {
            pair: pair(&text, &alias_to_text),
            source_shape: shape(&text),
            destination_shape: shape(&text),
            rule: composition::InclusionRule::UnfoldDestination,
            children: vec![],
        },
        composition::PairEntry {
            pair: pair(&text, &never),
            source_shape: shape(&text),
            destination_shape: shape(&never),
            rule: composition::InclusionRule::StringConditions,
            children: vec![],
        },
    ];
    let certificate = composition::InclusionCertificate {
        basis: composition::SemanticBasis::of(&graph),
        source: text.clone(),
        destination: alias_to_never.clone(),
        empty_types: vec![],
        pairs: entries,
        root: BigUint::from(0u8),
    };
    assert_eq!(
        inclusion::verify_inclusion(&graph, &text, &alias_to_never, &certificate).map(|_| ()),
        Err(composition::InclusionFailure::Unresolved(
            composition::TypeObligation {
                pair: pair(&text, &never),
                path: vec![],
                reason: composition::TypeObligationReason::ConstraintImplication,
            }
        ))
    );
}

#[test]
fn union_child_coverage_precedes_union_remainder_as_lean_does() {
    let mut library = union_fixture().0;
    library.nodes.push(TypeNodeInput {
        id: "empty-union".into(),
        shape: Shape::TaggedUnion(SignatureUnion { branches: vec![] }),
    });
    let graph = check_type_signatures(&library).unwrap();
    let source = present_slot("source-union");
    let destination = present_slot("empty-union");
    let entry = composition::PairEntry {
        pair: composition::TypePair {
            source: source.clone(),
            destination: destination.clone(),
            source_tag: None,
        },
        source_shape: graph.find_type(&source.type_ref).unwrap().shape.clone(),
        destination_shape: graph
            .find_type(&destination.type_ref)
            .unwrap()
            .shape
            .clone(),
        rule: composition::InclusionRule::SourceUnion,
        children: vec![BigUint::from(0u8)],
    };
    let certificate = composition::InclusionCertificate {
        basis: composition::SemanticBasis::of(&graph),
        source: source.clone(),
        destination: destination.clone(),
        empty_types: vec![],
        pairs: vec![entry],
        root: BigUint::from(0u8),
    };
    assert!(matches!(
        inclusion::verify_inclusion(&graph, &source, &destination, &certificate),
        Err(composition::InclusionFailure::ChildCoverage(0))
    ));
}
