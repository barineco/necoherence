# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Pure finite network-effect ledger and its eight state operations."""
from __future__ import annotations

from dataclasses import dataclass, replace
from enum import Enum
from typing import TypeAlias

from necoherence.request_progression import ExecutionHandle, RequestIdentity

ByteString: TypeAlias = tuple[int, ...]

@dataclass(frozen=True, slots=True)
class RawHeaderField:
    name: str
    value: ByteString

@dataclass(frozen=True, slots=True)
class HttpWireInstruction:
    method: str
    target: str
    headers: tuple[RawHeaderField, ...]
    body: ByteString
    def __post_init__(self) -> None:
        object.__setattr__(self, "headers", tuple(self.headers))
        object.__setattr__(self, "body", tuple(self.body))

@dataclass(frozen=True, slots=True)
class RawHttpResponse:
    status: int
    headers: tuple[RawHeaderField, ...]
    body: ByteString
    def __post_init__(self) -> None:
        object.__setattr__(self, "headers", tuple(self.headers))
        object.__setattr__(self, "body", tuple(self.body))

class HeaderProvenance(Enum):
    WIRE_OBSERVED = "WireObserved"
    LIBRARY_OBSERVED = "LibraryObserved"
    LIBRARY_NORMALIZED = "LibraryNormalized"
    WireObserved = "WireObserved"
    LibraryObserved = "LibraryObserved"
    LibraryNormalized = "LibraryNormalized"

@dataclass(frozen=True, slots=True)
class AttemptIdentity:
    logical: RequestIdentity
    ordinal: int

@dataclass(frozen=True, slots=True)
class OpaqueEvidence:
    value: str

@dataclass(frozen=True, slots=True)
class ClockBasis:
    value: str

@dataclass(frozen=True, slots=True)
class MonotonicClockObservation:
    clock_basis: ClockBasis
    value: int
    @property
    def clockBasis(self) -> ClockBasis: return self.clock_basis

@dataclass(frozen=True, slots=True)
class MonotonicClockCapability:
    identity: OpaqueEvidence
    clock_basis: ClockBasis
    @property
    def clockBasis(self) -> ClockBasis: return self.clock_basis

@dataclass(frozen=True, slots=True)
class CancellationCapability:
    identity: OpaqueEvidence

@dataclass(frozen=True, slots=True)
class Deadline:
    clock_basis: ClockBasis
    limit: int
    capability: MonotonicClockCapability
    @property
    def clockBasis(self) -> ClockBasis: return self.clock_basis

@dataclass(frozen=True, slots=True)
class HostConfiguration:
    request_body_limit: int
    response_body_limit: int
    cancellation: CancellationCapability | None = None
    monotonic_clock: MonotonicClockCapability | None = None
    @property
    def requestBodyLimit(self) -> int: return self.request_body_limit
    @property
    def responseBodyLimit(self) -> int: return self.response_body_limit
    @property
    def monotonicClock(self) -> MonotonicClockCapability | None: return self.monotonic_clock

@dataclass(frozen=True, slots=True)
class AttemptInput:
    attempt: AttemptIdentity
    instruction: HttpWireInstruction
    deadline: Deadline | None
    configuration: HostConfiguration

@dataclass(frozen=True, slots=True)
class RetryAuthorization:
    logical: RequestIdentity
    from_attempt: AttemptIdentity
    next: AttemptIdentity
    protocol_evidence: OpaqueEvidence
    @property
    def from_(self) -> AttemptIdentity: return self.from_attempt
    @property
    def protocolEvidence(self) -> OpaqueEvidence: return self.protocol_evidence

@dataclass(frozen=True, slots=True)
class Root: pass
@dataclass(frozen=True, slots=True)
class RetryOf:
    authorization: RetryAuthorization
AttemptLineage: TypeAlias = Root | RetryOf

@dataclass(frozen=True, slots=True)
class PreparedAttempt:
    input: AttemptInput
    lineage: AttemptLineage
@dataclass(frozen=True, slots=True)
class StartedAttempt:
    prepared: PreparedAttempt
    handle: ExecutionHandle
@dataclass(frozen=True, slots=True)
class SendCommand:
    prepared: PreparedAttempt
@dataclass(frozen=True, slots=True)
class CancelCommand:
    attempt: AttemptIdentity
    handle: ExecutionHandle
    capability: CancellationCapability

class EffectWitnessSource(Enum):
    ADAPTER = "Adapter"
    PROTOCOL = "Protocol"
    Adapter = "Adapter"
    Protocol = "Protocol"
@dataclass(frozen=True, slots=True)
class EffectWitness:
    attempt: AttemptIdentity
    source: EffectWitnessSource
    evidence: OpaqueEvidence
class UnknownEffectReason(Enum):
    NO_RESPONSE = "NoResponse"
    CANCELLATION = "Cancellation"
    DEADLINE = "Deadline"
    HOST_FAILURE = "HostFailure"
    PROTOCOL_WITNESS_MISSING = "ProtocolWitnessMissing"
    LATE_SIGNAL = "LateSignal"
    NoResponse = "NoResponse"
    Cancellation = "Cancellation"
    Deadline = "Deadline"
    HostFailure = "HostFailure"
    ProtocolWitnessMissing = "ProtocolWitnessMissing"
    LateSignal = "LateSignal"
@dataclass(frozen=True, slots=True)
class Unknown:
    reason: UnknownEffectReason
@dataclass(frozen=True, slots=True)
class NoEffect:
    witness: EffectWitness
@dataclass(frozen=True, slots=True)
class EffectOccurred:
    witness: EffectWitness
EffectStatus: TypeAlias = Unknown | NoEffect | EffectOccurred
@dataclass(frozen=True, slots=True)
class EffectObservation:
    attempt: AttemptIdentity
    status: EffectStatus

class HostStage(Enum):
    START = "Start"
    REQUEST_WRITE = "RequestWrite"
    RESPONSE_HEADERS = "ResponseHeaders"
    RESPONSE_BODY = "ResponseBody"
    CANCEL = "Cancel"
    DEADLINE = "Deadline"
    Start = "Start"
    RequestWrite = "RequestWrite"
    ResponseHeaders = "ResponseHeaders"
    ResponseBody = "ResponseBody"
    Cancel = "Cancel"
    Deadline = "Deadline"
class HostTimeoutCause(Enum):
    LIBRARY_REPORTED = "LibraryReported"
    SOCKET_REPORTED = "SocketReported"
    POOL_ACQUISITION = "PoolAcquisition"
    HOST_OPERATION = "HostOperation"
    LibraryReported = "LibraryReported"
    SocketReported = "SocketReported"
    PoolAcquisition = "PoolAcquisition"
    HostOperation = "HostOperation"
