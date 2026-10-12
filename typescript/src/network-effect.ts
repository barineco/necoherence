// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import type { ExecutionHandle, RequestIdentity } from "./request-progression.js";
export type { ExecutionHandle, RequestIdentity } from "./request-progression.js";

export type ByteString = readonly number[];
export interface RawHeaderField { readonly name: string; readonly value: ByteString; }
export interface HttpWireInstruction { readonly method: string; readonly target: string; readonly headers: readonly RawHeaderField[]; readonly body: ByteString; }
export interface RawHttpResponse { readonly status: number; readonly headers: readonly RawHeaderField[]; readonly body: ByteString; }
export type HeaderProvenance = "WireObserved" | "LibraryObserved" | "LibraryNormalized";
export interface AttemptIdentity { readonly logical: RequestIdentity; readonly ordinal: bigint; }
export interface OpaqueEvidence { readonly value: string; }
export interface ClockBasis { readonly value: string; }
export interface MonotonicClockObservation { readonly clockBasis: ClockBasis; readonly value: bigint; }
export interface MonotonicClockCapability { readonly identity: OpaqueEvidence; readonly clockBasis: ClockBasis; }
export interface CancellationCapability { readonly identity: OpaqueEvidence; }
export interface Deadline { readonly clockBasis: ClockBasis; readonly limit: bigint; readonly capability: MonotonicClockCapability; }
export interface HostConfiguration { readonly requestBodyLimit: bigint; readonly responseBodyLimit: bigint; readonly cancellation: CancellationCapability | null; readonly monotonicClock: MonotonicClockCapability | null; }
export interface AttemptInput { readonly attempt: AttemptIdentity; readonly instruction: HttpWireInstruction; readonly deadline: Deadline | null; readonly configuration: HostConfiguration; }
export interface RetryAuthorization { readonly logical: RequestIdentity; readonly from: AttemptIdentity; readonly next: AttemptIdentity; readonly protocolEvidence: OpaqueEvidence; }
export type AttemptLineage = { readonly tag: "Root" } | { readonly tag: "RetryOf"; readonly authorization: RetryAuthorization };
export interface PreparedAttempt { readonly input: AttemptInput; readonly lineage: AttemptLineage; }
export interface StartedAttempt { readonly prepared: PreparedAttempt; readonly handle: ExecutionHandle; }
export interface SendCommand { readonly prepared: PreparedAttempt; }
export interface CancelCommand { readonly attempt: AttemptIdentity; readonly handle: ExecutionHandle; readonly capability: CancellationCapability; }
export type EffectWitnessSource = "Adapter" | "Protocol";
export interface EffectWitness { readonly attempt: AttemptIdentity; readonly source: EffectWitnessSource; readonly evidence: OpaqueEvidence; }
export type UnknownEffectReason = "NoResponse" | "Cancellation" | "Deadline" | "HostFailure" | "ProtocolWitnessMissing" | "LateSignal";
export type EffectStatus = { readonly tag: "NoEffect"; readonly witness: EffectWitness } | { readonly tag: "EffectOccurred"; readonly witness: EffectWitness } | { readonly tag: "Unknown"; readonly reason: UnknownEffectReason };
export interface EffectObservation { readonly attempt: AttemptIdentity; readonly status: EffectStatus; }
export type HostStage = "Start" | "RequestWrite" | "ResponseHeaders" | "ResponseBody" | "Cancel" | "Deadline";
export type HostTimeoutCause = "LibraryReported" | "SocketReported" | "PoolAcquisition" | "HostOperation";
export type HostFailure =
  | { readonly tag: "UnsupportedUriScheme" }
  | { readonly tag: "InvalidHostConfiguration" }
  | { readonly tag: "ExecutionStartFailed" }
  | { readonly tag: "NameResolutionFailed" }
  | { readonly tag: "ConnectionFailed" }
  | { readonly tag: "RequestWriteFailed" }
  | { readonly tag: "ResponseHeadersFailed" }
  | { readonly tag: "ResponseBodyFailed" }
  | { readonly tag: "ResponseBodyLimitExceeded" }
  | { readonly tag: "MalformedResponse" }
  | { readonly tag: "HeaderRepresentationUnavailable" }
  | { readonly tag: "RequestHeaderEncodingUnavailable" }
  | { readonly tag: "CancellationRejected" }
  | { readonly tag: "DeadlineControlUnavailable" }
  | { readonly tag: "Timeout"; readonly stage: HostStage; readonly cause: HostTimeoutCause }
  | { readonly tag: "HostRuntimeFailure" }
  | { readonly tag: "HostClosed" };
export interface NetworkHostFailure { readonly attempt: AttemptIdentity; readonly stage: HostStage; readonly configuration: HostConfiguration; readonly cause: HostFailure; }
export type NetworkOutcome = { readonly tag: "Response"; readonly response: RawHttpResponse; readonly provenance: HeaderProvenance } | { readonly tag: "Failed"; readonly failure: NetworkHostFailure } | { readonly tag: "Cancelled" } | { readonly tag: "DeadlineExceeded"; readonly deadline: Deadline; readonly observedAt: MonotonicClockObservation };
export interface NetworkTerminal { readonly outcome: NetworkOutcome; readonly effect: EffectStatus; }
export type AttemptDisposition = { readonly tag: "Prepared" } | { readonly tag: "CommandIssued" } | { readonly tag: "Started"; readonly handle: ExecutionHandle } | { readonly tag: "Settled"; readonly handle: ExecutionHandle | null; readonly terminal: NetworkTerminal };
export type SourceSequence = { readonly tag: "none" } | { readonly tag: "some"; readonly value: bigint };
export type AdapterObservation =
  | { readonly tag: "ResponseObservation"; readonly attempt: AttemptIdentity; readonly handle: ExecutionHandle; readonly sourceSequence: SourceSequence; readonly response: RawHttpResponse; readonly provenance: HeaderProvenance; readonly effect: EffectStatus }
  | { readonly tag: "FailureObservation"; readonly attempt: AttemptIdentity; readonly handle: ExecutionHandle; readonly sourceSequence: SourceSequence; readonly failure: NetworkHostFailure; readonly effect: EffectStatus }
  | { readonly tag: "CancellationObservation"; readonly attempt: AttemptIdentity; readonly handle: ExecutionHandle; readonly sourceSequence: SourceSequence; readonly effect: EffectStatus }
  | { readonly tag: "DeadlineObservation"; readonly attempt: AttemptIdentity; readonly handle: ExecutionHandle; readonly sourceSequence: SourceSequence; readonly deadline: Deadline; readonly observedAt: MonotonicClockObservation; readonly effect: EffectStatus };
