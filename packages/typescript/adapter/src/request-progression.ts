// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { mapEmpty, setEmpty, setMin, setToArray, vecEmpty, vecGet, vecToArray, type PIntSet } from "./persistent.js";
import { type SnapshotFields, type SnapshotState, appended, positionOf, replaceAt, sealed, stateOf, zeroTotals } from "./progression-state.js";

export type RequestPolicy = "LatestWins" | "Fifo" | "AllExecute";
export type RequestPhase = "Pending" | "Preparing" | "Publishing" | "Published" | "Superseded" | "Cancelled" | "Failed";
export type RequestEffectClass = "Pure" | "OrderedEffect";

export interface RequestIdentity { readonly kind: string; readonly provenance: string; readonly revision: bigint; }
export interface RequestFootprint { readonly reads: readonly string[]; readonly writes: readonly string[]; readonly effectClass: RequestEffectClass; }
export interface ResourceDemand { readonly pending: bigint; readonly inFlight: bigint; readonly concurrent: bigint; }
export interface ConfiguredSafetyLimit { readonly resource: string; readonly maximum: bigint; }
export interface ResourceBudget { readonly pendingMaximum: ConfiguredSafetyLimit; readonly inFlightMaximum: ConfiguredSafetyLimit; readonly concurrentMaximum: ConfiguredSafetyLimit; }
export interface EvidenceVersion { readonly identifier: string; readonly digest: string; readonly artifactPath: string; }
export type PermissionDenial = { readonly tag: "denial"; readonly detail: string };
export function permissionDenial(detail: string): PermissionDenial { return frozen({ tag: "denial", detail }); }
export type MeaningPermission =
  | { readonly tag: "permitted"; readonly identity: RequestIdentity; readonly evidence: readonly EvidenceVersion[] }
  | { readonly tag: "ordered"; readonly identity: RequestIdentity; readonly evidence: readonly EvidenceVersion[] }
  | { readonly tag: "denied"; readonly identity: RequestIdentity; readonly reason: PermissionDenial };
export interface ExecutionHandle { readonly value: string; }
export type CostSelection =
  | { readonly tag: "executeNow"; readonly identity: RequestIdentity; readonly evidence: EvidenceVersion; readonly cost: bigint }
  | { readonly tag: "remainPending"; readonly identity: RequestIdentity; readonly evidence: EvidenceVersion; readonly cost: bigint };
export interface RequestEntry { readonly identity: RequestIdentity; readonly footprint: RequestFootprint; readonly demand: ResourceDemand; readonly phase: RequestPhase; readonly meaningPermission: MeaningPermission; readonly costSelection: CostSelection | null; readonly executionHandle: ExecutionHandle | null; }
declare const snapshotBrand: unique symbol;
export interface RequestProgressionSnapshot { readonly [snapshotBrand]: true; }
export interface RequestInput { readonly identity: RequestIdentity; readonly footprint: RequestFootprint; readonly demand: ResourceDemand; readonly permission: MeaningPermission; }
export interface Accepted { readonly identity: RequestIdentity; }
export type AdapterCommand =
  | { readonly tag: "startCommand"; readonly identity: RequestIdentity; readonly footprint: RequestFootprint }
  | { readonly tag: "cancelCommand"; readonly identity: RequestIdentity; readonly handle: ExecutionHandle };
export interface Starting { readonly identity: RequestIdentity; readonly command: AdapterCommand; }
export interface Running { readonly identity: RequestIdentity; readonly handle: ExecutionHandle; }
export type AdapterSignal<Result> =
  | { readonly tag: "started"; readonly identity: RequestIdentity; readonly handle: ExecutionHandle }
  | { readonly tag: "completed"; readonly identity: RequestIdentity; readonly handle: ExecutionHandle; readonly value: Result }
  | { readonly tag: "cancelledAtAdapter"; readonly identity: RequestIdentity; readonly handle: ExecutionHandle };
