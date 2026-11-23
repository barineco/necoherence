// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import { admissionStateConfiguredSafetyLimit, admissionStateOf, admissionStateProgression, admissionStateProvenance, admitDynamicRequest, elideAdmissionProvenance, type DynamicAdmissionInput, type DynamicAdmissionState } from "../src/dynamic-admission.js";
import { empty, progressionBudget, progressionCurrentIdentity, progressionEntries, progressionPolicy, progressionRevision, snapshotOf, type RequestIdentity, type ResourceBudget } from "../src/request-progression.js";

const budget: ResourceBudget = {
  pendingMaximum: { resource: "r", maximum: 3n },
  inFlightMaximum: { resource: "r", maximum: 1n },
  concurrentMaximum: { resource: "r", maximum: 1n },
};

const identity: RequestIdentity = { kind: "test", provenance: "request-1", revision: 0n };
const footprint = { reads: ["heap:1"], writes: [] as readonly string[], effectClass: "Pure" as const };
const permitted = { tag: "permitted" as const, identity, evidence: [] };
const denied = { tag: "denied" as const, identity, reason: { tag: "denial" as const, detail: "no" } };

function state(): DynamicAdmissionState {
  return admissionStateOf(empty("LatestWins", budget), budget, { futureUses: [], outstandingSignals: [] });
}

function input(overrides: Partial<DynamicAdmissionInput> = {}): DynamicAdmissionInput {
  return {
    state: state(),
    request: { identity, footprint, demand: { pending: 1n, inFlight: 1n, concurrent: 1n }, permission: permitted },
    environmentSpecification: { maxObservationAge: 10n },
    capacityObservation: { observed: budget, observedAt: 0n },
    observedAt: 0n,
    start: null,
    ...overrides,
  };
}

