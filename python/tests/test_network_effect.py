# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

from necoherence import network_effect as ne
from necoherence.request_progression import ExecutionHandle, RequestIdentity


def _input(ordinal: int = 0) -> ne.AttemptInput:
    logical = RequestIdentity("network", "test", 1)
    key = ne.AttemptIdentity(logical, ordinal)
    instruction = ne.HttpWireInstruction(
        "POST",
        "http://127.0.0.1:1/test",
        (),
        (1, 255),
    )
    return ne.AttemptInput(key, instruction, None, ne.HostConfiguration(8, 8))


def test_root_command_start_response_and_read_are_typed() -> None:
    state = ne.NetworkState(())
    prepared = ne.prepare(state, _input())
    assert isinstance(prepared, ne.Prepared)
    assert isinstance(ne.read_network_state(prepared.state).state, ne.NetworkState)
    issued = ne.send_command(prepared.state, prepared.prepared)
    assert isinstance(issued, ne.CommandReady)
    handle = ExecutionHandle("test-handle")
    started = ne.observe_start(
        issued.state,
        prepared.prepared,
        ne.Started(prepared.prepared.input.attempt, handle),
    )
    assert isinstance(started, ne.NetworkStarted)
    response = ne.ResponseObservation(
        prepared.prepared.input.attempt,
        handle,
        0,
        ne.RawHttpResponse(200, (), (2, 3)),
        ne.HeaderProvenance.LIBRARY_NORMALIZED,
        ne.Unknown(ne.UnknownEffectReason.NO_RESPONSE),
    )
    settled = ne.observe(started.state, ne.DeliveredObservation(0, response))
    assert isinstance(settled, ne.NetworkTerminalResult)
    annotated = ne.annotate_effect(
        settled.state,
        ne.EffectObservation(
            prepared.prepared.input.attempt,
            ne.NoEffect(
                ne.EffectWitness(
                    prepared.prepared.input.attempt,
                    ne.EffectWitnessSource.ADAPTER,
                    ne.OpaqueEvidence("peer"),
                )
            ),
        ),
    )
    disposition = annotated.state.attempts[0].disposition
    assert isinstance(disposition, ne.Settled)
    assert disposition.terminal.effect.__class__ is ne.NoEffect


def test_invalid_instruction_rejects_without_state_change() -> None:
    state = ne.NetworkState(())
    invalid = ne.AttemptInput(
        _input().attempt,
        ne.HttpWireInstruction("GET BAD", _input().instruction.target, (), ()),
        None,
        ne.HostConfiguration(8, 8),
    )
    result = ne.prepare(state, invalid)
    assert isinstance(result, ne.NetworkRejected)
    assert result.state == state
    assert result.failure.__class__.__name__ == "InvalidWireInstruction"


def test_invalid_state_failure_reports_the_first_failed_check() -> None:
    input = _input()
    record = ne.AttemptRecord(input, ne.Root(), ne.PreparedDisposition(), None, ())
    state = ne.NetworkState((record, record))

    result = ne.read_network_state(state)

    assert isinstance(result, ne.NetworkRejected)
    assert result.failure == ne.InvalidNetworkState(
        ne.DuplicateAttemptKey(input.attempt)
    )


def test_operation_failures_follow_relation_precedence() -> None:
    initial = ne.NetworkState(())
    prepared = ne.prepare(initial, _input())
    assert isinstance(prepared, ne.Prepared)
    issued = ne.send_command(prepared.state, prepared.prepared)
    assert isinstance(issued, ne.CommandReady)

    repeated = ne.send_command(issued.state, prepared.prepared)
    assert isinstance(repeated, ne.NetworkRejected)
    assert repeated.failure == ne.CommandAlreadyIssued(
        prepared.prepared.input.attempt,
    )

    record = ne.AttemptRecord(
        _input(),
        ne.Root(),
        ne.PreparedDisposition(),
        None,
        (),
    )
    invalid_state = ne.NetworkState((record, record))
    cancelled = ne.cancel_command(
        invalid_state,
        ne.StartedAttempt(
            ne.PreparedAttempt(_input(), ne.Root()),
            ExecutionHandle("missing"),
        ),
    )
    assert isinstance(cancelled, ne.NetworkRejected)
    assert cancelled.failure == ne.InvalidNetworkState(
        ne.DuplicateAttemptKey(record.input.attempt)
    )


