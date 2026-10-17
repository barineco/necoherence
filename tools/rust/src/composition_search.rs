// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use std::collections::HashSet;
use std::sync::Arc;

use necoherence::semantic_codegen_runtime::with_member;
use necoherence::semantic_composition::*;
use necoherence::semantic_types::ValueDecision;
use necoherence::semantic_types::*;
use necoherence::semantic_validation as validation;
use necoherence::typed_mapping as resource;

pub fn assess_terminal(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    terminal: &ReturnPlan,
) -> Result<TerminalAssessment, CompositionEngineFailure> {
    check_return(prepared, state, terminal).map_err(CompositionEngineFailure::Witness)?;
    let empty: Vec<_> = state
        .available
        .iter()
        .filter(|source| slot_empty(&source.contract, prepared.empty()))
        .map(|source| source.producer.clone())
        .collect();
    if !empty.is_empty() {
        return Ok(TerminalAssessment::EmptyValues(empty));
    }
    let models = match derive_value_models(prepared, state) {
        Ok(models) => models,
        Err(reason) => return Ok(TerminalAssessment::Unknown(vec![reason])),
    };
    if verify_return_values(prepared, terminal, &models).is_err() {
        return Ok(TerminalAssessment::Unknown(vec![
            UnresolvedObligation::BranchInhabitation,
        ]));
    }
    let trace = BranchTrace {
        steps: state.trace.clone(),
        terminal: terminal.clone(),
    };
    let (lowering, correspondence) = match lower_resource_trace(prepared, &trace) {
        Ok(lowering) => lowering,
        Err(LoweringFailure::Unknown(reason)) => {
            return Ok(TerminalAssessment::Unknown(vec![reason]))
        }
        Err(LoweringFailure::Invalid(reason)) => {
            return Ok(TerminalAssessment::RejectedLowering { trace, reason })
        }
    };
    if let Err(reason) = resource_trace_meaning(prepared, &correspondence) {
        return Ok(TerminalAssessment::Unknown(vec![reason]));
    }
    match crate::typed_mapping_solver::check_reachability(&lowering)
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
            match crate::typed_mapping_solver::check_well_foundedness(&lowering)
                .map_err(CompositionEngineFailure::Resource)?
            {
                resource::WellFoundednessResult::WellFounded(acyclicity) => {
                    verify_acyclic_witness(&lowering, &acyclicity)
                        .map_err(CompositionEngineFailure::Witness)?;
                    Ok(TerminalAssessment::Feasible(ResourceTraceCertificate {
                        trace,
                        lowering,
                        correspondence,
                        reachability,
                        acyclicity,
                        value_sources: models,
                    }))
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
fn replace_projected(
    value: &SlotValue,
    path: &[PathStep],
    replacement: &SlotValue,
) -> Option<SlotValue> {
    if path.is_empty() {
        return Some(replacement.clone());
    }
    let SlotValue::Present(root) = value else {
        return None;
    };
    fn replace(root: &JsonValue, path: &[PathStep], replacement: &SlotValue) -> Option<JsonValue> {
        let (step, rest) = path.split_first()?;
        match (root, step) {
            (JsonValue::Obj(members), PathStep::Field(name)) => {
                let mut members = members.clone();
                let index = members.iter().position(|(field, _)| field == name);
                let replacement = if rest.is_empty() {
                    replacement.clone()
                } else {
                    SlotValue::Present(replace(
                        index
                            .and_then(|index| members.get(index))
                            .map(|(_, value)| value)?,
                        rest,
                        replacement,
                    )?)
                };
                match replacement {
                    SlotValue::Absent => {
                        if let Some(index) = index {
                            members.remove(index);
                        }
                    }
                    SlotValue::Null => match index.and_then(|index| members.get_mut(index)) {
                        Some(member) => member.1 = JsonValue::Null,
                        None => members.push((name.clone(), JsonValue::Null)),
                    },
                    SlotValue::Present(value) => {
                        match index.and_then(|index| members.get_mut(index)) {
                            Some(member) => member.1 = value,
                            None => members.push((name.clone(), value)),
                        }
                    }
                }
                Some(JsonValue::Obj(members))
            }
            (JsonValue::Arr(items), PathStep::Index(index)) => {
                let index = usize::try_from(index).ok()?;
                let mut items = items.clone();
                let value = items.get(index)?;
                let replacement = if rest.is_empty() {
                    match replacement {
                        SlotValue::Absent => return None,
                        SlotValue::Null => JsonValue::Null,
                        SlotValue::Present(value) => value.clone(),
                    }
                } else {
                    replace(value, rest, replacement)?
                };
                *items.get_mut(index)? = replacement;
                Some(JsonValue::Arr(items))
            }
            (JsonValue::Obj(_), PathStep::Variant(_)) => {
                if rest.is_empty() {
                    match replacement {
                        SlotValue::Present(value) => Some(value.clone()),
                        _ => None,
                    }
                } else {
                    replace(root, rest, replacement)
                }
            }
            _ => None,
        }
    }
    replace(root, path, replacement).map(SlotValue::Present)
}
fn producer_model(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    source: &AvailableValue,
) -> Option<SlotValue> {
    let facts = state
        .facts
        .iter()
        .filter(|fact| fact.inspected.producer == source.producer)
        .collect::<Vec<_>>();
    let fixed = match &source.producer {
        ProducerRef::Initial(id) => prepared
            .input()
            .initial_inputs
            .iter()
            .find(|initial| initial.id == *id)
            .and_then(|initial| match &initial.source {
                InitialSource::SuppliedValue(value) => Some(value.clone()),
                _ => None,
            }),
        _ => None,
    };
    let mut replacements = Vec::new();
    let limit = prepared.input().bounds.max_type_obligations;
    if let Some(value) = fixed {
        if !matches!(
            validation::accepts_slot(prepared.graph(), &source.contract, borrowed_slot(&value)),
            ValueDecision::Accepted
        ) {
            return None;
        }
        return satisfy_branch_facts(
            prepared,
            state,
            source,
            &facts,
            0,
            &value,
            false,
            &mut replacements,
            limit,
        );
    }
    let mut answer = None;
    find_accepted_slot_candidate(
        prepared.graph(),
        &prepared.input().bounds,
        &source.contract,
        |candidate, _within_bound| {
            if let Some(value) = satisfy_branch_facts(
                prepared,
                state,
                source,
                &facts,
                0,
                candidate,
                true,
                &mut replacements,
                limit,
            ) {
                answer = Some(value);
                SlotCandidateControl::Accept
            } else if replacements.len() >= limit {
                SlotCandidateControl::StopNoEvidence
            } else {
                SlotCandidateControl::Continue
            }
        },
    );
    answer
}

fn branch_facts_hold(
    prepared: &PreparedCompositionInput<'_>,
    facts: &[&BranchFact],
    count: usize,
    value: &SlotValue,
) -> bool {
    facts.iter().take(count).all(|fact| {
        let Some(guard) = guard_declaration(prepared.input(), &fact.guard) else {
            return false;
        };
        let inspected = project_owned(value, &fact.inspected.path, &());
        evaluate_guard_arm(prepared.graph(), guard, borrowed_slot(&inspected))
            .ok()
            .as_ref()
            == Some(&fact.arm)
    })
}
#[allow(clippy::too_many_arguments)]
fn satisfy_branch_facts(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
    source: &AvailableValue,
    facts: &[&BranchFact],
    index: usize,
    current: &SlotValue,
    allow_replacement: bool,
    replacements: &mut Vec<SlotValue>,
    limit: usize,
) -> Option<SlotValue> {
    let Some(fact) = facts.get(index) else {
        return Some(current.clone());
    };
    let guard = guard_declaration(prepared.input(), &fact.guard)?;
    let projected = effective_projection(prepared, state, &fact.inspected).ok()?;
    let inspected = project_owned(current, &fact.inspected.path, &());
    if evaluate_guard_arm(prepared.graph(), guard, borrowed_slot(&inspected))
        .ok()
        .as_ref()
        == Some(&fact.arm)
    {
        if let Some(result) = satisfy_branch_facts(
            prepared,
            state,
            source,
            facts,
            index + 1,
            current,
            allow_replacement,
            replacements,
            limit,
        ) {
            if branch_facts_hold(prepared, facts, index + 1, &result) {
                return Some(result);
            }
        }
    }
    if !allow_replacement || replacements.len() >= limit {
        return None;
    }

    let (search_contract, shaping) = match (&fact.arm, &guard.kind) {
        (GuardArm::Accepted, GuardKind::Validate(contract)) => (contract.clone(), None),
        (GuardArm::Variant(tag), _) => {
            let TypeShape::TaggedUnion(spec) =
                resolved_shape(prepared.graph(), &projected.destination.type_ref)?
            else {
                return None;
            };
            let branch = spec
                .branches
                .iter()
                .find(|branch| &branch.wire_tag == tag)?;
            let mut contract = projected.destination.clone();
            contract.type_ref = branch.target.clone();
            let key = prepared
                .graph()
                .profile()
                .tag
                .as_ref()
                .map(|model| model.key.clone());
            (contract, Some((tag.clone(), key)))
        }
        _ => (projected.destination.clone(), None),
    };

    let mut answer = None;
    find_accepted_slot_candidate(
        prepared.graph(),
        &prepared.input().bounds,
        &search_contract,
        |candidate, _within_bound| {
            if replacements.len() >= limit {
                return SlotCandidateControl::StopNoEvidence;
            }
            let replacement = match (&shaping, candidate) {
                (Some((tag, Some(key))), SlotValue::Present(value)) => {
                    let Ok(value) = with_member(key, tag, value.clone()) else {
                        return SlotCandidateControl::Continue;
                    };
                    SlotValue::Present(value)
                }
                (Some((_, Some(_))), _) => return SlotCandidateControl::Continue,
                (_, value) => value.clone(),
            };
            if evaluate_guard_arm(prepared.graph(), guard, borrowed_slot(&replacement))
                .ok()
                .as_ref()
                != Some(&fact.arm)
            {
                return SlotCandidateControl::Continue;
            }
            let Some(updated) = replace_projected(current, &fact.inspected.path, &replacement)
            else {
                return SlotCandidateControl::Continue;
            };
            if !matches!(
                validation::accepts_slot(
                    prepared.graph(),
                    &source.contract,
                    borrowed_slot(&updated)
                ),
                ValueDecision::Accepted
            ) {
                return SlotCandidateControl::Continue;
            }
            if !replacements.contains(&updated) {
                replacements.push(updated.clone());
            }
            if let Some(result) = satisfy_branch_facts(
                prepared,
                state,
                source,
                facts,
                index + 1,
                &updated,
                allow_replacement,
                replacements,
                limit,
            ) {
                if branch_facts_hold(prepared, facts, index + 1, &result) {
                    answer = Some(result);
                    return SlotCandidateControl::Accept;
                }
            }
            if replacements.len() >= limit {
                SlotCandidateControl::StopNoEvidence
            } else {
                SlotCandidateControl::Continue
            }
        },
    );
    answer
}
fn derive_value_models(
    prepared: &PreparedCompositionInput<'_>,
    state: &SearchState,
) -> Result<Vec<(ProducerRef, SlotValue)>, UnresolvedObligation> {
    let mut result = Vec::new();
    for source in &state.available {
        if let Err(reason) = validation::check_meaning_defined(
            prepared.graph(),
            std::slice::from_ref(&source.contract.type_ref),
        ) {
            return Err(UnresolvedObligation::Meaning(vec![reason]));
        }
        if let ProducerRef::Initial(id) = &source.producer {
            if let Some(InitialInput {
                source: InitialSource::SuppliedValue(value),
                ..
            }) = prepared
                .input()
                .initial_inputs
                .iter()
                .find(|initial| &initial.id == id)
            {
                if let ValueDecision::Unresolved(reasons) = validation::accepts_slot(
                    prepared.graph(),
                    &source.contract,
                    borrowed_slot(value),
                ) {
                    return Err(UnresolvedObligation::SemanticMeaning(reasons));
                }
            }
        }
        let Some(value) = producer_model(prepared, state, source) else {
            return Err(UnresolvedObligation::Inhabitation {
                producer: source.producer.clone(),
                contract: source.contract.clone(),
            });
        };
        result.push((source.producer.clone(), value));
    }
    verify_value_models(prepared, state, &result)
        .map_err(|_| UnresolvedObligation::BranchInhabitation)?;
    Ok(result)
}
pub struct SearchEngine<'p, 'g> {
    prepared: &'p PreparedCompositionInput<'g>,
    budget: CandidateBudget,
    states: Vec<ClosedSearchState>,
    candidates: Vec<Vec<CandidateTree>>,
    expanded: usize,
    unknown: Vec<UnresolvedObligation>,
    frontier: Vec<SearchState>,
    failures: Vec<ConnectionFailure>,
}
fn missing_search_state() -> CompositionEngineFailure {
    CompositionEngineFailure::ContractViolation("search state is not recorded".to_owned())
}
impl<'p, 'g> SearchEngine<'p, 'g> {
    fn has_success(&self, index: usize) -> bool {
        self.candidates
            .get(index)
            .is_some_and(|candidates| candidates.iter().any(|candidate| candidate.success))
    }
    fn new(prepared: &'p PreparedCompositionInput<'g>) -> Self {
        let unknown = if prepared.initial_obligations().is_empty() {
            Vec::new()
        } else {
            vec![UnresolvedObligation::SemanticMeaning(
                prepared.initial_obligations().to_vec(),
            )]
        };
        Self {
            prepared,
            budget: CandidateBudget::new(),
            states: Vec::new(),
            candidates: Vec::new(),
            expanded: 0,
            unknown,
            frontier: Vec::new(),
            failures: Vec::new(),
        }
    }
    fn visit(&mut self, state: SearchState) -> Result<usize, CompositionEngineFailure> {
        if let Some(index) = self.states.iter().position(|record| record.state == state) {
            return Ok(index);
        }
        let index = self.states.len();
        let enumeration = enumerate_state(self.prepared, &state, &mut self.budget);
        self.failures.extend(enumeration.failures.iter().cloned());
        self.unknown.extend(enumeration.unknown);
        self.states.push(ClosedSearchState {
            state: state.clone(),
            terminals: Vec::new(),
            choices: Vec::new(),
            rejected_connections: enumeration.failures,
            missing_supply: enumeration.missing,
        });
        self.candidates.push(Vec::new());
        for terminal in enumeration.terminals {
            let assessment = if self.prepared.input().bounds.max_branch_nodes == 0 {
                self.budget.exhausted_branches = true;
                TerminalAssessment::Unknown(vec![UnresolvedObligation::BranchBoundExhausted])
            } else {
                assess_terminal(self.prepared, &state, &terminal)?
            };
            match &assessment {
                TerminalAssessment::Feasible(certificate) => self
                    .candidates
                    .get_mut(index)
                    .ok_or_else(missing_search_state)?
                    .push(CandidateTree {
                        tree: PlanTree {
                            rank: state.trace.len(),
                            node: PlanNode::Return(terminal.clone()),
                        },
                        node_count: 1,
                        success: matches!(terminal, ReturnPlan::Success(_)),
                        certificates: vec![certificate.clone()],
                    }),
                TerminalAssessment::Unknown(reasons) => {
                    self.unknown.extend(reasons.iter().cloned())
                }
                _ => {}
            }
            self.states
                .get_mut(index)
                .ok_or_else(missing_search_state)?
                .terminals
                .push(TerminalCoverage {
                    terminal,
                    assessment,
                });
        }
        let any_feasible =
            self.prepared.input().selection_policy == Some(SelectionPolicy::AnyFeasible);
        if any_feasible && self.has_success(index) {
            return Ok(index);
        }
        if !enumeration.choices.is_empty() {
            if self.expanded >= self.prepared.input().bounds.max_expanded_states {
                self.unknown.push(UnresolvedObligation::StateBoundExhausted);
                self.frontier.push(state);
                return Ok(index);
            }
            self.expanded += 1;
        }
        for choice in enumeration.choices {
            let children = choice_states(self.prepared, &state, &choice)
                .map_err(CompositionEngineFailure::Witness)?;
            let mut indices = Vec::with_capacity(children.len());
            for child in children {
                indices.push(self.visit(child)?);
            }
            let mut child_candidates = Vec::with_capacity(indices.len());
            for index in &indices {
                child_candidates.push(
                    self.candidates
                        .get(*index)
                        .cloned()
                        .ok_or_else(missing_search_state)?,
                );
            }
            let candidates = merge_choice(
                self.prepared.input(),
                &state,
                &choice,
                &child_candidates,
                &mut self.budget,
            );
            self.candidates
                .get_mut(index)
                .ok_or_else(missing_search_state)?
                .extend(candidates);
            self.states
                .get_mut(index)
                .ok_or_else(missing_search_state)?
                .choices
                .push(ChoiceCoverage {
                    choice,
                    children: indices,
                });
            if any_feasible && self.has_success(index) {
                break;
            }
        }
        let mut seen = HashSet::new();
        self.candidates
            .get_mut(index)
            .ok_or_else(missing_search_state)?
            .retain(|candidate| seen.insert(candidate_key(self.prepared.input(), candidate)));
        if self.budget.exhausted_branches {
            self.unknown
                .push(UnresolvedObligation::BranchBoundExhausted);
            self.frontier.push(state);
        }
        Ok(index)
    }
}

pub fn derive<'p, 'g>(
    prepared: &'p PreparedCompositionInput<'g>,
) -> Result<CompositionDecision<'p, 'g>, CompositionEngineFailure> {
    let mut engine = SearchEngine::new(prepared);
    let root = engine.visit(initial_state(prepared))?;
    let feasible = engine
        .candidates
        .get(root)
        .ok_or_else(missing_search_state)?
        .iter()
        .filter(|candidate| candidate.success)
        .cloned()
        .collect::<Vec<_>>();
    let policy = prepared
        .input()
        .selection_policy
        .unwrap_or(SelectionPolicy::RequireUnique);
    if let (SelectionPolicy::RequireUnique, [first, second, ..]) = (policy, feasible.as_slice()) {
        return CompositionDecision::decide_ambiguous(prepared, first.clone(), second.clone());
    }
    if let Some(candidate) = feasible.first() {
        if policy == SelectionPolicy::AnyFeasible || engine.unknown.is_empty() {
            let selection = if policy == SelectionPolicy::AnyFeasible {
                SelectionEvidence::AnyFeasible
            } else {
                SelectionEvidence::Unique {
                    closure: Box::new(CompositionClosureWitness {
                        input_snapshot: prepared.input().clone(),
                        root,
                        states: engine.states,
                    }),
                    canonical_plan: candidate_key(prepared.input(), candidate),
                }
            };
            let selection = Arc::new(selection);
            let raw = RawComposition {
                plan: CompositionPlan {
                    input_identity: prepared.input().identity.clone(),
                    input_revision: prepared.input().revision.clone(),
                    root: candidate.tree.clone(),
                },
                witness: CompositionWitness {
                    input_snapshot: prepared.input().clone(),
                    initial_membership: initial_membership(prepared)?,
                    resource_traces: candidate.certificates.clone(),
                },
                selection: Arc::clone(&selection),
            };
            let checked =
                verify_composition(prepared, &raw).map_err(CompositionEngineFailure::Witness)?;
            return Ok(CompositionDecision::Solved(checked, selection));
        }
        engine
            .unknown
            .push(UnresolvedObligation::UnresolvedUniqueness);
    }
    if !engine.unknown.is_empty() {
        let mut obligations = Vec::new();
        for obligation in engine.unknown {
            if !obligations.contains(&obligation) {
                obligations.push(obligation);
            }
        }
        let frontier = if engine.frontier.is_empty() {
            vec![initial_state(prepared)]
        } else {
            engine.frontier
        };
        return Ok(CompositionDecision::Unknown {
            obligations,
            frontier,
            rejected_connections: engine.failures,
        });
    }
    let closure = CompositionClosureWitness {
        input_snapshot: prepared.input().clone(),
        root,
        states: engine.states,
    };
    CompositionDecision::decide_unreachable(prepared, closure)
}
