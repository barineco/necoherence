-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

/-
Dynamic admission over `RequestProgression`.

`AdmissionProvenance` is an explicit input: future uses and outstanding
adapter signals are never inferred from a snapshot. `admitDynamicRequest`
computes an effective safety budget from a configured limit and an observed
capacity, coalesces an identical restored pending request idempotently, and
otherwise connects straight through to `RequestProgression.submit` and
`RequestProgression.decideStart`. Adapter observations are applied separately
through `RequestProgression.applyStartObservation` and
`RequestProgression.applyCompletionObservation`. `elideAdmissionProvenance` is
the only operation that mutates state, and only when the target terminal entry
carries no live future use or outstanding signal.
-/

import Necoherence.Core
import Necoherence.RequestProgression

namespace Necoherence

/-- Declares the maximum age, in the caller's Nat clock, that a `CapacityObservation` stays usable. -/
structure EnvironmentSpecification where
  maxObservationAge : Nat
  deriving DecidableEq, Repr

/-- An observed resource budget and the Nat instant it was taken at. -/
structure CapacityObservation where
  observed : ResourceBudget
  observedAt : Nat
  deriving DecidableEq, Repr

/-- Which adapter observation a still-open request is waiting on. -/
inductive SignalKind where
  | pendingCompletion
  | pendingCancellation
  deriving DecidableEq, Repr

/-- One adapter signal not yet folded into a terminal entry's own record. -/
structure AdmissionSignal where
  identity : RequestIdentity
  handle : ExecutionHandle
  kind : SignalKind
  deriving DecidableEq, Repr

/--
Explicit provenance carried alongside a `DynamicAdmissionState`: identities a
caller still intends to reuse, and adapter signals not yet folded into their
own terminal entry. Neither is inferred from the progression snapshot.
-/
structure AdmissionProvenance where
  futureUses : List RequestIdentity
  outstandingSignals : List AdmissionSignal
  deriving DecidableEq, Repr

/-- Dynamic admission state: the progression snapshot, its configured safety limit, and provenance. -/
structure DynamicAdmissionState where
  progression : RequestProgressionSnapshot
  configuredSafetyLimit : ResourceBudget
  provenance : AdmissionProvenance
  deriving DecidableEq, Repr

/-- One admission request: the state it applies against, the request, the capacity observation,
the caller's observed clock, and an optional start cost selection. -/
structure DynamicAdmissionInput where
  state : DynamicAdmissionState
  request : RequestInput
  environmentSpecification : EnvironmentSpecification
  capacityObservation : CapacityObservation
  observedAt : Nat
  start : Option CostSelection
  deriving DecidableEq, Repr

/-- The componentwise-minimum budget actually enforced by one admission evaluation. -/
abbrev EffectiveBudget := ResourceBudget

/-- Closed failure of a dynamic admission evaluation or provenance elision. -/
inductive DynamicAdmissionFailure where
  | capacityObservationUnavailable (age maxAge : Nat)
  | resourceCoordinateMismatch (configuredResource observedResource : String)
  | configuredSafetyLimitExceeded (resource : String) (occupied allowed : Nat)
  | meaningDenied (identity : RequestIdentity) (reason : PermissionDenial)
  | permissionIdentityMismatch (requestIdentity permissionIdentity : RequestIdentity)
  | adapterBindingUnavailable (identity : RequestIdentity)
  | bindingSelectionMismatch (identity : RequestIdentity)
  | progressionSubmitFailure (failure : SubmitFailure)
  | progressionStartFailure (failure : StartDecisionFailure)
  | provenanceRetentionRequired (identity : RequestIdentity)
  | unknownRequest (identity : RequestIdentity)
  | requestNotTerminal (identity : RequestIdentity)
  deriving DecidableEq, Repr

/-- Closed admit value: which `RequestProgression` connection produced the new state. -/
inductive AdmissionDecision where
  | submitted (state : DynamicAdmissionState) (accepted : Accepted)
  | started (state : DynamicAdmissionState) (result : StartDecisionResult)
  | coalesced (state : DynamicAdmissionState) (identity : RequestIdentity)
  deriving DecidableEq, Repr

