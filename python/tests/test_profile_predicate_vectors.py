# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

import copy
import json

import pytest
from necoherence.signature_values import DecimalLiteral, MeaningFailure, ValueContext, variant
from necoherence.type_signatures import (
    AdmissionFailure,
    DeclarationFailure,
    ExpectedSignatureBasis,
    admit_signature_generation,
    checkLibrary,
    checkProfile,
    decode_generation,
    decode_profile_artifact,
    signature_basis,
)
from v4_samples import REFERENCE, integer_spec, string_spec


def valid_profile():
    reference = copy.deepcopy(REFERENCE)
    identifier = variant("Identifier", fields={
        "first_alphabet": "ab", "rest_alphabet": "ab", "exact_length": None,
        "min_length": "1", "max_length": "4", "forbidden": [],
    })
    return {
        "reference": reference,
        "source_refs": [],
        "integer_domains": [{
            "name": "integer", "reference": copy.deepcopy(reference),
            "range": variant("Inclusive", fields={"minimum": "-1", "maximum": "1"}),
            "forms": [variant("Number"), variant("IntegralDecimal"), variant("DecimalString")],
        }],
        "default_integer_domain": "integer",
        "numbers": {"decimals": True},
        "grapheme_rules": {
            "reference": copy.deepcopy(reference),
            "properties": [{"first": "0", "last": "1", "property": variant("Other")}],
            "extended_pictographic": [{"first": "2", "last": "3"}],
            "indic_conjunct": [{"first": "4", "last": "5", "property": variant("Other")}],
        },
        "format_bindings": [
            {"name": "identifier", "reference": copy.deepcopy(reference), "rule": identifier},
            {"name": "tag-format", "reference": copy.deepcopy(reference),
             "rule": variant("Choice", [variant("Literal", "sealed"), variant("Literal", "other")])},
            {"name": "only-ok", "reference": copy.deepcopy(reference), "rule": variant("Literal", "ok")},
        ],
        "bytes_policy": {
            "reference": copy.deepcopy(reference), "padding_optional": True,
            "alphabet": variant("Either"), "strict_pad_bits": True, "wrapper": "bytes-wrapper",
        },
        "wrappers": [
            {"name": "bytes-wrapper", "key": "bytes", "payload": variant("Bytes")},
            {"name": "text-wrapper", "key": "text", "payload": variant("Text", "identifier")},
        ],
        "tag": {
            "key": "tag", "format": "tag-format",
            "sealed": [{
                "tag": "sealed",
                "fields": [
                    {"key": "name", "required": True,
                     "leaf": variant("String", string_spec(format=variant("Named", "identifier"), wrapper="text-wrapper"))},
                    {"key": "count", "required": False,
                     "leaf": variant("Integer", integer_spec(domain="integer"))},
                ],
                "extras": variant("Reject"),
            }],
        },
    }


def node(identity, shape):
    return {"id": identity, "shape": shape}


def unit_node():
    return node("unit", variant("Unit"))


def field(name, target="unit", required=True, nullable=False):
    return {"wire_name": name, "slot": {"type_id": target, "required": required, "nullable": nullable}}


def product(identity, fields=(), extras=None):
    return node(identity, variant("Product", {"fields": list(fields), "extras": extras or variant("Reject")}))


def branch(target, wire_tag, selector):
    return {"target": target, "wire_tag": wire_tag, "selector": selector}


def union(branches):
    return node("union", variant("TaggedUnion", {"branches": branches}))


def library_with(nodes, profile=None):
    return {
        "schema": "ncoh-type-signatures@1", "identity": "library", "revision": "4",
        "profile": copy.deepcopy(profile or valid_profile()), "sources": [], "provenance": [],
        "groups": [], "annotations": [], "nodes": list(nodes),
        "definitions": [{"id": "entry", "wire_identity": "entry", "shape": variant("Value", "unit")}],
    }


def changed_profile(change):
    value = valid_profile()
    change(value)
    return value


