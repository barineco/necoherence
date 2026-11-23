# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from dataclasses import fields, is_dataclass
from enum import Enum

import necoherence.network_effect as ne


_TAGGED = {
    "DuplicateAttemptKey", "NonRootFirstAttempt", "OrdinalGap", "ChainMismatch",
    "RetryAuthorizationReuse", "DispositionEvidenceMismatch", "DeliveryLogMismatch",
    "Root", "RetryOf", "Unknown", "NoEffect", "EffectOccurred",
    "UnsupportedUriScheme", "InvalidHostConfiguration", "ExecutionStartFailed",
    "NameResolutionFailed", "ConnectionFailed", "RequestWriteFailed",
    "ResponseHeadersFailed", "ResponseBodyFailed", "ResponseBodyLimitExceeded",
    "MalformedResponse", "HeaderRepresentationUnavailable",
    "RequestHeaderEncodingUnavailable", "CancellationRejected",
    "DeadlineControlUnavailable", "Timeout", "HostRuntimeFailure", "HostClosed",
    "Response", "Failed", "Cancelled", "DeadlineExceeded",
    "ResponseObservation", "FailureObservation", "CancellationObservation",
    "DeadlineObservation",
}

_NAMES = {
    "clock_basis": "clockBasis", "request_body_limit": "requestBodyLimit",
    "response_body_limit": "responseBodyLimit", "monotonic_clock": "monotonicClock",
    "from_attempt": "from", "protocol_evidence": "protocolEvidence",
    "observed_at": "observedAt",
}

_PLAIN_ENUMS = (
    ne.AttemptCondition, ne.AttemptTokenField, ne.ObservationField, ne.CapabilityKind,
)


def _name(owner, value: str) -> str:
    if isinstance(owner, (ne.ResponseObservation, ne.FailureObservation,
                          ne.CancellationObservation, ne.DeadlineObservation)) and value == "source":
        return "sourceSequence"
    if isinstance(owner, ne.DeadlineObservation) and value == "clock":
        return "observedAt"
    return _NAMES.get(value, value)


def _value(value):
    if value is None or isinstance(value, (str, int, bool)):
        return value
    if isinstance(value, _PLAIN_ENUMS):
        return value.value
    if isinstance(value, Enum):
        return {"tag": value.value}
    if isinstance(value, (list, tuple)):
        return [_value(item) for item in value]
    if is_dataclass(value):
        members = {_name(value, field.name): _value(getattr(value, field.name)) for field in fields(value)}
        if value.__class__.__name__ in _TAGGED:
            return {"tag": value.__class__.__name__, **members}
        return members
    raise TypeError(type(value).__name__)


def network_failure_json(value: ne.NetworkFailure):
    members = {_name(value, field.name): _value(getattr(value, field.name)) for field in fields(value)}
    return {"tag": value.__class__.__name__, **members}
