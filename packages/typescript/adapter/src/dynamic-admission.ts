// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT


import { judgeErasureBy } from "neco-quotient-retention";
import type { DematerializeWitness, MissingInput, RetentionReason } from "neco-quotient-retention";
import { applied, rejected, type Outcome } from "./core.js";
import {
  deriveConcurrent,
  deriveInFlight,
  derivePending,
  decideStart,
  submit,
  type Accepted,
  type CostSelection,
  type ExecutionHandle,
  type PermissionDenial,
  type RequestEntry,
  type RequestIdentity,
  type RequestInput,
  type RequestPhase,
  type RequestProgressionSnapshot,
  type ResourceBudget,
  type StartDecisionFailure,
  type StartDecisionResult,
  type SubmitFailure,
  findRequest,
  progressionRevision,
  withProgressionBudget,
} from "./request-progression.js";
import { identityKey, withProgressionEntry } from "./progression-state.js";

export interface EnvironmentSpecification {
  readonly maxObservationAge: bigint;
}

export interface CapacityObservation {
  readonly observed: ResourceBudget;
  readonly observedAt: bigint;
}

export type SignalKind = "PendingCompletion" | "PendingCancellation";

export interface AdmissionSignal {
  readonly identity: RequestIdentity;
  readonly handle: ExecutionHandle;
  readonly kind: SignalKind;
}

export interface AdmissionProvenance {
  readonly futureUses: readonly RequestIdentity[];
  readonly outstandingSignals: readonly AdmissionSignal[];
}

declare const admissionStateBrand: unique symbol;
export interface DynamicAdmissionState {
  readonly [admissionStateBrand]: true;
}

interface AdmissionStateFields {
  readonly progression: RequestProgressionSnapshot;
  readonly configuredSafetyLimit: ResourceBudget;
  readonly provenance: AdmissionProvenance;
  readonly futureUses: ReadonlySet<string>;
  readonly signalled: ReadonlySet<string>;
}

type AdmissionStateRecord = AdmissionStateFields & DynamicAdmissionState;

function admissionFieldsOf(state: DynamicAdmissionState): AdmissionStateFields {
  return state as AdmissionStateRecord;
}

function admissionSealed(fields: AdmissionStateFields): DynamicAdmissionState {
  return Object.freeze(fields) as AdmissionStateRecord;
}

export function admissionStateOf(
  progression: RequestProgressionSnapshot,
  configuredSafetyLimit: ResourceBudget,
  provenance: AdmissionProvenance
): DynamicAdmissionState {
  return admissionSealed({
    progression,
    configuredSafetyLimit,
    provenance,
    futureUses: new Set(provenance.futureUses.map(identityKey)),
    signalled: new Set(provenance.outstandingSignals.map((signal) => identityKey(signal.identity))),
  });
}

export function admissionStateProgression(state: DynamicAdmissionState): RequestProgressionSnapshot {
  return admissionFieldsOf(state).progression;
}

export function admissionStateConfiguredSafetyLimit(state: DynamicAdmissionState): ResourceBudget {
  return admissionFieldsOf(state).configuredSafetyLimit;
}

export function admissionStateProvenance(state: DynamicAdmissionState): AdmissionProvenance {
  return admissionFieldsOf(state).provenance;
}

function withProgression(state: DynamicAdmissionState, progression: RequestProgressionSnapshot): DynamicAdmissionState {
  return admissionSealed({ ...admissionFieldsOf(state), progression });
}

export interface DynamicAdmissionInput {
  readonly state: DynamicAdmissionState;
  readonly request: RequestInput;
  readonly environmentSpecification: EnvironmentSpecification;
  readonly capacityObservation: CapacityObservation;
  readonly observedAt: bigint;
  readonly start: CostSelection | null;
}

export type EffectiveBudget = ResourceBudget;

export type ProvenanceObservation = "Footprint" | "Evidence";

export type ErasureWitness = DematerializeWitness<RequestIdentity, never, never, ProvenanceObservation>;

export type ErasureRetention = RetentionReason<RequestIdentity, never, ProvenanceObservation>;

