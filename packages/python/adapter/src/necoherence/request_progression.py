# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Request progression with separate decision and observation phases."""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass, replace as dc_replace
from enum import Enum
from typing import Generic, TypeVar

from necoherence.persistent import (
    PersistentBitSet,
    PersistentMap,
    PersistentVector,
    bit_set_of,
    empty_bit_set,
    empty_map,
    map_of,
    vector_of,
)


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
class _PhaseTotals:
    pending: ResourceDemand
    in_flight: ResourceDemand
    concurrent: ResourceDemand


class RequestProgressionSnapshot:
    """Entries of a request progression with the totals the rules read.

    The fields are private. ``snapshot_of`` and ``empty`` are the construction
    paths, and the ``progression_*`` functions read the parts back. The sums
    per phase and the first pending entries are kept in step with the entries,
    and operations return a new value that shares every unchanged entry with
    the snapshot they were given.
    """

    __slots__ = (
        "_policy", "_budget", "_current_identity", "_revision",
        "_entries", "_positions", "_pending", "_ordered_pending", "_totals",
    )

    _policy: RequestPolicy
    _budget: ResourceBudget
    _current_identity: RequestIdentity | None
    _revision: int
    _entries: PersistentVector[RequestEntry]
    _positions: PersistentMap[RequestIdentity, int]
    _pending: PersistentBitSet
    _ordered_pending: PersistentBitSet
    _totals: _PhaseTotals

    def __init__(self, *_arguments: object, **_keywords: object) -> None:
        raise TypeError("RequestProgressionSnapshot is constructed with snapshot_of or empty")

    def __setattr__(self, name: str, value: object) -> None:
        raise AttributeError("RequestProgressionSnapshot is immutable")

    def __eq__(self, other: object) -> bool:
        return (
            isinstance(other, RequestProgressionSnapshot)
            and self._policy is other._policy
            and self._budget == other._budget
            and self._current_identity == other._current_identity
            and self._revision == other._revision
            and progression_entries(self) == progression_entries(other)
        )

    def __hash__(self) -> int:
        return hash((self._policy, self._budget, self._current_identity, self._revision, progression_entries(self)))

    def __repr__(self) -> str:
        return (
            f"RequestProgressionSnapshot(policy={self._policy!r}, budget={self._budget!r}, "
            f"current_identity={self._current_identity!r}, entries={progression_entries(self)!r}, "
            f"revision={self._revision!r})"
        )


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
type SnapshotFailure = DuplicateIdentity


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


def _snapshot_from(
    policy: RequestPolicy,
    budget: ResourceBudget,
    current_identity: RequestIdentity | None,
    revision: int,
    entries: PersistentVector[RequestEntry],
    positions: PersistentMap[RequestIdentity, int],
    pending: PersistentBitSet,
    ordered_pending: PersistentBitSet,
    totals: _PhaseTotals,
) -> RequestProgressionSnapshot:
    snapshot = object.__new__(RequestProgressionSnapshot)
    object.__setattr__(snapshot, "_policy", policy)
    object.__setattr__(snapshot, "_budget", budget)
    object.__setattr__(snapshot, "_current_identity", current_identity)
    object.__setattr__(snapshot, "_revision", revision)
    object.__setattr__(snapshot, "_entries", entries)
    object.__setattr__(snapshot, "_positions", positions)
    object.__setattr__(snapshot, "_pending", pending)
    object.__setattr__(snapshot, "_ordered_pending", ordered_pending)
    object.__setattr__(snapshot, "_totals", totals)
    return snapshot


_ZERO_DEMAND = ResourceDemand(0, 0, 0)
_IN_FLIGHT_PHASES = (RequestPhase.PREPARING, RequestPhase.PUBLISHING)


def _plus(left: ResourceDemand, right: ResourceDemand) -> ResourceDemand:
    return ResourceDemand(left.pending + right.pending, left.in_flight + right.in_flight, left.concurrent + right.concurrent)


def _minus(left: ResourceDemand, right: ResourceDemand) -> ResourceDemand:
    return ResourceDemand(left.pending - right.pending, left.in_flight - right.in_flight, left.concurrent - right.concurrent)


