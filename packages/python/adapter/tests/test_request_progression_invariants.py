# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

from typing import Any

from hypothesis import given, settings, strategies as st

from necoherence.request_progression import (
    Accepted,
    AdapterFailed,
    AppliedSignal,
    CancelledAtAdapter,
    Completed,
    CompletionAdapterFailure,
    ConfiguredSafetyLimit,
    DuplicateIdentity,
    EvidenceVersion,
    ExecuteNow,
    ExecutionHandle,
    Ordered,
    Permitted,
    RemainPending,
    RequestEffectClass,
    RequestEntry,
    RequestFootprint,
    RequestIdentity,
    RequestInput,
    RequestPhase,
    RequestPolicy,
    RequestProgressionSnapshot,
    ResourceBudget,
    ResourceDemand,
    Running,
    Started,
    StartAdapterFailure,
    Starting,
    StartCommand,
    StartDecisionRejected,
    apply_completion_observation,
    apply_start_observation,
    decide_cancel,
    decide_start,
    derive_concurrent,
    derive_in_flight,
    derive_pending,
    empty,
    progression_budget,
    progression_current_identity,
    progression_entries,
    progression_policy,
    progression_revision,
    snapshot_of,
    submit,
)

EVIDENCE = EvidenceVersion("e", "d", "a")


def _identity(index: int) -> RequestIdentity:
    return RequestIdentity("k", "p", index)


def _budget() -> ResourceBudget:
    limit = ConfiguredSafetyLimit
    return ResourceBudget(limit("p", 12), limit("i", 12), limit("c", 12))


def _request(index: int, effect_class: RequestEffectClass, demand: tuple[int, int, int]) -> RequestInput:
    identity = _identity(index)
    permission = Ordered(identity, ()) if effect_class is RequestEffectClass.ORDERED_EFFECT else Permitted(identity, ())
    return RequestInput(
        identity, RequestFootprint((), (), effect_class), ResourceDemand(*demand), permission
    )


def _rebuilt(snapshot: RequestProgressionSnapshot) -> RequestProgressionSnapshot:
    rebuilt = snapshot_of(
        progression_policy(snapshot),
        progression_budget(snapshot),
        progression_current_identity(snapshot),
        progression_entries(snapshot),
        progression_revision(snapshot),
    )
    assert isinstance(rebuilt, RequestProgressionSnapshot)
    return rebuilt


def _sum_over(snapshot: RequestProgressionSnapshot, phases: tuple[RequestPhase, ...]) -> ResourceDemand:
    chosen = [entry.demand for entry in progression_entries(snapshot) if entry.phase in phases]
    return ResourceDemand(
        sum(d.pending for d in chosen), sum(d.in_flight for d in chosen), sum(d.concurrent for d in chosen)
    )


def _assert_invariant(snapshot: RequestProgressionSnapshot) -> None:
    rebuilt = _rebuilt(snapshot)
    assert rebuilt == snapshot
    assert derive_pending(snapshot) == _sum_over(snapshot, (RequestPhase.PENDING,))
    assert derive_in_flight(snapshot) == _sum_over(snapshot, (RequestPhase.PREPARING, RequestPhase.PUBLISHING))
    assert derive_concurrent(snapshot) == _sum_over(snapshot, (RequestPhase.PUBLISHING,))
    for entry in progression_entries(snapshot):
        accepted = Accepted(entry.identity)
        selection = ExecuteNow(entry.identity, EVIDENCE, 1)
        assert decide_start(snapshot, accepted, selection) == decide_start(rebuilt, accepted, selection)
        assert decide_cancel(snapshot, entry.identity) == decide_cancel(rebuilt, entry.identity)


def _candidates(
    snapshot: RequestProgressionSnapshot, next_index: int, effect_class: RequestEffectClass, demand: tuple[int, int, int]
) -> list[tuple[str, object]]:
    options: list[tuple[str, object]] = [("submit", _request(next_index, effect_class, demand))]
    for entry in progression_entries(snapshot):
        identity = entry.identity
        options.append(("cancel", identity))
        if entry.phase is RequestPhase.PENDING:
            options.append(("execute", identity))
            options.append(("defer", identity))
        elif entry.phase is RequestPhase.PREPARING:
            options.append(("started", identity))
            options.append(("start-failed", identity))
        elif entry.phase is RequestPhase.PUBLISHING:
            options.append(("completed", entry))
            options.append(("cancelled-at-adapter", entry))
            options.append(("completion-failed", entry))
    return options


