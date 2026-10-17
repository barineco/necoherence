# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

import copy
import json

import pytest

from necoherence.signature_values import DecimalLiteral, MeaningFailure, ValueContext, ValueFailure, WireFailure, variant
from necoherence.type_signatures import (
    AdmissionFailure, DeclarationFailure, ExpectedSignatureBasis,
    admit_signature_generation, checkLibrary, checkProfile, decode_diagnostic,
    decode_generation, decode_library, decode_profile, decode_signature_basis,
    encode_diagnostic, encode_generation, encode_library, encode_profile,
    encode_signature_basis, signature_basis,
)
from v4_samples import library, profile, string_spec


def exchange():
    value = library(); entries = [{"identity": "root", "definition": "root"}]
    basis = signature_basis(value, entries)
    return basis, {"schema": "ncoh-checked-generation@4", "basis": copy.deepcopy(basis), "signatures": value,
                   "composition": None, "entrypoints": entries}


def test_checked_generation_roundtrips_canonical_v4_wire():
    basis, value = exchange()
    encoded = encode_generation(value)
    assert decode_generation(encoded) == value
    checked = admit_signature_generation(ExpectedSignatureBasis(basis), encoded)
    assert checked.input == value

def test_profile_library_diagnostic_and_basis_satisfy_both_wire_identities():
    source = {
        "repository": "repo", "revision": "rev", "path": "types.json",
        "content_digest": "b" * 64, "document_id": "document",
        "declared_revision": None,
    }
    type_ref = {"source": source, "definition_name": "root", "pointer": ["nodes", "0"]}
    diagnostic = {
        "type_ref": type_ref,
        "definition_ref": {"source": source, "name": "root"},
        "origin": {"source": source, "pointer": ["nodes", "0"]},
        "value_path": [variant("Field", "value"), variant("Index", "0")],
        "condition": variant("WrongValueKind", "string"),
        "observed": variant("Present", variant("Bool", False)),
        "reference_trace": [type_ref],
    }
    basis, _ = exchange()
    documents = (
        (profile(), encode_profile, decode_profile),
        (library(), encode_library, decode_library),
        (diagnostic, encode_diagnostic, decode_diagnostic),
        (basis, encode_signature_basis, decode_signature_basis),
    )
    for value, encode, decode in documents:
        encoded = encode(value)
        assert decode(encoded) == value
        assert encode(decode(encoded)) == encoded


def test_v3_and_unknown_fields_are_typed_wire_failures():
    _, value = exchange(); value["schema"] = "ncoh-checked-generation@3"
    with pytest.raises(WireFailure) as caught: decode_generation(value)
    assert caught.value.kind == "UnsupportedSchema"
    _, value = exchange(); value["extra"] = True
    with pytest.raises(WireFailure) as caught: decode_generation(value)
    assert caught.value.kind == "UnknownField"


def test_profile_and_library_failures_keep_predicate_and_location():
    changed = profile(); changed["reference"]["identity"] = ""
    with pytest.raises(DeclarationFailure) as caught: checkProfile(changed)
    assert (caught.value.predicate, caught.value.location) == ("PR01", ("profile",))
    changed = library(); changed["nodes"].append(copy.deepcopy(changed["nodes"][0]))
    with pytest.raises(DeclarationFailure) as caught: checkLibrary(changed)
    assert caught.value.predicate == "LB01"


