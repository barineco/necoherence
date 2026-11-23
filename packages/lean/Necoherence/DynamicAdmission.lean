-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT



import Necoherence.Core
import Necoherence.RequestProgression
import NecoQuotient.Retention

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

/-- The kind of provenance an erasure removes from a terminal entry. -/
inductive ProvenanceObservation where
  | footprint
  | evidence
  deriving DecidableEq, Repr

deriving instance DecidableEq, Repr for NecoQuotient.Recoverability
deriving instance DecidableEq, Repr for NecoQuotient.RetentionReason
deriving instance DecidableEq, Repr for NecoQuotient.MissingInput
deriving instance DecidableEq, Repr for NecoQuotient.DematerializeWitness

/-- The retention judgment's erasure witness for one identity's provenance. -/
abbrev ErasureWitness := NecoQuotient.DematerializeWitness RequestIdentity Unit Unit ProvenanceObservation

/-- The retention judgment's reason for keeping one identity's provenance. -/
abbrev ErasureRetention := NecoQuotient.RetentionReason RequestIdentity Unit ProvenanceObservation

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
  | provenanceRetentionRequired (identity : RequestIdentity) (reasons : List ErasureRetention)
  | erasureInputIncomplete (identity : RequestIdentity) (missing : NecoQuotient.MissingInput)
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
  provenanceErasureWitness : Option ErasureWitness
  coalescingWitness : CoalescingWitness
  deriving DecidableEq, Repr




private def findByIdentity (entries : List RequestEntry) (identity : RequestIdentity) : Option RequestEntry :=
  entries.find? (fun entry => entry.identity == identity)


private def replaceByIdentity (entries : List RequestEntry) (identity : RequestIdentity) (replacement : RequestEntry) :
    List RequestEntry :=
  entries.map (fun entry => if entry.identity == identity then replacement else entry)

private def minLimit (a b : ConfiguredSafetyLimit) : ConfiguredSafetyLimit :=
  { resource := a.resource, maximum := min a.maximum b.maximum }


private def effectiveBudgetOf (configured observed : ResourceBudget) : EffectiveBudget :=
  { pendingMaximum := minLimit configured.pendingMaximum observed.pendingMaximum,
    inFlightMaximum := minLimit configured.inFlightMaximum observed.inFlightMaximum,
    concurrentMaximum := minLimit configured.concurrentMaximum observed.concurrentMaximum }


private def resourceCoordinateMismatch (configured observed : ResourceBudget) : Option (String × String) :=
  if configured.pendingMaximum.resource != observed.pendingMaximum.resource then
    some (configured.pendingMaximum.resource, observed.pendingMaximum.resource)
  else if configured.inFlightMaximum.resource != observed.inFlightMaximum.resource then
    some (configured.inFlightMaximum.resource, observed.inFlightMaximum.resource)
  else if configured.concurrentMaximum.resource != observed.concurrentMaximum.resource then
    some (configured.concurrentMaximum.resource, observed.concurrentMaximum.resource)
  else none


private def observationAge (input : DynamicAdmissionInput) : Nat :=
  if input.observedAt < input.capacityObservation.observedAt then
    (input.capacityObservation.observedAt - input.observedAt) + input.environmentSpecification.maxObservationAge + 1
  else
    input.observedAt - input.capacityObservation.observedAt


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


private def samePendingEntry (entry : RequestEntry) (request : RequestInput) : Bool :=
  entry.phase == .pending &&
  entry.identity == request.identity &&
  entry.footprint == request.footprint &&
  entry.demand == request.demand &&
  entry.meaningPermission == request.permission


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


private def eraseEntryProvenance (entry : RequestEntry) : RequestEntry :=
  { entry with
    footprint := { entry.footprint with reads := [], writes := [] },
    meaningPermission := eraseMeaningPermissionEvidence entry.meaningPermission }



/-- The erasure request for one identity: its footprint and evidence are removed, none is preserved. -/
def erasureRequestOf (identity : RequestIdentity) :
    NecoQuotient.ErasureRequest RequestIdentity Unit ProvenanceObservation :=
  { target := identity,
    targetBasis := none,
    removedObservations := [.footprint, .evidence],
    preservedObservations := [] }

