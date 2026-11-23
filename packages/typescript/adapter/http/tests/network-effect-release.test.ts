// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { once } from "node:events";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { describe, expect, it } from "vitest";
import * as httpAdapter from "../src/index.js";
import { recordCount } from "../src/records.js";
import { networkEffect } from "necoherence";

const { FetchHttpAdapter } = httpAdapter;
const { cancelCommand, emptyNetworkState, observe, observeStart, prepare, sendCommand } = networkEffect;
type FetchHttpAdapter = httpAdapter.FetchHttpAdapter;

const capability = { identity: { value: "release-cancel" } };

function inputFor(revision: bigint, target: string, cancelling: boolean): networkEffect.AttemptInput {
  return {
    attempt: { logical: { kind: "http", provenance: "release", revision }, ordinal: 0n },
    instruction: { method: "GET", target, headers: [], body: new Uint8Array() },
    deadline: null,
    configuration: {
      requestBodyLimit: 1024n,
      responseBodyLimit: 1024n,
      cancellation: cancelling ? capability : null,
      monotonicClock: null,
    },
  };
}

function dispatch(adapter: FetchHttpAdapter, input: networkEffect.AttemptInput): {
  readonly state: networkEffect.NetworkState;
  readonly started: networkEffect.StartedAttempt;
} {
  const prepared = prepare(emptyNetworkState(), input);
  if (prepared.tag !== "Prepared") throw new Error("prepare failed");
  const issued = sendCommand(prepared.state, prepared.prepared);
  if (issued.tag !== "CommandReady") throw new Error("send command failed");
  const start = adapter.start(issued.command);
  const step = observeStart(issued.state, prepared.prepared, start);
  if (step.tag !== "Started") throw new Error("observe start failed");
  return { state: step.state, started: step.started };
}

async function nextDelivered(
  adapter: FetchHttpAdapter,
  started: networkEffect.StartedAttempt,
): Promise<networkEffect.HostObservation> {
  const limit = performance.now() + 5_000;
  while (performance.now() < limit) {
    const observation = adapter.observe(started);
    if (observation.tag === "Delivered") return observation;
    if (observation.tag === "UnknownExecution") throw new Error("unknown execution");
    await new Promise<void>((resolve) => setTimeout(resolve, 1));
  }
  throw new Error("adapter did not deliver an observation");
}

function effectOutstanding(decision: networkEffect.HostRecordDecision): boolean {
  return decision.kind === "retain"
    && decision.reasons.some((reason) => reason.kind === "outstandingEffect");
}

async function releaseWhenIdle(
  adapter: FetchHttpAdapter,
  state: networkEffect.NetworkState,
  started: networkEffect.StartedAttempt,
): Promise<networkEffect.HostRecordDecision> {
  const limit = performance.now() + 5_000;
  while (performance.now() < limit) {
    const decision = adapter.release(state, started);
    if (!effectOutstanding(decision)) return decision;
    await new Promise<void>((resolve) => setTimeout(resolve, 1));
  }
  throw new Error("worker remained running");
}

function responseLike(): httpAdapter.FetchResponseLike {
  return {
    status: 200,
    headers: { entries: () => [] },
    arrayBuffer: async () => new ArrayBuffer(0),
  };
}

