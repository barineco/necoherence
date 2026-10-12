# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Iterative call forms whose step-count upper bound is readable from the input.

Three declarations, each ``Immediate``: ``fold`` applies a step a stated
number of times; ``recurse`` applies a step until it reports a settled
state, requiring the measure it also reports to strictly decrease each
round; ``closure`` applies a monotone step over a finite carrier until the
accumulated set stops growing. In all three the bound on how many rounds
can happen is readable from the declaration's own input before the first
round runs: a field for ``fold``, the first round's own measure for
``recurse``, the carrier's size for ``closure``.

Each round's step is called through ``io(step, Request(state, step_fields))``,
never through the step declaration's ``output`` directly, so a round whose
input fails to project returns as a declared branch of the surrounding
declaration's own output, naming which round it was, rather than surfacing
as an exception or an unchecked ``ProjectionFailed`` mixed into a state
slot. ``step_fields`` is an explicit input field of every request type
here, the field names present on every round's own input to ``step``.

Only the repetition structures live here. An arithmetic function that
settles in one step needs none of this and belongs directly behind
``immediate_of``.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from necoherence.call import (
    CallFailed,
    CallOk,
    Immediate,
    ProjectionFailed,
    Request,
    immediate_of,
    io,
)

type Measure = int


class FoldCountNegative(ValueError):
    def __init__(self, value: int) -> None:
        super().__init__(f"fold count must not be negative: {value}")
        self.value = value


class MeasureNegative(ValueError):
    def __init__(self, value: int) -> None:
        super().__init__(f"recurse measure must not be negative: {value}")
        self.value = value


@dataclass(frozen=True, slots=True)
class StageProjectionFailed:
    """Where, in a run of rounds, one round's own ``io`` projection failed.

    ``position`` counts rounds completed before this one, starting at
    zero. ``failure`` is the ``ProjectionFailed`` that ``io`` returned for
    this round.
    """

    position: int
    failure: ProjectionFailed


def _call_io[S, P](step: Immediate[S, P], state: S, step_fields: tuple[str, ...]) -> CallOk[P] | CallFailed:
    return io(step, Request(payload=state, fields=step_fields))


# -- fold: the bound is an input field ---------------------------------------


@dataclass(frozen=True, slots=True)
class FoldReq[S]:
    """Input to ``fold``: a step, its seed, how many rounds to run, and the
    field names present on every round's own input to ``step``."""

    step: Immediate[S, S]
    seed: S
    count: int
    step_fields: tuple[str, ...]

    def __post_init__(self) -> None:
        if self.count < 0:
            raise FoldCountNegative(self.count)


@dataclass(frozen=True, slots=True)
class FoldTrace[S]:
    """Full history of ``count`` settled rounds.

    ``states`` holds ``seed`` followed by each round's settled output, in
    call order; its length is ``count + 1``.
    """

    states: tuple[S, ...]


@dataclass(frozen=True, slots=True)
class FoldStopped[S]:
    """History up to the round whose ``io`` projection failed.

    ``states`` holds ``seed`` followed by every settled output before the
    failing round; its length is ``stopped.position + 1``.
    """

    states: tuple[S, ...]
    stopped: StageProjectionFailed


type FoldOutcome[S] = FoldTrace[S] | FoldStopped[S]


def _fold_output[S](req: FoldReq[S]) -> FoldOutcome[S]:
    """Call ``req.step`` through ``io``, ``req.count`` times from ``req.seed``.

    Stops at the first round whose ``io`` call returns ``ProjectionFailed``
    and reports that round's position; otherwise runs every round.
    """
    states: list[S] = [req.seed]
    state = req.seed
    for position in range(req.count):
        match _call_io(req.step, state, req.step_fields):
            case CallFailed(failure=failure):
                return FoldStopped(
                    states=tuple(states),
                    stopped=StageProjectionFailed(position=position, failure=failure),
                )
            case CallOk(value=next_state):
                state = next_state
                states.append(state)
    return FoldTrace(states=tuple(states))


fold: Immediate[FoldReq[Any], FoldOutcome[Any]] = immediate_of(
    "necoherence.iteration.fold", ("step", "seed", "count", "step_fields"), _fold_output
)


# -- recurse: the bound is the first round's own measure ---------------------


@dataclass(frozen=True, slots=True)
class Continue[S]:
    """Next state together with this round's own measure toward termination."""

    state: S
    measure: Measure

    def __post_init__(self) -> None:
        if self.measure < 0:
            raise MeasureNegative(self.measure)


@dataclass(frozen=True, slots=True)
class Settled[S]:
    """Confirmed final state; no further round is run."""

    state: S


type StepOutcome[S] = Continue[S] | Settled[S]


@dataclass(frozen=True, slots=True)
class RecurseReq[S]:
    """Input to ``recurse``: a step, its seed, and the field names present on
    every round's own input to ``step``."""

    step: Immediate[S, StepOutcome[S]]
    seed: S
    step_fields: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class RecurseSettled[S]:
    """Final state reported by ``step``, and how many rounds it took."""

    value: S
    steps: int


