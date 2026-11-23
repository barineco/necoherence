// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

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

#[allow(dead_code, unused_imports)]
#[path = "fixtures/semantic_execution_samples.rs"]
mod samples;
#[allow(unused_imports)]
use samples::*;

fn product_library() -> TypeSignatureLibrary {
    let mut library = library();
    library.nodes.push(TypeNodeInput {
        id: "pair".into(),
        shape: Shape::Product(SignatureProduct {
            fields: vec![SignatureField {
                wire_name: "value".into(),
                slot: SignatureSlot {
                    type_id: "boolean".into(),
                    required: true,
                    nullable: false,
                },
            }],
            extras: SignatureExtraMembers::Reject,
        }),
    });
    library
}

fn rejection(
    graph: &SemanticGraph,
    problem: composition::CompositionInput,
) -> composition::CompositionInputFailure {
    composition::prepare_direct_composition(
        graph,
        problem,
        composition::operation_checker_without_library(),
        composition::operation_meaning_of(graph),
    )
    .err()
    .expect("the composition input is rejected")
}

fn rule(identity: &str, type_ref: &TypeRef) -> composition::ConstructionRule {
    composition::ConstructionRule {
        identity: identity.into(),
        type_ref: type_ref.clone(),
        nested_fields: vec![],
        field_constraints: vec![],
    }
}

fn absent_site_source() -> composition::SourceConstraint {
    composition::SourceConstraint::ProducedBy {
        site: composition::SiteId("absent".into()),
        outcome: composition::OutcomeId("success".into()),
        port: composition::PortId("value".into()),
        path: vec![],
    }
}

#[test]
fn empty_goal_is_reported_as_the_empty_goal_failure() {
    let library = library();
    let graph = check_type_signatures(&library).unwrap();
    let mut problem = invocation_problem(
        &graph,
        &bool_contract(),
        composition::CompositionEffect::PureFunction,
    );
    problem.goal.outputs.clear();
    assert_eq!(
        rejection(&graph, problem),
        composition::CompositionInputFailure::EmptyGoal
    );
}

#[test]
fn site_effect_outside_allowed_effects_names_the_site_and_effect() {
    let library = library();
    let graph = check_type_signatures(&library).unwrap();
    let mut problem = invocation_problem(
        &graph,
        &bool_contract(),
        composition::CompositionEffect::DataOnly,
    );
    problem.allowed_effects = vec![composition::CompositionEffect::PureFunction];
    assert_eq!(
        rejection(&graph, problem),
        composition::CompositionInputFailure::SiteEffectNotPermitted {
            site: composition::SiteId("site".into()),
            effect: composition::CompositionEffect::DataOnly,
        }
    );
}

#[test]
fn transform_outside_permitted_transforms_names_the_function() {
    let library = library();
    let graph = check_type_signatures(&library).unwrap();
    let mut problem = invocation_problem(
        &graph,
        &bool_contract(),
        composition::CompositionEffect::PureFunction,
    );
    problem.signatures[0].form = composition::FunctionForm::DeclaredTransform;
    assert_eq!(
        rejection(&graph, problem),
        composition::CompositionInputFailure::TransformNotPermitted(function_reference())
    );
}

#[test]
fn undefined_goal_source_names_the_goal_port_and_constraint() {
    let library = library();
    let graph = check_type_signatures(&library).unwrap();
    let mut problem = invocation_problem(
        &graph,
        &bool_contract(),
        composition::CompositionEffect::PureFunction,
    );
    let constraint = absent_site_source();
    problem.goal.outputs[0].source_constraint = constraint.clone();
    assert_eq!(
        rejection(&graph, problem),
        composition::CompositionInputFailure::GoalSourceConstraintUndefined {
            port: composition::GoalPortId("result".into()),
            constraint,
        }
    );
}

#[test]
fn undefined_failure_origin_names_the_embedding_and_origin() {
    let library = library();
    let graph = check_type_signatures(&library).unwrap();
    let mut problem = invocation_problem(
        &graph,
        &bool_contract(),
        composition::CompositionEffect::PureFunction,
    );
    let origin = composition::FailureOrigin::Function {
        function: function_reference(),
        outcome: composition::OutcomeId("absent".into()),
    };
    problem.goal.failures[0].origin = origin.clone();
    assert_eq!(
        rejection(&graph, problem),
        composition::CompositionInputFailure::FailureEmbeddingOriginUndefined {
            embedding: composition::FailureEmbeddingId("declared".into()),
            origin,
        }
    );
}

#[test]
fn construction_on_a_non_product_names_the_rule_and_type() {
    let library = product_library();
    let graph = check_type_signatures(&library).unwrap();
    let boolean = bool_contract().type_ref;
    let mut problem = invocation_problem(
        &graph,
        &bool_contract(),
        composition::CompositionEffect::PureFunction,
    );
    problem.invocation_domain.permitted_constructions = vec![rule("boolean-rule", &boolean)];
    assert_eq!(
        rejection(&graph, problem),
        composition::CompositionInputFailure::ConstructionNotProduct {
            identity: "boolean-rule".into(),
            type_ref: boolean,
        }
    );
}

#[test]
fn field_constraint_on_an_unknown_field_names_the_construction_and_field() {
    let library = product_library();
    let graph = check_type_signatures(&library).unwrap();
    let pair = signature_type_ref("pair");
    let mut problem = invocation_problem(
        &graph,
        &bool_contract(),
        composition::CompositionEffect::PureFunction,
    );
    let mut pair_rule = rule("pair-rule", &pair);
    pair_rule.field_constraints = vec![composition::FieldConstraint {
        field: "absent".into(),
        source: composition::SourceConstraint::AnyCompatible,
        presence: composition::FieldPresence::Required,
    }];
    problem.invocation_domain.permitted_constructions = vec![pair_rule];
    assert_eq!(
        rejection(&graph, problem),
        composition::CompositionInputFailure::FieldConstraintUnknownField {
            identity: "pair-rule".into(),
            field: "absent".into(),
        }
    );
}

