# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

from necoherence.signature_values import ValueContext, variant
from necoherence.type_signatures import checkLibrary
from necoherence_tools.inclusion_samples import checkAssignable, compatible
from v4_samples import library, string_spec


def context(value):
    checked=checkLibrary(value)
    return ValueContext({"profile":checked.value["profile"],"nodes":checked.value["nodes"]})


def test_incompatible_result_carries_a_valid_counterexample():
    value=library(); value["nodes"].append({"id":"constant","shape":variant("String",string_spec(wrapper="text",const_value="only"))})
    values=context(value); result=compatible(values,"text","constant")
    assert result["classification"]=="incompatible"
    values.validate("text",result["counterexample"])


def test_product_rule_accepts_identical_field_contracts():
    values=context(library())
    result=compatible(values,"product","product")
    assert result["classification"]=="compatible"


def test_destination_only_optional_field_with_rejected_extras_is_unknown():
    value=library()
    value["nodes"].extend([
        {"id":"source","shape":variant("Product",{"fields":[{"wire_name":"a","slot":{"type_id":"text","required":True,"nullable":False}}],"extras":variant("Reject")})},
        {"id":"destination","shape":variant("Product",{"fields":[{"wire_name":"a","slot":{"type_id":"text","required":True,"nullable":False}},{"wire_name":"b","slot":{"type_id":"text","required":False,"nullable":False}}],"extras":variant("Reject")})}])
    result=compatible(context(value),"source","destination")
    assert result["classification"]=="unknown"


def test_presence_counterexample_precedes_value_samples():
    values=context(library())
    result=checkAssignable(values,{"type_id":"text","required":False,"nullable":False},{"type_id":"text","required":True,"nullable":False})
    assert result["classification"]=="incompatible"
    assert result["counterexample"]=={"tag":"Absent"}
