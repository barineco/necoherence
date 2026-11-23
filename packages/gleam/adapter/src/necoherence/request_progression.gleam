// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import necoherence/internal/position_chain.{type PositionChain}

pub type RequestPolicy {
  LatestWins
  Fifo
  AllExecute
}

pub type RequestPhase {
  Pending
  Preparing
  Publishing
  Published
  Superseded
  Cancelled
  Failed
}

pub type RequestEffectClass {
  PureEffect
  OrderedEffect
}

pub type RequestIdentity {
  RequestIdentity(kind: String, provenance: String, revision: Int)
}

pub type RequestFootprint {
  RequestFootprint(
    reads: List(String),
    writes: List(String),
    effect_class: RequestEffectClass,
  )
}

pub type ResourceDemand {
  ResourceDemand(pending: Int, in_flight: Int, concurrent: Int)
}

pub type ConfiguredSafetyLimit {
  ConfiguredSafetyLimit(resource: String, maximum: Int)
}

pub type ResourceBudget {
  ResourceBudget(
    pending_maximum: ConfiguredSafetyLimit,
    in_flight_maximum: ConfiguredSafetyLimit,
    concurrent_maximum: ConfiguredSafetyLimit,
  )
}

pub type EvidenceVersion {
  EvidenceVersion(identifier: String, digest: String, artifact_path: String)
}

pub type PermissionDenial {
  Denial(String)
}

pub type MeaningPermission {
  Permitted(identity: RequestIdentity, evidence: List(EvidenceVersion))
  Ordered(identity: RequestIdentity, evidence: List(EvidenceVersion))
  Denied(identity: RequestIdentity, reason: PermissionDenial)
}

pub type ExecutionHandle {
  ExecutionHandle(value: String)
}

pub type CostSelection {
  ExecuteNow(identity: RequestIdentity, evidence: EvidenceVersion, cost: Int)
  RemainPending(identity: RequestIdentity, evidence: EvidenceVersion, cost: Int)
}

pub type RequestEntry {
  RequestEntry(
    identity: RequestIdentity,
    footprint: RequestFootprint,
    demand: ResourceDemand,
    phase: RequestPhase,
    meaning_permission: MeaningPermission,
    cost_selection: Option(CostSelection),
    execution_handle: Option(ExecutionHandle),
  )
}

pub opaque type RequestProgressionSnapshot {
  RequestProgressionSnapshot(
    policy: RequestPolicy,
    budget: ResourceBudget,
    current_identity: Option(RequestIdentity),
    slots: Dict(Int, RequestEntry),
    count: Int,
    positions: Dict(RequestIdentity, Int),
    totals: PhaseTotals,
    pending: PositionChain,
    ordered_pending: PositionChain,
    revision: Int,
  )
}

type PhaseTotals {
  PhaseTotals(
    pending: ResourceDemand,
    in_flight: ResourceDemand,
    concurrent: ResourceDemand,
  )
}

pub type SnapshotFailure {
  DuplicateIdentity(identity: RequestIdentity)
}

pub type RequestInput {
  RequestInput(
    identity: RequestIdentity,
    footprint: RequestFootprint,
    demand: ResourceDemand,
    permission: MeaningPermission,
  )
}

pub type Accepted {
  Accepted(identity: RequestIdentity)
}

pub type AdapterCommand {
  StartCommand(identity: RequestIdentity, footprint: RequestFootprint)
  CancelCommand(identity: RequestIdentity, handle: ExecutionHandle)
}

pub type Starting {
  Starting(identity: RequestIdentity, command: AdapterCommand)
}

pub type Running {
  Running(identity: RequestIdentity, handle: ExecutionHandle)
}

pub type AdapterSignal(result) {
  Started(identity: RequestIdentity, handle: ExecutionHandle)
  Completed(identity: RequestIdentity, handle: ExecutionHandle, value: result)
  CancelledAtAdapter(identity: RequestIdentity, handle: ExecutionHandle)
}