class HostFailure: pass
@dataclass(frozen=True, slots=True)
class UnsupportedUriScheme(HostFailure): pass
@dataclass(frozen=True, slots=True)
class InvalidHostConfiguration(HostFailure): pass
@dataclass(frozen=True, slots=True)
class ExecutionStartFailed(HostFailure): pass
@dataclass(frozen=True, slots=True)
class NameResolutionFailed(HostFailure): pass
@dataclass(frozen=True, slots=True)
class ConnectionFailed(HostFailure): pass
@dataclass(frozen=True, slots=True)
class RequestWriteFailed(HostFailure): pass
@dataclass(frozen=True, slots=True)
class ResponseHeadersFailed(HostFailure): pass
@dataclass(frozen=True, slots=True)
class ResponseBodyFailed(HostFailure): pass
@dataclass(frozen=True, slots=True)
class ResponseBodyLimitExceeded(HostFailure): pass
@dataclass(frozen=True, slots=True)
class MalformedResponse(HostFailure): pass
@dataclass(frozen=True, slots=True)
class HeaderRepresentationUnavailable(HostFailure): pass
@dataclass(frozen=True, slots=True)
class RequestHeaderEncodingUnavailable(HostFailure): pass
@dataclass(frozen=True, slots=True)
class CancellationRejected(HostFailure): pass
@dataclass(frozen=True, slots=True)
class DeadlineControlUnavailable(HostFailure): pass
@dataclass(frozen=True, slots=True)
class Timeout(HostFailure):
    stage: HostStage
    cause: HostTimeoutCause
@dataclass(frozen=True, slots=True)
class HostRuntimeFailure(HostFailure): pass
@dataclass(frozen=True, slots=True)
class HostClosed(HostFailure): pass
@dataclass(frozen=True, slots=True)
class NetworkHostFailure:
    attempt: AttemptIdentity
    stage: HostStage
    configuration: HostConfiguration
    cause: HostFailure

class ResponseOutcome: pass
@dataclass(frozen=True, slots=True)
class Response(ResponseOutcome):
    response: RawHttpResponse
    provenance: HeaderProvenance
@dataclass(frozen=True, slots=True)
class Failed(ResponseOutcome):
    failure: NetworkHostFailure
@dataclass(frozen=True, slots=True)
class Cancelled(ResponseOutcome): pass
@dataclass(frozen=True, slots=True)
class DeadlineExceeded(ResponseOutcome):
    deadline: Deadline
    observed_at: MonotonicClockObservation
@dataclass(frozen=True, slots=True)
class NetworkTerminal:
    outcome: ResponseOutcome
    effect: EffectStatus

@dataclass(frozen=True, slots=True)
class PreparedDisposition: pass
@dataclass(frozen=True, slots=True)
class CommandIssued: pass
@dataclass(frozen=True, slots=True)
class StartedDisposition:
    handle: ExecutionHandle
@dataclass(frozen=True, slots=True)
class Settled:
    handle: ExecutionHandle | None
    terminal: NetworkTerminal
@dataclass(frozen=True, slots=True)
class AttemptRecord:
    input: AttemptInput
    lineage: AttemptLineage
    disposition: object
    first_delivery: DeliveredObservation | None
    late: tuple[LateObservation, ...]
    def __post_init__(self) -> None: object.__setattr__(self, "late", tuple(self.late))
    @property
    def firstDelivery(self) -> DeliveredObservation | None: return self.first_delivery
@dataclass(frozen=True, slots=True)
class NetworkState:
    attempts: tuple[AttemptRecord, ...]
    def __post_init__(self) -> None: object.__setattr__(self, "attempts", tuple(self.attempts))

@dataclass(frozen=True, slots=True)
class RetryAllowed:
    authorization: RetryAuthorization
@dataclass(frozen=True, slots=True)
class RetryDenied:
    logical: RequestIdentity
    attempt: AttemptIdentity
    evidence: OpaqueEvidence
RetryPermission: TypeAlias = RetryAllowed | RetryDenied
@dataclass(frozen=True, slots=True)
class RetryRequest:
    permission: RetryPermission
    instruction: HttpWireInstruction
    deadline: Deadline | None
    configuration: HostConfiguration

class StartObservation: pass
@dataclass(frozen=True, slots=True)
class Started(StartObservation):
    attempt: AttemptIdentity
    handle: ExecutionHandle
@dataclass(frozen=True, slots=True)
class StartFailed(StartObservation):
    failure: NetworkHostFailure
    effect: EffectStatus
@dataclass(frozen=True, slots=True)
class PendingObservation:
    attempt: AttemptIdentity
    handle: ExecutionHandle
@dataclass(frozen=True, slots=True)
class ResponseObservation:
    attempt: AttemptIdentity
    handle: ExecutionHandle
    source: int | None
    response: RawHttpResponse
    provenance: HeaderProvenance
    effect: EffectStatus
@dataclass(frozen=True, slots=True)
class FailureObservation:
    attempt: AttemptIdentity
    handle: ExecutionHandle
    source: int | None
    failure: NetworkHostFailure
    effect: EffectStatus
@dataclass(frozen=True, slots=True)
class CancellationObservation:
    attempt: AttemptIdentity
    handle: ExecutionHandle
    source: int | None
    effect: EffectStatus
@dataclass(frozen=True, slots=True)
class DeadlineObservation:
    attempt: AttemptIdentity
    handle: ExecutionHandle
    source: int | None
    deadline: Deadline
    clock: MonotonicClockObservation
    effect: EffectStatus
@dataclass(frozen=True, slots=True)
class DeliveredObservation:
    delivery: int
    observation: ResponseObservation | FailureObservation | CancellationObservation | DeadlineObservation
HostObservation: TypeAlias = PendingObservation | DeliveredObservation
@dataclass(frozen=True, slots=True)
class LateObservation:
    delivered: DeliveredObservation
@dataclass(frozen=True, slots=True)
class SettledAttempt:
    prepared: PreparedAttempt
    handle: ExecutionHandle | None
    terminal: NetworkTerminal

@dataclass(frozen=True, slots=True)
class Read:
    state: NetworkState
@dataclass(frozen=True, slots=True)
class NetworkRejected:
    state: NetworkState
    failure: object
@dataclass(frozen=True, slots=True)
class Prepared:
    state: NetworkState
    prepared: PreparedAttempt
@dataclass(frozen=True, slots=True)
class CommandReady[Command: SendCommand | CancelCommand]:
    state: NetworkState
    command: Command
@dataclass(frozen=True, slots=True)
class Applied:
    state: NetworkState
@dataclass(frozen=True, slots=True)
class NetworkStarted:
    state: NetworkState
    started: StartedAttempt
@dataclass(frozen=True, slots=True)
class NetworkPending:
    state: NetworkState
    started: StartedAttempt
@dataclass(frozen=True, slots=True)
class NetworkTerminalResult:
    state: NetworkState
    settled: SettledAttempt
