# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Finite HTTP host adapter for the pure network-effect ledger."""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from enum import Enum, auto
import http.client
import errno
import queue
import select
import socket
import threading
import time
from collections.abc import Callable
from typing import Any, Protocol, cast
from urllib.parse import SplitResult, urlsplit

from necoherence import network_effect as ne
from necoherence import semantic_execution as se
from neco_quotient_retention import Dematerialize, Retain


class MonotonicClockPort(Protocol):
    def capability(self) -> ne.MonotonicClockCapability: ...
    def observe(self) -> ne.MonotonicClockObservation | ne.HostFailure: ...


class WaitingMonotonicClockPort(MonotonicClockPort, Protocol):
    def until(self, limit: int) -> float | None: ...


class CancellationPort(Protocol):
    def capability(self) -> ne.CancellationCapability: ...
    def request(self, handle: ne.ExecutionHandle) -> ne.HostFailure | None: ...


class SystemMonotonicClock:
    def __init__(
        self,
        capability: ne.MonotonicClockCapability | None = None,
    ) -> None:
        self._capability = capability or ne.MonotonicClockCapability(
            ne.OpaqueEvidence("python-system-monotonic-clock"),
            ne.ClockBasis("python-monotonic"),
        )

    def capability(self) -> ne.MonotonicClockCapability:
        return self._capability

    def observe(self) -> ne.MonotonicClockObservation | ne.HostFailure:
        return ne.MonotonicClockObservation(
            self._capability.clock_basis,
            time.monotonic_ns(),
        )

    def until(self, limit: int) -> float | None:
        return max(0, limit - time.monotonic_ns()) / 1_000_000_000


class EventCancellationPort:
    def __init__(
        self,
        capability: ne.CancellationCapability | None = None,
    ) -> None:
        self._capability = capability or ne.CancellationCapability(
            ne.OpaqueEvidence("python-event-cancellation")
        )
        self._events: dict[ne.ExecutionHandle, threading.Event] = {}
        self._lock = threading.Lock()

    def capability(self) -> ne.CancellationCapability:
        return self._capability

    def register(self, handle: ne.ExecutionHandle) -> None:
        with self._lock:
            self._events[handle] = threading.Event()

    def unregister(self, handle: ne.ExecutionHandle) -> None:
        with self._lock:
            self._events.pop(handle, None)

    def request(self, handle: ne.ExecutionHandle) -> ne.HostFailure | None:
        with self._lock:
            event = self._events.get(handle)
        if event is None:
            return ne.CancellationRejected()
        event.set()
        return None

    def cancelled(self, handle: ne.ExecutionHandle) -> bool:
        with self._lock:
            event = self._events.get(handle)
        return event is not None and event.is_set()


class _Lifecycle(Enum):
    RUNNING = auto()
    RUNNING_SETTLED = auto()
    FINISHED = auto()
    RELEASED = auto()


@dataclass(slots=True)
class _Worker:
    command: ne.SendCommand
    queue: queue.SimpleQueue[ne.AdapterObservation]
    next_source: int = 1
    delivery: int = 0
    deadline_emitted: bool = False
    lifecycle: _Lifecycle = _Lifecycle.RUNNING
    interrupted: bool = False
    stage: ne.HostStage = ne.HostStage.REQUEST_WRITE
    sockets: list[socket.socket] = field(default_factory=list)
    wake_read: socket.socket | None = None
    wake_write: socket.socket | None = None
    changed: threading.Condition = field(default_factory=threading.Condition)

    @property
    def is_running(self) -> bool:
        return self.lifecycle in (
            _Lifecycle.RUNNING,
            _Lifecycle.RUNNING_SETTLED,
        )

    def finish(self) -> bool:
        with self.changed:
            previous = self.lifecycle
            if previous is _Lifecycle.RUNNING:
                self.lifecycle = _Lifecycle.FINISHED
            elif previous is _Lifecycle.RUNNING_SETTLED:
                self.lifecycle = _Lifecycle.RELEASED
            self.changed.notify_all()
        return previous is _Lifecycle.RUNNING_SETTLED

    def settle(self) -> _Lifecycle:
        with self.changed:
            previous = self.lifecycle
            if previous is _Lifecycle.RUNNING:
                self.lifecycle = _Lifecycle.RUNNING_SETTLED
            elif previous is _Lifecycle.FINISHED:
                self.lifecycle = _Lifecycle.RELEASED
        return previous

    def discard(self) -> bool:
        with self.changed:
            previous = self.lifecycle
            self.lifecycle = _Lifecycle.RELEASED
        return previous is not _Lifecycle.RELEASED


