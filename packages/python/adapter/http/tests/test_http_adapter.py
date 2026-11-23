# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import http.client
import inspect
import socket
import queue
import struct
import threading
import time
from unittest.mock import patch
from urllib.parse import SplitResult

from necoherence import network_effect as ne
from neco_quotient_retention import (
    Dematerialize,
    FutureUse,
    OutstandingEffect,
    Retain,
)
from necoherence_http_adapter import (
    EventCancellationPort,
    HttpHostAdapter,
    UnknownExecution,
)
from necoherence_http_adapter import _Lifecycle
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

    def observe(self) -> ne.MonotonicClockObservation | ne.HostFailure:
        with self._lock:
            value = self._values.pop(0) if self._values else self._last
        return ne.MonotonicClockObservation(
            self._capability.clock_basis,
            value,
        )


class _RejectCancellationPort(EventCancellationPort):
    def request(self, handle: ne.ExecutionHandle) -> ne.HostFailure | None:
        return ne.CancellationRejected()


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


class _ConnectionRuntimeFailureAdapter(HttpHostAdapter):
    def _new_connection(
        self,
        target: SplitResult,
    ) -> http.client.HTTPConnection:
        raise RuntimeError("controlled connection failure")


class _HeaderRuntimeFailureAdapter(HttpHostAdapter):
    def _encode_response_header(
        self,
        name: str,
        value: str,
    ) -> ne.RawHeaderField:
        raise RuntimeError("controlled header failure")


class _BodyRuntimeFailureAdapter(HttpHostAdapter):
    def _new_connection(
        self,
        target: SplitResult,
    ) -> http.client.HTTPConnection:
        assert target.hostname is not None

        class _Connection(http.client.HTTPConnection):
            def getresponse(self) -> http.client.HTTPResponse:
                response = super().getresponse()

                def read(*arguments: object, **options: object) -> bytes:
                    raise RuntimeError("controlled body failure")

                setattr(response, "read", read)
                return response

        return _Connection(target.hostname, target.port)


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
    body: bytes = b"",
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
    prepared = ne.prepare(ne.empty_network_state(), input)
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
    return _Session(input, transition, len(ne.network_attempts(command.state)), 1)


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


def _worker_stopped(adapter: HttpHostAdapter, session: _Session) -> bool:
    worker = adapter._worker(
        session.started.started.handle,
        session.started.started.prepared.input.attempt,
    )
    return worker is None or not worker.is_running


def _assert_stopped_without_late_observation(
    adapter: HttpHostAdapter,
    session: _Session,
) -> None:
    stop_at = time.monotonic() + 2.0
    while not _worker_stopped(adapter, session):
        assert time.monotonic() < stop_at, "worker still running"
        time.sleep(0.005)
    later = adapter.observe(session.started.started)
    assert isinstance(later, (ne.PendingObservation, UnknownExecution))


def _assert_no_late_response(
    adapter: HttpHostAdapter,
    session: _Session,
    release: threading.Event,
) -> None:
    _assert_stopped_without_late_observation(adapter, session)
    release.set()
    time.sleep(0.15)
    for _ in range(2):
        later = adapter.observe(session.started.started)
        assert isinstance(later, ne.PendingObservation)


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
            input = _input(peer.target, body=b"\x08\x09", response_limit=16)
            adapter = HttpHostAdapter()
            session = _start(adapter, input)
            assert isinstance(session, _Session)
            assert isinstance(session.started.started.handle, ne.ExecutionHandle)
            delivered = _poll(adapter, session)
            assert delivered.delivery == 0
            assert isinstance(delivered.observation, ne.ResponseObservation)
            response = delivered.observation
            assert response.response.status == status
            assert response.response.body == bytes((0, 128, 255))
            assert response.provenance is ne.HeaderProvenance.LIBRARY_OBSERVED
            assert [
                (header.name.lower(), header.value)
                for header in response.response.headers
                if header.name.lower().startswith("x-")
            ] == [
                ("x-trace", b"one"),
                ("x-trace", b"two"),
                ("x-text", b"\xe9"),
            ]
            terminal = ne.observe(session.started.state, delivered)
            assert isinstance(terminal, ne.NetworkTerminalResult)
            assert len(ne.network_attempts(terminal.state)) == 1
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
        _assert_stopped_without_late_observation(adapter, session)

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
        _assert_stopped_without_late_observation(adapter, session)


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
            ne.RawHttpResponse(200, (), b"\x01"),
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
            b"\x01\x02",
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
    assert resolver.failure.stage is ne.HostStage.START

    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    listener.close()
    _, connection = _failure(
        HttpHostAdapter(),
        _input(f"http://127.0.0.1:{port}/"),
    )
    assert isinstance(connection.failure.cause, ne.ConnectionFailed)
    assert connection.failure.stage is ne.HostStage.START


def test_connection_failure_reports_the_start_stage() -> None:
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    listener.close()
    _, failure = _failure(
        HttpHostAdapter(),
        _input(f"http://127.0.0.1:{port}/"),
    )
    assert isinstance(failure.failure.cause, ne.ConnectionFailed)
    assert failure.failure.stage is ne.HostStage.START


def test_response_effect_reason_is_the_missing_protocol_witness() -> None:
    with _Peer(body=b"ok") as peer:
        adapter = HttpHostAdapter()
        session = _start(adapter, _input(peer.target))
        assert isinstance(session, _Session)
        delivered = _poll(adapter, session)
        assert isinstance(delivered.observation, ne.ResponseObservation)
        expected = ne.Unknown(ne.UnknownEffectReason.PROTOCOL_WITNESS_MISSING)
        assert delivered.observation.effect == expected
        terminal = ne.observe(session.started.state, delivered)
        assert isinstance(terminal, ne.NetworkTerminalResult)
        assert terminal.settled.terminal.effect == expected


def test_unclassified_failure_keeps_the_stage_of_the_worker() -> None:
    _, before_request = _failure(
        _ConnectionRuntimeFailureAdapter(),
        _input("http://127.0.0.1:1/"),
    )
    assert isinstance(before_request.failure.cause, ne.HostRuntimeFailure)
    assert before_request.failure.stage is ne.HostStage.REQUEST_WRITE

    with _Peer(body=b"ok") as peer:
        _, in_headers = _failure(
            _HeaderRuntimeFailureAdapter(),
            _input(peer.target),
        )
    assert isinstance(in_headers.failure.cause, ne.HostRuntimeFailure)
    assert in_headers.failure.stage is ne.HostStage.RESPONSE_HEADERS

    with _Peer(body=b"ok") as peer:
        _, in_body = _failure(
            _BodyRuntimeFailureAdapter(),
            _input(peer.target),
        )
    assert isinstance(in_body.failure.cause, ne.HostRuntimeFailure)
    assert in_body.failure.stage is ne.HostStage.RESPONSE_BODY


