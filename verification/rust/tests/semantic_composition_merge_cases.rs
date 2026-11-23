// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only
#![allow(
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::unwrap_used,
    clippy::panic
)]

use necoherence::semantic_composition::*;
use necoherence::semantic_exchange::*;
use necoherence::semantic_types::*;
use necoherence::signature_admission::*;
use necoherence::type_signatures::*;
use necoherence_composition_solver::composition_search::derive;
use necoherence_composition_solver::wire_admission::verified_signature_derivation;
use necoherence_composition_solver::{closure::*, document::*, verification::*};
use num_bigint::BigUint;
use std::sync::Arc;

fn profile() -> ValueSemanticProfile {
    let reference = ProfileRef {
        identity: "composition-test".into(),
        revision: "1".into(),
        content_digest: "a".repeat(64),
    };
    ValueSemanticProfile {
        reference: reference.clone(),
        source_refs: vec![],
        integer_domains: vec![IntegerDomainBinding {
            name: "integer".into(),
            reference: reference.clone(),
            range: IntegerDomain::Unbounded,
            forms: vec![IntegerForm::Number, IntegerForm::DecimalString],
        }],
        default_integer_domain: "integer".into(),
        numbers: NumberModel { decimals: true },
        grapheme_rules: None,
        format_bindings: vec![],
        wrappers: vec![Wrapper {
            name: "bytes".into(),
            key: "bytes".into(),
            payload: WrapperPayload::Bytes,
        }],
        tag: Some(TagModel {
            key: "kind".into(),
            format: None,
            sealed: vec![SealedForm {
                tag: "sealed".into(),
                fields: vec![],
                extras: SealedExtras::Reject,
            }],
        }),
        bytes_policy: Some(BytesPolicy {
            reference: reference.clone(),
            padding_optional: true,
            alphabet: BytesAlphabet::Either,
            strict_pad_bits: true,
            wrapper: Some("bytes".into()),
        }),
    }
}