pub type AdapterFailure {
  StartAdapterFailure(identity: RequestIdentity, detail: String)
  CompletionAdapterFailure(
    identity: RequestIdentity,
    handle: ExecutionHandle,
    detail: String,
  )
  CancellationAdapterFailure(
    identity: RequestIdentity,
    handle: ExecutionHandle,
    detail: String,
  )
}

pub type AdapterResult(result) {
  AppliedSignal(AdapterSignal(result))
  AdapterFailed(AdapterFailure)
}

pub type SubmitFailure {
  SubmitDuplicateIdentity(identity: RequestIdentity)
  SubmitPendingLimitExceeded(demand: ResourceDemand, budget: ResourceBudget)
}

pub type SubmitResult {
  SubmitAccepted(snapshot: RequestProgressionSnapshot, accepted: Accepted)
  SubmitRejected(snapshot: RequestProgressionSnapshot, failure: SubmitFailure)
}

pub type StartDecisionFailure {
  StartUnknownRequest(identity: RequestIdentity)
  StartRequestNotPending(identity: RequestIdentity)
  StartPolicyOrderBlocked(identity: RequestIdentity)
  StartPermissionDenied(identity: RequestIdentity, reason: PermissionDenial)
  StartPermissionIdentityMismatch(
    identity: RequestIdentity,
    other: RequestIdentity,
  )
  StartPermissionNotOrdered(identity: RequestIdentity)
  StartCostSelectionIdentityMismatch(
    identity: RequestIdentity,
    other: RequestIdentity,
  )
  StartInFlightLimitExceeded(demand: ResourceDemand, budget: ResourceBudget)
  StartConcurrentLimitExceeded(demand: ResourceDemand, budget: ResourceBudget)
}

pub type StartDecisionResult {
  Execute(
    snapshot: RequestProgressionSnapshot,
    starting: Starting,
    command: AdapterCommand,
  )
  Deferred(snapshot: RequestProgressionSnapshot, accepted: Accepted)
  StartDecisionRejected(
    snapshot: RequestProgressionSnapshot,
    failure: StartDecisionFailure,
  )
}

pub type StartObservationFailure {
  StartObservationUnknownRequest(identity: RequestIdentity)
  StartRequestNotStarting(identity: RequestIdentity)
  StartIdentityMismatch(identity: RequestIdentity, other: RequestIdentity)
  StartSignalMismatch(identity: RequestIdentity)
  StartAdapterFailureObserved(identity: RequestIdentity, detail: String)
}

pub type StartObservationResult {
  StartObservationPublishing(
    snapshot: RequestProgressionSnapshot,
    running: Running,
  )
  StartObservationFailed(
    snapshot: RequestProgressionSnapshot,
    failure: StartObservationFailure,
  )
}

pub type CompletionObservationFailure {
  CompletionUnknown(identity: RequestIdentity)
  CompletionNotRunning(identity: RequestIdentity)
  CompletionHandleMismatch(identity: RequestIdentity)
  CompletionIdentityMismatch(identity: RequestIdentity, other: RequestIdentity)
  CompletionSignalMismatch(identity: RequestIdentity)
  CompletionAdapterFailureObserved(identity: RequestIdentity, detail: String)
  CancellationAdapterFailureObserved(identity: RequestIdentity, detail: String)
}

pub type CompletionObservationResult(result) {
  CompletionApplied(
    snapshot: RequestProgressionSnapshot,
    identity: RequestIdentity,
    value: result,
  )
  CompletionSuperseded(
    snapshot: RequestProgressionSnapshot,
    identity: RequestIdentity,
  )
  CompletionCancelled(
    snapshot: RequestProgressionSnapshot,
    identity: RequestIdentity,
  )
  CompletionObservationFailed(
    snapshot: RequestProgressionSnapshot,
    failure: CompletionObservationFailure,
  )
}