def definition_target_library(reference_kind):
    value = library()
    value["nodes"].append({"id": "detached", "shape": variant("Unit")})
    if reference_kind in ("Value", "Message", "Symbol"):
        shape = variant(reference_kind, "detached")
    else:
        source = {"repository": "repo", "revision": "rev", "path": "types.json", "content_digest": "b" * 64}
        value["sources"] = [source]
        def port(identity, target):
            return {"id": identity, "contract": {"type_id": target, "required": True, "nullable": False}}
        shape = variant("Operation", {
            "effect": variant("DataOnly"),
            "inputs": [port("kept", "product"), port("input", "detached" if reference_kind == "input" else "product")],
            "outcomes": [
                {
                    "id": identity, "form": variant("Success"),
                    "cause": variant("ValueContract", fields={"origin": {"source": source, "locator": []}}),
                    "value_ports": [
                        port("kept", "product"),
                        port("output", "detached" if identity == "second" and reference_kind == "output" else "product"),
                    ],
                    "produced_resources": [
                        {"id": "resource", "token_type": "detached" if identity == "second" and reference_kind == "resource" else "product",
                         "revision": "1", "quantity": "1", "provenance": "declared"},
                    ],
                }
                for identity in ("first", "second")
            ],
        })
    value["definitions"].append({"id": "secondary", "wire_identity": "secondary", "shape": shape})
    return value


@pytest.mark.parametrize("reference_kind", ["Value", "Message", "input", "output", "resource"])
def test_definition_target_references_use_lean_library_failure(reference_kind):
    value = definition_target_library(reference_kind)
    assert checkLibrary(value).value == value
    value["nodes"] = [node for node in value["nodes"] if node["id"] != "detached"]
    with pytest.raises(DeclarationFailure) as caught:
        checkLibrary(value)
    assert caught.value.reference == value["identity"]
    assert caught.value.predicate == "LB01"
    assert caught.value.location == ("library",)
    entries = [{"identity": "root", "definition": "root"}]
    basis = signature_basis(value, entries)
    exchange_value = {
        "schema": "ncoh-checked-generation@4", "basis": basis, "signatures": value,
        "composition": None, "entrypoints": entries,
    }
    with pytest.raises(AdmissionFailure) as admitted:
        admit_signature_generation(ExpectedSignatureBasis(basis), json.dumps(exchange_value))
    assert admitted.value.kind == "DeclarationFailure"
    assert isinstance(admitted.value.cause, DeclarationFailure)
    assert admitted.value.cause.reference == value["identity"]
    assert admitted.value.cause.predicate == "LB01"
    assert admitted.value.cause.location == ("library",)


def test_symbol_definition_payload_is_not_a_type_reference():
    value = definition_target_library("Symbol")
    value["nodes"] = [node for node in value["nodes"] if node["id"] != "detached"]
    assert checkLibrary(value).value == value


def test_value_decisions_cover_wrappers_sealed_union_decimal_and_never():
    checked = checkLibrary(library())
    context = ValueContext.from_signature_nodes(checked.value["profile"], checked.value["nodes"])
    assert context.validate("text", {"text": "hello"}) == {"text": "hello"}
    assert context.validate("sealed", {"kind": "sealed", "label": "x"})["label"] == "x"
    assert context.validate("union", {"kind": "sealed", "label": "x"})["kind"] == "sealed"
    assert context.validate("decimal", DecimalLiteral("1.25")).spelling == "1.25"
    for reference, value, condition in (("text", "x", "WrongValueKind:string wrapper"), ("never", None, "InvalidDataModel")):
        with pytest.raises(ValueFailure) as caught: context.validate(reference, value)
        assert caught.value.condition == condition

def test_meaning_obligation_keeps_the_mo_predicate():
    value = library()
    value["profile"]["numbers"]["decimals"] = False
    context = ValueContext.from_signature_nodes(value["profile"], value["nodes"])
    with pytest.raises(MeaningFailure) as caught:
        context.validate("decimal", DecimalLiteral("1.0"))
    assert caught.value.predicate == "MO08"



def test_basis_tampering_is_an_admission_failure():
    basis, value = exchange(); value["basis"]["graph_sha256"] = "0" * 64
    with pytest.raises(AdmissionFailure) as caught:
        admit_signature_generation(ExpectedSignatureBasis(basis), value)
    assert caught.value.kind == "BasisMismatch"


