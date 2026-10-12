// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import necoherence/core.{type Outcome, Applied, Rejected}
import necoherence/request_progression.{
  type Accepted, type CostSelection, type PermissionDenial, type RequestEntry,
  type RequestIdentity, type RequestInput, type RequestProgressionSnapshot,
  type ResourceBudget, type StartDecisionFailure, type StartDecisionResult,
  type SubmitFailure, ConfiguredSafetyLimit, Denied, ExecuteNow, Ordered,
  Permitted, RequestEntry, RequestProgressionSnapshot, ResourceBudget,
  StartDecisionRejected, SubmitAccepted, SubmitRejected,
}

pub type EnvironmentSpecification {
  EnvironmentSpecification(max_observation_age: Int)
}

pub type CapacityObservation {
  CapacityObservation(observed: ResourceBudget, observed_at: Int)
}

pub type SignalKind {
  PendingCompletion
  PendingCancellation
}

pub type AdmissionSignal {
  AdmissionSignal(
    identity: RequestIdentity,
    handle: request_progression.ExecutionHandle,
    kind: SignalKind,
  )
}

pub type AdmissionProvenance {
  AdmissionProvenance(
    future_uses: List(RequestIdentity),
    outstanding_signals: List(AdmissionSignal),
  )
}

pub type DynamicAdmissionState {
  DynamicAdmissionState(
    progression: RequestProgressionSnapshot,
    configured_safety_limit: ResourceBudget,
    provenance: AdmissionProvenance,
  )
}

pub type DynamicAdmissionInput {
  DynamicAdmissionInput(
    state: DynamicAdmissionState,
    request: RequestInput,
    environment_specification: EnvironmentSpecification,
    capacity_observation: CapacityObservation,
    observed_at: Int,
    start: Option(CostSelection),
  )
}

pub type EffectiveBudget =
  ResourceBudget

pub type DynamicAdmissionFailure {
  CapacityObservationUnavailable(age: Int, max_age: Int)
  ResourceCoordinateMismatch(
    configured_resource: String,
    observed_resource: String,
  )
  ConfiguredSafetyLimitExceeded(resource: String, occupied: Int, allowed: Int)
  MeaningDenied(identity: RequestIdentity, reason: PermissionDenial)
  PermissionIdentityMismatch(
    request_identity: RequestIdentity,
    permission_identity: RequestIdentity,
  )
  AdapterBindingUnavailable(identity: RequestIdentity)
  BindingSelectionMismatch(identity: RequestIdentity)
  ProgressionSubmitFailure(failure: SubmitFailure)
  ProgressionStartFailure(failure: StartDecisionFailure)
  ProvenanceRetentionRequired(identity: RequestIdentity)
  AdmissionUnknownRequest(identity: RequestIdentity)
  AdmissionRequestNotTerminal(identity: RequestIdentity)
}

pub type AdmissionDecision {
  Submitted(state: DynamicAdmissionState, accepted: Accepted)
  Started(state: DynamicAdmissionState, result: StartDecisionResult)
  Coalesced(state: DynamicAdmissionState, identity: RequestIdentity)
}

pub type FutureUseSet {
  FutureUseSet(identities: List(RequestIdentity))
}

pub type OutstandingSignalSet {
  OutstandingSignalSet(signals: List(AdmissionSignal))
}

pub type ProvenanceErasureWitness {
  Erased(identity: RequestIdentity)
  Retained(identity: RequestIdentity, reason: String)
}

pub type CoalescingWitness {
  CoalescedRequest(identity: RequestIdentity)
  NotCoalesced(reason: String)
}

pub type DynamicAdmissionResult {
  DynamicAdmissionResult(
    effective_budget: EffectiveBudget,
    admission_decision: AdmissionDecision,
    future_use_set: FutureUseSet,
    outstanding_signal_set: OutstandingSignalSet,
    provenance_erasure_witness: Option(ProvenanceErasureWitness),
    coalescing_witness: CoalescingWitness,
  )
}