def test_start_checks_run_in_the_fixed_order() -> None:
    clock = ne.MonotonicClockCapability(
        ne.OpaqueEvidence("order-clock"),
        ne.ClockBasis("order"),
    )
    foreign_cancellation = ne.CancellationCapability(
        ne.OpaqueEvidence("foreign")
    )

    def failure(
        target: str,
        body: bytes,
        deadline: ne.Deadline | None,
        monotonic_clock: ne.MonotonicClockCapability | None,
    ) -> ne.HostFailure | None:
        input = ne.AttemptInput(
            ne.AttemptIdentity(RequestIdentity("network", "order", 1), 0),
            ne.HttpWireInstruction("POST", target, (), body),
            deadline,
            ne.HostConfiguration(
                4,
                16,
                foreign_cancellation,
                monotonic_clock,
            ),
        )
        return HttpHostAdapter()._start_failure(input)

    deadline = ne.Deadline(clock.clock_basis, 1, clock)
    assert isinstance(
        failure("ftp://127.0.0.1/", b"x" * 8, deadline, clock),
        ne.UnsupportedUriScheme,
    )
    assert isinstance(
        failure("http://127.0.0.1/", b"x" * 8, deadline, clock),
        ne.InvalidHostConfiguration,
    )
    assert isinstance(
        failure("http://127.0.0.1/", b"", deadline, clock),
        ne.DeadlineControlUnavailable,
    )
    assert isinstance(
        failure("http://127.0.0.1/", b"", None, None),
        ne.InvalidHostConfiguration,
    )


def test_request_write_and_header_encoding_failures_prevent_success() -> None:
    with _Peer(mode="reset") as peer:
        body = b"\x01" * (4 * 1024 * 1024)
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
                headers=(ne.RawHeaderField("X-Test", b"\x0a"),),
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
        _assert_stopped_without_late_observation(adapter, session)

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
        assert closed.observation.failure.stage is ne.HostStage.CANCEL
        _assert_stopped_without_late_observation(adapter, session)


class _RecordingCancellationPort(EventCancellationPort):
    def __init__(self, capability: ne.CancellationCapability) -> None:
        super().__init__(capability)
        self.calls = 0

    def request(self, handle: ne.ExecutionHandle) -> ne.HostFailure | None:
        self.calls += 1
        return super().request(handle)


class _RaisingCancellationPort(EventCancellationPort):
    def request(self, handle: ne.ExecutionHandle) -> ne.HostFailure | None:
        raise RuntimeError("controlled cancellation port failure")


def test_cancel_with_queued_response_calls_port_and_queues_cancellation() -> None:
    cancellation = ne.CancellationCapability(ne.OpaqueEvidence("cancel"))
    port = _RecordingCancellationPort(cancellation)
    with _Peer(body=b"ready") as peer:
        adapter = HttpHostAdapter(cancellation=port)
        session = _start(
            adapter,
            _input(peer.target, cancellation=cancellation),
        )
        assert isinstance(session, _Session)
        worker = adapter._worker(
            session.started.started.handle,
            session.started.started.prepared.input.attempt,
        )
        assert worker is not None
        for _ in range(400):
            if not worker.queue.empty():
                break
            time.sleep(0.002)
        assert not worker.queue.empty()
        command = ne.cancel_command(
            session.started.state,
            session.started.started,
        )
        assert isinstance(command, ne.CommandReady)
        assert isinstance(command.command, ne.CancelCommand)
        first = adapter.cancel(command.command)
        assert port.calls == 1
        assert isinstance(first, ne.DeliveredObservation)
        assert first.delivery == 0
        assert isinstance(first.observation, ne.ResponseObservation)
        second = adapter.observe(session.started.started)
        assert isinstance(second, ne.DeliveredObservation)
        assert second.delivery == 1
        assert isinstance(second.observation, ne.CancellationObservation)


def test_cancel_port_exception_is_host_runtime_failure() -> None:
    cancellation = ne.CancellationCapability(ne.OpaqueEvidence("cancel"))
    with _Peer(mode="delay", body=b"late") as peer:
        adapter = HttpHostAdapter(
            cancellation=_RaisingCancellationPort(cancellation)
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
        assert rejected.observation.failure.stage is ne.HostStage.CANCEL
        assert isinstance(
            rejected.observation.failure.cause,
            ne.HostRuntimeFailure,
        )
        assert rejected.observation.effect == ne.Unknown(
            ne.UnknownEffectReason.HOST_FAILURE
        )
        _assert_stopped_without_late_observation(adapter, session)


def test_close_with_queued_response_returns_head_and_queues_host_closed() -> None:
    with _Peer(body=b"ready") as peer:
        adapter = HttpHostAdapter()
        session = _start(adapter, _input(peer.target))
        assert isinstance(session, _Session)
        worker = adapter._worker(
            session.started.started.handle,
            session.started.started.prepared.input.attempt,
        )
        assert worker is not None
        for _ in range(400):
            if not worker.queue.empty():
                break
            time.sleep(0.002)
        assert not worker.queue.empty()
        first = adapter.close(session.started.started)
        assert isinstance(first, ne.DeliveredObservation)
        assert first.delivery == 0
        assert isinstance(first.observation, ne.ResponseObservation)
        second = adapter.observe(session.started.started)
        assert isinstance(second, ne.DeliveredObservation)
        assert second.delivery == 1
        assert isinstance(second.observation, ne.FailureObservation)
        assert isinstance(second.observation.failure.cause, ne.HostClosed)
        assert second.observation.failure.stage is ne.HostStage.CANCEL


def test_deadline_already_reached_at_start_is_observed_once() -> None:
    clock_capability = ne.MonotonicClockCapability(
        ne.OpaqueEvidence("clock"),
        ne.ClockBasis("basis"),
    )
    deadline = ne.Deadline(
        clock_capability.clock_basis,
        10,
        clock_capability,
    )
    adapter = HttpHostAdapter(clock=_Clock(clock_capability, (10,)))
    session = _start(
        adapter,
        _input("http://127.0.0.1:1/", deadline=deadline),
    )
    assert isinstance(session, _Session)
    observed = [adapter.observe(session.started.started)]
    time.sleep(0.2)
    observed.append(adapter.observe(session.started.started))
    observed.append(adapter.observe(session.started.started))
    deadlines = [
        item
        for item in observed
        if isinstance(item, ne.DeliveredObservation)
        and isinstance(item.observation, ne.DeadlineObservation)
    ]
    assert len(deadlines) == 1


def test_a_public_observe_and_the_worker_queue_one_deadline_observation() -> None:
    clock_capability = ne.MonotonicClockCapability(
        ne.OpaqueEvidence("clock"),
        ne.ClockBasis("basis"),
    )
    deadline = ne.Deadline(
        clock_capability.clock_basis,
        10,
        clock_capability,
    )
    adapter = HttpHostAdapter(clock=_Clock(clock_capability, (10,)))
    for _ in range(200):
        session = _start(
            adapter,
            _input("http://127.0.0.1:1/", deadline=deadline),
        )
        assert isinstance(session, _Session)
        stop_at = time.monotonic() + 2.0
        while True:
            observed = adapter.observe(session.started.started)
            if isinstance(observed, ne.DeliveredObservation):
                assert isinstance(observed.observation, ne.DeadlineObservation)
                break
            assert time.monotonic() < stop_at, "the deadline observation did not arrive"
        for _ in range(5):
            time.sleep(0.001)
            later = adapter.observe(session.started.started)
            assert not isinstance(later, ne.DeliveredObservation)


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

        ledger_record_count = len(ne.network_attempts(root_terminal.state))
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
        assert len(ne.network_attempts(retried.state)) == ledger_record_count + 1
        assert issued_command_count == session.issued_command_count
        assert peer.request_count == peer_received_count
        assert isinstance(retried.prepared.chain, ne.RetryOf)
        assert retried.prepared.chain.authorization == authorization
        root_record = ne.network_attempts(retried.state)[0]
        assert isinstance(root_record.chain, ne.Root)

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
            len(ne.network_attempts(command.state)),
            issued_command_count,
        )
        retry_delivered = _poll(adapter, retry_session)
        assert isinstance(retry_delivered.observation, ne.ResponseObservation)
        retry_terminal = ne.observe(retry_session.started.state, retry_delivered)
        assert isinstance(retry_terminal, ne.NetworkTerminalResult)

        assert issued_command_count == 2
        assert peer.request_count == peer_received_count + 1

        retry_record = ne.network_attempts(retry_terminal.state)[1]
        assert isinstance(retry_record.chain, ne.RetryOf)
        assert retry_record.chain.authorization == authorization
        assert retry_record.chain != root_record.chain
        assert isinstance(ne.network_attempts(retry_terminal.state)[0].chain, ne.Root)

        reused = ne.retry(retry_terminal.state, request)
        assert isinstance(reused, ne.NetworkRejected)
        assert isinstance(reused.failure, ne.RetryNotPermitted)
        assert len(ne.network_attempts(reused.state)) == len(ne.network_attempts(retry_terminal.state))
        assert peer.request_count == peer_received_count + 1