export type DynamicAdmissionFailure =
  | { readonly tag: "CapacityObservationUnavailable"; readonly age: bigint; readonly maxAge: bigint }
  | { readonly tag: "ResourceCoordinateMismatch"; readonly configuredResource: string; readonly observedResource: string }
  | { readonly tag: "ConfiguredSafetyLimitExceeded"; readonly resource: string; readonly occupied: bigint; readonly allowed: bigint }
  | { readonly tag: "MeaningDenied"; readonly identity: RequestIdentity; readonly reason: PermissionDenial }
  | { readonly tag: "PermissionIdentityMismatch"; readonly requestIdentity: RequestIdentity; readonly permissionIdentity: RequestIdentity }
  | { readonly tag: "AdapterBindingUnavailable"; readonly identity: RequestIdentity }
  | { readonly tag: "BindingSelectionMismatch"; readonly identity: RequestIdentity }
  | { readonly tag: "ProgressionSubmitFailure"; readonly failure: SubmitFailure }
  | { readonly tag: "ProgressionStartFailure"; readonly failure: StartDecisionFailure }
  | { readonly tag: "ProvenanceRetentionRequired"; readonly identity: RequestIdentity; readonly reasons: readonly ErasureRetention[] }
  | { readonly tag: "ErasureInputIncomplete"; readonly identity: RequestIdentity; readonly missing: MissingInput }
  | { readonly tag: "UnknownRequest"; readonly identity: RequestIdentity }
  | { readonly tag: "RequestNotTerminal"; readonly identity: RequestIdentity };

export type AdmissionDecision =
  | { readonly tag: "Submitted"; readonly state: DynamicAdmissionState; readonly accepted: Accepted }
  | { readonly tag: "Started"; readonly state: DynamicAdmissionState; readonly result: StartDecisionResult }
  | { readonly tag: "Coalesced"; readonly state: DynamicAdmissionState; readonly identity: RequestIdentity };

export interface FutureUseSet {
  readonly identities: readonly RequestIdentity[];
}

export interface OutstandingSignalSet {
  readonly signals: readonly AdmissionSignal[];
}

export type CoalescingWitness =
  | { readonly tag: "Coalesced"; readonly identity: RequestIdentity }
  | { readonly tag: "NotCoalesced"; readonly reason: string };

export interface DynamicAdmissionResult {
  readonly effectiveBudget: EffectiveBudget;
  readonly admissionDecision: AdmissionDecision;
  readonly futureUseSet: FutureUseSet;
  readonly outstandingSignalSet: OutstandingSignalSet;
  readonly provenanceErasureWitness: ErasureWitness | null;
  readonly coalescingWitness: CoalescingWitness;
}

function frozen<T>(value: T): T {
  return Object.freeze(value);
}

function sameIdentity(a: RequestIdentity, b: RequestIdentity): boolean {
  return a.kind === b.kind && a.provenance === b.provenance && a.revision === b.revision;
}

function sameFootprint(a: RequestEntry["footprint"], b: RequestEntry["footprint"]): boolean {
  return (
    a.effectClass === b.effectClass &&
    a.reads.length === b.reads.length &&
    a.reads.every((v, i) => v === b.reads[i]) &&
    a.writes.length === b.writes.length &&
    a.writes.every((v, i) => v === b.writes[i])
  );
}

function samePermission(a: RequestEntry["meaningPermission"], b: RequestEntry["meaningPermission"]): boolean {
  if (a.tag !== b.tag || !sameIdentity(a.identity, b.identity)) return false;
  if (a.tag === "denied" && b.tag === "denied") return a.reason.detail === b.reason.detail;
  if (a.tag !== "denied" && b.tag !== "denied") {
    return a.evidence.length === b.evidence.length && a.evidence.every(
      (ev, i) => ev.identifier === b.evidence[i]?.identifier && ev.digest === b.evidence[i]?.digest && ev.artifactPath === b.evidence[i]?.artifactPath
    );
  }
  return false;
}

