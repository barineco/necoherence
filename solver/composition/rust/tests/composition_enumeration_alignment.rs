// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

#![allow(
    clippy::expect_used,
    clippy::panic,
    clippy::unwrap_used,
    clippy::indexing_slicing
)]

use necoherence::semantic_composition as composition;
use necoherence::semantic_types::*;
use necoherence::signature_admission::{check_type_signatures, signature_type_ref};
use necoherence::type_signatures::*;
use necoherence::typed_mapping as resource;
use necoherence_composition_solver::verification::CompositionWitness;
use num_bigint::BigUint;
#[allow(unused_imports)]
use samples::*;

fn empty_integer_library() -> TypeSignatureLibrary {
    let mut library = library();
    library.nodes.push(TypeNodeInput {
        id: "empty".into(),
        shape: Shape::TaggedUnion(SignatureUnion {
            branches: Vec::new(),
        }),
    });
    library
}

fn slot(node: &str) -> SlotContract {
    SlotContract {
        type_ref: signature_type_ref(node),
        required: true,
        nullable: false,
    }
}

fn single_token_lot(token_type: TypeRef, quantity: u32) -> composition::ResourceLot {
    composition::ResourceLot {
        id: composition::LotId("lot".into()),
        token_type,
        producer: composition::ResourceProducer::Initial {
            identity: "producer".into(),
            revision: "1".into(),
        },
        revision: BigUint::from(1u8),
        quantity: BigUint::from(quantity),
        provenance: "alignment".into(),
    }
}

fn consuming_requirement(
    token_type: TypeRef,
    multiplicity: u8,
) -> composition::ResourceRequirement {
    composition::ResourceRequirement {
        id: composition::RequirementId("token".into()),
        token_type,
        mode: resource::BindingMode::Consume,
        multiplicity: BigUint::from(multiplicity),
        required_revision: BigUint::from(1u8),
        identity: composition::ResourceIdentityConstraint::Any,
    }
}

#[test]
fn empty_output_function_is_excluded_from_enumeration() {
    let library = empty_integer_library();
    let graph = check_type_signatures(&library).unwrap();
    let problem = invocation_problem(
        &graph,
        &slot("empty"),
        composition::CompositionEffect::PureFunction,
    );
    let prepared = composition::prepare_direct_composition(
        &graph,
        problem,
        composition::operation_checker_without_library(),
        composition::operation_meaning_of(&graph),
    )
    .unwrap();
    let state = necoherence_composition_solver::search_state::initial_state(&prepared);
    assert!(
        necoherence_composition_solver::enumeration::admissible_sites(&prepared, &state).is_empty()
    );
    let invocations =
        necoherence_composition_solver::enumeration::enumerate_invocations(&prepared, &state);
    assert!(invocations.values.is_empty());
    assert!(invocations.obligations.is_empty());
}

#[test]
fn prefix_resource_shortfall_excludes_invocation_and_sufficient_quantity_keeps_it() {
    let library = library();
    let graph = check_type_signatures(&library).unwrap();
    let token_type = slot("boolean").type_ref;
    let enumerate = |quantity: u32| {
        let mut problem = invocation_problem(
            &graph,
            &slot("boolean"),
            composition::CompositionEffect::PureFunction,
        );
        problem.signatures[0].resource_inputs = vec![consuming_requirement(token_type.clone(), 2)];
        problem.initial_resources = vec![single_token_lot(token_type.clone(), quantity)];
        let prepared = composition::prepare_direct_composition(
            &graph,
            problem,
            composition::operation_checker_without_library(),
            composition::operation_meaning_of(&graph),
        )
        .unwrap();
        let state = necoherence_composition_solver::search_state::initial_state(&prepared);
        necoherence_composition_solver::enumeration::enumerate_invocations(&prepared, &state)
    };
    let shortfall = enumerate(1);
    assert!(shortfall.values.is_empty());
    assert!(shortfall.obligations.is_empty());
    assert_eq!(enumerate(2).values.len(), 1);
}