class _GatedPeer:
    """Loopback peer that holds every connection until released."""

    def __init__(self) -> None:
        self.release = threading.Event()
        self.accepted = 0
        self._stop = threading.Event()
        self._listener = socket.socket()
        self._listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._listener.bind(("127.0.0.1", 0))
        self._listener.listen(128)
        self._listener.settimeout(0.1)
        self.port = self._listener.getsockname()[1]
        self._threads: list[threading.Thread] = []
        self._acceptor = threading.Thread(target=self._serve, daemon=True)
        self._acceptor.start()

    @property
    def target(self) -> str:
        return f"http://127.0.0.1:{self.port}/gated"

    def __enter__(self) -> "_GatedPeer":
        return self

    def __exit__(self, *_: object) -> None:
        self.release.set()
        self._stop.set()
        self._listener.close()
        self._acceptor.join(timeout=1)
        for thread in self._threads:
            thread.join(timeout=1)

    def _serve(self) -> None:
        while not self._stop.is_set():
            try:
                connection, _ = self._listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            self.accepted += 1
            thread = threading.Thread(
                target=self._answer,
                args=(connection,),
                daemon=True,
            )
            self._threads.append(thread)
            thread.start()

    def _answer(self, connection: socket.socket) -> None:
        try:
            _Peer._read_request(connection)
            self.release.wait(10)
            connection.sendall(
                b"HTTP/1.1 200 Test\r\nContent-Length: 2\r\n\r\nok"
            )
        except OSError:
            pass
        finally:
            connection.close()


def test_requests_beyond_the_executor_limit_stay_pending_then_complete() -> None:
    capability = ne.CancellationCapability(ne.OpaqueEvidence("queued-cancel"))
    adapter = HttpHostAdapter(cancellation=EventCancellationPort(capability))
    limit = adapter._executor._max_workers
    total = limit + 4
    with _GatedPeer() as peer:
        sessions: list[_Session] = []
        for _ in range(total):
            session = _start(
                adapter,
                _input(peer.target, cancellation=capability),
            )
            assert isinstance(session, _Session)
            sessions.append(session)
        stop_at = time.monotonic() + 5
        while peer.accepted < limit and time.monotonic() < stop_at:
            time.sleep(0.01)
        time.sleep(0.2)
        assert peer.accepted <= limit
        for session in sessions:
            assert isinstance(
                adapter.observe(session.started.started),
                ne.PendingObservation,
            )

        cancelled = sessions[total - 2]
        command = ne.cancel_command(
            cancelled.started.state,
            cancelled.started.started,
        )
        assert isinstance(command, ne.CommandReady)
        assert isinstance(command.command, ne.CancelCommand)
        cancel_result = adapter.cancel(command.command)
        assert isinstance(cancel_result, ne.DeliveredObservation)
        assert cancel_result.delivery == 0
        assert isinstance(
            cancel_result.observation,
            ne.CancellationObservation,
        )
        closed = adapter.close(sessions[total - 1].started.started)
        assert isinstance(closed, ne.DeliveredObservation)
        assert closed.delivery == 0
        assert isinstance(closed.observation, ne.FailureObservation)
        assert isinstance(closed.observation.failure.cause, ne.HostClosed)

        peer.release.set()
        for session in sessions:
            if session in (cancelled, sessions[total - 1]):
                _assert_stopped_without_late_observation(adapter, session)
                continue
            delivered = _poll(adapter, session)
            assert isinstance(delivered.observation, ne.ResponseObservation)


def _effect_outstanding(decision: object) -> bool:
    return isinstance(decision, Retain) and any(
        isinstance(reason, OutstandingEffect) for reason in decision.reasons
    )


def _release_when_idle(
    adapter: HttpHostAdapter,
    state: ne.NetworkState,
    session: _Session,
) -> object:
    for _ in range(5000):
        decision = adapter.release(state, session.started.started)
        if not _effect_outstanding(decision):
            return decision
        time.sleep(0.001)
    raise AssertionError("worker remained running")


