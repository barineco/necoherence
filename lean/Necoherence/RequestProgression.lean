-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

namespace Necoherence

/-- Policy for completion acceptance and request start order. -/
inductive RequestPolicy where
  | latestWins
  | fifo
  | allExecute
  deriving DecidableEq, Repr

/-- Progress phase of a request entry. `Preparing` is the actual phase after a command is derived and before
an adapter start observation is applied. -/
inductive RequestPhase where
  | pending
  | preparing
  | publishing
  | published
  | superseded
  | cancelled
  | failed
  deriving DecidableEq, Repr

/-- Effect classification of a footprint. `orderedEffect` does not grant automatic parallel execution. -/
inductive RequestEffectClass where
  | pure
  | orderedEffect
  deriving DecidableEq, Repr

/-- Identity that retains the input basis for each request kind. -/
structure RequestIdentity where
  kind : String
  provenance : String
  revision : Nat
  deriving DecidableEq, Repr

/-- Request-specific footprint used to decide meaning-level permission. -/
structure RequestFootprint where
  reads : List String
  writes : List String
  effectClass : RequestEffectClass
  deriving DecidableEq, Repr

/-- Demand or occupancy along the pending, in-flight, and concurrent axes. Each component is a Natural (Nat). -/
structure ResourceDemand where
  pending : Nat
  inFlight : Nat
  concurrent : Nat
  deriving DecidableEq, Repr

/-- Fixed limit declared by the configuration. The resource identifies an axis, and the maximum is a Natural (Nat). -/
structure ConfiguredSafetyLimit where
  resource : String
  maximum : Nat
  deriving DecidableEq, Repr

/-- Fixed budget that retains a `ConfiguredSafetyLimit` for each of the three axes. -/
structure ResourceBudget where
  pendingMaximum : ConfiguredSafetyLimit
  inFlightMaximum : ConfiguredSafetyLimit
  concurrentMaximum : ConfiguredSafetyLimit
  deriving DecidableEq, Repr

/-- Versioned evidence identified by a name, digest, and artifact path. -/
structure EvidenceVersion where
  identifier : String
  digest : String
  artifactPath : String
  deriving DecidableEq, Repr

/-- Reason why meaning-level permission was denied. -/
inductive PermissionDenial where
  | denial : String → PermissionDenial
  deriving DecidableEq, Repr

/-- Evidence-backed permission for starting a request. `ordered` allows an
`OrderedEffect` request to start in policy order; `permitted` does not. -/
inductive MeaningPermission where
  | permitted : RequestIdentity → List EvidenceVersion → MeaningPermission
  | ordered : RequestIdentity → List EvidenceVersion → MeaningPermission
  | denied : RequestIdentity → PermissionDenial → MeaningPermission
  deriving DecidableEq, Repr

/-- Execution handle issued by the adapter. -/
structure ExecutionHandle where
  value : String
  deriving DecidableEq, Repr

/-- Cost-based selection between immediate execution and remaining pending. -/
inductive CostSelection where
  | executeNow : RequestIdentity → EvidenceVersion → Nat → CostSelection
  | remainPending : RequestIdentity → EvidenceVersion → Nat → CostSelection
  deriving DecidableEq, Repr

/-- Current value of a request retained by the snapshot. -/
structure RequestEntry where
  identity : RequestIdentity
  footprint : RequestFootprint
  demand : ResourceDemand
  phase : RequestPhase
  meaningPermission : MeaningPermission
  costSelection : Option CostSelection
  executionHandle : Option ExecutionHandle
  deriving DecidableEq, Repr

/-- Sole source of truth for request progression. It retains the identity, phase, footprint, demand, permission,
selection, and handle. -/
structure RequestProgressionSnapshot where
  policy : RequestPolicy
  budget : ResourceBudget
  currentIdentity : Option RequestIdentity
  entries : List RequestEntry
  revision : Nat
  deriving DecidableEq, Repr

/-- Input surface for submit. It supplies the identity, footprint, demand, and permission together. -/
structure RequestInput where
  identity : RequestIdentity
  footprint : RequestFootprint
  demand : ResourceDemand
  permission : MeaningPermission
  deriving DecidableEq, Repr

/-- Typed token that retains an identity accepted by `submit`. `decideStart` accepts only this token, so its type
excludes start decisions for identities that have no `Accepted` value. -/
structure Accepted where
  identity : RequestIdentity
  deriving DecidableEq, Repr

/-- Start or cancellation command passed to the adapter. -/
inductive AdapterCommand where
  | startCommand : RequestIdentity → RequestFootprint → AdapterCommand
  | cancelCommand : RequestIdentity → ExecutionHandle → AdapterCommand
  deriving DecidableEq, Repr

/-- Typed token checked by `applyStartObservation` after `decideStart` derives a command. It retains the identity
and the derived StartCommand. -/
structure Starting where
  identity : RequestIdentity
  command : AdapterCommand
  deriving DecidableEq, Repr

/-- Typed token that retains the identity advanced to `Publishing` by `applyStartObservation` and the observed
handle. `applyCompletionObservation` accepts only this token, so its type excludes applying observations to
identities that have no `Running` value. -/
structure Running where
  identity : RequestIdentity
  handle : ExecutionHandle
  deriving DecidableEq, Repr

