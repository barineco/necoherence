// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use necoherence_composition_solver::{closure::*};
use necoherence::semantic_composition::*;
use necoherence::semantic_exchange::{encode_signature_generation};
use necoherence_composition_solver::document::signature_composition_from_native;
use necoherence::semantic_types::*;
use necoherence::signature_admission::*;
use necoherence::type_signatures::*;
use necoherence_composition_solver::composition_search::derive;
use serde_json::{json, Value};
use std::io::Write;
use std::io::{self, Read};

fn profile() -> ValueSemanticProfile {
    let reference = ProfileRef {
        identity: "ncoh-value-semantics".into(),
        revision: "1".into(),
        content_digest: "0".repeat(64),
    };
    ValueSemanticProfile {
        reference: reference.clone(),
        source_refs: vec![],
        integer_domains: vec![IntegerDomainBinding {
            name: "integer".into(),
            reference,
            range: IntegerDomain::Inclusive {
                minimum: (-10).into(),
                maximum: 10.into(),
            },
            forms: vec![IntegerForm::Number, IntegerForm::DecimalString],
        }],
        default_integer_domain: "integer".into(),
        numbers: NumberModel { decimals: true },
        grapheme_rules: None,
        format_bindings: vec![],
        wrappers: vec![],
        tag: None,
        bytes_policy: None,
    }
}

