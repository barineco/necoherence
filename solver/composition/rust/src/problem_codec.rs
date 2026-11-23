// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use super::derivation_codec::*;
use necoherence::semantic_composition::*;
use necoherence::semantic_exchange::syntax;
use necoherence::semantic_types::DefinitionRef;
use necoherence::signature_composition_codec::*;
use necoherence::type_signatures::{OutcomeCause, TypeSignatureLibrary};
use necoherence::typed_mapping::BindingMode;
use serde_json::Value;

pub(crate) fn try_all<T>(values: &[T], encode: impl Fn(&T) -> Decoded<Value>) -> Decoded<Value> {
    values
        .iter()
        .map(encode)
        .collect::<Decoded<Vec<Value>>>()
        .map(Value::Array)
}

fn encode_definition_ref(value: &DefinitionRef) -> Value {
    text(&value.name)
}

fn encode_source_constraint(value: &SourceConstraint) -> Value {
    match value {
        SourceConstraint::AnyCompatible => unit_tag("AnyCompatible"),
        SourceConstraint::InitialOnly { input, path } => record_tag(
            "InitialOnly",
            vec![("input", text(&input.0)), ("path", encode_value_path(path))],
        ),
        SourceConstraint::ProducedBy {
            site,
            outcome,
            port,
            path,
        } => record_tag(
            "ProducedBy",
            vec![
                ("site", text(&site.0)),
                ("outcome", text(&outcome.0)),
                ("port", text(&port.0)),
                ("path", encode_value_path(path)),
            ],
        ),
    }
}

fn encode_resource_producer(value: &ResourceProducer) -> Value {
    match value {
        ResourceProducer::Initial { identity, revision } => record_tag(
            "Initial",
            vec![("identity", text(identity)), ("revision", text(revision))],
        ),
        ResourceProducer::InvocationOutcome { site, outcome } => record_tag(
            "InvocationOutcome",
            vec![("site", text(&site.0)), ("outcome", text(&outcome.0))],
        ),
    }
}

fn encode_resource_identity_constraint(value: &ResourceIdentityConstraint) -> Value {
    match value {
        ResourceIdentityConstraint::Any => unit_tag("Any"),
        ResourceIdentityConstraint::Exactly(producer) => {
            tuple_tag("Exactly", encode_resource_producer(producer))
        }
    }
}

fn encode_resource_lot(value: &ResourceLot) -> Value {
    object(vec![
        ("id", text(&value.id.0)),
        ("token_type", encode_type_ref(&value.token_type)),
        ("producer", encode_resource_producer(&value.producer)),
        ("revision", decimal(&value.revision)),
        ("quantity", decimal(&value.quantity)),
        ("provenance", text(&value.provenance)),
    ])
}

fn encode_binding_mode(value: &BindingMode) -> Value {
    match value {
        BindingMode::Read => unit_tag("Read"),
        BindingMode::Consume => unit_tag("Consume"),
    }
}

fn encode_resource_requirement(value: &ResourceRequirement) -> Value {
    object(vec![
        ("id", text(&value.id.0)),
        ("token_type", encode_type_ref(&value.token_type)),
        ("mode", encode_binding_mode(&value.mode)),
        ("multiplicity", decimal(&value.multiplicity)),
        ("required_revision", decimal(&value.required_revision)),
        (
            "identity",
            encode_resource_identity_constraint(&value.identity),
        ),
    ])
}

fn encode_resource_production(value: &ResourceProduction) -> Value {
    object(vec![
        ("id", text(&value.id.0)),
        ("token_type", encode_type_ref(&value.token_type)),
        ("revision", decimal(&value.revision)),
        ("quantity", decimal(&value.quantity)),
        ("provenance", text(&value.provenance)),
    ])
}

fn encode_initial_source(value: &InitialSource) -> Decoded<Value> {
    match value {
        InitialSource::Argument => Ok(unit_tag("Argument")),
        InitialSource::SuppliedValue(value) => {
            Ok(tuple_tag("SuppliedValue", encode_slot_value(value)?))
        }
    }
}

fn encode_initial_input(value: &InitialInput) -> Decoded<Value> {
    Ok(object(vec![
        ("id", text(&value.id.0)),
        ("contract", encode_slot_contract(&value.contract)),
        ("source", encode_initial_source(&value.source)?),
        ("resource", optional(&value.resource, |lot| text(&lot.0))),
    ]))
}

fn encode_input_port(value: &InputPort) -> Value {
    object(vec![
        ("id", text(&value.id.0)),
        ("contract", encode_slot_contract(&value.contract)),
        (
            "source_constraint",
            encode_source_constraint(&value.source_constraint),
        ),
        (
            "resource_requirement",
            optional(&value.resource_requirement, |id| text(&id.0)),
        ),
    ])
}