/-- Signal observed from the adapter. The `Result` of `completed` retains the complete value unchanged. -/
inductive AdapterSignal (Result : Type) where
  | started : RequestIdentity → ExecutionHandle → AdapterSignal Result
  | completed : RequestIdentity → ExecutionHandle → Result → AdapterSignal Result
  | cancelledAtAdapter : RequestIdentity → ExecutionHandle → AdapterSignal Result
  deriving DecidableEq, Repr

/-- Failure observed from the adapter. -/
inductive AdapterFailure where
  | startAdapterFailure : RequestIdentity → String → AdapterFailure
  | completionAdapterFailure : RequestIdentity → ExecutionHandle → String → AdapterFailure
  | cancellationAdapterFailure : RequestIdentity → ExecutionHandle → String → AdapterFailure
  deriving DecidableEq, Repr

/-- Observed adapter result for a command. Lean does not execute the adapter and consumes this value as input to
a pure function. -/
inductive AdapterResult (Signal Failure : Type) where
  | appliedSignal : Signal → AdapterResult Signal Failure
  | adapterFailed : Failure → AdapterResult Signal Failure
  deriving DecidableEq, Repr

/-- Reason why submit rejects a request. -/
inductive SubmitFailure where
  | duplicateIdentity : RequestIdentity → SubmitFailure
  | pendingLimitExceeded : ResourceDemand → ResourceBudget → SubmitFailure
  deriving DecidableEq, Repr

/-- Closed result of submit. Success returns an `Accepted` token. -/
inductive SubmitResult where
  | accepted : RequestProgressionSnapshot → Accepted → SubmitResult
  | submitRejected : RequestProgressionSnapshot → SubmitFailure → SubmitResult
  deriving DecidableEq, Repr

/-- Reason why `decideStart` rejects a request before deriving a command. -/
inductive StartDecisionFailure where
  | unknownRequest : RequestIdentity → StartDecisionFailure
  | requestNotPending : RequestIdentity → StartDecisionFailure
  | policyOrderBlocked : RequestIdentity → StartDecisionFailure
  | permissionDenied : RequestIdentity → PermissionDenial → StartDecisionFailure
  | permissionIdentityMismatch : RequestIdentity → RequestIdentity → StartDecisionFailure
  | permissionNotOrdered : RequestIdentity → StartDecisionFailure
  | costSelectionIdentityMismatch : RequestIdentity → RequestIdentity → StartDecisionFailure
  | inFlightLimitExceeded : ResourceDemand → ResourceBudget → StartDecisionFailure
  | concurrentLimitExceeded : ResourceDemand → ResourceBudget → StartDecisionFailure
  deriving DecidableEq, Repr

/-- Closed result of `decideStart`. `execute` derives a command, moves the entry to `Preparing`, and returns a
`Starting` token and StartCommand. `deferred` applies `RemainPending`. `rejected` returns a closed failure before
command derivation. -/
inductive StartDecisionResult where
  | execute : RequestProgressionSnapshot → Starting → AdapterCommand → StartDecisionResult
  | deferred : RequestProgressionSnapshot → Accepted → StartDecisionResult
  | rejected : RequestProgressionSnapshot → StartDecisionFailure → StartDecisionResult
  deriving DecidableEq, Repr

/-- Reason why `applyStartObservation` rejects an observation. It explicitly distinguishes an adapter observation
with a mismatched identity after command derivation, a mismatched signal kind, and an adapter failure. -/
inductive StartObservationFailure where
  | unknownRequest : RequestIdentity → StartObservationFailure
  | requestNotStarting : RequestIdentity → StartObservationFailure
  | startIdentityMismatch : RequestIdentity → RequestIdentity → StartObservationFailure
  | startSignalMismatch : RequestIdentity → StartObservationFailure
  | startAdapterFailureObserved : RequestIdentity → String → StartObservationFailure
  deriving DecidableEq, Repr

/-- Closed result of `applyStartObservation`. `publishing` returns a `Running` token when the `Started` signal
matches. `failed` returns a closed failure when the observation does not match. -/
inductive StartObservationResult where
  | publishing : RequestProgressionSnapshot → Running → StartObservationResult
  | failed : RequestProgressionSnapshot → StartObservationFailure → StartObservationResult
  deriving DecidableEq, Repr

/-- Reason why `applyCompletionObservation` rejects an observation. It explicitly distinguishes identity or
handle mismatches from adapter failures. -/
inductive CompletionObservationFailure where
  | unknownCompletion : RequestIdentity → CompletionObservationFailure
  | completionNotRunning : RequestIdentity → CompletionObservationFailure
  | handleMismatch : RequestIdentity → CompletionObservationFailure
  | completionIdentityMismatch : RequestIdentity → RequestIdentity → CompletionObservationFailure
  | completionSignalMismatch : RequestIdentity → CompletionObservationFailure
  | completionAdapterFailureObserved : RequestIdentity → String → CompletionObservationFailure
  | cancellationAdapterFailureObserved : RequestIdentity → String → CompletionObservationFailure
  deriving DecidableEq, Repr

