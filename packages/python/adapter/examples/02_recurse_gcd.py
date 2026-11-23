# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""recurse: Euclid's algorithm, measure = the larger of the two values.

Each round's measure strictly decreases (the classic Euclid argument), so
recurse settles without any stated round count.
"""

from __future__ import annotations

from necoherence import (
    CallOk,
    Continue,
    Immediate,
    RecurseReq,
    RecurseSettled,
    Request,
    Settled,
    StepOutcome,
    io,
    recurse,
)


def _euclid_step(pair: tuple[int, int]) -> StepOutcome[tuple[int, int]]:
    a, b = pair
    if b == 0:
        return Settled(state=(a, b))
    return Continue(state=(b, a % b), measure=max(a, b))


# A tuple carries no field names, so this step declares no required fields.
euclid_step: Immediate[tuple[int, int], StepOutcome[tuple[int, int]]] = Immediate(
    identity="examples.recurse.euclid_step", required=(), output=_euclid_step
)


if __name__ == "__main__":
    req = RecurseReq(step=euclid_step, seed=(48, 18), step_fields=())
    result = io(recurse, Request(payload=req, fields=("step", "seed", "step_fields")))
    assert isinstance(result, CallOk)
    outcome = result.value
    assert isinstance(outcome, RecurseSettled)
    print(outcome.value)
    assert outcome.value == (6, 0)
