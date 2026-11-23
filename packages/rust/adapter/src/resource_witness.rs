// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use crate::core::Nat;
use crate::semantic_composition::WitnessFailure;
use crate::typed_mapping as resource;
use std::cmp::Reverse;
use std::collections::BinaryHeap;

#[derive(Debug)]
pub struct CheckedReachability<'a> {
    input: &'a resource::SolverInput,
    witness: &'a resource::ReachabilityWitness,
}
impl CheckedReachability<'_> {
    pub fn input(&self) -> &resource::SolverInput {
        self.input
    }
    pub fn witness(&self) -> &resource::ReachabilityWitness {
        self.witness
    }
}
/// 閉包の検査を済ませた証拠。値は [`verify_closure_witness`] だけが作る。
#[derive(Debug)]
pub struct CheckedClosure<'a> {
    input: &'a resource::SolverInput,
    witness: &'a resource::ClosureWitness,
}
impl<'a> CheckedClosure<'a> {
    pub fn input(&self) -> &resource::SolverInput {
        self.input
    }
    pub fn witness(&self) -> &resource::ClosureWitness {
        self.witness
    }
}
#[derive(Debug)]
pub struct CheckedAcyclic<'a> {
    input: &'a resource::SolverInput,
    witness: &'a resource::AcyclicWitness,
}
impl CheckedAcyclic<'_> {
    pub fn input(&self) -> &resource::SolverInput {
        self.input
    }
    pub fn witness(&self) -> &resource::AcyclicWitness {
        self.witness
    }
}
fn successor_covered(
    input: &resource::SolverInput,
    markings: &[resource::Marking],
    marking: &resource::Marking,
    transition_id: &str,
) -> Result<Option<usize>, WitnessFailure> {
    match resource::step_at(input, marking, transition_id) {
        None => Ok(None),
        Some(next) => markings
            .iter()
            .position(|candidate| candidate == &next)
            .map(Some)
            .ok_or_else(|| WitnessFailure::ForgedClosure("enabled successor omitted".to_owned())),
    }
}
fn successors_covered_at(
    input: &resource::SolverInput,
    markings: &[resource::Marking],
    marking: &resource::Marking,
) -> Result<Vec<usize>, WitnessFailure> {
    let mut successors = Vec::new();
    for transition in &input.transitions {
        if let Some(index) = successor_covered(input, markings, marking, &transition.identity)? {
            if !successors.contains(&index) {
                successors.push(index);
            }
        }
    }
    Ok(successors)
}
pub fn verify_reachability_witness<'a>(
    input: &'a resource::SolverInput,
    witness: &'a resource::ReachabilityWitness,
) -> Result<CheckedReachability<'a>, WitnessFailure> {
    if resource::validate(input).is_some() {
        return Err(WitnessFailure::ResourceReplayMismatch(
            "invalid resource declaration".to_owned(),
        ));
    }
    if resource::binding_bound_exceeded(input) {
        return Err(WitnessFailure::ResourceReplayMismatch(
            "binding bound".to_owned(),
        ));
    }
    if Nat::from(witness.path.len()) > input.bound.max_search_steps {
        return Err(WitnessFailure::ResourceReplayMismatch(
            "path step bound".to_owned(),
        ));
    }
    if resource::path_replay(input, &input.marking, &witness.path).as_ref()
        != Some(&witness.final_marking)
    {
        return Err(WitnessFailure::ResourceReplayMismatch(
            "enabled path or final marking".to_owned(),
        ));
    }
    if !resource::eval_goal(&witness.final_marking, &input.goal) {
        return Err(WitnessFailure::ResourceReplayMismatch(
            "terminal resource goal".to_owned(),
        ));
    }
    Ok(CheckedReachability { input, witness })
}
pub fn verify_finite_closure(
    input: &resource::SolverInput,
    markings: &[resource::Marking],
    steps: &Nat,
    frontier: &[resource::Marking],
) -> Result<Vec<Vec<usize>>, WitnessFailure> {
    if resource::validate(input).is_some() {
        return Err(WitnessFailure::ForgedClosure(
            "invalid resource declaration".to_owned(),
        ));
    }
    if resource::binding_bound_exceeded(input) {
        return Err(WitnessFailure::ForgedClosure(
            "resource binding bound".to_owned(),
        ));
    }
    if !frontier.is_empty()
        || *steps != Nat::from(markings.len())
        || steps > &input.bound.max_search_steps
    {
        return Err(WitnessFailure::ForgedClosure(
            "frontier, steps, or resource bound".to_owned(),
        ));
    }
    if !markings.contains(&input.marking) {
        return Err(WitnessFailure::ForgedClosure(
            "initial marking omitted".to_owned(),
        ));
    }
    for (index, marking) in markings.iter().enumerate() {
        if markings
            .iter()
            .take(index)
            .any(|earlier| earlier == marking)
        {
            return Err(WitnessFailure::ForgedClosure(
                "duplicated explored marking".to_owned(),
            ));
        }
    }
    markings
        .iter()
        .map(|marking| successors_covered_at(input, markings, marking))
        .collect()
}
pub fn verify_closure_witness<'a>(
    input: &'a resource::SolverInput,
    witness: &'a resource::ClosureWitness,
) -> Result<CheckedClosure<'a>, WitnessFailure> {
    verify_finite_closure(
        input,
        &witness.explored_markings,
        &witness.steps,
        &witness.frontier,
    )?;
    if witness
        .explored_markings
        .iter()
        .any(|marking| resource::eval_goal(marking, &input.goal))
    {
        return Err(WitnessFailure::ForgedClosure(
            "closed marking satisfies the goal".to_owned(),
        ));
    }
    Ok(CheckedClosure { input, witness })
}
pub fn verify_acyclic_witness<'a>(
    input: &'a resource::SolverInput,
    witness: &'a resource::AcyclicWitness,
) -> Result<CheckedAcyclic<'a>, WitnessFailure> {
    let edges = verify_finite_closure(
        input,
        &witness.explored_markings,
        &witness.steps,
        &witness.frontier,
    )?;
    let order = topological_markings(&edges);
    let positions = order_positions(&order, edges.len());
    if !(0..edges.len()).all(|marking| ranked_at(&positions, &edges, marking)) {
        return Err(WitnessFailure::ForgedAcyclicity(
            "closed resource graph contains a cycle".to_owned(),
        ));
    }
    if !(0..edges.len()).all(|marking| list_index(&positions, marking).is_some()) {
        return Err(WitnessFailure::ForgedAcyclicity(
            "explored marking omitted from order".to_owned(),
        ));
    }
    Ok(CheckedAcyclic { input, witness })
}
fn topological_markings(edges: &[Vec<usize>]) -> Vec<usize> {
    let mut indegrees = vec![0usize; edges.len()];
    for successors in edges {
        for index in successors {
            if let Some(degree) = indegrees.get_mut(*index) {
                *degree += 1;
            }
        }
    }
    let mut pending: BinaryHeap<Reverse<usize>> = indegrees
        .iter()
        .enumerate()
        .filter_map(|(index, degree)| (*degree == 0).then_some(Reverse(index)))
        .collect();
    let mut order = Vec::with_capacity(edges.len());
    while let Some(Reverse(index)) = pending.pop() {
        order.push(index);
        for successor in edges.get(index).into_iter().flatten() {
            if let Some(degree) = indegrees.get_mut(*successor) {
                *degree -= 1;
                if *degree == 0 {
                    pending.push(Reverse(*successor));
                }
            }
        }
    }
    order
}
fn order_positions(order: &[usize], count: usize) -> Vec<Option<usize>> {
    let mut positions = vec![None; count];
    for (position, marking) in order.iter().enumerate() {
        if let Some(slot) = positions.get_mut(*marking) {
            *slot = Some(position);
        }
    }
    positions
}
fn list_index(positions: &[Option<usize>], marking: usize) -> Option<usize> {
    positions.get(marking).copied().flatten()
}
fn successor_ranked(positions: &[Option<usize>], marking: usize, next: usize) -> bool {
    match (list_index(positions, marking), list_index(positions, next)) {
        (Some(before), Some(after)) => before < after,
        _ => false,
    }
}
fn ranked_at(positions: &[Option<usize>], edges: &[Vec<usize>], marking: usize) -> bool {
    edges
        .get(marking)
        .into_iter()
        .flatten()
        .all(|next| successor_ranked(positions, marking, *next))
}

#[cfg(test)]
mod topological_order_tests {
    use super::topological_markings;

    #[test]
    fn topological_markings_takes_the_first_root_in_marking_order() {
        assert_eq!(
            topological_markings(&[vec![2], vec![2], vec![]]),
            vec![0, 1, 2]
        );
        assert_eq!(
            topological_markings(&[vec![1], vec![], vec![1]]),
            vec![0, 2, 1]
        );
        assert!(topological_markings(&[vec![1], vec![0]]).is_empty());
    }
}
