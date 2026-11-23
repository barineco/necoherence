# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

import queue
import socket
import threading
import time
from dataclasses import replace

from necoherence import network_effect as ne
from necoherence import semantic_composition as sc
from necoherence import semantic_execution as se
from necoherence.request_progression import RequestIdentity
from necoherence_http_adapter import (
    DeadlineWaitUnavailable,
    Driven,
    DriveFailure,
    HttpHostAdapter,
    SystemMonotonicClock,
    UnknownExecution,
    drive,
)

REPEATS = 100


class _DelayPeer:
    def __init__(self, delay: float, held: bool = False) -> None:
        self.delay = delay
        self.gate = threading.Event()
        if not held:
            self.gate.set()
        self._stop = threading.Event()
        self._listener = socket.socket()
        self._listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._listener.bind(("127.0.0.1", 0))
        self._listener.listen(8)
        self._listener.settimeout(0.05)
        self.target = f"http://127.0.0.1:{self._listener.getsockname()[1]}/drive"
        self._thread = threading.Thread(target=self._accept, daemon=True)
        self._thread.start()

    def __enter__(self) -> _DelayPeer:
        return self

    def __exit__(self, *_exc: object) -> None:
        self.gate.set()
        self._stop.set()
        self._thread.join(5)
        self._listener.close()

    def _accept(self) -> None:
        while not self._stop.is_set():
            try:
                connection, _ = self._listener.accept()
            except OSError:
                continue
            threading.Thread(target=self._serve, args=(connection,), daemon=True).start()

    def _serve(self, connection: socket.socket) -> None:
        buffer = b""
        try:
            while True:
                chunk = connection.recv(1024)
                if not chunk:
                    return
                buffer += chunk
                while b"\r\n\r\n" in buffer:
                    _, buffer = buffer.split(b"\r\n\r\n", 1)
                    time.sleep(self.delay)
                    self.gate.wait()
                    connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        except OSError:
            return
        finally:
            connection.close()


_FUNCTION = sc.FunctionRef("http", "1", "0" * 64)
_OUTCOME = sc.OutcomeId("success")


def _prepared() -> sc.PreparedCompositionInput:
    graph = {
        "profile": {
            "reference": {"identity": "test", "revision": "1", "content_digest": "0" * 64},
            "source_refs": [],
        },
        "nodes": [
            {
                "id": "truth",
                "reference": {
                    "source": {
                        "repository": "ncoh-type-signatures",
                        "revision": "1",
                        "path": "",
                        "content_digest": "",
                        "document_id": "",
                        "declared_revision": None,
                    },
                    "definition_name": "truth",
                    "pointer": [],
                },
                "shape": {"tag": "Boolean", "value": {"const_value": None, "default_value": None}},
            }
        ],
        "definitions": [],
    }
    reference = {
        "repository": "ncoh-type-signatures",
        "revision": "1",
        "path": "",
        "content_digest": "",
        "document_id": "",
        "declared_revision": None,
    }
    contract = sc.SlotContract(sc.TypeRef(reference, "truth"), True, False)
    input_value = sc.CompositionInput(
        "composition", "1", sc.SemanticBasis.of(graph), (),
        (sc.InitialInput(sc.InputId("input"), contract, sc.SuppliedValueSource(sc.PresentValue(False)), None),),
        (), sc.GoalSpec((sc.GoalPort(sc.GoalPortId("goal"), contract, sc.ANY_COMPATIBLE),), (), ()),
        sc.InvocationDomain("domain", "1", (), (), (), (), ()), (), (), sc.SearchBounds(),
        sc.SelectionPolicy.ANY_FEASIBLE,
    )
    prepared = sc.prepare_direct_composition(
        graph, input_value, lambda _function, _definition: None, lambda _function, _definition: ()
    )
    assert isinstance(prepared, sc.PreparedCompositionInput)
    return prepared


def _return_plan(prepared: sc.PreparedCompositionInput) -> sc.ReturnPlanTree:
    initial = prepared.input.initial_inputs[0]
    assert isinstance(initial.source, sc.SuppliedValueSource)
    projection = sc.project_slot(initial.contract, (), (), prepared.values)
    assert isinstance(projection, sc.ProjectionCertificate)
    binding = sc.SourceBindingExpr(
        sc.ValueRef(sc.InitialProducer(initial.id), ()),
        projection,
        sc.SuppliedValueCompatibility(initial.source.value),
    )
    terminal = sc.SuccessReturnPlan(((prepared.input.goal.outputs[0].id, binding),))
    return sc.ReturnPlanTree(1, terminal)