/-- Closed result of `applyCompletionObservation`. `Result` retains the adapter's `Completed` value unchanged.
`superseded` is a stale completion under `LatestWins` and leaves the newer request unchanged. `cancelled` represents
`CancelledAtAdapter`. -/
inductive CompletionObservationResult (Result : Type) where
  | applied : RequestProgressionSnapshot → RequestIdentity → Result → CompletionObservationResult Result
  | superseded : RequestProgressionSnapshot → RequestIdentity → CompletionObservationResult Result
  | cancelled : RequestProgressionSnapshot → RequestIdentity → CompletionObservationResult Result
  | failed : RequestProgressionSnapshot → CompletionObservationFailure → CompletionObservationResult Result
  deriving DecidableEq, Repr

/-- Reason why `decideCancel` rejects a request. -/
inductive CancelFailure where
  | unknownRequest : RequestIdentity → CancelFailure
  | requestAlreadyTerminal : RequestIdentity → CancelFailure
  | missingExecutionHandle : RequestIdentity → CancelFailure
  deriving DecidableEq, Repr

/-- Closed result of `decideCancel`. A `Pending` entry advances to `Cancelled` without an adapter. A `Publishing`
entry returns a `CancelCommand` and `Running` token without changing the snapshot; subsequent adapter observations
are applied by `applyCompletionObservation`. A `Preparing` entry returns a closed failure because it has no handle. -/
inductive CancelDecisionResult where
  | cancelled : RequestProgressionSnapshot → RequestIdentity → CancelDecisionResult
  | cancelCommand : RequestProgressionSnapshot → Running → AdapterCommand → CancelDecisionResult
  | rejected : RequestProgressionSnapshot → CancelFailure → CancelDecisionResult
  deriving DecidableEq, Repr

/-- Empty snapshot containing only a policy and budget. -/
def empty (policy : RequestPolicy) (budget : ResourceBudget) : RequestProgressionSnapshot :=
  { policy := policy, budget := budget, currentIdentity := none, entries := [], revision := 0 }

private def findEntry (entries : List RequestEntry) (identity : RequestIdentity) : Option RequestEntry :=
  entries.find? (fun entry => entry.identity == identity)

private def replaceEntry (entries : List RequestEntry) (identity : RequestIdentity) (replacement : RequestEntry) : List RequestEntry :=
  entries.map (fun entry => if entry.identity == identity then replacement else entry)

/-- Sum of all three `ResourceDemand` components for `Pending` entries. This function depends only on phase and
demand. Submit compares the `.pending` component with `pendingMaximum`. -/
def derivePending (snapshot : RequestProgressionSnapshot) : ResourceDemand :=
  (snapshot.entries.filter (fun entry => entry.phase == .pending)).foldl
    (fun total entry =>
      { pending := total.pending + entry.demand.pending,
        inFlight := total.inFlight + entry.demand.inFlight,
        concurrent := total.concurrent + entry.demand.concurrent })
    { pending := 0, inFlight := 0, concurrent := 0 }

/-- Sum of all three `ResourceDemand` components for `Preparing` and `Publishing` entries. This function depends
only on phase and demand. decideStart compares the `.inFlight` component with `inFlightMaximum`. -/
def deriveInFlight (snapshot : RequestProgressionSnapshot) : ResourceDemand :=
  (snapshot.entries.filter (fun entry => entry.phase == .preparing || entry.phase == .publishing)).foldl
    (fun total entry =>
      { pending := total.pending + entry.demand.pending,
        inFlight := total.inFlight + entry.demand.inFlight,
        concurrent := total.concurrent + entry.demand.concurrent })
    { pending := 0, inFlight := 0, concurrent := 0 }

/-- Sum of all three `ResourceDemand` components for `Publishing` entries. This function depends only on phase and
demand. decideStart compares the `.concurrent` component with `concurrentMaximum`. -/
def deriveConcurrent (snapshot : RequestProgressionSnapshot) : ResourceDemand :=
  (snapshot.entries.filter (fun entry => entry.phase == .publishing)).foldl
    (fun total entry =>
      { pending := total.pending + entry.demand.pending,
        inFlight := total.inFlight + entry.demand.inFlight,
        concurrent := total.concurrent + entry.demand.concurrent })
    { pending := 0, inFlight := 0, concurrent := 0 }


private def policyOrderAllowed (snapshot : RequestProgressionSnapshot) (identity : RequestIdentity) : Bool :=
  match snapshot.policy with
  | .latestWins => snapshot.currentIdentity == some identity
  | .allExecute => true
  | .fifo =>
    match snapshot.entries.find? (fun entry => entry.phase == .pending) with
    | some earliest => earliest.identity == identity
    | none => false


private def orderedEffectAllowed (snapshot : RequestProgressionSnapshot) (identity : RequestIdentity) (entry : RequestEntry) : Bool :=
  if entry.footprint.effectClass != .orderedEffect then true
  else
    match snapshot.entries.find? (fun e => e.phase == .pending && e.footprint.effectClass == .orderedEffect) with
    | some earliest => earliest.identity == identity
    | none => true

