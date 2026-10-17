# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

import copy


def tagged(tag, value=None, *, fields=None):
    if fields is not None:
        return {"tag": tag, "fields": fields}
    return {"tag": tag} if value is None else {"tag": tag, "value": value}


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
    digest = "a" * 64
    reference = {"identity": "representative-declarations", "revision": "4", "content_digest": digest}
    return {
        "reference": reference,
        "source_refs": [],
        "integer_domains": [
            {"name": "default", "reference": reference, "range": tagged("Inclusive", fields={"minimum": "-100", "maximum": "100"}),
             "forms": [tagged("Number"), tagged("IntegralDecimal"), tagged("DecimalString")]},
            {"name": "narrow", "reference": reference, "range": tagged("Inclusive", fields={"minimum": "0", "maximum": "10"}),
             "forms": [tagged("Number")]},
            {"name": "wide", "reference": reference, "range": tagged("Inclusive", fields={"minimum": "0", "maximum": "100"}),
             "forms": [tagged("Number")]},
        ],
        "default_integer_domain": "default",
        "numbers": {"decimals": True},
        "grapheme_rules": {"reference": reference,
                           "component": {"unicode_version": "16.0.0", "uax29_revision": "45",
                                         "cluster_profile": "C1-1-default-extended-grapheme-cluster-no-tailoring"},
                           "table_sha256": "b" * 64, "sources": [],
                           "properties": [{"first": "769", "last": "769", "property": tagged("Extend")}],
                           "extended_pictographic": [], "indic_conjunct": []},
        "format_bindings": [
            {"name": "text", "reference": reference, "rule": tagged("Text")},
            {"name": "not-a", "reference": reference, "rule": tagged("Not", tagged("Literal", "a"))},
            {"name": "optional-a-then-b", "reference": reference,
             "rule": tagged("Sequence", [tagged("Optional", tagged("Literal", "a")), tagged("Literal", "b")])},
            {"name": "extra-x", "reference": reference, "rule": tagged("Literal", "x")},
        ],
        "bytes_policy": {"reference": reference, "padding_optional": True, "alphabet": tagged("Either"),
                         "strict_pad_bits": True, "wrapper": "bytes"},
        "wrappers": [
            {"name": "text-wrapper", "key": "text", "payload": {"tag": "Text", "value": None}},
            {"name": "bytes", "key": "bytes", "payload": tagged("Bytes")},
        ],
        "tag": {"key": "tag", "format": "text", "sealed": [
            {"tag": "sealed", "fields": [{"key": "label", "required": True,
              "leaf": tagged("String", string_spec())}], "extras": tagged("Reject")}
        ]},
    }


