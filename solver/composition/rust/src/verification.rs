// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use super::closure::*;
use super::enumeration::*;
use super::lowering::*;
use super::search_state::*;
use necoherence::core::Nat;
use necoherence::resource_witness::{verify_acyclic_witness, verify_reachability_witness};
use necoherence::semantic_composition::*;
use necoherence::semantic_types::*;
use necoherence::typed_mapping as resource;
use num_bigint::BigUint;
use std::sync::Arc;

pub(crate) fn check_return(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    terminal: &ReturnPlan,
) -> Result<bool, WitnessFailure> {
    match terminal {
        ReturnPlan::Success(outputs) => {
            if state.pending_failure.is_some() || outputs.len() != prepared.input.goal.outputs.len()
            {
                return Err(WitnessFailure::GoalMismatch);
            }
            for goal in &prepared.input.goal.outputs {
                let bindings: Vec<_> = outputs.iter().filter(|(id, _)| *id == goal.id).collect();
                let [(_, output_binding)] = bindings.as_slice() else {
                    return Err(WitnessFailure::GoalMismatch);
                };
                check_binding(
                    prepared,
                    state,
                    output_binding,
                    &goal.contract,
                    &goal.source_constraint,
                )?;
            }
            Ok(true)
        }
        ReturnPlan::Failure { embedding, value } => {
            let embedding_contract = prepared
                .input
                .goal
                .failures
                .iter()
                .find(|candidate| candidate.id == *embedding)
                .ok_or_else(|| WitnessFailure::FailureEmbeddingMismatch(embedding.clone()))?;
            if state.pending_failure.as_ref() != Some(&embedding_contract.origin) {
                return Err(WitnessFailure::FailureEmbeddingMismatch(embedding.clone()));
            }
            let mut sources = Vec::new();
            binding_sources(value, &mut sources);
            if !uses_actual_failure(state, &embedding_contract.origin, &sources) {
                return Err(WitnessFailure::FailureEmbeddingMismatch(embedding.clone()));
            }
            check_binding(
                prepared,
                state,
                value,
                &embedding_contract.contract,
                &SourceConstraint::AnyCompatible,
            )?;
            Ok(false)
        }
    }
}

fn evaluated_binding(
    prepared: &PreparedCompositionInput<'_>,
    binding: &BindingExpr,
    values: &[(ProducerRef, SlotValue)],
    destination: &SlotContract,
    fuel: usize,
) -> Result<SlotValue, WitnessFailure> {
    if fuel == 0 {
        return Err(WitnessFailure::ConstructionMismatch(
            destination.type_ref.clone(),
        ));
    }
    match binding {
        BindingExpr::Source { value, .. } => values
            .iter()
            .find(|(producer, _)| producer == &value.producer)
            .map(|(_, source)| project_owned(prepared.graph().profile(), source, &value.path))
            .ok_or_else(|| WitnessFailure::ProducerMismatch(value.clone()))
            .and_then(|value| {
                if matches!(
                    prepared
                        .validator()
                        .accepts_slot(destination, borrowed_slot(&value)),
                    ValueDecision::Accepted
                ) {
                    Ok(value)
                } else {
                    Err(WitnessFailure::MissingEvidence(
                        "model input membership".to_owned(),
                    ))
                }
            }),
        BindingExpr::Product {
            type_ref, fields, ..
        } => {
            let Some(TypeShape::Product(product)) = resolved_shape(prepared.graph(), type_ref)
            else {
                return Err(WitnessFailure::ConstructionMismatch(type_ref.clone()));
            };
            let mut members = Vec::new();
            for (name, binding) in fields {
                let field = product
                    .fields
                    .iter()
                    .find(|field| field.wire_name == *name)
                    .ok_or_else(|| WitnessFailure::ConstructionMismatch(type_ref.clone()))?;
                match evaluated_binding(prepared, binding, values, &field.slot, fuel - 1)? {
                    SlotValue::Absent => {}
                    SlotValue::Null => members.push((name.clone(), JsonValue::Null)),
                    SlotValue::Present(value) => members.push((name.clone(), value)),
                }
            }
            let value = SlotValue::Present(JsonValue::Obj(members));
            if matches!(
                prepared
                    .validator()
                    .accepts_slot(destination, borrowed_slot(&value)),
                ValueDecision::Accepted
            ) {
                Ok(value)
            } else {
                Err(WitnessFailure::ConstructionMismatch(type_ref.clone()))
            }
        }
    }
}

