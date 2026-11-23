// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use super::closure::*;
use super::lowering::*;
use super::search_state::*;
use super::verification::*;
use necoherence::core::Nat;
use necoherence::semantic_composition::*;
use necoherence::semantic_types::*;
use necoherence::semantic_validation::{self as validation};
use necoherence::typed_mapping as resource;
use num_bigint::BigUint;
use std::sync::Arc;

#[derive(Debug, Clone, PartialEq)]
pub enum ChoiceSkeleton {
    Invoke {
        invocation: InvocationPlan,
        outcomes: Vec<OutcomeId>,
        empty_outcomes: Vec<OutcomeId>,
    },
    Guard {
        guard: GuardId,
        inspected: ValueRef,
        arms: Vec<GuardArm>,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Enumeration<T> {
    pub values: Vec<T>,
    pub obligations: Vec<UnresolvedObligation>,
    pub cost: usize,
}

impl<T> Default for Enumeration<T> {
    fn default() -> Self {
        Self {
            values: Vec::new(),
            obligations: Vec::new(),
            cost: 0,
        }
    }
}

fn capped<T>(limit: usize, mut values: Vec<T>, reason: UnresolvedObligation) -> Enumeration<T> {
    let cost = values.len();
    let obligations = if limit < values.len() {
        vec![reason]
    } else {
        Vec::new()
    };
    values.truncate(limit);
    Enumeration {
        values,
        obligations,
        cost,
    }
}

fn binding_failure_obligations(failure: &WitnessFailure) -> Vec<UnresolvedObligation> {
    match failure {
        WitnessFailure::Inclusion(InclusionFailure::UndefinedMeaning(reasons)) => {
            vec![UnresolvedObligation::Meaning(reasons.clone())]
        }
        WitnessFailure::Inclusion(InclusionFailure::Unresolved(obligation)) => {
            vec![UnresolvedObligation::Type {
                value: None,
                obligations: vec![obligation.clone()],
            }]
        }
        WitnessFailure::ProjectionMismatch(ProjectionFailure::Unresolved(reasons)) => {
            vec![UnresolvedObligation::Meaning(reasons.clone())]
        }
        WitnessFailure::MissingEvidence(_) => vec![UnresolvedObligation::BranchBoundExhausted],
        _ => Vec::new(),
    }
}

pub fn candidate_values(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    constraint: &SourceConstraint,
) -> Vec<ValueRef> {
    let input = prepared.input();
    let mut values = Vec::new();
    for source in &state.available {
        let mut paths = vec![Vec::new()];
        paths.extend(
            input
                .invocation_domain
                .permitted_projections
                .iter()
                .filter(|projection| projection.source_type == source.contract.type_ref)
                .map(|projection| projection.path.clone()),
        );
        paths.extend(
            state
                .facts
                .iter()
                .filter(|fact| fact.inspected.producer == source.producer)
                .map(|fact| fact.inspected.path.clone()),
        );
        for path in distinct(paths) {
            let value = ValueRef {
                producer: source.producer.clone(),
                path,
            };
            if constraint.accepts(&value.producer, &value.path) {
                values.push(value);
            }
        }
    }
    values
}

fn enumerate_bindings_fuel(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    fuel: usize,
    destination: &SlotContract,
    constraint: &SourceConstraint,
) -> Enumeration<BindingExpr> {
    if fuel == 0 {
        return Enumeration {
            values: Vec::new(),
            obligations: vec![UnresolvedObligation::BranchBoundExhausted],
            cost: 0,
        };
    }
    let input = prepared.input();
    let max = input.bounds.binding_candidate_limit();
    let mut result = Enumeration::default();
    let mut validator = prepared.validator();
    for value in candidate_values(prepared, state, constraint) {
        result.cost += 1;
        let projection = match effective_projection(prepared, state, &value) {
            Ok(projection) => projection,
            Err(failure) => {
                result
                    .obligations
                    .extend(binding_failure_obligations(&failure));
                continue;
            }
        };
        let binding = if let Some(supplied) = exact_value(prepared, state, &value) {
            match prepared
                .validator()
                .accepts_slot(destination, borrowed_slot(&supplied))
            {
                ValueDecision::Accepted => Some(BindingExpr::Source {
                    value: value.clone(),
                    projection,
                    compatibility: BindingCompatibility::SuppliedValue { value: supplied },
                }),
                ValueDecision::Rejected(_) => None,
                ValueDecision::Unresolved(reasons) => {
                    result
                        .obligations
                        .push(UnresolvedObligation::Meaning(reasons));
                    None
                }
            }
        } else {
            match check_assignable_with_empty(
                &mut validator,
                prepared.empty_refs(),
                &projection.destination,
                destination,
                &input.bounds,
            ) {
                CompatibilityDecision::Compatible(checked) => Some(BindingExpr::Source {
                    value: value.clone(),
                    projection,
                    compatibility: BindingCompatibility::Inclusion(Arc::new(checked)),
                }),
                CompatibilityDecision::Incompatible(_) => None,
                CompatibilityDecision::Unknown(obligations) => {
                    result.obligations.push(UnresolvedObligation::Type {
                        value: Some(value.clone()),
                        obligations,
                    });
                    None
                }
            }
        };
        if let Some(binding) = binding {
            match check_binding(prepared, state, &binding, destination, constraint) {
                Ok(()) => result.values.push(binding),
                Err(failure) => result
                    .obligations
                    .extend(binding_failure_obligations(&failure)),
            }
        }
    }
    if matches!(constraint, SourceConstraint::AnyCompatible) {
        for rule in input
            .invocation_domain
            .permitted_constructions
            .iter()
            .filter(|rule| rule.type_ref == destination.type_ref)
        {
            let Some(TypeShape::Product(product)) =
                resolved_shape(prepared.graph(), &rule.type_ref)
            else {
                continue;
            };
            let mut products: Vec<Vec<(String, BindingExpr)>> = vec![Vec::new()];
            for field in &product.fields {
                let required = field.slot.required || rule.field_required(&field.wire_name);
                let child_constraint = rule.field_constraint(&field.wire_name);
                let choices = enumerate_bindings_fuel(
                    prepared,
                    state,
                    fuel - 1,
                    &field.slot,
                    child_constraint,
                );
                result.obligations.extend(choices.obligations);
                result.cost += choices.cost;
                let allowed: Vec<&BindingExpr> = choices
                    .values
                    .iter()
                    .filter(|choice| match choice {
                        BindingExpr::Source { .. } => true,
                        BindingExpr::Product { construction, .. } => rule
                            .nested_fields
                            .iter()
                            .any(|(name, child)| name == &field.wire_name && child == construction),
                    })
                    .take(max + 1)
                    .collect();
                let mut extended = if required {
                    Vec::new()
                } else {
                    products.clone()
                };
                for fields in &products {
                    for binding in &allowed {
                        let mut fields = fields.clone();
                        fields.push((field.wire_name.clone(), (*binding).clone()));
                        extended.push(fields);
                    }
                }
                if max < extended.len() {
                    result
                        .obligations
                        .push(UnresolvedObligation::BindingBoundExhausted);
                }
                products = extended.into_iter().take(max).collect();
                if products.is_empty() {
                    break;
                }
            }
            for fields in products {
                let binding = BindingExpr::Product {
                    construction: rule.identity.clone(),
                    type_ref: rule.type_ref.clone(),
                    fields,
                };
                match check_binding(prepared, state, &binding, destination, constraint) {
                    Ok(()) => result.values.push(binding),
                    Err(failure) => result
                        .obligations
                        .extend(binding_failure_obligations(&failure)),
                }
            }
        }
    }
    let limited = capped(
        max,
        result.values,
        UnresolvedObligation::BindingBoundExhausted,
    );
    result.values = limited.values;
    result.obligations.extend(limited.obligations);
    result
}

pub fn enumerate_bindings(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    destination: &SlotContract,
    constraint: &SourceConstraint,
) -> Enumeration<BindingExpr> {
    enumerate_bindings_fuel(
        prepared,
        state,
        prepared
            .input()
            .invocation_domain
            .permitted_constructions
            .len()
            + 2,
        destination,
        constraint,
    )
}

fn enumerate_resources(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    requirement: &ResourceRequirement,
) -> Enumeration<ResourceBinding> {
    let input = prepared.input();
    let mut result = Enumeration::default();
    for lot_ref in state_lots(input, state) {
        let Some(declaration) = declared_lot(input, &lot_ref) else {
            continue;
        };
        if declaration.revision != requirement.required_revision
            || !matches!(&requirement.identity, ResourceIdentityConstraint::Any)
                && requirement.identity
                    != ResourceIdentityConstraint::Exactly(declaration.producer.clone())
        {
            continue;
        }
        result.cost += 1;
        let source = present_contract(declaration.token_type.clone());
        let destination = present_contract(requirement.token_type.clone());
        match check_assignable_with_empty(
            &mut prepared.validator(),
            prepared.empty_refs(),
            &source,
            &destination,
            &input.bounds,
        ) {
            CompatibilityDecision::Compatible(checked) => result.values.push(ResourceBinding {
                requirement: requirement.id.clone(),
                lot: lot_ref,
                inclusion: Arc::new(checked),
            }),
            CompatibilityDecision::Incompatible(_) => {}
            CompatibilityDecision::Unknown(obligations) => {
                result.obligations.push(UnresolvedObligation::Type {
                    value: None,
                    obligations,
                })
            }
        }
    }
    result
}

fn prefix_resources(
    prepared: &PreparedCompositionInput<'_>,
    steps: Vec<TraceStep>,
) -> Result<bool, LoweringFailure> {
    let trace = BranchTrace {
        steps,
        terminal: ReturnPlan::Success(Vec::new()),
    };
    let (lowered, correspondence) = lower_resource_trace_core(prepared, &trace, false)?;
    if lowered.bound.max_bindings < resource::candidate_binding_count(&lowered) {
        return Err(LoweringFailure::Unknown(
            UnresolvedObligation::ResourceSolverUnknown(
                resource::UnknownReason::BindingBoundExhausted(lowered.bound.max_bindings.clone()),
            ),
        ));
    }
    if lowered.bound.max_search_steps < Nat::from(correspondence.execution_order.len()) {
        return Err(LoweringFailure::Unknown(
            UnresolvedObligation::ResourceSolverUnknown(
                resource::UnknownReason::SearchStepBoundExhausted(
                    lowered.bound.max_search_steps.clone(),
                ),
            ),
        ));
    }
    Ok(
        resource::path_replay(&lowered, &lowered.marking, &correspondence.execution_order)
            .is_some(),
    )
}

pub fn admissible_sites<'p>(
    prepared: &'p PreparedCompositionInput<'_>,
    state: &SearchState,
) -> Vec<(&'p InvocationSite, &'p FunctionSignature)> {
    let input = prepared.input();
    input
        .invocation_domain
        .sites
        .iter()
        .filter_map(|site| {
            if state.used_sites.contains(&site.id) {
                return None;
            }
            let function = site_signature(input, &site.id)?;
            if function
                .outcomes
                .iter()
                .all(|outcome| outcome_empty(prepared, outcome))
                || function.handles_failure != state.pending_failure
                || !input
                    .explicit_order
                    .iter()
                    .all(|(before, after)| after != &site.id || state.used_sites.contains(before))
            {
                return None;
            }
            Some((site, function))
        })
        .collect()
}

pub fn enumerate_invocations(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
) -> Enumeration<LocalAction> {
    let input = prepared.input();
    let max = input.bounds.binding_candidate_limit();
    let mut result = Enumeration::default();
    for (site, function) in admissible_sites(prepared, state) {
        let mut inputs: Vec<Vec<(PortId, BindingExpr)>> = vec![Vec::new()];
        for port in &function.inputs {
            let choices =
                enumerate_bindings(prepared, state, &port.contract, &port.source_constraint);
            result.obligations.extend(choices.obligations);
            result.cost += choices.cost;
            let mut extended = Vec::new();
            for selected in &inputs {
                for binding in &choices.values {
                    let mut selected = selected.clone();
                    selected.push((port.id.clone(), binding.clone()));
                    extended.push(selected);
                }
            }
            if max < extended.len() {
                result
                    .obligations
                    .push(UnresolvedObligation::BindingBoundExhausted);
            }
            inputs = extended.into_iter().take(max).collect();
        }
        let mut resources: Vec<Vec<ResourceBinding>> = vec![Vec::new()];
        for requirement in &function.resource_inputs {
            let choices = enumerate_resources(prepared, state, requirement);
            result.obligations.extend(choices.obligations);
            result.cost += choices.cost;
            let mut extended = Vec::new();
            for selected in &resources {
                for binding in &choices.values {
                    let mut selected = selected.clone();
                    selected.push(binding.clone());
                    extended.push(selected);
                }
            }
            if max < extended.len() {
                result
                    .obligations
                    .push(UnresolvedObligation::BindingBoundExhausted);
            }
            resources = extended.into_iter().take(max).collect();
        }
        for bindings in &inputs {
            for selected_resources in &resources {
                let invocation = InvocationPlan {
                    site: site.id.clone(),
                    function: function.reference.clone(),
                    bindings: bindings.clone(),
                    resources: selected_resources.clone(),
                };
                match check_invocation(prepared, state, &invocation) {
                    Err(failure) => result
                        .obligations
                        .extend(binding_failure_obligations(&failure)),
                    Ok(()) => {
                        let mut possible = true;
                        for outcome in function
                            .outcomes
                            .iter()
                            .filter(|outcome| !outcome_empty(prepared, outcome))
                        {
                            let mut steps = state.trace.clone();
                            steps.push(TraceStep::Invocation {
                                invocation: invocation.clone(),
                                outcome: outcome.id.clone(),
                            });
                            match prefix_resources(prepared, steps) {
                                Ok(true) => {}
                                Ok(false) | Err(LoweringFailure::Invalid(_)) => possible = false,
                                Err(LoweringFailure::Unknown(obligation)) => {
                                    possible = false;
                                    result.obligations.push(obligation);
                                }
                            }
                        }
                        if possible {
                            result.values.push(LocalAction::Invocation(invocation));
                        }
                    }
                }
            }
        }
    }
    result
}

pub fn enumerate_guards(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
) -> Enumeration<LocalAction> {
    let input = prepared.input();
    let mut result = Enumeration::default();
    for guard in &input.invocation_domain.guards {
        if state.used_guards.contains(&guard.id) {
            continue;
        }
        for source in &state.available {
            if source.contract.type_ref == guard.source_type {
                let inspected = ValueRef {
                    producer: source.producer.clone(),
                    path: guard.path.clone(),
                };
                match guard_arms(prepared, state, guard, &inspected) {
                    Ok(_) => {
                        result.values.push(LocalAction::Guard {
                            guard: guard.id.clone(),
                            inspected,
                        });
                        result.cost += 1;
                    }
                    Err(failure) => result
                        .obligations
                        .extend(binding_failure_obligations(&failure)),
                }
            }
        }
    }
    result
}

pub fn enumerate_returns(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
) -> Enumeration<ReturnPlan> {
    let input = prepared.input();
    let max = input.bounds.binding_candidate_limit();
    let mut result = Enumeration::default();
    match &state.pending_failure {
        None => {
            let mut outputs: Vec<Vec<(GoalPortId, BindingExpr)>> = vec![Vec::new()];
            for goal in &input.goal.outputs {
                let choices =
                    enumerate_bindings(prepared, state, &goal.contract, &goal.source_constraint);
                result.obligations.extend(choices.obligations);
                result.cost += choices.cost;
                let mut extended = Vec::new();
                for selected in &outputs {
                    for binding in &choices.values {
                        let mut selected = selected.clone();
                        selected.push((goal.id.clone(), binding.clone()));
                        extended.push(selected);
                    }
                }
                if max < extended.len() {
                    result
                        .obligations
                        .push(UnresolvedObligation::BindingBoundExhausted);
                }
                outputs = extended.into_iter().take(max).collect();
            }
            for selected in outputs {
                push_checked_return(prepared, state, ReturnPlan::Success(selected), &mut result);
            }
        }
        Some(origin) => {
            for embedding in input
                .goal
                .failures
                .iter()
                .filter(|embedding| &embedding.origin == origin)
            {
                let choices = enumerate_bindings(
                    prepared,
                    state,
                    &embedding.contract,
                    &SourceConstraint::AnyCompatible,
                );
                result.obligations.extend(choices.obligations);
                result.cost += choices.cost;
                for binding in choices.values {
                    push_checked_return(
                        prepared,
                        state,
                        ReturnPlan::Failure {
                            embedding: embedding.id.clone(),
                            value: binding,
                        },
                        &mut result,
                    );
                }
            }
        }
    }
    result
}

fn push_checked_return(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    terminal: ReturnPlan,
    result: &mut Enumeration<ReturnPlan>,
) {
    match check_return(prepared, state, &terminal) {
        Ok(_) => result.values.push(terminal),
        Err(failure) => result
            .obligations
            .extend(binding_failure_obligations(&failure)),
    }
}

pub fn local_action_choice(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    action: &LocalAction,
) -> Result<ChoiceSkeleton, WitnessFailure> {
    let successors = action_successors(prepared, state, action)?;
    choice_skeleton(prepared, action, &successors)
}

fn choice_skeleton(
    prepared: &PreparedCompositionInput<'_>,
    action: &LocalAction,
    successors: &[(TraceStep, SearchState)],
) -> Result<ChoiceSkeleton, WitnessFailure> {
    match action {
        LocalAction::Invocation(invocation) => {
            let function = site_signature(prepared.input(), &invocation.site)
                .ok_or_else(|| WitnessFailure::SignatureMismatch(invocation.site.clone()))?;
            Ok(ChoiceSkeleton::Invoke {
                invocation: invocation.clone(),
                outcomes: successors
                    .iter()
                    .filter_map(|(step, _)| match step {
                        TraceStep::Invocation { outcome, .. } => Some(outcome.clone()),
                        _ => None,
                    })
                    .collect(),
                empty_outcomes: function
                    .outcomes
                    .iter()
                    .filter(|outcome| outcome_empty(prepared, outcome))
                    .map(|outcome| outcome.id.clone())
                    .collect(),
            })
        }
        LocalAction::Guard { guard, inspected } => Ok(ChoiceSkeleton::Guard {
            guard: guard.clone(),
            inspected: inspected.clone(),
            arms: successors
                .iter()
                .filter_map(|(step, _)| match step {
                    TraceStep::Guard { arm, .. } => Some(arm.clone()),
                    _ => None,
                })
                .collect(),
        }),
    }
}

pub fn closure_branch_count(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    actions: &[LocalAction],
) -> Result<usize, WitnessFailure> {
    let mut count = 0usize;
    for action in actions {
        count += action_successors(prepared, state, action)?.len();
    }
    Ok(count)
}

pub fn action_successors(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    action: &LocalAction,
) -> Result<Vec<(TraceStep, SearchState)>, WitnessFailure> {
    match action {
        LocalAction::Invocation(invocation) => {
            check_invocation(prepared, state, invocation)?;
            let function = site_signature(prepared.input(), &invocation.site)
                .ok_or_else(|| WitnessFailure::SignatureMismatch(invocation.site.clone()))?;
            Ok(function
                .outcomes
                .iter()
                .filter(|outcome| !outcome_empty(prepared, outcome))
                .map(|outcome| {
                    (
                        TraceStep::Invocation {
                            invocation: invocation.clone(),
                            outcome: outcome.id.clone(),
                        },
                        after_invocation(state, invocation, outcome),
                    )
                })
                .collect())
        }
        LocalAction::Guard { guard, inspected } => {
            let declaration = guard_declaration(prepared.input(), guard)
                .ok_or_else(|| WitnessFailure::GuardNotDominating(inspected.clone()))?;
            guard_arms(prepared, state, declaration, inspected)?
                .into_iter()
                .map(|arm| {
                    let next = after_guard(prepared, state, declaration, inspected, &arm)?;
                    Ok((
                        TraceStep::Guard {
                            guard: guard.clone(),
                            inspected: inspected.clone(),
                            arm,
                        },
                        next,
                    ))
                })
                .collect()
        }
    }
}

pub fn closure_binding_candidates(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
) -> usize {
    enumerate_returns(prepared, state).cost
        + enumerate_invocations(prepared, state).cost
        + enumerate_guards(prepared, state).cost
}

fn field_keys(fields: &[(String, BindingExpr)]) -> Vec<String> {
    fields
        .iter()
        .map(|(name, binding)| encode_tuple(&[name, &binding_key(binding)]))
        .collect()
}

fn binding_key(binding: &BindingExpr) -> String {
    match binding {
        BindingExpr::Source { value, .. } => encode_tuple(&[
            "source",
            &producer_identity(&value.producer),
            &path_identity(&value.path),
        ]),
        BindingExpr::Product {
            construction,
            type_ref,
            fields,
        } => {
            let mut fields = field_keys(fields);
            fields.sort();
            encode_tuple(&[
                "product",
                construction,
                &type_identity(type_ref),
                &encode_tuple(&fields.iter().map(String::as_str).collect::<Vec<_>>()),
            ])
        }
    }
}

fn invocation_key(invocation: &InvocationPlan) -> String {
    let mut bindings = invocation
        .bindings
        .iter()
        .map(|(port, binding)| encode_tuple(&[&port.0, &binding_key(binding)]))
        .collect::<Vec<_>>();
    bindings.sort();
    let mut resources = invocation
        .resources
        .iter()
        .map(|binding| encode_tuple(&[&binding.requirement.0, &lot_identity(&binding.lot)]))
        .collect::<Vec<_>>();
    resources.sort();
    encode_tuple(&[
        &invocation.site.0,
        &function_identity(&invocation.function),
        &encode_tuple(&bindings.iter().map(String::as_str).collect::<Vec<_>>()),
        &encode_tuple(&resources.iter().map(String::as_str).collect::<Vec<_>>()),
    ])
}

fn return_key(terminal: &ReturnPlan) -> String {
    match terminal {
        ReturnPlan::Success(outputs) => {
            let mut outputs = outputs
                .iter()
                .map(|(id, binding)| encode_tuple(&[&id.0, &binding_key(binding)]))
                .collect::<Vec<_>>();
            outputs.sort();
            let mut parts = vec!["success"];
            parts.extend(outputs.iter().map(String::as_str));
            encode_tuple(&parts)
        }
        ReturnPlan::Failure { embedding, value } => {
            encode_tuple(&["failure", &embedding.0, &binding_key(value)])
        }
    }
}

fn outcome_keys(arms: &[(OutcomeId, PlanTree)]) -> Vec<String> {
    arms.iter()
        .map(|(outcome, child)| encode_tuple(&[&outcome.0, &control_key(child)]))
        .collect()
}

fn guard_keys(arms: &[(GuardArm, PlanTree)]) -> Vec<String> {
    arms.iter()
        .map(|(arm, child)| encode_tuple(&[&guard_arm_identity(arm), &control_key(child)]))
        .collect()
}

fn control_key(tree: &PlanTree) -> String {
    match &tree.node {
        PlanNode::Return(terminal) => return_key(terminal),
        PlanNode::Invoke {
            invocation,
            arms,
            empty_outcomes,
        } => {
            let mut outcomes = outcome_keys(arms);
            outcomes.sort();
            let mut empty = empty_outcomes
                .iter()
                .map(|outcome| outcome.0.as_str())
                .collect::<Vec<_>>();
            empty.sort();
            encode_tuple(&[
                "invoke",
                &invocation_key(invocation),
                &encode_tuple(&outcomes.iter().map(String::as_str).collect::<Vec<_>>()),
                &encode_tuple(&empty),
            ])
        }
        PlanNode::Guard {
            guard,
            inspected,
            arms,
        } => {
            let mut branches = guard_keys(arms);
            branches.sort();
            encode_tuple(&[
                "guard",
                &guard.0,
                &producer_identity(&inspected.producer),
                &path_identity(&inspected.path),
                &encode_tuple(&branches.iter().map(String::as_str).collect::<Vec<_>>()),
            ])
        }
    }
}

fn linear_independent(
    prepared: &PreparedCompositionInput<'_>,
    tree: &PlanTree,
) -> Option<(Vec<String>, String)> {
    match &tree.node {
        PlanNode::Return(terminal) => Some((Vec::new(), return_key(terminal))),
        PlanNode::Guard { .. } => None,
        PlanNode::Invoke {
            invocation,
            arms,
            empty_outcomes,
        } => {
            let [(outcome, child)] = arms.as_slice() else {
                return None;
            };
            if !empty_outcomes.is_empty() {
                return None;
            }
            let function = site_signature(prepared.input(), &invocation.site)?;
            if function.effect != CompositionEffect::PureFunction
                || !function
                    .resource_inputs
                    .iter()
                    .all(|requirement| requirement.mode == resource::BindingMode::Read)
                || !function
                    .outcomes
                    .iter()
                    .all(|branch| branch.produced_resources.is_empty())
            {
                return None;
            }
            let (mut calls, terminal) = linear_independent(prepared, child)?;
            calls.insert(0, encode_tuple(&[&invocation_key(invocation), &outcome.0]));
            Some((calls, terminal))
        }
    }
}

pub fn canonical_plan_key(prepared: &PreparedCompositionInput<'_>, tree: &PlanTree) -> String {
    match linear_independent(prepared, tree) {
        None => control_key(tree),
        Some((mut calls, terminal)) => {
            calls.sort();
            encode_tuple(&[
                "pure-dependency-graph",
                &encode_tuple(&calls.iter().map(String::as_str).collect::<Vec<_>>()),
                &terminal,
            ])
        }
    }
}

pub fn merge_choice(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    choice: &ChoiceSkeleton,
    children: &[Enumeration<PlanTree>],
) -> Enumeration<PlanTree> {
    let max = prepared.input().bounds.branch_node_limit();
    let mut result = Enumeration::default();
    let mut products: Vec<Vec<PlanTree>> = vec![Vec::new()];
    for child in children {
        result.obligations.extend(child.obligations.iter().cloned());
        result.cost += child.cost;
        let mut extended = Vec::new();
        for selected in &products {
            for candidate in &child.values {
                let mut selected = selected.clone();
                selected.push(candidate.clone());
                extended.push(selected);
            }
        }
        if max < extended.len() {
            result
                .obligations
                .push(UnresolvedObligation::BranchBoundExhausted);
        }
        products = extended.into_iter().take(max).collect();
    }
    for trees in products {
        let node = match choice {
            ChoiceSkeleton::Invoke {
                invocation,
                outcomes,
                empty_outcomes,
            } => PlanNode::Invoke {
                invocation: invocation.clone(),
                arms: outcomes.iter().cloned().zip(trees).collect(),
                empty_outcomes: empty_outcomes.clone(),
            },
            ChoiceSkeleton::Guard {
                guard,
                inspected,
                arms,
            } => PlanNode::Guard {
                guard: guard.clone(),
                inspected: inspected.clone(),
                arms: arms.iter().cloned().zip(trees).collect(),
            },
        };
        result.values.push(PlanTree {
            rank: BigUint::from(state.trace.len()),
            node,
        });
    }
    result
}

pub fn finish_program_values(
    prepared: &PreparedCompositionInput<'_>,
    mut result: Enumeration<PlanTree>,
) -> Enumeration<PlanTree> {
    let max = prepared.input().bounds.branch_node_limit();
    if result.values.iter().any(|tree| max < tree_node_count(tree)) {
        result
            .obligations
            .push(UnresolvedObligation::BranchBoundExhausted);
    }
    result.values.retain(|tree| tree_node_count(tree) <= max);
    let limited = capped(
        max,
        result.values,
        UnresolvedObligation::BranchBoundExhausted,
    );
    result.values = limited.values;
    result.obligations.extend(limited.obligations);
    result
}

fn plan_has_success(tree: &PlanTree) -> bool {
    match &tree.node {
        PlanNode::Return(terminal) => matches!(terminal, ReturnPlan::Success(_)),
        PlanNode::Invoke { arms, .. } => outcomes_have_success(arms),
        PlanNode::Guard { arms, .. } => guards_have_success(arms),
    }
}

fn outcomes_have_success(arms: &[(OutcomeId, PlanTree)]) -> bool {
    arms.iter().any(|(_, child)| plan_has_success(child))
}

fn guards_have_success(arms: &[(GuardArm, PlanTree)]) -> bool {
    arms.iter().any(|(_, child)| plan_has_success(child))
}

fn find_closure_node<'a>(
    witness: &'a CompositionClosureWitness,
    state: &SearchState,
) -> Option<&'a CompositionClosureNode> {
    witness.nodes.iter().find(|node| node.state == *state)
}