#[test]
fn enumerated_returns_pass_terminal_check() {
    let library = library();
    let graph = check_type_signatures(&library).unwrap();
    let problem = invocation_problem(
        &graph,
        &bool_contract(),
        composition::CompositionEffect::PureFunction,
    );
    let prepared = composition::prepare_direct_composition(
        &graph,
        problem,
        composition::operation_checker_without_library(),
        composition::operation_meaning_of(&graph),
    )
    .unwrap();
    let state = necoherence_composition_solver::search_state::initial_state(&prepared);
    let action =
        necoherence_composition_solver::enumeration::enumerate_invocations(&prepared, &state)
            .values
            .into_iter()
            .next()
            .expect("the invocation is enumerated");
    let children =
        necoherence_composition_solver::enumeration::action_successors(&prepared, &state, &action)
            .unwrap();
    assert_eq!(children.len(), 2);
    for (_, child) in children {
        let returns =
            necoherence_composition_solver::enumeration::enumerate_returns(&prepared, &child);
        assert_eq!(returns.values.len(), 1);
        for terminal in &returns.values {
            let models: Vec<_> = child
                .available
                .iter()
                .map(|source| {
                    (
                        source.producer.clone(),
                        SlotValue::Present(necoherence::exact_json::JsonValue::Bool(true)),
                    )
                })
                .collect();
            assert!(
                necoherence_composition_solver::verification::verify_terminal_values(
                    &prepared, &child, terminal, &models
                )
                .is_ok()
            );
        }
    }
}

#[test]
fn guard_choice_without_arms_yields_one_plan_node_and_empty_child_yields_none() {
    let library = library();
    let graph = check_type_signatures(&library).unwrap();
    let problem = invocation_problem(
        &graph,
        &bool_contract(),
        composition::CompositionEffect::PureFunction,
    );
    let prepared = composition::prepare_direct_composition(
        &graph,
        problem,
        composition::operation_checker_without_library(),
        composition::operation_meaning_of(&graph),
    )
    .unwrap();
    let state = necoherence_composition_solver::search_state::initial_state(&prepared);
    let choice = necoherence_composition_solver::enumeration::ChoiceSkeleton::Guard {
        guard: composition::GuardId("guard".into()),
        inspected: composition::ValueRef {
            producer: composition::ProducerRef::Initial(composition::InputId("input".into())),
            path: vec![],
        },
        arms: vec![],
    };
    let merged =
        necoherence_composition_solver::enumeration::merge_choice(&prepared, &state, &choice, &[]);
    assert!(merged.obligations.is_empty());
    assert_eq!(merged.values.len(), 1);
    match &merged.values[0].node {
        composition::PlanNode::Guard { arms, .. } => assert!(arms.is_empty()),
        other => panic!("the guard choice is a guard node, found {other:?}"),
    }
    let empty_child = necoherence_composition_solver::enumeration::merge_choice(
        &prepared,
        &state,
        &choice,
        &[necoherence_composition_solver::enumeration::Enumeration::default()],
    );
    assert!(empty_child.values.is_empty());
}

