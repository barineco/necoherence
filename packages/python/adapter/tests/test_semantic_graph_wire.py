# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""The semantic graph wire reads the key set of every record before it reads a field, as the Lean tools decoder does."""

import copy
from collections.abc import Iterator
from typing import Any

import pytest

from necoherence.semantic_graph_wire import SEMANTIC_GRAPH
from necoherence.signature_values import WireFailure
from v4_samples import library

SOURCE = {"repository": "r", "revision": "1", "path": "p", "content_digest": "d", "document_id": "doc", "declared_revision": None}


def _reference(name: str) -> dict[str, Any]:
    return {"source": copy.deepcopy(SOURCE), "definition_name": name, "pointer": [name]}


def _origin() -> dict[str, Any]:
    return {"source": copy.deepcopy(SOURCE), "pointer": ["origin"]}


def _node(name: str, shape: dict[str, Any]) -> dict[str, Any]:
    return {"reference": _reference(name), "shape": shape, "description": None, "attributes": [_origin()], "extensions": [_origin()]}


def _graph() -> dict[str, Any]:
    slot = {"type_ref": _reference("leaf"), "required": True, "nullable": False}
    element = {"type_ref": _reference("leaf"), "nullable": False}
    nodes = [
        _node("flag", {"tag": "Boolean", "value": {"const_value": None, "default_value": None}}),
        _node("unit", {"tag": "Unit"}),
        _node("never", {"tag": "Never"}),
        _node("alias", {"tag": "Alias", "fields": {"target": _reference("leaf"), "reference_text": "leaf"}}),
        _node("array", {"tag": "Array", "value": {"item": element, "min_length": None, "max_length": None}}),
        _node("leaf", {"tag": "Product", "value": {
            "fields": [{"wire_name": "a", "slot": slot, "origin": _origin()}],
            "extras": {"tag": "Allow", "fields": {"key_format": None, "value": element}},
        }}),
        _node("closed", {"tag": "Product", "value": {"fields": [], "extras": {"tag": "Reject"}}}),
        _node("union", {"tag": "TaggedUnion", "value": {"branches": [
            {"target": _reference("leaf"), "wire_tag": "t", "selector": {"tag": "InternalTag"}, "origin": _origin()},
        ]}}),
    ]
    return {"profile": library()["profile"], "nodes": nodes, "source_refs": [copy.deepcopy(SOURCE)]}


def _records(value: Any, path: tuple[Any, ...] = ()) -> Iterator[tuple[Any, ...]]:
    if isinstance(value, dict):
        yield path
        for name, item in value.items():
            yield from _records(item, (*path, name))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from _records(item, (*path, index))


def _at(value: Any, path: tuple[Any, ...]) -> Any:
    for step in path:
        value = value[step]
    return value


def _paths_outside_the_profile() -> list[tuple[Any, ...]]:
    return [path for path in _records(_graph()) if path[:1] != ("profile",)]


def test_a_graph_with_every_shape_is_accepted() -> None:
    SEMANTIC_GRAPH(_graph(), "$")


@pytest.mark.parametrize("path", _paths_outside_the_profile(), ids=lambda path: ".".join(map(str, path)) or "graph")
def test_a_record_with_an_extra_key_is_an_unknown_field(path: tuple[Any, ...]) -> None:
    graph = _graph()
    _at(graph, path)["extra"] = 1
    with pytest.raises(WireFailure) as caught:
        SEMANTIC_GRAPH(graph, "$")
    assert (caught.value.kind, caught.value.observed) == ("UnknownField", "extra")


def test_the_key_set_of_a_node_is_checked_before_its_fields() -> None:
    graph = _graph()
    graph["nodes"][0]["reference"] = "not a record"
    graph["nodes"][0]["extra"] = 1
    with pytest.raises(WireFailure) as caught:
        SEMANTIC_GRAPH(graph, "$")
    assert caught.value.kind == "UnknownField"


def test_an_unknown_shape_tag_is_an_unknown_tag_failure() -> None:
    graph = _graph()
    graph["nodes"][0]["shape"] = {"tag": "Bytes", "value": {"minimum": None, "maximum": None}}
    with pytest.raises(WireFailure) as caught:
        SEMANTIC_GRAPH(graph, "$")
    assert (caught.value.kind, caught.value.observed) == ("UnknownTag", "Bytes")