fn verify_value_models(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    values: &[(ProducerRef, SlotValue)],
) -> Result<(), WitnessFailure> {
    if values.len() != state.available.len() {
        return Err(WitnessFailure::MissingEvidence(
            "model producer coverage".to_owned(),
        ));
    }
    for source in &state.available {
        let models: Vec<_> = values
            .iter()
            .filter(|(producer, _)| producer == &source.producer)
            .collect();
        let model = match models.as_slice() {
            [] => {
                return Err(WitnessFailure::ProducerMismatch(ValueRef {
                    producer: source.producer.clone(),
                    path: Vec::new(),
                }))
            }
            [(_, model)] => model,
            _ => {
                return Err(WitnessFailure::MissingEvidence(
                    "duplicated model producer".to_owned(),
                ))
            }
        };
        if !matches!(
            prepared
                .validator()
                .accepts_slot(&source.contract, borrowed_slot(model)),
            ValueDecision::Accepted
        ) {
            return Err(WitnessFailure::MissingEvidence(
                "model producer membership".to_owned(),
            ));
        }
        if let ProducerRef::Initial(id) = &source.producer {
            let initial = prepared
                .input
                .initial_inputs
                .iter()
                .find(|initial| &initial.id == id)
                .ok_or_else(|| WitnessFailure::InitialMembership(id.clone()))?;
            if let InitialSource::SuppliedValue(expected) = &initial.source {
                if expected != model {
                    return Err(WitnessFailure::SuppliedValueMismatch(ValueRef {
                        producer: source.producer.clone(),
                        path: Vec::new(),
                    }));
                }
            }
        }
    }
    let mut current = initial_state(prepared);
    for step in &state.trace {
        match step {
            TraceStep::Guard {
                guard,
                inspected,
                arm,
            } => {
                let declaration = guard_declaration(prepared.input(), guard)
                    .ok_or_else(|| WitnessFailure::GuardNotDominating(inspected.clone()))?;
                let projected = effective_projection(prepared, &current, inspected)?;
                let value = values
                    .iter()
                    .find(|(producer, _)| producer == &inspected.producer)
                    .map(|(_, value)| {
                        project_owned(prepared.graph().profile(), value, &inspected.path)
                    })
                    .ok_or_else(|| WitnessFailure::ProducerMismatch(inspected.clone()))?;
                let actual = evaluate_guard_arm(
                    prepared.graph(),
                    declaration,
                    &projected.destination,
                    borrowed_slot(&value),
                )?;
                if actual != *arm {
                    return Err(WitnessFailure::GuardNotDominating(inspected.clone()));
                }
                current = after_guard(prepared, &current, declaration, inspected, arm)?;
            }
            TraceStep::Invocation {
                invocation,
                outcome,
            } => {
                check_invocation(prepared, &current, invocation)?;
                let function = site_signature(prepared.input(), &invocation.site)
                    .ok_or_else(|| WitnessFailure::SignatureMismatch(invocation.site.clone()))?;
                for port in &function.inputs {
                    let binding = invocation
                        .bindings
                        .iter()
                        .find(|(id, _)| *id == port.id)
                        .ok_or_else(|| WitnessFailure::MissingBinding(port.id.0.clone()))?;
                    evaluated_binding(
                        prepared,
                        &binding.1,
                        values,
                        &port.contract,
                        prepared
                            .input
                            .invocation_domain
                            .permitted_constructions
                            .len()
                            + 2,
                    )?;
                }
                let selected = function
                    .outcomes
                    .iter()
                    .find(|candidate| candidate.id == *outcome)
                    .ok_or_else(|| WitnessFailure::IncompleteBranchCoverage(outcome.0.clone()))?;
                current = after_invocation(&current, invocation, selected);
            }
        }
    }
    if current != *state {
        return Err(WitnessFailure::MissingEvidence(
            "model branch state".to_owned(),
        ));
    }
    Ok(())
}

fn verify_return_values(
    prepared: &PreparedCompositionInput<'_>,
    terminal: &ReturnPlan,
    values: &[(ProducerRef, SlotValue)],
) -> Result<(), WitnessFailure> {
    match terminal {
        ReturnPlan::Success(outputs) => {
            for goal in &prepared.input.goal.outputs {
                let binding = outputs
                    .iter()
                    .find(|(id, _)| *id == goal.id)
                    .ok_or(WitnessFailure::GoalMismatch)?;
                evaluated_binding(
                    prepared,
                    &binding.1,
                    values,
                    &goal.contract,
                    prepared
                        .input
                        .invocation_domain
                        .permitted_constructions
                        .len()
                        + 2,
                )?;
            }
        }
        ReturnPlan::Failure { embedding, value } => {
            let embedding = prepared
                .input
                .goal
                .failures
                .iter()
                .find(|candidate| candidate.id == *embedding)
                .ok_or_else(|| WitnessFailure::FailureEmbeddingMismatch(embedding.clone()))?;
            evaluated_binding(
                prepared,
                value,
                values,
                &embedding.contract,
                prepared
                    .input
                    .invocation_domain
                    .permitted_constructions
                    .len()
                    + 2,
            )?;
        }
    }
    Ok(())
}