/-- Live membership read from `state.provenance`; dynamic admission has no active basis, branch root or outstanding effect. -/
def erasureMembershipOf (state : DynamicAdmissionState) : NecoQuotient.LiveMembership RequestIdentity Unit :=
  { activeBasis := fun _ => false,
    branchRoot := fun _ => false,
    futureUse := fun i => decide (i ∈ state.provenance.futureUses),
    outstandingEffect := fun _ => false,
    outstandingSignal := fun i => state.provenance.outstandingSignals.any (fun s => s.identity == i) }

/-- Dynamic admission has no means to restore an erased footprint or evidence. -/
def erasureRecoverability : Option (NecoQuotient.Recoverability Unit Unit) := some .irrecoverable

/--
Elide one terminal entry's provenance. Unknown or non-terminal identities are closed failures. Otherwise
`NecoQuotient.judgeErasureBy` decides: a dematerialize decision clears only the target entry's footprint
and permission evidence, drops the identity from `state.provenance` and returns the judgment's witness;
a retain decision is `ProvenanceRetentionRequired` with its reasons; missing input is
`ErasureInputIncomplete`. Failures leave `state` unchanged.
-/
def elideAdmissionProvenance (state : DynamicAdmissionState) (identity : RequestIdentity) :
    Outcome (DynamicAdmissionState × ErasureWitness) DynamicAdmissionFailure Empty Empty :=
  match findByIdentity state.progression.entries identity with
  | none => .rejected (.unknownRequest identity)
  | some entry =>
    if !isTerminalPhase entry.phase then
      .rejected (.requestNotTerminal identity)
    else
      match NecoQuotient.judgeErasureBy (erasureRequestOf identity) (erasureMembershipOf state) erasureRecoverability with
      | .dematerialize witness =>
        let newProgression :=
          { state.progression with entries := replaceByIdentity state.progression.entries identity (eraseEntryProvenance entry) }
        let newProvenance : AdmissionProvenance :=
          { futureUses := state.provenance.futureUses.filter (fun i => i != identity),
            outstandingSignals := state.provenance.outstandingSignals.filter (fun s => s.identity != identity) }
        .applied ({ state with progression := newProgression, provenance := newProvenance }, witness)
      | .retain reasons => .rejected (.provenanceRetentionRequired identity reasons)
      | .rejected missing => .rejected (.erasureInputIncomplete identity missing)

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

private theorem erasure_reasons (state : DynamicAdmissionState) (identity : RequestIdentity) :
    NecoQuotient.retentionReasonsBy (erasureRequestOf identity) (erasureMembershipOf state)
        (NecoQuotient.Recoverability.irrecoverable : NecoQuotient.Recoverability Unit Unit) =
      (if state.provenance.futureUses.contains identity = true then [NecoQuotient.RetentionReason.futureUse identity] else []) ++
      (if state.provenance.outstandingSignals.any (fun s => s.identity == identity) = true then
        [NecoQuotient.RetentionReason.outstandingSignal identity] else []) := by
  simp [NecoQuotient.retentionReasonsBy, erasureRequestOf, erasureMembershipOf]

private theorem erasure_judgment_retain (state : DynamicAdmissionState) (identity : RequestIdentity)
    (reasons : List ErasureRetention)
    (hr : reasons =
      (if state.provenance.futureUses.contains identity = true then [NecoQuotient.RetentionReason.futureUse identity] else []) ++
      (if state.provenance.outstandingSignals.any (fun s => s.identity == identity) = true then
        [NecoQuotient.RetentionReason.outstandingSignal identity] else []))
    (ne : reasons ≠ []) :
    NecoQuotient.judgeErasureBy (erasureRequestOf identity) (erasureMembershipOf state) erasureRecoverability =
      .retain reasons := by
  have h := erasure_reasons state identity
  unfold NecoQuotient.judgeErasureBy NecoQuotient.decideWithBy erasureRecoverability
  simp only [erasureRequestOf]
  simp only [erasureRequestOf] at h
  rw [h, ← hr]
  cases reasons with
  | nil => exact absurd rfl ne
  | cons x xs => rfl

