# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import http.client
import inspect
import socket
import struct
import threading
import time
from unittest.mock import patch
from urllib.parse import SplitResult

from necoherence import network_effect as ne
from necoherence_http_adapter import (
    EventCancellationPort,
    HttpHostAdapter,
)
from necoherence.request_progression import RequestIdentity


class _Peer:
    def __init__(
        self,
        mode: str = "respond",
        *,
        status: int = 200,
        headers: tuple[tuple[str, str], ...] = (),
        body: bytes = b"",
    ) -> None:
        self.mode = mode
        self.status = status
        self.headers = headers
        self.body = body
        self.release = threading.Event()
        self.received = threading.Event()
        self.request_count = 0
        self.request = b""
        self.error: BaseException | None = None
        self._stop = threading.Event()
        self._listener = socket.socket()
        self._listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._listener.bind(("127.0.0.1", 0))
        self._listener.listen(1)
        self._listener.settimeout(0.1)
        self.port = self._listener.getsockname()[1]
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    @property
    def target(self) -> str:
        return f"http://127.0.0.1:{self.port}/value?q=1"

    def __enter__(self) -> _Peer:
        return self

    def __exit__(self, *_: object) -> None:
        self.release.set()
        self._stop.set()
        self._listener.close()
        self._thread.join(timeout=1)

    def _serve(self) -> None:
        connection: socket.socket | None = None
        try:
            while not self._stop.is_set():
                try:
                    connection, _ = self._listener.accept()
                    break
                except socket.timeout:
                    continue
            if connection is None:
                return
            if self.mode == "reset":
                connection.setsockopt(
                    socket.SOL_SOCKET,
                    socket.SO_LINGER,
                    struct.pack("ii", 1, 0),
                )
                connection.close()
                return
            self.request = self._read_request(connection)
            self.request_count += 1
            self.received.set()
            if self.mode == "close_headers":
                return
            if self.mode == "malformed":
                connection.sendall(b"not-http\r\n\r\n")
                return
            if self.mode == "partial_body":
                connection.sendall(
                    b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nab"
                )
                return
            if self.mode == "delay_body":
                connection.sendall(
                    b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n"
                )
                self.release.wait(2)
                connection.sendall(b"raw")
                return
            if self.mode == "delay":
                self.release.wait(2)
            response_headers = (
                self.headers
                + (("Content-Length", str(len(self.body))),)
            )
            encoded_headers = b"".join(
                name.encode("ascii")
                + b": "
                + value.encode("latin-1")
                + b"\r\n"
                for name, value in response_headers
            )
            connection.sendall(
                f"HTTP/1.1 {self.status} Test\r\n".encode("ascii")
                + encoded_headers
                + b"\r\n"
                + self.body
            )
        except BaseException as error:
            if not self._stop.is_set():
                self.error = error
        finally:
            if connection is not None:
                try:
                    connection.close()
                except OSError:
                    pass

    @staticmethod
    def _read_request(connection: socket.socket) -> bytes:
        value = bytearray()
        while b"\r\n\r\n" not in value:
            chunk = connection.recv(65536)
            if not chunk:
                return bytes(value)
            value.extend(chunk)
        header, body = bytes(value).split(b"\r\n\r\n", 1)
        length = 0
        for line in header.split(b"\r\n")[1:]:
            name, _, field_value = line.partition(b":")
            if name.lower() == b"content-length":
                length = int(field_value.strip())
        while len(body) < length:
            chunk = connection.recv(65536)
            if not chunk:
                break
            body += chunk
        return header + b"\r\n\r\n" + body


class _LoopPeer:
    """Loopback peer that serves an arbitrary number of sequential requests."""

    def __init__(self, *, status: int = 200, body: bytes = b"ok") -> None:
        self.status = status
        self.body = body
        self.request_count = 0
        self._stop = threading.Event()
        self._listener = socket.socket()
        self._listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._listener.bind(("127.0.0.1", 0))
        self._listener.listen(4)
        self._listener.settimeout(0.1)
        self.port = self._listener.getsockname()[1]
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    @property
    def target(self) -> str:
        return f"http://127.0.0.1:{self.port}/retry"

    def __enter__(self) -> "_LoopPeer":
        return self

    def __exit__(self, *_: object) -> None:
        self._stop.set()
        self._listener.close()
        self._thread.join(timeout=1)

    def _serve(self) -> None:
        while not self._stop.is_set():
            try:
                connection, _ = self._listener.accept()
            except socket.timeout:
                continue
            try:
                _Peer._read_request(connection)
                self.request_count += 1
                connection.sendall(
                    f"HTTP/1.1 {self.status} Test\r\n".encode("ascii")
                    + f"Content-Length: {len(self.body)}\r\n\r\n".encode(
                        "ascii"
                    )
                    + self.body
                )
            except OSError:
                pass
            finally:
                connection.close()