async function startServer(): Promise<{ readonly url: string; readonly close: () => Promise<void> }> {
  const server: Server = createServer((request, response) => {
    request.resume();
    response.writeHead(200);
    response.end("ok");
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address() as AddressInfo;
  return {
    url: `http://127.0.0.1:${address.port}/release`,
    close: async () => {
      server.close();
      server.closeAllConnections();
      await once(server, "close");
    },
  };
}

async function drainRequests(total: number, unreleased: number): Promise<number> {
  const server = await startServer();
  try {
    const adapter = new FetchHttpAdapter();
    for (let index = 0; index < total; index += 1) {
      const { state, started } = dispatch(adapter, inputFor(BigInt(index), server.url, false));
      const terminal = observe(state, await nextDelivered(adapter, started));
      if (terminal.tag !== "Terminal") throw new Error("terminal expected");
      if (index >= unreleased) {
        const decision = await releaseWhenIdle(adapter, terminal.state, started);
        expect(decision).toMatchObject({ kind: "dematerialize" });
      }
    }
    return recordCount(adapter);
  } finally {
    await server.close();
  }
}

describe("adapter record release", () => {
  it("leaves no registration after releasing every one of 500 requests", async () => {
    expect(await drainRequests(500, 0)).toBe(0);
  }, 120_000);

  it("keeps the registrations that were not released", async () => {
    expect(await drainRequests(40, 3)).toBe(3);
  }, 60_000);

  it("retains only future use before the ledger reaches a terminal state", async () => {
    const adapter = new FetchHttpAdapter({ fetch: async () => responseLike() });
    const { state, started } = dispatch(adapter, inputFor(1n, "http://127.0.0.1/", false));
    await nextDelivered(adapter, started);
    const decision = await releaseWhenIdle(adapter, state, started);
    expect(decision).toEqual({
      kind: "retain",
      reasons: [{ kind: "futureUse", target: started.prepared.input.attempt }],
    });
    expect(recordCount(adapter)).toBe(1);
  });

  it("retains only the outstanding effect while the worker runs after cancellation", async () => {
    let answer: ((response: httpAdapter.FetchResponseLike) => void) | undefined;
    const adapter = new FetchHttpAdapter({
      cancellation: { capability: () => capability, request: () => undefined },
      fetch: () => new Promise<httpAdapter.FetchResponseLike>((resolve) => { answer = resolve; }),
    });
    const { state, started } = dispatch(adapter, inputFor(2n, "http://127.0.0.1/", true));
    await Promise.resolve();
    const command = cancelCommand(state, started);
    if (command.tag !== "CommandReady") throw new Error("cancel command failed");
    const cancelled = adapter.cancel(command.command as networkEffect.CancelCommand);
    if (cancelled.tag !== "Delivered") throw new Error("cancellation observation expected");
    const terminal = observe(state, cancelled);
    if (terminal.tag !== "Terminal") throw new Error("terminal expected");
    const attempt = started.prepared.input.attempt;
    expect(adapter.release(terminal.state, started)).toEqual({
      kind: "retain",
      reasons: [{ kind: "outstandingEffect", target: attempt }],
    });
    expect(recordCount(adapter)).toBe(1);
    answer?.(responseLike());
    expect(await releaseWhenIdle(adapter, terminal.state, started)).toMatchObject(
      { kind: "dematerialize" },
    );
    expect(recordCount(adapter)).toBe(0);
  });

  it("returns UnknownExecution for a released handle and for a handle never started", async () => {
    const adapter = new FetchHttpAdapter({ fetch: async () => responseLike() });
    const { state, started } = dispatch(adapter, inputFor(3n, "http://127.0.0.1/", false));
    const terminal = observe(state, await nextDelivered(adapter, started));
    if (terminal.tag !== "Terminal") throw new Error("terminal expected");
    expect(await releaseWhenIdle(adapter, terminal.state, started)).toMatchObject({
      kind: "dematerialize",
    });
    expect(adapter.observe(started)).toEqual({ tag: "UnknownExecution", handle: started.handle });
    const never = { value: "never-started" };
    expect(adapter.observe({ prepared: started.prepared, handle: never }))
      .toEqual({ tag: "UnknownExecution", handle: never });
  });

  it("reports a cancellation port exception as a host runtime failure", async () => {
    const adapter = new FetchHttpAdapter({
      cancellation: {
        capability: () => capability,
        request: () => { throw new Error("controlled cancellation port failure"); },
      },
      fetch: () => new Promise<httpAdapter.FetchResponseLike>(() => undefined),
    });
    const { state, started } = dispatch(adapter, inputFor(5n, "http://127.0.0.1/", true));
    await Promise.resolve();
    const command = cancelCommand(state, started);
    if (command.tag !== "CommandReady") throw new Error("cancel command failed");
    const rejected = adapter.cancel(command.command as networkEffect.CancelCommand);
    if (rejected.tag !== "Delivered" || rejected.observation.tag !== "FailureObservation") {
      throw new Error("failure observation expected");
    }
    expect(rejected.observation.failure.stage).toBe("Cancel");
    expect(rejected.observation.failure.cause).toEqual({ tag: "HostRuntimeFailure" });
  });

  it("observes a deadline already reached at start exactly once", async () => {
    const clockBasis = { value: "once-basis" };
    const clockCapability = { identity: { value: "once-clock" }, clockBasis };
    const adapter = new FetchHttpAdapter({
      monotonicClock: { capability: () => clockCapability, observe: () => ({ clockBasis, value: 5n }) },
      fetch: () => new Promise<httpAdapter.FetchResponseLike>(() => undefined),
    });
    const input: networkEffect.AttemptInput = {
      ...inputFor(6n, "http://127.0.0.1/", false),
      deadline: { clockBasis, limit: 5n, capability: clockCapability },
      configuration: {
        requestBodyLimit: 1024n,
        responseBodyLimit: 1024n,
        cancellation: null,
        monotonicClock: clockCapability,
      },
    };
    const { started } = dispatch(adapter, input);
    const observed = [adapter.observe(started)];
    await new Promise<void>((resolve) => setTimeout(resolve, 50));
    observed.push(adapter.observe(started), adapter.observe(started));
    const deadlines = observed.filter(
      (item) => item.tag === "Delivered" && item.observation.tag === "DeadlineObservation",
    );
    expect(deadlines).toHaveLength(1);
  });

  it("returns the release decision for a handle that has no record", () => {
    const adapter = new FetchHttpAdapter({ fetch: async () => responseLike() });
    const { state, started } = dispatch(adapter, inputFor(4n, "http://127.0.0.1/", false));
    const never = { prepared: started.prepared, handle: { value: "never-started" } };
    const decision = adapter.release(state, never);
    expect(decision).not.toHaveProperty("tag");
    expect(decision).toEqual({
      kind: "retain",
      reasons: [{ kind: "futureUse", target: started.prepared.input.attempt }],
    });
  });
});
