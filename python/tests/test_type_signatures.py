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
from v4_samples import library, profile


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


def test_value_decisions_cover_wrappers_sealed_union_decimal_and_never():
    checked = checkLibrary(library())
    context = ValueContext({"profile": checked.value["profile"], "nodes": checked.value["nodes"]})
    assert context.validate("text", {"text": "hello"}) == {"text": "hello"}
    assert context.validate("sealed", {"kind": "sealed", "label": "x"})["label"] == "x"
    assert context.validate("union", {"kind": "sealed", "label": "x"})["kind"] == "sealed"
    assert context.validate("decimal", DecimalLiteral("1.25")).spelling == "1.25"
    for reference, value, condition in (("text", "x", "InvalidWrapper"), ("never", None, "InvalidDataModel")):
        with pytest.raises(ValueFailure) as caught: context.validate(reference, value)
        assert caught.value.condition == condition

def test_meaning_obligation_keeps_the_mo_predicate():
    value = library()
    value["profile"]["numbers"]["decimals"] = False
    context = ValueContext({"profile": value["profile"], "nodes": value["nodes"]})
    with pytest.raises(MeaningFailure) as caught:
        context.validate("decimal", DecimalLiteral("1.0"))
    assert caught.value.predicate == "MO08"



def test_basis_tampering_is_an_admission_failure():
    basis, value = exchange(); value["basis"]["graph_sha256"] = "0" * 64
    with pytest.raises(AdmissionFailure) as caught:
        admit_signature_generation(ExpectedSignatureBasis(basis), value)
    assert caught.value.kind == "BasisMismatch"
