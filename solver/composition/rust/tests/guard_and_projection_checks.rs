// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

#![allow(
    clippy::indexing_slicing,
    clippy::panic,
    clippy::result_large_err,
    clippy::unwrap_used
)]
use necoherence::exact_json_view::JsonValueView;
use necoherence::semantic_composition::{borrowed_slot, GuardArm, GuardKind, WitnessFailure};
use necoherence::semantic_types::*;
use necoherence::semantic_validation::*;
use necoherence::signature_admission::check_type_signatures;
use necoherence::signature_admission::*;
use semantic_value_samples::{v2a_library, v2a_reference};

fn guard_declaration(
    id: &str,
    source_type: TypeRef,
    path: Vec<PathStep>,
    kind: GuardKind,
) -> necoherence::semantic_composition::DeclaredGuard {
    necoherence::semantic_composition::DeclaredGuard {
        id: necoherence::semantic_composition::GuardId(id.into()),
        source_type,
        path,
        kind,
    }
}

fn missing_evidence(reason: &str) -> std::result::Result<GuardArm, WitnessFailure> {
    std::result::Result::Err(WitnessFailure::MissingEvidence(reason.to_owned()))
}

#[test]
fn prepared_guard_variants_match_lean_arms_and_missing_evidence() {
    use necoherence::semantic_composition::{present_contract, GuardArmView, PreparedGuard};
    use necoherence_composition_solver::search_state::evaluate_guard_arm;
    let library = semantic_value_samples::library();
    let graph = check_type_signatures(&library).unwrap();
    let choice = signature_type_ref("choice");
    let text = signature_type_ref("text");
    let tag_key = graph.profile.tag.as_ref().unwrap().key.clone();
    let declaration = guard_declaration("choice", choice.clone(), vec![], GuardKind::Variants);
    let contract = present_contract(choice);
    let validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
    let mut prepared = PreparedGuard::new(&validator, declaration.clone());
    let tagged = |tag: JsonValue| JsonValue::Obj(vec![(tag_key.clone(), tag)]);
    let cases: Vec<(
        SlotValue<JsonValue>,
        std::result::Result<GuardArm, WitnessFailure>,
    )> = vec![
        (SlotValue::Absent, Ok(GuardArm::Absent)),
        (SlotValue::Null, Ok(GuardArm::Null)),
        (
            SlotValue::Present(tagged(JsonValue::Str("sealed".into()))),
            Ok(GuardArm::Variant("sealed".into())),
        ),
        (
            SlotValue::Present(tagged(JsonValue::Str("unlisted".into()))),
            missing_evidence("union branch selection"),
        ),
        (
            SlotValue::Present(tagged(JsonValue::Num(1.into()))),
            missing_evidence("union discriminator"),
        ),
        (
            SlotValue::Present(JsonValue::Obj(vec![])),
            missing_evidence("union discriminator"),
        ),
        (
            SlotValue::Present(JsonValue::Str("text".into())),
            missing_evidence("union guard value"),
        ),
    ];
    for (value, expected) in &cases {
        let owned = evaluate_guard_arm(&graph, &declaration, &contract, borrowed_slot(value));
        let view = match value {
            SlotValue::Absent => SlotValue::Absent,
            SlotValue::Null => SlotValue::Null,
            SlotValue::Present(json) => SlotValue::Present(JsonValueView::from_json(json)),
        };
        let arm = prepared
            .evaluate(&contract, view)
            .map(GuardArmView::into_owned);
        assert_eq!(arm, *expected, "{value:?}");
        assert_eq!(owned, *expected, "{value:?}");
    }
    let sealed = tagged(JsonValue::Str("sealed".into()));
    assert_eq!(
        evaluate_guard_arm(
            &graph,
            &declaration,
            &present_contract(text),
            SlotValue::Present(&sealed),
        ),
        missing_evidence("union guard source"),
    );
}

#[test]
fn prepared_guard_selects_union_branch_by_member_shape_like_lean() {
    use necoherence::semantic_composition::present_contract;
    use necoherence::type_signatures::{
        Shape, SignatureUnion, SignatureUnionBranch, TypeNodeInput,
    };
    use necoherence_composition_solver::search_state::evaluate_guard_arm;
    let mut library = semantic_value_samples::library();
    library.nodes.push(TypeNodeInput {
        id: "shaped".into(),
        shape: Shape::TaggedUnion(SignatureUnion {
            branches: vec![SignatureUnionBranch {
                target: "text".into(),
                wire_tag: "bare".into(),
                selector: BranchSelector::MemberShape(vec![("m".into(), MemberTest::Absent)]),
            }],
        }),
    });
    let graph = check_type_signatures(&library).unwrap();
    let shaped = signature_type_ref("shaped");
    let tag_key = graph.profile.tag.as_ref().unwrap().key.clone();
    let declaration = guard_declaration("shaped", shaped.clone(), vec![], GuardKind::Variants);
    let value = JsonValue::Obj(vec![(tag_key, JsonValue::Str("unlisted".into()))]);
    assert_eq!(
        evaluate_guard_arm(
            &graph,
            &declaration,
            &present_contract(shaped),
            SlotValue::Present(&value),
        ),
        Ok(GuardArm::Variant("bare".into())),
    );
}

