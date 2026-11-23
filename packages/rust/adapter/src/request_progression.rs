// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

//! Request progression: pure policy decisions separated from adapter observations.

use std::collections::{BTreeSet, HashMap};

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
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
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
            pending: Nat::default(),
            in_flight: Nat::default(),
            concurrent: Nat::default(),
        }
    }
    fn accumulate(&mut self, other: &Self) {
        self.pending += &other.pending;
        self.in_flight += &other.in_flight;
        self.concurrent += &other.concurrent;
    }
    fn release(&mut self, other: &Self) {
        self.pending -= &other.pending;
        self.in_flight -= &other.in_flight;
        self.concurrent -= &other.concurrent;
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
    pub value: std::sync::Arc<str>,
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

#[derive(Clone, Debug)]
struct PhaseTotals {
    pending: ResourceDemand,
    in_flight: ResourceDemand,
    concurrent: ResourceDemand,
    pending_positions: BTreeSet<usize>,
    ordered_pending_positions: BTreeSet<usize>,
}
impl PhaseTotals {
    fn zero() -> Self {
        Self {
            pending: ResourceDemand::zero(),
            in_flight: ResourceDemand::zero(),
            concurrent: ResourceDemand::zero(),
            pending_positions: BTreeSet::new(),
            ordered_pending_positions: BTreeSet::new(),
        }
    }
    fn admit(&mut self, position: usize, entry: &RequestEntry) {
        match entry.phase {
            RequestPhase::Pending => {
                self.pending.accumulate(&entry.demand);
                self.pending_positions.insert(position);
                if entry.footprint.effect_class == RequestEffectClass::OrderedEffect {
                    self.ordered_pending_positions.insert(position);
                }
            }
            RequestPhase::Preparing => self.in_flight.accumulate(&entry.demand),
            RequestPhase::Publishing => {
                self.in_flight.accumulate(&entry.demand);
                self.concurrent.accumulate(&entry.demand);
            }
            _ => {}
        }
    }
    fn withdraw(&mut self, position: usize, entry: &RequestEntry) {
        match entry.phase {
            RequestPhase::Pending => {
                self.pending.release(&entry.demand);
                self.pending_positions.remove(&position);
                self.ordered_pending_positions.remove(&position);
            }
            RequestPhase::Preparing => self.in_flight.release(&entry.demand),
            RequestPhase::Publishing => {
                self.in_flight.release(&entry.demand);
                self.concurrent.release(&entry.demand);
            }
            _ => {}
        }
    }
}

/// Request progression state. Entries keep their submission order and have
/// pairwise distinct identities; [`snapshot_of`] checks this on construction.
#[derive(Clone, Debug)]
pub struct RequestProgressionSnapshot {
    policy: RequestPolicy,
    budget: ResourceBudget,
    current_identity: Option<RequestIdentity>,
    entries: Vec<RequestEntry>,
    revision: Nat,
    positions: HashMap<RequestIdentity, usize>,
    totals: PhaseTotals,
}
impl PartialEq for RequestProgressionSnapshot {
    fn eq(&self, other: &Self) -> bool {
        self.policy == other.policy
            && self.budget == other.budget
            && self.current_identity == other.current_identity
            && self.entries == other.entries
            && self.revision == other.revision
    }
}
impl Eq for RequestProgressionSnapshot {}
impl RequestProgressionSnapshot {
    fn position_of(&self, identity: &RequestIdentity) -> Option<usize> {
        self.positions.get(identity).copied()
    }
    fn entry_at(&self, position: usize) -> Option<&RequestEntry> {
        self.entries.get(position)
    }
    fn update_entry(&mut self, position: usize, change: impl FnOnce(&mut RequestEntry)) {
        if let Some(entry) = self.entries.get_mut(position) {
            self.totals.withdraw(position, entry);
            change(entry);
            self.totals.admit(position, entry);
        }
    }
    fn push_entry(&mut self, entry: RequestEntry) {
        let position = self.entries.len();
        self.totals.admit(position, &entry);
        self.positions.insert(entry.identity.clone(), position);
        self.entries.push(entry);
    }
    fn advance_revision(&mut self) {
        self.revision += 1u8;
    }
    fn first_pending_identity(&self) -> Option<&RequestIdentity> {
        self.totals
            .pending_positions
            .first()
            .and_then(|position| self.entry_at(*position))
            .map(|entry| &entry.identity)
    }
    fn first_ordered_pending_identity(&self) -> Option<&RequestIdentity> {
        self.totals
            .ordered_pending_positions
            .first()
            .and_then(|position| self.entry_at(*position))
            .map(|entry| &entry.identity)
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SnapshotFailure {
    DuplicateIdentity(RequestIdentity),
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
        revision: Nat::default(),
        positions: HashMap::new(),
        totals: PhaseTotals::zero(),
    }
}
/// Build a snapshot from its parts; entries must have distinct identities.
pub fn snapshot_of(
    policy: RequestPolicy,
    budget: ResourceBudget,
    current_identity: Option<RequestIdentity>,
    entries: Vec<RequestEntry>,
    revision: Nat,
) -> Result<RequestProgressionSnapshot, SnapshotFailure> {
    let mut snapshot = RequestProgressionSnapshot {
        revision,
        current_identity,
        ..empty(policy, budget)
    };
    for entry in entries {
        if snapshot.positions.contains_key(&entry.identity) {
            return Err(SnapshotFailure::DuplicateIdentity(entry.identity));
        }
        snapshot.push_entry(entry);
    }
    Ok(snapshot)
}
pub fn progression_policy(snapshot: &RequestProgressionSnapshot) -> RequestPolicy {
    snapshot.policy
}
pub fn progression_budget(snapshot: &RequestProgressionSnapshot) -> &ResourceBudget {
    &snapshot.budget
}
pub fn progression_current_identity(
    snapshot: &RequestProgressionSnapshot,
) -> Option<&RequestIdentity> {
    snapshot.current_identity.as_ref()
}
/// Borrow the entries in submission order.
pub fn progression_entries(snapshot: &RequestProgressionSnapshot) -> &[RequestEntry] {
    &snapshot.entries
}
pub fn progression_revision(snapshot: &RequestProgressionSnapshot) -> &Nat {
    &snapshot.revision
}
pub fn find_request<'a>(
    snapshot: &'a RequestProgressionSnapshot,
    identity: &RequestIdentity,
) -> Option<&'a RequestEntry> {
    snapshot
        .position_of(identity)
        .and_then(|position| snapshot.entry_at(position))
}
pub(crate) fn update_request(
    snapshot: &mut RequestProgressionSnapshot,
    identity: &RequestIdentity,
    change: impl FnOnce(&mut RequestEntry),
) {
    if let Some(position) = snapshot.position_of(identity) {
        snapshot.update_entry(position, change);
    }
}
pub(crate) fn with_budget(
    mut snapshot: RequestProgressionSnapshot,
    budget: ResourceBudget,
) -> RequestProgressionSnapshot {
    snapshot.budget = budget;
    snapshot
}
pub fn derive_pending(snapshot: &RequestProgressionSnapshot) -> ResourceDemand {
    snapshot.totals.pending.clone()
}
pub fn derive_in_flight(snapshot: &RequestProgressionSnapshot) -> ResourceDemand {
    snapshot.totals.in_flight.clone()
}
pub fn derive_concurrent(snapshot: &RequestProgressionSnapshot) -> ResourceDemand {
    snapshot.totals.concurrent.clone()
}
pub(crate) fn submit_check(
    snapshot: &RequestProgressionSnapshot,
    request: &RequestInput,
    budget: &ResourceBudget,
) -> Option<SubmitFailure> {
    if snapshot.positions.contains_key(&request.identity) {
        return Some(SubmitFailure::DuplicateIdentity(request.identity.clone()));
    }
    if &snapshot.totals.pending.pending + &request.demand.pending > budget.pending_maximum.maximum {
        return Some(SubmitFailure::PendingLimitExceeded(
            request.demand.clone(),
            budget.clone(),
        ));
    }
    None
}