pub fn verify_terminal_values(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    terminal: &ReturnPlan,
    values: &[(ProducerRef, SlotValue)],
) -> Result<(), WitnessFailure> {
    check_return(prepared, state, terminal)?;
    verify_value_models(prepared, state, values)?;
    verify_return_values(prepared, terminal, values)
}

fn trace_state(
    prepared: &PreparedCompositionInput<'_>,
    steps: &[TraceStep],
) -> Result<SearchState, WitnessFailure> {
    let mut state = initial_state(prepared);
    for step in steps {
        state = match step {
            TraceStep::Invocation {
                invocation,
                outcome,
            } => {
                check_invocation(prepared, &state, invocation)?;
                let function = site_signature(prepared.input(), &invocation.site)
                    .ok_or_else(|| WitnessFailure::SignatureMismatch(invocation.site.clone()))?;
                let declared = function
                    .outcomes
                    .iter()
                    .find(|candidate| candidate.id == *outcome)
                    .ok_or_else(|| WitnessFailure::IncompleteBranchCoverage(outcome.0.clone()))?;
                after_invocation(&state, invocation, declared)
            }
            TraceStep::Guard {
                guard,
                inspected,
                arm,
            } => {
                let declaration = guard_declaration(prepared.input(), guard)
                    .ok_or_else(|| WitnessFailure::GuardNotDominating(inspected.clone()))?;
                if !guard_arms(prepared, &state, declaration, inspected)?.contains(arm) {
                    return Err(WitnessFailure::IncompleteBranchCoverage(guard.0.clone()));
                }
                after_guard(prepared, &state, declaration, inspected, arm)?
            }
        };
    }
    Ok(state)
}

fn verify_resource_trace(
    prepared: &PreparedCompositionInput<'_>,
    trace: &BranchTrace,
    certificate: &ResourceTraceCertificate,
) -> Result<(), WitnessFailure> {
    if certificate.trace != *trace {
        return Err(WitnessFailure::ResourceLoweringMismatch(
            "branch trace".to_owned(),
        ));
    }
    let state = trace_state(prepared, &trace.steps)?;
    verify_terminal_values(
        prepared,
        &state,
        &trace.terminal,
        &certificate.value_sources,
    )?;
    let (lowering, correspondence) = lower_resource_trace(prepared, trace)
        .map_err(|_| WitnessFailure::ResourceLoweringMismatch("selected resources".to_owned()))?;
    if certificate.lowering != lowering || certificate.correspondence != correspondence {
        return Err(WitnessFailure::ResourceLoweringMismatch(
            "resource input or correspondence".to_owned(),
        ));
    }
    if certificate.reachability.path != correspondence.execution_order {
        return Err(WitnessFailure::ResourceLoweringMismatch(
            "prescribed resource order".to_owned(),
        ));
    }
    verify_reachability_witness(&lowering, &certificate.reachability)?;
    verify_acyclic_witness(&lowering, &certificate.acyclicity)?;
    Ok(())
}

fn program_keys(prepared: &PreparedCompositionInput<'_>, programs: &[PlanTree]) -> Vec<String> {
    distinct(
        programs
            .iter()
            .map(|tree| canonical_plan_key(prepared, tree)),
    )
}

pub struct VerifiedCompositionCandidate<'p, 'g> {
    prepared: &'p PreparedCompositionInput<'g>,
    plan: CompositionPlan,
    witness: CompositionWitness,
}

impl<'p, 'g> VerifiedCompositionCandidate<'p, 'g> {
    pub fn verify(
        prepared: &'p PreparedCompositionInput<'g>,
        plan: CompositionPlan,
        witness: CompositionWitness,
    ) -> Result<Self, WitnessFailure> {
        check_candidate(prepared, &plan, &witness)?;
        Ok(Self {
            prepared,
            plan,
            witness,
        })
    }
    pub fn prepared(&self) -> &'p PreparedCompositionInput<'g> {
        self.prepared
    }
    pub fn plan(&self) -> &CompositionPlan {
        &self.plan
    }
    pub fn witness(&self) -> &CompositionWitness {
        &self.witness
    }
}

#[derive(Debug)]
pub struct CheckedCompositionClosure<'a> {
    witness: &'a CompositionClosureWitness,
    canonical_plans: Vec<String>,
}

impl CheckedCompositionClosure<'_> {
    pub fn witness(&self) -> &CompositionClosureWitness {
        self.witness
    }
    pub fn canonical_plans(&self) -> &[String] {
        &self.canonical_plans
    }
    pub fn goal_unreachable(&self) -> bool {
        self.canonical_plans.is_empty()
    }
}