export type AdapterFailure =
  | { readonly tag: "startAdapterFailure"; readonly identity: RequestIdentity; readonly detail: string }
  | { readonly tag: "completionAdapterFailure"; readonly identity: RequestIdentity; readonly handle: ExecutionHandle; readonly detail: string }
  | { readonly tag: "cancellationAdapterFailure"; readonly identity: RequestIdentity; readonly handle: ExecutionHandle; readonly detail: string };
export type AdapterResult<Signal, Failure> = { readonly tag: "appliedSignal"; readonly signal: Signal } | { readonly tag: "adapterFailed"; readonly failure: Failure };
export type SubmitFailure = { readonly tag: "duplicateIdentity"; readonly identity: RequestIdentity } | { readonly tag: "pendingLimitExceeded"; readonly demand: ResourceDemand; readonly budget: ResourceBudget };
export type SubmitResult = { readonly tag: "accepted"; readonly snapshot: RequestProgressionSnapshot; readonly accepted: Accepted } | { readonly tag: "submitRejected"; readonly snapshot: RequestProgressionSnapshot; readonly failure: SubmitFailure };
export type StartDecisionFailure =
  | { readonly tag: "unknownRequest"; readonly identity: RequestIdentity }
  | { readonly tag: "requestNotPending"; readonly identity: RequestIdentity }
  | { readonly tag: "policyOrderBlocked"; readonly identity: RequestIdentity }
  | { readonly tag: "permissionDenied"; readonly identity: RequestIdentity; readonly reason: PermissionDenial }
  | { readonly tag: "permissionIdentityMismatch"; readonly identity: RequestIdentity; readonly other: RequestIdentity }
  | { readonly tag: "permissionNotOrdered"; readonly identity: RequestIdentity }
  | { readonly tag: "costSelectionIdentityMismatch"; readonly identity: RequestIdentity; readonly other: RequestIdentity }
  | { readonly tag: "inFlightLimitExceeded"; readonly demand: ResourceDemand; readonly budget: ResourceBudget }
  | { readonly tag: "concurrentLimitExceeded"; readonly demand: ResourceDemand; readonly budget: ResourceBudget };
export type StartDecisionResult =
  | { readonly tag: "execute"; readonly snapshot: RequestProgressionSnapshot; readonly starting: Starting; readonly command: AdapterCommand }
  | { readonly tag: "deferred"; readonly snapshot: RequestProgressionSnapshot; readonly accepted: Accepted }
  | { readonly tag: "rejected"; readonly snapshot: RequestProgressionSnapshot; readonly failure: StartDecisionFailure };
export type StartObservationFailure =
  | { readonly tag: "unknownRequest"; readonly identity: RequestIdentity }
  | { readonly tag: "requestNotStarting"; readonly identity: RequestIdentity }
  | { readonly tag: "startIdentityMismatch"; readonly identity: RequestIdentity; readonly other: RequestIdentity }
  | { readonly tag: "startSignalMismatch"; readonly identity: RequestIdentity }
  | { readonly tag: "startAdapterFailureObserved"; readonly identity: RequestIdentity; readonly detail: string };
export type StartObservationResult = { readonly tag: "publishing"; readonly snapshot: RequestProgressionSnapshot; readonly running: Running } | { readonly tag: "failed"; readonly snapshot: RequestProgressionSnapshot; readonly failure: StartObservationFailure };
export type CompletionObservationFailure =
  | { readonly tag: "unknownCompletion"; readonly identity: RequestIdentity }
  | { readonly tag: "completionNotRunning"; readonly identity: RequestIdentity }
  | { readonly tag: "handleMismatch"; readonly identity: RequestIdentity }
  | { readonly tag: "completionIdentityMismatch"; readonly identity: RequestIdentity; readonly other: RequestIdentity }
  | { readonly tag: "completionSignalMismatch"; readonly identity: RequestIdentity }
  | { readonly tag: "completionAdapterFailureObserved"; readonly identity: RequestIdentity; readonly detail: string }
  | { readonly tag: "cancellationAdapterFailureObserved"; readonly identity: RequestIdentity; readonly detail: string };
