// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT
#![allow(clippy::expect_used, clippy::unwrap_used)]
use necoherence::semantic_refinement::*;
use necoherence::semantic_types::*;
use necoherence::semantic_validation::*;
use necoherence::signature_admission::*;
use necoherence::type_signatures::*;
use num_bigint::{BigInt, BigUint};
use proptest::prelude::*;

#[allow(clippy::result_large_err)]
fn evaluate_with_graph(
    graph: &SemanticGraph,
    reference: &TypeRef,
    value: &JsonValue,
) -> SemanticEvaluation {
    evaluate_value(
        &mut PreparedValidator::new(graph, FormatWorkspace::empty()),
        reference,
        value,
    )
}

fn fixture_item<T>(items: &[T], index: usize) -> &T {
    items.get(index).expect("fixture item exists")
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

fn entry() -> SignatureEntrypoint {
    SignatureEntrypoint {
        identity: "entry".into(),
        definition: "entry".into(),
    }
}

#[test]
fn semantic_classification_is_total_and_preserves_mixed_reasons_and_provenance() {
    use ReasonDisposition::{Failed, Residual, Stopped};
    let cases = [
        (SemanticReason::UnknownFormat("format".into()), Residual),
        (SemanticReason::MissingGraphemeRules, Residual),
        (SemanticReason::MissingBytesPolicy, Residual),
        (
            SemanticReason::UnknownIntegerDomain("integer".into()),
            Residual,
        ),
        (SemanticReason::UnknownWrapper("wrapper".into()), Residual),
        (SemanticReason::WrapperPayload("wrapper".into()), Failed),
        (SemanticReason::UnknownSealedTag("tag".into()), Residual),
        (SemanticReason::DecimalNotAdmitted, Failed),
        (SemanticReason::IntegerBound, Failed),
        (SemanticReason::OpaqueType("opaque".into()), Residual),
        (SemanticReason::MissingTagModel, Residual),
        (
            SemanticReason::UninterpretedExtension("extension".into()),
            Residual,
        ),
        (SemanticReason::UnresolvedType, Residual),
        (SemanticReason::InvalidProfile("profile".into()), Failed),
        (SemanticReason::MembershipBound, Stopped),
        (
            SemanticReason::CertificateMismatch("certificate".into()),
            Failed,
        ),
        (
            SemanticReason::ProjectionUnavailable("projection".into()),
            Residual,
        ),
    ];
    let type_ref = signature_type_ref("text");
    let provenance = EvaluationProvenance {
        operation: "validate".into(),
        type_ref: type_ref.clone(),
        value_path: vec![],
    };
    let obligation = |reason| SemanticObligation {
        type_ref: type_ref.clone(),
        origin: OccurrenceRef {
            source: type_ref.source.clone(),
            pointer: type_ref.pointer.clone(),
        },
        value_path: vec![],
        profile: reference(),
        reason,
    };
    for (reason, expected) in cases {
        assert_eq!(reason.disposition(), expected);
        let reasons = vec![obligation(reason)];
        let result = classify_value_decision(
            provenance.clone(),
            ValueDecision::Unresolved(reasons.clone()),
        );
        match expected {
            Failed => {
                let result = result.unwrap_err();
                assert_eq!(result.decision, ValueDecision::Unresolved(reasons));
                assert_eq!(result.provenance, provenance);
            }
            Stopped => assert!(
                matches!(result.unwrap(), RefinementOutcome::Stopped { value: SemanticJudgment { decision: ValueDecision::Unresolved(actual), .. }, cause, .. } if actual == reasons && cause == reasons)
            ),
            Residual => assert!(
                matches!(result.unwrap(), RefinementOutcome::Residual { value: SemanticJudgment { decision: ValueDecision::Unresolved(actual), .. }, residuals } if actual == reasons && residuals.iter().cloned().collect::<Vec<_>>() == reasons)
            ),
        }
    }
    let residual = obligation(SemanticReason::UnknownFormat("format".into()));
    let stop = obligation(SemanticReason::MembershipBound);
    let failure = obligation(SemanticReason::IntegerBound);
    for reasons in [
        vec![residual.clone(), stop.clone(), failure.clone()],
        vec![failure, stop.clone(), residual.clone()],
    ] {
        let result = classify_value_decision(
            provenance.clone(),
            ValueDecision::Unresolved(reasons.clone()),
        )
        .unwrap_err();
        assert_eq!(result.decision, ValueDecision::Unresolved(reasons));
        assert_eq!(result.residuals, ResidualSet::new([residual.clone()]));
        assert!(result.classifications.contains(&Stopped));
    }
    let reasons = vec![residual.clone(), stop.clone(), residual.clone()];
    assert!(
        matches!(classify_value_decision(provenance.clone(), ValueDecision::Unresolved(reasons.clone())).unwrap(), RefinementOutcome::Stopped { value: SemanticJudgment { decision: ValueDecision::Unresolved(actual), .. }, residuals, cause } if actual == reasons && residuals.len() == 1 && cause == vec![stop])
    );
    let empty =
        classify_value_decision(provenance.clone(), ValueDecision::Unresolved(vec![])).unwrap_err();
    assert_eq!(empty.condition, SemanticDecisionCondition::EmptyReasons);
    assert_eq!(empty.provenance, provenance);
}

#[test]
fn signature_refinement_re_evaluates_added_information_and_connects_evidence() {
    let library = library();
    let generation = assemble_signature_generation(library, None, vec![entry()]).unwrap();
    let checked = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&generation),
        generation.clone(),
    )
    .unwrap();
    let type_ref = signature_type_ref("additional-text");
    let before = open_signature_evaluation(
        &checked,
        SemanticValueInput {
            type_ref: type_ref.clone(),
            value: JsonValue::Str("ok".into()),
        },
        "1".into(),
    );
    assert!(
        matches!(before.outcome(), Ok(RefinementOutcome::Residual { residuals, .. }) if residuals.len() == 1)
    );
    let node = TypeNode {
        reference: type_ref,
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
    let (after, verified) =
        refine_signature_evaluation(&before, information.clone(), "2".into()).unwrap();
    assert!(matches!(
        after.outcome(),
        Ok(RefinementOutcome::Resolved(SemanticJudgment {
            decision: ValueDecision::Accepted,
            ..
        }))
    ));
    assert_eq!(verified.before_observations(), before.observations());
    assert_eq!(verified.after_observations(), after.observations());
    assert_eq!(verified.evaluated_before().input, *before.input());
    assert_eq!(verified.evaluated_after().input, *after.input());
    assert_eq!(verified.evaluated_before().certificate, generation);
    assert_eq!(verified.evaluated_after().certificate, generation);
    assert_eq!(
        verified.evaluated_before().observations,
        *before.observations()
    );
    assert_eq!(
        verified.evaluated_after().observations,
        *after.observations()
    );
    let (again, _) = refine_signature_evaluation(&after, information.clone(), "3".into()).unwrap();
    assert_eq!(again.outcome(), after.outcome());
    let mut node = fixture_item(&information.nodes, 0).clone();
    if let TypeShape::String(spec) = &mut node.shape {
        spec.format = Some(FormatUse::Named("additional-format".into()));
    }
    let partial = refine_signature_evaluation(
        &before,
        AdditionalSemanticInformation {
            nodes: vec![node],
            profile: checked.graph().profile.clone(),
        },
        "2".into(),
    )
    .unwrap()
    .0;
    assert!(
        matches!(partial.outcome(), Ok(RefinementOutcome::Residual { residuals, .. }) if residuals.len() == 1 && residuals.iter().all(|reason| reason.reason == SemanticReason::UnknownFormat("additional-format".into()))),
        "{:?}",
        partial.outcome()
    );
    let mut supplemented = checked.graph().profile.clone();
    supplemented.format_bindings.push(FormatBinding {
        name: "additional-format".into(),
        reference: supplemented.reference.clone(),
        rule: FormatRule::Literal("ok".into()),
    });
    let completed = refine_signature_evaluation(
        &partial,
        AdditionalSemanticInformation {
            nodes: vec![],
            profile: supplemented,
        },
        "3".into(),
    )
    .unwrap()
    .0;
    assert!(matches!(
        completed.outcome(),
        Ok(RefinementOutcome::Resolved(SemanticJudgment {
            decision: ValueDecision::Accepted,
            ..
        }))
    ));
    let mut invalid_profile = checked.graph().profile.clone();
    invalid_profile.reference.identity.clear();
    assert!(matches!(
        refine_signature_evaluation(
            &before,
            AdditionalSemanticInformation {
                nodes: vec![],
                profile: invalid_profile,
            },
            "4".into(),
        ),
        Err(SemanticRefinementFailure::Profile {
            failure: ProfileFailure {
                predicate: ProfilePredicate::Pr01,
                location,
                ..
            },
            ..
        }) if location == vec!["profile".to_owned()]
    ));
    let mut invalid_node = fixture_item(&information.nodes, 0).clone();
    let field = FieldSpec {
        wire_name: "duplicate".into(),
        slot: SlotContract {
            type_ref: invalid_node.reference.clone(),
            required: true,
            nullable: false,
        },
        origin: OccurrenceRef::from(&invalid_node.reference),
    };
    invalid_node.shape = TypeShape::Product(ProductSpec {
        fields: vec![field.clone(), field],
        extras: ExtraMembers::Reject,
    });
    assert!(matches!(
        refine_signature_evaluation(
            &before,
            AdditionalSemanticInformation {
                nodes: vec![invalid_node],
                profile: checked.graph().profile.clone(),
            },
            "4".into(),
        ),
        Err(SemanticRefinementFailure::ObservationGraph {
            condition: SemanticGraphCondition::AdditionalNodeStructure(_),
            ..
        })
    ));
    let mut invalid_range = fixture_item(&information.nodes, 0).clone();
    invalid_range.shape = TypeShape::Integer(IntegerSpec {
        domain: Some("integer".into()),
        minimum: Some(2.into()),
        maximum: Some(1.into()),
        const_value: None,
        enum_values: None,
        default_value: None,
    });
    let mut invalid_branch = fixture_item(&information.nodes, 0).clone();
    let branch = |wire_tag: &str, selector| UnionBranch {
        target: invalid_branch.reference.clone(),
        wire_tag: wire_tag.into(),
        selector,
        origin: OccurrenceRef::from(&invalid_branch.reference),
    };
    invalid_branch.shape = TypeShape::TaggedUnion(UnionSpec {
        branches: vec![
            branch("otherwise", BranchSelector::Otherwise),
            branch("string", BranchSelector::Kind(ValueKind::String)),
        ],
    });
    let mut invalid_refinement = fixture_item(&information.nodes, 0).clone();
    invalid_refinement.shape = TypeShape::Sealed {
        tag: "sealed".into(),
        refinements: vec![SealedRefinement {
            key: "missing".into(),
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
    };
    for node in [invalid_range, invalid_branch, invalid_refinement] {
        assert!(matches!(
            refine_signature_evaluation(
                &before,
                AdditionalSemanticInformation {
                    nodes: vec![node],
                    profile: checked.graph().profile.clone(),
                },
                "4".into(),
            ),
            Err(SemanticRefinementFailure::ObservationGraph {
                condition: SemanticGraphCondition::AdditionalNodeStructure(_),
                ..
            })
        ));
    }
    let duplicate_node = fixture_item(&information.nodes, 0).clone();
    assert!(matches!(
        refine_signature_evaluation(
            &before,
            AdditionalSemanticInformation {
                nodes: vec![duplicate_node.clone(), duplicate_node],
                profile: checked.graph().profile.clone(),
            },
            "4".into(),
        ),
        Err(SemanticRefinementFailure::ObservationGraph {
            condition: SemanticGraphCondition::UniqueAdditionalTypeReference(_),
            ..
        })
    ));
    assert!(matches!(
        refine_signature_evaluation(&after, information, "2".into()),
        Err(SemanticRefinementFailure::ObservationGraph {
            condition: SemanticGraphCondition::DistinctGraphRevision,
            ..
        })
    ));
    let retained = refine_signature_evaluation(
        &before,
        AdditionalSemanticInformation {
            nodes: vec![],
            profile: checked.graph().profile.clone(),
        },
        "2".into(),
    )
    .unwrap()
    .0;
    assert_eq!(retained.outcome(), before.outcome());
    for value in ["ok", "bad"] {
        let input = SemanticValueInput {
            type_ref: signature_type_ref("text"),
            value: JsonValue::Str(value.into()),
        };
        let before = open_signature_evaluation(&checked, input, "1".into());
        if value == "ok" {
            assert!(matches!(
                before.outcome(),
                Ok(RefinementOutcome::Resolved(SemanticJudgment {
                    decision: ValueDecision::Accepted,
                    ..
                }))
            ));
        } else {
            assert!(matches!(
                before.outcome(),
                Err(SemanticDecisionFailure {
                    provenance: EvaluationProvenance { operation, .. },
                    condition: SemanticDecisionCondition::ValueRejected,
                    ..
                }) if operation == "validate"
            ));
        }
        let (after, _) = refine_signature_evaluation(
            &before,
            AdditionalSemanticInformation {
                nodes: vec![],
                profile: checked.graph().profile.clone(),
            },
            "2".into(),
        )
        .unwrap();
        assert_eq!(after.outcome(), before.outcome());
    }
}

#[test]
fn refinement_rejects_each_existing_profile_declaration_mutation() {
    let mut declaration = library();
    declaration.profile.source_refs.push(SourceIdentity {
        repository: "repository".into(),
        revision: "revision".into(),
        path: "profile.json".into(),
        content_digest: "b".repeat(64),
    });
    let mut secondary_integer = fixture_item(&declaration.profile.integer_domains, 0).clone();
    secondary_integer.name = "secondary-integer".into();
    declaration.profile.integer_domains.push(secondary_integer);
    declaration.profile.grapheme_rules = Some(GraphemeRules {
        reference: reference(),
        properties: vec![],
        extended_pictographic: vec![],
        indic_conjunct: vec![],
        component: GraphemeComponent {
            unicode_version: "16.0.0".into(),
            uax29_revision: "45".into(),
            cluster_profile: "C1-1-default-extended-grapheme-cluster-no-tailoring".into(),
        },
        table_sha256: "b".repeat(64),
        sources: vec![],
    });
    declaration.profile.bytes_policy = Some(BytesPolicy {
        reference: reference(),
        padding_optional: true,
        alphabet: BytesAlphabet::Either,
        strict_pad_bits: true,
        wrapper: None,
    });
    let generation = assemble_signature_generation(declaration, None, vec![entry()]).unwrap();
    let checked = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&generation),
        generation.clone(),
    )
    .unwrap();
    let before = open_signature_evaluation(
        &checked,
        SemanticValueInput {
            type_ref: signature_type_ref("text"),
            value: JsonValue::Str("ok".into()),
        },
        "1".into(),
    );
    let profile = checked.graph().profile.clone();
    let mut cases = Vec::new();

    let mut changed = profile.clone();
    changed.default_integer_domain = "secondary-integer".into();
    cases.push((changed, SemanticProfileDeclaration::DefaultIntegerDomain));
    let mut changed = profile.clone();
    changed.numbers.decimals = false;
    cases.push((changed, SemanticProfileDeclaration::Numbers));
    let mut changed = profile.clone();
    changed.source_refs.clear();
    cases.push((changed, SemanticProfileDeclaration::SourceRefs));
    let mut changed = profile.clone();
    changed.integer_domains.pop();
    cases.push((changed, SemanticProfileDeclaration::IntegerDomains));
    let mut changed = profile.clone();
    changed.format_bindings.clear();
    cases.push((changed, SemanticProfileDeclaration::FormatBindings));
    let mut changed = profile.clone();
    changed.wrappers.clear();
    cases.push((changed, SemanticProfileDeclaration::Wrappers));
    let mut changed = profile.clone();
    changed.grapheme_rules = None;
    cases.push((changed, SemanticProfileDeclaration::GraphemeRules));
    let mut changed = profile.clone();
    changed.bytes_policy = None;
    cases.push((changed, SemanticProfileDeclaration::BytesPolicy));
    let mut changed = profile.clone();
    changed.tag.as_mut().unwrap().key = "type".into();
    cases.push((changed, SemanticProfileDeclaration::Tag));
    let mut changed = profile.clone();
    changed.tag.as_mut().unwrap().format = Some("name".into());
    cases.push((changed, SemanticProfileDeclaration::Tag));
    let mut changed = profile.clone();
    changed.tag.as_mut().unwrap().sealed.clear();
    cases.push((changed, SemanticProfileDeclaration::Tag));
    let mut changed = profile;
    changed.tag = None;
    cases.push((changed, SemanticProfileDeclaration::Tag));

    for (profile, expected) in cases {
        check_profile(&profile).unwrap();
        assert!(matches!(
            refine_signature_evaluation(
                &before,
                AdditionalSemanticInformation {
                    nodes: vec![],
                    profile,
                },
                "2".into(),
            ),
            Err(SemanticRefinementFailure::ObservationGraph {
                condition: SemanticGraphCondition::ExistingProfileDeclaration(actual),
                ..
            }) if actual == expected
        ));
    }
}