export interface DeliveredObservation { readonly delivery: bigint; readonly observation: AdapterObservation; }
export interface LateObservation { readonly delivered: DeliveredObservation; }
export interface AttemptRecord { readonly input: AttemptInput; readonly lineage: AttemptLineage; readonly disposition: AttemptDisposition; readonly firstDelivery: DeliveredObservation | null; readonly late: readonly LateObservation[]; }
export interface NetworkState { readonly attempts: readonly AttemptRecord[]; }
export type RetryPermission = { readonly tag: "RetryAllowed"; readonly authorization: RetryAuthorization } | { readonly tag: "RetryDenied"; readonly logical: RequestIdentity; readonly parent: AttemptIdentity; readonly evidence: OpaqueEvidence };
export interface RetryRequest { readonly permission: RetryPermission; readonly instruction: HttpWireInstruction; readonly deadline: Deadline | null; readonly configuration: HostConfiguration; }
export type StartObservation = { readonly tag: "Started"; readonly attempt: AttemptIdentity; readonly handle: ExecutionHandle } | { readonly tag: "StartFailed"; readonly failure: NetworkHostFailure; readonly effect: EffectStatus };
export type HostObservation = { readonly tag: "Pending"; readonly attempt: AttemptIdentity; readonly handle: ExecutionHandle } | { readonly tag: "Delivered"; readonly delivery: bigint; readonly observation: AdapterObservation };
export type NetworkStateViolation =
  | { readonly tag: "DuplicateAttemptKey"; readonly attempt: AttemptIdentity }
  | { readonly tag: "NonRootFirstAttempt"; readonly attempt: AttemptIdentity }
  | { readonly tag: "OrdinalGap"; readonly attempt: AttemptIdentity }
  | { readonly tag: "LineageMismatch"; readonly attempt: AttemptIdentity }
  | { readonly tag: "RetryAuthorizationReuse"; readonly authorization: RetryAuthorization }
  | { readonly tag: "DispositionEvidenceMismatch"; readonly attempt: AttemptIdentity }
  | { readonly tag: "DeliveryLogMismatch"; readonly attempt: AttemptIdentity };
export type AttemptCondition = "IsPrepared" | "IsCommandIssued" | "IsStarted" | "IsSettled";
export type AttemptTokenField = "Instruction" | "Deadline" | "Configuration" | "Lineage" | "Handle";
export type ObservationField = "FailureConfiguration" | "FailureStage" | "DeadlineValue" | "ClockBasisValue" | "ClockObservationValue" | "EffectWitnessValue";
export type CapabilityKind = "Cancellation" | "MonotonicClock";
export type NetworkFailure =
  | { readonly tag: "InvalidWireInstruction"; readonly method: string }
  | { readonly tag: "InvalidDeadline" }
  | { readonly tag: "InvalidNetworkState"; readonly violation: NetworkStateViolation }
  | { readonly tag: "RootAttemptRequired"; readonly attempt: AttemptIdentity }
  | { readonly tag: "DuplicateAttempt"; readonly attempt: AttemptIdentity }
  | { readonly tag: "UnknownAttempt"; readonly attempt: AttemptIdentity }
  | { readonly tag: "AttemptConditionMismatch"; readonly attempt: AttemptIdentity; readonly expected: AttemptCondition; readonly actual: AttemptCondition }
  | { readonly tag: "AttemptTokenMismatch"; readonly attempt: AttemptIdentity; readonly field: AttemptTokenField }
  | { readonly tag: "ObservationRelationMismatch"; readonly attempt: AttemptIdentity; readonly field: ObservationField }
  | { readonly tag: "RequiredCapabilityUnavailable"; readonly attempt: AttemptIdentity; readonly capability: CapabilityKind }
  | { readonly tag: "CommandAlreadyIssued"; readonly attempt: AttemptIdentity }
  | { readonly tag: "IdentityMismatch"; readonly expected: AttemptIdentity; readonly actual: AttemptIdentity }
  | { readonly tag: "HandleMismatch"; readonly expected: ExecutionHandle; readonly actual: ExecutionHandle }
  | { readonly tag: "ClockBasisMismatch"; readonly expected: ClockBasis; readonly actual: ClockBasis }
  | { readonly tag: "DeadlineNotReached"; readonly deadline: Deadline; readonly observedAt: MonotonicClockObservation }
  | { readonly tag: "DeliveryOrderViolation"; readonly attempt: AttemptIdentity; readonly expected: bigint; readonly actual: bigint }
  | { readonly tag: "ConflictingDelivery"; readonly attempt: AttemptIdentity; readonly delivery: bigint; readonly old: AdapterObservation; readonly fresh: AdapterObservation }
  | { readonly tag: "MalformedAdapterObservation" }
  | { readonly tag: "Host"; readonly failure: NetworkHostFailure }
  | { readonly tag: "RetryNotPermitted"; readonly attempt: AttemptIdentity }
  | { readonly tag: "RetryIdentityMismatch"; readonly expected: RequestIdentity; readonly actual: RequestIdentity }
  | { readonly tag: "RetryParentMismatch"; readonly expected: AttemptIdentity; readonly actual: AttemptIdentity }
  | { readonly tag: "RetryParentNotSettled"; readonly attempt: AttemptIdentity }
  | { readonly tag: "RetryOrderViolation"; readonly expected: AttemptIdentity; readonly actual: AttemptIdentity }
  | { readonly tag: "RetryAuthorizationAlreadyUsed"; readonly authorization: RetryAuthorization }
  | { readonly tag: "EffectWitnessMissing"; readonly attempt: AttemptIdentity }
  | { readonly tag: "EffectKnowledgeConflict"; readonly attempt: AttemptIdentity };
export type ReadStateStep = { readonly tag: "Read"; readonly state: NetworkState } | { readonly tag: "Rejected"; readonly state: NetworkState; readonly failure: NetworkFailure };
export type PrepareStep = { readonly tag: "Prepared"; readonly state: NetworkState; readonly prepared: PreparedAttempt } | { readonly tag: "Rejected"; readonly state: NetworkState; readonly failure: NetworkFailure };
export type CommandStep<A> = { readonly tag: "CommandReady"; readonly state: NetworkState; readonly command: A } | { readonly tag: "Rejected"; readonly state: NetworkState; readonly failure: NetworkFailure };
export type StateStep = { readonly tag: "Applied"; readonly state: NetworkState } | { readonly tag: "Rejected"; readonly state: NetworkState; readonly failure: NetworkFailure };
export interface SettledAttempt { readonly prepared: PreparedAttempt; readonly handle: ExecutionHandle | null; readonly terminal: NetworkTerminal; }
export type NetworkStep =
  | { readonly tag: "Started"; readonly state: NetworkState; readonly started: StartedAttempt }
  | { readonly tag: "Pending"; readonly state: NetworkState; readonly started: StartedAttempt }
  | { readonly tag: "Terminal"; readonly state: NetworkState; readonly settled: SettledAttempt }
  | { readonly tag: "Late"; readonly state: NetworkState; readonly settled: SettledAttempt; readonly late: LateObservation }
  | { readonly tag: "Duplicate"; readonly state: NetworkState; readonly attempt: AttemptIdentity; readonly delivery: bigint }
  | { readonly tag: "Rejected"; readonly state: NetworkState; readonly failure: NetworkFailure };

const frozen = <T>(value: T): T => Object.freeze(value);
const arr = <T>(value: readonly T[]): readonly T[] => Object.freeze([...value]);

export function emptyNetworkState(): NetworkState {
  return frozen({ attempts: arr([]) });
}

export const emptyState = emptyNetworkState;

function same(left: unknown, right: unknown): boolean {
  if (Object.is(left, right)) return true;
  if (
    typeof left !== typeof right
    || left === null
    || right === null
    || typeof left !== "object"
    || typeof right !== "object"
  ) return false;
  if (Array.isArray(left) || Array.isArray(right)) {
    return Array.isArray(left)
      && Array.isArray(right)
      && left.length === right.length
      && left.every((value, index) => same(value, right[index]));
  }
  const leftKeys = Object.keys(left);
  const rightKeys = Object.keys(right);
  return leftKeys.length === rightKeys.length
    && leftKeys.every((key) =>
      Object.prototype.hasOwnProperty.call(right, key)
      && same(
        (left as Record<string, unknown>)[key],
        (right as Record<string, unknown>)[key],
      ));
}

function sameAttempt(left: AttemptIdentity, right: AttemptIdentity): boolean {
  return same(left, right);
}

