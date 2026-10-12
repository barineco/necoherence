// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

//! Request progression: pure policy decisions separated from adapter observations.

use crate::core::Nat;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RequestPolicy {
    LatestWins,
    Fifo,
    AllExecute,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RequestPhase {
    Pending,
    Preparing,
    Publishing,
    Published,
    Superseded,
    Cancelled,
    Failed,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RequestEffectClass {
    Pure,
    OrderedEffect,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RequestIdentity {
    pub kind: String,
    pub provenance: String,
    pub revision: Nat,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RequestFootprint {
    pub reads: Vec<String>,
    pub writes: Vec<String>,
    pub effect_class: RequestEffectClass,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResourceDemand {
    pub pending: Nat,
    pub in_flight: Nat,
    pub concurrent: Nat,
}
impl ResourceDemand {
    fn zero() -> Self {
        Self {
            pending: 0u8.into(),
            in_flight: 0u8.into(),
            concurrent: 0u8.into(),
        }
    }
    fn add(&self, other: &Self) -> Self {
        Self {
            pending: &self.pending + &other.pending,
            in_flight: &self.in_flight + &other.in_flight,
            concurrent: &self.concurrent + &other.concurrent,
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConfiguredSafetyLimit {
    pub resource: String,
    pub maximum: Nat,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResourceBudget {
    pub pending_maximum: ConfiguredSafetyLimit,
    pub in_flight_maximum: ConfiguredSafetyLimit,
    pub concurrent_maximum: ConfiguredSafetyLimit,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EvidenceVersion {
    pub identifier: String,
    pub digest: String,
    pub artifact_path: String,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PermissionDenial {
    Denial(String),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MeaningPermission {
    Permitted(RequestIdentity, Vec<EvidenceVersion>),
    Ordered(RequestIdentity, Vec<EvidenceVersion>),
    Denied(RequestIdentity, PermissionDenial),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ExecutionHandle {
    pub value: String,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CostSelection {
    ExecuteNow(RequestIdentity, EvidenceVersion, Nat),
    RemainPending(RequestIdentity, EvidenceVersion, Nat),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RequestEntry {
    pub identity: RequestIdentity,
    pub footprint: RequestFootprint,
    pub demand: ResourceDemand,
    pub phase: RequestPhase,
    pub meaning_permission: MeaningPermission,
    pub cost_selection: Option<CostSelection>,
    pub execution_handle: Option<ExecutionHandle>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RequestProgressionSnapshot {
    pub policy: RequestPolicy,
    pub budget: ResourceBudget,
    pub current_identity: Option<RequestIdentity>,
    pub entries: Vec<RequestEntry>,
    pub revision: Nat,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RequestInput {
    pub identity: RequestIdentity,
    pub footprint: RequestFootprint,
    pub demand: ResourceDemand,
    pub permission: MeaningPermission,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Accepted {
    pub identity: RequestIdentity,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AdapterCommand {
    StartCommand(RequestIdentity, RequestFootprint),
    CancelCommand(RequestIdentity, ExecutionHandle),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Starting {
    pub identity: RequestIdentity,
    pub command: AdapterCommand,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Running {
    pub identity: RequestIdentity,
    pub handle: ExecutionHandle,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AdapterSignal<Result> {
    Started(RequestIdentity, ExecutionHandle),
    Completed(RequestIdentity, ExecutionHandle, Result),
    CancelledAtAdapter(RequestIdentity, ExecutionHandle),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AdapterFailure {
    StartAdapterFailure(RequestIdentity, String),
    CompletionAdapterFailure(RequestIdentity, ExecutionHandle, String),
    CancellationAdapterFailure(RequestIdentity, ExecutionHandle, String),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AdapterResult<Signal, Failure> {
    AppliedSignal(Signal),
    AdapterFailed(Failure),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SubmitFailure {
    DuplicateIdentity(RequestIdentity),
    PendingLimitExceeded(ResourceDemand, ResourceBudget),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SubmitResult {
    Accepted(RequestProgressionSnapshot, Accepted),
    SubmitRejected(RequestProgressionSnapshot, SubmitFailure),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StartDecisionFailure {
    UnknownRequest(RequestIdentity),
    RequestNotPending(RequestIdentity),
    PolicyOrderBlocked(RequestIdentity),
    PermissionDenied(RequestIdentity, PermissionDenial),
    PermissionIdentityMismatch(RequestIdentity, RequestIdentity),
    PermissionNotOrdered(RequestIdentity),
    CostSelectionIdentityMismatch(RequestIdentity, RequestIdentity),
    InFlightLimitExceeded(ResourceDemand, ResourceBudget),
    ConcurrentLimitExceeded(ResourceDemand, ResourceBudget),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StartDecisionResult {
    Execute(RequestProgressionSnapshot, Starting, AdapterCommand),
    Deferred(RequestProgressionSnapshot, Accepted),
    Rejected(RequestProgressionSnapshot, StartDecisionFailure),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StartObservationFailure {
    UnknownRequest(RequestIdentity),
    RequestNotStarting(RequestIdentity),
    StartIdentityMismatch(RequestIdentity, RequestIdentity),
    StartSignalMismatch(RequestIdentity),
    StartAdapterFailureObserved(RequestIdentity, String),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StartObservationResult {
    Publishing(RequestProgressionSnapshot, Running),
    Failed(RequestProgressionSnapshot, StartObservationFailure),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CompletionObservationFailure {
    UnknownCompletion(RequestIdentity),
    CompletionNotRunning(RequestIdentity),
    HandleMismatch(RequestIdentity),
    CompletionIdentityMismatch(RequestIdentity, RequestIdentity),
    CompletionSignalMismatch(RequestIdentity),
    CompletionAdapterFailureObserved(RequestIdentity, String),
    CancellationAdapterFailureObserved(RequestIdentity, String),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CompletionObservationResult<Result> {
    Applied(RequestProgressionSnapshot, RequestIdentity, Result),
    Superseded(RequestProgressionSnapshot, RequestIdentity),
    Cancelled(RequestProgressionSnapshot, RequestIdentity),
    Failed(RequestProgressionSnapshot, CompletionObservationFailure),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CancelFailure {
    UnknownRequest(RequestIdentity),
    RequestAlreadyTerminal(RequestIdentity),
    MissingExecutionHandle(RequestIdentity),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CancelDecisionResult {
    Cancelled(RequestProgressionSnapshot, RequestIdentity),
    CancelCommand(RequestProgressionSnapshot, Running, AdapterCommand),
    Rejected(RequestProgressionSnapshot, CancelFailure),
}

pub fn empty(policy: RequestPolicy, budget: ResourceBudget) -> RequestProgressionSnapshot {
    RequestProgressionSnapshot {
        policy,
        budget,
        current_identity: None,
        entries: vec![],
        revision: 0u8.into(),
    }
}
fn find_entry<'a>(
    entries: &'a [RequestEntry],
    identity: &RequestIdentity,
) -> Option<&'a RequestEntry> {
    entries.iter().find(|entry| &entry.identity == identity)
}
fn replace_entry(
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
fn sum_demand(
    entries: &[RequestEntry],
    predicate: impl Fn(&RequestEntry) -> bool,
) -> ResourceDemand {
    entries
        .iter()
        .filter(|entry| predicate(entry))
        .fold(ResourceDemand::zero(), |total, entry| {
            total.add(&entry.demand)
        })
}
pub fn derive_pending(snapshot: &RequestProgressionSnapshot) -> ResourceDemand {
    sum_demand(&snapshot.entries, |entry| {
        entry.phase == RequestPhase::Pending
    })
}
pub fn derive_in_flight(snapshot: &RequestProgressionSnapshot) -> ResourceDemand {
    sum_demand(&snapshot.entries, |entry| {
        matches!(
            entry.phase,
            RequestPhase::Preparing | RequestPhase::Publishing
        )
    })
}
pub fn derive_concurrent(snapshot: &RequestProgressionSnapshot) -> ResourceDemand {
    sum_demand(&snapshot.entries, |entry| {
        entry.phase == RequestPhase::Publishing
    })
}
fn policy_order_allowed(snapshot: &RequestProgressionSnapshot, identity: &RequestIdentity) -> bool {
    match snapshot.policy {
        RequestPolicy::LatestWins => snapshot.current_identity.as_ref() == Some(identity),
        RequestPolicy::AllExecute => true,
        RequestPolicy::Fifo => snapshot
            .entries
            .iter()
            .find(|entry| entry.phase == RequestPhase::Pending)
            .is_some_and(|entry| &entry.identity == identity),
    }
}
fn ordered_effect_allowed(
    snapshot: &RequestProgressionSnapshot,
    identity: &RequestIdentity,
    entry: &RequestEntry,
) -> bool {
    if entry.footprint.effect_class != RequestEffectClass::OrderedEffect {
        true
    } else {
        match snapshot.entries.iter().find(|item| {
            item.phase == RequestPhase::Pending
                && item.footprint.effect_class == RequestEffectClass::OrderedEffect
        }) {
            Some(item) => &item.identity == identity,
            None => true,
        }
    }
}
fn revised(
    snapshot: &RequestProgressionSnapshot,
    entries: Vec<RequestEntry>,
) -> RequestProgressionSnapshot {
    RequestProgressionSnapshot {
        entries,
        revision: &snapshot.revision + Nat::from(1u8),
        ..snapshot.clone()
    }
}

pub fn submit(snapshot: &RequestProgressionSnapshot, request: &RequestInput) -> SubmitResult {
    if find_entry(&snapshot.entries, &request.identity).is_some() {
        return SubmitResult::SubmitRejected(
            snapshot.clone(),
            SubmitFailure::DuplicateIdentity(request.identity.clone()),
        );
    }
    if &derive_pending(snapshot).pending + &request.demand.pending
        > snapshot.budget.pending_maximum.maximum
    {
        return SubmitResult::SubmitRejected(
            snapshot.clone(),
            SubmitFailure::PendingLimitExceeded(request.demand.clone(), snapshot.budget.clone()),
        );
    }
    let entry = RequestEntry {
        identity: request.identity.clone(),
        footprint: request.footprint.clone(),
        demand: request.demand.clone(),
        phase: RequestPhase::Pending,
        meaning_permission: request.permission.clone(),
        cost_selection: None,
        execution_handle: None,
    };
    let mut entries: Vec<_> = snapshot
        .entries
        .iter()
        .map(|item| {
            if snapshot.policy == RequestPolicy::LatestWins && item.phase == RequestPhase::Pending {
                RequestEntry {
                    phase: RequestPhase::Superseded,
                    ..item.clone()
                }
            } else {
                item.clone()
            }
        })
        .collect();
    entries.push(entry);
    SubmitResult::Accepted(
        RequestProgressionSnapshot {
            entries,
            current_identity: Some(request.identity.clone()),
            revision: &snapshot.revision + Nat::from(1u8),
            ..snapshot.clone()
        },
        Accepted {
            identity: request.identity.clone(),
        },
    )
}

pub fn decide_start(
    snapshot: &RequestProgressionSnapshot,
    accepted: &Accepted,
    selection: &CostSelection,
) -> StartDecisionResult {
    let entry = match find_entry(&snapshot.entries, &accepted.identity) {
        Some(entry) => entry.clone(),
        None => {
            return StartDecisionResult::Rejected(
                snapshot.clone(),
                StartDecisionFailure::UnknownRequest(accepted.identity.clone()),
            )
        }
    };
    if entry.phase != RequestPhase::Pending {
        return StartDecisionResult::Rejected(
            snapshot.clone(),
            StartDecisionFailure::RequestNotPending(accepted.identity.clone()),
        );
    }
    if !policy_order_allowed(snapshot, &accepted.identity)
        || !ordered_effect_allowed(snapshot, &accepted.identity, &entry)
    {
        return StartDecisionResult::Rejected(
            snapshot.clone(),
            StartDecisionFailure::PolicyOrderBlocked(accepted.identity.clone()),
        );
    }
    match &entry.meaning_permission {
        MeaningPermission::Denied(_, reason) => {
            return StartDecisionResult::Rejected(
                snapshot.clone(),
                StartDecisionFailure::PermissionDenied(accepted.identity.clone(), reason.clone()),
            )
        }
        MeaningPermission::Permitted(identity, _) if identity != &accepted.identity => {
            return StartDecisionResult::Rejected(
                snapshot.clone(),
                StartDecisionFailure::PermissionIdentityMismatch(
                    accepted.identity.clone(),
                    identity.clone(),
                ),
            )
        }
        MeaningPermission::Ordered(identity, _) if identity != &accepted.identity => {
            return StartDecisionResult::Rejected(
                snapshot.clone(),
                StartDecisionFailure::PermissionIdentityMismatch(
                    accepted.identity.clone(),
                    identity.clone(),
                ),
            )
        }
        MeaningPermission::Permitted(_, _)
            if entry.footprint.effect_class == RequestEffectClass::OrderedEffect =>
        {
            return StartDecisionResult::Rejected(
                snapshot.clone(),
                StartDecisionFailure::PermissionNotOrdered(accepted.identity.clone()),
            )
        }
        _ => {}
    }
    let selected_identity = match selection {
        CostSelection::ExecuteNow(identity, _, _)
        | CostSelection::RemainPending(identity, _, _) => identity,
    };
    if selected_identity != &accepted.identity {
        return StartDecisionResult::Rejected(
            snapshot.clone(),
            StartDecisionFailure::CostSelectionIdentityMismatch(
                accepted.identity.clone(),
                selected_identity.clone(),
            ),
        );
    }
    match selection {
        CostSelection::RemainPending(_, _, _) => StartDecisionResult::Deferred(
            RequestProgressionSnapshot {
                entries: replace_entry(
                    &snapshot.entries,
                    &accepted.identity,
                    RequestEntry {
                        cost_selection: Some(selection.clone()),
                        ..entry
                    },
                ),
                ..snapshot.clone()
            },
            accepted.clone(),
        ),
        CostSelection::ExecuteNow(_, _, _) => {
            if &derive_in_flight(snapshot).in_flight + &entry.demand.in_flight
                > snapshot.budget.in_flight_maximum.maximum
            {
                return StartDecisionResult::Rejected(
                    snapshot.clone(),
                    StartDecisionFailure::InFlightLimitExceeded(
                        entry.demand.clone(),
                        snapshot.budget.clone(),
                    ),
                );
            }
            if &derive_concurrent(snapshot).concurrent + &entry.demand.concurrent
                > snapshot.budget.concurrent_maximum.maximum
            {
                return StartDecisionResult::Rejected(
                    snapshot.clone(),
                    StartDecisionFailure::ConcurrentLimitExceeded(
                        entry.demand.clone(),
                        snapshot.budget.clone(),
                    ),
                );
            }
            let command =
                AdapterCommand::StartCommand(accepted.identity.clone(), entry.footprint.clone());
            let advanced = revised(
                snapshot,
                replace_entry(
                    &snapshot.entries,
                    &accepted.identity,
                    RequestEntry {
                        phase: RequestPhase::Preparing,
                        cost_selection: Some(selection.clone()),
                        ..entry
                    },
                ),
            );
            StartDecisionResult::Execute(
                advanced,
                Starting {
                    identity: accepted.identity.clone(),
                    command: command.clone(),
                },
                command,
            )
        }
    }
}

pub fn apply_start_observation<Result>(
    snapshot: &RequestProgressionSnapshot,
    starting: &Starting,
    observed: &AdapterResult<AdapterSignal<Result>, AdapterFailure>,
) -> StartObservationResult {
    let entry = match find_entry(&snapshot.entries, &starting.identity) {
        Some(entry) => entry.clone(),
        None => {
            return StartObservationResult::Failed(
                snapshot.clone(),
                StartObservationFailure::UnknownRequest(starting.identity.clone()),
            )
        }
    };
    if entry.phase != RequestPhase::Preparing {
        return StartObservationResult::Failed(
            snapshot.clone(),
            StartObservationFailure::RequestNotStarting(starting.identity.clone()),
        );
    }
    match observed {
        AdapterResult::AppliedSignal(AdapterSignal::Started(identity, handle))
            if identity == &starting.identity =>
        {
            let advanced = revised(
                snapshot,
                replace_entry(
                    &snapshot.entries,
                    &starting.identity,
                    RequestEntry {
                        phase: RequestPhase::Publishing,
                        execution_handle: Some(handle.clone()),
                        ..entry
                    },
                ),
            );
            StartObservationResult::Publishing(
                advanced,
                Running {
                    identity: starting.identity.clone(),
                    handle: handle.clone(),
                },
            )
        }
        AdapterResult::AppliedSignal(AdapterSignal::Started(identity, _)) => {
            StartObservationResult::Failed(
                revised(
                    snapshot,
                    replace_entry(
                        &snapshot.entries,
                        &starting.identity,
                        RequestEntry {
                            phase: RequestPhase::Failed,
                            ..entry
                        },
                    ),
                ),
                StartObservationFailure::StartIdentityMismatch(
                    starting.identity.clone(),
                    identity.clone(),
                ),
            )
        }
        AdapterResult::AdapterFailed(AdapterFailure::StartAdapterFailure(identity, detail)) => {
            let failure = if identity == &starting.identity {
                StartObservationFailure::StartAdapterFailureObserved(
                    starting.identity.clone(),
                    detail.clone(),
                )
            } else {
                StartObservationFailure::StartIdentityMismatch(
                    starting.identity.clone(),
                    identity.clone(),
                )
            };
            StartObservationResult::Failed(
                revised(
                    snapshot,
                    replace_entry(
                        &snapshot.entries,
                        &starting.identity,
                        RequestEntry {
                            phase: RequestPhase::Failed,
                            ..entry
                        },
                    ),
                ),
                failure,
            )
        }
        _ => StartObservationResult::Failed(
            revised(
                snapshot,
                replace_entry(
                    &snapshot.entries,
                    &starting.identity,
                    RequestEntry {
                        phase: RequestPhase::Failed,
                        ..entry
                    },
                ),
            ),
            StartObservationFailure::StartSignalMismatch(starting.identity.clone()),
        ),
    }
}

pub fn apply_completion_observation<Result: Clone>(
    snapshot: &RequestProgressionSnapshot,
    running: &Running,
    observed: &AdapterResult<AdapterSignal<Result>, AdapterFailure>,
) -> CompletionObservationResult<Result> {
    let entry = match find_entry(&snapshot.entries, &running.identity) {
        Some(entry) => entry.clone(),
        None => {
            return CompletionObservationResult::Failed(
                snapshot.clone(),
                CompletionObservationFailure::UnknownCompletion(running.identity.clone()),
            )
        }
    };
    if entry.phase != RequestPhase::Publishing {
        return CompletionObservationResult::Failed(
            snapshot.clone(),
            CompletionObservationFailure::CompletionNotRunning(running.identity.clone()),
        );
    }
    if entry.execution_handle.as_ref() != Some(&running.handle) {
        return CompletionObservationResult::Failed(
            snapshot.clone(),
            CompletionObservationFailure::HandleMismatch(running.identity.clone()),
        );
    }
    match observed {
        AdapterResult::AppliedSignal(AdapterSignal::Completed(identity, handle, value)) => {
            if identity != &running.identity {
                return CompletionObservationResult::Failed(
                    snapshot.clone(),
                    CompletionObservationFailure::CompletionIdentityMismatch(
                        running.identity.clone(),
                        identity.clone(),
                    ),
                );
            }
            if handle != &running.handle {
                return CompletionObservationResult::Failed(
                    snapshot.clone(),
                    CompletionObservationFailure::HandleMismatch(running.identity.clone()),
                );
            }
            if snapshot.policy == RequestPolicy::LatestWins
                && snapshot.current_identity.as_ref() != Some(&running.identity)
            {
                CompletionObservationResult::Superseded(
                    RequestProgressionSnapshot {
                        entries: replace_entry(
                            &snapshot.entries,
                            &running.identity,
                            RequestEntry {
                                phase: RequestPhase::Superseded,
                                ..entry
                            },
                        ),
                        ..snapshot.clone()
                    },
                    running.identity.clone(),
                )
            } else {
                CompletionObservationResult::Applied(
                    revised(
                        snapshot,
                        replace_entry(
                            &snapshot.entries,
                            &running.identity,
                            RequestEntry {
                                phase: RequestPhase::Published,
                                ..entry
                            },
                        ),
                    ),
                    running.identity.clone(),
                    value.clone(),
                )
            }
        }
        AdapterResult::AppliedSignal(AdapterSignal::CancelledAtAdapter(identity, handle)) => {
            if identity != &running.identity {
                return CompletionObservationResult::Failed(
                    snapshot.clone(),
                    CompletionObservationFailure::CompletionIdentityMismatch(
                        running.identity.clone(),
                        identity.clone(),
                    ),
                );
            }
            if handle != &running.handle {
                return CompletionObservationResult::Failed(
                    snapshot.clone(),
                    CompletionObservationFailure::HandleMismatch(running.identity.clone()),
                );
            }
            CompletionObservationResult::Cancelled(
                revised(
                    snapshot,
                    replace_entry(
                        &snapshot.entries,
                        &running.identity,
                        RequestEntry {
                            phase: RequestPhase::Cancelled,
                            ..entry
                        },
                    ),
                ),
                running.identity.clone(),
            )
        }
        AdapterResult::AdapterFailed(AdapterFailure::CompletionAdapterFailure(
            identity,
            handle,
            detail,
        ))
        | AdapterResult::AdapterFailed(AdapterFailure::CancellationAdapterFailure(
            identity,
            handle,
            detail,
        )) => {
            if identity != &running.identity {
                return CompletionObservationResult::Failed(
                    snapshot.clone(),
                    CompletionObservationFailure::CompletionIdentityMismatch(
                        running.identity.clone(),
                        identity.clone(),
                    ),
                );
            }
            if handle != &running.handle {
                return CompletionObservationResult::Failed(
                    snapshot.clone(),
                    CompletionObservationFailure::HandleMismatch(running.identity.clone()),
                );
            }
            let failure = match observed {
                AdapterResult::AdapterFailed(AdapterFailure::CompletionAdapterFailure(_, _, _)) => {
                    CompletionObservationFailure::CompletionAdapterFailureObserved(
                        running.identity.clone(),
                        detail.clone(),
                    )
                }
                _ => CompletionObservationFailure::CancellationAdapterFailureObserved(
                    running.identity.clone(),
                    detail.clone(),
                ),
            };
            CompletionObservationResult::Failed(
                revised(
                    snapshot,
                    replace_entry(
                        &snapshot.entries,
                        &running.identity,
                        RequestEntry {
                            phase: RequestPhase::Failed,
                            ..entry
                        },
                    ),
                ),
                failure,
            )
        }
        _ => CompletionObservationResult::Failed(
            snapshot.clone(),
            CompletionObservationFailure::CompletionSignalMismatch(running.identity.clone()),
        ),
    }
}

pub fn decide_cancel(
    snapshot: &RequestProgressionSnapshot,
    identity: &RequestIdentity,
) -> CancelDecisionResult {
    let entry = match find_entry(&snapshot.entries, identity) {
        Some(entry) => entry.clone(),
        None => {
            return CancelDecisionResult::Rejected(
                snapshot.clone(),
                CancelFailure::UnknownRequest(identity.clone()),
            )
        }
    };
    match entry.phase {
        RequestPhase::Pending => CancelDecisionResult::Cancelled(
            revised(
                snapshot,
                replace_entry(
                    &snapshot.entries,
                    identity,
                    RequestEntry {
                        phase: RequestPhase::Cancelled,
                        ..entry
                    },
                ),
            ),
            identity.clone(),
        ),
        RequestPhase::Publishing => match entry.execution_handle {
            Some(handle) => {
                let running = Running {
                    identity: identity.clone(),
                    handle: handle.clone(),
                };
                CancelDecisionResult::CancelCommand(
                    snapshot.clone(),
                    running,
                    AdapterCommand::CancelCommand(identity.clone(), handle),
                )
            }
            None => CancelDecisionResult::Rejected(
                snapshot.clone(),
                CancelFailure::MissingExecutionHandle(identity.clone()),
            ),
        },
        RequestPhase::Preparing => CancelDecisionResult::Rejected(
            snapshot.clone(),
            CancelFailure::MissingExecutionHandle(identity.clone()),
        ),
        _ => CancelDecisionResult::Rejected(
            snapshot.clone(),
            CancelFailure::RequestAlreadyTerminal(identity.clone()),
        ),
    }
}
