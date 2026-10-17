// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import * as readline from "node:readline";
import {
  AttemptInput,
  CancelCommand,
  HostFailure,
  HostObservation,
  HostStage,
  HostTimeoutCause,
  NetworkState,
  NetworkStep,
  NetworkTerminal,
  PreparedAttempt,
  SendCommand,
  StartObservation,
  observe,
  observeStart,
  prepare,
  sendCommand,
} from "../../typescript/src/network-effect.js";
import {
  CancellationPort,
  FetchHttpAdapter,
  MonotonicClockPort,
} from "../../typescript-http-adapter/src/index.js";

interface Row {
  readonly constructor: string;
  readonly testOnly: boolean;
  readonly peerHost: string;
  readonly peerPort: number;
  readonly timeoutStage: string | null;
  readonly timeoutCause: string | null;
}

function identity(kind: string) {
  return { kind, provenance: "host-failure-matrix", revision: 0n };
}

function baseInput(row: Row, target: string): AttemptInput {
  return {
    attempt: { logical: identity(row.constructor), ordinal: 0n },
    instruction: { method: "GET", target, headers: [], body: [] },
    deadline: null,
    configuration: {
      requestBodyLimit: 256n,
      responseBodyLimit: row.constructor === "ResponseBodyLimitExceeded" ? 4n : 16n,
      cancellation: null,
      monotonicClock: null,
    },
  };
}

interface BuiltInput {
  readonly input: AttemptInput;
  readonly rejectCancellation: boolean;
  readonly throwingClock: boolean;
}

function buildInput(row: Row): BuiltInput {
  const scheme = row.constructor === "UnsupportedUriScheme" ? "ftp" : "http";
  const target = `${scheme}://${row.peerHost}:${row.peerPort}/host-failure-matrix`;
  let input = baseInput(row, target);
  let rejectCancellation = false;
  let throwingClock = false;
  switch (row.constructor) {
    case "RequestHeaderEncodingUnavailable":
      input = { ...input, instruction: { ...input.instruction, headers: [{ name: "x-forged", value: [0] }] } };
      break;
    case "DeadlineControlUnavailable": {
      const capability = { identity: { value: "matrix-clock" }, clockBasis: { value: "matrix" } };
      throwingClock = true;
      input = {
        ...input,
        deadline: { clockBasis: { value: "matrix" }, limit: 5n, capability },
        configuration: { ...input.configuration, monotonicClock: capability },
      };
      break;
    }
    case "CancellationRejected": {
      const capability = { identity: { value: "matrix-cancel" } };
      rejectCancellation = true;
      input = { ...input, configuration: { ...input.configuration, cancellation: capability } };
      break;
    }
    default:
      break;
  }
  return { input, rejectCancellation, throwingClock };
}

function directFailure(constructor: string, timeoutStage: string | null, timeoutCause: string | null): { stage: HostStage; cause: HostFailure } {
  switch (constructor) {
    case "ExecutionStartFailed":
      return { stage: "Start", cause: { tag: "ExecutionStartFailed" } };
    case "NameResolutionFailed":
      return { stage: "Start", cause: { tag: "NameResolutionFailed" } };
    case "RequestWriteFailed":
      return { stage: "RequestWrite", cause: { tag: "RequestWriteFailed" } };
    case "HeaderRepresentationUnavailable":
      return { stage: "ResponseHeaders", cause: { tag: "HeaderRepresentationUnavailable" } };
    case "InvalidHostConfiguration":
      return { stage: "Start", cause: { tag: "InvalidHostConfiguration" } };
    case "HostRuntimeFailure":
      return { stage: "ResponseBody", cause: { tag: "HostRuntimeFailure" } };
    case "Timeout": {
      const stage = (timeoutStage ?? "Start") as HostStage;
      const cause = (timeoutCause ?? "LibraryReported") as HostTimeoutCause;
      return { stage, cause: { tag: "Timeout", stage, cause } };
    }
    default:
      return { stage: "Start", cause: { tag: "HostRuntimeFailure" } };
  }
}