@dataclass(frozen=True)
class _Session:
    input: ne.AttemptInput
    started: ne.NetworkStarted
    ledger_record_count: int
    issued_command_count: int


class _Clock:
    def __init__(
        self,
        capability: ne.MonotonicClockCapability,
        values: tuple[int, ...],
    ) -> None:
        self._capability = capability
        self._values = list(values)
        self._last = values[-1]
        self._lock = threading.Lock()

    def capability(self) -> ne.MonotonicClockCapability:
        return self._capability

    def observe(self) -> ne.MonotonicClockObservation:
        with self._lock:
            value = self._values.pop(0) if self._values else self._last
        return ne.MonotonicClockObservation(
            self._capability.clock_basis,
            value,
        )


class _RejectCancellationPort(EventCancellationPort):
    def request(
        self,
        capability: ne.CancellationCapability,
        handle: ne.ExecutionHandle,
    ) -> bool:
        return False


class _ResolverFailureAdapter(HttpHostAdapter):
    def _new_connection(
        self,
        target: SplitResult,
    ) -> http.client.HTTPConnection:
        raise socket.gaierror("controlled resolver failure")


class _HeaderCodecFailureAdapter(HttpHostAdapter):
    def _encode_response_header(
        self,
        name: str,
        value: str,
    ) -> ne.RawHeaderField:
        raise UnicodeError("controlled header codec failure")


class _RuntimeFailureAdapter(HttpHostAdapter):
    def _request(
        self,
        handle: ne.ExecutionHandle,
        input: ne.AttemptInput,
        source: int,
    ) -> ne.AdapterObservation:
        raise RuntimeError("controlled worker failure")


class _TimeoutSourceAdapter(HttpHostAdapter):
    def __init__(
        self,
        stage: ne.HostStage,
        cause: ne.HostTimeoutCause,
    ) -> None:
        super().__init__()
        self._stage = stage
        self._cause = cause

    def _request(
        self,
        handle: ne.ExecutionHandle,
        input: ne.AttemptInput,
        source: int,
    ) -> ne.AdapterObservation:
        return self._failure_observation(
            input,
            handle,
            source,
            self._stage,
            ne.Timeout(self._stage, self._cause),
        )


class _ShortTimeoutAdapter(HttpHostAdapter):
    def _new_connection(
        self,
        target: SplitResult,
    ) -> http.client.HTTPConnection:
        import http.client

        assert target.hostname is not None
        return http.client.HTTPConnection(
            target.hostname,
            target.port,
            timeout=0.03,
        )


def _input(
    target: str,
    *,
    body: tuple[int, ...] = (),
    headers: tuple[ne.RawHeaderField, ...] = (),
    response_limit: int = 1024,
    cancellation: ne.CancellationCapability | None = None,
    deadline: ne.Deadline | None = None,
) -> ne.AttemptInput:
    logical = RequestIdentity("network", target, 1)
    configuration = ne.HostConfiguration(
        len(body),
        response_limit,
        cancellation,
        None if deadline is None else deadline.capability,
    )
    return ne.AttemptInput(
        ne.AttemptIdentity(logical, 0),
        ne.HttpWireInstruction("POST", target, headers, body),
        deadline,
        configuration,
    )


def _start(
    adapter: HttpHostAdapter,
    input: ne.AttemptInput,
) -> _Session | ne.StartFailed:
    prepared = ne.prepare(ne.NetworkState(()), input)
    assert isinstance(prepared, ne.Prepared)
    command = ne.send_command(prepared.state, prepared.prepared)
    assert isinstance(command, ne.CommandReady)
    assert isinstance(command.command, ne.SendCommand)
    started = adapter.start(command.command)
    if isinstance(started, ne.StartFailed):
        return started
    transition = ne.observe_start(
        command.state,
        prepared.prepared,
        started,
    )
    assert isinstance(transition, ne.NetworkStarted)
    return _Session(input, transition, len(command.state.attempts), 1)


def _poll(
    adapter: HttpHostAdapter,
    session: _Session,
) -> ne.DeliveredObservation:
    for _ in range(400):
        observation = adapter.observe(session.started.started)
        if isinstance(observation, ne.DeliveredObservation):
            return observation
        time.sleep(0.002)
    raise AssertionError("adapter observation remained pending")