describe("dynamic admission", () => {
  it("submits without start when no start is requested", () => {
    const result = admitDynamicRequest(input());
    expect(result.tag).toBe("Applied");
    if (result.tag === "Applied") expect(result.value.admissionDecision.tag).toBe("Submitted");
  });

  it("rejects a denied permission", () => {
    const result = admitDynamicRequest(
      input({ request: { identity, footprint, demand: { pending: 1n, inFlight: 1n, concurrent: 1n }, permission: denied } })
    );
    expect(result.tag).toBe("Rejected");
    if (result.tag === "Rejected") expect(result.reason.tag).toBe("MeaningDenied");
  });

  it("rejects an expired capacity observation", () => {
    const result = admitDynamicRequest(input({ observedAt: 100n }));
    expect(result.tag).toBe("Rejected");
    if (result.tag === "Rejected") expect(result.reason.tag).toBe("CapacityObservationUnavailable");
  });

  it("coalesces an identical restored pending duplicate", () => {
    const first = admitDynamicRequest(input());
    expect(first.tag).toBe("Applied");
    if (first.tag !== "Applied" || first.value.admissionDecision.tag !== "Submitted") return;
    const advancedState = first.value.admissionDecision.state;
    const second = admitDynamicRequest(input({ state: advancedState }));
    expect(second.tag).toBe("Applied");
    if (second.tag === "Applied") expect(second.value.admissionDecision.tag).toBe("Coalesced");
  });

  it("elideAdmissionProvenance rejects an unknown identity", () => {
    const result = elideAdmissionProvenance(state(), identity);
    expect(result.tag).toBe("Rejected");
    if (result.tag === "Rejected") expect(result.reason.tag).toBe("UnknownRequest");
  });

  it("elideAdmissionProvenance erases a terminal entry with no live provenance", () => {
    const first = admitDynamicRequest(input());
    expect(first.tag).toBe("Applied");
    if (first.tag !== "Applied" || first.value.admissionDecision.tag !== "Submitted") return;
    const submittedState = first.value.admissionDecision.state;
    const progression = admissionStateProgression(submittedState);
    const cancelledProgression = snapshotOf(
      progressionPolicy(progression),
      progressionBudget(progression),
      progressionCurrentIdentity(progression),
      progressionEntries(progression).map((entry) => ({ ...entry, phase: "Cancelled" as const })),
      progressionRevision(progression)
    );
    if (cancelledProgression.tag !== "snapshot") throw new Error("distinct identities expected");
    const cancelled = admissionStateOf(cancelledProgression.snapshot, admissionStateConfiguredSafetyLimit(submittedState), admissionStateProvenance(submittedState));
    const result = elideAdmissionProvenance(cancelled, identity);
    expect(result.tag).toBe("Applied");
    if (result.tag === "Applied") {
      expect(result.value[1]).toEqual({ target: identity, recoverability: { kind: "irrecoverable" }, removedObservations: ["Footprint", "Evidence"] });
    }
  });

  it("elideAdmissionProvenance keeps the progression revision and the other entries", () => {
    const first = admitDynamicRequest(input());
    if (first.tag !== "Applied" || first.value.admissionDecision.tag !== "Submitted") throw new Error("submitted expected");
    const submittedState = first.value.admissionDecision.state;
    const progression = admissionStateProgression(submittedState);
    const cancelledProgression = snapshotOf(
      progressionPolicy(progression),
      progressionBudget(progression),
      progressionCurrentIdentity(progression),
      progressionEntries(progression).map((entry) => ({ ...entry, phase: "Cancelled" as const })),
      progressionRevision(progression)
    );
    if (cancelledProgression.tag !== "snapshot") throw new Error("distinct identities expected");
    const cancelled = admissionStateOf(cancelledProgression.snapshot, admissionStateConfiguredSafetyLimit(submittedState), admissionStateProvenance(submittedState));
    const result = elideAdmissionProvenance(cancelled, identity);
    if (result.tag !== "Applied") throw new Error("applied expected");
    const after = admissionStateProgression(result.value[0]);
    expect(progressionRevision(after)).toBe(progressionRevision(progression));
    expect(progressionEntries(after).map((entry) => entry.phase)).toEqual(["Cancelled"]);
    expect(admissionStateProvenance(result.value[0])).toEqual(admissionStateProvenance(cancelled));
  });

  it("elideAdmissionProvenance retains provenance that a future use or an outstanding signal still holds", () => {
    const first = admitDynamicRequest(input());
    if (first.tag !== "Applied" || first.value.admissionDecision.tag !== "Submitted") throw new Error("submitted expected");
    const progression = admissionStateProgression(first.value.admissionDecision.state);
    const cancelledProgression = snapshotOf(
      progressionPolicy(progression),
      progressionBudget(progression),
      progressionCurrentIdentity(progression),
      progressionEntries(progression).map((entry) => ({ ...entry, phase: "Cancelled" as const })),
      progressionRevision(progression)
    );
    if (cancelledProgression.tag !== "snapshot") throw new Error("distinct identities expected");
    const held = admissionStateOf(cancelledProgression.snapshot, budget, { futureUses: [identity], outstandingSignals: [] });
    const signalled = admissionStateOf(cancelledProgression.snapshot, budget, {
      futureUses: [],
      outstandingSignals: [{ identity, handle: { value: "h" }, kind: "PendingCompletion" }],
    });
    const both = admissionStateOf(cancelledProgression.snapshot, budget, {
      futureUses: [identity],
      outstandingSignals: [{ identity, handle: { value: "h" }, kind: "PendingCompletion" }],
    });
    const expected = [
      [held, [{ kind: "futureUse", target: identity }]],
      [signalled, [{ kind: "outstandingSignal", target: identity }]],
      [both, [{ kind: "futureUse", target: identity }, { kind: "outstandingSignal", target: identity }]],
    ] as const;
    for (const [blocked, reasons] of expected) {
      const result = elideAdmissionProvenance(blocked, identity);
      expect(result.tag).toBe("Rejected");
      if (result.tag === "Rejected") expect(result.reason).toEqual({ tag: "ProvenanceRetentionRequired", identity, reasons });
    }
  });

  it("admissionState readers return the parts the state was built from", () => {
    const provenance = { futureUses: [identity], outstandingSignals: [] };
    const built = admissionStateOf(empty("Fifo", budget), budget, provenance);
    expect(admissionStateConfiguredSafetyLimit(built)).toBe(budget);
    expect(admissionStateProvenance(built)).toBe(provenance);
    expect(progressionEntries(admissionStateProgression(built))).toEqual([]);
  });
});