def _counted(entry: RequestEntry, pending: bool, in_flight: bool, concurrent: bool) -> _PhaseTotals:
    demand = entry.demand
    return _PhaseTotals(
        demand if pending else _ZERO_DEMAND,
        demand if in_flight else _ZERO_DEMAND,
        demand if concurrent else _ZERO_DEMAND,
    )


def _contribution(entry: RequestEntry) -> _PhaseTotals:
    phase = entry.phase
    return _counted(entry, phase is RequestPhase.PENDING, phase in _IN_FLIGHT_PHASES, phase is RequestPhase.PUBLISHING)


def _totals_replacing(totals: _PhaseTotals, old: RequestEntry, new: RequestEntry) -> _PhaseTotals:
    before = _contribution(old)
    after = _contribution(new)
    return _PhaseTotals(
        _plus(_minus(totals.pending, before.pending), after.pending),
        _plus(_minus(totals.in_flight, before.in_flight), after.in_flight),
        _plus(_minus(totals.concurrent, before.concurrent), after.concurrent),
    )


def _is_ordered_effect(entry: RequestEntry) -> bool:
    return entry.footprint.effect_class is RequestEffectClass.ORDERED_EFFECT


def _is_ordered_pending(entry: RequestEntry) -> bool:
    return entry.phase is RequestPhase.PENDING and _is_ordered_effect(entry)


def snapshot_of(
    policy: RequestPolicy,
    budget: ResourceBudget,
    current_identity: RequestIdentity | None,
    entries: Iterable[RequestEntry],
    revision: int,
) -> RequestProgressionSnapshot | SnapshotFailure:
    """Build a snapshot from its parts, or report the first identity that two entries share."""
    ordered = tuple(entries)
    positions = map_of((entry.identity, position) for position, entry in enumerate(ordered))
    if len(positions) != len(ordered):
        seen: set[RequestIdentity] = set()
        for entry in ordered:
            if entry.identity in seen:
                return DuplicateIdentity(entry.identity)
            seen.add(entry.identity)
    pending_total = in_flight_total = concurrent_total = _ZERO_DEMAND
    for entry in ordered:
        counted = _contribution(entry)
        pending_total = _plus(pending_total, counted.pending)
        in_flight_total = _plus(in_flight_total, counted.in_flight)
        concurrent_total = _plus(concurrent_total, counted.concurrent)
    return _snapshot_from(
        policy, budget, current_identity, revision,
        vector_of(ordered), positions,
        bit_set_of(position for position, entry in enumerate(ordered) if entry.phase is RequestPhase.PENDING),
        bit_set_of(position for position, entry in enumerate(ordered) if _is_ordered_pending(entry)),
        _PhaseTotals(pending_total, in_flight_total, concurrent_total),
    )


def progression_policy(snapshot: RequestProgressionSnapshot) -> RequestPolicy:
    """Return the ordering policy of a snapshot."""
    return snapshot._policy


def progression_budget(snapshot: RequestProgressionSnapshot) -> ResourceBudget:
    """Return the resource budget of a snapshot."""
    return snapshot._budget


def progression_current_identity(snapshot: RequestProgressionSnapshot) -> RequestIdentity | None:
    """Return the identity submitted last, or ``None`` before any submission."""
    return snapshot._current_identity


def progression_entries(snapshot: RequestProgressionSnapshot) -> tuple[RequestEntry, ...]:
    """Return the entries of a snapshot in submission order, read-only."""
    return tuple(snapshot._entries)


def progression_revision(snapshot: RequestProgressionSnapshot) -> int:
    """Return the revision of a snapshot."""
    return snapshot._revision


def find_request(snapshot: RequestProgressionSnapshot, identity: RequestIdentity) -> RequestEntry | None:
    """Return the entry with ``identity``, or ``None`` when no entry has it."""
    position = snapshot._positions.find(identity)
    return None if position is None else snapshot._entries.get(position)


def with_budget(snapshot: RequestProgressionSnapshot, budget: ResourceBudget) -> RequestProgressionSnapshot:
    """Return a snapshot with ``budget`` and every entry of ``snapshot``."""
    return _snapshot_from(
        snapshot._policy, budget, snapshot._current_identity, snapshot._revision,
        snapshot._entries, snapshot._positions, snapshot._pending, snapshot._ordered_pending, snapshot._totals,
    )


