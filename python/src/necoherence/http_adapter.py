# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Finite HTTP host adapter for the pure network-effect ledger."""
from __future__ import annotations

from dataclasses import dataclass
import http.client
import queue
import socket
import threading
import time
from typing import Protocol, cast
from urllib.parse import SplitResult, urlsplit

from necoherence import network_effect as ne


class MonotonicClockPort(Protocol):
    def capability(self) -> ne.MonotonicClockCapability: ...
    def observe(self) -> ne.MonotonicClockObservation: ...


class CancellationPort(Protocol):
    def capability(self) -> ne.CancellationCapability: ...
    def request(
        self,
        capability: ne.CancellationCapability,
        handle: ne.ExecutionHandle,
    ) -> bool: ...


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

    def observe(self) -> ne.MonotonicClockObservation:
        return ne.MonotonicClockObservation(
            self._capability.clock_basis,
            time.monotonic_ns(),
        )


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

    def request(
        self,
        capability: ne.CancellationCapability,
        handle: ne.ExecutionHandle,
    ) -> bool:
        if capability != self._capability:
            return False
        with self._lock:
            event = self._events.get(handle)
        if event is None:
            return False
        event.set()
        return True

    def cancelled(self, handle: ne.ExecutionHandle) -> bool:
        with self._lock:
            event = self._events.get(handle)
        return event is not None and event.is_set()


@dataclass(slots=True)
class _Worker:
    command: ne.SendCommand
    queue: queue.SimpleQueue[ne.AdapterObservation]
    cancel: threading.Event
    next_source: int = 1
    delivery: int = 0
    deadline_emitted: bool = False


