// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { createHash } from "node:crypto";
import { once } from "node:events";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { describe, expect, it } from "vitest";
import * as httpAdapter from "../src/index.js";
import { networkEffect } from "necoherence";

const { FetchHttpAdapter } = httpAdapter;
const {
  cancelCommand,
  emptyNetworkState,
  observe,
  observeStart,
  prepare,
  retry,
  sendCommand,
} = networkEffect;
type FetchHttpAdapter = httpAdapter.FetchHttpAdapter;
type FetchLike = httpAdapter.FetchLike;
type HostObservation = networkEffect.HostObservation;
type HostStage = networkEffect.HostStage;
type HostTimeoutCause = networkEffect.HostTimeoutCause;
type AttemptInput = networkEffect.AttemptInput;
type SendCommand = networkEffect.SendCommand;

type Delivered = Extract<HostObservation, { readonly tag: "Delivered" }>;
type FailureObservation = Extract<networkEffect.AdapterObservation, { readonly tag: "FailureObservation" }>;

interface LoopbackPeer {
  readonly url: string;
  readonly receivedCount: () => number;
  readonly acceptedCount: () => number;
  readonly waitForRequest: () => Promise<void>;
  readonly close: () => Promise<void>;
}

const baseConfiguration: networkEffect.HostConfiguration = {
  requestBodyLimit: 16n * 1024n * 1024n,
  responseBodyLimit: 1024n,
  cancellation: null,
  monotonicClock: null,
};

function inputFor(
  revision: bigint,
  instruction: Partial<networkEffect.HttpWireInstruction> = {},
  configuration: networkEffect.HostConfiguration = baseConfiguration,
  deadline: networkEffect.Deadline | null = null,
): AttemptInput {
  return {
    attempt: {
      logical: { kind: "http", provenance: "host-smoke", revision },
      ordinal: 0n,
    },
    instruction: {
      method: instruction.method ?? "GET",
      target: instruction.target ?? "http://127.0.0.1/",
      headers: instruction.headers ?? [],
      body: instruction.body ?? new Uint8Array(),
    },
    deadline,
    configuration,
  };
}

function commandFor(input: AttemptInput): {
  readonly command: SendCommand;
  readonly state: networkEffect.NetworkState;
  readonly prepared: networkEffect.PreparedAttempt;
} {
  const prepared = prepare(emptyNetworkState(), input);
  if (prepared.tag !== "Prepared") throw new Error("prepare failed");
  const issued = sendCommand(prepared.state, prepared.prepared);
  if (issued.tag !== "CommandReady") throw new Error("send command failed");
  return { command: issued.command, state: issued.state, prepared: prepared.prepared };
}

function forgedCommand(input: AttemptInput): SendCommand {
  return { prepared: { input, chain: { tag: "Root" } } };
}

async function startPeer(
  handler: (request: IncomingMessage, response: ServerResponse) => void,
): Promise<LoopbackPeer> {
  let received = 0;
  let accepted = 0;
  let resolveFirstRequest: (() => void) | undefined;
  const firstRequest = new Promise<void>((resolve) => {
    resolveFirstRequest = resolve;
  });
  const server = createServer((request, response) => {
    received += 1;
    resolveFirstRequest?.();
    handler(request, response);
  });
  server.on("connection", () => { accepted += 1; });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address() as AddressInfo;
  return {
    url: `http://127.0.0.1:${address.port}`,
    receivedCount: () => received,
    acceptedCount: () => accepted,
    waitForRequest: () => received > 0 ? Promise.resolve() : firstRequest,
    close: () => closeServer(server),
  };
}

async function closeServer(server: Server): Promise<void> {
  if (!server.listening) return;
  server.close();
  server.closeAllConnections();
  await once(server, "close");
}

function startedOf(
  command: SendCommand,
  started: { readonly handle: { readonly value: string } },
): networkEffect.StartedAttempt {
  return { prepared: command.prepared, handle: started.handle };
}

async function nextDelivered(
  adapter: Pick<FetchHttpAdapter, "observe">,
  started: networkEffect.StartedAttempt,
): Promise<Delivered> {
  const deadline = performance.now() + 5_000;
  while (performance.now() < deadline) {
    const observation = adapter.observe(started);
    if (observation.tag === "Delivered") return observation;
    await new Promise<void>((resolve) => setTimeout(resolve, 1));
  }
  throw new Error("adapter did not deliver an observation");
}

async function nextFailure(
  adapter: Pick<FetchHttpAdapter, "start" | "observe">,
  command: SendCommand,
): Promise<{ readonly delivered: Delivered; readonly failure: FailureObservation }> {
  const started = adapter.start(command);
  if (started.tag !== "Started") throw new Error(`expected Started, received ${started.tag}`);
  const delivered = await nextDelivered(adapter, startedOf(command, started));
  if (delivered.observation.tag !== "FailureObservation") {
    throw new Error(`expected FailureObservation, received ${delivered.observation.tag}`);
  }
  return { delivered, failure: delivered.observation };
}

function instructionDigest(instruction: networkEffect.HttpWireInstruction): string {
  return createHash("sha256").update(JSON.stringify(instruction)).digest("hex");
}


function immediateFailureFetch(error: Error): FetchLike {
  return async () => { throw error; };
}

function responseLike(
  status: number,
  body: readonly number[] = [],
  fields: readonly (readonly [string, string])[] = [],
): httpAdapter.FetchResponseLike {
  return {
    status,
    headers: { entries: () => fields },
    arrayBuffer: async () => Uint8Array.from(body).buffer,
  };
}