#[test]
fn refinement_preserves_determined_meaning_failures() {
    let mut declaration = library();
    declaration.nodes.push(TypeNodeInput {
        id: "out-of-range-integer".into(),
        shape: Shape::Integer(IntegerSpec {
            domain: Some("integer".into()),
            minimum: Some((-11).into()),
            maximum: None,
            const_value: None,
            enum_values: None,
            default_value: None,
        }),
    });
    let generation = assemble_signature_generation(declaration, None, vec![entry()]).unwrap();
    let checked = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&generation),
        generation.clone(),
    )
    .unwrap();
    let before = open_signature_evaluation(
        &checked,
        SemanticValueInput {
            type_ref: signature_type_ref("out-of-range-integer"),
            value: JsonValue::Num(0.into()),
        },
        "1".into(),
    );
    assert!(matches!(
        before.outcome(),
        Err(SemanticDecisionFailure {
            decision: ValueDecision::Unresolved(reasons),
            condition: SemanticDecisionCondition::InvalidMeaning,
            ..
        }) if reasons.iter().any(|reason| reason.reason == SemanticReason::IntegerBound)
    ));
    let after = refine_signature_evaluation(
        &before,
        AdditionalSemanticInformation {
            nodes: vec![],
            profile: checked.graph().profile.clone(),
        },
        "2".into(),
    )
    .unwrap()
    .0;
    assert_eq!(after.outcome(), before.outcome());
}

