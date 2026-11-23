# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

import copy
import json

import pytest
from necoherence.signature_values import DecimalLiteral, MeaningFailure, ValueContext, ValueFailure, decode_wire_json, exact_from_json, variant, wrong_value_kind
from necoherence.type_signatures import (
    AdmissionFailure,
    DeclarationFailure,
    ExpectedSignatureBasis,
    admit_signature_generation,
    checkLibrary,
    checkProfile,
    decode_generation,
    decode_library,
    decode_profile,
    decode_profile_artifact,
    signature_basis,
)
from v4_samples import REFERENCE, integer_spec, string_spec
from necoherence.type_signatures import _graph, _signature_ref


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
            "component": {"unicode_version": "16.0.0", "uax29_revision": "45", "cluster_profile": "C1-1-default-extended-grapheme-cluster-no-tailoring"},
            "table_sha256": "0" * 64,
            "sources": [],
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
    ("MO02", lambda p: p.update(grapheme_rules=None), variant("String", string_spec(format=variant("Inline", variant("Bounded", fields={"unit": variant("Graphemes"), "maximum": "1", "rule": variant("Text")})))), "x"),
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
    context = ValueContext(_graph({"profile": profile, "nodes": [node("subject", shape)], "definitions": []}))
    with pytest.raises(MeaningFailure) as caught:
        context.check_meaning("subject")
    assert caught.value.predicate == predicate
    assert caught.value.type_ref["definition_name"] == "subject"
    assert caught.value.location == ()


def test_unit_node_has_no_meaning_obligation():
    context = ValueContext(_graph({"profile": valid_profile(), "nodes": [node("subject", variant("Unit"))], "definitions": []}))
    assert context.check_meaning("subject") is None


def test_unresolved_type_is_meaning_obligation_mo12():
    context = ValueContext(_graph({"profile": valid_profile(), "nodes": [], "definitions": []}))
    with pytest.raises(MeaningFailure) as caught:
        context.check_meaning(_signature_ref("missing"))
    assert (caught.value.predicate, caught.value.type_ref["definition_name"], caught.value.location) == ("MO12", "missing", ())


def decimal_subject_context():
    return ValueContext(_graph({"profile": valid_profile(), "nodes": [node("subject", variant("Decimal", {"minimum": None, "maximum": None}))], "definitions": []}))


@pytest.mark.parametrize("text", ["0.0", "0e-100"])
def test_decode_exact_zero_text_is_accepted_by_a_decimal_field(text):
    assert decimal_subject_context().validate("subject", decode_wire_json(text)) == DecimalLiteral(text)


@pytest.mark.parametrize("text", ["0.0", "0e-100"])
def test_from_json_zero_with_a_fraction_or_exponent_is_the_decimal_zero(text):
    assert decimal_subject_context().validate("subject", exact_from_json(decode_wire_json(text))) == DecimalLiteral("0")


@pytest.mark.parametrize("text", ["0", "0e11"])
def test_from_json_zero_with_exponent_zero_is_an_integer_rejected_by_a_decimal_field(text):
    with pytest.raises(ValueFailure) as caught:
        decimal_subject_context().validate("subject", exact_from_json(decode_wire_json(text)))
    assert caught.value.condition == wrong_value_kind("decimal")


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
    context = ValueContext(_graph({"profile": profile, "nodes": subject["nodes"], "definitions": []}))
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
    return basis, {"schema": "ncoh-checked-generation@5", "basis": basis, "signatures": value,
                   "composition": None, "entrypoints": entries}


def test_pr01_is_observed_at_the_artifact_and_admission_entrances():
    profile = valid_profile()
    profile["reference"]["identity"] = ""
    with pytest.raises(DeclarationFailure, match="PR01"):
        decode_profile_artifact(profile["reference"], [], json.dumps(profile), json.dumps(profile))
    basis, exchange = invalid_exchange()
    assert decode_generation(exchange)["signatures"] == exchange["signatures"]
    with pytest.raises(AdmissionFailure) as caught:
        admit_signature_generation(ExpectedSignatureBasis(basis, None), exchange)
    assert isinstance(caught.value.cause, DeclarationFailure)
    assert caught.value.cause.predicate == "PR01"


def format_binding_rule(profile, rule):
    profile["format_bindings"][0]["rule"] = rule


