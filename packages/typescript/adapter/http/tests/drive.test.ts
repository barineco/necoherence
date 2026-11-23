// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { once } from "node:events";
import { createServer, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { describe, expect, it } from "vitest";
import { networkEffect, semanticExecution as E } from "necoherence";
import * as C from "../../dist/semantic_composition.js";
import { compositionAdmissionToken } from "../../dist/composition_admission_token.js";
import * as S from "../../dist/semantic_signatures.js";
import * as V from "../../dist/semantic_values.js";
import { projectSlot } from "../../dist/signature_verification.js";
import { library as fixtureLibrary } from "../../tests/semantic-fixture.js";
import * as httpAdapter from "../src/index.js";
import { recordCount } from "../src/records.js";

const { FetchHttpAdapter, drive } = httpAdapter;

const text: V.ExactSlot = { tag: "Present", value: { tag: "String", value: "accepted" } };
const functionRef: C.FunctionRef = { identity: "provider", revision: "1", contentDigest: "b".repeat(64) };
const bounds: C.SearchBounds = {
  maxExpandedStates: 16n, maxBindingCandidates: 64n, maxTypeObligations: 64n, maxBranchNodes: 64n, maxSampleLength: 64n,
  resourceBounds: null,
};

function slotBinding(prepared: C.PreparedCompositionInput, producer: C.ProducerRef): C.BindingExpr {
  const contract = prepared.input.initialInputs[0]!.contract;
  const projection = projectSlot(prepared.context, contract, [], []);
  const shape = prepared.context.node(contract.type_ref).shape;
  const certificate: C.InclusionCertificate = { basis: V.semanticBasisOf(prepared.context), source: contract, destination: contract, emptyTypes: [], pairs: [{ pair: { source: contract, destination: contract, sourceTag: null }, sourceShape: shape, destinationShape: shape, rule: { tag: "SameDefinedType" }, children: [] }], root: 0n };
  return { tag: "Source", fields: { value: { producer, path: [] }, projection, compatibility: { tag: "Inclusion", value: certificate } } };
}

function admittedHttp(): E.AdmittedComposition {
  const library = S.checkLibrary(fixtureLibrary() as unknown as S.TypeSignatureLibrary);
  const contract: V.SlotContract = { type_ref: library.refs.get("text")!, required: true, nullable: false };
  const effect: C.CompositionEffect = { tag: "HttpRequestResponse" };
  const signature: C.FunctionSignature = {
    reference: functionRef,
    form: { tag: "Operation", value: { source: contract.type_ref.source, name: "provider" } },
    effect,
    inputs: [{ id: "input", contract, sourceConstraint: { tag: "InitialOnly", fields: { input: "input", path: [] } }, resourceRequirement: null }],
    outcomes: [
      { id: "ok", form: { tag: "Success" }, valuePorts: [{ id: "output", contract, resourceProduction: null }], producedResources: [] },
      { id: "declined", form: { tag: "DeclaredFailure" }, valuePorts: [{ id: "failure", contract, resourceProduction: null }], producedResources: [] },
    ],
    resourceInputs: [], assumptionRef: "provider semantics", handlesFailure: null,
  };
  const input: C.CompositionInput = {
    identity: "execution", revision: "1", basis: V.semanticBasisOf(library.context), signatures: [signature],
    initialInputs: [{ id: "input", contract, source: { tag: "Argument" }, resource: null }], initialResources: [],
    goal: {
      outputs: [{ id: "result", contract, sourceConstraint: { tag: "ProducedBy", fields: { site: "site", outcome: "ok", port: "output", path: [] } } }],
      failures: [{ id: "declined", origin: { tag: "Function", fields: { function: functionRef, outcome: "declined" } }, contract, finalResources: [] }],
      finalResources: [],
    },
    invocationDomain: {
      identity: "execution", revision: "1", sites: [{ id: "site", function: functionRef }], permittedProjections: [], permittedConstructions: [],
      permittedTransforms: [], guards: [],
    },
    allowedEffects: [effect], explicitOrder: [], selectionPolicy: { tag: "AnyFeasible" }, bounds,
  };
  const admitted = C.prepareDirectComposition(library.context, input, () => null, () => []);
  if (admitted.tag === "Failed") throw new Error(JSON.stringify(admitted.failure));
  const prepared = admitted.value;
  const inputBinding = slotBinding(prepared, { tag: "Initial", value: "input" });
  const invocation: C.InvocationPlan = { site: "site", function: functionRef, bindings: [["input", inputBinding]], resources: [] };
  const output = (outcome: string, port: string): C.BindingExpr => slotBinding(prepared, { tag: "InvocationOutcome", fields: { site: "site", outcome, port } });
  const success: C.PlanTree = { tag: "ReturnValue", fields: { rank: 1n, terminal: { tag: "Success", value: [["result", output("ok", "output")]] } } };
  const failure: C.PlanTree = { tag: "ReturnValue", fields: { rank: 1n, terminal: { tag: "Failure", fields: { embedding: "declined", value: output("declined", "failure") } } } };
  const invoke: C.PlanTree = { tag: "Invoke", fields: { rank: 0n, invocation, arms: [["ok", success], ["declined", failure]], emptyOutcomes: [] } };
  return E.AdmittedComposition.admit(compositionAdmissionToken, prepared, { inputIdentity: input.identity, inputRevision: input.revision, root: invoke });
}

function provider(
  target: string,
  deadline: networkEffect.Deadline | null = null,
  cancellation: networkEffect.CancellationCapability | null = null,
): E.Provider {
  const attemptInput: networkEffect.AttemptInput = {
    attempt: { logical: { kind: "semantic-execution", provenance: "drive", revision: 0n }, ordinal: 0n },
    instruction: { method: "GET", target, headers: [], body: new Uint8Array() }, deadline,
    configuration: { requestBodyLimit: 1024n, responseBodyLimit: 1024n, cancellation, monotonicClock: deadline?.capability ?? null },
  };
  return {
    reference: functionRef,
    implementation: { tag: "PreparedHttp", owner: {
      prepare: () => ({ tag: "Ok", value: { tag: "Ready", input: attemptInput } }),
      decode: () => ({ tag: "Ok", value: { outcome: "ok", outputs: [["output", text]] } }),
    } },
  };
}

function first(
  admitted: E.AdmittedComposition,
  target: string,
  deadline: networkEffect.Deadline | null = null,
  cancellation: networkEffect.CancellationCapability | null = null,
): E.Progress {
  const started = E.start(admitted, [provider(target, deadline, cancellation)], [["input", text]], networkEffect.emptyNetworkState());
  if (started.tag !== "Ok") throw new Error(JSON.stringify(started.failure.cause));
  return started.value;
}

async function startServer(delayMs: number): Promise<{ readonly url: string; readonly close: () => Promise<void> }> {
  const server: Server = createServer((request, response) => {
    request.resume();
    setTimeout(() => { response.writeHead(200); response.end(""); }, delayMs);
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address() as AddressInfo;
  return {
    url: `http://127.0.0.1:${address.port}/drive`,
    close: async () => {
      server.close();
      server.closeAllConnections();
      await once(server, "close");
    },
  };
}

async function startHeldServer(): Promise<{ readonly url: string; readonly release: () => void; readonly close: () => Promise<void> }> {
  const held: ServerResponse[] = [];
  let open = false;
  const server: Server = createServer((request, response) => {
    request.resume();
    if (open) { response.writeHead(200); response.end(""); } else held.push(response);
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address() as AddressInfo;
  const release = (): void => {
    open = true;
    for (const response of held.splice(0)) { response.writeHead(200); response.end(""); }
  };
  return {
    url: `http://127.0.0.1:${address.port}/drive`,
    release,
    close: async () => {
      release();
      server.close();
      server.closeAllConnections();
      await once(server, "close");
    },
  };
}

const clockBasis = { value: "test-system" };
const clockCapability = { identity: { value: "test-system-clock" }, clockBasis };

function systemClock(): httpAdapter.MonotonicClockPort {
  return {
    capability: () => clockCapability,
    observe: () => ({ clockBasis, value: BigInt(Math.floor(performance.now())) }),
    until: (limit) => Math.max(0, Number(limit) - performance.now()),
  };
}

function manualClock(): httpAdapter.MonotonicClockPort {
  return { capability: () => clockCapability, observe: () => ({ clockBasis, value: 0n }) };
}

function deadlineAfter(clock: httpAdapter.MonotonicClockPort, millis: number): networkEffect.Deadline {
  const observed = clock.observe();
  if ("tag" in observed) throw new Error("the test clock returned a failure value");
  return { clockBasis, limit: observed.value + BigInt(millis), capability: clockCapability };
}

async function within<T>(promise: Promise<T>, millis: number): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => { reject(new Error(`drive did not return within ${millis}ms`)); }, millis);
  });
  try { return await Promise.race([promise, timeout]); } finally { clearTimeout(timer); }
}

async function manual(adapter: httpAdapter.FetchHttpAdapter, begin: E.Progress): Promise<E.ExecutionResult> {
  let progress = begin;
  for (;;) {
    if (progress.tag === "Completed") return progress.result;
    const instruction = progress.instruction;
    let observation: E.ExecutionObservation;
    if (instruction.tag === "Send") {
      observation = { tag: "Start", observation: adapter.start(instruction.command) };
    } else {
      for (;;) {
        const observed = adapter.observe(instruction.started);
        if (observed.tag === "UnknownExecution") throw new Error("unknown execution");
        if (observed.tag === "Delivered") { observation = { tag: "Host", observation: observed }; break; }
        await new Promise<void>((resolve) => setTimeout(resolve, 1));
      }
    }
    const resumed = E.resume(progress.execution, observation);
    if (resumed.tag !== "Ok") throw new Error("resume failed");
    progress = resumed.value;
  }
}

const repeats = 100;

describe("drive", () => {
  it("leaves no registration after driving in sequence, and matches the manual loop", async () => {
    const server = await startServer(0);
    try {
      const admitted = admittedHttp();
      const reference = new FetchHttpAdapter();
      const expected = await manual(reference, first(admitted, server.url));
      const adapter = new FetchHttpAdapter();
      for (let index = 0; index < repeats; index += 1) {
        const driven = await drive(adapter, first(admitted, server.url));
        if (driven.tag !== "Ok") throw new Error("drive failed");
        expect(driven.value.retained).toEqual([]);
        expect(driven.value.result).toEqual(expected);
      }
      expect(recordCount(adapter)).toBe(0);
      expect(recordCount(reference)).toBe(1);
    } finally {
      await server.close();
    }
  }, 120_000);

  async function observeCalls(delayMs: number): Promise<number> {
    const server = await startServer(delayMs);
    try {
      const adapter = new FetchHttpAdapter();
      let calls = 0;
      const original = adapter.observe.bind(adapter);
      adapter.observe = (started) => { calls += 1; return original(started); };
      const driven = await drive(adapter, first(admittedHttp(), server.url));
      if (driven.tag !== "Ok") throw new Error("drive failed");
      expect(driven.value.retained).toEqual([]);
      return calls;
    } finally {
      await server.close();
    }
  }

  it("does not poll at a fixed interval while the peer holds the response", async () => {
    const short = await observeCalls(150);
    const long = await observeCalls(300);
    expect(short).toBe(long);
    expect(short).toBeLessThanOrEqual(2);
  }, 30_000);

  it("ends a wait on a held peer at the deadline", async () => {
    const server = await startHeldServer();
    try {
      const clock = systemClock();
      const adapter = new FetchHttpAdapter({ monotonicClock: clock });
      const deadline = deadlineAfter(clock, 300);
      const driven = await within(drive(adapter, first(admittedHttp(), server.url, deadline)), 2000);
      if (driven.tag !== "Failed" || !("cause" in driven.failure.cause)) throw new Error(JSON.stringify(driven, (_k, v: unknown) => typeof v === "bigint" ? v.toString() : v));
      const cause = driven.failure.cause.cause;
      expect(cause).toMatchObject({ tag: "NetworkTerminal", terminal: { outcome: { tag: "DeadlineExceeded" } } });
      if (cause.tag !== "NetworkTerminal" || cause.terminal.outcome.tag !== "DeadlineExceeded") throw new Error("deadline terminal expected");
      expect(cause.terminal.outcome.observedAt.value - deadline.limit).toBeLessThan(250n);
      expect(driven.failure.retained).toEqual([]);
      const stopped = performance.now();
      while (recordCount(adapter) !== 0) {
        if (performance.now() - stopped > 2000) throw new Error("the record stayed without the peer being released");
        await new Promise<void>((resolve) => { setTimeout(resolve, 5); });
      }
    } finally {
      await server.close();
    }
  }, 10_000);

  it("completes with the response when it arrives before the deadline", async () => {
    const server = await startServer(100);
    try {
      const clock = systemClock();
      const adapter = new FetchHttpAdapter({ monotonicClock: clock });
      let calls = 0;
      const original = adapter.observe.bind(adapter);
      adapter.observe = (started) => { calls += 1; return original(started); };
      const deadline = deadlineAfter(clock, 300);
      const driven = await within(drive(adapter, first(admittedHttp(), server.url, deadline)), 3000);
      expect(driven.tag).toBe("Ok");
      if (driven.tag === "Ok") expect(driven.value.retained).toEqual([]);
      expect(recordCount(adapter)).toBe(0);
      expect(calls).toBeLessThanOrEqual(3);
    } finally {
      await server.close();
    }
  }, 10_000);

  it("fails typed without waiting when the clock cannot answer the wait length", async () => {
    const server = await startHeldServer();
    try {
      const clock = manualClock();
      const adapter = new FetchHttpAdapter({ monotonicClock: clock });
      const driven = await within(drive(adapter, first(admittedHttp(), server.url, deadlineAfter(clock, 300))), 1000);
      expect(driven).toMatchObject({ tag: "Failed", failure: { cause: { tag: "DeadlineWaitUnavailable" } } });
      if (driven.tag === "Failed") expect(driven.failure.retained).toHaveLength(1);
    } finally {
      await server.close();
    }
  }, 10_000);

  it("ends the drive with a host failure when the clock until throws", async () => {
    const server = await startHeldServer();
    try {
      const clock: httpAdapter.MonotonicClockPort = {
        ...manualClock(),
        until: () => { throw new Error("until failure"); },
      };
      const adapter = new FetchHttpAdapter({ monotonicClock: clock });
      const driven = await within(drive(adapter, first(admittedHttp(), server.url, deadlineAfter(clock, 300))), 2000);
      if (driven.tag !== "Failed" || !("cause" in driven.failure.cause)) throw new Error("terminal failure expected");
      expect(driven.failure.cause.cause).toMatchObject({
        tag: "NetworkTerminal",
        terminal: { outcome: { tag: "Failed", failure: { stage: "Deadline", cause: { tag: "HostRuntimeFailure" } } } },
      });
      await until(() => recordCount(adapter) === 0, "the record stayed without the peer being released");
    } finally {
      await server.close();
    }
  }, 10_000);

  it("returns an unknown handle as the drive failure", async () => {
    const server = await startServer(0);
    try {
      const adapter = new FetchHttpAdapter();
      const begun = first(admittedHttp(), server.url);
      if (begun.tag !== "Pending" || begun.instruction.tag !== "Send") throw new Error("send expected");
      const start = adapter.start(begun.instruction.command);
      const resumed = E.resume(begun.execution, { tag: "Start", observation: start });
      if (resumed.tag !== "Ok" || resumed.value.tag !== "Pending" || resumed.value.instruction.tag !== "Observe") throw new Error("observe expected");
      const stale = { prepared: resumed.value.instruction.started.prepared, handle: { value: "never-started" } };
      const failure = await drive(adapter, { tag: "Pending", execution: resumed.value.execution, instruction: { tag: "Observe", started: stale } });
      expect(failure).toMatchObject({ tag: "Failed", failure: { cause: { tag: "UnknownExecution", handle: { value: "never-started" } } } });
    } finally {
      await server.close();
    }
  });
});

interface Observing {
  readonly progress: E.Progress;
  readonly started: networkEffect.StartedAttempt;
  readonly state: networkEffect.NetworkState;
}

function beginObserving(
  adapter: httpAdapter.FetchHttpAdapter,
  target: string,
  cancellation: networkEffect.CancellationCapability | null,
): Observing {
  const begun = first(admittedHttp(), target, null, cancellation);
  if (begun.tag !== "Pending" || begun.instruction.tag !== "Send") throw new Error("send expected");
  const start = adapter.start(begun.instruction.command);
  const resumed = E.resume(begun.execution, { tag: "Start", observation: start });
  if (resumed.tag !== "Ok" || resumed.value.tag !== "Pending" || resumed.value.instruction.tag !== "Observe") {
    throw new Error("observe expected");
  }
  return { progress: resumed.value, started: resumed.value.instruction.started, state: resumed.value.execution.network };
}

function countObserves(adapter: httpAdapter.FetchHttpAdapter): () => number {
  let calls = 0;
  const original = adapter.observe.bind(adapter);
  adapter.observe = (started) => { calls += 1; return original(started); };
  return () => calls;
}

async function until(ready: () => boolean, what: string): Promise<void> {
  const limit = performance.now() + 5_000;
  while (!ready()) {
    if (performance.now() > limit) throw new Error(what);
    await new Promise<void>((resolve) => { setTimeout(resolve, 1); });
  }
}

describe("a wait on a record that is removed", () => {
  it("returns the unknown handle when the worker ends after a release that settled the core", async () => {
    const server = await startHeldServer();
    try {
      const capability = { identity: { value: "cancel" } };
      const adapter = new FetchHttpAdapter({ cancellation: { capability: () => capability, request: () => ({ tag: "CancellationRejected" as const }) } });
      const { progress, started, state } = beginObserving(adapter, server.url, capability);
      const command = networkEffect.cancelCommand(state, started);
      if (command.tag !== "CommandReady") throw new Error("cancel command failed");
      const rejected = adapter.cancel(command.command as networkEffect.CancelCommand);
      expect(rejected).toMatchObject({
        tag: "Delivered",
        observation: { tag: "FailureObservation", failure: { cause: { tag: "CancellationRejected" } } },
      });
      const terminal = networkEffect.observe(state, rejected as networkEffect.HostObservation);
      if (terminal.tag !== "Terminal") throw new Error("terminal expected");
      const calls = countObserves(adapter);
      const driven = drive(adapter, progress);
      await until(() => calls() >= 1, "the drive never started waiting");
      expect(["retain", "dematerialize"]).toContain(adapter.release(terminal.state, started).kind);
      const result = await within(driven, 5_000);
      expect(result).toMatchObject({ tag: "Failed", failure: { cause: { tag: "UnknownExecution", handle: started.handle } } });
      expect(recordCount(adapter)).toBe(0);
    } finally {
      await server.close();
    }
  }, 15_000);

  it("returns the unknown handle when a finished worker is released and dematerialized", async () => {
    const server = await startServer(0);
    try {
      const adapter = new FetchHttpAdapter();
      const { progress, started, state } = beginObserving(adapter, server.url, null);
      let delivered: networkEffect.HostObservation | undefined;
      await until(() => {
        const next = adapter.observe(started);
        if (next.tag === "Delivered") delivered = next;
        return delivered !== undefined;
      }, "the response never arrived");
      if (delivered === undefined) throw new Error("delivery expected");
      const terminal = networkEffect.observe(state, delivered);
      if (terminal.tag !== "Terminal") throw new Error("terminal expected");
      await until(() => {
        const decision = adapter.release(state, started);
        return decision.kind === "retain"
          && !decision.reasons.some((reason) => reason.kind === "outstandingEffect");
      }, "the worker kept running");
      const calls = countObserves(adapter);
      const driven = drive(adapter, progress);
      await until(() => calls() >= 1, "the drive never started waiting");
      expect(adapter.release(terminal.state, started)).toMatchObject({ kind: "dematerialize" });
      const result = await within(driven, 5_000);
      expect(result).toMatchObject({ tag: "Failed", failure: { cause: { tag: "UnknownExecution", handle: started.handle } } });
      expect(recordCount(adapter)).toBe(0);
    } finally {
      await server.close();
    }
  }, 15_000);
});

function sendCommand(begun: E.Progress): networkEffect.SendCommand {
  if (begun.tag !== "Pending" || begun.instruction.tag !== "Send") throw new Error("send expected");
  return begun.instruction.command;
}

function startedOf(command: networkEffect.SendCommand, start: networkEffect.StartObservation): networkEffect.StartedAttempt {
  if (start.tag !== "Started") throw new Error("started expected");
  return { prepared: command.prepared, handle: start.handle };
}

function clockReading(basisValue: string, value: bigint): httpAdapter.MonotonicClockPort {
  return { capability: () => clockCapability, observe: () => ({ clockBasis: { value: basisValue }, value }) };
}

describe("ports", () => {
  async function observeWithClock(clock: httpAdapter.MonotonicClockPort, limit: bigint): Promise<networkEffect.HostObservation | httpAdapter.UnknownExecution> {
    const server = await startHeldServer();
    try {
      const adapter = new FetchHttpAdapter({ monotonicClock: clock });
      const command = sendCommand(first(admittedHttp(), server.url, { clockBasis, limit, capability: clockCapability }));
      const started = startedOf(command, adapter.start(command));
      await new Promise<void>((resolve) => { setTimeout(resolve, 50); });
      const observed = adapter.observe(started);
      adapter.close(started);
      return observed;
    } finally {
      await server.close();
    }
  }

  it("leaves observe pending when the clock reports another basis past the limit", async () => {
    const observed = await observeWithClock(clockReading("other-basis", 100n), 10n);
    expect(observed.tag).toBe("Pending");
  }, 10_000);

  it("delivers the deadline when the clock reports the same basis at the limit", async () => {
    const observed = await observeWithClock(clockReading(clockBasis.value, 10n), 10n);
    expect(observed).toMatchObject({ tag: "Delivered", observation: { tag: "DeadlineObservation" } });
  }, 10_000);

  it("leaves observe pending when the clock reports the same basis one below the limit", async () => {
    const observed = await observeWithClock(clockReading(clockBasis.value, 9n), 10n);
    expect(observed.tag).toBe("Pending");
  }, 10_000);

  it("fails the start with a host runtime failure when the clock capability read throws", async () => {
    const clock: httpAdapter.MonotonicClockPort = {
      capability: () => { throw new Error("clock capability failure"); },
      observe: () => ({ clockBasis, value: 0n }),
    };
    const adapter = new FetchHttpAdapter({ monotonicClock: clock });
    const command = sendCommand(first(admittedHttp(), "http://127.0.0.1:1/", { clockBasis, limit: 10n, capability: clockCapability }));
    const start = adapter.start(command);
    expect(start).toMatchObject({ tag: "StartFailed", failure: { stage: "Start", cause: { tag: "HostRuntimeFailure" } } });
    expect(recordCount(adapter)).toBe(0);
  });

  it("fails the start with a host runtime failure when the cancellation capability read throws", async () => {
    const capability = { identity: { value: "cancel" } };
    const adapter = new FetchHttpAdapter({
      cancellation: { capability: () => { throw new Error("cancellation capability failure"); }, request: () => undefined },
    });
    const command = sendCommand(first(admittedHttp(), "http://127.0.0.1:1/", null, capability));
    const start = adapter.start(command);
    expect(start).toMatchObject({ tag: "StartFailed", failure: { stage: "Start", cause: { tag: "HostRuntimeFailure" } } });
    expect(recordCount(adapter)).toBe(0);
  });

  it("delivers a cancel host runtime failure when the cancellation capability read throws", async () => {
    const server = await startHeldServer();
    try {
      const capability = { identity: { value: "cancel" } };
      let armed = false;
      const adapter = new FetchHttpAdapter({
        cancellation: {
          capability: () => { if (armed) throw new Error("cancellation capability failure"); return capability; },
          request: () => undefined,
        },
      });
      const command = sendCommand(first(admittedHttp(), server.url, null, capability));
      const started = startedOf(command, adapter.start(command));
      armed = true;
      const observed = adapter.cancel({ attempt: command.prepared.input.attempt, handle: started.handle, capability });
      expect(observed).toMatchObject({
        tag: "Delivered",
        observation: {
          tag: "FailureObservation",
          failure: { stage: "Cancel", cause: { tag: "HostRuntimeFailure" } },
          effect: { tag: "Unknown", reason: "HostFailure" },
        },
      });
      adapter.close(started);
    } finally {
      await server.close();
    }
  }, 10_000);
});