fn operation_generation(
    effect: CompositionEffect,
    padding: usize,
    type_padding: usize,
    paired: bool,
) -> std::result::Result<SignatureGenerationInput, Box<dyn std::error::Error>> {
    let input_type = if paired { "pair" } else { "truth" };
    let source = SourceIdentity {
        repository: "comparison".into(),
        revision: "1".into(),
        path: "execution".into(),
        content_digest: "0".repeat(64),
    };
    let origin = Origin {
        source: source.clone(),
        locator: vec!["operation".into()],
    };
    let signature_effect = match effect {
        CompositionEffect::PureFunction => EffectPoint::DataOnly,
        CompositionEffect::HttpRequestResponse => EffectPoint::HttpRequestResponse,
        CompositionEffect::DataOnly => EffectPoint::DataOnly,
    };
    let port = |id: &str, ty: &str| SignaturePort {
        id: id.into(),
        contract: SignatureSlot {
            type_id: ty.into(),
            required: true,
            nullable: false,
        },
    };
    let library = TypeSignatureLibrary {
        schema: "ncoh-type-signatures@1".into(),
        identity: "execution.signatures".into(),
        revision: "1".into(),
        profile: profile(),
        sources: vec![source],
        provenance: vec![],
        groups: vec![],
        annotations: (0..padding)
            .map(|index| Annotation {
                target: AnnotationTarget::Library,
                key: format!("padding{index}"),
                value: necoherence::exact_json::JsonValue::Str("padding".into()),
            })
            .collect(),
        nodes: vec![
            TypeNodeInput {
                id: "truth".into(),
                shape: Shape::Boolean(BooleanSpec {
                    const_value: None,
                    default_value: None,
                }),
            },
            TypeNodeInput {
                id: "unit".into(),
                shape: Shape::Unit,
            },
        ]
        .into_iter()
        .chain(paired.then(|| {
            TypeNodeInput {
                id: "pair".into(),
                shape: Shape::Product(SignatureProduct {
                    fields: ["left", "right"]
                        .into_iter()
                        .map(|name| SignatureField {
                            wire_name: name.into(),
                            slot: SignatureSlot {
                                type_id: "truth".into(),
                                required: true,
                                nullable: false,
                            },
                        })
                        .collect(),
                    extras: SignatureExtraMembers::Reject,
                }),
            }
        }))
        .chain((0..type_padding).map(|index| TypeNodeInput {
            id: format!("padding{index}"),
            shape: Shape::Boolean(BooleanSpec {
                const_value: None,
                default_value: None,
            }),
        }))
        .collect(),
        definitions: vec![DefinitionInput {
            id: "operation".into(),
            wire_identity: "ExecutionOperation".into(),
            shape: SignatureDefinitionShape::Operation(OperationContract {
                effect: signature_effect,
                inputs: vec![port("input", input_type)],
                outcomes: vec![
                    SignatureOutcome {
                        id: "success".into(),
                        form: necoherence::type_signatures::OutcomeForm::Success,
                        cause: OutcomeCause::ValueContract {
                            origin: origin.clone(),
                        },
                        value_ports: vec![port("output", "truth")],
                        produced_resources: vec![],
                    },
                    SignatureOutcome {
                        id: "refused".into(),
                        form: necoherence::type_signatures::OutcomeForm::DeclaredFailure,
                        cause: OutcomeCause::ExternalCondition {
                            specification: origin,
                        },
                        value_ports: vec![port("reason", "unit")],
                        produced_resources: vec![],
                    },
                ],
            }),
        }],
    };
    let graph = check_type_signatures(&library)?;
    let digest = signature_basis(&library, None, &[])?.graph_sha256;
    let slot = |id: &str| SlotContract {
        type_ref: signature_type_ref(id),
        required: true,
        nullable: false,
    };
    let function = FunctionRef {
        identity: "ExecutionOperation".into(),
        revision: "1".into(),
        content_digest: digest.clone(),
    };
    let success = OutcomeContract {
        id: OutcomeId("success".into()),
        form: necoherence::semantic_composition::OutcomeForm::Success,
        value_ports: vec![OutputPort {
            id: PortId("output".into()),
            contract: slot("truth"),
            resource_production: None,
        }],
        produced_resources: vec![],
    };
    let refused = OutcomeContract {
        id: OutcomeId("refused".into()),
        form: necoherence::semantic_composition::OutcomeForm::DeclaredFailure,
        value_ports: vec![OutputPort {
            id: PortId("reason".into()),
            contract: slot("unit"),
            resource_production: None,
        }],
        produced_resources: vec![],
    };
    let problem = CompositionInput {
        identity: "execution comparison".into(),
        revision: "1".into(),
        basis: SemanticBasis::of(&graph),
        signatures: vec![FunctionSignature {
            reference: function.clone(),
            form: FunctionForm::Operation(signature_definition_ref("operation")),
            effect,
            inputs: vec![InputPort {
                id: PortId("input".into()),
                contract: slot(input_type),
                source_constraint: if paired {
                    SourceConstraint::AnyCompatible
                } else {
                    SourceConstraint::InitialOnly {
                        input: InputId("argument".into()),
                        path: vec![],
                    }
                },
                resource_requirement: None,
            }],
            outcomes: vec![success, refused],
            resource_inputs: vec![],
            assumption_ref: "comparison provider".into(),
            handles_failure: None,
        }],
        initial_inputs: (if paired {
            vec!["left", "right"]
        } else {
            vec!["argument"]
        })
        .into_iter()
        .map(|id| InitialInput {
            id: InputId(id.into()),
            contract: slot("truth"),
            source: InitialSource::Argument,
            resource: None,
        })
        .collect(),
        initial_resources: vec![],
        goal: GoalSpec {
            outputs: vec![GoalPort {
                id: GoalPortId("result".into()),
                contract: slot("truth"),
                source_constraint: SourceConstraint::ProducedBy {
                    site: SiteId("operation".into()),
                    outcome: OutcomeId("success".into()),
                    port: PortId("output".into()),
                    path: vec![],
                },
            }],
            failures: vec![FailureEmbedding {
                id: FailureEmbeddingId("refusal".into()),
                origin: FailureOrigin::Function {
                    function: function.clone(),
                    outcome: OutcomeId("refused".into()),
                },
                contract: slot("unit"),
                final_resources: vec![],
            }],
            final_resources: vec![],
        },
        invocation_domain: InvocationDomain {
            identity: "finite".into(),
            revision: "1".into(),
            sites: vec![InvocationSite {
                id: SiteId("operation".into()),
                function: function.clone(),
            }],
            permitted_projections: vec![],
            permitted_constructions: if paired {
                vec![ConstructionRule {
                    identity: "pair-construction".into(),
                    type_ref: signature_type_ref("pair"),
                    nested_fields: vec![],
                    field_constraints: ["left", "right"]
                        .into_iter()
                        .map(|name| FieldConstraint {
                            field: name.into(),
                            source: SourceConstraint::InitialOnly {
                                input: InputId(name.into()),
                                path: vec![],
                            },
                            presence: FieldPresence::Required,
                        })
                        .collect(),
                }]
            } else {
                vec![]
            },
            permitted_transforms: vec![],
            guards: vec![],
        },
        allowed_effects: vec![effect],
        explicit_order: vec![],
        selection_policy: Some(SelectionPolicy::AnyFeasible),
        bounds: SearchBounds::default(),
    };
    let prepared = prepare_direct_composition(
        &graph,
        problem.clone(),
        operation_checker_without_library(),
        operation_meaning_of(&graph),
    )
    .map_err(|failure| format!("{failure:?}"))?;
    let CompositionDecision::Solved(checked, _) =
        derive(&prepared).map_err(|failure| format!("{failure:?}"))?
    else {
        return Err("execution comparison composition was not solved".into());
    };
    let causes = vec![(
        function,
        vec![
            (
                OutcomeId("success".into()),
                OutcomeCause::ValueContract {
                    origin: Origin {
                        source: library.sources[0].clone(),
                        locator: vec!["operation".into()],
                    },
                },
            ),
            (
                OutcomeId("refused".into()),
                OutcomeCause::ExternalCondition {
                    specification: Origin {
                        source: library.sources[0].clone(),
                        locator: vec!["operation".into()],
                    },
                },
            ),
        ],
    )];
    let composition =
        signature_composition_from_native(&library, &problem, checked.raw(), &causes)?;
    let input = assemble_signature_generation(
        library,
        Some(composition),
        vec![SignatureEntrypoint {
            identity: "operation".into(),
            definition: "operation".into(),
        }],
    )?;
    Ok(input)
}

