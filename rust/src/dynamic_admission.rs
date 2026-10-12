// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

//! Dynamic admission over request progression: safety budget, idempotent coalescing, and provenance elision.

use crate::core::Nat;
use crate::request_progression::{
    decide_start, derive_concurrent, derive_in_flight, derive_pending, submit, Accepted,
    CostSelection, MeaningPermission, PermissionDenial, RequestEntry, RequestIdentity,
    RequestInput, RequestPhase, RequestProgressionSnapshot, ResourceBudget, StartDecisionFailure,
    StartDecisionResult, SubmitFailure, SubmitResult,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EnvironmentSpecification {
    pub max_observation_age: Nat,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CapacityObservation {
    pub observed: ResourceBudget,
    pub observed_at: Nat,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SignalKind {
    PendingCompletion,
    PendingCancellation,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AdmissionSignal {
    pub identity: RequestIdentity,
    pub handle: crate::request_progression::ExecutionHandle,
    pub kind: SignalKind,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AdmissionProvenance {
    pub future_uses: Vec<RequestIdentity>,
    pub outstanding_signals: Vec<AdmissionSignal>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DynamicAdmissionState {
    pub progression: RequestProgressionSnapshot,
    pub configured_safety_limit: ResourceBudget,
    pub provenance: AdmissionProvenance,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DynamicAdmissionInput {
    pub state: DynamicAdmissionState,
    pub request: RequestInput,
    pub environment_specification: EnvironmentSpecification,
    pub capacity_observation: CapacityObservation,
    pub observed_at: Nat,
    pub start: Option<CostSelection>,
}
pub type EffectiveBudget = ResourceBudget;
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DynamicAdmissionFailure {
    CapacityObservationUnavailable(Nat, Nat),
    ResourceCoordinateMismatch(String, String),
    ConfiguredSafetyLimitExceeded(String, Nat, Nat),
    MeaningDenied(RequestIdentity, PermissionDenial),
    PermissionIdentityMismatch(RequestIdentity, RequestIdentity),
    AdapterBindingUnavailable(RequestIdentity),
    BindingSelectionMismatch(RequestIdentity),
    ProgressionSubmitFailure(SubmitFailure),
    ProgressionStartFailure(StartDecisionFailure),
    ProvenanceRetentionRequired(RequestIdentity),
    UnknownRequest(RequestIdentity),
    RequestNotTerminal(RequestIdentity),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AdmissionDecision {
    Submitted(DynamicAdmissionState, Accepted),
    Started(DynamicAdmissionState, StartDecisionResult),
    Coalesced(DynamicAdmissionState, RequestIdentity),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FutureUseSet {
    pub identities: Vec<RequestIdentity>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OutstandingSignalSet {
    pub signals: Vec<AdmissionSignal>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProvenanceErasureWitness {
    Erased(RequestIdentity),
    Retained(RequestIdentity, String),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CoalescingWitness {
    Coalesced(RequestIdentity),
    NotCoalesced(String),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DynamicAdmissionResult {
    pub effective_budget: EffectiveBudget,
    pub admission_decision: AdmissionDecision,
    pub future_use_set: FutureUseSet,
    pub outstanding_signal_set: OutstandingSignalSet,
    pub provenance_erasure_witness: Option<ProvenanceErasureWitness>,
    pub coalescing_witness: CoalescingWitness,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome2<A, R> {
    Applied(A),
    Rejected(R),
}

fn find_by_identity<'a>(
    entries: &'a [RequestEntry],
    identity: &RequestIdentity,
) -> Option<&'a RequestEntry> {
    entries.iter().find(|entry| &entry.identity == identity)
}
fn replace_by_identity(
    entries: &[RequestEntry],
    identity: &RequestIdentity,
    replacement: RequestEntry,
) -> Vec<RequestEntry> {
    entries
        .iter()
        .map(|entry| {
            if &entry.identity == identity {
                replacement.clone()
            } else {
                entry.clone()
            }
        })
        .collect()
}
fn min_limit(
    a: &crate::request_progression::ConfiguredSafetyLimit,
    b: &crate::request_progression::ConfiguredSafetyLimit,
) -> crate::request_progression::ConfiguredSafetyLimit {
    crate::request_progression::ConfiguredSafetyLimit {
        resource: a.resource.clone(),
        maximum: if a.maximum <= b.maximum {
            a.maximum.clone()
        } else {
            b.maximum.clone()
        },
    }
}
fn effective_budget_of(configured: &ResourceBudget, observed: &ResourceBudget) -> EffectiveBudget {
    ResourceBudget {
        pending_maximum: min_limit(&configured.pending_maximum, &observed.pending_maximum),
        in_flight_maximum: min_limit(&configured.in_flight_maximum, &observed.in_flight_maximum),
        concurrent_maximum: min_limit(&configured.concurrent_maximum, &observed.concurrent_maximum),
    }
}
fn resource_coordinate_mismatch(
    configured: &ResourceBudget,
    observed: &ResourceBudget,
) -> Option<(String, String)> {
    for (a, b) in [
        (&configured.pending_maximum, &observed.pending_maximum),
        (&configured.in_flight_maximum, &observed.in_flight_maximum),
        (&configured.concurrent_maximum, &observed.concurrent_maximum),
    ] {
        if a.resource != b.resource {
            return Some((a.resource.clone(), b.resource.clone()));
        }
    }
    None
}
fn observation_age(input: &DynamicAdmissionInput) -> Nat {
    if input.observed_at < input.capacity_observation.observed_at {
        (&input.capacity_observation.observed_at - &input.observed_at)
            + &input.environment_specification.max_observation_age
            + Nat::from(1u8)
    } else {
        &input.observed_at - &input.capacity_observation.observed_at
    }
}
fn permission_check(request: &RequestInput) -> Option<DynamicAdmissionFailure> {
    match &request.permission {
        MeaningPermission::Denied(identity, reason) => Some(if identity == &request.identity {
            DynamicAdmissionFailure::MeaningDenied(identity.clone(), reason.clone())
        } else {
            DynamicAdmissionFailure::PermissionIdentityMismatch(
                request.identity.clone(),
                identity.clone(),
            )
        }),
        MeaningPermission::Permitted(identity, _) | MeaningPermission::Ordered(identity, _)
            if identity != &request.identity =>
        {
            Some(DynamicAdmissionFailure::PermissionIdentityMismatch(
                request.identity.clone(),
                identity.clone(),
            ))
        }
        _ => None,
    }
}
fn same_pending_entry(entry: &RequestEntry, request: &RequestInput) -> bool {
    entry.phase == RequestPhase::Pending
        && entry.identity == request.identity
        && entry.footprint == request.footprint
        && entry.demand == request.demand
        && entry.meaning_permission == request.permission
}
fn matching_pending_duplicate<'a>(
    snapshot: &'a RequestProgressionSnapshot,
    request: &RequestInput,
) -> Option<&'a RequestEntry> {
    find_by_identity(&snapshot.entries, &request.identity)
        .filter(|entry| same_pending_entry(entry, request))
}
fn is_execute_now(selection: &CostSelection) -> bool {
    matches!(selection, CostSelection::ExecuteNow(..))
}
fn to_future_use_set(provenance: &AdmissionProvenance) -> FutureUseSet {
    FutureUseSet {
        identities: provenance.future_uses.clone(),
    }
}
fn to_outstanding_signal_set(provenance: &AdmissionProvenance) -> OutstandingSignalSet {
    OutstandingSignalSet {
        signals: provenance.outstanding_signals.clone(),
    }
}
fn is_terminal_phase(phase: RequestPhase) -> bool {
    matches!(
        phase,
        RequestPhase::Published
            | RequestPhase::Superseded
            | RequestPhase::Cancelled
            | RequestPhase::Failed
    )
}
fn erase_meaning_permission_evidence(permission: &MeaningPermission) -> MeaningPermission {
    match permission {
        MeaningPermission::Permitted(identity, _) => {
            MeaningPermission::Permitted(identity.clone(), vec![])
        }
        MeaningPermission::Ordered(identity, _) => {
            MeaningPermission::Ordered(identity.clone(), vec![])
        }
        MeaningPermission::Denied(identity, reason) => {
            MeaningPermission::Denied(identity.clone(), reason.clone())
        }
    }
}
fn erase_entry_provenance(entry: &RequestEntry) -> RequestEntry {
    RequestEntry {
        footprint: crate::request_progression::RequestFootprint {
            reads: vec![],
            writes: vec![],
            effect_class: entry.footprint.effect_class,
        },
        meaning_permission: erase_meaning_permission_evidence(&entry.meaning_permission),
        ..entry.clone()
    }
}

pub fn elide_admission_provenance(
    state: &DynamicAdmissionState,
    identity: &RequestIdentity,
) -> Outcome2<(DynamicAdmissionState, ProvenanceErasureWitness), DynamicAdmissionFailure> {
    let entry = match find_by_identity(&state.progression.entries, identity) {
        Some(entry) => entry.clone(),
        None => {
            return Outcome2::Rejected(DynamicAdmissionFailure::UnknownRequest(identity.clone()))
        }
    };
    if !is_terminal_phase(entry.phase) {
        return Outcome2::Rejected(DynamicAdmissionFailure::RequestNotTerminal(
            identity.clone(),
        ));
    }
    if state.provenance.future_uses.contains(identity)
        || state
            .provenance
            .outstanding_signals
            .iter()
            .any(|signal| &signal.identity == identity)
    {
        return Outcome2::Rejected(DynamicAdmissionFailure::ProvenanceRetentionRequired(
            identity.clone(),
        ));
    }
    let progression = RequestProgressionSnapshot {
        entries: replace_by_identity(
            &state.progression.entries,
            identity,
            erase_entry_provenance(&entry),
        ),
        ..state.progression.clone()
    };
    let provenance = AdmissionProvenance {
        future_uses: state
            .provenance
            .future_uses
            .iter()
            .filter(|item| *item != identity)
            .cloned()
            .collect(),
        outstanding_signals: state
            .provenance
            .outstanding_signals
            .iter()
            .filter(|item| &item.identity != identity)
            .cloned()
            .collect(),
    };
    Outcome2::Applied((
        DynamicAdmissionState {
            progression,
            provenance,
            ..state.clone()
        },
        ProvenanceErasureWitness::Erased(identity.clone()),
    ))
}

pub fn admit_dynamic_request(
    input: &DynamicAdmissionInput,
) -> Outcome2<DynamicAdmissionResult, DynamicAdmissionFailure> {
    let age = observation_age(input);
    if age > input.environment_specification.max_observation_age {
        return Outcome2::Rejected(DynamicAdmissionFailure::CapacityObservationUnavailable(
            age,
            input.environment_specification.max_observation_age.clone(),
        ));
    }
    if let Some((configured, observed)) = resource_coordinate_mismatch(
        &input.state.configured_safety_limit,
        &input.capacity_observation.observed,
    ) {
        return Outcome2::Rejected(DynamicAdmissionFailure::ResourceCoordinateMismatch(
            configured, observed,
        ));
    }
    if let Some(failure) = permission_check(&input.request) {
        return Outcome2::Rejected(failure);
    }
    let effective_budget = effective_budget_of(
        &input.state.configured_safety_limit,
        &input.capacity_observation.observed,
    );
    let snapshot = &input.state.progression;
    let provenance = &input.state.provenance;
    if let Some(entry) = matching_pending_duplicate(snapshot, &input.request) {
        return match (&entry.cost_selection, &input.start) {
            (None, None) | (Some(_), Some(_)) if entry.cost_selection == input.start => {
                Outcome2::Applied(DynamicAdmissionResult {
                    effective_budget,
                    admission_decision: AdmissionDecision::Coalesced(
                        input.state.clone(),
                        input.request.identity.clone(),
                    ),
                    future_use_set: to_future_use_set(provenance),
                    outstanding_signal_set: to_outstanding_signal_set(provenance),
                    provenance_erasure_witness: None,
                    coalescing_witness: CoalescingWitness::Coalesced(
                        input.request.identity.clone(),
                    ),
                })
            }
            (Some(_), Some(_)) => Outcome2::Rejected(
                DynamicAdmissionFailure::BindingSelectionMismatch(input.request.identity.clone()),
            ),
            _ => Outcome2::Rejected(DynamicAdmissionFailure::AdapterBindingUnavailable(
                input.request.identity.clone(),
            )),
        };
    }
    let pending = &derive_pending(snapshot).pending + &input.request.demand.pending;
    if pending > effective_budget.pending_maximum.maximum {
        return Outcome2::Rejected(DynamicAdmissionFailure::ConfiguredSafetyLimitExceeded(
            effective_budget.pending_maximum.resource.clone(),
            pending,
            effective_budget.pending_maximum.maximum.clone(),
        ));
    }
    let execute = input.start.as_ref().is_some_and(is_execute_now);
    let in_flight = &derive_in_flight(snapshot).in_flight + &input.request.demand.in_flight;
    let concurrent = &derive_concurrent(snapshot).concurrent + &input.request.demand.concurrent;
    if execute && in_flight > effective_budget.in_flight_maximum.maximum {
        return Outcome2::Rejected(DynamicAdmissionFailure::ConfiguredSafetyLimitExceeded(
            effective_budget.in_flight_maximum.resource.clone(),
            in_flight,
            effective_budget.in_flight_maximum.maximum.clone(),
        ));
    }
    if execute && concurrent > effective_budget.concurrent_maximum.maximum {
        return Outcome2::Rejected(DynamicAdmissionFailure::ConfiguredSafetyLimitExceeded(
            effective_budget.concurrent_maximum.resource.clone(),
            concurrent,
            effective_budget.concurrent_maximum.maximum.clone(),
        ));
    }
    let budgeted = RequestProgressionSnapshot {
        budget: effective_budget.clone(),
        ..snapshot.clone()
    };
    match submit(&budgeted, &input.request) {
        SubmitResult::SubmitRejected(_, failure) => {
            Outcome2::Rejected(DynamicAdmissionFailure::ProgressionSubmitFailure(failure))
        }
        SubmitResult::Accepted(submitted, accepted) => match &input.start {
            None => {
                let state = DynamicAdmissionState {
                    progression: submitted,
                    ..input.state.clone()
                };
                Outcome2::Applied(DynamicAdmissionResult {
                    effective_budget,
                    admission_decision: AdmissionDecision::Submitted(state.clone(), accepted),
                    future_use_set: to_future_use_set(&state.provenance),
                    outstanding_signal_set: to_outstanding_signal_set(&state.provenance),
                    provenance_erasure_witness: None,
                    coalescing_witness: CoalescingWitness::NotCoalesced(
                        "no duplicate pending request".to_string(),
                    ),
                })
            }
            Some(selection) => match decide_start(&submitted, &accepted, selection) {
                StartDecisionResult::Rejected(_, failure) => {
                    Outcome2::Rejected(DynamicAdmissionFailure::ProgressionStartFailure(failure))
                }
                StartDecisionResult::Execute(advanced, starting, command) => {
                    let state = DynamicAdmissionState {
                        progression: advanced.clone(),
                        ..input.state.clone()
                    };
                    let result = StartDecisionResult::Execute(advanced, starting, command);
                    Outcome2::Applied(DynamicAdmissionResult {
                        effective_budget,
                        admission_decision: AdmissionDecision::Started(state.clone(), result),
                        future_use_set: to_future_use_set(&state.provenance),
                        outstanding_signal_set: to_outstanding_signal_set(&state.provenance),
                        provenance_erasure_witness: None,
                        coalescing_witness: CoalescingWitness::NotCoalesced(
                            "no duplicate pending request".to_string(),
                        ),
                    })
                }
                StartDecisionResult::Deferred(advanced, accepted) => {
                    let state = DynamicAdmissionState {
                        progression: advanced.clone(),
                        ..input.state.clone()
                    };
                    let result = StartDecisionResult::Deferred(advanced, accepted);
                    Outcome2::Applied(DynamicAdmissionResult {
                        effective_budget,
                        admission_decision: AdmissionDecision::Started(state.clone(), result),
                        future_use_set: to_future_use_set(&state.provenance),
                        outstanding_signal_set: to_outstanding_signal_set(&state.provenance),
                        provenance_erasure_witness: None,
                        coalescing_witness: CoalescingWitness::NotCoalesced(
                            "no duplicate pending request".to_string(),
                        ),
                    })
                }
            },
        },
    }
}