function reportTerminal(handle: string, ledgerRecordCount: number, terminal: NetworkTerminal): string {
  const effectTag = terminal.effect.tag;
  const outcome = terminal.outcome;
  const base = { ledgerRecordCount, issuedCommandCount: 1, effect: effectTag, handle };
  if (outcome.tag === "Failed") {
    const failure = outcome.failure;
    const inner = failure.cause.tag === "Timeout" ? failure.cause : null;
    return JSON.stringify({
      ...base,
      outcomeTag: "Failed",
      stage: failure.stage,
      cause: failure.cause.tag,
      innerStage: inner?.stage ?? null,
      innerCause: inner?.cause ?? null,
    });
  }
  if (outcome.tag === "Cancelled") {
    return JSON.stringify({ ...base, outcomeTag: "Cancelled", stage: "Cancel", cause: "Cancelled" });
  }
  return JSON.stringify({ ...base, outcomeTag: outcome.tag });
}

function reportStep(handle: string, ledgerRecordCount: number, step: NetworkStep): string {
  if (step.tag === "Terminal") {
    return reportTerminal(handle, ledgerRecordCount, step.settled.terminal);
  }
  if (step.tag === "Started" || step.tag === "Pending") {
    return JSON.stringify({ ledgerRecordCount, issuedCommandCount: 1, outcomeTag: "Pending", effect: "Unknown", handle });
  }
  if (step.tag === "Rejected") {
    return JSON.stringify({ ledgerRecordCount, issuedCommandCount: 1, outcomeTag: "LedgerRejected", cause: JSON.stringify(step.failure), handle });
  }
  return JSON.stringify({ error: `unexpected NetworkStep: ${JSON.stringify(step)}` });
}

function handleOf(observation: HostObservation): { value: string } {
  if (observation.tag === "Pending") return observation.handle;
  const inner = observation.observation;
  return inner.handle;
}

function finishFromHostObservation(state: NetworkState, prepared: PreparedAttempt, input: AttemptInput, ledgerRecordCount: number, observation: HostObservation): string {
  const handle = handleOf(observation);
  const startedStep = observeStart(state, prepared, { tag: "Started", attempt: input.attempt, handle });
  if (startedStep.tag !== "Started") {
    return JSON.stringify({ error: `unexpected observeStart result: ${JSON.stringify(startedStep)}` });
  }
  const step = observe(startedStep.state, observation);
  return reportStep(handle.value, ledgerRecordCount, step);
}

function finishFromStartObservation(state: NetworkState, prepared: PreparedAttempt, observation: StartObservation, ledgerRecordCount: number): string {
  const step = observeStart(state, prepared, observation);
  if (step.tag === "Terminal") return reportTerminal("start-failed", ledgerRecordCount, step.settled.terminal);
  if (step.tag === "Rejected") {
    return JSON.stringify({ ledgerRecordCount, issuedCommandCount: 1, outcomeTag: "LedgerRejected", cause: JSON.stringify(step.failure), handle: "start-failed" });
  }
  return JSON.stringify({ error: `unexpected observeStart result: ${JSON.stringify(step)}` });
}

async function runTestOnly(row: Row, input: AttemptInput, state: NetworkState, prepared: PreparedAttempt, ledgerRecordCount: number): Promise<string> {
  const { stage, cause } = directFailure(row.constructor, row.timeoutStage, row.timeoutCause);
  const unknown = { tag: "Unknown" as const, reason: "HostFailure" as const };
  if (row.constructor === "ExecutionStartFailed") {
    const observation: StartObservation = {
      tag: "StartFailed",
      failure: { attempt: input.attempt, stage, configuration: input.configuration, cause },
      effect: unknown,
    };
    return finishFromStartObservation(state, prepared, observation, ledgerRecordCount);
  }
  const handle = { value: "ts-test-only-handle" };
  const startedStep = observeStart(state, prepared, { tag: "Started", attempt: input.attempt, handle });
  if (startedStep.tag !== "Started") {
    return JSON.stringify({ error: `unexpected observeStart result: ${JSON.stringify(startedStep)}` });
  }
  const observation: HostObservation = {
    tag: "Delivered",
    delivery: 0n,
    observation: {
      tag: "FailureObservation",
      attempt: input.attempt,
      handle,
      sourceSequence: { tag: "none" },
      failure: { attempt: input.attempt, stage, configuration: input.configuration, cause },
      effect: unknown,
    },
  };
  const step = observe(startedStep.state, observation);
  return reportStep(handle.value, ledgerRecordCount, step);
}

