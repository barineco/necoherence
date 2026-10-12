# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Property tests for reconcile: order-independence and coherence closure."""

from __future__ import annotations

from hypothesis import given, strategies as st

from necoherence.core import Basis, ResourceId, Revision, World
from necoherence.reconcile import coherent, reconcile


def _rid(n: int) -> ResourceId:
    return ResourceId(kind="core", name=str(n))


@st.composite
def bases_and_world(draw: st.DrawFn) -> tuple[tuple[Basis | None, ...], World, int]:
    resource_ids = draw(st.lists(st.integers(min_value=0, max_value=5), min_size=1, max_size=5, unique=True))
    bases: list[Basis | None] = []
    for _ in range(draw(st.integers(min_value=0, max_value=10))):
        if draw(st.booleans()):
            bases.append(None)
        else:
            r = draw(st.sampled_from(resource_ids))
            v = draw(st.integers(min_value=0, max_value=10))
            bases.append(Basis(_rid(r), Revision(v)))
    world_entries = tuple(
        (_rid(r), Revision(draw(st.integers(min_value=0, max_value=10)))) for r in resource_ids
    )
    dropped = draw(st.integers(min_value=0, max_value=5))
    return tuple(bases), World(world_entries), dropped


@given(bases_and_world())
def test_unbased_counts_exactly_the_none_entries(data: tuple[tuple[Basis | None, ...], World, int]) -> None:
    bases, world, dropped = data
    r = reconcile(bases, world, dropped)
    assert r.unbased == sum(1 for b in bases if b is None)
    assert r.dropped == dropped


@given(bases_and_world())
def test_reconcile_result_is_order_independent(data: tuple[tuple[Basis | None, ...], World, int]) -> None:
    bases, world, dropped = data
    shuffled = tuple(reversed(bases))
    a = reconcile(bases, world, dropped)
    b = reconcile(shuffled, world, dropped)
    assert a.unbased == b.unbased
    assert a.dropped == b.dropped
    assert set(a.divergences) == set(b.divergences)


@given(bases_and_world())
def test_coherent_reads_exactly_the_closed_structure(
    data: tuple[tuple[Basis | None, ...], World, int]
) -> None:
    bases, world, dropped = data
    r = reconcile(bases, world, dropped)
    assert coherent(r) == (len(r.divergences) == 0 and r.unbased == 0 and r.dropped == 0)


def test_matching_world_is_coherent() -> None:
    world = World(((_rid(0), Revision(3)),))
    r = reconcile((Basis(_rid(0), Revision(3)),), world, 0)
    assert coherent(r)


def test_world_ahead_by_more_than_one_is_a_divergence() -> None:
    world = World(((_rid(0), Revision(5)),))
    r = reconcile((Basis(_rid(0), Revision(2)),), world, 0)
    assert not coherent(r)
    assert len(r.divergences) == 1