fn arbitrary_value() -> impl Strategy<Value = JsonValue> {
    prop_oneof![
        Just(JsonValue::Null),
        any::<bool>().prop_map(JsonValue::Bool),
        any::<i64>().prop_map(|value| JsonValue::Num(value.into())),
        ".*".prop_map(JsonValue::Str)
    ]
    .prop_recursive(4, 64, 8, |inner| {
        prop_oneof![
            proptest::collection::vec(inner.clone(), 0..8).prop_map(JsonValue::Arr),
            proptest::collection::btree_map("[a-z]{1,8}", inner, 0..8)
                .prop_map(|fields| JsonValue::Obj(fields.into_iter().collect())),
        ]
    })
}

proptest! {
    #[test]
    fn refinement_preserves_determined_decisions_for_arbitrary_values(value in arbitrary_value()) {
        let mut declaration = library();
        declaration.nodes.push(TypeNodeInput { id: "any".into(), shape: Shape::Unknown(UnknownKind::Any) });
        let generation = assemble_signature_generation(declaration, None, vec![entry()]).unwrap();
        let checked = admit_signature_generation(&necoherence::type_signatures::ExpectedSignatureBasis::of_input(&generation), generation.clone()).unwrap();
        let any = signature_type_ref("any");
        let before = open_signature_evaluation(&checked, SemanticValueInput { type_ref: any.clone(), value: value.clone() }, "1".into());
        let mut information = AdditionalSemanticInformation { nodes: vec![], profile: checked.graph().profile.clone() };
        information.profile.format_bindings.push(FormatBinding { name: "supplemental".into(), reference: reference(), rule: FormatRule::Text });
        let after = refine_signature_evaluation(&before, information.clone(), "2".into()).unwrap().0;
        prop_assert_eq!(&after.observations().graph.nodes, &before.observations().graph.nodes);
        for node in &before.observations().graph.nodes {
            let original = evaluate_with_graph(&before.observations().graph, &node.reference, &value);
            if matches!(&original, Ok(RefinementOutcome::Resolved(_)) | Err(_)) {
                prop_assert_eq!(evaluate_with_graph(&after.observations().graph, &node.reference, &value), original);
            }
        }
        let mut replacement = checked.graph().find_type(&any).unwrap().clone();
        replacement.shape = TypeShape::String(StringSpec { format: None, lengths: vec![], wrapper: None, const_value: None, enum_values: None, examples: vec![], default_value: None });
        information.nodes.push(replacement);
        prop_assert!(matches!(refine_signature_evaluation(&before, information, "2".into()), Err(SemanticRefinementFailure::ObservationGraph { condition: SemanticGraphCondition::ExistingTypeDeclaration(_), .. })), "existing declaration replacement is rejected");
    }
}