export type CompletionObservationResult<Result> =
  | { readonly tag: "applied"; readonly snapshot: RequestProgressionSnapshot; readonly identity: RequestIdentity; readonly value: Result }
  | { readonly tag: "superseded"; readonly snapshot: RequestProgressionSnapshot; readonly identity: RequestIdentity }
  | { readonly tag: "cancelled"; readonly snapshot: RequestProgressionSnapshot; readonly identity: RequestIdentity }
  | { readonly tag: "failed"; readonly snapshot: RequestProgressionSnapshot; readonly failure: CompletionObservationFailure };
export type CancelFailure = { readonly tag: "unknownRequest"; readonly identity: RequestIdentity } | { readonly tag: "requestAlreadyTerminal"; readonly identity: RequestIdentity } | { readonly tag: "missingExecutionHandle"; readonly identity: RequestIdentity };
export type CancelDecisionResult =
  | { readonly tag: "cancelled"; readonly snapshot: RequestProgressionSnapshot; readonly identity: RequestIdentity }
  | { readonly tag: "cancelCommand"; readonly snapshot: RequestProgressionSnapshot; readonly running: Running; readonly command: AdapterCommand }
  | { readonly tag: "rejected"; readonly snapshot: RequestProgressionSnapshot; readonly failure: CancelFailure };

function frozen<T>(value: T): T { return Object.freeze(value); }
function sameIdentity(a: RequestIdentity, b: RequestIdentity): boolean { return a.kind === b.kind && a.provenance === b.provenance && a.revision === b.revision; }
function sameHandle(a: ExecutionHandle, b: ExecutionHandle): boolean { return a.value === b.value; }

export type SnapshotFailure = { readonly tag: "duplicateIdentity"; readonly identity: RequestIdentity };
export type SnapshotResult = { readonly tag: "snapshot"; readonly snapshot: RequestProgressionSnapshot } | { readonly tag: "snapshotRejected"; readonly failure: SnapshotFailure };

export function snapshotOf(policy: RequestPolicy, budget: ResourceBudget, currentIdentity: RequestIdentity | null, entries: readonly RequestEntry[], revision: bigint): SnapshotResult {
  let state: SnapshotFields = { policy, budget, currentIdentity, entries: vecEmpty(), positions: mapEmpty(), pendingPositions: setEmpty, orderedPendingPositions: setEmpty, totals: zeroTotals, revision };
  for (const entry of entries) {
    if (positionOf(state, entry.identity) !== undefined) return frozen({ tag: "snapshotRejected", failure: frozen({ tag: "duplicateIdentity", identity: entry.identity }) });
    state = appended(state, entry);
  }
  return frozen({ tag: "snapshot", snapshot: sealed(state) });
}

export function empty(policy: RequestPolicy, budget: ResourceBudget): RequestProgressionSnapshot { return sealed({ policy, budget, currentIdentity: null, entries: vecEmpty(), positions: mapEmpty(), pendingPositions: setEmpty, orderedPendingPositions: setEmpty, totals: zeroTotals, revision: 0n }); }
export function progressionPolicy(snapshot: RequestProgressionSnapshot): RequestPolicy { return stateOf(snapshot).policy; }
export function progressionBudget(snapshot: RequestProgressionSnapshot): ResourceBudget { return stateOf(snapshot).budget; }
export function progressionCurrentIdentity(snapshot: RequestProgressionSnapshot): RequestIdentity | null { return stateOf(snapshot).currentIdentity; }
export function progressionRevision(snapshot: RequestProgressionSnapshot): bigint { return stateOf(snapshot).revision; }
export function progressionEntries(snapshot: RequestProgressionSnapshot): readonly RequestEntry[] { return frozen(vecToArray(stateOf(snapshot).entries)); }
export function findRequest(snapshot: RequestProgressionSnapshot, identity: RequestIdentity): RequestEntry | undefined { const state = stateOf(snapshot); const position = positionOf(state, identity); return position === undefined ? undefined : vecGet(state.entries, position); }
export function withProgressionBudget(snapshot: RequestProgressionSnapshot, budget: ResourceBudget): RequestProgressionSnapshot { return sealed({ ...stateOf(snapshot), budget }); }

