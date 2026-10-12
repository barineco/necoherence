# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Tests translating Lean Core theorems and the stale-basis counterexample."""

from __future__ import annotations

from dataclasses import FrozenInstanceError

import pytest
from hypothesis import given, strategies as st

from necoherence.core import (
    Applied,
    Basis,
    BoundaryFailed,
    Command,
    Conflicted,
    Observation,
    Rejected,
    ResourceId,
    Revision,
    StaleBasis,
    UnknownResource,
    World,
    apply,
    command_of,
    lookup,
)


def _rid(name: int) -> ResourceId:
    """Build a test resource identity. Distinct ``name``s never collide, and
    the same ``name`` always builds an equal value: there is no counter
    here to make either fact depend on call order."""
    return ResourceId(kind="test", name=str(name))


def _world(*pairs: tuple[int, int]) -> World:
    return World(
        entries=tuple(
            (_rid(resource), Revision(revision))
            for resource, revision in pairs
        )
    )


def _command(resource: int, revision: int, intent: object = None) -> Command[object]:
    return Command(
        intent=intent,
        basis=Basis(_rid(resource), Revision(revision)),
    )


def test_outcome_closure() -> None:
    """apply return values are exactly one of the four Outcome variants."""
    world = _world((0, 1), (1, 2))

    cases = [
        apply(world, _command(0, 1, "ok")),
        apply(world, _command(99, 0, "missing")),
        apply(world, _command(0, 0, "stale")),
    ]

    for outcome in cases:
        match outcome:
            case Applied():
                pass
            case Rejected():
                pass
            case Conflicted():
                pass
            case BoundaryFailed():
                pass
            case _:
                raise AssertionError(f"non-Outcome value: {outcome!r}")

    assert isinstance(cases[0], Applied)
    assert isinstance(cases[1], Rejected)
    assert isinstance(cases[2], Conflicted)


def test_resource_id_is_determined_by_kind_and_name_together() -> None:
    """Two calls naming the same resource in the same domain always build an
    equal identity, with no counter or registry involved. A name shared
    across different domains ( ``kind`` ) never collides: ``files`` are not
    the only domain ``ResourceId`` is meant to serve, so ``kind`` alone is
    what keeps a future domain's names out of file identity space, without
    needing a second domain to actually exist yet."""
    assert ResourceId(kind="file", name="/a") == ResourceId(kind="file", name="/a")
    assert ResourceId(kind="file", name="/a") != ResourceId(kind="file", name="/b")
    assert ResourceId(kind="file", name="/a") != ResourceId(kind="other", name="/a")


def test_world_lookup_is_closed_no_none_for_absence() -> None:
    """Absence is one of ``lookup``'s two possible return values, not a
    ``None`` outside the declared type."""
    world = _world((0, 3))
    assert lookup(world, _rid(0)) == Revision(3)
    assert lookup(world, _rid(99)) == UnknownResource(_rid(99))


def test_basis_retention() -> None:
    observation = Observation(
        payload=42,
        basis=Basis(_rid(0), Revision(5)),
        observed_at=0,
    )
    command = command_of(observation, "intent")
    assert command.basis == observation.basis


def test_stale_conflict() -> None:
    world = _world((0, 5))
    command = _command(0, 4, "x")
    outcome = apply(world, command)
    assert outcome == Conflicted(
        StaleBasis(expected=Revision(4), actual=Revision(5))
    )


def test_apply_disjoint_comm() -> None:
    world = _world((0, 1), (1, 2), (2, 3))
    c1 = _command(0, 1, "a")
    c2 = _command(1, 2, "b")

    o1 = apply(world, c1)
    assert isinstance(o1, Applied)
    w1 = o1.value[1]
    o12 = apply(w1, c2)
    assert isinstance(o12, Applied)
    w12 = o12.value[1]

    o2 = apply(world, c2)
    assert isinstance(o2, Applied)
    w2 = o2.value[1]
    o21 = apply(w2, c1)
    assert isinstance(o21, Applied)
    w21 = o21.value[1]

    resources = [_rid(0), _rid(1), _rid(2), _rid(99)]
    for resource in resources:
        assert lookup(w12, resource) == lookup(w21, resource)


