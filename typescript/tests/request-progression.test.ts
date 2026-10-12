// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import fc from "fast-check";
import {
  applyCompletionObservation,
  applyStartObservation,
  decideCancel,
  decideStart,
  derivePending,
  empty,
  submit,
  type RequestIdentity,
  type RequestInput,
  type RequestPolicy,
  type ResourceBudget,
} from "../src/request-progression.js";

const budget: ResourceBudget = { pendingMaximum: { resource: "r", maximum: 4n }, inFlightMaximum: { resource: "r", maximum: 1n }, concurrentMaximum: { resource: "r", maximum: 3n } };
const identity: RequestIdentity = { kind: "test", provenance: "r1", revision: 0n };
const newer: RequestIdentity = { kind: "test", provenance: "r2", revision: 1n };
const footprint = { reads: ["read:1"], writes: [] as readonly string[], effectClass: "Pure" as const };
const demand = { pending: 2n, inFlight: 1n, concurrent: 1n };
const permitted = { tag: "permitted" as const, identity, evidence: [] };
const denied = { tag: "denied" as const, identity, reason: { tag: "denial" as const, detail: "no" } };
const selection = { tag: "executeNow" as const, identity, evidence: { identifier: "e", digest: "d", artifactPath: "p" }, cost: 1n };

function submitted(permission: RequestInput["permission"] = permitted) {
  const result = submit(empty("LatestWins", budget), { identity, footprint, demand, permission });
  if (result.tag !== "accepted") throw new Error("submission failed");
  return result;
}
function executing() {
  const source = submitted();
  const decision = decideStart(source.snapshot, source.accepted, selection);
  if (decision.tag !== "execute") throw new Error("start decision failed");
  return decision;
}
function publishing() {
  const decision = executing();
  const result = applyStartObservation(decision.snapshot, decision.starting, { tag: "appliedSignal", signal: { tag: "started", identity, handle: { value: "h1" } } });
  if (result.tag !== "publishing") throw new Error("start observation failed");
  return result;
}

describe("request progression", () => {
  it("submit rejects a duplicate identity", () => {
    const source = submitted();
    expect(submit(source.snapshot, { identity, footprint, demand, permission: permitted }).tag).toBe("submitRejected");
  });

  it("decides execution before applying the independent start observation", () => {
    const decision = executing();
    expect(decision.snapshot.entries[0]?.phase).toBe("Preparing");
    const result = applyStartObservation(decision.snapshot, decision.starting, { tag: "appliedSignal", signal: { tag: "started", identity, handle: { value: "h1" } } });
    expect(result.tag).toBe("publishing");
  });

  it("defers without adapter observation", () => {
    const source = submitted();
    const result = decideStart(source.snapshot, source.accepted, { ...selection, tag: "remainPending" });
    expect(result.tag).toBe("deferred");
    if (result.tag === "deferred") expect(result.snapshot.entries[0]?.phase).toBe("Pending");
  });

  it("rejects a denied permission before touching budgets", () => {
    const source = submitted(denied);
    expect(decideStart(source.snapshot, source.accepted, selection).tag).toBe("rejected");
  });

  it("applies matching completion after publishing", () => {
    const started = publishing();
    const result = applyCompletionObservation(started.snapshot, started.running, { tag: "appliedSignal", signal: { tag: "completed", identity, handle: { value: "h1" }, value: "done" } });
    expect(result).toEqual({ tag: "applied", snapshot: expect.anything(), identity, value: "done" });
  });

  it("supersedes stale LatestWins completion without advancing the new request", () => {
    const started = publishing();
    const newerInput: RequestInput = { identity: newer, footprint, demand, permission: { ...permitted, identity: newer } };
    const next = submit(started.snapshot, newerInput);
    if (next.tag !== "accepted") throw new Error("new submission failed");
    const result = applyCompletionObservation(next.snapshot, started.running, { tag: "appliedSignal", signal: { tag: "completed", identity, handle: { value: "h1" }, value: "stale" } });
    expect(result.tag).toBe("superseded");
    if (result.tag === "superseded") {
      expect(result.snapshot.revision).toBe(next.snapshot.revision);
      expect(result.snapshot.entries.find((entry) => entry.identity.provenance === newer.provenance)?.phase).toBe("Pending");
    }
  });

  it("cancels pending immediately and publishing with a command", () => {
    const source = submitted();
    expect(decideCancel(source.snapshot, identity).tag).toBe("cancelled");
    const started = publishing();
    expect(decideCancel(started.snapshot, identity).tag).toBe("cancelCommand");
  });

  it("rejects preparing cancellation for its missing handle", () => {
    const decision = executing();
    const result = decideCancel(decision.snapshot, identity);
    expect(result).toMatchObject({ tag: "rejected", failure: { tag: "missingExecutionHandle" } });
  });

  it("fast-check: derivePending equals one accepted entry demand", () => {
    fc.assert(fc.property(fc.bigInt({ min: 0n, max: 4n }), (pending) => {
      const request: RequestInput = { identity, footprint, demand: { pending, inFlight: 0n, concurrent: 0n }, permission: permitted };
      const result = submit(empty("AllExecute", budget), request);
      if (result.tag === "accepted") expect(derivePending(result.snapshot).pending).toBe(pending);
    }));
  });

  it("fast-check: every policy accepts its first submission", () => {
    fc.assert(fc.property(fc.constantFrom<RequestPolicy>("LatestWins", "Fifo", "AllExecute"), (policy) => {
      expect(submit(empty(policy, budget), { identity, footprint, demand: { pending: 1n, inFlight: 0n, concurrent: 0n }, permission: permitted }).tag).toBe("accepted");
    }));
  });
});
