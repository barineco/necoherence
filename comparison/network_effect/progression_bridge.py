# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Executable connection evidence for the Python public APIs."""

from __future__ import annotations

import argparse
from dataclasses import fields
import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
PYTHON_SRC = ROOT / "python" / "src"
if str(PYTHON_SRC) not in sys.path:
    sys.path.insert(0, str(PYTHON_SRC))


def _budget(maximum: int = 10):
    from necoherence.request_progression import ConfiguredSafetyLimit, ResourceBudget

    return ResourceBudget(
        ConfiguredSafetyLimit("pending", maximum),
        ConfiguredSafetyLimit("in_flight", maximum),
        ConfiguredSafetyLimit("concurrent", maximum),
    )


def _progression_request(identity):
    from necoherence.request_progression import (
        Permitted,
        RequestEffectClass,
        RequestFootprint,
        RequestInput,
        ResourceDemand,
    )

    return RequestInput(
        identity,
        RequestFootprint((), (), RequestEffectClass.PURE),
        ResourceDemand(1, 1, 1),
        Permitted(identity, ()),
    )


def _running_progression(identity, handle, *, policy):
    from necoherence.request_progression import (
        AppliedSignal,
        EvidenceVersion,
        Execute,
        ExecuteNow,
        Publishing,
        Started,
        SubmitAccepted,
        apply_start_observation,
        decide_start,
        empty,
        submit,
    )

    submitted = submit(empty(policy, _budget()), _progression_request(identity))
    if not isinstance(submitted, SubmitAccepted):
        raise RuntimeError(f"submit returned {type(submitted).__name__}")
    selection = ExecuteNow(
        identity,
        EvidenceVersion("bridge-selection", "generated", "comparison"),
        0,
    )
    decided = decide_start(submitted.snapshot, submitted.accepted, selection)
    if not isinstance(decided, Execute):
        raise RuntimeError(f"decide_start returned {type(decided).__name__}")
    started = apply_start_observation(
        decided.snapshot,
        decided.starting,
        AppliedSignal(Started(identity, handle)),
    )
    if not isinstance(started, Publishing):
        raise RuntimeError(f"apply_start_observation returned {type(started).__name__}")
    return submitted, decided, started


def _instruction_from_call(identity):
    from necoherence import network_effect as network
    from necoherence.call import CallOk, Request, deferred_of, immediate_of, io, issue

    encoder = immediate_of(
        "network.protocol.encoder",
        ("method", "target", "headers", "body"),
        lambda payload: network.HttpWireInstruction(
            payload["method"],
            payload["target"],
            payload["headers"],
            payload["body"],
        ),
    )
    protocol_input = Request(
        {
            "method": "POST",
            "target": "http://127.0.0.1/bridge",
            "headers": (network.RawHeaderField("x-bridge", tuple(b"typed")),),
            "body": (0, 128, 255),
        },
        ("method", "target", "headers", "body"),
    )
    encoded = io(encoder, protocol_input)
    if not isinstance(encoded, CallOk):
        raise RuntimeError(f"Call.io returned {type(encoded).__name__}")
    dispatcher = deferred_of(
        "network.dispatch",
        ("identity", "instruction"),
        lambda payload: (payload["identity"], payload["instruction"]),
    )
    issued = issue(
        dispatcher,
        Request(
            {"identity": identity, "instruction": encoded.value},
            ("identity", "instruction"),
        ),
    )
    if not isinstance(issued, CallOk):
        raise RuntimeError(f"Call.issue returned {type(issued).__name__}")
    return encoded, issued


def _network_input(identity, instruction, configuration, *, deadline=None):
    from necoherence import network_effect as network

    return network.AttemptInput(
        network.AttemptIdentity(identity, 0),
        instruction,
        deadline,
        configuration,
    )