fn verify_local_node(
    prepared: &PreparedCompositionInput<'_>,
    node: &CompositionClosureNode,
) -> Result<(), WitnessFailure> {
    let invocations = enumerate_invocations(prepared, &node.state);
    let guards = enumerate_guards(prepared, &node.state);
    let returns = enumerate_returns(prepared, &node.state);
    if !invocations.obligations.is_empty()
        || !guards.obligations.is_empty()
        || !returns.obligations.is_empty()
    {
        return Err(WitnessFailure::ForgedClosure(
            "unresolved local meaning or binding obligations".to_owned(),
        ));
    }
    let expected_actions = invocations
        .values
        .into_iter()
        .chain(guards.values)
        .collect::<Vec<_>>();
    if node.actions != expected_actions {
        return Err(WitnessFailure::ForgedClosure(
            "typed invocation or guard successor coverage".to_owned(),
        ));
    }
    let mut expected_terminals = Vec::new();
    for terminal in returns.values {
        let trace = BranchTrace {
            steps: node.state.trace.clone(),
            terminal,
        };
        let Ok((lowering, correspondence)) = lower_resource_trace(prepared, &trace) else {
            return Err(WitnessFailure::ForgedClosure(
                "unresolved terminal resource lowering".to_owned(),
            ));
        };
        if lowering.bound.max_bindings < resource::candidate_binding_count(&lowering)
            || lowering.bound.max_search_steps < Nat::from(correspondence.execution_order.len())
        {
            return Err(WitnessFailure::ForgedClosure(
                "terminal resource bound".to_owned(),
            ));
        }
        if resource::path_replay(
            &lowering,
            &lowering.marking,
            &correspondence.execution_order,
        )
        .is_some_and(|marking| resource::eval_goal(&marking, &lowering.goal))
        {
            expected_terminals.push(trace.terminal);
        }
    }
    if node
        .terminals
        .iter()
        .map(|certificate| &certificate.trace.terminal)
        .ne(expected_terminals.iter())
    {
        return Err(WitnessFailure::ForgedClosure(
            "terminal alternatives omitted or added".to_owned(),
        ));
    }
    for certificate in &node.terminals {
        let trace = BranchTrace {
            steps: node.state.trace.clone(),
            terminal: certificate.trace.terminal.clone(),
        };
        verify_resource_trace(prepared, &trace, certificate)?;
    }
    Ok(())
}

pub fn verify_composition_closure<'a>(
    prepared: &PreparedCompositionInput<'_>,
    witness: &'a CompositionClosureWitness,
) -> Result<CheckedCompositionClosure<'a>, WitnessFailure> {
    if witness.input_identity != prepared.input.identity
        || witness.input_revision != prepared.input.revision
    {
        return Err(WitnessFailure::InputRevisionMismatch);
    }
    if witness.steps != BigUint::from(witness.nodes.len().saturating_sub(1))
        || prepared.input.bounds.max_expanded_states < witness.steps
        || prepared.input.bounds.max_binding_candidates < witness.binding_candidates
        || prepared.input.bounds.max_branch_nodes < witness.branch_nodes
    {
        return Err(WitnessFailure::ForgedClosure(
            "composition bounds".to_owned(),
        ));
    }
    let actual_binding_candidates = witness
        .nodes
        .iter()
        .map(|node| closure_binding_candidates(prepared, &node.state))
        .sum::<usize>();
    let mut actual_branch_nodes = 0usize;
    for node in &witness.nodes {
        actual_branch_nodes += closure_branch_count(prepared, &node.state, &node.actions)?;
    }
    if witness.binding_candidates != BigUint::from(actual_binding_candidates)
        || witness.branch_nodes != BigUint::from(actual_branch_nodes)
    {
        return Err(WitnessFailure::ForgedClosure(
            "local binding or branch counts".to_owned(),
        ));
    }
    if !witness.frontier.is_empty() {
        return Err(WitnessFailure::ForgedClosure(
            "unexplored composition frontier".to_owned(),
        ));
    }
    if !witness.obligations.is_empty() {
        return Err(WitnessFailure::ForgedClosure(
            "unresolved composition obligations".to_owned(),
        ));
    }
    if !witness
        .nodes
        .iter()
        .any(|node| node.state == initial_state(prepared))
    {
        return Err(WitnessFailure::ForgedClosure(
            "initial composition state omitted".to_owned(),
        ));
    }
    for node in &witness.nodes {
        verify_local_node(prepared, node)?;
    }
    for node in &witness.nodes {
        for action in &node.actions {
            for (_, next) in action_successors(prepared, &node.state, action)? {
                if !witness.nodes.iter().any(|node| node.state == next) {
                    return Err(WitnessFailure::ForgedClosure(
                        "typed successor state omitted".to_owned(),
                    ));
                }
            }
        }
    }
    let programs = root_programs(prepared, witness);
    if !programs.obligations.is_empty() {
        return Err(WitnessFailure::ForgedClosure(
            "unresolved finite program frontier".to_owned(),
        ));
    }
    let canonical_plans = program_keys(prepared, &programs.values);
    Ok(CheckedCompositionClosure {
        witness,
        canonical_plans,
    })
}

