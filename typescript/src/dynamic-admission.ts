// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT


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
} from "./request-progression.js";

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

export interface DynamicAdmissionState {
  readonly progression: RequestProgressionSnapshot;
  readonly configuredSafetyLimit: ResourceBudget;
  readonly provenance: AdmissionProvenance;
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
  | { readonly tag: "ProvenanceRetentionRequired"; readonly identity: RequestIdentity }
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

export type ProvenanceErasureWitness =
  | { readonly tag: "Erased"; readonly identity: RequestIdentity }
  | { readonly tag: "Retained"; readonly identity: RequestIdentity; readonly reason: string };

export type CoalescingWitness =
  | { readonly tag: "Coalesced"; readonly identity: RequestIdentity }
  | { readonly tag: "NotCoalesced"; readonly reason: string };

export interface DynamicAdmissionResult {
  readonly effectiveBudget: EffectiveBudget;
  readonly admissionDecision: AdmissionDecision;
  readonly futureUseSet: FutureUseSet;
  readonly outstandingSignalSet: OutstandingSignalSet;
  readonly provenanceErasureWitness: ProvenanceErasureWitness | null;
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

function findByIdentity(entries: readonly RequestEntry[], identity: RequestIdentity): RequestEntry | undefined {
  return entries.find((entry) => sameIdentity(entry.identity, identity));
}

function replaceByIdentity(
  entries: readonly RequestEntry[],
  identity: RequestIdentity,
  replacement: RequestEntry
): readonly RequestEntry[] {
  return frozen(entries.map((entry) => (sameIdentity(entry.identity, identity) ? replacement : entry)));
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
  const entry = findByIdentity(snapshot.entries, request.identity);
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
): Outcome<readonly [DynamicAdmissionState, ProvenanceErasureWitness], DynamicAdmissionFailure, never, never> {
  const entry = findByIdentity(state.progression.entries, identity);
  if (entry === undefined) {
    return rejected(frozen({ tag: "UnknownRequest", identity }));
  }
  if (!isTerminalPhase(entry.phase)) {
    return rejected(frozen({ tag: "RequestNotTerminal", identity }));
  }
  if (state.provenance.futureUses.some((i) => sameIdentity(i, identity))) {
    return rejected(frozen({ tag: "ProvenanceRetentionRequired", identity }));
  }
  if (state.provenance.outstandingSignals.some((s) => sameIdentity(s.identity, identity))) {
    return rejected(frozen({ tag: "ProvenanceRetentionRequired", identity }));
  }
  const newProgression = frozen({
    ...state.progression,
    entries: replaceByIdentity(state.progression.entries, identity, eraseEntryProvenance(entry)),
  });
  const newProvenance: AdmissionProvenance = frozen({
    futureUses: frozen(state.provenance.futureUses.filter((i) => !sameIdentity(i, identity))),
    outstandingSignals: frozen(state.provenance.outstandingSignals.filter((s) => !sameIdentity(s.identity, identity))),
  });
  const newState: DynamicAdmissionState = frozen({ ...state, progression: newProgression, provenance: newProvenance });
  return applied([newState, frozen({ tag: "Erased", identity })] as const);
}

export function admitDynamicRequest(
  input: DynamicAdmissionInput
): Outcome<DynamicAdmissionResult, DynamicAdmissionFailure, never, never> {
  const age = observationAge(input);
  if (age > input.environmentSpecification.maxObservationAge) {
    return rejected(frozen({ tag: "CapacityObservationUnavailable", age, maxAge: input.environmentSpecification.maxObservationAge }));
  }
  const mismatch = resourceCoordinateMismatch(input.state.configuredSafetyLimit, input.capacityObservation.observed);
  if (mismatch !== null) {
    return rejected(frozen({ tag: "ResourceCoordinateMismatch", configuredResource: mismatch[0], observedResource: mismatch[1] }));
  }
  const permissionFailure = permissionCheck(input.request);
  if (permissionFailure !== null) {
    return rejected(permissionFailure);
  }

  const effectiveBudget = effectiveBudgetOf(input.state.configuredSafetyLimit, input.capacityObservation.observed);
  const snapshot = input.state.progression;
  const provenance = input.state.provenance;
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

  const budgetedSnapshot = frozen({ ...snapshot, budget: effectiveBudget });
  const submitted = submit(budgetedSnapshot, input.request);
  if (submitted.tag === "submitRejected") {
    return rejected(frozen({ tag: "ProgressionSubmitFailure", failure: submitted.failure }));
  }

  if (input.start === null) {
    const newState: DynamicAdmissionState = frozen({ ...input.state, progression: submitted.snapshot });
    return applied(
      frozen({
        effectiveBudget,
        admissionDecision: frozen({ tag: "Submitted", state: newState, accepted: submitted.accepted }),
        futureUseSet: toFutureUseSet(newState.provenance),
        outstandingSignalSet: toOutstandingSignalSet(newState.provenance),
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
  const newState: DynamicAdmissionState = frozen({ ...input.state, progression: newSnapshot });
  return applied(
    frozen({
      effectiveBudget,
      admissionDecision: frozen({ tag: "Started", state: newState, result: startResult }),
      futureUseSet: toFutureUseSet(newState.provenance),
      outstandingSignalSet: toOutstandingSignalSet(newState.provenance),
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