#[test]
fn unknown_any_cannot_be_replaced_even_when_the_current_value_is_a_string() {
    let mut declaration = library();
    declaration.nodes.push(TypeNodeInput {
        id: "any".into(),
        shape: Shape::Unknown(UnknownKind::Any),
    });
    let generation = assemble_signature_generation(declaration, None, vec![entry()]).unwrap();
    let checked = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&generation),
        generation.clone(),
    )
    .unwrap();
    let reference = signature_type_ref("any");
    for value in [JsonValue::Str("ok".into()), JsonValue::Bool(true)] {
        let before = open_signature_evaluation(
            &checked,
            SemanticValueInput {
                type_ref: reference.clone(),
                value,
            },
            "1".into(),
        );
        assert!(matches!(
            before.outcome(),
            Ok(RefinementOutcome::Resolved(SemanticJudgment {
                decision: ValueDecision::Accepted,
                ..
            }))
        ));
        let mut replacement = checked.graph().find_type(&reference).unwrap().clone();
        replacement.shape = checked
            .graph()
            .nodes
            .iter()
            .find(|node| matches!(node.shape, TypeShape::String(_)))
            .unwrap()
            .shape
            .clone();
        assert!(matches!(
            refine_signature_evaluation(
                &before,
                AdditionalSemanticInformation {
                    nodes: vec![replacement],
                    profile: checked.graph().profile.clone()
                },
                "2".into()
            ),
            Err(SemanticRefinementFailure::ObservationGraph {
                condition: SemanticGraphCondition::ExistingTypeDeclaration(_),
                ..
            })
        ));
    }
}