pub fn submit(mut snapshot: RequestProgressionSnapshot, request: &RequestInput) -> SubmitResult {
    if let Some(failure) = submit_check(&snapshot, request, &snapshot.budget) {
        return SubmitResult::SubmitRejected(snapshot, failure);
    }
    if snapshot.policy == RequestPolicy::LatestWins {
        let superseded: Vec<usize> = snapshot.totals.pending_positions.iter().copied().collect();
        for position in superseded {
            snapshot.update_entry(position, |entry| entry.phase = RequestPhase::Superseded);
        }
    }
    snapshot.push_entry(RequestEntry {
        identity: request.identity.clone(),
        footprint: request.footprint.clone(),
        demand: request.demand.clone(),
        phase: RequestPhase::Pending,
        meaning_permission: request.permission.clone(),
        cost_selection: None,
        execution_handle: None,
    });
    snapshot.current_identity = Some(request.identity.clone());
    snapshot.advance_revision();
    SubmitResult::Accepted(
        snapshot,
        Accepted {
            identity: request.identity.clone(),
        },
    )
}

struct StartView<'a> {
    policy: RequestPolicy,
    current_identity: Option<&'a RequestIdentity>,
    first_pending: Option<&'a RequestIdentity>,
    first_ordered_pending: Option<&'a RequestIdentity>,
    in_flight: &'a Nat,
    concurrent: &'a Nat,
    budget: &'a ResourceBudget,
}