PROFILE_CASES = [
    ("PR01", lambda p: p["reference"].update(identity="")),
    ("PR02", lambda p: p["integer_domains"].append(copy.deepcopy(p["integer_domains"][0]))),
    ("PR03", lambda p: p["integer_domains"][0].update(range=variant("Inclusive", fields={"minimum": "2", "maximum": "1"}))),
    ("PR04", lambda p: p["integer_domains"][0].update(forms=[])),
    ("PR05", lambda p: p.update(default_integer_domain="missing")),
    ("PR06", lambda p: p["format_bindings"].append(copy.deepcopy(p["format_bindings"][0]))),
    ("PR07", lambda p: p["format_bindings"][0].update(rule=variant("Identifier", fields={"first_alphabet": "", "rest_alphabet": "ab", "exact_length": None, "min_length": "1", "max_length": "4", "forbidden": []}))),
    ("PR08", lambda p: p["wrappers"][1].update(key="bytes")),
    ("PR09", lambda p: p["wrappers"][1].update(payload=variant("Text", "missing"))),
    ("PR10", lambda p: p["bytes_policy"].update(wrapper="text-wrapper")),
    ("PR11", lambda p: p["tag"].update(key="text")),
    ("PR12", lambda p: p["tag"].update(format="missing")),
    ("PR13", lambda p: p["tag"]["sealed"].append(copy.deepcopy(p["tag"]["sealed"][0]))),
    ("PR14", lambda p: p["tag"]["sealed"][0]["fields"].append(copy.deepcopy(p["tag"]["sealed"][0]["fields"][0]))),
    ("PR15", lambda p: p["tag"]["sealed"][0]["fields"][1].update(leaf=variant("Integer", integer_spec(domain="missing")))),
    ("PR16", lambda p: p["grapheme_rules"].update(properties=[{"first": "2", "last": "1", "property": variant("Other")}]))
]


@pytest.mark.parametrize("predicate,change", PROFILE_CASES, ids=[case[0] for case in PROFILE_CASES])
def test_profile_predicates_match_lean_representatives(predicate, change):
    with pytest.raises(DeclarationFailure) as caught:
        checkProfile(changed_profile(change))
    assert caught.value.predicate == predicate


MEANING_CASES = [
    ("MO01", lambda p: None, variant("String", string_spec(format=variant("Named", "missing"))), "x"),
    ("MO02", lambda p: p.update(grapheme_rules=None), variant("String", string_spec(lengths=[{"unit": variant("Graphemes"), "minimum": "1", "maximum": None}])), "x"),
    ("MO03", lambda p: p.update(bytes_policy=None), variant("Bytes", {"minimum": None, "maximum": None}), {"bytes": ""}),
    ("MO04", lambda p: None, variant("Integer", integer_spec(domain="missing")), 0),
    ("MO05", lambda p: None, variant("String", string_spec(wrapper="missing")), "x"),
    ("MO06", lambda p: None, variant("String", string_spec(wrapper="bytes-wrapper")), "x"),
    ("MO07", lambda p: None, variant("Sealed", fields={"tag": "missing", "refinements": []}), {}),
    ("MO08", lambda p: p["numbers"].update(decimals=False), variant("Decimal", {"minimum": None, "maximum": None}), DecimalLiteral("0")),
    ("MO09", lambda p: None, variant("Integer", integer_spec(domain="integer", minimum="-2")), -2),
    ("MO10", lambda p: None, variant("Opaque", fields={"type_name": "external"}), None),
    ("MO11", lambda p: p.update(tag=None), variant("TaggedUnion", {"branches": [branch("subject", "other", variant("InternalTag"))]}), {}),
]


@pytest.mark.parametrize("predicate,profile_change,shape,value", MEANING_CASES, ids=[case[0] for case in MEANING_CASES])
def test_meaning_predicates_match_lean_representatives(predicate, profile_change, shape, value):
    profile = valid_profile()
    profile_change(profile)
    context = ValueContext.from_signature_nodes(profile, [node("subject", shape)])
    with pytest.raises(MeaningFailure) as caught:
        context.validate("subject", value)
    assert caught.value.predicate == predicate


