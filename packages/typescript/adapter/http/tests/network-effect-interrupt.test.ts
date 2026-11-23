// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { once } from "node:events";
import { createServer, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { describe, expect, it } from "vitest";
import * as httpAdapter from "../src/index.js";
import { recordCount } from "../src/records.js";
import { networkEffect } from "necoherence";

const { FetchHttpAdapter } = httpAdapter;
const { cancelCommand, emptyNetworkState, observe, observeStart, prepare, sendCommand } = networkEffect;

const cancelCapability = { identity: { value: "interrupt-cancel" } };
const clockBasis = { value: "interrupt-basis" };
const clockCapability = { identity: { value: "interrupt-clock" }, clockBasis };

interface Held {
  readonly url: string;
  readonly release: () => void;
  readonly accepted: () => Promise<void>;
  readonly clientClosed: () => Promise<void>;
  readonly close: () => Promise<void>;
}

async function startHeld(): Promise<Held> {
  const held: ServerResponse[] = [];
  let waiting: (() => void) | undefined;
  const server: Server = createServer((request, response) => {
    request.resume();
    held.push(response);
    waiting?.();
  });
  let closedConnections = 0;
  let closedWaiting: (() => void) | undefined;
  server.on("connection", (socket) => {
    socket.on("close", () => {
      closedConnections += 1;
      closedWaiting?.();
    });
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address() as AddressInfo;
  const release = (): void => {
    for (const response of held.splice(0)) {
      try { response.writeHead(200); response.end("late"); } catch { /* closed */ }
    }
  };
  return {
    url: `http://127.0.0.1:${address.port}/interrupt`,
    release,
    accepted: async () => {
      if (held.length > 0) return;
      await new Promise<void>((resolve) => { waiting = resolve; });
    },
    clientClosed: async () => {
      const limit = performance.now() + 2_000;
      while (closedConnections === 0) {
        if (performance.now() > limit) throw new Error("the connection was not closed from the client side");
        await new Promise<void>((resolve) => {
          closedWaiting = resolve;
          setTimeout(resolve, 20);
        });
      }
    },
    close: async () => {
      release();
      server.close();
      server.closeAllConnections();
      await once(server, "close");
    },
  };
}

function inputFor(revision: bigint, target: string, withDeadline: boolean): networkEffect.AttemptInput {
  return {
    attempt: { logical: { kind: "http", provenance: "interrupt", revision }, ordinal: 0n },
    instruction: { method: "GET", target, headers: [], body: new Uint8Array() },
    deadline: withDeadline ? { clockBasis, limit: 5n, capability: clockCapability } : null,
    configuration: {
      requestBodyLimit: 1024n,
      responseBodyLimit: 1024n,
      cancellation: cancelCapability,
      monotonicClock: withDeadline ? clockCapability : null,
    },
  };
}

function dispatch(adapter: httpAdapter.FetchHttpAdapter, input: networkEffect.AttemptInput): {
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

async function waitStopped(
  adapter: httpAdapter.FetchHttpAdapter,
  state: networkEffect.NetworkState,
  started: networkEffect.StartedAttempt,
): Promise<networkEffect.HostRecordDecision> {
  const limit = performance.now() + 2_000;
  for (;;) {
    const decision = adapter.release(state, started);
    const outstanding = decision.kind === "retain"
      && decision.reasons.some((reason) => reason.kind === "outstandingEffect");
    if (!outstanding) return decision;
    if (performance.now() > limit) throw new Error("worker still running without release of the peer");
    await new Promise<void>((resolve) => setTimeout(resolve, 5));
  }
}

async function expectNoLateObservation(
  adapter: httpAdapter.FetchHttpAdapter,
  started: networkEffect.StartedAttempt,
): Promise<void> {
  const later = adapter.observe(started);
  expect(["Pending", "UnknownExecution"]).toContain(later.tag);
}

async function expectNoLateResponse(
  adapter: httpAdapter.FetchHttpAdapter,
  started: networkEffect.StartedAttempt,
  peer: Held,
): Promise<void> {
  await peer.clientClosed();
  peer.release();
  await new Promise<void>((resolve) => setTimeout(resolve, 150));
  expect(adapter.observe(started).tag).toBe("Pending");
  expect(adapter.observe(started).tag).toBe("Pending");
}

describe("interrupting the request", () => {
  it("deadline: the connection is closed from the client side before release", async () => {
    const peer = await startHeld();
    try {
      let now = 0n;
      const adapter = new FetchHttpAdapter({
        cancellation: { capability: () => cancelCapability, request: () => undefined },
        monotonicClock: { capability: () => clockCapability, observe: () => ({ clockBasis, value: now }) },
      });
      const { state, started } = dispatch(adapter, inputFor(1n, peer.url, true));
      await peer.accepted();
      now = 5n;
      const deadline = adapter.observe(started);
      if (deadline.tag !== "Delivered" || deadline.observation.tag !== "DeadlineObservation") {
        throw new Error("deadline observation expected");
      }
      await peer.clientClosed();
      const terminal = observe(state, deadline);
      if (terminal.tag !== "Terminal") throw new Error("terminal expected");
      expect(await waitStopped(adapter, terminal.state, started)).toMatchObject({ kind: "dematerialize" });
      expect(recordCount(adapter)).toBe(0);
      await expectNoLateObservation(adapter, started);
    } finally {
      await peer.close();
    }
  });

  it("cancel: the connection is closed from the client side before release", async () => {
    const peer = await startHeld();
    try {
      const adapter = new FetchHttpAdapter({ cancellation: { capability: () => cancelCapability, request: () => undefined } });
      const { state, started } = dispatch(adapter, inputFor(2n, peer.url, false));
      await peer.accepted();
      const command = cancelCommand(state, started);
      if (command.tag !== "CommandReady") throw new Error("cancel command failed");
      const cancelled = adapter.cancel(command.command as networkEffect.CancelCommand);
      if (cancelled.tag !== "Delivered" || cancelled.observation.tag !== "CancellationObservation") {
        throw new Error("cancellation observation expected");
      }
      await peer.clientClosed();
      const terminal = observe(state, cancelled);
      if (terminal.tag !== "Terminal") throw new Error("terminal expected");
      expect(await waitStopped(adapter, terminal.state, started)).toMatchObject({ kind: "dematerialize" });
      expect(recordCount(adapter)).toBe(0);
      await expectNoLateObservation(adapter, started);
    } finally {
      await peer.close();
    }
  });

  it("close: the connection is closed from the client side before release", async () => {
    const peer = await startHeld();
    try {
      const adapter = new FetchHttpAdapter({
        cancellation: { capability: () => cancelCapability, request: () => undefined },
      });
      const { state, started } = dispatch(adapter, inputFor(3n, peer.url, false));
      await peer.accepted();
      const closed = adapter.close(started);
      if (closed.tag !== "Delivered" || closed.observation.tag !== "FailureObservation") {
        throw new Error("HostClosed expected");
      }
      expect(closed.observation.failure.cause).toEqual({ tag: "HostClosed" });
      await peer.clientClosed();
      const terminal = observe(state, closed);
      if (terminal.tag !== "Terminal") throw new Error("terminal expected");
      expect(await waitStopped(adapter, terminal.state, started)).toMatchObject({ kind: "dematerialize" });
      expect(recordCount(adapter)).toBe(0);
      await expectNoLateObservation(adapter, started);
    } finally {
      await peer.close();
    }
  });

  it("a rejected cancellation interrupts: the connection closes and no response follows", async () => {
    const peer = await startHeld();
    try {
      const adapter = new FetchHttpAdapter({ cancellation: { capability: () => cancelCapability, request: () => ({ tag: "CancellationRejected" as const }) } });
      const { state, started } = dispatch(adapter, inputFor(4n, peer.url, false));
      await peer.accepted();
      const command = cancelCommand(state, started);
      if (command.tag !== "CommandReady") throw new Error("cancel command failed");
      const rejected = adapter.cancel(command.command as networkEffect.CancelCommand);
      expect(rejected).toMatchObject({
        tag: "Delivered",
        observation: {
          tag: "FailureObservation",
          failure: { stage: "Cancel", cause: { tag: "CancellationRejected" } },
          effect: { tag: "Unknown", reason: "HostFailure" },
        },
      });
      await expectNoLateResponse(adapter, started, peer);
    } finally {
      await peer.close();
    }
  });

  it("a cancellation port failure interrupts: the connection closes and no response follows", async () => {
    const peer = await startHeld();
    try {
      const adapter = new FetchHttpAdapter({
        cancellation: { capability: () => cancelCapability, request: () => { throw new Error("port failure"); } },
      });
      const { state, started } = dispatch(adapter, inputFor(11n, peer.url, false));
      await peer.accepted();
      const command = cancelCommand(state, started);
      if (command.tag !== "CommandReady") throw new Error("cancel command failed");
      const failed = adapter.cancel(command.command as networkEffect.CancelCommand);
      expect(failed).toMatchObject({
        tag: "Delivered",
        observation: {
          tag: "FailureObservation",
          failure: { stage: "Cancel", cause: { tag: "HostRuntimeFailure" } },
          effect: { tag: "Unknown", reason: "HostFailure" },
        },
      });
      await expectNoLateResponse(adapter, started, peer);
    } finally {
      await peer.close();
    }
  });

  it("a clock failure seen by observe interrupts: the connection closes and no response follows", async () => {
    const peer = await startHeld();
    try {
      let failing = false;
      const adapter = new FetchHttpAdapter({
        cancellation: { capability: () => cancelCapability, request: () => undefined },
        monotonicClock: {
          capability: () => clockCapability,
          observe: () => {
            if (failing) throw new Error("clock failure");
            return { clockBasis, value: 0n };
          },
        },
      });
      const { started } = dispatch(adapter, inputFor(12n, peer.url, true));
      await peer.accepted();
      failing = true;
      const failed = adapter.observe(started);
      expect(failed).toMatchObject({
        tag: "Delivered",
        observation: {
          tag: "FailureObservation",
          failure: { stage: "Deadline", cause: { tag: "HostRuntimeFailure" } },
          effect: { tag: "Unknown", reason: "HostFailure" },
        },
      });
      await expectNoLateResponse(adapter, started, peer);
    } finally {
      await peer.close();
    }
  });

  it("a cancellation port returning a runtime failure value interrupts and yields the same observation as a thrown failure", async () => {
    const peer = await startHeld();
    try {
      const adapter = new FetchHttpAdapter({
        cancellation: { capability: () => cancelCapability, request: () => ({ tag: "HostRuntimeFailure" as const }) },
      });
      const { state, started } = dispatch(adapter, inputFor(21n, peer.url, false));
      await peer.accepted();
      const command = cancelCommand(state, started);
      if (command.tag !== "CommandReady") throw new Error("cancel command failed");
      const failed = adapter.cancel(command.command as networkEffect.CancelCommand);
      expect(failed).toMatchObject({
        tag: "Delivered",
        observation: {
          tag: "FailureObservation",
          failure: { stage: "Cancel", cause: { tag: "HostRuntimeFailure" } },
          effect: { tag: "Unknown", reason: "HostFailure" },
        },
      });
      await expectNoLateResponse(adapter, started, peer);
    } finally {
      await peer.close();
    }
  });

  it("a cancellation port returning a timeout value reports the stage the failure carries", async () => {
    const peer = await startHeld();
    try {
      const adapter = new FetchHttpAdapter({
        cancellation: {
          capability: () => cancelCapability,
          request: () => ({ tag: "Timeout" as const, stage: "ResponseBody" as const, cause: "HostOperation" as const }),
        },
      });
      const { state, started } = dispatch(adapter, inputFor(22n, peer.url, false));
      await peer.accepted();
      const command = cancelCommand(state, started);
      if (command.tag !== "CommandReady") throw new Error("cancel command failed");
      expect(adapter.cancel(command.command as networkEffect.CancelCommand)).toMatchObject({
        tag: "Delivered",
        observation: {
          tag: "FailureObservation",
          failure: { stage: "ResponseBody", cause: { tag: "Timeout", stage: "ResponseBody", cause: "HostOperation" } },
          effect: { tag: "Unknown", reason: "HostFailure" },
        },
      });
    } finally {
      await peer.close();
    }
  });

  it("a clock port returning a runtime failure value yields one deadline failure and no response follows", async () => {
    const peer = await startHeld();
    try {
      let failing = false;
      let calls = 0;
      const adapter = new FetchHttpAdapter({
        cancellation: { capability: () => cancelCapability, request: () => undefined },
        monotonicClock: {
          capability: () => clockCapability,
          observe: () => {
            calls += 1;
            if (failing) return { tag: "HostRuntimeFailure" as const };
            return { clockBasis, value: 0n };
          },
        },
      });
      const { started } = dispatch(adapter, inputFor(23n, peer.url, true));
      await peer.accepted();
      failing = true;
      const failed = adapter.observe(started);
      expect(failed).toMatchObject({
        tag: "Delivered",
        observation: {
          tag: "FailureObservation",
          failure: { stage: "Deadline", cause: { tag: "HostRuntimeFailure" } },
          effect: { tag: "Unknown", reason: "HostFailure" },
        },
      });
      const afterFirst = calls;
      expect(adapter.observe(started).tag).toBe("Pending");
      expect(calls).toBe(afterFirst);
      await expectNoLateResponse(adapter, started, peer);
    } finally {
      await peer.close();
    }
  });

  it("a clock port returning a failure value on the first observation sends no request", async () => {
    const peer = await startHeld();
    try {
      const adapter = new FetchHttpAdapter({
        cancellation: { capability: () => cancelCapability, request: () => undefined },
        monotonicClock: { capability: () => clockCapability, observe: () => ({ tag: "HostRuntimeFailure" as const }) },
      });
      const { started } = dispatch(adapter, inputFor(24n, peer.url, true));
      const limit = performance.now() + 2_000;
      let observed = adapter.observe(started);
      while (observed.tag === "Pending" && performance.now() < limit) {
        await new Promise<void>((resolve) => setTimeout(resolve, 5));
        observed = adapter.observe(started);
      }
      expect(observed).toMatchObject({
        tag: "Delivered",
        delivery: 0n,
        observation: {
          tag: "FailureObservation",
          failure: { stage: "Deadline", cause: { tag: "HostRuntimeFailure" } },
          effect: { tag: "Unknown", reason: "HostFailure" },
        },
      });
      expect(adapter.observe(started).tag).toBe("Pending");
    } finally {
      await peer.close();
    }
  });

  function rejectedCancel(
    adapter: httpAdapter.FetchHttpAdapter,
    state: networkEffect.NetworkState,
    started: networkEffect.StartedAttempt,
  ): networkEffect.HostObservation {
    const command = cancelCommand(state, started);
    if (command.tag !== "CommandReady") throw new Error("cancel command failed");
    const rejected = adapter.cancel(command.command as networkEffect.CancelCommand);
    expect(rejected).toMatchObject({
      tag: "Delivered",
      observation: {
        tag: "FailureObservation",
        failure: { stage: "Cancel", cause: { tag: "CancellationRejected" } },
      },
    });
    return rejected as networkEffect.HostObservation;
  }

  it("release after the terminal observation removes the record within the limit", async () => {
    const peer = await startHeld();
    try {
      const adapter = new FetchHttpAdapter({ cancellation: { capability: () => cancelCapability, request: () => ({ tag: "CancellationRejected" as const }) } });
      const { state, started } = dispatch(adapter, inputFor(8n, peer.url, false));
      await peer.accepted();
      const rejected = rejectedCancel(adapter, state, started);
      const terminal = observe(state, rejected);
      if (terminal.tag !== "Terminal") throw new Error("terminal expected");
      expect(["retain", "dematerialize"]).toContain(adapter.release(terminal.state, started).kind);
      const limit = performance.now() + 2_000;
      while (recordCount(adapter) !== 0) {
        if (performance.now() > limit) throw new Error("record remained without release of the peer");
        await new Promise<void>((resolve) => setTimeout(resolve, 5));
      }
      await expectNoLateObservation(adapter, started);
    } finally {
      await peer.close();
    }
  });

  it("release while the core still awaits keeps the record and no response follows", async () => {
    const peer = await startHeld();
    try {
      const adapter = new FetchHttpAdapter({ cancellation: { capability: () => cancelCapability, request: () => ({ tag: "CancellationRejected" as const }) } });
      const { state, started } = dispatch(adapter, inputFor(9n, peer.url, false));
      await peer.accepted();
      rejectedCancel(adapter, state, started);
      await peer.clientClosed();
      expect(adapter.release(state, started).kind).toBe("retain");
      expect(recordCount(adapter)).toBe(1);
      await expectNoLateResponse(adapter, started, peer);
    } finally {
      await peer.close();
    }
  });

  it("release with a state lacking the record does not interrupt", async () => {
    const peer = await startHeld();
    try {
      const adapter = new FetchHttpAdapter({ cancellation: { capability: () => cancelCapability, request: () => ({ tag: "CancellationRejected" as const }) } });
      const { state, started } = dispatch(adapter, inputFor(10n, peer.url, false));
      await peer.accepted();
      expect(adapter.release(emptyNetworkState(), started).kind).toBe("retain");
      expect(recordCount(adapter)).toBe(1);
      peer.release();
      const limit = performance.now() + 2_000;
      for (;;) {
        const next = adapter.observe(started);
        if (next.tag === "Delivered") {
          expect(next.observation.tag).toBe("ResponseObservation");
          expect(observe(state, next).tag).toBe("Terminal");
          break;
        }
        if (performance.now() > limit) throw new Error("response observation did not arrive");
        await new Promise<void>((resolve) => setTimeout(resolve, 5));
      }
    } finally {
      await peer.close();
    }
  });

  const foreignCapability = { identity: { value: "other-cancel" } };

  async function awaitResponse(adapter: httpAdapter.FetchHttpAdapter, started: networkEffect.StartedAttempt): Promise<void> {
    const limit = performance.now() + 2_000;
    for (;;) {
      const next = adapter.observe(started);
      if (next.tag === "Delivered") {
        expect(next.observation.tag).toBe("ResponseObservation");
        return;
      }
      if (performance.now() > limit) throw new Error("response observation did not arrive");
      await new Promise<void>((resolve) => setTimeout(resolve, 5));
    }
  }

  it("a matching cancel calls the port once and returns a cancellation observation", async () => {
    const peer = await startHeld();
    try {
      let calls = 0;
      const adapter = new FetchHttpAdapter({
        cancellation: { capability: () => cancelCapability, request: () => { calls += 1; return undefined; } },
      });
      const { state, started } = dispatch(adapter, inputFor(5n, peer.url, false));
      await peer.accepted();
      const command = cancelCommand(state, started);
      if (command.tag !== "CommandReady") throw new Error("cancel command failed");
      const cancelled = adapter.cancel(command.command as networkEffect.CancelCommand);
      expect(cancelled).toMatchObject({ tag: "Delivered", observation: { tag: "CancellationObservation" } });
      expect(calls).toBe(1);
    } finally {
      await peer.close();
    }
  });

  it("a cancel with a foreign capability never reaches the port and interrupts", async () => {
    const peer = await startHeld();
    try {
      let calls = 0;
      const adapter = new FetchHttpAdapter({
        cancellation: { capability: () => cancelCapability, request: () => { calls += 1; return undefined; } },
      });
      const { state, started } = dispatch(adapter, inputFor(6n, peer.url, false));
      await peer.accepted();
      const command = cancelCommand(state, started);
      if (command.tag !== "CommandReady") throw new Error("cancel command failed");
      const mutated = { ...(command.command as networkEffect.CancelCommand), capability: foreignCapability };
      const rejected = adapter.cancel(mutated);
      expect(rejected).toMatchObject({
        tag: "Delivered",
        observation: {
          tag: "FailureObservation",
          failure: { stage: "Cancel", cause: { tag: "CancellationRejected" } },
          effect: { tag: "Unknown", reason: "HostFailure" },
        },
      });
      expect(calls).toBe(0);
      await expectNoLateResponse(adapter, started, peer);
    } finally {
      await peer.close();
    }
  });

  it("a cancel with a foreign handle is an unknown execution and never reaches the port", async () => {
    const peer = await startHeld();
    try {
      let calls = 0;
      const adapter = new FetchHttpAdapter({
        cancellation: { capability: () => cancelCapability, request: () => { calls += 1; return undefined; } },
      });
      const { state, started } = dispatch(adapter, inputFor(7n, peer.url, false));
      await peer.accepted();
      const command = cancelCommand(state, started);
      if (command.tag !== "CommandReady") throw new Error("cancel command failed");
      const handle = { value: "foreign-handle" };
      const mutated = { ...(command.command as networkEffect.CancelCommand), handle };
      expect(adapter.cancel(mutated)).toEqual({ tag: "UnknownExecution", handle });
      expect(calls).toBe(0);
      peer.release();
      await awaitResponse(adapter, started);
    } finally {
      await peer.close();
    }
  });
});
