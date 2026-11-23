# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""The exponent of a JSON number is judged by its value, with the same limit for both signs, as the Lean `SignatureJson.parse`."""

import pytest

from necoherence.declaration_wire import exact_json
from necoherence.signature_values import DecimalLiteral, JsonFailure, WireFailure, decode_wire_json, encode_wire_json, exact_from_json
from necoherence import type_signatures as ts

ZEROS = "0" * 5000

REJECTED = [
    "1e-10000",
    "1E-10000",
    "1e+10000",
    "1e-4294967296",
    "1e99999999999999999999",
    "1e-99999999999999999999",
    "-0.5e-99999999999999999999",
    "1.5E-18446744073709551616",
    "0e-" + "9" * 32,
    "[1e-99999999999999999999]",
    '{"k":1e-99999999999999999999}',
    "1e-" + ZEROS + "10000",
    "1e" + ZEROS + "10000",
    '{"a":1e-10000,',
    "[1e-99999999999999999999,]",
]

ACCEPTED = [
    "1e-9999",
    "1e-42",
    "1e-" + ZEROS + "5",
    "1e+" + ZEROS + "5",
    "1e-" + ZEROS + "9999",
    "1e" + ZEROS + "9999",
]


@pytest.mark.parametrize("text", REJECTED)
def test_an_exponent_of_ten_thousand_or_more_in_either_sign_is_the_exponent_failure(text: str) -> None:
    with pytest.raises(JsonFailure) as caught:
        decode_wire_json(text)
    assert (caught.value.kind, caught.value.path, caught.value.observed) == ("Syntax", "$", "exponent too large")


@pytest.mark.parametrize("text", ACCEPTED)
def test_an_exponent_below_ten_thousand_by_value_is_accepted_with_any_leading_zeros(text: str) -> None:
    assert isinstance(decode_wire_json(text), DecimalLiteral)


@pytest.mark.parametrize("text", ["1e-10000", "1e99999999999999999999", "1e-99999999999999999999", "1e-" + ZEROS + "10000"])
def test_an_exact_decimal_text_with_an_exponent_at_the_limit_is_a_syntax_failure(text: str) -> None:
    with pytest.raises(WireFailure) as caught:
        exact_json({"tag": "Decimal", "text": text}, "$")
    assert (caught.value.kind, caught.value.path) == ("Syntax", "$.text")


@pytest.mark.parametrize("text", ["1e-9999", "1e-" + ZEROS + "5", "1e+" + ZEROS + "5"])
def test_an_exact_decimal_text_with_an_exponent_below_the_limit_is_accepted(text: str) -> None:
    exact_json({"tag": "Decimal", "text": text}, "$")


def test_the_canonical_number_reads_a_long_exponent_by_value() -> None:
    assert ts._canonical_number("1e-" + ZEROS + "1") == "0.1"
    assert ts._canonical_number("1e+" + ZEROS + "1") == "10"
    assert ts._canonical_number("1e-" + "0" * 4300 + "1") == "0.1"
    assert ts._canonical_number("1e-" + "0" * 4290 + "1") == "0.1"


def test_a_zero_decimal_is_encoded_as_zero_point_zero_when_its_exponent_is_below_the_limit() -> None:
    assert encode_wire_json(DecimalLiteral("0.0e+" + ZEROS + "5")) == "0.0"


@pytest.mark.parametrize("text, output", [
    ("0.0", "0.0"), ("-0.0", "0.0"), ("0e-100", "0.0"), ("10.0", "10.0"), ("-7.0", "-7.0"), ("1.0", "1.0"),
    ("1.50e1", "15.0"), ("100e-2", "1.0"), ("1.50", "1.5"), ("1e2", "100.0"), ("1.0e1", "10.0"), ("2.5e3", "2500.0"),
    ("100.00", "100.0"), ("1e-2", "0.01"), ("1e-10", "0.0000000001"), ("1e-20", "0.0000000001e-10"),
    ("1.5e-20", "0.00000000015e-10"), ("-1.25e-12", "-0.000000000125e-2"), ("12345678901e-9", "12.345678901"),
])
def test_decimal_writer_follows_the_lean_number_text(text: str, output: str) -> None:
    assert encode_wire_json(DecimalLiteral(text)) == output


@pytest.mark.parametrize("text, output", [("0.0", "0.0"), ("10.0", "10.0"), ("1.50e1", "15.0"), ("1e2", "100"), ("1.0e1", "10"), ("0e11", "0"), ("-0.00e5", "0")])
def test_wire_number_is_written_through_fromjson(text: str, output: str) -> None:
    assert encode_wire_json(exact_from_json(decode_wire_json(text))) == output


@pytest.mark.parametrize("text", ["0e-99999999999999999999", "0.5e-99999999999999999999"])
def test_a_decimal_whose_exponent_reaches_the_limit_is_not_encoded_whatever_its_mantissa(text: str) -> None:
    with pytest.raises(JsonFailure) as caught:
        encode_wire_json(DecimalLiteral(text))
    assert caught.value.observed == "exponent too large"
