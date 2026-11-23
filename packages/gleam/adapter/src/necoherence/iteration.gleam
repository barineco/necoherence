// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import necoherence/call.{type Immediate, CallFailed, CallOk, Request}

/// A round's own progress measure, read from the step's output.
pub type Measure =
  Int

/// Where, in a run of rounds, one round's own projection failed.
pub type StageProjectionFailed {
  StageProjectionFailed(position: Int, failure: call.ProjectionFailed)
}

/// Input to a fold run: a step declaration, its seed, how many rounds to
/// run, and the field names present on every round's own input.
pub type FoldReq(s) {
  FoldReq(step: Immediate(s, s), seed: s, count: Int, step_fields: List(String))
}

/// Closed outcome of a fold run.
pub type FoldOutcome(s) {
  FoldTrace(states: List(s))
  FoldStopped(states: List(s), stopped: StageProjectionFailed)
}

fn fold_loop(
  step: Immediate(s, s),
  step_fields: List(String),
  remaining: Int,
  state: s,
  acc: List(s),
  position: Int,
) -> FoldOutcome(s) {
  case remaining {
    n if n <= 0 -> FoldTrace(list.reverse(acc))
    _ ->
      case call.io(step, Request(state, step_fields)) {
        CallOk(next) ->
          fold_loop(
            step,
            step_fields,
            remaining - 1,
            next,
            [next, ..acc],
            position + 1,
          )
        CallFailed(f) ->
          FoldStopped(list.reverse(acc), StageProjectionFailed(position, f))
      }
  }
}

/// Run the step through a call at most `count` times from the seed. Stops
/// at the first round whose call fails to project and reports that round's
/// position; otherwise runs every round.
pub fn fold(req: FoldReq(s)) -> FoldOutcome(s) {
  fold_loop(req.step, req.step_fields, req.count, req.seed, [req.seed], 0)
}

/// Next state together with this round's own measure toward termination, or
/// the confirmed final state.
pub type StepOutcome(s) {
  Advance(state: s, measure: Measure)
  Settled(state: s)
}

/// Input to a recurse run: a step declaration, its seed, and the field
/// names present on every round's own input.
pub type RecurseReq(s) {
  RecurseReq(
    step: Immediate(s, StepOutcome(s)),
    seed: s,
    step_fields: List(String),
  )
}

/// Closed outcome of a recurse run.
pub type RecurseOutcome(s) {
  RecurseSettled(value: s, steps: Int)
  RecurseDidNotDecrease(
    position: Int,
    state: s,
    measure: Measure,
    previous_measure: Measure,
  )
  RecurseProjectionFailed(last_state: s, stopped: StageProjectionFailed)
}

fn recurse_loop(
  step: Immediate(s, StepOutcome(s)),
  step_fields: List(String),
  state: s,
  bound: Measure,
  position: Int,
) -> RecurseOutcome(s) {
  case call.io(step, Request(state, step_fields)) {
    CallFailed(f) ->
      RecurseProjectionFailed(state, StageProjectionFailed(position, f))
    CallOk(Settled(value)) -> RecurseSettled(value, position)
    CallOk(Advance(next, measure)) ->
      case measure < bound {
        True -> recurse_loop(step, step_fields, next, measure, position + 1)
        False -> RecurseDidNotDecrease(position, next, measure, bound)
      }
  }
}

/// Call the step from the seed until it settles. The first round sets the
/// bound from its own reported measure; every later round must report a
/// strictly smaller measure or the run stops early. A round whose call
/// fails to project stops the run instead.
pub fn recurse(req: RecurseReq(s)) -> RecurseOutcome(s) {
  case call.io(req.step, Request(req.seed, req.step_fields)) {
    CallFailed(f) ->
      RecurseProjectionFailed(req.seed, StageProjectionFailed(0, f))
    CallOk(Settled(value)) -> RecurseSettled(value, 0)
    CallOk(Advance(next, measure)) ->
      recurse_loop(req.step, req.step_fields, next, measure, 1)
  }
}

/// Input to a closure's step: the current accumulated subset of the
/// carrier, given as a list with no meaningful order or duplication.
pub type ClosureState(t) {
  ClosureState(elements: List(t))
}

/// Input to a closure run: a monotone step declaration, its finite carrier,
/// a seed subset, and the field names present on every round's own input.
pub type ClosureReq(t) {
  ClosureReq(
    step: Immediate(ClosureState(t), List(t)),
    carrier: List(t),
    seed: List(t),
    step_fields: List(String),
  )
}

/// Closed outcome of a closure run.
pub type ClosureOutcome(t) {
  Fixpoint(result: List(t), position: Int)
  Violation(position: Int, current: List(t), produced: List(t))
  ClosureProjectionFailed(current: List(t), stopped: StageProjectionFailed)
}

fn set_subset(a: List(t), b: List(t)) -> Bool {
  list.all(a, fn(x) { list.contains(b, x) })
}

fn set_eq(a: List(t), b: List(t)) -> Bool {
  set_subset(a, b) && set_subset(b, a)
}

fn closure_loop(
  step: Immediate(ClosureState(t), List(t)),
  step_fields: List(String),
  carrier: List(t),
  current: List(t),
  position: Int,
) -> ClosureOutcome(t) {
  case call.io(step, Request(ClosureState(current), step_fields)) {
    CallFailed(f) ->
      ClosureProjectionFailed(current, StageProjectionFailed(position, f))
    CallOk(produced) ->
      case set_eq(produced, current) {
        True -> Fixpoint(current, position)
        False ->
          case set_subset(current, produced) && set_subset(produced, carrier) {
            True ->
              closure_loop(step, step_fields, carrier, produced, position + 1)
            False -> Violation(position, current, produced)
          }
      }
  }
}

/// Call the step from the seed until the accumulated subset stops growing.
/// Each round's output must extend that round's own input and stay within
/// the carrier; either failing returns a declared outcome branch.
pub fn closure(req: ClosureReq(t)) -> ClosureOutcome(t) {
  closure_loop(req.step, req.step_fields, req.carrier, req.seed, 0)
}