def timestamp(minimum, maximum):
    return variant("Timestamp", {"allow_second_60": False, "minimum_year": minimum, "maximum_year": maximum, "rejectUtcYearOutsideRange": False})


def dfa(transitions, state_count="2"):
    return variant("AsciiDfa", {"state_count": state_count, "initial_state": "0", "accepting_states": ["1"], "transitions": transitions})


def transition(from_state="0", first="97", last="97", to_state="1"):
    return {"from_state": from_state, "first": first, "last": last, "to_state": to_state}


def identifier(first="ab", rest="ab", forbidden=()):
    return variant("Identifier", fields={
        "first_alphabet": first, "rest_alphabet": rest, "exact_length": None,
        "min_length": "1", "max_length": "4", "forbidden": list(forbidden),
    })


MALFORMED_FORMAT_RULES = [
    ("timestamp-year-order", timestamp("2000", "1999")),
    ("timestamp-year-over-9999", timestamp("2000", "10000")),
    ("dfa-from-state-out-of-range", dfa([transition(from_state="2")])),
    ("dfa-to-state-out-of-range", dfa([transition(to_state="2")])),
    ("dfa-range-reversed", dfa([transition(first="98", last="97")])),
    ("dfa-range-beyond-ascii", dfa([transition(first="97", last="128")])),
    ("dfa-overlap-same-state", dfa([transition(first="97", last="99"), transition(first="99", last="100", to_state="0")])),
    ("identifier-first-non-ascii", identifier(first="a\u00e9")),
    ("identifier-rest-non-ascii", identifier(rest="a\u00e9")),
    ("sequence-nested-timestamp", variant("Sequence", [variant("Literal", "x"), timestamp("2000", "1999")])),
    ("choice-nested-identifier", variant("Choice", [identifier(first="")])),
    ("not-nested-timestamp", variant("Not", timestamp("2000", "1999"))),
    ("labels-nested-timestamp", variant("Labels", fields={"separator": ".", "min_count": "1", "max_count": None, "total_max": None, "rule": timestamp("2000", "1999")})),
]


@pytest.mark.parametrize("name,rule", MALFORMED_FORMAT_RULES, ids=[case[0] for case in MALFORMED_FORMAT_RULES])
def test_pr07_rejects_malformed_format_rules_at_every_depth(name, rule):
    profile = valid_profile()
    format_binding_rule(profile, rule)
    with pytest.raises(DeclarationFailure) as caught:
        checkProfile(profile)
    assert caught.value.predicate == "PR07"


@pytest.mark.parametrize("name,rule", MALFORMED_FORMAT_RULES, ids=[case[0] for case in MALFORMED_FORMAT_RULES])
def test_pr15_and_lb13_reject_malformed_inline_format_rules(name, rule):
    profile = valid_profile()
    leaf = variant("String", string_spec(format=variant("Inline", rule)))
    profile["tag"]["sealed"][0]["fields"][0]["leaf"] = leaf
    with pytest.raises(DeclarationFailure) as caught:
        checkProfile(profile)
    assert caught.value.predicate == "PR15"
    value = library_with([unit_node(), node("string", variant("String", string_spec(format=variant("Inline", rule))))])
    with pytest.raises(DeclarationFailure) as caught:
        checkLibrary(value)
    assert caught.value.predicate == "LB13"


def test_pr01_rejects_an_incomplete_grapheme_rules_reference():
    profile = valid_profile()
    profile["grapheme_rules"]["reference"]["content_digest"] = ""
    with pytest.raises(DeclarationFailure) as caught:
        checkProfile(profile)
    assert caught.value.predicate == "PR01"


def test_pr14_in_a_later_sealed_form_precedes_pr15_in_an_earlier_form():
    profile = valid_profile()
    first = profile["tag"]["sealed"][0]
    first["fields"][1]["leaf"] = variant("Integer", integer_spec(domain="missing"))
    second = copy.deepcopy(first)
    second["tag"] = "other"
    second["fields"].append(copy.deepcopy(second["fields"][0]))
    profile["tag"]["sealed"].append(second)
    with pytest.raises(DeclarationFailure) as caught:
        checkProfile(profile)
    assert caught.value.predicate == "PR14"


def operation_definition(outcomes):
    contract = {"effect": variant("DataOnly"), "inputs": [], "outcomes": outcomes}
    return {"id": "operation", "wire_identity": "operation", "shape": variant("Operation", contract)}


