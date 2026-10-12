# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Property and unit tests for request progression's split lifecycle."""

from __future__ import annotations

from hypothesis import given, strategies as st

from necoherence.request_progression import (
    Accepted, AppliedResult, AppliedSignal, CancelIssued, CancelRejected,
    CancelledWithoutAdapter, Completed, ConfiguredSafetyLimit, Deferred,
    DuplicateIdentity, Execute, ExecuteNow, ExecutionHandle, EvidenceVersion,
    MissingExecutionHandle, PendingLimitExceeded, Permitted, Publishing, RemainPending,
    RequestEffectClass, RequestFootprint, RequestIdentity, RequestInput,
    RequestPhase, RequestPolicy, ResourceBudget, ResourceDemand, Started,
    StartCommand, StartDecisionRejected, SubmitAccepted, SubmitRejected,
    SupersededResult, apply_completion_observation, apply_start_observation,
    decide_cancel, decide_start, derive_concurrent, derive_in_flight,
    derive_pending, empty, submit,
)


def _limit(resource: str, maximum: int) -> ConfiguredSafetyLimit:
    return ConfiguredSafetyLimit(resource, maximum)


def _budget(pending: int = 10, in_flight: int = 10, concurrent: int = 10) -> ResourceBudget:
    return ResourceBudget(_limit("p", pending), _limit("i", in_flight), _limit("c", concurrent))


def _identity(n: int) -> RequestIdentity:
    return RequestIdentity("k", str(n), 0)


def _footprint(effect: RequestEffectClass = RequestEffectClass.PURE) -> RequestFootprint:
    return RequestFootprint((), (), effect)


def _demand() -> ResourceDemand:
    return ResourceDemand(1, 1, 1)


def _request(n: int) -> RequestInput:
    identity = _identity(n)
    return RequestInput(identity, _footprint(), _demand(), Permitted(identity, ()))


def _selection(identity: RequestIdentity) -> ExecuteNow:
    return ExecuteNow(identity, EvidenceVersion("i", "d", "a"), 0)


def _executing_snapshot(n: int = 1) -> tuple[RequestIdentity, Execute]:
    submitted = submit(empty(RequestPolicy.FIFO, _budget()), _request(n))
    assert isinstance(submitted, SubmitAccepted)
    decided = decide_start(submitted.snapshot, submitted.accepted, _selection(_identity(n)))
    assert isinstance(decided, Execute)
    return _identity(n), decided


def test_empty_snapshot_has_no_entries() -> None:
    snapshot = empty(RequestPolicy.FIFO, _budget())
    assert snapshot.entries == ()
    assert snapshot.revision == 0


def test_submit_duplicate_identity_is_rejected() -> None:
    submitted = submit(empty(RequestPolicy.FIFO, _budget()), _request(1))
    assert isinstance(submitted, SubmitAccepted)
    duplicate = submit(submitted.snapshot, _request(1))
    assert isinstance(duplicate, SubmitRejected)
    assert isinstance(duplicate.failure, DuplicateIdentity)


def test_decide_start_unknown_request_rejects() -> None:
    result = decide_start(empty(RequestPolicy.FIFO, _budget()), Accepted(_identity(99)), _selection(_identity(99)))
    assert isinstance(result, StartDecisionRejected)


def test_decide_start_execute_sets_preparing_and_returns_command() -> None:
    identity, result = _executing_snapshot()
    assert result.snapshot.entries[0].phase is RequestPhase.PREPARING
    assert result.starting.identity == identity
    assert isinstance(result.command, StartCommand)
    assert result.starting.command == result.command


def test_remain_pending_defers_without_adapter_observation() -> None:
    submitted = submit(empty(RequestPolicy.FIFO, _budget()), _request(1))
    assert isinstance(submitted, SubmitAccepted)
    result = decide_start(submitted.snapshot, submitted.accepted, RemainPending(_identity(1), EvidenceVersion("i", "d", "a"), 0))
    assert isinstance(result, Deferred)
    assert result.snapshot.entries[0].phase is RequestPhase.PENDING


def test_apply_start_observation_moves_preparing_to_publishing() -> None:
    identity, decided = _executing_snapshot()
    result = apply_start_observation(decided.snapshot, decided.starting, AppliedSignal(Started(identity, ExecutionHandle("h"))))
    assert isinstance(result, Publishing)
    assert result.snapshot.entries[0].phase is RequestPhase.PUBLISHING
    assert result.running.handle == ExecutionHandle("h")


