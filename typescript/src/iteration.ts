// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

// Iterative call forms whose step-count upper bound is readable from the
// input, with no caller-supplied fuel argument.

import {
  io,
  requestOf,
  type CallResult,
  type Immediate,
  type ProjectionFailed,
} from "./call.js";

export type Measure = bigint;

export interface StageProjectionFailed {
  readonly position: bigint;
  readonly failure: ProjectionFailed;
}

export function stageProjectionFailed(
  position: bigint,
  failure: ProjectionFailed
): StageProjectionFailed {
  return Object.freeze({ position, failure });
}

function callIo<S, P>(step: Immediate<S, P>, state: S, stepFields: readonly string[]): CallResult<P> {
  return io(step, requestOf(state, stepFields));
}

// -- fold --------------------------------------------------------------------

export interface FoldReq<S> {
  readonly step: Immediate<S, S>;
  readonly seed: S;
  readonly count: bigint;
  readonly stepFields: readonly string[];
}

export interface FoldTrace<S> {
  readonly tag: "FoldTrace";
  readonly states: readonly S[];
}

export interface FoldStopped<S> {
  readonly tag: "FoldStopped";
  readonly states: readonly S[];
  readonly stopped: StageProjectionFailed;
}

export type FoldOutcome<S> = FoldTrace<S> | FoldStopped<S>;

function foldOutput<S>(req: FoldReq<S>): FoldOutcome<S> {
  const states: S[] = [req.seed];
  let state = req.seed;
  for (let position = 0n; position < req.count; position += 1n) {
    const round = callIo(req.step, state, req.stepFields);
    if (round.tag === "Failed") {
      return Object.freeze({
        tag: "FoldStopped",
        states: Object.freeze([...states]),
        stopped: stageProjectionFailed(position, round.failure),
      });
    }
    state = round.value;
    states.push(state);
  }
  return Object.freeze({
    tag: "FoldTrace",
    states: Object.freeze([...states]),
  });
}

export const fold: Immediate<FoldReq<unknown>, FoldOutcome<unknown>> = Object.freeze({
  identity: "necoherence.iteration.fold",
  required: Object.freeze(["step", "seed", "count", "stepFields"]),
  output: foldOutput as (req: FoldReq<unknown>) => FoldOutcome<unknown>,
});

// -- recurse -----------------------------------------------------------------

export interface Advance<S> {
  readonly tag: "Advance";
  readonly state: S;
  readonly measure: Measure;
}

export interface Settled<S> {
  readonly tag: "Settled";
  readonly state: S;
}

export type StepOutcome<S> = Advance<S> | Settled<S>;

export function advance<S>(state: S, measure: Measure): Advance<S> {
  return Object.freeze({ tag: "Advance", state, measure });
}

export function settled<S>(state: S): Settled<S> {
  return Object.freeze({ tag: "Settled", state });
}

export interface RecurseReq<S> {
  readonly step: Immediate<S, StepOutcome<S>>;
  readonly seed: S;
  readonly stepFields: readonly string[];
}

export interface RecurseSettled<S> {
  readonly tag: "RecurseSettled";
  readonly value: S;
  readonly steps: bigint;
}

export interface RecurseDidNotDecrease<S> {
  readonly tag: "RecurseDidNotDecrease";
  readonly position: bigint;
  readonly state: S;
  readonly measure: Measure;
  readonly previousMeasure: Measure;
}

export interface RecurseProjectionFailed<S> {
  readonly tag: "RecurseProjectionFailed";
  readonly lastState: S;
  readonly stopped: StageProjectionFailed;
}

export type RecurseOutcome<S> =
  | RecurseSettled<S>
  | RecurseDidNotDecrease<S>
  | RecurseProjectionFailed<S>;

function recurseOutput<S>(req: RecurseReq<S>): RecurseOutcome<S> {
  let state = req.seed;
  let previousMeasure: Measure | null = null;
  let position = 0n;
  for (;;) {
    const round = callIo(req.step, state, req.stepFields);
    if (round.tag === "Failed") {
      return Object.freeze({
        tag: "RecurseProjectionFailed",
        lastState: state,
        stopped: stageProjectionFailed(position, round.failure),
      });
    }
    const outcome = round.value;
    if (outcome.tag === "Settled") {
      return Object.freeze({
        tag: "RecurseSettled",
        value: outcome.state,
        steps: position,
      });
    }
    if (previousMeasure !== null && outcome.measure >= previousMeasure) {
      return Object.freeze({
        tag: "RecurseDidNotDecrease",
        position,
        state: outcome.state,
        measure: outcome.measure,
        previousMeasure,
      });
    }
    previousMeasure = outcome.measure;
    state = outcome.state;
    position += 1n;
  }
}

export const recurse: Immediate<RecurseReq<unknown>, RecurseOutcome<unknown>> = Object.freeze({
  identity: "necoherence.iteration.recurse",
  required: Object.freeze(["step", "seed", "stepFields"]),
  output: recurseOutput as (req: RecurseReq<unknown>) => RecurseOutcome<unknown>,
});

// -- closure -----------------------------------------------------------------

export interface ClosureState<T> {
  readonly elements: readonly T[];
}

export function closureState<T>(elements: readonly T[]): ClosureState<T> {
  return Object.freeze({ elements: Object.freeze([...elements]) });
}

export interface ClosureReq<T> {
  readonly step: Immediate<ClosureState<T>, readonly T[]>;
  readonly carrier: readonly T[];
  readonly seed: readonly T[];
  readonly stepFields: readonly string[];
}

export interface ClosureFixpoint<T> {
  readonly tag: "ClosureFixpoint";
  readonly result: readonly T[];
  readonly position: bigint;
}

export interface ClosureViolation<T> {
  readonly tag: "ClosureViolation";
  readonly position: bigint;
  readonly current: readonly T[];
  readonly produced: readonly T[];
}

export interface ClosureProjectionFailed<T> {
  readonly tag: "ClosureProjectionFailed";
  readonly current: readonly T[];
  readonly stopped: StageProjectionFailed;
}

export type ClosureOutcome<T> =
  | ClosureFixpoint<T>
  | ClosureViolation<T>
  | ClosureProjectionFailed<T>;

function isSubset<T>(inner: readonly T[], outer: readonly T[]): boolean {
  const outerSet = new Set(outer);
  return inner.every((value) => outerSet.has(value));
}

function sameSet<T>(left: readonly T[], right: readonly T[]): boolean {
  return isSubset(left, right) && isSubset(right, left);
}

function closureOutput<T>(req: ClosureReq<T>): ClosureOutcome<T> {
  let current = req.seed;
  let position = 0n;
  for (;;) {
    const round = callIo(req.step, closureState(current), req.stepFields);
    if (round.tag === "Failed") {
      return Object.freeze({
        tag: "ClosureProjectionFailed",
        current,
        stopped: stageProjectionFailed(position, round.failure),
      });
    }
    const produced = round.value;
    if (sameSet(produced, current)) {
      return Object.freeze({
        tag: "ClosureFixpoint",
        result: current,
        position,
      });
    }
    if (!isSubset(current, produced) || !isSubset(produced, req.carrier)) {
      return Object.freeze({
        tag: "ClosureViolation",
        position,
        current,
        produced,
      });
    }
    current = produced;
    position += 1n;
  }
}

export const closure: Immediate<ClosureReq<unknown>, ClosureOutcome<unknown>> = Object.freeze({
  identity: "necoherence.iteration.closure",
  required: Object.freeze(["step", "carrier", "seed", "stepFields"]),
  output: closureOutput as (req: ClosureReq<unknown>) => ClosureOutcome<unknown>,
});
