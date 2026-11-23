// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { judgeErasureBy } from "neco-quotient-retention";
import type { ErasureDecision } from "neco-quotient-retention";
import type { ExecutionHandle, RequestIdentity } from "./request-progression.js";
import { type PMap, type PVec, mapEmpty, mapGet, mapSet, pairKey, vecEmpty, vecGet, vecPush, vecSet, vecToArray } from "./persistent.js";
export type { ExecutionHandle, RequestIdentity } from "./request-progression.js";

export type ByteString = Uint8Array;
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
export type AttemptChain = { readonly tag: "Root" } | { readonly tag: "RetryOf"; readonly authorization: RetryAuthorization };
export interface PreparedAttempt { readonly input: AttemptInput; readonly chain: AttemptChain; }
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
export interface AttemptRecord { readonly input: AttemptInput; readonly chain: AttemptChain; readonly disposition: AttemptDisposition; readonly firstDelivery: DeliveredObservation | null; readonly late: readonly LateObservation[]; }
declare const networkStateBrand: unique symbol;
export interface NetworkState { readonly [networkStateBrand]: true; }
export type RetryPermission = { readonly tag: "RetryAllowed"; readonly authorization: RetryAuthorization } | { readonly tag: "RetryDenied"; readonly logical: RequestIdentity; readonly parent: AttemptIdentity; readonly evidence: OpaqueEvidence };
export interface RetryRequest { readonly permission: RetryPermission; readonly instruction: HttpWireInstruction; readonly deadline: Deadline | null; readonly configuration: HostConfiguration; }
export type StartObservation = { readonly tag: "Started"; readonly attempt: AttemptIdentity; readonly handle: ExecutionHandle } | { readonly tag: "StartFailed"; readonly failure: NetworkHostFailure; readonly effect: EffectStatus };
export type HostObservation = { readonly tag: "Pending"; readonly attempt: AttemptIdentity; readonly handle: ExecutionHandle } | { readonly tag: "Delivered"; readonly delivery: bigint; readonly observation: AdapterObservation };
export type NetworkStateViolation =
  | { readonly tag: "DuplicateAttemptKey"; readonly attempt: AttemptIdentity }
  | { readonly tag: "NonRootFirstAttempt"; readonly attempt: AttemptIdentity }
  | { readonly tag: "OrdinalGap"; readonly attempt: AttemptIdentity }
  | { readonly tag: "ChainMismatch"; readonly attempt: AttemptIdentity }
  | { readonly tag: "RetryAuthorizationReuse"; readonly authorization: RetryAuthorization }
  | { readonly tag: "DispositionEvidenceMismatch"; readonly attempt: AttemptIdentity }
  | { readonly tag: "DeliveryLogMismatch"; readonly attempt: AttemptIdentity };
export type AttemptCondition = "IsPrepared" | "IsCommandIssued" | "IsStarted" | "IsSettled";
export type AttemptTokenField = "Instruction" | "Deadline" | "Configuration" | "Chain" | "Handle";
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
export interface ReadStateStep { readonly tag: "Read"; readonly state: NetworkState; }
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

interface StateFields {
  readonly records: PVec<AttemptRecord>;
  readonly positions: PMap<number>;
  readonly highestOrdinals: PMap<bigint>;
  readonly usedAuthorizations: PMap<true>;
}

type StateValue = StateFields & NetworkState;

function fieldsOf(state: NetworkState): StateFields {
  return state as StateValue;
}

function sealed(fields: StateFields): NetworkState {
  return frozen(fields) as StateValue;
}

function logicalKey(logical: RequestIdentity): string {
  return `${pairKey(logical.kind, logical.provenance)}${logical.revision};`;
}

function attemptKey(attempt: AttemptIdentity): string {
  return `${logicalKey(attempt.logical)}${attempt.ordinal};`;
}

