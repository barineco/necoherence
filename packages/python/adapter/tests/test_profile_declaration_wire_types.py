# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

import copy

import pytest

from necoherence.declaration_wire import LIBRARY
from necoherence.profile_wire import VALUE_PROFILE
from necoherence.signature_values import WireFailure, variant
from necoherence.type_signatures import decode_generation, decode_profile
from test_profile_predicate_vectors import valid_profile
from test_profile_wire_vectors import complete_library, exchange
from v4_samples import string_spec


def full_library():
    library = complete_library()
    source = {"repository": "r", "revision": "1", "path": "p", "content_digest": "0" * 64}
    def origin(): return {"source": copy.deepcopy(source), "locator": ["x"]}
    library["sources"] = [copy.deepcopy(source)]
    library["groups"] = [{"id": "g", "members": ["entry"]}]
    library["provenance"] = [{"target": variant("Definition", "entry"), "origins": [origin()]}]
    library["annotations"] = [
        {"target": variant("Library"), "key": "a", "value": variant("Null")},
        {"target": variant("Group", "g"), "key": "b", "value": variant("Bool", True)},
        {"target": variant("Type", "unit"), "key": "c", "value": variant("Integer", "-3")},
        {"target": variant("Outcome", fields={"definition": "entry", "outcome": "ok"}), "key": "d",
         "value": {"tag": "Object", "members": [{"key": "k", "value": {"tag": "Array", "items": [
             {"tag": "Decimal", "text": "1.5e2"}, variant("String", "s")]}}]}},
    ]
    port = {"id": "in", "contract": {"type_id": "unit", "required": True, "nullable": False}}
    library["definitions"] = [
        {"id": "entry", "wire_identity": "entry", "shape": variant("Value", "unit")},
        {"id": "sym", "wire_identity": "sym", "shape": variant("Symbol", "wire-symbol")},
        {"id": "msg", "wire_identity": "msg", "shape": variant("Message", "unit")},
        {"id": "op", "wire_identity": "op", "shape": variant("Operation", {
            "effect": variant("DataOnly"),
            "inputs": [port],
            "outcomes": [
                {"id": "ok", "form": variant("Success"),
                 "cause": variant("ValueContract", fields={"origin": origin()}),
                 "value_ports": [{"id": "out", "contract": {"type_id": "unit", "required": True, "nullable": False}}],
                 "produced_resources": [{"id": "r", "token_type": "unit", "revision": "1", "quantity": "2", "provenance": "p"}]},
                {"id": "failed", "form": variant("DeclaredFailure"),
                 "cause": variant("ExternalCondition", fields={"specification": origin()}),
                 "value_ports": [], "produced_resources": []},
            ],
        })},
    ]
    profile = library["profile"]
    profile["source_refs"] = [copy.deepcopy(source)]
    profile["grapheme_rules"]["sources"] = [{"role": "table", "origin": origin()}]
    profile["format_bindings"].append({"name": "dfa", "reference": copy.deepcopy(profile["reference"]), "rule": variant("AsciiDfa", {
        "state_count": "2", "initial_state": "0", "accepting_states": ["1"],
        "transitions": [{"from_state": "0", "first": "97", "last": "97", "to_state": "1"}],
    })})
    nodes = library["nodes"]
    nodes[5]["shape"]["value"]["minimum"] = {"mantissa": "1", "scale": "0", "exclusive": False}
    nodes[6]["shape"]["value"]["lengths"] = [{"unit": variant("Graphemes"), "minimum": "1", "maximum": None}]
    nodes[8]["shape"]["value"]["fields"] = [{"wire_name": "a", "slot": {"type_id": "unit", "required": True, "nullable": False}}]
    nodes[8]["shape"]["value"]["extras"] = variant("Allow", fields={"key_format": None, "value": {"type_id": "unit", "nullable": False}})
    nodes[9]["shape"]["value"]["min_length"] = "1"
    nodes[10]["shape"]["value"]["branches"].append({"target": "unit", "wire_tag": "member", "selector": variant("MemberShape", [{"key": "a", "test": variant("Format", "identifier")}])})
    nodes[11]["shape"]["fields"]["refinements"] = [{"key": "name", "leaf": variant("String", string_spec())}]
    return library


