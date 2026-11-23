# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT


from __future__ import annotations

from dataclasses import asdict, dataclass, field
from queue import Empty, Queue
from threading import Event, Thread
from time import monotonic
from typing import Any, Iterable


@dataclass(frozen=True)
class ResponseAction:
    status: int = 200
    headers: tuple[tuple[str, tuple[int, ...]], ...] = ()
    body: tuple[int, ...] = ()
    source_sequence: int | None = None
    effect: str = "Unknown"


@dataclass(frozen=True)
class FailureAction:
    cause: str
    stage: str = "Start"
    source_sequence: int | None = None
    effect: str = "Unknown"


@dataclass(frozen=True)
class CancelAction:
    source_sequence: int | None = None
    effect: str = "Unknown"


@dataclass(frozen=True)
class DeadlineAction:
    limit: int
    observed_at: int
    clock_basis: str = "generated"
    source_sequence: int | None = None
    effect: str = "Unknown"


@dataclass(frozen=True)
class StartFailureAction:
    cause: str = "ExecutionStartFailed"
    stage: str = "Start"
    effect: str = "Unknown"


@dataclass(frozen=True)
class MockEvent:
    kind: str
    handle: str | None
    source_sequence: int | None
    payload: Any = None
    delivery: int | None = None


@dataclass
class MockRun:
    attempt: tuple[str, int]
    handle: str
    started: bool
    start_failure: StartFailureAction | None
    _queue: Queue[MockEvent] = field(default_factory=Queue, repr=False)
    _delivery: int = field(default=0, repr=False)
    _closed: bool = field(default=False, repr=False)

    def enqueue(self, event: MockEvent) -> None:
        if not self._closed:
            self._queue.put(event)

    def observe(self) -> MockEvent:
        try:
            event = self._queue.get_nowait()
        except Empty:
            return MockEvent("Pending", self.handle, None)
        delivered = MockEvent(
            event.kind, event.handle, event.source_sequence, event.payload, self._delivery
        )
        self._delivery += 1
        return delivered

    def cancel(self) -> MockEvent:
        if self._closed:
            return MockEvent("Rejected", self.handle, None, "HostClosed")
        self.enqueue(MockEvent("Cancellation", self.handle, None, CancelAction()))
        return self.observe()

    def close(self) -> None:
        self._closed = True


class MockAdapter:

    def __init__(self, actions: Iterable[Any] = ()) -> None:
        self._actions = tuple(actions)
        self._runs: dict[tuple[str, int], MockRun] = {}
        self._counter = 0

    def start(self, attempt: tuple[str, int], *, actions: Iterable[Any] | None = None) -> MockRun:
        selected = tuple(self._actions if actions is None else actions)
        self._counter += 1
        handle = f"mock-handle-{self._counter}"
        start_failure = next((a for a in selected if isinstance(a, StartFailureAction)), None)
        run = MockRun(attempt, handle, start_failure is None, start_failure)
        self._runs[attempt] = run
        ready = Event()
        if start_failure is None:
            Thread(target=self._produce, args=(run, selected, ready), daemon=True).start()
            ready.wait(1.0)
        return run

    @staticmethod
    def _event_for(action: Any, handle: str) -> MockEvent | None:
        if isinstance(action, ResponseAction):
            return MockEvent("Response", handle, action.source_sequence, action)
        if isinstance(action, FailureAction):
            return MockEvent("Failure", handle, action.source_sequence, action)
        if isinstance(action, CancelAction):
            return MockEvent("Cancellation", handle, action.source_sequence, action)
        if isinstance(action, DeadlineAction):
            return MockEvent("Deadline", handle, action.source_sequence, action)
        return None

    @classmethod
    def _produce(cls, run: MockRun, actions: tuple[Any, ...], ready: Event) -> None:
        try:
            for action in actions:
                if isinstance(action, StartFailureAction):
                    continue
                event = cls._event_for(action, run.handle)
                if event is not None:
                    run.enqueue(event)
        finally:
            ready.set()

    def observe(self, attempt: tuple[str, int]) -> MockEvent:
        return self._runs[attempt].observe()

    def cancel(self, attempt: tuple[str, int]) -> MockEvent:
        return self._runs[attempt].cancel()

    def close(self, attempt: tuple[str, int]) -> None:
        self._runs[attempt].close()

    @property
    def issued_count(self) -> int:
        return self._counter


def response_action(*, status: int = 200, headers: Iterable[tuple[str, Iterable[int]]] = (), body: Iterable[int] = (), source_sequence: int | None = None) -> ResponseAction:
    return ResponseAction(status, tuple((name, tuple(value)) for name, value in headers), tuple(body), source_sequence)


def failure_action(cause: str, *, stage: str = "Start", source_sequence: int | None = None) -> FailureAction:
    return FailureAction(cause, stage, source_sequence)


def run_race(
    order: Iterable[str],
    source_sequences: Iterable[int] | None = None,
) -> dict[str, Any]:
    kinds = tuple(order)
    sources = (
        tuple(range(len(kinds)))
        if source_sequences is None
        else tuple(source_sequences)
    )
    if len(kinds) != len(sources):
        raise ValueError("source sequence count must equal action count")
    actions: list[Any] = []
    for source_sequence, kind in zip(sources, kinds):
        if kind == "response":
            actions.append(response_action(source_sequence=source_sequence))
        elif kind == "cancel":
            actions.append(CancelAction(source_sequence=source_sequence))
        elif kind == "deadline":
            actions.append(DeadlineAction(limit=10, observed_at=10, source_sequence=source_sequence))
        elif kind == "failure":
            actions.append(failure_action("HostRuntimeFailure", source_sequence=source_sequence))
    adapter = MockAdapter(actions)
    run = adapter.start(("generated", 0))
    events = [run.observe() for _ in range(len(actions) + 1)]
    winner = next((event.kind for event in events if event.kind != "Pending"), "Pending")
    delivered_sources = [
        event.source_sequence
        for event in events
        if event.kind != "Pending"
    ]
    return {
        "attempt": ["generated", 0],
        "handle": run.handle,
        "sourceSequences": list(sources),
        "sourceDeliveryRelation": (
            "same-order"
            if delivered_sources == list(range(len(delivered_sources)))
            else "reverse-order"
        ),
        "events": [
            {
                **{key: value for key, value in event.__dict__.items() if key != "payload"},
                "payload": asdict(event.payload) if hasattr(event.payload, "__dataclass_fields__") else event.payload,
            }
            for event in events
        ],
        "firstDelivery": next((event.delivery for event in events if event.kind != "Pending"), None),
        "winner": winner,
        "issuedCommandCount": adapter.issued_count,
    }


__all__ = [
    "CancelAction",
    "DeadlineAction",
    "FailureAction",
    "MockAdapter",
    "MockEvent",
    "MockRun",
    "ResponseAction",
    "StartFailureAction",
    "failure_action",
    "response_action",
    "run_race",
]