@dataclass(frozen=True, slots=True)
class UnknownExecution:
    handle: ne.ExecutionHandle


@dataclass(frozen=True, slots=True)
class DeadlineWaitUnavailable:
    handle: ne.ExecutionHandle


class HttpHostAdapter:
    def __init__(
        self,
        clock: MonotonicClockPort | None = None,
        cancellation: CancellationPort | None = None,
    ) -> None:
        self._clock = clock
        self._cancellation = cancellation or EventCancellationPort()
        self._workers: dict[ne.ExecutionHandle, _Worker] = {}
        self._executor = ThreadPoolExecutor()
        self._counter = 0
        self._lock = threading.Lock()

    def start(self, command: ne.SendCommand) -> ne.Started | ne.StartFailed:
        input = command.prepared.input
        failure = self._start_failure(input)
        if failure is not None:
            return self._start_failed(input, failure)
        with self._lock:
            handle = ne.ExecutionHandle(f"python-http-{self._counter}")
            self._counter += 1
            worker = _Worker(command, queue.SimpleQueue())
            self._workers[handle] = worker
        register = getattr(self._cancellation, "register", None)
        if callable(register):
            register(handle)
        try:
            self._executor.submit(self._run, handle, worker, 0)
        except BaseException:
            with self._lock:
                self._workers.pop(handle, None)
            return self._start_failed(input, ne.ExecutionStartFailed())
        return ne.Started(input.attempt, handle)

    def observe(
        self,
        started: ne.StartedAttempt,
    ) -> ne.HostObservation | UnknownExecution:
        worker = self._worker(started.handle, started.prepared.input.attempt)
        if worker is None:
            return UnknownExecution(started.handle)
        observation = self._take(worker)
        if observation is not None:
            return self._delivered(worker, observation)
        self._enqueue_deadline(started.handle, worker)
        observation = self._take(worker)
        if observation is not None:
            return self._delivered(worker, observation)
        return ne.PendingObservation(
            worker.command.prepared.input.attempt,
            started.handle,
        )

    def cancel(
        self,
        command: ne.CancelCommand,
    ) -> ne.HostObservation | UnknownExecution:
        worker = self._worker(command.handle, command.attempt)
        if worker is None:
            return UnknownExecution(command.handle)
        source = self._reserve_source(worker)
        requested: ne.HostFailure | None
        try:
            if command.capability != self._cancellation.capability():
                requested = ne.CancellationRejected()
            else:
                requested = self._cancellation.request(command.handle)
        except Exception:
            requested = ne.HostRuntimeFailure()
        if requested is None:
            observation: ne.AdapterObservation = ne.CancellationObservation(
                command.attempt,
                command.handle,
                source,
                ne.Unknown(ne.UnknownEffectReason.CANCELLATION),
            )
        else:
            observation = self._failure_observation(
                worker.command.prepared.input,
                command.handle,
                source,
                self._stage_for_cause(ne.HostStage.CANCEL, requested),
                requested,
            )
        self._publish(worker, observation)
        taken = self._take(worker)
        if taken is None:
            return UnknownExecution(command.handle)
        return self._delivered(worker, taken)

    def close(
        self,
        started: ne.StartedAttempt,
    ) -> ne.HostObservation | UnknownExecution:
        worker = self._worker(
            started.handle,
            started.prepared.input.attempt,
        )
        if worker is None:
            return UnknownExecution(started.handle)
        source = self._reserve_source(worker)
        observation = self._failure_observation(
            worker.command.prepared.input,
            started.handle,
            source,
            ne.HostStage.CANCEL,
            ne.HostClosed(),
        )
        self._publish(worker, observation)
        taken = self._take(worker)
        if taken is None:
            return UnknownExecution(started.handle)
        return self._delivered(worker, taken)

    def release(
        self,
        state: ne.NetworkState,
        started: ne.StartedAttempt,
    ) -> ne.ErasureDecision[
        ne.AttemptIdentity,
        None,
        None,
        None,
        ne.HostRecordObservation,
    ]:
        attempt = started.prepared.input.attempt
        worker = self._worker(started.handle, attempt)
        running = worker is not None and worker.is_running
        decision = ne.release_host_record(
            state,
            lambda _key: running,
            attempt,
        )
        if worker is not None:
            if isinstance(decision, ne.Dematerialize):
                if worker.discard():
                    self._detach(started.handle, worker)
            elif isinstance(decision, Retain) and ne.host_settled(
                state,
                attempt,
            ):
                if worker.settle() is _Lifecycle.FINISHED:
                    self._detach(started.handle, worker)
        return decision

    def _detach(self, handle: ne.ExecutionHandle, worker: _Worker) -> None:
        with self._lock:
            self._workers.pop(handle, None)
        with worker.changed:
            worker.changed.notify_all()
        unregister = getattr(self._cancellation, "unregister", None)
        if callable(unregister):
            unregister(handle)

    def _notify(self, worker: _Worker) -> None:
        with worker.changed:
            worker.changed.notify_all()

    def _wait_observation(
        self,
        started: ne.StartedAttempt,
    ) -> ne.HostObservation | UnknownExecution | DeadlineWaitUnavailable:
        while True:
            observed = self.observe(started)
            if not isinstance(observed, ne.PendingObservation):
                return observed
            worker = self._worker(started.handle, started.prepared.input.attempt)
            if worker is None:
                return UnknownExecution(started.handle)
            timeout: float | None = None
            deadline = worker.command.prepared.input.deadline
            if deadline is not None and not worker.deadline_emitted:
                try:
                    length = self._deadline_wait(deadline.limit)
                except Exception:
                    self._enqueue_clock_failure(started.handle, worker)
                    continue
                if length is None:
                    return DeadlineWaitUnavailable(started.handle)
                timeout = max(length, 0.001)
            with worker.changed:
                worker.changed.wait_for(
                    lambda: not worker.queue.empty()
                    or worker.lifecycle is _Lifecycle.RELEASED,
                    timeout,
                )

    def _deadline_wait(self, limit: int) -> float | None:
        until = getattr(self._clock, "until", None)
        if not callable(until):
            return None
        length = until(limit)
        return None if length is None else float(length)

    def _sweep(
        self,
        state: ne.NetworkState,
        candidates: list[ne.StartedAttempt],
    ) -> list[ne.StartedAttempt]:
        return [
            started
            for started in candidates
            if not isinstance(self.release(state, started), Dematerialize)
        ]

    def _finish(
        self,
        state: ne.NetworkState,
        candidates: list[ne.StartedAttempt],
    ) -> tuple[ne.StartedAttempt, ...]:
        remaining: list[ne.StartedAttempt] = []
        for started in candidates:
            decision = self.release(state, started)
            if isinstance(decision, Dematerialize):
                continue
            if isinstance(decision, Retain) and ne.host_settled(
                state,
                started.prepared.input.attempt,
            ):
                continue
            remaining.append(started)
        return tuple(remaining)

    def _record_count(self) -> int:
        with self._lock:
            return len(self._workers)

    def _start_failure(self, input: ne.AttemptInput) -> ne.HostFailure | None:
        target = urlsplit(input.instruction.target)
        if target.scheme not in {"http", "https"}:
            return ne.UnsupportedUriScheme()
        if not ne.valid_attempt_input(input):
            return ne.InvalidHostConfiguration()
        if input.deadline is not None:
            if self._clock is None:
                return ne.DeadlineControlUnavailable()
            try:
                clock_capability = self._clock.capability()
            except Exception:
                return ne.HostRuntimeFailure()
            if clock_capability != input.deadline.capability:
                return ne.DeadlineControlUnavailable()
        if input.configuration.cancellation is not None:
            capability = getattr(self._cancellation, "capability", None)
            if not callable(capability):
                return ne.InvalidHostConfiguration()
            try:
                cancellation_capability = capability()
            except Exception:
                return ne.HostRuntimeFailure()
            if cancellation_capability != input.configuration.cancellation:
                return ne.InvalidHostConfiguration()
        return None

    def _run(
        self,
        handle: ne.ExecutionHandle,
        worker: _Worker,
        source: int,
    ) -> None:
        input = worker.command.prepared.input
        deadline_related = False
        try:
            try:
                try:
                    deadline = self._deadline_observation(
                        input,
                        handle,
                        source,
                    )
                except Exception:
                    deadline_related = True
                    outcome: ne.AdapterObservation = self._failure_observation(
                        input,
                        handle,
                        source,
                        ne.HostStage.DEADLINE,
                        ne.HostRuntimeFailure(),
                    )
                else:
                    deadline_related = deadline is not None
                    outcome = (
                        deadline
                        if deadline is not None
                        else self._request(handle, input, source)
                    )
            except BaseException as error:
                stage, cause = self._classify_exception(error, worker.stage)
                outcome = self._failure_observation(
                    input,
                    handle,
                    source,
                    stage,
                    cause,
                )
            self._close_sockets(worker)
            with worker.changed:
                duplicate = deadline_related and worker.deadline_emitted
                if deadline_related:
                    worker.deadline_emitted = True
                if not duplicate and not worker.interrupted:
                    if deadline_related:
                        self._publish(worker, outcome)
                    else:
                        worker.queue.put(outcome)
            self._notify(worker)
        finally:
            self._close_sockets(worker)
            if worker.finish():
                self._detach(handle, worker)

    def _request(
        self,
        handle: ne.ExecutionHandle,
        input: ne.AttemptInput,
        source: int,
    ) -> ne.AdapterObservation:
        instruction = input.instruction
        target = urlsplit(instruction.target)
        with self._lock:
            owner = self._workers.get(handle)
        try:
            headers = tuple(
                self._encode_request_header(header)
                for header in instruction.headers
            )
        except (UnicodeError, ValueError):
            return self._failure_observation(
                input,
                handle,
                source,
                ne.HostStage.REQUEST_WRITE,
                ne.RequestHeaderEncodingUnavailable(),
            )
        connection = self._new_connection(target)
        if owner is not None:
            setattr(
                connection,
                "_create_connection",
                self._interruptible_connector(owner),
            )
        try:
            try:
                connection.connect()
            except socket.gaierror:
                return self._failure_observation(
                    input,
                    handle,
                    source,
                    ne.HostStage.START,
                    ne.NameResolutionFailed(),
                )
            except (ConnectionError, OSError):
                return self._failure_observation(
                    input,
                    handle,
                    source,
                    ne.HostStage.START,
                    ne.ConnectionFailed(),
                )
            try:
                path = target.path or "/"
                if target.query:
                    path += "?" + target.query
                connection.putrequest(
                    instruction.method,
                    path,
                    skip_host=True,
                    skip_accept_encoding=True,
                )
                for name, value in headers:
                    connection.putheader(name, value)
                connection.endheaders(instruction.body)
            except (UnicodeError, ValueError):
                return self._failure_observation(
                    input,
                    handle,
                    source,
                    ne.HostStage.REQUEST_WRITE,
                    ne.RequestHeaderEncodingUnavailable(),
                )
            except (ConnectionError, OSError, http.client.HTTPException):
                return self._failure_observation(
                    input,
                    handle,
                    source,
                    ne.HostStage.REQUEST_WRITE,
                    ne.RequestWriteFailed(),
                )
            if owner is not None:
                owner.stage = ne.HostStage.RESPONSE_HEADERS
            try:
                response = connection.getresponse()
            except socket.timeout:
                return self._failure_observation(
                    input,
                    handle,
                    source,
                    ne.HostStage.RESPONSE_HEADERS,
                    ne.Timeout(
                        ne.HostStage.RESPONSE_HEADERS,
                        ne.HostTimeoutCause.LIBRARY_REPORTED,
                    ),
                )
            except http.client.RemoteDisconnected:
                return self._failure_observation(
                    input,
                    handle,
                    source,
                    ne.HostStage.RESPONSE_HEADERS,
                    ne.ResponseHeadersFailed(),
                )
            except http.client.BadStatusLine:
                return self._failure_observation(
                    input,
                    handle,
                    source,
                    ne.HostStage.RESPONSE_HEADERS,
                    ne.MalformedResponse(),
                )
            except (ConnectionError, OSError, http.client.HTTPException):
                return self._failure_observation(
                    input,
                    handle,
                    source,
                    ne.HostStage.RESPONSE_HEADERS,
                    ne.ResponseHeadersFailed(),
                )
            try:
                response_headers = tuple(
                    self._encode_response_header(name, value)
                    for name, value in response.getheaders()
                )
            except (UnicodeError, ValueError, AttributeError):
                return self._failure_observation(
                    input,
                    handle,
                    source,
                    ne.HostStage.RESPONSE_HEADERS,
                    ne.HeaderRepresentationUnavailable(),
                )
            if owner is not None:
                owner.stage = ne.HostStage.RESPONSE_BODY
            body = bytearray()
            try:
                while True:
                    chunk = response.read(65536)
                    if not chunk:
                        break
                    body.extend(chunk)
                    if (
                        len(body)
                        > input.configuration.response_body_limit
                    ):
                        return self._failure_observation(
                            input,
                            handle,
                            source,
                            ne.HostStage.RESPONSE_BODY,
                            ne.ResponseBodyLimitExceeded(),
                        )
            except socket.timeout:
                return self._failure_observation(
                    input,
                    handle,
                    source,
                    ne.HostStage.RESPONSE_BODY,
                    ne.Timeout(
                        ne.HostStage.RESPONSE_BODY,
                        ne.HostTimeoutCause.LIBRARY_REPORTED,
                    ),
                )
            except (
                http.client.IncompleteRead,
                ConnectionError,
                OSError,
                http.client.HTTPException,
            ):
                return self._failure_observation(
                    input,
                    handle,
                    source,
                    ne.HostStage.RESPONSE_BODY,
                    ne.ResponseBodyFailed(),
                )
            if response.length not in (None, 0):
                return self._failure_observation(
                    input,
                    handle,
                    source,
                    ne.HostStage.RESPONSE_BODY,
                    ne.ResponseBodyFailed(),
                )
            return ne.ResponseObservation(
                input.attempt,
                handle,
                source,
                ne.RawHttpResponse(
                    response.status,
                    response_headers,
                    bytes(body),
                ),
                ne.HeaderProvenance.LIBRARY_OBSERVED,
                ne.Unknown(ne.UnknownEffectReason.PROTOCOL_WITNESS_MISSING),
            )
        finally:
            connection.close()

    def _publish(
        self,
        worker: _Worker,
        observation: ne.AdapterObservation,
    ) -> None:
        with worker.changed:
            worker.queue.put(observation)
            self._interrupt(worker)
            worker.changed.notify_all()

    def _interrupt(self, worker: _Worker) -> None:
        with worker.changed:
            worker.interrupted = True
            if worker.wake_write is not None:
                try:
                    worker.wake_write.send(b"x")
                except OSError:
                    pass
            for duplicate in worker.sockets:
                try:
                    duplicate.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    def _close_sockets(self, worker: _Worker) -> None:
        with worker.changed:
            held = [*worker.sockets, worker.wake_read, worker.wake_write]
            worker.sockets.clear()
            worker.wake_read = None
            worker.wake_write = None
        for item in held:
            if item is not None:
                try:
                    item.close()
                except OSError:
                    pass

    def _interruptible_connector(
        self,
        worker: _Worker,
    ) -> Callable[..., socket.socket]:
        def create(
            address: tuple[str, int],
            timeout: object = None,
            source_address: tuple[str, int] | None = None,
        ) -> socket.socket:
            host, port = address
            limit = (
                socket.getdefaulttimeout()
                if timeout is socket._GLOBAL_DEFAULT_TIMEOUT  # type: ignore[attr-defined]
                else cast("float | None", timeout)
            )
            failure: OSError | None = None
            for family, kind, proto, _, target in socket.getaddrinfo(
                host,
                port,
                0,
                socket.SOCK_STREAM,
            ):
                candidate = socket.socket(family, kind, proto)
                try:
                    if source_address is not None:
                        candidate.bind(source_address)
                    self._connect(worker, candidate, target, limit)
                    return candidate
                except OSError as error:
                    candidate.close()
                    failure = error
            raise failure or OSError("getaddrinfo returns an empty list")

        return create

    def _connect(
        self,
        worker: _Worker,
        candidate: socket.socket,
        target: tuple[Any, ...],
        limit: float | None,
    ) -> None:
        duplicate = candidate.dup()
        with worker.changed:
            if worker.interrupted:
                duplicate.close()
                raise ConnectionAbortedError("request interrupted")
            worker.sockets.append(duplicate)
            if worker.wake_read is None:
                worker.wake_read, worker.wake_write = socket.socketpair()
            wake = worker.wake_read
        candidate.setblocking(False)
        pending = {errno.EINPROGRESS, errno.EWOULDBLOCK, errno.EALREADY, errno.EINTR}
        code = candidate.connect_ex(target)
        if code != 0 and code not in pending:
            raise OSError(code, errno.errorcode.get(code, "connect failed"))
        if code != 0:
            end = None if limit is None else time.monotonic() + limit
            while True:
                left = None if end is None else max(0.0, end - time.monotonic())
                readable, writable, _ = select.select(
                    [wake],
                    [candidate],
                    [],
                    left,
                )
                if worker.interrupted:
                    raise ConnectionAbortedError("request interrupted")
                if writable:
                    break
                if not readable and left is not None and left <= 0.0:
                    raise socket.timeout("timed out")
            failure = candidate.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
            if failure != 0:
                raise OSError(failure, errno.errorcode.get(failure, "connect failed"))
        candidate.settimeout(limit)

    def _new_connection(
        self,
        target: SplitResult,
    ) -> http.client.HTTPConnection:
        connection_type = (
            http.client.HTTPSConnection
            if target.scheme == "https"
            else http.client.HTTPConnection
        )
        return connection_type(cast(str, target.hostname), target.port)

    def _encode_request_header(
        self,
        header: ne.RawHeaderField,
    ) -> tuple[str, str]:
        if any(
            value != 9 and (value < 32 or value == 127)
            for value in header.value
        ):
            raise ValueError("unrepresentable request header")
        return header.name, header.value.decode("latin-1")

    def _encode_response_header(
        self,
        name: str,
        value: str,
    ) -> ne.RawHeaderField:
        return ne.RawHeaderField(name, value.encode("latin-1"))

    def _enqueue_deadline(
        self,
        handle: ne.ExecutionHandle,
        worker: _Worker,
    ) -> None:
        if worker.deadline_emitted:
            return
        source = self._reserve_source(worker)
        try:
            observation = self._deadline_observation(
                worker.command.prepared.input,
                handle,
                source,
            )
        except Exception:
            self._queue_clock_failure(handle, worker, source)
            return
        if observation is not None:
            with worker.changed:
                duplicate = worker.deadline_emitted
                worker.deadline_emitted = True
            if not duplicate:
                self._publish(worker, observation)

    def _enqueue_clock_failure(
        self,
        handle: ne.ExecutionHandle,
        worker: _Worker,
    ) -> None:
        if worker.deadline_emitted:
            return
        self._queue_clock_failure(
            handle,
            worker,
            self._reserve_source(worker),
        )

    def _queue_clock_failure(
        self,
        handle: ne.ExecutionHandle,
        worker: _Worker,
        source: int,
    ) -> None:
        observation = self._failure_observation(
            worker.command.prepared.input,
            handle,
            source,
            ne.HostStage.DEADLINE,
            ne.HostRuntimeFailure(),
        )
        with worker.changed:
            duplicate = worker.deadline_emitted
            worker.deadline_emitted = True
            if not duplicate:
                self._publish(worker, observation)

    def _deadline_observation(
        self,
        input: ne.AttemptInput,
        handle: ne.ExecutionHandle,
        source: int,
    ) -> ne.AdapterObservation | None:
        deadline = input.deadline
        if deadline is None or self._clock is None:
            return None
        observed = self._clock.observe()
        if isinstance(observed, ne.HostFailure):
            return self._failure_observation(
                input,
                handle,
                source,
                self._stage_for_cause(ne.HostStage.DEADLINE, observed),
                observed,
            )
        if (
            observed.clock_basis == deadline.clock_basis
            and deadline.limit <= observed.value
        ):
            return ne.DeadlineObservation(
                input.attempt,
                handle,
                source,
                deadline,
                observed,
                ne.Unknown(ne.UnknownEffectReason.DEADLINE),
            )
        return None

    def _worker(
        self,
        handle: ne.ExecutionHandle,
        attempt: ne.AttemptIdentity,
    ) -> _Worker | None:
        with self._lock:
            worker = self._workers.get(handle)
        if (
            worker is None
            or worker.command.prepared.input.attempt != attempt
        ):
            return None
        return worker

    def _take(
        self,
        worker: _Worker,
    ) -> ne.AdapterObservation | None:
        try:
            return worker.queue.get_nowait()
        except queue.Empty:
            return None

    def _delivered(
        self,
        worker: _Worker,
        observation: ne.AdapterObservation,
    ) -> ne.DeliveredObservation:
        with self._lock:
            delivery = worker.delivery
            worker.delivery += 1
        return ne.DeliveredObservation(delivery, observation)

    def _reserve_source(self, worker: _Worker) -> int:
        with self._lock:
            source = worker.next_source
            worker.next_source += 1
        return source

    def _start_failed(
        self,
        input: ne.AttemptInput,
        cause: ne.HostFailure,
    ) -> ne.StartFailed:
        return ne.StartFailed(
            self._failure(
                input,
                ne.HostStage.START,
                cause,
            ),
            ne.Unknown(ne.UnknownEffectReason.HOST_FAILURE),
        )

    def _failure_observation(
        self,
        input: ne.AttemptInput,
        handle: ne.ExecutionHandle,
        source: int | None,
        stage: ne.HostStage,
        cause: ne.HostFailure,
        reason: ne.UnknownEffectReason = ne.UnknownEffectReason.HOST_FAILURE,
    ) -> ne.FailureObservation:
        return ne.FailureObservation(
            input.attempt,
            handle,
            source,
            self._failure(input, stage, cause),
            ne.Unknown(reason),
        )

    @staticmethod
    def _stage_for_cause(
        default: ne.HostStage,
        cause: ne.HostFailure,
    ) -> ne.HostStage:
        if isinstance(cause, ne.Timeout):
            return cause.stage
        return default

    @staticmethod
    def _failure(
        input: ne.AttemptInput,
        stage: ne.HostStage,
        cause: ne.HostFailure,
    ) -> ne.NetworkHostFailure:
        return ne.NetworkHostFailure(
            input.attempt,
            stage,
            input.configuration,
            cause,
        )

    @staticmethod
    def _classify_exception(
        error: BaseException,
        stage: ne.HostStage,
    ) -> tuple[ne.HostStage, ne.HostFailure]:
        if isinstance(error, socket.gaierror):
            return ne.HostStage.START, ne.NameResolutionFailed()
        if isinstance(error, socket.timeout):
            return (
                ne.HostStage.RESPONSE_BODY,
                ne.Timeout(
                    ne.HostStage.RESPONSE_BODY,
                    ne.HostTimeoutCause.LIBRARY_REPORTED,
                ),
            )
        return stage, ne.HostRuntimeFailure()