def _drain_requests(total: int, unreleased: int) -> int:
    adapter = HttpHostAdapter()
    with _GatedPeer() as peer:
        peer.release.set()
        for index in range(total):
            session = _start(adapter, _input(peer.target))
            assert isinstance(session, _Session)
            delivered = _poll(adapter, session)
            terminal = ne.observe(session.started.state, delivered)
            assert isinstance(terminal, ne.NetworkTerminalResult)
            if index >= unreleased:
                decision = _release_when_idle(adapter, terminal.state, session)
                assert isinstance(decision, Dematerialize)
    return adapter._record_count()


def test_released_records_leave_no_registration_after_many_requests() -> None:
    assert _drain_requests(500, 0) == 0


def test_unreleased_records_remain_registered() -> None:
    assert _drain_requests(40, 3) == 3


def test_release_retains_only_future_use_before_terminal() -> None:
    adapter = HttpHostAdapter()
    with _GatedPeer() as peer:
        peer.release.set()
        session = _start(adapter, _input(peer.target))
        assert isinstance(session, _Session)
        _poll(adapter, session)
        decision = _release_when_idle(adapter, session.started.state, session)
        attempt = session.started.started.prepared.input.attempt
        assert isinstance(decision, Retain)
        assert tuple(decision.reasons) == (FutureUse(attempt),)
        assert adapter._record_count() == 1


def test_released_and_unknown_handles_return_unknown_execution() -> None:
    cancellation = ne.CancellationCapability(ne.OpaqueEvidence("cancel"))
    adapter = HttpHostAdapter(cancellation=EventCancellationPort(cancellation))
    with _GatedPeer() as peer:
        peer.release.set()
        session = _start(
            adapter,
            _input(peer.target, cancellation=cancellation),
        )
        assert isinstance(session, _Session)
        delivered = _poll(adapter, session)
        terminal = ne.observe(session.started.state, delivered)
        assert isinstance(terminal, ne.NetworkTerminalResult)
        decision = _release_when_idle(adapter, terminal.state, session)
        assert isinstance(decision, Dematerialize)
        started = session.started.started
        unknown = UnknownExecution(started.handle)
        assert adapter.observe(started) == unknown
        assert adapter.close(started) == unknown
        assert (
            adapter.cancel(
                ne.CancelCommand(
                    started.prepared.input.attempt,
                    started.handle,
                    cancellation,
                )
            )
            == unknown
        )
        never = ne.StartedAttempt(
            started.prepared,
            ne.ExecutionHandle("never-started"),
        )
        assert adapter.observe(never) == UnknownExecution(never.handle)


class _CountingCancellationPort(EventCancellationPort):
    def __init__(self, capability: ne.CancellationCapability) -> None:
        super().__init__(capability)
        self.unregistered: dict[ne.ExecutionHandle, int] = {}
        self.counting = threading.Lock()

    def unregister(self, handle: ne.ExecutionHandle) -> None:
        with self.counting:
            self.unregistered[handle] = self.unregistered.get(handle, 0) + 1
        super().unregister(handle)


def test_release_right_after_terminal_removes_each_record_once() -> None:
    cancellation = ne.CancellationCapability(ne.OpaqueEvidence("cancel"))
    port = _CountingCancellationPort(cancellation)
    adapter = HttpHostAdapter(cancellation=port)
    handles: list[ne.ExecutionHandle] = []
    with _GatedPeer() as peer:
        peer.release.set()
        for _ in range(300):
            session = _start(
                adapter,
                _input(peer.target, cancellation=cancellation),
            )
            assert isinstance(session, _Session)
            delivered = _poll(adapter, session)
            terminal = ne.observe(session.started.state, delivered)
            assert isinstance(terminal, ne.NetworkTerminalResult)
            started = session.started.started
            handles.append(started.handle)
            decision = adapter.release(terminal.state, started)
            assert not isinstance(decision, ne.Rejected)
            stop_at = time.monotonic() + 5.0
            while adapter._record_count() != 0:
                assert time.monotonic() < stop_at, "the record stayed"
                time.sleep(0.001)
            assert adapter.observe(started) == UnknownExecution(started.handle)
    time.sleep(0.05)
    with port.counting:
        assert [port.unregistered.get(handle, 0) for handle in handles] == [
            1
        ] * 300


def _wait_accepted(peer: _GatedPeer) -> None:
    stop_at = time.monotonic() + 2.0
    while peer.accepted < 1:
        assert time.monotonic() < stop_at, "peer did not accept"
        time.sleep(0.002)
    time.sleep(0.05)


def test_deadline_interrupts_the_request_without_releasing_the_peer() -> None:
    clock_capability = ne.MonotonicClockCapability(
        ne.OpaqueEvidence("clock"),
        ne.ClockBasis("basis"),
    )
    deadline = ne.Deadline(clock_capability.clock_basis, 10, clock_capability)
    with _GatedPeer() as peer:
        adapter = HttpHostAdapter(clock=_Clock(clock_capability, (0, 10)))
        session = _start(adapter, _input(peer.target, deadline=deadline))
        assert isinstance(session, _Session)
        _wait_accepted(peer)
        observed = adapter.observe(session.started.started)
        assert isinstance(observed, ne.DeliveredObservation)
        assert isinstance(observed.observation, ne.DeadlineObservation)
        terminal = ne.observe(session.started.state, observed)
        assert isinstance(terminal, ne.NetworkTerminalResult)
        _assert_stopped_without_late_observation(adapter, session)
        decision = adapter.release(terminal.state, session.started.started)
        assert isinstance(decision, Dematerialize)
        assert adapter._record_count() == 0


class _ObserveRaisingClock(_Clock):
    def __init__(
        self,
        capability: ne.MonotonicClockCapability,
        values: tuple[int, ...],
    ) -> None:
        super().__init__(capability, values)
        self.armed = False
        self.raised = 0

    def observe(self) -> ne.MonotonicClockObservation | ne.HostFailure:
        if self.armed:
            self.raised += 1
            raise RuntimeError("clock failure")
        return super().observe()


def test_clock_below_the_limit_leaves_observe_pending() -> None:
    clock_capability = ne.MonotonicClockCapability(
        ne.OpaqueEvidence("clock"),
        ne.ClockBasis("basis"),
    )
    deadline = ne.Deadline(clock_capability.clock_basis, 10, clock_capability)
    with _GatedPeer() as peer:
        adapter = HttpHostAdapter(clock=_Clock(clock_capability, (0, 9)))
        session = _start(adapter, _input(peer.target, deadline=deadline))
        assert isinstance(session, _Session)
        _wait_accepted(peer)
        observed = adapter.observe(session.started.started)
        assert isinstance(observed, ne.PendingObservation)