#[test]
fn refinement_preserves_the_global_object_classification_for_existing_types() {
    let mut declaration = library();
    declaration.nodes.push(TypeNodeInput {
        id: "known-product".into(),
        shape: Shape::Product(SignatureProduct {
            fields: vec![SignatureField {
                wire_name: "$supplemental".into(),
                slot: SignatureSlot {
                    type_id: "text".into(),
                    required: false,
                    nullable: false,
                },
            }],
            extras: SignatureExtraMembers::Reject,
        }),
    });
    let generation = assemble_signature_generation(declaration, None, vec![entry()]).unwrap();
    let checked = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&generation),
        generation.clone(),
    )
    .unwrap();
    let reference = signature_type_ref("known-product");
    let before = open_signature_evaluation(
        &checked,
        SemanticValueInput {
            type_ref: reference,
            value: JsonValue::Obj(vec![("$supplemental".into(), JsonValue::Str("ok".into()))]),
        },
        "1".into(),
    );
    assert!(matches!(
        before.outcome(),
        Ok(RefinementOutcome::Resolved(SemanticJudgment {
            decision: ValueDecision::Accepted,
            ..
        }))
    ));
    let mut profile = checked.graph().profile.clone();
    profile.wrappers.push(Wrapper {
        name: "supplemental".into(),
        key: "$supplemental".into(),
        payload: WrapperPayload::Text { format: None },
    });
    assert!(matches!(
        refine_signature_evaluation(
            &before,
            AdditionalSemanticInformation {
                nodes: vec![],
                profile
            },
            "2".into()
        ),
        Err(SemanticRefinementFailure::ObservationGraph {
            condition: SemanticGraphCondition::ObjectInterpretation,
            ..
        })
    ));
    let other_value = JsonValue::Obj(vec![("kind".into(), JsonValue::Str("new-form".into()))]);
    assert!(matches!(
        evaluate_with_graph(
            &before.observations().graph,
            &before.input().type_ref,
            &other_value
        ),
        Ok(RefinementOutcome::Resolved(SemanticJudgment {
            decision: ValueDecision::Accepted,
            ..
        }))
    ));
    let mut profile = checked.graph().profile.clone();
    profile.tag.as_mut().unwrap().sealed.push(SealedForm {
        tag: "new-form".into(),
        fields: vec![],
        extras: SealedExtras::Reject,
    });
    assert!(matches!(
        refine_signature_evaluation(
            &before,
            AdditionalSemanticInformation {
                nodes: vec![],
                profile
            },
            "3".into()
        ),
        Err(SemanticRefinementFailure::ObservationGraph {
            condition: SemanticGraphCondition::ObjectInterpretation,
            ..
        })
    ));
}