def _started_network(state, input_value, handle):
    from necoherence import network_effect as network

    prepared = network.prepare(state, input_value)
    if not isinstance(prepared, network.Prepared):
        raise RuntimeError(f"prepare returned {type(prepared).__name__}")
    issued = network.send_command(prepared.state, prepared.prepared)
    if not isinstance(issued, network.CommandReady):
        raise RuntimeError(f"send_command returned {type(issued).__name__}")
    started = network.observe_start(
        issued.state,
        prepared.prepared,
        network.Started(input_value.attempt, handle),
    )
    if not isinstance(started, network.NetworkStarted):
        raise RuntimeError(f"observe_start returned {type(started).__name__}")
    return prepared, issued, started


def _settle_network(state, input_value, handle, kind: str):
    from necoherence import network_effect as network

    prepared, issued, started = _started_network(state, input_value, handle)
    unknown = network.Unknown(network.UnknownEffectReason.HOST_FAILURE)
    if kind == "response":
        adapter_observation = network.ResponseObservation(
            input_value.attempt,
            handle,
            7,
            network.RawHttpResponse(
                201,
                (network.RawHeaderField("x-result", tuple(b"typed")),),
                (1, 2, 3),
            ),
            network.HeaderProvenance.WIRE_OBSERVED,
            network.Unknown(network.UnknownEffectReason.NO_RESPONSE),
        )
    elif kind == "cancel":
        adapter_observation = network.CancellationObservation(
            input_value.attempt,
            handle,
            3,
            network.Unknown(network.UnknownEffectReason.CANCELLATION),
        )
    elif kind == "deadline":
        if input_value.deadline is None:
            raise RuntimeError("deadline input required")
        adapter_observation = network.DeadlineObservation(
            input_value.attempt,
            handle,
            5,
            input_value.deadline,
            network.MonotonicClockObservation(
                input_value.deadline.clock_basis,
                input_value.deadline.limit,
            ),
            network.Unknown(network.UnknownEffectReason.DEADLINE),
        )
    elif kind == "failure":
        failure = network.NetworkHostFailure(
            input_value.attempt,
            network.HostStage.RESPONSE_BODY,
            input_value.configuration,
            network.HostRuntimeFailure(),
        )
        adapter_observation = network.FailureObservation(
            input_value.attempt,
            handle,
            11,
            failure,
            unknown,
        )
    else:
        raise ValueError(f"unknown terminal kind: {kind}")
    settled = network.observe(
        started.state,
        network.DeliveredObservation(0, adapter_observation),
    )
    if not isinstance(settled, network.NetworkTerminalResult):
        raise RuntimeError(f"observe returned {type(settled).__name__}")
    return prepared, issued, started, settled


def _read_terminal(state, attempt):
    from necoherence import network_effect as network

    read = network.read_network_state(state)
    if not isinstance(read, network.Read):
        raise RuntimeError(f"read_network_state returned {type(read).__name__}")
    record = next(
        (candidate for candidate in read.state.attempts if candidate.input.attempt == attempt),
        None,
    )
    if record is None or not isinstance(record.disposition, network.Settled):
        raise RuntimeError("settled attempt absent from readNetworkState")
    return read, record.disposition.terminal


def _diagnostic(terminal) -> str:
    from necoherence import network_effect as network

    outcome = terminal.outcome
    if isinstance(outcome, network.Failed):
        return "/".join(
            (
                type(outcome).__name__,
                type(outcome.failure.cause).__name__,
                outcome.failure.stage.value,
            )
        )
    return type(outcome).__name__


