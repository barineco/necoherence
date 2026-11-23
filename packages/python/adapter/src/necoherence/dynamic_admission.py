# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Dynamic admission over ``request_progression``."""

from __future__ import annotations

from dataclasses import dataclass, replace as dc_replace
from enum import Enum
from typing import Never

from neco_quotient_retention import (
    Dematerialize,
    DematerializeWitness,
    ErasureRequest,
    Irrecoverable,
    LiveMembership,
    MissingInput,
    Retain,
    RetentionReason,
    judge_erasure_by,
)
from neco_quotient_retention import Rejected as ErasureRejected

from necoherence.core import Applied, Outcome, Rejected
from necoherence.request_progression import (
    Accepted,
    ConfiguredSafetyLimit,
    CostSelection,
    ExecuteNow,
    ExecutionHandle,
    MeaningPermission,
    Denied,
    Ordered,
    Permitted,
    PermissionDenial,
    RequestEntry,
    RequestIdentity,
    RequestInput,
    RequestPhase,
    RequestProgressionSnapshot,
    ResourceBudget,
    StartDecisionRejected,
    StartDecisionFailure,
    StartDecisionResult,
    SubmitFailure,
    SubmitRejected,
    decide_start,
    derive_concurrent,
    derive_in_flight,
    derive_pending,
    find_request,
    progression_revision,
    submit,
    with_budget,
    _position_of,
    _with_entry,
)




@dataclass(frozen=True, slots=True)
class EnvironmentSpecification:
    """Declares the maximum age, in the caller's clock, a ``CapacityObservation``
    stays usable."""

    max_observation_age: int


@dataclass(frozen=True, slots=True)
class CapacityObservation:
    """An observed resource budget and the instant it was taken at."""

    observed: ResourceBudget
    observed_at: int


class SignalKind(Enum):
    """Which adapter observation a still-open request is waiting on."""

    PENDING_COMPLETION = "pendingCompletion"
    PENDING_CANCELLATION = "pendingCancellation"


@dataclass(frozen=True, slots=True)
class AdmissionSignal:
    """One adapter signal not yet folded into a terminal entry's own record."""

    identity: RequestIdentity
    handle: ExecutionHandle
    kind: SignalKind


@dataclass(frozen=True, slots=True)
class AdmissionProvenance:
    """Explicit provenance alongside a ``DynamicAdmissionState``: identities a
    caller still intends to reuse, and adapter signals not yet folded into
    their own terminal entry. Neither is inferred from the progression
    snapshot."""

    future_uses: tuple[RequestIdentity, ...]
    outstanding_signals: tuple[AdmissionSignal, ...]


class DynamicAdmissionState:
    """Dynamic admission state: the progression snapshot, its configured
    safety limit, and provenance.

    The fields are private. ``admission_state_of`` is the only construction
    path, and ``admission_state_progression``,
    ``admission_state_configured_safety_limit`` and
    ``admission_state_provenance`` read the parts back. Operations return a new
    value that shares every unchanged part with the state they were given.
    """

    __slots__ = ("_progression", "_configured_safety_limit", "_provenance", "_future_uses", "_signalled")

    _progression: RequestProgressionSnapshot
    _configured_safety_limit: ResourceBudget
    _provenance: AdmissionProvenance
    _future_uses: frozenset[RequestIdentity]
    _signalled: frozenset[RequestIdentity]

    def __init__(self, *_arguments: object, **_keywords: object) -> None:
        raise TypeError("DynamicAdmissionState is constructed with admission_state_of")

    def __setattr__(self, name: str, value: object) -> None:
        raise AttributeError("DynamicAdmissionState is immutable")

    def __eq__(self, other: object) -> bool:
        return (
            isinstance(other, DynamicAdmissionState)
            and self._progression == other._progression
            and self._configured_safety_limit == other._configured_safety_limit
            and self._provenance == other._provenance
        )

    def __hash__(self) -> int:
        return hash((self._progression, self._configured_safety_limit, self._provenance))

    def __repr__(self) -> str:
        return (
            f"DynamicAdmissionState(progression={self._progression!r}, "
            f"configured_safety_limit={self._configured_safety_limit!r}, provenance={self._provenance!r})"
        )