def test_clock_observe_exception_is_a_single_host_runtime_failure() -> None:
    clock_capability = ne.MonotonicClockCapability(
        ne.OpaqueEvidence("clock"),
        ne.ClockBasis("basis"),
    )
    deadline = ne.Deadline(clock_capability.clock_basis, 10, clock_capability)
    with _GatedPeer() as peer:
        clock = _ObserveRaisingClock(clock_capability, (0,))
        adapter = HttpHostAdapter(clock=clock)
        session = _start(adapter, _input(peer.target, deadline=deadline))
        assert isinstance(session, _Session)
        _wait_accepted(peer)
        clock.armed = True
        first = adapter.observe(session.started.started)
        assert isinstance(first, ne.DeliveredObservation)
        assert isinstance(first.observation, ne.FailureObservation)
        failure = first.observation.failure
        assert failure.stage is ne.HostStage.DEADLINE
        assert isinstance(failure.cause, ne.HostRuntimeFailure)
        assert first.observation.effect == ne.Unknown(
            ne.UnknownEffectReason.HOST_FAILURE
        )
        assert clock.raised == 1
        second = adapter.observe(session.started.started)
        assert isinstance(second, ne.PendingObservation)
        assert clock.raised == 1
        _assert_no_late_response(adapter, session, peer.release)
        assert clock.raised == 1


def test_accepted_cancellation_interrupts_the_request() -> None:
    cancellation = ne.CancellationCapability(ne.OpaqueEvidence("cancel"))
    with _GatedPeer() as peer:
        adapter = HttpHostAdapter(
            cancellation=EventCancellationPort(cancellation)
        )
        session = _start(
            adapter,
            _input(peer.target, cancellation=cancellation),
        )
        assert isinstance(session, _Session)
        _wait_accepted(peer)
        command = ne.cancel_command(
            session.started.state,
            session.started.started,
        )
        assert isinstance(command, ne.CommandReady)
        assert isinstance(command.command, ne.CancelCommand)
        cancelled = adapter.cancel(command.command)
        assert isinstance(cancelled, ne.DeliveredObservation)
        assert isinstance(cancelled.observation, ne.CancellationObservation)
        terminal = ne.observe(session.started.state, cancelled)
        assert isinstance(terminal, ne.NetworkTerminalResult)
        _assert_stopped_without_late_observation(adapter, session)
        decision = adapter.release(terminal.state, session.started.started)
        assert isinstance(decision, Dematerialize)
        assert adapter._record_count() == 0


def test_close_interrupts_the_request() -> None:
    with _GatedPeer() as peer:
        adapter = HttpHostAdapter()
        session = _start(adapter, _input(peer.target))
        assert isinstance(session, _Session)
        _wait_accepted(peer)
        closed = adapter.close(session.started.started)
        assert isinstance(closed, ne.DeliveredObservation)
        assert isinstance(closed.observation, ne.FailureObservation)
        assert isinstance(closed.observation.failure.cause, ne.HostClosed)
        terminal = ne.observe(session.started.state, closed)
        assert isinstance(terminal, ne.NetworkTerminalResult)
        _assert_stopped_without_late_observation(adapter, session)
        decision = adapter.release(terminal.state, session.started.started)
        assert isinstance(decision, Dematerialize)
        assert adapter._record_count() == 0


def test_rejected_cancellation_interrupts_the_request_and_no_late_observation_follows() -> None:
    cancellation = ne.CancellationCapability(ne.OpaqueEvidence("cancel"))
    with _GatedPeer() as peer:
        adapter = HttpHostAdapter(
            cancellation=_RejectCancellationPort(cancellation)
        )
        session = _start(
            adapter,
            _input(peer.target, cancellation=cancellation),
        )
        assert isinstance(session, _Session)
        _wait_accepted(peer)
        command = ne.cancel_command(
            session.started.state,
            session.started.started,
        )
        assert isinstance(command, ne.CommandReady)
        assert isinstance(command.command, ne.CancelCommand)
        rejected = adapter.cancel(command.command)
        assert isinstance(rejected, ne.DeliveredObservation)
        assert isinstance(rejected.observation, ne.FailureObservation)
        assert rejected.observation.failure.stage is ne.HostStage.CANCEL
        assert isinstance(
            rejected.observation.failure.cause,
            ne.CancellationRejected,
        )
        assert rejected.observation.effect == ne.Unknown(
            ne.UnknownEffectReason.HOST_FAILURE
        )
        _assert_no_late_response(adapter, session, peer.release)


def _rejected_cancel_session(
    peer: _GatedPeer,
) -> tuple[HttpHostAdapter, _Session, ne.DeliveredObservation]:
    cancellation = ne.CancellationCapability(ne.OpaqueEvidence("cancel"))
    adapter = HttpHostAdapter(
        cancellation=_RejectCancellationPort(cancellation)
    )
    session = _start(
        adapter,
        _input(peer.target, cancellation=cancellation),
    )
    assert isinstance(session, _Session)
    _wait_accepted(peer)
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
    return adapter, session, rejected


def test_a_rejected_cancellation_right_after_the_start_never_leaves_a_response_behind_it() -> None:
    cancellation = ne.CancellationCapability(ne.OpaqueEvidence("cancel"))
    with _LoopPeer() as peer:
        adapter = HttpHostAdapter(
            cancellation=_RejectCancellationPort(cancellation)
        )
        for _ in range(200):
            session = _start(
                adapter,
                _input(peer.target, cancellation=cancellation),
            )
            assert isinstance(session, _Session)
            command = ne.cancel_command(
                session.started.state,
                session.started.started,
            )
            assert isinstance(command, ne.CommandReady)
            assert isinstance(command.command, ne.CancelCommand)
            first = adapter.cancel(command.command)
            assert isinstance(first, ne.DeliveredObservation)
            kinds = [type(first.observation)]
            stop_at = time.monotonic() + 5.0
            while not _worker_stopped(adapter, session):
                assert time.monotonic() < stop_at, "worker still running"
                time.sleep(0.001)
            while True:
                later = adapter.observe(session.started.started)
                if not isinstance(later, ne.DeliveredObservation):
                    break
                kinds.append(type(later.observation))
            assert kinds in (
                [ne.FailureObservation],
                [ne.ResponseObservation, ne.FailureObservation],
            )


def test_release_after_the_terminal_observation_removes_the_record_within_the_limit() -> None:
    with _GatedPeer() as peer:
        adapter, session, rejected = _rejected_cancel_session(peer)
        terminal = ne.observe(session.started.state, rejected)
        assert isinstance(terminal, ne.NetworkTerminalResult)
        decision = adapter.release(terminal.state, session.started.started)
        assert isinstance(decision, (Retain, Dematerialize))
        stop_at = time.monotonic() + 2.0
        while adapter._record_count() != 0:
            assert time.monotonic() < stop_at, "record remained"
            time.sleep(0.005)
        peer.release.set()


