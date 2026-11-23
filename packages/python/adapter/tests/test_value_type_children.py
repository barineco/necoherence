# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""The types a shape refers to include the value type of an allowed extra member, as the Lean `typeChildren`."""

from typing import Any

from necoherence.signature_values import UnresolvedValueFailure, ValueContext
from test_semantic_graph_wire import _graph, _node, _reference


def _holder_graph(extras: dict[str, Any], *nodes: dict[str, Any]) -> dict[str, Any]:
    graph = _graph()
    shape = {"tag": "Product", "value": {"fields": [], "extras": extras}}
    graph["nodes"] = [_node("holder", shape), *nodes]
    return graph


def _allow(target: str) -> dict[str, Any]:
    return {"tag": "Allow", "fields": {"key_format": None, "value": {"type_ref": _reference(target), "nullable": False}}}


def test_the_meaning_walk_reaches_the_value_type_of_the_allowed_extra_members() -> None:
    context = ValueContext(_holder_graph(_allow("ghost")))
    obligations = context.meaning_obligations([_reference("holder")])
    assert [(item["type_ref"]["definition_name"], item["reason"]) for item in obligations] == [("ghost", {"tag": "UnresolvedType"})]


def test_the_meaning_walk_finds_nothing_when_the_extra_value_type_is_declared() -> None:
    graph = _holder_graph(_allow("flag"), _node("flag", {"tag": "Boolean", "value": {"const_value": None, "default_value": None}}))
    assert ValueContext(graph).meaning_obligations([_reference("holder")]) == []


def test_the_meaning_walk_does_not_reach_a_type_of_rejected_extra_members() -> None:
    assert ValueContext(_holder_graph({"tag": "Reject"})).meaning_obligations([_reference("holder")]) == []


def test_a_value_of_a_product_whose_extra_value_type_is_undeclared_is_unresolved() -> None:
    context = ValueContext(_holder_graph(_allow("ghost")))
    try:
        context.validate(_reference("holder"), {"a": 1})
    except UnresolvedValueFailure as failure:
        assert [item["reason"] for item in failure.obligations] == [{"tag": "UnresolvedType"}]
    else:
        raise AssertionError("an undeclared extra value type is unresolved")
