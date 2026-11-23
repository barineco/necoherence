# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

import json
from pathlib import Path

import pytest

from necoherence.signature_values import ValueContext, ValueFailure, grapheme_length, length_in_unit, variant
from v4_samples import profile, string_spec
from necoherence.type_signatures import _graph


def context(rules):
    value=profile(); value["grapheme_rules"]=rules
    return ValueContext(_graph({"profile": value, "nodes": [{"id":"unit","shape":variant("Unit")}], "definitions": []}))


def test_missing_grapheme_rules_have_no_grapheme_length():
    assert length_in_unit(profile(), variant("Graphemes"), "abc") is None


def test_some_grapheme_rules_preserve_combining_cluster():
    rules={"properties":[{"first":"768","last":"879","property":variant("Extend")}],"extended_pictographic":[],"indic_conjunct":[]}
    assert grapheme_length(rules, "") == 0
    assert grapheme_length(rules, "a\u0301b")==2


SYNTHETIC_PROFILE = Path(__file__).parents[3] / "typescript/adapter/tests/synthetic-profile.json"
BREAK_VECTORS = Path(__file__).parents[4] / "verification/declaration/semantic_profile_data/GraphemeBreakTest.txt"


def official_vectors():
    for line in BREAK_VECTORS.read_text().splitlines():
        body = line.split("#")[0].strip()
        if not body:
            continue
        characters, expected = [], []
        for token in body.split():
            if token == "\u00f7":
                expected.append(len(characters))
            elif token != "\u00d7":
                characters.append(chr(int(token, 16)))
        yield "".join(characters), tuple(expected)


def test_official_grapheme_break_vectors_match_lean_boundaries():
    rules = json.loads(SYNTHETIC_PROFILE.read_text())["grapheme_rules"]
    assert rules["component"]["unicode_version"] == "16.0.0" and rules["component"]["uax29_revision"] == "45"
    count = 0
    for text, expected in official_vectors():
        assert grapheme_length(rules, text) == len(expected) - 1
        count += 1
    assert count == 1093


def test_utf8_and_scalar_bounds_are_independent():
    shape=variant("String",string_spec(lengths=[{"unit":variant("Utf8Bytes"),"minimum":None,"maximum":"2"},{"unit":variant("UnicodeScalars"),"minimum":"1","maximum":"1"}]))
    values=ValueContext(_graph({"profile": profile(), "nodes": [{"id":"value","shape":shape}], "definitions": []}))
    values.validate("value","é")
    with pytest.raises(ValueFailure): values.validate("value","éé")
