// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

//! Iterative call forms whose step-count upper bound is readable from the
//! input. A failing round returns as a declared branch of the outcome.

use crate::call::{io, CallResult, Immediate, ProjectionFailed, Request};
use crate::core::Nat;
use std::collections::BTreeSet;

pub type Measure = Nat;

/// Position and cause of a round's own projection failure.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StageProjectionFailed {
    pub position: Nat,
    pub failure: ProjectionFailed,
}

/// Closed outcome of a fold run.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FoldOutcome<S> {
    Trace(Vec<S>),
    Stopped(Vec<S>, StageProjectionFailed),
}

/// Run a bounded number of settled rounds from a seed.
pub fn fold_output<S, F>(
    step: &Immediate<S, S, F>,
    step_fields: &[String],
    seed: S,
    count: &Nat,
) -> FoldOutcome<S>
where
    S: Clone,
    F: Fn(&S) -> S,
{
    let mut states = vec![seed.clone()];
    let mut state = seed;
    let mut position = Nat::from(0u8);
    let one = Nat::from(1u8);
    while &position < count {
        let request = Request {
            payload: state.clone(),
            fields: step_fields.to_vec(),
        };
        match io(step, &request) {
            CallResult::Ok(next) => {
                state = next;
                states.push(state.clone());
                position += &one;
            }
            CallResult::Failed(f) => {
                return FoldOutcome::Stopped(
                    states,
                    StageProjectionFailed {
                        position,
                        failure: f,
                    },
                );
            }
        }
    }
    FoldOutcome::Trace(states)
}

/// A round's continuation, or its settled value.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StepOutcome<S> {
    Advance(S, Measure),
    Settled(S),
}

/// Closed outcome of a recurse run.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RecurseOutcome<S> {
    Settled(S, Nat),
    DidNotDecrease(Nat, S, Measure, Measure),
    ProjectionFailed(S, StageProjectionFailed),
}

/// Descend while the reported measure strictly decreases, or settle.
pub fn recurse_output<S, F>(
    step: &Immediate<S, StepOutcome<S>, F>,
    step_fields: &[String],
    seed: S,
) -> RecurseOutcome<S>
where
    S: Clone,
    F: Fn(&S) -> StepOutcome<S>,
{
    let mut state = seed.clone();
    let mut previous_measure: Option<Measure> = None;
    let mut position = Nat::from(0u8);
    let one = Nat::from(1u8);
    loop {
        let request = Request {
            payload: state.clone(),
            fields: step_fields.to_vec(),
        };
        match io(step, &request) {
            CallResult::Failed(f) => {
                let stopped = if position == Nat::from(0u8) {
                    seed.clone()
                } else {
                    state.clone()
                };
                return RecurseOutcome::ProjectionFailed(
                    stopped,
                    StageProjectionFailed {
                        position,
                        failure: f,
                    },
                );
            }
            CallResult::Ok(StepOutcome::Settled(value)) => {
                return RecurseOutcome::Settled(value, position);
            }
            CallResult::Ok(StepOutcome::Advance(next, measure)) => {
                if let Some(prev) = &previous_measure {
                    if measure >= *prev {
                        return RecurseOutcome::DidNotDecrease(
                            position,
                            next,
                            measure,
                            prev.clone(),
                        );
                    }
                }
                previous_measure = Some(measure);
                state = next;
                position += &one;
            }
        }
    }
}

/// A closure round's own accumulated subset.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClosureState<T> {
    pub elements: BTreeSet<T>,
}

/// Closed outcome of a closure run.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ClosureOutcome<T> {
    Fixpoint(BTreeSet<T>, Nat),
    Violation(Nat, BTreeSet<T>, BTreeSet<T>),
    ProjectionFailed(BTreeSet<T>, StageProjectionFailed),
}

/// Grow a subset until it stops changing, staying inside a fixed carrier.
pub fn closure_output<T, F>(
    step: &Immediate<ClosureState<T>, BTreeSet<T>, F>,
    step_fields: &[String],
    carrier: BTreeSet<T>,
    seed: BTreeSet<T>,
) -> ClosureOutcome<T>
where
    T: Ord + Clone,
    F: Fn(&ClosureState<T>) -> BTreeSet<T>,
{
    let mut current = seed;
    let mut position = Nat::from(0u8);
    let one = Nat::from(1u8);
    loop {
        let request = Request {
            payload: ClosureState {
                elements: current.clone(),
            },
            fields: step_fields.to_vec(),
        };
        match io(step, &request) {
            CallResult::Failed(f) => {
                return ClosureOutcome::ProjectionFailed(
                    current,
                    StageProjectionFailed {
                        position,
                        failure: f,
                    },
                );
            }
            CallResult::Ok(produced) => {
                if produced == current {
                    return ClosureOutcome::Fixpoint(current, position);
                }
                if current.is_subset(&produced) && produced.is_subset(&carrier) {
                    current = produced;
                    position += &one;
                } else {
                    return ClosureOutcome::Violation(position, current, produced);
                }
            }
        }
    }
}
