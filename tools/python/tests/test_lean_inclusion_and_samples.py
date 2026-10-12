# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

import copy

import pytest

from necoherence.signature_values import DecimalLiteral, ValueContext, ValueFailure, variant
from necoherence_tools.inclusion_samples import compatible, sample_values
from test_profile_predicate_vectors import valid_profile
from v4_samples import integer_spec, string_spec


def field(name, target, required=True, nullable=False):
    return {"wire_name": name, "slot": {"type_id": target, "required": required, "nullable": nullable}}


def node(name, shape):
    return {"id": name, "shape": shape}


def product(fields=(), extras=None):
    return variant("Product", {"fields": list(fields), "extras": extras or variant("Reject")})


def allow(value, key_format=None, nullable=False):
    return variant("Allow", fields={"key_format": key_format, "value": {"type_id": value, "nullable": nullable}})


def branch(target, wire_tag, selector=None):
    return {"target": target, "wire_tag": wire_tag, "selector": selector or variant("InternalTag")}


def profile():
    value = valid_profile()
    value["integer_domains"] = [
        {"name": "zero-to-ten", "reference": copy.deepcopy(value["reference"]),
         "range": variant("Inclusive", fields={"minimum": "0", "maximum": "10"}),
         "forms": [variant("Number")]},
        {"name": "forms", "reference": copy.deepcopy(value["reference"]),
         "range": variant("Inclusive", fields={"minimum": "0", "maximum": "10"}),
         "forms": [variant("Number"), variant("IntegralDecimal"), variant("DecimalString")]},
    ]
    value["default_integer_domain"] = "zero-to-ten"
    value["format_bindings"] = [
        {"name": "all-text", "reference": copy.deepcopy(value["reference"]), "rule": variant("Text")},
        {"name": "not-a", "reference": copy.deepcopy(value["reference"]), "rule": variant("Not", variant("Literal", "a"))},
        {"name": "key-x", "reference": copy.deepcopy(value["reference"]), "rule": variant("Literal", "x")},
    ]
    value["tag"]["format"] = "all-text"
    value["tag"]["sealed"] = [{
        "tag": "sealed",
        "fields": [
            {"key": "text", "required": True, "leaf": variant("String", string_spec(const_value="x"))},
            {"key": "count", "required": True, "leaf": variant("Integer", integer_spec(const_value="1"))},
        ],
        "extras": variant("Reject"),
    }]
    value["tag"]["key"] = "tag"
    value["wrappers"] = [{"name": "bytes", "key": "bytes", "payload": variant("Bytes")}]
    value["bytes_policy"]["wrapper"] = "bytes"
    return value


def context(nodes):
    return ValueContext({"profile": profile(), "nodes": nodes})


def assert_incompatible(values, source, destination, witness):
    result = compatible(values, source, destination)
    assert result["classification"] == "incompatible"
    assert result["counterexample"] == witness
    values.validate(source, witness)
    with pytest.raises(ValueFailure):
        values.validate(destination, witness)


def test_c1_i1_format_inclusion_matches_lean():
    values = context([
        node("text-string", variant("String", string_spec(format=variant("Named", "all-text")))),
        node("not-a-string", variant("String", string_spec(format=variant("Named", "not-a")))),
    ])
    assert compatible(values, "not-a-string", "not-a-string")["classification"] == "compatible"
    assert_incompatible(values, "text-string", "not-a-string", "a")


def test_c2_and_product_rule_pairs_match_lean():
    values = context([
        node("any", variant("Unknown", variant("Any"))),
        node("c2-source", product(extras=allow("any", variant("Inline", variant("Literal", "x"))))),
        node("c2-destination", product(extras=allow("any", variant("Inline", variant("Text"))))),
    ])
    assert compatible(values, "c2-source", "c2-destination")["classification"] == "compatible"

    values = context([
        node("order-text", variant("String", string_spec())),
        node("order-integer", variant("Integer", integer_spec())),
        node("order-source", product([field("text", "order-text"), field("integer", "order-integer")])),
        node("order-destination", product([field("integer", "order-integer"), field("text", "order-text")])),
    ])
    assert compatible(values, "order-source", "order-destination")["classification"] == "compatible"

    values = context([
        node("source-field-integer", variant("Integer", integer_spec())),
        node("source-field-source", product([field("x", "source-field-integer")])),
        node("source-field-destination", product(extras=allow("source-field-integer", variant("Inline", variant("Literal", "x"))))),
    ])
    assert compatible(values, "source-field-source", "source-field-destination")["classification"] == "compatible"


