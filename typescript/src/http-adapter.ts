// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import {
  type AdapterObservation,
  type CancelCommand,
  type EffectStatus,
  type HostObservation,
  type HostStage,
  type MonotonicClockObservation,
  type NetworkHostFailure,
  type RawHeaderField,
  type SendCommand,
  type StartObservation,
  sourceNone,
  sourceSome,
} from "./network-effect.js";

export interface FetchResponseLike {
  readonly status: number;
  readonly headers: { readonly entries: () => Iterable<readonly [string, string]> };
  readonly arrayBuffer: () => Promise<ArrayBuffer>;
}

export interface FetchRequestOptions {
  readonly method: string;
  readonly headers: readonly (readonly [string, string])[];
  readonly body: Uint8Array;
  readonly signal: unknown;
}

export type FetchLike = (
  target: string,
  options: FetchRequestOptions,
) => Promise<FetchResponseLike>;

export interface AbortControllerLike {
  readonly signal: unknown;
  abort: () => void;
}

export type AbortControllerFactory = () => AbortControllerLike;
export interface MonotonicClockPort { observe: () => MonotonicClockObservation; }
export interface CancellationPort { request: (command: CancelCommand) => void | boolean; }

export interface FetchHttpAdapterOptions {
  readonly fetch?: FetchLike;
  readonly createAbortController?: AbortControllerFactory;
  readonly monotonicClock?: MonotonicClockPort;
  readonly cancellation?: CancellationPort;
}

interface Worker {
  readonly command: SendCommand;
  readonly handle: { readonly value: string };
  readonly controller: AbortControllerLike;
  readonly queue: AdapterObservation[];
  delivery: bigint;
  sourceSequence: bigint;
  closed: boolean;
  cancelled: boolean;
  deadlineQueued: boolean;
}

interface ClassifiedFailure {
  readonly stage: HostStage;
  readonly cause: NetworkHostFailure["cause"];
}

const unknownEffect: EffectStatus = Object.freeze({
  tag: "Unknown",
  reason: "NoResponse",
});
const frozen = <T>(value: T): T => Object.freeze(value);

const defaultFetch: FetchLike = async (target, options) => {
  const headers = new Headers();
  for (const [name, value] of options.headers) headers.append(name, value);
  const init: RequestInit = {
    method: options.method,
    headers,
    signal: options.signal as AbortSignal,
  };
  if (options.body.length > 0) {
    init.body = options.body;
  }
  const response = await globalThis.fetch(target, init);
  return {
    status: response.status,
    headers: response.headers,
    arrayBuffer: () => response.arrayBuffer(),
  };
};

function failure(
  command: SendCommand,
  stage: NetworkHostFailure["stage"],
  cause: NetworkHostFailure["cause"],
): NetworkHostFailure {
  return frozen({
    attempt: command.prepared.input.attempt,
    stage,
    configuration: command.prepared.input.configuration,
    cause,
  });
}

function textBytes(value: string): readonly number[] {
  return Object.freeze(Array.from(new TextEncoder().encode(value)));
}

function headersOf(response: FetchResponseLike): readonly RawHeaderField[] {
  const fields: RawHeaderField[] = [];
  for (const [name, value] of response.headers.entries()) {
    fields.push(frozen({ name, value: textBytes(value) }));
  }
  return Object.freeze(fields);
}

function bodyOf(buffer: ArrayBuffer): readonly number[] {
  return Object.freeze(Array.from(new Uint8Array(buffer)));
}

function requestHeadersOf(command: SendCommand): readonly (readonly [string, string])[] {
  const decoder = new TextDecoder("utf-8", { fatal: true });
  return Object.freeze(command.prepared.input.instruction.headers.map((header) => {
    const value = decoder.decode(Uint8Array.from(header.value));
    if (/[\u0000\r\n]/.test(value)) throw new TypeError("request header value is unavailable");
    return Object.freeze([header.name, value] as const);
  }));
}

function property(value: unknown, name: string): unknown {
  return value !== null && typeof value === "object" && name in value
    ? (value as Record<string, unknown>)[name]
    : undefined;
}