pub type CancelFailure {
  CancelUnknownRequest(identity: RequestIdentity)
  CancelRequestAlreadyTerminal(identity: RequestIdentity)
  CancelMissingExecutionHandle(identity: RequestIdentity)
}

pub type CancelDecisionResult {
  CancelledDecision(
    snapshot: RequestProgressionSnapshot,
    identity: RequestIdentity,
  )
  CancelCommandDecision(
    snapshot: RequestProgressionSnapshot,
    running: Running,
    command: AdapterCommand,
  )
  CancelDecisionRejected(
    snapshot: RequestProgressionSnapshot,
    failure: CancelFailure,
  )
}

pub fn empty(
  policy: RequestPolicy,
  budget: ResourceBudget,
) -> RequestProgressionSnapshot {
  RequestProgressionSnapshot(
    policy,
    budget,
    None,
    dict.new(),
    0,
    dict.new(),
    PhaseTotals(zero_demand(), zero_demand(), zero_demand()),
    position_chain.empty(),
    position_chain.empty(),
    0,
  )
}

pub fn snapshot_of(
  policy: RequestPolicy,
  budget: ResourceBudget,
  current_identity: Option(RequestIdentity),
  entries: List(RequestEntry),
  revision: Int,
) -> Result(RequestProgressionSnapshot, SnapshotFailure) {
  let base =
    RequestProgressionSnapshot(
      ..empty(policy, budget),
      current_identity: current_identity,
      revision: revision,
    )
  list.try_fold(entries, base, fn(snapshot, entry) {
    case dict.has_key(snapshot.positions, entry.identity) {
      True -> Error(DuplicateIdentity(entry.identity))
      False -> Ok(append_entry(snapshot, entry))
    }
  })
}

pub fn progression_policy(
  snapshot: RequestProgressionSnapshot,
) -> RequestPolicy {
  snapshot.policy
}

pub fn progression_budget(
  snapshot: RequestProgressionSnapshot,
) -> ResourceBudget {
  snapshot.budget
}

pub fn progression_current_identity(
  snapshot: RequestProgressionSnapshot,
) -> Option(RequestIdentity) {
  snapshot.current_identity
}

pub fn progression_revision(snapshot: RequestProgressionSnapshot) -> Int {
  snapshot.revision
}

pub fn progression_entries(
  snapshot: RequestProgressionSnapshot,
) -> List(RequestEntry) {
  collect_entries(snapshot.slots, snapshot.count - 1, [])
}

pub fn find_request(
  snapshot: RequestProgressionSnapshot,
  identity: RequestIdentity,
) -> Option(RequestEntry) {
  case dict.get(snapshot.positions, identity) {
    Error(Nil) -> None
    Ok(position) -> dict.get(snapshot.slots, position) |> option.from_result
  }
}

pub fn with_budget(
  snapshot: RequestProgressionSnapshot,
  budget: ResourceBudget,
) -> RequestProgressionSnapshot {
  RequestProgressionSnapshot(..snapshot, budget: budget)
}

/// Replaces the stored request that has the same identity as `replacement`.
/// The stored phase is kept, so the derived totals and the pending order do
/// not change.
pub fn replace_request(
  snapshot: RequestProgressionSnapshot,
  replacement: RequestEntry,
) -> RequestProgressionSnapshot {
  case find_request(snapshot, replacement.identity) {
    None -> snapshot
    Some(stored) ->
      with_entry(
        snapshot,
        replacement.identity,
        RequestEntry(..replacement, phase: stored.phase),
      )
  }
}

fn zero_demand() -> ResourceDemand {
  ResourceDemand(0, 0, 0)
}

fn collect_entries(
  slots: Dict(Int, RequestEntry),
  position: Int,
  accumulated: List(RequestEntry),
) -> List(RequestEntry) {
  case position < 0 {
    True -> accumulated
    False ->
      case dict.get(slots, position) {
        Ok(entry) ->
          collect_entries(slots, position - 1, [entry, ..accumulated])
        Error(Nil) -> collect_entries(slots, position - 1, accumulated)
      }
  }
}