#[test]
fn profile_supplements_resolve_missing_meaning_and_preserve_existing_judgments() {
    let mut declaration = library();
    declaration.nodes.retain(|node| node.id == "text");
    declaration
        .definitions
        .iter_mut()
        .for_each(|definition| definition.shape = SignatureDefinitionShape::Value("text".into()));
    let generation = assemble_signature_generation(declaration, None, vec![entry()]).unwrap();
    let checked = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&generation),
        generation.clone(),
    )
    .unwrap();
    let new_reference = signature_type_ref("additional");
    let plain_string = StringSpec {
        format: None,
        lengths: vec![],
        wrapper: None,
        const_value: None,
        enum_values: None,
        examples: vec![],
        default_value: None,
    };
    let mut graphemes = checked.graph().profile.clone();
    graphemes.grapheme_rules = Some(GraphemeRules {
        reference: reference(),
        properties: vec![],
        extended_pictographic: vec![],
        indic_conjunct: vec![],
        component: GraphemeComponent {
            unicode_version: "16.0.0".into(),
            uax29_revision: "45".into(),
            cluster_profile: "C1-1-default-extended-grapheme-cluster-no-tailoring".into(),
        },
        table_sha256: "b".repeat(64),
        sources: vec![],
    });
    let mut bytes = checked.graph().profile.clone();
    bytes.bytes_policy = Some(BytesPolicy {
        reference: reference(),
        padding_optional: true,
        alphabet: BytesAlphabet::Either,
        strict_pad_bits: true,
        wrapper: None,
    });
    let mut wrapper = checked.graph().profile.clone();
    wrapper.wrappers.push(Wrapper {
        name: "additional".into(),
        key: "$additional".into(),
        payload: WrapperPayload::Text { format: None },
    });
    let mut sealed = checked.graph().profile.clone();
    sealed.tag.as_mut().unwrap().sealed.push(SealedForm {
        tag: "additional".into(),
        fields: vec![],
        extras: SealedExtras::Reject,
    });
    let cases = [
        (
            TypeShape::String(StringSpec {
                lengths: vec![LengthBound {
                    unit: StringLengthUnit::Graphemes,
                    minimum: Some(1u8.into()),
                    maximum: None,
                }],
                ..plain_string.clone()
            }),
            JsonValue::Str("a".into()),
            graphemes.clone(),
            SemanticReason::MissingGraphemeRules,
        ),
        (
            TypeShape::String(StringSpec {
                format: Some(FormatUse::Inline(FormatRule::Bounded {
                    unit: StringLengthUnit::Graphemes,
                    maximum: 1u8.into(),
                    rule: Box::new(FormatRule::Text),
                })),
                ..plain_string.clone()
            }),
            JsonValue::Str("a".into()),
            graphemes,
            SemanticReason::MissingGraphemeRules,
        ),
        (
            TypeShape::Bytes(LengthSpec {
                minimum: None,
                maximum: None,
            }),
            JsonValue::Str("AQ==".into()),
            bytes,
            SemanticReason::MissingBytesPolicy,
        ),
        (
            TypeShape::String(StringSpec {
                wrapper: Some("additional".into()),
                ..plain_string
            }),
            JsonValue::Obj(vec![("$additional".into(), JsonValue::Str("ok".into()))]),
            wrapper,
            SemanticReason::UnknownWrapper("additional".into()),
        ),
        (
            TypeShape::Sealed {
                tag: "additional".into(),
                refinements: vec![],
            },
            JsonValue::Obj(vec![("kind".into(), JsonValue::Str("additional".into()))]),
            sealed,
            SemanticReason::UnknownSealedTag("additional".into()),
        ),
    ];
    for (shape, value, supplemented_profile, reason) in cases {
        let node = TypeNode {
            reference: new_reference.clone(),
            shape,
            description: None,
            attributes: vec![],
            extensions: vec![],
        };
        let text_reference = signature_type_ref("text");
        let product_reference = signature_type_ref("known-product");
        let mut additional_nodes = vec![node.clone()];
        if matches!(
            reason,
            SemanticReason::MissingGraphemeRules | SemanticReason::MissingBytesPolicy
        ) {
            additional_nodes.push(TypeNode {
                reference: product_reference.clone(),
                shape: TypeShape::Product(ProductSpec {
                    fields: vec![FieldSpec {
                        wire_name: "label".into(),
                        slot: SlotContract {
                            type_ref: text_reference.clone(),
                            required: true,
                            nullable: false,
                        },
                        origin: OccurrenceRef::from(&product_reference),
                    }],
                    extras: ExtraMembers::Reject,
                }),
                description: None,
                attributes: vec![],
                extensions: vec![],
            });
        }
        let before = open_signature_evaluation(
            &checked,
            SemanticValueInput {
                type_ref: new_reference.clone(),
                value,
            },
            "1".into(),
        );
        let partial = refine_signature_evaluation(
            &before,
            AdditionalSemanticInformation {
                nodes: additional_nodes.clone(),
                profile: checked.graph().profile.clone(),
            },
            "2".into(),
        )
        .unwrap()
        .0;
        assert!(
            matches!(partial.outcome(), Ok(RefinementOutcome::Residual { residuals, .. }) if residuals.len() == 1 && residuals.iter().all(|item| item.reason == reason))
        );
        let completed = refine_signature_evaluation(
            &partial,
            AdditionalSemanticInformation {
                nodes: vec![],
                profile: supplemented_profile.clone(),
            },
            "3".into(),
        )
        .unwrap()
        .0;
        assert!(matches!(
            completed.outcome(),
            Ok(RefinementOutcome::Resolved(SemanticJudgment {
                decision: ValueDecision::Accepted,
                ..
            }))
        ));
        let mut preserved_inputs = vec![
            (text_reference.clone(), JsonValue::Str("ok".into())),
            (text_reference, JsonValue::Str("bad".into())),
        ];
        if additional_nodes.len() == 2 {
            preserved_inputs.extend([
                (
                    product_reference.clone(),
                    JsonValue::Obj(vec![("label".into(), JsonValue::Str("ok".into()))]),
                ),
                (
                    product_reference,
                    JsonValue::Obj(vec![("label".into(), JsonValue::Str("bad".into()))]),
                ),
            ]);
        }
        for (type_ref, value) in preserved_inputs {
            let original = open_signature_evaluation(
                &checked,
                SemanticValueInput { type_ref, value },
                "1".into(),
            );
            let partial = refine_signature_evaluation(
                &original,
                AdditionalSemanticInformation {
                    nodes: additional_nodes.clone(),
                    profile: checked.graph().profile.clone(),
                },
                "2".into(),
            )
            .unwrap()
            .0;
            assert!(matches!(
                partial.outcome(),
                Ok(RefinementOutcome::Resolved(_)) | Err(_)
            ));
            let completed = refine_signature_evaluation(
                &partial,
                AdditionalSemanticInformation {
                    nodes: vec![],
                    profile: supplemented_profile.clone(),
                },
                "3".into(),
            )
            .unwrap()
            .0;
            assert_eq!(completed.outcome(), partial.outcome());
        }
    }
}