@dataclass(frozen=True, slots=True)
class NetworkLate:
    state: NetworkState
    settled: SettledAttempt
    late: LateObservation
@dataclass(frozen=True, slots=True)
class Duplicate:
    state: NetworkState
    attempt: AttemptIdentity
    delivery: int

class NetworkFailure: pass
@dataclass(frozen=True, slots=True)
class InvalidWireInstruction(NetworkFailure): method: str
@dataclass(frozen=True, slots=True)
class InvalidDeadline(NetworkFailure): pass
@dataclass(frozen=True, slots=True)
class InvalidNetworkState(NetworkFailure): violation: object
@dataclass(frozen=True, slots=True)
class RootAttemptRequired(NetworkFailure): attempt: AttemptIdentity
@dataclass(frozen=True, slots=True)
class DuplicateAttempt(NetworkFailure): attempt: AttemptIdentity
@dataclass(frozen=True, slots=True)
class UnknownAttempt(NetworkFailure): attempt: AttemptIdentity
@dataclass(frozen=True, slots=True)
class AttemptConditionMismatch(NetworkFailure):
    attempt: AttemptIdentity
    expected: object
    actual: object
@dataclass(frozen=True, slots=True)
class AttemptTokenMismatch(NetworkFailure):
    attempt: AttemptIdentity
    field: object
@dataclass(frozen=True, slots=True)
class ObservationRelationMismatch(NetworkFailure):
    attempt: AttemptIdentity
    field: object
@dataclass(frozen=True, slots=True)
class RequiredCapabilityUnavailable(NetworkFailure):
    attempt: AttemptIdentity
    capability: object
@dataclass(frozen=True, slots=True)
class CommandAlreadyIssued(NetworkFailure): attempt: AttemptIdentity
@dataclass(frozen=True, slots=True)
class IdentityMismatch(NetworkFailure):
    expected: AttemptIdentity
    actual: AttemptIdentity
@dataclass(frozen=True, slots=True)
class HandleMismatch(NetworkFailure):
    expected: ExecutionHandle
    actual: ExecutionHandle
@dataclass(frozen=True, slots=True)
class ClockBasisMismatch(NetworkFailure):
    expected: ClockBasis
    actual: ClockBasis
@dataclass(frozen=True, slots=True)
class DeadlineNotReached(NetworkFailure):
    deadline: Deadline
    observed_at: MonotonicClockObservation
@dataclass(frozen=True, slots=True)
class DeliveryOrderViolation(NetworkFailure):
    attempt: AttemptIdentity
    expected: int
    actual: int
@dataclass(frozen=True, slots=True)
class ConflictingDelivery(NetworkFailure):
    attempt: AttemptIdentity
    delivery: int
    old: object
    fresh: object
@dataclass(frozen=True, slots=True)
class MalformedAdapterObservation(NetworkFailure): pass
@dataclass(frozen=True, slots=True)
class Host(NetworkFailure): failure: NetworkHostFailure
@dataclass(frozen=True, slots=True)
class RetryNotPermitted(NetworkFailure): attempt: AttemptIdentity
@dataclass(frozen=True, slots=True)
class RetryIdentityMismatch(NetworkFailure):
    expected: RequestIdentity
    actual: RequestIdentity
@dataclass(frozen=True, slots=True)
class RetryParentMismatch(NetworkFailure):
    expected: AttemptIdentity
    actual: AttemptIdentity
@dataclass(frozen=True, slots=True)
class RetryParentNotSettled(NetworkFailure): attempt: AttemptIdentity
@dataclass(frozen=True, slots=True)
class RetryOrderViolation(NetworkFailure):
    expected: AttemptIdentity
    actual: AttemptIdentity
@dataclass(frozen=True, slots=True)
class RetryAuthorizationAlreadyUsed(NetworkFailure): authorization: RetryAuthorization
@dataclass(frozen=True, slots=True)
class EffectWitnessMissing(NetworkFailure): attempt: AttemptIdentity
@dataclass(frozen=True, slots=True)
class EffectKnowledgeConflict(NetworkFailure): attempt: AttemptIdentity

class AttemptCondition(Enum):
    PREPARED = "IsPrepared"
    COMMAND_ISSUED = "IsCommandIssued"
    STARTED = "IsStarted"
    SETTLED = "IsSettled"
    IsPrepared = "IsPrepared"
    IsCommandIssued = "IsCommandIssued"
    IsStarted = "IsStarted"
    IsSettled = "IsSettled"
class AttemptTokenField(Enum):
    INSTRUCTION = "Instruction"
    DEADLINE = "Deadline"
    CONFIGURATION = "Configuration"
    LINEAGE = "Lineage"
    HANDLE = "Handle"
class ObservationField(Enum):
    FAILURE_CONFIGURATION = "FailureConfiguration"
    FAILURE_STAGE = "FailureStage"
    DEADLINE_VALUE = "DeadlineValue"
    CLOCK_BASIS_VALUE = "ClockBasisValue"
    CLOCK_OBSERVATION_VALUE = "ClockObservationValue"
    EFFECT_WITNESS_VALUE = "EffectWitnessValue"
class CapabilityKind(Enum):
    CANCELLATION = "Cancellation"
    MONOTONIC_CLOCK = "MonotonicClock"
@dataclass(frozen=True, slots=True)
class DuplicateAttemptKey: attempt: AttemptIdentity
@dataclass(frozen=True, slots=True)
class NonRootFirstAttempt: attempt: AttemptIdentity
@dataclass(frozen=True, slots=True)
class OrdinalGap: attempt: AttemptIdentity
@dataclass(frozen=True, slots=True)
class LineageMismatch: attempt: AttemptIdentity
@dataclass(frozen=True, slots=True)
class RetryAuthorizationReuse: authorization: RetryAuthorization
@dataclass(frozen=True, slots=True)
class DispositionEvidenceMismatch: attempt: AttemptIdentity
@dataclass(frozen=True, slots=True)
class DeliveryLogMismatch: attempt: AttemptIdentity

_ASCII_ALPHA = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
_ASCII_DIGIT = frozenset("0123456789")
_ASCII_HEX = frozenset("0123456789abcdefABCDEF")
_TOKEN_PUNCTUATION = frozenset("!#$%&'*+-.^_`|~")
_URI_UNRESERVED_PUNCTUATION = frozenset("-._~")
_URI_SUB_DELIMITERS = frozenset("!$&'()*+,;=")


def _natural(value: object) -> bool:
    return type(value) is int and value >= 0


def _valid_bytes(value: tuple[int, ...]) -> bool:
    return all(_natural(item) and item <= 255 for item in value)


def _token_char_ok(value: str) -> bool:
    return value in _ASCII_ALPHA or value in _ASCII_DIGIT or value in _TOKEN_PUNCTUATION