fn shift_demand(
  total: ResourceDemand,
  demand: ResourceDemand,
  sign: Int,
) -> ResourceDemand {
  ResourceDemand(
    total.pending + sign * demand.pending,
    total.in_flight + sign * demand.in_flight,
    total.concurrent + sign * demand.concurrent,
  )
}

fn shift_totals(
  totals: PhaseTotals,
  entry: RequestEntry,
  sign: Int,
) -> PhaseTotals {
  case entry.phase {
    Pending ->
      PhaseTotals(
        ..totals,
        pending: shift_demand(totals.pending, entry.demand, sign),
      )
    Preparing ->
      PhaseTotals(
        ..totals,
        in_flight: shift_demand(totals.in_flight, entry.demand, sign),
      )
    Publishing ->
      PhaseTotals(
        ..totals,
        in_flight: shift_demand(totals.in_flight, entry.demand, sign),
        concurrent: shift_demand(totals.concurrent, entry.demand, sign),
      )
    _ -> totals
  }
}

fn append_entry(
  snapshot: RequestProgressionSnapshot,
  entry: RequestEntry,
) -> RequestProgressionSnapshot {
  let position = snapshot.count
  let pending = case entry.phase {
    Pending -> position_chain.push_back(snapshot.pending, position)
    _ -> snapshot.pending
  }
  let ordered_pending = case
    entry.phase == Pending && entry.footprint.effect_class == OrderedEffect
  {
    True -> position_chain.push_back(snapshot.ordered_pending, position)
    False -> snapshot.ordered_pending
  }
  RequestProgressionSnapshot(
    ..snapshot,
    slots: dict.insert(snapshot.slots, position, entry),
    count: position + 1,
    positions: dict.insert(snapshot.positions, entry.identity, position),
    totals: shift_totals(snapshot.totals, entry, 1),
    pending: pending,
    ordered_pending: ordered_pending,
  )
}

fn with_entry(
  snapshot: RequestProgressionSnapshot,
  identity: RequestIdentity,
  replacement: RequestEntry,
) -> RequestProgressionSnapshot {
  case dict.get(snapshot.positions, identity) {
    Error(Nil) -> snapshot
    Ok(position) ->
      case dict.get(snapshot.slots, position) {
        Error(Nil) -> snapshot
        Ok(stored) -> {
          let leaves_pending =
            stored.phase == Pending && replacement.phase != Pending
          RequestProgressionSnapshot(
            ..snapshot,
            slots: dict.insert(snapshot.slots, position, replacement),
            totals: shift_totals(
              shift_totals(snapshot.totals, stored, -1),
              replacement,
              1,
            ),
            pending: case leaves_pending {
              True -> position_chain.remove(snapshot.pending, position)
              False -> snapshot.pending
            },
            ordered_pending: case leaves_pending {
              True -> position_chain.remove(snapshot.ordered_pending, position)
              False -> snapshot.ordered_pending
            },
          )
        }
      }
  }
}

pub fn derive_pending(snapshot: RequestProgressionSnapshot) -> ResourceDemand {
  snapshot.totals.pending
}

pub fn derive_in_flight(
  snapshot: RequestProgressionSnapshot,
) -> ResourceDemand {
  snapshot.totals.in_flight
}

pub fn derive_concurrent(
  snapshot: RequestProgressionSnapshot,
) -> ResourceDemand {
  snapshot.totals.concurrent
}

fn first_pending(snapshot: RequestProgressionSnapshot) -> Option(RequestEntry) {
  first_in_chain(snapshot, snapshot.pending)
}

fn first_ordered_pending(
  snapshot: RequestProgressionSnapshot,
) -> Option(RequestEntry) {
  first_in_chain(snapshot, snapshot.ordered_pending)
}