def _failure(
    adapter: HttpHostAdapter,
    input: ne.AttemptInput,
) -> tuple[_Session, ne.FailureObservation]:
    session = _start(adapter, input)
    assert isinstance(session, _Session)
    delivered = _poll(adapter, session)
    assert isinstance(delivered.observation, ne.FailureObservation)
    terminal = ne.observe(session.started.state, delivered)
    assert isinstance(terminal, ne.NetworkTerminalResult)
    assert terminal.settled.terminal.outcome == ne.Failed(
        delivered.observation.failure
    )
    return session, delivered.observation


def test_started_precedes_completion_and_preserves_raw_responses() -> None:
    for status in (200, 301, 404, 429, 500):
        with _Peer(
            status=status,
            headers=(("X-Trace", "one"), ("X-Trace", "two"), ("X-Text", "é")),
            body=bytes((0, 128, 255)),
        ) as peer:
            input = _input(peer.target, body=(8, 9), response_limit=16)
            adapter = HttpHostAdapter()
            session = _start(adapter, input)
            assert isinstance(session, _Session)
            assert isinstance(session.started.started.handle, ne.ExecutionHandle)
            delivered = _poll(adapter, session)
            assert delivered.delivery == 0
            assert isinstance(delivered.observation, ne.ResponseObservation)
            response = delivered.observation
            assert response.response.status == status
            assert response.response.body == (0, 128, 255)
            assert response.provenance is ne.HeaderProvenance.LIBRARY_OBSERVED
            assert [
                (header.name.lower(), header.value)
                for header in response.response.headers
                if header.name.lower().startswith("x-")
            ] == [
                ("x-trace", tuple(b"one")),
                ("x-trace", tuple(b"two")),
                ("x-text", (233,)),
            ]
            terminal = ne.observe(session.started.state, delivered)
            assert isinstance(terminal, ne.NetworkTerminalResult)
            assert len(terminal.state.attempts) == 1
            assert session.ledger_record_count == 1
            assert session.issued_command_count == 1
            assert peer.request_count == 1
            assert peer.request_count <= session.issued_command_count
            digest = hashlib.sha256(repr(input.instruction).encode()).hexdigest()
            causal_identity = (
                input.attempt,
                input.attempt.ordinal,
                digest,
                session.started.started.handle,
            )
            assert causal_identity[0] == response.attempt
            assert causal_identity[1] == 0
            assert causal_identity[2]
            assert causal_identity[3] == response.handle


def test_pending_is_stable_until_the_peer_releases_response() -> None:
    with _Peer(mode="delay", body=b"ready") as peer:
        adapter = HttpHostAdapter()
        session = _start(adapter, _input(peer.target))
        assert isinstance(session, _Session)
        assert peer.received.wait(1)
        first = adapter.observe(session.started.started)
        second = adapter.observe(session.started.started)
        assert isinstance(first, ne.PendingObservation)
        assert first == second
        peer.release.set()
        delivered = _poll(adapter, session)
        assert delivered.delivery == 0
        assert peer.request_count == 1


