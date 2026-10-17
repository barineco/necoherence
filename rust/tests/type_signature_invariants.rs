// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT
#![allow(clippy::expect_used, clippy::unwrap_used)]
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
use necoherence::typed_mapping as resource;
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
    let choice = signature_type_ref(&subject, &canonical_digest(&subject), "choice");
    for (index, tag) in ["com.example.a", "com.example.b"].iter().enumerate() {
        let value = JsonValue::Obj(vec![("$type".into(), JsonValue::Str((*tag).into()))]);
        assert_eq!(select_branch(&graph, &choice, &value).unwrap(), index);
    }
    assert!(select_branch(
        &graph,
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
        "../../presets/atproto-data-model/profile.json"
    ))
    .unwrap();
    preset.nodes.retain(|node| node.id != "sealed");
    if let Shape::String(spec) = &mut fixture_item_mut(&mut preset.nodes, 0).shape {
        spec.format = None;
    }
    check_library(&preset).unwrap();
    let preset_graph = check_type_signatures(&preset).unwrap();
    let preset_choice = signature_type_ref(&preset, &canonical_digest(&preset), "choice");
    for (index, tag) in ["com.example.a", "com.example.b"].iter().enumerate() {
        let value = JsonValue::Obj(vec![("$type".into(), JsonValue::Str((*tag).into()))]);
        assert_eq!(
            select_branch(&preset_graph, &preset_choice, &value).unwrap(),
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

fn solved_signature_composition(
    library: &TypeSignatureLibrary,
    problem: &composition::CompositionInput,
) -> SignatureComposition {
    let graph = check_type_signatures(library).unwrap();
    let prepared = composition::prepare_composition(&graph, problem.clone()).unwrap();
    let state = composition::initial_state(&prepared);
    let enumeration =
        composition::enumerate_state(&prepared, &state, &mut composition::CandidateBudget::new());
    let terminal = fixture_item(&enumeration.terminals, 0).clone();
    let trace = composition::BranchTrace {
        steps: vec![],
        terminal: terminal.clone(),
    };
    let (lowering, correspondence) = composition::lower_resource_trace(&prepared, &trace).unwrap();
    assert!(lowering.transitions.is_empty());
    let raw = composition::RawComposition {
        plan: composition::CompositionPlan {
            input_identity: problem.identity.clone(),
            input_revision: problem.revision.clone(),
            root: composition::PlanTree {
                rank: 0,
                node: composition::PlanNode::Return(terminal),
            },
        },
        witness: composition::CompositionWitness {
            input_snapshot: problem.clone(),
            initial_membership: composition::initial_membership(&prepared).unwrap(),
            resource_traces: vec![composition::ResourceTraceCertificate {
                trace,
                correspondence,
                reachability: resource::ReachabilityWitness {
                    path: vec![],
                    final_marking: lowering.marking.clone(),
                },
                acyclicity: resource::AcyclicWitness {
                    explored_markings: vec![lowering.marking.clone()],
                    steps: BigUint::from(1u8),
                    frontier: vec![],
                },
                lowering,
                value_sources: vec![(
                    composition::ProducerRef::Initial(composition::InputId("initial".into())),
                    SlotValue::Present(JsonValue::Bool(false)),
                )],
            }],
        },
        selection: Arc::new(composition::SelectionEvidence::AnyFeasible),
    };
    let checked = composition::verify_composition(&prepared, &raw).unwrap();
    signature_composition_from_native(library, problem, checked.raw(), &[]).unwrap()
}

#[test]
fn permitted_projection_source_type_roundtrip_preserves_path_and_coordinates() {
    let (library, mut problem) = composition_fixture();
    let reference = signature_type_ref(&library, &canonical_digest(&library), "record");
    problem
        .invocation_domain
        .permitted_projections
        .push(composition::PermittedProjection {
            source_type: reference.clone(),
            path: vec![PathStep::Field("flag".into())],
        });
    let wire = solved_signature_composition(&library, &problem);
    assert_eq!(
        wire.problem
            .pointer("/invocation_domain/permitted_projections/0/source_type")
            .and_then(serde_json::Value::as_str),
        Some("record")
    );
    let decoded = decode_signature_problem(&library, &wire.problem).unwrap();
    assert_eq!(decoded, problem);
    assert_eq!(
        fixture_item(&decoded.invocation_domain.permitted_projections, 0).source_type,
        reference
    );
    assert_eq!(decoded.basis, problem.basis);
    assert_eq!(
        wire.problem
            .pointer("/basis/library_identity")
            .and_then(serde_json::Value::as_str),
        Some(library.identity.as_str())
    );
    assert_eq!(
        wire.problem
            .pointer("/basis/library_revision")
            .and_then(serde_json::Value::as_str),
        Some(library.revision.as_str())
    );
}

#[test]
fn declared_guard_source_type_roundtrip_preserves_id_path_and_kind() {
    let (library, mut problem) = composition_fixture();
    let reference = signature_type_ref(&library, &canonical_digest(&library), "record");
    problem
        .invocation_domain
        .guards
        .push(composition::DeclaredGuard {
            id: composition::GuardId("flag-guard".into()),
            source_type: reference,
            path: vec![PathStep::Field("flag".into())],
            kind: composition::GuardKind::Validate(SlotContract {
                type_ref: signature_type_ref(&library, &canonical_digest(&library), "boolean"),
                required: true,
                nullable: false,
            }),
        });
    let wire = solved_signature_composition(&library, &problem);
    assert_eq!(
        wire.problem
            .pointer("/invocation_domain/guards/0/source_type")
            .and_then(serde_json::Value::as_str),
        Some("record")
    );
    let decoded = decode_signature_problem(&library, &wire.problem).unwrap();
    assert_eq!(
        decoded.invocation_domain.guards,
        problem.invocation_domain.guards
    );
    assert_eq!(decoded, problem);
}

#[test]
fn minimal_solved_projection_composition_public_roundtrip() {
    let (library, mut problem) = composition_fixture();
    problem
        .invocation_domain
        .permitted_projections
        .push(composition::PermittedProjection {
            source_type: signature_type_ref(&library, &canonical_digest(&library), "boolean"),
            path: vec![],
        });
    let wire = solved_signature_composition(&library, &problem);
    let decoded = decode_signature_problem(&library, &wire.problem).unwrap();
    assert_eq!(decoded, problem);
    assert_eq!(solved_signature_composition(&library, &decoded), wire);
    let input = assemble_signature_generation(library, Some(wire), vec![]).unwrap();
    admit_signature_generation(&input.basis.clone(), input).unwrap();
}

#[test]
fn unknown_source_type_is_a_typed_composition_admission_failure() {
    for role in ["permitted_projections", "guards"] {
        let (library, problem) = composition_fixture();
        let mut wire = solved_signature_composition(&library, &problem);
        let entry = if role == "guards" {
            serde_json::json!({
                "id": "unknown-guard", "source_type": "unknown", "path": [],
                "kind": {"tag": "Presence"}
            })
        } else {
            serde_json::json!({"source_type": "unknown", "path": []})
        };
        *wire
            .problem
            .get_mut("invocation_domain")
            .and_then(|domain| domain.get_mut(role))
            .expect("declared source type role exists") = serde_json::json!([entry]);
        assert!(matches!(
            decode_signature_problem(&library, &wire.problem),
            Err(GenerationFailure::Encoding(reason)) if reason.contains("UnresolvedType")
        ));
        let input = assemble_signature_generation(library, Some(wire), vec![]).unwrap();
        assert!(matches!(
            admit_signature_generation(&input.basis.clone(), input),
            Err(AdmissionFailure::Composition(_))
        ));
    }
}

#[test]
fn bounded_scalar_product_inclusion_and_composition() {
    for (text, cid) in [
        ("generic".to_owned(), false),
        (format!("bafkrei{}", "a".repeat(52)), true),
    ] {
        let (mut library, mut problem) = composition_fixture();
        if cid {
            let preset = decode_value_profile(include_str!(
                "../../presets/atproto-data-model/profile.json"
            ))
            .unwrap();
            let rule = preset
                .format_bindings
                .iter()
                .find(|binding| binding.name == "cid")
                .unwrap()
                .rule
                .clone();
            library.profile.format_bindings.push(FormatBinding {
                name: "cid".into(),
                reference: reference(),
                rule,
            });
        }
        library.nodes.push(TypeNodeInput {
            id: "bounded-scalar".into(),
            shape: Shape::String(StringSpec {
                format: if cid {
                    Some(FormatUse::Named("cid".into()))
                } else {
                    Some(FormatUse::Inline(FormatRule::Literal(text.clone())))
                },
                lengths: vec![],
                wrapper: None,
                const_value: None,
                enum_values: None,
                examples: vec![],
                default_value: None,
            }),
        });
        for (id, names) in [
            (
                "getRecord-parameters",
                vec![
                    ("repo", true),
                    ("collection", true),
                    ("rkey", true),
                    ("cid", false),
                ],
            ),
            ("errorBody", vec![("error", true), ("message", false)]),
            ("cid-holder", vec![("cid", true)]),
        ] {
            library.nodes.push(TypeNodeInput {
                id: id.into(),
                shape: Shape::Product(SignatureProduct {
                    fields: names
                        .into_iter()
                        .map(|(name, required)| SignatureField {
                            wire_name: name.into(),
                            slot: SignatureSlot {
                                type_id: "bounded-scalar".into(),
                                required,
                                nullable: false,
                            },
                        })
                        .collect(),
                    extras: SignatureExtraMembers::Reject,
                }),
            });
        }
        let graph = check_type_signatures(&library).unwrap();
        let slot = |id| SlotContract {
            type_ref: signature_type_ref(&library, &canonical_digest(&library), id),
            required: true,
            nullable: false,
        };
        let source = slot("bounded-scalar");
        let length = text.len();
        if cid {
            assert_eq!(length, 59);
        }
        for maximum in [length - 1, length] {
            let bounds = composition::SearchBounds {
                max_sample_length: maximum,
                ..Default::default()
            };
            for destination in ["getRecord-parameters", "errorBody"] {
                let destination = slot(destination);
                let samples = composition::inclusion_samples_bounded(
                    &graph,
                    &source.type_ref,
                    &destination.type_ref,
                    &bounds,
                );
                let decision =
                    composition::check_assignable_bounded(&graph, &source, &destination, &bounds);
                if maximum < length {
                    assert!(samples.values.is_empty());
                    assert!(samples
                        .obligations
                        .contains(&composition::SampleObligation::SampleBound));
                    assert!(matches!(
                        decision,
                        composition::CompatibilityDecision::Unknown(_)
                    ));
                } else {
                    assert!(samples.values.contains(&JsonValue::Str(text.clone())));
                    let certificate = match decision {
                        composition::CompatibilityDecision::Incompatible(certificate) => {
                            Some(certificate)
                        }
                        _ => None,
                    }
                    .expect("expected counterexample");
                    assert!(
                        matches!(certificate.value, SlotValue::Present(JsonValue::Str(ref value)) if value.len() == length)
                    );
                    assert_eq!(
                        certificate.destination_failure.condition,
                        ValueCondition::WrongValueKind("object".into())
                    );
                    composition::verify_counterexample(&graph, &certificate).unwrap();
                }
            }
            let holder = slot("cid-holder");
            let projection =
                composition::project_slot(&graph, &holder, &[PathStep::Field("cid".into())], &[])
                    .unwrap();
            assert!(matches!(
                composition::check_assignable_bounded(
                    &graph,
                    &projection.destination,
                    &source,
                    &bounds
                ),
                composition::CompatibilityDecision::Compatible(_)
            ));
            problem.basis = composition::SemanticBasis::of(&graph);
            fixture_item_mut(&mut problem.initial_inputs, 0).contract = source.clone();
            fixture_item_mut(&mut problem.goal.outputs, 0).contract = slot("getRecord-parameters");
            problem.goal.outputs.push(composition::GoalPort {
                id: composition::GoalPortId("error".into()),
                contract: slot("errorBody"),
                source_constraint: composition::SourceConstraint::AnyCompatible,
            });
            problem.bounds = bounds;
            let prepared = composition::prepare_composition(&graph, problem.clone()).unwrap();
            let enumeration = composition::enumerate_state(
                &prepared,
                &composition::initial_state(&prepared),
                &mut composition::CandidateBudget::new(),
            );
            assert!(enumeration.terminals.is_empty());
            if maximum < length {
                assert!(!enumeration.unknown.is_empty());
            } else {
                assert!(enumeration.unknown.is_empty());
                assert!(enumeration
                    .failures
                    .iter()
                    .any(|failure| failure.destination == slot("getRecord-parameters")));
                assert!(enumeration
                    .failures
                    .iter()
                    .any(|failure| failure.destination == slot("errorBody")));
            }
            problem.goal.outputs.truncate(1);
        }
    }
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
    let source = signature_type_ref(&library, &canonical_digest(&library), "extras-source");
    let destination =
        signature_type_ref(&library, &canonical_digest(&library), "field-destination");
    for maximum in [0, 1] {
        let samples = composition::inclusion_samples_bounded(
            &graph,
            &source,
            &destination,
            &composition::SearchBounds {
                max_sample_length: maximum,
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
        assert!(samples
            .values
            .iter()
            .all(|value| accepts_value(&graph, &source, value) == ValueDecision::Accepted));
    }
}

fn single_output_composition(
    library: &TypeSignatureLibrary,
    output_type: &str,
    bounds: SearchBounds,
) -> (
    SemanticGraph,
    composition::CompositionInput,
    composition::InvocationPlan,
    composition::OutcomeId,
    composition::PortId,
    SlotContract,
) {
    let graph = check_type_signatures(library).unwrap();
    let contract = SlotContract {
        type_ref: signature_type_ref(library, &canonical_digest(library), output_type),
        required: true,
        nullable: false,
    };
    let function = composition::FunctionRef {
        identity: "produce-output".into(),
        revision: "1".into(),
        content_digest: "b".repeat(64),
    };
    let site = composition::SiteId("producer-site".into());
    let outcome = composition::OutcomeId("success".into());
    let port = composition::PortId("output".into());
    let problem = composition::CompositionInput {
        identity: "first-witness-regression".into(),
        revision: "1".into(),
        basis: composition::SemanticBasis::of(&graph),
        signatures: vec![composition::FunctionSignature {
            reference: function.clone(),
            form: composition::FunctionForm::DeclaredTransform,
            effect: composition::CompositionEffect::PureFunction,
            inputs: vec![],
            outcomes: vec![composition::OutcomeContract {
                id: outcome.clone(),
                form: composition::OutcomeForm::Success,
                value_ports: vec![composition::OutputPort {
                    id: port.clone(),
                    contract: contract.clone(),
                    resource_production: None,
                }],
                produced_resources: vec![],
            }],
            resource_inputs: vec![],
            assumption_ref: "inhabitation witness regression".into(),
            handles_failure: None,
        }],
        initial_inputs: vec![],
        initial_resources: vec![],
        goal: composition::GoalSpec {
            outputs: vec![composition::GoalPort {
                id: composition::GoalPortId("result".into()),
                contract: contract.clone(),
                source_constraint: composition::SourceConstraint::ProducedBy {
                    site: site.clone(),
                    outcome: outcome.clone(),
                    port: port.clone(),
                    path: vec![],
                },
            }],
            failures: vec![],
            final_resources: vec![],
        },
        invocation_domain: composition::InvocationDomain {
            identity: "one-site-domain".into(),
            revision: "1".into(),
            sites: vec![composition::InvocationSite {
                id: site.clone(),
                function: function.clone(),
            }],
            permitted_projections: vec![],
            permitted_constructions: vec![],
            permitted_transforms: vec![function.clone()],
            guards: vec![],
        },
        allowed_effects: vec![composition::CompositionEffect::PureFunction],
        explicit_order: vec![],
        selection_policy: Some(composition::SelectionPolicy::AnyFeasible),
        bounds,
    };
    let invocation = composition::InvocationPlan {
        site,
        function,
        bindings: vec![],
        resources: vec![],
    };
    (graph, problem, invocation, outcome, port, contract)
}

fn state_after_output(
    invocation: &composition::InvocationPlan,
    outcome: &composition::OutcomeId,
    port: &composition::PortId,
    contract: &SlotContract,
) -> composition::SearchState {
    let producer = composition::ProducerRef::InvocationOutcome {
        site: invocation.site.clone(),
        outcome: outcome.clone(),
        port: port.clone(),
    };
    composition::SearchState {
        available: vec![composition::AvailableValue {
            producer,
            contract: contract.clone(),
            resource: None,
        }],
        used_sites: vec![invocation.site.clone()],
        used_guards: vec![],
        facts: vec![],
        trace: vec![composition::TraceStep::Invocation {
            invocation: invocation.clone(),
            outcome: outcome.clone(),
        }],
        pending_failure: None,
    }
}

fn resource_acyclic_witness(input: &resource::SolverInput) -> resource::AcyclicWitness {
    let mut explored = vec![input.marking.clone()];
    let mut cursor = 0;
    while cursor < explored.len() {
        let marking = fixture_item(&explored, cursor).clone();
        for transition in &input.transitions {
            let bindings = resource::bindings_for(input, &transition.identity);
            if resource::transition_enabled_at(&bindings, &marking) {
                let next = resource::apply_branch_at(&marking, transition, &bindings);
                if !explored.contains(&next) {
                    explored.push(next);
                }
            }
        }
        cursor += 1;
    }
    resource::AcyclicWitness {
        steps: BigUint::from(explored.len()),
        explored_markings: explored,
        frontier: vec![],
    }
}

#[allow(clippy::too_many_arguments)]
fn verify_single_output_binding(
    prepared: &composition::PreparedCompositionInput<'_>,
    problem: &composition::CompositionInput,
    invocation: &composition::InvocationPlan,
    outcome: &composition::OutcomeId,
    port: &composition::PortId,
    state: &composition::SearchState,
    terminal: composition::ReturnPlan,
    value: SlotValue,
) {
    let trace = composition::BranchTrace {
        steps: state.trace.clone(),
        terminal: terminal.clone(),
    };
    let (lowering, correspondence) = composition::lower_resource_trace(prepared, &trace).unwrap();
    let mut final_marking = lowering.marking.clone();
    for identity in &correspondence.execution_order {
        let transition = lowering
            .transitions
            .iter()
            .find(|transition| transition.identity == *identity)
            .unwrap();
        let bindings = resource::bindings_for(&lowering, identity);
        assert!(resource::transition_enabled_at(&bindings, &final_marking));
        final_marking = resource::apply_branch_at(&final_marking, transition, &bindings);
    }
    let producer = composition::ProducerRef::InvocationOutcome {
        site: invocation.site.clone(),
        outcome: outcome.clone(),
        port: port.clone(),
    };
    let raw = composition::RawComposition {
        plan: composition::CompositionPlan {
            input_identity: problem.identity.clone(),
            input_revision: problem.revision.clone(),
            root: composition::PlanTree {
                rank: 0,
                node: composition::PlanNode::Invoke {
                    invocation: invocation.clone(),
                    arms: vec![(
                        outcome.clone(),
                        composition::PlanTree {
                            rank: 1,
                            node: composition::PlanNode::Return(terminal),
                        },
                    )],
                    empty_outcomes: vec![],
                },
            },
        },
        witness: composition::CompositionWitness {
            input_snapshot: problem.clone(),
            initial_membership: composition::initial_membership(prepared).unwrap(),
            resource_traces: vec![composition::ResourceTraceCertificate {
                trace,
                correspondence: correspondence.clone(),
                reachability: resource::ReachabilityWitness {
                    path: correspondence.execution_order.clone(),
                    final_marking,
                },
                acyclicity: resource_acyclic_witness(&lowering),
                lowering,
                value_sources: vec![(producer, value)],
            }],
        },
        selection: Arc::new(composition::SelectionEvidence::AnyFeasible),
    };
    composition::verify_composition(prepared, &raw).unwrap();
}

#[test]
fn first_witness_binds_optional_nested_product_union_absence() {
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
    library.nodes.push(TypeNodeInput {
        id: "record-choice".into(),
        shape: Shape::TaggedUnion(SignatureUnion {
            branches: vec![
                SignatureUnionBranch {
                    target: "record".into(),
                    wire_tag: "record".into(),
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
    library.nodes.push(TypeNodeInput {
        id: "optional-envelope".into(),
        shape: Shape::Product(SignatureProduct {
            fields: vec![SignatureField {
                wire_name: "nested".into(),
                slot: SignatureSlot {
                    type_id: "record-choice".into(),
                    required: false,
                    nullable: false,
                },
            }],
            extras: SignatureExtraMembers::Reject,
        }),
    });
    let (graph, problem, invocation, outcome, port, contract) =
        single_output_composition(&library, "optional-envelope", SearchBounds::default());
    let samples = slot_samples(&graph, &problem.bounds, &contract);
    assert_eq!(
        samples.values.first(),
        Some(&SlotValue::Present(JsonValue::Obj(vec![])))
    );
    let prepared = composition::prepare_composition(&graph, problem.clone()).unwrap();
    let state = state_after_output(&invocation, &outcome, &port, &contract);
    let enumeration =
        composition::enumerate_state(&prepared, &state, &mut composition::CandidateBudget::new());
    assert!(enumeration.unknown.is_empty());
    let terminal = fixture_item(&enumeration.terminals, 0).clone();
    assert!(matches!(
        &terminal,
        composition::ReturnPlan::Success(bindings)
            if matches!(&fixture_item(bindings, 0).1,
                composition::BindingExpr::Source {
                    value: composition::ValueRef {
                        producer: composition::ProducerRef::InvocationOutcome { .. },
                        path,
                    },
                    ..
                } if path.is_empty())
    ));
    verify_single_output_binding(
        &prepared,
        &problem,
        &invocation,
        &outcome,
        &port,
        &state,
        terminal,
        SlotValue::Present(JsonValue::Obj(vec![])),
    );
}

#[test]
fn accepted_constant_beyond_sample_bound_produces_verified_source_binding() {
    let mut library = library();
    let constant = "x".repeat(64);
    library.nodes.push(TypeNodeInput {
        id: "oversized-constant".into(),
        shape: Shape::String(StringSpec {
            format: None,
            lengths: vec![],
            wrapper: None,
            const_value: Some(constant.clone()),
            enum_values: None,
            examples: vec![],
            default_value: None,
        }),
    });
    let bounds = SearchBounds {
        max_sample_length: 59,
        ..SearchBounds::default()
    };
    let (graph, problem, invocation, outcome, port, contract) =
        single_output_composition(&library, "oversized-constant", bounds);
    let bounded = slot_samples(&graph, &problem.bounds, &contract);
    assert!(bounded.values.is_empty());
    assert!(bounded
        .obligations
        .contains(&composition::SampleObligation::SampleBound));
    let reference = contract.type_ref.clone();
    let value = JsonValue::Str(constant);
    assert_eq!(
        accepts_value(&graph, &reference, &value),
        ValueDecision::Accepted
    );
    let prepared = composition::prepare_composition(&graph, problem.clone()).unwrap();
    let state = state_after_output(&invocation, &outcome, &port, &contract);
    let enumeration =
        composition::enumerate_state(&prepared, &state, &mut composition::CandidateBudget::new());
    assert!(enumeration.unknown.is_empty());
    assert!(enumeration.terminals.iter().any(|terminal| matches!(
        terminal,
        composition::ReturnPlan::Success(bindings)
            if matches!(&fixture_item(bindings, 0).1,
                composition::BindingExpr::Source {
                    value: composition::ValueRef {
                        producer: composition::ProducerRef::InvocationOutcome { .. },
                        path,
                    },
                    ..
                } if path.is_empty())
    )));
    verify_single_output_binding(
        &prepared,
        &problem,
        &invocation,
        &outcome,
        &port,
        &state,
        fixture_item(&enumeration.terminals, 0).clone(),
        SlotValue::Present(value),
    );
}

#[test]
fn shallow_product_fuel_returns_inhabitation_unknown_without_binding() {
    let mut library = library();
    library.nodes.extend([
        TypeNodeInput {
            id: "deep-one".into(),
            shape: Shape::Product(SignatureProduct {
                fields: vec![SignatureField {
                    wire_name: "flag".into(),
                    slot: SignatureSlot {
                        type_id: "text".into(),
                        required: true,
                        nullable: false,
                    },
                }],
                extras: SignatureExtraMembers::Reject,
            }),
        },
        TypeNodeInput {
            id: "deep-two".into(),
            shape: Shape::Product(SignatureProduct {
                fields: vec![SignatureField {
                    wire_name: "child".into(),
                    slot: SignatureSlot {
                        type_id: "deep-one".into(),
                        required: true,
                        nullable: false,
                    },
                }],
                extras: SignatureExtraMembers::Reject,
            }),
        },
        TypeNodeInput {
            id: "deep-three".into(),
            shape: Shape::Product(SignatureProduct {
                fields: vec![SignatureField {
                    wire_name: "child".into(),
                    slot: SignatureSlot {
                        type_id: "deep-two".into(),
                        required: true,
                        nullable: false,
                    },
                }],
                extras: SignatureExtraMembers::Reject,
            }),
        },
    ]);
    let bounds = SearchBounds {
        max_type_obligations: 1,
        ..SearchBounds::default()
    };
    let (graph, problem, invocation, outcome, port, contract) =
        single_output_composition(&library, "deep-three", bounds);
    let samples = slot_samples(&graph, &problem.bounds, &contract);
    assert!(samples.values.is_empty());
    assert!(!samples
        .obligations
        .contains(&composition::SampleObligation::SampleBound));
    let prepared = composition::prepare_composition(&graph, problem).unwrap();
    let state = state_after_output(&invocation, &outcome, &port, &contract);
    let enumeration =
        composition::enumerate_state(&prepared, &state, &mut composition::CandidateBudget::new());
    assert!(enumeration.terminals.is_empty());
    assert!(enumeration.unknown.iter().any(|obligation| matches!(
        obligation,
        composition::UnresolvedObligation::Inhabitation {
            producer: composition::ProducerRef::InvocationOutcome {
                site: actual_site,
                outcome: actual_outcome,
                port: actual_port,
            },
            contract: unresolved,
        } if actual_site == &invocation.site
            && actual_outcome == &outcome
            && actual_port == &port
            && unresolved == &contract
    )));
}

#[test]
fn slot_candidate_control_filters_values_and_stops_at_the_selected_witness() {
    let library = library();
    let graph = check_type_signatures(&library).unwrap();
    let contract = SlotContract {
        type_ref: signature_type_ref(&library, &canonical_digest(&library), "text"),
        required: true,
        nullable: false,
    };
    let bounds = SearchBounds {
        max_sample_length: 1,
        ..SearchBounds::default()
    };
    let mut visited = Vec::new();
    let found = composition::find_accepted_slot_candidate(
        &graph,
        &bounds,
        &contract,
        |value, within_bound| {
            assert_eq!(
                accepts_slot(&graph, &contract, composition::borrowed_slot(value)),
                ValueDecision::Accepted,
            );
            visited.push((value.clone(), within_bound));
            if within_bound {
                composition::SlotCandidateControl::Accept
            } else {
                composition::SlotCandidateControl::Continue
            }
        },
    );
    assert!(matches!(
        found,
        composition::SlotCandidateSearch::AcceptedWithinBound(_)
    ));
    assert_eq!(visited.len(), 2);
    assert!(!fixture_item(&visited, 0).1);
    assert!(fixture_item(&visited, 1).1);
    let mut calls = 0;
    let stopped = composition::find_accepted_slot_candidate(&graph, &bounds, &contract, |_, _| {
        calls += 1;
        composition::SlotCandidateControl::StopNoEvidence
    });
    assert_eq!(stopped, composition::SlotCandidateSearch::NoEvidence);
    assert_eq!(calls, 1);
}

#[test]
fn first_array_witness_uses_zero_length_before_uninhabited_items() {
    let mut library = library();
    library.nodes.push(TypeNodeInput {
        id: "empty-array".into(),
        shape: Shape::Array(SignatureArray {
            item: SignatureElementContract {
                type_id: "never".into(),
                nullable: false,
            },
            minimum: Some(BigUint::from(0u8)),
            maximum: Some(BigUint::from(1u8)),
        }),
    });
    let graph = check_type_signatures(&library).unwrap();
    let contract = SlotContract {
        type_ref: signature_type_ref(&library, &canonical_digest(&library), "empty-array"),
        required: true,
        nullable: false,
    };
    let bounds = SearchBounds {
        max_type_obligations: 1,
        ..SearchBounds::default()
    };
    assert!(slot_samples(&graph, &bounds, &contract).values.is_empty());
    let mut calls = 0;
    let found = composition::find_accepted_slot_candidate(&graph, &bounds, &contract, |_, _| {
        calls += 1;
        composition::SlotCandidateControl::Accept
    });
    assert_eq!(
        found,
        composition::SlotCandidateSearch::AcceptedWithinBound(SlotValue::Present(JsonValue::Arr(
            vec![]
        ))),
    );
    assert_eq!(calls, 1);
}
