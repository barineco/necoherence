// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only
// 核の実行の検査で共有する fixture のうち、solver の要素を使うものである。
#![allow(
    clippy::expect_used,
    clippy::panic,
    clippy::result_large_err,
    clippy::unwrap_used,
    clippy::indexing_slicing
)]

use necoherence::semantic_composition as composition;
use necoherence::semantic_types::*;
use necoherence::typed_mapping as resource;
use necoherence_composition_solver::verification::{
    BranchTrace, CompositionWitness, ResourceTraceCertificate, TraceStep,
};
use num_bigint::BigUint;
use std::sync::Arc;

pub fn acyclicity(input: &resource::SolverInput) -> resource::AcyclicWitness {
    let mut explored = vec![input.marking.clone()];
    let mut cursor = 0;
    while cursor < explored.len() {
        let marking = explored.get(cursor).unwrap().clone();
        for transition in &input.transitions {
            let bindings = resource::bindings_for(input, &transition.identity);
            if resource::transition_enabled_at(&bindings, &marking) {
                let next = resource::apply_branch_at(marking.clone(), transition, &bindings);
                if !explored.contains(&next) {
                    explored.push(next);
                }
            }
        }
        cursor += 1;
    }
    resource::AcyclicWitness {
        steps: BigUint::from(explored.len()),
        explored_markings: explored,
        frontier: vec![],
    }
}

pub fn certificate(
    prepared: &composition::PreparedCompositionInput<'_>,
    state: &necoherence_composition_solver::search_state::SearchState,
    terminal: &composition::ReturnPlan,
) -> ResourceTraceCertificate {
    let trace = BranchTrace {
        steps: state.trace.clone(),
        terminal: terminal.clone(),
    };
    let (lowering, correspondence) =
        necoherence_composition_solver::lowering::lower_resource_trace(prepared, &trace).unwrap();
    let mut final_marking = lowering.marking.clone();
    for identity in &correspondence.execution_order {
        let transition = lowering
            .transitions
            .iter()
            .find(|transition| transition.identity == *identity)
            .unwrap();
        let bindings = resource::bindings_for(&lowering, identity);
        final_marking = resource::apply_branch_at(final_marking, transition, &bindings);
    }
    let value_sources = state
        .available
        .iter()
        .map(|available| {
            let guarded = state.trace.iter().rev().find_map(|step| match step {
                TraceStep::Guard { inspected, arm, .. }
                    if inspected.producer == available.producer =>
                {
                    Some(match arm {
                        composition::GuardArm::Absent => SlotValue::Absent,
                        composition::GuardArm::Null => SlotValue::Null,
                        _ => SlotValue::Present(JsonValue::Bool(false)),
                    })
                }
                _ => None,
            });
            let value = guarded.unwrap_or_else(|| {
                composition::slot_samples(
                    prepared.graph(),
                    &prepared.input().bounds,
                    &available.contract,
                )
                .values
                .into_iter()
                .next()
                .expect("the boolean slot is inhabited")
            });
            (available.producer.clone(), value)
        })
        .collect();
    ResourceTraceCertificate {
        trace,
        lowering: lowering.clone(),
        correspondence: correspondence.clone(),
        reachability: resource::ReachabilityWitness {
            path: correspondence.execution_order.clone(),
            final_marking,
        },
        acyclicity: acyclicity(&lowering),
        value_sources,
    }
}

pub fn derivation(
    prepared: &composition::PreparedCompositionInput<'_>,
    want_guard: bool,
) -> necoherence_composition_solver::verification::RawComposition {
    let state = necoherence_composition_solver::search_state::initial_state(prepared);
    let action =
        necoherence_composition_solver::enumeration::enumerate_invocations(prepared, &state)
            .values
            .into_iter()
            .chain(
                necoherence_composition_solver::enumeration::enumerate_guards(prepared, &state)
                    .values,
            )
            .find(|action| {
                matches!(
                    action,
                    necoherence_composition_solver::closure::LocalAction::Guard { .. }
                ) == want_guard
            })
            .expect("the requested execution choice exists");
    let choice =
        necoherence_composition_solver::enumeration::local_action_choice(prepared, &state, &action)
            .unwrap();
    let states =
        necoherence_composition_solver::enumeration::action_successors(prepared, &state, &action)
            .unwrap()
            .into_iter()
            .map(|(_, child)| child)
            .collect::<Vec<_>>();
    let (children, certificates): (Vec<_>, Vec<_>) = states
        .iter()
        .map(|child_state| {
            let child = necoherence_composition_solver::enumeration::enumerate_returns(
                prepared,
                child_state,
            );
            let terminal = child
                .values
                .first()
                .expect("every selected branch has a terminal")
                .clone();
            let branch = vec![composition::PlanTree {
                rank: child_state.trace.len().into(),
                node: composition::PlanNode::Return(terminal.clone()),
            }];
            let branch = necoherence_composition_solver::enumeration::Enumeration {
                values: branch,
                obligations: Vec::new(),
                cost: 0,
            };
            (branch, certificate(prepared, child_state, &terminal))
        })
        .unzip();
    let root = necoherence_composition_solver::enumeration::merge_choice(
        prepared, &state, &choice, &children,
    )
    .values
    .into_iter()
    .next()
    .expect("the branch plans merge");
    necoherence_composition_solver::verification::RawComposition {
        plan: composition::CompositionPlan {
            input_identity: prepared.input().identity.clone(),
            input_revision: prepared.input().revision.clone(),
            root,
        },
        witness: CompositionWitness {
            input_snapshot: prepared.input().clone(),
            initial_membership: necoherence_composition_solver::search_state::initial_membership(
                prepared,
            )
            .unwrap(),
            resource_traces: certificates,
        },
        selection: Arc::new(
            necoherence_composition_solver::closure::SelectionEvidence::AnyFeasible,
        ),
    }
}