fn first_in_chain(
  snapshot: RequestProgressionSnapshot,
  chain: PositionChain,
) -> Option(RequestEntry) {
  case position_chain.first(chain) {
    None -> None
    Some(position) -> dict.get(snapshot.slots, position) |> option.from_result
  }
}

fn supersede_pending(
  snapshot: RequestProgressionSnapshot,
) -> RequestProgressionSnapshot {
  case first_pending(snapshot) {
    None -> snapshot
    Some(entry) ->
      supersede_pending(with_entry(
        snapshot,
        entry.identity,
        RequestEntry(..entry, phase: Superseded),
      ))
  }
}

fn policy_order_allowed(
  snapshot: RequestProgressionSnapshot,
  identity: RequestIdentity,
) -> Bool {
  case snapshot.policy {
    LatestWins -> snapshot.current_identity == Some(identity)
    AllExecute -> True
    Fifo ->
      case first_pending(snapshot) {
        Some(earliest) -> earliest.identity == identity
        None -> False
      }
  }
}

fn ordered_effect_allowed(
  snapshot: RequestProgressionSnapshot,
  identity: RequestIdentity,
  entry: RequestEntry,
) -> Bool {
  case entry.footprint.effect_class != OrderedEffect {
    True -> True
    False ->
      case first_ordered_pending(snapshot) {
        Some(earliest) -> earliest.identity == identity
        None -> True
      }
  }
}

pub fn submit(
  snapshot: RequestProgressionSnapshot,
  request: RequestInput,
) -> SubmitResult {
  case option.is_some(find_request(snapshot, request.identity)) {
    True -> SubmitRejected(snapshot, SubmitDuplicateIdentity(request.identity))
    False -> {
      let pending_total = derive_pending(snapshot)
      case
        pending_total.pending + request.demand.pending
        > snapshot.budget.pending_maximum.maximum
      {
        True ->
          SubmitRejected(
            snapshot,
            SubmitPendingLimitExceeded(request.demand, snapshot.budget),
          )
        False -> {
          let entry =
            RequestEntry(
              request.identity,
              request.footprint,
              request.demand,
              Pending,
              request.permission,
              None,
              None,
            )
          let base = case snapshot.policy {
            LatestWins -> supersede_pending(snapshot)
            Fifo | AllExecute -> snapshot
          }
          SubmitAccepted(
            RequestProgressionSnapshot(
              ..append_entry(base, entry),
              current_identity: Some(request.identity),
              revision: snapshot.revision + 1,
            ),
            Accepted(request.identity),
          )
        }
      }
    }
  }
}

fn decide_start_selection(
  snapshot: RequestProgressionSnapshot,
  accepted: Accepted,
  entry: RequestEntry,
  selection: CostSelection,
) -> StartDecisionResult {
  case selection {
    RemainPending(selection_identity, _, _) ->
      case selection_identity != accepted.identity {
        True ->
          StartDecisionRejected(
            snapshot,
            StartCostSelectionIdentityMismatch(
              accepted.identity,
              selection_identity,
            ),
          )
        False ->
          Deferred(
            with_entry(
              snapshot,
              accepted.identity,
              RequestEntry(..entry, cost_selection: Some(selection)),
            ),
            accepted,
          )
      }
    ExecuteNow(selection_identity, _, _) ->
      case selection_identity != accepted.identity {
        True ->
          StartDecisionRejected(
            snapshot,
            StartCostSelectionIdentityMismatch(
              accepted.identity,
              selection_identity,
            ),
          )
        False -> {
          let in_flight = derive_in_flight(snapshot)
          let concurrent = derive_concurrent(snapshot)
          case
            in_flight.in_flight + entry.demand.in_flight
            > snapshot.budget.in_flight_maximum.maximum
          {
            True ->
              StartDecisionRejected(
                snapshot,
                StartInFlightLimitExceeded(entry.demand, snapshot.budget),
              )
            False ->
              case
                concurrent.concurrent + entry.demand.concurrent
                > snapshot.budget.concurrent_maximum.maximum
              {
                True ->
                  StartDecisionRejected(
                    snapshot,
                    StartConcurrentLimitExceeded(entry.demand, snapshot.budget),
                  )
                False -> {
                  let command = StartCommand(accepted.identity, entry.footprint)
                  let advanced =
                    RequestProgressionSnapshot(
                      ..with_entry(
                        snapshot,
                        accepted.identity,
                        RequestEntry(
                          ..entry,
                          phase: Preparing,
                          cost_selection: Some(selection),
                        ),
                      ),
                      revision: snapshot.revision + 1,
                    )
                  Execute(
                    advanced,
                    Starting(accepted.identity, command),
                    command,
                  )
                }
              }
          }
        }
      }
  }
}