/-- Identities whose data a caller still intends to use again, read from `AdmissionProvenance`. -/
structure FutureUseSet where
  identities : List RequestIdentity
  deriving DecidableEq, Repr

/-- Adapter signals still outstanding, read from `AdmissionProvenance`. -/
structure OutstandingSignalSet where
  signals : List AdmissionSignal
  deriving DecidableEq, Repr

/-- Whether one identity's provenance was erased, or is retained and why. -/
inductive ProvenanceErasureWitness where
  | erased (identity : RequestIdentity)
  | retained (identity : RequestIdentity) (reason : String)
  deriving DecidableEq, Repr

/-- Whether a restored pending duplicate was absorbed idempotently, or why it was not. -/
inductive CoalescingWitness where
  | coalesced (identity : RequestIdentity)
  | notCoalesced (reason : String)
  deriving DecidableEq, Repr

/-- Result of one successful dynamic admission evaluation; all six declared fields are always present. -/
structure DynamicAdmissionResult where
  effectiveBudget : EffectiveBudget
  admissionDecision : AdmissionDecision
  futureUseSet : FutureUseSet
  outstandingSignalSet : OutstandingSignalSet
  provenanceErasureWitness : Option ProvenanceErasureWitness
  coalescingWitness : CoalescingWitness
  deriving DecidableEq, Repr

/-! ### Private helpers -/

/-- `RequestProgression.findEntry`'s own copy, kept private to this file. -/
private def findByIdentity (entries : List RequestEntry) (identity : RequestIdentity) : Option RequestEntry :=
  entries.find? (fun entry => entry.identity == identity)

/-- `RequestProgression.replaceEntry`'s own copy, kept private to this file. -/
private def replaceByIdentity (entries : List RequestEntry) (identity : RequestIdentity) (replacement : RequestEntry) :
    List RequestEntry :=
  entries.map (fun entry => if entry.identity == identity then replacement else entry)

private def minLimit (a b : ConfiguredSafetyLimit) : ConfiguredSafetyLimit :=
  { resource := a.resource, maximum := min a.maximum b.maximum }

/-- Effective budget: componentwise min of `configured` and `observed`, keeping `configured`'s resource labels. -/
private def effectiveBudgetOf (configured observed : ResourceBudget) : EffectiveBudget :=
  { pendingMaximum := minLimit configured.pendingMaximum observed.pendingMaximum,
    inFlightMaximum := minLimit configured.inFlightMaximum observed.inFlightMaximum,
    concurrentMaximum := minLimit configured.concurrentMaximum observed.concurrentMaximum }

/-- First axis, if any, whose `configured` and `observed` resource labels disagree. -/
private def resourceCoordinateMismatch (configured observed : ResourceBudget) : Option (String × String) :=
  if configured.pendingMaximum.resource != observed.pendingMaximum.resource then
    some (configured.pendingMaximum.resource, observed.pendingMaximum.resource)
  else if configured.inFlightMaximum.resource != observed.inFlightMaximum.resource then
    some (configured.inFlightMaximum.resource, observed.inFlightMaximum.resource)
  else if configured.concurrentMaximum.resource != observed.concurrentMaximum.resource then
    some (configured.concurrentMaximum.resource, observed.concurrentMaximum.resource)
  else none

/--
Age of the capacity observation relative to `input.observedAt`. An observation taken after
`input.observedAt` (a future-dated observation) is folded to strictly exceed `maxObservationAge`, so the
single `age > maxObservationAge` test used by `admitDynamicRequest` also rejects time reversal.
-/
private def observationAge (input : DynamicAdmissionInput) : Nat :=
  if input.observedAt < input.capacityObservation.observedAt then
    (input.capacityObservation.observedAt - input.observedAt) + input.environmentSpecification.maxObservationAge + 1
  else
    input.observedAt - input.capacityObservation.observedAt