function authorizationKey(authorization: RetryAuthorization): string {
  return `${logicalKey(authorization.logical)}${attemptKey(authorization.from)}${attemptKey(authorization.next)}${pairKey(authorization.protocolEvidence.value, "")}`;
}

function appendRecord(fields: StateFields, record: AttemptRecord): StateFields {
  const attempt = record.input.attempt;
  const logical = logicalKey(attempt.logical);
  const highest = mapGet(fields.highestOrdinals, logical);
  return {
    records: vecPush(fields.records, record),
    positions: mapSet(fields.positions, attemptKey(attempt), fields.records.size),
    highestOrdinals: highest === undefined || highest < attempt.ordinal ? mapSet(fields.highestOrdinals, logical, attempt.ordinal) : fields.highestOrdinals,
    usedAuthorizations: record.chain.tag === "RetryOf" ? mapSet(fields.usedAuthorizations, authorizationKey(record.chain.authorization), true as const) : fields.usedAuthorizations,
  };
}

const emptyFields: StateFields = {
  records: vecEmpty(),
  positions: mapEmpty(),
  highestOrdinals: mapEmpty(),
  usedAuthorizations: mapEmpty(),
};

export function emptyNetworkState(): NetworkState {
  return sealed(emptyFields);
}

export const emptyState = emptyNetworkState;

export type NetworkStateResult =
  | { readonly tag: "state"; readonly state: NetworkState }
  | { readonly tag: "stateRejected"; readonly violation: NetworkStateViolation };

export function networkStateOf(records: readonly AttemptRecord[]): NetworkStateResult {
  if (!validRecords(records)) {
    return frozen({ tag: "stateRejected", violation: recordsViolation(records) });
  }
  let fields = emptyFields;
  for (const record of records) fields = appendRecord(fields, record);
  return frozen({ tag: "state", state: sealed(fields) });
}

export function networkAttempts(state: NetworkState): readonly AttemptRecord[] {
  return frozen(vecToArray(fieldsOf(state).records));
}

function same(left: unknown, right: unknown): boolean {
  if (Object.is(left, right)) return true;
  if (
    typeof left !== typeof right
    || left === null
    || right === null
    || typeof left !== "object"
    || typeof right !== "object"
  ) return false;
  if (left instanceof Uint8Array || right instanceof Uint8Array) {
    return left instanceof Uint8Array
      && right instanceof Uint8Array
      && left.length === right.length
      && left.every((byte, index) => byte === right[index]);
  }
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
  const fields = fieldsOf(state);
  const position = mapGet(fields.positions, attemptKey(attempt));
  return position === undefined ? undefined : vecGet(fields.records, position);
}

function replaceRecord(
  state: NetworkState,
  attempt: AttemptIdentity,
  replacement: AttemptRecord,
): NetworkState {
  const fields = fieldsOf(state);
  const position = mapGet(fields.positions, attemptKey(attempt));
  if (position === undefined) return state;
  return sealed({ ...fields, records: vecSet(fields.records, position, replacement) });
}

function appendedState(state: NetworkState, record: AttemptRecord): NetworkState {
  return sealed(appendRecord(fieldsOf(state), record));
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
  return headers.every((header) => validToken(header.name));
}

function validInstruction(instruction: HttpWireInstruction): boolean {
  return validToken(instruction.method)
    && validTarget(instruction.target)
    && validHeaders(instruction.headers);
}