def library():
    p = profile()
    nodes = [
        {"id": "text", "shape": tagged("String", string_spec(format=tagged("Named", "text")))},
        {"id": "not-a", "shape": tagged("String", string_spec(format=tagged("Named", "not-a")))},
        {"id": "sequence", "shape": tagged("String", string_spec(format=tagged("Named", "optional-a-then-b")))},
        {"id": "wrapped-text", "shape": tagged("String", string_spec(wrapper="text-wrapper"))},
        {"id": "narrow", "shape": tagged("Integer", integer_spec(domain="narrow"))},
        {"id": "wide", "shape": tagged("Integer", integer_spec(domain="wide"))},
        {"id": "forms-integer", "shape": tagged("Integer", integer_spec(domain="default"))},
        {"id": "decimal", "shape": tagged("Decimal", {"minimum": None, "maximum": None})},
        {"id": "bytes", "shape": tagged("Bytes", {"minimum": None, "maximum": None})},
        {"id": "sealed", "shape": tagged("Sealed", fields={"tag": "sealed", "refinements": []})},
        {"id": "ordinary", "shape": tagged("Product", {"fields": [], "extras": tagged("Reject")})},
        {"id": "extras", "shape": tagged("Product", {"fields": [], "extras": tagged("Allow", fields={
            "key_format": tagged("Named", "extra-x"), "value": {"type_id": "wide", "nullable": False}})})},
        {"id": "nullable-array", "shape": tagged("Array", {
            "item": {"type_id": "text", "nullable": True},
            "min_length": None,
            "max_length": None,
        })},
        {"id": "nullable-extras", "shape": tagged("Product", {
            "fields": [],
            "extras": tagged("Allow", fields={
                "key_format": None,
                "value": {"type_id": "text", "nullable": True},
            }),
        })},
        {"id": "union", "shape": tagged("TaggedUnion", {"branches": [
            {"target": "sealed", "wire_tag": "sealed", "selector": tagged("InternalTag")},
            {"target": "ordinary", "wire_tag": "shaped", "selector": tagged("MemberShape", [{"key": "tag", "test": tagged("Absent")}])},
            {"target": "text", "wire_tag": "string", "selector": tagged("Kind", tagged("String"))},
            {"target": "wide", "wire_tag": "otherwise", "selector": tagged("Otherwise")},
        ]})},
        {"id": "never", "shape": tagged("Never")},
        {"id": "any", "shape": tagged("Unknown", tagged("Any"))},
        {"id": "ordinary-object", "shape": tagged("Unknown", tagged("OrdinaryObject"))},
        {"id": "c2-source", "shape": tagged("Product", {"fields": [], "extras": tagged("Allow", fields={
            "key_format": tagged("Inline", tagged("Literal", "x")), "value": {"type_id": "any", "nullable": False}})})},
        {"id": "c2-destination", "shape": tagged("Product", {"fields": [], "extras": tagged("Allow", fields={
            "key_format": tagged("Inline", tagged("Text")), "value": {"type_id": "any", "nullable": False}})})},
        {"id": "tag-x", "shape": tagged("String", string_spec(const_value="x"))},
        {"id": "i2-source", "shape": tagged("Product", {"fields": [], "extras": tagged("Reject")})},
        {"id": "i2-destination", "shape": tagged("Product", {"fields": [
            {"wire_name": "tag", "slot": {"type_id": "tag-x", "required": False, "nullable": False}}],
            "extras": tagged("Reject")})},
        {"id": "tag-a", "shape": tagged("String", string_spec(const_value="a"))},
        {"id": "tag-b", "shape": tagged("String", string_spec(const_value="b"))},
        {"id": "payload-a", "shape": tagged("Product", {"fields": [
            {"wire_name": "tag", "slot": {"type_id": "tag-a", "required": True, "nullable": False}}],
            "extras": tagged("Reject")})},
        {"id": "payload-b", "shape": tagged("Product", {"fields": [
            {"wire_name": "tag", "slot": {"type_id": "tag-b", "required": True, "nullable": False}}],
            "extras": tagged("Reject")})},
        {"id": "c3-source", "shape": tagged("TaggedUnion", {"branches": [
            {"target": "payload-a", "wire_tag": "a", "selector": tagged("InternalTag")}]})},
        {"id": "c3-destination", "shape": tagged("TaggedUnion", {"branches": [
            {"target": "payload-a", "wire_tag": "a", "selector": tagged("InternalTag")},
            {"target": "payload-b", "wire_tag": "b", "selector": tagged("Otherwise")}]})},
        {"id": "i3-source", "shape": tagged("TaggedUnion", {"branches": [
            {"target": "payload-a", "wire_tag": "a", "selector": tagged("InternalTag")},
            {"target": "payload-b", "wire_tag": "b", "selector": tagged("Otherwise")}]})},
        {"id": "i3-destination", "shape": tagged("TaggedUnion", {"branches": [
            {"target": "payload-a", "wire_tag": "a", "selector": tagged("InternalTag")}]})},
        {"id": "zero-to-nine", "shape": tagged("Integer", integer_spec(domain="narrow", minimum="0", maximum="9"))},
        {"id": "zero-to-ten", "shape": tagged("Integer", integer_spec(domain="narrow", minimum="0", maximum="10"))},
        {"id": "scalar-one", "shape": tagged("String", string_spec(lengths=[
            {"unit": tagged("UnicodeScalars"), "minimum": None, "maximum": "1"}]))},
        {"id": "scalar-two", "shape": tagged("String", string_spec(lengths=[
            {"unit": tagged("UnicodeScalars"), "minimum": None, "maximum": "2"}]))},
        {"id": "utf8-two", "shape": tagged("String", string_spec(lengths=[
            {"unit": tagged("Utf8Bytes"), "minimum": "2", "maximum": "2"}]))},
        {"id": "grapheme-one", "shape": tagged("String", string_spec(lengths=[
            {"unit": tagged("Graphemes"), "minimum": None, "maximum": "1"}]))},
        {"id": "i6-source", "shape": tagged("Product", {"fields": [], "extras": tagged("Allow", fields={
            "key_format": tagged("Inline", tagged("Literal", "x")), "value": {"type_id": "any", "nullable": False}})})},
        {"id": "i6-destination", "shape": tagged("Product", {"fields": [], "extras": tagged("Reject")})},
        {"id": "bytes-source", "shape": tagged("Bytes", {"minimum": None, "maximum": None})},
    ]
    return {"schema": "ncoh-type-signatures@1", "identity": "representative-declarations", "revision": "4",
            "profile": p, "sources": [], "provenance": [], "groups": [], "annotations": [], "nodes": nodes,
            "definitions": [{"id": "root", "wire_identity": "Root", "shape": tagged("Value", "ordinary")}]}