def _admitted() -> se.AdmittedComposition:
    base = _prepared()
    signature = sc.FunctionSignature(
        _FUNCTION,
        sc.OperationFunctionForm(sc.DefinitionRef({}, "http")),
        sc.CompositionEffect.HTTP_REQUEST_RESPONSE,
        (),
        (sc.OutcomeContract(_OUTCOME, sc.OutcomeForm.SUCCESS, (), ()),),
        (),
        "provider",
    )
    site = sc.InvocationSite(sc.SiteId(_FUNCTION.identity), _FUNCTION)
    input_value = replace(
        base.input,
        signatures=(signature,),
        allowed_effects=(signature.effect,),
        goal=replace(base.input.goal, failures=()),
        invocation_domain=replace(base.input.invocation_domain, sites=(site,)),
    )
    prepared = sc.prepare_direct_composition(
        base.graph, input_value, base.operation_checker, base.operation_meaning
    )
    assert isinstance(prepared, sc.PreparedCompositionInput)
    invocation = sc.InvocationPlan(sc.SiteId("http"), _FUNCTION, (), ())
    tree = sc.InvokePlanTree(0, invocation, ((_OUTCOME, _return_plan(prepared)),), ())
    plan = sc.CompositionPlan(prepared.input.identity, prepared.input.revision, tree)
    return se.AdmittedComposition(se._admission_token, prepared, plan)


def _provider(target: str, deadline: ne.Deadline | None = None) -> se.Provider:
    attempt = ne.AttemptIdentity(RequestIdentity("semantic", "http", 1), 0)
    attempt_input = ne.AttemptInput(
        attempt,
        ne.HttpWireInstruction("GET", target, (), b""),
        deadline,
        ne.HostConfiguration(
            8, 8, None, None if deadline is None else deadline.capability
        ),
    )
    return se.Provider(
        _FUNCTION,
        se.PreparedHttpProvider(
            se.PreparedNetworkOwner(
                lambda _: se.ReadyCall(attempt_input),
                lambda _: se.CallResult(_OUTCOME, ()),
            )
        ),
    )


def _first(
    admitted: se.AdmittedComposition,
    target: str,
    deadline: ne.Deadline | None = None,
) -> se.Progress:
    started = se.start(
        admitted, (_provider(target, deadline),), (), ne.empty_network_state()
    )
    assert isinstance(started, se.Progress)
    return started


def _manual(adapter: HttpHostAdapter, first: se.Progress) -> se.ExecutionResult:
    progress = first
    while True:
        if isinstance(progress, se.Completed):
            return progress.result
        assert isinstance(progress, se.Pending)
        instruction = progress.instruction
        if isinstance(instruction, se.Send):
            resumed = se.resume(
                progress.execution, se.StartObservation(adapter.start(instruction.command))
            )
        else:
            assert isinstance(instruction, se.Observe)
            while True:
                host = adapter.observe(instruction.started)
                assert not isinstance(host, UnknownExecution)
                if isinstance(host, ne.DeliveredObservation):
                    break
                time.sleep(0.001)
            resumed = se.resume(progress.execution, se.HostObservation(host))
        assert isinstance(resumed, se.Progress)
        progress = resumed


def test_drive_alone_leaves_no_registration_and_matches_the_manual_loop() -> None:
    admitted = _admitted()
    adapter = HttpHostAdapter()
    with _DelayPeer(0.0) as peer:
        expected = _manual(adapter, _first(admitted, peer.target))
        assert adapter._record_count() == 1
        for _ in range(REPEATS):
            driven = drive(adapter, _first(admitted, peer.target))
            assert isinstance(driven, Driven)
            assert driven.retained == ()
            assert driven.result == expected
        assert adapter._record_count() == 1
    adapter2 = HttpHostAdapter()
    with _DelayPeer(0.0) as peer:
        for _ in range(REPEATS):
            driven = drive(adapter2, _first(admitted, peer.target))
            assert isinstance(driven, Driven)
            assert driven.retained == ()
        assert adapter2._record_count() == 0


class _Counting(HttpHostAdapter):
    calls = 0

    def observe(
        self, started: ne.StartedAttempt
    ) -> ne.HostObservation | UnknownExecution:
        self.calls += 1
        return super().observe(started)


def _observe_calls(delay: float) -> int:
    adapter = _Counting()
    with _DelayPeer(delay) as peer:
        driven = drive(adapter, _first(_admitted(), peer.target))
        assert isinstance(driven, Driven)
        assert driven.retained == ()
    return adapter.calls


def test_waiting_does_not_poll_at_a_fixed_interval() -> None:
    short = _observe_calls(0.15)
    long = _observe_calls(0.30)
    assert short == long
    assert short <= 2


def test_unknown_handle_is_returned_as_the_drive_failure() -> None:
    admitted = _admitted()
    adapter = HttpHostAdapter()
    with _DelayPeer(0.0) as peer:
        first = _first(admitted, peer.target)
        assert isinstance(first, se.Pending) and isinstance(first.instruction, se.Send)
        started = adapter.start(first.instruction.command)
        assert isinstance(started, ne.Started)
        resumed = se.resume(first.execution, se.StartObservation(started))
        assert isinstance(resumed, se.Pending)
        assert isinstance(resumed.instruction, se.Observe)
        stale = ne.StartedAttempt(
            resumed.instruction.started.prepared, ne.ExecutionHandle("never-started")
        )
        forged = se.Pending(resumed.execution, se.Observe(stale))
        failure = drive(adapter, forged)
        assert isinstance(failure, DriveFailure)
        assert failure.cause == UnknownExecution(stale.handle)


