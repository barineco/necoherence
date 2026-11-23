// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use super::closure::CompositionEngineFailure;
use super::lowering::*;
use super::verification::TraceStep;
use necoherence::exact_json_view::JsonValueView;
use necoherence::inclusion::verify_inclusion;
use necoherence::semantic_composition::*;
use necoherence::semantic_types::*;
use necoherence::semantic_validation::{FormatWorkspace, PreparedValidator};
use std::collections::HashSet;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AvailableValue {
    pub producer: ProducerRef,
    pub contract: SlotContract,
    pub resource: Option<ResourceLotRef>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct BranchFact {
    pub guard: GuardId,
    pub inspected: ValueRef,
    pub arm: GuardArm,
    pub refinement: Option<SlotContract>,
    pub assumptions: Vec<ProjectionAssumption>,
    pub exact: Option<SlotValue>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SearchState {
    pub available: Vec<AvailableValue>,
    pub used_sites: Vec<SiteId>,
    pub used_guards: Vec<GuardId>,
    pub facts: Vec<BranchFact>,
    pub trace: Vec<TraceStep>,
    pub pending_failure: Option<FailureOrigin>,
}

pub fn initial_state(prepared: &PreparedCompositionInput<'_>) -> SearchState {
    SearchState {
        available: prepared
            .input
            .initial_inputs
            .iter()
            .map(|initial| AvailableValue {
                producer: ProducerRef::Initial(initial.id.clone()),
                contract: initial.contract.clone(),
                resource: initial.resource.clone().map(ResourceLotRef::Initial),
            })
            .collect(),
        used_sites: Vec::new(),
        used_guards: Vec::new(),
        facts: Vec::new(),
        trace: Vec::new(),
        pending_failure: None,
    }
}

fn relative_assumption(
    assumption: &ProjectionAssumption,
    prefix: &[PathStep],
) -> Option<ProjectionAssumption> {
    let trim = |path: &[PathStep]| path.strip_prefix(prefix).map(<[PathStep]>::to_vec);
    match assumption {
        ProjectionAssumption::Present(path) => trim(path).map(ProjectionAssumption::Present),
        ProjectionAssumption::NonNull(path) => trim(path).map(ProjectionAssumption::NonNull),
        ProjectionAssumption::Variant { path, tag } => {
            trim(path).map(|path| ProjectionAssumption::Variant {
                path,
                tag: tag.clone(),
            })
        }
        ProjectionAssumption::IndexPresent { path, index } => {
            trim(path).map(|path| ProjectionAssumption::IndexPresent {
                path,
                index: index.clone(),
            })
        }
    }
}

fn projection_basis<'a>(
    state: &'a SearchState,
    value: &ValueRef,
) -> Result<(&'a SlotContract, &'a [PathStep], Vec<ProjectionAssumption>), WitnessFailure> {
    let source = state
        .available
        .iter()
        .find(|source| source.producer == value.producer)
        .ok_or_else(|| WitnessFailure::ProducerMismatch(value.clone()))?;
    let refinement = state.facts.iter().rev().find(|fact| {
        fact.inspected.producer == value.producer
            && fact.refinement.is_some()
            && value.path.starts_with(&fact.inspected.path)
    });
    let (contract, prefix) = match refinement {
        Some(fact) => (
            fact.refinement
                .as_ref()
                .ok_or_else(|| WitnessFailure::GuardNotDominating(value.clone()))?,
            fact.inspected.path.as_slice(),
        ),
        None => (&source.contract, &[][..]),
    };
    let assumptions = state
        .facts
        .iter()
        .filter(|fact| fact.inspected.producer == value.producer)
        .flat_map(|fact| &fact.assumptions)
        .filter_map(|assumption| relative_assumption(assumption, prefix))
        .collect::<Vec<_>>();
    if !value.path.starts_with(prefix) {
        return Err(WitnessFailure::GuardNotDominating(value.clone()));
    }
    Ok((contract, prefix, assumptions))
}

pub fn effective_projection(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    value: &ValueRef,
) -> Result<ProjectionCertificate, WitnessFailure> {
    let (contract, prefix, assumptions) = projection_basis(state, value)?;
    let path = value.path.get(prefix.len()..).unwrap_or(&[]);
    project_slot(
        prepared.validator().metadata(),
        contract,
        path,
        &assumptions,
    )
    .map_err(WitnessFailure::ProjectionMismatch)
}

pub fn check_binding(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    binding: &BindingExpr,
    destination: &SlotContract,
    constraint: &SourceConstraint,
) -> Result<(), WitnessFailure> {
    let rules = &prepared.input.invocation_domain.permitted_constructions;
    check_binding_fuel(
        prepared,
        state,
        rules.len() + 2,
        binding,
        destination,
        constraint,
    )
}

pub(crate) fn check_invocation(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    invocation: &InvocationPlan,
) -> Result<(), WitnessFailure> {
    let input = prepared.input();
    let function = site_signature(input, &invocation.site)
        .ok_or_else(|| WitnessFailure::SignatureMismatch(invocation.site.clone()))?;
    let mut outcome_ids = HashSet::new();
    if !function
        .outcomes
        .iter()
        .all(|outcome| outcome_ids.insert(&outcome.id))
    {
        return Err(WitnessFailure::IncompleteBranchCoverage(
            invocation.site.0.clone(),
        ));
    }
    if let FunctionForm::Operation(definition) = &function.form {
        let obligations = (prepared.operation_meaning())(function, definition);
        if !obligations.is_empty() {
            return Err(WitnessFailure::Inclusion(
                InclusionFailure::UndefinedMeaning(obligations),
            ));
        }
    }
    if function.reference != invocation.function
        || state.used_sites.contains(&invocation.site)
        || function.handles_failure != state.pending_failure
    {
        return Err(WitnessFailure::SignatureMismatch(invocation.site.clone()));
    }
    if let Some(origin) = function.handles_failure.as_ref() {
        let mut sources = Vec::new();
        for (_, binding) in &invocation.bindings {
            binding_sources(binding, &mut sources);
        }
        if !uses_actual_failure(state, origin, &sources) {
            return Err(WitnessFailure::MissingEvidence(
                "handler must receive the current failure value".to_owned(),
            ));
        }
    }
    if invocation.bindings.len() != function.inputs.len()
        || invocation.resources.len() != function.resource_inputs.len()
    {
        return Err(WitnessFailure::MissingBinding(invocation.site.0.clone()));
    }
    for port in &function.inputs {
        let bindings: Vec<_> = invocation
            .bindings
            .iter()
            .filter(|(id, _)| *id == port.id)
            .collect();
        let [(_, port_binding)] = bindings.as_slice() else {
            return Err(WitnessFailure::MissingBinding(port.id.0.clone()));
        };
        check_binding(
            prepared,
            state,
            port_binding,
            &port.contract,
            &port.source_constraint,
        )?;
        if let Some(requirement) = &port.resource_requirement {
            let resource = invocation
                .resources
                .iter()
                .find(|resource| resource.requirement == *requirement)
                .ok_or_else(|| WitnessFailure::MissingBinding(requirement.0.clone()))?;
            let mut sources = Vec::new();
            binding_sources(port_binding, &mut sources);
            let [source] = sources.as_slice() else {
                return Err(WitnessFailure::ResourceLoweringMismatch(
                    "input backing needs one producer".to_owned(),
                ));
            };
            if declared_value(input, &source.producer)
                .and_then(|(_, lot)| lot)
                .as_ref()
                != Some(&resource.lot)
            {
                return Err(WitnessFailure::ResourceLoweringMismatch(
                    "input backing producer".to_owned(),
                ));
            }
        }
    }
    let available_lots = state_lots(input, state);
    for requirement in &function.resource_inputs {
        let bindings: Vec<_> = invocation
            .resources
            .iter()
            .filter(|binding| binding.requirement == requirement.id)
            .collect();
        let binding = match bindings.as_slice() {
            [binding] if available_lots.contains(&binding.lot) => *binding,
            _ => return Err(WitnessFailure::MissingBinding(requirement.id.0.clone())),
        };
        let lot = declared_lot(input, &binding.lot).ok_or_else(|| {
            WitnessFailure::ResourceLoweringMismatch("resource lot declaration".to_owned())
        })?;
        if lot.revision != requirement.required_revision {
            return Err(WitnessFailure::ResourceLoweringMismatch(
                "required resource revision".to_owned(),
            ));
        }
        if !matches!(&requirement.identity, ResourceIdentityConstraint::Any)
            && requirement.identity != ResourceIdentityConstraint::Exactly(lot.producer)
        {
            return Err(WitnessFailure::ResourceLoweringMismatch(
                "resource producer identity".to_owned(),
            ));
        }
        verify_inclusion(
            prepared.graph(),
            &present_contract(lot.token_type),
            &present_contract(requirement.token_type.clone()),
            &binding.inclusion,
        )
        .map_err(WitnessFailure::Inclusion)?;
    }
    if input
        .explicit_order
        .iter()
        .any(|(before, after)| after == &invocation.site && !state.used_sites.contains(before))
    {
        return Err(WitnessFailure::RankViolation);
    }
    Ok(())
}

pub(crate) fn after_invocation(
    state: &SearchState,
    invocation: &InvocationPlan,
    outcome: &OutcomeContract,
) -> SearchState {
    let mut next = state.clone();
    next.used_sites.push(invocation.site.clone());
    for port in &outcome.value_ports {
        next.available.push(AvailableValue {
            producer: ProducerRef::InvocationOutcome {
                site: invocation.site.clone(),
                outcome: outcome.id.clone(),
                port: port.id.clone(),
            },
            contract: port.contract.clone(),
            resource: port
                .resource_production
                .clone()
                .map(|production| ResourceLotRef::Produced {
                    site: invocation.site.clone(),
                    outcome: outcome.id.clone(),
                    production,
                }),
        });
    }
    next.trace.push(TraceStep::Invocation {
        invocation: invocation.clone(),
        outcome: outcome.id.clone(),
    });
    next.pending_failure = match outcome.form {
        OutcomeForm::Success => None,
        OutcomeForm::DeclaredFailure => Some(FailureOrigin::Function {
            function: invocation.function.clone(),
            outcome: outcome.id.clone(),
        }),
    };
    next
}

pub fn state_lots(input: &CompositionInput, state: &SearchState) -> Vec<ResourceLotRef> {
    let mut result: Vec<_> = input
        .initial_resources
        .iter()
        .map(|lot| ResourceLotRef::Initial(lot.id.clone()))
        .collect();
    for step in &state.trace {
        if let TraceStep::Invocation {
            invocation,
            outcome,
        } = step
        {
            if let Some(outcome_contract) =
                site_signature(input, &invocation.site).and_then(|function| {
                    function
                        .outcomes
                        .iter()
                        .find(|candidate| candidate.id == *outcome)
                })
            {
                result.extend(
                    outcome_contract
                        .produced_resources
                        .iter()
                        .map(|production| ResourceLotRef::Produced {
                            site: invocation.site.clone(),
                            outcome: outcome.clone(),
                            production: production.id.clone(),
                        }),
                );
            }
        }
    }
    result
}

pub(crate) fn guard_arms(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    guard: &DeclaredGuard,
    inspected: &ValueRef,
) -> Result<Vec<GuardArm>, WitnessFailure> {
    if state.used_guards.contains(&guard.id) {
        return Err(WitnessFailure::GuardNotDominating(inspected.clone()));
    }
    let source = state
        .available
        .iter()
        .find(|source| source.producer == inspected.producer)
        .ok_or_else(|| WitnessFailure::ProducerMismatch(inspected.clone()))?;
    if source.contract.type_ref != guard.source_type || inspected.path != guard.path {
        return Err(WitnessFailure::GuardNotDominating(inspected.clone()));
    }
    let projected = effective_projection(prepared, state, inspected)?;
    if let Some(value) = exact_value(prepared, state, inspected) {
        return Ok(vec![evaluate_guard_arm(
            prepared.graph(),
            guard,
            &projected.destination,
            borrowed_slot(&value),
        )?]);
    }
    let mut arms = Vec::new();
    match &guard.kind {
        GuardKind::Validate(destination) => {
            let reasons = prepared
                .validator()
                .meaning_obligations(std::slice::from_ref(&destination.type_ref));
            if !reasons.is_empty() {
                return Err(WitnessFailure::Inclusion(
                    InclusionFailure::UndefinedMeaning(reasons),
                ));
            }
            arms.push(GuardArm::Accepted);
            arms.push(GuardArm::Rejected);
        }
        GuardKind::Presence | GuardKind::Variants => {
            if !projected.destination.required {
                arms.push(GuardArm::Absent);
            }
            if projected.destination.nullable {
                arms.push(GuardArm::Null);
            }
            if guard.kind == GuardKind::Presence {
                arms.push(GuardArm::Present);
            } else {
                let Some(TypeShape::TaggedUnion(spec)) =
                    resolved_shape(prepared.graph(), &projected.destination.type_ref)
                else {
                    return Err(WitnessFailure::GuardNotDominating(inspected.clone()));
                };
                arms.extend(
                    spec.branches
                        .iter()
                        .map(|branch| GuardArm::Variant(branch.wire_tag.clone())),
                );
            }
        }
    }
    Ok(arms)
}

pub fn evaluate_guard_arm(
    graph: &SemanticGraph,
    guard: &DeclaredGuard,
    contract: &SlotContract,
    inspected: SlotValue<&JsonValue>,
) -> Result<GuardArm, WitnessFailure> {
    let validator = PreparedValidator::new(graph, FormatWorkspace::empty());
    let mut prepared = PreparedGuard::new(&validator, guard.clone());
    let view = match inspected {
        SlotValue::Absent => SlotValue::Absent,
        SlotValue::Null => SlotValue::Null,
        SlotValue::Present(value) => SlotValue::Present(JsonValueView::from_json(value)),
    };
    prepared
        .evaluate(contract, view)
        .map(GuardArmView::into_owned)
}

pub(crate) fn after_guard(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    guard: &DeclaredGuard,
    inspected: &ValueRef,
    arm: &GuardArm,
) -> Result<SearchState, WitnessFailure> {
    let projected = effective_projection(prepared, state, inspected)?;
    let mut fact = BranchFact {
        guard: guard.id.clone(),
        inspected: inspected.clone(),
        arm: arm.clone(),
        refinement: None,
        assumptions: Vec::new(),
        exact: None,
    };
    match arm {
        GuardArm::Present | GuardArm::UnknownVariant => {
            let mut contract = projected.destination.clone();
            contract.required = true;
            contract.nullable = false;
            fact.refinement = Some(contract);
        }
        GuardArm::Variant(tag) => fact.assumptions.push(ProjectionAssumption::Variant {
            path: inspected.path.clone(),
            tag: tag.clone(),
        }),
        GuardArm::Absent => fact.exact = Some(SlotValue::Absent),
        GuardArm::Null => fact.exact = Some(SlotValue::Null),
        GuardArm::Accepted => {
            let GuardKind::Validate(contract) = &guard.kind else {
                return Err(WitnessFailure::GuardNotDominating(inspected.clone()));
            };
            fact.refinement = Some(contract.clone());
        }
        GuardArm::Rejected => {}
    }
    if let Some(exact) = exact_value(prepared, state, inspected) {
        fact.exact = Some(exact);
    }
    let mut next = state.clone();
    next.used_guards.push(guard.id.clone());
    next.facts.push(fact);
    next.trace.push(TraceStep::Guard {
        guard: guard.id.clone(),
        inspected: inspected.clone(),
        arm: arm.clone(),
    });
    let preserves_pending = matches!(
        state.pending_failure,
        Some(FailureOrigin::Function { .. })
            | Some(FailureOrigin::Guard {
                arm: GuardArm::Rejected,
                ..
            })
    );
    if !preserves_pending
        && matches!(
            arm,
            GuardArm::Absent | GuardArm::Null | GuardArm::UnknownVariant | GuardArm::Rejected
        )
    {
        next.pending_failure = Some(FailureOrigin::Guard {
            guard: guard.id.clone(),
            arm: arm.clone(),
        });
    }
    Ok(next)
}

pub fn initial_membership(
    prepared: &PreparedCompositionInput<'_>,
) -> Result<Vec<(InputId, SlotValue)>, CompositionEngineFailure> {
    let mut result = Vec::new();
    for initial in &prepared.input.initial_inputs {
        let value = match &initial.source {
            InitialSource::SuppliedValue(value) => value.clone(),
            InitialSource::Argument => {
                match find_accepted_slot_candidate(
                    &mut prepared.validator(),
                    &prepared.input.bounds,
                    &initial.contract,
                    |_, _| SlotCandidateControl::Accept,
                ) {
                    SlotCandidateSearch::AcceptedWithinBound(value)
                    | SlotCandidateSearch::AcceptedBeyondSampleBound(value) => value,
                    SlotCandidateSearch::NoEvidence => {
                        return Err(CompositionEngineFailure::ContractViolation(
                            "feasible branch omitted initial inhabitation".to_owned(),
                        ));
                    }
                }
            }
        };
        result.push((initial.id.clone(), value));
    }
    Ok(result)
}

pub(crate) fn uses_actual_failure(
    state: &SearchState,
    origin: &FailureOrigin,
    sources: &[&ValueRef],
) -> bool {
    match origin {
        FailureOrigin::Function { function, outcome } => {
            let latest = state.trace.iter().rev().find_map(|step| match step {
                TraceStep::Invocation {
                    invocation,
                    outcome: selected,
                } if &invocation.function == function && selected == outcome => {
                    Some(&invocation.site)
                }
                _ => None,
            });
            latest.is_some_and(|site| {
                sources.iter().any(|source| {
                    matches!(&source.producer, ProducerRef::InvocationOutcome { site: actual, outcome: selected, .. } if actual == site && selected == outcome)
                })
            })
        }
        FailureOrigin::Guard { guard, .. } => state
            .facts
            .iter()
            .rev()
            .find(|fact| &fact.guard == guard)
            .is_some_and(|fact| {
                sources.iter().any(|source| {
                    source.producer == fact.inspected.producer
                        && source.path.starts_with(&fact.inspected.path)
                })
            }),
    }
}
fn path_permitted(input: &CompositionInput, source: &SlotContract, path: &[PathStep]) -> bool {
    path.is_empty()
        || input
            .invocation_domain
            .permitted_projections
            .iter()
            .any(|projection| projection.source_type == source.type_ref && projection.path == path)
        || input
            .invocation_domain
            .guards
            .iter()
            .any(|guard| guard.source_type == source.type_ref && guard.path == path)
}
fn ensure_possible(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    value: &ValueRef,
    contract: &SlotContract,
) -> Result<(), WitnessFailure> {
    if let Some(exact) = exact_value(prepared, state, value) {
        if matches!(
            prepared
                .validator()
                .accepts_slot(contract, borrowed_slot(&exact)),
            ValueDecision::Accepted
        ) {
            return Ok(());
        }
    } else if !slot_empty(contract, &prepared.empty_refs)
        && matches!(
            find_accepted_slot_candidate(
                &mut prepared.validator(),
                &prepared.input.bounds,
                contract,
                |_, _| SlotCandidateControl::Accept,
            ),
            SlotCandidateSearch::AcceptedWithinBound(_)
                | SlotCandidateSearch::AcceptedBeyondSampleBound(_)
        )
    {
        return Ok(());
    }
    Err(WitnessFailure::MissingEvidence(
        "no accepted value for producer".to_owned(),
    ))
}
pub(crate) fn check_binding_fuel(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    fuel: usize,
    binding: &BindingExpr,
    destination: &SlotContract,
    constraint: &SourceConstraint,
) -> Result<(), WitnessFailure> {
    let Some(remaining) = fuel.checked_sub(1) else {
        return Err(WitnessFailure::ConstructionMismatch(
            destination.type_ref.clone(),
        ));
    };
    match binding {
        BindingExpr::Source {
            value,
            projection,
            compatibility,
        } => {
            if !constraint.accepts(&value.producer, &value.path) {
                return Err(WitnessFailure::SourceConstraintMismatch(value.clone()));
            }
            let source = state
                .available
                .iter()
                .find(|source| source.producer == value.producer)
                .ok_or_else(|| WitnessFailure::ProducerMismatch(value.clone()))?;
            if !path_permitted(prepared.input(), &source.contract, &value.path) {
                return Err(WitnessFailure::ProjectionMismatch(
                    ProjectionFailure::CertificateMismatch(
                        "projection is outside the finite domain".to_owned(),
                    ),
                ));
            }
            let computed = effective_projection(prepared, state, value)?;
            if computed != *projection {
                return Err(WitnessFailure::ProjectionMismatch(
                    ProjectionFailure::CertificateMismatch(
                        "source, projection, or dominating guard".to_owned(),
                    ),
                ));
            }
            ensure_possible(prepared, state, value, &projection.destination)?;
            check_projection_certificate(prepared.validator().metadata(), projection)
                .map_err(WitnessFailure::ProjectionMismatch)?;
            match compatibility {
                BindingCompatibility::Inclusion(certificate) => {
                    verify_inclusion(
                        prepared.graph(),
                        &projection.destination,
                        destination,
                        certificate,
                    )
                    .map_err(WitnessFailure::Inclusion)?;
                }
                BindingCompatibility::SuppliedValue { value: supplied } => {
                    if exact_value(prepared, state, value).as_ref() != Some(supplied)
                        || !matches!(
                            prepared
                                .validator()
                                .accepts_slot(&projection.destination, borrowed_slot(supplied)),
                            ValueDecision::Accepted
                        )
                        || !matches!(
                            prepared
                                .validator()
                                .accepts_slot(destination, borrowed_slot(supplied)),
                            ValueDecision::Accepted
                        )
                    {
                        return Err(WitnessFailure::SuppliedValueMismatch(value.clone()));
                    }
                }
            }
            Ok(())
        }
        BindingExpr::Product {
            construction,
            type_ref,
            fields,
        } => {
            let rule = prepared
                .input
                .invocation_domain
                .permitted_constructions
                .iter()
                .find(|rule| &rule.identity == construction && &rule.type_ref == type_ref)
                .ok_or_else(|| WitnessFailure::ConstructionMismatch(type_ref.clone()))?;
            if !matches!(constraint, SourceConstraint::AnyCompatible)
                || *type_ref != destination.type_ref
            {
                return Err(WitnessFailure::ConstructionMismatch(type_ref.clone()));
            }
            let Some(TypeShape::Product(spec)) = resolved_shape(prepared.graph(), type_ref) else {
                return Err(WitnessFailure::ConstructionMismatch(type_ref.clone()));
            };
            if !no_duplicates(&fields.iter().map(|(name, _)| name).collect::<Vec<_>>()) {
                return Err(WitnessFailure::ConstructionMismatch(type_ref.clone()));
            }
            for (name, binding) in fields {
                let field = spec
                    .fields
                    .iter()
                    .find(|field| field.wire_name == *name)
                    .ok_or_else(|| WitnessFailure::ConstructionMismatch(type_ref.clone()))?;
                if let BindingExpr::Product {
                    construction: child,
                    ..
                } = binding
                {
                    if !rule
                        .nested_fields
                        .iter()
                        .any(|(field, nested)| field == name && nested == child)
                    {
                        return Err(WitnessFailure::ConstructionMismatch(type_ref.clone()));
                    }
                }
                if !field.slot.nullable && binding_may_have_present_null(prepared, state, binding) {
                    return Err(WitnessFailure::ConstructionMismatch(type_ref.clone()));
                }
                let constraint = rule.field_constraint(name);
                check_binding_fuel(prepared, state, remaining, binding, &field.slot, constraint)?;
            }
            for field in &spec.fields {
                if (field.slot.required || rule.field_required(&field.wire_name))
                    && !fields.iter().any(|(name, _)| name == &field.wire_name)
                {
                    return Err(WitnessFailure::ConstructionMismatch(type_ref.clone()));
                }
            }
            let reasons = prepared
                .validator()
                .meaning_obligations(std::slice::from_ref(type_ref));
            if !reasons.is_empty() {
                return Err(WitnessFailure::Inclusion(
                    InclusionFailure::UndefinedMeaning(reasons),
                ));
            }
            Ok(())
        }
    }
}
fn binding_may_have_present_null(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    binding: &BindingExpr,
) -> bool {
    match binding {
        BindingExpr::Source { value, .. } => match exact_value(prepared, state, value) {
            Some(SlotValue::Present(JsonValue::Null)) => true,
            Some(_) => false,
            None => match effective_projection(prepared, state, value) {
                Err(_) => true,
                Ok(projection) => !matches!(
                    prepared
                        .validator()
                        .accepts_value(&projection.destination.type_ref, &JsonValue::Null),
                    ValueDecision::Rejected(_)
                ),
            },
        },
        BindingExpr::Product { .. } => false,
    }
}
pub(crate) fn no_duplicates<T: PartialEq>(items: &[T]) -> bool {
    items
        .iter()
        .enumerate()
        .all(|(index, item)| items.iter().skip(index + 1).all(|other| other != item))
}
pub fn exact_value(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    value: &ValueRef,
) -> Option<SlotValue> {
    let profile = prepared.graph().profile();
    if let Some(fact) = state.facts.iter().rev().find(|fact| {
        fact.inspected.producer == value.producer
            && fact.exact.is_some()
            && value.path.starts_with(&fact.inspected.path)
    }) {
        return Some(project_owned(
            profile,
            fact.exact.as_ref()?,
            value.path.strip_prefix(fact.inspected.path.as_slice())?,
        ));
    }
    match &value.producer {
        ProducerRef::Initial(id) => match &prepared
            .input()
            .initial_inputs
            .iter()
            .find(|initial| initial.id == *id)?
            .source
        {
            InitialSource::SuppliedValue(supplied) => {
                Some(project_owned(profile, supplied, &value.path))
            }
            InitialSource::Argument => None,
        },
        _ => None,
    }
}
#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod binding_fuel_tests {
    use super::*;
    use necoherence::semantic_types::{
        IntegerDomain, IntegerDomainBinding, IntegerForm, NumberModel, ProfileRef,
    };
    use necoherence::signature_admission::{check_type_signatures, signature_type_ref};
    use necoherence::type_signatures::{
        Shape, SignatureExtraMembers, SignatureField, SignatureProduct, SignatureSlot,
        TypeNodeInput, TypeSignatureLibrary, ValueSemanticProfile,
    };
    use num_bigint::BigInt;

    fn product_node(id: &str, child: Option<&str>) -> TypeNodeInput {
        let fields = match child {
            Some(type_id) => vec![SignatureField {
                wire_name: "next".into(),
                slot: SignatureSlot {
                    type_id: type_id.into(),
                    required: true,
                    nullable: false,
                },
            }],
            None => vec![],
        };
        TypeNodeInput {
            id: id.into(),
            shape: Shape::Product(SignatureProduct {
                fields,
                extras: SignatureExtraMembers::Reject,
            }),
        }
    }

    fn chain_library() -> TypeSignatureLibrary {
        let reference = ProfileRef {
            identity: "execution-profile".into(),
            revision: "1".into(),
            content_digest: "a".repeat(64),
        };
        TypeSignatureLibrary {
            schema: "ncoh-type-signatures@1".into(),
            identity: "binding-fuel-library".into(),
            revision: "1".into(),
            profile: ValueSemanticProfile {
                reference: reference.clone(),
                source_refs: vec![],
                integer_domains: vec![IntegerDomainBinding {
                    name: "integer".into(),
                    reference,
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
                bytes_policy: None,
                wrappers: vec![],
                tag: None,
            },
            sources: vec![],
            provenance: vec![],
            groups: vec![],
            annotations: vec![],
            nodes: vec![
                product_node("leaf", None),
                product_node("middle", Some("leaf")),
                product_node("outer", Some("middle")),
            ],
            definitions: vec![],
        }
    }

    fn chain_problem(graph: &SemanticGraph) -> CompositionInput {
        CompositionInput {
            identity: "binding-fuel".into(),
            revision: "1".into(),
            basis: SemanticBasis::of(graph),
            signatures: vec![],
            initial_inputs: vec![],
            initial_resources: vec![],
            goal: GoalSpec {
                outputs: vec![],
                failures: vec![],
                final_resources: vec![],
            },
            invocation_domain: InvocationDomain {
                identity: "binding-fuel-domain".into(),
                revision: "1".into(),
                sites: vec![],
                permitted_projections: vec![],
                permitted_constructions: vec![],
                permitted_transforms: vec![],
                guards: vec![],
            },
            allowed_effects: vec![],
            explicit_order: vec![],
            selection_policy: None,
            bounds: SearchBounds::default(),
        }
    }

    fn rule(identity: &str, type_ref: &TypeRef, nested: Option<&str>) -> ConstructionRule {
        let nested_fields = match nested {
            Some(child) => vec![("next".into(), child.into())],
            None => vec![],
        };
        ConstructionRule {
            identity: identity.into(),
            type_ref: type_ref.clone(),
            nested_fields,
            field_constraints: vec![],
        }
    }

    #[test]
    fn binding_fuel_is_spent_per_product_level_and_fails_at_zero_as_lean_does() {
        let graph = check_type_signatures(&chain_library()).unwrap();
        let leaf = signature_type_ref("leaf");
        let middle = signature_type_ref("middle");
        let outer = signature_type_ref("outer");
        let destination = SlotContract {
            type_ref: outer.clone(),
            required: true,
            nullable: false,
        };
        let mut input = chain_problem(&graph);
        input.goal.outputs = vec![GoalPort {
            id: GoalPortId("result".into()),
            contract: destination.clone(),
            source_constraint: SourceConstraint::AnyCompatible,
        }];
        input.invocation_domain.permitted_constructions = vec![
            rule("outer-rule", &outer, Some("middle-rule")),
            rule("middle-rule", &middle, Some("leaf-rule")),
            rule("leaf-rule", &leaf, None),
        ];
        let prepared = prepare_direct_composition(
            &graph,
            input,
            operation_checker_without_library(),
            operation_meaning_of(&graph),
        )
        .unwrap();
        let state = initial_state(&prepared);
        let binding = BindingExpr::Product {
            construction: "outer-rule".into(),
            type_ref: outer.clone(),
            fields: vec![(
                "next".into(),
                BindingExpr::Product {
                    construction: "middle-rule".into(),
                    type_ref: middle.clone(),
                    fields: vec![(
                        "next".into(),
                        BindingExpr::Product {
                            construction: "leaf-rule".into(),
                            type_ref: leaf.clone(),
                            fields: vec![],
                        },
                    )],
                },
            )],
        };
        let check = |fuel: usize| {
            check_binding_fuel(
                &prepared,
                &state,
                fuel,
                &binding,
                &destination,
                &SourceConstraint::AnyCompatible,
            )
        };
        assert_eq!(
            check(0),
            Err(WitnessFailure::ConstructionMismatch(outer.clone()))
        );
        assert_eq!(
            check(1),
            Err(WitnessFailure::ConstructionMismatch(middle.clone()))
        );
        assert_eq!(
            check(2),
            Err(WitnessFailure::ConstructionMismatch(leaf.clone()))
        );
        assert_eq!(check(3), Ok(()));
        assert_eq!(
            check_binding(
                &prepared,
                &state,
                &binding,
                &destination,
                &SourceConstraint::AnyCompatible,
            ),
            Ok(())
        );
    }

    #[test]
    fn duplicate_field_names_fail_before_child_checks_as_lean_does() {
        let graph = check_type_signatures(&chain_library()).unwrap();
        let leaf = signature_type_ref("leaf");
        let middle = signature_type_ref("middle");
        let outer = signature_type_ref("outer");
        let destination = SlotContract {
            type_ref: outer.clone(),
            required: true,
            nullable: false,
        };
        let mut input = chain_problem(&graph);
        input.goal.outputs = vec![GoalPort {
            id: GoalPortId("result".into()),
            contract: destination.clone(),
            source_constraint: SourceConstraint::AnyCompatible,
        }];
        input.invocation_domain.permitted_constructions = vec![
            rule("outer-rule", &outer, Some("middle-rule")),
            rule("middle-rule", &middle, Some("leaf-rule")),
            rule("leaf-rule", &leaf, None),
        ];
        let prepared = prepare_direct_composition(
            &graph,
            input,
            operation_checker_without_library(),
            operation_meaning_of(&graph),
        )
        .unwrap();
        let state = initial_state(&prepared);
        let failing_child = BindingExpr::Product {
            construction: "middle-rule".into(),
            type_ref: middle.clone(),
            fields: vec![(
                "missing".into(),
                BindingExpr::Product {
                    construction: "leaf-rule".into(),
                    type_ref: leaf.clone(),
                    fields: vec![],
                },
            )],
        };
        let valid_child = BindingExpr::Product {
            construction: "middle-rule".into(),
            type_ref: middle.clone(),
            fields: vec![(
                "next".into(),
                BindingExpr::Product {
                    construction: "leaf-rule".into(),
                    type_ref: leaf.clone(),
                    fields: vec![],
                },
            )],
        };
        let outer_binding = |fields: Vec<(String, BindingExpr)>| BindingExpr::Product {
            construction: "outer-rule".into(),
            type_ref: outer.clone(),
            fields,
        };
        let check = |binding: &BindingExpr| {
            check_binding_fuel(
                &prepared,
                &state,
                3,
                binding,
                &destination,
                &SourceConstraint::AnyCompatible,
            )
        };
        assert_eq!(
            check(&outer_binding(vec![("next".into(), failing_child.clone())])),
            Err(WitnessFailure::ConstructionMismatch(middle.clone()))
        );
        assert_eq!(
            check(&outer_binding(vec![
                ("next".into(), failing_child),
                ("next".into(), valid_child),
            ])),
            Err(WitnessFailure::ConstructionMismatch(outer.clone()))
        );
    }
}