fn library() -> TypeSignatureLibrary {
    TypeSignatureLibrary {
        schema: "ncoh-type-signatures@1".into(),
        identity: "composition-test-library".into(),
        revision: "1".into(),
        profile: profile(),
        sources: vec![SourceIdentity {
            repository: "semantic-composition-execution-test".into(),
            revision: "1".into(),
            path: "transform".into(),
            content_digest: "d".repeat(64),
        }],
        provenance: vec![],
        groups: vec![],
        annotations: vec![],
        definitions: vec![],
        nodes: vec![
            TypeNodeInput {
                id: "text".into(),
                shape: Shape::String(StringSpec {
                    format: None,
                    lengths: vec![],
                    wrapper: None,
                    const_value: None,
                    enum_values: None,
                    examples: vec!["valid".into()],
                    default_value: None,
                }),
            },
            TypeNodeInput {
                id: "never".into(),
                shape: Shape::Never,
            },
            TypeNodeInput {
                id: "integer".into(),
                shape: Shape::Integer(IntegerSpec {
                    domain: Some("integer".into()),
                    minimum: None,
                    maximum: None,
                    const_value: None,
                    enum_values: None,
                    default_value: None,
                }),
            },
            TypeNodeInput {
                id: "raw_body".into(),
                shape: Shape::RawBody {
                    encoding: "raw".into(),
                },
            },
            TypeNodeInput {
                id: "bytes".into(),
                shape: Shape::Bytes(LengthSpec {
                    minimum: None,
                    maximum: None,
                }),
            },
            TypeNodeInput {
                id: "inner".into(),
                shape: Shape::Product(SignatureProduct {
                    fields: vec![
                        SignatureField {
                            wire_name: "content".into(),
                            slot: SignatureSlot {
                                type_id: "text".into(),
                                required: true,
                                nullable: false,
                            },
                        },
                        SignatureField {
                            wire_name: "body".into(),
                            slot: SignatureSlot {
                                type_id: "raw_body".into(),
                                required: false,
                                nullable: false,
                            },
                        },
                        SignatureField {
                            wire_name: "amount".into(),
                            slot: SignatureSlot {
                                type_id: "integer".into(),
                                required: false,
                                nullable: false,
                            },
                        },
                    ],
                    extras: SignatureExtraMembers::Reject,
                }),
            },
            TypeNodeInput {
                id: "outer".into(),
                shape: Shape::Product(SignatureProduct {
                    fields: vec![SignatureField {
                        wire_name: "payload".into(),
                        slot: SignatureSlot {
                            type_id: "inner".into(),
                            required: true,
                            nullable: false,
                        },
                    }],
                    extras: SignatureExtraMembers::Reject,
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
                id: "variant".into(),
                shape: Shape::TaggedUnion(SignatureUnion {
                    branches: vec![SignatureUnionBranch {
                        target: "sealed".into(),
                        wire_tag: "sealed".into(),
                        selector: BranchSelector::InternalTag,
                    }],
                }),
            },
        ],
    }
}

fn slot(id: &str, required: bool, nullable: bool) -> SlotContract {
    SlotContract {
        type_ref: signature_type_ref(id),
        required,
        nullable,
    }
}

fn presence_generation() -> SignatureGenerationInput {
    presence_generation_for("text")
}

fn presence_generation_for(type_id: &str) -> SignatureGenerationInput {
    presence_generation_with(type_id, vec![])
}

fn presence_generation_with(
    type_id: &str,
    extra_nodes: Vec<TypeNodeInput>,
) -> SignatureGenerationInput {
    let mut declaration = library();
    declaration.nodes.extend(extra_nodes);
    if !declaration.nodes.iter().any(|node| node.id == type_id) {
        declaration.nodes.push(TypeNodeInput {
            id: type_id.into(),
            shape: Shape::String(StringSpec {
                format: None,
                lengths: vec![],
                wrapper: None,
                const_value: None,
                enum_values: None,
                examples: vec!["valid".into()],
                default_value: None,
            }),
        });
    }
    let library = Arc::new(declaration);
    let graph = check_type_signatures(&library).unwrap();
    let optional_text = slot(type_id, false, true);
    let required_text = slot(type_id, true, false);
    let input = CompositionInput {
        identity: "presence-guard".into(),
        revision: "1".into(),
        basis: SemanticBasis::of(&graph),
        signatures: vec![],
        initial_inputs: vec![InitialInput {
            id: InputId("argument".into()),
            contract: optional_text.clone(),
            source: InitialSource::Argument,
            resource: None,
        }],
        initial_resources: vec![],
        goal: GoalSpec {
            outputs: vec![GoalPort {
                id: GoalPortId("result".into()),
                contract: required_text,
                source_constraint: SourceConstraint::AnyCompatible,
            }],
            failures: vec![
                FailureEmbedding {
                    id: FailureEmbeddingId("absent".into()),
                    origin: FailureOrigin::Guard {
                        guard: GuardId("presence".into()),
                        arm: GuardArm::Absent,
                    },
                    contract: optional_text.clone(),
                    final_resources: vec![],
                },
                FailureEmbedding {
                    id: FailureEmbeddingId("null".into()),
                    origin: FailureOrigin::Guard {
                        guard: GuardId("presence".into()),
                        arm: GuardArm::Null,
                    },
                    contract: optional_text,
                    final_resources: vec![],
                },
            ],
            final_resources: vec![],
        },
        invocation_domain: InvocationDomain {
            identity: "finite".into(),
            revision: "1".into(),
            sites: vec![],
            permitted_projections: vec![],
            permitted_constructions: vec![],
            permitted_transforms: vec![],
            guards: vec![DeclaredGuard {
                id: GuardId("presence".into()),
                source_type: signature_type_ref(type_id),
                path: vec![],
                kind: GuardKind::Presence,
            }],
        },
        allowed_effects: vec![],
        explicit_order: vec![],
        selection_policy: Some(SelectionPolicy::AnyFeasible),
        bounds: SearchBounds {
            max_sample_length: BigUint::from(59u32),
            ..SearchBounds::default()
        },
    };

    let prepared = prepare_direct_composition(
        &graph,
        input.clone(),
        operation_checker_without_library(),
        operation_meaning_of(&graph),
    )
    .unwrap();
    let checked = match derive(&prepared).unwrap() {
        CompositionDecision::Solved(checked, _) => checked,
        _ => panic!("presence composition is not solved"),
    };
    verify_composition(&prepared, checked.raw()).unwrap();
    let composition =
        signature_composition_from_native(&library, &input, checked.raw(), &[]).unwrap();
    assemble_signature_generation((*library).clone(), Some(composition), vec![]).unwrap()
}

fn refresh_basis(input: &mut SignatureGenerationInput) {
    input.basis = signature_basis(
        &input.signatures,
        input.composition.as_ref(),
        &input.entrypoints,
    )
    .unwrap();
}

fn two_site_generation(mode: necoherence::typed_mapping::BindingMode) -> SignatureGenerationInput {
    let library = Arc::new(library());
    let graph = check_type_signatures(&library).unwrap();
    let initial_quantity = if mode == necoherence::typed_mapping::BindingMode::Consume {
        2u8.into()
    } else {
        1u8.into()
    };
    let contract = slot("text", true, false);
    let body_contract = slot("raw_body", true, false);
    let amount_contract = slot("integer", true, false);
    let bytes_contract = slot("bytes", true, false);
    let function = FunctionRef {
        identity: "transform".into(),
        revision: "1".into(),
        content_digest: "c".repeat(64),
    };
    let outcome_id = OutcomeId("success".into());
    let port_id = PortId("value".into());
    let body_port_id = PortId("body".into());
    let amount_port_id = PortId("amount".into());
    let bytes_port_id = PortId("octets".into());
    let production_id = ProductionId("next-lot".into());
    let requirement = ResourceRequirement {
        id: RequirementId("access".into()),
        token_type: contract.type_ref.clone(),
        mode: mode.clone(),
        multiplicity: 1u8.into(),
        required_revision: 0u8.into(),
        identity: ResourceIdentityConstraint::Any,
    };
    let signature = FunctionSignature {
        reference: function.clone(),
        form: FunctionForm::DeclaredTransform,
        effect: CompositionEffect::PureFunction,
        inputs: vec![
            InputPort {
                id: PortId("input".into()),
                contract: contract.clone(),
                source_constraint: SourceConstraint::AnyCompatible,
                resource_requirement: Some(requirement.id.clone()),
            },
            InputPort {
                id: PortId("body".into()),
                contract: body_contract.clone(),
                source_constraint: SourceConstraint::AnyCompatible,
                resource_requirement: None,
            },
            InputPort {
                id: amount_port_id.clone(),
                contract: amount_contract.clone(),
                source_constraint: SourceConstraint::AnyCompatible,
                resource_requirement: None,
            },
            InputPort {
                id: bytes_port_id.clone(),
                contract: bytes_contract.clone(),
                source_constraint: SourceConstraint::AnyCompatible,
                resource_requirement: None,
            },
        ],
        outcomes: vec![OutcomeContract {
            id: outcome_id.clone(),
            form: necoherence::semantic_composition::OutcomeForm::Success,
            value_ports: vec![
                OutputPort {
                    id: port_id.clone(),
                    contract: contract.clone(),
                    resource_production: None,
                },
                OutputPort {
                    id: body_port_id.clone(),
                    contract: body_contract.clone(),
                    resource_production: None,
                },
                OutputPort {
                    id: amount_port_id.clone(),
                    contract: amount_contract.clone(),
                    resource_production: None,
                },
                OutputPort {
                    id: bytes_port_id.clone(),
                    contract: bytes_contract.clone(),
                    resource_production: None,
                },
            ],
            produced_resources: vec![ResourceProduction {
                id: production_id.clone(),
                token_type: contract.type_ref.clone(),
                revision: 0u8.into(),
                quantity: 1u8.into(),
                provenance: "transform result".into(),
            }],
        }],
        resource_inputs: vec![requirement],
        assumption_ref: "test provider".into(),
        handles_failure: None,
    };
    let first = SiteId("first".into());
    let second = SiteId("second".into());
    let problem = CompositionInput {
        identity: "two-site-resource-flow".into(),
        revision: "1".into(),
        basis: SemanticBasis::of(&graph),
        signatures: vec![signature],
        initial_inputs: vec![
            InitialInput {
                id: InputId("argument".into()),
                contract: contract.clone(),
                source: InitialSource::Argument,
                resource: Some(LotId("original-lot".into())),
            },
            InitialInput {
                id: InputId("body".into()),
                contract: body_contract.clone(),
                source: InitialSource::Argument,
                resource: None,
            },
            InitialInput {
                id: InputId("amount".into()),
                contract: amount_contract.clone(),
                source: InitialSource::Argument,
                resource: None,
            },
            InitialInput {
                id: InputId("octets".into()),
                contract: bytes_contract.clone(),
                source: InitialSource::Argument,
                resource: None,
            },
        ],
        initial_resources: vec![ResourceLot {
            id: LotId("original-lot".into()),
            token_type: contract.type_ref.clone(),
            producer: ResourceProducer::Initial {
                identity: "session".into(),
                revision: "1".into(),
            },
            revision: 0u8.into(),
            quantity: initial_quantity,
            provenance: "initial authority".into(),
        }],
        goal: GoalSpec {
            outputs: vec![
                GoalPort {
                    id: GoalPortId("result".into()),
                    contract,
                    source_constraint: SourceConstraint::ProducedBy {
                        site: second.clone(),
                        outcome: outcome_id.clone(),
                        port: port_id.clone(),
                        path: vec![],
                    },
                },
                GoalPort {
                    id: GoalPortId("body_result".into()),
                    contract: body_contract,
                    source_constraint: SourceConstraint::ProducedBy {
                        site: second.clone(),
                        outcome: outcome_id.clone(),
                        port: body_port_id.clone(),
                        path: vec![],
                    },
                },
                GoalPort {
                    id: GoalPortId("amount_result".into()),
                    contract: amount_contract,
                    source_constraint: SourceConstraint::ProducedBy {
                        site: second.clone(),
                        outcome: outcome_id.clone(),
                        port: amount_port_id.clone(),
                        path: vec![],
                    },
                },
                GoalPort {
                    id: GoalPortId("octets_result".into()),
                    contract: bytes_contract,
                    source_constraint: SourceConstraint::ProducedBy {
                        site: second.clone(),
                        outcome: outcome_id.clone(),
                        port: bytes_port_id.clone(),
                        path: vec![],
                    },
                },
            ],
            failures: vec![],
            final_resources: vec![ResourceGoal {
                lot: ResourceLotRef::Produced {
                    site: second.clone(),
                    outcome: outcome_id.clone(),
                    production: production_id.clone(),
                },
                multiplicity: 1u8.into(),
                revision: 0u8.into(),
            }],
        },
        invocation_domain: InvocationDomain {
            identity: "two-sites".into(),
            revision: "1".into(),
            sites: vec![
                InvocationSite {
                    id: first.clone(),
                    function: function.clone(),
                },
                InvocationSite {
                    id: second.clone(),
                    function: function.clone(),
                },
            ],
            permitted_projections: vec![],
            permitted_constructions: vec![],
            permitted_transforms: vec![function.clone()],
            guards: vec![],
        },
        allowed_effects: vec![CompositionEffect::PureFunction],
        explicit_order: vec![],
        selection_policy: Some(SelectionPolicy::AnyFeasible),
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
    let checked = match derive(&prepared).unwrap() {
        CompositionDecision::Solved(checked, _) => checked,
        _ => panic!("two-site composition is not solved"),
    };
    verify_composition(&prepared, checked.raw()).unwrap();
    let origin = OutcomeCause::ValueContract {
        origin: Origin {
            source: SourceIdentity {
                repository: "semantic-composition-execution-test".into(),
                revision: "1".into(),
                path: "transform".into(),
                content_digest: "d".repeat(64),
            },
            locator: vec!["success".into()],
        },
    };
    let composition = signature_composition_from_native(
        &library,
        &problem,
        checked.raw(),
        &[(function, vec![(outcome_id, origin)])],
    )
    .unwrap();
    assemble_signature_generation((*library).clone(), Some(composition), vec![]).unwrap()
}

fn resource_judgment_failure(mutate: impl FnOnce(&mut serde_json::Value)) -> WitnessFailure {
    let mut input = two_site_generation(necoherence::typed_mapping::BindingMode::Consume);
    mutate(input.composition.as_mut().unwrap());
    refresh_basis(&mut input);
    let checked = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input),
        input,
    )
    .unwrap();
    match verified_signature_derivation(checked.input(), checked.graph()) {
        Err(SignatureCompositionAdmissionFailure::Composition(failure)) => failure,
        _ => panic!("unexpected admission result"),
    }
}

#[test]
fn composition_generation_does_not_check_unused_undefined_meaning() {
    let unused = TypeNodeInput {
        id: "unused".into(),
        shape: Shape::String(StringSpec {
            format: None,
            lengths: vec![LengthBound {
                unit: StringLengthUnit::Graphemes,
                minimum: None,
                maximum: Some(num_bigint::BigUint::from(8u8)),
            }],
            wrapper: None,
            const_value: None,
            enum_values: None,
            examples: vec![],
            default_value: None,
        }),
    };
    let input = presence_generation_with("text", vec![unused]);
    let graph = check_type_signatures(&input.signatures).unwrap();
    assert!(necoherence::semantic_validation::check_meaning_defined(
        &graph,
        std::slice::from_ref(
            &graph
                .nodes
                .iter()
                .find(|node| node.reference.definition_name.as_ref() == "unused")
                .unwrap()
                .reference
        ),
    )
    .is_err());
    let document = encode_signature_generation(&input).unwrap();
    assert!(!render_admitted(&input).is_empty());
    assert!(
        necoherence_generator::renderer::render_signature_exchange_for(
            &necoherence_generator::renderer::Target::Rust,
            &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input),
            &document
        )
        .is_ok()
    );
}