def outcome(identifier="ok", source=None):
    origin = {"source": source or SOURCE, "locator": []}
    return {"id": identifier, "form": variant("Success"), "cause": variant("ValueContract", fields={"origin": origin}),
            "value_ports": [], "produced_resources": []}


SOURCE = {"repository": "r", "revision": "1", "path": "p", "content_digest": "0" * 64}


def with_sources(value):
    value["sources"] = [copy.deepcopy(SOURCE)]
    return value


def lb01_cases():
    return [
        ("profile-digest-short", lambda v: v["profile"]["reference"].update(content_digest="0" * 63)),
        ("profile-digest-uppercase", lambda v: v["profile"]["reference"].update(content_digest="A" * 64)),
        ("profile-digest-non-hex", lambda v: v["profile"]["reference"].update(content_digest="g" * 64)),
        ("source-digest-non-hex", lambda v: v["sources"][0].update(content_digest="g" * 64)),
        ("source-duplicate", lambda v: v["sources"].append(copy.deepcopy(v["sources"][0]))),
        ("group-id-duplicate", lambda v: v["groups"].extend([{"id": "g", "members": []}, {"id": "g", "members": []}])),
        ("group-member-undefined", lambda v: v["groups"].append({"id": "g", "members": ["missing"]})),
        ("operation-outcomes-empty", lambda v: v["definitions"].append(operation_definition([]))),
        ("operation-outcome-id-duplicate", lambda v: v["definitions"].append(operation_definition([outcome(), outcome()]))),
        ("operation-outcome-origin-unknown", lambda v: v["definitions"].append(operation_definition([outcome(source={**SOURCE, "path": "other"})]))),
        ("provenance-group-undefined", lambda v: v["provenance"].append({"target": variant("Group", "missing"), "origins": []})),
        ("provenance-origin-unknown", lambda v: v["provenance"].append({"target": variant("Library"), "origins": [{"source": {**SOURCE, "path": "other"}, "locator": []}]})),
        ("annotation-type-undefined", lambda v: v["annotations"].append({"target": variant("Type", "missing"), "key": "k", "value": variant("Null")})),
        ("annotation-outcome-of-value-definition", lambda v: v["annotations"].append({"target": variant("Outcome", fields={"definition": "entry", "outcome": "ok"}), "key": "k", "value": variant("Null")})),
    ]


@pytest.mark.parametrize("name,change", lb01_cases(), ids=[case[0] for case in lb01_cases()])
def test_lb01_rejects_every_declaration_the_lean_check_rejects(name, change):
    value = with_sources(library_with([unit_node()]))
    checkLibrary(copy.deepcopy(value))
    change(value)
    with pytest.raises(DeclarationFailure) as caught:
        checkLibrary(value)
    assert caught.value.predicate == "LB01"


def test_lb01_accepts_an_operation_and_targets_declared_in_the_library():
    value = with_sources(library_with([unit_node()]))
    value["definitions"].append(operation_definition([outcome()]))
    value["groups"].append({"id": "g", "members": ["operation"]})
    value["provenance"].append({"target": variant("Outcome", fields={"definition": "operation", "outcome": "ok"}), "origins": [{"source": copy.deepcopy(SOURCE), "locator": []}]})
    value["annotations"].append({"target": variant("Group", "g"), "key": "k", "value": variant("Null")})
    checkLibrary(value)


def test_library_predicates_scan_every_node_before_the_next_predicate():
    value = library_with([
        unit_node(),
        node("string", variant("String", string_spec(wrapper="missing"))),
        product("product", [field("value"), field("value")]),
    ])
    with pytest.raises(DeclarationFailure) as caught:
        checkLibrary(value)
    assert caught.value.predicate == "LB02"


def test_lb06_rejects_an_empty_member_test_key():
    value = library_with([unit_node(), union([branch("unit", "member", variant("MemberShape", [{"key": "", "test": variant("Absent")}]))])])
    with pytest.raises(DeclarationFailure) as caught:
        checkLibrary(value)
    assert caught.value.predicate == "LB06"


def test_decoding_a_library_or_a_profile_runs_no_declaration_check():
    value = invalid_profile_library()
    assert decode_library(value)["profile"] == value["profile"]
    assert decode_profile(value["profile"]) == value["profile"]
    with pytest.raises(DeclarationFailure, match="PR01"):
        checkLibrary(value)
    with pytest.raises(DeclarationFailure, match="PR01"):
        checkProfile(value["profile"])