struct StartCandidate<'a> {
    identity: &'a RequestIdentity,
    phase: RequestPhase,
    footprint: &'a RequestFootprint,
    demand: &'a ResourceDemand,
    permission: &'a MeaningPermission,
}

fn start_permission_failure(candidate: &StartCandidate) -> Option<StartDecisionFailure> {
    let identity = candidate.identity;
    match candidate.permission {
        MeaningPermission::Denied(_, reason) => Some(StartDecisionFailure::PermissionDenied(
            identity.clone(),
            reason.clone(),
        )),
        MeaningPermission::Permitted(permitted, _) | MeaningPermission::Ordered(permitted, _)
            if permitted != identity =>
        {
            Some(StartDecisionFailure::PermissionIdentityMismatch(
                identity.clone(),
                permitted.clone(),
            ))
        }
        MeaningPermission::Permitted(_, _)
            if candidate.footprint.effect_class == RequestEffectClass::OrderedEffect =>
        {
            Some(StartDecisionFailure::PermissionNotOrdered(identity.clone()))
        }
        _ => None,
    }
}

fn start_check(
    view: &StartView,
    candidate: &StartCandidate,
    selection: &CostSelection,
) -> Result<(), StartDecisionFailure> {
    let identity = candidate.identity;
    if candidate.phase != RequestPhase::Pending {
        return Err(StartDecisionFailure::RequestNotPending(identity.clone()));
    }
    let policy_order_allowed = match view.policy {
        RequestPolicy::LatestWins => view.current_identity == Some(identity),
        RequestPolicy::AllExecute => true,
        RequestPolicy::Fifo => view.first_pending == Some(identity),
    };
    let ordered_effect_allowed = candidate.footprint.effect_class
        != RequestEffectClass::OrderedEffect
        || view
            .first_ordered_pending
            .is_none_or(|first| first == identity);
    if !policy_order_allowed || !ordered_effect_allowed {
        return Err(StartDecisionFailure::PolicyOrderBlocked(identity.clone()));
    }
    if let Some(failure) = start_permission_failure(candidate) {
        return Err(failure);
    }
    let selected_identity = match selection {
        CostSelection::ExecuteNow(selected, _, _)
        | CostSelection::RemainPending(selected, _, _) => selected,
    };
    if selected_identity != identity {
        return Err(StartDecisionFailure::CostSelectionIdentityMismatch(
            identity.clone(),
            selected_identity.clone(),
        ));
    }
    if let CostSelection::ExecuteNow(_, _, _) = selection {
        if view.in_flight + &candidate.demand.in_flight > view.budget.in_flight_maximum.maximum {
            return Err(StartDecisionFailure::InFlightLimitExceeded(
                candidate.demand.clone(),
                view.budget.clone(),
            ));
        }
        if view.concurrent + &candidate.demand.concurrent > view.budget.concurrent_maximum.maximum {
            return Err(StartDecisionFailure::ConcurrentLimitExceeded(
                candidate.demand.clone(),
                view.budget.clone(),
            ));
        }
    }
    Ok(())
}

