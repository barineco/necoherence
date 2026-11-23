// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import {
  type AdapterObservation,
  type CancelCommand,
  type CancellationCapability,
  type EffectStatus,
  type ExecutionHandle,
  type HostFailure,
  type HostObservation,
  type HostRecordDecision,
  type HostStage,
  type MonotonicClockCapability,
  type MonotonicClockObservation,
  type NetworkHostFailure,
  type NetworkState,
  type RawHeaderField,
  type SendCommand,
  type StartObservation,
  type StartedAttempt,
  emptyNetworkState,
  hostSettled,
  prepare,
  releaseHostRecord,
  sourceNone,
  sourceSome,
} from "necoherence/network-effect";
import { semanticExecution } from "necoherence";
import { registerRecords } from "./records.js";

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
export interface MonotonicClockPort {
  capability: () => MonotonicClockCapability;
  observe: () => MonotonicClockObservation | HostFailure;
  until?: (limit: bigint) => number | undefined;
}
export interface CancellationPort {
  capability: () => CancellationCapability;
  request: (handle: ExecutionHandle) => undefined | HostFailure;
}

export interface FetchHttpAdapterOptions {
  readonly fetch?: FetchLike;
  readonly createAbortController?: AbortControllerFactory;
  readonly monotonicClock?: MonotonicClockPort;
  readonly cancellation?: CancellationPort;
}

type Lifecycle = "Running" | "RunningSettled" | "Finished" | "Released";

interface Worker {
  readonly command: SendCommand;
  readonly handle: { readonly value: string };
  readonly controller: AbortControllerLike;
  readonly queue: AdapterObservation[];
  delivery: bigint;
  sourceSequence: bigint;
  closed: boolean;
  interrupted: boolean;
  deadlineQueued: boolean;
  stage: HostStage;
  lifecycle: Lifecycle;
  readonly waiters: (() => void)[];
}

export interface UnknownExecution {
  readonly tag: "UnknownExecution";
  readonly handle: { readonly value: string };
}

export interface DeadlineWaitUnavailable {
  readonly tag: "DeadlineWaitUnavailable";
  readonly handle: { readonly value: string };
}

interface ClassifiedFailure {
  readonly stage: HostStage;
  readonly cause: NetworkHostFailure["cause"];
}

