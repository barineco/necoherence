// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import neco_quotient_retention as retention
import necoherence/core.{type Outcome, Applied, Rejected}
import necoherence/request_progression.{
  type Accepted, type CostSelection, type PermissionDenial, type RequestEntry,
  type RequestIdentity, type RequestInput, type RequestProgressionSnapshot,
  type ResourceBudget, type StartDecisionFailure, type StartDecisionResult,
  type SubmitFailure, ConfiguredSafetyLimit, Denied, ExecuteNow, Ordered,
  Permitted, RequestEntry, ResourceBudget, StartDecisionRejected, SubmitAccepted,
  SubmitRejected,
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

pub opaque type DynamicAdmissionState {
  DynamicAdmissionState(
    progression: RequestProgressionSnapshot,
    configured_safety_limit: ResourceBudget,
    provenance: AdmissionProvenance,
    future_use_identities: Set(RequestIdentity),
    signal_identities: Set(RequestIdentity),
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

pub type ProvenanceObservation {
  Footprint
  Evidence
}

pub type ErasureWitness =
  retention.DematerializeWitness(
    RequestIdentity,
    Nil,
    Nil,
    ProvenanceObservation,
  )

pub type ErasureRetention =
  retention.RetentionReason(RequestIdentity, Nil, ProvenanceObservation)

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
  ProvenanceRetentionRequired(
    identity: RequestIdentity,
    reasons: List(ErasureRetention),
  )
  ErasureInputIncomplete(
    identity: RequestIdentity,
    missing: retention.MissingInput,
  )
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
    provenance_erasure_witness: Option(ErasureWitness),
    coalescing_witness: CoalescingWitness,
  )
}

pub fn admission_state_of(
  progression: RequestProgressionSnapshot,
  configured_safety_limit: ResourceBudget,
  provenance: AdmissionProvenance,
) -> DynamicAdmissionState {
  DynamicAdmissionState(
    progression,
    configured_safety_limit,
    provenance,
    set.from_list(provenance.future_uses),
    set.from_list(
      list.map(provenance.outstanding_signals, fn(s) { s.identity }),
    ),
  )
}

pub fn admission_progression(
  state: DynamicAdmissionState,
) -> RequestProgressionSnapshot {
  state.progression
}

pub fn admission_safety_limit(state: DynamicAdmissionState) -> ResourceBudget {
  state.configured_safety_limit
}

pub fn admission_provenance(
  state: DynamicAdmissionState,
) -> AdmissionProvenance {
  state.provenance
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
  case request_progression.find_request(snapshot, request.identity) {
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
  #(DynamicAdmissionState, ErasureWitness),
  DynamicAdmissionFailure,
  boundary_c,
  boundary_p,
) {
  case request_progression.find_request(state.progression, identity) {
    None -> Rejected(AdmissionUnknownRequest(identity))
    Some(entry) ->
      case !is_terminal_phase(entry.phase) {
        True -> Rejected(AdmissionRequestNotTerminal(identity))
        False -> erase_by_judgment(state, identity, entry)
      }
  }
}

fn erase_by_judgment(
  state: DynamicAdmissionState,
  identity: RequestIdentity,
  entry: RequestEntry,
) -> Outcome(
  #(DynamicAdmissionState, ErasureWitness),
  DynamicAdmissionFailure,
  boundary_c,
  boundary_p,
) {
  let request =
    retention.ErasureRequest(
      target: identity,
      target_basis: None,
      removed_observations: [Footprint, Evidence],
      preserved_observations: [],
    )
  let membership =
    retention.LiveMembership(
      active_basis: fn(_) { False },
      branch_root: fn(_) { False },
      future_use: fn(target) {
        set.contains(state.future_use_identities, target)
      },
      outstanding_effect: fn(_) { False },
      outstanding_signal: fn(target) {
        set.contains(state.signal_identities, target)
      },
    )
  case
    retention.judge_erasure_by(
      request,
      membership,
      Some(retention.Irrecoverable),
    )
  {
    retention.Dematerialize(witness) ->
      Applied(#(
        DynamicAdmissionState(
          ..state,
          progression: request_progression.replace_request(
            state.progression,
            erase_entry_provenance(entry),
          ),
        ),
        witness,
      ))
    retention.Retain(reasons) ->
      Rejected(ProvenanceRetentionRequired(identity, reasons))
    retention.Rejected(missing) ->
      Rejected(ErasureInputIncomplete(identity, missing))
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
                                request_progression.with_budget(
                                  snapshot,
                                  effective_budget,
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