export function derivePending(snapshot: RequestProgressionSnapshot): ResourceDemand { return stateOf(snapshot).totals.pending; }
export function deriveInFlight(snapshot: RequestProgressionSnapshot): ResourceDemand { return stateOf(snapshot).totals.inFlight; }
export function deriveConcurrent(snapshot: RequestProgressionSnapshot): ResourceDemand { return stateOf(snapshot).totals.concurrent; }

function earliestPending(state: SnapshotFields, positions: PIntSet): RequestEntry | undefined { const position = setMin(positions); return position === undefined ? undefined : vecGet(state.entries, position); }
function policyOrderAllowed(state: SnapshotFields, identity: RequestIdentity): boolean { if (state.policy === "LatestWins") return state.currentIdentity !== null && sameIdentity(state.currentIdentity, identity); if (state.policy === "AllExecute") return true; const earliest = earliestPending(state, state.pendingPositions); return earliest !== undefined && sameIdentity(earliest.identity, identity); }
function orderedEffectAllowed(state: SnapshotFields, identity: RequestIdentity, entry: RequestEntry): boolean { if (entry.footprint.effectClass !== "OrderedEffect") return true; const earliest = earliestPending(state, state.orderedPendingPositions); return earliest === undefined || sameIdentity(earliest.identity, identity); }
function advanced(state: SnapshotFields, position: number, entry: RequestEntry): RequestProgressionSnapshot { return sealed({ ...replaceAt(state, position, entry), revision: state.revision + 1n }); }
function failedStart(state: SnapshotFields, position: number, entry: RequestEntry, failure: StartObservationFailure): StartObservationResult { return frozen({ tag: "failed", snapshot: advanced(state, position, frozen({ ...entry, phase: "Failed" })), failure: frozen(failure) }); }

export function submit(snapshot: RequestProgressionSnapshot, request: RequestInput): SubmitResult {
  const state = stateOf(snapshot);
  if (positionOf(state, request.identity) !== undefined) return frozen({ tag: "submitRejected", snapshot, failure: frozen({ tag: "duplicateIdentity", identity: request.identity }) });
  if (state.totals.pending.pending + request.demand.pending > state.budget.pendingMaximum.maximum) return frozen({ tag: "submitRejected", snapshot, failure: frozen({ tag: "pendingLimitExceeded", demand: request.demand, budget: state.budget }) });
  const entry: RequestEntry = frozen({ identity: request.identity, footprint: request.footprint, demand: request.demand, phase: "Pending", meaningPermission: request.permission, costSelection: null, executionHandle: null });
  let next = state;
  if (state.policy === "LatestWins") {
    for (const position of setToArray(state.pendingPositions)) next = replaceAt(next, position, frozen({ ...vecGet(next.entries, position), phase: "Superseded" as const }));
  }
  next = { ...appended(next, entry), currentIdentity: request.identity, revision: state.revision + 1n };
  return frozen({ tag: "accepted", snapshot: sealed(next), accepted: frozen({ identity: request.identity }) });
}

