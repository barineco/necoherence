// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use num_bigint::BigUint;
use std::collections::VecDeque;
use std::sync::Arc;

use crate::closure::*;
use crate::enumeration::*;
use crate::lowering::*;
use crate::search_state::*;
use crate::verification::*;
use necoherence::resource_witness::{verify_acyclic_witness, verify_reachability_witness};
use necoherence::semantic_composition::*;
use necoherence::semantic_types::ValueDecision;
use necoherence::semantic_types::*;
use necoherence::typed_mapping as resource;

pub use necoherence::resource_witness::verify_closure_witness;

fn assess_terminal_value(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    terminal: &ReturnPlan,
) -> Result<TerminalAssessment, CompositionEngineFailure> {
    let trace = BranchTrace {
        steps: state.trace.clone(),
        terminal: terminal.clone(),
    };
    let (lowering, correspondence) = match lower_resource_trace(prepared, &trace) {
        Ok(lowering) => lowering,
        Err(LoweringFailure::Unknown(reason)) => {
            return Ok(TerminalAssessment::Unknown(vec![reason]))
        }
        Err(LoweringFailure::Invalid(_)) => {
            return Ok(TerminalAssessment::Unknown(vec![
                UnresolvedObligation::BranchBoundExhausted,
            ]))
        }
    };
    match necoherence_solver::typed_mapping_solver::check_reachability(&lowering)
        .map_err(CompositionEngineFailure::Resource)?
    {
        resource::ReachabilityResult::Reachable(reachability) => {
            verify_reachability_witness(&lowering, &reachability)
                .map_err(CompositionEngineFailure::Witness)?;
            if reachability.path != correspondence.execution_order {
                return Err(CompositionEngineFailure::ContractViolation(
                    "resource solver path differs from the selected finite trace".to_owned(),
                ));
            }
            match necoherence_solver::typed_mapping_solver::check_well_foundedness(&lowering)
                .map_err(CompositionEngineFailure::Resource)?
            {
                resource::WellFoundednessResult::WellFounded(acyclicity) => {
                    verify_acyclic_witness(&lowering, &acyclicity)
                        .map_err(CompositionEngineFailure::Witness)?;
                    let candidates = model_candidates(prepared, state);
                    for value_sources in candidates.models {
                        if verify_terminal_values(prepared, state, terminal, &value_sources).is_ok()
                        {
                            return Ok(TerminalAssessment::Feasible(ResourceTraceCertificate {
                                trace,
                                lowering,
                                correspondence,
                                reachability,
                                acyclicity,
                                value_sources,
                            }));
                        }
                    }
                    Ok(TerminalAssessment::Unknown(vec![candidates
                        .obligations
                        .into_iter()
                        .next()
                        .unwrap_or(UnresolvedObligation::BranchBoundExhausted)]))
                }
                resource::WellFoundednessResult::Unknown(reason) => {
                    Ok(TerminalAssessment::Unknown(vec![
                        UnresolvedObligation::ResourceSolverUnknown(reason),
                    ]))
                }
                other => Err(CompositionEngineFailure::ContractViolation(format!(
                    "finite permit-controlled trace is not acyclic: {:?}",
                    other
                ))),
            }
        }
        resource::ReachabilityResult::Unreachable(closure) => {
            verify_closure_witness(&lowering, &closure)
                .map_err(CompositionEngineFailure::Witness)?;
            Ok(TerminalAssessment::ResourceUnreachable {
                trace,
                lowering,
                correspondence,
                closure,
            })
        }
        resource::ReachabilityResult::Unknown(reason) => Ok(TerminalAssessment::Unknown(vec![
            UnresolvedObligation::ResourceSolverUnknown(reason),
        ])),
        resource::ReachabilityResult::Invalid(reason) => {
            Err(CompositionEngineFailure::ContractViolation(format!(
                "validated lowering became invalid: {:?}",
                reason
            )))
        }
    }
}

pub fn assess_terminal(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    terminal: &ReturnPlan,
) -> Result<CompositionEvaluation<TerminalAssessment>, CompositionEngineFailure> {
    assess_terminal_value(prepared, state, terminal).map(|assessment| {
        classify_terminal_assessment(
            CompositionProvenance {
                operation: "assess_terminal".into(),
                input_identity: prepared.input().identity.clone(),
                input_revision: prepared.input().revision.clone(),
            },
            assessment,
        )
    })
}
struct ModelCandidates {
    models: Vec<Vec<(ProducerRef, SlotValue)>>,
    obligations: Vec<UnresolvedObligation>,
}