def test_apply_completion_observation_publishes_matching_completion() -> None:
    identity, decided = _executing_snapshot()
    started = apply_start_observation(decided.snapshot, decided.starting, AppliedSignal(Started(identity, ExecutionHandle("h"))))
    assert isinstance(started, Publishing)
    result = apply_completion_observation(started.snapshot, started.running, AppliedSignal(Completed(identity, ExecutionHandle("h"), "value")))
    assert isinstance(result, AppliedResult)
    assert result.value == "value"
    assert result.snapshot.entries[0].phase is RequestPhase.PUBLISHED


def test_latest_wins_stale_completion_is_superseded_without_newer_change() -> None:
    first = submit(empty(RequestPolicy.LATEST_WINS, _budget()), _request(1))
    assert isinstance(first, SubmitAccepted)
    decided = decide_start(first.snapshot, first.accepted, _selection(_identity(1)))
    assert isinstance(decided, Execute)
    started = apply_start_observation(decided.snapshot, decided.starting, AppliedSignal(Started(_identity(1), ExecutionHandle("h"))))
    assert isinstance(started, Publishing)
    later = submit(started.snapshot, _request(2))
    assert isinstance(later, SubmitAccepted)
    result = apply_completion_observation(later.snapshot, started.running, AppliedSignal(Completed(_identity(1), ExecutionHandle("h"), None)))
    assert isinstance(result, SupersededResult)
    assert result.snapshot.entries[0].phase is RequestPhase.SUPERSEDED
    assert result.snapshot.entries[1].phase is RequestPhase.PENDING


def test_decide_cancel_pending_cancels_without_adapter() -> None:
    submitted = submit(empty(RequestPolicy.FIFO, _budget()), _request(1))
    assert isinstance(submitted, SubmitAccepted)
    result = decide_cancel(submitted.snapshot, _identity(1))
    assert isinstance(result, CancelledWithoutAdapter)
    assert result.snapshot.entries[0].phase is RequestPhase.CANCELLED


def test_decide_cancel_publishing_returns_command_without_snapshot_change() -> None:
    identity, decided = _executing_snapshot()
    started = apply_start_observation(decided.snapshot, decided.starting, AppliedSignal(Started(identity, ExecutionHandle("h"))))
    assert isinstance(started, Publishing)
    result = decide_cancel(started.snapshot, identity)
    assert isinstance(result, CancelIssued)
    assert result.snapshot == started.snapshot


def test_decide_cancel_preparing_rejects_missing_handle() -> None:
    identity, decided = _executing_snapshot()
    result = decide_cancel(decided.snapshot, identity)
    assert isinstance(result, CancelRejected)
    assert isinstance(result.failure, MissingExecutionHandle)


@given(st.integers(min_value=0, max_value=5), st.integers(min_value=0, max_value=5))
def test_derive_totals_depend_only_on_entries_and_phase(n_pending: int, n_publishing: int) -> None:
    snapshot = empty(RequestPolicy.ALL_EXECUTE, _budget(100, 100, 100))
    for i in range(n_pending):
        result = submit(snapshot, _request(i))
        assert isinstance(result, SubmitAccepted)
        snapshot = result.snapshot
    for i in range(n_publishing):
        identity = _identity(1000 + i)
        result = submit(snapshot, _request(1000 + i))
        assert isinstance(result, SubmitAccepted)
        decided = decide_start(result.snapshot, result.accepted, _selection(identity))
        assert isinstance(decided, Execute)
        started = apply_start_observation(decided.snapshot, decided.starting, AppliedSignal(Started(identity, ExecutionHandle("h"))))
        assert isinstance(started, Publishing)
        snapshot = started.snapshot
    assert derive_pending(snapshot).pending == n_pending
    assert derive_concurrent(snapshot).concurrent == n_publishing
    assert derive_in_flight(snapshot).in_flight == n_publishing


@given(st.integers(min_value=0, max_value=64), st.integers(min_value=0, max_value=64))
def test_pending_limit_admits_demand_up_to_the_configured_maximum(maximum: int, demand: int) -> None:
    snapshot = empty(RequestPolicy.FIFO, _budget(pending=maximum))
    identity = _identity(0)
    result = submit(snapshot, RequestInput(identity, _footprint(), ResourceDemand(demand, 0, 0), Permitted(identity, ())))
    if demand <= maximum:
        assert isinstance(result, SubmitAccepted)
        assert derive_pending(result.snapshot).pending == demand
    else:
        assert isinstance(result, SubmitRejected)
        assert isinstance(result.failure, PendingLimitExceeded)
        assert result.snapshot == snapshot
