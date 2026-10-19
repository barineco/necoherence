# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from copy import deepcopy

import pytest

from necoherence.signature_values import ValueContext, ValueFailure, variant
from v4_samples import integer_spec, profile, string_spec
from necoherence.type_signatures import _graph


def representative_graph(alphabet="Either"):
    value_profile = profile()
    value_profile["reference"]["identity"] = "representative-declarations"
    value_profile["integer_domains"] = [
        {
            "name": "default",
            "reference": deepcopy(value_profile["reference"]),
            "range": variant("Inclusive", fields={"minimum": "-100", "maximum": "100"}),
            "forms": [variant("Number"), variant("IntegralDecimal"), variant("DecimalString")],
        },
        {
            "name": "narrow",
            "reference": deepcopy(value_profile["reference"]),
            "range": variant("Inclusive", fields={"minimum": "0", "maximum": "10"}),
            "forms": [variant("Number")],
        },
    ]
    value_profile["default_integer_domain"] = "default"
    value_profile["format_bindings"].append({
        "name": "not-x",
        "reference": deepcopy(value_profile["reference"]),
        "rule": variant("Not", variant("Literal", "x")),
    })
    value_profile["grapheme_rules"] = {
        "properties": [{"first": "769", "last": "769", "property": variant("Extend")}]
    }
    value_profile["bytes_policy"]["alphabet"] = variant(alphabet)
    value_profile["tag"] = {
        "key": "tag",
        "format": "identifier",
        "sealed": [{
            "tag": "sealed",
            "fields": [{"key": "label", "required": True, "leaf": variant("String", string_spec())}],
            "extras": variant("Reject"),
        }],
    }
    value_profile["wrappers"][0] = {
        "name": "text-wrapper",
        "key": "text",
        "payload": variant("Text", None),
    }
    nodes = [
        {"id": "not-x", "shape": variant("String", string_spec(format=variant("Named", "not-x")))},
        {"id": "wrapped-text", "shape": variant("String", string_spec(wrapper="text-wrapper"))},
        {"id": "sealed", "shape": variant("Sealed", fields={"tag": "sealed", "refinements": []})},
        {"id": "narrow", "shape": variant("Integer", integer_spec(domain="narrow"))},
        {"id": "ordinary", "shape": variant("Product", {"fields": [], "extras": variant("Reject")})},
        {"id": "string", "shape": variant("String", string_spec())},
        {"id": "unknown-any", "shape": variant("Unknown", variant("Any"))},
        {"id": "string-array-nullable", "shape": variant("Array", {"item": {"type_id": "string", "nullable": True}, "min_length": None, "max_length": None})},
        {"id": "string-array-required", "shape": variant("Array", {"item": {"type_id": "string", "nullable": False}, "min_length": None, "max_length": None})},
        {"id": "unknown-array-required", "shape": variant("Array", {"item": {"type_id": "unknown-any", "nullable": False}, "min_length": None, "max_length": None})},
        {"id": "unknown-map-required", "shape": variant("Product", {"fields": [], "extras": variant("Allow", fields={"key_format": None, "value": {"type_id": "unknown-any", "nullable": False}})})},
        {"id": "integer-map-required", "shape": variant("Product", {"fields": [], "extras": variant("Allow", fields={"key_format": None, "value": {"type_id": "forms-integer", "nullable": False}})})},
        {"id": "never", "shape": variant("Never")},
        {"id": "forms-integer", "shape": variant("Integer", integer_spec(domain="default"))},
        {"id": "decimal", "shape": variant("Decimal", {"minimum": None, "maximum": None})},
        {"id": "utf8-two", "shape": variant("String", string_spec(lengths=[
            {"unit": variant("Utf8Bytes"), "minimum": "2", "maximum": "2"}
        ]))},
        {"id": "scalar-one", "shape": variant("String", string_spec(lengths=[
            {"unit": variant("UnicodeScalars"), "minimum": None, "maximum": "1"}
        ]))},
        {"id": "grapheme-one", "shape": variant("String", string_spec(lengths=[
            {"unit": variant("Graphemes"), "minimum": None, "maximum": "1"}
        ]))},
        {"id": "bytes", "shape": variant("Bytes", {"minimum": None, "maximum": None})},
    ]
    return _graph({"profile": value_profile, "nodes": nodes, "definitions": []})