function validResponse(response: RawHttpResponse): boolean {
  return Number.isInteger(response.status)
    && response.status >= 100
    && response.status <= 999
    && validHeaders(response.headers);
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

interface StateQueries {
  readonly laterAttempt: (index: number) => boolean;
  readonly laterAuthorization: (index: number) => boolean;
  readonly rootFor: (index: number) => boolean;
  readonly parentSettled: (index: number) => boolean;
}

function rootForLogical(
  records: readonly AttemptRecord[],
  logical: RequestIdentity,
): boolean {
  return records.some((record) =>
    sameLogical(record.input.attempt.logical, logical)
    && record.input.attempt.ordinal === 0n
    && record.chain.tag === "Root");
}

function settledAttemptExists(
  records: readonly AttemptRecord[],
  attempt: AttemptIdentity,
): boolean {
  return records.some((record) =>
    sameAttempt(record.input.attempt, attempt)
    && record.disposition.tag === "Settled");
}

function retryAuthorization(record: AttemptRecord): RetryAuthorization {
  if (record.chain.tag !== "RetryOf") throw new TypeError("retry chain");
  return record.chain.authorization;
}

function directQueries(records: readonly AttemptRecord[]): StateQueries {
  const recordAt = (index: number): AttemptRecord => records[index] as AttemptRecord;
  return {
    laterAttempt: (index) => records.slice(index + 1).some((candidate) =>
      sameAttempt(candidate.input.attempt, recordAt(index).input.attempt)),
    laterAuthorization: (index) => records.slice(index + 1).some((candidate) =>
      candidate.chain.tag === "RetryOf"
      && same(candidate.chain.authorization, retryAuthorization(recordAt(index)))),
    rootFor: (index) => rootForLogical(records, recordAt(index).input.attempt.logical),
    parentSettled: (index) => settledAttemptExists(records, retryAuthorization(recordAt(index)).from),
  };
}

function sameKey(value: unknown, known: Map<object, string | null>, depth = 0): string | null {
  if (value === null) return "z";
  switch (typeof value) {
    case "undefined": return "u";
    case "boolean": return value ? "t" : "f";
    case "string": return `s${value.length}:${value}`;
    case "bigint": return `b${value};`;
    case "number": return Object.is(value, -0) ? "n-0;" : `n${String(value)};`;
    case "object": break;
    default: return null;
  }
  const cached = known.get(value);
  if (cached !== undefined) return cached;
  if (depth > 64) return null;
  let key: string | null = "";
  if (Array.isArray(value)) {
    for (let index = 0; index < value.length && key !== null; index += 1) {
      const part = index in value ? sameKey(value[index], known, depth + 1) : null;
      key = part === null ? null : key + part;
    }
    key = key === null ? null : `[${value.length};${key}]`;
  } else {
    const keys = Object.keys(value);
    if (Object.getOwnPropertyNames(value).length !== keys.length) key = null;
    for (const name of keys.sort()) {
      if (key === null) break;
      const part = sameKey((value as Record<string, unknown>)[name], known, depth + 1);
      key = part === null ? null : `${key}${name.length}:${name}=${part}`;
    }
    key = key === null ? null : `{${keys.length};${key}}`;
  }
  known.set(value, key);
  return key;
}

function indexedQueries(records: readonly AttemptRecord[]): StateQueries | null {
  const attempts: string[] = [];
  const logicals: string[] = [];
  const authorizations: string[] = [];
  const parents: string[] = [];
  const lastAttempt = new Map<string, number>();
  const lastAuthorization = new Map<string, number>();
  const roots = new Set<string>();
  const settled = new Set<string>();
  const known = new Map<object, string | null>();
  for (let index = 0; index < records.length; index += 1) {
    const record = records[index] as AttemptRecord;
    const attempt = sameKey(record.input.attempt, known);
    const logical = sameKey(record.input.attempt.logical, known);
    if (attempt === null || logical === null) return null;
    attempts.push(attempt);
    logicals.push(logical);
    lastAttempt.set(attempt, index);
    if (record.input.attempt.ordinal === 0n && record.chain.tag === "Root") roots.add(logical);
    if (record.disposition.tag === "Settled") settled.add(attempt);
    if (record.chain.tag === "RetryOf") {
      const authorization = sameKey(record.chain.authorization, known);
      const parent = sameKey(record.chain.authorization.from, known);
      if (authorization === null || parent === null) return null;
      authorizations.push(authorization);
      parents.push(parent);
      lastAuthorization.set(authorization, index);
    } else {
      authorizations.push("");
      parents.push("");
    }
  }
  return {
    laterAttempt: (index) => (lastAttempt.get(attempts[index] ?? "") ?? index) > index,
    laterAuthorization: (index) => (lastAuthorization.get(authorizations[index] ?? "") ?? index) > index,
    rootFor: (index) => roots.has(logicals[index] ?? ""),
    parentSettled: (index) => settled.has(parents[index] ?? ""),
  };
}

function stateQueries(records: readonly AttemptRecord[]): StateQueries {
  try {
    return indexedQueries(records) ?? directQueries(records);
  } catch {
    return directQueries(records);
  }
}

function chainValid(
  queries: StateQueries,
  index: number,
  record: AttemptRecord,
): boolean {
  if (!queries.rootFor(index)) return false;
  if (record.chain.tag === "Root") return record.input.attempt.ordinal === 0n;
  const authorization = record.chain.authorization;
  return sameLogical(authorization.logical, record.input.attempt.logical)
    && sameLogical(authorization.from.logical, record.input.attempt.logical)
    && sameAttempt(authorization.next, record.input.attempt)
    && authorization.from.ordinal + 1n === authorization.next.ordinal
    && queries.parentSettled(index);
}

function validRecords(records: readonly AttemptRecord[]): boolean {
  const queries = stateQueries(records);
  for (let index = 0; index < records.length; index += 1) {
    const record = records[index];
    if (record === undefined) return false;
    if (
      queries.laterAttempt(index)
      || !recordEvidenceValid(record)
      || !chainValid(queries, index, record)
    ) return false;
  }
  for (let index = 0; index < records.length; index += 1) {
    const record = records[index];
    if (record?.chain.tag !== "RetryOf") continue;
    if (queries.laterAuthorization(index)) return false;
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
  queries: StateQueries,
): NetworkStateViolation | undefined {
  for (let index = 0; index < records.length; index += 1) {
    const record = records[index];
    if (record !== undefined && queries.laterAttempt(index)) {
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

function chainViolation(
  queries: StateQueries,
  index: number,
  record: AttemptRecord,
): NetworkStateViolation | undefined {
  if (chainValid(queries, index, record)) return undefined;
  if (!queries.rootFor(index)) {
    return frozen({ tag: "NonRootFirstAttempt", attempt: record.input.attempt });
  }
  if (record.chain.tag === "Root") {
    return frozen({ tag: "NonRootFirstAttempt", attempt: record.input.attempt });
  }
  return record.chain.authorization.next.ordinal
      !== record.chain.authorization.from.ordinal + 1n
    ? frozen({ tag: "OrdinalGap", attempt: record.input.attempt })
    : frozen({ tag: "ChainMismatch", attempt: record.input.attempt });
}

function firstChainViolation(
  records: readonly AttemptRecord[],
  queries: StateQueries,
): NetworkStateViolation | undefined {
  for (const [index, record] of records.entries()) {
    const violation = chainViolation(queries, index, record);
    if (violation !== undefined) return violation;
  }
  return undefined;
}

function firstRootViolation(
  records: readonly AttemptRecord[],
  queries: StateQueries,
): NetworkStateViolation | undefined {
  for (const [index, record] of records.entries()) {
    if (!queries.rootFor(index)) {
      return frozen({ tag: "NonRootFirstAttempt", attempt: record.input.attempt });
    }
  }
  return undefined;
}

function firstAuthorizationViolation(
  records: readonly AttemptRecord[],
  queries: StateQueries,
): NetworkStateViolation | undefined {
  for (let index = 0; index < records.length; index += 1) {
    const record = records[index];
    if (record?.chain.tag !== "RetryOf") continue;
    if (queries.laterAuthorization(index)) {
      return frozen({ tag: "RetryAuthorizationReuse", authorization: record.chain.authorization });
    }
  }
  return undefined;
}

function recordsViolation(records: readonly AttemptRecord[]): NetworkStateViolation {
  const queries = stateQueries(records);
  return firstDuplicateViolation(records, queries)
    ?? firstRecordViolation(records)
    ?? firstChainViolation(records, queries)
    ?? firstRootViolation(records, queries)
    ?? firstAuthorizationViolation(records, queries)
    ?? frozen({ tag: "DuplicateAttemptKey", attempt: emptyAttemptIdentity() });
}

function preparedRecordMatches(state: NetworkState, prepared: PreparedAttempt): boolean {
  const record = findRecord(state, prepared.input.attempt);
  return record !== undefined
    && same(record.input, prepared.input)
    && same(record.chain, prepared.chain);
}

function preparedReady(state: NetworkState, prepared: PreparedAttempt): boolean {
  const record = findRecord(state, prepared.input.attempt);
  return preparedRecordMatches(state, prepared)
    && record !== undefined
    && record.disposition.tag === "Prepared";
}

function commandIssuedMatches(state: NetworkState, prepared: PreparedAttempt): boolean {
  const record = findRecord(state, prepared.input.attempt);
  return record !== undefined
    && same(record.input, prepared.input)
    && same(record.chain, prepared.chain)
    && record.disposition.tag === "CommandIssued";
}

function commandIssuedRelation(state: NetworkState, prepared: PreparedAttempt): boolean {
  const record = findRecord(state, prepared.input.attempt);
  return preparedRecordMatches(state, prepared)
    && record !== undefined
    && record.disposition.tag === "CommandIssued";
}

function startedRecordMatches(state: NetworkState, started: StartedAttempt): boolean {
  const record = findRecord(state, started.prepared.input.attempt);
  return record !== undefined
    && same(record.input, started.prepared.input)
    && same(record.chain, started.prepared.chain)
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
  if (!same(record.chain, prepared.chain)) {
    return frozen({
      tag: "AttemptTokenMismatch",
      attempt: prepared.input.attempt,
      field: "Chain",
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
  return frozen({ tag: "Read", state });
}

export function prepare(state: NetworkState, input: AttemptInput): PrepareStep {
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
  if (mapGet(fieldsOf(state).highestOrdinals, logicalKey(input.attempt.logical)) !== undefined) {
    return frozen({
      tag: "Rejected",
      state,
      failure: frozen({ tag: "DuplicateAttempt", attempt: input.attempt }),
    });
  }
  const chain: AttemptChain = frozen({ tag: "Root" });
  const prepared: PreparedAttempt = frozen({ input, chain });
  const next = appendedState(state, frozen({
    input,
    chain,
    disposition: frozen({ tag: "Prepared" }),
    firstDelivery: null,
    late: arr([]),
  }));
  return frozen({ tag: "Prepared", state: next, prepared });
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
  const record = findRecord(state, prepared.input.attempt);
  if (record === undefined || !preparedReady(state, prepared)) {
    const failure = preparedConditionFailure(state, prepared, "IsPrepared")
      ?? frozen({
        tag: "AttemptConditionMismatch" as const,
        attempt: prepared.input.attempt,
        expected: "IsPrepared" as const,
        actual: "IsPrepared" as const,
      });
    return frozen({ tag: "Rejected", state, failure });
  }
  const next = replaceRecord(state, prepared.input.attempt, frozen({
    ...record,
    disposition: frozen({ tag: "CommandIssued" }),
  }));
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
  if (!startedRecordMatches(state, started)) {
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
    return frozen({ tag: "Rejected", state, failure: startObservationFailure(state, prepared, observation) });
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
    return frozen({ tag: "Started", state: next, started });
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
  return frozen({ tag: "Terminal", state: next, settled });
}

export function observe(state: NetworkState, observation: HostObservation): NetworkStep {
  if (!hostObservationRelation(state, observation)) {
    return frozen({ tag: "Rejected", state, failure: hostObservationFailure(state, observation) });
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
        prepared: frozen({ input: record.input, chain: record.chain }),
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
      prepared: frozen({ input: record.input, chain: record.chain }),
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
    return frozen({ tag: "Terminal", state: next, settled });
  }
  if (record.disposition.tag === "Settled") {
    const late: LateObservation = frozen({
      delivered: frozen({
        delivery: observation.delivery,
        observation: deliveredObservation,
      }),
    });
    const settled: SettledAttempt = frozen({
      prepared: frozen({ input: record.input, chain: record.chain }),
      handle: record.disposition.handle,
      terminal: record.disposition.terminal,
    });
    const next = replaceRecord(state, attempt, frozen({
      ...record,
      late: arr([...record.late, late]),
    }));
    return frozen({ tag: "Late", state: next, settled, late });
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
  return frozen({ tag: "Applied", state: next });
}

function retryFailureAttempt(permission: RetryPermission): AttemptIdentity {
  return permission.tag === "RetryAllowed"
    ? permission.authorization.from
    : permission.parent;
}

function retryAcceptable(state: NetworkState, request: RetryRequest): boolean {
  if (request.permission.tag !== "RetryAllowed") return false;
  const authorization = request.permission.authorization;
  const input: AttemptInput = {
    attempt: authorization.next,
    instruction: request.instruction,
    deadline: request.deadline,
    configuration: request.configuration,
  };
  const fields = fieldsOf(state);
  const parent = findRecord(state, authorization.from);
  const highest = mapGet(fields.highestOrdinals, logicalKey(authorization.from.logical));
  return validInput(input)
    && sameLogical(authorization.logical, authorization.from.logical)
    && sameLogical(authorization.logical, authorization.next.logical)
    && authorization.from.ordinal + 1n === authorization.next.ordinal
    && parent !== undefined
    && parent.disposition.tag === "Settled"
    && (highest === undefined || highest <= authorization.from.ordinal)
    && findRecord(state, authorization.next) === undefined
    && mapGet(fields.usedAuthorizations, authorizationKey(authorization)) === undefined;
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
  const chain: AttemptChain = frozen({ tag: "RetryOf", authorization });
  const prepared: PreparedAttempt = frozen({ input, chain });
  const next = appendedState(state, frozen({
    input,
    chain,
    disposition: frozen({ tag: "Prepared" }),
    firstDelivery: null,
    late: arr([]),
  }));
  return frozen({ tag: "Prepared", state: next, prepared });
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

export type HostRecordObservation = "Undelivered" | "DeliveryOrdinal";

export type HostRecordDecision = ErasureDecision<AttemptIdentity, never, never, never, HostRecordObservation>;

export function hostAwaits(state: NetworkState, key: AttemptIdentity): boolean {
  const record = findRecord(state, key);
  return record !== undefined && record.disposition.tag !== "Settled";
}

export function hostSettled(state: NetworkState, key: AttemptIdentity): boolean {
  const record = findRecord(state, key);
  return record !== undefined && record.disposition.tag === "Settled";
}

export function releaseHostRecord(
  state: NetworkState,
  running: (key: AttemptIdentity) => boolean,
  key: AttemptIdentity,
): HostRecordDecision {
  return judgeErasureBy<AttemptIdentity, never, never, never, HostRecordObservation>(
    {
      target: key,
      targetBasis: null,
      removedObservations: ["Undelivered", "DeliveryOrdinal"],
      preservedObservations: [],
    },
    {
      activeBasis: () => false,
      branchRoot: () => false,
      futureUse: (target) => hostAwaits(state, target),
      outstandingEffect: (target) => running(target),
      outstandingSignal: () => false,
    },
    { kind: "irrecoverable" },
    { sameObservation: (left, right) => left === right },
  );
}