fn rich_library() -> TypeSignatureLibrary {
    let mut value = TypeSignatureLibrary {
        schema: "ncoh-type-signatures@1".into(),
        identity: "execution.rich".into(),
        revision: "1".into(),
        profile: profile(),
        sources: vec![],
        provenance: vec![],
        groups: vec![],
        annotations: vec![],
        definitions: vec![],
        nodes: vec![
            TypeNodeInput {
                id: "truth".into(),
                shape: Shape::Boolean(BooleanSpec {
                    const_value: None,
                    default_value: None,
                }),
            },
            TypeNodeInput {
                id: "text".into(),
                shape: Shape::String(StringSpec {
                    format: None,
                    lengths: vec![],
                    wrapper: None,
                    const_value: None,
                    enum_values: None,
                    examples: vec!["accepted".into()],
                    default_value: None,
                }),
            },
            TypeNodeInput {
                id: "known".into(),
                shape: Shape::Sealed {
                    tag: "known".into(),
                    refinements: vec![],
                },
            },
            TypeNodeInput {
                id: "other".into(),
                shape: Shape::Sealed {
                    tag: "other".into(),
                    refinements: vec![],
                },
            },
            TypeNodeInput {
                id: "variant".into(),
                shape: Shape::TaggedUnion(SignatureUnion {
                    branches: vec![
                        SignatureUnionBranch {
                            target: "known".into(),
                            wire_tag: "known".into(),
                            selector: BranchSelector::InternalTag,
                        },
                        SignatureUnionBranch {
                            target: "other".into(),
                            wire_tag: "otherwise".into(),
                            selector: BranchSelector::Otherwise,
                        },
                    ],
                }),
            },
            TypeNodeInput {
                id: "pair".into(),
                shape: Shape::Product(SignatureProduct {
                    fields: vec![
                        SignatureField {
                            wire_name: "left".into(),
                            slot: SignatureSlot {
                                type_id: "truth".into(),
                                required: true,
                                nullable: false,
                            },
                        },
                        SignatureField {
                            wire_name: "right".into(),
                            slot: SignatureSlot {
                                type_id: "truth".into(),
                                required: true,
                                nullable: false,
                            },
                        },
                    ],
                    extras: SignatureExtraMembers::Reject,
                }),
            },
            TypeNodeInput {
                id: "truths".into(),
                shape: Shape::Array(SignatureArray {
                    item: SignatureElementContract {
                        type_id: "truth".into(),
                        nullable: false,
                    },
                    minimum: Some(2u8.into()),
                    maximum: Some(2u8.into()),
                }),
            },
        ],
    };
    let sealed = |tag: &str| SealedForm {
        tag: tag.into(),
        fields: vec![SealedField {
            key: "value".into(),
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
    };
    value.profile.tag = Some(TagModel {
        key: "kind".into(),
        format: None,
        sealed: vec![sealed("known"), sealed("other")],
    });
    value
}

fn rich_slot(id: &str, required: bool, nullable: bool) -> SlotContract {
    SlotContract {
        type_ref: signature_type_ref(id),
        required,
        nullable,
    }
}

fn solve(
    library: TypeSignatureLibrary,
    problem: CompositionInput,
) -> std::result::Result<SignatureGenerationInput, Box<dyn std::error::Error>> {
    solve_with_causes(library, problem, &[])
}

fn solve_with_causes(
    library: TypeSignatureLibrary,
    problem: CompositionInput,
    causes: &[(FunctionRef, Vec<(OutcomeId, OutcomeCause)>)],
) -> std::result::Result<SignatureGenerationInput, Box<dyn std::error::Error>> {
    let graph = check_type_signatures(&library)?;
    let prepared = prepare_direct_composition(
        &graph,
        problem.clone(),
        operation_checker_without_library(),
        operation_meaning_of(&graph),
    )
    .map_err(|failure| format!("{failure:?}"))?;
    let decision = derive(&prepared).map_err(|failure| format!("{failure:?}"))?;
    let CompositionDecision::Solved(checked, _) = decision else {
        return Err(format!("{} was not solved", problem.identity).into());
    };
    let composition = signature_composition_from_native(&library, &problem, checked.raw(), causes)?;
    Ok(assemble_signature_generation(
        library,
        Some(composition),
        vec![],
    )?)
}

fn flow_generation() -> std::result::Result<SignatureGenerationInput, Box<dyn std::error::Error>> {
    let mut library = rich_library();
    let source = SourceIdentity {
        repository: "comparison".into(),
        revision: "1".into(),
        path: "flow".into(),
        content_digest: "0".repeat(64),
    };
    library.sources.push(source.clone());
    let graph = check_type_signatures(&library)?;
    let truth = rich_slot("truth", true, false);
    let pair = rich_slot("pair", true, false);
    let function = FunctionRef {
        identity: "Flow".into(),
        revision: "1".into(),
        content_digest: "f".repeat(64),
    };
    let site = SiteId("flow".into());
    let outcome = OutcomeId("success".into());
    let production = ProductionId("next".into());
    let requirement = ResourceRequirement {
        id: RequirementId("authority".into()),
        token_type: truth.type_ref.clone(),
        mode: necoherence::typed_mapping::BindingMode::Consume,
        multiplicity: 1u8.into(),
        required_revision: 0u8.into(),
        identity: ResourceIdentityConstraint::Any,
    };
    let output = |id: &str, contract: SlotContract| OutputPort {
        id: PortId(id.into()),
        contract,
        resource_production: None,
    };
    let signature = FunctionSignature {
        reference: function.clone(),
        form: FunctionForm::DeclaredTransform,
        effect: CompositionEffect::PureFunction,
        inputs: vec![
            InputPort {
                id: PortId("input".into()),
                contract: pair.clone(),
                source_constraint: SourceConstraint::AnyCompatible,
                resource_requirement: None,
            },
            InputPort {
                id: PortId("authority".into()),
                contract: truth.clone(),
                source_constraint: SourceConstraint::InitialOnly {
                    input: InputId("left".into()),
                    path: vec![],
                },
                resource_requirement: Some(requirement.id.clone()),
            },
        ],
        outcomes: vec![OutcomeContract {
            id: outcome.clone(),
            form: necoherence::semantic_composition::OutcomeForm::Success,
            value_ports: vec![output("pair", pair.clone())],
            produced_resources: vec![ResourceProduction {
                id: production.clone(),
                token_type: truth.type_ref.clone(),
                revision: 1u8.into(),
                quantity: 1u8.into(),
                provenance: "flow result".into(),
            }],
        }],
        resource_inputs: vec![requirement],
        assumption_ref: "flow provider".into(),
        handles_failure: None,
    };
    let produced = |port: &str, path: Vec<PathStep>| SourceConstraint::ProducedBy {
        site: site.clone(),
        outcome: outcome.clone(),
        port: PortId(port.into()),
        path,
    };
    let problem = CompositionInput {
        identity: "execution-product-resource-projections".into(),
        revision: "1".into(),
        basis: SemanticBasis::of(&graph),
        signatures: vec![signature],
        initial_inputs: vec![
            InitialInput {
                id: InputId("left".into()),
                contract: truth.clone(),
                source: InitialSource::Argument,
                resource: Some(LotId("authority".into())),
            },
            InitialInput {
                id: InputId("right".into()),
                contract: truth.clone(),
                source: InitialSource::Argument,
                resource: None,
            },
        ],
        initial_resources: vec![ResourceLot {
            id: LotId("authority".into()),
            token_type: truth.type_ref.clone(),
            producer: ResourceProducer::Initial {
                identity: "comparison".into(),
                revision: "1".into(),
            },
            revision: 0u8.into(),
            quantity: 1u8.into(),
            provenance: "initial authority".into(),
        }],
        goal: GoalSpec {
            outputs: vec![GoalPort {
                id: GoalPortId("result".into()),
                contract: pair.clone(),
                source_constraint: produced("pair", vec![]),
            }],
            failures: vec![],
            final_resources: vec![ResourceGoal {
                lot: ResourceLotRef::Produced {
                    site: site.clone(),
                    outcome: outcome.clone(),
                    production: production.clone(),
                },
                multiplicity: 1u8.into(),
                revision: 1u8.into(),
            }],
        },
        invocation_domain: InvocationDomain {
            identity: "flow-domain".into(),
            revision: "1".into(),
            sites: vec![InvocationSite {
                id: site,
                function: function.clone(),
            }],
            permitted_projections: vec![],
            permitted_constructions: vec![ConstructionRule {
                identity: "pair".into(),
                type_ref: pair.type_ref.clone(),
                nested_fields: vec![],
                field_constraints: vec![
                    FieldConstraint {
                        field: "left".into(),
                        source: SourceConstraint::InitialOnly {
                            input: InputId("left".into()),
                            path: vec![],
                        },
                        presence: FieldPresence::Required,
                    },
                    FieldConstraint {
                        field: "right".into(),
                        source: SourceConstraint::InitialOnly {
                            input: InputId("right".into()),
                            path: vec![],
                        },
                        presence: FieldPresence::Required,
                    },
                ],
            }],
            permitted_transforms: vec![function.clone()],
            guards: vec![],
        },
        allowed_effects: vec![CompositionEffect::PureFunction],
        explicit_order: vec![],
        selection_policy: Some(SelectionPolicy::AnyFeasible),
        bounds: SearchBounds::default(),
    };
    solve_with_causes(
        library,
        problem,
        &[(
            function,
            vec![(
                outcome,
                OutcomeCause::ValueContract {
                    origin: Origin {
                        source,
                        locator: vec!["success".into()],
                    },
                },
            )],
        )],
    )
}

fn guard_generation(
    kind: &str,
) -> std::result::Result<SignatureGenerationInput, Box<dyn std::error::Error>> {
    let library = rich_library();
    let graph = check_type_signatures(&library)?;
    let (source, accepted, guard_kind, failure_arms) = match kind {
        "presence" => {
            let source = rich_slot("text", false, true);
            (
                source,
                rich_slot("text", true, false),
                GuardKind::Presence,
                vec![("absent", GuardArm::Absent), ("null", GuardArm::Null)],
            )
        }
        "validate" => {
            let accepted = rich_slot("text", true, false);
            (
                rich_slot("text", false, false),
                accepted.clone(),
                GuardKind::Validate(accepted),
                vec![("rejected", GuardArm::Rejected)],
            )
        }
        "variant" => {
            let source = rich_slot("variant", false, true);
            (
                source.clone(),
                rich_slot("known", true, false),
                GuardKind::Variants,
                vec![
                    ("absent", GuardArm::Absent),
                    ("null", GuardArm::Null),
                    ("otherwise", GuardArm::Variant("otherwise".into())),
                ],
            )
        }
        _ => unreachable!(),
    };
    let guard = GuardId(kind.into());
    let result_path = if kind == "variant" {
        vec![PathStep::Variant("known".into())]
    } else {
        vec![]
    };
    let problem = CompositionInput {
        identity: format!("execution-{kind}-guard"),
        revision: "1".into(),
        basis: SemanticBasis::of(&graph),
        signatures: vec![],
        initial_inputs: vec![InitialInput {
            id: InputId("argument".into()),
            contract: source.clone(),
            source: InitialSource::Argument,
            resource: None,
        }],
        initial_resources: vec![],
        goal: GoalSpec {
            outputs: vec![GoalPort {
                id: GoalPortId("result".into()),
                contract: accepted,
                source_constraint: SourceConstraint::InitialOnly {
                    input: InputId("argument".into()),
                    path: result_path.clone(),
                },
            }],
            failures: failure_arms
                .into_iter()
                .map(|(id, arm)| FailureEmbedding {
                    id: FailureEmbeddingId(id.into()),
                    origin: FailureOrigin::Guard {
                        guard: guard.clone(),
                        arm,
                    },
                    contract: source.clone(),
                    final_resources: vec![],
                })
                .collect(),
            final_resources: vec![],
        },
        invocation_domain: InvocationDomain {
            identity: "guard-domain".into(),
            revision: "1".into(),
            sites: vec![],
            permitted_projections: if kind == "variant" {
                vec![PermittedProjection {
                    source_type: source.type_ref.clone(),
                    path: result_path,
                }]
            } else {
                vec![]
            },
            permitted_constructions: vec![],
            permitted_transforms: vec![],
            guards: vec![DeclaredGuard {
                id: guard,
                source_type: source.type_ref.clone(),
                path: vec![],
                kind: guard_kind,
            }],
        },
        allowed_effects: vec![],
        explicit_order: vec![],
        selection_policy: Some(SelectionPolicy::AnyFeasible),
        bounds: SearchBounds::default(),
    };
    solve(library, problem)
}

fn projection_generation(
    kind: &str,
) -> std::result::Result<SignatureGenerationInput, Box<dyn std::error::Error>> {
    let mut library = rich_library();
    if kind == "variant" {
        let variant = library
            .nodes
            .iter_mut()
            .find(|node| node.id == "variant")
            .ok_or("variant type")?;
        let Shape::TaggedUnion(spec) = &mut variant.shape else {
            return Err("variant shape".into());
        };
        spec.branches.truncate(1);
    }
    let graph = check_type_signatures(&library)?;
    let (source_id, destination_id, path, nullable) = match kind {
        "field" => ("pair", "truth", vec![PathStep::Field("left".into())], false),
        "index" => ("truths", "truth", vec![PathStep::Index(1u8.into())], true),
        "variant" => (
            "variant",
            "known",
            vec![PathStep::Variant("known".into())],
            false,
        ),
        _ => unreachable!(),
    };
    let source = rich_slot(source_id, kind != "variant", kind == "variant");
    let guard = GuardId("variant-projection".into());
    let problem = CompositionInput {
        identity: format!("execution-{kind}-projection"),
        revision: "1".into(),
        basis: SemanticBasis::of(&graph),
        signatures: vec![],
        initial_inputs: vec![InitialInput {
            id: InputId("argument".into()),
            contract: source.clone(),
            source: InitialSource::Argument,
            resource: None,
        }],
        initial_resources: vec![],
        goal: GoalSpec {
            outputs: vec![GoalPort {
                id: GoalPortId("result".into()),
                contract: rich_slot(destination_id, true, nullable),
                source_constraint: SourceConstraint::InitialOnly {
                    input: InputId("argument".into()),
                    path: path.clone(),
                },
            }],
            failures: if kind == "variant" {
                [("absent", GuardArm::Absent), ("null", GuardArm::Null)]
                    .into_iter()
                    .map(|(id, arm)| FailureEmbedding {
                        id: FailureEmbeddingId(id.into()),
                        origin: FailureOrigin::Guard {
                            guard: guard.clone(),
                            arm,
                        },
                        contract: source.clone(),
                        final_resources: vec![],
                    })
                    .collect()
            } else {
                vec![]
            },
            final_resources: vec![],
        },
        invocation_domain: InvocationDomain {
            identity: "projection-domain".into(),
            revision: "1".into(),
            sites: vec![],
            permitted_projections: vec![PermittedProjection {
                source_type: source.type_ref.clone(),
                path,
            }],
            permitted_constructions: vec![],
            permitted_transforms: vec![],
            guards: if kind == "variant" {
                vec![DeclaredGuard {
                    id: guard,
                    source_type: source.type_ref.clone(),
                    path: vec![],
                    kind: GuardKind::Variants,
                }]
            } else {
                vec![]
            },
        },
        allowed_effects: vec![],
        explicit_order: vec![],
        selection_policy: Some(SelectionPolicy::AnyFeasible),
        bounds: SearchBounds::default(),
    };
    solve(library, problem)
}

fn variant_generation() -> std::result::Result<SignatureGenerationInput, Box<dyn std::error::Error>>
{
    let library = rich_library();
    let graph = check_type_signatures(&library)?;
    let source = rich_slot("variant", false, true);
    let present = rich_slot("variant", true, false);
    let guard = GuardId("variant".into());
    let problem = CompositionInput {
        identity: "execution-variant-guard".into(),
        revision: "1".into(),
        basis: SemanticBasis::of(&graph),
        signatures: vec![],
        initial_inputs: vec![InitialInput {
            id: InputId("argument".into()),
            contract: source.clone(),
            source: InitialSource::Argument,
            resource: None,
        }],
        initial_resources: vec![],
        goal: GoalSpec {
            outputs: vec![GoalPort {
                id: GoalPortId("result".into()),
                contract: present,
                source_constraint: SourceConstraint::InitialOnly {
                    input: InputId("argument".into()),
                    path: vec![],
                },
            }],
            failures: vec![
                FailureEmbedding {
                    id: FailureEmbeddingId("absent".into()),
                    origin: FailureOrigin::Guard {
                        guard: guard.clone(),
                        arm: GuardArm::Absent,
                    },
                    contract: source.clone(),
                    final_resources: vec![],
                },
                FailureEmbedding {
                    id: FailureEmbeddingId("null".into()),
                    origin: FailureOrigin::Guard {
                        guard: guard.clone(),
                        arm: GuardArm::Null,
                    },
                    contract: source.clone(),
                    final_resources: vec![],
                },
            ],
            final_resources: vec![],
        },
        invocation_domain: InvocationDomain {
            identity: "variant-domain".into(),
            revision: "1".into(),
            sites: vec![],
            permitted_projections: vec![],
            permitted_constructions: vec![],
            permitted_transforms: vec![],
            guards: vec![DeclaredGuard {
                id: guard,
                source_type: source.type_ref.clone(),
                path: vec![],
                kind: GuardKind::Variants,
            }],
        },
        allowed_effects: vec![],
        explicit_order: vec![],
        selection_policy: Some(SelectionPolicy::AnyFeasible),
        bounds: SearchBounds::default(),
    };
    solve(library, problem)
}

fn sequence_generation() -> std::result::Result<SignatureGenerationInput, Box<dyn std::error::Error>>
{
    let mut library = rich_library();
    let source = SourceIdentity {
        repository: "comparison".into(),
        revision: "1".into(),
        path: "sequence".into(),
        content_digest: "0".repeat(64),
    };
    library.sources.push(source.clone());
    for (id, wire_identity) in [
        ("first-operation", "FirstOperation"),
        ("second-operation", "SecondOperation"),
    ] {
        library.definitions.push(DefinitionInput {
            id: id.into(),
            wire_identity: wire_identity.into(),
            shape: SignatureDefinitionShape::Operation(OperationContract {
                effect: EffectPoint::HttpRequestResponse,
                inputs: vec![],
                outcomes: vec![SignatureOutcome {
                    id: "success".into(),
                    form: necoherence::type_signatures::OutcomeForm::Success,
                    cause: OutcomeCause::ValueContract {
                        origin: Origin {
                            source: source.clone(),
                            locator: vec!["success".into()],
                        },
                    },
                    value_ports: vec![SignaturePort {
                        id: "output".into(),
                        contract: SignatureSlot {
                            type_id: "truth".into(),
                            required: true,
                            nullable: false,
                        },
                    }],
                    produced_resources: vec![],
                }],
            }),
        });
    }
    let graph = check_type_signatures(&library)?;
    let truth = rich_slot("truth", true, false);
    let outcome = OutcomeId("success".into());
    let digest = signature_basis(&library, None, &[])?.graph_sha256;
    let signature = |identity: &str, definition: &str| {
        let reference = FunctionRef {
            identity: identity.into(),
            revision: "1".into(),
            content_digest: digest.clone(),
        };
        (
            reference.clone(),
            FunctionSignature {
                reference,
                form: FunctionForm::Operation(signature_definition_ref(definition)),
                effect: CompositionEffect::HttpRequestResponse,
                inputs: vec![],
                outcomes: vec![OutcomeContract {
                    id: outcome.clone(),
                    form: necoherence::semantic_composition::OutcomeForm::Success,
                    value_ports: vec![OutputPort {
                        id: PortId("output".into()),
                        contract: truth.clone(),
                        resource_production: None,
                    }],
                    produced_resources: vec![],
                }],
                resource_inputs: vec![],
                assumption_ref: format!("{identity} provider"),
                handles_failure: None,
            },
        )
    };
    let (first_ref, first) = signature("FirstOperation", "first-operation");
    let (second_ref, second) = signature("SecondOperation", "second-operation");
    let first_site = SiteId("first".into());
    let second_site = SiteId("second".into());
    let problem = CompositionInput {
        identity: "execution-sequential-http".into(),
        revision: "1".into(),
        basis: SemanticBasis::of(&graph),
        signatures: vec![first, second],
        initial_inputs: vec![],
        initial_resources: vec![],
        goal: GoalSpec {
            outputs: vec![GoalPort {
                id: GoalPortId("result".into()),
                contract: truth,
                source_constraint: SourceConstraint::ProducedBy {
                    site: second_site.clone(),
                    outcome: outcome.clone(),
                    port: PortId("output".into()),
                    path: vec![],
                },
            }],
            failures: vec![],
            final_resources: vec![],
        },
        invocation_domain: InvocationDomain {
            identity: "sequence-domain".into(),
            revision: "1".into(),
            sites: vec![
                InvocationSite {
                    id: first_site.clone(),
                    function: first_ref.clone(),
                },
                InvocationSite {
                    id: second_site.clone(),
                    function: second_ref.clone(),
                },
            ],
            permitted_projections: vec![],
            permitted_constructions: vec![],
            permitted_transforms: vec![first_ref.clone(), second_ref.clone()],
            guards: vec![],
        },
        allowed_effects: vec![CompositionEffect::HttpRequestResponse],
        explicit_order: vec![(first_site, second_site)],
        selection_policy: Some(SelectionPolicy::AnyFeasible),
        bounds: SearchBounds::default(),
    };
    let cause = || OutcomeCause::ValueContract {
        origin: Origin {
            source: source.clone(),
            locator: vec!["success".into()],
        },
    };
    solve_with_causes(
        library,
        problem,
        &[
            (first_ref, vec![(outcome.clone(), cause())]),
            (second_ref, vec![(outcome, cause())]),
        ],
    )
}

fn independent_sequence_generation(
    reverse: bool,
) -> std::result::Result<SignatureGenerationInput, Box<dyn std::error::Error>> {
    let mut library = rich_library();
    let source = SourceIdentity {
        repository: "comparison".into(),
        revision: "1".into(),
        path: "independent-sequence".into(),
        content_digest: "0".repeat(64),
    };
    library.sources.push(source.clone());
    for (id, wire_identity, effect) in
        [("final-http", "FinalHttp", EffectPoint::HttpRequestResponse)]
    {
        library.definitions.push(DefinitionInput {
            id: id.into(),
            wire_identity: wire_identity.into(),
            shape: SignatureDefinitionShape::Operation(OperationContract {
                effect,
                inputs: vec![
                    SignaturePort {
                        id: "first".into(),
                        contract: SignatureSlot {
                            type_id: "truth".into(),
                            required: true,
                            nullable: false,
                        },
                    },
                    SignaturePort {
                        id: "second".into(),
                        contract: SignatureSlot {
                            type_id: "truth".into(),
                            required: true,
                            nullable: false,
                        },
                    },
                ],
                outcomes: vec![SignatureOutcome {
                    id: "success".into(),
                    form: necoherence::type_signatures::OutcomeForm::Success,
                    cause: OutcomeCause::ValueContract {
                        origin: Origin {
                            source: source.clone(),
                            locator: vec!["success".into()],
                        },
                    },
                    value_ports: vec![SignaturePort {
                        id: "output".into(),
                        contract: SignatureSlot {
                            type_id: "truth".into(),
                            required: true,
                            nullable: false,
                        },
                    }],
                    produced_resources: vec![],
                }],
            }),
        });
    }
    let graph = check_type_signatures(&library)?;
    let truth = rich_slot("truth", true, false);
    let outcome = OutcomeId("success".into());
    let digest = signature_basis(&library, None, &[])?.graph_sha256;
    let function = |identity: &str| FunctionRef {
        identity: identity.into(),
        revision: "1".into(),
        content_digest: digest.clone(),
    };
    let first_ref = function("FirstPure");
    let second_ref = function("SecondPure");
    let final_ref = function("FinalHttp");
    let first_site = SiteId("first".into());
    let second_site = SiteId("second".into());
    let final_site = SiteId("final".into());
    let output = |id: &str| OutputPort {
        id: PortId(id.into()),
        contract: truth.clone(),
        resource_production: None,
    };
    let source_constraint = |site: &SiteId| SourceConstraint::ProducedBy {
        site: site.clone(),
        outcome: outcome.clone(),
        port: PortId("output".into()),
        path: vec![],
    };
    let signature = |reference: FunctionRef,
                     definition: Option<&str>,
                     effect: CompositionEffect,
                     inputs: Vec<InputPort>| FunctionSignature {
        reference,
        form: definition.map_or(FunctionForm::DeclaredTransform, |value| {
            FunctionForm::Operation(signature_definition_ref(value))
        }),
        effect,
        inputs,
        outcomes: vec![OutcomeContract {
            id: outcome.clone(),
            form: necoherence::semantic_composition::OutcomeForm::Success,
            value_ports: vec![output("output")],
            produced_resources: vec![],
        }],
        resource_inputs: vec![],
        assumption_ref: "comparison provider".into(),
        handles_failure: None,
    };
    let first = signature(
        first_ref.clone(),
        None,
        CompositionEffect::PureFunction,
        vec![],
    );
    let second = signature(
        second_ref.clone(),
        None,
        CompositionEffect::PureFunction,
        vec![],
    );
    let final_signature = signature(
        final_ref.clone(),
        Some("final-http"),
        CompositionEffect::HttpRequestResponse,
        vec![
            InputPort {
                id: PortId("first".into()),
                contract: truth.clone(),
                source_constraint: source_constraint(&first_site),
                resource_requirement: None,
            },
            InputPort {
                id: PortId("second".into()),
                contract: truth.clone(),
                source_constraint: source_constraint(&second_site),
                resource_requirement: None,
            },
        ],
    );
    let order = if reverse {
        (second_site.clone(), first_site.clone())
    } else {
        (first_site.clone(), second_site.clone())
    };
    let problem = CompositionInput {
        identity: "independent-pure-before-http".into(),
        revision: "1".into(),
        basis: SemanticBasis::of(&graph),
        signatures: vec![first, second, final_signature],
        initial_inputs: vec![],
        initial_resources: vec![],
        goal: GoalSpec {
            outputs: vec![GoalPort {
                id: GoalPortId("result".into()),
                contract: truth,
                source_constraint: source_constraint(&final_site),
            }],
            failures: vec![],
            final_resources: vec![],
        },
        invocation_domain: InvocationDomain {
            identity: "independent-sequence-domain".into(),
            revision: "1".into(),
            sites: vec![
                InvocationSite {
                    id: first_site,
                    function: first_ref.clone(),
                },
                InvocationSite {
                    id: second_site,
                    function: second_ref.clone(),
                },
                InvocationSite {
                    id: final_site,
                    function: final_ref.clone(),
                },
            ],
            permitted_projections: vec![],
            permitted_constructions: vec![],
            permitted_transforms: vec![first_ref.clone(), second_ref.clone(), final_ref.clone()],
            guards: vec![],
        },
        allowed_effects: vec![
            CompositionEffect::PureFunction,
            CompositionEffect::HttpRequestResponse,
        ],
        explicit_order: vec![order],
        selection_policy: Some(SelectionPolicy::RequireUnique),
        bounds: SearchBounds::default(),
    };
    let cause = || OutcomeCause::ValueContract {
        origin: Origin {
            source: source.clone(),
            locator: vec!["success".into()],
        },
    };
    solve_with_causes(
        library,
        problem,
        &[
            (first_ref, vec![(outcome.clone(), cause())]),
            (second_ref, vec![(outcome.clone(), cause())]),
            (final_ref, vec![(outcome, cause())]),
        ],
    )
}

fn main() -> std::result::Result<(), Box<dyn std::error::Error>> {
    let mut text = String::new();
    io::stdin().read_to_string(&mut text)?;
    let request: Value = serde_json::from_str(&text)?;
    let effects = request["scenarios"]
        .as_array()
        .ok_or("scenarios required")?;
    let mut output = serde_json::Map::new();
    for value in effects {
        let name = value.as_str().ok_or("effect must be a string")?;
        let input = match name {
            "pure" => operation_generation(CompositionEffect::DataOnly, 0, 0, false)?,
            "pair" => operation_generation(CompositionEffect::DataOnly, 0, 0, true)?,
            "pair_http" => {
                operation_generation(CompositionEffect::HttpRequestResponse, 0, 0, true)?
            }
            "http" => operation_generation(CompositionEffect::HttpRequestResponse, 0, 0, false)?,
            "presence" => guard_generation("presence")?,
            "validate" => guard_generation("validate")?,
            "variant" => variant_generation()?,
            "variant_projection" => projection_generation("variant")?,
            "field" => projection_generation("field")?,
            "index" => projection_generation("index")?,
            "flow" => flow_generation()?,
            "sequence" => sequence_generation()?,
            "independent_sequence_left" => independent_sequence_generation(false)?,
            "independent_sequence_right" => independent_sequence_generation(true)?,
            padded if padded.starts_with("pure_padded_") => operation_generation(
                CompositionEffect::DataOnly,
                padded["pure_padded_".len()..].parse()?,
                0,
                false,
            )?,
            typed if typed.starts_with("pure_typed_") => operation_generation(
                CompositionEffect::DataOnly,
                0,
                typed["pure_typed_".len()..].parse()?,
                false,
            )?,
            _ => return Err("unknown scenario".into()),
        };
        output.insert(name.into(), json!(encode_signature_generation(&input)?));
    }
    let mut stdout = std::io::stdout().lock();
    writeln!(stdout, "{}", Value::Object(output))?;
    Ok(())
}
