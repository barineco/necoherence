# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

from necoherence import network_effect as ne
from necoherence.call import CallOk, Immediate, Request, immediate_of, io
from necoherence.request_progression import (
    ConfiguredSafetyLimit, ExecuteNow, ExecutionHandle, Permitted,
    RequestEffectClass, RequestFootprint, RequestIdentity, RequestInput,
    RequestPolicy, ResourceBudget, ResourceDemand, empty, submit,
)


def test_call_input_can_be_projected_into_progression_and_network_prepare() -> None:
    identity = RequestIdentity("call", "progression", 1)
    request = Request({"value": 7}, ("value",))
    call: Immediate[dict[str, int], int] = immediate_of(
        "network-input", ("value",), lambda payload: payload["value"]
    )
    called = io(call, request)
    assert isinstance(called, CallOk)
    assert called.value == 7
    footprint = RequestFootprint(("value",), (), RequestEffectClass.PURE)
    demand = ResourceDemand(1, 0, 0)
    permission = Permitted(identity, ())
    progression_input = RequestInput(identity, footprint, demand, permission)
    budget = ResourceBudget(
        ConfiguredSafetyLimit("pending", 2),
        ConfiguredSafetyLimit("in-flight", 2),
        ConfiguredSafetyLimit("concurrent", 2),
    )
    accepted = submit(empty(RequestPolicy.FIFO, budget), progression_input)
    assert accepted.__class__.__name__ == "SubmitAccepted"
    network_input = ne.AttemptInput(
        ne.AttemptIdentity(identity, 0),
        ne.HttpWireInstruction("POST", "http://example.test/", (), (7,)),
        None,
        ne.HostConfiguration(1, 8),
    )
    prepared = ne.prepare(ne.NetworkState(()), network_input)
    assert prepared.__class__.__name__ == "Prepared"


def test_forged_tokens_and_retry_do_not_dispatch_without_a_command() -> None:
    identity = RequestIdentity("network", "progression-counts", 1)
    input = ne.AttemptInput(
        ne.AttemptIdentity(identity, 0),
        ne.HttpWireInstruction("POST", "http://127.0.0.1/", (), ()),
        None,
        ne.HostConfiguration(0, 16),
    )
    prepared = ne.prepare(ne.NetworkState(()), input)
    assert isinstance(prepared, ne.Prepared)
    ledger_record_count = len(prepared.state.attempts)
    issued_command_count = 0
    peer_received_count = 0

    forged_input = ne.AttemptInput(
        input.attempt,
        ne.HttpWireInstruction("GET", input.instruction.target, (), ()),
        input.deadline,
        input.configuration,
    )
    forged = ne.send_command(
        prepared.state,
        ne.PreparedAttempt(forged_input, prepared.prepared.lineage),
    )
    assert isinstance(forged, ne.NetworkRejected)
    assert isinstance(forged.failure, ne.AttemptTokenMismatch)
    assert (issued_command_count, peer_received_count) == (0, 0)

    command = ne.send_command(prepared.state, prepared.prepared)
    assert isinstance(command, ne.CommandReady)
    handle = ExecutionHandle("progression-counts")
    started = ne.observe_start(
        command.state,
        prepared.prepared,
        ne.Started(input.attempt, handle),
    )
    assert isinstance(started, ne.NetworkStarted)
    forged_started = ne.cancel_command(
        started.state,
        ne.StartedAttempt(prepared.prepared, ExecutionHandle("forged")),
    )
    assert isinstance(forged_started, ne.NetworkRejected)
    assert isinstance(forged_started.failure, ne.HandleMismatch)
    unavailable_cancel = ne.cancel_command(started.state, started.started)
    assert isinstance(unavailable_cancel, ne.NetworkRejected)
    assert isinstance(
        unavailable_cancel.failure,
        ne.RequiredCapabilityUnavailable,
    )
    assert (issued_command_count, peer_received_count) == (0, 0)

    delivered = ne.DeliveredObservation(
        0,
        ne.ResponseObservation(
            input.attempt,
            handle,
            None,
            ne.RawHttpResponse(200, (), ()),
            ne.HeaderProvenance.LIBRARY_OBSERVED,
            ne.Unknown(ne.UnknownEffectReason.NO_RESPONSE),
        ),
    )
    settled = ne.observe(started.state, delivered)
    assert isinstance(settled, ne.NetworkTerminalResult)
    authorization = ne.RetryAuthorization(
        identity,
        input.attempt,
        ne.AttemptIdentity(identity, 1),
        ne.OpaqueEvidence("retry"),
    )
    request = ne.RetryRequest(
        ne.RetryAllowed(authorization),
        input.instruction,
        input.deadline,
        input.configuration,
    )
    retried = ne.retry(settled.state, request)
    assert isinstance(retried, ne.Prepared)
    assert len(retried.state.attempts) == ledger_record_count + 1
    assert (issued_command_count, peer_received_count) == (0, 0)
    reused = ne.retry(retried.state, request)
    assert isinstance(reused, ne.NetworkRejected)
    assert isinstance(reused.failure, ne.RetryNotPermitted)
    denied = ne.retry(
        settled.state,
        ne.RetryRequest(
            ne.RetryDenied(
                identity,
                input.attempt,
                ne.OpaqueEvidence("denied"),
            ),
            input.instruction,
            input.deadline,
            input.configuration,
        ),
    )
    assert isinstance(denied, ne.NetworkRejected)
    assert (issued_command_count, peer_received_count) == (0, 0)
