# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Request progression with separate decision and observation phases."""

from __future__ import annotations

from dataclasses import dataclass, replace as dc_replace
from enum import Enum
from typing import Generic, TypeVar


class RequestPolicy(Enum):
    LATEST_WINS = "latestWins"
    FIFO = "fifo"
    ALL_EXECUTE = "allExecute"


class RequestPhase(Enum):
    PENDING = "pending"
    PREPARING = "preparing"
    PUBLISHING = "publishing"
    PUBLISHED = "published"
    SUPERSEDED = "superseded"
    CANCELLED = "cancelled"
    FAILED = "failed"


class RequestEffectClass(Enum):
    PURE = "pure"
    ORDERED_EFFECT = "orderedEffect"


@dataclass(frozen=True, slots=True)
class RequestIdentity:
    kind: str
    provenance: str
    revision: int


@dataclass(frozen=True, slots=True)
class RequestFootprint:
    reads: tuple[str, ...]
    writes: tuple[str, ...]
    effect_class: RequestEffectClass


@dataclass(frozen=True, slots=True)
class ResourceDemand:
    pending: int
    in_flight: int
    concurrent: int


@dataclass(frozen=True, slots=True)
class ConfiguredSafetyLimit:
    resource: str
    maximum: int


@dataclass(frozen=True, slots=True)
class ResourceBudget:
    pending_maximum: ConfiguredSafetyLimit
    in_flight_maximum: ConfiguredSafetyLimit
    concurrent_maximum: ConfiguredSafetyLimit


@dataclass(frozen=True, slots=True)
class EvidenceVersion:
    identifier: str
    digest: str
    artifact_path: str


@dataclass(frozen=True, slots=True)
class PermissionDenial:
    reason: str


@dataclass(frozen=True, slots=True)
class Permitted:
    identity: RequestIdentity
    evidence: tuple[EvidenceVersion, ...]


@dataclass(frozen=True, slots=True)
class Ordered:
    identity: RequestIdentity
    evidence: tuple[EvidenceVersion, ...]


@dataclass(frozen=True, slots=True)
class Denied:
    identity: RequestIdentity
    reason: PermissionDenial


type MeaningPermission = Permitted | Ordered | Denied


@dataclass(frozen=True, slots=True)
class ExecutionHandle:
    value: str


@dataclass(frozen=True, slots=True)
class ExecuteNow:
    identity: RequestIdentity
    evidence: EvidenceVersion
    cost: int


@dataclass(frozen=True, slots=True)
class RemainPending:
    identity: RequestIdentity
    evidence: EvidenceVersion
    cost: int


type CostSelection = ExecuteNow | RemainPending


@dataclass(frozen=True, slots=True)
class RequestEntry:
    identity: RequestIdentity
    footprint: RequestFootprint
    demand: ResourceDemand
    phase: RequestPhase
    meaning_permission: MeaningPermission
    cost_selection: CostSelection | None
    execution_handle: ExecutionHandle | None


@dataclass(frozen=True, slots=True)
class RequestProgressionSnapshot:
    policy: RequestPolicy
    budget: ResourceBudget
    current_identity: RequestIdentity | None
    entries: tuple[RequestEntry, ...]
    revision: int


@dataclass(frozen=True, slots=True)
class RequestInput:
    identity: RequestIdentity
    footprint: RequestFootprint
    demand: ResourceDemand
    permission: MeaningPermission


@dataclass(frozen=True, slots=True)
class Accepted:
    identity: RequestIdentity


@dataclass(frozen=True, slots=True)
class StartCommand:
    identity: RequestIdentity
    footprint: RequestFootprint


@dataclass(frozen=True, slots=True)
class CancelCommand:
    identity: RequestIdentity
    handle: ExecutionHandle


type AdapterCommand = StartCommand | CancelCommand


@dataclass(frozen=True, slots=True)
class Starting:
    identity: RequestIdentity
    command: AdapterCommand


@dataclass(frozen=True, slots=True)
class Running:
    identity: RequestIdentity
    handle: ExecutionHandle


Result = TypeVar("Result")


@dataclass(frozen=True, slots=True)
class Started(Generic[Result]):
    identity: RequestIdentity
    handle: ExecutionHandle


