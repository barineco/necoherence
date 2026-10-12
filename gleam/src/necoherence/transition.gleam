// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list

/// A positive bound on how many times one input may be reprocessed.
pub opaque type PositiveLimit {
  PositiveLimit(value: Int)
}

pub type LimitError {
  LimitNotPositive(value: Int)
}

pub fn positive_limit_new(value: Int) -> Result(PositiveLimit, LimitError) {
  case value > 0 {
    True -> Ok(PositiveLimit(value))
    False -> Error(LimitNotPositive(value))
  }
}

pub fn positive_limit_value(limit: PositiveLimit) -> Int {
  limit.value
}

/// A bound on how many outputs one transition may accumulate.
pub opaque type Capacity {
  Capacity(value: Int)
}

pub type CapacityError {
  CapacityNegative(value: Int)
}

pub fn capacity_new(value: Int) -> Result(Capacity, CapacityError) {
  case value >= 0 {
    True -> Ok(Capacity(value))
    False -> Error(CapacityNegative(value))
  }
}

pub fn capacity_value(capacity: Capacity) -> Int {
  capacity.value
}

/// What one application of the caller's advance function decided about the
/// input it was given.
pub type Consumption(state, output) {
  Consumed(state: state, outputs: List(output))
  Reprocess(state: state, outputs: List(output))
}

/// Why a transition stopped without consuming its input.
pub type StepFailure {
  ReprocessLimitExhausted(limit: Int)
  CapacityExceeded(capacity: Int, attempted: Int)
}

/// The closed result of one transition.
pub type StepTransition(state, output) {
  Settled(state: state, outputs: List(output), applications: Int)
  Failed(state: state, outputs: List(output), failure: StepFailure)
}

/// Evaluate one input to a closed result in a single call.
///
/// `advance` is applied to the same input until it reports `Consumed`, at most
/// `limit` times. Outputs keep the order in which `advance` produced them and
/// never exceed `capacity`.
pub fn step(
  state: state,
  input: input,
  advance: fn(state, input) -> Consumption(state, output),
  limit: PositiveLimit,
  capacity: Capacity,
) -> StepTransition(state, output) {
  loop(state, input, advance, limit.value, capacity.value, [], 0)
}

fn loop(
  state: state,
  input: input,
  advance: fn(state, input) -> Consumption(state, output),
  fuel: Int,
  capacity: Int,
  accumulated: List(output),
  applications: Int,
) -> StepTransition(state, output) {
  case fuel > 0 {
    False ->
      Failed(
        state,
        list.reverse(accumulated),
        ReprocessLimitExhausted(applications),
      )
    True -> {
      let #(next_state, produced, consumed) = case advance(state, input) {
        Consumed(state: next_state, outputs: produced) -> #(
          next_state,
          produced,
          True,
        )
        Reprocess(state: next_state, outputs: produced) -> #(
          next_state,
          produced,
          False,
        )
      }
      let accumulated = prepend_all(accumulated, produced)
      let total = list.length(accumulated)
      let applications = applications + 1
      case total > capacity {
        True ->
          Failed(
            next_state,
            list.reverse(accumulated),
            CapacityExceeded(capacity, total),
          )
        False ->
          case consumed {
            True -> Settled(next_state, list.reverse(accumulated), applications)
            False ->
              loop(
                next_state,
                input,
                advance,
                fuel - 1,
                capacity,
                accumulated,
                applications,
              )
          }
      }
    }
  }
}

fn prepend_all(
  accumulated: List(output),
  produced: List(output),
) -> List(output) {
  list.fold(produced, accumulated, fn(acc, item) { [item, ..acc] })
}