def empty(policy: RequestPolicy, budget: ResourceBudget) -> RequestProgressionSnapshot:
    return _snapshot_from(
        policy, budget, None, 0, vector_of(()), empty_map(), empty_bit_set(), empty_bit_set(),
        _PhaseTotals(_ZERO_DEMAND, _ZERO_DEMAND, _ZERO_DEMAND),
    )


def _position_of(snapshot: RequestProgressionSnapshot, identity: RequestIdentity) -> int | None:
    return snapshot._positions.find(identity)


def _with_entry(
    snapshot: RequestProgressionSnapshot,
    position: int,
    old: RequestEntry,
    new: RequestEntry,
    revision: int,
) -> RequestProgressionSnapshot:
    pending = snapshot._pending
    if (old.phase is RequestPhase.PENDING) != (new.phase is RequestPhase.PENDING):
        pending = pending.add(position) if new.phase is RequestPhase.PENDING else pending.discard(position)
    ordered_pending = snapshot._ordered_pending
    if _is_ordered_pending(old) != _is_ordered_pending(new):
        ordered_pending = ordered_pending.add(position) if _is_ordered_pending(new) else ordered_pending.discard(position)
    return _snapshot_from(
        snapshot._policy, snapshot._budget, snapshot._current_identity, revision,
        snapshot._entries.set(position, new), snapshot._positions, pending, ordered_pending,
        _totals_replacing(snapshot._totals, old, new),
    )


def _with_phase(
    snapshot: RequestProgressionSnapshot,
    position: int,
    entry: RequestEntry,
    updated: RequestEntry,
    advance: bool = True,
) -> RequestProgressionSnapshot:
    return _with_entry(snapshot, position, entry, updated, snapshot._revision + 1 if advance else snapshot._revision)


def derive_pending(snapshot: RequestProgressionSnapshot) -> ResourceDemand:
    return snapshot._totals.pending


def derive_in_flight(snapshot: RequestProgressionSnapshot) -> ResourceDemand:
    return snapshot._totals.in_flight


def derive_concurrent(snapshot: RequestProgressionSnapshot) -> ResourceDemand:
    return snapshot._totals.concurrent


def _policy_order_allowed(snapshot: RequestProgressionSnapshot, identity: RequestIdentity) -> bool:
    if snapshot._policy is RequestPolicy.LATEST_WINS:
        return snapshot._current_identity == identity
    if snapshot._policy is RequestPolicy.ALL_EXECUTE:
        return True
    earliest = snapshot._pending.least()
    return earliest is not None and snapshot._entries.get(earliest).identity == identity


def _ordered_effect_allowed(snapshot: RequestProgressionSnapshot, identity: RequestIdentity, entry: RequestEntry) -> bool:
    if not _is_ordered_effect(entry):
        return True
    earliest = snapshot._ordered_pending.least()
    return earliest is None or snapshot._entries.get(earliest).identity == identity


def _supersede_pending(snapshot: RequestProgressionSnapshot) -> RequestProgressionSnapshot:
    entries = snapshot._entries
    ordered_pending = snapshot._ordered_pending
    pending_total = snapshot._totals.pending
    for position in snapshot._pending:
        entry = entries.get(position)
        entries = entries.set(position, dc_replace(entry, phase=RequestPhase.SUPERSEDED))
        if _is_ordered_effect(entry):
            ordered_pending = ordered_pending.discard(position)
        pending_total = _minus(pending_total, entry.demand)
    return _snapshot_from(
        snapshot._policy, snapshot._budget, snapshot._current_identity, snapshot._revision,
        entries, snapshot._positions, empty_bit_set(), ordered_pending,
        _PhaseTotals(pending_total, snapshot._totals.in_flight, snapshot._totals.concurrent),
    )


def _appended(snapshot: RequestProgressionSnapshot, entry: RequestEntry) -> RequestProgressionSnapshot:
    position = len(snapshot._entries)
    return _snapshot_from(
        snapshot._policy, snapshot._budget, entry.identity, snapshot._revision + 1,
        snapshot._entries.append(entry), snapshot._positions.set(entry.identity, position),
        snapshot._pending.add(position),
        snapshot._ordered_pending.add(position) if _is_ordered_effect(entry) else snapshot._ordered_pending,
        _PhaseTotals(_plus(snapshot._totals.pending, entry.demand), snapshot._totals.in_flight, snapshot._totals.concurrent),
    )


