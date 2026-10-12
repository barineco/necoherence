# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Provenance of calls as data.

An edge exists where a later input carries the basis an earlier product
settled. A caller holds its own record values as immutable data; nothing
here writes, sinks, or counts records on the caller's behalf.

This module does not touch ``core`` or ``call``. It is an independent
vocabulary: a record does not add a third declared type to ``io`` /
``issue``, and it settles nothing itself.
"""

from __future__ import annotations

from dataclasses import dataclass

from necoherence.core import Basis


@dataclass(frozen=True, slots=True)
class NoBasis:
    """Closed payload for a record that carries no basis.

    ``CallRecord.basis`` never holds ``None``: a record without a basis
    holds this value instead, the same way ``core.lookup`` and
    ``files.lookup_digest`` report absence with a value rather than with a
    type-external ``None``. Unlike ``UnknownResource`` (a resource is
    absent from a world) or ``UnobservedContents`` (a digest was never
    recorded), ``NoBasis`` names a third, distinct absence: this particular
    call was never situated on a basis at all, so there is nothing to
    reject or fail to observe.
    """


type MaybeBasis = Basis | NoBasis


@dataclass(frozen=True, slots=True)
class CallRecord[Input, Product]:
    """One call: which declaration ran, on what input, and what settled.

    The edge to a later call is not stored here; it is derived by
    ``has_edge`` from the two records' bases.
    """

    declaration: str
    input: Input
    product: Product
    basis: MaybeBasis


def record_of[Input, Product](
    declaration: str, input: Input, product: Product
) -> CallRecord[Input, Product]:
    """Build a ``CallRecord`` without a basis."""
    return CallRecord(declaration=declaration, input=input, product=product, basis=NoBasis())


def record_on_basis[Input, Product](
    declaration: str, input: Input, product: Product, basis: Basis
) -> CallRecord[Input, Product]:
    """Build a ``CallRecord`` that carries the basis its command was situated on."""
    return CallRecord(declaration=declaration, input=input, product=product, basis=basis)


def has_edge(earlier: CallRecord[object, object], later: CallRecord[object, object]) -> bool:
    """Hold where ``later`` reads the resource ``earlier`` settled.

    An absent edge witnesses that two calls touched disjoint coordinates,
    or that either call carries no basis at all.
    """
    if isinstance(earlier.basis, NoBasis) or isinstance(later.basis, NoBasis):
        return False
    return earlier.basis.resource == later.basis.resource
