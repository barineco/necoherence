# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Core types and operations for revision-aware state updates.

Public computation uses immutable values, observations that carry a basis,
commands, and closed outcomes.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Never


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


@dataclass(frozen=True, slots=True)
class World:
    """Immutable ordered map from resource identity to revision."""

    entries: tuple[tuple[ResourceId, Revision], ...]


def lookup(world: World, resource: ResourceId) -> Revision | UnknownResource:
    """Return the first revision paired with ``resource``, or its absence.

    Presence is a two-way fact about the world, not a fallible operation,
    so absence is reported with the same payload already used elsewhere
    for an absent resource rather than with a value outside the type.
    """
    for rid, rev in world.entries:
        if rid == resource:
            return rev
    return UnknownResource(resource)


def bump(world: World, resource: ResourceId) -> World:
    """Return a world with the first matching resource's revision incremented."""
    rebuilt: list[tuple[ResourceId, Revision]] = []
    found = False
    for rid, rev in world.entries:
        if not found and rid == resource:
            rebuilt.append((rid, Revision(rev.value + 1)))
            found = True
        else:
            rebuilt.append((rid, rev))
    return World(tuple(rebuilt))


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
