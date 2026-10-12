// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

//! Typed mapping solver search: bounded exploration of the marking graph,
//! reachability, deadlock and well-foundedness checks over the typed
//! mapping model of `necoherence::typed_mapping`.

use std::collections::VecDeque;

use necoherence::typed_mapping::{
    apply_branch_at, binding_bound_exceeded, bindings_for, derive_enabled, eval_goal,
    transition_enabled_at, validate, AcyclicWitness, ClosureWitness, CycleWitness, DeadlockResult,
    DeadlockWitness, EnabledResult, Marking, ReachabilityResult, ReachabilityWitness,
    SolverFailure, SolverInput, UnknownReason, WellFoundednessResult,
};
use necoherence::Nat;

/// The result of one exploration step: goal reached, frontier
/// exhausted within bound, or the search-step bound hit.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ExploreOutcome {
    Found(Vec<String>, Marking),
    Closed(Vec<Marking>),
    BoundHit(Vec<Marking>),
}

fn neighbors_of(input: &SolverInput, path: &[String], m: &Marking) -> Vec<(Vec<String>, Marking)> {
    input
        .transitions
        .iter()
        .filter_map(|t| {
            let bs = bindings_for(input, &t.identity);
            if transition_enabled_at(&bs, m) {
                let mut next_path = path.to_vec();
                next_path.push(t.identity.clone());
                Some((next_path, apply_branch_at(m, t, &bs)))
            } else {
                None
            }
        })
        .collect()
}

/// The neighbours that are genuinely new: marking not among the
/// `blocked` visited or pending markings and not produced by another
/// neighbour in the same batch; convergent markings enqueue at most once.
fn fresh_neighbors(
    neighbors: Vec<(Vec<String>, Marking)>,
    blocked: &[Marking],
) -> Vec<(Vec<String>, Marking)> {
    let mut blocked = blocked.to_vec();
    neighbors
        .into_iter()
        .filter(|pr| {
            if blocked.contains(&pr.1) {
                false
            } else {
                blocked.push(pr.1.clone());
                true
            }
        })
        .collect()
}

/// Bounded breadth-first exploration of the hypothetical marking graph,
/// one declared branch at a time, fuel-limited by the search-step bound.
pub fn explore(
    input: &SolverInput,
    fuel: Nat,
    frontier: Vec<(Vec<String>, Marking)>,
    visited: Vec<Marking>,
) -> ExploreOutcome {
    let zero = Nat::from(0u8);
    let one = Nat::from(1u8);
    let mut remaining = fuel;
    let mut frontier: VecDeque<(Vec<String>, Marking)> = frontier.into();
    let mut visited = visited;
    loop {
        let Some((path, m)) = frontier.pop_front() else {
            return ExploreOutcome::Closed(visited);
        };
        if remaining == zero {
            if eval_goal(&m, &input.goal) {
                return ExploreOutcome::Found(path, m);
            }
            visited.insert(0, m);
            return ExploreOutcome::BoundHit(visited);
        }
        if eval_goal(&m, &input.goal) {
            return ExploreOutcome::Found(path, m);
        }
        visited.insert(0, m.clone());
        let mut blocked = visited.clone();
        blocked.extend(frontier.iter().map(|pr| pr.1.clone()));
        for neighbor in fresh_neighbors(neighbors_of(input, &path, &m), &blocked) {
            frontier.push_back(neighbor);
        }
        remaining -= &one;
    }
}

/// Check whether `input.goal` is reachable within the declared bounds,
/// after validating the declaration.
pub fn check_reachability(input: &SolverInput) -> Result<ReachabilityResult, SolverFailure> {
    if let Some(reason) = validate(input) {
        return Ok(ReachabilityResult::Invalid(reason));
    }
    if binding_bound_exceeded(input) {
        return Ok(ReachabilityResult::Unknown(
            UnknownReason::BindingBoundExhausted(input.bound.max_bindings.clone()),
        ));
    }
    match explore(
        input,
        input.bound.max_search_steps.clone(),
        vec![(vec![], input.marking.clone())],
        vec![],
    ) {
        ExploreOutcome::Found(path, m) => Ok(ReachabilityResult::Reachable(ReachabilityWitness {
            path,
            final_marking: m,
        })),
        ExploreOutcome::Closed(visited) => Ok(ReachabilityResult::Unreachable(ClosureWitness {
            steps: Nat::from(visited.len()),
            explored_markings: visited,
            frontier: vec![],
        })),
        ExploreOutcome::BoundHit(_) => Ok(ReachabilityResult::Unknown(
            UnknownReason::SearchStepBoundExhausted(input.bound.max_search_steps.clone()),
        )),
    }
}