def test_composition_json_preserves_caller_sample_length_and_basis():
    _, value = exchange()
    problem = {
        "identity": "finite", "revision": "1", "basis": signature_basis(value["signatures"], []),
        "signatures": [], "initial_inputs": [], "initial_resources": [],
        "goal": {"outputs": [], "failures": [], "final_resources": []},
        "invocation_domain": {"identity": "finite", "revision": "1", "sites": [],
                              "permitted_projections": [], "permitted_constructions": [],
                              "permitted_transforms": [], "guards": []},
        "allowed_effects": [], "explicit_order": [], "selection_policy": variant("AnyFeasible"),
        "bounds": {"max_expanded_states": "10000", "max_binding_candidates": "100000",
                   "max_type_obligations": "10000", "max_branch_nodes": "100000",
                   "resource_bounds": None, "max_sample_length": "59"},
    }
    value["composition"] = {"problem": problem, "derivation": {"witness": {"input_snapshot": copy.deepcopy(problem)}}}
    value["basis"] = signature_basis(value["signatures"], value["entrypoints"], value["composition"])
    encoded = encode_generation(value)
    restored = decode_generation(encoded)
    assert restored["composition"] == value["composition"]
    assert restored["basis"] == value["basis"]
    assert encode_generation(restored) == encoded
    changed = copy.deepcopy(value["composition"])
    changed["problem"]["bounds"]["max_sample_length"] = "58"
    changed["derivation"]["witness"]["input_snapshot"]["bounds"]["max_sample_length"] = "58"
    assert signature_basis(value["signatures"], value["entrypoints"], changed)["problem_sha256"] != value["basis"]["problem_sha256"]


def wrapper_failure_context(bytes_payload):
    field = "blob" if bytes_payload else "cid"
    key = "$bytes" if bytes_payload else "$link"
    wrapper = "bytes" if bytes_payload else "cid"
    value = library()
    value["profile"]["wrappers"] = [
        {"name": wrapper, "key": key, "payload": variant("Bytes") if bytes_payload else variant("Text", None)},
    ]
    value["profile"]["tag"] = None
    value["nodes"] = [
        {"id": "leaf", "shape": variant("Bytes", {"minimum": None, "maximum": None}) if bytes_payload else variant("String", string_spec(wrapper=wrapper))},
        {"id": "operation", "shape": variant("Product", {
            "fields": [{"wire_name": field, "slot": {"type_id": "leaf", "required": True, "nullable": False}}],
            "extras": variant("Reject"),
        })},
        {"id": "operations", "shape": variant("Array", {
            "item": {"type_id": "operation", "nullable": False}, "min_length": None, "max_length": None,
        })},
        {"id": "root", "shape": variant("Product", {
            "fields": [{"wire_name": "ops", "slot": {"type_id": "operations", "required": True, "nullable": False}}],
            "extras": variant("Reject"),
        })},
    ]
    return ValueContext.from_signature_nodes(value["profile"], value["nodes"]), field, key


@pytest.mark.parametrize("bytes_payload", [False, True])
@pytest.mark.parametrize("invalid_kind", ["plain", "empty", "wrong_key", "wrong_payload", "extra", "array"])
@pytest.mark.parametrize("reference", ["leaf", "operation", "operations", "root"])
def test_wrapper_decode_failure_keeps_value_location(bytes_payload, invalid_kind, reference):
    context, field, key = wrapper_failure_context(bytes_payload)
    invalid = {
        "plain": "invalid", "empty": {}, "wrong_key": {"wrong": "x"},
        "wrong_payload": {key: False}, "extra": {key: "YQ==", "extra": True}, "array": [],
    }[invalid_kind]
    valid = {key: "YQ=="}
    operations = [{field: valid}, {field: invalid}]
    value, path = {
        "leaf": (invalid, ()),
        "operation": ({field: invalid}, (field,)),
        "operations": (operations, (1, field)),
        "root": ({"ops": operations}, ("ops", 1, field)),
    }[reference]
    with pytest.raises(ValueFailure) as caught:
        context.decode(reference, value)
    failure = caught.value
    assert failure.value_path == path
    expected_condition = (
        "InvalidBytes" if bytes_payload else
        "WrongValueKind:wrapper text" if invalid_kind in ("wrong_payload", "extra") else
        "WrongValueKind:string wrapper"
    )
    assert failure.condition == expected_condition
    assert failure.type_ref == context.reference("leaf")
    assert failure.observed == invalid
    expected_trace = {
        "leaf": (), "operation": ("operation",),
        "operations": ("operations", "operation"),
        "root": ("root", "operations", "operation"),
    }[reference]
    assert failure.reference_trace == tuple(context.reference(item) for item in expected_trace)