fn find_by_identity(
  entries: List(RequestEntry),
  identity: RequestIdentity,
) -> Option(RequestEntry) {
  list.find(entries, fn(entry) { entry.identity == identity })
  |> option.from_result
}

fn replace_by_identity(
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

fn min_limit(
  a: request_progression.ConfiguredSafetyLimit,
  b: request_progression.ConfiguredSafetyLimit,
) -> request_progression.ConfiguredSafetyLimit {
  ConfiguredSafetyLimit(a.resource, int.min(a.maximum, b.maximum))
}

fn effective_budget_of(
  configured: ResourceBudget,
  observed: ResourceBudget,
) -> EffectiveBudget {
  ResourceBudget(
    min_limit(configured.pending_maximum, observed.pending_maximum),
    min_limit(configured.in_flight_maximum, observed.in_flight_maximum),
    min_limit(configured.concurrent_maximum, observed.concurrent_maximum),
  )
}

fn resource_coordinate_mismatch(
  configured: ResourceBudget,
  observed: ResourceBudget,
) -> Option(#(String, String)) {
  case
    configured.pending_maximum.resource != observed.pending_maximum.resource
  {
    True ->
      Some(#(
        configured.pending_maximum.resource,
        observed.pending_maximum.resource,
      ))
    False ->
      case
        configured.in_flight_maximum.resource
        != observed.in_flight_maximum.resource
      {
        True ->
          Some(#(
            configured.in_flight_maximum.resource,
            observed.in_flight_maximum.resource,
          ))
        False ->
          case
            configured.concurrent_maximum.resource
            != observed.concurrent_maximum.resource
          {
            True ->
              Some(#(
                configured.concurrent_maximum.resource,
                observed.concurrent_maximum.resource,
              ))
            False -> None
          }
      }
  }
}

fn observation_age(input: DynamicAdmissionInput) -> Int {
  case input.observed_at < input.capacity_observation.observed_at {
    True ->
      input.capacity_observation.observed_at
      - input.observed_at
      + input.environment_specification.max_observation_age
      + 1
    False -> input.observed_at - input.capacity_observation.observed_at
  }
}

fn permission_check(request: RequestInput) -> Option(DynamicAdmissionFailure) {
  case request.permission {
    Denied(identity, reason) ->
      case identity == request.identity {
        True -> Some(MeaningDenied(identity, reason))
        False -> Some(PermissionIdentityMismatch(request.identity, identity))
      }
    Permitted(identity, _) | Ordered(identity, _) ->
      case identity == request.identity {
        True -> None
        False -> Some(PermissionIdentityMismatch(request.identity, identity))
      }
  }
}

fn same_pending_entry(entry: RequestEntry, request: RequestInput) -> Bool {
  entry.phase == request_progression.Pending
  && entry.identity == request.identity
  && entry.footprint == request.footprint
  && entry.demand == request.demand
  && entry.meaning_permission == request.permission
}

fn matching_pending_duplicate(
  snapshot: RequestProgressionSnapshot,
  request: RequestInput,
) -> Option(RequestEntry) {
  case find_by_identity(snapshot.entries, request.identity) {
    Some(entry) ->
      case same_pending_entry(entry, request) {
        True -> Some(entry)
        False -> None
      }
    None -> None
  }
}

fn is_execute_now(selection: CostSelection) -> Bool {
  case selection {
    ExecuteNow(_, _, _) -> True
    request_progression.RemainPending(_, _, _) -> False
  }
}

fn to_future_use_set(provenance: AdmissionProvenance) -> FutureUseSet {
  FutureUseSet(provenance.future_uses)
}

fn to_outstanding_signal_set(
  provenance: AdmissionProvenance,
) -> OutstandingSignalSet {
  OutstandingSignalSet(provenance.outstanding_signals)
}

fn is_terminal_phase(phase: request_progression.RequestPhase) -> Bool {
  phase == request_progression.Published
  || phase == request_progression.Superseded
  || phase == request_progression.Cancelled
  || phase == request_progression.Failed
}