@dataclass(frozen=True, slots=True)
class Completed(Generic[Result]):
    identity: RequestIdentity
    handle: ExecutionHandle
    value: Result


@dataclass(frozen=True, slots=True)
class CancelledAtAdapter(Generic[Result]):
    identity: RequestIdentity
    handle: ExecutionHandle

type AdapterSignal[Result] = Started[Result] | Completed[Result] | CancelledAtAdapter[Result]


@dataclass(frozen=True, slots=True)
class StartAdapterFailure:
    identity: RequestIdentity
    detail: str


@dataclass(frozen=True, slots=True)
class CompletionAdapterFailure:
    identity: RequestIdentity
    handle: ExecutionHandle
    detail: str


@dataclass(frozen=True, slots=True)
class CancellationAdapterFailure:
    identity: RequestIdentity
    handle: ExecutionHandle
    detail: str

type AdapterFailure = StartAdapterFailure | CompletionAdapterFailure | CancellationAdapterFailure


@dataclass(frozen=True, slots=True)
class AppliedSignal(Generic[Result]):
    signal: AdapterSignal[Result]


@dataclass(frozen=True, slots=True)
class AdapterFailed:
    failure: AdapterFailure

type AdapterResult[Result] = AppliedSignal[Result] | AdapterFailed


@dataclass(frozen=True, slots=True)
class DuplicateIdentity:
    identity: RequestIdentity


@dataclass(frozen=True, slots=True)
class PendingLimitExceeded:
    demand: ResourceDemand
    budget: ResourceBudget

type SubmitFailure = DuplicateIdentity | PendingLimitExceeded


@dataclass(frozen=True, slots=True)
class SubmitAccepted:
    snapshot: RequestProgressionSnapshot
    accepted: Accepted


@dataclass(frozen=True, slots=True)
class SubmitRejected:
    snapshot: RequestProgressionSnapshot
    failure: SubmitFailure

type SubmitResult = SubmitAccepted | SubmitRejected


@dataclass(frozen=True, slots=True)
class UnknownRequest:
    identity: RequestIdentity


@dataclass(frozen=True, slots=True)
class RequestNotPending:
    identity: RequestIdentity


@dataclass(frozen=True, slots=True)
class PolicyOrderBlocked:
    identity: RequestIdentity


@dataclass(frozen=True, slots=True)
class PermissionDenied:
    identity: RequestIdentity
    reason: PermissionDenial


@dataclass(frozen=True, slots=True)
class PermissionIdentityMismatch:
    identity: RequestIdentity
    other: RequestIdentity


@dataclass(frozen=True, slots=True)
class PermissionNotOrdered:
    identity: RequestIdentity


@dataclass(frozen=True, slots=True)
class CostSelectionIdentityMismatch:
    identity: RequestIdentity
    other: RequestIdentity


@dataclass(frozen=True, slots=True)
class InFlightLimitExceeded:
    demand: ResourceDemand
    budget: ResourceBudget


@dataclass(frozen=True, slots=True)
class ConcurrentLimitExceeded:
    demand: ResourceDemand
    budget: ResourceBudget

type StartDecisionFailure = (
    UnknownRequest | RequestNotPending | PolicyOrderBlocked | PermissionDenied
    | PermissionIdentityMismatch | PermissionNotOrdered | CostSelectionIdentityMismatch
    | InFlightLimitExceeded | ConcurrentLimitExceeded
)


@dataclass(frozen=True, slots=True)
class Execute:
    snapshot: RequestProgressionSnapshot
    starting: Starting
    command: AdapterCommand


@dataclass(frozen=True, slots=True)
class Deferred:
    snapshot: RequestProgressionSnapshot
    accepted: Accepted


@dataclass(frozen=True, slots=True)
class StartDecisionRejected:
    snapshot: RequestProgressionSnapshot
    failure: StartDecisionFailure

type StartDecisionResult = Execute | Deferred | StartDecisionRejected


@dataclass(frozen=True, slots=True)
class RequestNotStarting:
    identity: RequestIdentity