def test_cancel_and_deadline_win_without_event_priority() -> None:
    cancellation = ne.CancellationCapability(ne.OpaqueEvidence("cancel"))
    with _Peer(mode="delay", body=b"late") as peer:
        adapter = HttpHostAdapter(
            cancellation=EventCancellationPort(cancellation)
        )
        session = _start(
            adapter,
            _input(peer.target, cancellation=cancellation),
        )
        assert isinstance(session, _Session)
        assert peer.received.wait(1)
        command = ne.cancel_command(
            session.started.state,
            session.started.started,
        )
        assert isinstance(command, ne.CommandReady)
        assert isinstance(command.command, ne.CancelCommand)
        cancelled = adapter.cancel(command.command)
        assert isinstance(cancelled, ne.DeliveredObservation)
        assert cancelled.delivery == 0
        assert cancelled.observation.source == 1
        terminal = ne.observe(session.started.state, cancelled)
        assert isinstance(terminal, ne.NetworkTerminalResult)
        assert isinstance(terminal.settled.terminal.outcome, ne.Cancelled)
        peer.release.set()
        late_response = _poll(adapter, session)
        assert late_response.delivery == 1
        assert late_response.observation.source == 0
        late = ne.observe(terminal.state, late_response)
        assert isinstance(late, ne.NetworkLate)

    clock_capability = ne.MonotonicClockCapability(
        ne.OpaqueEvidence("clock"),
        ne.ClockBasis("basis"),
    )
    deadline = ne.Deadline(
        clock_capability.clock_basis,
        10,
        clock_capability,
    )
    with _Peer(mode="delay", body=b"late") as peer:
        adapter = HttpHostAdapter(
            clock=_Clock(clock_capability, (0, 10))
        )
        session = _start(adapter, _input(peer.target, deadline=deadline))
        assert isinstance(session, _Session)
        assert peer.received.wait(1)
        pending = adapter.observe(session.started.started)
        if isinstance(pending, ne.PendingObservation):
            deadline_event = adapter.observe(session.started.started)
        else:
            deadline_event = pending
        assert isinstance(deadline_event, ne.DeliveredObservation)
        assert deadline_event.delivery == 0
        assert deadline_event.observation.source == 1
        assert isinstance(deadline_event.observation, ne.DeadlineObservation)
        terminal = ne.observe(session.started.state, deadline_event)
        assert isinstance(terminal, ne.NetworkTerminalResult)
        assert isinstance(terminal.settled.terminal.outcome, ne.DeadlineExceeded)
        peer.release.set()
        late_response = _poll(adapter, session)
        assert late_response.delivery == 1
        assert late_response.observation.source == 0


def test_duplicate_and_conflicting_delivery_are_distinct() -> None:
    with _Peer(body=b"raw") as peer:
        adapter = HttpHostAdapter()
        session = _start(adapter, _input(peer.target))
        assert isinstance(session, _Session)
        delivered = _poll(adapter, session)
        terminal = ne.observe(session.started.state, delivered)
        assert isinstance(terminal, ne.NetworkTerminalResult)
        duplicate = ne.observe(terminal.state, delivered)
        assert isinstance(duplicate, ne.Duplicate)
        assert isinstance(delivered.observation, ne.ResponseObservation)
        changed = ne.ResponseObservation(
            delivered.observation.attempt,
            delivered.observation.handle,
            delivered.observation.source,
            ne.RawHttpResponse(200, (), (1,)),
            delivered.observation.provenance,
            delivered.observation.effect,
        )
        conflict = ne.observe(
            terminal.state,
            ne.DeliveredObservation(delivered.delivery, changed),
        )
        assert isinstance(conflict, ne.NetworkRejected)
        assert isinstance(conflict.failure, ne.ConflictingDelivery)


def test_pre_handle_failure_matrix_has_zero_peer_count() -> None:
    unsupported = _start(
        HttpHostAdapter(),
        _input("ftp://127.0.0.1/value"),
    )
    assert isinstance(unsupported, ne.StartFailed)
    assert isinstance(unsupported.failure.cause, ne.UnsupportedUriScheme)

    invalid_input = ne.AttemptInput(
        ne.AttemptIdentity(RequestIdentity("network", "invalid", 1), 0),
        ne.HttpWireInstruction(
            "POST",
            "http://127.0.0.1/",
            (),
            (1, 2),
        ),
        None,
        ne.HostConfiguration(1, 16),
    )
    invalid = HttpHostAdapter().start(
        ne.SendCommand(ne.PreparedAttempt(invalid_input, ne.Root()))
    )
    assert isinstance(invalid, ne.StartFailed)
    assert isinstance(invalid.failure.cause, ne.InvalidHostConfiguration)

    with patch.object(
        threading.Thread,
        "start",
        side_effect=RuntimeError("controlled start failure"),
    ):
        execution = _start(
            HttpHostAdapter(),
            _input("http://127.0.0.1:1/"),
        )
    assert isinstance(execution, ne.StartFailed)
    assert isinstance(execution.failure.cause, ne.ExecutionStartFailed)

    clock_capability = ne.MonotonicClockCapability(
        ne.OpaqueEvidence("clock"),
        ne.ClockBasis("basis"),
    )
    deadline = ne.Deadline(
        clock_capability.clock_basis,
        10,
        clock_capability,
    )
    deadline_control = _start(
        HttpHostAdapter(),
        _input("http://127.0.0.1:1/", deadline=deadline),
    )
    assert isinstance(deadline_control, ne.StartFailed)
    assert isinstance(
        deadline_control.failure.cause,
        ne.DeadlineControlUnavailable,
    )