#[test]
fn pending_presence_failure_rejects_success_terminal() {
    let mut input = presence_generation();
    let derivation = &mut input.composition.as_mut().unwrap()["derivation"];
    let arms = derivation
        .pointer_mut("/plan/root/node/fields/arms")
        .and_then(serde_json::Value::as_array_mut)
        .unwrap();
    let success = arms.get(2).and_then(|arm| arm.get(1)).cloned().unwrap();
    *arms.get_mut(0).and_then(|arm| arm.get_mut(1)).unwrap() = success;
    refresh_basis(&mut input);
    let failure = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input),
        input,
    )
    .err();
    let rendered = format!("{failure:?}");
    assert!(
        matches!(failure, Some(AdmissionFailure::Certificate(_)))
            && rendered.contains("observations: Mismatched")
            && rendered.matches("Mismatched").count() == 1,
        "{rendered}"
    );
}

#[test]
fn missing_invocation_binding_precedes_rank_violation() {
    let mut input = two_site_generation(necoherence::typed_mapping::BindingMode::Consume);
    let composition = input.composition.as_mut().unwrap();
    let invocation = composition["derivation"]
        .pointer_mut("/plan/root/node/fields/invocation")
        .unwrap();
    let root = invocation["site"].as_str().unwrap().to_owned();
    let before = if root == "first" { "second" } else { "first" };
    invocation["bindings"] = serde_json::json!([]);
    let order = serde_json::json!([[before, root]]);
    *composition["problem"]
        .pointer_mut("/explicit_order")
        .unwrap() = order.clone();
    *composition["derivation"]
        .pointer_mut("/witness/input_snapshot/explicit_order")
        .unwrap() = order;
    refresh_basis(&mut input);
    let checked = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input),
        input,
    )
    .unwrap();
    assert!(matches!(
        verified_signature_derivation(checked.input(), checked.graph()),
        Err(SignatureCompositionAdmissionFailure::Composition(
            WitnessFailure::MissingBinding(_)
        ))
    ));
}

