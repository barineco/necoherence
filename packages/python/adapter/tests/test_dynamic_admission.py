# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Tests for dynamic admission: capacity, idempotent coalescing, provenance erasure."""

from __future__ import annotations

from collections.abc import Callable

from neco_quotient_retention import DematerializeWitness, FutureUse, Irrecoverable, OutstandingSignal

from necoherence.core import Applied, Rejected
from necoherence.dynamic_admission import (
    AdmissionProvenance,
    AdmissionSignal,
    CapacityObservation,
    CapacityObservationUnavailable,
    Coalesced,
    DynamicAdmissionInput,
    DynamicAdmissionState,
    EnvironmentSpecification,
    ProvenanceObservation,
    ProvenanceRetentionRequired,
    SignalKind,
    Started,
    Submitted,
    admission_state_configured_safety_limit,
    admission_state_of,
    admission_state_progression,
    admission_state_provenance,
    admit_dynamic_request,
    elide_admission_provenance,
)
from necoherence.request_progression import (
    ConfiguredSafetyLimit,
    EvidenceVersion,
    Execute,
    ExecuteNow,
    ExecutionHandle,
    Permitted,
    RequestEffectClass,
    RequestFootprint,
    RequestIdentity,
    RequestInput,
    RequestPhase,
    RequestPolicy,
    ResourceBudget,
    ResourceDemand,
    RequestProgressionSnapshot,
    empty,
    progression_budget,
    progression_current_identity,
    progression_entries,
    progression_policy,
    progression_revision,
    snapshot_of,
)


def _with_entries(progression: RequestProgressionSnapshot, entries: object) -> RequestProgressionSnapshot:
    rebuilt = snapshot_of(
        progression_policy(progression),
        progression_budget(progression),
        progression_current_identity(progression),
        entries,  # type: ignore[arg-type]
        progression_revision(progression),
    )
    assert isinstance(rebuilt, RequestProgressionSnapshot)
    return rebuilt


def _limit(resource: str, maximum: int) -> ConfiguredSafetyLimit:
    return ConfiguredSafetyLimit(resource=resource, maximum=maximum)


def _budget(pending: int = 10, in_flight: int = 10, concurrent: int = 10) -> ResourceBudget:
    return ResourceBudget(_limit("p", pending), _limit("i", in_flight), _limit("c", concurrent))


def _identity(n: int) -> RequestIdentity:
    return RequestIdentity(kind="k", provenance=str(n), revision=0)


def _footprint() -> RequestFootprint:
    return RequestFootprint(reads=(), writes=(), effect_class=RequestEffectClass.PURE)


def _demand(pending: int = 1) -> ResourceDemand:
    return ResourceDemand(pending=pending, in_flight=0, concurrent=0)


def _request(n: int, pending: int = 1) -> RequestInput:
    identity = _identity(n)
    return RequestInput(identity=identity, footprint=_footprint(), demand=_demand(pending), permission=Permitted(identity, ()))


def _state(budget: ResourceBudget = _budget()) -> DynamicAdmissionState:
    return admission_state_of(
        progression=empty(RequestPolicy.FIFO, budget),
        configured_safety_limit=budget,
        provenance=AdmissionProvenance(future_uses=(), outstanding_signals=()),
    )


def _input(
    state: DynamicAdmissionState,
    request: RequestInput,
    observed_at: int = 0,
    observation_at: int = 0,
    max_age: int = 100,
) -> DynamicAdmissionInput:
    return DynamicAdmissionInput(
        state=state,
        request=request,
        environment_specification=EnvironmentSpecification(max_age),
        capacity_observation=CapacityObservation(observed=admission_state_configured_safety_limit(state), observed_at=observation_at),
        observed_at=observed_at,
        start=None,
    )


def test_future_dated_observation_is_rejected() -> None:
    state = _state()
    outcome = admit_dynamic_request(_input(state, _request(1), observed_at=0, observation_at=5))
    assert isinstance(outcome, Rejected)
    assert isinstance(outcome.reason, CapacityObservationUnavailable)


def test_expired_observation_is_rejected() -> None:
    state = _state()
    outcome = admit_dynamic_request(_input(state, _request(1), observed_at=200, observation_at=0, max_age=10))
    assert isinstance(outcome, Rejected)
    assert isinstance(outcome.reason, CapacityObservationUnavailable)


def test_fresh_request_submits_when_within_budget() -> None:
    state = _state()
    outcome = admit_dynamic_request(_input(state, _request(1)))
    assert isinstance(outcome, Applied)
    assert isinstance(outcome.value.admission_decision, Submitted)