function sleep(ms: number): Promise<void> {
  const { promise, resolve } = Promise.withResolvers<void>();
  setTimeout(resolve, ms);
  return promise;
}

async function runReal(row: Row, built: BuiltInput, state: NetworkState, prepared: PreparedAttempt, command: SendCommand, ledgerRecordCount: number): Promise<string> {
  const { input, rejectCancellation, throwingClock } = built;
  const cancellation: CancellationPort | undefined = rejectCancellation ? { request: () => false } : undefined;
  const monotonicClock: MonotonicClockPort | undefined = throwingClock
    ? {
        observe: () => {
          throw new Error("matrix clock unavailable");
        },
      }
    : undefined;
  const adapter = new FetchHttpAdapter({ cancellation, monotonicClock });
  const startObservation = adapter.start(command);
  if (startObservation.tag === "StartFailed") {
    return finishFromStartObservation(state, prepared, startObservation, ledgerRecordCount);
  }
  const handle = startObservation.handle;
  if (rejectCancellation) {
    await sleep(50);
    const cancelCommand: CancelCommand = { attempt: input.attempt, handle, capability: input.configuration.cancellation! };
    adapter.cancel(cancelCommand);
    const observation = adapter.observe(handle);
    return finishFromHostObservation(state, prepared, input, ledgerRecordCount, observation);
  }
  if (row.constructor === "HostClosed") {
    await sleep(50);
    adapter.close(handle);
    const observation = adapter.observe(handle);
    return finishFromHostObservation(state, prepared, input, ledgerRecordCount, observation);
  }
  const deadline = Date.now() + 3000;
  while (true) {
    const observation = adapter.observe(handle);
    if (observation.tag === "Delivered") {
      return finishFromHostObservation(state, prepared, input, ledgerRecordCount, observation);
    }
    if (Date.now() >= deadline) {
      return JSON.stringify({ error: "polling timed out" });
    }
    await sleep(10);
  }
}

async function runRow(row: Row): Promise<string> {
  const built = buildInput(row);
  const prepareStep = prepare({ attempts: [] }, built.input);
  if (prepareStep.tag !== "Prepared") {
    return JSON.stringify({ error: `prepare rejected: ${JSON.stringify(prepareStep)}` });
  }
  const ledgerRecordCount = prepareStep.state.attempts.length;
  const sendStep = sendCommand(prepareStep.state, prepareStep.prepared);
  if (sendStep.tag !== "CommandReady") {
    return JSON.stringify({ error: `sendCommand rejected: ${JSON.stringify(sendStep)}` });
  }
  if (row.testOnly) {
    return runTestOnly(row, built.input, sendStep.state, prepareStep.prepared, ledgerRecordCount);
  }
  return runReal(row, built, sendStep.state, prepareStep.prepared, sendStep.command, ledgerRecordCount);
}

async function main(): Promise<void> {
  const rl = readline.createInterface({ input: process.stdin, terminal: false });
  for await (const line of rl) {
    const trimmed = line.trim();
    if (trimmed.length === 0) continue;
    let report: string;
    try {
      const row = JSON.parse(trimmed) as Row;
      report = await runRow(row);
    } catch (error) {
      report = JSON.stringify({ error: `row error: ${String(error)}` });
    }
    process.stdout.write(report + "\n");
  }
}

void main();