fn tag_key(prepared: &PreparedCompositionInput<'_>) -> String {
    prepared
        .graph()
        .profile()
        .tag
        .as_ref()
        .map(|model| model.key.clone())
        .unwrap_or_default()
}

fn member_value<'a>(key: &str, members: &'a [(String, JsonValue)]) -> Option<&'a JsonValue> {
    members
        .iter()
        .find(|(name, _)| name == key)
        .map(|(_, value)| value)
}

fn replace_model_path(
    tag_key: &str,
    value: &SlotValue,
    path: &[PathStep],
    replacement: &SlotValue,
) -> Option<SlotValue> {
    let Some((step, rest)) = path.split_first() else {
        return Some(replacement.clone());
    };
    match (value, step) {
        (SlotValue::Present(JsonValue::Obj(members)), PathStep::Field(name)) => {
            let original = match member_value(name, members) {
                None => SlotValue::Absent,
                Some(JsonValue::Null) => SlotValue::Null,
                Some(value) => SlotValue::Present(value.clone()),
            };
            let next = replace_model_path(tag_key, &original, rest, replacement)?;
            let mut updated: Vec<(String, JsonValue)> = members
                .iter()
                .filter(|(member, _)| member != name)
                .cloned()
                .collect();
            match next {
                SlotValue::Absent => {}
                SlotValue::Null => updated.push((name.clone(), JsonValue::Null)),
                SlotValue::Present(value) => updated.push((name.clone(), value)),
            }
            Some(SlotValue::Present(JsonValue::Obj(updated)))
        }
        (SlotValue::Present(JsonValue::Arr(values)), PathStep::Index(index)) => {
            let index = usize::try_from(index).ok()?;
            let original = values.get(index)?.clone();
            let next =
                replace_model_path(tag_key, &SlotValue::Present(original), rest, replacement)?;
            let item = match next {
                SlotValue::Present(item) => item,
                SlotValue::Null => JsonValue::Null,
                SlotValue::Absent => return None,
            };
            let mut updated = values.clone();
            *updated.get_mut(index)? = item;
            Some(SlotValue::Present(JsonValue::Arr(updated)))
        }
        (SlotValue::Present(JsonValue::Obj(members)), PathStep::Variant(tag)) => {
            if member_value(tag_key, members) == Some(&JsonValue::Str(tag.clone())) {
                replace_model_path(tag_key, value, rest, replacement)
            } else {
                None
            }
        }
        _ => None,
    }
}

fn refined_model_values(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    source: &AvailableValue,
    base: Vec<SlotValue>,
) -> Vec<SlotValue> {
    let graph = prepared.graph();
    let bounds = &prepared.input().bounds;
    let key = tag_key(prepared);
    let mut values = base;
    for fact in &state.facts {
        if fact.inspected.producer != source.producer {
            continue;
        }
        let replacements = match (&fact.exact, &fact.refinement) {
            (Some(value), _) => vec![value.clone()],
            (None, Some(contract)) => slot_samples(graph, bounds, contract).values,
            (None, None) => Vec::new(),
        };
        let extended: Vec<SlotValue> = values
            .iter()
            .flat_map(|original| {
                replacements.iter().filter_map(|replacement| {
                    replace_model_path(&key, original, &fact.inspected.path, replacement)
                })
            })
            .collect();
        values.extend(extended);
        let mut validator = prepared.validator();
        values = values
            .into_iter()
            .filter(|value| {
                matches!(
                    validator.accepts_slot(&source.contract, borrowed_slot(value)),
                    ValueDecision::Accepted
                )
            })
            .take(bounds.binding_candidate_limit())
            .collect();
    }
    values
}

