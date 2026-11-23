# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from hypothesis import given, settings, strategies as st

from necoherence import network_effect as ne
from necoherence.request_progression import ExecutionHandle, RequestIdentity

CONFIGURATION = ne.HostConfiguration(64, 64, ne.CancellationCapability(ne.OpaqueEvidence("cancel")), None)
INSTRUCTION = ne.HttpWireInstruction("GET", "http://127.0.0.1/invariant", (), b"")
UNKNOWN = ne.Unknown(ne.UnknownEffectReason.CANCELLATION)


def _attempt(logical: int, ordinal: int = 0) -> ne.AttemptIdentity:
    return ne.AttemptIdentity(RequestIdentity("net", "t", logical), ordinal)


def _input(logical: int, ordinal: int = 0) -> ne.AttemptInput:
    return ne.AttemptInput(_attempt(logical, ordinal), INSTRUCTION, None, CONFIGURATION)


def _delivery(record: ne.AttemptRecord, handle: ExecutionHandle, delivery: int) -> ne.DeliveredObservation:
    return ne.DeliveredObservation(
        delivery, ne.CancellationObservation(record.input.attempt, handle, None, UNKNOWN)
    )


def _witness(attempt: ne.AttemptIdentity) -> ne.EffectWitness:
    return ne.EffectWitness(attempt, ne.EffectWitnessSource.ADAPTER, ne.OpaqueEvidence("peer"))


def _then(function: Callable[..., Any], *arguments: Any) -> Callable[[ne.NetworkState], Any]:
    return lambda state: function(state, *arguments)


def _options(state: ne.NetworkState, fresh: int) -> list[Callable[[ne.NetworkState], Any]]:
    options: list[Callable[[ne.NetworkState], Any]] = [_then(ne.prepare, _input(fresh))]
    records = ne.network_attempts(state)
    latest = {record.input.attempt.logical: record.input.attempt.ordinal for record in records}
    for record in records:
        prepared = ne.PreparedAttempt(record.input, record.chain)
        attempt = record.input.attempt
        handle = ExecutionHandle(f"h-{attempt.logical.revision}-{attempt.ordinal}")
        disposition = record.disposition
        if isinstance(disposition, ne.PreparedDisposition):
            options.append(_then(ne.send_command, prepared))
        elif isinstance(disposition, ne.CommandIssued):
            options.append(_then(ne.observe_start, prepared, ne.Started(attempt, handle)))
            failure = ne.NetworkHostFailure(attempt, ne.HostStage.START, CONFIGURATION, ne.ExecutionStartFailed())
            options.append(_then(ne.observe_start, prepared, ne.StartFailed(failure, UNKNOWN)))
        elif isinstance(disposition, ne.StartedDisposition):
            options.append(_then(ne.observe, _delivery(record, disposition.handle, 0)))
            options.append(_then(ne.observe, ne.PendingObservation(attempt, disposition.handle)))
            options.append(_then(ne.cancel_command, ne.StartedAttempt(prepared, disposition.handle)))
        else:
            assert isinstance(disposition, ne.Settled)
            if disposition.handle is not None:
                next_delivery = 1 + len(record.late)
                options.append(_then(ne.observe, _delivery(record, disposition.handle, next_delivery)))
            options.append(
                _then(ne.annotate_effect, ne.EffectObservation(attempt, ne.NoEffect(_witness(attempt))))
            )
            if latest[attempt.logical] == attempt.ordinal:
                authorization = ne.RetryAuthorization(
                    attempt.logical, attempt, _attempt(attempt.logical.revision, attempt.ordinal + 1),
                    ne.OpaqueEvidence("retry"),
                )
                request = ne.RetryRequest(ne.RetryAllowed(authorization), INSTRUCTION, None, CONFIGURATION)
                options.append(_then(ne.retry, request))
    return options


@settings(max_examples=60, deadline=None)
@given(st.lists(st.integers(0, 10**6), min_size=1, max_size=40))
def test_generated_operation_sequences_keep_the_state_invariant(choices: list[int]) -> None:
    state = ne.empty_network_state()
    fresh = 0
    for choice in choices:
        options = _options(state, fresh)
        operation = options[choice % len(options)]
        rebuilt = ne.network_state_of(ne.network_attempts(state))
        assert rebuilt == state
        assert isinstance(rebuilt, ne.NetworkState)
        result = operation(state)
        assert operation(rebuilt) == result
        if isinstance(result, ne.Prepared) and result.prepared.input.attempt.ordinal == 0:
            fresh += 1
        state = result.state


def _record(
    logical: int,
    ordinal: int,
    chain: ne.AttemptChain,
    disposition: object | None = None,
) -> ne.AttemptRecord:
    return ne.AttemptRecord(
        _input(logical, ordinal), chain, ne.PreparedDisposition() if disposition is None else disposition, None, ()
    )


def _authorization(logical: int, parent: int, evidence: str = "retry") -> ne.RetryAuthorization:
    return ne.RetryAuthorization(
        _attempt(logical).logical, _attempt(logical, parent), _attempt(logical, parent + 1), ne.OpaqueEvidence(evidence)
    )


SETTLED = ne.Settled(None, ne.NetworkTerminal(ne.Cancelled(), UNKNOWN))


def test_construction_rejects_each_violated_condition() -> None:
    root = _record(1, 0, ne.Root(), SETTLED)
    retry_one = _record(1, 1, ne.RetryOf(_authorization(1, 0)), SETTLED)

    assert isinstance(ne.network_state_of([root, retry_one]), ne.NetworkState)
    assert ne.network_state_of([root, root]) == ne.DuplicateAttemptKey(root.input.attempt)
    assert ne.network_state_of([retry_one]) == ne.NonRootFirstAttempt(retry_one.input.attempt)
    assert ne.network_state_of([_record(1, 1, ne.Root(), SETTLED)]) == ne.NonRootFirstAttempt(_attempt(1, 1))
    gap = _record(1, 2, ne.RetryOf(ne.RetryAuthorization(
        _attempt(1).logical, _attempt(1, 0), _attempt(1, 2), ne.OpaqueEvidence("gap")
    )), SETTLED)
    assert ne.network_state_of([root, gap]) == ne.OrdinalGap(gap.input.attempt)
    unsettled_parent = _record(1, 0, ne.Root())
    assert ne.network_state_of([unsettled_parent, retry_one]) == ne.ChainMismatch(retry_one.input.attempt)
    delivered_on_prepared = ne.AttemptRecord(
        _input(3), ne.Root(), ne.PreparedDisposition(),
        ne.DeliveredObservation(0, ne.CancellationObservation(_attempt(3), ExecutionHandle("x"), None, UNKNOWN)), (),
    )
    assert ne.network_state_of([delivered_on_prepared]) == ne.DeliveryLogMismatch(_attempt(3))


def test_a_state_is_constructed_only_by_its_construction_functions() -> None:
    try:
        ne.NetworkState()
    except TypeError:
        return
    raise AssertionError("direct construction must be refused")