pub fn decide_start(
  snapshot: RequestProgressionSnapshot,
  accepted: Accepted,
  selection: CostSelection,
) -> StartDecisionResult {
  case find_request(snapshot, accepted.identity) {
    None ->
      StartDecisionRejected(snapshot, StartUnknownRequest(accepted.identity))
    Some(entry) ->
      case entry.phase != Pending {
        True ->
          StartDecisionRejected(
            snapshot,
            StartRequestNotPending(accepted.identity),
          )
        False ->
          case
            !policy_order_allowed(snapshot, accepted.identity)
            || !ordered_effect_allowed(snapshot, accepted.identity, entry)
          {
            True ->
              StartDecisionRejected(
                snapshot,
                StartPolicyOrderBlocked(accepted.identity),
              )
            False ->
              case entry.meaning_permission {
                Denied(_, reason) ->
                  StartDecisionRejected(
                    snapshot,
                    StartPermissionDenied(accepted.identity, reason),
                  )
                Permitted(permission_identity, _) ->
                  case permission_identity != accepted.identity {
                    True ->
                      StartDecisionRejected(
                        snapshot,
                        StartPermissionIdentityMismatch(
                          accepted.identity,
                          permission_identity,
                        ),
                      )
                    False ->
                      case entry.footprint.effect_class == OrderedEffect {
                        True ->
                          StartDecisionRejected(
                            snapshot,
                            StartPermissionNotOrdered(accepted.identity),
                          )
                        False ->
                          decide_start_selection(
                            snapshot,
                            accepted,
                            entry,
                            selection,
                          )
                      }
                  }
                Ordered(permission_identity, _) ->
                  case permission_identity != accepted.identity {
                    True ->
                      StartDecisionRejected(
                        snapshot,
                        StartPermissionIdentityMismatch(
                          accepted.identity,
                          permission_identity,
                        ),
                      )
                    False ->
                      decide_start_selection(
                        snapshot,
                        accepted,
                        entry,
                        selection,
                      )
                  }
              }
          }
      }
  }
}

fn start_observation_failure(
  snapshot: RequestProgressionSnapshot,
  starting: Starting,
  entry: RequestEntry,
  failure: StartObservationFailure,
) -> StartObservationResult {
  StartObservationFailed(
    RequestProgressionSnapshot(
      ..with_entry(
        snapshot,
        starting.identity,
        RequestEntry(..entry, phase: Failed),
      ),
      revision: snapshot.revision + 1,
    ),
    failure,
  )
}