fn encode_output_port(value: &OutputPort) -> Value {
    object(vec![
        ("id", text(&value.id.0)),
        ("contract", encode_slot_contract(&value.contract)),
        (
            "resource_production",
            optional(&value.resource_production, |id| text(&id.0)),
        ),
    ])
}

fn encode_outcome_form(value: &OutcomeForm) -> Value {
    match value {
        OutcomeForm::Success => unit_tag("Success"),
        OutcomeForm::DeclaredFailure => unit_tag("DeclaredFailure"),
    }
}

fn encode_outcome_contract(value: &OutcomeContract, cause: &OutcomeCause) -> Decoded<Value> {
    Ok(object(vec![
        ("id", text(&value.id.0)),
        ("form", encode_outcome_form(&value.form)),
        ("cause", native(cause)?),
        ("value_ports", all(&value.value_ports, encode_output_port)),
        (
            "produced_resources",
            all(&value.produced_resources, encode_resource_production),
        ),
    ]))
}

fn encode_function_form(value: &FunctionForm) -> Value {
    match value {
        FunctionForm::Pure => unit_tag("Pure"),
        FunctionForm::DeclaredTransform => unit_tag("DeclaredTransform"),
        FunctionForm::Operation(reference) => {
            tuple_tag("Operation", encode_definition_ref(reference))
        }
    }
}

fn encode_composition_effect(value: &CompositionEffect) -> Value {
    match value {
        CompositionEffect::PureFunction => unit_tag("PureFunction"),
        CompositionEffect::HttpRequestResponse => unit_tag("HttpRequestResponse"),
        CompositionEffect::DataOnly => unit_tag("DataOnly"),
    }
}

fn encode_failure_origin(value: &FailureOrigin) -> Value {
    match value {
        FailureOrigin::Function { function, outcome } => record_tag(
            "Function",
            vec![
                ("function", encode_function_ref(function)),
                ("outcome", text(&outcome.0)),
            ],
        ),
        FailureOrigin::Guard { guard, arm } => record_tag(
            "Guard",
            vec![("guard", text(&guard.0)), ("arm", encode_guard_arm(arm))],
        ),
    }
}

fn encode_function_signature(
    value: &FunctionSignature,
    causes: &[(FunctionRef, Vec<(OutcomeId, OutcomeCause)>)],
) -> Decoded<Value> {
    let declared = causes
        .iter()
        .find(|(reference, _)| *reference == value.reference)
        .map(|(_, outcomes)| outcomes)
        .ok_or_else(|| syntax("$.signature.reference", "outcome causes"))?;
    let outcomes = value
        .outcomes
        .iter()
        .map(|outcome| {
            let (_, cause) = declared
                .iter()
                .find(|(id, _)| id.0 == outcome.id.0)
                .ok_or_else(|| syntax("$.signature.outcome.cause", "outcome cause"))?;
            encode_outcome_contract(outcome, cause)
        })
        .collect::<Decoded<Vec<Value>>>()?;
    Ok(object(vec![
        ("reference", encode_function_ref(&value.reference)),
        ("form", encode_function_form(&value.form)),
        ("effect", encode_composition_effect(&value.effect)),
        ("inputs", all(&value.inputs, encode_input_port)),
        ("outcomes", Value::Array(outcomes)),
        (
            "resource_inputs",
            all(&value.resource_inputs, encode_resource_requirement),
        ),
        ("assumption_ref", text(&value.assumption_ref)),
        (
            "handles_failure",
            optional(&value.handles_failure, encode_failure_origin),
        ),
    ]))
}

fn encode_invocation_site(value: &InvocationSite) -> Value {
    object(vec![
        ("id", text(&value.id.0)),
        ("function", encode_function_ref(&value.function)),
    ])
}

fn encode_permitted_projection(value: &PermittedProjection) -> Value {
    object(vec![
        ("source_type", encode_type_ref(&value.source_type)),
        ("path", encode_value_path(&value.path)),
    ])
}

fn encode_guard_kind(value: &GuardKind) -> Value {
    match value {
        GuardKind::Presence => unit_tag("Presence"),
        GuardKind::Variants => unit_tag("Variants"),
        GuardKind::Validate(contract) => tuple_tag("Validate", encode_slot_contract(contract)),
    }
}

fn encode_declared_guard(value: &DeclaredGuard) -> Value {
    object(vec![
        ("id", text(&value.id.0)),
        ("source_type", encode_type_ref(&value.source_type)),
        ("path", encode_value_path(&value.path)),
        ("kind", encode_guard_kind(&value.kind)),
    ])
}

fn encode_field_presence(value: &FieldPresence) -> Value {
    match value {
        FieldPresence::Required => unit_tag("Required"),
        FieldPresence::Optional => unit_tag("Optional"),
    }
}

fn encode_field_constraint(value: &FieldConstraint) -> Value {
    object(vec![
        ("field", text(&value.field)),
        ("source", encode_source_constraint(&value.source)),
        ("presence", encode_field_presence(&value.presence)),
    ])
}

