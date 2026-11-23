# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Core types and operations for revision-aware state updates.

Public computation uses immutable values, observations that carry a basis,
commands, and closed outcomes.
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from typing import Never

from necoherence.persistent import PersistentMap, PersistentVector, map_of, vector_of


@dataclass(frozen=True, slots=True)
class Revision:
    """Ordered generation identifier for owned state."""

    value: int


@dataclass(frozen=True, slots=True)
class ResourceId:
    """Identity of an owned resource, determined by the resource's own name.

    ``kind`` separates one domain of resources from another (files from
    whatever else comes to be owned), so identically named resources in
    different domains never compare equal. ``name`` is that domain's own
    name for the resource. Two calls that name the same resource always
    build an equal value; nothing here is issued by a counter or looked up
    in a registry, so independently branched values never collide.
    """

    kind: str
    name: str


@dataclass(frozen=True, slots=True)
class Basis:
    """Identity and revision that situate an observation or command."""

    resource: ResourceId
    revision: Revision


@dataclass(frozen=True, slots=True)
class Observation[A]:
    """Value that records what was seen together with its basis."""

    payload: A
    basis: Basis
    observed_at: int


@dataclass(frozen=True, slots=True)
class Command[A]:
    """Value that requests a state transition.

    The public construction path is ``command_of``. Direct construction is for
    module-internal use and for tests that exhibit basis loss.
    """

    intent: A
    basis: Basis


@dataclass(frozen=True, slots=True)
class Applied[A]:
    """Outcome of a successful command."""

    value: A


@dataclass(frozen=True, slots=True)
class Rejected[R]:
    """Outcome of a command rejected without state change."""

    reason: R


@dataclass(frozen=True, slots=True)
class Conflicted[C]:
    """Outcome of a command whose basis no longer matches owned state."""

    conflict: C


@dataclass(frozen=True, slots=True)
class BoundaryFailed[F]:
    """Outcome of a command that failed at an owned boundary."""

    failure: F


type Outcome[A, R, C, F] = Applied[A] | Rejected[R] | Conflicted[C] | BoundaryFailed[F]


@dataclass(frozen=True, slots=True)
class UnknownResource:
    """Rejection payload when the commanded resource is absent."""

    resource: ResourceId


@dataclass(frozen=True, slots=True)
class StaleBasis:
    """Conflict payload when the commanded revision differs from owned state.

    ``expected`` is the revision carried by the command basis.
    ``actual`` is the revision currently held by the world.
    """

    expected: Revision
    actual: Revision


class World:
    """Ordered map from resource identity to revision.

    The fields are private. ``world_of`` is the only construction path, and
    ``world_entries`` reads the entries back in order. Operations return a new
    value that shares every unchanged entry with the world they were given.
    """

    __slots__ = ("_entries", "_first")

    _entries: PersistentVector[tuple[ResourceId, Revision]]
    _first: PersistentMap[ResourceId, int]

    def __init__(self, *_arguments: object, **_keywords: object) -> None:
        raise TypeError("World is constructed with world_of")

    def __setattr__(self, name: str, value: object) -> None:
        raise AttributeError("World is immutable")

    def __eq__(self, other: object) -> bool:
        return isinstance(other, World) and world_entries(self) == world_entries(other)

    def __hash__(self) -> int:
        return hash(world_entries(self))

    def __repr__(self) -> str:
        return f"World(entries={world_entries(self)!r})"


def _world_from(
    entries: PersistentVector[tuple[ResourceId, Revision]], first: PersistentMap[ResourceId, int]
) -> World:
    world = object.__new__(World)
    object.__setattr__(world, "_entries", entries)
    object.__setattr__(world, "_first", first)
    return world


def world_of(entries: Iterable[tuple[ResourceId, Revision]]) -> World:
    """Build a world from ordered entries, indexing each resource's first position.

    Every ordered sequence is a world. A resource that appears more than once
    is read and bumped at its first entry.
    """
    ordered = tuple(entries)
    first: dict[ResourceId, int] = {}
    for position, (resource, _revision) in enumerate(ordered):
        first.setdefault(resource, position)
    return _world_from(vector_of(ordered), map_of(first.items()))


def world_entries(world: World) -> tuple[tuple[ResourceId, Revision], ...]:
    """Return the ordered entries of a world, read-only."""
    return tuple(world._entries)


def lookup(world: World, resource: ResourceId) -> Revision | UnknownResource:
    """Return the first revision paired with ``resource``, or its absence.

    Presence is a two-way fact about the world, not a fallible operation,
    so absence is reported with the same payload already used elsewhere
    for an absent resource rather than with a value outside the type.
    """
    position = world._first.find(resource)
    if position is None:
        return UnknownResource(resource)
    return world._entries.get(position)[1]


def bump(world: World, resource: ResourceId) -> World:
    """Return a world with the first matching resource's revision incremented."""
    position = world._first.find(resource)
    if position is None:
        return world
    found, revision = world._entries.get(position)
    return _world_from(world._entries.set(position, (found, Revision(revision.value + 1))), world._first)


def _world_appended(world: World, resource: ResourceId, revision: Revision) -> World:
    """Return ``world`` with one entry added at the end, sharing every entry of ``world``."""
    position = len(world._entries)
    first = world._first if world._first.contains(resource) else world._first.set(resource, position)
    return _world_from(world._entries.append((resource, revision)), first)


def command_of[A, B](observation: Observation[A], intent: B) -> Command[B]:
    """Build a ``Command`` that retains the observation's basis.

    This is the public construction path for ``Command``.
    """
    return Command(intent=intent, basis=observation.basis)


def apply[A](
    world: World, command: Command[A]
) -> Outcome[tuple[A, World], UnknownResource, StaleBasis, Never]:
    """Apply ``command`` to ``world`` and return a closed outcome.

    Absent resource yields ``Rejected``. Mismatched revision yields
    ``Conflicted``. Matching revision yields ``Applied`` with bumped world.
    """
    current = lookup(world, command.basis.resource)
    if isinstance(current, UnknownResource):
        return Rejected(current)
    if current != command.basis.revision:
        return Conflicted(
            StaleBasis(expected=command.basis.revision, actual=current)
        )
    return Applied((command.intent, bump(world, command.basis.resource)))