fn enumerate_programs(
    prepared: &PreparedCompositionInput<'_>,
    witness: &CompositionClosureWitness,
    state: &SearchState,
    fuel: usize,
) -> Enumeration<PlanTree> {
    if fuel == 0 {
        return Enumeration {
            values: Vec::new(),
            obligations: vec![UnresolvedObligation::BranchBoundExhausted],
            cost: 0,
        };
    }
    let Some(record) = find_closure_node(witness, state) else {
        return Enumeration {
            values: Vec::new(),
            obligations: vec![UnresolvedObligation::StateBoundExhausted],
            cost: 0,
        };
    };
    let mut result = Enumeration::default();
    for certificate in &record.terminals {
        result.values.push(PlanTree {
            rank: BigUint::from(record.state.trace.len()),
            node: PlanNode::Return(certificate.trace.terminal.clone()),
        });
    }
    for action in &record.actions {
        let successors = match action_successors(prepared, &record.state, action) {
            Ok(successors) => successors,
            Err(failure) => {
                result
                    .obligations
                    .extend(binding_failure_obligations(&failure));
                continue;
            }
        };
        let choice = match choice_skeleton(prepared, action, &successors) {
            Ok(choice) => choice,
            Err(failure) => {
                result
                    .obligations
                    .extend(binding_failure_obligations(&failure));
                continue;
            }
        };
        let children: Vec<Enumeration<PlanTree>> = successors
            .iter()
            .map(|(_, next)| enumerate_programs(prepared, witness, next, fuel - 1))
            .collect();
        let merged = merge_choice(prepared, &record.state, &choice, &children);
        result.cost += merged.cost;
        result.obligations.extend(merged.obligations);
        result.values.extend(merged.values);
    }
    finish_program_values(prepared, result)
}

