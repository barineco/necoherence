# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

import pytest

from necoherence.signature_values import ValueContext, variant
from necoherence.type_signatures import checkLibrary
from necoherence_tools.inclusion_samples import sample_values, slotSamples
from v4_samples import library, string_spec


def context_with(shape):
    value=library(); value["nodes"].append({"id":"bounded","shape":shape})
    checked=checkLibrary(value)
    return ValueContext({"profile":checked.value["profile"],"nodes":checked.value["nodes"]})


def test_samples_are_accepted_by_their_source():
    checked=checkLibrary(library()); context=ValueContext({"profile":checked.value["profile"],"nodes":checked.value["nodes"]})
    result=sample_values(context,8,(),"text")
    assert result.possible
    for value in result.values: context.validate("text",value)


@pytest.mark.parametrize("bounds,expected",[
    ([{"unit":variant("Utf8Bytes"),"minimum":"3","maximum":None}],"aaa"),
    ([{"unit":variant("UnicodeScalars"),"minimum":"4","maximum":None}],"aaaa"),
    ([{"unit":variant("Utf8Bytes"),"minimum":"9","maximum":None},{"unit":variant("UnicodeScalars"),"minimum":"10","maximum":None}],"aaaaaaaaaa"),
    ([{"unit":variant("Utf8Bytes"),"minimum":"10","maximum":None},{"unit":variant("UnicodeScalars"),"minimum":"9","maximum":None}],"aaaaaaaaaa")])
def test_string_length_samples_include_each_declared_lower_bound(bounds,expected):
    context=context_with(variant("String",string_spec(lengths=bounds)))
    assert expected in sample_values(context,8,(),"bounded").values


def test_slot_samples_include_absent_null_and_present_in_contract_order():
    context=context_with(variant("String",string_spec()))
    result=slotSamples(context,{"type_id":"bounded","required":False,"nullable":True})
    assert result.values[0]=={"tag":"Absent"}
    assert result.values[1]=={"tag":"Null"}
    assert result.values[2]["tag"]=="Present"


def test_sample_bound_is_an_obligation():
    context=context_with(variant("String",string_spec(examples=["long"])))
    result=sample_values(context,8,(),"bounded",2)
    assert result.obligations==("sampleBound",)