function errorDetail(error: unknown, name: string): unknown {
  return property(error, name) ?? property(property(error, "cause"), name);
}

function errorCode(error: unknown): string | undefined {
  const code = errorDetail(error, "code");
  return typeof code === "string" ? code : undefined;
}

function classifyTimeout(
  error: unknown,
  phase: "Fetch" | "ResponseBody",
): ClassifiedFailure | undefined {
  const code = errorCode(error);
  let stage: HostStage;
  let cause: Extract<
    NetworkHostFailure["cause"],
    { readonly tag: "Timeout" }
  >["cause"];
  switch (code) {
    case "UND_ERR_CONNECT_TIMEOUT":
      stage = "Start";
      cause = "LibraryReported";
      break;
    case "UND_ERR_HEADERS_TIMEOUT":
      stage = "ResponseHeaders";
      cause = "LibraryReported";
      break;
    case "UND_ERR_BODY_TIMEOUT":
      stage = "ResponseBody";
      cause = "LibraryReported";
      break;
    case "ETIMEDOUT":
      stage = phase === "ResponseBody" ? "ResponseBody" : "Start";
      cause = "SocketReported";
      break;
    default:
      if (!(error instanceof DOMException) || error.name !== "TimeoutError") {
        return undefined;
      }
      stage = phase === "ResponseBody" ? "ResponseBody" : "ResponseHeaders";
      cause = "HostOperation";
  }
  return frozen({
    stage,
    cause: frozen({ tag: "Timeout", stage, cause }),
  });
}

function classifyFetchFailure(error: unknown, hasRequestBody: boolean): ClassifiedFailure {
  const timeout = classifyTimeout(error, "Fetch");
  if (timeout !== undefined) return timeout;
  const code = errorCode(error);
  if (code === "ENOTFOUND" || code === "EAI_AGAIN") {
    return frozen({ stage: "Start", cause: frozen({ tag: "NameResolutionFailed" }) });
  }
  if (code === "ECONNREFUSED") {
    return frozen({ stage: "Start", cause: frozen({ tag: "ConnectionFailed" }) });
  }
  const errorName = errorDetail(error, "name");
  const errorMessage = errorDetail(error, "message");
  const cause = property(error, "cause");
  const causeName = property(cause, "name");
  const causeMessage = property(cause, "message");
  if (
    code?.startsWith("HPE_") === true
    || errorName === "HTTPParserError"
    || causeName === "HTTPParserError"
    || (typeof errorMessage === "string"
      && errorMessage.includes("HTTP/1.1 protocol"))
    || (typeof causeMessage === "string"
      && (causeMessage.includes("HTTP/1.1 protocol")
        || causeMessage.includes("Invalid status")))
  ) {
    return frozen({
      stage: "ResponseHeaders",
      cause: frozen({ tag: "MalformedResponse" }),
    });
  }
  if (code === "UND_ERR_SOCKET" || code === "ECONNRESET" || code === "EPIPE") {
    return hasRequestBody
      ? frozen({
        stage: "RequestWrite",
        cause: frozen({ tag: "RequestWriteFailed" }),
      })
      : frozen({
        stage: "ResponseHeaders",
        cause: frozen({ tag: "ResponseHeadersFailed" }),
      });
  }
  const message = property(error, "message");
  if (
    typeof message === "string"
    && (message.includes("header") || message.includes("GET/HEAD method cannot have body"))
  ) {
    return frozen({
      stage: "RequestWrite",
      cause: frozen({ tag: "RequestHeaderEncodingUnavailable" }),
    });
  }
  return frozen({
    stage: "ResponseHeaders",
    cause: frozen({ tag: "HostRuntimeFailure" }),
  });
}

export class FetchHttpAdapter {
  readonly #fetch: FetchLike;
  readonly #createAbortController: AbortControllerFactory;
  readonly #clock: MonotonicClockPort | undefined;
  readonly #cancellation: CancellationPort | undefined;
  readonly #workers = new Map<string, Worker>();
  #nextHandle = 0n;