class TimeoutPairTestAdapter {
  readonly #stage: HostStage;
  readonly #cause: HostTimeoutCause;
  #worker: {
    readonly command: SendCommand;
    readonly handle: { readonly value: string };
    delivered: boolean;
  } | undefined;

  public constructor(stage: HostStage, cause: HostTimeoutCause) {
    this.#stage = stage;
    this.#cause = cause;
  }

  public start(command: SendCommand): networkEffect.StartObservation {
    const handle = { value: "typescript.test.timeout" };
    this.#worker = { command, handle, delivered: false };
    return {
      tag: "Started",
      attempt: command.prepared.input.attempt,
      handle,
    };
  }

  public observe(started: networkEffect.StartedAttempt): HostObservation {
    const worker = this.#worker;
    if (worker === undefined || worker.handle.value !== started.handle.value) {
      throw new Error("unknown test worker");
    }
    if (worker.delivered) {
      return {
        tag: "Pending",
        attempt: worker.command.prepared.input.attempt,
        handle: worker.handle,
      };
    }
    worker.delivered = true;
    const input = worker.command.prepared.input;
    return {
      tag: "Delivered",
      delivery: 0n,
      observation: {
        tag: "FailureObservation",
        attempt: input.attempt,
        handle: worker.handle,
        sourceSequence: { tag: "none" },
        failure: {
          attempt: input.attempt,
          stage: this.#stage,
          configuration: input.configuration,
          cause: {
            tag: "Timeout",
            stage: this.#stage,
            cause: this.#cause,
          },
        },
        effect: { tag: "Unknown", reason: "NoResponse" },
      },
    };
  }
}