function minLimit(a: ResourceBudget["pendingMaximum"], b: ResourceBudget["pendingMaximum"]) {
  return frozen({ resource: a.resource, maximum: a.maximum < b.maximum ? a.maximum : b.maximum });
}

function effectiveBudgetOf(configured: ResourceBudget, observed: ResourceBudget): EffectiveBudget {
  return frozen({
    pendingMaximum: minLimit(configured.pendingMaximum, observed.pendingMaximum),
    inFlightMaximum: minLimit(configured.inFlightMaximum, observed.inFlightMaximum),
    concurrentMaximum: minLimit(configured.concurrentMaximum, observed.concurrentMaximum),
  });
}

function resourceCoordinateMismatch(
  configured: ResourceBudget,
  observed: ResourceBudget
): readonly [string, string] | null {
  if (configured.pendingMaximum.resource !== observed.pendingMaximum.resource) {
    return [configured.pendingMaximum.resource, observed.pendingMaximum.resource];
  }
  if (configured.inFlightMaximum.resource !== observed.inFlightMaximum.resource) {
    return [configured.inFlightMaximum.resource, observed.inFlightMaximum.resource];
  }
  if (configured.concurrentMaximum.resource !== observed.concurrentMaximum.resource) {
    return [configured.concurrentMaximum.resource, observed.concurrentMaximum.resource];
  }
  return null;
}

function observationAge(input: DynamicAdmissionInput): bigint {
  if (input.observedAt < input.capacityObservation.observedAt) {
    return (
      input.capacityObservation.observedAt -
      input.observedAt +
      input.environmentSpecification.maxObservationAge +
      1n
    );
  }
  return input.observedAt - input.capacityObservation.observedAt;
}

function permissionCheck(request: RequestInput): DynamicAdmissionFailure | null {
  const permission = request.permission;
  if (permission.tag === "denied") {
    return sameIdentity(permission.identity, request.identity)
      ? frozen({ tag: "MeaningDenied", identity: permission.identity, reason: permission.reason })
      : frozen({ tag: "PermissionIdentityMismatch", requestIdentity: request.identity, permissionIdentity: permission.identity });
  }
  return sameIdentity(permission.identity, request.identity)
    ? null
    : frozen({ tag: "PermissionIdentityMismatch", requestIdentity: request.identity, permissionIdentity: permission.identity });
}

function samePendingEntry(entry: RequestEntry, request: RequestInput): boolean {
  return (
    entry.phase === "Pending" &&
    sameIdentity(entry.identity, request.identity) &&
    sameFootprint(entry.footprint, request.footprint) &&
    entry.demand.pending === request.demand.pending &&
    entry.demand.inFlight === request.demand.inFlight &&
    entry.demand.concurrent === request.demand.concurrent &&
    samePermission(entry.meaningPermission, request.permission)
  );
}

function matchingPendingDuplicate(
  snapshot: RequestProgressionSnapshot,
  request: RequestInput
): RequestEntry | undefined {
  const entry = findRequest(snapshot, request.identity);
  return entry !== undefined && samePendingEntry(entry, request) ? entry : undefined;
}

function isExecuteNow(selection: CostSelection): boolean {
  return selection.tag === "executeNow";
}

function toFutureUseSet(provenance: AdmissionProvenance): FutureUseSet {
  return frozen({ identities: provenance.futureUses });
}

function toOutstandingSignalSet(provenance: AdmissionProvenance): OutstandingSignalSet {
  return frozen({ signals: provenance.outstandingSignals });
}

const terminalPhases: readonly RequestPhase[] = ["Published", "Superseded", "Cancelled", "Failed"];

function isTerminalPhase(phase: RequestPhase): boolean {
  return terminalPhases.includes(phase);
}

function eraseMeaningPermissionEvidence(
  permission: RequestEntry["meaningPermission"]
): RequestEntry["meaningPermission"] {
  if (permission.tag === "denied") return permission;
  return permission.tag === "permitted"
    ? frozen({ tag: "permitted", identity: permission.identity, evidence: frozen([]) })
    : frozen({ tag: "ordered", identity: permission.identity, evidence: frozen([]) });
}