  public constructor(options: FetchHttpAdapterOptions = {}) {
    this.#fetch = options.fetch ?? defaultFetch;
    this.#createAbortController = options.createAbortController
      ?? (() => new AbortController());
    this.#clock = options.monotonicClock;
    this.#cancellation = options.cancellation;
  }

  public start(command: SendCommand): StartObservation {
    const input = command.prepared.input;
    if (
      input.configuration.requestBodyLimit < 0n
      || input.configuration.responseBodyLimit < 0n
      || BigInt(input.instruction.body.length) > input.configuration.requestBodyLimit
      || (input.deadline !== null
        && (input.configuration.monotonicClock === null
          || input.deadline.capability.clockBasis.value !== input.deadline.clockBasis.value
          || input.configuration.monotonicClock.identity.value
            !== input.deadline.capability.identity.value
          || input.configuration.monotonicClock.clockBasis.value
            !== input.deadline.capability.clockBasis.value))
    ) {
      return frozen({
        tag: "StartFailed",
        failure: failure(command, "Start", frozen({ tag: "InvalidHostConfiguration" })),
        effect: unknownEffect,
      });
    }
    if (!/^https?:\/\//i.test(input.instruction.target)) {
      return frozen({
        tag: "StartFailed",
        failure: failure(command, "Start", frozen({ tag: "UnsupportedUriScheme" })),
        effect: unknownEffect,
      });
    }
    if (input.deadline !== null && this.#clock === undefined) {
      return frozen({
        tag: "StartFailed",
        failure: failure(command, "Start", frozen({ tag: "DeadlineControlUnavailable" })),
        effect: unknownEffect,
      });
    }
    let controller: AbortControllerLike;
    try {
      controller = this.#createAbortController();
    } catch {
      return frozen({
        tag: "StartFailed",
        failure: failure(command, "Start", frozen({ tag: "ExecutionStartFailed" })),
        effect: unknownEffect,
      });
    }
    const handle = frozen({
      value: `typescript.worker.${this.#nextHandle.toString()}`,
    });
    this.#nextHandle += 1n;
    const worker: Worker = {
      command,
      handle,
      controller,
      queue: [],
      delivery: 0n,
      closed: false,
      sourceSequence: 0n,
      cancelled: false,
      deadlineQueued: false,
    };
    this.#workers.set(handle.value, worker);
    queueMicrotask(() => { void this.#run(worker); });
    return frozen({ tag: "Started", attempt: input.attempt, handle });
  }

  public observe(handle: { readonly value: string }): HostObservation {
    const worker = this.#workers.get(handle.value);
    if (worker === undefined) {
      return frozen({
        tag: "Pending",
        attempt: {
          logical: { kind: "", provenance: "", revision: 0n },
          ordinal: 0n,
        },
        handle,
      });
    }
    this.#queueDeadline(worker);
    const observation = worker.queue.shift();
    if (observation === undefined) {
      return frozen({
        tag: "Pending",
        attempt: worker.command.prepared.input.attempt,
        handle: worker.handle,
      });
    }
    const delivery = worker.delivery;
    worker.delivery += 1n;
    return frozen({ tag: "Delivered", delivery, observation });
  }

  public cancel(command: CancelCommand): void {
    const worker = this.#workers.get(command.handle.value);
    if (worker === undefined || worker.closed) return;
    if (this.#cancellation === undefined) {
      this.#queueFailure(worker, "Cancel", frozen({ tag: "CancellationRejected" }));
      return;
    }
    try {
      const accepted = this.#cancellation.request(command);
      if (accepted === false) {
        this.#queueFailure(worker, "Cancel", frozen({ tag: "CancellationRejected" }));
        return;
      }
      worker.cancelled = true;
      worker.controller.abort();
      worker.queue.push(frozen({
        tag: "CancellationObservation",
        attempt: command.attempt,
        handle: command.handle,
        sourceSequence: sourceNone(),
        effect: unknownEffect,
      }));
    } catch {
      this.#queueFailure(worker, "Cancel", frozen({ tag: "CancellationRejected" }));
    }
  }

  public close(handle: { readonly value: string }): void {
    const worker = this.#workers.get(handle.value);
    if (worker === undefined || worker.closed) return;
    worker.closed = true;
    this.#queueFailure(worker, "Cancel", frozen({ tag: "HostClosed" }));
    worker.controller.abort();
  }

  #queueFailure(
    worker: Worker,
    stage: NetworkHostFailure["stage"],
    cause: NetworkHostFailure["cause"],
  ): void {
    worker.queue.push(frozen({
      tag: "FailureObservation",
      attempt: worker.command.prepared.input.attempt,
      handle: worker.handle,
      sourceSequence: sourceNone(),
      failure: failure(worker.command, stage, cause),
      effect: unknownEffect,
    }));
  }

  #queueDeadline(worker: Worker): void {
    const deadline = worker.command.prepared.input.deadline;
    if (worker.deadlineQueued || deadline === null || this.#clock === undefined) return;
    try {
      const observedAt = this.#clock.observe();
      if (
        observedAt.clockBasis.value === deadline.clockBasis.value
        && observedAt.value >= deadline.limit
      ) {
        worker.deadlineQueued = true;
        worker.queue.push(frozen({
          tag: "DeadlineObservation",
          attempt: worker.command.prepared.input.attempt,
          handle: worker.handle,
          sourceSequence: sourceNone(),
          deadline,
          observedAt,
          effect: unknownEffect,
        }));
      }
    } catch {
      worker.deadlineQueued = true;
      this.#queueFailure(
        worker,
        "Deadline",
        frozen({ tag: "DeadlineControlUnavailable" }),
      );
    }
  }

