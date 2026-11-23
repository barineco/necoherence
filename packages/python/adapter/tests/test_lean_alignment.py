# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Regression checks that align the Python core with the Lean behavior."""

from typing import Any, cast

import pytest

from necoherence import signature_values as sv
from necoherence import type_signatures as ts
from necoherence import wire_schema as ws
from necoherence.composition_wire_base import wire_list
from necoherence.semantic_composition import PairEntry, SlotContract, TypeObligation, TypePair, TypeRef, UnitTypeObligationReason
from necoherence.signature_values import WireFailure, decode_wire_json


def _wire_failure(text: str) -> WireFailure:
    with pytest.raises(WireFailure) as caught:
        decode_wire_json(text)
    return caught.value


@pytest.mark.parametrize("text", ['"\\ud800"', '"\\udc00"', '"\\ud800\\u0041"', '{"\\ud800": 1}'])
def test_lone_surrogate_escape_is_a_typed_syntax_failure(text: str) -> None:
    failure = _wire_failure(text)
    assert (failure.kind, failure.path, failure.observed) == ("Syntax", "$", "unpaired Unicode surrogate")


def test_json_stage_failures_are_json_failures() -> None:
    for text in ('{"a": 1, "a": 2}', '"\\ud800"', "1e10000", "{", '{"a": NaN}'):
        assert isinstance(_wire_failure(text), sv.JsonFailure)


@pytest.mark.parametrize("text", ["-0", "1" + "0" * 5000, "1e9999"])
def test_numbers_below_the_limit_are_read_without_the_integer_string_limit(text: str) -> None:
    decode_wire_json(text)


def test_canonical_number_of_a_positive_exponent_below_the_limit_is_the_full_digit_text() -> None:
    assert ts._canonical_number("1e9999") == "1" + "0" * 9999
    assert ts._canonical_number("-12.5e3") == "-12500"
    assert ts._canonical_number("1" + "0" * 5000) == "1" + "0" * 5000


def test_surrogate_pair_escape_is_accepted() -> None:
    assert decode_wire_json('"\\ud83d\\ude00"') == "\U0001F600"


@pytest.mark.parametrize(("text", "key"), [('{"ten":10.0,"ten":1.0}', "ten"), ('{"child":{"flag":true,"flag":false}}', "flag"), ('{"flag":true,"\\u0066lag":false}', "flag")])
def test_duplicate_object_key_is_a_syntax_failure_at_the_parse(text: str, key: str) -> None:
    failure = _wire_failure(text)
    assert (failure.kind, failure.path, failure.observed) == ("Syntax", "$", "duplicate object key: " + key)


def test_positive_exponent_at_the_limit_is_a_typed_syntax_failure() -> None:
    failure = _wire_failure("1e10000")
    assert (failure.kind, failure.path, failure.observed) == ("Syntax", "$", "exponent too large")


def test_uppercase_positive_exponent_at_the_limit_is_a_typed_syntax_failure() -> None:
    failure = _wire_failure("[1E+10000]")
    assert (failure.kind, failure.observed) == ("Syntax", "exponent too large")


@pytest.mark.parametrize("text", ["1e42", "1e9999", "1e-42", "1e-9999"])
def test_exponent_below_the_limit_in_either_sign_is_accepted(text: str) -> None:
    decode_wire_json(text)


def test_exponent_text_inside_a_string_is_not_a_number_exponent() -> None:
    assert decode_wire_json('"1e10000"') == "1e10000"


@pytest.mark.parametrize("text, output", [("0", "0"), ("0.0", "0.0"), ("0e11", "0"), ("-0.00e5", "0")])
def test_zero_number_is_written_as_the_lean_number_text(text: str, output: str) -> None:
    assert sv.canonical_json(sv.exact_from_json(decode_wire_json(text)), sv._exact_number) == output


def test_product_extras_value_type_is_a_child_of_the_product() -> None:
    shape = {
        "tag": "Product",
        "value": {
            "fields": [],
            "extras": {"tag": "Allow", "value": {"key_format": None, "value": {"type_id": "value"}}},
        },
    }
    assert ts.shape_references(shape) == ["value"]


def test_wire_list_element_failure_path_carries_the_index() -> None:
    def decode(value: object, path: str) -> str:
        if value != "ok":
            raise WireFailure("Syntax", path, "bad")
        return "ok"

    with pytest.raises(WireFailure) as caught:
        wire_list(["ok", "bad"], "$.items", decode)
    assert caught.value.path == "$.items[1]"


def test_schema_list_element_failure_path_carries_the_index() -> None:
    with pytest.raises(WireFailure) as caught:
        ws.listed(ws.string)(["a", 1], "$.items")
    assert caught.value.path == "$.items[1]"


def test_outcome_rejects_duplicate_produced_resource_ids() -> None:
    outcome = {"value_ports": [], "produced_resources": [{"id": "stock"}, {"id": "stock"}]}
    assert ts.outcomeValid({}, outcome) is False


def _grapheme_bound_rule(maximum: str) -> dict[str, object]:
    return {"tag": "Bounded", "fields": {"unit": {"tag": "Graphemes"}, "maximum": maximum, "rule": {"tag": "Text"}}}


_COMBINING_RULES: dict[str, object] = {
    "properties": [{"first": "769", "last": "769", "property": {"tag": "Extend"}}],
    "extended_pictographic": [],
    "indic_conjunct": [],
}


def test_grapheme_bound_with_rules_counts_a_combining_accent_as_one_grapheme() -> None:
    assert sv.format_accepts(_COMBINING_RULES, _grapheme_bound_rule("1"), "e\u0301") is True
    assert sv.format_accepts_fast(_COMBINING_RULES, _grapheme_bound_rule("1"), "e\u0301") is True