private theorem erasure_judgment_dematerialize (state : DynamicAdmissionState) (identity : RequestIdentity)
    (noFuture : state.provenance.futureUses.contains identity = false)
    (noSignal : state.provenance.outstandingSignals.any (fun s => s.identity == identity) = false) :
    NecoQuotient.judgeErasureBy (erasureRequestOf identity) (erasureMembershipOf state) erasureRecoverability =
      .dematerialize { target := identity, recoverability := .irrecoverable, removedObservations := [.footprint, .evidence] } := by
  have h := erasure_reasons state identity
  rw [noFuture, noSignal] at h
  unfold NecoQuotient.judgeErasureBy NecoQuotient.decideWithBy erasureRecoverability
  simp only [erasureRequestOf] at h ⊢
  simp [h]

/-- A terminal entry with a live future use blocks erasure and leaves `state` unchanged. -/
theorem future_use_blocks_erasure (state : DynamicAdmissionState) (identity : RequestIdentity) (entry : RequestEntry)
    (found : findByIdentity state.progression.entries identity = some entry)
    (terminal : isTerminalPhase entry.phase = true)
    (future : state.provenance.futureUses.contains identity = true) :
    elideAdmissionProvenance state identity =
      .rejected
        (.provenanceRetentionRequired identity
          ([NecoQuotient.RetentionReason.futureUse identity] ++
            (if state.provenance.outstandingSignals.any (fun s => s.identity == identity) = true then
              [NecoQuotient.RetentionReason.outstandingSignal identity] else []))) := by
  rw [elideAdmissionProvenance, found]
  simp only [terminal, Bool.not_true, Bool.false_eq_true, if_false]
  rw [erasure_judgment_retain state identity
    ([NecoQuotient.RetentionReason.futureUse identity] ++
      (if state.provenance.outstandingSignals.any (fun s => s.identity == identity) = true then
        [NecoQuotient.RetentionReason.outstandingSignal identity] else []))
    (by have f : identity ∈ state.provenance.futureUses := by simpa using future
        simp [f]) (by simp)]

/-- A terminal entry with a live outstanding signal blocks erasure and leaves `state` unchanged. -/
theorem outstanding_signal_blocks_erasure (state : DynamicAdmissionState) (identity : RequestIdentity)
    (entry : RequestEntry) (found : findByIdentity state.progression.entries identity = some entry)
    (terminal : isTerminalPhase entry.phase = true)
    (signal : state.provenance.outstandingSignals.any (fun s => s.identity == identity) = true) :
    elideAdmissionProvenance state identity =
      .rejected
        (.provenanceRetentionRequired identity
          ((if state.provenance.futureUses.contains identity = true then
              [NecoQuotient.RetentionReason.futureUse identity] else []) ++
            [NecoQuotient.RetentionReason.outstandingSignal identity])) := by
  rw [elideAdmissionProvenance, found]
  simp only [terminal, Bool.not_true, Bool.false_eq_true, if_false]
  rw [erasure_judgment_retain state identity
    ((if state.provenance.futureUses.contains identity = true then
        [NecoQuotient.RetentionReason.futureUse identity] else []) ++
      [NecoQuotient.RetentionReason.outstandingSignal identity])
    (by simp [signal]) (by simp)]

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
          { target := identity, recoverability := .irrecoverable, removedObservations := [.footprint, .evidence] }) := by
  rw [elideAdmissionProvenance, found]
  simp only [terminal, Bool.not_true, Bool.false_eq_true, if_false]
  rw [erasure_judgment_dematerialize state identity noFuture noSignal]