def test_resolver_and_connection_failures_are_typed() -> None:
    _, resolver = _failure(
        _ResolverFailureAdapter(),
        _input("http://resolver.invalid/"),
    )
    assert isinstance(resolver.failure.cause, ne.NameResolutionFailed)
    assert resolver.failure.stage is ne.HostStage.REQUEST_WRITE

    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    listener.close()
    _, connection = _failure(
        HttpHostAdapter(),
        _input(f"http://127.0.0.1:{port}/"),
    )
    assert isinstance(connection.failure.cause, ne.ConnectionFailed)
    assert connection.failure.stage is ne.HostStage.REQUEST_WRITE


def test_request_write_and_header_encoding_failures_prevent_success() -> None:
    with _Peer(mode="reset") as peer:
        body = tuple(1 for _ in range(4 * 1024 * 1024))
        _, write = _failure(
            HttpHostAdapter(),
            _input(peer.target, body=body),
        )
        assert isinstance(write.failure.cause, ne.RequestWriteFailed)

    with _Peer() as peer:
        _, header = _failure(
            HttpHostAdapter(),
            _input(
                peer.target,
                headers=(ne.RawHeaderField("X-Test", (10,)),),
            ),
        )
        assert isinstance(
            header.failure.cause,
            ne.RequestHeaderEncodingUnavailable,
        )
        assert peer.request_count == 0


def test_response_failure_matrix_uses_real_http_client() -> None:
    for mode, limit, expected in (
        ("close_headers", 16, ne.ResponseHeadersFailed),
        ("partial_body", 16, ne.ResponseBodyFailed),
        ("respond", 2, ne.ResponseBodyLimitExceeded),
        ("malformed", 16, ne.MalformedResponse),
    ):
        body = b"oversized" if expected is ne.ResponseBodyLimitExceeded else b""
        with _Peer(mode=mode, body=body) as peer:
            _, failure = _failure(
                HttpHostAdapter(),
                _input(peer.target, response_limit=limit),
            )
            assert isinstance(failure.failure.cause, expected)
            assert peer.request_count == 1


def test_response_header_codec_fault_is_closed_and_private() -> None:
    with _Peer(headers=(("X-Test", "value"),)) as peer:
        _, failure = _failure(
            _HeaderCodecFailureAdapter(),
            _input(peer.target),
        )
        assert isinstance(
            failure.failure.cause,
            ne.HeaderRepresentationUnavailable,
        )
    parameters = inspect.signature(HttpHostAdapter).parameters
    assert "resolver" not in parameters
    assert "writer" not in parameters
    assert "header_codec" not in parameters
    assert "timeout_source" not in parameters


def test_cancellation_rejection_runtime_failure_and_host_close_are_typed() -> None:
    cancellation = ne.CancellationCapability(ne.OpaqueEvidence("cancel"))
    with _Peer(mode="delay", body=b"late") as peer:
        adapter = HttpHostAdapter(
            cancellation=_RejectCancellationPort(cancellation)
        )
        session = _start(
            adapter,
            _input(peer.target, cancellation=cancellation),
        )
        assert isinstance(session, _Session)
        assert peer.received.wait(1)
        command = ne.cancel_command(
            session.started.state,
            session.started.started,
        )
        assert isinstance(command, ne.CommandReady)
        assert isinstance(command.command, ne.CancelCommand)
        rejected = adapter.cancel(command.command)
        assert isinstance(rejected, ne.DeliveredObservation)
        assert isinstance(rejected.observation, ne.FailureObservation)
        assert isinstance(
            rejected.observation.failure.cause,
            ne.CancellationRejected,
        )
        assert rejected.observation.failure.stage is ne.HostStage.CANCEL

    _, runtime = _failure(
        _RuntimeFailureAdapter(),
        _input("http://127.0.0.1:1/"),
    )
    assert isinstance(runtime.failure.cause, ne.HostRuntimeFailure)

    with _Peer(mode="delay", body=b"late") as peer:
        adapter = HttpHostAdapter()
        session = _start(adapter, _input(peer.target))
        assert isinstance(session, _Session)
        assert peer.received.wait(1)
        closed = adapter.close(session.started.started)
        assert isinstance(closed, ne.DeliveredObservation)
        assert isinstance(closed.observation, ne.FailureObservation)
        assert isinstance(closed.observation.failure.cause, ne.HostClosed)
        peer.release.set()
        late = _poll(adapter, session)
        assert late.delivery == 1