def library_cases():
    allow_missing = variant("Allow", fields={"key_format": variant("Named", "missing"), "value": {"type_id": "unit", "nullable": False}})
    decimal = lambda lo, hi: variant("Decimal", {"minimum": lo, "maximum": hi})
    bound = lambda value: {"mantissa": str(value), "scale": "0", "exclusive": False}
    return [
        ("LB01", library_with([unit_node(), node("alias", variant("Alias", fields={"target": "missing"}))])),
        ("LB02", library_with([unit_node(), product("product", [field("value"), field("value")])])),
        ("LB03", library_with([unit_node(), product("product", [field("text")])])),
        ("LB04", library_with([unit_node(), union([branch("unit", "same", variant("Kind", variant("Null"))), branch("unit", "same", variant("Kind", variant("Boolean")))])])),
        ("LB05", library_with([unit_node(), union([branch("unit", "fallback", variant("Otherwise")), branch("unit", "null", variant("Kind", variant("Null")))])])),
        ("LB06", library_with([unit_node(), union([branch("unit", "", variant("Kind", variant("Null")))])])),
        ("LB07", library_with([unit_node(), product("target"), union([branch("target", "outside", variant("InternalTag"))])])),
        ("LB08", library_with([unit_node(), product("target"), union([branch("target", "sealed", variant("InternalTag"))])])),
        ("LB09", library_with([unit_node(), union([branch("unit", "member", variant("MemberShape", [{"key": "key", "test": variant("Format", "missing")}]))])])),
        ("LB10", library_with([unit_node(), node("sealed-node", variant("Sealed", fields={"tag": "sealed", "refinements": [{"key": "missing", "leaf": variant("String", string_spec())}]}))])),
        ("LB11", library_with([unit_node(), union([branch("unit", "other", variant("InternalTag"))])])),
        ("LB12", library_with([unit_node(), product("product", extras=allow_missing)])),
        ("LB13", library_with([unit_node(), node("string", variant("String", string_spec(wrapper="missing")))])),
        ("LB14", library_with([unit_node(), node("integer", variant("Integer", integer_spec(minimum="2", maximum="1")))])),
        ("LB15", library_with([unit_node(), node("decimal", decimal(bound(2), bound(1)))])),
        ("LB16", library_with([unit_node(), node("array", variant("Array", {"item": {"type_id": "unit", "nullable": False}, "min_length": "2", "max_length": "1"}))])),
        ("LB17", library_with([unit_node(), node("tag-value", variant("String", string_spec(const_value="different"))), product("target", [field("tag", "tag-value")]), union([branch("target", "other", variant("InternalTag"))])])),
        ("LB18", library_with([unit_node(), union([branch("unit", "first", variant("Kind", variant("Null"))), branch("unit", "second", variant("Kind", variant("Null")))])])),
        ("LB19", library_with([unit_node(), node("string", variant("String", string_spec(format=variant("Named", "only-ok"), const_value="bad")))])),
    ]


@pytest.mark.parametrize("predicate,value", library_cases(), ids=[case[0] for case in library_cases()])
def test_library_predicates_match_lean_representatives(predicate, value):
    with pytest.raises(DeclarationFailure) as caught:
        checkLibrary(value)
    assert caught.value.predicate == predicate


def test_internal_tag_selection_identity_preserves_other_selector_duplicates():
    profile = valid_profile()
    profile["tag"] = {"key": "$type", "format": None, "sealed": []}
    base = [unit_node(), node("tag-value", variant("String", string_spec())),
            product("a", [field("$type", "tag-value")]),
            product("b", [field("$type", "tag-value")])]
    branches = [branch("a", "com.example.a", variant("InternalTag")),
                branch("b", "com.example.b", variant("InternalTag"))]
    subject = library_with([*base, union(branches)], profile)
    checkLibrary(subject)
    context = ValueContext.from_signature_nodes(profile, subject["nodes"])
    for tag in ("com.example.a", "com.example.b"):
        context.validate("union", {"$type": tag})
    for selector in (variant("Kind", variant("Null")),
                     variant("MemberShape", [{"key": "key", "test": variant("Absent")}])):
        duplicate = library_with([*base, union([{**item, "selector": selector} for item in branches])], profile)
        with pytest.raises(DeclarationFailure) as caught:
            checkLibrary(duplicate)
        assert caught.value.predicate == "LB18"


def invalid_profile_library():
    profile = changed_profile(lambda p: p["reference"].update(identity=""))
    return library_with([unit_node()], profile)


def invalid_exchange():
    value = invalid_profile_library()
    entries = [{"identity": "entry", "definition": "entry"}]
    basis = signature_basis(value, entries)
    return basis, {"schema": "ncoh-checked-generation@4", "basis": basis, "signatures": value,
                   "composition": None, "entrypoints": entries}


def test_pr01_is_observed_at_json_wire_and_admission_entrances():
    profile = valid_profile()
    profile["reference"]["identity"] = ""
    with pytest.raises(DeclarationFailure, match="PR01"):
        decode_profile_artifact(profile["reference"], [], json.dumps(profile), json.dumps(profile))
    basis, exchange = invalid_exchange()
    with pytest.raises(DeclarationFailure, match="PR01"):
        decode_generation(exchange)
    with pytest.raises(AdmissionFailure) as caught:
        admit_signature_generation(ExpectedSignatureBasis(basis), exchange)
    assert isinstance(caught.value.cause, DeclarationFailure)
    assert caught.value.cause.predicate == "PR01"