def test_counterexample_discarded_basis() -> None:
    """Rebuilding Command with a stale basis yields Conflicted."""
    res = _rid(0)
    world = World(entries=((res, Revision(5)),))
    observation = Observation(
        payload=42,
        basis=Basis(res, Revision(5)),
        observed_at=0,
    )
    # payload-only extraction rebuilt with a stale basis (revision 4)
    command = Command(intent=observation.payload, basis=Basis(res, Revision(4)))
    outcome = apply(world, command)
    assert isinstance(outcome, Conflicted)


def test_frozen_instances() -> None:
    revision = Revision(1)
    resource = _rid(0)
    basis = Basis(resource, revision)
    observation = Observation(payload=1, basis=basis, observed_at=0)
    command = Command(intent=1, basis=basis)
    world = World(entries=((resource, revision),))
    applied = Applied(value=1)
    rejected = Rejected(reason=UnknownResource(resource))
    conflicted = Conflicted(
        conflict=StaleBasis(expected=revision, actual=Revision(0))
    )
    boundary = BoundaryFailed(failure="x")
    unknown = UnknownResource(resource)
    stale = StaleBasis(expected=revision, actual=Revision(0))

    with pytest.raises(FrozenInstanceError):
        revision.value = 2  # type: ignore[misc]
    with pytest.raises(FrozenInstanceError):
        resource.name = "x"  # type: ignore[misc]
    with pytest.raises(FrozenInstanceError):
        basis.revision = Revision(2)  # type: ignore[misc]
    with pytest.raises(FrozenInstanceError):
        observation.payload = 2  # type: ignore[misc]
    with pytest.raises(FrozenInstanceError):
        command.intent = 2  # type: ignore[misc]
    with pytest.raises(FrozenInstanceError):
        world.entries = ()  # type: ignore[misc]
    with pytest.raises(FrozenInstanceError):
        applied.value = 2  # type: ignore[misc]
    with pytest.raises(FrozenInstanceError):
        rejected.reason = UnknownResource(_rid(1))  # type: ignore[misc]
    with pytest.raises(FrozenInstanceError):
        conflicted.conflict = StaleBasis(Revision(0), Revision(1))  # type: ignore[misc]
    with pytest.raises(FrozenInstanceError):
        boundary.failure = "y"  # type: ignore[misc]
    with pytest.raises(FrozenInstanceError):
        unknown.resource = _rid(1)  # type: ignore[misc]
    with pytest.raises(FrozenInstanceError):
        stale.expected = Revision(0)  # type: ignore[misc]


@st.composite
def worlds_and_disjoint_commands(draw: st.DrawFn) -> tuple[World, Command[str], Command[str]]:
    resources = draw(
        st.lists(
            st.integers(min_value=0, max_value=20),
            min_size=2,
            max_size=8,
            unique=True,
        )
    )
    entries = [
        (_rid(r), Revision(draw(st.integers(min_value=0, max_value=50))))
        for r in resources
    ]
    world = World(entries=tuple(entries))
    idxs = draw(
        st.lists(
            st.sampled_from(list(range(len(resources)))),
            min_size=2,
            max_size=2,
            unique=True,
        )
    )
    r1, rev1 = entries[idxs[0]]
    r2, rev2 = entries[idxs[1]]
    c1 = Command(intent="a", basis=Basis(r1, rev1))
    c2 = Command(intent="b", basis=Basis(r2, rev2))
    return world, c1, c2


@given(worlds_and_disjoint_commands())
def test_apply_disjoint_comm_property(
    data: tuple[World, Command[str], Command[str]],
) -> None:
    world, c1, c2 = data
    assert c1.basis.resource != c2.basis.resource

    o1 = apply(world, c1)
    o2 = apply(world, c2)
    assert isinstance(o1, Applied)
    assert isinstance(o2, Applied)
    w1 = o1.value[1]
    w2 = o2.value[1]

    # after first bump, second command still matches its original revision
    o12 = apply(w1, c2)
    o21 = apply(w2, c1)
    assert isinstance(o12, Applied)
    assert isinstance(o21, Applied)
    w12 = o12.value[1]
    w21 = o21.value[1]

    observed = {rid for rid, _ in world.entries}
    observed.add(_rid(-1))
    for resource in observed:
        assert lookup(w12, resource) == lookup(w21, resource)
