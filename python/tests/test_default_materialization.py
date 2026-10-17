# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from dataclasses import replace

import pytest

from necoherence.signature_values import ValueContext, ValueFailure, WireFailure, encode_wire_json, variant
from necoherence.type_signatures import _signature_ref
from v4_samples import profile


def context(minimum=None):
    shapes = {
        "flag": variant("Boolean", {"const_value": None, "default_value": False}),
        "number": variant("Integer", {"domain": None, "minimum": minimum, "maximum": None, "const_value": None, "enum_values": None, "default_value": "0"}),
        "alias": variant("Alias", fields={"target": "number"}),
        "object": variant("Product", {"fields": [
            {"wire_name": name, "slot": {"type_id": target, "required": required, "nullable": False}}
            for name, target, required in (("flag", "flag", True), ("number", "alias", False))
        ], "extras": variant("Reject")}),
        "array": variant("Array", {"item": {"type_id": "object", "nullable": False}, "min_length": None, "max_length": None}),
    }
    return ValueContext.from_signature_nodes(profile(), [{"id": name, "shape": shape} for name, shape in shapes.items()])


def test_defaults_preserve_false_zero_order_alias_and_idempotence():
    ctx = context()
    before = [{}]
    defaulted = ctx.materialize_defaults("array", before)
    assert before == [{}]
    assert encode_wire_json(defaulted.value) == '[{"flag":false,"number":0}]'
    assert tuple(application.value_path for application in defaulted.applications) == ((0, "flag"), (0, "number"))
    assert defaulted.applications[1].type_ref["definition_name"] == "number"
    assert defaulted.applications[1].origin["pointer"] == ("default",)
    with pytest.raises(TypeError):
        defaulted.value[0]["flag"] = True
    second = ctx.materialize_defaults("array", defaulted.value)
    assert second.value == defaulted.value
    assert second.applications == ()
    forged = replace(defaulted.applications[0], value=True)
    assert not ctx.check_default_applications(before, defaulted.value, (forged,))


def test_invalid_default_precedes_root_validation_with_resolved_ref():
    ctx = context("1")
    with pytest.raises(ValueFailure) as caught:
        ctx.materialize_defaults("object", {"flag": "bad"})
    assert caught.value.type_ref["definition_name"] == "number"
    assert caught.value.value_path == ()
    assert caught.value.condition == "BelowMinimum"
    assert caught.value.origin["pointer"] == []


def test_default_wire_entry_preserves_strict_decode_and_wire_failure():
    ctx = context()
    with pytest.raises(ValueFailure):
        ctx.decode("object", {})
    assert encode_wire_json(ctx.decode_with_defaults("object", "{}").value) == '{"flag":false,"number":0}'
    with pytest.raises(WireFailure):
        ctx.decode_with_defaults("object", '{"flag":false,"flag":true}')

def test_canonical_qualified_graph_and_published_immutable_ref_are_reusable():
    primitive = _signature_ref("flag")
    primitive["source"].update(repository="external", revision="qualified", path="types.json", document_id="document")
    primitive["pointer"] = ["definitions", "flag"]
    root = {**primitive, "definition_name": "root", "pointer": ["definitions", "root"]}
    graph = {"profile": profile(), "nodes": [
        {"reference": primitive, "shape": variant("Boolean", {"const_value": None, "default_value": False})},
        {"reference": root, "shape": variant("Product", {"fields": [
            {"wire_name": "flag", "slot": {"type_ref": primitive, "required": True, "nullable": False}}
        ], "extras": variant("Reject")})},
    ]}
    ctx = ValueContext(graph)
    defaulted = ctx.materialize_defaults(root, {})
    published = defaulted.applications[0].type_ref
    assert ctx.validate(published, False) is False
    assert ctx.materialize_defaults(published, False).applications == ()
    assert published["source"]["repository"] == "external"
    assert published["pointer"] == ("definitions", "flag")
    assert defaulted.applications[0].origin["pointer"] == ("definitions", "flag", "default")

def test_materialization_meaning_admission_has_semantic_evidence_at_root():
    from necoherence.signature_values import UnresolvedValueFailure
    gone, root = _signature_ref("gone"), _signature_ref("root")
    graph = {"profile": profile(), "nodes": [{"reference": root, "shape": variant("Product", {"fields": [
        {"wire_name": "optional", "slot": {"type_ref": gone, "required": False, "nullable": False}}
    ], "extras": variant("Reject")})}]}
    with pytest.raises(UnresolvedValueFailure) as caught:
        ValueContext(graph).materialize_defaults(root, {})
    obligation = caught.value.obligations[0]
    assert obligation["type_ref"]["definition_name"] == "gone"
    assert obligation["value_path"] == ()
    assert obligation["profile"] == graph["profile"]["reference"]
    assert obligation["reason"]["tag"] == "UnresolvedType"

    text_ref = _signature_ref("text")
    graph["nodes"] = [
        {"reference": text_ref, "shape": variant("String", {"format": variant("Named", "missing-format"), "lengths": [], "wrapper": None, "const_value": None, "enum_values": None, "examples": [], "default_value": ""})},
        {"reference": root, "shape": variant("Product", {"fields": [
            {"wire_name": "label", "slot": {"type_ref": text_ref, "required": True, "nullable": False}}
        ], "extras": variant("Reject")})},
    ]
    context = ValueContext(graph)
    for reference, before in ((root, {}), (text_ref, "")):
        with pytest.raises(UnresolvedValueFailure) as caught:
            context.materialize_defaults(reference, before)
        obligation = caught.value.obligations[0]
        assert obligation["type_ref"]["definition_name"] == "text"
        assert obligation["origin"]["pointer"] == ()
        assert obligation["value_path"] == ()
        assert obligation["reason"] == {"tag": "UnknownFormat", "value": "missing-format"}
