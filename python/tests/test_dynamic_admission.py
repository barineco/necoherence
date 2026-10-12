# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Tests for dynamic admission: capacity, idempotent coalescing, provenance erasure."""

from __future__ import annotations

from necoherence.core import Applied, Rejected
from necoherence.dynamic_admission import (
    AdmissionProvenance,
    CapacityObservation,
    CapacityObservationUnavailable,
    Coalesced,
    DynamicAdmissionInput,
    DynamicAdmissionState,
    Erased,
    EnvironmentSpecification,
    ProvenanceRetentionRequired,
    Started,
    Submitted,
    admit_dynamic_request,
    elide_admission_provenance,
)
from necoherence.request_progression import (
    ConfiguredSafetyLimit,
    EvidenceVersion,
    Execute,
    ExecuteNow,
    Permitted,
    RequestEffectClass,
    RequestFootprint,
    RequestIdentity,
    RequestInput,
    RequestPhase,
    RequestPolicy,
    ResourceBudget,
    ResourceDemand,
    empty,
)


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
    return DynamicAdmissionState(
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
        capacity_observation=CapacityObservation(observed=state.configured_safety_limit, observed_at=observation_at),
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
    assert outcome.value.admission_decision.state.progression.entries[0].phase is RequestPhase.PREPARING


def test_identical_pending_duplicate_coalesces_idempotently() -> None:
    state = _state()
    first = admit_dynamic_request(_input(state, _request(1)))
    assert isinstance(first, Applied)
    admitted_state = first.value.admission_decision.state
    second = admit_dynamic_request(_input(admitted_state, _request(1)))
    assert isinstance(second, Applied)
    assert isinstance(second.value.admission_decision, Coalesced)
    assert second.value.admission_decision.state.progression == admitted_state.progression


def test_elide_provenance_of_unknown_identity_is_rejected() -> None:
    state = _state()
    outcome = elide_admission_provenance(state, _identity(1))
    assert isinstance(outcome, Rejected)


def test_elide_provenance_blocked_by_future_use() -> None:
    state = _state()
    submitted = admit_dynamic_request(_input(state, _request(1)))
    assert isinstance(submitted, Applied)
    admitted_state = submitted.value.admission_decision.state
    entry = admitted_state.progression.entries[0]
    from dataclasses import replace as dc_replace

    terminal_entries = tuple(
        dc_replace(e, phase=RequestPhase.CANCELLED) if e.identity == entry.identity else e
        for e in admitted_state.progression.entries
    )
    terminal_progression = dc_replace(admitted_state.progression, entries=terminal_entries)
    state_with_future_use = dc_replace(
        admitted_state,
        progression=terminal_progression,
        provenance=AdmissionProvenance(future_uses=(entry.identity,), outstanding_signals=()),
    )
    outcome = elide_admission_provenance(state_with_future_use, entry.identity)
    assert isinstance(outcome, Rejected)
    assert isinstance(outcome.reason, ProvenanceRetentionRequired)


def test_elide_provenance_of_terminal_entry_with_no_retention_erases() -> None:
    state = _state()
    submitted = admit_dynamic_request(_input(state, _request(1)))
    assert isinstance(submitted, Applied)
    admitted_state = submitted.value.admission_decision.state
    entry = admitted_state.progression.entries[0]
    from dataclasses import replace as dc_replace

    terminal_entries = tuple(
        dc_replace(e, phase=RequestPhase.CANCELLED) if e.identity == entry.identity else e
        for e in admitted_state.progression.entries
    )
    terminal_progression = dc_replace(admitted_state.progression, entries=terminal_entries)
    terminal_state = dc_replace(admitted_state, progression=terminal_progression)
    outcome = elide_admission_provenance(terminal_state, entry.identity)
    assert isinstance(outcome, Applied)
    _, witness = outcome.value
    assert isinstance(witness, Erased)