function sameLogical(left: RequestIdentity, right: RequestIdentity): boolean {
  return same(left, right);
}

function sameHandle(left: ExecutionHandle, right: ExecutionHandle): boolean {
  return left.value === right.value;
}

function findRecord(state: NetworkState, attempt: AttemptIdentity): AttemptRecord | undefined {
  return state.attempts.find((record) => sameAttempt(record.input.attempt, attempt));
}

function replaceRecord(
  state: NetworkState,
  attempt: AttemptIdentity,
  replacement: AttemptRecord,
): NetworkState {
  return frozen({
    attempts: arr(state.attempts.map((record) =>
      sameAttempt(record.input.attempt, attempt) ? replacement : record)),
  });
}

function appendRecord(state: NetworkState, record: AttemptRecord): NetworkState {
  return frozen({ attempts: arr([...state.attempts, record]) });
}

function attemptOf(observation: AdapterObservation): AttemptIdentity {
  return observation.attempt;
}

function handleOf(observation: AdapterObservation): ExecutionHandle {
  return observation.handle;
}

function effectOf(observation: AdapterObservation): EffectStatus {
  return observation.effect;
}

function dispositionCondition(disposition: AttemptDisposition): AttemptCondition {
  switch (disposition.tag) {
    case "Prepared": return "IsPrepared";
    case "CommandIssued": return "IsCommandIssued";
    case "Started": return "IsStarted";
    case "Settled": return "IsSettled";
  }
}

function validBytes(value: ByteString): boolean {
  return value.every((byte) => Number.isInteger(byte) && byte >= 0 && byte <= 255);
}