#[test]
fn grapheme_supplement_preserves_defined_unknown_sealed_membership() {
    let mut declaration = library();
    declaration.nodes.retain(|node| node.id == "text");
    declaration.nodes.push(TypeNodeInput {
        id: "any".into(),
        shape: Shape::Unknown(UnknownKind::Any),
    });
    declaration
        .definitions
        .iter_mut()
        .for_each(|definition| definition.shape = SignatureDefinitionShape::Value("text".into()));
    let form = declaration
        .profile
        .tag
        .as_mut()
        .unwrap()
        .sealed
        .first_mut()
        .unwrap();
    let SealedLeaf::String(spec) = &mut form.fields.first_mut().unwrap().leaf else {
        unreachable!()
    };
    spec.lengths = vec![LengthBound {
        unit: StringLengthUnit::Graphemes,
        minimum: None,
        maximum: Some(1u8.into()),
    }];
    let generation = assemble_signature_generation(declaration, None, vec![entry()]).unwrap();
    let checked = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&generation),
        generation.clone(),
    )
    .unwrap();
    let any_reference = signature_type_ref("any");
    let before = open_signature_evaluation(
        &checked,
        SemanticValueInput {
            type_ref: signature_type_ref("text"),
            value: JsonValue::Str("ok".into()),
        },
        "1".into(),
    );
    let other_value = JsonValue::Obj(vec![
        ("kind".into(), JsonValue::Str("sealed".into())),
        ("name".into(), JsonValue::Str("a".into())),
    ]);
    let original_other =
        evaluate_with_graph(&before.observations().graph, &any_reference, &other_value);
    assert!(
        matches!(&original_other, Err(failure) if matches!(&failure.decision, ValueDecision::Rejected(value) if value.condition == ValueCondition::StringLength))
    );
    let mut profile = checked.graph().profile.clone();
    profile.grapheme_rules = Some(GraphemeRules {
        reference: checked.graph().profile.reference.clone(),
        properties: vec![],
        extended_pictographic: vec![],
        indic_conjunct: vec![],
        component: GraphemeComponent {
            unicode_version: "16.0.0".into(),
            uax29_revision: "45".into(),
            cluster_profile: "C1-1-default-extended-grapheme-cluster-no-tailoring".into(),
        },
        table_sha256: "b".repeat(64),
        sources: vec![],
    });
    let failure = refine_signature_evaluation(
        &before,
        AdditionalSemanticInformation {
            nodes: vec![],
            profile,
        },
        "2".into(),
    )
    .unwrap_err();
    assert!(matches!(
        failure,
        SemanticRefinementFailure::ObservationGraph {
            condition: SemanticGraphCondition::SealedLeafJudgment,
            ..
        }
    ));
}

