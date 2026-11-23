# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT


from __future__ import annotations

from necoherence.core import Basis, Revision, ResourceId
from necoherence.record import (
    NoBasis,
    has_edge,
    record_of,
    record_on_basis,
)


def _rid(name: int) -> ResourceId:
    return ResourceId(kind="core", name=str(name))


def _basis(resource: int, revision: int) -> Basis:
    return Basis(resource=_rid(resource), revision=Revision(revision))


def test_a_record_holds_declaration_input_and_product() -> None:
    held = record_of("example.greet", "world", "hello world")
    assert held.declaration == "example.greet"
    assert held.input == "world"
    assert held.product == "hello world"
    assert isinstance(held.basis, NoBasis)


def test_an_edge_holds_where_a_later_call_reads_the_settled_resource() -> None:
    earlier = record_on_basis("pane.apply", 1, "applied", _basis(3, 7))
    later = record_on_basis("pane.apply", 2, "conflicted", _basis(3, 7))
    disjoint = record_on_basis("pane.apply", 3, "applied", _basis(4, 1))

    assert has_edge(earlier, later)
    assert not has_edge(earlier, disjoint)


def test_a_record_without_a_basis_forms_no_edge() -> None:
    earlier = record_of("example.greet", 1, "one")
    later = record_on_basis("pane.apply", 2, "two", _basis(3, 7))

    assert not has_edge(earlier, later)
    assert not has_edge(later, earlier)


def test_record_on_basis_retains_the_given_basis() -> None:
    basis = _basis(0, 4)
    held = record_on_basis("core.apply", 1, "applied", basis)
    assert held.basis == basis
