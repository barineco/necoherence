# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

import pytest

from necoherence.signature_values import (
    ValueContext,
    _json_size,
    canonical_wire,
    decode_wire_json,
    encode_wire_json,
    exact_decode,
    exact_encode,
    exact_from_json,
    variant,
)
from necoherence.type_signatures import _graph

SHALLOW = 1000
DEEP = 10000


def nested_arrays(depth):
    return "[" * depth + "]" * depth


def nested_objects(depth):
    return '{"child":' * depth + "{}" + "}" * depth


def context(nodes):
    return ValueContext(_graph({"profile": {"tag": None}, "nodes": nodes, "definitions": []}))


def array_node():
    return {
        "id": "list",
        "shape": variant("Array", {"item": {"type_id": "list", "nullable": False}, "min_length": None, "max_length": None}),
    }


def child_node():
    return {
        "id": "node",
        "shape": variant(
            "Product",
            {
                "fields": [{"wire_name": "child", "slot": {"type_id": "node", "required": False, "nullable": False}}],
                "extras": variant("Reject"),
            },
        ),
    }


def unknown_node():
    return {"id": "any", "shape": variant("Unknown", variant("Any"))}


@pytest.mark.parametrize("depth", [SHALLOW, DEEP])
def test_nested_arrays_are_read_with_their_size(depth):
    assert _json_size(decode_wire_json(nested_arrays(depth))) == depth


@pytest.mark.parametrize("depth", [SHALLOW, DEEP])
def test_nested_objects_are_read_with_their_size(depth):
    assert _json_size(decode_wire_json(nested_objects(depth))) == depth + 1


@pytest.mark.parametrize("depth", [SHALLOW, DEEP])
def test_nested_arrays_are_converted_to_exact_values_with_their_size(depth):
    assert _json_size(exact_from_json(decode_wire_json(nested_arrays(depth)))) == depth


@pytest.mark.parametrize("depth", [SHALLOW, DEEP])
def test_nested_values_are_written_back_as_their_canonical_text(depth):
    assert canonical_wire(decode_wire_json(nested_arrays(depth))) == nested_arrays(depth)
    assert canonical_wire(decode_wire_json(nested_objects(depth))) == nested_objects(depth)
    assert encode_wire_json(decode_wire_json(nested_arrays(depth))) == nested_arrays(depth)


@pytest.mark.parametrize("depth", [SHALLOW, DEEP])
def test_nested_values_round_trip_through_exact_encoding(depth):
    for text in (nested_arrays(depth), nested_objects(depth)):
        value = exact_from_json(decode_wire_json(text))
        assert _json_size(exact_decode(exact_encode(value))) == _json_size(value)


@pytest.mark.parametrize("depth", [SHALLOW, DEEP])
def test_nested_arrays_are_accepted_by_a_recursive_array_type(depth):
    value = decode_wire_json(nested_arrays(depth))
    assert context([array_node()]).validate("list", value) is value
    assert context([array_node()]).encode("list", value) is value


@pytest.mark.parametrize("depth", [SHALLOW, DEEP])
def test_nested_objects_are_accepted_by_a_recursive_product_type(depth):
    value = decode_wire_json(nested_objects(depth))
    assert context([child_node()]).validate("node", value) is value


@pytest.mark.parametrize("depth", [SHALLOW, DEEP])
def test_nested_values_are_accepted_by_an_unknown_type(depth):
    for text in (nested_arrays(depth), nested_objects(depth)):
        value = decode_wire_json(text)
        assert context([unknown_node()]).validate("any", value) is value


@pytest.mark.parametrize("depth", [SHALLOW, DEEP])
def test_nested_arrays_keep_their_size_when_defaults_are_materialized(depth):
    result = context([array_node()]).decode_with_defaults("list", nested_arrays(depth))
    assert result.applications == ()
    assert _json_size(result.value) == depth