/-- Adds a request entry as `Pending`. `LatestWins` transitions existing pending entries to `Superseded`. This
preserves the meaning of existing valid inputs. -/
def submit (snapshot : RequestProgressionSnapshot) (request : RequestInput) : SubmitResult :=
  if (findEntry snapshot.entries request.identity).isSome then
    .submitRejected snapshot (.duplicateIdentity request.identity)
  else if (derivePending snapshot).pending + request.demand.pending > snapshot.budget.pendingMaximum.maximum then
    .submitRejected snapshot (.pendingLimitExceeded request.demand snapshot.budget)
  else
    let entry : RequestEntry :=
      { identity := request.identity, footprint := request.footprint, demand := request.demand,
        phase := .pending, meaningPermission := request.permission, costSelection := none,
        executionHandle := none }
    let entries :=
      match snapshot.policy with
      | .latestWins =>
        (snapshot.entries.map (fun e => if e.phase == .pending then { e with phase := .superseded } else e)) ++ [entry]
      | .fifo => snapshot.entries ++ [entry]
      | .allExecute => snapshot.entries ++ [entry]
    .accepted
      { snapshot with entries := entries, currentIdentity := some request.identity, revision := snapshot.revision + 1 }
      { identity := request.identity }


private def decideStartSelection (snapshot : RequestProgressionSnapshot) (accepted : Accepted)
    (entry : RequestEntry) (selection : CostSelection) : StartDecisionResult :=
  match selection with
  | .remainPending selIdentity _ _ =>
    if selIdentity != accepted.identity then
      .rejected snapshot (.costSelectionIdentityMismatch accepted.identity selIdentity)
    else
      .deferred
        { snapshot with entries := replaceEntry snapshot.entries accepted.identity { entry with costSelection := some selection } }
        accepted
  | .executeNow selIdentity _ _ =>
    if selIdentity != accepted.identity then
      .rejected snapshot (.costSelectionIdentityMismatch accepted.identity selIdentity)
    else if (deriveInFlight snapshot).inFlight + entry.demand.inFlight > snapshot.budget.inFlightMaximum.maximum then
      .rejected snapshot (.inFlightLimitExceeded entry.demand snapshot.budget)
    else if (deriveConcurrent snapshot).concurrent + entry.demand.concurrent > snapshot.budget.concurrentMaximum.maximum then
      .rejected snapshot (.concurrentLimitExceeded entry.demand snapshot.budget)
    else
      let command := AdapterCommand.startCommand accepted.identity entry.footprint
      let preparingEntry : RequestEntry :=
        { entry with phase := .preparing, costSelection := some selection }
      let advanced :=
        { snapshot with
          entries := replaceEntry snapshot.entries accepted.identity preparingEntry, revision := snapshot.revision + 1 }
      .execute advanced { identity := accepted.identity, command := command } command

/-- Considers only the `Pending` entry whose identity is carried by `Accepted`. After checking policy order,
`OrderedEffect` order, permission identity agreement, and the requirement that `OrderedEffect` starts only with
`Ordered` permission, it continues to `decideStartSelection`. It takes no adapter observation as input, so command
derivation precedes observation application. -/
def decideStart (snapshot : RequestProgressionSnapshot) (accepted : Accepted) (selection : CostSelection) :
    StartDecisionResult :=
  match findEntry snapshot.entries accepted.identity with
  | none => .rejected snapshot (.unknownRequest accepted.identity)
  | some entry =>
    if entry.phase != .pending then .rejected snapshot (.requestNotPending accepted.identity)
    else if !policyOrderAllowed snapshot accepted.identity then .rejected snapshot (.policyOrderBlocked accepted.identity)
    else if !orderedEffectAllowed snapshot accepted.identity entry then
      .rejected snapshot (.policyOrderBlocked accepted.identity)
    else
      match entry.meaningPermission with
      | .denied _ reason => .rejected snapshot (.permissionDenied accepted.identity reason)
      | .permitted permIdentity _ =>
        if permIdentity != accepted.identity then
          .rejected snapshot (.permissionIdentityMismatch accepted.identity permIdentity)
        else if entry.footprint.effectClass == .orderedEffect then
          .rejected snapshot (.permissionNotOrdered accepted.identity)
        else
          decideStartSelection snapshot accepted entry selection
      | .ordered permIdentity _ =>
        if permIdentity != accepted.identity then
          .rejected snapshot (.permissionIdentityMismatch accepted.identity permIdentity)
        else
          decideStartSelection snapshot accepted entry selection