def test_product_extras_value_and_destination_field_rules_match_lean():
    values = context([
        node("zero-to-nine", variant("Integer", integer_spec(domain="zero-to-ten", minimum="0", maximum="9"))),
        node("zero-to-ten", variant("Integer", integer_spec(domain="zero-to-ten", minimum="0", maximum="10"))),
        node("source", product(extras=allow("zero-to-nine", variant("Inline", variant("Literal", "x"))))),
        node("destination", product(extras=allow("zero-to-ten", variant("Inline", variant("Literal", "x"))))),
    ])
    assert compatible(values, "source", "destination")["classification"] == "compatible"
    assert_incompatible(values, "destination", "source", {"x": 10})

    for required, expected in ((False, "compatible"), (True, "incompatible")):
        values = context([
            node("zero-to-nine", variant("Integer", integer_spec(domain="zero-to-ten", minimum="0", maximum="9"))),
            node("zero-to-ten", variant("Integer", integer_spec(domain="zero-to-ten", minimum="0", maximum="10"))),
            node("source", product(extras=allow("zero-to-nine"))),
            node("destination", product([field("y", "zero-to-ten", required=required)], allow("zero-to-ten"))),
        ])
        result = compatible(values, "source", "destination")
        assert result["classification"] == expected
        if required:
            assert result["counterexample"] == {}


def test_element_null_inclusion_and_samples_match_the_contract():
    values = context([
        node("any", variant("Unknown", variant("Any"))),
        node("text", variant("String", string_spec())),
        node("source", product(extras=allow("any"))),
        node("destination", product([field("x", "any", required=False)], allow("any"))),
        node("nullable-array", variant("Array", {"item": {"type_id": "text", "nullable": True}, "min_length": "1", "max_length": "1"})),
        node("nullable-map", product(extras=allow("text", variant("Inline", variant("Literal", "x")), nullable=True))),
    ])
    assert_incompatible(values, "source", "destination", {"x": None})
    assert [None] in sample_values(values, len(values.nodes) + 1, (), "nullable-array").values
    assert {"x": None} in sample_values(values, len(values.nodes) + 1, (), "nullable-map").values


def test_i2_product_optional_field_witness_matches_lean():
    values = context([
        node("tag-x", variant("String", string_spec(const_value="x"))),
        node("source", product()),
        node("destination", product([field("tag", "tag-x", required=False)])),
    ])
    assert_incompatible(values, "source", "destination", {"tag": "y"})


def test_c3_i3_union_pairs_match_lean():
    payload = node("payload", product())
    values = context([
        payload,
        node("c3-source", variant("TaggedUnion", {"branches": [branch("payload", "a")]})),
        node("c3-destination", variant("TaggedUnion", {"branches": [branch("payload", "a"), branch("payload", "b")]})),
        node("i3-source", variant("TaggedUnion", {"branches": [branch("payload", "a"), branch("payload", "b")]})),
        node("i3-destination", variant("TaggedUnion", {"branches": [branch("payload", "a")]})),
    ])
    assert compatible(values, "c3-source", "c3-destination")["classification"] == "compatible"
    assert_incompatible(values, "i3-source", "i3-destination", {"tag": "b"})


def test_c4_i4_integer_ranges_match_lean():
    values = context([
        node("zero-to-nine", variant("Integer", integer_spec(domain="zero-to-ten", minimum="0", maximum="9"))),
        node("zero-to-ten", variant("Integer", integer_spec(domain="zero-to-ten", minimum="0", maximum="10"))),
    ])
    assert compatible(values, "zero-to-nine", "zero-to-ten")["classification"] == "compatible"
    assert_incompatible(values, "zero-to-ten", "zero-to-nine", 10)


def test_c5_i5_scalar_lengths_match_lean():
    one = [{"unit": variant("UnicodeScalars"), "minimum": None, "maximum": "1"}]
    two = [{"unit": variant("UnicodeScalars"), "minimum": None, "maximum": "2"}]
    values = context([
        node("scalar-one", variant("String", string_spec(lengths=one))),
        node("scalar-two", variant("String", string_spec(lengths=two))),
    ])
    assert compatible(values, "scalar-one", "scalar-two")["classification"] == "compatible"
    assert_incompatible(values, "scalar-two", "scalar-one", "aa")


