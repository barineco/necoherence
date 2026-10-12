# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

import json
import sys

from necoherence import network_effect as ne
from necoherence.request_progression import ExecutionHandle, RequestIdentity

for _network_name in ne.__all__:
    globals()[_network_name] = getattr(ne, _network_name)
del _network_name


_HOST_FAILURE_TYPES = {
    failure_type.__name__: failure_type
    for failure_type in (
        UnsupportedUriScheme,
        InvalidHostConfiguration,
        ExecutionStartFailed,
        NameResolutionFailed,
        ConnectionFailed,
        RequestWriteFailed,
        ResponseHeadersFailed,
        ResponseBodyFailed,
        ResponseBodyLimitExceeded,
        MalformedResponse,
        HeaderRepresentationUnavailable,
        RequestHeaderEncodingUnavailable,
        CancellationRejected,
        DeadlineControlUnavailable,
        HostRuntimeFailure,
        HostClosed,
    )
}



def req(value: object, key: str) -> object:
    if not isinstance(value, dict) or key not in value:
        raise ValueError(f"{key}: missing field")
    return value[key]


def text(value: object, name: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{name}: expected string")
    return value


def natural(value: object, name: str) -> int:
    if type(value) is not int or value < 0:
        raise ValueError(f"{name}: expected natural number")
    return value


def array(value: object, name: str) -> list[object]:
    if not isinstance(value, list):
        raise ValueError(f"{name}: expected array")
    return value


def ident(value: object) -> RequestIdentity:
    return RequestIdentity(
        text(req(value, "kind"), "kind"),
        text(req(value, "provenance"), "provenance"),
        natural(req(value, "revision"), "revision"),
    )


def handle(value: object) -> ExecutionHandle:
    return ExecutionHandle(text(req(value, "value"), "value"))


def evidence(value: object) -> OpaqueEvidence:
    return OpaqueEvidence(text(req(value, "value"), "value"))


def basis(value: object) -> ClockBasis:
    return ClockBasis(text(req(value, "value"), "value"))


def attempt(value: object) -> AttemptIdentity:
    return AttemptIdentity(
        ident(req(value, "logical")),
        natural(req(value, "ordinal"), "ordinal"),
    )


def header(value: object) -> RawHeaderField:
    return RawHeaderField(
        text(req(value, "name"), "name"),
        tuple(natural(item, "header byte") for item in array(req(value, "value"), "value")),
    )


def instruction(value: object) -> HttpWireInstruction:
    return HttpWireInstruction(
        text(req(value, "method"), "method"),
        text(req(value, "target"), "target"),
        tuple(header(item) for item in array(req(value, "headers"), "headers")),
        tuple(natural(item, "body byte") for item in array(req(value, "body"), "body")),
    )


def response(value: object) -> RawHttpResponse:
    return RawHttpResponse(
        natural(req(value, "status"), "status"),
        tuple(header(item) for item in array(req(value, "headers"), "headers")),
        tuple(natural(item, "body byte") for item in array(req(value, "body"), "body")),
    )


def clock_observation(value: object) -> MonotonicClockObservation:
    return MonotonicClockObservation(
        basis(req(value, "clockBasis")),
        natural(req(value, "value"), "value"),
    )


def clock_capability(value: object) -> MonotonicClockCapability:
    return MonotonicClockCapability(
        evidence(req(value, "identity")),
        basis(req(value, "clockBasis")),
    )


def cancellation(value: object) -> CancellationCapability:
    return CancellationCapability(evidence(req(value, "identity")))


def deadline(value: object) -> Deadline:
    return Deadline(
        basis(req(value, "clockBasis")),
        natural(req(value, "limit"), "limit"),
        clock_capability(req(value, "capability")),
    )


def configuration(value: object) -> HostConfiguration:
    cancellation_value = req(value, "cancellation")
    clock_value = req(value, "monotonicClock")
    return HostConfiguration(
        natural(req(value, "requestBodyLimit"), "requestBodyLimit"),
        natural(req(value, "responseBodyLimit"), "responseBodyLimit"),
        None if cancellation_value is None else cancellation(cancellation_value),
        None if clock_value is None else clock_capability(clock_value),
    )


def input_value(value: object) -> AttemptInput:
    deadline_value = req(value, "deadline")
    return AttemptInput(
        attempt(req(value, "attempt")),
        instruction(req(value, "instruction")),
        None if deadline_value is None else deadline(deadline_value),
        configuration(req(value, "configuration")),
    )


def authorization(value: object) -> RetryAuthorization:
    return RetryAuthorization(
        ident(req(value, "logical")),
        attempt(req(value, "from")),
        attempt(req(value, "next")),
        evidence(req(value, "protocolEvidence")),
    )


def lineage(value: object) -> AttemptLineage:
    tag = text(req(value, "tag"), "AttemptLineage.tag")
    if tag == "Root":
        return Root()
    if tag == "RetryOf":
        return RetryOf(authorization(req(value, "authorization")))
    raise ValueError(f"AttemptLineage.tag: unknown value {tag}")


def prepared(value: object) -> PreparedAttempt:
    return PreparedAttempt(input_value(req(value, "input")), lineage(req(value, "lineage")))


def started(value: object) -> StartedAttempt:
    return StartedAttempt(prepared(req(value, "prepared")), handle(req(value, "handle")))


def effect_witness(value: object) -> EffectWitness:
    source = text(req(req(value, "source"), "tag"), "EffectWitnessSource.tag")
    return EffectWitness(
        attempt(req(value, "attempt")),
        EffectWitnessSource(source),
        evidence(req(value, "evidence")),
    )


def effect(value: object) -> EffectStatus:
    tag = text(req(value, "tag"), "EffectStatus.tag")
    if tag == "Unknown":
        reason = text(req(req(value, "reason"), "tag"), "UnknownEffectReason.tag")
        return Unknown(UnknownEffectReason(reason))
    if tag == "NoEffect":
        return NoEffect(effect_witness(req(value, "witness")))
    if tag == "EffectOccurred":
        return EffectOccurred(effect_witness(req(value, "witness")))
    raise ValueError(f"EffectStatus.tag: unknown value {tag}")


def host_stage(value: object) -> HostStage:
    return HostStage(text(req(value, "tag"), "HostStage.tag"))


def timeout_cause(value: object) -> HostTimeoutCause:
    return HostTimeoutCause(text(req(value, "tag"), "HostTimeoutCause.tag"))


def host_failure(value: object) -> HostFailure:
    tag = text(req(value, "tag"), "HostFailure.tag")
    if tag == "Timeout":
        return Timeout(host_stage(req(value, "stage")), timeout_cause(req(value, "cause")))
    failure_type = _HOST_FAILURE_TYPES.get(tag)
    if failure_type is None:
        raise ValueError(f"HostFailure.tag: unknown value {tag}")
    return failure_type()


def network_host_failure(value: object) -> NetworkHostFailure:
    return NetworkHostFailure(
        attempt(req(value, "attempt")),
        host_stage(req(value, "stage")),
        configuration(req(value, "configuration")),
        host_failure(req(value, "cause")),
    )


def outcome(value: object) -> ResponseOutcome:
    tag = text(req(value, "tag"), "NetworkOutcome.tag")
    if tag == "Response":
        provenance = text(req(req(value, "provenance"), "tag"), "HeaderProvenance.tag")
        return Response(response(req(value, "response")), HeaderProvenance(provenance))
    if tag == "Failed":
        return Failed(network_host_failure(req(value, "failure")))
    if tag == "Cancelled":
        return Cancelled()
    if tag == "DeadlineExceeded":
        return DeadlineExceeded(
            deadline(req(value, "deadline")),
            clock_observation(req(value, "observedAt")),
        )
    raise ValueError(f"NetworkOutcome.tag: unknown value {tag}")


def terminal(value: object) -> NetworkTerminal:
    return NetworkTerminal(outcome(req(value, "outcome")), effect(req(value, "effect")))


def adapter_observation(value: object) -> AdapterObservation:
    tag = text(req(value, "tag"), "AdapterObservation.tag")
    key = attempt(req(value, "attempt"))
    execution = handle(req(value, "handle"))
    source_value = req(value, "sourceSequence")
    source = None if source_value is None else natural(source_value, "sourceSequence")
    if tag == "ResponseObservation":
        provenance = text(req(req(value, "provenance"), "tag"), "HeaderProvenance.tag")
        return ResponseObservation(
            key,
            execution,
            source,
            response(req(value, "response")),
            HeaderProvenance(provenance),
            effect(req(value, "effect")),
        )
    if tag == "FailureObservation":
        return FailureObservation(
            key,
            execution,
            source,
            network_host_failure(req(value, "failure")),
            effect(req(value, "effect")),
        )
    if tag == "CancellationObservation":
        return CancellationObservation(key, execution, source, effect(req(value, "effect")))
    if tag == "DeadlineObservation":
        return DeadlineObservation(
            key,
            execution,
            source,
            deadline(req(value, "deadline")),
            clock_observation(req(value, "observedAt")),
            effect(req(value, "effect")),
        )
    raise ValueError(f"AdapterObservation.tag: unknown value {tag}")


def delivered(value: object) -> DeliveredObservation:
    return DeliveredObservation(
        natural(req(value, "delivery"), "delivery"),
        adapter_observation(req(value, "observation")),
    )


def disposition(value: object) -> object:
    tag = text(req(value, "tag"), "AttemptDisposition.tag")
    if tag == "Prepared":
        return PreparedDisposition()
    if tag == "CommandIssued":
        return CommandIssued()
    if tag == "Started":
        return StartedDisposition(handle(req(value, "handle")))
    if tag == "Settled":
        handle_value = req(value, "handle")
        return Settled(
            None if handle_value is None else handle(handle_value),
            terminal(req(value, "terminal")),
        )
    raise ValueError(f"AttemptDisposition.tag: unknown value {tag}")


def record(value: object) -> AttemptRecord:
    first = req(value, "firstDelivery")
    return AttemptRecord(
        input_value(req(value, "input")),
        lineage(req(value, "lineage")),
        disposition(req(value, "disposition")),
        None if first is None else delivered(first),
        tuple(
            LateObservation(delivered(req(item, "delivered")))
            for item in array(req(value, "late"), "late")
        ),
    )


def state(value: object) -> NetworkState:
    return NetworkState(tuple(record(item) for item in array(req(value, "attempts"), "attempts")))


def retry_permission(value: object) -> RetryPermission:
    tag = text(req(value, "tag"), "RetryPermission.tag")
    if tag == "RetryAllowed":
        return RetryAllowed(authorization(req(value, "authorization")))
    if tag == "RetryDenied":
        return RetryDenied(
            ident(req(value, "logical")),
            attempt(req(value, "parent")),
            evidence(req(value, "evidence")),
        )
    raise ValueError(f"RetryPermission.tag: unknown value {tag}")


def retry_request(value: object) -> RetryRequest:
    deadline_value = req(value, "deadline")
    return RetryRequest(
        retry_permission(req(value, "permission")),
        instruction(req(value, "instruction")),
        None if deadline_value is None else deadline(deadline_value),
        configuration(req(value, "configuration")),
    )


def start_observation(value: object) -> StartObservation:
    tag = text(req(value, "tag"), "StartObservation.tag")
    if tag == "Started":
        return Started(attempt(req(value, "attempt")), handle(req(value, "handle")))
    if tag == "StartFailed":
        return StartFailed(
            network_host_failure(req(value, "failure")),
            effect(req(value, "effect")),
        )
    raise ValueError(f"StartObservation.tag: unknown value {tag}")


def host_observation(value: object) -> HostObservation:
    tag = text(req(value, "tag"), "HostObservation.tag")
    if tag == "Pending":
        return PendingObservation(attempt(req(value, "attempt")), handle(req(value, "handle")))
    if tag == "Delivered":
        return delivered(value)
    raise ValueError(f"HostObservation.tag: unknown value {tag}")


def effect_observation(value: object) -> EffectObservation:
    return EffectObservation(attempt(req(value, "attempt")), effect(req(value, "status")))


def enc(v: object) -> object:
    if isinstance(v, RequestIdentity): return {"kind": v.kind, "provenance": v.provenance, "revision": v.revision}
    if isinstance(v, ExecutionHandle): return {"value": v.value}
    if isinstance(v, OpaqueEvidence): return {"value": v.value}
    if isinstance(v, ClockBasis): return {"value": v.value}
    if isinstance(v, AttemptIdentity): return {"logical": enc(v.logical), "ordinal": v.ordinal}
    if isinstance(v, RawHeaderField): return {"name": v.name, "value": list(v.value)}
    if isinstance(v, HttpWireInstruction): return {"method": v.method, "target": v.target, "headers": [enc(x) for x in v.headers], "body": list(v.body)}
    if isinstance(v, RawHttpResponse): return {"status": v.status, "headers": [enc(x) for x in v.headers], "body": list(v.body)}
    if isinstance(v, MonotonicClockObservation): return {"clockBasis": enc(v.clock_basis), "value": v.value}
    if isinstance(v, MonotonicClockCapability): return {"identity": enc(v.identity), "clockBasis": enc(v.clock_basis)}
    if isinstance(v, CancellationCapability): return {"identity": enc(v.identity)}
    if isinstance(v, Deadline): return {"clockBasis": enc(v.clock_basis), "limit": v.limit, "capability": enc(v.capability)}
    if isinstance(v, HostConfiguration): return {"requestBodyLimit": v.request_body_limit, "responseBodyLimit": v.response_body_limit, "cancellation": enc(v.cancellation), "monotonicClock": enc(v.monotonic_clock)}
    if isinstance(v, AttemptInput): return {"attempt": enc(v.attempt), "instruction": enc(v.instruction), "deadline": enc(v.deadline), "configuration": enc(v.configuration)}
    if isinstance(v, RetryAuthorization): return {"logical": enc(v.logical), "from": enc(v.from_attempt), "next": enc(v.next), "protocolEvidence": enc(v.protocol_evidence)}
    if isinstance(v, Root): return {"tag": "Root"}
    if isinstance(v, RetryOf): return {"tag": "RetryOf", "authorization": enc(v.authorization)}
    if isinstance(v, PreparedAttempt): return {"input": enc(v.input), "lineage": enc(v.lineage)}
    if isinstance(v, StartedAttempt): return {"prepared": enc(v.prepared), "handle": enc(v.handle)}
    if isinstance(v, EffectWitnessSource): return {"tag": v.value}
    if isinstance(v, EffectWitness): return {"attempt": enc(v.attempt), "source": enc(v.source), "evidence": enc(v.evidence)}
    if isinstance(v, UnknownEffectReason): return {"tag": v.value}
    if isinstance(v, (Unknown, NoEffect, EffectOccurred)):
        tag = type(v).__name__; return {"tag": tag, ("reason" if isinstance(v, Unknown) else "witness"): enc(v.reason if isinstance(v, Unknown) else v.witness)}
    if isinstance(v, NetworkHostFailure): return {"attempt": enc(v.attempt), "stage": enc(v.stage), "configuration": enc(v.configuration), "cause": enc(v.cause)}
    if isinstance(v, HostStage | HostTimeoutCause | HeaderProvenance | EffectWitnessSource): return {"tag": v.value}
    if isinstance(v, Timeout): return {"tag": "Timeout", "stage": enc(v.stage), "cause": enc(v.cause)}
    if isinstance(v, HostFailure): return {"tag": type(v).__name__}
    if isinstance(v, Response): return {"tag": "Response", "response": enc(v.response), "provenance": enc(v.provenance)}
    if isinstance(v, Failed): return {"tag": "Failed", "failure": enc(v.failure)}
    if isinstance(v, Cancelled): return {"tag": "Cancelled"}
    if isinstance(v, DeadlineExceeded): return {"tag": "DeadlineExceeded", "deadline": enc(v.deadline), "observedAt": enc(v.observed_at)}
    if isinstance(v, NetworkTerminal): return {"outcome": enc(v.outcome), "effect": enc(v.effect)}
    if isinstance(v, PreparedDisposition): return {"tag": "Prepared"}
    if isinstance(v, CommandIssued): return {"tag": "CommandIssued"}
    if isinstance(v, StartedDisposition): return {"tag": "Started", "handle": enc(v.handle)}
    if isinstance(v, Settled): return {"tag": "Settled", "handle": enc(v.handle), "terminal": enc(v.terminal)}
    if isinstance(v, DeliveredObservation): return {"delivery": v.delivery, "observation": enc(v.observation)}
    if isinstance(v, LateObservation): return {"delivered": enc(v.delivered)}
    if isinstance(v, AttemptRecord): return {"input": enc(v.input), "lineage": enc(v.lineage), "disposition": enc(v.disposition), "firstDelivery": enc(v.first_delivery), "late": [enc(x) for x in v.late]}
    if isinstance(v, NetworkState): return {"attempts": [enc(x) for x in v.attempts]}
    if isinstance(v, RetryAllowed): return {"tag": "RetryAllowed", "authorization": enc(v.authorization)}
    if isinstance(v, RetryDenied): return {"tag": "RetryDenied", "logical": enc(v.logical), "parent": enc(v.attempt), "evidence": enc(v.evidence)}
    if isinstance(v, RetryRequest): return {"permission": enc(v.permission), "instruction": enc(v.instruction), "deadline": enc(v.deadline), "configuration": enc(v.configuration)}
    if isinstance(v, (ResponseObservation, FailureObservation, CancellationObservation, DeadlineObservation)):
        out = {"tag": type(v).__name__, "attempt": enc(v.attempt), "handle": enc(v.handle), "sourceSequence": v.source, "effect": enc(v.effect)}
        if isinstance(v, ResponseObservation): out.update(response=enc(v.response), provenance=enc(v.provenance))
        elif isinstance(v, FailureObservation): out["failure"] = enc(v.failure)
        elif isinstance(v, DeadlineObservation): out.update(deadline=enc(v.deadline), observedAt=enc(v.clock))
        return out
    if isinstance(v, StartFailed): return {"tag": "StartFailed", "failure": enc(v.failure), "effect": enc(v.effect)}
    if isinstance(v, Started): return {"tag": "Started", "attempt": enc(v.attempt), "handle": enc(v.handle)}
    if isinstance(v, PendingObservation): return {"tag": "Pending", "attempt": enc(v.attempt), "handle": enc(v.handle)}
    if isinstance(v, EffectObservation): return {"attempt": enc(v.attempt), "status": enc(v.status)}
    if isinstance(v, SettledAttempt): return {"prepared": enc(v.prepared), "handle": enc(v.handle), "terminal": enc(v.terminal)}
    if isinstance(v, (NetworkStarted, NetworkPending)): return {"result": type(v).__name__.replace("Network", ""), "state": enc(v.state), "started": enc(v.started)}
    if isinstance(v, NetworkTerminalResult): return {"result": "Terminal", "state": enc(v.state), "settled": enc(v.settled)}
    if isinstance(v, NetworkLate): return {"result": "Late", "state": enc(v.state), "settled": enc(v.settled), "late": enc(v.late)}
    if isinstance(v, Duplicate): return {"result": "Duplicate", "state": enc(v.state), "attempt": enc(v.attempt), "delivery": v.delivery}
    if isinstance(v, Read): return {"result": "Read", "state": enc(v.state)}
    if isinstance(v, Prepared): return {"result": "Prepared", "state": enc(v.state), "prepared": enc(v.prepared)}
    if isinstance(v, CommandReady): return {"result": "CommandReady", "state": enc(v.state), "command": enc(v.command)}
    if isinstance(v, SendCommand): return {"prepared": enc(v.prepared)}
    if isinstance(v, CancelCommand): return {"attempt": enc(v.attempt), "handle": enc(v.handle), "capability": enc(v.capability)}
    if isinstance(v, Applied): return {"result": "Applied", "state": enc(v.state)}
    if isinstance(v, NetworkRejected): return {"result": "Rejected", "state": enc(v.state), "failure": enc(v.failure)}
    if isinstance(v, InvalidWireInstruction): return {"tag": "InvalidWireInstruction", "method": v.method}
    if isinstance(v, InvalidDeadline): return {"tag": "InvalidDeadline"}
    if isinstance(v, InvalidNetworkState): return {"tag": "InvalidNetworkState", "violation": enc(v.violation)}
    if isinstance(v, (RootAttemptRequired, DuplicateAttempt, UnknownAttempt, CommandAlreadyIssued, RetryNotPermitted, RetryParentNotSettled, EffectWitnessMissing, EffectKnowledgeConflict)):
        return {"tag": type(v).__name__, "attempt": enc(v.attempt)}
    if isinstance(v, AttemptConditionMismatch):
        return {"tag": "AttemptConditionMismatch", "attempt": enc(v.attempt), "expected": enc(v.expected), "actual": enc(v.actual)}
    if isinstance(v, AttemptTokenMismatch):
        return {"tag": "AttemptTokenMismatch", "attempt": enc(v.attempt), "field": enc(v.field)}
    if isinstance(v, ObservationRelationMismatch):
        return {"tag": "ObservationRelationMismatch", "attempt": enc(v.attempt), "field": enc(v.field)}
    if isinstance(v, RequiredCapabilityUnavailable):
        return {"tag": "RequiredCapabilityUnavailable", "attempt": enc(v.attempt), "capability": enc(v.capability)}
    if isinstance(v, (IdentityMismatch, HandleMismatch, ClockBasisMismatch, RetryIdentityMismatch, RetryParentMismatch, RetryOrderViolation)):
        return {"tag": type(v).__name__, "expected": enc(v.expected), "actual": enc(v.actual)}
    if isinstance(v, DeadlineNotReached):
        return {"tag": "DeadlineNotReached", "deadline": enc(v.deadline), "observedAt": enc(v.observed_at)}
    if isinstance(v, DeliveryOrderViolation):
        return {"tag": "DeliveryOrderViolation", "attempt": enc(v.attempt), "expected": v.expected, "actual": v.actual}
    if isinstance(v, ConflictingDelivery):
        return {"tag": "ConflictingDelivery", "attempt": enc(v.attempt), "delivery": v.delivery, "old": enc(v.old), "fresh": enc(v.fresh)}
    if isinstance(v, MalformedAdapterObservation): return {"tag": "MalformedAdapterObservation"}
    if isinstance(v, Host): return {"tag": "Host", "failure": enc(v.failure)}
    if isinstance(v, RetryAuthorizationAlreadyUsed):
        return {"tag": "RetryAuthorizationAlreadyUsed", "authorization": enc(v.authorization)}
    if isinstance(v, RetryAuthorizationReuse):
        return {"tag": "RetryAuthorizationReuse", "authorization": enc(v.authorization)}
    if isinstance(v, (DuplicateAttemptKey, NonRootFirstAttempt, OrdinalGap, LineageMismatch, DispositionEvidenceMismatch, DeliveryLogMismatch)):
        return {"tag": type(v).__name__, "attempt": enc(v.attempt)}
    if isinstance(v, (AttemptCondition, AttemptTokenField, ObservationField, CapabilityKind)): return v.value
    if v is None: return None
    if isinstance(v, tuple): return [enc(x) for x in v]
    return v


def run(value: object) -> object:
    op = text(req(value, "operation"), "operation")
    s = state(req(value, "state"))
    if op == "readNetworkState": return read_network_state(s)
    if op == "prepare": return prepare(s, input_value(req(value, "input")))
    if op == "sendCommand": return send_command(s, prepared(req(value, "prepared")))
    if op == "cancelCommand": return cancel_command(s, started(req(value, "started")))
    if op == "observeStart": return observe_start(s, prepared(req(value, "prepared")), start_observation(req(value, "observation")))
    if op == "observe": return observe(s, host_observation(req(value, "observation")))
    if op == "annotateEffect": return annotate_effect(s, effect_observation(req(value, "effect")))
    if op == "retry": return retry(s, retry_request(req(value, "request")))
    raise ValueError(f"operation: unknown value {op}")

def _desurrogate(value: object) -> object:
    if isinstance(value, str):
        return "".join(
            "\ufffd" if 0xD800 <= ord(character) <= 0xDFFF else character
            for character in value
        )
    if isinstance(value, list):
        return [_desurrogate(item) for item in value]
    if isinstance(value, dict):
        return {key: _desurrogate(item) for key, item in value.items()}
    return value

def main() -> None:
    for line in sys.stdin:
        try:
            value = _desurrogate(json.loads(line))
            output = json.dumps(
                enc(run(value)),
                separators=(",", ":"),
                sort_keys=True,
            )
        except Exception as error:
            output = json.dumps(
                {"result": "InvalidInvocation", "error": str(error)},
                separators=(",", ":"),
                sort_keys=True,
            )
        sys.stdout.write(output + "\n")

if __name__ == "__main__": main()
