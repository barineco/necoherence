// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import { networkEffect } from "../src/index.js";

const {
  annotateEffect,
  cancelCommand,
  emptyNetworkState,
  networkStateOf,
  observe,
  observeStart,
  prepare,
  retry,
  sendCommand,
} = networkEffect;
type AttemptInput = networkEffect.AttemptInput;
type EffectObservation = networkEffect.EffectObservation;
type HostConfiguration = networkEffect.HostConfiguration;
type HttpWireInstruction = networkEffect.HttpWireInstruction;
type NetworkState = networkEffect.NetworkState;
type PreparedAttempt = networkEffect.PreparedAttempt;
type StartedAttempt = networkEffect.StartedAttempt;
const identity = { kind: "network", provenance: "test", revision: 0n };
const configuration: HostConfiguration = { requestBodyLimit: 32n, responseBodyLimit: 32n, cancellation: null, monotonicClock: null };
const instruction: HttpWireInstruction = { method: "GET", target: "https://127.0.0.1/test", headers: [], body: new Uint8Array() };
const input: AttemptInput = { attempt: { logical: identity, ordinal: 0n }, instruction, deadline: null, configuration };

function prepared(): { state: NetworkState; prepared: PreparedAttempt } {
  const result = prepare(emptyNetworkState(), input);
  if (result.tag !== "Prepared") throw new Error("expected prepared attempt");
  return { state: result.state, prepared: result.prepared };
}
function started(configurationOverride: HostConfiguration = configuration): { state: NetworkState; prepared: PreparedAttempt; started: StartedAttempt } {
  const rootInput = { ...input, configuration: configurationOverride };
  const root = prepare(emptyNetworkState(), rootInput);
  if (root.tag !== "Prepared") throw new Error("expected root");
  const issued = sendCommand(root.state, root.prepared);
  if (issued.tag !== "CommandReady") throw new Error("expected command");
  const result = observeStart(issued.state, root.prepared, { tag: "Started", attempt: rootInput.attempt, handle: { value: "h0" } });
  if (result.tag !== "Started") throw new Error("expected start");
  return { state: result.state, prepared: result.started.prepared, started: result.started };
}