def test_state_and_token_failures_preserve_the_failed_check() -> None:
    input = _input()
    observation = ne.ResponseObservation(
        input.attempt,
        ExecutionHandle("unrecorded"),
        None,
        ne.RawHttpResponse(200, (), ()),
        ne.HeaderProvenance.WIRE_OBSERVED,
        ne.Unknown(ne.UnknownEffectReason.NO_RESPONSE),
    )
    invalid_record = ne.AttemptRecord(
        input,
        ne.Root(),
        ne.PreparedDisposition(),
        ne.DeliveredObservation(0, observation),
        (),
    )
    invalid_result = ne.read_network_state(ne.NetworkState((invalid_record,)))
    assert isinstance(invalid_result, ne.NetworkRejected)
    assert invalid_result.failure == ne.InvalidNetworkState(
        ne.DeliveryLogMismatch(input.attempt)
    )

    prepared = ne.prepare(ne.NetworkState(()), input)
    assert isinstance(prepared, ne.Prepared)
    forged_input = ne.AttemptInput(
        input.attempt,
        ne.HttpWireInstruction(
            "GET",
            input.instruction.target,
            input.instruction.headers,
            input.instruction.body,
        ),
        input.deadline,
        input.configuration,
    )
    forged = ne.PreparedAttempt(forged_input, prepared.prepared.lineage)
    forged_result = ne.send_command(prepared.state, forged)
    assert isinstance(forged_result, ne.NetworkRejected)
    assert forged_result.failure == ne.AttemptTokenMismatch(
        input.attempt,
        ne.AttemptTokenField.INSTRUCTION,
    )



def test_denied_retry_returns_the_canonical_failure() -> None:
    input = _input()
    request = ne.RetryRequest(
        ne.RetryDenied(
            input.attempt.logical,
            input.attempt,
            ne.OpaqueEvidence("denied"),
        ),
        input.instruction,
        input.deadline,
        input.configuration,
    )

    result = ne.retry(ne.NetworkState(()), request)

    assert isinstance(result, ne.NetworkRejected)
    assert result.failure == ne.RetryNotPermitted(input.attempt)


def _settled(logical: str, ordinal: int, lineage: ne.AttemptLineage) -> ne.AttemptRecord:
    key = ne.RequestIdentity("network", logical, 1)
    attempt = ne.AttemptIdentity(key, ordinal)
    instruction = ne.HttpWireInstruction("GET", "/", (), ())
    input = ne.AttemptInput(attempt, instruction, None, ne.HostConfiguration(8, 8))
    terminal = ne.NetworkTerminal(ne.Cancelled(), ne.Unknown(ne.UnknownEffectReason.NO_RESPONSE))
    return ne.AttemptRecord(input, lineage, ne.Settled(None, terminal), None, ())


def test_retry_authorization_from_a_different_logical_is_a_lineage_mismatch() -> None:
    logical_l = ne.RequestIdentity("network", "L", 1)
    logical_m = ne.RequestIdentity("network", "M", 1)
    l0 = _settled("L", 0, ne.Root())
    m0 = _settled("M", 0, ne.Root())
    m1 = _settled(
        "M",
        1,
        ne.RetryOf(ne.RetryAuthorization(
            logical_m,
            ne.AttemptIdentity(logical_m, 0),
            ne.AttemptIdentity(logical_m, 1),
            ne.OpaqueEvidence("ev"),
        )),
    )
    l2 = _settled(
        "L",
        2,
        ne.RetryOf(ne.RetryAuthorization(
            logical_l,
            ne.AttemptIdentity(logical_m, 1),
            ne.AttemptIdentity(logical_l, 2),
            ne.OpaqueEvidence("ev"),
        )),
    )

    result = ne.read_network_state(ne.NetworkState((l0, m0, m1, l2)))

    assert isinstance(result, ne.NetworkRejected)
    assert result.failure == ne.InvalidNetworkState(
        ne.LineageMismatch(l2.input.attempt)
    )