#[derive(Debug)]
pub struct CheckedUnreachable {
    witness: CompositionClosureWitness,
}

impl CheckedUnreachable {
    pub fn witness(&self) -> &CompositionClosureWitness {
        &self.witness
    }
}

pub fn verify_unreachable_composition(
    prepared: &PreparedCompositionInput<'_>,
    witness: CompositionClosureWitness,
) -> Result<CheckedUnreachable, WitnessFailure> {
    if !verify_composition_closure(prepared, &witness)?.goal_unreachable() {
        return Err(WitnessFailure::ForgedClosure(
            "closed domain contains a complete success plan".to_owned(),
        ));
    }
    Ok(CheckedUnreachable { witness })
}

fn verify_initial_membership(
    prepared: &PreparedCompositionInput<'_>,
    witness: &CompositionWitness,
) -> Result<(), WitnessFailure> {
    if witness.input_snapshot != *prepared.input() {
        return Err(WitnessFailure::InputRevisionMismatch);
    }
    if witness.initial_membership.len() != prepared.input.initial_inputs.len() {
        return Err(WitnessFailure::MissingEvidence(
            "initial member coverage".to_owned(),
        ));
    }
    for initial in &prepared.input.initial_inputs {
        let values: Vec<_> = witness
            .initial_membership
            .iter()
            .filter(|(id, _)| *id == initial.id)
            .collect();
        let value = match values.as_slice() {
            [(_, value)]
                if matches!(
                    prepared
                        .validator()
                        .accepts_slot(&initial.contract, borrowed_slot(value)),
                    ValueDecision::Accepted
                ) =>
            {
                value
            }
            _ => return Err(WitnessFailure::InitialMembership(initial.id.clone())),
        };
        if let InitialSource::SuppliedValue(supplied) = &initial.source {
            if supplied != value {
                return Err(WitnessFailure::InitialMembership(initial.id.clone()));
            }
        }
    }
    Ok(())
}

pub(crate) fn verify_plan_tree(
    prepared: &PreparedCompositionInput<'_>,
    fuel: usize,
    state: &SearchState,
    tree: &PlanTree,
) -> Result<(), WitnessFailure> {
    let Some(fuel) = fuel.checked_sub(1) else {
        return Err(WitnessFailure::RankViolation);
    };
    match &tree.node {
        PlanNode::Return(terminal) => {
            check_return(prepared, state, terminal)?;
            Ok(())
        }
        PlanNode::Invoke {
            invocation,
            arms,
            empty_outcomes,
        } => {
            check_invocation(prepared, state, invocation)?;
            let function = site_signature(prepared.input(), &invocation.site)
                .ok_or_else(|| WitnessFailure::SignatureMismatch(invocation.site.clone()))?;
            let arm_ids: Vec<&OutcomeId> = arms.iter().map(|(id, _)| id).collect();
            let empty_partition = no_duplicates(empty_outcomes)
                && function.outcomes.iter().all(|outcome| {
                    empty_outcomes.contains(&outcome.id) == outcome_empty(prepared, outcome)
                })
                && empty_outcomes.iter().all(|id| {
                    function.outcomes.iter().any(|outcome| outcome.id == *id)
                        && !arm_ids.contains(&id)
                });
            if !empty_partition
                || !no_duplicates(&arm_ids)
                || !function.outcomes.iter().all(|outcome| {
                    empty_outcomes.contains(&outcome.id) || arm_ids.contains(&&outcome.id)
                })
            {
                return Err(WitnessFailure::IncompleteBranchCoverage(
                    invocation.site.0.clone(),
                ));
            }
            for (id, child) in arms {
                let outcome = function
                    .outcomes
                    .iter()
                    .find(|candidate| candidate.id == *id)
                    .ok_or_else(|| WitnessFailure::IncompleteBranchCoverage(id.0.clone()))?;
                if tree.rank >= child.rank {
                    return Err(WitnessFailure::RankViolation);
                }
                verify_plan_tree(
                    prepared,
                    fuel,
                    &after_invocation(state, invocation, outcome),
                    child,
                )?;
            }
            Ok(())
        }
        PlanNode::Guard {
            guard,
            inspected,
            arms,
        } => {
            let declaration = guard_declaration(prepared.input(), guard)
                .ok_or_else(|| WitnessFailure::GuardNotDominating(inspected.clone()))?;
            let partition = guard_arms(prepared, state, declaration, inspected)?;
            let arm_ids: Vec<&GuardArm> = arms.iter().map(|(arm, _)| arm).collect();
            if !no_duplicates(&arm_ids) || !partition.iter().all(|arm| arm_ids.contains(&arm)) {
                return Err(WitnessFailure::IncompleteBranchCoverage(guard.0.clone()));
            }
            for (arm, child) in arms {
                if !partition.contains(arm) {
                    return Err(WitnessFailure::IncompleteBranchCoverage(guard.0.clone()));
                }
                let next = after_guard(prepared, state, declaration, inspected, arm)?;
                if tree.rank >= child.rank {
                    return Err(WitnessFailure::RankViolation);
                }
                verify_plan_tree(prepared, fuel, &next, child)?;
            }
            Ok(())
        }
    }
}

