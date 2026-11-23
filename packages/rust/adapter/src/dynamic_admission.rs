// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

//! Dynamic admission over request progression: safety budget, idempotent coalescing, and provenance elision.

use std::collections::HashSet;

use neco_quotient_retention::{
    judge_erasure_by, DematerializeWitness, ErasureDecision, ErasureRequest, LiveFns, MissingInput,
    Recoverability, RetentionReason,
};

use crate::core::Nat;
use crate::request_progression::{
    decide_start, derive_concurrent, derive_in_flight, derive_pending, find_request,
    progression_budget, start_after_submit, submit, submit_check, update_request, with_budget,
    Accepted, AdapterCommand, CostSelection, MeaningPermission, PermissionDenial, RequestEntry,
    RequestIdentity, RequestInput, RequestPhase, RequestProgressionSnapshot, ResourceBudget,
    StartDecisionFailure, StartDecisionResult, Starting, SubmitFailure, SubmitResult,
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
/// Dynamic admission state. The identities named by the provenance are
/// indexed at construction for the membership read of the retention judgment.
#[derive(Clone, Debug)]
pub struct DynamicAdmissionState {
    progression: RequestProgressionSnapshot,
    configured_safety_limit: ResourceBudget,
    provenance: AdmissionProvenance,
    future_use_index: HashSet<RequestIdentity>,
    outstanding_signal_index: HashSet<RequestIdentity>,
}
impl PartialEq for DynamicAdmissionState {
    fn eq(&self, other: &Self) -> bool {
        self.progression == other.progression
            && self.configured_safety_limit == other.configured_safety_limit
            && self.provenance == other.provenance
    }
}
impl Eq for DynamicAdmissionState {}
pub fn admission_state_of(
    progression: RequestProgressionSnapshot,
    configured_safety_limit: ResourceBudget,
    provenance: AdmissionProvenance,
) -> DynamicAdmissionState {
    let future_use_index = provenance.future_uses.iter().cloned().collect();
    let outstanding_signal_index = provenance
        .outstanding_signals
        .iter()
        .map(|signal| signal.identity.clone())
        .collect();
    DynamicAdmissionState {
        progression,
        configured_safety_limit,
        provenance,
        future_use_index,
        outstanding_signal_index,
    }
}
pub fn admission_progression(state: &DynamicAdmissionState) -> &RequestProgressionSnapshot {
    &state.progression
}
pub fn admission_safety_limit(state: &DynamicAdmissionState) -> &ResourceBudget {
    &state.configured_safety_limit
}
pub fn admission_provenance(state: &DynamicAdmissionState) -> &AdmissionProvenance {
    &state.provenance
}
/// Identities whose data a caller still intends to use again, read from the state.
pub fn admission_future_use_set(state: &DynamicAdmissionState) -> FutureUseSet {
    FutureUseSet {
        identities: state.provenance.future_uses.clone(),
    }
}
/// Adapter signals still outstanding, read from the state.
pub fn admission_outstanding_signal_set(state: &DynamicAdmissionState) -> OutstandingSignalSet {
    OutstandingSignalSet {
        signals: state.provenance.outstanding_signals.clone(),
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DynamicAdmissionInput {
    pub request: RequestInput,
    pub environment_specification: EnvironmentSpecification,
    pub capacity_observation: CapacityObservation,
    pub observed_at: Nat,
    pub start: Option<CostSelection>,
}
pub type EffectiveBudget = ResourceBudget;
/// The kind of provenance an erasure removes from a terminal entry.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProvenanceObservation {
    Footprint,
    Evidence,
}
/// The retention judgment's erasure witness for one identity's provenance.
pub type ErasureWitness = DematerializeWitness<RequestIdentity, (), (), ProvenanceObservation>;
/// The retention judgment's reason for keeping one identity's provenance.
pub type ErasureRetention = RetentionReason<RequestIdentity, (), ProvenanceObservation>;
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
    ProvenanceRetentionRequired(RequestIdentity, Vec<ErasureRetention>),
    ErasureInputIncomplete(RequestIdentity, MissingInput),
    UnknownRequest(RequestIdentity),
    RequestNotTerminal(RequestIdentity),
}
/// Decision of one admission. The resulting state is returned next to the
/// decision by [`admit_dynamic_request`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AdmissionDecision {
    Submitted(Accepted),
    Executed(Starting, AdapterCommand),
    Deferred(Accepted),
    Coalesced(RequestIdentity),
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
pub enum CoalescingWitness {
    Coalesced(RequestIdentity),
    NotCoalesced(&'static str),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DynamicAdmissionResult {
    pub effective_budget: EffectiveBudget,
    pub admission_decision: AdmissionDecision,
    pub provenance_erasure_witness: Option<ErasureWitness>,
    pub coalescing_witness: CoalescingWitness,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome2<A, R> {
    Applied(A),
    Rejected(R),
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
    find_request(snapshot, &request.identity).filter(|entry| same_pending_entry(entry, request))
}
fn is_execute_now(selection: &CostSelection) -> bool {
    matches!(selection, CostSelection::ExecuteNow(..))
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
fn erase_entry_provenance(entry: &mut RequestEntry) {
    entry.footprint.reads.clear();
    entry.footprint.writes.clear();
    match &mut entry.meaning_permission {
        MeaningPermission::Permitted(_, evidence) | MeaningPermission::Ordered(_, evidence) => {
            evidence.clear()
        }
        MeaningPermission::Denied(_, _) => {}
    }
}

fn elision_precondition_failure(
    state: &DynamicAdmissionState,
    identity: &RequestIdentity,
) -> Option<DynamicAdmissionFailure> {
    let Some(entry) = find_request(&state.progression, identity) else {
        return Some(DynamicAdmissionFailure::UnknownRequest(identity.clone()));
    };
    if !is_terminal_phase(entry.phase) {
        return Some(DynamicAdmissionFailure::RequestNotTerminal(
            identity.clone(),
        ));
    }
    None
}

pub fn elide_admission_provenance(
    mut state: DynamicAdmissionState,
    identity: &RequestIdentity,
) -> (
    DynamicAdmissionState,
    Outcome2<ErasureWitness, DynamicAdmissionFailure>,
) {
    if let Some(failure) = elision_precondition_failure(&state, identity) {
        return (state, Outcome2::Rejected(failure));
    }
    let request = ErasureRequest {
        target: identity.clone(),
        target_basis: None,
        removed_observations: vec![
            ProvenanceObservation::Footprint,
            ProvenanceObservation::Evidence,
        ],
        preserved_observations: Vec::new(),
    };
    let membership = LiveFns {
        active_basis: |_: &()| false,
        branch_root: |_: &RequestIdentity| false,
        future_use: |target: &RequestIdentity| state.future_use_index.contains(target),
        outstanding_effect: |_: &RequestIdentity| false,
        outstanding_signal: |target: &RequestIdentity| {
            state.outstanding_signal_index.contains(target)
        },
    };
    let decision = judge_erasure_by(
        request,
        &membership,
        Some(Recoverability::<(), ()>::Irrecoverable),
    );
    match decision {
        ErasureDecision::Dematerialize(witness) => {
            update_request(&mut state.progression, identity, erase_entry_provenance);
            (state, Outcome2::Applied(witness))
        }
        ErasureDecision::Retain(reasons) => (
            state,
            Outcome2::Rejected(DynamicAdmissionFailure::ProvenanceRetentionRequired(
                identity.clone(),
                reasons,
            )),
        ),
        ErasureDecision::Rejected(missing) => (
            state,
            Outcome2::Rejected(DynamicAdmissionFailure::ErasureInputIncomplete(
                identity.clone(),
                missing,
            )),
        ),
    }
}

fn admission_failure(
    state: &DynamicAdmissionState,
    input: &DynamicAdmissionInput,
) -> Option<DynamicAdmissionFailure> {
    let age = observation_age(input);
    if age > input.environment_specification.max_observation_age {
        return Some(DynamicAdmissionFailure::CapacityObservationUnavailable(
            age,
            input.environment_specification.max_observation_age.clone(),
        ));
    }
    if let Some((configured, observed)) = resource_coordinate_mismatch(
        &state.configured_safety_limit,
        &input.capacity_observation.observed,
    ) {
        return Some(DynamicAdmissionFailure::ResourceCoordinateMismatch(
            configured, observed,
        ));
    }
    permission_check(&input.request)
}

fn coalescing(
    entry: &RequestEntry,
    input: &DynamicAdmissionInput,
) -> Outcome2<(), DynamicAdmissionFailure> {
    match (&entry.cost_selection, &input.start) {
        (None, None) | (Some(_), Some(_)) if entry.cost_selection == input.start => {
            Outcome2::Applied(())
        }
        (Some(_), Some(_)) => Outcome2::Rejected(
            DynamicAdmissionFailure::BindingSelectionMismatch(input.request.identity.clone()),
        ),
        _ => Outcome2::Rejected(DynamicAdmissionFailure::AdapterBindingUnavailable(
            input.request.identity.clone(),
        )),
    }
}

fn budget_failure(
    snapshot: &RequestProgressionSnapshot,
    input: &DynamicAdmissionInput,
    effective_budget: &EffectiveBudget,
) -> Option<DynamicAdmissionFailure> {
    let pending = &derive_pending(snapshot).pending + &input.request.demand.pending;
    if pending > effective_budget.pending_maximum.maximum {
        return Some(DynamicAdmissionFailure::ConfiguredSafetyLimitExceeded(
            effective_budget.pending_maximum.resource.clone(),
            pending,
            effective_budget.pending_maximum.maximum.clone(),
        ));
    }
    if !input.start.as_ref().is_some_and(is_execute_now) {
        return None;
    }
    let in_flight = &derive_in_flight(snapshot).in_flight + &input.request.demand.in_flight;
    if in_flight > effective_budget.in_flight_maximum.maximum {
        return Some(DynamicAdmissionFailure::ConfiguredSafetyLimitExceeded(
            effective_budget.in_flight_maximum.resource.clone(),
            in_flight,
            effective_budget.in_flight_maximum.maximum.clone(),
        ));
    }
    let concurrent = &derive_concurrent(snapshot).concurrent + &input.request.demand.concurrent;
    if concurrent > effective_budget.concurrent_maximum.maximum {
        return Some(DynamicAdmissionFailure::ConfiguredSafetyLimitExceeded(
            effective_budget.concurrent_maximum.resource.clone(),
            concurrent,
            effective_budget.concurrent_maximum.maximum.clone(),
        ));
    }
    None
}

fn not_coalesced() -> CoalescingWitness {
    CoalescingWitness::NotCoalesced(NOT_COALESCED_REASON)
}

const NOT_COALESCED_REASON: &str = "no duplicate pending request";

/// Admit `input` against `state`; return the resulting state and the
/// outcome. The state is unchanged unless the outcome is `Applied`.
pub fn admit_dynamic_request(
    state: DynamicAdmissionState,
    input: &DynamicAdmissionInput,
) -> (
    DynamicAdmissionState,
    Outcome2<DynamicAdmissionResult, DynamicAdmissionFailure>,
) {
    if let Some(failure) = admission_failure(&state, input) {
        return (state, Outcome2::Rejected(failure));
    }
    let effective_budget = effective_budget_of(
        &state.configured_safety_limit,
        &input.capacity_observation.observed,
    );
    if let Some(entry) = matching_pending_duplicate(&state.progression, &input.request) {
        let outcome = match coalescing(entry, input) {
            Outcome2::Applied(()) => Outcome2::Applied(DynamicAdmissionResult {
                effective_budget,
                admission_decision: AdmissionDecision::Coalesced(input.request.identity.clone()),
                provenance_erasure_witness: None,
                coalescing_witness: CoalescingWitness::Coalesced(input.request.identity.clone()),
            }),
            Outcome2::Rejected(failure) => Outcome2::Rejected(failure),
        };
        return (state, outcome);
    }
    if let Some(failure) = budget_failure(&state.progression, input, &effective_budget) {
        return (state, Outcome2::Rejected(failure));
    }
    if let Some(failure) = submit_check(&state.progression, &input.request, &effective_budget) {
        return (
            state,
            Outcome2::Rejected(DynamicAdmissionFailure::ProgressionSubmitFailure(failure)),
        );
    }
    if let Some(selection) = &input.start {
        if let Err(failure) = start_after_submit(
            &state.progression,
            &input.request,
            &effective_budget,
            selection,
        ) {
            return (
                state,
                Outcome2::Rejected(DynamicAdmissionFailure::ProgressionStartFailure(failure)),
            );
        }
    }
    let DynamicAdmissionState {
        progression,
        configured_safety_limit,
        provenance,
        future_use_index,
        outstanding_signal_index,
    } = state;
    let held_budget = progression_budget(&progression).clone();
    let rebuild = |progression| DynamicAdmissionState {
        progression,
        configured_safety_limit,
        provenance,
        future_use_index,
        outstanding_signal_index,
    };
    let (submitted, accepted) = match submit(
        with_budget(progression, effective_budget.clone()),
        &input.request,
    ) {
        SubmitResult::SubmitRejected(unchanged, failure) => {
            return (
                rebuild(with_budget(unchanged, held_budget)),
                Outcome2::Rejected(DynamicAdmissionFailure::ProgressionSubmitFailure(failure)),
            )
        }
        SubmitResult::Accepted(submitted, accepted) => (submitted, accepted),
    };
    let Some(selection) = &input.start else {
        return (
            rebuild(submitted),
            Outcome2::Applied(DynamicAdmissionResult {
                effective_budget,
                admission_decision: AdmissionDecision::Submitted(accepted),
                provenance_erasure_witness: None,
                coalescing_witness: not_coalesced(),
            }),
        );
    };
    let (advanced, admission_decision) = match decide_start(submitted, &accepted, selection) {
        StartDecisionResult::Execute(advanced, starting, command) => {
            (advanced, AdmissionDecision::Executed(starting, command))
        }
        StartDecisionResult::Deferred(advanced, accepted) => {
            (advanced, AdmissionDecision::Deferred(accepted))
        }
        StartDecisionResult::Rejected(advanced, failure) => {
            return (
                rebuild(advanced),
                Outcome2::Rejected(DynamicAdmissionFailure::ProgressionStartFailure(failure)),
            )
        }
    };
    (
        rebuild(advanced),
        Outcome2::Applied(DynamicAdmissionResult {
            effective_budget,
            admission_decision,
            provenance_erasure_witness: None,
            coalescing_witness: not_coalesced(),
        }),
    )
}
