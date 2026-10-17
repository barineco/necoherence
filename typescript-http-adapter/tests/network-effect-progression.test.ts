// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import { decideStart, empty, submit, type ResourceBudget } from "necoherence/request-progression";
import * as httpAdapter from "../src/index.js";
import { networkEffect } from "necoherence";

describe("network effect progression bridge", () => {
  it("keeps progression identity separate from the transport ledger", () => {
    const budget: ResourceBudget = { pendingMaximum: { resource: "http", maximum: 2n }, inFlightMaximum: { resource: "http", maximum: 1n }, concurrentMaximum: { resource: "http", maximum: 1n } };
    const identity = { kind: "bridge", provenance: "test", revision: 0n };
    const submitted = submit(empty("AllExecute", budget), { identity, footprint: { reads: ["network"], writes: [], effectClass: "Pure" }, demand: { pending: 1n, inFlight: 1n, concurrent: 1n }, permission: { tag: "permitted", identity, evidence: [] } });
    expect(submitted.tag).toBe("accepted");
    const transport = networkEffect.prepare(networkEffect.emptyNetworkState(), { attempt: { logical: identity, ordinal: 0n }, instruction: { method: "GET", target: "https://example.test/", headers: [], body: [] }, deadline: null, configuration: { requestBodyLimit: 0n, responseBodyLimit: 0n, cancellation: null, monotonicClock: null } });
    expect(transport.tag).toBe("Prepared");
    if (transport.tag !== "Prepared") return;
    const read = networkEffect.readNetworkState(transport.state);
    expect(read.tag).toBe("Read");
    if (submitted.tag !== "accepted") return;
    const selection = { tag: "executeNow" as const, identity, evidence: { identifier: "bridge", digest: "d", artifactPath: "p" }, cost: 1n };
    const decision = decideStart(submitted.snapshot, submitted.accepted, selection);
    expect(decision.tag).toBe("execute");
  });

  it("keeps forged tokens and retry authorization reuse outside adapter dispatch", () => {
    let fetchCalls = 0;
    const adapter = new httpAdapter.FetchHttpAdapter({
      fetch: async () => {
        fetchCalls += 1;
        return {
          status: 200,
          headers: { entries: () => [] },
          arrayBuffer: async () => new ArrayBuffer(0),
        };
      },
    });
    const logical = { kind: "bridge", provenance: "causal", revision: 1n };
    const rootInput: networkEffect.AttemptInput = {
      attempt: { logical, ordinal: 0n },
      instruction: {
        method: "GET",
        target: "http://127.0.0.1/",
        headers: [],
        body: [],
      },
      deadline: null,
      configuration: {
        requestBodyLimit: 0n,
        responseBodyLimit: 32n,
        cancellation: null,
        monotonicClock: null,
      },
    };
    const root = networkEffect.prepare(networkEffect.emptyNetworkState(), rootInput);
    if (root.tag !== "Prepared") throw new Error("prepare failed");
    const mismatches: readonly networkEffect.PreparedAttempt[] = [
      {
        ...root.prepared,
        input: {
          ...root.prepared.input,
          instruction: { ...rootInput.instruction, method: "POST" },
        },
      },
      {
        ...root.prepared,
        input: {
          ...root.prepared.input,
          deadline: {
            clockBasis: { value: "forged" },
            limit: 1n,
            capability: {
              identity: { value: "forged" },
              clockBasis: { value: "forged" },
            },
          },
        },
      },
      {
        ...root.prepared,
        input: {
          ...root.prepared.input,
          configuration: { ...rootInput.configuration, responseBodyLimit: 31n },
        },
      },
      {
        ...root.prepared,
        lineage: {
          tag: "RetryOf",
          authorization: {
            logical,
            from: rootInput.attempt,
            next: { logical, ordinal: 1n },
            protocolEvidence: { value: "forged" },
          },
        },
      },
    ];
    for (const forged of mismatches) {
      const result = networkEffect.sendCommand(root.state, forged);
      expect(result.tag).toBe("Rejected");
      if (result.tag === "CommandReady") adapter.start(result.command);
    }
    expect(fetchCalls).toBe(0);

    const issued = networkEffect.sendCommand(root.state, root.prepared);
    if (issued.tag !== "CommandReady") throw new Error("send failed");
    const started = networkEffect.observeStart(issued.state, root.prepared, {
      tag: "Started",
      attempt: rootInput.attempt,
      handle: { value: "bridge.handle" },
    });
    if (started.tag !== "Started") throw new Error("start failed");
    const terminal = networkEffect.observe(started.state, {
      tag: "Delivered",
      delivery: 0n,
      observation: {
        tag: "ResponseObservation",
        attempt: rootInput.attempt,
        handle: started.started.handle,
        sourceSequence: { tag: "none" },
        response: { status: 200, headers: [], body: [] },
        provenance: "LibraryNormalized",
        effect: { tag: "Unknown", reason: "NoResponse" },
      },
    });
    if (terminal.tag !== "Terminal") throw new Error("settle failed");
    const authorization: networkEffect.RetryAuthorization = {
      logical,
      from: rootInput.attempt,
      next: { logical, ordinal: 1n },
      protocolEvidence: { value: "retry" },
    };
    const request: networkEffect.RetryRequest = {
      permission: { tag: "RetryAllowed", authorization },
      instruction: rootInput.instruction,
      deadline: null,
      configuration: rootInput.configuration,
    };
    const retried = networkEffect.retry(terminal.state, request);
    if (retried.tag !== "Prepared") throw new Error("retry failed");
    expect(networkEffect.retry(retried.state, request).tag).toBe("Rejected");
    expect(networkEffect.retry(retried.state, {
      ...request,
      permission: {
        tag: "RetryDenied",
        logical,
        parent: authorization.next,
        evidence: { value: "denied" },
      },
    }).tag).toBe("Rejected");

    const ledgerRecordCount = retried.state.attempts.length;
    const issuedCommandCount = 0;
    const peerReceivedCount = fetchCalls;
    expect({ ledgerRecordCount, issuedCommandCount, peerReceivedCount }).toEqual({
      ledgerRecordCount: 2,
      issuedCommandCount: 0,
      peerReceivedCount: 0,
    });
    expect(peerReceivedCount).toBeLessThanOrEqual(issuedCommandCount);
    expect(retried.prepared.input.attempt).toEqual({ logical, ordinal: 1n });
  });
});