fn model_candidates(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
) -> ModelCandidates {
    let limit = prepared.input().bounds.binding_candidate_limit();
    let mut models: Vec<Vec<(ProducerRef, SlotValue)>> = vec![Vec::new()];
    let mut obligations = Vec::new();
    for source in &state.available {
        let supplied = exact_value(
            prepared,
            state,
            &ValueRef {
                producer: source.producer.clone(),
                path: Vec::new(),
            },
        );
        let values = match supplied {
            Some(value) => vec![value],
            None => {
                let base =
                    slot_samples(prepared.graph(), &prepared.input().bounds, &source.contract)
                        .values;
                refined_model_values(prepared, state, source, base)
            }
        };
        if values.is_empty() {
            obligations.push(UnresolvedObligation::Inhabitation {
                producer: source.producer.clone(),
                contract: source.contract.clone(),
            });
        }
        let mut extended = Vec::new();
        for model in &models {
            for value in &values {
                let mut next = model.clone();
                next.push((source.producer.clone(), value.clone()));
                extended.push(next);
            }
        }
        if limit < extended.len() {
            obligations.push(UnresolvedObligation::BindingBoundExhausted);
        }
        extended.truncate(limit);
        models = extended;
    }
    ModelCandidates {
        models,
        obligations,
    }
}

pub fn decide_unreachable<'p, 'g>(
    prepared: &PreparedCompositionInput<'_>,
    closure: CompositionClosureWitness,
) -> Result<CompositionDecision<'p, 'g>, CompositionEngineFailure> {
    let checked = verify_unreachable_composition(prepared, closure)
        .map_err(CompositionEngineFailure::Witness)?;
    Ok(CompositionDecision::Unreachable(checked))
}

pub fn decide_ambiguous<'p, 'g>(
    prepared: &'p PreparedCompositionInput<'g>,
    candidates: Vec<VerifiedCompositionCandidate<'p, 'g>>,
) -> Result<CompositionDecision<'p, 'g>, CompositionEngineFailure> {
    let canonical_plans: Vec<String> = candidates
        .iter()
        .map(|candidate| canonical_plan_key(prepared, &candidate.plan().root))
        .collect();
    let Some(first) = canonical_plans.first() else {
        return Err(CompositionEngineFailure::ContractViolation(
            "ambiguity needs checked candidates".to_owned(),
        ));
    };
    if !canonical_plans.iter().any(|key| key != first) {
        return Err(CompositionEngineFailure::ContractViolation(
            "ambiguity needs distinct canonical programs".to_owned(),
        ));
    }
    Ok(CompositionDecision::Ambiguous {
        candidates,
        canonical_plans,
    })
}

fn connection_failures(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    destination: &SlotContract,
    constraint: &SourceConstraint,
    fuel: usize,
    failures: &mut Vec<ConnectionFailure>,
) {
    if fuel == 0 {
        return;
    }
    for value in candidate_values(prepared, state, constraint) {
        failures.extend(source_rejection(prepared, state, &value, destination));
    }
    if !matches!(constraint, SourceConstraint::AnyCompatible) {
        return;
    }
    let input = prepared.input();
    for rule in input
        .invocation_domain
        .permitted_constructions
        .iter()
        .filter(|rule| rule.type_ref == destination.type_ref)
    {
        let Some(TypeShape::Product(product)) = resolved_shape(prepared.graph(), &rule.type_ref)
        else {
            continue;
        };
        for field in &product.fields {
            let field_constraint = rule
                .field_constraints
                .iter()
                .find(|constraint| constraint.field == field.wire_name)
                .map_or(&SourceConstraint::AnyCompatible, |constraint| {
                    &constraint.source
                });
            connection_failures(
                prepared,
                state,
                &field.slot,
                field_constraint,
                fuel - 1,
                failures,
            );
        }
    }
}

fn state_diagnostics(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
) -> Vec<ConnectionFailure> {
    let input = prepared.input();
    let fuel = input.invocation_domain.permitted_constructions.len() + 2;
    let mut failures = Vec::new();
    if state.pending_failure.is_none() {
        for goal in &input.goal.outputs {
            connection_failures(
                prepared,
                state,
                &goal.contract,
                &goal.source_constraint,
                fuel,
                &mut failures,
            );
        }
    }
    if let Some(origin) = &state.pending_failure {
        for embedding in input
            .goal
            .failures
            .iter()
            .filter(|embedding| &embedding.origin == origin)
        {
            connection_failures(
                prepared,
                state,
                &embedding.contract,
                &SourceConstraint::AnyCompatible,
                fuel,
                &mut failures,
            );
        }
    }
    for (_, function) in admissible_sites(prepared, state) {
        for port in &function.inputs {
            connection_failures(
                prepared,
                state,
                &port.contract,
                &port.source_constraint,
                fuel,
                &mut failures,
            );
        }
        for requirement in &function.resource_inputs {
            failures.extend(resource_rejections(prepared, state, requirement));
        }
    }
    failures
}