fn admitted_start(
    snapshot: &RequestProgressionSnapshot,
    identity: &RequestIdentity,
    selection: &CostSelection,
) -> Result<(usize, RequestFootprint), StartDecisionFailure> {
    let unknown = || StartDecisionFailure::UnknownRequest(identity.clone());
    let position = snapshot.position_of(identity).ok_or_else(unknown)?;
    let entry = snapshot.entry_at(position).ok_or_else(unknown)?;
    let view = StartView {
        policy: snapshot.policy,
        current_identity: snapshot.current_identity.as_ref(),
        first_pending: snapshot.first_pending_identity(),
        first_ordered_pending: snapshot.first_ordered_pending_identity(),
        in_flight: &snapshot.totals.in_flight.in_flight,
        concurrent: &snapshot.totals.concurrent.concurrent,
        budget: &snapshot.budget,
    };
    let candidate = StartCandidate {
        identity,
        phase: entry.phase,
        footprint: &entry.footprint,
        demand: &entry.demand,
        permission: &entry.meaning_permission,
    };
    start_check(&view, &candidate, selection)?;
    Ok((position, entry.footprint.clone()))
}

/// The start decision that [`decide_start`] returns for `request` right
/// after [`submit`] accepted it under `budget`.
pub(crate) fn start_after_submit(
    snapshot: &RequestProgressionSnapshot,
    request: &RequestInput,
    budget: &ResourceBudget,
    selection: &CostSelection,
) -> Result<(), StartDecisionFailure> {
    let supersedes = snapshot.policy == RequestPolicy::LatestWins;
    let ordered = request.footprint.effect_class == RequestEffectClass::OrderedEffect;
    let held_first_pending = if supersedes {
        None
    } else {
        snapshot.first_pending_identity()
    };
    let held_first_ordered = if supersedes {
        None
    } else {
        snapshot.first_ordered_pending_identity()
    };
    let view = StartView {
        policy: snapshot.policy,
        current_identity: Some(&request.identity),
        first_pending: held_first_pending.or(Some(&request.identity)),
        first_ordered_pending: held_first_ordered.or(ordered.then_some(&request.identity)),
        in_flight: &snapshot.totals.in_flight.in_flight,
        concurrent: &snapshot.totals.concurrent.concurrent,
        budget,
    };
    let candidate = StartCandidate {
        identity: &request.identity,
        phase: RequestPhase::Pending,
        footprint: &request.footprint,
        demand: &request.demand,
        permission: &request.permission,
    };
    start_check(&view, &candidate, selection)
}

pub fn decide_start(
    mut snapshot: RequestProgressionSnapshot,
    accepted: &Accepted,
    selection: &CostSelection,
) -> StartDecisionResult {
    let (position, footprint) = match admitted_start(&snapshot, &accepted.identity, selection) {
        Ok(admitted) => admitted,
        Err(failure) => return StartDecisionResult::Rejected(snapshot, failure),
    };
    match selection {
        CostSelection::RemainPending(_, _, _) => {
            snapshot.update_entry(position, |entry| {
                entry.cost_selection = Some(selection.clone())
            });
            StartDecisionResult::Deferred(snapshot, accepted.clone())
        }
        CostSelection::ExecuteNow(_, _, _) => {
            snapshot.update_entry(position, |entry| {
                entry.phase = RequestPhase::Preparing;
                entry.cost_selection = Some(selection.clone());
            });
            snapshot.advance_revision();
            let command = AdapterCommand::StartCommand(accepted.identity.clone(), footprint);
            StartDecisionResult::Execute(
                snapshot,
                Starting {
                    identity: accepted.identity.clone(),
                    command: command.clone(),
                },
                command,
            )
        }
    }
}

