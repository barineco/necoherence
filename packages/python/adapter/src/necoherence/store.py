# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Payload-owning store that projects onto ``World``.

No public entry returns a mutable view into the store. Observation is a
pure function and does not advance revisions. Mutation replaces payload
values only.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from types import MappingProxyType
from typing import Never

from necoherence.core import (
    Applied,
    Command,
    Conflicted,
    Outcome,
    Rejected,
    ResourceId,
    Revision,
    StaleBasis,
    UnknownResource,
    World,
    world_of,
)
from necoherence.persistent import PersistentVector, vector_of


class Store[A]:
    """Owns each resource's payload alongside its revision.

    The fields are private. ``store_of`` is the only construction path, and
    ``store_entries`` reads the entries back in order. Operations return a new
    value that shares every unchanged entry with the store they were given.
    """

    __slots__ = ("_entries", "_first")

    _entries: PersistentVector[tuple[ResourceId, Revision, A]]
    _first: Mapping[ResourceId, int]

    def __init__(self, *_arguments: object, **_keywords: object) -> None:
        raise TypeError("Store is constructed with store_of")

    def __setattr__(self, name: str, value: object) -> None:
        raise AttributeError("Store is immutable")

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Store) and store_entries(self) == store_entries(other)

    def __hash__(self) -> int:
        return hash(store_entries(self))

    def __repr__(self) -> str:
        return f"Store(entries={store_entries(self)!r})"


def _store_from[A](
    entries: PersistentVector[tuple[ResourceId, Revision, A]], first: Mapping[ResourceId, int]
) -> Store[A]:
    store: Store[A] = object.__new__(Store)
    object.__setattr__(store, "_entries", entries)
    object.__setattr__(store, "_first", first)
    return store


@dataclass(frozen=True, slots=True)
class Found[A]:
    """Observation that found a revision and a payload copy."""

    revision: Revision
    payload: A


@dataclass(frozen=True, slots=True)
class Unknown:
    """Observation that the resource is absent."""

    unknown: UnknownResource


type Observed[A] = Found[A] | Unknown


def store_of[A](entries: Iterable[tuple[ResourceId, Revision, A]]) -> Store[A]:
    """Build a store from ordered entries, indexing each resource's first position."""
    ordered = tuple(entries)
    first: dict[ResourceId, int] = {}
    for position, (resource, _revision, _payload) in enumerate(ordered):
        first.setdefault(resource, position)
    return _store_from(vector_of(ordered), MappingProxyType(first))


def store_entries[A](store: Store[A]) -> tuple[tuple[ResourceId, Revision, A], ...]:
    """Return the ordered entries of a store, read-only."""
    return tuple(store._entries)


def observe[A](store: Store[A], resource: ResourceId) -> Observed[A]:
    """Read-only observation: does not change the store."""
    position = store._first.get(resource)
    if position is None:
        return Unknown(UnknownResource(resource))
    _found, revision, payload = store._entries.get(position)
    return Found(revision, payload)


def _bump[A](store: Store[A], resource: ResourceId, intent: A) -> Store[A]:
    position = store._first.get(resource)
    if position is None:
        return store
    found, revision, _payload = store._entries.get(position)
    return _store_from(store._entries.set(position, (found, Revision(revision.value + 1), intent)), store._first)


def apply[A](
    store: Store[A], command: Command[A]
) -> Outcome[tuple[A, Store[A]], UnknownResource, StaleBasis, Never]:
    """Apply a command to a store and return a closed outcome."""
    current = observe(store, command.basis.resource)
    if isinstance(current, Unknown):
        return Rejected(current.unknown)
    if current.revision != command.basis.revision:
        return Conflicted(
            StaleBasis(expected=command.basis.revision, actual=current.revision)
        )
    next_store = _bump(store, command.basis.resource, command.intent)
    return Applied((command.intent, next_store))


def world_of_store[A](store: Store[A]) -> World:
    """Projection onto World: drop each entry's payload."""
    return world_of((rid, rev) for rid, rev, _ in store._entries)