#[test]
fn invocation_with_only_empty_outcomes_and_no_arms_passes_the_tree_check_like_lean() {
    let library = empty_integer_library();
    let graph = check_type_signatures(&library).unwrap();
    let problem = invocation_problem(
        &graph,
        &slot("empty"),
        composition::CompositionEffect::PureFunction,
    );
    let prepared = composition::prepare_direct_composition(
        &graph,
        problem.clone(),
        composition::operation_checker_without_library(),
        composition::operation_meaning_of(&graph),
    )
    .unwrap();
    let raw = necoherence_composition_solver::verification::RawComposition {
        plan: composition::CompositionPlan {
            input_identity: problem.identity.clone(),
            input_revision: problem.revision.clone(),
            root: composition::PlanTree {
                rank: BigUint::from(0u8),
                node: composition::PlanNode::Invoke {
                    invocation: composition::InvocationPlan {
                        site: composition::SiteId("site".into()),
                        function: function_reference(),
                        bindings: vec![],
                        resources: vec![],
                    },
                    arms: vec![],
                    empty_outcomes: vec![
                        composition::OutcomeId("success".into()),
                        composition::OutcomeId("failure".into()),
                    ],
                },
            },
        },
        witness: CompositionWitness {
            input_snapshot: problem,
            initial_membership: vec![],
            resource_traces: vec![],
        },
        selection: std::sync::Arc::new(
            necoherence_composition_solver::closure::SelectionEvidence::AnyFeasible,
        ),
    };
    assert!(matches!(
        necoherence_composition_solver::verification::verify_composition(&prepared, &raw),
        Err(composition::WitnessFailure::GoalMismatch)
    ));
}

#[test]
fn product_construction_with_required_slot_fields_keeps_no_absent_branch() {
    let mut library = library();
    library.nodes.push(TypeNodeInput {
        id: "pair".into(),
        shape: Shape::Product(SignatureProduct {
            fields: ["a", "b"]
                .into_iter()
                .map(|name| SignatureField {
                    wire_name: name.into(),
                    slot: SignatureSlot {
                        type_id: "boolean".into(),
                        required: true,
                        nullable: false,
                    },
                })
                .collect(),
            extras: SignatureExtraMembers::Reject,
        }),
    });
    let graph = check_type_signatures(&library).unwrap();
    let pair = slot("pair");
    let mut problem =
        invocation_problem(&graph, &pair, composition::CompositionEffect::PureFunction);
    problem.initial_inputs = vec![composition::InitialInput {
        id: composition::InputId("flag".into()),
        contract: slot("boolean"),
        source: composition::InitialSource::Argument,
        resource: None,
    }];
    problem.invocation_domain.permitted_constructions = vec![composition::ConstructionRule {
        identity: "pair".into(),
        type_ref: pair.type_ref.clone(),
        nested_fields: Vec::new(),
        field_constraints: Vec::new(),
    }];
    problem.bounds = composition::SearchBounds {
        max_binding_candidates: BigUint::from(1u32),
        ..composition::SearchBounds::default()
    };
    let prepared = composition::prepare_direct_composition(
        &graph,
        problem,
        composition::operation_checker_without_library(),
        composition::operation_meaning_of(&graph),
    )
    .unwrap();
    let state = necoherence_composition_solver::search_state::initial_state(&prepared);
    let enumerated = necoherence_composition_solver::enumeration::enumerate_bindings(
        &prepared,
        &state,
        &pair,
        &composition::SourceConstraint::AnyCompatible,
    );
    assert!(
        enumerated.obligations.is_empty(),
        "{:?}",
        enumerated.obligations
    );
    let [composition::BindingExpr::Product { fields, .. }] = enumerated.values.as_slice() else {
        panic!("the product is enumerated once: {:?}", enumerated.values);
    };
    assert_eq!(fields.len(), 2);
}

