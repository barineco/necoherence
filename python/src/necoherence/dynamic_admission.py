# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Dynamic admission over ``request_progression``."""

from __future__ import annotations

from dataclasses import dataclass, replace as dc_replace
from enum import Enum
from typing import Never

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
    submit,
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


@dataclass(frozen=True, slots=True)
class DynamicAdmissionState:
    """Dynamic admission state: the progression snapshot, its configured
    safety limit, and provenance."""

    progression: RequestProgressionSnapshot
    configured_safety_limit: ResourceBudget
    provenance: AdmissionProvenance


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


@dataclass(frozen=True, slots=True)
class ProvenanceRetentionRequired:
    identity: RequestIdentity


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
class Erased:
    identity: RequestIdentity


@dataclass(frozen=True, slots=True)
class Retained:
    identity: RequestIdentity
    reason: str


type ProvenanceErasureWitness = Erased | Retained


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
    provenance_erasure_witness: ProvenanceErasureWitness | None
    coalescing_witness: CoalescingWitness


type DynamicAdmissionOutcome = Outcome[DynamicAdmissionResult, DynamicAdmissionFailure, Never, Never]
type ElisionOutcome = Outcome[
    tuple[DynamicAdmissionState, ProvenanceErasureWitness], DynamicAdmissionFailure, Never, Never
]


def _find_entry(entries: tuple[RequestEntry, ...], identity: RequestIdentity) -> RequestEntry | None:
    for entry in entries:
        if entry.identity == identity:
            return entry
    return None


def _replace_entry(
    entries: tuple[RequestEntry, ...], identity: RequestIdentity, replacement: RequestEntry
) -> tuple[RequestEntry, ...]:
    return tuple(replacement if entry.identity == identity else entry for entry in entries)


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
    entry = _find_entry(snapshot.entries, request.identity)
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
    identities are closed failures. A live future use or outstanding signal
    blocks erasure and leaves ``state`` unchanged."""
    entry = _find_entry(state.progression.entries, identity)
    if entry is None:
        return Rejected(DynamicUnknownRequest(identity))
    if not _is_terminal_phase(entry.phase):
        return Rejected(RequestNotTerminal(identity))
    if identity in state.provenance.future_uses:
        return Rejected(ProvenanceRetentionRequired(identity))
    if any(s.identity == identity for s in state.provenance.outstanding_signals):
        return Rejected(ProvenanceRetentionRequired(identity))
    new_progression = dc_replace(
        state.progression,
        entries=_replace_entry(state.progression.entries, identity, _erase_entry_provenance(entry)),
    )
    new_provenance = AdmissionProvenance(
        future_uses=tuple(i for i in state.provenance.future_uses if i != identity),
        outstanding_signals=tuple(s for s in state.provenance.outstanding_signals if s.identity != identity),
    )
    new_state = dc_replace(state, progression=new_progression, provenance=new_provenance)
    return Applied((new_state, Erased(identity)))


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
        input.state.configured_safety_limit, input.capacity_observation.observed
    )
    if mismatch is not None:
        return Rejected(ResourceCoordinateMismatch(mismatch[0], mismatch[1]))

    permission_failure = _permission_check(input.request)
    if permission_failure is not None:
        return Rejected(permission_failure)

    effective_budget = _effective_budget_of(
        input.state.configured_safety_limit, input.capacity_observation.observed
    )
    snapshot = input.state.progression
    provenance = input.state.provenance

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

    budgeted_snapshot = dc_replace(snapshot, budget=effective_budget)
    submit_result = submit(budgeted_snapshot, input.request)
    if isinstance(submit_result, SubmitRejected):
        return Rejected(ProgressionSubmitFailure(submit_result.failure))

    snapshot_after_submit = submit_result.snapshot
    accepted = submit_result.accepted

    if input.start is None:
        new_state = dc_replace(input.state, progression=snapshot_after_submit)
        return Applied(
            DynamicAdmissionResult(
                effective_budget=effective_budget,
                admission_decision=Submitted(new_state, accepted),
                future_use_set=_to_future_use_set(new_state.provenance),
                outstanding_signal_set=_to_outstanding_signal_set(new_state.provenance),
                provenance_erasure_witness=None,
                coalescing_witness=NotCoalesced("no duplicate pending request"),
            )
        )

    start_result = decide_start(snapshot_after_submit, accepted, input.start)
    if isinstance(start_result, StartDecisionRejected):
        return Rejected(ProgressionStartFailure(start_result.failure))
    new_state = dc_replace(input.state, progression=start_result.snapshot)
    return Applied(
        DynamicAdmissionResult(
            effective_budget=effective_budget,
            admission_decision=Started(new_state, start_result),
            future_use_set=_to_future_use_set(new_state.provenance),
            outstanding_signal_set=_to_outstanding_signal_set(new_state.provenance),
            provenance_erasure_witness=None,
            coalescing_witness=NotCoalesced("no duplicate pending request"),
        )
    )