def _state_from(
    progression: RequestProgressionSnapshot,
    configured_safety_limit: ResourceBudget,
    provenance: AdmissionProvenance,
    future_uses: frozenset[RequestIdentity],
    signalled: frozenset[RequestIdentity],
) -> DynamicAdmissionState:
    state = object.__new__(DynamicAdmissionState)
    object.__setattr__(state, "_progression", progression)
    object.__setattr__(state, "_configured_safety_limit", configured_safety_limit)
    object.__setattr__(state, "_provenance", provenance)
    object.__setattr__(state, "_future_uses", future_uses)
    object.__setattr__(state, "_signalled", signalled)
    return state


def admission_state_of(
    progression: RequestProgressionSnapshot,
    configured_safety_limit: ResourceBudget,
    provenance: AdmissionProvenance,
) -> DynamicAdmissionState:
    """Build a state from its parts, indexing the identities provenance still holds."""
    return _state_from(
        progression,
        configured_safety_limit,
        provenance,
        frozenset(provenance.future_uses),
        frozenset(signal.identity for signal in provenance.outstanding_signals),
    )


def admission_state_progression(state: DynamicAdmissionState) -> RequestProgressionSnapshot:
    """Return the progression snapshot of a state."""
    return state._progression


def admission_state_configured_safety_limit(state: DynamicAdmissionState) -> ResourceBudget:
    """Return the configured safety limit of a state."""
    return state._configured_safety_limit


def admission_state_provenance(state: DynamicAdmissionState) -> AdmissionProvenance:
    """Return the provenance of a state."""
    return state._provenance


def _with_progression(state: DynamicAdmissionState, progression: RequestProgressionSnapshot) -> DynamicAdmissionState:
    return _state_from(
        progression, state._configured_safety_limit, state._provenance, state._future_uses, state._signalled
    )


@dataclass(frozen=True, slots=True)
class DynamicAdmissionInput:
    """One admission request with an optional progression start selection."""

    state: DynamicAdmissionState
    request: RequestInput
    environment_specification: EnvironmentSpecification
    capacity_observation: CapacityObservation
    observed_at: int
    start: CostSelection | None


type EffectiveBudget = ResourceBudget


@dataclass(frozen=True, slots=True)
class CapacityObservationUnavailable:
    age: int
    max_age: int


@dataclass(frozen=True, slots=True)
class ResourceCoordinateMismatch:
    configured_resource: str
    observed_resource: str


@dataclass(frozen=True, slots=True)
class ConfiguredSafetyLimitExceeded:
    resource: str
    occupied: int
    allowed: int


@dataclass(frozen=True, slots=True)
class MeaningDenied:
    identity: RequestIdentity
    reason: PermissionDenial


@dataclass(frozen=True, slots=True)
class DynamicPermissionIdentityMismatch:
    request_identity: RequestIdentity
    permission_identity: RequestIdentity


@dataclass(frozen=True, slots=True)
class AdapterBindingUnavailable:
    identity: RequestIdentity


@dataclass(frozen=True, slots=True)
class BindingSelectionMismatch:
    identity: RequestIdentity


@dataclass(frozen=True, slots=True)
class ProgressionSubmitFailure:
    failure: SubmitFailure


@dataclass(frozen=True, slots=True)
class ProgressionStartFailure:
    failure: StartDecisionFailure


class ProvenanceObservation(Enum):
    """The kind of provenance an erasure removes from a terminal entry."""

    FOOTPRINT = "footprint"
    EVIDENCE = "evidence"


type ErasureWitness = DematerializeWitness[RequestIdentity, None, None, ProvenanceObservation]
type ErasureRetention = RetentionReason[RequestIdentity, None, ProvenanceObservation]


@dataclass(frozen=True, slots=True)
class ProvenanceRetentionRequired:
    identity: RequestIdentity
    reasons: tuple[ErasureRetention, ...]


@dataclass(frozen=True, slots=True)
class ErasureInputIncomplete:
    identity: RequestIdentity
    missing: MissingInput


@dataclass(frozen=True, slots=True)
class DynamicUnknownRequest:
    identity: RequestIdentity


@dataclass(frozen=True, slots=True)
class RequestNotTerminal:
    identity: RequestIdentity