CASES = [
    ("format-not-reject", "not-x", "x", "Format:not-x", (), "Either"),
    ("object-wrapper", "wrapped-text", {"text": "x"}, None, (), "Either"),
    ("object-sealed-tag-kind", "sealed", {"label": "x", "tag": 1}, "InvalidTag", ("tag",), "Either"),
    ("object-sealed-tag-format", "sealed", {"label": "x", "tag": "invalid tag"}, "InvalidTag", ("tag",), "Either"),
    ("object-sealed-tag-unicode", "sealed", {"label": "x", "tag": "\ud800"}, "InvalidDataModel", ("tag",), "Either"),
    ("integer-decimal-string", "narrow", "10", "WrongValueKind:integer", (), "Either"),
    ("integer-outside-domain", "narrow", 11, "IntegerDomain", (), "Either"),
    ("extras-reject", "ordinary", {"x": 1}, "UnexpectedField:x", ("x",), "Either"),
    ("never", "never", None, "InvalidDataModel", (), "Either"),
    ("integer-integral-decimal", "forms-integer", 10.0, None, (), "Either"),
    ("decimal-accept", "decimal", 1.5, None, (), "Either"),
    ("decimal-reject", "decimal", "1.5", "WrongValueKind:decimal", (), "Either"),
    ("length-utf8-reject", "utf8-two", "a", "StringLength", (), "Either"),
    ("length-scalar-reject", "scalar-one", "aa", "StringLength", (), "Either"),
    ("length-grapheme-reject", "grapheme-one", "ab", "StringLength", (), "Either"),
    ("bytes-standard-reject", "bytes", {"bytes": "-_8="}, "InvalidBytes", (), "Standard"),
    ("bytes-either-reject", "bytes", {"bytes": "?"}, "InvalidBytes", (), "Either"),
]


@pytest.mark.parametrize("identity,type_id,value,condition,path,alphabet", CASES, ids=[row[0] for row in CASES])
def test_value_decision_matches_lean(identity, type_id, value, condition, path, alphabet):
    context = ValueContext(representative_graph(alphabet))
    if condition is None:
        assert context.validate(type_id, value) == value
        return
    with pytest.raises(ValueFailure) as caught:
        context.validate(type_id, value)
    assert caught.value.condition == condition
    assert caught.value.value_path == path
    assert caught.value.reference_trace == ()


def test_element_contract_null_is_decided_by_nullable_or_child_type():
    context = ValueContext(representative_graph())
    assert context.validate("string-array-nullable", [None]) == [None]
    with pytest.raises(ValueFailure):
        context.validate("string-array-required", [None])
    assert context.validate("unknown-array-required", [None]) == [None]
    assert context.validate("unknown-map-required", {"x": None}) == {"x": None}
    with pytest.raises(ValueFailure):
        context.validate("integer-map-required", {"x": None})
@pytest.mark.parametrize("value", [1.25, -1.25, 6.02e23])
def test_unknown_any_accepts_profile_admitted_decimals(value):
    graph = representative_graph()
    graph["profile"]["integer_domains"][0]["forms"] = [variant("Number")]
    context = ValueContext(graph)
    assert context.validate("unknown-any", value) == value
    assert context.validate("unknown-array-required", [value]) == [value]
    assert context.validate("unknown-map-required", {"nested": [value]}) == {"nested": [value]}


def test_unknown_any_integral_decimal_precedes_decimal_admission():
    from necoherence.signature_values import DecimalLiteral

    graph = representative_graph()
    graph["profile"]["integer_domains"][0]["range"] = variant("Inclusive", fields={"minimum": "-10", "maximum": "10"})
    context = ValueContext(graph)
    assert context.validate("unknown-any", DecimalLiteral("1.0")) == DecimalLiteral("1.0")
    assert context.validate("unknown-any", DecimalLiteral("1.25")) == DecimalLiteral("1.25")
    with pytest.raises(ValueFailure) as caught:
        context.validate("unknown-any", DecimalLiteral("11.0"))
    assert caught.value.condition == "IntegerDomain"
    with pytest.raises(ValueFailure) as caught:
        context.validate("unknown-any", DecimalLiteral("1e999999"))
    assert caught.value.condition == "IntegerDomain"


def test_unknown_any_rejects_decimals_when_profile_disables_them():
    graph = representative_graph()
    graph["profile"]["numbers"]["decimals"] = False
    graph["profile"]["integer_domains"][0]["range"] = variant("Inclusive", fields={"minimum": "-10", "maximum": "10"})
    context = ValueContext(graph)
    from necoherence.signature_values import DecimalLiteral

    assert context.validate("unknown-any", DecimalLiteral("10.0")) == DecimalLiteral("10.0")
    with pytest.raises(ValueFailure) as caught:
        context.validate("unknown-any", DecimalLiteral("11.0"))
    assert caught.value.condition == "IntegerDomain"
    for value in (1.25, -1.25):
        with pytest.raises(ValueFailure) as caught:
            context.validate("unknown-any", value)
        assert caught.value.condition == "InvalidDataModel"
    with pytest.raises(ValueFailure) as caught:
        context.validate("unknown-any", 6.02e23)
    assert caught.value.condition == "IntegerDomain"


@pytest.mark.parametrize("text", ["01.2", "1.", "1e", "+1.0"])
def test_unknown_any_rejects_malformed_decimal_json(text):
    from necoherence.signature_values import decode_wire_json

    with pytest.raises(ValueError):
        decode_wire_json(text)

    from necoherence.signature_values import DecimalLiteral

    for text in ("01.2", "1.", "1e", "+1.0", "NaN", "Infinity"):
        with pytest.raises(ValueError):
            DecimalLiteral(text)


@pytest.mark.parametrize("value", [float("nan"), float("inf")])
def test_unknown_any_rejects_non_json_native_floats(value):
    with pytest.raises(ValueFailure) as caught:
        ValueContext(representative_graph()).validate("unknown-any", value)
    assert caught.value.condition == "InvalidDataModel"