@dataclass(frozen=True, slots=True)
class StartIdentityMismatch:
    identity: RequestIdentity
    other: RequestIdentity


@dataclass(frozen=True, slots=True)
class StartSignalMismatch:
    identity: RequestIdentity


@dataclass(frozen=True, slots=True)
class StartAdapterFailureObserved:
    identity: RequestIdentity
    detail: str

type StartObservationFailure = UnknownRequest | RequestNotStarting | StartIdentityMismatch | StartSignalMismatch | StartAdapterFailureObserved


@dataclass(frozen=True, slots=True)
class Publishing:
    snapshot: RequestProgressionSnapshot
    running: Running


@dataclass(frozen=True, slots=True)
class StartObservationFailed:
    snapshot: RequestProgressionSnapshot
    failure: StartObservationFailure

type StartObservationResult = Publishing | StartObservationFailed


@dataclass(frozen=True, slots=True)
class UnknownCompletion:
    identity: RequestIdentity


@dataclass(frozen=True, slots=True)
class CompletionNotRunning:
    identity: RequestIdentity


@dataclass(frozen=True, slots=True)
class HandleMismatch:
    identity: RequestIdentity


@dataclass(frozen=True, slots=True)
class CompletionIdentityMismatch:
    identity: RequestIdentity
    other: RequestIdentity


@dataclass(frozen=True, slots=True)
class CompletionSignalMismatch:
    identity: RequestIdentity


@dataclass(frozen=True, slots=True)
class CompletionAdapterFailureObserved:
    identity: RequestIdentity
    detail: str


@dataclass(frozen=True, slots=True)
class CancellationAdapterFailureObserved:
    identity: RequestIdentity
    detail: str

type CompletionObservationFailure = (
    UnknownCompletion | CompletionNotRunning | HandleMismatch | CompletionIdentityMismatch
    | CompletionSignalMismatch | CompletionAdapterFailureObserved | CancellationAdapterFailureObserved
)


@dataclass(frozen=True, slots=True)
class AppliedResult(Generic[Result]):
    snapshot: RequestProgressionSnapshot
    identity: RequestIdentity
    value: Result


@dataclass(frozen=True, slots=True)
class SupersededResult:
    snapshot: RequestProgressionSnapshot
    identity: RequestIdentity


@dataclass(frozen=True, slots=True)
class CancelledResult:
    snapshot: RequestProgressionSnapshot
    identity: RequestIdentity


@dataclass(frozen=True, slots=True)
class CompletionObservationFailed:
    snapshot: RequestProgressionSnapshot
    failure: CompletionObservationFailure

type CompletionObservationResult[Result] = AppliedResult[Result] | SupersededResult | CancelledResult | CompletionObservationFailed


@dataclass(frozen=True, slots=True)
class CancelUnknownRequest:
    identity: RequestIdentity


@dataclass(frozen=True, slots=True)
class RequestAlreadyTerminal:
    identity: RequestIdentity


@dataclass(frozen=True, slots=True)
class MissingExecutionHandle:
    identity: RequestIdentity

type CancelFailure = CancelUnknownRequest | RequestAlreadyTerminal | MissingExecutionHandle


@dataclass(frozen=True, slots=True)
class CancelledWithoutAdapter:
    snapshot: RequestProgressionSnapshot
    identity: RequestIdentity


@dataclass(frozen=True, slots=True)
class CancelIssued:
    snapshot: RequestProgressionSnapshot
    running: Running
    command: AdapterCommand


@dataclass(frozen=True, slots=True)
class CancelRejected:
    snapshot: RequestProgressionSnapshot
    failure: CancelFailure

type CancelDecisionResult = CancelledWithoutAdapter | CancelIssued | CancelRejected


def empty(policy: RequestPolicy, budget: ResourceBudget) -> RequestProgressionSnapshot:
    return RequestProgressionSnapshot(policy, budget, None, (), 0)


def _find_entry(entries: tuple[RequestEntry, ...], identity: RequestIdentity) -> RequestEntry | None:
    return next((entry for entry in entries if entry.identity == identity), None)


def _replace_entry(entries: tuple[RequestEntry, ...], identity: RequestIdentity, replacement: RequestEntry) -> tuple[RequestEntry, ...]:
    return tuple(replacement if entry.identity == identity else entry for entry in entries)