/-- For a terminal target entry, erasure is applied exactly when the target is in neither `futureUses` nor any outstanding signal. -/
theorem elideAdmissionProvenance_dematerialize_iff (state : DynamicAdmissionState) (identity : RequestIdentity)
    (entry : RequestEntry) (found : findByIdentity state.progression.entries identity = some entry)
    (terminal : isTerminalPhase entry.phase = true) :
    (∃ result, elideAdmissionProvenance state identity = .applied result) ↔
      (identity ∉ state.provenance.futureUses ∧
        ∀ signal ∈ state.provenance.outstandingSignals, signal.identity ≠ identity) := by
  have hmatch : (∃ result, elideAdmissionProvenance state identity = .applied result) ↔
      ∃ w, NecoQuotient.judgeErasureBy (erasureRequestOf identity) (erasureMembershipOf state) erasureRecoverability
        = .dematerialize w := by
    rw [elideAdmissionProvenance, found]
    simp only [terminal, Bool.not_true, Bool.false_eq_true, if_false]
    generalize NecoQuotient.judgeErasureBy (erasureRequestOf identity) (erasureMembershipOf state) erasureRecoverability = d
    cases d <;> simp
  rw [hmatch, NecoQuotient.judgeErasureBy_dematerialize_iff]
  simp [NecoQuotient.InputsComplete, erasureRequestOf, erasureMembershipOf, erasureRecoverability]

/-- When erasure is retained, the reasons name the future use and each outstanding signal, in that order. -/
theorem elideAdmissionProvenance_retention_reasons (state : DynamicAdmissionState) (identity : RequestIdentity)
    (entry : RequestEntry) (found : findByIdentity state.progression.entries identity = some entry)
    (terminal : isTerminalPhase entry.phase = true) (reasons : List ErasureRetention)
    (retained : elideAdmissionProvenance state identity = .rejected (.provenanceRetentionRequired identity reasons)) :
    (state.provenance.futureUses.contains identity = true →
        NecoQuotient.RetentionReason.futureUse identity ∈ reasons) ∧
      (state.provenance.outstandingSignals.any (fun s => s.identity == identity) = true →
        NecoQuotient.RetentionReason.outstandingSignal identity ∈ reasons) ∧
      (state.provenance.futureUses.contains identity = true →
        state.provenance.outstandingSignals.any (fun s => s.identity == identity) = true →
        reasons = [NecoQuotient.RetentionReason.futureUse identity, NecoQuotient.RetentionReason.outstandingSignal identity]) := by
  by_cases hf : state.provenance.futureUses.contains identity = true <;>
  by_cases hs : state.provenance.outstandingSignals.any (fun s => s.identity == identity) = true
  · have hfm : identity ∈ state.provenance.futureUses := by simpa using hf
    have hsm : ∃ x, x ∈ state.provenance.outstandingSignals ∧ x.identity = identity := by simpa using hs
    rw [future_use_blocks_erasure state identity entry found terminal hf] at retained
    simp [hsm] at retained
    subst retained
    simp [hfm, hsm]
  · have hfm : identity ∈ state.provenance.futureUses := by simpa using hf
    have hsm : ¬ ∃ x, x ∈ state.provenance.outstandingSignals ∧ x.identity = identity := by simpa using hs
    rw [future_use_blocks_erasure state identity entry found terminal hf] at retained
    simp [hsm] at retained
    subst retained
    simp [hfm, hsm]
  · have hfm : identity ∉ state.provenance.futureUses := by simpa using hf
    have hsm : ∃ x, x ∈ state.provenance.outstandingSignals ∧ x.identity = identity := by simpa using hs
    rw [outstanding_signal_blocks_erasure state identity entry found terminal hs] at retained
    simp [hfm] at retained
    subst retained
    simp [hfm, hsm]
  · rw [elideAdmissionProvenance, found] at retained
    simp only [terminal, Bool.not_true, Bool.false_eq_true, if_false] at retained
    rw [erasure_judgment_dematerialize state identity (by simpa using hf) (by simpa using hs)] at retained
    simp at retained

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

def AdmissionDecision.state : AdmissionDecision → DynamicAdmissionState
  | .submitted state _ => state
  | .started state _ => state
  | .coalesced state _ => state