function tokenCharacterValid(value: string): boolean {
  return /^[A-Za-z0-9!#$%&'*+\-.^_`|~]$/.test(value);
}

function validToken(value: string): boolean {
  return value.length > 0 && Array.from(value).every(tokenCharacterValid);
}

function alphaCharacterValid(value: string): boolean {
  return /^[A-Za-z]$/.test(value);
}

function digitCharacterValid(value: string): boolean {
  return /^[0-9]$/.test(value);
}

function hexadecimalCharacterValid(value: string): boolean {
  return /^[0-9A-Fa-f]$/.test(value);
}

function uriUnreservedValid(value: string): boolean {
  return alphaCharacterValid(value)
    || digitCharacterValid(value)
    || value === "-"
    || value === "."
    || value === "_"
    || value === "~";
}

function uriSubDelimiterValid(value: string): boolean {
  return value === "!"
    || value === "$"
    || value === "&"
    || value === "'"
    || value === "("
    || value === ")"
    || value === "*"
    || value === "+"
    || value === ","
    || value === ";"
    || value === "=";
}

function uriPathCharacterValid(value: string): boolean {
  return uriUnreservedValid(value)
    || uriSubDelimiterValid(value)
    || value === ":"
    || value === "@";
}

function uriComponentValid(allowQuestion: boolean, value: readonly string[]): boolean {
  let index = 0;
  while (index < value.length) {
    const character = value[index];
    if (character === "%") {
      if (
        index + 2 >= value.length
        || !hexadecimalCharacterValid(value[index + 1] ?? "")
        || !hexadecimalCharacterValid(value[index + 2] ?? "")
      ) return false;
      index += 3;
      continue;
    }
    if (
      character === undefined
      || !(uriPathCharacterValid(character)
        || character === "/"
        || (allowQuestion && character === "?"))
    ) return false;
    index += 1;
  }
  return true;
}

function splitAtCharacter(
  value: readonly string[],
  delimiter: string,
): readonly [readonly string[], readonly string[] | null] {
  const index = value.indexOf(delimiter);
  return index < 0
    ? [value, null]
    : [value.slice(0, index), value.slice(index + 1)];
}

function uriRegisteredNameValid(value: readonly string[]): boolean {
  let index = 0;
  while (index < value.length) {
    const character = value[index];
    if (character === "%") {
      if (
        index + 2 >= value.length
        || !hexadecimalCharacterValid(value[index + 1] ?? "")
        || !hexadecimalCharacterValid(value[index + 2] ?? "")
      ) return false;
      index += 3;
    } else if (
      character !== undefined
      && (uriUnreservedValid(character) || uriSubDelimiterValid(character))
    ) {
      index += 1;
    } else {
      return false;
    }
  }
  return true;
}

function uriUserInfoValid(value: readonly string[]): boolean {
  let index = 0;
  while (index < value.length) {
    const character = value[index];
    if (character === "%") {
      if (
        index + 2 >= value.length
        || !hexadecimalCharacterValid(value[index + 1] ?? "")
        || !hexadecimalCharacterValid(value[index + 2] ?? "")
      ) return false;
      index += 3;
    } else if (
      character !== undefined
      && (uriUnreservedValid(character) || uriSubDelimiterValid(character) || character === ":")
    ) {
      index += 1;
    } else {
      return false;
    }
  }
  return true;
}

function uriPortValid(value: readonly string[]): boolean {
  return value.every(digitCharacterValid);
}

function uriIpLiteralValid(value: readonly string[]): boolean {
  return value.length > 0
    && value.some((character) => character === ":" || character === ".")
    && value.every((character) =>
      hexadecimalCharacterValid(character)
      || character === ":"
      || character === "."
      || character === "v"
      || character === "V"
      || uriUnreservedValid(character)
      || uriSubDelimiterValid(character));
}

function uriPortSuffixValid(value: readonly string[]): boolean {
  return value.length === 0 || (value[0] === ":" && uriPortValid(value.slice(1)));
}

function uriHostPortValid(value: readonly string[]): boolean {
  if (value[0] === "[") {
    const end = value.slice(1).indexOf("]");
    return end >= 0
      && uriIpLiteralValid(value.slice(1, end + 1))
      && uriPortSuffixValid(value.slice(end + 2));
  }
  const [host, port] = splitAtCharacter(value, ":");
  return uriRegisteredNameValid(host) && (port === null || uriPortValid(port));
}

function authorityValid(value: readonly string[]): boolean {
  const [userInfo, hostPort] = splitAtCharacter(value, "@");
  return hostPort === null
    ? uriHostPortValid(userInfo)
    : !hostPort.includes("@") && uriUserInfoValid(userInfo) && uriHostPortValid(hostPort);
}

function uriHierarchyValid(value: readonly string[]): boolean {
  if (value[0] === "/" && value[1] === "/") {
    const rest = value.slice(2);
    const slash = rest.indexOf("/");
    const authorityLength = slash < 0 ? rest.length : slash;
    return authorityValid(rest.slice(0, authorityLength))
      && uriComponentValid(false, rest.slice(authorityLength));
  }
  return uriComponentValid(false, value);
}

function uriTailValid(value: readonly string[]): boolean {
  const [beforeFragment, fragment] = splitAtCharacter(value, "#");
  const [path, query] = splitAtCharacter(beforeFragment, "?");
  return uriHierarchyValid(path)
    && (query === null || uriComponentValid(true, query))
    && (fragment === null || uriComponentValid(true, fragment));
}

function validTarget(target: string): boolean {
  const characters = Array.from(target);
  const first = characters[0];
  if (first === undefined) return false;
  const rest = characters.slice(1);
  const schemeLength = rest.indexOf(":");
  return schemeLength >= 0
    && alphaCharacterValid(first)
    && rest.slice(0, schemeLength).every((character) =>
      alphaCharacterValid(character)
      || digitCharacterValid(character)
      || character === "+"
      || character === "-"
      || character === ".")
    && uriTailValid(rest.slice(schemeLength + 1));
}

function validHeaders(headers: readonly RawHeaderField[]): boolean {
  return headers.every((header) => validToken(header.name) && validBytes(header.value));
}

function validInstruction(instruction: HttpWireInstruction): boolean {
  return validToken(instruction.method)
    && validTarget(instruction.target)
    && validHeaders(instruction.headers)
    && validBytes(instruction.body);
}

function validResponse(response: RawHttpResponse): boolean {
  return Number.isInteger(response.status)
    && response.status >= 100
    && response.status <= 999
    && validHeaders(response.headers)
    && validBytes(response.body);
}

function validInput(input: AttemptInput): boolean {
  return input.configuration.requestBodyLimit >= 0n
    && input.configuration.responseBodyLimit >= 0n
    && validInstruction(input.instruction)
    && BigInt(input.instruction.body.length) <= input.configuration.requestBodyLimit
    && (input.deadline === null
      || (same(input.deadline.capability.clockBasis, input.deadline.clockBasis)
        && input.configuration.monotonicClock !== null
        && same(input.configuration.monotonicClock, input.deadline.capability)));
}

function clockReaches(
  deadline: Deadline,
  observation: MonotonicClockObservation,
): boolean {
  return same(deadline.capability.clockBasis, deadline.clockBasis)
    && same(observation.clockBasis, deadline.clockBasis)
    && deadline.limit <= observation.value;
}

function effectMatches(attempt: AttemptIdentity, status: EffectStatus): boolean {
  return status.tag === "Unknown" || sameAttempt(status.witness.attempt, attempt);
}

function terminalEvidenceValid(attempt: AttemptIdentity, terminal: NetworkTerminal): boolean {
  return effectMatches(attempt, terminal.effect)
    && (terminal.outcome.tag !== "Failed"
      || sameAttempt(terminal.outcome.failure.attempt, attempt));
}

function dispositionHandle(disposition: AttemptDisposition): ExecutionHandle | undefined {
  if (disposition.tag === "Started") return disposition.handle;
  if (disposition.tag === "Settled" && disposition.handle !== null) return disposition.handle;
  return undefined;
}

function lateEvidenceValid(
  lateObservations: readonly LateObservation[],
  attempt: AttemptIdentity,
  handle: ExecutionHandle,
  firstDelivery: bigint,
): boolean {
  let previous = firstDelivery;
  for (const late of lateObservations) {
    if (
      previous >= late.delivered.delivery
      || !sameAttempt(attemptOf(late.delivered.observation), attempt)
      || !sameHandle(handleOf(late.delivered.observation), handle)
    ) return false;
    previous = late.delivered.delivery;
  }
  return true;
}

function recordEvidenceValid(record: AttemptRecord): boolean {
  if (record.disposition.tag !== "Settled") {
    return record.firstDelivery === null && record.late.length === 0;
  }
  if (!terminalEvidenceValid(record.input.attempt, record.disposition.terminal)) return false;
  const handle = record.disposition.handle;
  if (handle === null) return record.firstDelivery === null && record.late.length === 0;
  const first = record.firstDelivery;
  return first !== null
    && first.delivery === 0n
    && sameAttempt(attemptOf(first.observation), record.input.attempt)
    && sameHandle(handleOf(first.observation), handle)
    && lateEvidenceValid(record.late, record.input.attempt, handle, first.delivery);
}

function rootForLogical(
  records: readonly AttemptRecord[],
  logical: RequestIdentity,
): boolean {
  return records.some((record) =>
    sameLogical(record.input.attempt.logical, logical)
    && record.input.attempt.ordinal === 0n
    && record.lineage.tag === "Root");
}

function settledAttemptExists(
  records: readonly AttemptRecord[],
  attempt: AttemptIdentity,
): boolean {
  return records.some((record) =>
    sameAttempt(record.input.attempt, attempt)
    && record.disposition.tag === "Settled");
}

function lineageValid(
  records: readonly AttemptRecord[],
  record: AttemptRecord,
): boolean {
  if (!rootForLogical(records, record.input.attempt.logical)) return false;
  if (record.lineage.tag === "Root") return record.input.attempt.ordinal === 0n;
  const authorization = record.lineage.authorization;
  return sameLogical(authorization.logical, record.input.attempt.logical)
    && sameLogical(authorization.from.logical, record.input.attempt.logical)
    && sameAttempt(authorization.next, record.input.attempt)
    && authorization.from.ordinal + 1n === authorization.next.ordinal
    && settledAttemptExists(records, authorization.from);
}

function validState(state: NetworkState): boolean {
  for (let index = 0; index < state.attempts.length; index += 1) {
    const record = state.attempts[index];
    if (record === undefined) return false;
    if (
      state.attempts.slice(index + 1).some((candidate) =>
        sameAttempt(candidate.input.attempt, record.input.attempt))
      || !recordEvidenceValid(record)
      || !lineageValid(state.attempts, record)
    ) return false;
  }
  for (let index = 0; index < state.attempts.length; index += 1) {
    const record = state.attempts[index];
    if (record?.lineage.tag !== "RetryOf") continue;
    const authorization = record.lineage.authorization;
    if (
      state.attempts.slice(index + 1).some((candidate) =>
        candidate.lineage.tag === "RetryOf"
        && same(candidate.lineage.authorization, authorization))
    ) return false;
  }
  return true;
}

function emptyAttemptIdentity(): AttemptIdentity {
  return frozen({
    logical: frozen({ kind: "", provenance: "", revision: 0n }),
    ordinal: 0n,
  });
}

function firstDuplicateViolation(
  records: readonly AttemptRecord[],
): NetworkStateViolation | undefined {
  for (let index = 0; index < records.length; index += 1) {
    const record = records[index];
    if (
      record !== undefined
      && records.slice(index + 1).some((candidate) =>
        sameAttempt(candidate.input.attempt, record.input.attempt))
    ) {
      return frozen({ tag: "DuplicateAttemptKey", attempt: record.input.attempt });
    }
  }
  return undefined;
}

function recordEvidenceViolation(
  record: AttemptRecord,
): NetworkStateViolation | undefined {
  if (recordEvidenceValid(record)) return undefined;
  if (record.disposition.tag !== "Settled") {
    return frozen({ tag: "DeliveryLogMismatch", attempt: record.input.attempt });
  }
  if (record.disposition.handle === null) {
    return record.firstDelivery === null && record.late.length === 0
      ? frozen({ tag: "DispositionEvidenceMismatch", attempt: record.input.attempt })
      : frozen({ tag: "DeliveryLogMismatch", attempt: record.input.attempt });
  }
  return terminalEvidenceValid(record.input.attempt, record.disposition.terminal)
    ? frozen({ tag: "DeliveryLogMismatch", attempt: record.input.attempt })
    : frozen({ tag: "DispositionEvidenceMismatch", attempt: record.input.attempt });
}

function firstRecordViolation(
  records: readonly AttemptRecord[],
): NetworkStateViolation | undefined {
  for (const record of records) {
    const violation = recordEvidenceViolation(record);
    if (violation !== undefined) return violation;
  }
  return undefined;
}

function lineageViolation(
  records: readonly AttemptRecord[],
  record: AttemptRecord,
): NetworkStateViolation | undefined {
  if (lineageValid(records, record)) return undefined;
  if (!rootForLogical(records, record.input.attempt.logical)) {
    return frozen({ tag: "NonRootFirstAttempt", attempt: record.input.attempt });
  }
  if (record.lineage.tag === "Root") {
    return frozen({ tag: "NonRootFirstAttempt", attempt: record.input.attempt });
  }
  return record.lineage.authorization.next.ordinal
      !== record.lineage.authorization.from.ordinal + 1n
    ? frozen({ tag: "OrdinalGap", attempt: record.input.attempt })
    : frozen({ tag: "LineageMismatch", attempt: record.input.attempt });
}

function firstLineageViolation(
  records: readonly AttemptRecord[],
): NetworkStateViolation | undefined {
  for (const record of records) {
    const violation = lineageViolation(records, record);
    if (violation !== undefined) return violation;
  }
  return undefined;
}

function firstRootViolation(
  records: readonly AttemptRecord[],
): NetworkStateViolation | undefined {
  for (const record of records) {
    if (!rootForLogical(records, record.input.attempt.logical)) {
      return frozen({ tag: "NonRootFirstAttempt", attempt: record.input.attempt });
    }
  }
  return undefined;
}

function firstAuthorizationViolation(
  records: readonly AttemptRecord[],
): NetworkStateViolation | undefined {
  for (let index = 0; index < records.length; index += 1) {
    const record = records[index];
    if (record?.lineage.tag !== "RetryOf") continue;
    const authorization = record.lineage.authorization;
    if (
      records.slice(index + 1).some((candidate) =>
        candidate.lineage.tag === "RetryOf"
        && same(candidate.lineage.authorization, authorization))
    ) {
      return frozen({ tag: "RetryAuthorizationReuse", authorization });
    }
  }
  return undefined;
}

function stateViolation(state: NetworkState): NetworkStateViolation {
  return firstDuplicateViolation(state.attempts)
    ?? firstRecordViolation(state.attempts)
    ?? firstLineageViolation(state.attempts)
    ?? firstRootViolation(state.attempts)
    ?? firstAuthorizationViolation(state.attempts)
    ?? frozen({ tag: "DuplicateAttemptKey", attempt: emptyAttemptIdentity() });
}

function preparedRelation(state: NetworkState, prepared: PreparedAttempt): boolean {
  if (!validState(state)) return false;
  const record = findRecord(state, prepared.input.attempt);
  return record !== undefined
    && same(record.input, prepared.input)
    && same(record.lineage, prepared.lineage);
}

function preparedReady(state: NetworkState, prepared: PreparedAttempt): boolean {
  const record = findRecord(state, prepared.input.attempt);
  return preparedRelation(state, prepared)
    && record !== undefined
    && record.disposition.tag === "Prepared";
}

function commandIssuedMatches(state: NetworkState, prepared: PreparedAttempt): boolean {
  return state.attempts.some((record) =>
    same(record.input, prepared.input)
    && same(record.lineage, prepared.lineage)
    && record.disposition.tag === "CommandIssued");
}

function commandIssuedRelation(state: NetworkState, prepared: PreparedAttempt): boolean {
  const record = findRecord(state, prepared.input.attempt);
  return preparedRelation(state, prepared)
    && record !== undefined
    && record.disposition.tag === "CommandIssued";
}

function startedRelation(state: NetworkState, started: StartedAttempt): boolean {
  if (!validState(state)) return false;
  const record = findRecord(state, started.prepared.input.attempt);
  return record !== undefined
    && same(record.input, started.prepared.input)
    && same(record.lineage, started.prepared.lineage)
    && record.disposition.tag === "Started"
    && sameHandle(record.disposition.handle, started.handle)
    && record.firstDelivery === null
    && record.late.length === 0;
}

function preparedTokenFailure(
  state: NetworkState,
  prepared: PreparedAttempt,
): NetworkFailure | undefined {
  const record = findRecord(state, prepared.input.attempt);
  if (record === undefined) {
    return frozen({ tag: "UnknownAttempt", attempt: prepared.input.attempt });
  }
  if (!same(record.input.instruction, prepared.input.instruction)) {
    return frozen({
      tag: "AttemptTokenMismatch",
      attempt: prepared.input.attempt,
      field: "Instruction",
    });
  }
  if (!same(record.input.deadline, prepared.input.deadline)) {
    return frozen({
      tag: "AttemptTokenMismatch",
      attempt: prepared.input.attempt,
      field: "Deadline",
    });
  }
  if (!same(record.input.configuration, prepared.input.configuration)) {
    return frozen({
      tag: "AttemptTokenMismatch",
      attempt: prepared.input.attempt,
      field: "Configuration",
    });
  }
  if (!same(record.lineage, prepared.lineage)) {
    return frozen({
      tag: "AttemptTokenMismatch",
      attempt: prepared.input.attempt,
      field: "Lineage",
    });
  }
  return undefined;
}

function preparedConditionFailure(
  state: NetworkState,
  prepared: PreparedAttempt,
  expected: AttemptCondition,
): NetworkFailure | undefined {
  const tokenFailure = preparedTokenFailure(state, prepared);
  if (tokenFailure !== undefined) return tokenFailure;
  const record = findRecord(state, prepared.input.attempt);
  if (record === undefined) {
    return frozen({ tag: "UnknownAttempt", attempt: prepared.input.attempt });
  }
  const actual = dispositionCondition(record.disposition);
  return actual === expected
    ? undefined
    : frozen({
      tag: "AttemptConditionMismatch",
      attempt: prepared.input.attempt,
      expected,
      actual,
    });
}

function startedTokenFailure(
  state: NetworkState,
  started: StartedAttempt,
): NetworkFailure | undefined {
  const tokenFailure = preparedTokenFailure(state, started.prepared);
  if (tokenFailure !== undefined) return tokenFailure;
  const attempt = started.prepared.input.attempt;
  const record = findRecord(state, attempt);
  if (record === undefined) return frozen({ tag: "UnknownAttempt", attempt });
  if (record.disposition.tag !== "Started") {
    return frozen({
      tag: "AttemptConditionMismatch",
      attempt,
      expected: "IsStarted",
      actual: dispositionCondition(record.disposition),
    });
  }
  return sameHandle(record.disposition.handle, started.handle)
    ? undefined
    : frozen({
      tag: "HandleMismatch",
      expected: record.disposition.handle,
      actual: started.handle,
    });
}

function responseFieldsMatch(
  record: AttemptRecord,
  observation: AdapterObservation,
): boolean {
  if (observation.tag === "CancellationObservation") return true;
  return observation.tag === "ResponseObservation"
    && validResponse(observation.response)
    && BigInt(observation.response.body.length)
      <= record.input.configuration.responseBodyLimit;
}

function failureFieldsMatch(
  record: AttemptRecord,
  observation: AdapterObservation,
): boolean {
  return observation.tag === "FailureObservation"
    && sameAttempt(observation.failure.attempt, observation.attempt)
    && same(observation.failure.configuration, record.input.configuration)
    && (observation.failure.cause.tag !== "Timeout"
      || observation.failure.cause.stage === observation.failure.stage);
}

function deadlineFieldsMatch(
  record: AttemptRecord,
  observation: AdapterObservation,
): boolean {
  const expected = record.input.deadline;
  const capability = record.input.configuration.monotonicClock;
  return expected !== null
    && capability !== null
    && observation.tag === "DeadlineObservation"
    && same(expected, observation.deadline)
    && same(capability, expected.capability)
    && clockReaches(expected, observation.observedAt);
}

function observationRelation(
  state: NetworkState,
  observation: AdapterObservation,
): boolean {
  if (!validState(state)) return false;
  const record = findRecord(state, attemptOf(observation));
  if (record === undefined) return false;
  const handle = dispositionHandle(record.disposition);
  return handle !== undefined
    && sameAttempt(attemptOf(observation), record.input.attempt)
    && sameHandle(handleOf(observation), handle)
    && effectMatches(record.input.attempt, effectOf(observation))
    && (responseFieldsMatch(record, observation)
      || failureFieldsMatch(record, observation)
      || deadlineFieldsMatch(record, observation));
}

function hostObservationRelation(
  state: NetworkState,
  observation: HostObservation,
): boolean {
  if (observation.tag === "Delivered") {
    return observationRelation(state, observation.observation);
  }
  if (!validState(state)) return false;
  const record = findRecord(state, observation.attempt);
  return record !== undefined
    && record.disposition.tag === "Started"
    && sameHandle(record.disposition.handle, observation.handle);
}

function startObservationRelation(
  state: NetworkState,
  prepared: PreparedAttempt,
  observation: StartObservation,
): boolean {
  if (!commandIssuedRelation(state, prepared)) return false;
  if (observation.tag === "Started") {
    return sameAttempt(observation.attempt, prepared.input.attempt);
  }
  return sameAttempt(observation.failure.attempt, prepared.input.attempt)
    && observation.failure.stage === "Start"
    && same(observation.failure.configuration, prepared.input.configuration)
    && effectMatches(prepared.input.attempt, observation.effect);
}

function startObservationFailure(
  state: NetworkState,
  prepared: PreparedAttempt,
  observation: StartObservation,
): NetworkFailure {
  const conditionFailure = preparedConditionFailure(state, prepared, "IsCommandIssued");
  if (conditionFailure !== undefined) return conditionFailure;
  if (observation.tag === "Started") {
    return frozen({
      tag: "IdentityMismatch",
      expected: prepared.input.attempt,
      actual: observation.attempt,
    });
  }
  if (!sameAttempt(observation.failure.attempt, prepared.input.attempt)) {
    return frozen({
      tag: "IdentityMismatch",
      expected: prepared.input.attempt,
      actual: observation.failure.attempt,
    });
  }
  if (observation.failure.stage !== "Start") {
    return frozen({
      tag: "ObservationRelationMismatch",
      attempt: prepared.input.attempt,
      field: "FailureStage",
    });
  }
  return !same(observation.failure.configuration, prepared.input.configuration)
    ? frozen({
      tag: "ObservationRelationMismatch",
      attempt: prepared.input.attempt,
      field: "FailureConfiguration",
    })
    : frozen({
      tag: "ObservationRelationMismatch",
      attempt: prepared.input.attempt,
      field: "EffectWitnessValue",
    });
}

function adapterObservationFailure(
  state: NetworkState,
  observation: AdapterObservation,
): NetworkFailure {
  const attempt = attemptOf(observation);
  const record = findRecord(state, attempt);
  if (record === undefined) return frozen({ tag: "UnknownAttempt", attempt });
  const expectedHandle = dispositionHandle(record.disposition);
  if (expectedHandle === undefined) {
    return frozen({
      tag: "AttemptConditionMismatch",
      attempt,
      expected: "IsStarted",
      actual: dispositionCondition(record.disposition),
    });
  }
  if (!sameHandle(handleOf(observation), expectedHandle)) {
    return frozen({
      tag: "HandleMismatch",
      expected: expectedHandle,
      actual: handleOf(observation),
    });
  }
  if (!effectMatches(attempt, effectOf(observation))) {
    return frozen({ tag: "EffectWitnessMissing", attempt });
  }
  if (
    observation.tag === "ResponseObservation"
    || observation.tag === "CancellationObservation"
  ) return frozen({ tag: "MalformedAdapterObservation" });
  if (observation.tag === "FailureObservation") {
    if (!sameAttempt(observation.failure.attempt, attempt)) {
      return frozen({
        tag: "IdentityMismatch",
        expected: attempt,
        actual: observation.failure.attempt,
      });
    }
    if (
      observation.failure.cause.tag === "Timeout"
      && observation.failure.cause.stage !== observation.failure.stage
    ) {
      return frozen({
        tag: "ObservationRelationMismatch",
        attempt,
        field: "FailureStage",
      });
    }
    return frozen({
      tag: "ObservationRelationMismatch",
      attempt,
      field: "FailureConfiguration",
    });
  }
  if (!same(record.input.deadline, observation.deadline)) {
    return frozen({
      tag: "ObservationRelationMismatch",
      attempt,
      field: "DeadlineValue",
    });
  }
  if (!same(observation.deadline.clockBasis, observation.observedAt.clockBasis)) {
    return frozen({
      tag: "ClockBasisMismatch",
      expected: observation.deadline.clockBasis,
      actual: observation.observedAt.clockBasis,
    });
  }
  return frozen({
    tag: "DeadlineNotReached",
    deadline: observation.deadline,
    observedAt: observation.observedAt,
  });
}

function hostObservationFailure(
  state: NetworkState,
  observation: HostObservation,
): NetworkFailure {
  if (observation.tag === "Delivered") {
    return adapterObservationFailure(state, observation.observation);
  }
  const record = findRecord(state, observation.attempt);
  if (record === undefined) {
    return frozen({ tag: "UnknownAttempt", attempt: observation.attempt });
  }
  if (record.disposition.tag !== "Started") {
    return frozen({
      tag: "AttemptConditionMismatch",
      attempt: observation.attempt,
      expected: "IsStarted",
      actual: dispositionCondition(record.disposition),
    });
  }
  return sameHandle(observation.handle, record.disposition.handle)
    ? frozen({ tag: "MalformedAdapterObservation" })
    : frozen({
      tag: "HandleMismatch",
      expected: record.disposition.handle,
      actual: observation.handle,
    });
}

function recordedDelivery(
  record: AttemptRecord,
  delivery: bigint,
): AdapterObservation | undefined {
  if (record.firstDelivery?.delivery === delivery) return record.firstDelivery.observation;
  return record.late.find((late) =>
    late.delivered.delivery === delivery)?.delivered.observation;
}

function expectedDelivery(record: AttemptRecord): bigint {
  if (record.firstDelivery === null) return 0n;
  const last = record.late[record.late.length - 1];
  return (last?.delivered.delivery ?? record.firstDelivery.delivery) + 1n;
}

function terminalOf(observation: AdapterObservation): NetworkTerminal {
  switch (observation.tag) {
    case "ResponseObservation":
      return frozen({
        outcome: frozen({
          tag: "Response",
          response: observation.response,
          provenance: observation.provenance,
        }),
        effect: observation.effect,
      });
    case "FailureObservation":
      return frozen({
        outcome: frozen({ tag: "Failed", failure: observation.failure }),
        effect: observation.effect,
      });
    case "CancellationObservation":
      return frozen({
        outcome: frozen({ tag: "Cancelled" }),
        effect: observation.effect,
      });
    case "DeadlineObservation":
      return frozen({
        outcome: frozen({
          tag: "DeadlineExceeded",
          deadline: observation.deadline,
          observedAt: observation.observedAt,
        }),
        effect: observation.effect,
      });
  }
}

export function readNetworkState(state: NetworkState): ReadStateStep {
  return validState(state)
    ? frozen({ tag: "Read", state })
    : frozen({
      tag: "Rejected",
      state,
      failure: frozen({ tag: "InvalidNetworkState", violation: stateViolation(state) }),
    });
}

export function prepare(state: NetworkState, input: AttemptInput): PrepareStep {
  if (!validState(state)) {
    return frozen({
      tag: "Rejected",
      state,
      failure: frozen({ tag: "InvalidNetworkState", violation: stateViolation(state) }),
    });
  }
  if (!validInput(input)) {
    return frozen({
      tag: "Rejected",
      state,
      failure: frozen({ tag: "InvalidWireInstruction", method: input.instruction.method }),
    });
  }
  if (input.attempt.ordinal !== 0n) {
    return frozen({
      tag: "Rejected",
      state,
      failure: frozen({ tag: "RootAttemptRequired", attempt: input.attempt }),
    });
  }
  if (state.attempts.some((record) =>
    sameLogical(record.input.attempt.logical, input.attempt.logical))) {
    return frozen({
      tag: "Rejected",
      state,
      failure: frozen({ tag: "DuplicateAttempt", attempt: input.attempt }),
    });
  }
  const lineage: AttemptLineage = frozen({ tag: "Root" });
  const prepared: PreparedAttempt = frozen({ input, lineage });
  const next = appendRecord(state, frozen({
    input,
    lineage,
    disposition: frozen({ tag: "Prepared" }),
    firstDelivery: null,
    late: arr([]),
  }));
  return validState(next) && preparedRelation(next, prepared)
    ? frozen({ tag: "Prepared", state: next, prepared })
    : frozen({
      tag: "Rejected",
      state,
      failure: frozen({ tag: "InvalidNetworkState", violation: stateViolation(next) }),
    });
}

export function sendCommand(
  state: NetworkState,
  prepared: PreparedAttempt,
): CommandStep<SendCommand> {
  if (commandIssuedMatches(state, prepared)) {
    return frozen({
      tag: "Rejected",
      state,
      failure: frozen({ tag: "CommandAlreadyIssued", attempt: prepared.input.attempt }),
    });
  }
  if (!preparedReady(state, prepared)) {
    if (!validState(state)) {
      return frozen({
        tag: "Rejected",
        state,
        failure: frozen({
          tag: "InvalidNetworkState",
          violation: stateViolation(state),
        }),
      });
    }
    const failure = preparedConditionFailure(state, prepared, "IsPrepared")
      ?? frozen({
        tag: "AttemptConditionMismatch" as const,
        attempt: prepared.input.attempt,
        expected: "IsPrepared" as const,
        actual: "IsPrepared" as const,
      });
    return frozen({ tag: "Rejected", state, failure });
  }
  const record = findRecord(state, prepared.input.attempt);
  if (record === undefined) {
    return frozen({
      tag: "Rejected",
      state,
      failure: frozen({ tag: "UnknownAttempt", attempt: prepared.input.attempt }),
    });
  }
  const next = replaceRecord(state, prepared.input.attempt, frozen({
    ...record,
    disposition: frozen({ tag: "CommandIssued" }),
  }));
  if (!validState(next)) {
    return frozen({
      tag: "Rejected",
      state,
      failure: frozen({ tag: "InvalidNetworkState", violation: stateViolation(next) }),
    });
  }
  return frozen({
    tag: "CommandReady",
    state: next,
    command: frozen({ prepared }),
  });
}

export function cancelCommand(
  state: NetworkState,
  started: StartedAttempt,
): CommandStep<CancelCommand> {
  if (!startedRelation(state, started)) {
    if (!validState(state)) {
      return frozen({
        tag: "Rejected",
        state,
        failure: frozen({
          tag: "InvalidNetworkState",
          violation: stateViolation(state),
        }),
      });
    }
    const failure = startedTokenFailure(state, started)
      ?? frozen({
        tag: "AttemptConditionMismatch" as const,
        attempt: started.prepared.input.attempt,
        expected: "IsStarted" as const,
        actual: "IsStarted" as const,
      });
    return frozen({ tag: "Rejected", state, failure });
  }
  const capability = started.prepared.input.configuration.cancellation;
  if (capability === null) {
    return frozen({
      tag: "Rejected",
      state,
      failure: frozen({
        tag: "RequiredCapabilityUnavailable",
        attempt: started.prepared.input.attempt,
        capability: "Cancellation",
      }),
    });
  }
  return frozen({
    tag: "CommandReady",
    state,
    command: frozen({
      attempt: started.prepared.input.attempt,
      handle: started.handle,
      capability,
    }),
  });
}

export function observeStart(
  state: NetworkState,
  prepared: PreparedAttempt,
  observation: StartObservation,
): NetworkStep {
  if (!startObservationRelation(state, prepared, observation)) {
    const failure = validState(state)
      ? startObservationFailure(state, prepared, observation)
      : frozen({
        tag: "InvalidNetworkState" as const,
        violation: stateViolation(state),
      });
    return frozen({ tag: "Rejected", state, failure });
  }
  const record = findRecord(state, prepared.input.attempt);
  if (record === undefined) {
    return frozen({
      tag: "Rejected",
      state,
      failure: frozen({
        tag: "ObservationRelationMismatch",
        attempt: prepared.input.attempt,
        field: "FailureStage",
      }),
    });
  }
  if (observation.tag === "Started") {
    const started: StartedAttempt = frozen({ prepared, handle: observation.handle });
    const next = replaceRecord(state, observation.attempt, frozen({
      ...record,
      disposition: frozen({ tag: "Started", handle: observation.handle }),
    }));
    return validState(next) && startedRelation(next, started)
      ? frozen({ tag: "Started", state: next, started })
      : frozen({
        tag: "Rejected",
        state,
        failure: frozen({ tag: "InvalidNetworkState", violation: stateViolation(next) }),
      });
  }
  const terminal: NetworkTerminal = frozen({
    outcome: frozen({ tag: "Failed", failure: observation.failure }),
    effect: observation.effect,
  });
  const settled: SettledAttempt = frozen({ prepared, handle: null, terminal });
  const next = replaceRecord(state, prepared.input.attempt, frozen({
    ...record,
    disposition: frozen({ tag: "Settled", handle: null, terminal }),
  }));
  return validState(next)
    ? frozen({ tag: "Terminal", state: next, settled })
    : frozen({
      tag: "Rejected",
      state,
      failure: frozen({ tag: "InvalidNetworkState", violation: stateViolation(next) }),
    });
}

export function observe(state: NetworkState, observation: HostObservation): NetworkStep {
  if (!hostObservationRelation(state, observation)) {
    const failure = validState(state)
      ? hostObservationFailure(state, observation)
      : frozen({
        tag: "InvalidNetworkState" as const,
        violation: stateViolation(state),
      });
    return frozen({ tag: "Rejected", state, failure });
  }
  if (observation.tag === "Pending") {
    const record = findRecord(state, observation.attempt);
    if (record === undefined) {
      return frozen({
        tag: "Rejected",
        state,
        failure: frozen({ tag: "UnknownAttempt", attempt: observation.attempt }),
      });
    }
    return frozen({
      tag: "Pending",
      state,
      started: frozen({
        prepared: frozen({ input: record.input, lineage: record.lineage }),
        handle: observation.handle,
      }),
    });
  }
  const deliveredObservation = observation.observation;
  const attempt = attemptOf(deliveredObservation);
  const record = findRecord(state, attempt);
  if (record === undefined) {
    return frozen({
      tag: "Rejected",
      state,
      failure: frozen({ tag: "UnknownAttempt", attempt }),
    });
  }
  const old = recordedDelivery(record, observation.delivery);
  if (old !== undefined) {
    return same(old, deliveredObservation)
      ? frozen({ tag: "Duplicate", state, attempt, delivery: observation.delivery })
      : frozen({
        tag: "Rejected",
        state,
        failure: frozen({
          tag: "ConflictingDelivery",
          attempt,
          delivery: observation.delivery,
          old,
          fresh: deliveredObservation,
        }),
      });
  }
  const expected = expectedDelivery(record);
  if (observation.delivery !== expected) {
    return frozen({
      tag: "Rejected",
      state,
      failure: frozen({
        tag: "DeliveryOrderViolation",
        attempt,
        expected,
        actual: observation.delivery,
      }),
    });
  }
  if (record.disposition.tag === "Started") {
    const terminal = terminalOf(deliveredObservation);
    const settled: SettledAttempt = frozen({
      prepared: frozen({ input: record.input, lineage: record.lineage }),
      handle: record.disposition.handle,
      terminal,
    });
    const firstDelivery: DeliveredObservation = frozen({
      delivery: observation.delivery,
      observation: deliveredObservation,
    });
    const next = replaceRecord(state, attempt, frozen({
      ...record,
      disposition: frozen({
        tag: "Settled",
        handle: record.disposition.handle,
        terminal,
      }),
      firstDelivery,
      late: arr([]),
    }));
    return validState(next)
      ? frozen({ tag: "Terminal", state: next, settled })
      : frozen({
        tag: "Rejected",
        state,
        failure: frozen({ tag: "InvalidNetworkState", violation: stateViolation(next) }),
      });
  }
  if (record.disposition.tag === "Settled") {
    const late: LateObservation = frozen({
      delivered: frozen({
        delivery: observation.delivery,
        observation: deliveredObservation,
      }),
    });
    const settled: SettledAttempt = frozen({
      prepared: frozen({ input: record.input, lineage: record.lineage }),
      handle: record.disposition.handle,
      terminal: record.disposition.terminal,
    });
    const next = replaceRecord(state, attempt, frozen({
      ...record,
      late: arr([...record.late, late]),
    }));
    return validState(next)
      ? frozen({ tag: "Late", state: next, settled, late })
      : frozen({
        tag: "Rejected",
        state,
        failure: frozen({ tag: "InvalidNetworkState", violation: stateViolation(next) }),
      });
  }
  return frozen({
    tag: "Rejected",
    state,
    failure: frozen({
      tag: "AttemptConditionMismatch",
      attempt,
      expected: "IsStarted",
      actual: dispositionCondition(record.disposition),
    }),
  });
}

function annotationStatusValid(current: EffectStatus, requested: EffectStatus): boolean {
  if (current.tag === "Unknown") {
    return requested.tag === "NoEffect" || requested.tag === "EffectOccurred";
  }
  if (current.tag === "NoEffect" && requested.tag === "NoEffect") {
    return same(current.witness, requested.witness);
  }
  if (current.tag === "EffectOccurred" && requested.tag === "EffectOccurred") {
    return same(current.witness, requested.witness);
  }
  return false;
}

function annotationConflicts(current: EffectStatus, requested: EffectStatus): boolean {
  return (current.tag === "NoEffect" && requested.tag === "EffectOccurred")
    || (current.tag === "EffectOccurred" && requested.tag === "NoEffect");
}

export function annotateEffect(
  state: NetworkState,
  observation: EffectObservation,
): StateStep {
  if (!validState(state)) {
    return frozen({
      tag: "Rejected",
      state,
      failure: frozen({ tag: "InvalidNetworkState", violation: stateViolation(state) }),
    });
  }
  const record = findRecord(state, observation.attempt);
  if (record === undefined) {
    return frozen({
      tag: "Rejected",
      state,
      failure: frozen({ tag: "UnknownAttempt", attempt: observation.attempt }),
    });
  }
  if (record.disposition.tag !== "Settled") {
    return frozen({
      tag: "Rejected",
      state,
      failure: frozen({
        tag: "AttemptConditionMismatch",
        attempt: observation.attempt,
        expected: "IsSettled",
        actual: dispositionCondition(record.disposition),
      }),
    });
  }
  if (!effectMatches(observation.attempt, observation.status)) {
    return frozen({
      tag: "Rejected",
      state,
      failure: frozen({ tag: "EffectWitnessMissing", attempt: observation.attempt }),
    });
  }
  if (!annotationStatusValid(record.disposition.terminal.effect, observation.status)) {
    return frozen({
      tag: "Rejected",
      state,
      failure: annotationConflicts(record.disposition.terminal.effect, observation.status)
        ? frozen({ tag: "EffectKnowledgeConflict", attempt: observation.attempt })
        : frozen({ tag: "EffectWitnessMissing", attempt: observation.attempt }),
    });
  }
  const next = replaceRecord(state, observation.attempt, frozen({
    ...record,
    disposition: frozen({
      ...record.disposition,
      terminal: frozen({
        ...record.disposition.terminal,
        effect: observation.status,
      }),
    }),
  }));
  return validState(next)
    ? frozen({ tag: "Applied", state: next })
    : frozen({
      tag: "Rejected",
      state,
      failure: frozen({ tag: "InvalidNetworkState", violation: stateViolation(next) }),
    });
}

function retryFailureAttempt(permission: RetryPermission): AttemptIdentity {
  return permission.tag === "RetryAllowed"
    ? permission.authorization.from
    : permission.parent;
}

function retryAcceptable(state: NetworkState, request: RetryRequest): boolean {
  if (!validState(state) || request.permission.tag !== "RetryAllowed") return false;
  const authorization = request.permission.authorization;
  const input: AttemptInput = {
    attempt: authorization.next,
    instruction: request.instruction,
    deadline: request.deadline,
    configuration: request.configuration,
  };
  const parent = findRecord(state, authorization.from);
  return validInput(input)
    && sameLogical(authorization.logical, authorization.from.logical)
    && sameLogical(authorization.logical, authorization.next.logical)
    && authorization.from.ordinal + 1n === authorization.next.ordinal
    && parent !== undefined
    && parent.disposition.tag === "Settled"
    && !state.attempts.some((candidate) =>
      sameLogical(candidate.input.attempt.logical, authorization.from.logical)
      && candidate.input.attempt.ordinal > authorization.from.ordinal)
    && findRecord(state, authorization.next) === undefined
    && state.attempts.every((record) =>
      record.lineage.tag !== "RetryOf"
      || !same(record.lineage.authorization, authorization));
}

export function retry(state: NetworkState, request: RetryRequest): PrepareStep {
  if (!retryAcceptable(state, request) || request.permission.tag !== "RetryAllowed") {
    return frozen({
      tag: "Rejected",
      state,
      failure: frozen({
        tag: "RetryNotPermitted",
        attempt: retryFailureAttempt(request.permission),
      }),
    });
  }
  const authorization = request.permission.authorization;
  const input: AttemptInput = frozen({
    attempt: authorization.next,
    instruction: request.instruction,
    deadline: request.deadline,
    configuration: request.configuration,
  });
  const lineage: AttemptLineage = frozen({ tag: "RetryOf", authorization });
  const prepared: PreparedAttempt = frozen({ input, lineage });
  const next = appendRecord(state, frozen({
    input,
    lineage,
    disposition: frozen({ tag: "Prepared" }),
    firstDelivery: null,
    late: arr([]),
  }));
  return validState(next) && preparedRelation(next, prepared)
    ? frozen({ tag: "Prepared", state: next, prepared })
    : frozen({
      tag: "Rejected",
      state,
      failure: frozen({ tag: "InvalidNetworkState", violation: stateViolation(next) }),
    });
}

export function effectUnknown(
  reason: UnknownEffectReason = "NoResponse",
): EffectStatus {
  return frozen({ tag: "Unknown", reason });
}

export function sourceNone(): SourceSequence {
  return frozen({ tag: "none" });
}

export function sourceSome(value: bigint): SourceSequence {
  return frozen({ tag: "some", value });
}
