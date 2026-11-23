# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Reconcile a recorded call history against the world it should have produced.

For each resource named by a basis in the input, take the highest recorded
revision seen for that resource across all inputs, then compare that
revision against the world's own revision. Mirrors ``Reconcile.lean``.
"""

from __future__ import annotations

from dataclasses import dataclass

from necoherence.core import Basis, ResourceId, Revision, World, lookup
from necoherence.core import UnknownResource


@dataclass(frozen=True, slots=True)
class WorldAhead:
    """The world holds a revision more than one step past what was recorded."""

    resource: ResourceId
    recorded: Revision
    actual: Revision


@dataclass(frozen=True, slots=True)
class WorldBehind:
    """The world holds a revision less than what was recorded."""

    resource: ResourceId
    recorded: Revision
    actual: Revision


@dataclass(frozen=True, slots=True)
class UnknownToWorld:
    """A recorded resource is absent from the world."""

    resource: ResourceId
    recorded: Revision


type Divergence = WorldAhead | WorldBehind | UnknownToWorld


@dataclass(frozen=True, slots=True)
class Reconciliation:
    """Closed reconciliation product. Carries no derivable boolean field."""

    divergences: tuple[Divergence, ...]
    unbased: int
    dropped: int


def coherent(r: Reconciliation) -> bool:
    """Read whether the reconciliation is free of any gap."""
    return len(r.divergences) == 0 and r.unbased == 0 and r.dropped == 0


def _divergence_at(world: World, r: ResourceId, recorded: Revision) -> Divergence | None:
    actual = lookup(world, r)
    if isinstance(actual, UnknownResource):
        return UnknownToWorld(resource=r, recorded=recorded)
    if actual.value > recorded.value + 1:
        return WorldAhead(resource=r, recorded=recorded, actual=actual)
    if actual.value < recorded.value:
        return WorldBehind(resource=r, recorded=recorded, actual=actual)
    return None


def reconcile(bases: tuple[Basis | None, ...], world: World, dropped: int) -> Reconciliation:
    """Reconcile the highest recorded revision per resource against
    ``world``. ``dropped`` is supplied by the caller as a value; it is not
    counted here."""
    positions: dict[ResourceId, int] = {}
    resources: list[ResourceId] = []
    highest: list[Revision] = []
    unbased = 0
    for mb in bases:
        if mb is None:
            unbased += 1
            continue
        position = positions.get(mb.resource)
        if position is None:
            positions[mb.resource] = len(resources)
            resources.append(mb.resource)
            highest.append(mb.revision)
        elif mb.revision.value > highest[position].value:
            highest[position] = mb.revision
    divergences: list[Divergence] = []
    for resource, recorded in zip(resources, highest):
        divergence = _divergence_at(world, resource, recorded)
        if divergence is not None:
            divergences.append(divergence)
    return Reconciliation(divergences=tuple(divergences), unbased=unbased, dropped=dropped)
