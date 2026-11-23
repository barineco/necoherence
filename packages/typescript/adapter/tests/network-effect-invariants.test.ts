// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import fc from "fast-check";
import { networkEffect } from "../src/index.js";

type Record_ = networkEffect.AttemptRecord;
type State = networkEffect.NetworkState;

const configuration: networkEffect.HostConfiguration = {
  requestBodyLimit: 32n,
  responseBodyLimit: 32n,
  cancellation: { identity: { value: "cancel" } },
  monotonicClock: null,
};
const instruction: networkEffect.HttpWireInstruction = { method: "GET", target: "https://127.0.0.1/t", headers: [], body: new Uint8Array() };

function logical(index: number) {
  return { kind: "network", provenance: "generated", revision: BigInt(index) };
}

function inputOf(attempt: networkEffect.AttemptIdentity): networkEffect.AttemptInput {
  return { attempt, instruction, deadline: null, configuration };
}

function responseOf(record: Record_, delivery: bigint, handle: networkEffect.ExecutionHandle): networkEffect.HostObservation {
  return {
    tag: "Delivered",
    delivery,
    observation: {
      tag: "ResponseObservation",
      attempt: record.input.attempt,
      handle,
      sourceSequence: { tag: "none" },
      response: { status: 200, headers: [], body: Uint8Array.of(1, 2) },
      provenance: "LibraryNormalized",
      effect: { tag: "Unknown", reason: "NoResponse" },
    },
  };
}

interface Step {
  readonly kind: number;
  readonly pick: number;
  readonly flag: boolean;
}

const stepArb: fc.Arbitrary<Step> = fc.record({ kind: fc.nat(7), pick: fc.nat(30), flag: fc.boolean() });

function snapshotOf(state: State): readonly Record_[] {
  return networkEffect.networkAttempts(state);
}

function rebuilt(state: State): State {
  const result = networkEffect.networkStateOf(snapshotOf(state));
  if (result.tag !== "state") throw new Error(`state rejected: ${result.violation.tag}`);
  return result.state;
}

function advance(state: State, step: Step, counter: number): State {
  const records = snapshotOf(state);
  const record = records.length === 0 ? undefined : records[step.pick % records.length];
  const attempt = record?.input.attempt;
  const handle = { value: `handle-${step.pick}` };
  switch (step.kind) {
    case 0: {
      const next = networkEffect.prepare(state, inputOf({ logical: logical(counter), ordinal: 0n }));
      return next.state;
    }
    case 1:
      return record === undefined ? state : networkEffect.sendCommand(state, { input: record.input, chain: record.chain }).state;
    case 2:
      if (record === undefined || attempt === undefined) return state;
      return networkEffect.observeStart(state, { input: record.input, chain: record.chain }, step.flag
        ? { tag: "Started", attempt, handle }
        : { tag: "StartFailed", failure: { attempt, stage: "Start", configuration, cause: { tag: "ExecutionStartFailed" } }, effect: { tag: "Unknown", reason: "HostFailure" } }).state;
    case 3: {
      if (record === undefined || record.disposition.tag === "Prepared" || record.disposition.tag === "CommandIssued") return state;
      const known = record.disposition.handle ?? handle;
      const delivery = record.firstDelivery === null ? 0n : (record.late.at(-1)?.delivered.delivery ?? 0n) + 1n;
      return networkEffect.observe(state, responseOf(record, delivery, known)).state;
    }
    case 4:
      if (record === undefined || record.disposition.tag !== "Started") return state;
      return networkEffect.observe(state, { tag: "Pending", attempt: record.input.attempt, handle: record.disposition.handle }).state;
    case 5:
      if (record === undefined || attempt === undefined) return state;
      return networkEffect.annotateEffect(state, { attempt, status: { tag: "NoEffect", witness: { attempt, source: "Adapter", evidence: { value: "evidence" } } } }).state;
    case 6: {
      if (record === undefined || attempt === undefined) return state;
      const next = { logical: attempt.logical, ordinal: attempt.ordinal + 1n };
      return networkEffect.retry(state, {
        permission: { tag: "RetryAllowed", authorization: { logical: attempt.logical, from: attempt, next, protocolEvidence: { value: "protocol" } } },
        instruction,
        deadline: null,
        configuration,
      }).state;
    }
    default:
      if (record === undefined || record.disposition.tag !== "Started") return state;
      return networkEffect.cancelCommand(state, { prepared: { input: record.input, chain: record.chain }, handle: record.disposition.handle }).state;
  }
}

describe("network effect state invariants after generated operation sequences", () => {
  it("keeps every reachable state accepted by the checked constructor, with an index that agrees with the record list", () => {
    fc.assert(
      fc.property(fc.array(stepArb, { maxLength: 60 }), (steps) => {
        let state = networkEffect.emptyNetworkState();
        steps.forEach((step, index) => {
          const before = snapshotOf(state);
          const next = advance(state, step, index);
          expect(snapshotOf(state)).toEqual(before);
          const reconstructed = rebuilt(next);
          expect(snapshotOf(reconstructed)).toEqual(snapshotOf(next));
          const again = advance(reconstructed, step, index);
          expect(snapshotOf(again)).toEqual(snapshotOf(advance(next, step, index)));
          state = next;
        });
      }),
      { numRuns: 300 }
    );
  });

  it("reaches settled records, late deliveries and retries in the generated sequences", () => {
    const reached = new Set<string>();
    fc.assert(
      fc.property(fc.array(stepArb, { minLength: 30, maxLength: 60 }), (steps) => {
        let state = networkEffect.emptyNetworkState();
        steps.forEach((step, index) => {
          state = advance(state, step, index);
        });
        for (const record of snapshotOf(state)) {
          reached.add(record.disposition.tag);
          if (record.chain.tag === "RetryOf") reached.add("RetryOf");
          if (record.late.length > 0) reached.add("Late");
        }
      }),
      { numRuns: 300 }
    );
    expect([...reached].sort()).toEqual(["CommandIssued", "Late", "Prepared", "RetryOf", "Settled", "Started"]);
  });
});
