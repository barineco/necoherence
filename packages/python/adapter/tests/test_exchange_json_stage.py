# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""The JSON stage of an exchange is one typed failure that is separate from the wire stage."""

import json

import pytest

from necoherence.signature_composition_wire import _decode_slot_value
from necoherence.signature_values import JsonFailure, WireFailure
from necoherence.type_signatures import ExpectedSignatureBasis, Generation, admit_signature_generation, decode_generation
from test_profile_predicate_vectors import invalid_exchange

JSON_STAGE_TEXTS = [
    '{"a":1,"a":2}',
    '{"a":{"b":1,"b":2}}',
    '{"a":[{"b":1,"b":2}]}',
    '{"a":"\\ud800"}',
    '{"\\udc00":1}',
    '{"a":1e10000}',
    '{"a":1E+99999999999}',
    '{"a":1e-10000}',
    '{"a":1E-99999999999}',
    '{"a":',
]


@pytest.mark.parametrize("text", JSON_STAGE_TEXTS)
def test_the_json_stage_failure_is_a_json_failure(text: str) -> None:
    basis, _ = invalid_exchange()
    with pytest.raises(Generation) as caught:
        admit_signature_generation(ExpectedSignatureBasis(basis, None), text)
    assert isinstance(caught.value.cause, JsonFailure)
    with pytest.raises(JsonFailure):
        decode_generation(text)


def test_a_wire_stage_failure_is_not_a_json_failure() -> None:
    basis, exchange = invalid_exchange()
    exchange["extra"] = 1
    with pytest.raises(Generation) as caught:
        admit_signature_generation(ExpectedSignatureBasis(basis, None), json.dumps(exchange))
    assert type(caught.value.cause) is WireFailure
    assert caught.value.cause.kind == "UnknownField"


@pytest.mark.parametrize("text", ['{"a":1e9999}', '{"a":-0}', '{"a":' + "1" * 5000 + "}", '{"a":1e-9999}', '{"a":1e-' + "0" * 5000 + '5}'])
def test_numbers_below_the_exponent_limit_pass_the_json_stage(text: str) -> None:
    basis, _ = invalid_exchange()
    with pytest.raises(Generation) as caught:
        admit_signature_generation(ExpectedSignatureBasis(basis, None), text)
    assert type(caught.value.cause) is WireFailure
    assert caught.value.cause.kind == "UnknownField"


def test_a_supplied_json_value_without_a_tag_is_a_syntax_failure() -> None:
    with pytest.raises(WireFailure) as caught:
        _decode_slot_value({"tag": "Present", "value": {}}, "$")
    assert (caught.value.kind, caught.value.path) == ("Syntax", "$.tag")


def test_a_supplied_json_value_with_a_known_tag_and_an_extra_key_is_an_unknown_field() -> None:
    with pytest.raises(WireFailure) as caught:
        _decode_slot_value({"tag": "Present", "value": {"tag": "Null", "extra": 1}}, "$")
    assert (caught.value.kind, caught.value.path) == ("UnknownField", "$.extra")