  async #run(worker: Worker): Promise<void> {
    const input = worker.command.prepared.input;
    let headers: readonly (readonly [string, string])[];
    try {
      headers = requestHeadersOf(worker.command);
    } catch {
      this.#queueFailure(
        worker,
        "RequestWrite",
        frozen({ tag: "RequestHeaderEncodingUnavailable" }),
      );
      return;
    }
    let response: FetchResponseLike;
    try {
      response = await this.#fetch(input.instruction.target, {
        method: input.instruction.method,
        headers,
        body: Uint8Array.from(input.instruction.body),
        signal: worker.controller.signal,
      });
    } catch (error) {
      if (worker.closed || worker.cancelled) return;
      const classified = classifyFetchFailure(error, input.instruction.body.length > 0);
      this.#queueFailure(worker, classified.stage, classified.cause);
      return;
    }
    if (!Number.isInteger(response.status) || response.status < 100 || response.status > 999) {
      this.#queueFailure(
        worker,
        "ResponseHeaders",
        frozen({ tag: "MalformedResponse" }),
      );
      return;
    }
    let body: readonly number[];
    try {
      body = bodyOf(await response.arrayBuffer());
    } catch (error) {
      const timeout = classifyTimeout(error, "ResponseBody");
      if (timeout !== undefined) {
        this.#queueFailure(worker, timeout.stage, timeout.cause);
      } else {
        this.#queueFailure(
          worker,
          "ResponseBody",
          frozen({ tag: "ResponseBodyFailed" }),
        );
      }
      return;
    }
    if (BigInt(body.length) > input.configuration.responseBodyLimit) {
      this.#queueFailure(
        worker,
        "ResponseBody",
        frozen({ tag: "ResponseBodyLimitExceeded" }),
      );
      return;
    }
    let responseHeaders: readonly RawHeaderField[];
    try {
      responseHeaders = headersOf(response);
    } catch {
      this.#queueFailure(
        worker,
        "ResponseHeaders",
        frozen({ tag: "HeaderRepresentationUnavailable" }),
      );
      return;
    }
    worker.queue.push(frozen({
      tag: "ResponseObservation",
      attempt: input.attempt,
      handle: worker.handle,
      sourceSequence: sourceSome(worker.sourceSequence),
      response: frozen({
        status: response.status,
        headers: responseHeaders,
        body,
      }),
      provenance: "LibraryNormalized",
      effect: unknownEffect,
    }));
    worker.sourceSequence += 1n;
  }
}