/-- Commits an observed `Started` signal to a `Running` token in `Publishing` only when it matches the `Preparing`
entry whose identity is carried by the `Starting` token. A mismatched signal kind or adapter failure transitions the
entry to `Failed`. An identity mismatch is returned as a closed failure. -/
def applyStartObservation {Result : Type} (snapshot : RequestProgressionSnapshot) (starting : Starting)
    (observed : AdapterResult (AdapterSignal Result) AdapterFailure) : StartObservationResult :=
  match findEntry snapshot.entries starting.identity with
  | none => .failed snapshot (.unknownRequest starting.identity)
  | some entry =>
    if entry.phase != .preparing then .failed snapshot (.requestNotStarting starting.identity)
    else
      match observed with
      | .appliedSignal (.started signalIdentity handle) =>
        if signalIdentity == starting.identity then
          let publishedEntry : RequestEntry :=
            { entry with phase := .publishing, executionHandle := some handle }
          .publishing
            { snapshot with
              entries := replaceEntry snapshot.entries starting.identity publishedEntry, revision := snapshot.revision + 1 }
            { identity := starting.identity, handle := handle }
        else
          let failedEntry : RequestEntry := { entry with phase := .failed }
          .failed
            { snapshot with
              entries := replaceEntry snapshot.entries starting.identity failedEntry, revision := snapshot.revision + 1 }
            (.startIdentityMismatch starting.identity signalIdentity)
      | .appliedSignal (.completed _ _ _) | .appliedSignal (.cancelledAtAdapter _ _) =>
        let failedEntry : RequestEntry := { entry with phase := .failed }
        .failed
          { snapshot with
            entries := replaceEntry snapshot.entries starting.identity failedEntry, revision := snapshot.revision + 1 }
          (.startSignalMismatch starting.identity)
      | .adapterFailed (.startAdapterFailure failureIdentity detail) =>
        let failedEntry : RequestEntry := { entry with phase := .failed }
        let advanced :=
          { snapshot with
            entries := replaceEntry snapshot.entries starting.identity failedEntry, revision := snapshot.revision + 1 }
        if failureIdentity == starting.identity then
          .failed advanced (.startAdapterFailureObserved starting.identity detail)
        else
          .failed advanced (.startIdentityMismatch starting.identity failureIdentity)
      | .adapterFailed (.completionAdapterFailure _ _ _) | .adapterFailed (.cancellationAdapterFailure _ _ _) =>
        let failedEntry : RequestEntry := { entry with phase := .failed }
        .failed
          { snapshot with
            entries := replaceEntry snapshot.entries starting.identity failedEntry, revision := snapshot.revision + 1 }
          (.startSignalMismatch starting.identity)

/-- Applies an observed `Completed`, `CancelledAtAdapter`, `CompletionAdapterFailure`, or
`CancellationAdapterFailure` only when the identity and handle carried by the `Running` token match the `Publishing`
entry. The `Completed` value is retained in the result. A `current_identity` mismatch under `LatestWins` transitions
the entry to `Superseded`. -/
def applyCompletionObservation {Result : Type} (snapshot : RequestProgressionSnapshot) (running : Running)
    (observed : AdapterResult (AdapterSignal Result) AdapterFailure) : CompletionObservationResult Result :=
  match findEntry snapshot.entries running.identity with
  | none => .failed snapshot (.unknownCompletion running.identity)
  | some entry =>
    if entry.phase != .publishing then .failed snapshot (.completionNotRunning running.identity)
    else if entry.executionHandle != some running.handle then .failed snapshot (.handleMismatch running.identity)
    else
      match observed with
      | .appliedSignal (.completed signalIdentity signalHandle value) =>
        if signalIdentity != running.identity then
          .failed snapshot (.completionIdentityMismatch running.identity signalIdentity)
        else if signalHandle != running.handle then
          .failed snapshot (.handleMismatch running.identity)
        else
          match snapshot.policy with
          | .latestWins =>
            if snapshot.currentIdentity != some running.identity then
              let supersededEntry : RequestEntry := { entry with phase := .superseded }
              .superseded
                { snapshot with entries := replaceEntry snapshot.entries running.identity supersededEntry }
                running.identity
            else
              let publishedEntry : RequestEntry := { entry with phase := .published }
              .applied
                { snapshot with
                  entries := replaceEntry snapshot.entries running.identity publishedEntry, revision := snapshot.revision + 1 }
                running.identity value
          | .fifo | .allExecute =>
            let publishedEntry : RequestEntry := { entry with phase := .published }
            .applied
              { snapshot with
                entries := replaceEntry snapshot.entries running.identity publishedEntry, revision := snapshot.revision + 1 }
              running.identity value
      | .appliedSignal (.cancelledAtAdapter signalIdentity signalHandle) =>
        if signalIdentity != running.identity then
          .failed snapshot (.completionIdentityMismatch running.identity signalIdentity)
        else if signalHandle != running.handle then
          .failed snapshot (.handleMismatch running.identity)
        else
          let cancelledEntry : RequestEntry := { entry with phase := .cancelled }
          .cancelled
            { snapshot with
              entries := replaceEntry snapshot.entries running.identity cancelledEntry, revision := snapshot.revision + 1 }
            running.identity
      | .appliedSignal (.started _ _) => .failed snapshot (.completionSignalMismatch running.identity)
      | .adapterFailed (.completionAdapterFailure failureIdentity failureHandle detail) =>
        if failureIdentity != running.identity then
          .failed snapshot (.completionIdentityMismatch running.identity failureIdentity)
        else if failureHandle != running.handle then
          .failed snapshot (.handleMismatch running.identity)
        else
          let failedEntry : RequestEntry := { entry with phase := .failed }
          .failed
            { snapshot with
              entries := replaceEntry snapshot.entries running.identity failedEntry, revision := snapshot.revision + 1 }
            (.completionAdapterFailureObserved running.identity detail)
      | .adapterFailed (.cancellationAdapterFailure failureIdentity failureHandle detail) =>
        if failureIdentity != running.identity then
          .failed snapshot (.completionIdentityMismatch running.identity failureIdentity)
        else if failureHandle != running.handle then
          .failed snapshot (.handleMismatch running.identity)
        else
          let failedEntry : RequestEntry := { entry with phase := .failed }
          .failed
            { snapshot with
              entries := replaceEntry snapshot.entries running.identity failedEntry, revision := snapshot.revision + 1 }
            (.cancellationAdapterFailureObserved running.identity detail)
      | .adapterFailed (.startAdapterFailure _ _) => .failed snapshot (.completionSignalMismatch running.identity)