def test_release_while_the_core_still_awaits_keeps_the_record_and_no_late_observation_follows() -> None:
    with _GatedPeer() as peer:
        adapter, session, _ = _rejected_cancel_session(peer)
        _assert_stopped_without_late_observation(adapter, session)
        decision = adapter.release(
            session.started.state,
            session.started.started,
        )
        assert isinstance(decision, Retain)
        assert adapter._record_count() == 1
        _assert_no_late_response(adapter, session, peer.release)


def test_release_with_a_state_lacking_the_record_does_not_interrupt() -> None:
    with _GatedPeer() as peer:
        adapter = HttpHostAdapter()
        session = _start(adapter, _input(peer.target))
        assert isinstance(session, _Session)
        _wait_accepted(peer)
        decision = adapter.release(
            ne.empty_network_state(),
            session.started.started,
        )
        assert isinstance(decision, Retain)
        time.sleep(0.1)
        assert not _worker_stopped(adapter, session)
        assert adapter._record_count() == 1
        peer.release.set()
        delivered = _poll(adapter, session)
        assert isinstance(delivered.observation, ne.ResponseObservation)
        terminal = ne.observe(session.started.state, delivered)
        assert isinstance(terminal, ne.NetworkTerminalResult)


def _spawn_waiter(
    adapter: HttpHostAdapter,
    session: _Session,
) -> queue.Queue[object]:
    started = session.started.started
    results: queue.Queue[object] = queue.Queue()
    worker = adapter._workers[started.handle]
    waiter = threading.Thread(
        target=lambda: results.put(adapter._wait_observation(started)),
        daemon=True,
    )
    waiter.start()
    stop_at = time.monotonic() + 5.0
    while not getattr(worker.changed, "_waiters"):
        assert time.monotonic() < stop_at, "waiter never started waiting"
        time.sleep(0.001)
    return results


def _assert_waiter_returns_unknown(
    results: queue.Queue[object],
    session: _Session,
) -> None:
    try:
        result = results.get(timeout=5.0)
    except queue.Empty:
        raise AssertionError("waiter did not return within the limit")
    assert result == UnknownExecution(session.started.started.handle)


def test_a_waiter_returns_unknown_when_the_record_is_removed_after_a_terminal_release() -> None:
    with _GatedPeer() as peer:
        adapter, session, rejected = _rejected_cancel_session(peer)
        terminal = ne.observe(session.started.state, rejected)
        assert isinstance(terminal, ne.NetworkTerminalResult)
        results = _spawn_waiter(adapter, session)
        decision = adapter.release(terminal.state, session.started.started)
        assert isinstance(decision, (Retain, Dematerialize))
        _assert_waiter_returns_unknown(results, session)
        assert adapter._record_count() == 0


def test_a_waiter_returns_unknown_when_a_finished_worker_is_released_and_dematerialized() -> None:
    adapter = HttpHostAdapter()
    with _GatedPeer() as peer:
        peer.release.set()
        session = _start(adapter, _input(peer.target))
        assert isinstance(session, _Session)
        delivered = _poll(adapter, session)
        terminal = ne.observe(session.started.state, delivered)
        assert isinstance(terminal, ne.NetworkTerminalResult)
        started = session.started.started
        stop_at = time.monotonic() + 5.0
        while adapter._workers[started.handle].lifecycle is not _Lifecycle.FINISHED:
            assert time.monotonic() < stop_at, "worker did not finish"
            time.sleep(0.001)
        results = _spawn_waiter(adapter, session)
        decision = adapter.release(terminal.state, started)
        assert isinstance(decision, Dematerialize)
        _assert_waiter_returns_unknown(results, session)
        assert adapter._record_count() == 0


class _AcceptingCancellationPort(EventCancellationPort):
    def __init__(self, capability: ne.CancellationCapability) -> None:
        super().__init__(capability)
        self.calls = 0

    def request(self, handle: ne.ExecutionHandle) -> ne.HostFailure | None:
        self.calls += 1
        return None


def _cancel_with(
    command: ne.CancelCommand,
    capability: ne.CancellationCapability | None = None,
    handle: ne.ExecutionHandle | None = None,
) -> ne.CancelCommand:
    return ne.CancelCommand(
        command.attempt,
        handle or command.handle,
        capability or command.capability,
    )


def test_cancel_with_a_foreign_capability_never_reaches_the_port() -> None:
    cancellation = ne.CancellationCapability(ne.OpaqueEvidence("cancel"))
    foreign = ne.CancellationCapability(ne.OpaqueEvidence("other-cancel"))
    port = _AcceptingCancellationPort(cancellation)
    with _GatedPeer() as peer:
        adapter = HttpHostAdapter(cancellation=port)
        session = _start(
            adapter,
            _input(peer.target, cancellation=cancellation),
        )
        assert isinstance(session, _Session)
        _wait_accepted(peer)
        command = ne.cancel_command(
            session.started.state,
            session.started.started,
        )
        assert isinstance(command, ne.CommandReady)
        assert isinstance(command.command, ne.CancelCommand)
        rejected = adapter.cancel(_cancel_with(command.command, foreign))
        assert isinstance(rejected, ne.DeliveredObservation)
        assert isinstance(rejected.observation, ne.FailureObservation)
        assert isinstance(
            rejected.observation.failure.cause,
            ne.CancellationRejected,
        )
        assert rejected.observation.failure.stage is ne.HostStage.CANCEL
        assert isinstance(rejected.observation.effect, ne.Unknown)
        assert (
            rejected.observation.effect.reason
            is ne.UnknownEffectReason.HOST_FAILURE
        )
        assert port.calls == 0
        _assert_no_late_response(adapter, session, peer.release)


def test_cancel_with_a_foreign_handle_is_unknown_and_never_reaches_the_port() -> None:
    cancellation = ne.CancellationCapability(ne.OpaqueEvidence("cancel"))
    port = _AcceptingCancellationPort(cancellation)
    with _GatedPeer() as peer:
        adapter = HttpHostAdapter(cancellation=port)
        session = _start(
            adapter,
            _input(peer.target, cancellation=cancellation),
        )
        assert isinstance(session, _Session)
        _wait_accepted(peer)
        command = ne.cancel_command(
            session.started.state,
            session.started.started,
        )
        assert isinstance(command, ne.CommandReady)
        assert isinstance(command.command, ne.CancelCommand)
        foreign = ne.ExecutionHandle("foreign-handle")
        assert adapter.cancel(
            _cancel_with(command.command, handle=foreign)
        ) == UnknownExecution(foreign)
        assert port.calls == 0
        peer.release.set()
        delivered = _poll(adapter, session)
        assert isinstance(delivered.observation, ne.ResponseObservation)