def test_grapheme_bound_without_rules_rejects_every_text() -> None:
    assert sv.format_accepts(None, _grapheme_bound_rule("1"), "a") is False
    assert sv.format_accepts_fast(None, _grapheme_bound_rule("1"), "a") is False


def _inclusion_row(source: TypeRef, destination: TypeRef, children: tuple[tuple[TypeRef, TypeRef], ...]) -> tuple[PairEntry, tuple[tuple[TypeRef, TypeRef], ...]]:
    pair = TypePair(SlotContract(source, True, False), SlotContract(destination, True, False))
    return PairEntry(pair, None, None, cast(Any, None), ()), children


@pytest.mark.parametrize("text", ["0.0", "0e-100", "-0.0", "0.000e-100"])
def test_decode_exact_keeps_the_decimal_text_of_zero(text: str) -> None:
    assert decode_wire_json(text) == sv.DecimalLiteral(text)


@pytest.mark.parametrize("text, expected", [
    ("0.0", sv.DecimalLiteral("0")),
    ("0e-100", sv.DecimalLiteral("0")),
    ("0.000e-100", sv.DecimalLiteral("0")),
    ("-0.0", sv.DecimalLiteral("0")),
    ("0", 0),
    ("0e11", 0),
])
def test_from_json_reads_a_zero_number_by_the_exponent_rule(text: str, expected: object) -> None:
    value = sv.exact_from_json(decode_wire_json(text))
    assert value == expected and type(value) is type(expected)


@pytest.mark.parametrize("text, expected", [
    ("1.5", sv.DecimalLiteral("1.5")),
    ("1.50", sv.DecimalLiteral("1.5")),
    ("1.0", sv.DecimalLiteral("1")),
    ("10", 10),
    ("1e1", 10),
    ("1E1", 10),
    ("1e-5", sv.DecimalLiteral("0.00001")),
    ("10e-1", sv.DecimalLiteral("1")),
    ("1.50e1", sv.DecimalLiteral("15")),
    ("1e3", 1000),
    ("9007199254740993", 9007199254740993),
    ("1e-9999", sv.DecimalLiteral("0.0000000001e-9989")),
    ("1.5e-9999", sv.DecimalLiteral("0.00000000015e-9989")),
])
def test_from_json_follows_the_lean_json_number_normal_form(text: str, expected: object) -> None:
    assert sv.exact_from_json(decode_wire_json(text)) == expected


def test_from_json_reads_an_exponent_below_the_limit_as_the_full_integer() -> None:
    assert sv.exact_from_json(decode_wire_json("1e9999")) == 10 ** 9999
    assert sv.exact_from_json(decode_wire_json("-1e9999")) == -(10 ** 9999)


@pytest.mark.parametrize("text, output", [("1.50", "1.5"), ("1.0", "1.0"), ("1e-5", "0.00001"), ("0e-100", "0.0"), ("0.0", "0.0")])
def test_json_output_number_is_the_lean_number_text(text: str, output: str) -> None:
    assert sv.json_output_number(sv.DecimalLiteral(text)) == sv.RawJsonNumber(output)


def test_exponent_marker_outside_strings_reaches_the_limit() -> None:
    flags = [sv.json_text_exponent_too_large(text) for text in ("1e10000", "1E+10000", "1e-10000", "1e9999", '"e10000"')]
    assert flags == [True, True, True, False, False]


def test_integral_decimal_form_rejects_an_exponent_at_the_limit() -> None:
    form = sv.variant("IntegralDecimal")
    assert sv.integer_value_for_form(form, sv.DecimalLiteral("1e9999")) is not None
    assert sv.integer_value_for_form(form, sv.DecimalLiteral("1e10000")) is None
    assert sv.integer_value_for_form(form, sv.DecimalLiteral("1e1000000000")) is None


def test_unbounded_integral_data_rejects_an_exponent_at_the_limit_as_invalid_data_model() -> None:
    profile = {
        "default_integer_domain": "forms",
        "integer_domains": [{"name": "forms", "forms": [sv.variant("Number"), sv.variant("IntegralDecimal")], "range": sv.variant("Unbounded")}],
        "numbers": {"decimals": True},
    }
    assert sv.data_value_failure(profile, (), sv.DecimalLiteral("1e9999")) is None
    assert sv.data_value_failure(profile, (), sv.DecimalLiteral("1e10000"))[1] == sv.INVALID_DATA_MODEL


def test_decimal_condition_rejects_an_exponent_at_the_limit_as_invalid_data_model() -> None:
    assert sv.decimal_condition({"minimum": None, "maximum": None}, "1e10000") == sv.INVALID_DATA_MODEL


def test_profile_artifact_rejects_an_exponent_at_the_limit_as_a_json_failure() -> None:
    expected = {"content_digest": "digest", "identity": "profile", "revision": "1"}
    with pytest.raises(sv.JsonFailure) as caught:
        ts.decode_profile_artifact(expected, [], '{"x":1e10000}', '{"x":1e10000}')
    assert caught.value.observed == "exponent too large"


def test_encoding_an_exponent_at_the_limit_is_a_json_failure() -> None:
    with pytest.raises(sv.JsonFailure) as caught:
        sv.encode_wire_json(sv.DecimalLiteral("1e10000"))
    assert caught.value.observed == "exponent too large"
    assert sv.encode_wire_json(sv.DecimalLiteral("1e9999")) == "1" + "0" * 9999 + ".0"