struct ExpandedNode {
    node: CompositionClosureNode,
    obligations: Vec<UnresolvedObligation>,
    cost: usize,
    successors: Vec<SearchState>,
    failures: Vec<ConnectionFailure>,
}

fn expand_node(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
) -> Result<ExpandedNode, CompositionEngineFailure> {
    let returns = enumerate_returns(prepared, state);
    let invocations = enumerate_invocations(prepared, state);
    let guards = enumerate_guards(prepared, state);
    let cost = returns.cost + invocations.cost + guards.cost;
    let failures = state_diagnostics(prepared, state);
    let mut obligations = returns.obligations;
    obligations.extend(invocations.obligations);
    obligations.extend(guards.obligations);
    let mut terminals = Vec::new();
    for terminal in returns.values {
        let assessment = match assess_terminal(prepared, state, &terminal)?
            .map_err(CompositionEngineFailure::Reasons)?
        {
            RefinementOutcome::Resolved(value)
            | RefinementOutcome::Residual { value, .. }
            | RefinementOutcome::Stopped { value, .. } => value.value,
        };
        match assessment {
            TerminalAssessment::Feasible(certificate) => terminals.push(certificate),
            TerminalAssessment::Unknown(reasons) => obligations.extend(reasons),
            _ => {}
        }
    }
    let actions = invocations
        .values
        .into_iter()
        .chain(guards.values)
        .collect::<Vec<_>>();
    let mut successors = Vec::new();
    for action in &actions {
        for (_, child) in
            action_successors(prepared, state, action).map_err(CompositionEngineFailure::Witness)?
        {
            successors.push(child);
        }
    }
    Ok(ExpandedNode {
        node: CompositionClosureNode {
            state: state.clone(),
            actions,
            terminals,
        },
        obligations,
        cost,
        successors,
        failures,
    })
}

fn expand_closure(
    prepared: &PreparedCompositionInput<'_>,
) -> Result<(CompositionClosureWitness, Vec<ConnectionFailure>), CompositionEngineFailure> {
    let bounds = &prepared.input().bounds;
    let ExpandedNode {
        node: root_node,
        obligations: root_obligations,
        cost: root_cost,
        successors: root_successors,
        failures: root_failures,
    } = expand_node(prepared, &initial_state(prepared))?;
    let mut failures = root_failures;
    let mut nodes = vec![root_node];
    let mut obligations = root_obligations;
    let mut binding_candidates = root_cost;
    let mut branch_nodes = root_successors.len();
    let mut pending = VecDeque::from(root_successors);
    let mut fuel = bounds.expanded_state_limit();
    let mut steps = 0usize;
    let frontier: Vec<SearchState> = loop {
        if fuel == 0 {
            break pending.into_iter().collect();
        }
        let Some(state) = pending.pop_front() else {
            break Vec::new();
        };
        fuel -= 1;
        if nodes.iter().any(|node| node.state == state) {
            continue;
        }
        let ExpandedNode {
            node,
            obligations: node_obligations,
            cost,
            successors,
            failures: node_failures,
        } = expand_node(prepared, &state)?;
        failures.extend(node_failures);
        obligations.extend(node_obligations);
        steps += 1;
        binding_candidates += cost;
        branch_nodes += successors.len();
        for successor in successors.iter().rev() {
            pending.push_front(successor.clone());
        }
        nodes.push(node);
        if bounds.binding_candidate_limit() < binding_candidates
            || bounds.branch_node_limit() < branch_nodes
        {
            obligations.push(if bounds.binding_candidate_limit() < binding_candidates {
                UnresolvedObligation::BindingBoundExhausted
            } else {
                UnresolvedObligation::BranchBoundExhausted
            });
            break pending.into_iter().collect();
        }
    };
    Ok((
        CompositionClosureWitness {
            input_identity: prepared.input().identity.clone(),
            input_revision: prepared.input().revision.clone(),
            nodes,
            steps: BigUint::from(steps),
            binding_candidates: BigUint::from(binding_candidates),
            branch_nodes: BigUint::from(branch_nodes),
            frontier,
            obligations,
        },
        failures,
    ))
}