def _case(identity, operation, subject, **fields):
    return {"id": identity, "operation": operation, "rule": subject, **fields}


def generate():
    subject = library()
    invalid_profile = copy.deepcopy(subject)
    invalid_profile["profile"]["reference"]["identity"] = ""
    invalid_library = copy.deepcopy(subject)
    invalid_ordinary = next(node for node in invalid_library["nodes"] if node["id"] == "ordinary")
    invalid_ordinary["shape"]["value"]["fields"] = [
        {"wire_name": "duplicate", "slot": {"type_id": "text", "required": True, "nullable": False}},
        {"wire_name": "duplicate", "slot": {"type_id": "text", "required": True, "nullable": False}},
    ]
    standard_bytes = copy.deepcopy(subject)
    standard_bytes["profile"]["bytes_policy"]["alphabet"] = tagged("Standard")
    urlsafe_bytes = copy.deepcopy(subject)
    urlsafe_bytes["profile"]["bytes_policy"]["alphabet"] = tagged("UrlSafe")
    cases = [
        _case("profile-valid", "profile", "profile-roundtrip", library=subject),
        _case("profile-pr01", "profile", "PR01", library=invalid_profile),
        _case("library-valid", "library", "library-roundtrip", library=subject),
        _case("library-lb02", "library", "LB02", library=invalid_library),
        _case("format-text", "value", "Text", library=subject, type_id="text", value="anything"),
        _case("format-not-accept", "value", "Not", library=subject, type_id="not-a", value="y"),
        _case("format-not-reject", "value", "Not", library=subject, type_id="not-a", value="a"),
        _case("format-sequence-empty-left", "value", "Sequence", library=subject, type_id="sequence", value="b"),
        _case("object-wrapper", "value", "wrapper", library=subject, type_id="wrapped-text", value={"text": "x"}),
        _case("object-sealed", "value", "sealed", library=subject, type_id="sealed", value={"tag": "sealed", "label": "x"}),
        _case("object-sealed-tag-format", "value", "tag-format", library=subject, type_id="sealed", value={"tag": 1, "label": "x"}),
        _case("object-ordinary", "value", "ordinary", library=subject, type_id="ordinary", value={}),
        _case("union-internal-tag", "value", "internalTag", library=subject, type_id="union", value={"tag": "sealed", "label": "x"}),
        _case("union-member-shape", "value", "memberShape", library=subject, type_id="union", value={}),
        _case("union-kind", "value", "kind", library=subject, type_id="union", value="x"),
        _case("union-otherwise", "value", "otherwise", library=subject, type_id="union", value=1),
        _case("integer-number", "value", "IntegerForm.number", library=subject, type_id="narrow", value=10),
        _case("integer-decimal-string", "value", "IntegerForm.decimalString", library=subject, type_id="narrow", value="10"),
        _case("integer-outside-domain", "value", "integer-domain", library=subject, type_id="narrow", value=11),
        _case("extras-reject", "value", "extras-reject", library=subject, type_id="ordinary", value={"x": 1}),
        _case("extras-allow", "value", "extras-allow", library=subject, type_id="extras", value={"x": 1}),
        _case("nullable-array-null", "value", "nullable-array", library=subject,
              type_id="nullable-array", value=[None]),
        _case("nullable-extras-null", "value", "nullable-extras", library=subject,
              type_id="nullable-extras", value={"k": None}),
        _case("never", "value", "never", library=subject, type_id="never", value=None),
        _case("integer-integral-decimal", "value", "IntegerForm.integralDecimal", library=subject,
              type_id="forms-integer", value=10.0),
        _case("decimal-accept", "value", "decimal", library=subject, type_id="decimal", value=1.5),
        _case("decimal-reject", "value", "decimal", library=subject, type_id="decimal", value="1.5"),
        _case("length-utf8-accept", "value", "length-utf8", library=subject, type_id="utf8-two", value="é"),
        _case("length-utf8-reject", "value", "length-utf8", library=subject, type_id="utf8-two", value="a"),
        _case("length-scalar-accept", "value", "length-scalar", library=subject, type_id="scalar-one", value="é"),
        _case("length-scalar-reject", "value", "length-scalar", library=subject, type_id="scalar-one", value="aa"),
        _case("length-grapheme-accept", "value", "length-grapheme", library=subject, type_id="grapheme-one", value="é"),
        _case("length-grapheme-reject", "value", "length-grapheme", library=subject, type_id="grapheme-one", value="ab"),
        _case("bytes-standard-accept", "value", "BytesAlphabet.Standard", library=standard_bytes,
              type_id="bytes", value={"bytes": "AQI="}),
        _case("bytes-standard-reject", "value", "BytesAlphabet.Standard", library=standard_bytes,
              type_id="bytes", value={"bytes": "-_8="}),
        _case("bytes-urlsafe-accept", "value", "BytesAlphabet.UrlSafe", library=urlsafe_bytes,
              type_id="bytes", value={"bytes": "-_8="}),
        _case("bytes-urlsafe-reject", "value", "BytesAlphabet.UrlSafe", library=urlsafe_bytes,
              type_id="bytes", value={"bytes": "+/8="}),
        _case("bytes-either-accept", "value", "BytesAlphabet.Either", library=subject,
              type_id="bytes", value={"bytes": "+/8="}),
        _case("bytes-either-reject", "value", "BytesAlphabet.Either", library=subject,
              type_id="bytes", value={"bytes": "?"}),
    ]
    internal = copy.deepcopy(subject)
    internal["profile"]["tag"] = {"key": "$type", "format": "text", "sealed": []}
    internal["nodes"] = [
        {"id": "text", "shape": tagged("String", string_spec())},
        *[{"id": name, "shape": tagged("Product", {"fields": [
            {"wire_name": "$type", "slot": {"type_id": "text", "required": True, "nullable": False}}
        ], "extras": tagged("Reject")})} for name in ("a", "b")],
        {"id": "union", "shape": tagged("TaggedUnion", {"branches": [
            {"target": name, "wire_tag": "com.example." + name, "selector": tagged("InternalTag")}
            for name in ("a", "b")
        ]})},
    ]
    internal["definitions"][0]["shape"] = tagged("Value", "union")
    cases.append(_case("internal-tags-distinct", "library", "library-roundtrip", library=internal))
    for name, selector in (("kind", tagged("Kind", tagged("Null"))),
                           ("member-shape", tagged("MemberShape", [{"key": "key", "test": tagged("Absent")}]))):
        duplicate = copy.deepcopy(internal)
        for branch in duplicate["nodes"][-1]["shape"]["value"]["branches"]:
            branch["selector"] = copy.deepcopy(selector)
        cases.append(_case("duplicate-selection-" + name, "library", "LB18", library=duplicate))
    for name in ("a", "b", "unknown"):
        cases.append(_case("internal-tag-selection-" + name, "value", "internalTag",
                           library=internal, type_id="union", value={"$type": "com.example." + name}))
    for identity, source, destination, rule in [
        ("c1", "not-a", "not-a", "C1"),
        ("c2", "c2-source", "c2-destination", "C2"),
        ("c3", "c3-source", "c3-destination", "C3"),
        ("c4", "zero-to-nine", "zero-to-ten", "C4"),
        ("c5", "scalar-one", "scalar-two", "C5"),
        ("i1", "text", "not-a", "I1"),
        ("i2", "i2-source", "i2-destination", "I2"),
        ("i3", "i3-source", "i3-destination", "I3"),
        ("i4", "zero-to-ten", "zero-to-nine", "I4"),
        ("i5", "scalar-two", "scalar-one", "I5"),
        ("i6", "i6-source", "i6-destination", "I6"),
        ("i7", "bytes-source", "ordinary-object", "I7"),
    ]:
        cases.append(_case(identity, "inclusion", rule, library=subject, type_id=source,
                           destination_type_id=destination, max_type_obligations="64"))
    for type_id in ("text", "not-a", "sequence", "wrapped-text", "narrow", "sealed", "union", "ordinary", "extras", "never"):
        cases.append(_case("samples-" + type_id, "samples", "samples", library=subject,
                           type_id=type_id, max_type_obligations="64", max_sample_length="32"))
    for name, maximum in (("null", None), ("three", "3")):
        identifier = copy.deepcopy(subject)
        identifier["profile"]["format_bindings"].append({
            "name": "identifier-optional-maximum",
            "reference": identifier["profile"]["reference"],
            "rule": tagged("Identifier", fields={
                "first_alphabet": "ab", "rest_alphabet": "ab", "exact_length": None,
                "min_length": "1", "max_length": maximum, "forbidden": [],
            }),
        })
        cases.append(_case("profile-identifier-maximum-" + name, "profile",
                           "profile-roundtrip", library=identifier))
    return cases


def wire_cases(signature_basis):
    subject = library()
    entrypoints = [{"identity": "Root", "definition": "root"}]
    basis = signature_basis(subject, entrypoints)
    valid = {"schema": "ncoh-checked-generation@4", "basis": basis, "signatures": subject,
             "composition": None, "entrypoints": entrypoints}
    legacy = copy.deepcopy(valid)
    legacy["schema"] = "ncoh-checked-generation@3"
    return [
        _case("wire-v4", "wire", "wire-roundtrip", value=valid),
        _case("wire-v3-rejected", "wire", "wire-invalid", value=legacy),
    ]


DEFAULT_SEED = 38620261011