fn plan_branches(leading: &[TraceStep], tree: &PlanTree) -> Vec<BranchTrace> {
    match &tree.node {
        PlanNode::Return(terminal) => vec![BranchTrace {
            steps: leading.to_vec(),
            terminal: terminal.clone(),
        }],
        PlanNode::Invoke {
            invocation, arms, ..
        } => invocation_branches(leading, invocation, arms),
        PlanNode::Guard {
            guard,
            inspected,
            arms,
        } => guard_branches(leading, guard, inspected, arms),
    }
}

fn invocation_branches(
    leading: &[TraceStep],
    invocation: &InvocationPlan,
    arms: &[(OutcomeId, PlanTree)],
) -> Vec<BranchTrace> {
    arms.iter()
        .flat_map(|(outcome, child)| {
            let mut steps = leading.to_vec();
            steps.push(TraceStep::Invocation {
                invocation: invocation.clone(),
                outcome: outcome.clone(),
            });
            plan_branches(&steps, child)
        })
        .collect()
}

fn guard_branches(
    leading: &[TraceStep],
    guard: &GuardId,
    inspected: &ValueRef,
    arms: &[(GuardArm, PlanTree)],
) -> Vec<BranchTrace> {
    arms.iter()
        .flat_map(|(arm, child)| {
            let mut steps = leading.to_vec();
            steps.push(TraceStep::Guard {
                guard: guard.clone(),
                inspected: inspected.clone(),
                arm: arm.clone(),
            });
            plan_branches(&steps, child)
        })
        .collect()
}

pub(crate) fn initial_input_obligations(
    prepared: &PreparedCompositionInput<'_>,
) -> Vec<SemanticObligation> {
    let mut obligations = Vec::new();
    let mut validator = prepared.validator();
    for initial in &prepared.input().initial_inputs {
        obligations.extend(
            validator.meaning_obligations(std::slice::from_ref(&initial.contract.type_ref)),
        );
        if let InitialSource::SuppliedValue(value) = &initial.source {
            if let ValueDecision::Unresolved(unresolved) =
                validator.accepts_slot(&initial.contract, borrowed_slot(value))
            {
                obligations.extend(unresolved);
            }
        }
    }
    obligations
}

fn check_candidate(
    prepared: &PreparedCompositionInput<'_>,
    plan: &CompositionPlan,
    witness: &CompositionWitness,
) -> Result<(), WitnessFailure> {
    let initial_obligations = initial_input_obligations(prepared);
    if !initial_obligations.is_empty() {
        return Err(WitnessFailure::Inclusion(
            InclusionFailure::UndefinedMeaning(initial_obligations),
        ));
    }
    if plan.input_identity != prepared.input.identity
        || plan.input_revision != prepared.input.revision
    {
        return Err(WitnessFailure::InputRevisionMismatch);
    }
    verify_initial_membership(prepared, witness)?;
    let max = prepared.input.bounds.branch_node_limit();
    if max < tree_node_count(&plan.root) {
        return Err(WitnessFailure::RankViolation);
    }
    verify_plan_tree(prepared, max, &initial_state(prepared), &plan.root)?;
    let branches = plan_branches(&[], &plan.root);
    if branches.len() != witness.resource_traces.len() {
        return Err(WitnessFailure::MissingEvidence(
            "branch resource coverage".to_owned(),
        ));
    }
    for branch in &branches {
        let certificates: Vec<_> = witness
            .resource_traces
            .iter()
            .filter(|certificate| certificate.trace == *branch)
            .collect();
        match certificates.as_slice() {
            [] => {
                return Err(WitnessFailure::MissingEvidence(
                    "branch resource trace".to_owned(),
                ))
            }
            [certificate] => verify_resource_trace(prepared, branch, certificate)?,
            _ => {
                return Err(WitnessFailure::MissingEvidence(
                    "duplicated branch resource trace".to_owned(),
                ))
            }
        }
    }
    if !branches
        .iter()
        .any(|branch| matches!(branch.terminal, ReturnPlan::Success(_)))
    {
        return Err(WitnessFailure::GoalMismatch);
    }
    Ok(())
}

