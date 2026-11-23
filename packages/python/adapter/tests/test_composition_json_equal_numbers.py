# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""The composition wire compares numbers as the Lean `sameJson` does, by the text that the Lean `canonicalJson` writes."""

import pytest

from necoherence.composition_wire_base import json_equal
from necoherence.signature_values import decode_wire_json

SAME_NUMBER_SPELLINGS = [
    ("10", "10.0"),
    ("10", "1e1"),
    ("10.0", "1e1"),
    ("1", "1.0e0"),
    ("0", "0.0"),
    ("0", "-0.0"),
    ("100e-2", "1"),
    ("1.5", "1.50"),
]

DIFFERENT_VALUES = [
    ("10", "10.5"),
    ("1", "true"),
    ("0", "null"),
    ("1.5", "1.6"),
]


@pytest.mark.parametrize(("left", "right"), SAME_NUMBER_SPELLINGS)
def test_equal_numbers_in_either_spelling_are_json_equal(left: str, right: str) -> None:
    assert json_equal(decode_wire_json(left), decode_wire_json(right))
    assert json_equal(decode_wire_json(right), decode_wire_json(left))


@pytest.mark.parametrize(("left", "right"), DIFFERENT_VALUES)
def test_different_values_and_kinds_are_not_json_equal(left: str, right: str) -> None:
    assert not json_equal(decode_wire_json(left), decode_wire_json(right))


def test_nested_numbers_are_compared_by_value() -> None:
    assert json_equal(decode_wire_json('{"a":[10.0,{"b":1.50}]}'), decode_wire_json('{"a":[10,{"b":1.5}]}'))
    assert not json_equal(decode_wire_json('{"a":[10.0,{"b":1.50}]}'), decode_wire_json('{"a":[10,{"b":1.6}]}'))