def test_interrupting_twice_is_the_same_as_once() -> None:
    with _GatedPeer() as peer:
        adapter = HttpHostAdapter()
        session = _start(adapter, _input(peer.target))
        assert isinstance(session, _Session)
        _wait_accepted(peer)
        worker = adapter._worker(
            session.started.started.handle,
            session.started.started.prepared.input.attempt,
        )
        assert worker is not None
        adapter._interrupt(worker)
        adapter._interrupt(worker)
        _assert_stopped_without_late_observation(adapter, session)
        adapter._interrupt(worker)


class _FirstCallRaisingClock(_Clock):
    def __init__(
        self,
        capability: ne.MonotonicClockCapability,
        values: tuple[int, ...],
    ) -> None:
        super().__init__(capability, values)
        self.calls = 0
        self.raised = 0

    def observe(self) -> ne.MonotonicClockObservation | ne.HostFailure:
        self.calls += 1
        if self.calls == 1:
            self.raised += 1
            raise RuntimeError("first clock failure")
        return super().observe()


class _BasisMismatchClock(_Clock):
    def observe(self) -> ne.MonotonicClockObservation | ne.HostFailure:
        return ne.MonotonicClockObservation(ne.ClockBasis("other"), 100)


class _CapabilityRaisingClock(_Clock):
    def capability(self) -> ne.MonotonicClockCapability:
        raise RuntimeError("clock capability failure")


class _CapabilityRaisingCancellationPort(EventCancellationPort):
    def __init__(self, capability: ne.CancellationCapability) -> None:
        super().__init__(capability)
        self.armed = False

    def capability(self) -> ne.CancellationCapability:
        if self.armed:
            raise RuntimeError("cancellation capability failure")
        return super().capability()


def test_first_clock_exception_in_the_worker_is_a_single_deadline_failure() -> None:
    clock_capability = ne.MonotonicClockCapability(
        ne.OpaqueEvidence("clock"),
        ne.ClockBasis("basis"),
    )
    deadline = ne.Deadline(clock_capability.clock_basis, 10, clock_capability)
    with _GatedPeer() as peer:
        clock = _FirstCallRaisingClock(clock_capability, (0,))
        adapter = HttpHostAdapter(clock=clock)
        session = _start(adapter, _input(peer.target, deadline=deadline))
        assert isinstance(session, _Session)
        stop_at = time.monotonic() + 2.0
        while clock.calls < 1:
            assert time.monotonic() < stop_at, "worker did not observe"
            time.sleep(0.002)
        first = _poll(adapter, session)
        assert isinstance(first.observation, ne.FailureObservation)
        failure = first.observation.failure
        assert failure.stage is ne.HostStage.DEADLINE
        assert isinstance(failure.cause, ne.HostRuntimeFailure)
        assert first.observation.effect == ne.Unknown(
            ne.UnknownEffectReason.HOST_FAILURE
        )
        delivered = 1
        for _ in range(5):
            later = adapter.observe(session.started.started)
            if isinstance(later, ne.DeliveredObservation):
                delivered += 1
            time.sleep(0.02)
        assert delivered == 1
        assert clock.raised == 1
        assert peer.accepted == 0
        _assert_no_late_response(adapter, session, peer.release)


def test_a_clock_at_the_limit_from_the_start_sends_no_request() -> None:
    clock_capability = ne.MonotonicClockCapability(
        ne.OpaqueEvidence("clock"),
        ne.ClockBasis("basis"),
    )
    deadline = ne.Deadline(clock_capability.clock_basis, 10, clock_capability)
    with _GatedPeer() as peer:
        adapter = HttpHostAdapter(clock=_Clock(clock_capability, (10,)))
        session = _start(adapter, _input(peer.target, deadline=deadline))
        assert isinstance(session, _Session)
        time.sleep(0.3)
        assert peer.accepted == 0
        delivered = _poll(adapter, session)
        assert isinstance(delivered.observation, ne.DeadlineObservation)
        assert peer.accepted == 0


def test_clock_with_another_basis_never_reaches_the_deadline() -> None:
    clock_capability = ne.MonotonicClockCapability(
        ne.OpaqueEvidence("clock"),
        ne.ClockBasis("basis"),
    )
    deadline = ne.Deadline(clock_capability.clock_basis, 10, clock_capability)
    with _GatedPeer() as peer:
        adapter = HttpHostAdapter(
            clock=_BasisMismatchClock(clock_capability, (0,))
        )
        session = _start(adapter, _input(peer.target, deadline=deadline))
        assert isinstance(session, _Session)
        _wait_accepted(peer)
        for _ in range(3):
            observed = adapter.observe(session.started.started)
            assert isinstance(observed, ne.PendingObservation)
        peer.release.set()
        delivered = _poll(adapter, session)
        assert isinstance(delivered.observation, ne.ResponseObservation)


def test_cancel_capability_read_exception_is_a_cancel_runtime_failure() -> None:
    cancellation = ne.CancellationCapability(ne.OpaqueEvidence("cancel"))
    port = _CapabilityRaisingCancellationPort(cancellation)
    with _GatedPeer() as peer:
        adapter = HttpHostAdapter(cancellation=port)
        session = _start(
            adapter,
            _input(peer.target, cancellation=cancellation),
        )
        assert isinstance(session, _Session)
        _wait_accepted(peer)
        command = ne.cancel_command(
            session.started.state,
            session.started.started,
        )
        assert isinstance(command, ne.CommandReady)
        assert isinstance(command.command, ne.CancelCommand)
        port.armed = True
        rejected = adapter.cancel(command.command)
        assert isinstance(rejected, ne.DeliveredObservation)
        assert isinstance(rejected.observation, ne.FailureObservation)
        failure = rejected.observation.failure
        assert failure.stage is ne.HostStage.CANCEL
        assert isinstance(failure.cause, ne.HostRuntimeFailure)
        assert rejected.observation.effect == ne.Unknown(
            ne.UnknownEffectReason.HOST_FAILURE
        )
        _assert_no_late_response(adapter, session, peer.release)