def _token_ok(value: str) -> bool:
    return bool(value) and all(_token_char_ok(character) for character in value)


def _uri_unreserved_ok(value: str) -> bool:
    return value in _ASCII_ALPHA or value in _ASCII_DIGIT or value in _URI_UNRESERVED_PUNCTUATION


def _uri_sub_delimiter_ok(value: str) -> bool:
    return value in _URI_SUB_DELIMITERS


def _uri_pchar_ok(value: str) -> bool:
    return _uri_unreserved_ok(value) or _uri_sub_delimiter_ok(value) or value in ":@"


def _uri_component_ok(allow_question: bool, value: str) -> bool:
    index = 0
    while index < len(value):
        character = value[index]
        if character == "%":
            if index + 2 >= len(value) or value[index + 1] not in _ASCII_HEX or value[index + 2] not in _ASCII_HEX:
                return False
            index += 3
        elif _uri_pchar_ok(character) or character == "/" or (allow_question and character == "?"):
            index += 1
        else:
            return False
    return True


def _split_at_char(value: str, delimiter: str) -> tuple[str, str | None]:
    index = value.find(delimiter)
    return (value, None) if index < 0 else (value[:index], value[index + 1:])


def _uri_reg_name_ok(value: str) -> bool:
    index = 0
    while index < len(value):
        if value[index] == "%":
            if index + 2 >= len(value) or value[index + 1] not in _ASCII_HEX or value[index + 2] not in _ASCII_HEX:
                return False
            index += 3
        elif _uri_unreserved_ok(value[index]) or _uri_sub_delimiter_ok(value[index]):
            index += 1
        else:
            return False
    return True


def _uri_user_info_ok(value: str) -> bool:
    index = 0
    while index < len(value):
        if value[index] == "%":
            if index + 2 >= len(value) or value[index + 1] not in _ASCII_HEX or value[index + 2] not in _ASCII_HEX:
                return False
            index += 3
        elif _uri_unreserved_ok(value[index]) or _uri_sub_delimiter_ok(value[index]) or value[index] == ":":
            index += 1
        else:
            return False
    return True


def _uri_port_ok(value: str) -> bool:
    return all(character in _ASCII_DIGIT for character in value)


def _uri_ip_literal_ok(value: str) -> bool:
    return (
        bool(value)
        and any(character in ":." for character in value)
        and all(
            character in _ASCII_HEX
            or character in ":.vV"
            or _uri_unreserved_ok(character)
            or _uri_sub_delimiter_ok(character)
            for character in value
        )
    )


def _uri_port_suffix_ok(value: str) -> bool:
    return not value or value.startswith(":") and _uri_port_ok(value[1:])


def _uri_host_port_ok(value: str) -> bool:
    if value.startswith("["):
        end = value.find("]", 1)
        return end >= 0 and _uri_ip_literal_ok(value[1:end]) and _uri_port_suffix_ok(value[end + 1:])
    host, port = _split_at_char(value, ":")
    return _uri_reg_name_ok(host) and (port is None or _uri_port_ok(port))


def _authority_ok(value: str) -> bool:
    user_info, host_port = _split_at_char(value, "@")
    if host_port is None:
        return _uri_host_port_ok(user_info)
    return "@" not in host_port and _uri_user_info_ok(user_info) and _uri_host_port_ok(host_port)


def _uri_hier_part_ok(value: str) -> bool:
    if value.startswith("//"):
        rest = value[2:]
        slash = rest.find("/")
        authority_length = len(rest) if slash < 0 else slash
        return _authority_ok(rest[:authority_length]) and _uri_component_ok(False, rest[authority_length:])
    return _uri_component_ok(False, value)


def _uri_tail_ok(value: str) -> bool:
    before_fragment, fragment = _split_at_char(value, "#")
    path, query = _split_at_char(before_fragment, "?")
    return (
        _uri_hier_part_ok(path)
        and (query is None or _uri_component_ok(True, query))
        and (fragment is None or _uri_component_ok(True, fragment))
    )


def _valid_target(target: str) -> bool:
    if not target or target[0] not in _ASCII_ALPHA:
        return False
    scheme_end = target.find(":", 1)
    return (
        scheme_end >= 0
        and all(character in _ASCII_ALPHA or character in _ASCII_DIGIT or character in "+-." for character in target[1:scheme_end])
        and _uri_tail_ok(target[scheme_end + 1:])
    )


def _valid_instruction(instruction: HttpWireInstruction) -> bool:
    return (
        _token_ok(instruction.method)
        and _valid_target(instruction.target)
        and all(_token_ok(header.name) and _valid_bytes(header.value) for header in instruction.headers)
        and _valid_bytes(instruction.body)
    )


def _valid_deadline(configuration: HostConfiguration, deadline: Deadline | None) -> bool:
    return deadline is None or (
        deadline.capability.clock_basis == deadline.clock_basis
        and configuration.monotonic_clock == deadline.capability
    )


def valid_attempt_input(input: AttemptInput) -> bool:
    return (
        _valid_instruction(input.instruction)
        and len(input.instruction.body) <= input.configuration.request_body_limit
        and _valid_deadline(input.configuration, input.deadline)
    )


def _lookup(state: NetworkState, key: AttemptIdentity) -> AttemptRecord | None:
    return next((record for record in state.attempts if record.input.attempt == key), None)


def _replace_record(state: NetworkState, key: AttemptIdentity, replacement: AttemptRecord) -> NetworkState:
    return NetworkState(tuple(replacement if record.input.attempt == key else record for record in state.attempts))


def _effect_matches(key: AttemptIdentity, status: EffectStatus) -> bool:
    return isinstance(status, Unknown) or status.witness.attempt == key


def _terminal_evidence_ok(key: AttemptIdentity, terminal: NetworkTerminal) -> bool:
    return _effect_matches(key, terminal.effect) and (
        not isinstance(terminal.outcome, Failed) or terminal.outcome.failure.attempt == key
    )


def _record_evidence_ok(record: AttemptRecord) -> bool:
    disposition = record.disposition
    if isinstance(disposition, (PreparedDisposition, CommandIssued, StartedDisposition)):
        return record.first_delivery is None and not record.late
    if not isinstance(disposition, Settled) or not _terminal_evidence_ok(record.input.attempt, disposition.terminal):
        return False
    if disposition.handle is None:
        return record.first_delivery is None and not record.late
    first = record.first_delivery
    if (
        first is None
        or first.delivery != 0
        or first.observation.attempt != record.input.attempt
        or first.observation.handle != disposition.handle
    ):
        return False
    previous = first.delivery
    for late in record.late:
        delivered = late.delivered
        if (
            delivered.delivery <= previous
            or delivered.observation.attempt != record.input.attempt
            or delivered.observation.handle != disposition.handle
        ):
            return False
        previous = delivered.delivery
    return True


