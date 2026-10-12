# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Property tests for the closed bounded single-owner transition."""

from __future__ import annotations

from hypothesis import given, strategies as st

from necoherence.transition import (
    Capacity,
    CapacityExceeded,
    CapacityNegative,
    Consumed,
    LimitNotPositive,
    PositiveLimit,
    Reprocess,
    ReprocessLimitExhausted,
    StepFailed,
    StepSettled,
    step,
)

import pytest


def test_positive_limit_rejects_non_positive_values() -> None:
    with pytest.raises(LimitNotPositive):
        PositiveLimit(0)
    with pytest.raises(LimitNotPositive):
        PositiveLimit(-1)


def test_capacity_rejects_negative_values() -> None:
    with pytest.raises(CapacityNegative):
        Capacity(-1)


def test_consuming_immediately_settles_after_one_application() -> None:
    def advance(state: int, _input: int) -> Consumed[int, int]:
        return Consumed(state=state + 1, outputs=(state,))

    result = step(0, 0, advance, PositiveLimit(5), Capacity(10))
    assert isinstance(result, StepSettled)
    assert result.applications == 1
    assert result.outputs == (0,)


def test_output_order_is_preserved_across_rounds() -> None:
    def advance(state: int, _input: int) -> Consumed[int, int] | Reprocess[int, int]:
        if state >= 2:
            return Consumed(state=state + 1, outputs=(state,))
        return Reprocess(state=state + 1, outputs=(state,))

    result = step(0, 0, advance, PositiveLimit(5), Capacity(10))
    assert isinstance(result, StepSettled)
    assert result.outputs == (0, 1, 2)


def test_exceeding_capacity_fails_with_capacity_exceeded() -> None:
    def advance(state: int, _input: int) -> Reprocess[int, int]:
        return Reprocess(state=state, outputs=(1, 2, 3))

    result = step(0, 0, advance, PositiveLimit(5), Capacity(2))
    assert isinstance(result, StepFailed)
    assert isinstance(result.failure, CapacityExceeded)


def test_exhausting_the_reprocess_limit_reports_applications() -> None:
    def advance(state: int, _input: int) -> Reprocess[int, int]:
        return Reprocess(state=state, outputs=())

    result = step(0, 0, advance, PositiveLimit(3), Capacity(10))
    assert isinstance(result, StepFailed)
    assert isinstance(result.failure, ReprocessLimitExhausted)
    assert result.failure.applications == 3


def test_zero_output_still_settles_even_with_zero_capacity() -> None:
    def advance(state: int, _input: int) -> Consumed[int, int]:
        return Consumed(state=state, outputs=())

    result = step(0, 0, advance, PositiveLimit(1), Capacity(0))
    assert isinstance(result, StepSettled)
    assert result.outputs == ()


@given(
    st.integers(min_value=1, max_value=8),
    st.integers(min_value=0, max_value=5),
)
def test_settled_output_never_exceeds_capacity(limit_value: int, capacity_value: int) -> None:
    def advance(state: int, _input: int) -> Consumed[int, int] | Reprocess[int, int]:
        if state + 1 >= limit_value:
            return Consumed(state=state + 1, outputs=(state,))
        return Reprocess(state=state + 1, outputs=(state,))

    result = step(0, 0, advance, PositiveLimit(limit_value), Capacity(capacity_value))
    if isinstance(result, StepSettled):
        assert len(result.outputs) <= capacity_value


@given(st.integers(min_value=0, max_value=64), st.integers(min_value=0, max_value=64))
def test_capacity_admits_output_up_to_the_configured_maximum(capacity_value: int, emitted: int) -> None:
    def advance(state: int, _input: int) -> Consumed[int, int]:
        return Consumed(state=state, outputs=tuple(range(emitted)))

    result = step(0, 0, advance, PositiveLimit(1), Capacity(capacity_value))
    if emitted <= capacity_value:
        assert isinstance(result, StepSettled)
        assert result.outputs == tuple(range(emitted))
    else:
        assert isinstance(result, StepFailed)
        assert isinstance(result.failure, CapacityExceeded)


@given(st.integers(min_value=1, max_value=64), st.integers(min_value=1, max_value=64))
def test_reprocess_limit_admits_applications_up_to_the_configured_maximum(limit_value: int, needed: int) -> None:
    def advance(state: int, _input: int) -> Consumed[int, int] | Reprocess[int, int]:
        if state + 1 == needed:
            return Consumed(state=state + 1, outputs=())
        return Reprocess(state=state + 1, outputs=())

    result = step(0, 0, advance, PositiveLimit(limit_value), Capacity(0))
    if needed <= limit_value:
        assert isinstance(result, StepSettled)
        assert result.applications == needed
    else:
        assert isinstance(result, StepFailed)
        assert isinstance(result.failure, ReprocessLimitExhausted)
        assert result.failure.applications == limit_value