fn erase_meaning_permission_evidence(
  permission: request_progression.MeaningPermission,
) -> request_progression.MeaningPermission {
  case permission {
    Permitted(identity, _) -> Permitted(identity, [])
    Ordered(identity, _) -> Ordered(identity, [])
    Denied(identity, reason) -> Denied(identity, reason)
  }
}

fn erase_entry_provenance(entry: RequestEntry) -> RequestEntry {
  RequestEntry(
    ..entry,
    footprint: request_progression.RequestFootprint(
      ..entry.footprint,
      reads: [],
      writes: [],
    ),
    meaning_permission: erase_meaning_permission_evidence(
      entry.meaning_permission,
    ),
  )
}

pub fn elide_admission_provenance(
  state: DynamicAdmissionState,
  identity: RequestIdentity,
) -> Outcome(
  #(DynamicAdmissionState, ProvenanceErasureWitness),
  DynamicAdmissionFailure,
  boundary_c,
  boundary_p,
) {
  case find_by_identity(state.progression.entries, identity) {
    None -> Rejected(AdmissionUnknownRequest(identity))
    Some(entry) ->
      case !is_terminal_phase(entry.phase) {
        True -> Rejected(AdmissionRequestNotTerminal(identity))
        False ->
          case
            list.contains(state.provenance.future_uses, identity)
            || list.any(state.provenance.outstanding_signals, fn(s) {
              s.identity == identity
            })
          {
            True -> Rejected(ProvenanceRetentionRequired(identity))
            False ->
              Applied(#(
                DynamicAdmissionState(
                  ..state,
                  progression: RequestProgressionSnapshot(
                    ..state.progression,
                    entries: replace_by_identity(
                      state.progression.entries,
                      identity,
                      erase_entry_provenance(entry),
                    ),
                  ),
                  provenance: AdmissionProvenance(
                    list.filter(state.provenance.future_uses, fn(i) {
                      i != identity
                    }),
                    list.filter(state.provenance.outstanding_signals, fn(s) {
                      s.identity != identity
                    }),
                  ),
                ),
                Erased(identity),
              ))
          }
      }
  }
}

fn admission_result(
  effective_budget: EffectiveBudget,
  decision: AdmissionDecision,
  state: DynamicAdmissionState,
  witness: CoalescingWitness,
) -> Outcome(
  DynamicAdmissionResult,
  DynamicAdmissionFailure,
  boundary_c,
  boundary_p,
) {
  Applied(DynamicAdmissionResult(
    effective_budget,
    decision,
    to_future_use_set(state.provenance),
    to_outstanding_signal_set(state.provenance),
    None,
    witness,
  ))
}

