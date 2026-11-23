# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""fold: accumulate a running sum across a stated number of rounds.

The step is one-step-determinate addition; ``count`` is the fold's own
input field, so the number of rounds is fixed before the first one runs.
"""

from __future__ import annotations

from dataclasses import dataclass

from necoherence import CallOk, FoldReq, FoldTrace, Request, fold, immediate_of, io


@dataclass(frozen=True)
class RunningSum:
    total: int
    next_term: int


def _add_next_term(state: RunningSum) -> RunningSum:
    return RunningSum(total=state.total + state.next_term, next_term=state.next_term + 1)


accumulate = immediate_of("examples.fold.accumulate", (), _add_next_term)


if __name__ == "__main__":
    req = FoldReq(step=accumulate, seed=RunningSum(total=0, next_term=1), count=5, step_fields=())
    result = io(fold, Request(payload=req, fields=("step", "seed", "count", "step_fields")))
    assert isinstance(result, CallOk)
    outcome = result.value
    assert isinstance(outcome, FoldTrace)
    totals = tuple(state.total for state in outcome.states)
    print(totals)
    assert totals == (0, 1, 3, 6, 10, 15)