def test_i6_i7_extra_and_wrapper_witnesses_match_lean():
    values = context([
        node("any", variant("Unknown", variant("Any"))),
        node("source", product(extras=allow("any", variant("Inline", variant("Literal", "x"))))),
        node("destination", product()),
    ])
    assert_incompatible(values, "source", "destination", {"x": {}})

    values = context([
        node("bytes-source", variant("Bytes", {"minimum": None, "maximum": None})),
        node("ordinary-object", variant("Unknown", variant("OrdinaryObject"))),
    ])
    assert_incompatible(values, "bytes-source", "ordinary-object", {"bytes": ""})


def sample_context():
    shape_text = variant("String", string_spec(format=variant("Named", "all-text")))
    return context([
        node("bytes", variant("Bytes", {"minimum": None, "maximum": None})),
        node("sealed", variant("Sealed", fields={"tag": "sealed", "refinements": []})),
        node("shape-text", shape_text),
        node("selector-product", product([field("shape", "shape-text", required=False)])),
        node("kind-string", variant("String", string_spec())),
        node("otherwise-boolean", variant("Boolean", {"const_value": None, "default_value": None})),
        node("selector-union", variant("TaggedUnion", {"branches": [
            branch("selector-product", "internal"),
            branch("selector-product", "shape", variant("MemberShape", [{"key": "shape", "test": variant("Format", "all-text")}])) ,
            branch("kind-string", "string", variant("Kind", variant("String"))),
            branch("otherwise-boolean", "otherwise", variant("Otherwise")),
        ]})),
        node("integer-forms", variant("Integer", integer_spec(domain="forms"))),
        node("bytes-length", variant("String", string_spec(lengths=[{"unit": variant("Utf8Bytes"), "minimum": "2", "maximum": "2"}]))),
        node("scalar-length", variant("String", string_spec(lengths=[{"unit": variant("UnicodeScalars"), "minimum": "2", "maximum": "2"}]))),
        node("grapheme-length", variant("String", string_spec(lengths=[{"unit": variant("Graphemes"), "minimum": "2", "maximum": "2"}]))),
        node("any", variant("Unknown", variant("Any"))),
        node("extras", product(extras=allow("any", variant("Named", "key-x")))),
    ])


@pytest.mark.parametrize("name", ["bytes", "sealed", "selector-union", "integer-forms", "bytes-length", "scalar-length", "grapheme-length", "extras"])
def test_representative_samples_are_nonempty_and_accepted(name):
    values = sample_context()
    result = sample_values(values, len(values.nodes) + 1, (), name)
    assert result.values
    for value in result.values:
        values.validate(name, value)


def test_representative_sample_shapes_match_lean():
    result = {name: sample_values(sample_context(), 20, (), name).values for name in (
        "bytes", "sealed", "selector-union", "integer-forms", "bytes-length",
        "scalar-length", "grapheme-length", "extras")}
    assert any("bytes" in value for value in result["bytes"])
    assert any("tag" in value for value in result["sealed"])
    assert any(isinstance(value, dict) and "tag" in value for value in result["selector-union"])
    assert any(isinstance(value, dict) and "shape" in value for value in result["selector-union"])
    assert any(type(value) is str for value in result["selector-union"])
    assert any(type(value) is bool for value in result["selector-union"])
    assert 0 in result["integer-forms"]
    assert DecimalLiteral("0") in result["integer-forms"]
    assert "0" in result["integer-forms"]
    for name in ("bytes-length", "scalar-length", "grapheme-length"):
        assert "aa" in result[name]
    assert any("x" in value for value in result["extras"])


def test_sample_bound_obligations_match_lean():
    values = context([node("long", variant("String", string_spec(const_value="aaaa")))])
    result = sample_values(values, 2, (), "long", 3)
    assert result.values == ()
    assert result.obligations == ("sampleBound",)

    values = context([
        node("flag", variant("Boolean", {"const_value": None, "default_value": None})),
        node("four-fields", product([field(name, "flag") for name in "abcd"])),
    ])
    bounded = sample_values(values, len(values.nodes) + 1, (), "four-fields", 3)
    unbounded = sample_values(values, len(values.nodes) + 1, (), "four-fields", 4)
    assert bounded.values == () and bounded.obligations == ("sampleBound",)
    assert unbounded.values and unbounded.obligations == ()