private theorem replaceByIdentity_identities (entries : List RequestEntry) (identity : RequestIdentity)
    (entry replacement : RequestEntry) (found : findByIdentity entries identity = some entry)
    (same : replacement.identity = entry.identity) :
    (replaceByIdentity entries identity replacement).map (·.identity) = entries.map (·.identity) := by
  have held : entry.identity = identity := by
    unfold findByIdentity at found
    simpa using List.find?_some found
  unfold replaceByIdentity
  rw [List.map_map]
  apply List.map_congr_left
  intro other _
  by_cases matched : other.identity = identity <;> simp [matched, same, held]

theorem elideAdmissionProvenance_preserves_identities_distinct (state next : DynamicAdmissionState)
    (identity : RequestIdentity) (witness : ErasureWitness)
    (distinct : IdentitiesDistinct state.progression)
    (elided : elideAdmissionProvenance state identity = .applied (next, witness)) :
    IdentitiesDistinct next.progression := by
  unfold elideAdmissionProvenance at elided
  split at elided
  · cases elided
  · rename_i entry found
    repeat' split at elided
    all_goals simp only [Outcome.applied.injEq, Prod.mk.injEq, reduceCtorEq] at elided
    obtain ⟨stateEq, _⟩ := elided
    subst stateEq
    show ((replaceByIdentity state.progression.entries identity (eraseEntryProvenance entry)).map
      (·.identity)).Nodup
    rw [replaceByIdentity_identities _ _ entry (eraseEntryProvenance entry) found rfl]
    exact distinct

private theorem findByIdentity_replaceByIdentity_self (entries : List RequestEntry)
    (identity : RequestIdentity) (entry replacement : RequestEntry)
    (found : findByIdentity entries identity = some entry)
    (same : replacement.identity = identity) :
    findByIdentity (replaceByIdentity entries identity replacement) identity = some replacement := by
  unfold findByIdentity replaceByIdentity at *
  induction entries with
  | nil => simp at found
  | cons e es ih =>
    rw [List.map_cons]
    by_cases he : e.identity = identity
    · have hcond : (e.identity == identity) = true := by simp [he]
      have hrep : (replacement.identity == identity) = true := by simp [same]
      rw [show (if e.identity == identity then replacement else e) = replacement by simp [hcond]]
      simp [hrep]
    · have hcond : (e.identity == identity) = false := by rw [beq_eq_false_iff_ne]; exact he
      rw [show (if e.identity == identity then replacement else e) = e by simp [hcond]]
      simp only [List.find?_cons, hcond] at found ⊢
      exact ih found

private theorem replaceByIdentity_idem (entries : List RequestEntry)
    (identity : RequestIdentity) (replacement : RequestEntry)
    (same : replacement.identity = identity) :
    replaceByIdentity (replaceByIdentity entries identity replacement) identity replacement =
      replaceByIdentity entries identity replacement := by
  unfold replaceByIdentity
  rw [List.map_map]
  apply List.map_congr_left
  intro e _
  by_cases he : e.identity = identity
  · simp [he, same]
  · simp [he]

private theorem eraseEntryProvenance_idem (entry : RequestEntry) :
    eraseEntryProvenance (eraseEntryProvenance entry) = eraseEntryProvenance entry := by
  cases entry with
  | mk id fp dm ph mp cs =>
    cases mp <;> simp [eraseEntryProvenance, eraseMeaningPermissionEvidence]