#[test]
fn bytes_supplement_preserves_defined_sealed_leaf_judgments() {
    let mut declaration = library();
    declaration.profile.wrappers.push(Wrapper {
        name: "binary".into(),
        key: "$bytes".into(),
        payload: WrapperPayload::Bytes,
    });
    declaration
        .definitions
        .iter_mut()
        .for_each(|definition| definition.shape = SignatureDefinitionShape::Value("text".into()));
    let generation = assemble_signature_generation(declaration, None, vec![entry()]).unwrap();
    let checked = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&generation),
        generation.clone(),
    )
    .unwrap();
    let sealed_reference = signature_type_ref("sealed");
    let before = open_signature_evaluation(
        &checked,
        SemanticValueInput {
            type_ref: signature_type_ref("text"),
            value: JsonValue::Str("ok".into()),
        },
        "1".into(),
    );
    let other_value = JsonValue::Obj(vec![
        ("kind".into(), JsonValue::Str("sealed".into())),
        (
            "name".into(),
            JsonValue::Obj(vec![("$bytes".into(), JsonValue::Str("AQ==".into()))]),
        ),
    ]);
    assert!(matches!(
        evaluate_with_graph(&before.observations().graph, &sealed_reference, &other_value),
        Err(failure)
            if matches!(failure.decision, ValueDecision::Rejected(ValueFailure {
                condition: ValueCondition::InvalidBytes,
                ..
            }))
    ));
    let mut profile = checked.graph().profile.clone();
    profile.bytes_policy = Some(BytesPolicy {
        reference: profile.reference.clone(),
        padding_optional: true,
        alphabet: BytesAlphabet::Either,
        strict_pad_bits: true,
        wrapper: None,
    });
    let failure = refine_signature_evaluation(
        &before,
        AdditionalSemanticInformation {
            nodes: vec![],
            profile,
        },
        "2".into(),
    )
    .unwrap_err();
    assert!(matches!(
        failure,
        SemanticRefinementFailure::ObservationGraph {
            condition: SemanticGraphCondition::SealedLeafJudgment,
            ..
        }
    ));
}

#[test]
fn grapheme_supplement_resolves_a_sealed_type_whose_tag_was_unknown() {
    let generation = assemble_signature_generation(library(), None, vec![entry()]).unwrap();
    let checked = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&generation),
        generation.clone(),
    )
    .unwrap();
    let type_ref = signature_type_ref("new-sealed");
    let input = SemanticValueInput {
        type_ref: type_ref.clone(),
        value: JsonValue::Obj(vec![
            ("kind".into(), JsonValue::Str("new-form".into())),
            ("name".into(), JsonValue::Str("a".into())),
        ]),
    };
    let missing_type = open_signature_evaluation(&checked, input, "1".into());
    let (before, _) = refine_signature_evaluation(
        &missing_type,
        AdditionalSemanticInformation {
            nodes: vec![TypeNode {
                reference: type_ref,
                shape: TypeShape::Sealed {
                    tag: "new-form".into(),
                    refinements: vec![SealedRefinement {
                        key: "name".into(),
                        leaf: SealedLeaf::String(StringSpec {
                            format: None,
                            lengths: vec![LengthBound {
                                unit: StringLengthUnit::Graphemes,
                                minimum: None,
                                maximum: Some(1u8.into()),
                            }],
                            wrapper: None,
                            const_value: None,
                            enum_values: None,
                            examples: vec![],
                            default_value: None,
                        }),
                    }],
                },
                description: None,
                attributes: vec![],
                extensions: vec![],
            }],
            profile: checked.graph().profile.clone(),
        },
        "2".into(),
    )
    .unwrap();
    assert!(matches!(
        before.outcome(),
        Ok(RefinementOutcome::Residual { residuals, .. })
            if residuals.iter().any(|obligation| obligation.reason == SemanticReason::UnknownSealedTag("new-form".into()))
    ));
    let mut profile = checked.graph().profile.clone();
    profile.tag.as_mut().unwrap().sealed.push(SealedForm {
        tag: "new-form".into(),
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
    });
    profile.grapheme_rules = Some(GraphemeRules {
        reference: profile.reference.clone(),
        properties: vec![],
        extended_pictographic: vec![],
        indic_conjunct: vec![],
        component: GraphemeComponent {
            unicode_version: "16.0.0".into(),
            uax29_revision: "45".into(),
            cluster_profile: "C1-1-default-extended-grapheme-cluster-no-tailoring".into(),
        },
        table_sha256: "b".repeat(64),
        sources: vec![],
    });
    let (after, _) = refine_signature_evaluation(
        &before,
        AdditionalSemanticInformation {
            nodes: vec![],
            profile,
        },
        "3".into(),
    )
    .unwrap();
    assert!(matches!(
        after.outcome(),
        Ok(RefinementOutcome::Resolved(SemanticJudgment {
            decision: ValueDecision::Accepted,
            ..
        }))
    ));
}