describe("network effect pure surface", () => {
  it("rejects a record list with a repeated attempt key at construction", () => {
    const record = { input, chain: { tag: "Root" as const }, disposition: { tag: "Prepared" as const }, firstDelivery: null, late: [] };
    const result = networkStateOf([record, record]);
    expect(result).toEqual({ tag: "stateRejected", violation: { tag: "DuplicateAttemptKey", attempt: input.attempt } });
  });

  it("preserves state through prepare, command, start, delivery, and annotation", () => {
    const root = prepared();
    const issued = sendCommand(root.state, root.prepared);
    expect(issued.tag).toBe("CommandReady");
    if (issued.tag !== "CommandReady") return;
    const started = observeStart(issued.state, root.prepared, { tag: "Started", attempt: input.attempt, handle: { value: "h0" } });
    expect(started.tag).toBe("Started");
    if (started.tag !== "Started") return;
    const delivered = observe(started.state, { tag: "Delivered", delivery: 0n, observation: { tag: "ResponseObservation", attempt: input.attempt, handle: started.started.handle, sourceSequence: { tag: "some", value: 1n }, response: { status: 200, headers: [], body: Uint8Array.of(1, 255) }, provenance: "LibraryNormalized", effect: { tag: "Unknown", reason: "NoResponse" } } });
    expect(delivered.tag).toBe("Terminal");
    if (delivered.tag !== "Terminal") return;
    const annotation: EffectObservation = { attempt: input.attempt, status: { tag: "EffectOccurred", witness: { attempt: input.attempt, source: "Protocol", evidence: { value: "accepted" } } } };
    const applied = annotateEffect(delivered.state, annotation);
    expect(applied.tag).toBe("Applied");
  });
  it("covers generated input and lifecycle rejection branches", () => {
    for (const method of ["", "GET", "POST", "\u0000"]) {
      const candidate = prepare(emptyNetworkState(), { ...input, instruction: { ...instruction, method } });
      expect(candidate.tag).toBe(method === "" || method === "\u0000" ? "Rejected" : "Prepared");
    }
    const nonRoot = prepare(emptyNetworkState(), { ...input, attempt: { logical: identity, ordinal: 1n } });
    expect(nonRoot.tag).toBe("Rejected");
    const root = prepared();
    expect(prepare(root.state, input).tag).toBe("Rejected");
    const issued = sendCommand(root.state, root.prepared);
    if (issued.tag !== "CommandReady") throw new Error("expected command");
    expect(sendCommand(issued.state, root.prepared).tag).toBe("Rejected");
    expect(observeStart(root.state, root.prepared, { tag: "Started", attempt: input.attempt, handle: { value: "h0" } }).tag).toBe("Rejected");
    const running = started();
    expect(observe(running.state, { tag: "Pending", attempt: input.attempt, handle: running.started.handle }).tag).toBe("Pending");
    expect(annotateEffect(running.state, { attempt: input.attempt, status: { tag: "EffectOccurred", witness: { attempt: input.attempt, source: "Protocol", evidence: { value: "x" } } } }).tag).toBe("Rejected");
  });

  it("distinguishes pending, first, late, duplicate, conflict, and delivery order", () => {
    const running = started();
    const response = { tag: "ResponseObservation" as const, attempt: input.attempt, handle: running.started.handle, sourceSequence: { tag: "none" as const }, response: { status: 200, headers: [], body: new Uint8Array() }, provenance: "LibraryNormalized" as const, effect: { tag: "Unknown" as const, reason: "NoResponse" as const } };
    expect(observe(running.state, { tag: "Delivered", delivery: 1n, observation: response }).tag).toBe("Rejected");
    const terminal = observe(running.state, { tag: "Delivered", delivery: 0n, observation: response });
    if (terminal.tag !== "Terminal") throw new Error("expected terminal");
    expect(observe(terminal.state, { tag: "Delivered", delivery: 0n, observation: response }).tag).toBe("Duplicate");
    const conflict = { ...response, response: { status: 500, headers: [], body: new Uint8Array() } };
    expect(observe(terminal.state, { tag: "Delivered", delivery: 0n, observation: conflict }).tag).toBe("Rejected");
    const late = observe(terminal.state, { tag: "Delivered", delivery: 1n, observation: conflict });
    expect(late.tag).toBe("Late");
  });

  it("requires cancellation capability and applies retry authorization once", () => {
    const capability = { identity: { value: "cancel" } };
    const cancellable = started({ ...configuration, cancellation: capability });
    const cancel = (awaitable: typeof cancellable) => cancelCommand(awaitable.state, awaitable.started);
    expect(cancel(cancellable).tag).toBe("CommandReady");
    expect(cancel(started()).tag).toBe("Rejected");
    const response = { tag: "ResponseObservation" as const, attempt: input.attempt, handle: cancellable.started.handle, sourceSequence: { tag: "none" as const }, response: { status: 200, headers: [], body: new Uint8Array() }, provenance: "LibraryNormalized" as const, effect: { tag: "Unknown" as const, reason: "NoResponse" as const } };
    const settled = observe(cancellable.state, { tag: "Delivered", delivery: 0n, observation: response });
    if (settled.tag !== "Terminal") throw new Error("expected settled");
    const authorization = { logical: identity, from: input.attempt, next: { logical: identity, ordinal: 1n }, protocolEvidence: { value: "retry" } };
    const request = { permission: { tag: "RetryAllowed" as const, authorization }, instruction, deadline: null, configuration };
    const retried = retry(settled.state, request);
    expect(retried.tag).toBe("Prepared");
    if (retried.tag === "Prepared") expect(retry(retried.state, request).tag).toBe("Rejected");
  });

  it("reports the first failed token, condition, handle, and observation check", () => {
    const root = prepared();
    const instructionMismatch = sendCommand(root.state, {
      ...root.prepared,
      input: {
        ...root.prepared.input,
        instruction: { ...instruction, method: "POST" },
      },
    });
    expect(instructionMismatch).toMatchObject({
      tag: "Rejected",
      failure: { tag: "AttemptTokenMismatch", field: "Instruction" },
    });

    const issued = sendCommand(root.state, root.prepared);
    if (issued.tag !== "CommandReady") throw new Error("expected command");
    expect(sendCommand(issued.state, root.prepared)).toMatchObject({
      tag: "Rejected",
      failure: {
        tag: "CommandAlreadyIssued",
        attempt: root.prepared.input.attempt,
      },
    });
    expect(observeStart(issued.state, root.prepared, {
      tag: "Started",
      attempt: { logical: identity, ordinal: 1n },
      handle: { value: "h1" },
    })).toMatchObject({
      tag: "Rejected",
      failure: { tag: "IdentityMismatch" },
    });

    const running = started({
      ...configuration,
      cancellation: { identity: { value: "cancel" } },
    });
    expect(cancelCommand(running.state, {
      ...running.started,
      handle: { value: "other" },
    })).toMatchObject({
      tag: "Rejected",
      failure: {
        tag: "HandleMismatch",
        expected: running.started.handle,
        actual: { value: "other" },
      },
    });
    expect(observe(running.state, {
      tag: "Pending",
      attempt: input.attempt,
      handle: { value: "other" },
    })).toMatchObject({
      tag: "Rejected",
      failure: {
        tag: "HandleMismatch",
        expected: running.started.handle,
        actual: { value: "other" },
      },
    });
  });

  it("rejects a retry whose authorization.from belongs to a different logical request", () => {
    const logicalL = { kind: "k", provenance: "p", revision: 0n };
    const logicalM = { kind: "k", provenance: "p", revision: 1n };
    const settledTerminal: networkEffect.NetworkTerminal = {
      outcome: { tag: "Cancelled" },
      effect: { tag: "Unknown", reason: "NoResponse" },
    };
    const recordFor = (attempt: networkEffect.AttemptIdentity, chain: networkEffect.AttemptChain) => ({
      input: { attempt, instruction, deadline: null, configuration },
      chain,
      disposition: { tag: "Settled" as const, handle: null, terminal: settledTerminal },
      firstDelivery: null,
      late: [],
    });
    const rootL: networkEffect.AttemptRecord = recordFor({ logical: logicalL, ordinal: 0n }, { tag: "Root" });
    const rootM: networkEffect.AttemptRecord = recordFor({ logical: logicalM, ordinal: 0n }, { tag: "Root" });
    const retryM1: networkEffect.AttemptRecord = recordFor(
      { logical: logicalM, ordinal: 1n },
      {
        tag: "RetryOf",
        authorization: {
          logical: logicalM,
          from: { logical: logicalM, ordinal: 0n },
          next: { logical: logicalM, ordinal: 1n },
          protocolEvidence: { value: "e" },
        },
      },
    );
    const badAttempt: networkEffect.AttemptIdentity = { logical: logicalL, ordinal: 2n };
    const retryL2 = {
      input: { attempt: badAttempt, instruction, deadline: null, configuration },
      chain: {
        tag: "RetryOf" as const,
        authorization: {
          logical: logicalL,
          from: { logical: logicalM, ordinal: 1n },
          next: badAttempt,
          protocolEvidence: { value: "e" },
        },
      },
      disposition: { tag: "Prepared" as const },
      firstDelivery: null,
      late: [],
    };
    expect(networkStateOf([rootL, rootM, retryM1, retryL2])).toEqual({
      tag: "stateRejected",
      violation: { tag: "ChainMismatch", attempt: badAttempt },
    });
  });

  describe("host record release", () => {
    function settledState(): NetworkState {
      const running = started();
      const response = { tag: "ResponseObservation" as const, attempt: input.attempt, handle: running.started.handle, sourceSequence: { tag: "none" as const }, response: { status: 200, headers: [], body: new Uint8Array() }, provenance: "LibraryNormalized" as const, effect: { tag: "Unknown" as const, reason: "NoResponse" as const } };
      const terminal = observe(running.state, { tag: "Delivered", delivery: 0n, observation: response });
      if (terminal.tag !== "Terminal") throw new Error("expected terminal");
      return terminal.state;
    }

    it("retains a started record only for future use", () => {
      const running = started();
      expect(networkEffect.hostAwaits(running.state, input.attempt)).toBe(true);
      expect(networkEffect.hostSettled(running.state, input.attempt)).toBe(false);
      const decision = networkEffect.releaseHostRecord(running.state, () => false, input.attempt);
      expect(decision).toEqual({ kind: "retain", reasons: [{ kind: "futureUse", target: input.attempt }] });
    });

    it("retains a settled record with a running worker only for the outstanding effect", () => {
      const state = settledState();
      expect(networkEffect.hostAwaits(state, input.attempt)).toBe(false);
      expect(networkEffect.hostSettled(state, input.attempt)).toBe(true);
      const decision = networkEffect.releaseHostRecord(state, () => true, input.attempt);
      expect(decision).toEqual({ kind: "retain", reasons: [{ kind: "outstandingEffect", target: input.attempt }] });
    });

    it("discards a settled record without a running worker", () => {
      const decision = networkEffect.releaseHostRecord(settledState(), () => false, input.attempt);
      expect(decision.kind).toBe("dematerialize");
      if (decision.kind !== "dematerialize") return;
      expect(decision.witness.target).toEqual(input.attempt);
      expect(decision.witness.removedObservations).toEqual(["Undelivered", "DeliveryOrdinal"]);
    });

    it("discards a missing record without a running worker", () => {
      const state = emptyNetworkState();
      expect(networkEffect.hostAwaits(state, input.attempt)).toBe(false);
      expect(networkEffect.hostSettled(state, input.attempt)).toBe(false);
      expect(networkEffect.releaseHostRecord(state, () => false, input.attempt).kind).toBe("dematerialize");
    });
  });
});