const protocolWitnessMissingEffect: EffectStatus = Object.freeze({
  tag: "Unknown",
  reason: "ProtocolWitnessMissing",
});
const hostFailureEffect: EffectStatus = Object.freeze({
  tag: "Unknown",
  reason: "HostFailure",
});
const cancellationEffect: EffectStatus = Object.freeze({
  tag: "Unknown",
  reason: "Cancellation",
});
const deadlineEffect: EffectStatus = Object.freeze({
  tag: "Unknown",
  reason: "Deadline",
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

function isHostFailure(value: unknown): value is HostFailure {
  return value !== null && typeof value === "object" && typeof (value as { tag?: unknown }).tag === "string";
}

function stageForCause(fallback: HostStage, cause: HostFailure): HostStage {
  return cause.tag === "Timeout" ? cause.stage : fallback;
}

function sameClockCapability(
  left: MonotonicClockCapability,
  right: MonotonicClockCapability,
): boolean {
  return left.identity.value === right.identity.value
    && left.clockBasis.value === right.clockBasis.value;
}

function textBytes(value: string): Uint8Array {
  return new TextEncoder().encode(value);
}

function headersOf(response: FetchResponseLike): readonly RawHeaderField[] {
  const fields: RawHeaderField[] = [];
  for (const [name, value] of response.headers.entries()) {
    fields.push(frozen({ name, value: textBytes(value) }));
  }
  return Object.freeze(fields);
}

function bodyOf(buffer: ArrayBuffer): Uint8Array {
  return new Uint8Array(buffer);
}

function requestHeadersOf(command: SendCommand): readonly (readonly [string, string])[] {
  const decoder = new TextDecoder("utf-8", { fatal: true });
  return Object.freeze(command.prepared.input.instruction.headers.map((header) => {
    const value = decoder.decode(header.value);
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

function classifyFetchFailure(
  error: unknown,
  hasRequestBody: boolean,
  current: HostStage,
): ClassifiedFailure {
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
    stage: current,
    cause: frozen({ tag: "HostRuntimeFailure" }),
  });
}

interface Internals {
  readonly waitObservation: (
    started: StartedAttempt,
  ) => Promise<HostObservation | UnknownExecution | DeadlineWaitUnavailable>;
}

const internals = new WeakMap<object, Internals>();

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
    registerRecords(this, this.#workers);
    internals.set(this, {
      waitObservation: (started) => this.#waitObservation(started),
    });
  }

  public start(command: SendCommand): StartObservation {
    const input = command.prepared.input;
    if (!/^https?:\/\//i.test(input.instruction.target)) {
      return frozen({
        tag: "StartFailed",
        failure: failure(command, "Start", frozen({ tag: "UnsupportedUriScheme" })),
        effect: hostFailureEffect,
      });
    }
    const root = { ...input, attempt: { ...input.attempt, ordinal: 0n } };
    if (prepare(emptyNetworkState(), root).tag !== "Prepared") {
      return frozen({
        tag: "StartFailed",
        failure: failure(command, "Start", frozen({ tag: "InvalidHostConfiguration" })),
        effect: hostFailureEffect,
      });
    }
    if (input.deadline !== null) {
      const clockMatch = this.#clockCapabilitiesMatch(input);
      if (clockMatch === "Failed") {
        return frozen({
          tag: "StartFailed",
          failure: failure(command, "Start", frozen({ tag: "HostRuntimeFailure" })),
          effect: hostFailureEffect,
        });
      }
      if (!clockMatch) {
        return frozen({
          tag: "StartFailed",
          failure: failure(command, "Start", frozen({ tag: "DeadlineControlUnavailable" })),
          effect: hostFailureEffect,
        });
      }
    }
    if (input.configuration.cancellation !== null) {
      const cancellationMatch = this.#cancellationCapabilityMatches(
        input.configuration.cancellation,
      );
      if (cancellationMatch === "Failed") {
        return frozen({
          tag: "StartFailed",
          failure: failure(command, "Start", frozen({ tag: "HostRuntimeFailure" })),
          effect: hostFailureEffect,
        });
      }
      if (!cancellationMatch) {
        return frozen({
          tag: "StartFailed",
          failure: failure(command, "Start", frozen({ tag: "InvalidHostConfiguration" })),
          effect: hostFailureEffect,
        });
      }
    }
    let controller: AbortControllerLike;
    try {
      controller = this.#createAbortController();
    } catch {
      return frozen({
        tag: "StartFailed",
        failure: failure(command, "Start", frozen({ tag: "ExecutionStartFailed" })),
        effect: hostFailureEffect,
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
      interrupted: false,
      deadlineQueued: false,
      stage: "RequestWrite",
      lifecycle: "Running",
      waiters: [],
    };
    this.#workers.set(handle.value, worker);
    queueMicrotask(() => { void this.#run(worker); });
    return frozen({ tag: "Started", attempt: input.attempt, handle });
  }

  #clockCapabilitiesMatch(input: SendCommand["prepared"]["input"]): boolean | "Failed" {
    if (this.#clock === undefined || input.deadline === null) return false;
    try {
      const port = this.#clock.capability();
      return sameClockCapability(port, input.deadline.capability);
    } catch {
      return "Failed";
    }
  }

  #cancellationCapabilityMatches(configured: CancellationCapability): boolean | "Failed" {
    if (this.#cancellation === undefined) return false;
    try {
      return this.#cancellation.capability().identity.value === configured.identity.value;
    } catch {
      return "Failed";
    }
  }

  public observe(started: StartedAttempt): HostObservation | UnknownExecution {
    const worker = this.#workers.get(started.handle.value);
    if (worker === undefined) {
      return frozen({ tag: "UnknownExecution", handle: started.handle });
    }
    this.#queueDeadline(worker);
    return this.#deliver(worker);
  }

  public cancel(command: CancelCommand): HostObservation | UnknownExecution {
    const worker = this.#workers.get(command.handle.value);
    if (worker === undefined) {
      return frozen({ tag: "UnknownExecution", handle: command.handle });
    }
    if (worker.closed) return this.#deliver(worker);
    if (this.#cancellation === undefined) {
      this.#publishFailure(worker, "Cancel", frozen({ tag: "CancellationRejected" }));
      return this.#deliver(worker);
    }
    const cancellationMatch = this.#cancellationCapabilityMatches(command.capability);
    if (cancellationMatch === "Failed") {
      this.#publishFailure(worker, "Cancel", frozen({ tag: "HostRuntimeFailure" }));
      return this.#deliver(worker);
    }
    if (!cancellationMatch) {
      this.#publishFailure(worker, "Cancel", frozen({ tag: "CancellationRejected" }));
      return this.#deliver(worker);
    }
    let requested: undefined | HostFailure;
    try {
      requested = this.#cancellation.request(command.handle);
    } catch {
      this.#publishFailure(worker, "Cancel", frozen({ tag: "HostRuntimeFailure" }));
      return this.#deliver(worker);
    }
    if (requested !== undefined) {
      const cause: HostFailure = isHostFailure(requested)
        ? requested
        : frozen({ tag: "HostRuntimeFailure" });
      this.#publishFailure(worker, stageForCause("Cancel", cause), cause);
      return this.#deliver(worker);
    }
    this.#publish(worker, frozen({
      tag: "CancellationObservation",
      attempt: command.attempt,
      handle: command.handle,
      sourceSequence: sourceNone(),
      effect: cancellationEffect,
    }));
    return this.#deliver(worker);
  }

  public close(started: StartedAttempt): HostObservation | UnknownExecution {
    const worker = this.#workers.get(started.handle.value);
    if (worker === undefined) {
      return frozen({ tag: "UnknownExecution", handle: started.handle });
    }
    if (worker.closed) return this.#deliver(worker);
    worker.closed = true;
    this.#publishFailure(worker, "Cancel", frozen({ tag: "HostClosed" }));
    return this.#deliver(worker);
  }

  public release(
    state: NetworkState,
    started: StartedAttempt,
  ): HostRecordDecision {
    const worker = this.#workers.get(started.handle.value);
    if (worker === undefined) {
      return releaseHostRecord(state, () => false, started.prepared.input.attempt);
    }
    const decision = releaseHostRecord(
      state,
      () => worker.lifecycle === "Running" || worker.lifecycle === "RunningSettled",
      worker.command.prepared.input.attempt,
    );
    if (decision.kind === "dematerialize") {
      worker.lifecycle = "Released";
      this.#detach(worker);
    } else if (
      decision.kind === "retain"
      && hostSettled(state, worker.command.prepared.input.attempt)
    ) {
      if (worker.lifecycle === "Running") {
        worker.lifecycle = "RunningSettled";
      } else if (worker.lifecycle === "Finished") {
        worker.lifecycle = "Released";
        this.#detach(worker);
      }
    }
    return decision;
  }

  #deliver(worker: Worker): HostObservation {
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

  #detach(worker: Worker): void {
    this.#workers.delete(worker.handle.value);
    this.#wake(worker);
  }

  #push(worker: Worker, observation: AdapterObservation): void {
    worker.queue.push(observation);
    this.#wake(worker);
  }

  #publish(worker: Worker, observation: AdapterObservation): void {
    worker.queue.push(observation);
    worker.interrupted = true;
    worker.controller.abort();
    this.#wake(worker);
  }

  #publishFailure(
    worker: Worker,
    stage: NetworkHostFailure["stage"],
    cause: NetworkHostFailure["cause"],
  ): void {
    this.#publish(worker, this.#failureObservation(worker, stage, cause));
  }

  #wake(worker: Worker): void {
    for (const resume of worker.waiters.splice(0)) resume();
  }

  async #waitUntil(worker: Worker, ready: () => boolean): Promise<void> {
    while (!ready()) {
      await new Promise<void>((resolve) => { worker.waiters.push(resolve); });
    }
  }

  async #waitFor(worker: Worker, ready: () => boolean, limitMs: number): Promise<void> {
    if (ready()) return;
    await new Promise<void>((resolve) => {
      const wake = (): void => {
        clearTimeout(timer);
        const index = worker.waiters.indexOf(wake);
        if (index >= 0) worker.waiters.splice(index, 1);
        resolve();
      };
      const timer = setTimeout(wake, limitMs);
      worker.waiters.push(wake);
    });
  }

  #deadlineWait(worker: Worker): number | undefined | "unavailable" {
    const deadline = worker.command.prepared.input.deadline;
    if (deadline === null || worker.deadlineQueued) return undefined;
    let length: number | undefined;
    try {
      length = this.#clock?.until?.(deadline.limit);
    } catch {
      this.#queueClockFailure(worker);
      return undefined;
    }
    if (length === undefined) return "unavailable";
    return Math.max(length, 1);
  }

  async #waitObservation(
    started: StartedAttempt,
  ): Promise<HostObservation | UnknownExecution | DeadlineWaitUnavailable> {
    const handle = started.handle;
    for (;;) {
      const observed = this.observe(started);
      if (observed.tag !== "Pending") return observed;
      const worker = this.#workers.get(handle.value);
      if (worker === undefined) return frozen({ tag: "UnknownExecution", handle });
      const ready = (): boolean => worker.queue.length > 0 || worker.lifecycle === "Released";
      const bound = this.#deadlineWait(worker);
      if (bound === "unavailable") return frozen({ tag: "DeadlineWaitUnavailable", handle });
      if (bound === undefined) await this.#waitUntil(worker, ready);
      else await this.#waitFor(worker, ready, bound);
    }
  }

  #failureObservation(
    worker: Worker,
    stage: NetworkHostFailure["stage"],
    cause: NetworkHostFailure["cause"],
  ): AdapterObservation {
    return frozen({
      tag: "FailureObservation",
      attempt: worker.command.prepared.input.attempt,
      handle: worker.handle,
      sourceSequence: sourceNone(),
      failure: failure(worker.command, stage, cause),
      effect: hostFailureEffect,
    });
  }

  #queueResult(worker: Worker, observation: AdapterObservation): void {
    if (this.#interrupted(worker)) return;
    this.#push(worker, observation);
  }

  #queueFailure(
    worker: Worker,
    stage: NetworkHostFailure["stage"],
    cause: NetworkHostFailure["cause"],
  ): void {
    this.#queueResult(worker, this.#failureObservation(worker, stage, cause));
  }

  #queueDeadline(worker: Worker): void {
    const deadline = worker.command.prepared.input.deadline;
    if (worker.deadlineQueued || deadline === null || this.#clock === undefined) return;
    try {
      const observedAt = this.#clock.observe();
      if (isHostFailure(observedAt)) {
        this.#queueClockFailure(worker, observedAt);
        return;
      }
      if (
        observedAt.clockBasis.value === deadline.clockBasis.value
        && observedAt.value >= deadline.limit
      ) {
        worker.deadlineQueued = true;
        this.#publish(worker, frozen({
          tag: "DeadlineObservation",
          attempt: worker.command.prepared.input.attempt,
          handle: worker.handle,
          sourceSequence: sourceNone(),
          deadline,
          observedAt,
          effect: deadlineEffect,
        }));
      }
    } catch {
      this.#queueClockFailure(worker);
    }
  }

  #queueClockFailure(
    worker: Worker,
    cause: HostFailure = frozen({ tag: "HostRuntimeFailure" }),
  ): void {
    if (worker.deadlineQueued) return;
    worker.deadlineQueued = true;
    this.#publishFailure(worker, stageForCause("Deadline", cause), cause);
  }

  #interrupted(worker: Worker): boolean {
    return worker.interrupted;
  }

  async #run(worker: Worker): Promise<void> {
    try {
      await this.#runRequest(worker);
    } catch {
      if (!this.#interrupted(worker)) {
        this.#queueFailure(worker, worker.stage, frozen({ tag: "HostRuntimeFailure" }));
      }
    } finally {
      if (worker.lifecycle === "RunningSettled") {
        worker.lifecycle = "Released";
        this.#detach(worker);
      } else {
        if (worker.lifecycle === "Running") worker.lifecycle = "Finished";
        this.#wake(worker);
      }
    }
  }

  async #runRequest(worker: Worker): Promise<void> {
    const input = worker.command.prepared.input;
    this.#queueDeadline(worker);
    if (worker.deadlineQueued) return;
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
      const options: FetchRequestOptions = {
        method: input.instruction.method,
        headers,
        body: input.instruction.body,
        signal: worker.controller.signal,
      };
      worker.stage = "ResponseHeaders";
      response = await this.#fetch(input.instruction.target, options);
    } catch (error) {
      if (this.#interrupted(worker)) return;
      const classified = classifyFetchFailure(
        error,
        input.instruction.body.length > 0,
        worker.stage,
      );
      this.#queueFailure(worker, classified.stage, classified.cause);
      return;
    }
    if (this.#interrupted(worker)) return;
    if (!Number.isInteger(response.status) || response.status < 100 || response.status > 999) {
      this.#queueFailure(
        worker,
        "ResponseHeaders",
        frozen({ tag: "MalformedResponse" }),
      );
      return;
    }
    worker.stage = "ResponseBody";
    let body: Uint8Array;
    try {
      body = bodyOf(await response.arrayBuffer());
    } catch (error) {
      if (this.#interrupted(worker)) return;
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
    if (this.#interrupted(worker)) return;
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
    this.#queueResult(worker, frozen({
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
      effect: protocolWitnessMissingEffect,
    }));
    worker.sourceSequence += 1n;
  }
}