pub fn verify_composition<'g>(
    prepared: &PreparedCompositionInput<'g>,
    raw: &RawComposition,
) -> Result<CheckedComposition<'g>, WitnessFailure> {
    check_candidate(prepared, &raw.plan, &raw.witness)?;
    let key = canonical_plan_key(prepared, &raw.plan.root);
    match raw.selection.as_ref() {
        SelectionEvidence::AnyFeasible => {
            if prepared.input.selection_policy != Some(SelectionPolicy::AnyFeasible) {
                return Err(WitnessFailure::MissingEvidence(
                    "AnyFeasible policy must be explicit".to_owned(),
                ));
            }
        }
        SelectionEvidence::Unique {
            closure,
            canonical_plan,
        } => {
            if prepared.input.selection_policy == Some(SelectionPolicy::AnyFeasible) {
                return Err(WitnessFailure::MissingEvidence(
                    "unique evidence does not select the requested policy".to_owned(),
                ));
            }
            let checked = verify_composition_closure(prepared, closure)?;
            if checked.canonical_plans.as_slice() != std::slice::from_ref(canonical_plan) {
                return Err(WitnessFailure::MissingEvidence(
                    "closed domain does not have one canonical program".to_owned(),
                ));
            }
            if *canonical_plan != key {
                return Err(WitnessFailure::MissingEvidence(
                    "selected program differs from canonical unique program".to_owned(),
                ));
            }
        }
    }
    Ok(CheckedComposition {
        prepared: prepared.clone(),
        raw: raw.clone(),
    })
}
#[derive(Debug, Clone, PartialEq)]
pub struct RawComposition {
    pub plan: CompositionPlan,
    pub witness: CompositionWitness,
    pub selection: Arc<SelectionEvidence>,
}
pub struct CheckedComposition<'g> {
    pub(crate) prepared: PreparedCompositionInput<'g>,
    pub(crate) raw: RawComposition,
}
impl<'g> CheckedComposition<'g> {
    pub fn prepared(&self) -> &PreparedCompositionInput<'g> {
        &self.prepared
    }
    pub fn plan(&self) -> &CompositionPlan {
        &self.raw.plan
    }
    pub fn witness(&self) -> &CompositionWitness {
        &self.raw.witness
    }
    pub fn raw(&self) -> &RawComposition {
        &self.raw
    }
}
#[derive(Debug, Clone, PartialEq)]
pub enum TraceStep {
    Invocation {
        invocation: InvocationPlan,
        outcome: OutcomeId,
    },
    Guard {
        guard: GuardId,
        inspected: ValueRef,
        arm: GuardArm,
    },
}
#[derive(Debug, Clone, PartialEq)]
pub struct BranchTrace {
    pub steps: Vec<TraceStep>,
    pub terminal: ReturnPlan,
}
#[derive(Debug, Clone, PartialEq)]
pub struct ResourceTraceCertificate {
    pub trace: BranchTrace,
    pub lowering: resource::SolverInput,
    pub correspondence: ResourceCorrespondence,
    pub reachability: resource::ReachabilityWitness,
    pub acyclicity: resource::AcyclicWitness,
    pub value_sources: Vec<(ProducerRef, SlotValue)>,
}
#[derive(Debug, Clone, PartialEq)]
pub struct CompositionWitness {
    pub input_snapshot: CompositionInput,
    pub initial_membership: Vec<(InputId, SlotValue)>,
    pub resource_traces: Vec<ResourceTraceCertificate>,
}
#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tree_check_tests {
    use super::*;
    use necoherence::semantic_types::{
        IntegerDomain, IntegerDomainBinding, IntegerForm, NumberModel, ProfileRef,
    };
    use necoherence::signature_admission::{check_type_signatures, signature_type_ref};
    use necoherence::type_signatures::{
        Shape, SignatureUnion, TypeNodeInput, TypeSignatureLibrary, ValueSemanticProfile,
    };
    use num_bigint::BigInt;
    use num_traits::{One, Zero};

    fn empty_union_library() -> TypeSignatureLibrary {
        let reference = ProfileRef {
            identity: "execution-profile".into(),
            revision: "1".into(),
            content_digest: "a".repeat(64),
        };
        TypeSignatureLibrary {
            schema: "ncoh-type-signatures@1".into(),
            identity: "guard-library".into(),
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
            nodes: vec![TypeNodeInput {
                id: "empty".into(),
                shape: Shape::TaggedUnion(SignatureUnion {
                    branches: Vec::new(),
                }),
            }],
            definitions: vec![],
        }
    }

    fn union_problem(
        graph: &SemanticGraph,
        contract: &SlotContract,
        guards: Vec<DeclaredGuard>,
        max_branch_nodes: usize,
    ) -> CompositionInput {
        CompositionInput {
            identity: "tree-check".into(),
            revision: "1".into(),
            basis: SemanticBasis::of(graph),
            signatures: vec![],
            initial_inputs: vec![InitialInput {
                id: InputId("input".into()),
                contract: contract.clone(),
                source: InitialSource::Argument,
                resource: None,
            }],
            initial_resources: vec![],
            goal: GoalSpec {
                outputs: vec![GoalPort {
                    id: GoalPortId("result".into()),
                    contract: contract.clone(),
                    source_constraint: SourceConstraint::InitialOnly {
                        input: InputId("input".into()),
                        path: vec![],
                    },
                }],
                failures: vec![],
                final_resources: vec![],
            },
            invocation_domain: InvocationDomain {
                identity: "tree-check-domain".into(),
                revision: "1".into(),
                sites: vec![],
                permitted_projections: vec![],
                permitted_constructions: vec![],
                permitted_transforms: vec![],
                guards,
            },
            allowed_effects: vec![],
            explicit_order: vec![],
            selection_policy: Some(SelectionPolicy::AnyFeasible),
            bounds: SearchBounds {
                max_branch_nodes: BigUint::from(max_branch_nodes),
                ..SearchBounds::default()
            },
        }
    }

    #[test]
    fn guard_without_arms_is_accepted_by_the_tree_check_like_lean() {
        let library = empty_union_library();
        let graph = check_type_signatures(&library).unwrap();
        let contract = SlotContract {
            type_ref: signature_type_ref("empty"),
            required: true,
            nullable: false,
        };
        let guard = GuardId("variants".into());
        let input = union_problem(
            &graph,
            &contract,
            vec![DeclaredGuard {
                id: guard.clone(),
                source_type: contract.type_ref.clone(),
                path: vec![],
                kind: GuardKind::Variants,
            }],
            SearchBounds::default().branch_node_limit(),
        );
        let prepared = prepare_direct_composition(
            &graph,
            input,
            operation_checker_without_library(),
            operation_meaning_of(&graph),
        )
        .unwrap();
        let state = initial_state(&prepared);
        let tree = PlanTree {
            rank: BigUint::zero(),
            node: PlanNode::Guard {
                guard,
                inspected: ValueRef {
                    producer: ProducerRef::Initial(InputId("input".into())),
                    path: vec![],
                },
                arms: vec![],
            },
        };
        assert_eq!(verify_plan_tree(&prepared, 1, &state, &tree), Ok(()));
    }

    #[test]
    fn plan_larger_than_the_branch_bound_is_a_rank_violation_before_the_walk() {
        let library = empty_union_library();
        let graph = check_type_signatures(&library).unwrap();
        let contract = SlotContract {
            type_ref: signature_type_ref("empty"),
            required: true,
            nullable: true,
        };
        let input = union_problem(&graph, &contract, vec![], 2);
        let prepared = prepare_direct_composition(
            &graph,
            input.clone(),
            operation_checker_without_library(),
            operation_meaning_of(&graph),
        )
        .unwrap();
        let leaf = PlanTree {
            rank: BigUint::one(),
            node: PlanNode::Return(ReturnPlan::Success(vec![])),
        };
        let root = PlanTree {
            rank: BigUint::zero(),
            node: PlanNode::Invoke {
                invocation: InvocationPlan {
                    site: SiteId("missing".into()),
                    function: FunctionRef {
                        identity: "missing".into(),
                        revision: "1".into(),
                        content_digest: "b".repeat(64),
                    },
                    bindings: vec![],
                    resources: vec![],
                },
                arms: vec![
                    (OutcomeId("success".into()), leaf.clone()),
                    (OutcomeId("failure".into()), leaf),
                ],
                empty_outcomes: vec![],
            },
        };
        let raw = RawComposition {
            plan: CompositionPlan {
                input_identity: input.identity.clone(),
                input_revision: input.revision.clone(),
                root,
            },
            witness: CompositionWitness {
                input_snapshot: input,
                initial_membership: vec![(InputId("input".into()), SlotValue::Null)],
                resource_traces: vec![],
            },
            selection: Arc::new(SelectionEvidence::AnyFeasible),
        };
        assert_eq!(
            verify_composition(&prepared, &raw).err(),
            Some(WitnessFailure::RankViolation)
        );
    }
}