def _sum_demand(entries: tuple[RequestEntry, ...]) -> ResourceDemand:
    return ResourceDemand(sum(e.demand.pending for e in entries), sum(e.demand.in_flight for e in entries), sum(e.demand.concurrent for e in entries))


def derive_pending(snapshot: RequestProgressionSnapshot) -> ResourceDemand:
    return _sum_demand(tuple(e for e in snapshot.entries if e.phase is RequestPhase.PENDING))


def derive_in_flight(snapshot: RequestProgressionSnapshot) -> ResourceDemand:
    return _sum_demand(tuple(e for e in snapshot.entries if e.phase in (RequestPhase.PREPARING, RequestPhase.PUBLISHING)))


def derive_concurrent(snapshot: RequestProgressionSnapshot) -> ResourceDemand:
    return _sum_demand(tuple(e for e in snapshot.entries if e.phase is RequestPhase.PUBLISHING))


def _policy_order_allowed(snapshot: RequestProgressionSnapshot, identity: RequestIdentity) -> bool:
    if snapshot.policy is RequestPolicy.LATEST_WINS:
        return snapshot.current_identity == identity
    if snapshot.policy is RequestPolicy.ALL_EXECUTE:
        return True
    earliest = next((e for e in snapshot.entries if e.phase is RequestPhase.PENDING), None)
    return earliest is not None and earliest.identity == identity


def _ordered_effect_allowed(snapshot: RequestProgressionSnapshot, identity: RequestIdentity, entry: RequestEntry) -> bool:
    if entry.footprint.effect_class is not RequestEffectClass.ORDERED_EFFECT:
        return True
    earliest = next((e for e in snapshot.entries if e.phase is RequestPhase.PENDING and e.footprint.effect_class is RequestEffectClass.ORDERED_EFFECT), None)
    return earliest is None or earliest.identity == identity


def submit(snapshot: RequestProgressionSnapshot, request: RequestInput) -> SubmitResult:
    if _find_entry(snapshot.entries, request.identity) is not None:
        return SubmitRejected(snapshot, DuplicateIdentity(request.identity))
    if derive_pending(snapshot).pending + request.demand.pending > snapshot.budget.pending_maximum.maximum:
        return SubmitRejected(snapshot, PendingLimitExceeded(request.demand, snapshot.budget))
    entry = RequestEntry(request.identity, request.footprint, request.demand, RequestPhase.PENDING, request.permission, None, None)
    entries = tuple(dc_replace(e, phase=RequestPhase.SUPERSEDED) if e.phase is RequestPhase.PENDING else e for e in snapshot.entries) + (entry,) if snapshot.policy is RequestPolicy.LATEST_WINS else snapshot.entries + (entry,)
    return SubmitAccepted(dc_replace(snapshot, entries=entries, current_identity=request.identity, revision=snapshot.revision + 1), Accepted(request.identity))


def _decision_selection(snapshot: RequestProgressionSnapshot, accepted: Accepted, entry: RequestEntry, selection: CostSelection) -> StartDecisionResult:
    if selection.identity != accepted.identity:
        return StartDecisionRejected(snapshot, CostSelectionIdentityMismatch(accepted.identity, selection.identity))
    if isinstance(selection, RemainPending):
        return Deferred(dc_replace(snapshot, entries=_replace_entry(snapshot.entries, accepted.identity, dc_replace(entry, cost_selection=selection))), accepted)
    if derive_in_flight(snapshot).in_flight + entry.demand.in_flight > snapshot.budget.in_flight_maximum.maximum:
        return StartDecisionRejected(snapshot, InFlightLimitExceeded(entry.demand, snapshot.budget))
    if derive_concurrent(snapshot).concurrent + entry.demand.concurrent > snapshot.budget.concurrent_maximum.maximum:
        return StartDecisionRejected(snapshot, ConcurrentLimitExceeded(entry.demand, snapshot.budget))
    command = StartCommand(accepted.identity, entry.footprint)
    advanced = dc_replace(snapshot, entries=_replace_entry(snapshot.entries, accepted.identity, dc_replace(entry, phase=RequestPhase.PREPARING, cost_selection=selection)), revision=snapshot.revision + 1)
    return Execute(advanced, Starting(accepted.identity, command), command)