#[test]
fn supplied_value_destination_is_judged_before_projection_check() {
    let library = empty_integer_library();
    let graph = check_type_signatures(&library).unwrap();
    let mut problem = invocation_problem(
        &graph,
        &slot("empty"),
        composition::CompositionEffect::PureFunction,
    );
    problem.initial_inputs = vec![composition::InitialInput {
        id: composition::InputId("flag".into()),
        contract: bool_contract(),
        source: composition::InitialSource::SuppliedValue(SlotValue::Present(JsonValue::Bool(
            true,
        ))),
        resource: None,
    }];
    let prepared = composition::prepare_direct_composition(
        &graph,
        problem,
        composition::operation_checker_without_library(),
        composition::operation_meaning_of(&graph),
    )
    .unwrap();
    let state = necoherence_composition_solver::search_state::initial_state(&prepared);
    let supplied = |destination: &SlotContract| {
        necoherence_composition_solver::enumeration::enumerate_bindings(
            &prepared,
            &state,
            destination,
            &composition::SourceConstraint::AnyCompatible,
        )
    };
    let supplied_root_is_bound =
        |enumeration: &necoherence_composition_solver::enumeration::Enumeration<
            composition::BindingExpr,
        >| {
            enumeration.values.iter().any(|binding| {
            matches!(
                binding,
                composition::BindingExpr::Source { value, .. }
                    if value.producer
                        == composition::ProducerRef::Initial(composition::InputId("flag".into()))
                        && value.path.is_empty()
            )
        })
        };
    let rejected = supplied(&slot("empty"));
    assert!(
        !supplied_root_is_bound(&rejected),
        "a destination rejection leaves no binding"
    );
    assert!(
        rejected.obligations.is_empty(),
        "a destination rejection is a connection failure, not an obligation: {:?}",
        rejected.obligations
    );
    assert!(supplied_root_is_bound(&supplied(&bool_contract())));
}

#[test]
fn failure_terminal_without_actual_source_reports_embedding_mismatch_like_lean() {
    let library = library();
    let graph = check_type_signatures(&library).unwrap();
    let contract = bool_contract();
    let problem = invocation_problem(
        &graph,
        &contract,
        composition::CompositionEffect::PureFunction,
    );
    let prepared = composition::prepare_direct_composition(
        &graph,
        problem,
        composition::operation_checker_without_library(),
        composition::operation_meaning_of(&graph),
    )
    .unwrap();
    let mut state = necoherence_composition_solver::search_state::initial_state(&prepared);
    state.pending_failure = Some(composition::FailureOrigin::Function {
        function: function_reference(),
        outcome: composition::OutcomeId("failure".into()),
    });
    let embedding = composition::FailureEmbeddingId("declared".into());
    let terminal = composition::ReturnPlan::Failure {
        embedding: embedding.clone(),
        value: composition::BindingExpr::Product {
            construction: "unbuilt".into(),
            type_ref: contract.type_ref.clone(),
            fields: Vec::new(),
        },
    };
    assert_eq!(
        necoherence_composition_solver::verification::verify_terminal_values(
            &prepared,
            &state,
            &terminal,
            &[]
        ),
        Err(composition::WitnessFailure::FailureEmbeddingMismatch(
            embedding
        ))
    );
}

#[test]
fn closure_branch_count_propagates_a_failing_successor() {
    let library = library();
    let graph = check_type_signatures(&library).unwrap();
    let problem = invocation_problem(
        &graph,
        &bool_contract(),
        composition::CompositionEffect::PureFunction,
    );
    let prepared = composition::prepare_direct_composition(
        &graph,
        problem,
        composition::operation_checker_without_library(),
        composition::operation_meaning_of(&graph),
    )
    .unwrap();
    let state = necoherence_composition_solver::search_state::initial_state(&prepared);
    let action =
        necoherence_composition_solver::enumeration::enumerate_invocations(&prepared, &state)
            .values
            .into_iter()
            .next()
            .expect("the invocation is enumerated");
    assert!(matches!(
        necoherence_composition_solver::enumeration::closure_branch_count(
            &prepared,
            &state,
            std::slice::from_ref(&action)
        ),
        Ok(2)
    ));
    let mut unresolved = action.clone();
    if let necoherence_composition_solver::closure::LocalAction::Invocation(plan) = &mut unresolved
    {
        plan.site = composition::SiteId("absent".into());
    }
    assert!(matches!(
        necoherence_composition_solver::enumeration::closure_branch_count(
            &prepared,
            &state,
            &[action, unresolved]
        ),
        Err(composition::WitnessFailure::SignatureMismatch(_))
    ));
}

#[allow(dead_code, unused_imports)]
#[path = "../../../../packages/rust/adapter/tests/fixtures/semantic_execution_samples.rs"]
mod samples;