#[test]
fn forged_resource_requirement_is_a_missing_binding() {
    let failure = resource_judgment_failure(|composition| {
        *composition["derivation"]
            .pointer_mut("/plan/root/node/fields/invocation/resources/0/requirement")
            .unwrap() = serde_json::json!("forged");
    });
    assert_eq!(failure, WitnessFailure::MissingBinding("access".into()));
}

#[test]
fn input_without_a_lot_is_rejected_as_input_backing_producer() {
    let failure = resource_judgment_failure(|composition| {
        *composition["problem"]
            .pointer_mut("/initial_inputs/0/resource")
            .unwrap() = serde_json::Value::Null;
        *composition["derivation"]
            .pointer_mut("/witness/input_snapshot/initial_inputs/0/resource")
            .unwrap() = serde_json::Value::Null;
    });
    assert_eq!(
        failure,
        WitnessFailure::ResourceLoweringMismatch("input backing producer".into())
    );
}

#[test]
fn resource_revision_mismatch_is_reported_as_required_resource_revision() {
    let failure = resource_judgment_failure(|composition| {
        for pointer in [
            "/problem/signatures/0/resource_inputs/0/required_revision",
            "/derivation/witness/input_snapshot/signatures/0/resource_inputs/0/required_revision",
        ] {
            *composition.pointer_mut(pointer).unwrap() = serde_json::json!("1");
        }
    });
    assert_eq!(
        failure,
        WitnessFailure::ResourceLoweringMismatch("required resource revision".into())
    );
}