pub fn apply_start_observation(
  snapshot: RequestProgressionSnapshot,
  starting: Starting,
  observed: AdapterResult(result),
) -> StartObservationResult {
  case find_request(snapshot, starting.identity) {
    None ->
      StartObservationFailed(
        snapshot,
        StartObservationUnknownRequest(starting.identity),
      )
    Some(entry) ->
      case entry.phase != Preparing {
        True ->
          StartObservationFailed(
            snapshot,
            StartRequestNotStarting(starting.identity),
          )
        False ->
          case observed {
            AppliedSignal(Started(signal_identity, handle)) ->
              case signal_identity == starting.identity {
                True ->
                  StartObservationPublishing(
                    RequestProgressionSnapshot(
                      ..with_entry(
                        snapshot,
                        starting.identity,
                        RequestEntry(
                          ..entry,
                          phase: Publishing,
                          execution_handle: Some(handle),
                        ),
                      ),
                      revision: snapshot.revision + 1,
                    ),
                    Running(starting.identity, handle),
                  )
                False ->
                  start_observation_failure(
                    snapshot,
                    starting,
                    entry,
                    StartIdentityMismatch(starting.identity, signal_identity),
                  )
              }
            AppliedSignal(Completed(_, _, _))
            | AppliedSignal(CancelledAtAdapter(_, _)) ->
              start_observation_failure(
                snapshot,
                starting,
                entry,
                StartSignalMismatch(starting.identity),
              )
            AdapterFailed(StartAdapterFailure(failure_identity, detail)) ->
              case failure_identity == starting.identity {
                True ->
                  start_observation_failure(
                    snapshot,
                    starting,
                    entry,
                    StartAdapterFailureObserved(starting.identity, detail),
                  )
                False ->
                  start_observation_failure(
                    snapshot,
                    starting,
                    entry,
                    StartIdentityMismatch(starting.identity, failure_identity),
                  )
              }
            AdapterFailed(CompletionAdapterFailure(_, _, _))
            | AdapterFailed(CancellationAdapterFailure(_, _, _)) ->
              start_observation_failure(
                snapshot,
                starting,
                entry,
                StartSignalMismatch(starting.identity),
              )
          }
      }
  }
}