def test_pending_over_budget_is_rejected() -> None:
    state = _state(budget=_budget(pending=0))
    outcome = admit_dynamic_request(_input(state, _request(1)))
    assert isinstance(outcome, Rejected)


def test_admission_decides_start_without_adapter_observation() -> None:
    state = _state()
    identity = _identity(1)
    base = _input(state, _request(1))
    outcome = admit_dynamic_request(
        DynamicAdmissionInput(
            state=base.state,
            request=base.request,
            environment_specification=base.environment_specification,
            capacity_observation=base.capacity_observation,
            observed_at=base.observed_at,
            start=ExecuteNow(identity, EvidenceVersion("i", "d", "a"), 0),
        )
    )
    assert isinstance(outcome, Applied)
    assert isinstance(outcome.value.admission_decision, Started)
    assert isinstance(outcome.value.admission_decision.result, Execute)
    assert progression_entries(admission_state_progression(outcome.value.admission_decision.state))[0].phase is RequestPhase.PREPARING


def test_identical_pending_duplicate_coalesces_idempotently() -> None:
    state = _state()
    first = admit_dynamic_request(_input(state, _request(1)))
    assert isinstance(first, Applied)
    admitted_state = first.value.admission_decision.state
    second = admit_dynamic_request(_input(admitted_state, _request(1)))
    assert isinstance(second, Applied)
    assert isinstance(second.value.admission_decision, Coalesced)
    assert admission_state_progression(second.value.admission_decision.state) == admission_state_progression(admitted_state)


def test_elide_provenance_of_unknown_identity_is_rejected() -> None:
    state = _state()
    outcome = elide_admission_provenance(state, _identity(1))
    assert isinstance(outcome, Rejected)


def _terminal_state_with(provenance_of: Callable[[RequestIdentity], AdmissionProvenance]) -> tuple[DynamicAdmissionState, RequestIdentity]:
    state = _state()
    submitted = admit_dynamic_request(_input(state, _request(1)))
    assert isinstance(submitted, Applied)
    admitted_state = submitted.value.admission_decision.state
    entry = progression_entries(admission_state_progression(admitted_state))[0]
    from dataclasses import replace as dc_replace

    terminal_entries = tuple(
        dc_replace(e, phase=RequestPhase.CANCELLED) if e.identity == entry.identity else e
        for e in progression_entries(admission_state_progression(admitted_state))
    )
    terminal_progression = _with_entries(admission_state_progression(admitted_state), terminal_entries)
    terminal_state = admission_state_of(
        progression=terminal_progression,
        configured_safety_limit=admission_state_configured_safety_limit(admitted_state),
        provenance=provenance_of(entry.identity),
    )
    return terminal_state, entry.identity


def _signal(identity: RequestIdentity) -> AdmissionSignal:
    return AdmissionSignal(identity=identity, handle=ExecutionHandle("h0"), kind=SignalKind.PENDING_COMPLETION)


def test_elide_provenance_blocked_by_future_use() -> None:
    state, identity = _terminal_state_with(
        lambda i: AdmissionProvenance(future_uses=(i,), outstanding_signals=())
    )
    outcome = elide_admission_provenance(state, identity)
    assert isinstance(outcome, Rejected)
    assert outcome.reason == ProvenanceRetentionRequired(identity, (FutureUse(identity),))


def test_elide_provenance_blocked_by_outstanding_signal() -> None:
    state, identity = _terminal_state_with(
        lambda i: AdmissionProvenance(future_uses=(), outstanding_signals=(_signal(i),))
    )
    outcome = elide_admission_provenance(state, identity)
    assert isinstance(outcome, Rejected)
    assert outcome.reason == ProvenanceRetentionRequired(identity, (OutstandingSignal(identity),))


def test_elide_provenance_blocked_by_future_use_and_outstanding_signal_lists_both_in_order() -> None:
    state, identity = _terminal_state_with(
        lambda i: AdmissionProvenance(future_uses=(i,), outstanding_signals=(_signal(i),))
    )
    outcome = elide_admission_provenance(state, identity)
    assert isinstance(outcome, Rejected)
    assert outcome.reason == ProvenanceRetentionRequired(
        identity, (FutureUse(identity), OutstandingSignal(identity))
    )


def test_elide_provenance_of_terminal_entry_with_no_retention_erases() -> None:
    state, identity = _terminal_state_with(
        lambda _i: AdmissionProvenance(future_uses=(), outstanding_signals=())
    )
    outcome = elide_admission_provenance(state, identity)
    assert isinstance(outcome, Applied)
    _, witness = outcome.value
    assert witness == DematerializeWitness(
        identity, Irrecoverable(), (ProvenanceObservation.FOOTPRINT, ProvenanceObservation.EVIDENCE)
    )
