# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT


from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import pytest

from necoherence.call import CallFailed, CallOk, Immediate, ProjectionFailed, Request, immediate_of, io
from necoherence.iteration import (
    ClosureFixpoint,
    ClosureProjectionFailed,
    ClosureReq,
    ClosureState,
    ClosureViolation,
    Continue,
    FoldCountNegative,
    FoldReq,
    FoldStopped,
    FoldTrace,
    MeasureNegative,
    RecurseDidNotDecrease,
    RecurseProjectionFailed,
    RecurseReq,
    RecurseSettled,
    Settled,
    StepOutcome,
    closure,
    fold,
    recurse,
)




def _increment(x: int) -> int:
    return x + 1



increment: Immediate[int, int] = Immediate(identity="test.increment", required=(), output=_increment)


@dataclass
class _TwoFieldReq:
    a: int
    b: int


def _combine(req: _TwoFieldReq) -> int:
    return req.a + req.b


combine: Immediate[_TwoFieldReq, int] = immediate_of("test.combine", ("a", "b"), _combine)


@dataclass
class _Empty:
    pass


def _fold_request(step: Immediate[Any, Any], seed: Any, count: int) -> Request[FoldReq[Any]]:
    req = FoldReq(step=step, seed=seed, count=count, step_fields=step.required)
    return Request(payload=req, fields=("step", "seed", "count", "step_fields"))


def _recurse_request(step: Immediate[Any, Any], seed: Any) -> Request[RecurseReq[Any]]:
    req = RecurseReq(step=step, seed=seed, step_fields=step.required)
    return Request(payload=req, fields=("step", "seed", "step_fields"))


def _closure_request(
    step: Immediate[Any, Any], carrier: frozenset[Any], seed: frozenset[Any]
) -> Request[ClosureReq[Any]]:
    req = ClosureReq(step=step, carrier=carrier, seed=seed, step_fields=step.required)
    return Request(payload=req, fields=("step", "carrier", "seed", "step_fields"))





def test_fold_is_immediate_and_bound_is_an_input_field() -> None:
    assert isinstance(fold, Immediate)
    assert fold.required == ("step", "seed", "count", "step_fields")


def test_recurse_is_immediate_and_has_no_count_field() -> None:
    assert isinstance(recurse, Immediate)
    assert recurse.required == ("step", "seed", "step_fields")


def test_closure_is_immediate_and_bound_is_the_carrier() -> None:
    assert isinstance(closure, Immediate)
    assert closure.required == ("step", "carrier", "seed", "step_fields")





def test_fold_runs_count_rounds_and_states_has_count_plus_one_entries() -> None:
    result = io(fold, _fold_request(increment, 0, 3))
    assert result == CallOk(FoldTrace(states=(0, 1, 2, 3)))


def test_fold_rejects_a_negative_count() -> None:
    with pytest.raises(FoldCountNegative):
        FoldReq(step=increment, seed=0, count=-1, step_fields=())


@dataclass
class _Pair:
    a: int
    b: int


def test_fold_reports_the_position_of_a_failing_round() -> None:
    req = FoldReq(step=combine, seed=_Pair(a=1, b=2), count=5, step_fields=())  # type: ignore[misc]
    result = io(fold, Request(payload=req, fields=("step", "seed", "count", "step_fields")))
    assert isinstance(result, CallOk)
    outcome = result.value
    assert isinstance(outcome, FoldStopped)
    assert outcome.states == (_Pair(a=1, b=2),)
    assert outcome.stopped.position == 0
    assert outcome.stopped.failure == ProjectionFailed(declaration="test.combine", fields=("a", "b"))


def test_fold_outcome_is_a_closed_exclusive_union() -> None:
    result = io(fold, _fold_request(increment, 0, 1))
    assert isinstance(result, CallOk)
    assert isinstance(result.value, FoldTrace | FoldStopped)





def _gcd_step(state: tuple[int, int]) -> StepOutcome[tuple[int, int]]:
    a, b = state
    if b == 0:
        return Settled(state=(a, b))
    return Continue(state=(b, a % b), measure=b)


gcd_step: Immediate[tuple[int, int], StepOutcome[tuple[int, int]]] = Immediate(
    identity="test.gcd_step", required=(), output=_gcd_step
)


def test_recurse_settles_when_measure_strictly_decreases() -> None:
    result = io(recurse, _recurse_request(gcd_step, (48, 18)))
    assert result == CallOk(RecurseSettled(value=(6, 0), steps=3))


def test_continue_rejects_a_negative_measure() -> None:
    with pytest.raises(MeasureNegative):
        Continue(state=0, measure=-1)


def test_recurse_returns_did_not_decrease_instead_of_waiting() -> None:
    def _stuck(state: int) -> StepOutcome[int]:
        return Continue(state=state + 1, measure=5)

    stuck: Immediate[int, StepOutcome[int]] = Immediate(identity="test.stuck", required=(), output=_stuck)
    result = io(recurse, _recurse_request(stuck, 0))
    assert isinstance(result, CallOk)
    outcome = result.value
    assert isinstance(outcome, RecurseDidNotDecrease)
    assert outcome.position == 1
    assert outcome.measure == 5
    assert outcome.previous_measure == 5