pub fn apply_completion_observation(
  snapshot: RequestProgressionSnapshot,
  running: Running,
  observed: AdapterResult(result),
) -> CompletionObservationResult(result) {
  case find_request(snapshot, running.identity) {
    None ->
      CompletionObservationFailed(snapshot, CompletionUnknown(running.identity))
    Some(entry) ->
      case entry.phase != Publishing {
        True ->
          CompletionObservationFailed(
            snapshot,
            CompletionNotRunning(running.identity),
          )
        False ->
          case entry.execution_handle != Some(running.handle) {
            True ->
              CompletionObservationFailed(
                snapshot,
                CompletionHandleMismatch(running.identity),
              )
            False ->
              case observed {
                AppliedSignal(Completed(signal_identity, signal_handle, value)) ->
                  case signal_identity != running.identity {
                    True ->
                      CompletionObservationFailed(
                        snapshot,
                        CompletionIdentityMismatch(
                          running.identity,
                          signal_identity,
                        ),
                      )
                    False ->
                      case signal_handle != running.handle {
                        True ->
                          CompletionObservationFailed(
                            snapshot,
                            CompletionHandleMismatch(running.identity),
                          )
                        False ->
                          case
                            snapshot.policy == LatestWins
                            && snapshot.current_identity
                            != Some(running.identity)
                          {
                            True ->
                              CompletionSuperseded(
                                with_entry(
                                  snapshot,
                                  running.identity,
                                  RequestEntry(..entry, phase: Superseded),
                                ),
                                running.identity,
                              )
                            False ->
                              CompletionApplied(
                                RequestProgressionSnapshot(
                                  ..with_entry(
                                    snapshot,
                                    running.identity,
                                    RequestEntry(..entry, phase: Published),
                                  ),
                                  revision: snapshot.revision + 1,
                                ),
                                running.identity,
                                value,
                              )
                          }
                      }
                  }
                AppliedSignal(CancelledAtAdapter(signal_identity, signal_handle)) ->
                  case signal_identity != running.identity {
                    True ->
                      CompletionObservationFailed(
                        snapshot,
                        CompletionIdentityMismatch(
                          running.identity,
                          signal_identity,
                        ),
                      )
                    False ->
                      case signal_handle != running.handle {
                        True ->
                          CompletionObservationFailed(
                            snapshot,
                            CompletionHandleMismatch(running.identity),
                          )
                        False ->
                          CompletionCancelled(
                            RequestProgressionSnapshot(
                              ..with_entry(
                                snapshot,
                                running.identity,
                                RequestEntry(..entry, phase: Cancelled),
                              ),
                              revision: snapshot.revision + 1,
                            ),
                            running.identity,
                          )
                      }
                  }
                AppliedSignal(Started(_, _)) ->
                  CompletionObservationFailed(
                    snapshot,
                    CompletionSignalMismatch(running.identity),
                  )
                AdapterFailed(CompletionAdapterFailure(
                  failure_identity,
                  failure_handle,
                  detail,
                )) ->
                  case failure_identity != running.identity {
                    True ->
                      CompletionObservationFailed(
                        snapshot,
                        CompletionIdentityMismatch(
                          running.identity,
                          failure_identity,
                        ),
                      )
                    False ->
                      case failure_handle != running.handle {
                        True ->
                          CompletionObservationFailed(
                            snapshot,
                            CompletionHandleMismatch(running.identity),
                          )
                        False ->
                          CompletionObservationFailed(
                            RequestProgressionSnapshot(
                              ..with_entry(
                                snapshot,
                                running.identity,
                                RequestEntry(..entry, phase: Failed),
                              ),
                              revision: snapshot.revision + 1,
                            ),
                            CompletionAdapterFailureObserved(
                              running.identity,
                              detail,
                            ),
                          )
                      }
                  }
                AdapterFailed(CancellationAdapterFailure(
                  failure_identity,
                  failure_handle,
                  detail,
                )) ->
                  case failure_identity != running.identity {
                    True ->
                      CompletionObservationFailed(
                        snapshot,
                        CompletionIdentityMismatch(
                          running.identity,
                          failure_identity,
                        ),
                      )
                    False ->
                      case failure_handle != running.handle {
                        True ->
                          CompletionObservationFailed(
                            snapshot,
                            CompletionHandleMismatch(running.identity),
                          )
                        False ->
                          CompletionObservationFailed(
                            RequestProgressionSnapshot(
                              ..with_entry(
                                snapshot,
                                running.identity,
                                RequestEntry(..entry, phase: Failed),
                              ),
                              revision: snapshot.revision + 1,
                            ),
                            CancellationAdapterFailureObserved(
                              running.identity,
                              detail,
                            ),
                          )
                      }
                  }
                AdapterFailed(StartAdapterFailure(_, _)) ->
                  CompletionObservationFailed(
                    snapshot,
                    CompletionSignalMismatch(running.identity),
                  )
              }
          }
      }
  }
}

pub fn decide_cancel(
  snapshot: RequestProgressionSnapshot,
  identity: RequestIdentity,
) -> CancelDecisionResult {
  case find_request(snapshot, identity) {
    None -> CancelDecisionRejected(snapshot, CancelUnknownRequest(identity))
    Some(entry) ->
      case entry.phase {
        Pending ->
          CancelledDecision(
            RequestProgressionSnapshot(
              ..with_entry(
                snapshot,
                identity,
                RequestEntry(..entry, phase: Cancelled),
              ),
              revision: snapshot.revision + 1,
            ),
            identity,
          )
        Publishing ->
          case entry.execution_handle {
            None ->
              CancelDecisionRejected(
                snapshot,
                CancelMissingExecutionHandle(identity),
              )
            Some(handle) ->
              CancelCommandDecision(
                snapshot,
                Running(identity, handle),
                CancelCommand(identity, handle),
              )
          }
        Preparing ->
          CancelDecisionRejected(
            snapshot,
            CancelMissingExecutionHandle(identity),
          )
        _ ->
          CancelDecisionRejected(
            snapshot,
            CancelRequestAlreadyTerminal(identity),
          )
      }
  }
}