type DynamicAdmissionFailure = (
    CapacityObservationUnavailable
    | ResourceCoordinateMismatch
    | ConfiguredSafetyLimitExceeded
    | MeaningDenied
    | DynamicPermissionIdentityMismatch
    | AdapterBindingUnavailable
    | BindingSelectionMismatch
    | ProgressionSubmitFailure
    | ProgressionStartFailure
    | ProvenanceRetentionRequired
    | ErasureInputIncomplete
    | DynamicUnknownRequest
    | RequestNotTerminal
)


@dataclass(frozen=True, slots=True)
class Submitted:
    state: DynamicAdmissionState
    accepted: Accepted


@dataclass(frozen=True, slots=True)
class Started:
    state: DynamicAdmissionState
    result: StartDecisionResult


@dataclass(frozen=True, slots=True)
class Coalesced:
    state: DynamicAdmissionState
    identity: RequestIdentity


type AdmissionDecision = Submitted | Started | Coalesced


@dataclass(frozen=True, slots=True)
class FutureUseSet:
    identities: tuple[RequestIdentity, ...]


@dataclass(frozen=True, slots=True)
class OutstandingSignalSet:
    signals: tuple[AdmissionSignal, ...]


@dataclass(frozen=True, slots=True)
class CoalescedWitness:
    identity: RequestIdentity


@dataclass(frozen=True, slots=True)
class NotCoalesced:
    reason: str


type CoalescingWitness = CoalescedWitness | NotCoalesced


@dataclass(frozen=True, slots=True)
class DynamicAdmissionResult:
    """Result of one successful dynamic admission evaluation; all six
    declared fields are always present."""

    effective_budget: EffectiveBudget
    admission_decision: AdmissionDecision
    future_use_set: FutureUseSet
    outstanding_signal_set: OutstandingSignalSet
    provenance_erasure_witness: ErasureWitness | None
    coalescing_witness: CoalescingWitness


type DynamicAdmissionOutcome = Outcome[DynamicAdmissionResult, DynamicAdmissionFailure, Never, Never]
type ElisionOutcome = Outcome[
    tuple[DynamicAdmissionState, ErasureWitness], DynamicAdmissionFailure, Never, Never
]


def _min_limit(a: ConfiguredSafetyLimit, b: ConfiguredSafetyLimit) -> ConfiguredSafetyLimit:
    return ConfiguredSafetyLimit(resource=a.resource, maximum=min(a.maximum, b.maximum))


def _effective_budget_of(configured: ResourceBudget, observed: ResourceBudget) -> EffectiveBudget:
    return ResourceBudget(
        pending_maximum=_min_limit(configured.pending_maximum, observed.pending_maximum),
        in_flight_maximum=_min_limit(configured.in_flight_maximum, observed.in_flight_maximum),
        concurrent_maximum=_min_limit(configured.concurrent_maximum, observed.concurrent_maximum),
    )


def _resource_coordinate_mismatch(
    configured: ResourceBudget, observed: ResourceBudget
) -> tuple[str, str] | None:
    if configured.pending_maximum.resource != observed.pending_maximum.resource:
        return (configured.pending_maximum.resource, observed.pending_maximum.resource)
    if configured.in_flight_maximum.resource != observed.in_flight_maximum.resource:
        return (configured.in_flight_maximum.resource, observed.in_flight_maximum.resource)
    if configured.concurrent_maximum.resource != observed.concurrent_maximum.resource:
        return (configured.concurrent_maximum.resource, observed.concurrent_maximum.resource)
    return None


def _observation_age(input: DynamicAdmissionInput) -> int:
    if input.observed_at < input.capacity_observation.observed_at:
        return (
            (input.capacity_observation.observed_at - input.observed_at)
            + input.environment_specification.max_observation_age
            + 1
        )
    return input.observed_at - input.capacity_observation.observed_at


def _permission_check(request: RequestInput) -> DynamicAdmissionFailure | None:
    permission = request.permission
    if isinstance(permission, Denied):
        if permission.identity == request.identity:
            return MeaningDenied(permission.identity, permission.reason)
        return DynamicPermissionIdentityMismatch(request.identity, permission.identity)
    if permission.identity == request.identity:
        return None
    return DynamicPermissionIdentityMismatch(request.identity, permission.identity)