fn encode_construction_rule(value: &ConstructionRule) -> Value {
    object(vec![
        ("identity", text(&value.identity)),
        ("type_id", encode_type_ref(&value.type_ref)),
        (
            "nested_fields",
            all(&value.nested_fields, |(field, source)| {
                Value::Array(vec![text(field), text(source)])
            }),
        ),
        (
            "field_constraints",
            all(&value.field_constraints, encode_field_constraint),
        ),
    ])
}

fn encode_invocation_domain(value: &InvocationDomain) -> Value {
    object(vec![
        ("identity", text(&value.identity)),
        ("revision", text(&value.revision)),
        ("sites", all(&value.sites, encode_invocation_site)),
        (
            "permitted_projections",
            all(&value.permitted_projections, encode_permitted_projection),
        ),
        (
            "permitted_constructions",
            all(&value.permitted_constructions, encode_construction_rule),
        ),
        (
            "permitted_transforms",
            all(&value.permitted_transforms, encode_function_ref),
        ),
        ("guards", all(&value.guards, encode_declared_guard)),
    ])
}

fn encode_resource_goal(value: &ResourceGoal) -> Value {
    object(vec![
        ("lot", encode_resource_lot_ref(&value.lot)),
        ("multiplicity", decimal(&value.multiplicity)),
        ("revision", decimal(&value.revision)),
    ])
}

fn encode_goal_port(value: &GoalPort) -> Value {
    object(vec![
        ("id", text(&value.id.0)),
        ("contract", encode_slot_contract(&value.contract)),
        (
            "source_constraint",
            encode_source_constraint(&value.source_constraint),
        ),
    ])
}

fn encode_failure_embedding(value: &FailureEmbedding) -> Value {
    object(vec![
        ("id", text(&value.id.0)),
        ("origin", encode_failure_origin(&value.origin)),
        ("contract", encode_slot_contract(&value.contract)),
        (
            "final_resources",
            all(&value.final_resources, encode_resource_goal),
        ),
    ])
}

fn encode_goal_spec(value: &GoalSpec) -> Value {
    object(vec![
        ("outputs", all(&value.outputs, encode_goal_port)),
        ("failures", all(&value.failures, encode_failure_embedding)),
        (
            "final_resources",
            all(&value.final_resources, encode_resource_goal),
        ),
    ])
}

fn encode_selection_policy(value: &SelectionPolicy) -> Value {
    match value {
        SelectionPolicy::RequireUnique => unit_tag("RequireUnique"),
        SelectionPolicy::AnyFeasible => unit_tag("AnyFeasible"),
    }
}

fn encode_resource_bounds(value: &ResourceBounds) -> Value {
    object(vec![
        ("max_bindings", decimal(&value.max_bindings)),
        ("max_search_steps", decimal(&value.max_search_steps)),
        ("max_tokens", decimal(&value.max_tokens)),
    ])
}

fn encode_search_bounds(value: &SearchBounds) -> Value {
    object(vec![
        ("max_expanded_states", decimal(&value.max_expanded_states)),
        (
            "max_binding_candidates",
            decimal(&value.max_binding_candidates),
        ),
        ("max_type_obligations", decimal(&value.max_type_obligations)),
        ("max_branch_nodes", decimal(&value.max_branch_nodes)),
        (
            "resource_bounds",
            optional(&value.resource_bounds, encode_resource_bounds),
        ),
        ("max_sample_length", decimal(&value.max_sample_length)),
    ])
}

pub(crate) fn encode_problem(
    library: &TypeSignatureLibrary,
    problem: &CompositionInput,
    causes: &[(FunctionRef, Vec<(OutcomeId, OutcomeCause)>)],
) -> Decoded<Value> {
    Ok(object(vec![
        ("identity", text(&problem.identity)),
        ("revision", text(&problem.revision)),
        ("basis", wire_basis(library)?),
        (
            "signatures",
            try_all(&problem.signatures, |signature| {
                encode_function_signature(signature, causes)
            })?,
        ),
        (
            "initial_inputs",
            try_all(&problem.initial_inputs, encode_initial_input)?,
        ),
        (
            "initial_resources",
            all(&problem.initial_resources, encode_resource_lot),
        ),
        ("goal", encode_goal_spec(&problem.goal)),
        (
            "invocation_domain",
            encode_invocation_domain(&problem.invocation_domain),
        ),
        (
            "allowed_effects",
            all(&problem.allowed_effects, encode_composition_effect),
        ),
        (
            "explicit_order",
            all(&problem.explicit_order, |(left, right)| {
                Value::Array(vec![text(&left.0), text(&right.0)])
            }),
        ),
        (
            "selection_policy",
            optional(&problem.selection_policy, encode_selection_policy),
        ),
        ("bounds", encode_search_bounds(&problem.bounds)),
    ]))
}

pub(crate) fn wire_basis(library: &TypeSignatureLibrary) -> Decoded<Value> {
    native(&library_basis(library)?)
}
