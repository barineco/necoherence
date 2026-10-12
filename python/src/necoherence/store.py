# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Payload-owning store that projects onto ``World``.

No public entry returns a mutable view into the store. Observation is a
pure function and does not advance revisions. Mutation replaces payload
values only.
"""

from __future__ import annotations

from dataclasses import dataclass
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
)


@dataclass(frozen=True, slots=True)
class Store[A]:
    """Owns each resource's payload alongside its revision."""

    entries: tuple[tuple[ResourceId, Revision, A], ...]


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


def store_of[A](entries: list[tuple[ResourceId, Revision, A]] | tuple[tuple[ResourceId, Revision, A], ...]) -> Store[A]:
    """Build a store from an ordered list of entries."""
    return Store(tuple(entries))


def store_entries[A](store: Store[A]) -> tuple[tuple[ResourceId, Revision, A], ...]:
    """Return the ordered entries of a store, read-only."""
    return store.entries


def observe[A](store: Store[A], resource: ResourceId) -> Observed[A]:
    """Read-only observation: does not change the store."""
    for rid, rev, payload in store.entries:
        if rid == resource:
            return Found(rev, payload)
    return Unknown(UnknownResource(resource))


def _bump[A](store: Store[A], resource: ResourceId, intent: A) -> Store[A]:
    rebuilt: list[tuple[ResourceId, Revision, A]] = []
    found = False
    for rid, rev, payload in store.entries:
        if not found and rid == resource:
            rebuilt.append((rid, Revision(rev.value + 1), intent))
            found = True
        else:
            rebuilt.append((rid, rev, payload))
    return store_of(rebuilt)


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
    return World(tuple((rid, rev) for rid, rev, _ in store.entries))