/-- Closed check of `RequestInput.permission` against `RequestInput.identity`; `none` means permitted. -/
private def permissionCheck (request : RequestInput) : Option DynamicAdmissionFailure :=
  match request.permission with
  | .denied identity reason =>
    some
      (if identity == request.identity then DynamicAdmissionFailure.meaningDenied identity reason
       else DynamicAdmissionFailure.permissionIdentityMismatch request.identity identity)
  | .permitted permIdentity _ =>
    if permIdentity == request.identity then none
    else some (.permissionIdentityMismatch request.identity permIdentity)
  | .ordered permIdentity _ =>
    if permIdentity == request.identity then none
    else some (.permissionIdentityMismatch request.identity permIdentity)

/-- A `Pending` entry that matches `request`'s identity, footprint, demand, and permission exactly. -/
private def samePendingEntry (entry : RequestEntry) (request : RequestInput) : Bool :=
  entry.phase == .pending &&
  entry.identity == request.identity &&
  entry.footprint == request.footprint &&
  entry.demand == request.demand &&
  entry.meaningPermission == request.permission

/-- The existing pending entry that `request` would idempotently coalesce into, if any. -/
private def matchingPendingDuplicate (snapshot : RequestProgressionSnapshot) (request : RequestInput) :
    Option RequestEntry :=
  match findByIdentity snapshot.entries request.identity with
  | some entry => if samePendingEntry entry request then some entry else none
  | none => none

private def isExecuteNow : CostSelection → Bool
  | .executeNow _ _ _ => true
  | .remainPending _ _ _ => false

private def toFutureUseSet (provenance : AdmissionProvenance) : FutureUseSet :=
  ⟨provenance.futureUses⟩

private def toOutstandingSignalSet (provenance : AdmissionProvenance) : OutstandingSignalSet :=
  ⟨provenance.outstandingSignals⟩

private def isTerminalPhase (phase : RequestPhase) : Bool :=
  phase == .published || phase == .superseded || phase == .cancelled || phase == .failed

private def eraseMeaningPermissionEvidence : MeaningPermission → MeaningPermission
  | .permitted identity _ => .permitted identity []
  | .ordered identity _ => .ordered identity []
  | .denied identity reason => .denied identity reason

/-- Clear one entry's footprint reads/writes and permission evidence, keeping identity, demand, and phase. -/
private def eraseEntryProvenance (entry : RequestEntry) : RequestEntry :=
  { entry with
    footprint := { entry.footprint with reads := [], writes := [] },
    meaningPermission := eraseMeaningPermissionEvidence entry.meaningPermission }

/-! ### Public operations -/

/--
Elide one terminal entry's provenance. Unknown or non-terminal identities are closed failures. A live
future use or outstanding signal in `state.provenance` blocks erasure with `ProvenanceRetentionRequired`
and leaves `state` unchanged. Otherwise only the target entry's footprint and permission evidence are
cleared, and the identity is dropped from `state.provenance`.
-/
def elideAdmissionProvenance (state : DynamicAdmissionState) (identity : RequestIdentity) :
    Outcome (DynamicAdmissionState × ProvenanceErasureWitness) DynamicAdmissionFailure Empty Empty :=
  match findByIdentity state.progression.entries identity with
  | none => .rejected (.unknownRequest identity)
  | some entry =>
    if !isTerminalPhase entry.phase then
      .rejected (.requestNotTerminal identity)
    else if state.provenance.futureUses.contains identity then
      .rejected (.provenanceRetentionRequired identity)
    else if state.provenance.outstandingSignals.any (fun s => s.identity == identity) then
      .rejected (.provenanceRetentionRequired identity)
    else
      let newProgression :=
        { state.progression with entries := replaceByIdentity state.progression.entries identity (eraseEntryProvenance entry) }
      let newProvenance : AdmissionProvenance :=
        { futureUses := state.provenance.futureUses.filter (fun i => i != identity),
          outstandingSignals := state.provenance.outstandingSignals.filter (fun s => s.identity != identity) }
      .applied ({ state with progression := newProgression, provenance := newProvenance }, .erased identity)

