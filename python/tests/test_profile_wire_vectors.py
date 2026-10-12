# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

import copy
import json

import pytest

from necoherence.signature_values import WireFailure, variant
from necoherence.type_signatures import (
    decode_generation,
    decode_value_condition,
    encode_generation,
    encode_value_condition,
    signature_basis,
)
from test_profile_predicate_vectors import valid_profile
from v4_samples import integer_spec, string_spec


FORMATS = [
    variant("AsciiDfa", {"state_count": "1", "initial_state": "0", "accepting_states": ["0"], "transitions": []}),
    variant("Timestamp", {"allow_second_60": False, "minimum_year": "0", "maximum_year": "9999", "reject_utc_year_outside_range": True}),
    variant("Choice", [variant("Text")]),
    variant("Identifier", fields={"first_alphabet": "a", "rest_alphabet": "a", "exact_length": None, "min_length": "1", "max_length": "2", "forbidden": []}),
    variant("AbsoluteUri", fields={"max_bytes": None}),
    variant("LanguageTag", fields={"grandfathered": []}),
    variant("Literal", "x"),
    variant("Sequence", [variant("Text")]),
    variant("Optional", variant("Text")),
    variant("Labels", fields={"separator": ".", "min_count": "1", "max_count": None, "total_max": None, "rule": variant("Text")}),
    variant("Bounded", fields={"unit": variant("UnicodeScalars"), "maximum": "2", "rule": variant("Text")}),
    variant("Text"),
    variant("Not", variant("Literal", "x")),
]


CONDITIONS = [
    variant("MissingRequired"), variant("NullNotAllowed"), variant("WrongValueKind", "string"),
    variant("ConstMismatch"), variant("EnumMismatch"), variant("BelowMinimum"), variant("AboveMaximum"),
    variant("IntegerDomain"), variant("StringLength"), variant("ArrayLength"), variant("BytesLength"),
    variant("Format", "f"), variant("InvalidBytes"), variant("InvalidWrapper", "text"),
    variant("InvalidTag"), variant("ReservedForm"), variant("NoBranchSelected"),
    variant("KeyFormat", "key"), variant("Uninhabited"), variant("DuplicateField", "key"),
    variant("UnexpectedField", "key"), variant("InvalidDataModel"), variant("ReferenceCycle"),
]


def complete_library():
    profile = valid_profile()
    profile["format_bindings"] = [
        {"name": f"f{index}", "reference": copy.deepcopy(profile["reference"]), "rule": rule}
        for index, rule in enumerate(FORMATS)
    ]
    profile["tag"]["format"] = None
    profile["wrappers"][1]["payload"] = variant("Text", None)
    profile["tag"]["sealed"][0]["fields"] = []
    shapes = [
        variant("Unknown", variant("Any")),
        variant("Unknown", variant("OrdinaryObject")),
        variant("Unit"),
        variant("Boolean", {"const_value": None, "default_value": None}),
        variant("Integer", integer_spec(domain="integer")),
        variant("Decimal", {"minimum": None, "maximum": None}),
        variant("String", string_spec()),
        variant("Bytes", {"minimum": None, "maximum": None}),
        variant("Product", {"fields": [], "extras": variant("Reject")}),
        variant("Array", {"item": {"type_id": "unit", "nullable": False}, "min_length": None, "max_length": None}),
        variant("TaggedUnion", {"branches": [{"target": "unit", "wire_tag": "unit", "selector": variant("Kind", variant("Null"))}]}),
        variant("Sealed", fields={"tag": "sealed", "refinements": []}),
        variant("Never"),
        variant("Alias", fields={"target": "unit"}),
        variant("RawBody", fields={"encoding": "raw"}),
        variant("Opaque", fields={"type_name": "opaque"}),
    ]
    names = ["unknown", "ordinary", "unit", "boolean", "integer", "decimal", "string", "bytes",
             "product", "array", "union", "sealed", "never", "alias", "raw-body", "opaque"]
    return {
        "schema": "ncoh-type-signatures@1", "identity": "wire", "revision": "4", "profile": profile,
        "sources": [], "provenance": [], "groups": [], "annotations": [],
        "nodes": [{"id": name, "shape": shape} for name, shape in zip(names, shapes)],
        "definitions": [{"id": "entry", "wire_identity": "entry", "shape": variant("Value", "unit")}],
    }


def exchange():
    library = complete_library()
    entries = [{"identity": "entry", "definition": "entry"}]
    basis = signature_basis(library, entries)
    return {"schema": "ncoh-checked-generation@4", "basis": basis, "signatures": library,
            "composition": None, "entrypoints": entries}


def test_all_format_and_shape_rows_roundtrip_in_the_canonical_document():
    value = exchange()
    encoded = encode_generation(value)
    assert decode_generation(encoded) == value
    assert json.loads(encode_generation(decode_generation(encoded))) == json.loads(encoded)


@pytest.mark.parametrize("condition", CONDITIONS)
def test_all_value_condition_rows_roundtrip(condition):
    encoded = encode_value_condition(condition)
    assert decode_value_condition(encoded) == condition
    assert json.loads(encode_value_condition(decode_value_condition(encoded))) == json.loads(encoded)


def test_old_profile_key_and_format_tag_are_rejected():
    value = exchange()
    value["signatures"]["profile"]["representation"] = None
    with pytest.raises(WireFailure) as caught:
        decode_generation(value)
    assert caught.value.kind == "UnknownField"

    value = exchange()
    value["signatures"]["profile"]["format_bindings"][0]["rule"] = variant("Cid")
    with pytest.raises(WireFailure) as caught:
        decode_generation(value)
    assert caught.value.kind == "UnknownTag"