def _root_for_logical(records: tuple[AttemptRecord, ...], logical: RequestIdentity) -> bool:
    return any(
        record.input.attempt.logical == logical
        and record.input.attempt.ordinal == 0
        and isinstance(record.lineage, Root)
        for record in records
    )


def _settled_key(records: tuple[AttemptRecord, ...], key: AttemptIdentity) -> bool:
    return any(record.input.attempt == key and isinstance(record.disposition, Settled) for record in records)


def _lineage_ok(records: tuple[AttemptRecord, ...], record: AttemptRecord) -> bool:
    if not _root_for_logical(records, record.input.attempt.logical):
        return False
    if isinstance(record.lineage, Root):
        return record.input.attempt.ordinal == 0
    authorization = record.lineage.authorization
    return (
        authorization.logical == record.input.attempt.logical
        and authorization.from_attempt.logical == record.input.attempt.logical
        and authorization.next == record.input.attempt
        and authorization.next.ordinal == authorization.from_attempt.ordinal + 1
        and _settled_key(records, authorization.from_attempt)
    )


def _authorization_unique(records: tuple[AttemptRecord, ...]) -> bool:
    return all(
        not isinstance(record.lineage, RetryOf)
        or not any(
            isinstance(candidate.lineage, RetryOf)
            and candidate.lineage.authorization == record.lineage.authorization
            for candidate in records[index + 1:]
        )
        for index, record in enumerate(records)
    )


def valid_state(state: NetworkState) -> bool:
    keys = tuple(record.input.attempt for record in state.attempts)
    return (
        all(key not in keys[index + 1:] for index, key in enumerate(keys))
        and all(_record_evidence_ok(record) for record in state.attempts)
        and all(_lineage_ok(state.attempts, record) for record in state.attempts)
        and all(
            _root_for_logical(state.attempts, record.input.attempt.logical)
            for record in state.attempts
        )
        and _authorization_unique(state.attempts)
    )


def _empty_attempt_identity() -> AttemptIdentity:
    return AttemptIdentity(RequestIdentity("", "", 0), 0)


def _record_evidence_violation(record: AttemptRecord) -> object | None:
    if _record_evidence_ok(record):
        return None
    disposition = record.disposition
    if isinstance(disposition, (PreparedDisposition, CommandIssued, StartedDisposition)):
        return DeliveryLogMismatch(record.input.attempt)
    assert isinstance(disposition, Settled)
    if disposition.handle is None:
        if record.first_delivery is None and not record.late:
            return DispositionEvidenceMismatch(record.input.attempt)
        return DeliveryLogMismatch(record.input.attempt)
    if _terminal_evidence_ok(record.input.attempt, disposition.terminal):
        return DeliveryLogMismatch(record.input.attempt)
    return DispositionEvidenceMismatch(record.input.attempt)


def _lineage_violation(
    records: tuple[AttemptRecord, ...],
    record: AttemptRecord,
) -> object | None:
    if _lineage_ok(records, record):
        return None
    if not _root_for_logical(records, record.input.attempt.logical):
        return NonRootFirstAttempt(record.input.attempt)
    if isinstance(record.lineage, Root):
        return NonRootFirstAttempt(record.input.attempt)
    authorization = record.lineage.authorization
    if authorization.next.ordinal != authorization.from_attempt.ordinal + 1:
        return OrdinalGap(record.input.attempt)
    return LineageMismatch(record.input.attempt)


def _state_violation(state: NetworkState) -> object:
    for index, record in enumerate(state.attempts):
        if any(
            candidate.input.attempt == record.input.attempt
            for candidate in state.attempts[index + 1:]
        ):
            return DuplicateAttemptKey(record.input.attempt)
    for record in state.attempts:
        violation = _record_evidence_violation(record)
        if violation is not None:
            return violation
    for record in state.attempts:
        violation = _lineage_violation(state.attempts, record)
        if violation is not None:
            return violation
    for record in state.attempts:
        if not _root_for_logical(state.attempts, record.input.attempt.logical):
            return NonRootFirstAttempt(record.input.attempt)
    for index, record in enumerate(state.attempts):
        if isinstance(record.lineage, RetryOf) and any(
            isinstance(candidate.lineage, RetryOf)
            and candidate.lineage.authorization == record.lineage.authorization
            for candidate in state.attempts[index + 1:]
        ):
            return RetryAuthorizationReuse(record.lineage.authorization)
    return DuplicateAttemptKey(_empty_attempt_identity())


def _reject(state: NetworkState, failure: object) -> NetworkRejected:
    return NetworkRejected(state, failure)


def _prepared_relation(state: NetworkState, prepared: PreparedAttempt) -> bool:
    record = _lookup(state, prepared.input.attempt)
    return (
        valid_state(state)
        and record is not None
        and record.input == prepared.input
        and record.lineage == prepared.lineage
    )


def _prepared_ready(state: NetworkState, prepared: PreparedAttempt) -> bool:
    record = _lookup(state, prepared.input.attempt)
    return _prepared_relation(state, prepared) and record is not None and isinstance(record.disposition, PreparedDisposition)


def _started_relation(state: NetworkState, started: StartedAttempt) -> bool:
    record = _lookup(state, started.prepared.input.attempt)
    return (
        valid_state(state)
        and record is not None
        and record.input == started.prepared.input
        and record.lineage == started.prepared.lineage
        and record.disposition == StartedDisposition(started.handle)
        and record.first_delivery is None
        and not record.late
    )


def _disposition_condition(disposition: object) -> AttemptCondition:
    if isinstance(disposition, PreparedDisposition):
        return AttemptCondition.PREPARED
    if isinstance(disposition, CommandIssued):
        return AttemptCondition.COMMAND_ISSUED
    if isinstance(disposition, StartedDisposition):
        return AttemptCondition.STARTED
    return AttemptCondition.SETTLED


def _prepared_token_failure(
    state: NetworkState,
    prepared: PreparedAttempt,
) -> object | None:
    record = _lookup(state, prepared.input.attempt)
    if record is None:
        return UnknownAttempt(prepared.input.attempt)
    if record.input.instruction != prepared.input.instruction:
        return AttemptTokenMismatch(prepared.input.attempt, AttemptTokenField.INSTRUCTION)
    if record.input.deadline != prepared.input.deadline:
        return AttemptTokenMismatch(prepared.input.attempt, AttemptTokenField.DEADLINE)
    if record.input.configuration != prepared.input.configuration:
        return AttemptTokenMismatch(prepared.input.attempt, AttemptTokenField.CONFIGURATION)
    if record.lineage != prepared.lineage:
        return AttemptTokenMismatch(prepared.input.attempt, AttemptTokenField.LINEAGE)
    return None