def kind_and_path(check, document):
    with pytest.raises(WireFailure) as caught:
        check(document, "$")
    return caught.value.kind, caught.value.path


def nodes_of(document, path=()):
    yield path, document
    if isinstance(document, dict):
        for key, item in document.items():
            yield from nodes_of(item, (*path, key))
    elif isinstance(document, list):
        for index, item in enumerate(document):
            yield from nodes_of(item, (*path, index))


def container(document, path):
    for step in path:
        document = document[step]
    return document


def replaced_leaf(document, path):
    result = copy.deepcopy(document)
    container(result, path[:-1])[path[-1]] = 1
    return result


def with_extra_field(document, path):
    result = copy.deepcopy(document)
    container(result, path)["unknown-field"] = None
    return result


def without_field(document, path, key):
    result = copy.deepcopy(document)
    del container(result, path)[key]
    return result


def test_full_library_fixture_passes_the_wire_check():
    LIBRARY(full_library(), "$")


def test_every_leaf_of_a_wrong_json_type_is_a_syntax_failure():
    library = full_library()
    leaves = [path for path, node in nodes_of(library) if path and not isinstance(node, (dict, list))]
    accepted = []
    for path in leaves:
        try:
            LIBRARY(replaced_leaf(library, path), "$")
        except WireFailure as failure:
            if failure.kind != "Syntax":
                accepted.append((path, failure.kind))
        else:
            accepted.append((path, "accepted"))
    assert accepted == []


def test_every_record_rejects_an_unknown_field_as_unknown_field():
    library = full_library()
    records = [path for path, node in nodes_of(library) if isinstance(node, dict)]
    rejected_otherwise = [path for path in records if kind_and_path(LIBRARY, with_extra_field(library, path))[0] != "UnknownField"]
    assert rejected_otherwise == []


def test_every_record_rejects_a_missing_field_as_syntax():
    library = full_library()
    cases = [(path, key) for path, node in nodes_of(library) if isinstance(node, dict) for key in node]
    rejected_otherwise = [(path, key) for path, key in cases
                          if kind_and_path(LIBRARY, without_field(library, path, key))[0] != "Syntax"]
    assert rejected_otherwise == []


def profile_with(change):
    profile = valid_profile()
    change(profile)
    return profile


