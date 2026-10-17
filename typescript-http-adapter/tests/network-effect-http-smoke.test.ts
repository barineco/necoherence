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
      body: instruction.body ?? [],
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
  return { prepared: { input, lineage: { tag: "Root" } } };
}

async function startPeer(
  handler: (request: IncomingMessage, response: ServerResponse) => void,
): Promise<LoopbackPeer> {
  let received = 0;
  let resolveFirstRequest: (() => void) | undefined;
  const firstRequest = new Promise<void>((resolve) => {
    resolveFirstRequest = resolve;
  });
  const server = createServer((request, response) => {
    received += 1;
    resolveFirstRequest?.();
    handler(request, response);
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address() as AddressInfo;
  return {
    url: `http://127.0.0.1:${address.port}`,
    receivedCount: () => received,
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

async function nextDelivered(
  adapter: Pick<FetchHttpAdapter, "observe">,
  handle: { readonly value: string },
): Promise<Delivered> {
  const deadline = performance.now() + 5_000;
  while (performance.now() < deadline) {
    const observation = adapter.observe(handle);
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
  const delivered = await nextDelivered(adapter, started.handle);
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

  public observe(handle: { readonly value: string }): HostObservation {
    const worker = this.#worker;
    if (worker === undefined || worker.handle.value !== handle.value) {
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
        headers: [{ name: "x-input", value: [111, 107] }],
        body: [0, 128, 255],
      });
      const prepared = commandFor(candidate);
      const adapter = new FetchHttpAdapter();
      let issuedCommandCount = 0;
      issuedCommandCount += 1;
      const started = adapter.start(prepared.command);
      expect(started.tag).toBe("Started");
      if (started.tag !== "Started") return;
      expect(peer.receivedCount()).toBe(0);
      expect(adapter.observe(started.handle)).toEqual({
        tag: "Pending",
        attempt: candidate.attempt,
        handle: started.handle,
      });

      const delivered = await nextDelivered(adapter, started.handle);
      expect(delivered.delivery).toBe(0n);
      expect(delivered.observation).toMatchObject({
        tag: "ResponseObservation",
        attempt: candidate.attempt,
        handle: started.handle,
        sourceSequence: { tag: "some", value: 0n },
        response: { status: 201, body: [0, 128, 255] },
        provenance: "LibraryNormalized",
        effect: { tag: "Unknown", reason: "NoResponse" },
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
        .toEqual(Array.from(Buffer.from("first, second", "utf8")));
      expect(delivered.observation.response.headers.find((field) => field.name === "x-utf8")?.value)
        .toEqual([0xc3, 0xa9]);

      const startedState = observeStart(prepared.state, prepared.prepared, started);
      if (startedState.tag !== "Started") throw new Error("observeStart failed");
      const terminal = observe(startedState.state, delivered);
      expect(terminal).toMatchObject({
        tag: "Terminal",
        settled: {
          terminal: {
            outcome: {
              tag: "Response",
              response: { status: 201, body: [0, 128, 255] },
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
          response: { ...delivered.observation.response, body: [255, 0] },
        },
      })).toMatchObject({
        tag: "Rejected",
        failure: { tag: "ConflictingDelivery", delivery: 0n },
      });

      const ledgerRecordCount = prepared.state.attempts.length;
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
        const delivered = await nextDelivered(adapter, started.handle);
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

  it("keeps delayed polls pending and records deadline before late response", async () => {
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
        monotonicClock: { observe: () => ({ clockBasis, value: clockValue }) },
      });
      const started = adapter.start(prepared.command);
      if (started.tag !== "Started") throw new Error("start failed");
      expect(adapter.observe(started.handle).tag).toBe("Pending");
      expect(adapter.observe(started.handle).tag).toBe("Pending");
      clockValue = 5n;
      const deadline = adapter.observe(started.handle);
      expect(deadline).toMatchObject({
        tag: "Delivered",
        delivery: 0n,
        observation: {
          tag: "DeadlineObservation",
          deadline: candidate.deadline,
          observedAt: { clockBasis, value: 5n },
          effect: { tag: "Unknown" },
        },
      });
      await peer.waitForRequest();
      release?.();
      const response = await nextDelivered(adapter, started.handle);
      expect(response).toMatchObject({
        tag: "Delivered",
        delivery: 1n,
        observation: {
          tag: "ResponseObservation",
          sourceSequence: { tag: "some", value: 0n },
        },
      });
      const startedState = observeStart(prepared.state, prepared.prepared, started);
      if (startedState.tag !== "Started" || deadline.tag !== "Delivered") {
        throw new Error("state transition setup failed");
      }
      const terminal = observe(startedState.state, deadline);
      if (terminal.tag !== "Terminal") throw new Error("deadline did not settle");
      expect(observe(terminal.state, response)).toMatchObject({
        tag: "Late",
        late: { delivered: { delivery: 1n } },
      });
    } finally {
      release?.();
      await peer.close();
    }
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
        { target: `${peer.url}/invalid`, body: [1] },
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
      headers: [{ name: "x-invalid", value: [255] }],
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
      const adapter = new FetchHttpAdapter({ cancellation: { request: () => false } });
      const started = adapter.start(prepared.command);
      if (started.tag !== "Started") throw new Error("start failed");
      const startedState = observeStart(prepared.state, prepared.prepared, started);
      if (startedState.tag !== "Started") throw new Error("start observation failed");
      const cancellationCommand = cancelCommand(startedState.state, startedState.started);
      if (cancellationCommand.tag !== "CommandReady") throw new Error("cancel command failed");
      adapter.cancel(cancellationCommand.command);
      expect((await nextDelivered(adapter, started.handle)).observation).toMatchObject({
        tag: "FailureObservation",
        failure: { stage: "Cancel", cause: { tag: "CancellationRejected" } },
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
        body: new Array<number>(2 * 1024 * 1024).fill(1),
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
          request: (command) =>
            command.capability.identity.value === capability.identity.value,
        },
      });
      const started = adapter.start(prepared.command);
      if (started.tag !== "Started") throw new Error("start failed");
      const startedState = observeStart(prepared.state, prepared.prepared, started);
      if (startedState.tag !== "Started") throw new Error("start observation failed");
      const command = cancelCommand(startedState.state, startedState.started);
      if (command.tag !== "CommandReady") throw new Error("cancel command failed");
      adapter.cancel(command.command);
      const cancelled = await nextDelivered(adapter, started.handle);
      expect(cancelled).toMatchObject({
        delivery: 0n,
        observation: {
          tag: "CancellationObservation",
          attempt: candidate.attempt,
          handle: started.handle,
          effect: { tag: "Unknown", reason: "NoResponse" },
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
        const delivered = await nextDelivered(adapter, started.handle);
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

  it("records HostClosed first and a completed worker response as late delivery", async () => {
    let release: ((response: httpAdapter.FetchResponseLike) => void) | undefined;
    const fetch: FetchLike = async () => new Promise<httpAdapter.FetchResponseLike>((resolve) => {
      release = resolve;
    });
    const prepared = commandFor(inputFor(100n));
    const adapter = new FetchHttpAdapter({ fetch });
    const started = adapter.start(prepared.command);
    if (started.tag !== "Started") throw new Error("start failed");
    await Promise.resolve();
    adapter.close(started.handle);
    const closed = await nextDelivered(adapter, started.handle);
    expect(closed).toMatchObject({
      delivery: 0n,
      observation: {
        tag: "FailureObservation",
        failure: { stage: "Cancel", cause: { tag: "HostClosed" } },
      },
    });
    release?.(responseLike(200, [1, 2, 3]));
    const late = await nextDelivered(adapter, started.handle);
    expect(late).toMatchObject({
      delivery: 1n,
      observation: {
        tag: "ResponseObservation",
        response: { body: [1, 2, 3] },
      },
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
      const rootDelivered = await nextDelivered(adapter, rootStarted.handle);
      expect(rootDelivered.observation.tag).toBe("ResponseObservation");
      const rootTerminal = observe(rootStartedState.state, rootDelivered);
      if (rootTerminal.tag !== "Terminal") throw new Error("root did not settle");

      const ledgerRecordCount = rootTerminal.state.attempts.length;
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
      expect(retried.state.attempts.length).toBe(ledgerRecordCount + 1);
      expect(issuedCommandCount).toBe(1);
      expect(peer.receivedCount()).toBe(peerReceivedCount);
      expect(retried.prepared.lineage).toEqual({ tag: "RetryOf", authorization });
      expect(retried.state.attempts[0]?.lineage).toEqual({ tag: "Root" });

      const issued = sendCommand(retried.state, retried.prepared);
      expect(issued.tag).toBe("CommandReady");
      if (issued.tag !== "CommandReady") return;
      const retryStarted = adapter.start(issued.command);
      expect(retryStarted.tag).toBe("Started");
      if (retryStarted.tag !== "Started") return;
      issuedCommandCount += 1;
      const retryStartedState = observeStart(issued.state, retried.prepared, retryStarted);
      if (retryStartedState.tag !== "Started") throw new Error("retry observeStart failed");
      const retryDelivered = await nextDelivered(adapter, retryStarted.handle);
      expect(retryDelivered.observation.tag).toBe("ResponseObservation");
      const retryTerminal = observe(retryStartedState.state, retryDelivered);
      if (retryTerminal.tag !== "Terminal") throw new Error("retry did not settle");

      expect(issuedCommandCount).toBe(2);
      expect(peer.receivedCount()).toBe(peerReceivedCount + 1);
      expect(retryTerminal.state.attempts.length).toBe(ledgerRecordCount + 1);
      expect(retryTerminal.state.attempts[1]?.lineage).toEqual({ tag: "RetryOf", authorization });
      expect(retryTerminal.state.attempts[1]?.lineage).not.toEqual(retryTerminal.state.attempts[0]?.lineage);
      expect(retryTerminal.state.attempts[0]?.lineage).toEqual({ tag: "Root" });

      const reused = retry(retryTerminal.state, request);
      expect(reused.tag).toBe("Rejected");
      if (reused.tag !== "Rejected") return;
      expect(reused.failure).toMatchObject({ tag: "RetryNotPermitted" });
      expect(reused.state.attempts.length).toBe(retryTerminal.state.attempts.length);
      expect(peer.receivedCount()).toBe(peerReceivedCount + 1);
    } finally {
      await peer.close();
    }
  });

});