export interface Driven {
  readonly result: semanticExecution.ExecutionResult;
  readonly retained: readonly StartedAttempt[];
}

export interface DriveFailure {
  readonly cause: semanticExecution.RunFailure | UnknownExecution | DeadlineWaitUnavailable;
  readonly retained: readonly StartedAttempt[];
}

export type DriveResult =
  | { readonly tag: "Ok"; readonly value: Driven }
  | { readonly tag: "Failed"; readonly failure: DriveFailure };

function released(decision: HostRecordDecision): boolean {
  return decision.kind === "dematerialize";
}

function sweep(
  adapter: FetchHttpAdapter,
  state: NetworkState,
  candidates: readonly StartedAttempt[],
): StartedAttempt[] {
  return candidates.filter((started) => !released(adapter.release(state, started)));
}

async function finish(
  adapter: FetchHttpAdapter,
  state: NetworkState,
  candidates: readonly StartedAttempt[],
): Promise<readonly StartedAttempt[]> {
  const remaining: StartedAttempt[] = [];
  for (const started of candidates) {
    const decision = adapter.release(state, started);
    if (released(decision)) continue;
    if (
      decision.kind === "retain"
      && hostSettled(state, started.prepared.input.attempt)
    ) {
      continue;
    }
    remaining.push(started);
  }
  return remaining;
}

