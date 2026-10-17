// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT


export interface PositiveLimit {
  readonly kind: "PositiveLimit";
  readonly value: bigint;
}

export interface Capacity {
  readonly kind: "Capacity";
  readonly value: bigint;
}

export type LimitError = { readonly tag: "LimitNotPositive"; readonly value: bigint };
export type CapacityError = { readonly tag: "CapacityNegative"; readonly value: bigint };

export function positiveLimit(value: bigint): PositiveLimit | LimitError {
  return value > 0n
    ? Object.freeze({ kind: "PositiveLimit", value })
    : Object.freeze({ tag: "LimitNotPositive", value });
}

export function capacity(value: bigint): Capacity | CapacityError {
  return value >= 0n
    ? Object.freeze({ kind: "Capacity", value })
    : Object.freeze({ tag: "CapacityNegative", value });
}

export type Consumption<S, O> =
  | { readonly tag: "Consumed"; readonly state: S; readonly outputs: readonly O[] }
  | { readonly tag: "Reprocess"; readonly state: S; readonly outputs: readonly O[] };

export function consumed<S, O>(state: S, outputs: readonly O[]): Consumption<S, O> {
  return Object.freeze({ tag: "Consumed", state, outputs: Object.freeze([...outputs]) });
}

export function reprocess<S, O>(state: S, outputs: readonly O[]): Consumption<S, O> {
  return Object.freeze({ tag: "Reprocess", state, outputs: Object.freeze([...outputs]) });
}

export type StepFailure =
  | { readonly tag: "ReprocessLimitExhausted"; readonly applications: bigint }
  | { readonly tag: "CapacityExceeded"; readonly capacity: bigint; readonly attempted: bigint };

export type StepTransition<S, O> =
  | {
      readonly tag: "Settled";
      readonly state: S;
      readonly outputs: readonly O[];
      readonly applications: bigint;
    }
  | {
      readonly tag: "Failed";
      readonly state: S;
      readonly outputs: readonly O[];
      readonly failure: StepFailure;
    };

export function step<S, I, O>(
  initial: S,
  input: I,
  advance: (state: S, input: I) => Consumption<S, O>,
  limit: PositiveLimit,
  bound: Capacity
): StepTransition<S, O> {
  let state = initial;
  const accumulated: O[] = [];
  let applications = 0n;
  let fuel = limit.value;
  while (fuel > 0n) {
    const decision = advance(state, input);
    state = decision.state;
    accumulated.push(...decision.outputs);
    applications += 1n;
    if (BigInt(accumulated.length) > bound.value) {
      return Object.freeze({
        tag: "Failed",
        state,
        outputs: Object.freeze([...accumulated]),
        failure: Object.freeze({
          tag: "CapacityExceeded",
          capacity: bound.value,
          attempted: BigInt(accumulated.length),
        }),
      });
    }
    if (decision.tag === "Consumed") {
      return Object.freeze({ tag: "Settled", state, outputs: Object.freeze([...accumulated]), applications });
    }
    fuel -= 1n;
  }
  return Object.freeze({
    tag: "Failed",
    state,
    outputs: Object.freeze([...accumulated]),
    failure: Object.freeze({ tag: "ReprocessLimitExhausted", applications }),
  });
}