#[test]
fn field_constraint_on_a_nested_field_is_rejected_by_name() {
    let library = product_library();
    let graph = check_type_signatures(&library).unwrap();
    let pair = signature_type_ref("pair");
    let boolean = bool_contract().type_ref;
    let mut problem = invocation_problem(
        &graph,
        &bool_contract(),
        composition::CompositionEffect::PureFunction,
    );
    let mut pair_rule = rule("pair-rule", &pair);
    pair_rule.nested_fields = vec![("value".into(), "boolean-rule".into())];
    pair_rule.field_constraints = vec![composition::FieldConstraint {
        field: "value".into(),
        source: composition::SourceConstraint::AnyCompatible,
        presence: composition::FieldPresence::Required,
    }];
    problem.invocation_domain.permitted_constructions =
        vec![pair_rule, rule("boolean-rule", &boolean)];
    assert_eq!(
        rejection(&graph, problem),
        composition::CompositionInputFailure::ConstrainedNestedField {
            identity: "pair-rule".into(),
            field: "value".into(),
        }
    );
}

#[test]
fn field_constraint_with_an_undefined_source_names_the_construction_and_constraint() {
    let library = product_library();
    let graph = check_type_signatures(&library).unwrap();
    let pair = signature_type_ref("pair");
    let mut problem = invocation_problem(
        &graph,
        &bool_contract(),
        composition::CompositionEffect::PureFunction,
    );
    let constraint = composition::FieldConstraint {
        field: "value".into(),
        source: absent_site_source(),
        presence: composition::FieldPresence::Required,
    };
    let mut pair_rule = rule("pair-rule", &pair);
    pair_rule.field_constraints = vec![constraint.clone()];
    problem.invocation_domain.permitted_constructions = vec![pair_rule];
    assert_eq!(
        rejection(&graph, problem),
        composition::CompositionInputFailure::ConstructionFieldSourceUndefined {
            identity: "pair-rule".into(),
            constraint,
        }
    );
}

#[test]
fn nested_field_not_declared_by_the_product_names_the_construction_and_field() {
    let library = product_library();
    let graph = check_type_signatures(&library).unwrap();
    let pair = signature_type_ref("pair");
    let mut problem = invocation_problem(
        &graph,
        &bool_contract(),
        composition::CompositionEffect::PureFunction,
    );
    let mut pair_rule = rule("pair-rule", &pair);
    pair_rule.nested_fields = vec![("absent".into(), "pair-rule".into())];
    problem.invocation_domain.permitted_constructions = vec![pair_rule];
    assert_eq!(
        rejection(&graph, problem),
        composition::CompositionInputFailure::NestedFieldUndeclared {
            identity: "pair-rule".into(),
            field: "absent".into(),
        }
    );
}

#[test]
fn nested_rule_missing_for_the_field_names_the_rule_field_and_field_type() {
    let library = product_library();
    let graph = check_type_signatures(&library).unwrap();
    let pair = signature_type_ref("pair");
    let boolean = bool_contract().type_ref;
    let mut problem = invocation_problem(
        &graph,
        &bool_contract(),
        composition::CompositionEffect::PureFunction,
    );
    let mut pair_rule = rule("pair-rule", &pair);
    pair_rule.nested_fields = vec![("value".into(), "absent-rule".into())];
    problem.invocation_domain.permitted_constructions = vec![pair_rule];
    assert_eq!(
        rejection(&graph, problem),
        composition::CompositionInputFailure::NestedConstructionMismatch {
            identity: "pair-rule".into(),
            field: "value".into(),
            nested: "absent-rule".into(),
            type_ref: boolean,
        }
    );
}

#[test]
fn mutually_nested_construction_rules_name_the_first_cyclic_identity() {
    let mut library = library();
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
    let graph = check_type_signatures(&library).unwrap();
    let left = signature_type_ref("left");
    let right = signature_type_ref("right");
    let nested = |identity: &str, type_ref: &TypeRef, target: &str| composition::ConstructionRule {
        identity: identity.into(),
        type_ref: type_ref.clone(),
        nested_fields: vec![("next".into(), target.into())],
        field_constraints: vec![],
    };
    let mut problem = invocation_problem(
        &graph,
        &bool_contract(),
        composition::CompositionEffect::PureFunction,
    );
    problem.invocation_domain.permitted_constructions = vec![
        nested("left-rule", &left, "right-rule"),
        nested("right-rule", &right, "left-rule"),
    ];
    assert_eq!(
        rejection(&graph, problem),
        composition::CompositionInputFailure::CyclicConstruction {
            identity: "left-rule".into(),
        }
    );
}

#[test]
fn explicit_order_with_an_unknown_site_names_both_sites() {
    let library = library();
    let graph = check_type_signatures(&library).unwrap();
    let mut problem = invocation_problem(
        &graph,
        &bool_contract(),
        composition::CompositionEffect::PureFunction,
    );
    problem.explicit_order = vec![(
        composition::SiteId("site".into()),
        composition::SiteId("absent".into()),
    )];
    assert_eq!(
        rejection(&graph, problem),
        composition::CompositionInputFailure::ExplicitSiteOrderInvalid {
            before: composition::SiteId("site".into()),
            after: composition::SiteId("absent".into()),
        }
    );
}