function eraseEntryProvenance(entry: RequestEntry): RequestEntry {
  return frozen({
    ...entry,
    footprint: frozen({ ...entry.footprint, reads: frozen([]), writes: frozen([]) }),
    meaningPermission: eraseMeaningPermissionEvidence(entry.meaningPermission),
  });
}

export function elideAdmissionProvenance(
  state: DynamicAdmissionState,
  identity: RequestIdentity
): Outcome<readonly [DynamicAdmissionState, ErasureWitness], DynamicAdmissionFailure, never, never> {
  const fields = admissionFieldsOf(state);
  const entry = findRequest(fields.progression, identity);
  if (entry === undefined) {
    return rejected(frozen({ tag: "UnknownRequest", identity }));
  }
  if (!isTerminalPhase(entry.phase)) {
    return rejected(frozen({ tag: "RequestNotTerminal", identity }));
  }
  const decision = judgeErasureBy<RequestIdentity, never, never, never, ProvenanceObservation>(
    {
      target: identity,
      targetBasis: null,
      removedObservations: ["Footprint", "Evidence"],
      preservedObservations: [],
    },
    {
      activeBasis: () => false,
      branchRoot: () => false,
      futureUse: (target) => fields.futureUses.has(identityKey(target)),
      outstandingEffect: () => false,
      outstandingSignal: (target) => fields.signalled.has(identityKey(target)),
    },
    { kind: "irrecoverable" },
    { sameObservation: (left, right) => left === right }
  );
  switch (decision.kind) {
    case "dematerialize": {
      const newProgression = withProgressionEntry(fields.progression, eraseEntryProvenance(entry));
      return applied([withProgression(state, newProgression), decision.witness] as const);
    }
    case "retain":
      return rejected(frozen({ tag: "ProvenanceRetentionRequired", identity, reasons: decision.reasons }));
    case "rejected":
      return rejected(frozen({ tag: "ErasureInputIncomplete", identity, missing: decision.missing }));
  }
}