def submit(snapshot: RequestProgressionSnapshot, request: RequestInput) -> SubmitResult:
    if _position_of(snapshot, request.identity) is not None:
        return SubmitRejected(snapshot, DuplicateIdentity(request.identity))
    if snapshot._totals.pending.pending + request.demand.pending > snapshot._budget.pending_maximum.maximum:
        return SubmitRejected(snapshot, PendingLimitExceeded(request.demand, snapshot._budget))
    entry = RequestEntry(request.identity, request.footprint, request.demand, RequestPhase.PENDING, request.permission, None, None)
    base = _supersede_pending(snapshot) if snapshot._policy is RequestPolicy.LATEST_WINS else snapshot
    return SubmitAccepted(_appended(base, entry), Accepted(request.identity))


def _decision_selection(snapshot: RequestProgressionSnapshot, accepted: Accepted, position: int, entry: RequestEntry, selection: CostSelection) -> StartDecisionResult:
    if selection.identity != accepted.identity:
        return StartDecisionRejected(snapshot, CostSelectionIdentityMismatch(accepted.identity, selection.identity))
    if isinstance(selection, RemainPending):
        return Deferred(_with_phase(snapshot, position, entry, dc_replace(entry, cost_selection=selection), advance=False), accepted)
    if snapshot._totals.in_flight.in_flight + entry.demand.in_flight > snapshot._budget.in_flight_maximum.maximum:
        return StartDecisionRejected(snapshot, InFlightLimitExceeded(entry.demand, snapshot._budget))
    if snapshot._totals.concurrent.concurrent + entry.demand.concurrent > snapshot._budget.concurrent_maximum.maximum:
        return StartDecisionRejected(snapshot, ConcurrentLimitExceeded(entry.demand, snapshot._budget))
    command = StartCommand(accepted.identity, entry.footprint)
    advanced = _with_phase(snapshot, position, entry, dc_replace(entry, phase=RequestPhase.PREPARING, cost_selection=selection))
    return Execute(advanced, Starting(accepted.identity, command), command)


def decide_start(snapshot: RequestProgressionSnapshot, accepted: Accepted, selection: CostSelection) -> StartDecisionResult:
    position = _position_of(snapshot, accepted.identity)
    if position is None:
        return StartDecisionRejected(snapshot, UnknownRequest(accepted.identity))
    entry = snapshot._entries.get(position)
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
    return _decision_selection(snapshot, accepted, position, entry, selection)


def _failed_start(snapshot: RequestProgressionSnapshot, position: int, entry: RequestEntry, failure: StartObservationFailure) -> StartObservationFailed:
    return StartObservationFailed(_with_phase(snapshot, position, entry, dc_replace(entry, phase=RequestPhase.FAILED)), failure)


def apply_start_observation(snapshot: RequestProgressionSnapshot, starting: Starting, observed: AdapterResult[Result]) -> StartObservationResult:
    position = _position_of(snapshot, starting.identity)
    if position is None:
        return StartObservationFailed(snapshot, UnknownRequest(starting.identity))
    entry = snapshot._entries.get(position)
    if entry.phase is not RequestPhase.PREPARING:
        return StartObservationFailed(snapshot, RequestNotStarting(starting.identity))
    if isinstance(observed, AppliedSignal) and isinstance(observed.signal, Started):
        signal = observed.signal
        if signal.identity == starting.identity:
            advanced = _with_phase(snapshot, position, entry, dc_replace(entry, phase=RequestPhase.PUBLISHING, execution_handle=signal.handle))
            return Publishing(advanced, Running(starting.identity, signal.handle))
        return _failed_start(snapshot, position, entry, StartIdentityMismatch(starting.identity, signal.identity))
    if isinstance(observed, AdapterFailed) and isinstance(observed.failure, StartAdapterFailure):
        failure = observed.failure
        if failure.identity == starting.identity:
            return _failed_start(snapshot, position, entry, StartAdapterFailureObserved(starting.identity, failure.detail))
        return _failed_start(snapshot, position, entry, StartIdentityMismatch(starting.identity, failure.identity))
    return _failed_start(snapshot, position, entry, StartSignalMismatch(starting.identity))


