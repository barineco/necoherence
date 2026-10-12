// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{type Option, None, Some}

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

pub type RequestProgressionSnapshot {
  RequestProgressionSnapshot(
    policy: RequestPolicy,
    budget: ResourceBudget,
    current_identity: Option(RequestIdentity),
    entries: List(RequestEntry),
    revision: Int,
  )
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
  RequestProgressionSnapshot(policy, budget, None, [], 0)
}

fn find_entry(
  entries: List(RequestEntry),
  identity: RequestIdentity,
) -> Option(RequestEntry) {
  list.find(entries, fn(entry) { entry.identity == identity })
  |> option.from_result
}

fn replace_entry(
  entries: List(RequestEntry),
  identity: RequestIdentity,
  replacement: RequestEntry,
) -> List(RequestEntry) {
  list.map(entries, fn(entry) {
    case entry.identity == identity {
      True -> replacement
      False -> entry
    }
  })
}

fn sum_demand(entries: List(RequestEntry)) -> ResourceDemand {
  list.fold(entries, ResourceDemand(0, 0, 0), fn(total, entry) {
    ResourceDemand(
      total.pending + entry.demand.pending,
      total.in_flight + entry.demand.in_flight,
      total.concurrent + entry.demand.concurrent,
    )
  })
}

pub fn derive_pending(snapshot: RequestProgressionSnapshot) -> ResourceDemand {
  sum_demand(
    list.filter(snapshot.entries, fn(entry) { entry.phase == Pending }),
  )
}

pub fn derive_in_flight(
  snapshot: RequestProgressionSnapshot,
) -> ResourceDemand {
  sum_demand(
    list.filter(snapshot.entries, fn(entry) {
      entry.phase == Preparing || entry.phase == Publishing
    }),
  )
}

pub fn derive_concurrent(
  snapshot: RequestProgressionSnapshot,
) -> ResourceDemand {
  sum_demand(
    list.filter(snapshot.entries, fn(entry) { entry.phase == Publishing }),
  )
}

fn policy_order_allowed(
  snapshot: RequestProgressionSnapshot,
  identity: RequestIdentity,
) -> Bool {
  case snapshot.policy {
    LatestWins -> snapshot.current_identity == Some(identity)
    AllExecute -> True
    Fifo ->
      case list.find(snapshot.entries, fn(entry) { entry.phase == Pending }) {
        Ok(earliest) -> earliest.identity == identity
        Error(_) -> False
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
      case
        list.find(snapshot.entries, fn(e) {
          e.phase == Pending && e.footprint.effect_class == OrderedEffect
        })
      {
        Ok(earliest) -> earliest.identity == identity
        Error(_) -> True
      }
  }
}

pub fn submit(
  snapshot: RequestProgressionSnapshot,
  request: RequestInput,
) -> SubmitResult {
  case option.is_some(find_entry(snapshot.entries, request.identity)) {
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
          let entries = case snapshot.policy {
            LatestWins ->
              list.append(
                list.map(snapshot.entries, fn(e) {
                  case e.phase == Pending {
                    True -> RequestEntry(..e, phase: Superseded)
                    False -> e
                  }
                }),
                [entry],
              )
            Fifo | AllExecute -> list.append(snapshot.entries, [entry])
          }
          SubmitAccepted(
            RequestProgressionSnapshot(
              ..snapshot,
              entries: entries,
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
            RequestProgressionSnapshot(
              ..snapshot,
              entries: replace_entry(
                snapshot.entries,
                accepted.identity,
                RequestEntry(..entry, cost_selection: Some(selection)),
              ),
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
                      ..snapshot,
                      entries: replace_entry(
                        snapshot.entries,
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
  case find_entry(snapshot.entries, accepted.identity) {
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
      ..snapshot,
      entries: replace_entry(
        snapshot.entries,
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
  case find_entry(snapshot.entries, starting.identity) {
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
                      ..snapshot,
                      entries: replace_entry(
                        snapshot.entries,
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
  case find_entry(snapshot.entries, running.identity) {
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
                                RequestProgressionSnapshot(
                                  ..snapshot,
                                  entries: replace_entry(
                                    snapshot.entries,
                                    running.identity,
                                    RequestEntry(..entry, phase: Superseded),
                                  ),
                                ),
                                running.identity,
                              )
                            False ->
                              CompletionApplied(
                                RequestProgressionSnapshot(
                                  ..snapshot,
                                  entries: replace_entry(
                                    snapshot.entries,
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
                              ..snapshot,
                              entries: replace_entry(
                                snapshot.entries,
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
                              ..snapshot,
                              entries: replace_entry(
                                snapshot.entries,
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
                              ..snapshot,
                              entries: replace_entry(
                                snapshot.entries,
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
  case find_entry(snapshot.entries, identity) {
    None -> CancelDecisionRejected(snapshot, CancelUnknownRequest(identity))
    Some(entry) ->
      case entry.phase {
        Pending ->
          CancelledDecision(
            RequestProgressionSnapshot(
              ..snapshot,
              entries: replace_entry(
                snapshot.entries,
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