class _ManualClock:
    def __init__(self) -> None:
        self._capability = ne.MonotonicClockCapability(
            ne.OpaqueEvidence("manual-clock"), ne.ClockBasis("manual")
        )

    def capability(self) -> ne.MonotonicClockCapability:
        return self._capability

    def observe(self) -> ne.MonotonicClockObservation:
        return ne.MonotonicClockObservation(self._capability.clock_basis, 0)


def _deadline_after(clock: SystemMonotonicClock | _ManualClock, millis: int) -> ne.Deadline:
    capability = clock.capability()
    observed = clock.observe()
    assert isinstance(observed, ne.MonotonicClockObservation)
    now = observed.value
    return ne.Deadline(capability.clock_basis, now + millis * 1_000_000, capability)


def _drive_within(
    adapter: HttpHostAdapter,
    target: str,
    deadline: ne.Deadline,
    seconds: float,
) -> tuple[Driven | DriveFailure, float]:
    box: queue.SimpleQueue[tuple[Driven | DriveFailure, float]] = queue.SimpleQueue()

    def run() -> None:
        began = time.monotonic()
        result = drive(adapter, _first(_admitted(), target, deadline))
        assert isinstance(result, (Driven, DriveFailure))
        box.put((result, time.monotonic() - began))

    threading.Thread(target=run, daemon=True).start()
    try:
        return box.get(timeout=seconds)
    except queue.Empty:
        raise AssertionError(f"drive did not return within {seconds}s") from None


def test_deadline_ends_a_wait_on_a_held_peer() -> None:
    clock = SystemMonotonicClock()
    adapter = HttpHostAdapter(clock=clock)
    with _DelayPeer(0.0, held=True) as peer:
        deadline = _deadline_after(clock, 300)
        result, _ = _drive_within(adapter, peer.target, deadline, 2.0)
        assert isinstance(result, DriveFailure)
        assert isinstance(result.cause, se.RunFailure)
        assert isinstance(result.cause.cause, se.NetworkTerminalFailure)
        outcome = result.cause.cause.terminal.outcome
        assert isinstance(outcome, ne.DeadlineExceeded)
        late = (outcome.observed_at.value - deadline.limit) / 1_000_000
        assert late < 250, late
        assert result.retained == ()
        began = time.monotonic()
        while adapter._record_count() != 0:
            assert time.monotonic() - began < 2.0, "the record stayed without the peer being released"
            time.sleep(0.005)


def test_response_before_the_deadline_completes() -> None:
    clock = SystemMonotonicClock()
    calls = _Counting(clock=clock)
    with _DelayPeer(0.1) as peer:
        deadline = _deadline_after(clock, 300)
        result, _ = _drive_within(calls, peer.target, deadline, 3.0)
        assert isinstance(result, Driven)
        assert result.retained == ()
        assert calls._record_count() == 0
        assert calls.calls <= 3


def test_deadline_without_a_wait_length_fails_typed_without_waiting() -> None:
    clock = _ManualClock()
    adapter = HttpHostAdapter(clock=clock)
    with _DelayPeer(0.0, held=True) as peer:
        result, _ = _drive_within(adapter, peer.target, _deadline_after(clock, 300), 1.0)
        assert isinstance(result, DriveFailure)
        assert isinstance(result.cause, DeadlineWaitUnavailable)
        assert len(result.retained) == 1


class _UntilRaisingClock(_ManualClock):
    def until(self, limit: int) -> float | None:
        raise RuntimeError("until failure")


def test_clock_until_exception_ends_the_drive_with_a_host_failure() -> None:
    clock = _UntilRaisingClock()
    adapter = HttpHostAdapter(clock=clock)
    with _DelayPeer(0.0, held=True) as peer:
        result, _ = _drive_within(adapter, peer.target, _deadline_after(clock, 300), 2.0)
        assert isinstance(result, DriveFailure)
        assert isinstance(result.cause, se.RunFailure)
        assert isinstance(result.cause.cause, se.NetworkTerminalFailure)
        outcome = result.cause.cause.terminal.outcome
        assert isinstance(outcome, ne.Failed)
        assert outcome.failure.stage is ne.HostStage.DEADLINE
        assert isinstance(outcome.failure.cause, ne.HostRuntimeFailure)
        began = time.monotonic()
        while adapter._record_count() != 0:
            assert time.monotonic() - began < 2.0, "the record stayed without the peer being released"
            time.sleep(0.005)