/-- A `Pending` entry advances to `Cancelled` without an adapter. A `Publishing` entry returns a `CancelCommand`
and `Running` token without changing the snapshot; subsequent adapter observations are applied by
`applyCompletionObservation`. A `Preparing` entry returns a closed failure because it has no handle. -/
def decideCancel (snapshot : RequestProgressionSnapshot) (identity : RequestIdentity) : CancelDecisionResult :=
  match findEntry snapshot.entries identity with
  | none => .rejected snapshot (.unknownRequest identity)
  | some entry =>
    match entry.phase with
    | .pending =>
      let cancelledEntry : RequestEntry := { entry with phase := .cancelled }
      .cancelled
        { snapshot with
          entries := replaceEntry snapshot.entries identity cancelledEntry, revision := snapshot.revision + 1 }
        identity
    | .publishing =>
      match entry.executionHandle with
      | none => .rejected snapshot (.missingExecutionHandle identity)
      | some handle =>
        .cancelCommand snapshot { identity := identity, handle := handle } (AdapterCommand.cancelCommand identity handle)
    | .preparing => .rejected snapshot (.missingExecutionHandle identity)
    | _ => .rejected snapshot (.requestAlreadyTerminal identity)

theorem submit_duplicate_is_rejected (snapshot : RequestProgressionSnapshot) (request : RequestInput)
    (found : (findEntry snapshot.entries request.identity).isSome = true) :
    submit snapshot request = .submitRejected snapshot (.duplicateIdentity request.identity) := by
  simp [submit, found]

/-- A successful submit returns an `Accepted` token retaining the request identity unchanged and updates
`current_identity`. The `Accepted` value required by `decideStart` can be constructed only through this path. -/
theorem submit_success_returns_accepted (snapshot advanced : RequestProgressionSnapshot) (request : RequestInput)
    (accepted : Accepted) (result : submit snapshot request = .accepted advanced accepted) :
    accepted.identity = request.identity ∧ advanced.currentIdentity = some request.identity := by
  unfold submit at result
  split at result
  · cases result
  · split at result
    · cases result
    · injection result with heq1 heq2
      exact ⟨by rw [← heq2], by rw [← heq1]⟩

theorem decideStart_unknown_request_fails (snapshot : RequestProgressionSnapshot) (accepted : Accepted)
    (selection : CostSelection) (missing : findEntry snapshot.entries accepted.identity = none) :
    decideStart snapshot accepted selection = .rejected snapshot (.unknownRequest accepted.identity) := by
  simp [decideStart, missing]

theorem decideStart_denied_permission_fails (snapshot : RequestProgressionSnapshot) (accepted : Accepted)
    (entry : RequestEntry) (reason : PermissionDenial) (selection : CostSelection)
    (found : findEntry snapshot.entries accepted.identity = some entry) (pending : entry.phase = .pending)
    (order : policyOrderAllowed snapshot accepted.identity = true)
    (orderedOk : orderedEffectAllowed snapshot accepted.identity entry = true)
    (denied : entry.meaningPermission = .denied accepted.identity reason) :
    decideStart snapshot accepted selection = .rejected snapshot (.permissionDenied accepted.identity reason) := by
  simp [decideStart, found, pending, order, orderedOk, denied]

/-- For an `ExecuteNow` with valid `Ordered` permission, matching identity, permitted order, and sufficient budget,
`decideStart` derives a command, moves the entry to `Preparing`, and returns a `Starting` token and StartCommand. -/
theorem decideStart_execute_sets_preparing (snapshot : RequestProgressionSnapshot) (accepted : Accepted)
    (entry : RequestEntry) (evidence : List EvidenceVersion) (selectionEvidence : EvidenceVersion) (costRevision : Nat)
    (found : findEntry snapshot.entries accepted.identity = some entry)
    (pending : entry.phase = .pending)
    (order : policyOrderAllowed snapshot accepted.identity = true)
    (orderedOk : orderedEffectAllowed snapshot accepted.identity entry = true)
    (permission : entry.meaningPermission = .ordered accepted.identity evidence)
    (budget1 : ¬ (deriveInFlight snapshot).inFlight + entry.demand.inFlight > snapshot.budget.inFlightMaximum.maximum)
    (budget2 : ¬ (deriveConcurrent snapshot).concurrent + entry.demand.concurrent > snapshot.budget.concurrentMaximum.maximum) :
    decideStart snapshot accepted (.executeNow accepted.identity selectionEvidence costRevision) =
      .execute
        { snapshot with
          entries :=
            replaceEntry snapshot.entries accepted.identity
              { entry with
                phase := .preparing,
                costSelection := some (.executeNow accepted.identity selectionEvidence costRevision) },
          revision := snapshot.revision + 1 }
        { identity := accepted.identity,
          command := AdapterCommand.startCommand accepted.identity entry.footprint }
        (AdapterCommand.startCommand accepted.identity entry.footprint) := by
  simp [decideStart, decideStartSelection, found, pending, order, orderedOk, permission, budget1, budget2]