def _failed_completion(snapshot: RequestProgressionSnapshot, position: int, entry: RequestEntry, failure: CompletionObservationFailure) -> CompletionObservationFailed:
    return CompletionObservationFailed(_with_phase(snapshot, position, entry, dc_replace(entry, phase=RequestPhase.FAILED)), failure)


def apply_completion_observation(snapshot: RequestProgressionSnapshot, running: Running, observed: AdapterResult[Result]) -> CompletionObservationResult[Result]:
    position = _position_of(snapshot, running.identity)
    if position is None:
        return CompletionObservationFailed(snapshot, UnknownCompletion(running.identity))
    entry = snapshot._entries.get(position)
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
        if snapshot._policy is RequestPolicy.LATEST_WINS and snapshot._current_identity != running.identity:
            return SupersededResult(_with_phase(snapshot, position, entry, dc_replace(entry, phase=RequestPhase.SUPERSEDED), advance=False), running.identity)
        advanced = _with_phase(snapshot, position, entry, dc_replace(entry, phase=RequestPhase.PUBLISHED))
        return AppliedResult(advanced, running.identity, signal.value)
    if isinstance(observed, AppliedSignal) and isinstance(observed.signal, CancelledAtAdapter):
        cancellation = observed.signal
        if cancellation.identity != running.identity:
            return CompletionObservationFailed(snapshot, CompletionIdentityMismatch(running.identity, cancellation.identity))
        if cancellation.handle != running.handle:
            return CompletionObservationFailed(snapshot, HandleMismatch(running.identity))
        advanced = _with_phase(snapshot, position, entry, dc_replace(entry, phase=RequestPhase.CANCELLED))
        return CancelledResult(advanced, running.identity)
    if isinstance(observed, AdapterFailed) and isinstance(observed.failure, CompletionAdapterFailure):
        failure = observed.failure
        if failure.identity != running.identity:
            return CompletionObservationFailed(snapshot, CompletionIdentityMismatch(running.identity, failure.identity))
        if failure.handle != running.handle:
            return CompletionObservationFailed(snapshot, HandleMismatch(running.identity))
        return _failed_completion(snapshot, position, entry, CompletionAdapterFailureObserved(running.identity, failure.detail))
    if isinstance(observed, AdapterFailed) and isinstance(observed.failure, CancellationAdapterFailure):
        cancellation_failure = observed.failure
        if cancellation_failure.identity != running.identity:
            return CompletionObservationFailed(snapshot, CompletionIdentityMismatch(running.identity, cancellation_failure.identity))
        if cancellation_failure.handle != running.handle:
            return CompletionObservationFailed(snapshot, HandleMismatch(running.identity))
        return _failed_completion(snapshot, position, entry, CancellationAdapterFailureObserved(running.identity, cancellation_failure.detail))
    return CompletionObservationFailed(snapshot, CompletionSignalMismatch(running.identity))


def decide_cancel(snapshot: RequestProgressionSnapshot, identity: RequestIdentity) -> CancelDecisionResult:
    position = _position_of(snapshot, identity)
    if position is None:
        return CancelRejected(snapshot, CancelUnknownRequest(identity))
    entry = snapshot._entries.get(position)
    if entry.phase is RequestPhase.PENDING:
        advanced = _with_phase(snapshot, position, entry, dc_replace(entry, phase=RequestPhase.CANCELLED))
        return CancelledWithoutAdapter(advanced, identity)
    if entry.phase is RequestPhase.PUBLISHING:
        if entry.execution_handle is None:
            return CancelRejected(snapshot, MissingExecutionHandle(identity))
        handle = entry.execution_handle
        return CancelIssued(snapshot, Running(identity, handle), CancelCommand(identity, handle))
    if entry.phase is RequestPhase.PREPARING:
        return CancelRejected(snapshot, MissingExecutionHandle(identity))
    return CancelRejected(snapshot, RequestAlreadyTerminal(identity))