@pytest.mark.parametrize("bytes_payload", [False, True])
def test_wrapper_decode_accepts_valid_nested_values(bytes_payload):
    context, field, key = wrapper_failure_context(bytes_payload)
    value = {"ops": [{field: {key: "YQ=="}}]}
    assert context.decode("root", value) == value


@pytest.mark.parametrize("label,condition", [
    ({"text": False}, "WrongValueKind:wrapper text"),
    ({"text": "hello", "extra": True}, "WrongValueKind:wrapper text"),
    ({"wrong": "hello"}, "WrongValueKind:string"),
    (False, "WrongValueKind:string"),
])
def test_sealed_leaf_wrapper_failure_keeps_field_path_and_wrapper_condition(label, condition):
    value = library()
    value["profile"]["tag"]["sealed"][0]["fields"][0]["leaf"] = variant("String", string_spec(wrapper="text"))
    context = ValueContext.from_signature_nodes(value["profile"], value["nodes"])
    with pytest.raises(ValueFailure) as caught:
        context.decode("sealed", {"kind": "sealed", "label": label})
    assert caught.value.value_path == ("label",)
    assert caught.value.condition == condition
    assert caught.value.type_ref == context.reference("sealed")


@pytest.mark.parametrize("label", ["hello", {"text": "hello"}])
def test_sealed_leaf_accepts_text_and_valid_wrapper(label):
    value = library()
    value["profile"]["tag"]["sealed"][0]["fields"][0]["leaf"] = variant("String", string_spec(wrapper="text"))
    context = ValueContext.from_signature_nodes(value["profile"], value["nodes"])
    data = {"kind": "sealed", "label": label}
    assert context.decode("sealed", data) == data


@pytest.mark.parametrize("text,accepted", [
    ("!", False), ("a", False), ("YQ===", False), ("YR==", False),
    ("YWJ=", False), ("YW+_", True), ("YQ==", True), ("YQ", True),
    ("YWJj", True), ("", True),
])
def test_sealed_leaf_bytes_wrapper_validates_base64_payload(text, accepted):
    value = library()
    context = ValueContext.from_signature_nodes(value["profile"], value["nodes"])
    data = {"kind": "sealed", "label": {"bytes": text}}
    if accepted:
        assert context.decode("sealed", data) == data
    else:
        with pytest.raises(ValueFailure) as caught:
            context.decode("sealed", data)
        assert caught.value.value_path == ("label",)
        assert caught.value.condition == "InvalidBytes"


@pytest.mark.parametrize("text,accepted", [("hello", True), ("wrong", False)])
def test_sealed_leaf_text_wrapper_validates_profile_format(text, accepted):
    value = library()
    value["profile"]["format_bindings"].append({
        "name": "wrapper-format", "reference": value["profile"]["reference"],
        "rule": variant("Literal", "hello"),
    })
    value["profile"]["wrappers"][0]["payload"] = variant("Text", "wrapper-format")
    context = ValueContext.from_signature_nodes(value["profile"], value["nodes"])
    data = {"kind": "sealed", "label": {"text": text}}
    if accepted:
        assert context.decode("sealed", data) == data
    else:
        with pytest.raises(ValueFailure) as caught:
            context.decode("sealed", data)
        assert caught.value.value_path == ("label",)
        assert caught.value.condition == "Format:wrapper-format"