fn presence_resource_failure(mutate: impl FnOnce(&mut Vec<serde_json::Value>)) -> WitnessFailure {
    let mut input = presence_generation();
    let composition = input.composition.as_mut().unwrap();
    let traces = composition["derivation"]
        .pointer_mut("/witness/resource_traces")
        .and_then(serde_json::Value::as_array_mut)
        .unwrap();
    mutate(traces);
    refresh_basis(&mut input);
    let checked = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input),
        input,
    )
    .unwrap();
    match verified_signature_derivation(checked.input(), checked.graph()) {
        Err(SignatureCompositionAdmissionFailure::Composition(failure)) => failure,
        _ => panic!("unexpected admission result"),
    }
}

#[test]
fn branch_without_resource_certificate_is_a_branch_resource_coverage_failure() {
    let failure = presence_resource_failure(|traces| traces.clear());
    assert_eq!(
        failure,
        WitnessFailure::MissingEvidence("branch resource coverage".into())
    );
}

#[test]
fn branch_without_matching_resource_certificate_is_a_branch_resource_trace_failure() {
    let failure = presence_resource_failure(|traces| traces[1] = traces[2].clone());
    assert_eq!(
        failure,
        WitnessFailure::MissingEvidence("branch resource trace".into())
    );
}

#[test]
fn duplicated_resource_certificate_is_a_duplicated_branch_resource_trace_failure() {
    let failure = presence_resource_failure(|traces| traces[1] = traces[0].clone());
    assert_eq!(
        failure,
        WitnessFailure::MissingEvidence("duplicated branch resource trace".into())
    );
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
