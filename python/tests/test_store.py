# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT


from __future__ import annotations

from necoherence.core import (
    Applied,
    Basis,
    Command,
    Conflicted,
    Rejected,
    ResourceId,
    Revision,
    StaleBasis,
    UnknownResource,
    World,
    apply as world_apply,
)
from necoherence.store import (
    Found,
    Unknown,
    apply,
    observe,
    store_entries,
    store_of,
    world_of_store,
)


def _rid(name: int) -> ResourceId:
    return ResourceId(kind="store", name=str(name))


def _basis(resource: int, revision: int) -> Basis:
    return Basis(resource=_rid(resource), revision=Revision(revision))


def _one(resource: int, revision: int, payload: str):
    return store_of([(_rid(resource), Revision(revision), payload)])


def test_observe_does_not_change_the_store() -> None:
    store = _one(0, 3, "alpha")
    before = world_of_store(store)
    observe(store, _rid(0))
    assert world_of_store(store) == before


def test_apply_applies_when_the_revision_matches() -> None:
    store = _one(0, 3, "alpha")
    command = Command(intent="beta", basis=_basis(0, 3))
    outcome = apply(store, command)
    assert isinstance(outcome, Applied)
    intent, next_store = outcome.value
    assert intent == "beta"
    assert observe(next_store, _rid(0)) == Found(Revision(4), "beta")


def test_apply_rejects_when_the_resource_is_absent() -> None:
    store = _one(0, 3, "alpha")
    command = Command(intent="beta", basis=_basis(99, 0))
    outcome = apply(store, command)
    assert isinstance(outcome, Rejected)
    assert outcome.reason == UnknownResource(_rid(99))


def test_apply_conflicts_when_the_revision_is_stale() -> None:
    store = _one(0, 5, "alpha")
    command = Command(intent="beta", basis=_basis(0, 4))
    outcome = apply(store, command)
    assert isinstance(outcome, Conflicted)
    assert outcome.conflict == StaleBasis(Revision(4), Revision(5))


def test_apply_projection_commutes_with_core_apply_on_applied() -> None:
    store = _one(0, 3, "alpha")
    command = Command(intent="beta", basis=_basis(0, 3))
    store_outcome = apply(store, command)
    world_outcome = world_apply(world_of_store(store), command)
    assert isinstance(store_outcome, Applied)
    assert isinstance(world_outcome, Applied)
    assert world_of_store(store_outcome.value[1]) == world_outcome.value[1]


def test_apply_projection_commutes_with_core_apply_on_rejected() -> None:
    store = _one(0, 3, "alpha")
    command = Command(intent="beta", basis=_basis(99, 0))
    store_outcome = apply(store, command)
    world_outcome = world_apply(world_of_store(store), command)
    assert store_outcome == world_outcome


def test_apply_projection_commutes_with_core_apply_on_conflicted() -> None:
    store = _one(0, 5, "alpha")
    command = Command(intent="beta", basis=_basis(0, 4))
    store_outcome = apply(store, command)
    world_outcome = world_apply(world_of_store(store), command)
    assert store_outcome == world_outcome


def test_observe_returns_unknown_for_an_absent_resource() -> None:
    store = _one(0, 3, "alpha")
    assert observe(store, _rid(99)) == Unknown(UnknownResource(_rid(99)))


def test_world_of_store_projects_resource_and_revision_only() -> None:
    store = _one(0, 3, "alpha")
    assert world_of_store(store) == World(((_rid(0), Revision(3)),))


def test_apply_replaces_only_the_first_match() -> None:
    store = store_of(
        [
            (_rid(0), Revision(1), "first"),
            (_rid(0), Revision(9), "shadowed"),
            (_rid(7), Revision(7), "other"),
        ]
    )
    command = Command(intent="replaced", basis=_basis(0, 1))
    outcome = apply(store, command)
    assert isinstance(outcome, Applied)
    next_store = outcome.value[1]
    assert observe(next_store, _rid(0)) == Found(Revision(2), "replaced")
    assert observe(next_store, _rid(7)) == Found(Revision(7), "other")
    entries = store_entries(next_store)
    assert len(entries) == 3
    assert entries[1] == (_rid(0), Revision(9), "shadowed")