def test_recurse_reports_a_failing_rounds_projection_failure() -> None:
    req = RecurseReq(step=combine, seed=_Empty(), step_fields=())  # type: ignore[misc, arg-type]
    result = io(recurse, Request(payload=req, fields=("step", "seed", "step_fields")))
    assert isinstance(result, CallOk)
    outcome = result.value
    assert isinstance(outcome, RecurseProjectionFailed)
    assert outcome.stopped.position == 0
    assert outcome.stopped.failure == ProjectionFailed(declaration="test.combine", fields=("a", "b"))


def test_recurse_outcome_is_a_closed_exclusive_union() -> None:
    result = io(recurse, _recurse_request(gcd_step, (48, 18)))
    assert isinstance(result, CallOk)
    assert isinstance(result.value, RecurseSettled | RecurseDidNotDecrease | RecurseProjectionFailed)





_edges = {1: frozenset({2}), 2: frozenset({3}), 3: frozenset()}


def _reach_step(state: ClosureState[int]) -> frozenset[int]:
    grown = set(state.elements)
    for node in state.elements:
        grown |= _edges.get(node, frozenset())
    return frozenset(grown)


reach_step: Immediate[ClosureState[int], frozenset[int]] = immediate_of(
    "test.reach_step", ("elements",), _reach_step
)


def test_closure_reaches_the_least_fixpoint_over_a_finite_carrier() -> None:
    result = io(closure, _closure_request(reach_step, frozenset({1, 2, 3}), frozenset({1})))
    assert result == CallOk(ClosureFixpoint(elements=frozenset({1, 2, 3}), steps=2))


def test_closure_reports_a_violation_when_the_step_is_not_extensive() -> None:
    def _shrinks(state: ClosureState[int]) -> frozenset[int]:
        return frozenset()

    shrinks: Immediate[ClosureState[int], frozenset[int]] = immediate_of(
        "test.shrinks", ("elements",), _shrinks
    )
    result = io(closure, _closure_request(shrinks, frozenset({1, 2}), frozenset({1})))
    assert isinstance(result, CallOk)
    outcome = result.value
    assert isinstance(outcome, ClosureViolation)
    assert outcome.position == 0
    assert outcome.current == frozenset({1})
    assert outcome.produced == frozenset()


def test_closure_reports_a_violation_when_the_step_leaves_the_carrier() -> None:
    def _escapes(state: ClosureState[int]) -> frozenset[int]:
        return state.elements | {99}

    escapes: Immediate[ClosureState[int], frozenset[int]] = immediate_of(
        "test.escapes", ("elements",), _escapes
    )
    result = io(closure, _closure_request(escapes, frozenset({1, 2}), frozenset({1})))
    assert isinstance(result, CallOk)
    outcome = result.value
    assert isinstance(outcome, ClosureViolation)
    assert outcome.produced == frozenset({1, 99})


def test_closure_reports_a_failing_rounds_projection_failure() -> None:
    req = ClosureReq(step=combine, carrier=frozenset({1}), seed=frozenset({1}), step_fields=())  # type: ignore[arg-type]
    result = io(closure, Request(payload=req, fields=("step", "carrier", "seed", "step_fields")))
    assert isinstance(result, CallOk)
    outcome = result.value
    assert isinstance(outcome, ClosureProjectionFailed)
    assert outcome.stopped.failure == ProjectionFailed(declaration="test.combine", fields=("a", "b"))


def test_closure_outcome_is_a_closed_exclusive_union() -> None:
    result = io(closure, _closure_request(reach_step, frozenset({1, 2, 3}), frozenset({1})))
    assert isinstance(result, CallOk)
    assert isinstance(result.value, ClosureFixpoint | ClosureViolation | ClosureProjectionFailed)





def test_fold_projects_each_round_using_the_declared_step_fields() -> None:
    req = FoldReq(step=combine, seed=_Pair(a=1, b=2), count=1, step_fields=("a", "b"))  # type: ignore[misc]
    result = io(fold, Request(payload=req, fields=("step", "seed", "count", "step_fields")))
    assert result == CallOk(FoldTrace(states=(_Pair(a=1, b=2), 3)))


def test_fold_missing_a_declared_step_field_fails_the_first_round() -> None:
    req = FoldReq(step=combine, seed=_Pair(a=1, b=2), count=1, step_fields=("a",))  # type: ignore[misc]
    result = io(fold, Request(payload=req, fields=("step", "seed", "count", "step_fields")))
    assert isinstance(result, CallOk)
    outcome = result.value
    assert isinstance(outcome, FoldStopped)
    assert outcome.stopped.position == 0
    assert outcome.stopped.failure == ProjectionFailed(declaration="test.combine", fields=("b",))





def test_io_fold_itself_projection_fails_when_the_request_is_missing_fields() -> None:
    req = FoldReq(step=increment, seed=0, count=1, step_fields=())
    result = io(fold, Request(payload=req, fields=("step", "seed")))
    assert result == CallFailed(ProjectionFailed(declaration="necoherence.iteration.fold", fields=("count", "step_fields")))