export function admitDynamicRequest(
  input: DynamicAdmissionInput
): Outcome<DynamicAdmissionResult, DynamicAdmissionFailure, never, never> {
  const age = observationAge(input);
  if (age > input.environmentSpecification.maxObservationAge) {
    return rejected(frozen({ tag: "CapacityObservationUnavailable", age, maxAge: input.environmentSpecification.maxObservationAge }));
  }
  const mismatch = resourceCoordinateMismatch(admissionStateConfiguredSafetyLimit(input.state), input.capacityObservation.observed);
  if (mismatch !== null) {
    return rejected(frozen({ tag: "ResourceCoordinateMismatch", configuredResource: mismatch[0], observedResource: mismatch[1] }));
  }
  const permissionFailure = permissionCheck(input.request);
  if (permissionFailure !== null) {
    return rejected(permissionFailure);
  }

  const effectiveBudget = effectiveBudgetOf(admissionStateConfiguredSafetyLimit(input.state), input.capacityObservation.observed);
  const snapshot = admissionStateProgression(input.state);
  const provenance = admissionStateProvenance(input.state);
  const duplicate = matchingPendingDuplicate(snapshot, input.request);

  if (duplicate !== undefined) {
    const newSelection = input.start;
    const entrySelection = duplicate.costSelection;
    if (entrySelection === null && newSelection === null) {
      return applied(
        frozen({
          effectiveBudget,
          admissionDecision: frozen({ tag: "Coalesced", state: input.state, identity: input.request.identity }),
          futureUseSet: toFutureUseSet(provenance),
          outstandingSignalSet: toOutstandingSignalSet(provenance),
          provenanceErasureWitness: null,
          coalescingWitness: frozen({ tag: "Coalesced", identity: input.request.identity }),
        })
      );
    }
    if (entrySelection !== null && newSelection !== null) {
      if (sameSelection(entrySelection, newSelection)) {
        return applied(
          frozen({
            effectiveBudget,
            admissionDecision: frozen({ tag: "Coalesced", state: input.state, identity: input.request.identity }),
            futureUseSet: toFutureUseSet(provenance),
            outstandingSignalSet: toOutstandingSignalSet(provenance),
            provenanceErasureWitness: null,
            coalescingWitness: frozen({ tag: "Coalesced", identity: input.request.identity }),
          })
        );
      }
      return rejected(frozen({ tag: "BindingSelectionMismatch", identity: input.request.identity }));
    }
    return rejected(frozen({ tag: "AdapterBindingUnavailable", identity: input.request.identity }));
  }

  const pendingOccupied = derivePending(snapshot).pending + input.request.demand.pending;
  if (pendingOccupied > effectiveBudget.pendingMaximum.maximum) {
    return rejected(
      frozen({
        tag: "ConfiguredSafetyLimitExceeded",
        resource: effectiveBudget.pendingMaximum.resource,
        occupied: pendingOccupied,
        allowed: effectiveBudget.pendingMaximum.maximum,
      })
    );
  }
  const executeNow = input.start !== null && isExecuteNow(input.start);
  const inFlightOccupied = deriveInFlight(snapshot).inFlight + input.request.demand.inFlight;
  const concurrentOccupied = deriveConcurrent(snapshot).concurrent + input.request.demand.concurrent;
  if (executeNow && inFlightOccupied > effectiveBudget.inFlightMaximum.maximum) {
    return rejected(
      frozen({
        tag: "ConfiguredSafetyLimitExceeded",
        resource: effectiveBudget.inFlightMaximum.resource,
        occupied: inFlightOccupied,
        allowed: effectiveBudget.inFlightMaximum.maximum,
      })
    );
  }
  if (executeNow && concurrentOccupied > effectiveBudget.concurrentMaximum.maximum) {
    return rejected(
      frozen({
        tag: "ConfiguredSafetyLimitExceeded",
        resource: effectiveBudget.concurrentMaximum.resource,
        occupied: concurrentOccupied,
        allowed: effectiveBudget.concurrentMaximum.maximum,
      })
    );
  }

  const budgetedSnapshot = withProgressionBudget(snapshot, effectiveBudget);
  const submitted = submit(budgetedSnapshot, input.request);
  if (submitted.tag === "submitRejected") {
    return rejected(frozen({ tag: "ProgressionSubmitFailure", failure: submitted.failure }));
  }

  if (input.start === null) {
    const newState: DynamicAdmissionState = withProgression(input.state, submitted.snapshot);
    return applied(
      frozen({
        effectiveBudget,
        admissionDecision: frozen({ tag: "Submitted", state: newState, accepted: submitted.accepted }),
        futureUseSet: toFutureUseSet(admissionStateProvenance(newState)),
        outstandingSignalSet: toOutstandingSignalSet(admissionStateProvenance(newState)),
        provenanceErasureWitness: null,
        coalescingWitness: frozen({ tag: "NotCoalesced", reason: "no duplicate pending request" }),
      })
    );
  }

  const startResult = decideStart(submitted.snapshot, submitted.accepted, input.start);
  if (startResult.tag === "rejected") {
    return rejected(frozen({ tag: "ProgressionStartFailure", failure: startResult.failure }));
  }
  const newSnapshot = startResult.snapshot;
  const newState: DynamicAdmissionState = withProgression(input.state, newSnapshot);
  return applied(
    frozen({
      effectiveBudget,
      admissionDecision: frozen({ tag: "Started", state: newState, result: startResult }),
      futureUseSet: toFutureUseSet(admissionStateProvenance(newState)),
      outstandingSignalSet: toOutstandingSignalSet(admissionStateProvenance(newState)),
      provenanceErasureWitness: null,
      coalescingWitness: frozen({ tag: "NotCoalesced", reason: "no duplicate pending request" }),
    })
  );
}

function sameSelection(a: CostSelection, b: CostSelection): boolean {
  return (
    a.tag === b.tag &&
    sameIdentity(a.identity, b.identity) &&
    a.evidence.identifier === b.evidence.identifier &&
    a.evidence.digest === b.evidence.digest &&
    a.evidence.artifactPath === b.evidence.artifactPath &&
    a.cost === b.cost
  );
}
