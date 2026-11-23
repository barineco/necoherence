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

impl<S, O> Consumption<S, O> {
    fn into_parts(self) -> (S, Vec<O>, bool) {
        match self {
            Consumption::Consumed(s, o) => (s, o, true),
            Consumption::Reprocess(s, o) => (s, o, false),
        }
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
    advance: impl Fn(S, &I) -> Consumption<S, O>,
    limit: &PositiveLimit,
    capacity: &Capacity,
) -> StepTransition<S, O> {
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
        let (next, mut produced, is_consumed) = advance(current, input).into_parts();
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
