// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import fc from "fast-check";
import {
  applyCompletionObservation,
  applyStartObservation,
  decideCancel,
  decideStart,
  deriveConcurrent,
  deriveInFlight,
  derivePending,
  empty,
  findRequest,
  progressionBudget,
  progressionCurrentIdentity,
  progressionEntries,
  progressionPolicy,
  progressionRevision,
  snapshotOf,
  submit,
  type RequestEntry,
  type RequestIdentity,
  type RequestPhase,
  type RequestPolicy,
  type RequestProgressionSnapshot,
  type ResourceBudget,
  type ResourceDemand,
} from "../src/request-progression.js";

const budget: ResourceBudget = {
  pendingMaximum: { resource: "r", maximum: 1000n },
  inFlightMaximum: { resource: "r", maximum: 1000n },
  concurrentMaximum: { resource: "r", maximum: 1000n },
};
const evidence = { identifier: "e", digest: "d", artifactPath: "p" };

type Step =
  | { readonly kind: "submit"; readonly ordered: boolean; readonly weight: number }
  | { readonly kind: "start"; readonly pick: number; readonly now: boolean }
  | { readonly kind: "started"; readonly pick: number }
  | { readonly kind: "completed"; readonly pick: number }
  | { readonly kind: "cancel"; readonly pick: number };

const stepArb: fc.Arbitrary<Step> = fc.oneof(
  fc.record({ kind: fc.constant("submit" as const), ordered: fc.boolean(), weight: fc.integer({ min: 1, max: 5 }) }),
  fc.record({ kind: fc.constant("start" as const), pick: fc.nat(40), now: fc.boolean() }),
  fc.record({ kind: fc.constant("started" as const), pick: fc.nat(40) }),
  fc.record({ kind: fc.constant("completed" as const), pick: fc.nat(40) }),
  fc.record({ kind: fc.constant("cancel" as const), pick: fc.nat(40) })
);

function identityOf(index: number): RequestIdentity {
  return { kind: "k", provenance: "p", revision: BigInt(index) };
}

function sumFor(entries: readonly RequestEntry[], phases: readonly RequestPhase[]): ResourceDemand {
  return entries
    .filter((entry) => phases.includes(entry.phase))
    .reduce<ResourceDemand>(
      (total, entry) => ({
        pending: total.pending + entry.demand.pending,
        inFlight: total.inFlight + entry.demand.inFlight,
        concurrent: total.concurrent + entry.demand.concurrent,
      }),
      { pending: 0n, inFlight: 0n, concurrent: 0n }
    );
}

function firstPending(entries: readonly RequestEntry[], ordered: boolean): RequestEntry | undefined {
  return entries.find((entry) => entry.phase === "Pending" && (!ordered || entry.footprint.effectClass === "OrderedEffect"));
}

function check(snapshot: RequestProgressionSnapshot): void {
  const entries = progressionEntries(snapshot);
  expect(derivePending(snapshot)).toEqual(sumFor(entries, ["Pending"]));
  expect(deriveInFlight(snapshot)).toEqual(sumFor(entries, ["Preparing", "Publishing"]));
  expect(deriveConcurrent(snapshot)).toEqual(sumFor(entries, ["Publishing"]));
  const rebuilt = snapshotOf(progressionPolicy(snapshot), progressionBudget(snapshot), progressionCurrentIdentity(snapshot), entries, progressionRevision(snapshot));
  expect(rebuilt.tag).toBe("snapshot");
  if (rebuilt.tag === "snapshot") {
    expect(derivePending(rebuilt.snapshot)).toEqual(derivePending(snapshot));
    expect(deriveInFlight(rebuilt.snapshot)).toEqual(deriveInFlight(snapshot));
    expect(deriveConcurrent(rebuilt.snapshot)).toEqual(deriveConcurrent(snapshot));
  }
  for (const entry of entries) expect(findRequest(snapshot, entry.identity)).toBe(entry);
}