/--
Evaluate dynamic admission. A future-dated or expired capacity observation, a resource-label mismatch
against `state.configuredSafetyLimit`, or a denied/mismatched meaning permission rejects outright. A
restored pending duplicate (identical identity, footprint, demand, and permission) is coalesced
idempotently when its binding selection agrees with the new request's, and rejected as an adapter
binding mismatch otherwise. A fresh request is checked against the effective budget (current occupancy
plus this request's demand, adding in-flight/concurrent only for an `ExecuteNow` start) and then
connected through `RequestProgression.submit` and, when requested, `RequestProgression.decideStart`.
Adapter observations are not part of this operation.
-/
def admitDynamicRequest (input : DynamicAdmissionInput) :
    Outcome DynamicAdmissionResult DynamicAdmissionFailure Empty Empty :=
  let age := observationAge input
  if age > input.environmentSpecification.maxObservationAge then
    .rejected (.capacityObservationUnavailable age input.environmentSpecification.maxObservationAge)
  else
    match resourceCoordinateMismatch input.state.configuredSafetyLimit input.capacityObservation.observed with
    | some (configuredResource, observedResource) => .rejected (.resourceCoordinateMismatch configuredResource observedResource)
    | none =>
      match permissionCheck input.request with
      | some failure => .rejected failure
      | none =>
        let effectiveBudget := effectiveBudgetOf input.state.configuredSafetyLimit input.capacityObservation.observed
        let snapshot := input.state.progression
        let provenance := input.state.provenance
        match matchingPendingDuplicate snapshot input.request with
        | some entry =>
          match entry.costSelection, input.start with
          | none, none =>
            .applied
              { effectiveBudget := effectiveBudget,
                admissionDecision := .coalesced input.state input.request.identity,
                futureUseSet := toFutureUseSet provenance,
                outstandingSignalSet := toOutstandingSignalSet provenance,
                provenanceErasureWitness := none,
                coalescingWitness := .coalesced input.request.identity }
          | some s1, some s2 =>
            if s1 == s2 then
              .applied
                { effectiveBudget := effectiveBudget,
                  admissionDecision := .coalesced input.state input.request.identity,
                  futureUseSet := toFutureUseSet provenance,
                  outstandingSignalSet := toOutstandingSignalSet provenance,
                  provenanceErasureWitness := none,
                  coalescingWitness := .coalesced input.request.identity }
            else
              .rejected (.bindingSelectionMismatch input.request.identity)
          | _, _ => .rejected (.adapterBindingUnavailable input.request.identity)
        | none =>
          let pendingOccupied := (derivePending snapshot).pending + input.request.demand.pending
          if pendingOccupied > effectiveBudget.pendingMaximum.maximum then
            .rejected
              (.configuredSafetyLimitExceeded effectiveBudget.pendingMaximum.resource pendingOccupied
                effectiveBudget.pendingMaximum.maximum)
          else
            let executeNow :=
              match input.start with
              | some s => isExecuteNow s
              | none => false
            let inFlightOccupied := (deriveInFlight snapshot).inFlight + input.request.demand.inFlight
            let concurrentOccupied := (deriveConcurrent snapshot).concurrent + input.request.demand.concurrent
            if executeNow && inFlightOccupied > effectiveBudget.inFlightMaximum.maximum then
              .rejected
                (.configuredSafetyLimitExceeded effectiveBudget.inFlightMaximum.resource inFlightOccupied
                  effectiveBudget.inFlightMaximum.maximum)
            else if executeNow && concurrentOccupied > effectiveBudget.concurrentMaximum.maximum then
              .rejected
                (.configuredSafetyLimitExceeded effectiveBudget.concurrentMaximum.resource concurrentOccupied
                  effectiveBudget.concurrentMaximum.maximum)
            else
              let budgetedSnapshot := { snapshot with budget := effectiveBudget }
              match submit budgetedSnapshot input.request with
              | .submitRejected _ failure => .rejected (.progressionSubmitFailure failure)
              | .accepted snapshot' accepted =>
                match input.start with
                | none =>
                  let newState := { input.state with progression := snapshot' }
                  .applied
                    { effectiveBudget := effectiveBudget,
                      admissionDecision := .submitted newState accepted,
                      futureUseSet := toFutureUseSet newState.provenance,
                      outstandingSignalSet := toOutstandingSignalSet newState.provenance,
                      provenanceErasureWitness := none,
                      coalescingWitness := .notCoalesced "no duplicate pending request" }
                | some selection =>
                  match decideStart snapshot' accepted selection with
                  | .rejected _ failure => .rejected (.progressionStartFailure failure)
                  | .execute snapshot'' starting command =>
                    let newState := { input.state with progression := snapshot'' }
                    .applied
                      { effectiveBudget := effectiveBudget,
                        admissionDecision := .started newState (.execute snapshot'' starting command),
                        futureUseSet := toFutureUseSet newState.provenance,
                        outstandingSignalSet := toOutstandingSignalSet newState.provenance,
                        provenanceErasureWitness := none,
                        coalescingWitness := .notCoalesced "no duplicate pending request" }
                  | .deferred snapshot'' accepted' =>
                    let newState := { input.state with progression := snapshot'' }
                    .applied
                      { effectiveBudget := effectiveBudget,
                        admissionDecision := .started newState (.deferred snapshot'' accepted'),
                        futureUseSet := toFutureUseSet newState.provenance,
                        outstandingSignalSet := toOutstandingSignalSet newState.provenance,
                        provenanceErasureWitness := none,
                        coalescingWitness := .notCoalesced "no duplicate pending request" }

/-! ### Theorems -/

/-- A future-dated capacity observation always exceeds the age threshold, so admission is rejected. -/
theorem future_observation_is_rejected (input : DynamicAdmissionInput)
    (future : input.observedAt < input.capacityObservation.observedAt) :
    admitDynamicRequest input =
      .rejected (.capacityObservationUnavailable (observationAge input) input.environmentSpecification.maxObservationAge) := by
  have hage : observationAge input > input.environmentSpecification.maxObservationAge := by
    simp only [observationAge, future, ↓reduceIte]
    omega
  simp [admitDynamicRequest, hage]

/-- A capacity observation older than the declared maximum age rejects admission. -/
theorem capacity_observation_expired_rejects (input : DynamicAdmissionInput)
    (expired : observationAge input > input.environmentSpecification.maxObservationAge) :
    admitDynamicRequest input =
      .rejected (.capacityObservationUnavailable (observationAge input) input.environmentSpecification.maxObservationAge) := by
  simp [admitDynamicRequest, expired]

/-- The effective budget is the componentwise min of `configured` and `observed`. -/
theorem effective_budget_is_componentwise_min (configured observed : ResourceBudget) :
    (effectiveBudgetOf configured observed).pendingMaximum.maximum
        = min configured.pendingMaximum.maximum observed.pendingMaximum.maximum ∧
      (effectiveBudgetOf configured observed).inFlightMaximum.maximum
        = min configured.inFlightMaximum.maximum observed.inFlightMaximum.maximum ∧
      (effectiveBudgetOf configured observed).concurrentMaximum.maximum
        = min configured.concurrentMaximum.maximum observed.concurrentMaximum.maximum := by
  simp [effectiveBudgetOf, minLimit]

/--
With every earlier gate passed and no restored duplicate, pending occupancy plus this request's own
demand exceeding the effective budget rejects admission with `ConfiguredSafetyLimitExceeded`.
-/
theorem pending_occupancy_with_demand_exceeded_rejects (input : DynamicAdmissionInput)
    (notExpired : ¬ observationAge input > input.environmentSpecification.maxObservationAge)
    (noMismatch : resourceCoordinateMismatch input.state.configuredSafetyLimit input.capacityObservation.observed = none)
    (permitted : permissionCheck input.request = none)
    (noDuplicate : matchingPendingDuplicate input.state.progression input.request = none)
    (exceeded :
      (derivePending input.state.progression).pending + input.request.demand.pending
        > (effectiveBudgetOf input.state.configuredSafetyLimit input.capacityObservation.observed).pendingMaximum.maximum) :
    admitDynamicRequest input =
      .rejected
        (.configuredSafetyLimitExceeded
          (effectiveBudgetOf input.state.configuredSafetyLimit input.capacityObservation.observed).pendingMaximum.resource
          ((derivePending input.state.progression).pending + input.request.demand.pending)
          (effectiveBudgetOf input.state.configuredSafetyLimit input.capacityObservation.observed).pendingMaximum.maximum) := by
  simp [admitDynamicRequest, notExpired, noMismatch, permitted, noDuplicate, exceeded]

/-- A restored pending duplicate with no binding selection on either side coalesces idempotently, leaving `state` unchanged. -/
theorem same_pending_no_binding_is_idempotent (input : DynamicAdmissionInput)
    (notExpired : ¬ observationAge input > input.environmentSpecification.maxObservationAge)
    (noMismatch : resourceCoordinateMismatch input.state.configuredSafetyLimit input.capacityObservation.observed = none)
    (permitted : permissionCheck input.request = none)
    (entry : RequestEntry) (duplicate : matchingPendingDuplicate input.state.progression input.request = some entry)
    (noEntrySelection : entry.costSelection = none) (noStart : input.start = none) :
    admitDynamicRequest input =
      .applied
        { effectiveBudget := effectiveBudgetOf input.state.configuredSafetyLimit input.capacityObservation.observed,
          admissionDecision := .coalesced input.state input.request.identity,
          futureUseSet := toFutureUseSet input.state.provenance,
          outstandingSignalSet := toOutstandingSignalSet input.state.provenance,
          provenanceErasureWitness := none,
          coalescingWitness := .coalesced input.request.identity } := by
  simp [admitDynamicRequest, notExpired, noMismatch, permitted, duplicate, noEntrySelection, noStart]

/-- A restored pending duplicate whose binding selection differs from the new request's is rejected as a binding mismatch. -/
theorem binding_selection_mismatch_is_rejected (input : DynamicAdmissionInput)
    (notExpired : ¬ observationAge input > input.environmentSpecification.maxObservationAge)
    (noMismatch : resourceCoordinateMismatch input.state.configuredSafetyLimit input.capacityObservation.observed = none)
    (permitted : permissionCheck input.request = none)
    (entry : RequestEntry) (duplicate : matchingPendingDuplicate input.state.progression input.request = some entry)
    (s1 s2 : CostSelection) (entrySelection : entry.costSelection = some s1)
    (isStart : input.start = some s2) (differ : s1 ≠ s2) :
    admitDynamicRequest input = .rejected (.bindingSelectionMismatch input.request.identity) := by
  have hne : (s1 == s2) = false := by simpa using differ
  simp [admitDynamicRequest, notExpired, noMismatch, permitted, duplicate, entrySelection, isStart, hne]

/--
With no restored duplicate, the effective budget satisfied, and no `start` requested, admission connects
straight through to `RequestProgression.submit`'s accepted result.
-/
theorem submit_without_start_connects (input : DynamicAdmissionInput)
    (notExpired : ¬ observationAge input > input.environmentSpecification.maxObservationAge)
    (noMismatch : resourceCoordinateMismatch input.state.configuredSafetyLimit input.capacityObservation.observed = none)
    (permitted : permissionCheck input.request = none)
    (noDuplicate : matchingPendingDuplicate input.state.progression input.request = none)
    (withinPending :
      ¬ (derivePending input.state.progression).pending + input.request.demand.pending
        > (effectiveBudgetOf input.state.configuredSafetyLimit input.capacityObservation.observed).pendingMaximum.maximum)
    (noStart : input.start = none)
    (snapshot' : RequestProgressionSnapshot) (accepted : Accepted)
    (accepts :
      submit { input.state.progression with budget := effectiveBudgetOf input.state.configuredSafetyLimit input.capacityObservation.observed }
        input.request = .accepted snapshot' accepted) :
    admitDynamicRequest input =
      .applied
        { effectiveBudget := effectiveBudgetOf input.state.configuredSafetyLimit input.capacityObservation.observed,
          admissionDecision := .submitted { input.state with progression := snapshot' } accepted,
          futureUseSet := toFutureUseSet input.state.provenance,
          outstandingSignalSet := toOutstandingSignalSet input.state.provenance,
          provenanceErasureWitness := none,
          coalescingWitness := .notCoalesced "no duplicate pending request" } := by
  simp [admitDynamicRequest, notExpired, noMismatch, permitted, noDuplicate, withinPending, noStart, accepts]

/--
With no restored duplicate, the effective budget satisfied, and a requested `ExecuteNow` start that
`RequestProgression.decideStart` executes, admission connects the submitted and started snapshots together.
-/
theorem start_success_connects (input : DynamicAdmissionInput)
    (notExpired : ¬ observationAge input > input.environmentSpecification.maxObservationAge)
    (noMismatch : resourceCoordinateMismatch input.state.configuredSafetyLimit input.capacityObservation.observed = none)
    (permitted : permissionCheck input.request = none)
    (noDuplicate : matchingPendingDuplicate input.state.progression input.request = none)
    (withinPending :
      ¬ (derivePending input.state.progression).pending + input.request.demand.pending
        > (effectiveBudgetOf input.state.configuredSafetyLimit input.capacityObservation.observed).pendingMaximum.maximum)
    (selection : CostSelection) (isStart : input.start = some selection)
    (executeNow : isExecuteNow selection = true)
    (withinInFlight :
      ¬ (deriveInFlight input.state.progression).inFlight + input.request.demand.inFlight
        > (effectiveBudgetOf input.state.configuredSafetyLimit input.capacityObservation.observed).inFlightMaximum.maximum)
    (withinConcurrent :
      ¬ (deriveConcurrent input.state.progression).concurrent + input.request.demand.concurrent
        > (effectiveBudgetOf input.state.configuredSafetyLimit input.capacityObservation.observed).concurrentMaximum.maximum)
    (snapshot' : RequestProgressionSnapshot) (accepted : Accepted)
    (accepts :
      submit { input.state.progression with budget := effectiveBudgetOf input.state.configuredSafetyLimit input.capacityObservation.observed }
        input.request = .accepted snapshot' accepted)
    (snapshot'' : RequestProgressionSnapshot) (starting : Starting) (command : AdapterCommand)
    (started : decideStart snapshot' accepted selection = .execute snapshot'' starting command) :
    admitDynamicRequest input =
      .applied
        { effectiveBudget := effectiveBudgetOf input.state.configuredSafetyLimit input.capacityObservation.observed,
          admissionDecision := .started { input.state with progression := snapshot'' } (.execute snapshot'' starting command),
          futureUseSet := toFutureUseSet input.state.provenance,
          outstandingSignalSet := toOutstandingSignalSet input.state.provenance,
          provenanceErasureWitness := none,
          coalescingWitness := .notCoalesced "no duplicate pending request" } := by
  simp [admitDynamicRequest, notExpired, noMismatch, permitted, noDuplicate, withinPending, isStart, executeNow,
    withinInFlight, withinConcurrent, accepts, started]

/-- A terminal entry with a live future use blocks erasure and leaves `state` unchanged. -/
theorem future_use_blocks_erasure (state : DynamicAdmissionState) (identity : RequestIdentity) (entry : RequestEntry)
    (found : findByIdentity state.progression.entries identity = some entry)
    (terminal : isTerminalPhase entry.phase = true)
    (future : state.provenance.futureUses.contains identity = true) :
    elideAdmissionProvenance state identity = .rejected (.provenanceRetentionRequired identity) := by
  have future' : identity ∈ state.provenance.futureUses := by simpa using future
  simp [elideAdmissionProvenance, found, terminal, future']

/-- A terminal entry with a live outstanding signal blocks erasure and leaves `state` unchanged. -/
theorem outstanding_signal_blocks_erasure (state : DynamicAdmissionState) (identity : RequestIdentity)
    (entry : RequestEntry) (found : findByIdentity state.progression.entries identity = some entry)
    (terminal : isTerminalPhase entry.phase = true)
    (signal : state.provenance.outstandingSignals.any (fun s => s.identity == identity) = true) :
    elideAdmissionProvenance state identity = .rejected (.provenanceRetentionRequired identity) := by
  simp [elideAdmissionProvenance, found, terminal, signal]

/-- With no live future use or signal, erasure clears exactly the target terminal entry and no other. -/
theorem empty_provenance_erases_target_entry_only (state : DynamicAdmissionState) (identity : RequestIdentity)
    (entry : RequestEntry) (found : findByIdentity state.progression.entries identity = some entry)
    (terminal : isTerminalPhase entry.phase = true)
    (noFuture : state.provenance.futureUses.contains identity = false)
    (noSignal : state.provenance.outstandingSignals.any (fun s => s.identity == identity) = false) :
    elideAdmissionProvenance state identity =
      .applied
        ({ state with
            progression := { state.progression with entries := replaceByIdentity state.progression.entries identity (eraseEntryProvenance entry) },
            provenance :=
              { futureUses := state.provenance.futureUses.filter (fun i => i != identity),
                outstandingSignals := state.provenance.outstandingSignals.filter (fun s => s.identity != identity) } },
          .erased identity) := by
  have noFuture' : identity ∉ state.provenance.futureUses := by simpa using noFuture
  simp [elideAdmissionProvenance, found, terminal, noFuture', noSignal]

/-- Every other entry's identity is untouched by `eraseEntryProvenance`'s single-entry replacement. -/
theorem erase_provenance_preserves_other_entries (entries : List RequestEntry) (identity other : RequestIdentity)
    (replacement : RequestEntry) (sameIdentity : replacement.identity = identity) (distinct : other ≠ identity) :
    findByIdentity (replaceByIdentity entries identity replacement) other = findByIdentity entries other := by
  unfold findByIdentity replaceByIdentity
  induction entries with
  | nil => simp
  | cons e es ih =>
    rw [List.map_cons]
    by_cases he : e.identity = identity
    · have hne : (e.identity == other) = false := by
        rw [beq_eq_false_iff_ne]; rw [he]; exact fun h => distinct h.symm
      have hne2 : (replacement.identity == other) = false := by
        rw [beq_eq_false_iff_ne]; rw [sameIdentity]; exact fun h => distinct h.symm
      rw [show (if e.identity == identity then replacement else e) = replacement by simp [he]]
      rw [List.find?_cons, List.find?_cons, hne, hne2]
      exact ih
    · have heFalse : (e.identity == identity) = false := by rw [beq_eq_false_iff_ne]; exact he
      rw [show (if e.identity == identity then replacement else e) = e by simp [heFalse]]
      rw [List.find?_cons, List.find?_cons]
      by_cases heo : e.identity = other
      · simp [heo]
      · have heoFalse : (e.identity == other) = false := by rw [beq_eq_false_iff_ne]; exact heo
        rw [heoFalse]
        exact ih

/-- An unknown identity is a closed erasure failure and never touches `state`. -/
theorem unknown_request_erasure_is_rejected (state : DynamicAdmissionState) (identity : RequestIdentity)
    (missing : findByIdentity state.progression.entries identity = none) :
    elideAdmissionProvenance state identity = .rejected (.unknownRequest identity) := by
  simp [elideAdmissionProvenance, missing]

/-- A non-terminal entry is a closed erasure failure and never touches `state`. -/
theorem non_terminal_erasure_is_rejected (state : DynamicAdmissionState) (identity : RequestIdentity)
    (entry : RequestEntry) (found : findByIdentity state.progression.entries identity = some entry)
    (notTerminal : isTerminalPhase entry.phase = false) :
    elideAdmissionProvenance state identity = .rejected (.requestNotTerminal identity) := by
  simp [elideAdmissionProvenance, found, notTerminal]

#print axioms future_observation_is_rejected
#print axioms capacity_observation_expired_rejects
#print axioms effective_budget_is_componentwise_min
#print axioms pending_occupancy_with_demand_exceeded_rejects
#print axioms same_pending_no_binding_is_idempotent
#print axioms binding_selection_mismatch_is_rejected
#print axioms submit_without_start_connects
#print axioms start_success_connects
#print axioms future_use_blocks_erasure
#print axioms outstanding_signal_blocks_erasure
#print axioms empty_provenance_erases_target_entry_only
#print axioms erase_provenance_preserves_other_entries
#print axioms unknown_request_erasure_is_rejected
#print axioms non_terminal_erasure_is_rejected

end Necoherence