/-- When an earlier entry is both `Pending` and `OrderedEffect`, `decideStart` rejects an `OrderedEffect` request
with `PolicyOrderBlocked`, even under the `AllExecute` policy where general order is always permitted. This observes
that the request is excluded from the automatic parallel set. -/
theorem ordered_effect_not_auto_parallel (snapshot : RequestProgressionSnapshot) (accepted : Accepted)
    (entry : RequestEntry) (selection : CostSelection)
    (found : findEntry snapshot.entries accepted.identity = some entry) (pending : entry.phase = .pending)
    (order : policyOrderAllowed snapshot accepted.identity = true)
    (blocked : orderedEffectAllowed snapshot accepted.identity entry = false) :
    decideStart snapshot accepted selection = .rejected snapshot (.policyOrderBlocked accepted.identity) := by
  simp [decideStart, found, pending, order, blocked]

/-- `applyStartObservation` commits a matching `Started` signal to a `Running` token in `Publishing`. This observes
the accepted-before-start and starting-before-running causal order. -/
theorem applyStartObservation_success_sets_publishing {Result : Type} (snapshot : RequestProgressionSnapshot)
    (starting : Starting) (entry : RequestEntry) (handle : ExecutionHandle)
    (found : findEntry snapshot.entries starting.identity = some entry)
    (preparing : entry.phase = .preparing) :
    applyStartObservation (Result := Result) snapshot starting
        (.appliedSignal (.started starting.identity handle)) =
      .publishing
        { snapshot with
          entries :=
            replaceEntry snapshot.entries starting.identity
              { entry with phase := .publishing, executionHandle := some handle },
          revision := snapshot.revision + 1 }
        { identity := starting.identity, handle := handle } := by
  simp [applyStartObservation, found, preparing]

/-- Observing a mismatched `Started` signal transitions the `Preparing` entry to `Failed`. -/
theorem applyStartObservation_identity_mismatch_fails {Result : Type} (snapshot : RequestProgressionSnapshot)
    (starting : Starting) (entry : RequestEntry) (otherIdentity : RequestIdentity) (handle : ExecutionHandle)
    (found : findEntry snapshot.entries starting.identity = some entry)
    (preparing : entry.phase = .preparing) (differ : otherIdentity ≠ starting.identity) :
    applyStartObservation (Result := Result) snapshot starting
        (.appliedSignal (.started otherIdentity handle)) =
      .failed
        { snapshot with
          entries := replaceEntry snapshot.entries starting.identity { entry with phase := .failed },
          revision := snapshot.revision + 1 }
        (.startIdentityMismatch starting.identity otherIdentity) := by
  have hne : (otherIdentity == starting.identity) = false := by
    rw [beq_eq_false_iff_ne]; exact differ
  simp [applyStartObservation, found, preparing, hne]

theorem applyCompletionObservation_unknown_fails {Result : Type} (snapshot : RequestProgressionSnapshot) (running : Running)
    (observed : AdapterResult (AdapterSignal Result) AdapterFailure)
    (missing : findEntry snapshot.entries running.identity = none) :
    applyCompletionObservation snapshot running observed = .failed snapshot (.unknownCompletion running.identity) := by
  simp [applyCompletionObservation, missing]

/-- Under `LatestWins`, when the identity in `Running` does not match `current_identity`, a matching `Completed`
signal returns `Superseded` and transitions the entry to `Superseded`. -/
theorem applyCompletionObservation_stale_completion_is_superseded {Result : Type} (snapshot : RequestProgressionSnapshot)
    (running : Running) (entry : RequestEntry) (value : Result)
    (found : findEntry snapshot.entries running.identity = some entry) (publishing : entry.phase = .publishing)
    (handleSet : entry.executionHandle = some running.handle) (latestWins : snapshot.policy = .latestWins)
    (stale : snapshot.currentIdentity ≠ some running.identity) :
    applyCompletionObservation snapshot running (.appliedSignal (.completed running.identity running.handle value)) =
      .superseded
        { snapshot with entries := replaceEntry snapshot.entries running.identity { entry with phase := .superseded } }
        running.identity := by
  simp [applyCompletionObservation, found, publishing, handleSet, latestWins, stale]

/-- Observing a matching `CancelledAtAdapter` transitions the `Running` token in `Publishing` to `Cancelled`. -/
theorem applyCompletionObservation_cancelled_at_adapter_sets_cancelled {Result : Type} (snapshot : RequestProgressionSnapshot)
    (running : Running) (entry : RequestEntry) (found : findEntry snapshot.entries running.identity = some entry)
    (publishing : entry.phase = .publishing) (handleSet : entry.executionHandle = some running.handle) :
    applyCompletionObservation (Result := Result) snapshot running
        (.appliedSignal (.cancelledAtAdapter running.identity running.handle)) =
      .cancelled
        { snapshot with
          entries := replaceEntry snapshot.entries running.identity { entry with phase := .cancelled },
          revision := snapshot.revision + 1 }
        running.identity := by
  simp [applyCompletionObservation, found, publishing, handleSet]