pub fn root_programs(
    prepared: &PreparedCompositionInput<'_>,
    witness: &CompositionClosureWitness,
) -> Enumeration<PlanTree> {
    let programs = enumerate_programs(
        prepared,
        witness,
        &initial_state(prepared),
        prepared.input.invocation_domain.sites.len()
            + prepared.input.invocation_domain.guards.len()
            + 1,
    );
    Enumeration {
        values: programs
            .values
            .into_iter()
            .filter(plan_has_success)
            .collect(),
        obligations: programs.obligations,
        cost: programs.cost,
    }
}

fn path_identity(path: &[PathStep]) -> String {
    let steps = path
        .iter()
        .map(|step| match step {
            PathStep::Field(name) => encode_tuple(&["field", name]),
            PathStep::Index(index) => encode_tuple(&["index", &index.to_string()]),
            PathStep::Variant(tag) => encode_tuple(&["variant", tag]),
        })
        .collect::<Vec<_>>();
    encode_tuple(&steps.iter().map(String::as_str).collect::<Vec<_>>())
}

fn guard_arm_identity(arm: &GuardArm) -> String {
    match arm {
        GuardArm::Present => encode_tuple(&["present"]),
        GuardArm::Absent => encode_tuple(&["absent"]),
        GuardArm::Null => encode_tuple(&["null"]),
        GuardArm::Variant(tag) => encode_tuple(&["variant", tag]),
        GuardArm::UnknownVariant => encode_tuple(&["unknown-variant"]),
        GuardArm::Accepted => encode_tuple(&["accepted"]),
        GuardArm::Rejected => encode_tuple(&["rejected"]),
    }
}

pub(crate) fn outcome_empty(
    prepared: &PreparedCompositionInput<'_>,
    outcome: &OutcomeContract,
) -> bool {
    outcome.value_ports.iter().all(|port| {
        validation::check_meaning_defined(
            prepared.graph(),
            std::slice::from_ref(&port.contract.type_ref),
        )
        .is_ok()
    }) && outcome
        .value_ports
        .iter()
        .any(|port| slot_empty(&port.contract, &prepared.empty_refs))
}

pub(crate) fn tree_node_count(tree: &PlanTree) -> usize {
    match &tree.node {
        PlanNode::Return(_) => 1,
        PlanNode::Invoke { arms, .. } => 1 + outcome_node_count(arms),
        PlanNode::Guard { arms, .. } => 1 + guard_node_count(arms),
    }
}

fn outcome_node_count(arms: &[(OutcomeId, PlanTree)]) -> usize {
    arms.iter().map(|(_, child)| tree_node_count(child)).sum()
}

fn guard_node_count(arms: &[(GuardArm, PlanTree)]) -> usize {
    arms.iter().map(|(_, child)| tree_node_count(child)).sum()
}