fn fail_entry(snapshot: &mut RequestProgressionSnapshot, position: usize) {
    snapshot.update_entry(position, |entry| entry.phase = RequestPhase::Failed);
    snapshot.advance_revision();
}

pub fn apply_start_observation<Result>(
    mut snapshot: RequestProgressionSnapshot,
    starting: &Starting,
    observed: &AdapterResult<AdapterSignal<Result>, AdapterFailure>,
) -> StartObservationResult {
    let Some(position) = snapshot.position_of(&starting.identity) else {
        return StartObservationResult::Failed(
            snapshot,
            StartObservationFailure::UnknownRequest(starting.identity.clone()),
        );
    };
    if snapshot.entry_at(position).map(|entry| entry.phase) != Some(RequestPhase::Preparing) {
        return StartObservationResult::Failed(
            snapshot,
            StartObservationFailure::RequestNotStarting(starting.identity.clone()),
        );
    }
    let failure = match observed {
        AdapterResult::AppliedSignal(AdapterSignal::Started(identity, handle))
            if identity == &starting.identity =>
        {
            snapshot.update_entry(position, |entry| {
                entry.phase = RequestPhase::Publishing;
                entry.execution_handle = Some(handle.clone());
            });
            snapshot.advance_revision();
            return StartObservationResult::Publishing(
                snapshot,
                Running {
                    identity: starting.identity.clone(),
                    handle: handle.clone(),
                },
            );
        }
        AdapterResult::AppliedSignal(AdapterSignal::Started(identity, _)) => {
            StartObservationFailure::StartIdentityMismatch(
                starting.identity.clone(),
                identity.clone(),
            )
        }
        AdapterResult::AdapterFailed(AdapterFailure::StartAdapterFailure(identity, detail)) => {
            if identity == &starting.identity {
                StartObservationFailure::StartAdapterFailureObserved(
                    starting.identity.clone(),
                    detail.clone(),
                )
            } else {
                StartObservationFailure::StartIdentityMismatch(
                    starting.identity.clone(),
                    identity.clone(),
                )
            }
        }
        _ => StartObservationFailure::StartSignalMismatch(starting.identity.clone()),
    };
    fail_entry(&mut snapshot, position);
    StartObservationResult::Failed(snapshot, failure)
}

fn completion_mismatch(
    running: &Running,
    identity: &RequestIdentity,
    handle: &ExecutionHandle,
) -> Option<CompletionObservationFailure> {
    if identity != &running.identity {
        Some(CompletionObservationFailure::CompletionIdentityMismatch(
            running.identity.clone(),
            identity.clone(),
        ))
    } else if handle != &running.handle {
        Some(CompletionObservationFailure::HandleMismatch(
            running.identity.clone(),
        ))
    } else {
        None
    }
}