def _dynamic_admission_evidence(identity) -> dict[str, Any]:
    from necoherence.core import Applied
    from necoherence.dynamic_admission import (
        AdmissionProvenance,
        CapacityObservation,
        DynamicAdmissionInput,
        DynamicAdmissionState,
        EnvironmentSpecification,
        Started as AdmissionStarted,
        admit_dynamic_request,
    )
    from necoherence.request_progression import (
        EvidenceVersion,
        Execute,
        ExecuteNow,
        RequestPolicy,
        empty,
    )

    configured = _budget(8)
    observed = _budget(5)
    provenance = AdmissionProvenance((identity,), ())
    state = DynamicAdmissionState(
        empty(RequestPolicy.FIFO, configured),
        configured,
        provenance,
    )
    selection = ExecuteNow(
        identity,
        EvidenceVersion("capacity-selection", "generated", "comparison"),
        0,
    )
    admission_input = DynamicAdmissionInput(
        state,
        _progression_request(identity),
        EnvironmentSpecification(4),
        CapacityObservation(observed, 10),
        12,
        selection,
    )
    outcome = admit_dynamic_request(admission_input)
    applied = isinstance(outcome, Applied)
    result = outcome.value if applied else None
    decision = result.admission_decision if result is not None else None
    return {
        "outcome": type(outcome).__name__,
        "decision": type(decision).__name__ if decision is not None else None,
        "effectiveBudget": (
            result.effective_budget.pending_maximum.maximum
            if result is not None
            else None
        ),
        "capacityObservationApplied": (
            result is not None and result.effective_budget == observed
        ),
        "provenanceExplicit": (
            result is not None
            and result.future_use_set.identities == provenance.future_uses
            and result.outstanding_signal_set.signals
            == provenance.outstanding_signals
        ),
        "adapterObservationIsAdmissionInput": any(
            field.name == "adapter_observation" for field in fields(DynamicAdmissionInput)
        ),
        "progressionExecuted": (
            isinstance(decision, AdmissionStarted)
            and isinstance(decision.result, Execute)
        ),
    }


def _failure_distinction(instruction) -> dict[str, Any]:
    from necoherence import network_effect as network
    from necoherence.request_progression import (
        AdapterFailed,
        CompletionAdapterFailure,
        ExecutionHandle,
        RequestIdentity,
        RequestPolicy,
        apply_completion_observation,
    )

    identities = (
        RequestIdentity("bridge-failure", "configuration-a", 1),
        RequestIdentity("bridge-failure", "configuration-b", 2),
    )
    configurations = (
        network.HostConfiguration(32, 64),
        network.HostConfiguration(96, 128),
    )
    state = network.NetworkState(())
    diagnostics: list[str] = []
    projections: list[object] = []
    terminals: list[object] = []
    for index, (identity, configuration) in enumerate(zip(identities, configurations)):
        handle = ExecutionHandle(f"bridge-failure-handle-{index}")
        _, _, progression = _running_progression(
            identity,
            handle,
            policy=RequestPolicy.FIFO,
        )
        input_value = _network_input(identity, instruction, configuration)
        _, _, _, settled = _settle_network(
            state,
            input_value,
            handle,
            "failure",
        )
        state = settled.state
        terminal = settled.settled.terminal
        diagnostic = _diagnostic(terminal)
        projected = apply_completion_observation(
            progression.snapshot,
            progression.running,
            AdapterFailed(
                CompletionAdapterFailure(identity, handle, diagnostic)
            ),
        )
        diagnostics.append(diagnostic)
        projections.append(projected)
        terminals.append(terminal)
    read = network.read_network_state(state)
    if not isinstance(read, network.Read):
        raise RuntimeError("failure state became unreadable")
    stored_failures = [
        record.disposition.terminal.outcome.failure
        for record in read.state.attempts
        if isinstance(record.disposition, network.Settled)
        and isinstance(record.disposition.terminal.outcome, network.Failed)
    ]
    same_closed_projection = (
        len(stored_failures) == 2
        and type(stored_failures[0].cause) is type(stored_failures[1].cause)
        and stored_failures[0].stage is stored_failures[1].stage
        and diagnostics[0] == diagnostics[1]
    )
    configurations_differ = (
        len(stored_failures) == 2
        and stored_failures[0].configuration
        != stored_failures[1].configuration
    )
    return {
        "projectionResults": [type(value).__name__ for value in projections],
        "diagnostics": diagnostics,
        "storedConfigurations": [
            {
                "requestBodyLimit": failure.configuration.request_body_limit,
                "responseBodyLimit": failure.configuration.response_body_limit,
            }
            for failure in stored_failures
        ],
        "sameOutcomeCauseStage": same_closed_projection,
        "differentConfigurations": configurations_differ,
        "distinguishableAfterProjection": (
            same_closed_projection
            and configurations_differ
            and len({failure.attempt for failure in stored_failures}) == 2
        ),
        "readNetworkState": type(read).__name__,
    }