describe("network effect Node fetch adapter", () => {
  it("starts before native completion and preserves normalized response evidence and causal counts", async () => {
    const requestBodies: number[][] = [];
    const peer = await startPeer((request, response) => {
      const chunks: Buffer[] = [];
      request.on("data", (chunk: Buffer) => chunks.push(chunk));
      request.on("end", () => requestBodies.push(Array.from(Buffer.concat(chunks))));
      response.setHeader("x-z", "last");
      response.setHeader("x-repeat", ["first", "second"]);
      response.setHeader("x-utf8", "é");
      response.writeHead(201);
      response.end(Uint8Array.from([0, 128, 255]));
    });
    try {
      const candidate = inputFor(1n, {
        method: "POST",
        target: `${peer.url}/native?query=1`,
        headers: [{ name: "x-input", value: Uint8Array.of(111, 107) }],
        body: Uint8Array.of(0, 128, 255),
      });
      const prepared = commandFor(candidate);
      const adapter = new FetchHttpAdapter();
      let issuedCommandCount = 0;
      issuedCommandCount += 1;
      const started = adapter.start(prepared.command);
      expect(started.tag).toBe("Started");
      if (started.tag !== "Started") return;
      expect(peer.receivedCount()).toBe(0);
      expect(adapter.observe(startedOf(prepared.command, started))).toEqual({
        tag: "Pending",
        attempt: candidate.attempt,
        handle: started.handle,
      });

      const delivered = await nextDelivered(adapter, startedOf(prepared.command, started));
      expect(delivered.delivery).toBe(0n);
      expect(delivered.observation).toMatchObject({
        tag: "ResponseObservation",
        attempt: candidate.attempt,
        handle: started.handle,
        sourceSequence: { tag: "some", value: 0n },
        response: { status: 201, body: Uint8Array.of(0, 128, 255) },
        provenance: "LibraryNormalized",
        effect: { tag: "Unknown", reason: "ProtocolWitnessMissing" },
      });
      if (delivered.observation.tag !== "ResponseObservation") return;
      const responseHeaderNames = delivered.observation.response.headers.map(
        (field) => field.name,
      );
      expect(responseHeaderNames).toEqual([...responseHeaderNames].sort());
      expect(responseHeaderNames).toEqual(
        expect.arrayContaining(["x-repeat", "x-utf8", "x-z"]),
      );
      expect(delivered.observation.response.headers.find((field) => field.name === "x-repeat")?.value)
        .toEqual(new TextEncoder().encode("first, second"));
      expect(delivered.observation.response.headers.find((field) => field.name === "x-utf8")?.value)
        .toEqual(Uint8Array.of(0xc3, 0xa9));

      const startedState = observeStart(prepared.state, prepared.prepared, started);
      if (startedState.tag !== "Started") throw new Error("observeStart failed");
      const terminal = observe(startedState.state, delivered);
      expect(terminal).toMatchObject({
        tag: "Terminal",
        settled: {
          terminal: {
            outcome: {
              tag: "Response",
              response: { status: 201, body: Uint8Array.of(0, 128, 255) },
              provenance: "LibraryNormalized",
            },
          },
        },
      });
      if (terminal.tag !== "Terminal") throw new Error("response did not settle");
      expect(observe(terminal.state, delivered)).toMatchObject({
        tag: "Duplicate",
        delivery: 0n,
      });
      expect(observe(terminal.state, {
        ...delivered,
        observation: {
          ...delivered.observation,
          response: { ...delivered.observation.response, body: Uint8Array.of(255, 0) },
        },
      })).toMatchObject({
        tag: "Rejected",
        failure: { tag: "ConflictingDelivery", delivery: 0n },
      });

      const ledgerRecordCount = networkEffect.networkAttempts(prepared.state).length;
      const peerReceivedCount = peer.receivedCount();
      const causalIdentity = {
        attempt: candidate.attempt,
        ordinal: candidate.attempt.ordinal,
        instructionDigest: instructionDigest(candidate.instruction),
        handle: started.handle,
      };
      expect({ ledgerRecordCount, issuedCommandCount, peerReceivedCount }).toEqual({
        ledgerRecordCount: 1,
        issuedCommandCount: 1,
        peerReceivedCount: 1,
      });
      expect(peerReceivedCount).toBeLessThanOrEqual(issuedCommandCount);
      expect(causalIdentity.attempt).toEqual(candidate.attempt);
      expect(causalIdentity.ordinal).toBe(0n);
      expect(causalIdentity.handle.value).toBe("typescript.worker.0");
      expect(causalIdentity.instructionDigest).not.toBe(instructionDigest({
        ...candidate.instruction,
        target: `${peer.url}/different`,
      }));
      expect(requestBodies).toEqual([[0, 128, 255]]);
    } finally {
      await peer.close();
    }
  });

  it("keeps protocol statuses as raw responses", async () => {
    const peer = await startPeer((request, response) => {
      const status = Number(request.url?.slice(1));
      response.writeHead(status);
      response.end(`status-${status}`);
    });
    try {
      const adapter = new FetchHttpAdapter();
      for (const [index, status] of [404, 429, 500].entries()) {
        const prepared = commandFor(inputFor(BigInt(10 + index), {
          target: `${peer.url}/${status}`,
        }));
        const started = adapter.start(prepared.command);
        if (started.tag !== "Started") throw new Error("start failed");
        const delivered = await nextDelivered(adapter, startedOf(prepared.command, started));
        expect(delivered.observation).toMatchObject({
          tag: "ResponseObservation",
          response: { status },
        });
      }
      expect(peer.receivedCount()).toBe(3);
    } finally {
      await peer.close();
    }
  });

  it("keeps delayed polls pending and records deadline without a late response", async () => {
    let release: (() => void) | undefined;
    const peer = await startPeer((_request, response) => {
      release = () => {
        if (response.writableEnded) return;
        response.writeHead(200, { "x-release": "yes" });
        response.end("released");
      };
    });
    const clockBasis = { value: "host-smoke-clock" };
    const capability = { identity: { value: "clock-capability" }, clockBasis };
    let clockValue = 0n;
    try {
      const candidate = inputFor(
        20n,
        { target: `${peer.url}/delay` },
        { ...baseConfiguration, monotonicClock: capability },
        { clockBasis, limit: 5n, capability },
      );
      const prepared = commandFor(candidate);
      const adapter = new FetchHttpAdapter({
        monotonicClock: { capability: () => capability, observe: () => ({ clockBasis, value: clockValue }) },
      });
      const started = adapter.start(prepared.command);
      if (started.tag !== "Started") throw new Error("start failed");
      const startedAttempt = startedOf(prepared.command, started);
      expect(adapter.observe(startedAttempt).tag).toBe("Pending");
      expect(adapter.observe(startedAttempt).tag).toBe("Pending");
      await peer.waitForRequest();
      clockValue = 5n;
      const deadline = adapter.observe(startedAttempt);
      expect(deadline).toMatchObject({
        tag: "Delivered",
        delivery: 0n,
        observation: {
          tag: "DeadlineObservation",
          deadline: candidate.deadline,
          observedAt: { clockBasis, value: 5n },
          effect: { tag: "Unknown", reason: "Deadline" },
        },
      });
      release?.();
      await new Promise<void>((resolve) => setTimeout(resolve, 50));
      expect(adapter.observe(startedAttempt).tag).toBe("Pending");
      const startedState = observeStart(prepared.state, prepared.prepared, started);
      if (startedState.tag !== "Started" || deadline.tag !== "Delivered") {
        throw new Error("state transition setup failed");
      }
      expect(observe(startedState.state, deadline).tag).toBe("Terminal");
    } finally {
      release?.();
      await peer.close();
    }
  });

  it("maps a clock observe exception to one host runtime failure without calling the port again", async () => {
    let release: (() => void) | undefined;
    const peer = await startPeer((_request, response) => {
      release = () => {
        if (response.writableEnded) return;
        response.writeHead(200);
        response.end("released");
      };
    });
    const clockBasis = { value: "raising-clock" };
    const capability = { identity: { value: "raising-clock-capability" }, clockBasis };
    let observeCalls = 0;
    try {
      const candidate = inputFor(
        21n,
        { target: `${peer.url}/delay` },
        { ...baseConfiguration, monotonicClock: capability },
        { clockBasis, limit: 5n, capability },
      );
      const prepared = commandFor(candidate);
      const adapter = new FetchHttpAdapter({
        monotonicClock: {
          capability: () => capability,
          observe: () => {
            observeCalls += 1;
            if (observeCalls > 1) throw new Error("clock failure");
            return { clockBasis, value: 0n };
          },
        },
      });
      const started = adapter.start(prepared.command);
      if (started.tag !== "Started") throw new Error("start failed");
      const startedAttempt = startedOf(prepared.command, started);
      await peer.waitForRequest();
      expect(observeCalls).toBe(1);
      const first = adapter.observe(startedAttempt);
      expect(first).toMatchObject({
        tag: "Delivered",
        delivery: 0n,
        observation: {
          tag: "FailureObservation",
          failure: { stage: "Deadline", cause: { tag: "HostRuntimeFailure" } },
          effect: { tag: "Unknown", reason: "HostFailure" },
        },
      });
      expect(observeCalls).toBe(2);
      expect(adapter.observe(startedAttempt).tag).toBe("Pending");
      expect(observeCalls).toBe(2);
    } finally {
      release?.();
      await peer.close();
    }
  });

  describe("the deadline check before the request is sent", () => {
    const clockBasis = { value: "before-send-clock" };
    const otherBasis = { value: "other-clock" };
    const capability = { identity: { value: "before-send-capability" }, clockBasis };

    async function launch(
      revision: bigint,
      observeClock: (call: number) => networkEffect.MonotonicClockObservation,
    ): Promise<{
      readonly peer: LoopbackPeer;
      readonly adapter: FetchHttpAdapter;
      readonly started: networkEffect.StartedAttempt;
      readonly calls: () => number;
    }> {
      const peer = await startPeer((_request, response) => response.end("ok"));
      let calls = 0;
      const prepared = commandFor(inputFor(
        revision,
        { target: `${peer.url}/before-send` },
        { ...baseConfiguration, monotonicClock: capability },
        { clockBasis, limit: 5n, capability },
      ));
      const adapter = new FetchHttpAdapter({
        monotonicClock: {
          capability: () => capability,
          observe: () => {
            calls += 1;
            return observeClock(calls);
          },
        },
      });
      const started = adapter.start(prepared.command);
      if (started.tag !== "Started") throw new Error("start failed");
      return { peer, adapter, started: startedOf(prepared.command, started), calls: () => calls };
    }

    it("sends no request when the clock is at the deadline from the start", async () => {
      const { peer, adapter, started } = await launch(40n, () => ({ clockBasis, value: 5n }));
      try {
        await new Promise<void>((resolve) => setTimeout(resolve, 300));
        expect(peer.acceptedCount()).toBe(0);
        const delivered = await nextDelivered(adapter, started);
        expect(delivered).toMatchObject({
          observation: {
            tag: "DeadlineObservation",
            effect: { tag: "Unknown", reason: "Deadline" },
          },
        });
        expect(adapter.observe(started).tag).toBe("Pending");
      } finally {
        await peer.close();
      }
    });

    it("sends the request when the clock is one before the deadline", async () => {
      const { peer, adapter, started } = await launch(41n, () => ({ clockBasis, value: 4n }));
      try {
        await peer.waitForRequest();
        expect(peer.receivedCount()).toBe(1);
        const delivered = await nextDelivered(adapter, started);
        expect(delivered.observation.tag).toBe("ResponseObservation");
      } finally {
        await peer.close();
      }
    });

    it("sends the request when only the clock basis differs from the deadline", async () => {
      const { peer, started } = await launch(42n, () => ({ clockBasis: otherBasis, value: 9n }));
      try {
        await peer.waitForRequest();
        expect(peer.receivedCount()).toBe(1);
        expect(started.handle.value.length).toBeGreaterThan(0);
      } finally {
        await peer.close();
      }
    });

    it("reports one clock failure and sends no request when only the first read fails", async () => {
      const { peer, adapter, started, calls } = await launch(43n, (call) => {
        if (call === 1) throw new Error("first read");
        return { clockBasis, value: 0n };
      });
      try {
        await new Promise<void>((resolve) => setTimeout(resolve, 300));
        expect(peer.acceptedCount()).toBe(0);
        const delivered = await nextDelivered(adapter, started);
        expect(delivered).toMatchObject({
          observation: {
            tag: "FailureObservation",
            failure: { stage: "Deadline", cause: { tag: "HostRuntimeFailure" } },
          },
        });
        expect(adapter.observe(started).tag).toBe("Pending");
        expect(calls()).toBe(1);
      } finally {
        await peer.close();
      }
    });
  });

  it("classifies pre-handle validation failures without peer receipt", async () => {
    const peer = await startPeer((_request, response) => response.end("unexpected"));
    try {
      const unsupported = commandFor(inputFor(30n, { target: "ftp://127.0.0.1/value" }));
      expect(new FetchHttpAdapter().start(unsupported.command)).toMatchObject({
        tag: "StartFailed",
        failure: { stage: "Start", cause: { tag: "UnsupportedUriScheme" } },
      });
      const invalid = forgedCommand(inputFor(
        31n,
        { target: `${peer.url}/invalid`, body: Uint8Array.of(1) },
        { ...baseConfiguration, requestBodyLimit: 0n },
      ));
      expect(new FetchHttpAdapter().start(invalid)).toMatchObject({
        tag: "StartFailed",
        failure: { cause: { tag: "InvalidHostConfiguration" } },
      });
      const bootstrap = commandFor(inputFor(32n, { target: `${peer.url}/bootstrap` }));
      expect(new FetchHttpAdapter({
        createAbortController: () => { throw new Error("bootstrap"); },
      }).start(bootstrap.command)).toMatchObject({
        tag: "StartFailed",
        failure: { cause: { tag: "ExecutionStartFailed" } },
      });
      const basis = { value: "missing-clock" };
      const capability = { identity: { value: "missing" }, clockBasis: basis };
      const deadline = commandFor(inputFor(
        33n,
        { target: `${peer.url}/deadline` },
        { ...baseConfiguration, monotonicClock: capability },
        { clockBasis: basis, limit: 1n, capability },
      ));
      expect(new FetchHttpAdapter().start(deadline.command)).toMatchObject({
        tag: "StartFailed",
        failure: { cause: { tag: "DeadlineControlUnavailable" } },
      });
      expect(peer.receivedCount()).toBe(0);
    } finally {
      await peer.close();
    }
  });

  it("checks the start conditions in the fixed order", () => {
    const basis = { value: "order-basis" };
    const capability = { identity: { value: "order-clock" }, clockBasis: basis };
    const configuration = { ...baseConfiguration, requestBodyLimit: 0n, monotonicClock: capability };
    const deadline = { clockBasis: basis, limit: 1n, capability };
    const body = Uint8Array.of(1);
    expect(new FetchHttpAdapter().start(forgedCommand(inputFor(
      50n,
      { target: "ftp://127.0.0.1/", body },
      configuration,
      deadline,
    )))).toMatchObject({
      tag: "StartFailed",
      failure: { stage: "Start", cause: { tag: "UnsupportedUriScheme" } },
    });
    expect(new FetchHttpAdapter().start(forgedCommand(inputFor(
      51n,
      { target: "http://127.0.0.1/", body },
      configuration,
      deadline,
    )))).toMatchObject({
      tag: "StartFailed",
      failure: { stage: "Start", cause: { tag: "InvalidHostConfiguration" } },
    });
    const withClock = { ...baseConfiguration, monotonicClock: capability };
    expect(new FetchHttpAdapter().start(commandFor(inputFor(
      52n,
      { target: "http://127.0.0.1/" },
      withClock,
      deadline,
    )).command)).toMatchObject({
      tag: "StartFailed",
      failure: { stage: "Start", cause: { tag: "DeadlineControlUnavailable" } },
    });
  });

  it("reports an unavailable or mismatched deadline clock as a start failure", async () => {
    const peer = await startPeer((_request, response) => response.end("unexpected"));
    try {
      const basis = { value: "matrix" };
      const capability = { identity: { value: "matrix-clock" }, clockBasis: basis };
      const configuration = { ...baseConfiguration, monotonicClock: capability };
      const deadline = { clockBasis: basis, limit: 10n ** 18n, capability };
      const command = commandFor(inputFor(
        53n,
        { target: `${peer.url}/clock` },
        configuration,
        deadline,
      )).command;
      const absent = new FetchHttpAdapter();
      expect(absent.start(command)).toMatchObject({
        tag: "StartFailed",
        failure: { stage: "Start", cause: { tag: "DeadlineControlUnavailable" } },
      });
      const foreign = new FetchHttpAdapter({
        monotonicClock: {
          capability: () => ({ identity: capability.identity, clockBasis: { value: "foreign-basis" } }),
          observe: () => ({ clockBasis: { value: "foreign-basis" }, value: 0n }),
        },
      });
      expect(foreign.start(command)).toMatchObject({
        tag: "StartFailed",
        failure: { stage: "Start", cause: { tag: "DeadlineControlUnavailable" } },
      });
      const sameBasisOtherIdentity = new FetchHttpAdapter({
        monotonicClock: {
          capability: () => ({ identity: { value: "other-clock" }, clockBasis: basis }),
          observe: () => ({ clockBasis: basis, value: 0n }),
        },
      });
      expect(sameBasisOtherIdentity.start(command)).toMatchObject({
        tag: "StartFailed",
        failure: { stage: "Start", cause: { tag: "DeadlineControlUnavailable" } },
      });
      expect(peer.receivedCount()).toBe(0);
      const matching = new FetchHttpAdapter({
        monotonicClock: { capability: () => capability, observe: () => ({ clockBasis: basis, value: 0n }) },
        fetch: async () => responseLike(200),
      });
      expect(matching.start(command).tag).toBe("Started");
    } finally {
      await peer.close();
    }
  });

  it("rejects a cancellation capability that differs from the port as a start failure", async () => {
    const peer = await startPeer((_request, response) => response.end("unexpected"));
    try {
      const configured = { identity: { value: "configured-cancel" } };
      const command = commandFor(inputFor(
        60n,
        { target: `${peer.url}/cancel-mismatch` },
        { ...baseConfiguration, cancellation: configured },
      )).command;
      const other = new FetchHttpAdapter({
        cancellation: { capability: () => ({ identity: { value: "port-cancel" } }), request: () => undefined },
      });
      expect(other.start(command)).toMatchObject({
        tag: "StartFailed",
        failure: { stage: "Start", cause: { tag: "InvalidHostConfiguration" } },
      });
      expect(new FetchHttpAdapter().start(command)).toMatchObject({
        tag: "StartFailed",
        failure: { stage: "Start", cause: { tag: "InvalidHostConfiguration" } },
      });
      expect(peer.receivedCount()).toBe(0);
      const matching = new FetchHttpAdapter({
        cancellation: { capability: () => configured, request: () => undefined },
        fetch: async () => responseLike(200),
      });
      expect(matching.start(command).tag).toBe("Started");
    } finally {
      await peer.close();
    }
  });

  it("marks a response with the missing protocol witness", async () => {
    const adapter = new FetchHttpAdapter({ fetch: async () => responseLike(200, [1]) });
    const command = commandFor(inputFor(54n)).command;
    const started = adapter.start(command);
    if (started.tag !== "Started") throw new Error("start failed");
    const delivered = await nextDelivered(adapter, startedOf(command, started));
    expect(delivered.observation).toMatchObject({
      tag: "ResponseObservation",
      effect: { tag: "Unknown", reason: "ProtocolWitnessMissing" },
    });
  });

  it("keeps the stage of the worker for an unclassified failure", async () => {
    const throwingSignal = {
      get signal(): unknown { throw new Error("signal unavailable"); },
      abort: () => undefined,
    };
    const beforeRequest = new FetchHttpAdapter({
      createAbortController: () => throwingSignal,
      fetch: async () => responseLike(200),
    });
    const early = await nextFailure(beforeRequest, commandFor(inputFor(55n)).command);
    expect(early.failure.failure).toMatchObject({
      stage: "RequestWrite",
      cause: { tag: "HostRuntimeFailure" },
    });

    const inHeaders = new FetchHttpAdapter({
      fetch: immediateFailureFetch(new Error("unclassified worker failure")),
    });
    const headers = await nextFailure(inHeaders, commandFor(inputFor(56n)).command);
    expect(headers.failure.failure).toMatchObject({
      stage: "ResponseHeaders",
      cause: { tag: "HostRuntimeFailure" },
    });

    let reads = 0;
    const inBody = new FetchHttpAdapter({
      fetch: async () => ({
        get status(): number {
          reads += 1;
          if (reads > 3) throw new Error("status unavailable");
          return 200;
        },
        headers: { entries: () => [] },
        arrayBuffer: async () => new ArrayBuffer(0),
      }),
    });
    const body = await nextFailure(inBody, commandFor(inputFor(57n)).command);
    expect(body.failure.failure).toMatchObject({
      stage: "ResponseBody",
      cause: { tag: "HostRuntimeFailure" },
    });
  });

  it("classifies resolver, refusal, encoding, codec, runtime, and cancellation failures", async () => {
    const resolver = commandFor(inputFor(40n, { target: "http://unresolvable.invalid/" }));
    expect((await nextFailure(new FetchHttpAdapter(), resolver.command)).failure.failure.cause.tag)
      .toBe("NameResolutionFailed");

    const refusedPeer = await startPeer((_request, response) => response.end());
    const refusedTarget = refusedPeer.url;
    await refusedPeer.close();
    const refused = commandFor(inputFor(41n, { target: refusedTarget }));
    expect((await nextFailure(new FetchHttpAdapter(), refused.command)).failure.failure.cause.tag)
      .toBe("ConnectionFailed");

    let fetchCalls = 0;
    const badHeader = commandFor(inputFor(42n, {
      target: "http://127.0.0.1/encoding",
      headers: [{ name: "x-invalid", value: Uint8Array.of(255) }],
    }));
    const encodingAdapter = new FetchHttpAdapter({
      fetch: async () => {
        fetchCalls += 1;
        return responseLike(200);
      },
    });
    expect((await nextFailure(encodingAdapter, badHeader.command)).failure.failure.cause.tag)
      .toBe("RequestHeaderEncodingUnavailable");
    expect(fetchCalls).toBe(0);

    const codecAdapter = new FetchHttpAdapter({
      fetch: async () => ({
        status: 200,
        headers: { entries: () => { throw new Error("codec"); } },
        arrayBuffer: async () => new ArrayBuffer(0),
      }),
    });
    expect((await nextFailure(codecAdapter, commandFor(inputFor(43n)).command))
      .failure.failure.cause.tag).toBe("HeaderRepresentationUnavailable");

    const runtimeAdapter = new FetchHttpAdapter({
      fetch: immediateFailureFetch(new Error("unclassified worker failure")),
    });
    expect((await nextFailure(runtimeAdapter, commandFor(inputFor(44n)).command))
      .failure.failure.cause.tag).toBe("HostRuntimeFailure");

    let release: (() => void) | undefined;
    const peer = await startPeer((_request, response) => {
      release = () => response.end("released");
    });
    try {
      const cancellation = { identity: { value: "cancel-capability" } };
      const candidate = inputFor(
        45n,
        { target: `${peer.url}/cancel` },
        { ...baseConfiguration, cancellation },
      );
      const prepared = commandFor(candidate);
      const adapter = new FetchHttpAdapter({ cancellation: { capability: () => cancellation, request: () => ({ tag: "CancellationRejected" as const }) } });
      const started = adapter.start(prepared.command);
      if (started.tag !== "Started") throw new Error("start failed");
      const startedState = observeStart(prepared.state, prepared.prepared, started);
      if (startedState.tag !== "Started") throw new Error("start observation failed");
      const cancellationCommand = cancelCommand(startedState.state, startedState.started);
      if (cancellationCommand.tag !== "CommandReady") throw new Error("cancel command failed");
      const rejected = adapter.cancel(cancellationCommand.command);
      expect(rejected).toMatchObject({
        tag: "Delivered",
        delivery: 0n,
        observation: {
          tag: "FailureObservation",
          failure: { stage: "Cancel", cause: { tag: "CancellationRejected" } },
          effect: { tag: "Unknown", reason: "HostFailure" },
        },
      });
      release?.();
    } finally {
      release?.();
      await peer.close();
    }
  }, 15_000);

  it("classifies controlled peer write, header, body, limit, and malformed failures", async () => {
    const requestWritePeer = await startPeer((request) => request.socket.destroy());
    try {
      const requestWrite = commandFor(inputFor(50n, {
        method: "POST",
        target: `${requestWritePeer.url}/write`,
        body: new Uint8Array(2 * 1024 * 1024).fill(1),
      }));
      expect((await nextFailure(new FetchHttpAdapter(), requestWrite.command)).failure.failure)
        .toMatchObject({ stage: "RequestWrite", cause: { tag: "RequestWriteFailed" } });
    } finally {
      await requestWritePeer.close();
    }

    const headerPeer = await startPeer((request) => request.socket.destroy());
    try {
      const headers = commandFor(inputFor(51n, { target: `${headerPeer.url}/headers` }));
      expect((await nextFailure(new FetchHttpAdapter(), headers.command)).failure.failure)
        .toMatchObject({ stage: "ResponseHeaders", cause: { tag: "ResponseHeadersFailed" } });
    } finally {
      await headerPeer.close();
    }

    const bodyPeer = await startPeer((_request, response) => {
      response.writeHead(200, { "content-length": "8" });
      response.flushHeaders();
      response.write("short");
      setImmediate(() => response.socket?.destroy());
    });
    try {
      const body = commandFor(inputFor(52n, { target: `${bodyPeer.url}/body` }));
      expect((await nextFailure(new FetchHttpAdapter(), body.command)).failure.failure)
        .toMatchObject({ stage: "ResponseBody", cause: { tag: "ResponseBodyFailed" } });
    } finally {
      await bodyPeer.close();
    }

    const limitPeer = await startPeer((_request, response) => response.end("oversized"));
    try {
      const limit = commandFor(inputFor(
        53n,
        { target: `${limitPeer.url}/limit` },
        { ...baseConfiguration, responseBodyLimit: 2n },
      ));
      expect((await nextFailure(new FetchHttpAdapter(), limit.command)).failure.failure)
        .toMatchObject({ stage: "ResponseBody", cause: { tag: "ResponseBodyLimitExceeded" } });
    } finally {
      await limitPeer.close();
    }

    const malformedPeer = await startPeer((request) => {
      request.socket.end("HTTP/1.1 invalid-status\r\ncontent-length: 0\r\n\r\n");
    });
    try {
      const malformed = commandFor(inputFor(54n, {
        target: `${malformedPeer.url}/malformed`,
      }));
      expect((await nextFailure(new FetchHttpAdapter(), malformed.command)).failure.failure)
        .toMatchObject({ stage: "ResponseHeaders", cause: { tag: "MalformedResponse" } });
    } finally {
      await malformedPeer.close();
    }
  }, 20_000);

  it("uses the matching cancellation capability without claiming remote effect", async () => {
    const peer = await startPeer(() => {});
    try {
      const capability = { identity: { value: "accepted-cancel" } };
      const candidate = inputFor(
        59n,
        { target: `${peer.url}/accepted-cancel` },
        { ...baseConfiguration, cancellation: capability },
      );
      const prepared = commandFor(candidate);
      const adapter = new FetchHttpAdapter({
        cancellation: {
          capability: () => capability,
          request: () => undefined,
        },
      });
      const started = adapter.start(prepared.command);
      if (started.tag !== "Started") throw new Error("start failed");
      const startedState = observeStart(prepared.state, prepared.prepared, started);
      if (startedState.tag !== "Started") throw new Error("start observation failed");
      const command = cancelCommand(startedState.state, startedState.started);
      if (command.tag !== "CommandReady") throw new Error("cancel command failed");
      const cancelled = adapter.cancel(command.command);
      expect(cancelled).toMatchObject({
        tag: "Delivered",
        delivery: 0n,
        observation: {
          tag: "CancellationObservation",
          attempt: candidate.attempt,
          handle: started.handle,
          effect: { tag: "Unknown", reason: "Cancellation" },
        },
      });
    } finally {
      await peer.close();
    }
  });

  it("derives production timeout classification from Node codes and lifecycle phase", async () => {
    const codeCases = [
      ["UND_ERR_CONNECT_TIMEOUT", "Start"],
      ["UND_ERR_HEADERS_TIMEOUT", "ResponseHeaders"],
      ["UND_ERR_BODY_TIMEOUT", "ResponseBody"],
    ] as const;
    let revision = 60n;
    for (const [code, stage] of codeCases) {
      const command = commandFor(inputFor(revision));
      revision += 1n;
      const adapter = new FetchHttpAdapter({
        fetch: immediateFailureFetch(Object.assign(new Error(code), { code })),
      });
      expect((await nextFailure(adapter, command.command)).failure.failure)
        .toMatchObject({
          stage,
          cause: { tag: "Timeout", stage, cause: "LibraryReported" },
        });
    }

    const fetchCommand = commandFor(inputFor(revision));
    revision += 1n;
    const fetchTimeout = new FetchHttpAdapter({
      fetch: immediateFailureFetch(new DOMException("fetch timed out", "TimeoutError")),
    });
    expect((await nextFailure(fetchTimeout, fetchCommand.command)).failure.failure)
      .toMatchObject({
        stage: "ResponseHeaders",
        cause: {
          tag: "Timeout",
          stage: "ResponseHeaders",
          cause: "HostOperation",
        },
      });

    const bodyCommand = commandFor(inputFor(revision));
    const bodyTimeout = new FetchHttpAdapter({
      fetch: async () => ({
        status: 200,
        headers: { entries: () => [] },
        arrayBuffer: async () => {
          throw new DOMException("body timed out", "TimeoutError");
        },
      }),
    });
    expect((await nextFailure(bodyTimeout, bodyCommand.command)).failure.failure)
      .toMatchObject({
        stage: "ResponseBody",
        cause: {
          tag: "Timeout",
          stage: "ResponseBody",
          cause: "HostOperation",
        },
      });
  });

  it("preserves every test-only timeout stage and cause through the reducer", async () => {
    let revision = 70n;
    const stages: readonly HostStage[] = [
      "Start",
      "RequestWrite",
      "ResponseHeaders",
      "ResponseBody",
      "Cancel",
      "Deadline",
    ];
    const causes: readonly HostTimeoutCause[] = [
      "LibraryReported",
      "SocketReported",
      "PoolAcquisition",
      "HostOperation",
    ];
    for (const stage of stages) {
      for (const cause of causes) {
        const prepared = commandFor(inputFor(revision));
        revision += 1n;
        const adapter = new TimeoutPairTestAdapter(stage, cause);
        const started = adapter.start(prepared.command);
        if (started.tag !== "Started") throw new Error("test timeout adapter did not start");
        const startedState = observeStart(prepared.state, prepared.prepared, started);
        if (startedState.tag !== "Started") throw new Error("timeout start was rejected");
        const delivered = await nextDelivered(adapter, startedOf(prepared.command, started));
        const terminal = observe(startedState.state, delivered);
        expect(terminal).toMatchObject({
          tag: "Terminal",
          settled: {
            terminal: {
              outcome: {
                tag: "Failed",
                failure: {
                  stage,
                  cause: { tag: "Timeout", stage, cause },
                },
              },
            },
          },
        });
      }
    }
  });

  it("records HostClosed first and drops a worker response that arrives after the close", async () => {
    let release: ((response: httpAdapter.FetchResponseLike) => void) | undefined;
    const fetch: FetchLike = async () => new Promise<httpAdapter.FetchResponseLike>((resolve) => {
      release = resolve;
    });
    const prepared = commandFor(inputFor(100n));
    const adapter = new FetchHttpAdapter({ fetch });
    const started = adapter.start(prepared.command);
    if (started.tag !== "Started") throw new Error("start failed");
    await Promise.resolve();
    const startedAttempt = startedOf(prepared.command, started);
    const closed = adapter.close(startedAttempt);
    expect(closed).toMatchObject({
      tag: "Delivered",
      delivery: 0n,
      observation: {
        tag: "FailureObservation",
        failure: { stage: "Cancel", cause: { tag: "HostClosed" } },
        effect: { tag: "Unknown", reason: "HostFailure" },
      },
    });
    release?.(responseLike(200, [1, 2, 3]));
    await new Promise<void>((resolve) => setTimeout(resolve, 20));
    expect(adapter.observe(startedAttempt).tag).toBe("Pending");
  });

  it("returns UnknownExecution from cancel and close for a handle that has no record", () => {
    const prepared = commandFor(inputFor(300n));
    const never = { value: "never-started" };
    const adapter = new FetchHttpAdapter();
    expect(adapter.cancel({
      attempt: prepared.prepared.input.attempt,
      handle: never,
      capability: { identity: { value: "never" } },
    })).toEqual({ tag: "UnknownExecution", handle: never });
    expect(adapter.close({ prepared: prepared.prepared, handle: never }))
      .toEqual({ tag: "UnknownExecution", handle: never });
  });

  it("returns the head observation from close again without queueing a new one", async () => {
    const fetch: FetchLike = async () => new Promise<httpAdapter.FetchResponseLike>(() => {});
    const prepared = commandFor(inputFor(301n));
    const adapter = new FetchHttpAdapter({ fetch });
    const started = adapter.start(prepared.command);
    if (started.tag !== "Started") throw new Error("start failed");
    const startedAttempt = startedOf(prepared.command, started);
    await Promise.resolve();
    expect(adapter.close(startedAttempt)).toMatchObject({ tag: "Delivered", delivery: 0n });
    expect(adapter.close(startedAttempt)).toMatchObject({
      tag: "Pending",
      handle: started.handle,
    });
  });

  it("marks failure observations with the HostFailure reason", async () => {
    const adapter = new FetchHttpAdapter({
      fetch: immediateFailureFetch(Object.assign(new Error("refused"), { code: "ECONNREFUSED" })),
    });
    const { failure } = await nextFailure(adapter, commandFor(inputFor(302n)).command);
    expect(failure.effect).toEqual({ tag: "Unknown", reason: "HostFailure" });
    const startFailed = new FetchHttpAdapter().start(
      commandFor(inputFor(303n, { target: "ftp://127.0.0.1/value" })).command,
    );
    expect(startFailed).toMatchObject({
      tag: "StartFailed",
      effect: { tag: "Unknown", reason: "HostFailure" },
    });
  });

  it("dispatches ordinal one against a real peer after a settled root retry", async () => {
    const peer = await startPeer((request, response) => {
      request.on("data", () => {});
      request.on("end", () => {
        response.writeHead(200);
        response.end(Uint8Array.from([1, 2, 3]));
      });
    });
    try {
      const rootInput = inputFor(200n, { method: "GET", target: `${peer.url}/retry` });
      const rootPrepared = commandFor(rootInput);
      const adapter = new FetchHttpAdapter();
      let issuedCommandCount = 0;
      issuedCommandCount += 1;
      const rootStarted = adapter.start(rootPrepared.command);
      expect(rootStarted.tag).toBe("Started");
      if (rootStarted.tag !== "Started") return;
      const rootStartedState = observeStart(rootPrepared.state, rootPrepared.prepared, rootStarted);
      if (rootStartedState.tag !== "Started") throw new Error("observeStart failed");
      const rootDelivered = await nextDelivered(adapter, startedOf(rootPrepared.command, rootStarted));
      expect(rootDelivered.observation.tag).toBe("ResponseObservation");
      const rootTerminal = observe(rootStartedState.state, rootDelivered);
      if (rootTerminal.tag !== "Terminal") throw new Error("root did not settle");

      const ledgerRecordCount = networkEffect.networkAttempts(rootTerminal.state).length;
      const peerReceivedCount = peer.receivedCount();
      expect(ledgerRecordCount).toBe(1);
      expect(issuedCommandCount).toBe(1);
      expect(peerReceivedCount).toBe(1);

      const authorization: networkEffect.RetryAuthorization = {
        logical: rootInput.attempt.logical,
        from: rootInput.attempt,
        next: { logical: rootInput.attempt.logical, ordinal: 1n },
        protocolEvidence: { value: "retry-auth" },
      };
      const request: networkEffect.RetryRequest = {
        permission: { tag: "RetryAllowed", authorization },
        instruction: rootInput.instruction,
        deadline: rootInput.deadline,
        configuration: rootInput.configuration,
      };
      const retried = retry(rootTerminal.state, request);
      expect(retried.tag).toBe("Prepared");
      if (retried.tag !== "Prepared") return;
      expect(networkEffect.networkAttempts(retried.state).length).toBe(ledgerRecordCount + 1);
      expect(issuedCommandCount).toBe(1);
      expect(peer.receivedCount()).toBe(peerReceivedCount);
      expect(retried.prepared.chain).toEqual({ tag: "RetryOf", authorization });
      expect(networkEffect.networkAttempts(retried.state)[0]?.chain).toEqual({ tag: "Root" });

      const issued = sendCommand(retried.state, retried.prepared);
      expect(issued.tag).toBe("CommandReady");
      if (issued.tag !== "CommandReady") return;
      const retryStarted = adapter.start(issued.command);
      expect(retryStarted.tag).toBe("Started");
      if (retryStarted.tag !== "Started") return;
      issuedCommandCount += 1;
      const retryStartedState = observeStart(issued.state, retried.prepared, retryStarted);
      if (retryStartedState.tag !== "Started") throw new Error("retry observeStart failed");
      const retryDelivered = await nextDelivered(adapter, startedOf(issued.command, retryStarted));
      expect(retryDelivered.observation.tag).toBe("ResponseObservation");
      const retryTerminal = observe(retryStartedState.state, retryDelivered);
      if (retryTerminal.tag !== "Terminal") throw new Error("retry did not settle");

      expect(issuedCommandCount).toBe(2);
      expect(peer.receivedCount()).toBe(peerReceivedCount + 1);
      expect(networkEffect.networkAttempts(retryTerminal.state).length).toBe(ledgerRecordCount + 1);
      expect(networkEffect.networkAttempts(retryTerminal.state)[1]?.chain).toEqual({ tag: "RetryOf", authorization });
      expect(networkEffect.networkAttempts(retryTerminal.state)[1]?.chain).not.toEqual(networkEffect.networkAttempts(retryTerminal.state)[0]?.chain);
      expect(networkEffect.networkAttempts(retryTerminal.state)[0]?.chain).toEqual({ tag: "Root" });

      const reused = retry(retryTerminal.state, request);
      expect(reused.tag).toBe("Rejected");
      if (reused.tag !== "Rejected") return;
      expect(reused.failure).toMatchObject({ tag: "RetryNotPermitted" });
      expect(networkEffect.networkAttempts(reused.state).length).toBe(networkEffect.networkAttempts(retryTerminal.state).length);
      expect(peer.receivedCount()).toBe(peerReceivedCount + 1);
    } finally {
      await peer.close();
    }
  });

});