#[test]
fn prepared_guard_presence_and_validate_match_owned_arms() {
    use necoherence::semantic_composition::{present_contract, GuardArmView, PreparedGuard};
    use necoherence_composition_solver::search_state::evaluate_guard_arm;
    let library = v2a_library();
    let graph = check_type_signatures(&library).unwrap();
    let text = v2a_reference(&graph, "plain");
    let validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
    let contract = present_contract(text.clone());
    let presence = guard_declaration("presence", text.clone(), vec![], GuardKind::Presence);
    let mut presence_guard = PreparedGuard::new(&validator, presence.clone());
    for (value, want) in [
        (SlotValue::Absent, GuardArm::Absent),
        (SlotValue::Null, GuardArm::Null),
        (SlotValue::Present(JsonValue::Null), GuardArm::Present),
    ] {
        let view = match &value {
            SlotValue::Absent => SlotValue::Absent,
            SlotValue::Null => SlotValue::Null,
            SlotValue::Present(json) => SlotValue::Present(JsonValueView::from_json(json)),
        };
        let arm = presence_guard
            .evaluate(&contract, view)
            .map(GuardArmView::into_owned);
        assert_eq!(arm, Ok(want.clone()));
        assert_eq!(
            evaluate_guard_arm(&graph, &presence, &contract, borrowed_slot(&value)),
            Ok(want)
        );
    }
    let slot = SlotContract {
        type_ref: text.clone(),
        required: true,
        nullable: false,
    };
    let validate = guard_declaration("validate", text, vec![], GuardKind::Validate(slot));
    let mut validate_guard = PreparedGuard::new(&validator, validate.clone());
    let accepted = JsonValue::Str("abc".into());
    let arm = validate_guard
        .evaluate(
            &contract,
            SlotValue::Present(JsonValueView::from_json(&accepted)),
        )
        .map(GuardArmView::into_owned);
    assert_eq!(arm, Ok(GuardArm::Accepted));
    assert_eq!(
        evaluate_guard_arm(&graph, &validate, &contract, SlotValue::Present(&accepted)),
        Ok(GuardArm::Accepted)
    );
    let absent = validate_guard
        .evaluate(&contract, SlotValue::Absent)
        .map(GuardArmView::into_owned);
    assert_eq!(absent, Ok(GuardArm::Rejected));
    assert_eq!(
        evaluate_guard_arm(&graph, &validate, &contract, SlotValue::Absent),
        Ok(GuardArm::Rejected)
    );
}

#[test]
fn prepared_guard_unresolved_validation_is_missing_evidence() {
    use necoherence::semantic_composition::{present_contract, GuardArmView, PreparedGuard};
    use necoherence_composition_solver::search_state::evaluate_guard_arm;
    let graph =
        semantic_value_samples::recursive_graph(vec![semantic_value_samples::recursive_node(
            "P",
            semantic_value_samples::recursive_product(&[("a", "Missing")]),
        )]);
    let product = semantic_value_samples::recursive_ref("P");
    let missing = semantic_value_samples::recursive_ref("Missing");
    let declaration = guard_declaration(
        "unresolved",
        product.clone(),
        vec![],
        GuardKind::Validate(SlotContract {
            type_ref: missing,
            required: true,
            nullable: false,
        }),
    );
    let validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
    let mut prepared = PreparedGuard::new(&validator, declaration.clone());
    let contract = present_contract(product);
    let payload = JsonValue::Bool(true);
    let expected = missing_evidence("validation guard meaning");
    let arm = prepared
        .evaluate(
            &contract,
            SlotValue::Present(JsonValueView::from_json(&payload)),
        )
        .map(GuardArmView::into_owned);
    assert_eq!(arm, expected);
    assert_eq!(
        evaluate_guard_arm(
            &graph,
            &declaration,
            &contract,
            SlotValue::Present(&payload)
        ),
        expected
    );
}

mod semantic_value_samples {
    #![allow(
        clippy::expect_used,
        clippy::unwrap_used,
        clippy::panic,
        clippy::indexing_slicing
    )]
    use necoherence::semantic_types::*;
    use necoherence::signature_admission::*;
    use necoherence::type_signatures::*;
    use num_bigint::{BigInt, BigUint};

    pub fn reference() -> ProfileRef {
        ProfileRef {
            identity: "p".into(),
            revision: "1".into(),
            content_digest: "a".repeat(64),
        }
    }

    pub fn profile() -> ValueSemanticProfile {
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

    pub(crate) fn recursive_graph(nodes: Vec<TypeNode>) -> SemanticGraph {
        SemanticGraph {
            profile: check_type_signatures(&library()).unwrap().profile,
            nodes,
            source_refs: vec![],
        }
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
}