def _latest_wins_evidence(instruction) -> dict[str, Any]:
    from necoherence import network_effect as network
    from necoherence.request_progression import (
        AdapterFailed,
        AppliedSignal,
        CancelledAtAdapter,
        Completed,
        CompletionAdapterFailure,
        ExecutionHandle,
        RequestIdentity,
        RequestPhase,
        RequestPolicy,
        SubmitAccepted,
        apply_completion_observation,
        submit,
    )

    results: dict[str, Any] = {}
    for index, kind in enumerate(("response", "cancel", "deadline")):
        old_identity = RequestIdentity("latest", kind, index)
        new_identity = RequestIdentity("latest", kind, index + 100)
        handle = ExecutionHandle(f"latest-{kind}")
        _, _, progression = _running_progression(
            old_identity,
            handle,
            policy=RequestPolicy.LATEST_WINS,
        )
        newer = submit(progression.snapshot, _progression_request(new_identity))
        if not isinstance(newer, SubmitAccepted):
            raise RuntimeError(f"latest submit returned {type(newer).__name__}")
        if kind == "deadline":
            basis = network.ClockBasis(f"latest-{kind}")
            capability = network.MonotonicClockCapability(
                network.OpaqueEvidence(f"latest-{kind}-clock"),
                basis,
            )
            deadline = network.Deadline(basis, 5, capability)
            configuration = network.HostConfiguration(
                32,
                64,
                None,
                capability,
            )
        else:
            deadline = None
            configuration = network.HostConfiguration(32, 64)
        input_value = _network_input(
            old_identity,
            instruction,
            configuration,
            deadline=deadline,
        )
        _, _, _, settled = _settle_network(
            network.NetworkState(()),
            input_value,
            handle,
            kind,
        )
        terminal = settled.settled.terminal
        if kind == "response":
            projection = AppliedSignal(Completed(old_identity, handle, terminal))
        elif kind == "cancel":
            projection = AppliedSignal(CancelledAtAdapter(old_identity, handle))
        else:
            projection = AdapterFailed(
                CompletionAdapterFailure(
                    old_identity,
                    handle,
                    _diagnostic(terminal),
                )
            )
        projected = apply_completion_observation(
            newer.snapshot,
            progression.running,
            projection,
        )
        new_entry = next(
            entry
            for entry in projected.snapshot.entries
            if entry.identity == new_identity
        )
        read, stored = _read_terminal(settled.state, input_value.attempt)
        results[kind] = {
            "projection": type(projected).__name__,
            "newRequestPhase": new_entry.phase.value,
            "newRequestPreserved": (
                projected.snapshot.current_identity == new_identity
                and new_entry.phase is RequestPhase.PENDING
            ),
            "networkTerminalPreserved": (
                stored == terminal
                and read.state == settled.state
            ),
        }
    return results