PROFILE_FAILURES = [
    pytest.param(lambda p: p["numbers"].update(decimals="true"), "Syntax", "$.numbers.decimals", id="decimals-as-text"),
    pytest.param(lambda p: p.update(default_integer_domain=1), "Syntax", "$.default_integer_domain", id="default-domain-as-number"),
    pytest.param(lambda p: p.update(source_refs=[{"repository": 1, "revision": "1", "path": "p", "content_digest": "0" * 64}]),
                 "Syntax", "$.source_refs[0].repository", id="source-ref-repository-as-number"),
    pytest.param(lambda p: p["integer_domains"][0]["range"]["fields"].update(minimum="+1"),
                 "Syntax", "$.integer_domains[0].range.minimum", id="integer-domain-noncanonical"),
    pytest.param(lambda p: p["bytes_policy"].update(padding_optional="yes"),
                 "Syntax", "$.bytes_policy.padding_optional", id="padding-as-text"),
    pytest.param(lambda p: p["wrappers"][1]["payload"].update(value=1), "Syntax", "$.wrappers[1].payload", id="wrapper-text-payload-as-number"),
    pytest.param(lambda p: p["wrappers"][0].pop("key"), "Syntax", "$.wrappers[0].key", id="wrapper-key-missing"),
    pytest.param(lambda p: p["format_bindings"][0].update(reference={**p["format_bindings"][0]["reference"], "revision": None}),
                 "Syntax", "$.format_bindings[0].reference.revision", id="format-reference-revision-null"),
    pytest.param(lambda p: p["format_bindings"][0].update(rule=variant("Labels", fields={
        "separator": ".", "min_count": "-1", "max_count": None, "total_max": None, "rule": variant("Text")})),
        "Syntax", "$.format_bindings[0].rule.min_count", id="labels-negative-minimum"),
    pytest.param(lambda p: p["format_bindings"][0].update(rule=variant("Labels", fields={
        "separator": ".", "min_count": "1", "max_count": None, "total_max": None, "rule": variant("Literal", 1)})),
        "Syntax", "$.format_bindings[0].rule", id="labels-nested-literal-value-as-number"),
    pytest.param(lambda p: p["format_bindings"][0].update(rule=variant("Bounded", fields={
        "unit": variant("Graphemes"), "maximum": "1", "rule": variant("Cid")})),
        "UnknownTag", "$.format_bindings[0].rule.tag", id="bounded-nested-unknown-tag"),
    pytest.param(lambda p: p["format_bindings"][0].update(rule=variant("AsciiDfa", {
        "state_count": "-1", "initial_state": "0", "accepting_states": ["0"], "transitions": []})),
        "Syntax", "$.format_bindings[0].rule.state_count", id="dfa-negative-state-count"),
    pytest.param(lambda p: p["format_bindings"][0].update(rule=variant("Identifier", fields={
        "first_alphabet": "a", "rest_alphabet": "a", "exact_length": "x", "min_length": "1",
        "max_length": None, "forbidden": []})),
        "Syntax", "$.format_bindings[0].rule.exact_length", id="identifier-exact-length-text"),
    pytest.param(lambda p: p["format_bindings"][0].update(rule=variant("Sequence", [variant("Literal", 1)])),
                 "Syntax", "$.format_bindings[0].rule[0]", id="sequence-item-literal-value-as-number"),
    pytest.param(lambda p: p["format_bindings"][0].update(rule={"tag": "Literal"}),
                 "Syntax", "$.format_bindings[0].rule.value", id="literal-payload-missing"),
    pytest.param(lambda p: p["grapheme_rules"]["properties"][0].update(first="-1"),
                 "Syntax", "$.grapheme_rules.properties[0].first", id="grapheme-range-negative"),
    pytest.param(lambda p: p["grapheme_rules"]["properties"][0].update(property=variant("Bogus")),
                 "UnknownTag", "$.grapheme_rules.properties[0].property.tag", id="grapheme-property-unknown-tag"),
    pytest.param(lambda p: p["tag"]["sealed"][0].update(extras=variant("Other")),
                 "UnknownTag", "$.tag.sealed[0].extras.tag", id="sealed-extras-unknown-tag"),
    pytest.param(lambda p: p["tag"]["sealed"][0]["fields"][1]["leaf"]["value"].update(minimum=1),
                 "Syntax", "$.tag.sealed[0].fields[1].leaf.minimum", id="sealed-integer-minimum-as-number"),
]


@pytest.mark.parametrize(("change", "kind", "path"), PROFILE_FAILURES)
def test_profile_fields_fail_with_the_lean_kind_and_path(change, kind, path):
    assert kind_and_path(VALUE_PROFILE, profile_with(change)) == (kind, path)


def library_with(change):
    library = full_library()
    change(library)
    return library