def _prepared_condition_failure(
    state: NetworkState,
    prepared: PreparedAttempt,
    expected: AttemptCondition,
) -> object | None:
    failure = _prepared_token_failure(state, prepared)
    if failure is not None:
        return failure
    record = _lookup(state, prepared.input.attempt)
    if record is None:
        return UnknownAttempt(prepared.input.attempt)
    actual = _disposition_condition(record.disposition)
    if actual is expected:
        return None
    return AttemptConditionMismatch(prepared.input.attempt, expected, actual)


def _started_token_failure(
    state: NetworkState,
    started: StartedAttempt,
) -> object | None:
    failure = _prepared_token_failure(state, started.prepared)
    if failure is not None:
        return failure
    record = _lookup(state, started.prepared.input.attempt)
    if record is None:
        return UnknownAttempt(started.prepared.input.attempt)
    if not isinstance(record.disposition, StartedDisposition):
        return AttemptConditionMismatch(
            started.prepared.input.attempt,
            AttemptCondition.STARTED,
            _disposition_condition(record.disposition),
        )
    if record.disposition.handle != started.handle:
        return HandleMismatch(record.disposition.handle, started.handle)
    return None


def read_network_state(state: NetworkState) -> Read | NetworkRejected:
    if valid_state(state):
        return Read(state)
    return _reject(state, InvalidNetworkState(_state_violation(state)))


def prepare(state: NetworkState, input: AttemptInput) -> Prepared | NetworkRejected:
    if not valid_state(state):
        return _reject(state, InvalidNetworkState(_state_violation(state)))
    if not valid_attempt_input(input):
        return _reject(state, InvalidWireInstruction(input.instruction.method))
    if input.attempt.ordinal != 0:
        return _reject(state, RootAttemptRequired(input.attempt))
    if any(record.input.attempt.logical == input.attempt.logical for record in state.attempts):
        return _reject(state, DuplicateAttempt(input.attempt))
    prepared = PreparedAttempt(input, Root())
    next_state = NetworkState(state.attempts + (AttemptRecord(input, Root(), PreparedDisposition(), None, ()),))
    if valid_state(next_state) and _prepared_relation(next_state, prepared):
        return Prepared(next_state, prepared)
    return _reject(state, InvalidNetworkState(_state_violation(next_state)))


def send_command(state: NetworkState, prepared: PreparedAttempt) -> CommandReady[SendCommand] | NetworkRejected:
    if any(
        record.input == prepared.input
        and record.lineage == prepared.lineage
        and isinstance(record.disposition, CommandIssued)
        for record in state.attempts
    ):
        return _reject(state, CommandAlreadyIssued(prepared.input.attempt))
    if _prepared_ready(state, prepared):
        record = _lookup(state, prepared.input.attempt)
        assert record is not None
        next_state = _replace_record(
            state,
            prepared.input.attempt,
            replace(record, disposition=CommandIssued()),
        )
        if not valid_state(next_state):
            return _reject(state, InvalidNetworkState(_state_violation(next_state)))
        return CommandReady(next_state, SendCommand(prepared))
    if not valid_state(state):
        return _reject(state, InvalidNetworkState(_state_violation(state)))
    failure = _prepared_condition_failure(
        state,
        prepared,
        AttemptCondition.PREPARED,
    )
    if failure is None:
        failure = AttemptConditionMismatch(
            prepared.input.attempt,
            AttemptCondition.PREPARED,
            AttemptCondition.PREPARED,
        )
    return _reject(state, failure)


def cancel_command(state: NetworkState, started: StartedAttempt) -> CommandReady[CancelCommand] | NetworkRejected:
    if not _started_relation(state, started):
        if not valid_state(state):
            return _reject(state, InvalidNetworkState(_state_violation(state)))
        failure = _started_token_failure(state, started)
        if failure is None:
            failure = AttemptConditionMismatch(
                started.prepared.input.attempt,
                AttemptCondition.STARTED,
                AttemptCondition.STARTED,
            )
        return _reject(state, failure)
    capability = started.prepared.input.configuration.cancellation
    if capability is None:
        return _reject(
            state,
            RequiredCapabilityUnavailable(
                started.prepared.input.attempt,
                CapabilityKind.CANCELLATION,
            ),
        )
    return CommandReady(
        state,
        CancelCommand(started.prepared.input.attempt, started.handle, capability),
    )


def _start_observation_relation(
    state: NetworkState,
    prepared: PreparedAttempt,
    observation: Started | StartFailed,
) -> bool:
    record = _lookup(state, prepared.input.attempt)
    if not (
        _prepared_relation(state, prepared)
        and record is not None
        and isinstance(record.disposition, CommandIssued)
    ):
        return False
    if isinstance(observation, Started):
        return observation.attempt == prepared.input.attempt
    return (
        observation.failure.attempt == prepared.input.attempt
        and observation.failure.stage is HostStage.START
        and observation.failure.configuration == prepared.input.configuration
        and _effect_matches(prepared.input.attempt, observation.effect)
    )


def observe_start(
    state: NetworkState,
    prepared: PreparedAttempt,
    observation: StartObservation,
) -> NetworkStarted | NetworkTerminalResult | NetworkRejected:
    if not isinstance(observation, (Started, StartFailed)):
        raise TypeError('start observation must be Started or StartFailed')
    if not _start_observation_relation(state, prepared, observation):
        if not valid_state(state):
            return _reject(state, InvalidNetworkState(_state_violation(state)))
        failure = _prepared_condition_failure(
            state,
            prepared,
            AttemptCondition.COMMAND_ISSUED,
        )
        if failure is not None:
            return _reject(state, failure)
        if isinstance(observation, Started):
            return _reject(
                state,
                IdentityMismatch(prepared.input.attempt, observation.attempt),
            )
        if observation.failure.attempt != prepared.input.attempt:
            return _reject(
                state,
                IdentityMismatch(
                    prepared.input.attempt,
                    observation.failure.attempt,
                ),
            )
        if observation.failure.stage is not HostStage.START:
            return _reject(
                state,
                ObservationRelationMismatch(
                    prepared.input.attempt,
                    ObservationField.FAILURE_STAGE,
                ),
            )
        if observation.failure.configuration != prepared.input.configuration:
            return _reject(
                state,
                ObservationRelationMismatch(
                    prepared.input.attempt,
                    ObservationField.FAILURE_CONFIGURATION,
                ),
            )
        return _reject(
            state,
            ObservationRelationMismatch(
                prepared.input.attempt,
                ObservationField.EFFECT_WITNESS_VALUE,
            ),
        )
    record = _lookup(state, prepared.input.attempt)
    assert record is not None
    if isinstance(observation, Started):
        started = StartedAttempt(prepared, observation.handle)
        next_state = _replace_record(
            state,
            observation.attempt,
            replace(record, disposition=StartedDisposition(observation.handle)),
        )
        if valid_state(next_state) and _started_relation(next_state, started):
            return NetworkStarted(next_state, started)
        return _reject(state, InvalidNetworkState(_state_violation(next_state)))
    terminal = NetworkTerminal(Failed(observation.failure), observation.effect)
    settled = SettledAttempt(prepared, None, terminal)
    next_state = _replace_record(
        state,
        prepared.input.attempt,
        replace(record, disposition=Settled(None, terminal)),
    )
    if valid_state(next_state):
        return NetworkTerminalResult(next_state, settled)
    return _reject(state, InvalidNetworkState(_state_violation(next_state)))