def decide_start(snapshot: RequestProgressionSnapshot, accepted: Accepted, selection: CostSelection) -> StartDecisionResult:
    entry = _find_entry(snapshot.entries, accepted.identity)
    if entry is None:
        return StartDecisionRejected(snapshot, UnknownRequest(accepted.identity))
    if entry.phase is not RequestPhase.PENDING:
        return StartDecisionRejected(snapshot, RequestNotPending(accepted.identity))
    if not _policy_order_allowed(snapshot, accepted.identity) or not _ordered_effect_allowed(snapshot, accepted.identity, entry):
        return StartDecisionRejected(snapshot, PolicyOrderBlocked(accepted.identity))
    permission = entry.meaning_permission
    if isinstance(permission, Denied):
        return StartDecisionRejected(snapshot, PermissionDenied(accepted.identity, permission.reason))
    if permission.identity != accepted.identity:
        return StartDecisionRejected(snapshot, PermissionIdentityMismatch(accepted.identity, permission.identity))
    if isinstance(permission, Permitted) and entry.footprint.effect_class is RequestEffectClass.ORDERED_EFFECT:
        return StartDecisionRejected(snapshot, PermissionNotOrdered(accepted.identity))
    return _decision_selection(snapshot, accepted, entry, selection)


def _failed_start(snapshot: RequestProgressionSnapshot, identity: RequestIdentity, entry: RequestEntry, failure: StartObservationFailure) -> StartObservationFailed:
    advanced = dc_replace(snapshot, entries=_replace_entry(snapshot.entries, identity, dc_replace(entry, phase=RequestPhase.FAILED)), revision=snapshot.revision + 1)
    return StartObservationFailed(advanced, failure)


def apply_start_observation(snapshot: RequestProgressionSnapshot, starting: Starting, observed: AdapterResult[Result]) -> StartObservationResult:
    entry = _find_entry(snapshot.entries, starting.identity)
    if entry is None:
        return StartObservationFailed(snapshot, UnknownRequest(starting.identity))
    if entry.phase is not RequestPhase.PREPARING:
        return StartObservationFailed(snapshot, RequestNotStarting(starting.identity))
    if isinstance(observed, AppliedSignal) and isinstance(observed.signal, Started):
        signal = observed.signal
        if signal.identity == starting.identity:
            advanced = dc_replace(snapshot, entries=_replace_entry(snapshot.entries, starting.identity, dc_replace(entry, phase=RequestPhase.PUBLISHING, execution_handle=signal.handle)), revision=snapshot.revision + 1)
            return Publishing(advanced, Running(starting.identity, signal.handle))
        return _failed_start(snapshot, starting.identity, entry, StartIdentityMismatch(starting.identity, signal.identity))
    if isinstance(observed, AdapterFailed) and isinstance(observed.failure, StartAdapterFailure):
        failure = observed.failure
        if failure.identity == starting.identity:
            return _failed_start(snapshot, starting.identity, entry, StartAdapterFailureObserved(starting.identity, failure.detail))
        return _failed_start(snapshot, starting.identity, entry, StartIdentityMismatch(starting.identity, failure.identity))
    return _failed_start(snapshot, starting.identity, entry, StartSignalMismatch(starting.identity))


def _failed_completion(snapshot: RequestProgressionSnapshot, running: Running, entry: RequestEntry, failure: CompletionObservationFailure) -> CompletionObservationFailed:
    advanced = dc_replace(snapshot, entries=_replace_entry(snapshot.entries, running.identity, dc_replace(entry, phase=RequestPhase.FAILED)), revision=snapshot.revision + 1)
    return CompletionObservationFailed(advanced, failure)