@dataclass(frozen=True, slots=True)
class Driven:
    result: se.ExecutionResult
    retained: tuple[ne.StartedAttempt, ...]


@dataclass(frozen=True, slots=True)
class DriveFailure:
    cause: se.RunFailure | UnknownExecution | DeadlineWaitUnavailable
    retained: tuple[ne.StartedAttempt, ...]


def drive(
    adapter: HttpHostAdapter,
    first: se.Progress,
) -> Driven | DriveFailure:
    candidates: list[ne.StartedAttempt] = []
    progress = first
    while True:
        if isinstance(progress, se.Completed):
            return Driven(
                progress.result,
                adapter._finish(progress.network, candidates),
            )
        if not isinstance(progress, se.Pending):
            raise TypeError("drive requires a progress")
        execution = progress.execution
        instruction = progress.instruction
        observation: se.ExecutionObservation
        if isinstance(instruction, se.Send):
            command = instruction.command
            start = adapter.start(command)
            handled = (
                ne.StartedAttempt(command.prepared, start.handle)
                if isinstance(start, ne.Started)
                else None
            )
            observation = se.StartObservation(start)
        elif isinstance(instruction, se.Observe):
            handled = instruction.started
            host = adapter._wait_observation(handled)
            if isinstance(host, UnknownExecution):
                return DriveFailure(
                    host,
                    adapter._finish(execution.network, candidates),
                )
            if isinstance(host, DeadlineWaitUnavailable):
                return DriveFailure(
                    host,
                    adapter._finish(execution.network, candidates),
                )
            observation = se.HostObservation(host)
        else:
            raise TypeError("drive requires a network instruction")
        resumed = se.resume(execution, observation)
        if handled is not None and all(
            known.handle != handled.handle for known in candidates
        ):
            candidates.append(handled)
        if isinstance(resumed, se.RunFailure):
            return DriveFailure(
                resumed,
                adapter._finish(resumed.network, candidates),
            )
        progress = resumed
        state = (
            progress.network
            if isinstance(progress, se.Completed)
            else progress.execution.network
            if isinstance(progress, se.Pending)
            else None
        )
        if state is not None:
            candidates = adapter._sweep(state, candidates)


__all__ = [
    "CancellationPort",
    "DeadlineWaitUnavailable",
    "DriveFailure",
    "Driven",
    "drive",
    "EventCancellationPort",
    "HttpHostAdapter",
    "MonotonicClockPort",
    "SystemMonotonicClock",
    "WaitingMonotonicClockPort",
]