fn source_rejection(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    value: &ValueRef,
    destination: &SlotContract,
) -> Option<ConnectionFailure> {
    let graph = prepared.graph();
    let mut validator = prepared.validator();
    let projection = effective_projection(prepared, state, value).ok()?;
    if let Some(supplied) = exact_value(prepared, state, value) {
        let ValueDecision::Rejected(destination_failure) =
            validator.accepts_slot(destination, borrowed_slot(&supplied))
        else {
            return None;
        };
        return Some(ConnectionFailure {
            value: Some(value.clone()),
            destination: destination.clone(),
            counterexample: CounterexampleCertificate {
                basis: SemanticBasis::of(graph),
                source: projection.destination,
                destination: destination.clone(),
                value: supplied,
                destination_failure,
            },
        });
    }
    match check_assignable_with_empty(
        &mut validator,
        prepared.empty_refs(),
        &projection.destination,
        destination,
        &prepared.input().bounds,
    ) {
        CompatibilityDecision::Incompatible(counterexample) => Some(ConnectionFailure {
            value: Some(value.clone()),
            destination: destination.clone(),
            counterexample,
        }),
        _ => None,
    }
}

fn resource_rejections(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    requirement: &ResourceRequirement,
) -> Vec<ConnectionFailure> {
    let input = prepared.input();
    let mut failures = Vec::new();
    let mut validator = prepared.validator();
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
        let source = present_contract(declaration.token_type.clone());
        let destination = present_contract(requirement.token_type.clone());
        if let CompatibilityDecision::Incompatible(counterexample) = check_assignable_with_empty(
            &mut validator,
            prepared.empty_refs(),
            &source,
            &destination,
            &input.bounds,
        ) {
            failures.push(ConnectionFailure {
                value: None,
                destination,
                counterexample,
            });
        }
    }
    failures
}

fn collect_plan_certificates(
    closure: &CompositionClosureWitness,
    tree: &PlanTree,
    leading: &mut Vec<TraceStep>,
    certificates: &mut Vec<ResourceTraceCertificate>,
) -> Result<(), CompositionEngineFailure> {
    match &tree.node {
        PlanNode::Return(terminal) => {
            let branch = BranchTrace {
                steps: leading.clone(),
                terminal: terminal.clone(),
            };
            let certificate = closure
                .nodes
                .iter()
                .flat_map(|node| node.terminals.iter())
                .find(|certificate| certificate.trace == branch)
                .ok_or_else(|| {
                    CompositionEngineFailure::ContractViolation(
                        "a plan branch has no resource trace certificate".to_owned(),
                    )
                })?;
            certificates.push(certificate.clone());
        }
        PlanNode::Invoke {
            invocation, arms, ..
        } => {
            for (outcome, child) in arms {
                leading.push(TraceStep::Invocation {
                    invocation: invocation.clone(),
                    outcome: outcome.clone(),
                });
                collect_plan_certificates(closure, child, leading, certificates)?;
                leading.pop();
            }
        }
        PlanNode::Guard {
            guard,
            inspected,
            arms,
        } => {
            for (arm, child) in arms {
                leading.push(TraceStep::Guard {
                    guard: guard.clone(),
                    inspected: inspected.clone(),
                    arm: arm.clone(),
                });
                collect_plan_certificates(closure, child, leading, certificates)?;
                leading.pop();
            }
        }
    }
    Ok(())
}

fn plan_certificates(
    closure: &CompositionClosureWitness,
    tree: &PlanTree,
) -> Result<Vec<ResourceTraceCertificate>, CompositionEngineFailure> {
    let mut certificates = Vec::new();
    collect_plan_certificates(closure, tree, &mut Vec::new(), &mut certificates)?;
    Ok(certificates)
}

fn solved<'p, 'g>(
    prepared: &'p PreparedCompositionInput<'g>,
    candidate: &VerifiedCompositionCandidate<'p, 'g>,
    selection: SelectionEvidence,
) -> Result<CompositionDecision<'p, 'g>, CompositionEngineFailure> {
    let selection = Arc::new(selection);
    let raw = RawComposition {
        plan: candidate.plan().clone(),
        witness: candidate.witness().clone(),
        selection: Arc::clone(&selection),
    };
    let checked = verify_composition(prepared, &raw).map_err(CompositionEngineFailure::Witness)?;
    Ok(CompositionDecision::Solved(checked, selection))
}