export async function drive(
  adapter: FetchHttpAdapter,
  first: semanticExecution.Progress,
): Promise<DriveResult> {
  const waiting = internals.get(adapter);
  if (waiting === undefined) throw new TypeError("drive requires a FetchHttpAdapter");
  let candidates: StartedAttempt[] = [];
  let progress = first;
  for (;;) {
    if (progress.tag === "Completed") {
      const retained = await finish(adapter, progress.network, candidates);
      return frozen({ tag: "Ok", value: frozen({ result: progress.result, retained }) });
    }
    const instruction = progress.instruction;
    let observation: semanticExecution.ExecutionObservation;
    let handled: StartedAttempt | null = null;
    if (instruction.tag === "Send") {
      const start = adapter.start(instruction.command);
      if (start.tag === "Started") {
        handled = { prepared: instruction.command.prepared, handle: start.handle };
      }
      observation = { tag: "Start", observation: start };
    } else {
      handled = instruction.started;
      const host = await waiting.waitObservation(instruction.started);
      if ("tag" in host && host.tag === "UnknownExecution") {
        const retained = await finish(adapter, progress.execution.network, candidates);
        return frozen({ tag: "Failed", failure: frozen({ cause: host, retained }) });
      }
      if ("tag" in host && host.tag === "DeadlineWaitUnavailable") {
        const retained = await finish(adapter, progress.execution.network, candidates);
        return frozen({ tag: "Failed", failure: frozen({ cause: host, retained }) });
      }
      observation = { tag: "Host", observation: host as HostObservation };
    }
    const resumed = semanticExecution.resume(progress.execution, observation);
    if (handled !== null && !candidates.some((known) => known.handle.value === handled?.handle.value)) {
      candidates.push(handled);
    }
    if (resumed.tag === "Failed") {
      const retained = await finish(adapter, resumed.failure.network, candidates);
      return frozen({ tag: "Failed", failure: frozen({ cause: resumed.failure, retained }) });
    }
    progress = resumed.value;
    candidates = sweep(
      adapter,
      progress.tag === "Completed" ? progress.network : progress.execution.network,
      candidates,
    );
  }
}
