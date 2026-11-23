# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from typing import cast

"""Regression checks for the composition wire against the Lean keys, get, and payload rules."""

import pytest

from necoherence.semantic_composition import TypeRef, _type_ref_native
from necoherence.composition_wire_base import wire_list, wire_natural, wire_record, wire_string
from necoherence.semantic_composition import CompositionInput, GoalSpec, InvocationDomain, SearchBounds, SemanticBasis
from necoherence.signature_composition_wire import _decode_path_step
from necoherence.signature_values import ValueContext, WireFailure, decode_wire_json

SOURCE = {
    "repository": "ncoh-type-signatures@1",
    "revision": "rev",
    "path": "path",
    "content_digest": "digest",
    "document_id": "doc",
    "declared_revision": None,
}


_LIBRARY: dict[str, object] = {}
_INPUT = CompositionInput(
    identity="",
    revision="",
    basis=SemanticBasis({}, ()),
    signatures=(),
    initial_inputs=(),
    initial_resources=(),
    goal=GoalSpec((), (), ()),
    invocation_domain=InvocationDomain("", "", (), (), (), (), ()),
    allowed_effects=(),
    explicit_order=(),
    bounds=SearchBounds(),
)


def _ref(name: str) -> TypeRef:
    return TypeRef(SOURCE, name, ())


def _native(name: str) -> dict[str, object]:
    return {"source": SOURCE, "definition_name": name, "pointer": []}


def _node(name: str, tag: str, value: object) -> dict[str, object]:
    return {"reference": _native(name), "shape": {"tag": tag, "value": value}}


def _graph(nodes: list[dict[str, object]]) -> dict[str, object]:
    profile = {
        "reference": {"name": "profile"},
        "default_integer_domain": "number",
        "integer_domains": [],
    }
    return {"profile": profile, "nodes": nodes}


def test_missing_field_is_a_syntax_failure_with_the_lean_message() -> None:
    with pytest.raises(WireFailure) as caught:
        wire_record({"b": 1}, ("a", "b"), "$")
    assert (caught.value.kind, caught.value.path, caught.value.observed) == ("Syntax", "$.a", "missing field")


def test_unknown_field_is_reported_before_a_missing_field_at_the_field_path() -> None:
    with pytest.raises(WireFailure) as caught:
        wire_record({"z": 1, "y": 2}, ("a",), "$.x")
    assert (caught.value.kind, caught.value.path, caught.value.observed) == ("UnknownField", "$.x.y", "y")


def test_list_elements_carry_their_index_in_the_path() -> None:
    def string_item(value: object, path: str) -> str:
        return wire_string(value, path)

    with pytest.raises(WireFailure) as caught:
        wire_list([1], "$.labels", string_item)
    assert (caught.value.path, caught.value.observed) == ("$.labels[0]", "String expected")


def test_variant_payload_keeps_the_path_of_the_enclosing_value() -> None:
    with pytest.raises(WireFailure) as caught:
        _decode_path_step({"tag": "Index", "value": "-1"}, "$.path")
    assert (caught.value.path, caught.value.observed) == ("$.path", "negative natural")


@pytest.mark.parametrize(
    ("text", "message"),
    [("x", "expected canonical integer"), ("01", "noncanonical integer"), ("-1", "negative natural"), (1, "String expected")],
)
def test_natural_failures_use_the_lean_messages(text: object, message: str) -> None:
    with pytest.raises(WireFailure) as caught:
        wire_natural(text, "$.n")
    assert (caught.value.path, caught.value.observed) == ("$.n", message)


def test_duplicate_object_key_is_a_syntax_failure_at_the_root() -> None:
    with pytest.raises(WireFailure) as caught:
        decode_wire_json('{"a": 1, "a": 2}')
    assert (caught.value.kind, caught.value.path, caught.value.observed) == (
        "Syntax",
        "$",
        "duplicate object key: a",
    )


def test_meaning_obligations_walk_all_references_once() -> None:
    shared = _native("Count")
    product = _node(
        "Pair",
        "Product",
        {"fields": [{"slot": {"type_ref": _native("Count")}, "wire_name": "count"}], "extras": {"tag": "Reject"}},
    )
    array = _node("Counts", "Array", {"item": {"type_ref": shared}})
    count = _node("Count", "Integer", {"domain": "missing", "minimum": None, "maximum": None})
    graph = _graph([product, array, count])

    obligations = tuple(ValueContext(graph).meaning_obligations([_type_ref_native(_ref("Pair")), _type_ref_native(_ref("Counts"))]))

    assert [cast(dict[str, object], item)["reason"] for item in obligations] == [{"tag": "UnknownIntegerDomain", "value": "missing"}]


def test_the_allowed_extras_type_is_a_child_of_the_product() -> None:
    extra = _native("Extra")
    product = _node(
        "Holder",
        "Product",
        {"fields": [], "extras": {"tag": "Allow", "fields": {"value": {"type_ref": extra}}}},
    )
    extra_node = _node("Extra", "Integer", {"domain": "missing", "minimum": None, "maximum": None})
    graph = _graph([product, extra_node])

    obligations = tuple(ValueContext(graph).meaning_obligations([_type_ref_native(_ref("Holder"))]))

    assert [cast(dict[str, object], item)["reason"] for item in obligations] == [{"tag": "UnknownIntegerDomain", "value": "missing"}]