def _terminal(observation: AdapterObservation) -> NetworkTerminal:
    if isinstance(observation, ResponseObservation):
        return NetworkTerminal(Response(observation.response, observation.provenance), observation.effect)
    if isinstance(observation, FailureObservation):
        return NetworkTerminal(Failed(observation.failure), observation.effect)
    if isinstance(observation, CancellationObservation):
        return NetworkTerminal(Cancelled(), observation.effect)
    return NetworkTerminal(DeadlineExceeded(observation.deadline, observation.clock), observation.effect)


def _response_ok(response: RawHttpResponse) -> bool:
    return (
        100 <= response.status <= 999
        and all(_token_ok(header.name) and _valid_bytes(header.value) for header in response.headers)
        and _valid_bytes(response.body)
    )


def _observation_relation(state: NetworkState, observation: AdapterObservation) -> bool:
    if not valid_state(state):
        return False
    record = _lookup(state, observation.attempt)
    if record is None:
        return False
    disposition = record.disposition
    if isinstance(disposition, StartedDisposition):
        authoritative_handle = disposition.handle
    elif isinstance(disposition, Settled) and disposition.handle is not None:
        authoritative_handle = disposition.handle
    else:
        return False
    if (
        observation.attempt != record.input.attempt
        or observation.handle != authoritative_handle
        or not _effect_matches(record.input.attempt, observation.effect)
    ):
        return False
    if isinstance(observation, ResponseObservation):
        return (
            _response_ok(observation.response)
            and len(observation.response.body) <= record.input.configuration.response_body_limit
        )
    if isinstance(observation, CancellationObservation):
        return True
    if isinstance(observation, FailureObservation):
        return (
            observation.failure.attempt == observation.attempt
            and observation.failure.configuration == record.input.configuration
            and (
                not isinstance(observation.failure.cause, Timeout)
                or observation.failure.cause.stage is observation.failure.stage
            )
        )
    deadline = record.input.deadline
    capability = record.input.configuration.monotonic_clock
    return (
        deadline is not None
        and capability is not None
        and deadline == observation.deadline
        and capability == deadline.capability
        and deadline.capability.clock_basis == deadline.clock_basis
        and observation.clock.clock_basis == deadline.clock_basis
        and deadline.limit <= observation.clock.value
    )


def _host_observation_relation(state: NetworkState, observation: HostObservation) -> bool:
    if isinstance(observation, PendingObservation):
        record = _lookup(state, observation.attempt)
        return (
            valid_state(state)
            and record is not None
            and record.disposition == StartedDisposition(observation.handle)
        )
    return _observation_relation(state, observation.observation)


def _recorded(record: AttemptRecord, delivery: int) -> AdapterObservation | None:
    if record.first_delivery is not None and record.first_delivery.delivery == delivery:
        return record.first_delivery.observation
    return next(
        (
            late.delivered.observation
            for late in record.late
            if late.delivered.delivery == delivery
        ),
        None,
    )


def _expected_delivery(record: AttemptRecord) -> int:
    if record.first_delivery is None:
        return 0
    if record.late:
        return record.late[-1].delivered.delivery + 1
    return record.first_delivery.delivery + 1


def _host_observation_failure(
    state: NetworkState,
    observation: HostObservation,
) -> object:
    if isinstance(observation, PendingObservation):
        record = _lookup(state, observation.attempt)
        if record is None:
            return UnknownAttempt(observation.attempt)
        if not isinstance(record.disposition, StartedDisposition):
            return AttemptConditionMismatch(
                observation.attempt,
                AttemptCondition.STARTED,
                _disposition_condition(record.disposition),
            )
        if observation.handle != record.disposition.handle:
            return HandleMismatch(record.disposition.handle, observation.handle)
        return MalformedAdapterObservation()

    delivered = observation.observation
    record = _lookup(state, delivered.attempt)
    if record is None:
        return UnknownAttempt(delivered.attempt)
    if isinstance(record.disposition, StartedDisposition):
        expected_handle = record.disposition.handle
    elif isinstance(record.disposition, Settled) and record.disposition.handle is not None:
        expected_handle = record.disposition.handle
    else:
        return AttemptConditionMismatch(
            delivered.attempt,
            AttemptCondition.STARTED,
            _disposition_condition(record.disposition),
        )
    if delivered.handle != expected_handle:
        return HandleMismatch(expected_handle, delivered.handle)
    if not _effect_matches(delivered.attempt, delivered.effect):
        return EffectWitnessMissing(delivered.attempt)
    if isinstance(delivered, (ResponseObservation, CancellationObservation)):
        return MalformedAdapterObservation()
    if isinstance(delivered, FailureObservation):
        if delivered.failure.attempt != delivered.attempt:
            return IdentityMismatch(
                delivered.attempt,
                delivered.failure.attempt,
            )
        if (
            isinstance(delivered.failure.cause, Timeout)
            and delivered.failure.cause.stage is not delivered.failure.stage
        ):
            return ObservationRelationMismatch(
                delivered.attempt,
                ObservationField.FAILURE_STAGE,
            )
        return ObservationRelationMismatch(
            delivered.attempt,
            ObservationField.FAILURE_CONFIGURATION,
        )
    if record.input.deadline != delivered.deadline:
        return ObservationRelationMismatch(
            delivered.attempt,
            ObservationField.DEADLINE_VALUE,
        )
    if delivered.deadline.clock_basis != delivered.clock.clock_basis:
        return ClockBasisMismatch(
            delivered.deadline.clock_basis,
            delivered.clock.clock_basis,
        )
    return DeadlineNotReached(delivered.deadline, delivered.clock)


