# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

import pytest

from necoherence.signature_values import ValueContext, ValueFailure, variant
from v4_samples import profile, string_spec


def context(rules):
    value=profile(); value["grapheme_rules"]=rules
    return ValueContext({"profile":value,"nodes":[{"id":"unit","shape":variant("Unit")}]})


def test_none_grapheme_rules_preserve_scalar_fallback_observation():
    values=context(None)
    assert values.grapheme_boundaries("")== ()
    assert values.grapheme_count("abc")==3


def test_some_grapheme_rules_preserve_combining_cluster():
    rules={"properties":[{"first":"768","last":"879","property":variant("Extend")}],"extended_pictographic":[],"indic_conjunct":[]}
    values=context(rules)
    assert values.grapheme_boundaries("a\u0301b")== (0,2,3)
    assert values.grapheme_count("a\u0301b")==2


def test_utf8_and_scalar_bounds_are_independent():
    shape=variant("String",string_spec(lengths=[{"unit":variant("Utf8Bytes"),"minimum":None,"maximum":"2"},{"unit":variant("UnicodeScalars"),"minimum":"1","maximum":"1"}]))
    values=ValueContext({"profile":profile(),"nodes":[{"id":"value","shape":shape}]})
    values.validate("value","é")
    with pytest.raises(ValueFailure): values.validate("value","éé")