export function decideStart(snapshot: RequestProgressionSnapshot, accepted: Accepted, selection: CostSelection): StartDecisionResult {
  const state = stateOf(snapshot);
  const position = positionOf(state, accepted.identity);
  if (position === undefined) return frozen({ tag: "rejected", snapshot, failure: frozen({ tag: "unknownRequest", identity: accepted.identity }) });
  const entry = vecGet(state.entries, position);
  if (entry.phase !== "Pending") return frozen({ tag: "rejected", snapshot, failure: frozen({ tag: "requestNotPending", identity: accepted.identity }) });
  if (!policyOrderAllowed(state, accepted.identity) || !orderedEffectAllowed(state, accepted.identity, entry)) return frozen({ tag: "rejected", snapshot, failure: frozen({ tag: "policyOrderBlocked", identity: accepted.identity }) });
  const permission = entry.meaningPermission;
  if (permission.tag === "denied") return frozen({ tag: "rejected", snapshot, failure: frozen({ tag: "permissionDenied", identity: accepted.identity, reason: permission.reason }) });
  if (!sameIdentity(permission.identity, accepted.identity)) return frozen({ tag: "rejected", snapshot, failure: frozen({ tag: "permissionIdentityMismatch", identity: accepted.identity, other: permission.identity }) });
  if (permission.tag === "permitted" && entry.footprint.effectClass === "OrderedEffect") return frozen({ tag: "rejected", snapshot, failure: frozen({ tag: "permissionNotOrdered", identity: accepted.identity }) });
  if (!sameIdentity(selection.identity, accepted.identity)) return frozen({ tag: "rejected", snapshot, failure: frozen({ tag: "costSelectionIdentityMismatch", identity: accepted.identity, other: selection.identity }) });
  if (selection.tag === "remainPending") return frozen({ tag: "deferred", snapshot: sealed(replaceAt(state, position, frozen({ ...entry, costSelection: selection }))), accepted });
  if (state.totals.inFlight.inFlight + entry.demand.inFlight > state.budget.inFlightMaximum.maximum) return frozen({ tag: "rejected", snapshot, failure: frozen({ tag: "inFlightLimitExceeded", demand: entry.demand, budget: state.budget }) });
  if (state.totals.concurrent.concurrent + entry.demand.concurrent > state.budget.concurrentMaximum.maximum) return frozen({ tag: "rejected", snapshot, failure: frozen({ tag: "concurrentLimitExceeded", demand: entry.demand, budget: state.budget }) });
  const command: AdapterCommand = frozen({ tag: "startCommand", identity: accepted.identity, footprint: entry.footprint });
  const next = advanced(state, position, frozen({ ...entry, phase: "Preparing", costSelection: selection }));
  return frozen({ tag: "execute", snapshot: next, starting: frozen({ identity: accepted.identity, command }), command });
}

export function applyStartObservation<Result>(snapshot: RequestProgressionSnapshot, starting: Starting, observed: AdapterResult<AdapterSignal<Result>, AdapterFailure>): StartObservationResult {
  const state = stateOf(snapshot);
  const position = positionOf(state, starting.identity);
  if (position === undefined) return frozen({ tag: "failed", snapshot, failure: frozen({ tag: "unknownRequest", identity: starting.identity }) });
  const entry = vecGet(state.entries, position);
  if (entry.phase !== "Preparing") return frozen({ tag: "failed", snapshot, failure: frozen({ tag: "requestNotStarting", identity: starting.identity }) });
  if (observed.tag === "appliedSignal" && observed.signal.tag === "started") {
    if (!sameIdentity(observed.signal.identity, starting.identity)) return failedStart(state, position, entry, { tag: "startIdentityMismatch", identity: starting.identity, other: observed.signal.identity });
    const handle = observed.signal.handle;
    return frozen({ tag: "publishing", snapshot: advanced(state, position, frozen({ ...entry, phase: "Publishing", executionHandle: handle })), running: frozen({ identity: starting.identity, handle }) });
  }
  if (observed.tag === "adapterFailed" && observed.failure.tag === "startAdapterFailure") {
    return sameIdentity(observed.failure.identity, starting.identity)
      ? failedStart(state, position, entry, { tag: "startAdapterFailureObserved", identity: starting.identity, detail: observed.failure.detail })
      : failedStart(state, position, entry, { tag: "startIdentityMismatch", identity: starting.identity, other: observed.failure.identity });
  }
  return failedStart(state, position, entry, { tag: "startSignalMismatch", identity: starting.identity });
}