def observe(
    state: NetworkState,
    observation: HostObservation,
) -> NetworkPending | NetworkTerminalResult | NetworkLate | Duplicate | NetworkRejected:
    if not _host_observation_relation(state, observation):
        if not valid_state(state):
            return _reject(state, InvalidNetworkState(_state_violation(state)))
        return _reject(state, _host_observation_failure(state, observation))
    if isinstance(observation, PendingObservation):
        record = _lookup(state, observation.attempt)
        if record is None:
            return _reject(state, UnknownAttempt(observation.attempt))
        return NetworkPending(
            state,
            StartedAttempt(PreparedAttempt(record.input, record.lineage), observation.handle),
        )
    delivered = observation.observation
    record = _lookup(state, delivered.attempt)
    if record is None:
        return _reject(state, UnknownAttempt(delivered.attempt))
    old = _recorded(record, observation.delivery)
    if old is not None:
        if old == delivered:
            return Duplicate(state, delivered.attempt, observation.delivery)
        return _reject(
            state,
            ConflictingDelivery(delivered.attempt, observation.delivery, old, delivered),
        )
    expected = _expected_delivery(record)
    if observation.delivery != expected:
        return _reject(
            state,
            DeliveryOrderViolation(delivered.attempt, expected, observation.delivery),
        )
    if isinstance(record.disposition, StartedDisposition):
        terminal = _terminal(delivered)
        first = DeliveredObservation(observation.delivery, delivered)
        settled = SettledAttempt(
            PreparedAttempt(record.input, record.lineage),
            record.disposition.handle,
            terminal,
        )
        next_state = _replace_record(
            state,
            delivered.attempt,
            replace(
                record,
                disposition=Settled(record.disposition.handle, terminal),
                first_delivery=first,
                late=(),
            ),
        )
        if valid_state(next_state):
            return NetworkTerminalResult(next_state, settled)
        return _reject(state, InvalidNetworkState(_state_violation(next_state)))
    if isinstance(record.disposition, Settled):
        late = LateObservation(observation)
        settled = SettledAttempt(
            PreparedAttempt(record.input, record.lineage),
            record.disposition.handle,
            record.disposition.terminal,
        )
        next_state = _replace_record(
            state,
            delivered.attempt,
            replace(record, late=record.late + (late,)),
        )
        if valid_state(next_state):
            return NetworkLate(next_state, settled, late)
        return _reject(state, InvalidNetworkState(_state_violation(next_state)))
    return _reject(
        state,
        AttemptConditionMismatch(
            delivered.attempt,
            AttemptCondition.STARTED,
            _disposition_condition(record.disposition),
        ),
    )


def _annotation_status_ok(current: EffectStatus, requested: EffectStatus) -> bool:
    if isinstance(current, Unknown):
        return isinstance(requested, (NoEffect, EffectOccurred))
    if isinstance(current, NoEffect) and isinstance(requested, NoEffect):
        return current.witness == requested.witness
    if isinstance(current, EffectOccurred) and isinstance(requested, EffectOccurred):
        return current.witness == requested.witness
    return False


def annotate_effect(state: NetworkState, observation: EffectObservation) -> Applied | NetworkRejected:
    if not valid_state(state):
        return _reject(state, InvalidNetworkState(_state_violation(state)))
    record = _lookup(state, observation.attempt)
    if record is None:
        return _reject(state, UnknownAttempt(observation.attempt))
    if not isinstance(record.disposition, Settled):
        return _reject(
            state,
            AttemptConditionMismatch(
                observation.attempt,
                AttemptCondition.SETTLED,
                _disposition_condition(record.disposition),
            ),
        )
    if not _effect_matches(observation.attempt, observation.status):
        return _reject(state, EffectWitnessMissing(observation.attempt))
    current = record.disposition.terminal.effect
    if not _annotation_status_ok(current, observation.status):
        if (
            isinstance(current, NoEffect)
            and isinstance(observation.status, EffectOccurred)
            or isinstance(current, EffectOccurred)
            and isinstance(observation.status, NoEffect)
        ):
            return _reject(state, EffectKnowledgeConflict(observation.attempt))
        return _reject(state, EffectWitnessMissing(observation.attempt))
    terminal = replace(record.disposition.terminal, effect=observation.status)
    next_state = _replace_record(
        state,
        observation.attempt,
        replace(record, disposition=replace(record.disposition, terminal=terminal)),
    )
    if valid_state(next_state):
        return Applied(next_state)
    return _reject(state, InvalidNetworkState(_state_violation(next_state)))


def _retry_acceptable(state: NetworkState, request: RetryRequest) -> bool:
    if not isinstance(request.permission, RetryAllowed):
        return False
    authorization = request.permission.authorization
    input = AttemptInput(
        authorization.next,
        request.instruction,
        request.deadline,
        request.configuration,
    )
    parent = _lookup(state, authorization.from_attempt)
    return (
        valid_state(state)
        and valid_attempt_input(input)
        and authorization.logical == authorization.from_attempt.logical
        and authorization.logical == authorization.next.logical
        and authorization.next.ordinal == authorization.from_attempt.ordinal + 1
        and parent is not None
        and isinstance(parent.disposition, Settled)
        and not any(
            candidate.input.attempt.logical == authorization.from_attempt.logical
            and candidate.input.attempt.ordinal > authorization.from_attempt.ordinal
            for candidate in state.attempts
        )
        and _lookup(state, authorization.next) is None
        and not any(
            isinstance(record.lineage, RetryOf)
            and record.lineage.authorization == authorization
            for record in state.attempts
        )
    )


def retry(state: NetworkState, request: RetryRequest) -> Prepared | NetworkRejected:
    if not _retry_acceptable(state, request):
        if isinstance(request.permission, RetryAllowed):
            attempt = request.permission.authorization.from_attempt
        else:
            attempt = request.permission.attempt
        return _reject(state, RetryNotPermitted(attempt))
    assert isinstance(request.permission, RetryAllowed)
    authorization = request.permission.authorization
    input = AttemptInput(
        authorization.next,
        request.instruction,
        request.deadline,
        request.configuration,
    )
    lineage = RetryOf(authorization)
    prepared = PreparedAttempt(input, lineage)
    next_state = NetworkState(
        state.attempts + (AttemptRecord(input, lineage, PreparedDisposition(), None, ()),)
    )
    if valid_state(next_state) and _prepared_relation(next_state, prepared):
        return Prepared(next_state, prepared)
    return _reject(state, InvalidNetworkState(_state_violation(next_state)))

ReadStateStep: TypeAlias = Read | NetworkRejected
PrepareStep: TypeAlias = Prepared | NetworkRejected
CommandStep: TypeAlias = CommandReady[SendCommand] | CommandReady[CancelCommand] | NetworkRejected
StateStep: TypeAlias = Applied | NetworkRejected
StartedResult = NetworkStarted
PendingResult = NetworkPending
TerminalResult = NetworkTerminalResult
LateResult = NetworkLate
Rejected = NetworkRejected
DeliveryOrdinal: TypeAlias = int
SourceSequence: TypeAlias = int | None
AttemptDisposition: TypeAlias = PreparedDisposition | CommandIssued | StartedDisposition | Settled
NetworkOutcome: TypeAlias = Response | Failed | Cancelled | DeadlineExceeded
AdapterObservation: TypeAlias = ResponseObservation | FailureObservation | CancellationObservation | DeadlineObservation
__all__ = [name for name in globals() if not name.startswith("_")]