def test_library_timeout_and_deadline_are_separate() -> None:
    with _Peer(mode="delay") as peer:
        _, failure = _failure(
            _ShortTimeoutAdapter(),
            _input(peer.target),
        )
        assert isinstance(failure.failure.cause, ne.Timeout)
        assert (
            failure.failure.cause.stage
            is ne.HostStage.RESPONSE_HEADERS
        )
        assert (
            failure.failure.cause.cause
            is ne.HostTimeoutCause.LIBRARY_REPORTED
        )
        assert isinstance(failure.effect, ne.Unknown)
        assert failure.effect.reason is ne.UnknownEffectReason.HOST_FAILURE

    with _Peer(mode="delay_body") as peer:
        _, failure = _failure(
            _ShortTimeoutAdapter(),
            _input(peer.target),
        )
        assert isinstance(failure.failure.cause, ne.Timeout)
        assert failure.failure.cause.stage is ne.HostStage.RESPONSE_BODY


def test_timeout_source_covers_every_stage_and_cause() -> None:
    observed: set[tuple[ne.HostStage, ne.HostTimeoutCause]] = set()
    for stage in ne.HostStage:
        for cause in ne.HostTimeoutCause:
            _, failure = _failure(
                _TimeoutSourceAdapter(stage, cause),
                _input("http://127.0.0.1:1/"),
            )
            assert failure.failure.stage is stage
            assert failure.failure.cause == ne.Timeout(stage, cause)
            assert isinstance(failure.effect, ne.Unknown)
            observed.add((stage, cause))
    assert len(observed) == 24


def test_retry_after_settled_root_dispatches_ordinal_one_against_a_peer() -> None:
    with _LoopPeer(body=b"root") as peer:
        adapter = HttpHostAdapter()
        input = _input(peer.target)
        session = _start(adapter, input)
        assert isinstance(session, _Session)
        delivered = _poll(adapter, session)
        assert isinstance(delivered.observation, ne.ResponseObservation)
        root_terminal = ne.observe(session.started.state, delivered)
        assert isinstance(root_terminal, ne.NetworkTerminalResult)

        ledger_record_count = len(root_terminal.state.attempts)
        issued_command_count = session.issued_command_count
        peer_received_count = peer.request_count
        assert ledger_record_count == 1
        assert issued_command_count == 1
        assert peer_received_count == 1

        authorization = ne.RetryAuthorization(
            input.attempt.logical,
            input.attempt,
            ne.AttemptIdentity(input.attempt.logical, 1),
            ne.OpaqueEvidence("retry-auth"),
        )
        request = ne.RetryRequest(
            ne.RetryAllowed(authorization),
            input.instruction,
            input.deadline,
            input.configuration,
        )
        retried = ne.retry(root_terminal.state, request)
        assert isinstance(retried, ne.Prepared)
        assert len(retried.state.attempts) == ledger_record_count + 1
        assert issued_command_count == session.issued_command_count
        assert peer.request_count == peer_received_count
        assert isinstance(retried.prepared.lineage, ne.RetryOf)
        assert retried.prepared.lineage.authorization == authorization
        root_record = retried.state.attempts[0]
        assert isinstance(root_record.lineage, ne.Root)

        command = ne.send_command(retried.state, retried.prepared)
        assert isinstance(command, ne.CommandReady)
        assert isinstance(command.command, ne.SendCommand)
        started = adapter.start(command.command)
        assert isinstance(started, ne.Started)
        issued_command_count += 1
        transition = ne.observe_start(command.state, retried.prepared, started)
        assert isinstance(transition, ne.NetworkStarted)
        retry_session = _Session(
            retried.prepared.input,
            transition,
            len(command.state.attempts),
            issued_command_count,
        )
        retry_delivered = _poll(adapter, retry_session)
        assert isinstance(retry_delivered.observation, ne.ResponseObservation)
        retry_terminal = ne.observe(retry_session.started.state, retry_delivered)
        assert isinstance(retry_terminal, ne.NetworkTerminalResult)

        assert issued_command_count == 2
        assert peer.request_count == peer_received_count + 1

        retry_record = retry_terminal.state.attempts[1]
        assert isinstance(retry_record.lineage, ne.RetryOf)
        assert retry_record.lineage.authorization == authorization
        assert retry_record.lineage != root_record.lineage
        assert isinstance(retry_terminal.state.attempts[0].lineage, ne.Root)

        reused = ne.retry(retry_terminal.state, request)
        assert isinstance(reused, ne.NetworkRejected)
        assert isinstance(reused.failure, ne.RetryNotPermitted)
        assert len(reused.state.attempts) == len(retry_terminal.state.attempts)
        assert peer.request_count == peer_received_count + 1