@dataclass(frozen=True, slots=True)
class RecurseDidNotDecrease[S]:
    """Declared branch for a round whose measure did not strictly decrease.

    ``measure`` is what this round returned; ``previous_measure`` is what
    the prior round returned. ``position`` counts rounds completed before
    this one.
    """

    position: int
    state: S
    measure: Measure
    previous_measure: Measure


@dataclass(frozen=True, slots=True)
class RecurseProjectionFailed[S]:
    """Declared branch for a round whose ``io`` projection failed."""

    last_state: S
    stopped: StageProjectionFailed


type RecurseOutcome[S] = (
    RecurseSettled[S] | RecurseDidNotDecrease[S] | RecurseProjectionFailed[S]
)


def _recurse_output[S](req: RecurseReq[S]) -> RecurseOutcome[S]:
    """Call ``req.step`` through ``io`` from ``req.seed`` until it settles.

    Each round's measure must be strictly less than the prior round's; the
    first round's measure sets the bound and is not itself checked against
    one. A round that does not decrease, or whose ``io`` call fails to
    project, returns as a declared branch instead of continuing.
    """
    state = req.seed
    previous_measure: Measure | None = None
    position = 0
    while True:
        match _call_io(req.step, state, req.step_fields):
            case CallFailed(failure=failure):
                return RecurseProjectionFailed(
                    last_state=state,
                    stopped=StageProjectionFailed(position=position, failure=failure),
                )
            case CallOk(value=Settled(state=value)):
                return RecurseSettled(value=value, steps=position)
            case CallOk(value=Continue(state=next_state, measure=measure)):
                if previous_measure is not None and measure >= previous_measure:
                    return RecurseDidNotDecrease(
                        position=position,
                        state=next_state,
                        measure=measure,
                        previous_measure=previous_measure,
                    )
                previous_measure = measure
                state = next_state
                position += 1


recurse: Immediate[RecurseReq[Any], RecurseOutcome[Any]] = immediate_of(
    "necoherence.iteration.recurse", ("step", "seed", "step_fields"), _recurse_output
)


# -- closure: the bound is the carrier's size ---------------------------------


@dataclass(frozen=True, slots=True)
class ClosureState[T]:
    """Input to a closure's step: the current subset of the carrier.

    Concrete, not a ``Protocol``: ``closure`` itself is what constructs
    this value on every round, so nothing outside this module needs to
    build one to satisfy the step's declared input.
    """

    elements: frozenset[T]


@dataclass(frozen=True, slots=True)
class ClosureReq[T]:
    """Input to ``closure``: a monotone step, its finite carrier, a seed
    subset, and the field names present on every round's own input to
    ``step``."""

    step: Immediate[ClosureState[T], frozenset[T]]
    carrier: frozenset[T]
    seed: frozenset[T]
    step_fields: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class ClosureFixpoint[T]:
    """Least fixpoint reached: ``elements`` is the settled set, ``steps`` the rounds taken."""

    elements: frozenset[T]
    steps: int


@dataclass(frozen=True, slots=True)
class ClosureViolation[T]:
    """Declared branch for a round whose output breaks the closure's own invariants.

    A violation is ``produced`` not containing ``current`` (not extensive,
    so the residual would not shrink) or ``produced`` reaching outside the
    declared carrier. ``position`` counts rounds completed before this one.
    """

    position: int
    current: frozenset[T]
    produced: frozenset[T]


@dataclass(frozen=True, slots=True)
class ClosureProjectionFailed[T]:
    """Declared branch for a round whose ``io`` projection failed."""

    last: frozenset[T]
    stopped: StageProjectionFailed


type ClosureOutcome[T] = (
    ClosureFixpoint[T] | ClosureViolation[T] | ClosureProjectionFailed[T]
)


def _closure_output[T](req: ClosureReq[T]) -> ClosureOutcome[T]:
    """Call ``req.step`` through ``io`` from ``req.seed`` until the set stops growing.

    Each round's output must be a superset of that round's own input and a
    subset of ``req.carrier``; either failing returns as a declared branch.
    The residual (``len(carrier) - len(current)``) strictly decreases on
    every round that grows the set, so a well-behaved step terminates
    within ``len(carrier)`` rounds.
    """
    current = req.seed
    position = 0
    while True:
        match _call_io(req.step, ClosureState(elements=current), req.step_fields):
            case CallFailed(failure=failure):
                return ClosureProjectionFailed(
                    last=current,
                    stopped=StageProjectionFailed(position=position, failure=failure),
                )
            case CallOk(value=produced):
                if produced == current:
                    return ClosureFixpoint(elements=current, steps=position)
                if not (current <= produced) or not (produced <= req.carrier):
                    return ClosureViolation(
                        position=position, current=current, produced=produced
                    )
                current = produced
                position += 1


closure: Immediate[ClosureReq[Any], ClosureOutcome[Any]] = immediate_of(
    "necoherence.iteration.closure", ("step", "carrier", "seed", "step_fields"), _closure_output
)
