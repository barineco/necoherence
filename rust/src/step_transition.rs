// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

//! Closed bounded single-owner transition, evaluated in one call.

use crate::core::Nat;

/// A positive bound on how many times one input may be reprocessed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PositiveLimit {
    value: Nat,
}

impl PositiveLimit {
    /// Build a positive limit, or `None` when `value` is zero.
    pub fn new(value: Nat) -> Option<Self> {
        if value > Nat::from(0u8) {
            Some(Self { value })
        } else {
            None
        }
    }

    pub fn value(&self) -> &Nat {
        &self.value
    }
}

/// A bound on how many outputs one transition may accumulate.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Capacity {
    pub value: Nat,
}

/// What one application of `advance` decided about the input it was given.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Consumption<S, O> {
    Consumed(S, Vec<O>),
    Reprocess(S, Vec<O>),
}

impl<S: Clone, O: Clone> Consumption<S, O> {
    fn state(&self) -> S {
        match self {
            Consumption::Consumed(s, _) => s.clone(),
            Consumption::Reprocess(s, _) => s.clone(),
        }
    }

    fn outputs(&self) -> Vec<O> {
        match self {
            Consumption::Consumed(_, o) => o.clone(),
            Consumption::Reprocess(_, o) => o.clone(),
        }
    }

    fn is_consumed(&self) -> bool {
        matches!(self, Consumption::Consumed(_, _))
    }
}

/// Why a transition stopped without consuming its input.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StepFailure {
    ReprocessLimitExhausted(Nat),
    CapacityExceeded(Nat, Nat),
}

/// The closed result of one transition.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StepTransition<S, O> {
    Settled(S, Vec<O>, Nat),
    Failed(S, Vec<O>, StepFailure),
}

/// Evaluate one input to a closed result in a single call.
pub fn step<S, I, O>(
    state: S,
    input: &I,
    advance: impl Fn(&S, &I) -> Consumption<S, O>,
    limit: &PositiveLimit,
    capacity: &Capacity,
) -> StepTransition<S, O>
where
    S: Clone,
    O: Clone,
{
    let mut current = state;
    let mut acc: Vec<O> = Vec::new();
    let mut applications = Nat::from(0u8);
    let one = Nat::from(1u8);
    let mut remaining = limit.value().clone();
    loop {
        if remaining == Nat::from(0u8) {
            return StepTransition::Failed(
                current,
                acc,
                StepFailure::ReprocessLimitExhausted(applications),
            );
        }
        let decision = advance(&current, input);
        let next = decision.state();
        let mut produced = decision.outputs();
        let is_consumed = decision.is_consumed();
        acc.append(&mut produced);
        let acc_len = Nat::from(acc.len());
        if acc_len > capacity.value {
            return StepTransition::Failed(
                next,
                acc,
                StepFailure::CapacityExceeded(capacity.value.clone(), acc_len),
            );
        }
        applications += &one;
        if is_consumed {
            return StepTransition::Settled(next, acc, applications);
        }
        current = next;
        remaining -= &one;
    }
}