def _step(snapshot: RequestProgressionSnapshot, kind: str, argument: object) -> RequestProgressionSnapshot:
    result: Any
    if kind == "submit":
        assert isinstance(argument, RequestInput)
        result = submit(snapshot, argument)
    elif kind == "cancel":
        assert isinstance(argument, RequestIdentity)
        result = decide_cancel(snapshot, argument)
    elif kind in ("execute", "defer"):
        assert isinstance(argument, RequestIdentity)
        selection = ExecuteNow(argument, EVIDENCE, 1) if kind == "execute" else RemainPending(argument, EVIDENCE, 1)
        result = decide_start(snapshot, Accepted(argument), selection)
    elif kind in ("started", "start-failed"):
        assert isinstance(argument, RequestIdentity)
        starting = Starting(argument, StartCommand(argument, RequestFootprint((), (), RequestEffectClass.PURE)))
        observed: Any = (
            AppliedSignal(Started(argument, ExecutionHandle(f"h{argument.revision}")))
            if kind == "started"
            else AdapterFailed(StartAdapterFailure(argument, "x"))
        )
        result = apply_start_observation(snapshot, starting, observed)
    else:
        assert isinstance(argument, RequestEntry)
        handle = argument.execution_handle
        assert handle is not None
        running = Running(argument.identity, handle)
        observed2: Any
        if kind == "completed":
            observed2 =AppliedSignal(Completed(argument.identity, handle, "v"))
        elif kind == "cancelled-at-adapter":
            observed2 = AppliedSignal(CancelledAtAdapter(argument.identity, handle))
        else:
            observed2 = AdapterFailed(CompletionAdapterFailure(argument.identity, handle, "x"))
        result = apply_completion_observation(snapshot, running, observed2)
    return result.snapshot


@settings(max_examples=60, deadline=None)
@given(
    st.sampled_from(list(RequestPolicy)),
    st.lists(
        st.tuples(
            st.integers(0, 10**6),
            st.sampled_from(list(RequestEffectClass)),
            st.tuples(st.integers(0, 2), st.integers(0, 2), st.integers(0, 2)),
        ),
        min_size=1,
        max_size=30,
    ),
)
def test_generated_operation_sequences_keep_the_snapshot_invariant(
    policy: RequestPolicy, plan: list[tuple[int, RequestEffectClass, tuple[int, int, int]]]
) -> None:
    snapshot = empty(policy, _budget())
    next_index = 0
    for choice, effect_class, demand in plan:
        options = _candidates(snapshot, next_index, effect_class, demand)
        kind, argument = options[choice % len(options)]
        if kind == "submit":
            next_index += 1
        snapshot = _step(snapshot, kind, argument)
        _assert_invariant(snapshot)


@settings(max_examples=60, deadline=None)
@given(st.lists(st.integers(0, 10**6), min_size=1, max_size=20))
def test_fifo_start_is_blocked_exactly_for_pending_entries_after_the_first(order: list[int]) -> None:
    snapshot = empty(RequestPolicy.FIFO, _budget())
    for index in range(len(order)):
        result = submit(snapshot, _request(index, RequestEffectClass.PURE, (1, 0, 0)))
        snapshot = result.snapshot  # type: ignore[union-attr]
    remaining = list(range(len(order)))
    for choice in order:
        if not remaining:
            break
        target = remaining[choice % len(remaining)]
        decided = decide_start(snapshot, Accepted(_identity(target)), ExecuteNow(_identity(target), EVIDENCE, 1))
        if target == remaining[0]:
            assert not isinstance(decided, StartDecisionRejected)
            remaining.remove(target)
            snapshot = decided.snapshot  # type: ignore[union-attr]
        else:
            assert isinstance(decided, StartDecisionRejected)


def test_construction_rejects_two_entries_with_one_identity() -> None:
    entry = RequestEntry(
        _identity(1),
        RequestFootprint((), (), RequestEffectClass.PURE),
        ResourceDemand(1, 0, 0),
        RequestPhase.PENDING,
        Permitted(_identity(1), ()),
        None,
        None,
    )
    built = snapshot_of(RequestPolicy.FIFO, _budget(), None, [entry, entry], 0)
    assert built == DuplicateIdentity(_identity(1))


def test_a_snapshot_is_constructed_only_by_its_construction_functions() -> None:
    try:
        RequestProgressionSnapshot()
    except TypeError:
        return
    raise AssertionError("direct construction must be refused")