pub fn admit_dynamic_request(
  input: DynamicAdmissionInput,
) -> Outcome(
  DynamicAdmissionResult,
  DynamicAdmissionFailure,
  boundary_c,
  boundary_p,
) {
  let age = observation_age(input)
  case age > input.environment_specification.max_observation_age {
    True ->
      Rejected(CapacityObservationUnavailable(
        age,
        input.environment_specification.max_observation_age,
      ))
    False ->
      case
        resource_coordinate_mismatch(
          input.state.configured_safety_limit,
          input.capacity_observation.observed,
        )
      {
        Some(#(configured_resource, observed_resource)) ->
          Rejected(ResourceCoordinateMismatch(
            configured_resource,
            observed_resource,
          ))
        None ->
          case permission_check(input.request) {
            Some(failure) -> Rejected(failure)
            None -> {
              let effective_budget =
                effective_budget_of(
                  input.state.configured_safety_limit,
                  input.capacity_observation.observed,
                )
              let snapshot = input.state.progression
              case matching_pending_duplicate(snapshot, input.request) {
                Some(entry) ->
                  case entry.cost_selection, input.start {
                    None, None ->
                      admission_result(
                        effective_budget,
                        Coalesced(input.state, input.request.identity),
                        input.state,
                        CoalescedRequest(input.request.identity),
                      )
                    Some(existing), Some(new) ->
                      case existing == new {
                        True ->
                          admission_result(
                            effective_budget,
                            Coalesced(input.state, input.request.identity),
                            input.state,
                            CoalescedRequest(input.request.identity),
                          )
                        False ->
                          Rejected(BindingSelectionMismatch(
                            input.request.identity,
                          ))
                      }
                    _, _ ->
                      Rejected(AdapterBindingUnavailable(input.request.identity))
                  }
                None -> {
                  let pending_occupied =
                    request_progression.derive_pending(snapshot).pending
                    + input.request.demand.pending
                  case
                    pending_occupied > effective_budget.pending_maximum.maximum
                  {
                    True ->
                      Rejected(ConfiguredSafetyLimitExceeded(
                        effective_budget.pending_maximum.resource,
                        pending_occupied,
                        effective_budget.pending_maximum.maximum,
                      ))
                    False -> {
                      let execute_now = case input.start {
                        Some(selection) -> is_execute_now(selection)
                        None -> False
                      }
                      let in_flight_occupied =
                        request_progression.derive_in_flight(snapshot).in_flight
                        + input.request.demand.in_flight
                      let concurrent_occupied =
                        request_progression.derive_concurrent(snapshot).concurrent
                        + input.request.demand.concurrent
                      case
                        execute_now
                        && in_flight_occupied
                        > effective_budget.in_flight_maximum.maximum
                      {
                        True ->
                          Rejected(ConfiguredSafetyLimitExceeded(
                            effective_budget.in_flight_maximum.resource,
                            in_flight_occupied,
                            effective_budget.in_flight_maximum.maximum,
                          ))
                        False ->
                          case
                            execute_now
                            && concurrent_occupied
                            > effective_budget.concurrent_maximum.maximum
                          {
                            True ->
                              Rejected(ConfiguredSafetyLimitExceeded(
                                effective_budget.concurrent_maximum.resource,
                                concurrent_occupied,
                                effective_budget.concurrent_maximum.maximum,
                              ))
                            False -> {
                              let budgeted_snapshot =
                                RequestProgressionSnapshot(
                                  ..snapshot,
                                  budget: effective_budget,
                                )
                              case
                                request_progression.submit(
                                  budgeted_snapshot,
                                  input.request,
                                )
                              {
                                SubmitRejected(_, failure) ->
                                  Rejected(ProgressionSubmitFailure(failure))
                                SubmitAccepted(submitted_snapshot, accepted) ->
                                  case input.start {
                                    None -> {
                                      let state =
                                        DynamicAdmissionState(
                                          ..input.state,
                                          progression: submitted_snapshot,
                                        )
                                      admission_result(
                                        effective_budget,
                                        Submitted(state, accepted),
                                        state,
                                        NotCoalesced(
                                          "no duplicate pending request",
                                        ),
                                      )
                                    }
                                    Some(selection) ->
                                      case
                                        request_progression.decide_start(
                                          submitted_snapshot,
                                          accepted,
                                          selection,
                                        )
                                      {
                                        StartDecisionRejected(_, failure) ->
                                          Rejected(ProgressionStartFailure(
                                            failure,
                                          ))
                                        result -> {
                                          let state = case result {
                                            request_progression.Execute(
                                              progressed,
                                              _,
                                              _,
                                            )
                                            | request_progression.Deferred(
                                                progressed,
                                                _,
                                              ) ->
                                              DynamicAdmissionState(
                                                ..input.state,
                                                progression: progressed,
                                              )
                                            StartDecisionRejected(_, _) ->
                                              input.state
                                          }
                                          admission_result(
                                            effective_budget,
                                            Started(state, result),
                                            state,
                                            NotCoalesced(
                                              "no duplicate pending request",
                                            ),
                                          )
                                        }
                                      }
                                  }
                              }
                            }
                          }
                      }
                    }
                  }
                }
              }
            }
          }
      }
  }
}