def run_bridge() -> dict[str, Any]:
    from necoherence import network_effect as network
    from necoherence.call import CallOk
    from necoherence.request_progression import (
        AppliedResult,
        AppliedSignal,
        Completed,
        ExecutionHandle,
        RequestIdentity,
        RequestPolicy,
        apply_completion_observation,
    )

    identity = RequestIdentity("bridge", "network", 0)
    encoded, issued_call = _instruction_from_call(identity)
    instruction = encoded.value
    handle = ExecutionHandle("bridge-response-handle")
    submitted, decided, progression = _running_progression(
        identity,
        handle,
        policy=RequestPolicy.FIFO,
    )
    input_value = _network_input(
        identity,
        instruction,
        network.HostConfiguration(256, 256),
    )
    prepared, command, started, settled = _settle_network(
        network.NetworkState(()),
        input_value,
        handle,
        "response",
    )
    read, stored_terminal = _read_terminal(
        settled.state,
        input_value.attempt,
    )
    projected = apply_completion_observation(
        progression.snapshot,
        progression.running,
        AppliedSignal(
            Completed(identity, handle, settled.settled.terminal)
        ),
    )
    dynamic = _dynamic_admission_evidence(
        RequestIdentity("bridge", "admission", 1)
    )
    failures = _failure_distinction(instruction)
    latest = _latest_wins_evidence(instruction)
    checks = {
        "callIoProducedInstruction": (
            isinstance(encoded, CallOk)
            and isinstance(encoded.value, network.HttpWireInstruction)
        ),
        "callIssueReceivedEncodedInstruction": (
            isinstance(issued_call, CallOk)
            and issued_call.value == (identity, encoded.value)
        ),
        "submitAndDecideStartConnected": (
            submitted.accepted.identity == identity
            and decided.starting.identity == identity
        ),
        "networkPreparedProgressionIdentity": (
            prepared.prepared.input.attempt.logical == identity
        ),
        "sendCommandPrecededObserveStart": (
            isinstance(command.state.attempts[0].disposition, network.CommandIssued)
            and started.started.handle == progression.running.handle
        ),
        "typedTerminalPersistedBeforeProjection": (
            stored_terminal == settled.settled.terminal
            and read.state == settled.state
        ),
        "projectionUsesReducerTerminal": (
            isinstance(projected, AppliedResult)
            and projected.value == settled.settled.terminal
        ),
        "dynamicCapacityObservationApplied": bool(
            dynamic["capacityObservationApplied"]
        ),
        "dynamicProvenanceExplicit": bool(dynamic["provenanceExplicit"]),
        "dynamicProgressionExecuted": bool(dynamic["progressionExecuted"]),
        "adapterObservationExcludedFromAdmissionInput": (
            dynamic["adapterObservationIsAdmissionInput"] is False
        ),
        "configurationsDistinguishedAfterProjection": bool(
            failures["distinguishableAfterProjection"]
        ),
        "latestWinsPreservesNewRequest": all(
            value["newRequestPreserved"] for value in latest.values()
        ),
        "latestWinsPreservesNetworkTerminal": all(
            value["networkTerminalPreserved"] for value in latest.values()
        ),
    }
    return {
        "result": "ProgressionBridge",
        "passed": all(checks.values()),
        "checks": checks,
        "call": {
            "io": type(encoded).__name__,
            "issue": type(issued_call).__name__,
            "instruction": {
                "method": instruction.method,
                "target": instruction.target,
                "headerCount": len(instruction.headers),
                "body": list(instruction.body),
            },
        },
        "progression": {
            "submit": type(submitted).__name__,
            "decideStart": type(decided).__name__,
            "applyStartObservation": type(progression).__name__,
            "networkPrepare": type(prepared).__name__,
            "sendCommand": type(command).__name__,
            "observeStart": type(started).__name__,
            "networkObserve": type(settled).__name__,
            "readNetworkState": type(read).__name__,
            "applyCompletionObservation": type(projected).__name__,
        },
        "dynamicAdmission": dynamic,
        "configurationDistinction": failures,
        "latestWins": latest,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--all", action="store_true")
    args = parser.parse_args()
    if not args.all:
        parser.error("use --all")
    result = run_bridge()
    print(json.dumps(result, sort_keys=True))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())


__all__ = ["run_bridge"]