fn verified_candidate<'p, 'g>(
    prepared: &'p PreparedCompositionInput<'g>,
    tree: &PlanTree,
    resource_traces: Vec<ResourceTraceCertificate>,
) -> Result<VerifiedCompositionCandidate<'p, 'g>, CompositionEngineFailure> {
    let plan = CompositionPlan {
        input_identity: prepared.input().identity.clone(),
        input_revision: prepared.input().revision.clone(),
        root: tree.clone(),
    };
    let witness = CompositionWitness {
        input_snapshot: prepared.input().clone(),
        initial_membership: initial_membership(prepared)?,
        resource_traces,
    };
    VerifiedCompositionCandidate::verify(prepared, plan, witness)
        .map_err(CompositionEngineFailure::Witness)
}

pub fn derive<'p, 'g>(
    prepared: &'p PreparedCompositionInput<'g>,
) -> Result<CompositionDecision<'p, 'g>, CompositionEngineFailure> {
    let initial_obligations = initial_input_obligations(prepared);
    if !initial_obligations.is_empty() {
        return Ok(CompositionDecision::Incomplete {
            evaluation: classify_unresolved_obligations(
                CompositionProvenance {
                    operation: "derive".into(),
                    input_identity: prepared.input().identity.clone(),
                    input_revision: prepared.input().revision.clone(),
                },
                vec![UnresolvedObligation::Meaning(initial_obligations)],
            )
            .map_err(CompositionEngineFailure::Reasons)?,
            frontier: vec![initial_state(prepared)],
            rejected_connections: Vec::new(),
        });
    }
    let (closure, rejected_connections) = expand_closure(prepared)?;
    let Enumeration {
        values: programs,
        obligations: program_obligations,
        ..
    } = root_programs(prepared, &closure);
    let program_obligations_present = !program_obligations.is_empty();
    let mut candidates: Vec<VerifiedCompositionCandidate<'p, 'g>> = Vec::new();
    let mut keys: Vec<String> = Vec::new();
    for tree in programs {
        let key = canonical_plan_key(prepared, &tree);
        if !keys.contains(&key) {
            let certificates = plan_certificates(&closure, &tree)?;
            candidates.push(verified_candidate(prepared, &tree, certificates)?);
            keys.push(key);
        }
    }
    let policy = prepared
        .input()
        .selection_policy
        .unwrap_or(SelectionPolicy::RequireUnique);
    if policy == SelectionPolicy::RequireUnique && 2 <= candidates.len() {
        return decide_ambiguous(prepared, candidates);
    }
    if policy == SelectionPolicy::AnyFeasible {
        if let Some(candidate) = candidates.first() {
            return solved(prepared, candidate, SelectionEvidence::AnyFeasible);
        }
    }
    let mut obligations = closure.obligations.clone();
    obligations.extend(program_obligations);
    if !closure.frontier.is_empty() {
        obligations.push(UnresolvedObligation::StateBoundExhausted);
    }
    if !obligations.is_empty() {
        if !candidates.is_empty() {
            obligations.push(UnresolvedObligation::UnresolvedUniqueness);
        }
        let frontier = if closure.frontier.is_empty() && program_obligations_present {
            vec![initial_state(prepared)]
        } else {
            closure.frontier
        };
        return Ok(CompositionDecision::Incomplete {
            evaluation: classify_unresolved_obligations(
                CompositionProvenance {
                    operation: "derive".into(),
                    input_identity: prepared.input().identity.clone(),
                    input_revision: prepared.input().revision.clone(),
                },
                obligations,
            )
            .map_err(CompositionEngineFailure::Reasons)?,
            frontier,
            rejected_connections,
        });
    }
    match candidates.first() {
        Some(candidate) => {
            let canonical_plan = canonical_plan_key(prepared, &candidate.plan().root);
            solved(
                prepared,
                candidate,
                SelectionEvidence::Unique {
                    closure: Box::new(closure),
                    canonical_plan,
                },
            )
        }
        None => decide_unreachable(prepared, closure),
    }
}