/-- A second erasure request for the same identity succeeds with the same witness and leaves `next` unchanged. -/
theorem elideAdmissionProvenance_idempotent (state next : DynamicAdmissionState)
    (identity : RequestIdentity) (witness : ErasureWitness)
    (elided : elideAdmissionProvenance state identity = .applied (next, witness)) :
    elideAdmissionProvenance next identity = .applied (next, witness) := by
  unfold elideAdmissionProvenance at elided
  cases hfind : findByIdentity state.progression.entries identity with
  | none =>
    simp [hfind] at elided
  | some entry =>
    simp only [hfind] at elided
    cases hterm : isTerminalPhase entry.phase with
    | false =>
      simp [hterm] at elided
    | true =>
      simp only [hterm, Bool.not_true, Bool.false_eq_true, if_false] at elided
      cases hjudge : NecoQuotient.judgeErasureBy (erasureRequestOf identity) (erasureMembershipOf state) erasureRecoverability with
      | retain _ => simp [hjudge] at elided
      | rejected _ => simp [hjudge] at elided
      | dematerialize w =>
        simp only [hjudge, Outcome.applied.injEq, Prod.mk.injEq] at elided
        obtain ⟨hnext, hw⟩ := elided
        subst hnext
        subst hw
        have hEntryId : entry.identity = identity := by
          unfold findByIdentity at hfind
          simpa using List.find?_some hfind
        have hErasedId : (eraseEntryProvenance entry).identity = identity := by
          simpa [eraseEntryProvenance] using hEntryId
        have hFindNext :
            findByIdentity (replaceByIdentity state.progression.entries identity (eraseEntryProvenance entry)) identity =
              some (eraseEntryProvenance entry) :=
          findByIdentity_replaceByIdentity_self _ _ entry (eraseEntryProvenance entry) hfind hErasedId
        have hTermNext : isTerminalPhase (eraseEntryProvenance entry).phase = true := by
          simpa [eraseEntryProvenance] using hterm
        have hNoFuture :
            (state.provenance.futureUses.filter (fun i => i != identity)).contains identity = false := by
          simp
        have hNoSignal :
            (state.provenance.outstandingSignals.filter (fun s => s.identity != identity)).any
              (fun s => s.identity == identity) = false := by
          simp
        have hW :
            w = { target := identity, recoverability := .irrecoverable, removedObservations := [.footprint, .evidence] } := by
          unfold NecoQuotient.judgeErasureBy NecoQuotient.decideWithBy erasureRecoverability at hjudge
          simp only [erasureRequestOf] at hjudge
          split at hjudge
          · cases hjudge; rfl
          · simp at hjudge
        rw [hW]
        rw [empty_provenance_erases_target_entry_only _ identity (eraseEntryProvenance entry) hFindNext hTermNext hNoFuture hNoSignal]
        simp [eraseEntryProvenance_idem, replaceByIdentity_idem _ identity (eraseEntryProvenance entry) hErasedId, List.filter_filter]

theorem admitDynamicRequest_preserves_identities_distinct (input : DynamicAdmissionInput)
    (result : DynamicAdmissionResult) (distinct : IdentitiesDistinct input.state.progression)
    (admitted : admitDynamicRequest input = .applied result) :
    IdentitiesDistinct result.admissionDecision.state.progression := by
  have budgeted : ∀ budget : ResourceBudget,
      IdentitiesDistinct { input.state.progression with budget := budget } := fun _ => distinct
  unfold admitDynamicRequest at admitted
  by_cases expired : observationAge input > input.environmentSpecification.maxObservationAge
  · simp [expired] at admitted
  simp only [expired, if_false] at admitted
  repeat' split at admitted
  all_goals simp only [Outcome.applied.injEq, reduceCtorEq] at admitted
  all_goals subst admitted
  all_goals simp only [AdmissionDecision.state]
  all_goals first
    | exact distinct
    | (have accepted := submit_preserves_identities_distinct _ input.request
         (budgeted (effectiveBudgetOf input.state.configuredSafetyLimit input.capacityObservation.observed))
       simp only [‹submit _ _ = SubmitResult.accepted _ _›, SubmitResult.snapshot] at accepted
       first
         | exact accepted
         | (have shape := congrArg StartDecisionResult.snapshot ‹decideStart _ _ _ = _›
            simp only [StartDecisionResult.snapshot] at shape
            rw [← shape]
            exact decideStart_preserves_identities_distinct _ _ _ accepted))

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
#print axioms elideAdmissionProvenance_dematerialize_iff
#print axioms elideAdmissionProvenance_retention_reasons
#print axioms elideAdmissionProvenance_preserves_identities_distinct
#print axioms elideAdmissionProvenance_idempotent
#print axioms admitDynamicRequest_preserves_identities_distinct

end Necoherence