def _same_pending_entry(entry: RequestEntry, request: RequestInput) -> bool:
    return (
        entry.phase == RequestPhase.PENDING
        and entry.identity == request.identity
        and entry.footprint == request.footprint
        and entry.demand == request.demand
        and entry.meaning_permission == request.permission
    )


def _matching_pending_duplicate(
    snapshot: RequestProgressionSnapshot, request: RequestInput
) -> RequestEntry | None:
    entry = find_request(snapshot, request.identity)
    if entry is not None and _same_pending_entry(entry, request):
        return entry
    return None


def _to_future_use_set(provenance: AdmissionProvenance) -> FutureUseSet:
    return FutureUseSet(provenance.future_uses)


def _to_outstanding_signal_set(provenance: AdmissionProvenance) -> OutstandingSignalSet:
    return OutstandingSignalSet(provenance.outstanding_signals)


def _is_terminal_phase(phase: RequestPhase) -> bool:
    return phase in (
        RequestPhase.PUBLISHED,
        RequestPhase.SUPERSEDED,
        RequestPhase.CANCELLED,
        RequestPhase.FAILED,
    )


def _erase_meaning_permission_evidence(permission: MeaningPermission) -> MeaningPermission:
    if isinstance(permission, Permitted):
        return Permitted(permission.identity, ())
    if isinstance(permission, Ordered):
        return Ordered(permission.identity, ())
    return permission


def _erase_entry_provenance(entry: RequestEntry) -> RequestEntry:
    return dc_replace(
        entry,
        footprint=dc_replace(entry.footprint, reads=(), writes=()),
        meaning_permission=_erase_meaning_permission_evidence(entry.meaning_permission),
    )


def elide_admission_provenance(
    state: DynamicAdmissionState, identity: RequestIdentity
) -> ElisionOutcome:
    """Elide one terminal entry's provenance. Unknown or non-terminal
    identities are closed failures. Otherwise ``judge_erasure_by`` decides: a
    dematerialize decision clears the entry's footprint and permission
    evidence and returns the judgment's witness; a retain decision is
    ``ProvenanceRetentionRequired`` with its reasons; missing input is
    ``ErasureInputIncomplete``. Failures leave ``state`` unchanged."""
    entry = find_request(state._progression, identity)
    position = _position_of(state._progression, identity)
    if entry is None or position is None:
        return Rejected(DynamicUnknownRequest(identity))
    if not _is_terminal_phase(entry.phase):
        return Rejected(RequestNotTerminal(identity))
    request = ErasureRequest(
        target=identity,
        target_basis=None,
        removed_observations=(ProvenanceObservation.FOOTPRINT, ProvenanceObservation.EVIDENCE),
        preserved_observations=(),
    )
    membership = LiveMembership(
        active_basis=lambda _basis: False,
        branch_root=lambda _target: False,
        future_use=state._future_uses.__contains__,
        outstanding_effect=lambda _target: False,
        outstanding_signal=state._signalled.__contains__,
    )
    decision = judge_erasure_by(request, membership, Irrecoverable())
    if isinstance(decision, Dematerialize):
        progression = state._progression
        new_progression = _with_entry(
            progression, position, entry, _erase_entry_provenance(entry), progression_revision(progression)
        )
        return Applied((_with_progression(state, new_progression), decision.witness))
    if isinstance(decision, Retain):
        return Rejected(ProvenanceRetentionRequired(identity, tuple(decision.reasons)))
    assert isinstance(decision, ErasureRejected)
    return Rejected(ErasureInputIncomplete(identity, decision.missing))


