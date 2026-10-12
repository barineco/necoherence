# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from copy import deepcopy

from necoherence.signature_values import variant

DIGEST = "a" * 64
REFERENCE = {"identity": "profile", "revision": "1", "content_digest": DIGEST}


def string_spec(**changes):
    value = {"format": None, "lengths": [], "wrapper": None, "const_value": None,
             "enum_values": None, "examples": [], "default_value": None}
    value.update(changes)
    return value


def integer_spec(**changes):
    value = {"domain": None, "minimum": None, "maximum": None, "const_value": None,
             "enum_values": None, "default_value": None}
    value.update(changes)
    return value


def profile():
    text = variant("Text")
    return {
        "reference": deepcopy(REFERENCE), "source_refs": [],
        "integer_domains": [{"name": "integer", "reference": deepcopy(REFERENCE),
                             "range": variant("Inclusive", fields={"minimum": "-100", "maximum": "100"}),
                             "forms": [variant("Number"), variant("IntegralDecimal"), variant("DecimalString")]}],
        "default_integer_domain": "integer", "numbers": {"decimals": True},
        "grapheme_rules": None,
        "format_bindings": [{"name": "text", "reference": deepcopy(REFERENCE), "rule": text}],
        "bytes_policy": {"reference": deepcopy(REFERENCE), "padding_optional": True,
                         "alphabet": variant("Either"), "strict_pad_bits": True, "wrapper": "bytes"},
        "wrappers": [{"name": "text", "key": "text", "payload": variant("Text", None)},
                     {"name": "bytes", "key": "bytes", "payload": variant("Bytes")}],
        "tag": {"key": "kind", "format": "text", "sealed": [
            {"tag": "sealed", "fields": [{"key": "label", "required": True,
                                              "leaf": variant("String", string_spec())}],
             "extras": variant("Reject")}]},
    }


def library():
    p = profile()
    nodes = [
        {"id": "text", "shape": variant("String", string_spec(wrapper="text", examples=["x"]))},
        {"id": "integer", "shape": variant("Integer", integer_spec())},
        {"id": "decimal", "shape": variant("Decimal", {"minimum": None, "maximum": None})},
        {"id": "bytes", "shape": variant("Bytes", {"minimum": None, "maximum": None})},
        {"id": "sealed", "shape": variant("Sealed", fields={"tag": "sealed", "refinements": []})},
        {"id": "union", "shape": variant("TaggedUnion", {"branches": [
            {"target": "sealed", "wire_tag": "sealed", "selector": variant("InternalTag")} ]})},
        {"id": "product", "shape": variant("Product", {"fields": [
            {"wire_name": "name", "slot": {"type_id": "text", "required": True, "nullable": False}},
            {"wire_name": "count", "slot": {"type_id": "integer", "required": False, "nullable": False}}],
            "extras": variant("Reject")})},
        {"id": "never", "shape": variant("Never")},
    ]
    return {"schema": "ncoh-type-signatures@1", "identity": "sample", "revision": "1",
            "profile": p, "sources": [], "provenance": [], "groups": [], "annotations": [],
            "nodes": nodes,
            "definitions": [{"id": "root", "wire_identity": "root", "shape": variant("Value", "product")}]}