export function applyCompletionObservation<Result>(snapshot: RequestProgressionSnapshot, running: Running, observed: AdapterResult<AdapterSignal<Result>, AdapterFailure>): CompletionObservationResult<Result> {
  const state = stateOf(snapshot);
  const position = positionOf(state, running.identity);
  const failure = (f: CompletionObservationFailure): CompletionObservationResult<Result> => frozen({ tag: "failed", snapshot, failure: frozen(f) });
  if (position === undefined) return failure({ tag: "unknownCompletion", identity: running.identity });
  const entry = vecGet(state.entries, position);
  if (entry.phase !== "Publishing") return failure({ tag: "completionNotRunning", identity: running.identity });
  if (entry.executionHandle === null || !sameHandle(entry.executionHandle, running.handle)) return failure({ tag: "handleMismatch", identity: running.identity });
  if (observed.tag === "appliedSignal") {
    const signal = observed.signal;
    if (signal.tag === "started") return failure({ tag: "completionSignalMismatch", identity: running.identity });
    if (!sameIdentity(signal.identity, running.identity)) return failure({ tag: "completionIdentityMismatch", identity: running.identity, other: signal.identity });
    if (!sameHandle(signal.handle, running.handle)) return failure({ tag: "handleMismatch", identity: running.identity });
    if (signal.tag === "cancelledAtAdapter") return frozen({ tag: "cancelled", snapshot: advanced(state, position, frozen({ ...entry, phase: "Cancelled" })), identity: running.identity });
    if (state.policy === "LatestWins" && (state.currentIdentity === null || !sameIdentity(state.currentIdentity, running.identity))) return frozen({ tag: "superseded", snapshot: sealed(replaceAt(state, position, frozen({ ...entry, phase: "Superseded" }))), identity: running.identity });
    return frozen({ tag: "applied", snapshot: advanced(state, position, frozen({ ...entry, phase: "Published" })), identity: running.identity, value: signal.value });
  }
  const adapterFailure = observed.failure;
  if (adapterFailure.tag === "startAdapterFailure") return failure({ tag: "completionSignalMismatch", identity: running.identity });
  if (!sameIdentity(adapterFailure.identity, running.identity)) return failure({ tag: "completionIdentityMismatch", identity: running.identity, other: adapterFailure.identity });
  if (!sameHandle(adapterFailure.handle, running.handle)) return failure({ tag: "handleMismatch", identity: running.identity });
  return frozen({ tag: "failed", snapshot: advanced(state, position, frozen({ ...entry, phase: "Failed" })), failure: frozen(adapterFailure.tag === "completionAdapterFailure" ? { tag: "completionAdapterFailureObserved", identity: running.identity, detail: adapterFailure.detail } : { tag: "cancellationAdapterFailureObserved", identity: running.identity, detail: adapterFailure.detail }) });
}

export function decideCancel(snapshot: RequestProgressionSnapshot, identity: RequestIdentity): CancelDecisionResult {
  const state = stateOf(snapshot);
  const position = positionOf(state, identity);
  if (position === undefined) return frozen({ tag: "rejected", snapshot, failure: frozen({ tag: "unknownRequest", identity }) });
  const entry = vecGet(state.entries, position);
  if (entry.phase === "Pending") return frozen({ tag: "cancelled", snapshot: advanced(state, position, frozen({ ...entry, phase: "Cancelled" })), identity });
  if (entry.phase === "Publishing") {
    if (entry.executionHandle === null) return frozen({ tag: "rejected", snapshot, failure: frozen({ tag: "missingExecutionHandle", identity }) });
    const running = frozen({ identity, handle: entry.executionHandle });
    return frozen({ tag: "cancelCommand", snapshot, running, command: frozen({ tag: "cancelCommand", identity, handle: entry.executionHandle }) });
  }
  return frozen({ tag: "rejected", snapshot, failure: frozen({ tag: entry.phase === "Preparing" ? "missingExecutionHandle" : "requestAlreadyTerminal", identity }) });
}
