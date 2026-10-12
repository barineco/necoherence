# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Closed bounded single-owner transition.

One input is evaluated to a closed result in a single call. The caller's
``advance`` function may ask for the same input again, but only a positive
number of times, and accumulated outputs never exceed a declared capacity.
Mirrors ``StepTransition.lean``.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable


class LimitNotPositive(ValueError):
    def __init__(self, value: int) -> None:
        super().__init__(f"reprocess limit must be positive: {value}")
        self.value = value


class CapacityNegative(ValueError):
    def __init__(self, value: int) -> None:
        super().__init__(f"capacity must not be negative: {value}")
        self.value = value


@dataclass(frozen=True, slots=True)
class PositiveLimit:
    """A positive bound on how many times one input may be reprocessed."""

    value: int

    def __post_init__(self) -> None:
        if self.value <= 0:
            raise LimitNotPositive(self.value)


@dataclass(frozen=True, slots=True)
class Capacity:
    """A bound on how many outputs one transition may accumulate."""

    value: int

    def __post_init__(self) -> None:
        if self.value < 0:
            raise CapacityNegative(self.value)


@dataclass(frozen=True, slots=True)
class Consumed[S, O]:
    """One application decided the input is now settled."""

    state: S
    outputs: tuple[O, ...]


@dataclass(frozen=True, slots=True)
class Reprocess[S, O]:
    """One application decided the input must be asked for again."""

    state: S
    outputs: tuple[O, ...]


type Consumption[S, O] = Consumed[S, O] | Reprocess[S, O]


@dataclass(frozen=True, slots=True)
class ReprocessLimitExhausted:
    applications: int


@dataclass(frozen=True, slots=True)
class CapacityExceeded:
    capacity: int
    attempted: int


type StepFailure = ReprocessLimitExhausted | CapacityExceeded


@dataclass(frozen=True, slots=True)
class StepSettled[S, O]:
    """The closed result of a transition that consumed its input."""

    state: S
    outputs: tuple[O, ...]
    applications: int


@dataclass(frozen=True, slots=True)
class StepFailed[S, O]:
    """The closed result of a transition that stopped without consuming its input."""

    state: S
    outputs: tuple[O, ...]
    failure: StepFailure


type StepTransition[S, O] = StepSettled[S, O] | StepFailed[S, O]


def step[S, I, O](
    state: S,
    input: I,
    advance: Callable[[S, I], Consumption[S, O]],
    limit: PositiveLimit,
    capacity: Capacity,
) -> StepTransition[S, O]:
    """Evaluate one input to a closed result in a single call.

    ``advance`` is applied to the same input until it reports ``Consumed``,
    at most ``limit.value`` times. Outputs keep the order in which
    ``advance`` produced them and never exceed ``capacity.value``.
    """
    accumulated: list[O] = []
    applications = 0
    fuel = limit.value
    while fuel > 0:
        decision = advance(state, input)
        state = decision.state
        accumulated.extend(decision.outputs)
        applications += 1
        if len(accumulated) > capacity.value:
            return StepFailed(
                state, tuple(accumulated), CapacityExceeded(capacity.value, len(accumulated))
            )
        if isinstance(decision, Consumed):
            return StepSettled(state, tuple(accumulated), applications)
        fuel -= 1
    return StepFailed(state, tuple(accumulated), ReprocessLimitExhausted(applications))
