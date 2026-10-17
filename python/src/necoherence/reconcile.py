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


def _resources_of(bases: tuple[Basis | None, ...]) -> tuple[ResourceId, ...]:
    acc: list[ResourceId] = []
    for mb in bases:
        if mb is None:
            continue
        if mb.resource not in acc:
            acc.append(mb.resource)
    return tuple(acc)


def _max_revision(bases: tuple[Basis | None, ...], r: ResourceId) -> Revision | None:
    acc: Revision | None = None
    for mb in bases:
        if mb is None or mb.resource != r:
            continue
        if acc is None or mb.revision.value > acc.value:
            acc = mb.revision
    return acc


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
    resources = _resources_of(bases)
    unbased = sum(1 for mb in bases if mb is None)
    divergences: list[Divergence] = []
    for r in resources:
        recorded = _max_revision(bases, r)
        if recorded is None:
            continue
        divergence = _divergence_at(world, r, recorded)
        if divergence is not None:
            divergences.append(divergence)
    return Reconciliation(divergences=tuple(divergences), unbased=unbased, dropped=dropped)