/-- Observing a matching `CompletionAdapterFailure` transitions the `Running` token in `Publishing` to `Failed`. -/
theorem applyCompletionObservation_adapter_failure_sets_failed {Result : Type} (snapshot : RequestProgressionSnapshot)
    (running : Running) (entry : RequestEntry) (detail : String)
    (found : findEntry snapshot.entries running.identity = some entry)
    (publishing : entry.phase = .publishing) (handleSet : entry.executionHandle = some running.handle) :
    applyCompletionObservation (Result := Result) snapshot running
        (.adapterFailed (.completionAdapterFailure running.identity running.handle detail)) =
      .failed
        { snapshot with
          entries := replaceEntry snapshot.entries running.identity { entry with phase := .failed },
          revision := snapshot.revision + 1 }
        (.completionAdapterFailureObserved running.identity detail) := by
  simp [applyCompletionObservation, found, publishing, handleSet]

/-- Observing a matching `CancellationAdapterFailure` also transitions the `Running` token in `Publishing` to
`Failed`. -/
theorem applyCompletionObservation_cancellation_adapter_failure_sets_failed {Result : Type}
    (snapshot : RequestProgressionSnapshot) (running : Running) (entry : RequestEntry) (detail : String)
    (found : findEntry snapshot.entries running.identity = some entry) (publishing : entry.phase = .publishing)
    (handleSet : entry.executionHandle = some running.handle) :
    applyCompletionObservation (Result := Result) snapshot running
        (.adapterFailed (.cancellationAdapterFailure running.identity running.handle detail)) =
      .failed
        { snapshot with
          entries := replaceEntry snapshot.entries running.identity { entry with phase := .failed },
          revision := snapshot.revision + 1 }
        (.cancellationAdapterFailureObserved running.identity detail) := by
  simp [applyCompletionObservation, found, publishing, handleSet]

theorem decideCancel_unknown_fails (snapshot : RequestProgressionSnapshot) (identity : RequestIdentity)
    (missing : findEntry snapshot.entries identity = none) :
    decideCancel snapshot identity = .rejected snapshot (.unknownRequest identity) := by
  simp [decideCancel, missing]

/-- `decideCancel` returns a `CancelCommand` and `Running` token for a `Publishing` entry while preserving the
snapshot itself ( phase preservation by `CancelCommand` ). Subsequent application is performed by
`applyCompletionObservation`. -/
theorem decideCancel_publishing_preserves_snapshot (snapshot : RequestProgressionSnapshot) (identity : RequestIdentity)
    (entry : RequestEntry) (handle : ExecutionHandle) (found : findEntry snapshot.entries identity = some entry)
    (publishing : entry.phase = .publishing) (handleSet : entry.executionHandle = some handle) :
    decideCancel snapshot identity =
      .cancelCommand snapshot { identity := identity, handle := handle } (AdapterCommand.cancelCommand identity handle) := by
  simp [decideCancel, found, publishing, handleSet]

/-- `decideCancel` rejects a `Preparing` entry because no handle is present. -/
theorem decideCancel_preparing_rejected_for_missing_handle (snapshot : RequestProgressionSnapshot)
    (identity : RequestIdentity) (entry : RequestEntry) (found : findEntry snapshot.entries identity = some entry)
    (preparing : entry.phase = .preparing) :
    decideCancel snapshot identity = .rejected snapshot (.missingExecutionHandle identity) := by
  simp [decideCancel, found, preparing]

theorem derivePending_depends_only_on_entries (s1 s2 : RequestProgressionSnapshot)
    (same : s1.entries = s2.entries) : derivePending s1 = derivePending s2 := by
  simp [derivePending, same]

theorem deriveInFlight_depends_only_on_entries (s1 s2 : RequestProgressionSnapshot)
    (same : s1.entries = s2.entries) : deriveInFlight s1 = deriveInFlight s2 := by
  simp [deriveInFlight, same]

theorem deriveConcurrent_depends_only_on_entries (s1 s2 : RequestProgressionSnapshot)
    (same : s1.entries = s2.entries) : deriveConcurrent s1 = deriveConcurrent s2 := by
  simp [deriveConcurrent, same]

#print axioms submit_duplicate_is_rejected
#print axioms submit_success_returns_accepted
#print axioms decideStart_unknown_request_fails
#print axioms decideStart_denied_permission_fails
#print axioms decideStart_execute_sets_preparing
#print axioms ordered_effect_not_auto_parallel
#print axioms applyStartObservation_success_sets_publishing
#print axioms applyStartObservation_identity_mismatch_fails
#print axioms applyCompletionObservation_unknown_fails
#print axioms applyCompletionObservation_stale_completion_is_superseded
#print axioms applyCompletionObservation_cancelled_at_adapter_sets_cancelled
#print axioms applyCompletionObservation_adapter_failure_sets_failed
#print axioms applyCompletionObservation_cancellation_adapter_failure_sets_failed
#print axioms decideCancel_unknown_fails
#print axioms decideCancel_publishing_preserves_snapshot
#print axioms decideCancel_preparing_rejected_for_missing_handle
#print axioms derivePending_depends_only_on_entries
#print axioms deriveInFlight_depends_only_on_entries
#print axioms deriveConcurrent_depends_only_on_entries

end Necoherence