/// A marking is deadlocked when the goal is not satisfied and no
/// transition is enabled; this is a separate proposition from goal
/// satisfaction and from reachability.
pub fn check_deadlock(input: &SolverInput) -> Result<DeadlockResult, SolverFailure> {
    if let Some(reason) = validate(input) {
        return Ok(DeadlockResult::Invalid(reason));
    }
    if binding_bound_exceeded(input) {
        return Ok(DeadlockResult::Unknown(
            UnknownReason::BindingBoundExhausted(input.bound.max_bindings.clone()),
        ));
    }
    match derive_enabled(input)? {
        EnabledResult::Invalid(reason) => Ok(DeadlockResult::Invalid(reason)),
        EnabledResult::EnabledSet(s) => {
            if eval_goal(&input.marking, &input.goal) {
                Ok(DeadlockResult::NotDeadlocked(s))
            } else if s.enabled.is_empty() {
                Ok(DeadlockResult::Deadlocked(DeadlockWitness {
                    marking: input.marking.clone(),
                }))
            } else {
                Ok(DeadlockResult::NotDeadlocked(s))
            }
        }
    }
}

fn total_tokens(m: &Marking) -> Nat {
    m.places
        .iter()
        .fold(Nat::from(0u8), |acc, (_, ts)| acc + Nat::from(ts.len()))
}

/// The result of a cycle search: a repeated marking, a finite acyclic
/// closure, or an exhausted search bound.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CycleOutcome {
    CycleFound {
        prefix_path: Vec<String>,
        cycle_path: Vec<String>,
        cycle_start: Marking,
        cycle_end: Marking,
        measure_decreasing: bool,
    },
    ClosedNoCycle(Vec<Marking>),
    BoundHit(Vec<Marking>),
}

/// One pending entry of the well-foundedness search: the transition
/// path that reached a marking, the markings on the root-to-node path it
/// was discovered along (the active DFS stack), and the marking itself.
pub type WfEntry = (Vec<String>, Vec<Marking>, Marking);

/// Bounded depth-first search for the first repeated marking, fuel-limited
/// by the search-step bound.
pub fn explore_wf(
    input: &SolverInput,
    fuel: Nat,
    frontier: Vec<WfEntry>,
    explored: Vec<Marking>,
) -> CycleOutcome {
    let zero = Nat::from(0u8);
    let one = Nat::from(1u8);
    let mut remaining = fuel;
    let mut frontier: VecDeque<WfEntry> = frontier.into();
    let mut explored = explored;
    loop {
        let Some((path, path_ms, m)) = frontier.pop_front() else {
            return CycleOutcome::ClosedNoCycle(explored);
        };
        if remaining == zero {
            return CycleOutcome::BoundHit(explored);
        }
        if explored.contains(&m) {
            continue;
        }
        let neighbors = neighbors_of(input, &path, &m);
        if let Some((ancestor_index, (closing_path, cycle_end))) =
            neighbors
                .iter()
                .find_map(|(candidate_path, candidate_marking)| {
                    path_ms
                        .iter()
                        .position(|ancestor| ancestor == candidate_marking)
                        .map(|index| (index, (candidate_path, candidate_marking)))
                })
        {
            let prefix_len = path.len().saturating_sub(ancestor_index);
            let (prefix, cycle) = closing_path.split_at(prefix_len);
            return CycleOutcome::CycleFound {
                prefix_path: prefix.to_vec(),
                cycle_path: cycle.to_vec(),
                cycle_start: cycle_end.clone(),
                cycle_end: cycle_end.clone(),
                measure_decreasing: total_tokens(cycle_end) < total_tokens(&m),
            };
        }
        explored.insert(0, m.clone());
        let mut blocked = path_ms.clone();
        blocked.extend(explored.iter().cloned());
        for (p2, m2) in fresh_neighbors(neighbors, &blocked).into_iter().rev() {
            let mut next_ms = vec![m2.clone()];
            next_ms.extend(path_ms.iter().cloned());
            frontier.push_front((p2, next_ms, m2));
        }
        remaining -= &one;
    }
}

/// Check well-foundedness: every repeated marking is a non-well-founded
/// cycle, including cycles whose closing edge decreases the measure.
pub fn check_well_foundedness(input: &SolverInput) -> Result<WellFoundednessResult, SolverFailure> {
    if let Some(reason) = validate(input) {
        return Ok(WellFoundednessResult::Invalid(reason));
    }
    if binding_bound_exceeded(input) {
        return Ok(WellFoundednessResult::Unknown(
            UnknownReason::BindingBoundExhausted(input.bound.max_bindings.clone()),
        ));
    }
    match explore_wf(
        input,
        input.bound.max_search_steps.clone(),
        vec![(vec![], vec![input.marking.clone()], input.marking.clone())],
        vec![],
    ) {
        CycleOutcome::CycleFound {
            prefix_path,
            cycle_path,
            cycle_start,
            cycle_end,
            measure_decreasing,
        } => Ok(WellFoundednessResult::NotWellFounded(CycleWitness {
            prefix_path,
            cycle_path,
            cycle_start,
            cycle_end,
            measure_decreasing,
        })),
        CycleOutcome::ClosedNoCycle(explored_markings) => {
            Ok(WellFoundednessResult::WellFounded(AcyclicWitness {
                steps: Nat::from(explored_markings.len()),
                explored_markings,
                frontier: vec![],
            }))
        }
        CycleOutcome::BoundHit(_) => Ok(WellFoundednessResult::Unknown(
            UnknownReason::SearchStepBoundExhausted(input.bound.max_search_steps.clone()),
        )),
    }
}