def test_start_capability_read_exception_is_a_start_runtime_failure() -> None:
    clock_capability = ne.MonotonicClockCapability(
        ne.OpaqueEvidence("clock"),
        ne.ClockBasis("basis"),
    )
    deadline = ne.Deadline(clock_capability.clock_basis, 10, clock_capability)
    clock_adapter = HttpHostAdapter(
        clock=_CapabilityRaisingClock(clock_capability, (0,))
    )
    by_clock = _start(
        clock_adapter,
        _input("http://127.0.0.1:1/", deadline=deadline),
    )
    assert isinstance(by_clock, ne.StartFailed)
    assert by_clock.failure.stage is ne.HostStage.START
    assert isinstance(by_clock.failure.cause, ne.HostRuntimeFailure)
    assert clock_adapter._record_count() == 0

    cancellation = ne.CancellationCapability(ne.OpaqueEvidence("cancel"))
    port = _CapabilityRaisingCancellationPort(cancellation)
    port.armed = True
    cancel_adapter = HttpHostAdapter(cancellation=port)
    by_cancellation = _start(
        cancel_adapter,
        _input("http://127.0.0.1:1/", cancellation=cancellation),
    )
    assert isinstance(by_cancellation, ne.StartFailed)
    assert by_cancellation.failure.stage is ne.HostStage.START
    assert isinstance(by_cancellation.failure.cause, ne.HostRuntimeFailure)
    assert cancel_adapter._record_count() == 0


class _ReturningFailureClock(_Clock):
    def __init__(
        self,
        capability: ne.MonotonicClockCapability,
        failure: ne.HostFailure,
    ) -> None:
        super().__init__(capability, (0,))
        self.failure = failure
        self.armed = False
        self.returned = 0

    def observe(self) -> ne.MonotonicClockObservation | ne.HostFailure:
        if self.armed:
            self.returned += 1
            return self.failure
        return super().observe()


class _ReturningFailureCancellationPort(EventCancellationPort):
    def __init__(
        self,
        capability: ne.CancellationCapability,
        failure: ne.HostFailure,
    ) -> None:
        super().__init__(capability)
        self.failure = failure

    def request(self, handle: ne.ExecutionHandle) -> ne.HostFailure | None:
        return self.failure


def test_clock_returning_a_failure_is_a_single_deadline_failure() -> None:
    clock_capability = ne.MonotonicClockCapability(
        ne.OpaqueEvidence("clock"),
        ne.ClockBasis("basis"),
    )
    deadline = ne.Deadline(clock_capability.clock_basis, 10, clock_capability)
    with _GatedPeer() as peer:
        clock = _ReturningFailureClock(clock_capability, ne.HostRuntimeFailure())
        adapter = HttpHostAdapter(clock=clock)
        session = _start(adapter, _input(peer.target, deadline=deadline))
        assert isinstance(session, _Session)
        _wait_accepted(peer)
        clock.armed = True
        first = _poll(adapter, session)
        assert isinstance(first.observation, ne.FailureObservation)
        failure = first.observation.failure
        assert failure.stage is ne.HostStage.DEADLINE
        assert isinstance(failure.cause, ne.HostRuntimeFailure)
        assert first.observation.effect == ne.Unknown(
            ne.UnknownEffectReason.HOST_FAILURE
        )
        delivered = 1
        for _ in range(5):
            later = adapter.observe(session.started.started)
            if isinstance(later, ne.DeliveredObservation):
                delivered += 1
            time.sleep(0.02)
        assert delivered == 1
        assert clock.returned == 1
        _assert_no_late_response(adapter, session, peer.release)


def test_clock_returning_a_timeout_failure_keeps_the_stage_of_the_timeout() -> None:
    clock_capability = ne.MonotonicClockCapability(
        ne.OpaqueEvidence("clock"),
        ne.ClockBasis("basis"),
    )
    deadline = ne.Deadline(clock_capability.clock_basis, 10, clock_capability)
    timeout = ne.Timeout(
        ne.HostStage.RESPONSE_BODY,
        ne.HostTimeoutCause.LIBRARY_REPORTED,
    )
    with _GatedPeer() as peer:
        clock = _ReturningFailureClock(clock_capability, timeout)
        adapter = HttpHostAdapter(clock=clock)
        session = _start(adapter, _input(peer.target, deadline=deadline))
        assert isinstance(session, _Session)
        _wait_accepted(peer)
        clock.armed = True
        first = _poll(adapter, session)
        assert isinstance(first.observation, ne.FailureObservation)
        assert first.observation.failure.stage is ne.HostStage.RESPONSE_BODY
        assert first.observation.failure.cause == timeout
        _assert_no_late_response(adapter, session, peer.release)


def test_cancel_port_returning_rejection_is_a_cancel_rejection() -> None:
    cancellation = ne.CancellationCapability(ne.OpaqueEvidence("cancel"))
    port = _ReturningFailureCancellationPort(
        cancellation,
        ne.CancellationRejected(),
    )
    with _GatedPeer() as peer:
        adapter = HttpHostAdapter(cancellation=port)
        session = _start(
            adapter,
            _input(peer.target, cancellation=cancellation),
        )
        assert isinstance(session, _Session)
        _wait_accepted(peer)
        command = ne.cancel_command(
            session.started.state,
            session.started.started,
        )
        assert isinstance(command, ne.CommandReady)
        assert isinstance(command.command, ne.CancelCommand)
        rejected = adapter.cancel(command.command)
        assert isinstance(rejected, ne.DeliveredObservation)
        assert isinstance(rejected.observation, ne.FailureObservation)
        failure = rejected.observation.failure
        assert failure.stage is ne.HostStage.CANCEL
        assert isinstance(failure.cause, ne.CancellationRejected)
        assert rejected.observation.effect == ne.Unknown(
            ne.UnknownEffectReason.HOST_FAILURE
        )
        _assert_no_late_response(adapter, session, peer.release)


def test_cancel_port_returning_a_failure_keeps_the_returned_cause() -> None:
    cancellation = ne.CancellationCapability(ne.OpaqueEvidence("cancel"))
    timeout = ne.Timeout(
        ne.HostStage.RESPONSE_HEADERS,
        ne.HostTimeoutCause.LIBRARY_REPORTED,
    )
    port = _ReturningFailureCancellationPort(cancellation, timeout)
    with _GatedPeer() as peer:
        adapter = HttpHostAdapter(cancellation=port)
        session = _start(
            adapter,
            _input(peer.target, cancellation=cancellation),
        )
        assert isinstance(session, _Session)
        _wait_accepted(peer)
        command = ne.cancel_command(
            session.started.state,
            session.started.started,
        )
        assert isinstance(command, ne.CommandReady)
        assert isinstance(command.command, ne.CancelCommand)
        failed = adapter.cancel(command.command)
        assert isinstance(failed, ne.DeliveredObservation)
        assert isinstance(failed.observation, ne.FailureObservation)
        assert failed.observation.failure.stage is ne.HostStage.RESPONSE_HEADERS
        assert failed.observation.failure.cause == timeout
        _assert_no_late_response(adapter, session, peer.release)