function run(policy: RequestPolicy, steps: readonly Step[]): void {
  let snapshot = empty(policy, budget);
  let counter = 0;
  for (const step of steps) {
    const entries = progressionEntries(snapshot);
    const target = entries.length === 0 ? undefined : entries[step.kind === "submit" ? 0 : step.pick % entries.length];
    if (step.kind === "submit") {
      const identity = identityOf(counter);
      counter += 1;
      const demand = { pending: BigInt(step.weight), inFlight: 1n, concurrent: 1n };
      const result = submit(snapshot, {
        identity,
        footprint: { reads: [], writes: [], effectClass: step.ordered ? "OrderedEffect" : "Pure" },
        demand,
        permission: step.ordered ? { tag: "ordered", identity, evidence: [evidence] } : { tag: "permitted", identity, evidence: [evidence] },
      });
      snapshot = result.snapshot;
    } else if (target !== undefined && step.kind === "start") {
      const selection = { tag: step.now ? ("executeNow" as const) : ("remainPending" as const), identity: target.identity, evidence, cost: 1n };
      snapshot = decideStart(snapshot, { identity: target.identity }, selection).snapshot;
    } else if (target !== undefined && step.kind === "started") {
      const handle = { value: `h${counter}` };
      snapshot = applyStartObservation(snapshot, { identity: target.identity, command: { tag: "startCommand", identity: target.identity, footprint: target.footprint } }, { tag: "appliedSignal", signal: { tag: "started", identity: target.identity, handle } }).snapshot;
    } else if (target !== undefined && step.kind === "completed" && target.executionHandle !== null) {
      snapshot = applyCompletionObservation(snapshot, { identity: target.identity, handle: target.executionHandle }, { tag: "appliedSignal", signal: { tag: "completed", identity: target.identity, handle: target.executionHandle, value: 0 } }).snapshot;
    } else if (target !== undefined && step.kind === "cancel") {
      snapshot = decideCancel(snapshot, target.identity).snapshot;
    }
    check(snapshot);
  }
}

describe("request progression invariants after generated operation sequences", () => {
  for (const policy of ["LatestWins", "Fifo", "AllExecute"] as const) {
    it(`keeps the maintained totals equal to the derivation from the entries under ${policy}`, () => {
      fc.assert(fc.property(fc.array(stepArb, { maxLength: 40 }), (steps) => run(policy, steps)), { numRuns: 200 });
    });
  }

  it("blocks an ordered effect exactly when an earlier pending ordered effect exists", () => {
    fc.assert(
      fc.property(fc.array(fc.boolean(), { minLength: 1, maxLength: 30 }), (flags) => {
        let snapshot = empty("AllExecute", budget);
        flags.forEach((ordered, index) => {
          const identity = identityOf(index);
          snapshot = submit(snapshot, {
            identity,
            footprint: { reads: [], writes: [], effectClass: ordered ? "OrderedEffect" : "Pure" },
            demand: { pending: 1n, inFlight: 1n, concurrent: 1n },
            permission: ordered ? { tag: "ordered", identity, evidence: [evidence] } : { tag: "permitted", identity, evidence: [evidence] },
          }).snapshot;
        });
        const entries = progressionEntries(snapshot);
        const earliestOrdered = firstPending(entries, true);
        for (const entry of entries) {
          const result = decideStart(snapshot, { identity: entry.identity }, { tag: "remainPending", identity: entry.identity, evidence, cost: 1n });
          const blocked = result.tag === "rejected" && result.failure.tag === "policyOrderBlocked";
          const expectedBlocked = entry.footprint.effectClass === "OrderedEffect" && earliestOrdered !== undefined && earliestOrdered.identity !== entry.identity;
          expect(blocked).toBe(expectedBlocked);
        }
      })
    );
  });

  it("rejects an entry list with a repeated identity", () => {
    const identity = identityOf(1);
    const entry: RequestEntry = {
      identity,
      footprint: { reads: [], writes: [], effectClass: "Pure" },
      demand: { pending: 1n, inFlight: 1n, concurrent: 1n },
      phase: "Pending",
      meaningPermission: { tag: "permitted", identity, evidence: [evidence] },
      costSelection: null,
      executionHandle: null,
    };
    const result = snapshotOf("Fifo", budget, null, [entry, entry], 0n);
    expect(result.tag).toBe("snapshotRejected");
  });
});