class HttpHostAdapter:
    def __init__(
        self,
        clock: MonotonicClockPort | None = None,
        cancellation: CancellationPort | None = None,
    ) -> None:
        self._clock = clock
        self._cancellation = cancellation or EventCancellationPort()
        self._workers: dict[ne.ExecutionHandle, _Worker] = {}
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
            worker = _Worker(command, queue.SimpleQueue(), threading.Event())
            self._workers[handle] = worker
        register = getattr(self._cancellation, "register", None)
        if callable(register):
            register(handle)
        try:
            thread = threading.Thread(
                target=self._run,
                args=(handle, worker, 0),
                daemon=True,
            )
            thread.start()
        except BaseException:
            with self._lock:
                self._workers.pop(handle, None)
            return self._start_failed(input, ne.ExecutionStartFailed())
        return ne.Started(input.attempt, handle)

    def observe(self, started: ne.StartedAttempt) -> ne.HostObservation:
        worker = self._worker(started.handle, started.prepared.input.attempt)
        if worker is None:
            return ne.PendingObservation(
                started.prepared.input.attempt,
                started.handle,
            )
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

    def cancel(self, command: ne.CancelCommand) -> ne.HostObservation:
        worker = self._worker(command.handle, command.attempt)
        if worker is None:
            return ne.PendingObservation(command.attempt, command.handle)
        observation = self._take(worker)
        if observation is not None:
            return self._delivered(worker, observation)
        source = self._reserve_source(worker)
        if self._cancellation.request(command.capability, command.handle):
            worker.cancel.set()
            observation = ne.CancellationObservation(
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
                ne.HostStage.CANCEL,
                ne.CancellationRejected(),
            )
        return self._delivered(worker, observation)

    def close(self, started: ne.StartedAttempt) -> ne.HostObservation:
        worker = self._worker(
            started.handle,
            started.prepared.input.attempt,
        )
        if worker is None:
            return ne.PendingObservation(
                started.prepared.input.attempt,
                started.handle,
            )
        source = self._reserve_source(worker)
        observation = self._failure_observation(
            worker.command.prepared.input,
            started.handle,
            source,
            ne.HostStage.RESPONSE_BODY,
            ne.HostClosed(),
        )
        return self._delivered(worker, observation)

    def _start_failure(self, input: ne.AttemptInput) -> ne.HostFailure | None:
        target = urlsplit(input.instruction.target)
        if target.scheme not in {"http", "https"}:
            return ne.UnsupportedUriScheme()
        if not ne.valid_attempt_input(input):
            return ne.InvalidHostConfiguration()
        if input.deadline is not None:
            if (
                self._clock is None
                or self._clock.capability() != input.deadline.capability
                or input.configuration.monotonic_clock
                != input.deadline.capability
            ):
                return ne.DeadlineControlUnavailable()
        if input.configuration.cancellation is not None:
            capability = getattr(self._cancellation, "capability", None)
            if (
                not callable(capability)
                or capability() != input.configuration.cancellation
            ):
                return ne.InvalidHostConfiguration()
        return None

    def _run(
        self,
        handle: ne.ExecutionHandle,
        worker: _Worker,
        source: int,
    ) -> None:
        input = worker.command.prepared.input
        try:
            deadline = self._deadline_observation(
                input,
                handle,
                source,
            )
            outcome = (
                deadline
                if deadline is not None
                else self._request(handle, input, source)
            )
        except BaseException as error:
            stage, cause = self._classify_exception(error)
            outcome = self._failure_observation(
                input,
                handle,
                source,
                stage,
                cause,
            )
        worker.queue.put(outcome)

    def _request(
        self,
        handle: ne.ExecutionHandle,
        input: ne.AttemptInput,
        source: int,
    ) -> ne.AdapterObservation:
        instruction = input.instruction
        target = urlsplit(instruction.target)
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
        try:
            try:
                connection.connect()
            except socket.gaierror:
                return self._failure_observation(
                    input,
                    handle,
                    source,
                    ne.HostStage.REQUEST_WRITE,
                    ne.NameResolutionFailed(),
                )
            except (ConnectionError, OSError):
                return self._failure_observation(
                    input,
                    handle,
                    source,
                    ne.HostStage.REQUEST_WRITE,
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
                connection.endheaders(bytes(instruction.body))
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
                    tuple(body),
                ),
                ne.HeaderProvenance.LIBRARY_OBSERVED,
                ne.Unknown(ne.UnknownEffectReason.NO_RESPONSE),
            )
        finally:
            connection.close()

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
        return header.name, bytes(header.value).decode("latin-1")

    def _encode_response_header(
        self,
        name: str,
        value: str,
    ) -> ne.RawHeaderField:
        return ne.RawHeaderField(name, tuple(value.encode("latin-1")))

    def _enqueue_deadline(
        self,
        handle: ne.ExecutionHandle,
        worker: _Worker,
    ) -> None:
        if worker.deadline_emitted:
            return
        source = self._reserve_source(worker)
        observation = self._deadline_observation(
            worker.command.prepared.input,
            handle,
            source,
        )
        if observation is not None:
            worker.deadline_emitted = True
            worker.queue.put(observation)

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
        if observed.clock_basis != deadline.clock_basis:
            return self._failure_observation(
                input,
                handle,
                source,
                ne.HostStage.DEADLINE,
                ne.DeadlineControlUnavailable(),
                ne.UnknownEffectReason.DEADLINE,
            )
        if deadline.limit <= observed.value:
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
    ) -> tuple[ne.HostStage, ne.HostFailure]:
        if isinstance(error, socket.gaierror):
            return ne.HostStage.REQUEST_WRITE, ne.NameResolutionFailed()
        if isinstance(error, socket.timeout):
            return (
                ne.HostStage.RESPONSE_BODY,
                ne.Timeout(
                    ne.HostStage.RESPONSE_BODY,
                    ne.HostTimeoutCause.LIBRARY_REPORTED,
                ),
            )
        return ne.HostStage.RESPONSE_BODY, ne.HostRuntimeFailure()


__all__ = [
    "CancellationPort",
    "EventCancellationPort",
    "HttpHostAdapter",
    "MonotonicClockPort",
    "SystemMonotonicClock",
]
