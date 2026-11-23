# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""closure: reachable-node set as a monotone step's least fixpoint.

Each round adds every node one hop from the current set; the carrier's
size bounds the number of rounds, since the residual strictly shrinks.
"""

from __future__ import annotations

from necoherence import CallOk, ClosureFixpoint, ClosureReq, ClosureState, Request, closure, immediate_of, io

_edges: dict[int, frozenset[int]] = {
    1: frozenset({2, 3}),
    2: frozenset({4}),
    3: frozenset({4}),
    4: frozenset(),
    5: frozenset(),
}


def _one_hop(state: ClosureState[int]) -> frozenset[int]:
    grown = set(state.elements)
    for node in state.elements:
        grown |= _edges[node]
    return frozenset(grown)


one_hop = immediate_of("examples.closure.one_hop", ("elements",), _one_hop)


if __name__ == "__main__":
    req = ClosureReq(step=one_hop, carrier=frozenset(_edges), seed=frozenset({1}), step_fields=("elements",))
    result = io(closure, Request(payload=req, fields=("step", "carrier", "seed", "step_fields")))
    assert isinstance(result, CallOk)
    outcome = result.value
    assert isinstance(outcome, ClosureFixpoint)
    print(sorted(outcome.elements))
    assert outcome.elements == frozenset({1, 2, 3, 4})