pub fn apply_completion_observation<Result: Clone>(
    mut snapshot: RequestProgressionSnapshot,
    running: &Running,
    observed: &AdapterResult<AdapterSignal<Result>, AdapterFailure>,
) -> CompletionObservationResult<Result> {
    let Some(position) = snapshot.position_of(&running.identity) else {
        return CompletionObservationResult::Failed(
            snapshot,
            CompletionObservationFailure::UnknownCompletion(running.identity.clone()),
        );
    };
    let held = snapshot.entry_at(position).map(|entry| {
        (
            entry.phase,
            entry.execution_handle.as_ref() == Some(&running.handle),
        )
    });
    if held.map(|(phase, _)| phase) != Some(RequestPhase::Publishing) {
        return CompletionObservationResult::Failed(
            snapshot,
            CompletionObservationFailure::CompletionNotRunning(running.identity.clone()),
        );
    }
    if held.map(|(_, same_handle)| same_handle) != Some(true) {
        return CompletionObservationResult::Failed(
            snapshot,
            CompletionObservationFailure::HandleMismatch(running.identity.clone()),
        );
    }
    match observed {
        AdapterResult::AppliedSignal(AdapterSignal::Completed(identity, handle, value)) => {
            if let Some(failure) = completion_mismatch(running, identity, handle) {
                return CompletionObservationResult::Failed(snapshot, failure);
            }
            if snapshot.policy == RequestPolicy::LatestWins
                && snapshot.current_identity.as_ref() != Some(&running.identity)
            {
                snapshot.update_entry(position, |entry| entry.phase = RequestPhase::Superseded);
                CompletionObservationResult::Superseded(snapshot, running.identity.clone())
            } else {
                snapshot.update_entry(position, |entry| entry.phase = RequestPhase::Published);
                snapshot.advance_revision();
                CompletionObservationResult::Applied(
                    snapshot,
                    running.identity.clone(),
                    value.clone(),
                )
            }
        }
        AdapterResult::AppliedSignal(AdapterSignal::CancelledAtAdapter(identity, handle)) => {
            if let Some(failure) = completion_mismatch(running, identity, handle) {
                return CompletionObservationResult::Failed(snapshot, failure);
            }
            snapshot.update_entry(position, |entry| entry.phase = RequestPhase::Cancelled);
            snapshot.advance_revision();
            CompletionObservationResult::Cancelled(snapshot, running.identity.clone())
        }
        AdapterResult::AdapterFailed(AdapterFailure::CompletionAdapterFailure(
            identity,
            handle,
            detail,
        )) => {
            if let Some(failure) = completion_mismatch(running, identity, handle) {
                return CompletionObservationResult::Failed(snapshot, failure);
            }
            fail_entry(&mut snapshot, position);
            CompletionObservationResult::Failed(
                snapshot,
                CompletionObservationFailure::CompletionAdapterFailureObserved(
                    running.identity.clone(),
                    detail.clone(),
                ),
            )
        }
        AdapterResult::AdapterFailed(AdapterFailure::CancellationAdapterFailure(
            identity,
            handle,
            detail,
        )) => {
            if let Some(failure) = completion_mismatch(running, identity, handle) {
                return CompletionObservationResult::Failed(snapshot, failure);
            }
            fail_entry(&mut snapshot, position);
            CompletionObservationResult::Failed(
                snapshot,
                CompletionObservationFailure::CancellationAdapterFailureObserved(
                    running.identity.clone(),
                    detail.clone(),
                ),
            )
        }
        _ => CompletionObservationResult::Failed(
            snapshot,
            CompletionObservationFailure::CompletionSignalMismatch(running.identity.clone()),
        ),
    }
}

pub fn decide_cancel(
    mut snapshot: RequestProgressionSnapshot,
    identity: &RequestIdentity,
) -> CancelDecisionResult {
    let Some(position) = snapshot.position_of(identity) else {
        return CancelDecisionResult::Rejected(
            snapshot,
            CancelFailure::UnknownRequest(identity.clone()),
        );
    };
    let held = snapshot
        .entry_at(position)
        .map(|entry| (entry.phase, entry.execution_handle.clone()));
    match held {
        Some((RequestPhase::Pending, _)) => {
            snapshot.update_entry(position, |entry| entry.phase = RequestPhase::Cancelled);
            snapshot.advance_revision();
            CancelDecisionResult::Cancelled(snapshot, identity.clone())
        }
        Some((RequestPhase::Publishing, Some(handle))) => {
            let running = Running {
                identity: identity.clone(),
                handle: handle.clone(),
            };
            CancelDecisionResult::CancelCommand(
                snapshot,
                running,
                AdapterCommand::CancelCommand(identity.clone(), handle),
            )
        }
        Some((RequestPhase::Publishing, None)) | Some((RequestPhase::Preparing, _)) => {
            CancelDecisionResult::Rejected(
                snapshot,
                CancelFailure::MissingExecutionHandle(identity.clone()),
            )
        }
        _ => CancelDecisionResult::Rejected(
            snapshot,
            CancelFailure::RequestAlreadyTerminal(identity.clone()),
        ),
    }
}