def apply_completion_observation(snapshot: RequestProgressionSnapshot, running: Running, observed: AdapterResult[Result]) -> CompletionObservationResult[Result]:
    entry = _find_entry(snapshot.entries, running.identity)
    if entry is None:
        return CompletionObservationFailed(snapshot, UnknownCompletion(running.identity))
    if entry.phase is not RequestPhase.PUBLISHING:
        return CompletionObservationFailed(snapshot, CompletionNotRunning(running.identity))
    if entry.execution_handle != running.handle:
        return CompletionObservationFailed(snapshot, HandleMismatch(running.identity))
    if isinstance(observed, AppliedSignal) and isinstance(observed.signal, Completed):
        signal = observed.signal
        if signal.identity != running.identity:
            return CompletionObservationFailed(snapshot, CompletionIdentityMismatch(running.identity, signal.identity))
        if signal.handle != running.handle:
            return CompletionObservationFailed(snapshot, HandleMismatch(running.identity))
        if snapshot.policy is RequestPolicy.LATEST_WINS and snapshot.current_identity != running.identity:
            return SupersededResult(dc_replace(snapshot, entries=_replace_entry(snapshot.entries, running.identity, dc_replace(entry, phase=RequestPhase.SUPERSEDED))), running.identity)
        advanced = dc_replace(snapshot, entries=_replace_entry(snapshot.entries, running.identity, dc_replace(entry, phase=RequestPhase.PUBLISHED)), revision=snapshot.revision + 1)
        return AppliedResult(advanced, running.identity, signal.value)
    if isinstance(observed, AppliedSignal) and isinstance(observed.signal, CancelledAtAdapter):
        cancellation = observed.signal
        if cancellation.identity != running.identity:
            return CompletionObservationFailed(snapshot, CompletionIdentityMismatch(running.identity, cancellation.identity))
        if cancellation.handle != running.handle:
            return CompletionObservationFailed(snapshot, HandleMismatch(running.identity))
        advanced = dc_replace(snapshot, entries=_replace_entry(snapshot.entries, running.identity, dc_replace(entry, phase=RequestPhase.CANCELLED)), revision=snapshot.revision + 1)
        return CancelledResult(advanced, running.identity)
    if isinstance(observed, AdapterFailed) and isinstance(observed.failure, CompletionAdapterFailure):
        failure = observed.failure
        if failure.identity != running.identity:
            return CompletionObservationFailed(snapshot, CompletionIdentityMismatch(running.identity, failure.identity))
        if failure.handle != running.handle:
            return CompletionObservationFailed(snapshot, HandleMismatch(running.identity))
        return _failed_completion(snapshot, running, entry, CompletionAdapterFailureObserved(running.identity, failure.detail))
    if isinstance(observed, AdapterFailed) and isinstance(observed.failure, CancellationAdapterFailure):
        cancellation_failure = observed.failure
        if cancellation_failure.identity != running.identity:
            return CompletionObservationFailed(snapshot, CompletionIdentityMismatch(running.identity, cancellation_failure.identity))
        if cancellation_failure.handle != running.handle:
            return CompletionObservationFailed(snapshot, HandleMismatch(running.identity))
        return _failed_completion(snapshot, running, entry, CancellationAdapterFailureObserved(running.identity, cancellation_failure.detail))
    return CompletionObservationFailed(snapshot, CompletionSignalMismatch(running.identity))


def decide_cancel(snapshot: RequestProgressionSnapshot, identity: RequestIdentity) -> CancelDecisionResult:
    entry = _find_entry(snapshot.entries, identity)
    if entry is None:
        return CancelRejected(snapshot, CancelUnknownRequest(identity))
    if entry.phase is RequestPhase.PENDING:
        advanced = dc_replace(snapshot, entries=_replace_entry(snapshot.entries, identity, dc_replace(entry, phase=RequestPhase.CANCELLED)), revision=snapshot.revision + 1)
        return CancelledWithoutAdapter(advanced, identity)
    if entry.phase is RequestPhase.PUBLISHING:
        if entry.execution_handle is None:
            return CancelRejected(snapshot, MissingExecutionHandle(identity))
        handle = entry.execution_handle
        return CancelIssued(snapshot, Running(identity, handle), CancelCommand(identity, handle))
    if entry.phase is RequestPhase.PREPARING:
        return CancelRejected(snapshot, MissingExecutionHandle(identity))
    return CancelRejected(snapshot, RequestAlreadyTerminal(identity))