LIBRARY_FAILURES = [
    pytest.param(lambda d: d["annotations"][0].update(target=variant("Bogus")),
                 "UnknownTag", "$.annotations[0].target.tag", id="annotation-target-unknown-tag"),
    pytest.param(lambda d: d["annotations"][3]["value"]["members"][0]["value"]["items"][0].update(text="01"),
                 "Syntax", "$.annotations[3].value.text", id="annotation-decimal-leading-zero"),
    pytest.param(lambda d: d["annotations"][3]["value"]["members"][0].pop("value"),
                 "Syntax", "$.annotations[3].value.value", id="annotation-member-value-missing"),
    pytest.param(lambda d: d["annotations"][3]["target"]["fields"].pop("outcome"),
                 "Syntax", "$.annotations[3].target.outcome", id="annotation-outcome-target-missing-field"),
    pytest.param(lambda d: d["definitions"][3]["shape"]["value"]["outcomes"][0]["cause"]["fields"].update(extra=None),
                 "UnknownField", "$.definitions[3].shape.outcomes[0].cause.extra", id="outcome-cause-unknown-field"),
    pytest.param(lambda d: d["definitions"][1].update(shape=variant("Symbol", 1)),
                 "Syntax", "$.definitions[1].shape", id="symbol-payload-as-number"),
    pytest.param(lambda d: d["groups"][0].update(members="entry"),
                 "Syntax", "$.groups[0].members", id="group-members-as-text"),
    pytest.param(lambda d: d["provenance"][0]["origins"][0].update(locator=[1]),
                 "Syntax", "$.provenance[0].origins[0].locator[0]", id="provenance-locator-element-as-number"),
    pytest.param(lambda d: d["nodes"][4]["shape"]["value"].update(minimum=1),
                 "Syntax", "$.nodes[4].shape.minimum", id="integer-shape-minimum-as-number"),
    pytest.param(lambda d: d["nodes"][2].update(shape=variant("Bogus")),
                 "UnknownTag", "$.nodes[2].shape.tag", id="node-shape-unknown-tag"),
    pytest.param(lambda d: d["nodes"][5]["shape"]["value"].update(minimum={"mantissa": "x", "scale": "0", "exclusive": False, }),
                 "Syntax", "$.nodes[5].shape.minimum.mantissa", id="decimal-bound-mantissa-text"),
    pytest.param(lambda d: d["nodes"][5]["shape"]["value"].update(minimum={"mantissa": "1", "scale": "-1", "exclusive": False}),
                 "Syntax", "$.nodes[5].shape.minimum.scale", id="decimal-bound-negative-scale"),
    pytest.param(lambda d: (d.pop("schema"), d.pop("identity")),
                 "Syntax", "$.schema", id="first-missing-field-in-lean-order"),
    pytest.param(lambda d: (d.update(extra=None), d.pop("schema")),
                 "UnknownField", "$.extra", id="unknown-field-before-missing-field"),
]


@pytest.mark.parametrize(("change", "kind", "path"), LIBRARY_FAILURES)
def test_library_declarations_fail_with_the_lean_kind_and_path(change, kind, path):
    assert kind_and_path(LIBRARY, library_with(change)) == (kind, path)


def test_option_fields_accept_null_and_reject_other_types():
    profile = valid_profile()
    profile["bytes_policy"]["wrapper"] = None
    VALUE_PROFILE(profile, "$")
    profile["bytes_policy"]["wrapper"] = 1
    assert kind_and_path(VALUE_PROFILE, profile) == ("Syntax", "$.bytes_policy.wrapper")


def test_decimal_and_nat_fields_keep_their_sign_rules():
    library = full_library()
    library["nodes"][5]["shape"]["value"]["minimum"] = {"mantissa": "-1", "scale": "0", "exclusive": True}
    LIBRARY(library, "$")


@pytest.mark.parametrize(("change", "kind", "path"), [
    (lambda document: document.update(schema="ncoh-checked-generation@3"), "UnsupportedSchema", "$.schema"),
    (lambda document: document["entrypoints"][0].update(identity=1), "Syntax", "$.entrypoints[0].identity"),
    (lambda document: document["basis"].update(problem_sha256=1), "Syntax", "$.basis.problem_sha256"),
    (lambda document: document["signatures"]["profile"]["numbers"].update(decimals="x"),
     "Syntax", "$.signatures.profile.numbers.decimals"),
])
def test_generation_declarations_fail_with_the_lean_kind_and_path(change, kind, path):
    document = exchange()
    change(document)
    with pytest.raises(WireFailure) as caught:
        decode_generation(document)
    assert (caught.value.kind, caught.value.path) == (kind, path)


def test_duplicate_key_in_a_signature_document_is_a_syntax_failure():
    with pytest.raises(WireFailure) as caught:
        decode_profile('{"identity": "a", "identity": "b"}')
    assert (caught.value.kind, caught.value.path) == ("Syntax", "$")