def admit_dynamic_request(input: DynamicAdmissionInput) -> DynamicAdmissionOutcome:
    """Evaluate dynamic admission through ``submit`` and ``decide_start``.

    Adapter observations are not an admission input and are applied later by
    request progression's observation operations.
    """
    age = _observation_age(input)
    if age > input.environment_specification.max_observation_age:
        return Rejected(
            CapacityObservationUnavailable(age, input.environment_specification.max_observation_age)
        )

    mismatch = _resource_coordinate_mismatch(
        input.state._configured_safety_limit, input.capacity_observation.observed
    )
    if mismatch is not None:
        return Rejected(ResourceCoordinateMismatch(mismatch[0], mismatch[1]))

    permission_failure = _permission_check(input.request)
    if permission_failure is not None:
        return Rejected(permission_failure)

    effective_budget = _effective_budget_of(
        input.state._configured_safety_limit, input.capacity_observation.observed
    )
    snapshot = input.state._progression
    provenance = input.state._provenance

    duplicate = _matching_pending_duplicate(snapshot, input.request)
    if duplicate is not None:
        new_selection = input.start
        entry_selection = duplicate.cost_selection
        if entry_selection is None and new_selection is None:
            return Applied(
                DynamicAdmissionResult(
                    effective_budget=effective_budget,
                    admission_decision=Coalesced(input.state, input.request.identity),
                    future_use_set=_to_future_use_set(provenance),
                    outstanding_signal_set=_to_outstanding_signal_set(provenance),
                    provenance_erasure_witness=None,
                    coalescing_witness=CoalescedWitness(input.request.identity),
                )
            )
        if entry_selection is not None and new_selection is not None:
            if entry_selection == new_selection:
                return Applied(
                    DynamicAdmissionResult(
                        effective_budget=effective_budget,
                        admission_decision=Coalesced(input.state, input.request.identity),
                        future_use_set=_to_future_use_set(provenance),
                        outstanding_signal_set=_to_outstanding_signal_set(provenance),
                        provenance_erasure_witness=None,
                        coalescing_witness=CoalescedWitness(input.request.identity),
                    )
                )
            return Rejected(BindingSelectionMismatch(input.request.identity))
        return Rejected(AdapterBindingUnavailable(input.request.identity))

    pending_occupied = derive_pending(snapshot).pending + input.request.demand.pending
    if pending_occupied > effective_budget.pending_maximum.maximum:
        return Rejected(
            ConfiguredSafetyLimitExceeded(
                effective_budget.pending_maximum.resource,
                pending_occupied,
                effective_budget.pending_maximum.maximum,
            )
        )

    execute_now = input.start is not None and isinstance(input.start, ExecuteNow)
    in_flight_occupied = derive_in_flight(snapshot).in_flight + input.request.demand.in_flight
    concurrent_occupied = derive_concurrent(snapshot).concurrent + input.request.demand.concurrent
    if execute_now and in_flight_occupied > effective_budget.in_flight_maximum.maximum:
        return Rejected(
            ConfiguredSafetyLimitExceeded(
                effective_budget.in_flight_maximum.resource,
                in_flight_occupied,
                effective_budget.in_flight_maximum.maximum,
            )
        )
    if execute_now and concurrent_occupied > effective_budget.concurrent_maximum.maximum:
        return Rejected(
            ConfiguredSafetyLimitExceeded(
                effective_budget.concurrent_maximum.resource,
                concurrent_occupied,
                effective_budget.concurrent_maximum.maximum,
            )
        )

    budgeted_snapshot = with_budget(snapshot, effective_budget)
    submit_result = submit(budgeted_snapshot, input.request)
    if isinstance(submit_result, SubmitRejected):
        return Rejected(ProgressionSubmitFailure(submit_result.failure))

    snapshot_after_submit = submit_result.snapshot
    accepted = submit_result.accepted

    if input.start is None:
        new_state = _with_progression(input.state, snapshot_after_submit)
        return Applied(
            DynamicAdmissionResult(
                effective_budget=effective_budget,
                admission_decision=Submitted(new_state, accepted),
                future_use_set=_to_future_use_set(new_state._provenance),
                outstanding_signal_set=_to_outstanding_signal_set(new_state._provenance),
                provenance_erasure_witness=None,
                coalescing_witness=NotCoalesced("no duplicate pending request"),
            )
        )

    start_result = decide_start(snapshot_after_submit, accepted, input.start)
    if isinstance(start_result, StartDecisionRejected):
        return Rejected(ProgressionStartFailure(start_result.failure))
    new_state = _with_progression(input.state, start_result.snapshot)
    return Applied(
        DynamicAdmissionResult(
            effective_budget=effective_budget,
            admission_decision=Started(new_state, start_result),
            future_use_set=_to_future_use_set(new_state._provenance),
            outstanding_signal_set=_to_outstanding_signal_set(new_state._provenance),
            provenance_erasure_witness=None,
            coalescing_witness=NotCoalesced("no duplicate pending request"),
        )
    )
