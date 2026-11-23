# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

import copy


class NumberText(str):
    pass


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
        _case("object-ordinary-key-order", "value", "ordinary-key-order", library=subject, type_id="ordinary", value={"b": 1, "a": 2}),
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
    cases.extend(semantic_classification_cases())
    cases.extend(extra_key_cases())
    cases.extend(tag_before_keys_cases())
    cases.extend(field_order_cases())
    cases.extend(residual_difference_cases())
    cases.extend(entry_boundary_cases())
    cases.extend(number_text_cases(subject))
    cases.extend(decimal_text_cases(subject))
    cases.extend(decimal_exponent_cases(subject))
    cases.extend(codec_cases(subject))
    cases.extend(decimal_classification_cases())
    cases.extend(bounded_grapheme_cases(subject))
    cases.extend(unresolved_reference_cases())
    cases.extend(sample_and_pair_cases(subject))
    cases.extend(field_extra_order_cases(subject))
    nat_lower = copy.deepcopy(subject)
    nat_lower["nodes"].append({"id": "scalar-min-zero", "shape": tagged("String", string_spec(lengths=[
        {"unit": tagged("UnicodeScalars"), "minimum": "0", "maximum": "1"}]))})
    cases.append(_case("c5-lower-zero", "inclusion", "C5", library=nat_lower, type_id="scalar-one",
                       destination_type_id="scalar-min-zero", max_type_obligations="64"))
    cases.extend(residual_record_cases(cases))
    return cases


def residual_record_bases():
    reference = profile()["reference"]
    full = {"signature_schema": "ncoh-type-signatures@1", "library_identity": "representative-declarations",
            "library_revision": "4", "profile": reference, "graph_sha256": "1" * 64,
            "provenance_sha256": "2" * 64, "metadata_sha256": "3" * 64, "problem_sha256": "4" * 64,
            "observations_sha256": "5" * 64, "entrypoints_sha256": "6" * 64}
    sparse = {**full, "problem_sha256": None, "observations_sha256": None}
    return (("full", full), ("sparse", sparse))


def unresolved_value_cases():
    subject = library()

    def changed(edit, *nodes):
        result = copy.deepcopy(subject)
        edit(result["profile"])
        result["nodes"].extend(nodes)
        return result

    def product(identity, *fields):
        return {"id": identity, "shape": tagged("Product", {"fields": [
            {"wire_name": name, "slot": {"type_id": type_id, "required": True, "nullable": False}}
            for name, type_id in fields], "extras": tagged("Reject")})}

    def opaque(identity, type_name):
        return {"id": identity, "shape": tagged("Opaque", fields={"type_name": type_name})}

    def without_meaning(profile):
        profile.update(grapheme_rules=None, bytes_policy=None)

    def without_decimals(profile):
        profile["numbers"] = {"decimals": False}

    over_bound = {"id": "over-bound", "shape": tagged("Integer", integer_spec(domain="narrow", minimum="0", maximum="1000"))}
    return [
        ("undeclared-type", subject, "undeclared", "x"),
        ("missing-grapheme-rules", changed(lambda p: p.update(grapheme_rules=None)), "grapheme-one", "é"),
        ("missing-bytes-policy", changed(lambda p: p.update(bytes_policy=None)), "bytes", {"bytes": "AQI="}),
        ("opaque-type", changed(lambda p: None, {"id": "opaque", "shape": tagged("Opaque", fields={"type_name": "external"})}),
         "opaque", "x"),
        ("two-residuals-grapheme-bytes",
         changed(without_meaning, product("pair", ("a", "grapheme-one"), ("b", "bytes"))),
         "pair", {"a": "x", "b": {"bytes": "AQI="}}),
        ("two-residuals-bytes-grapheme",
         changed(without_meaning, product("pair", ("a", "bytes"), ("b", "grapheme-one"))),
         "pair", {"a": {"bytes": "AQI="}, "b": "x"}),
        ("two-opaque-types",
         changed(lambda p: None, opaque("first", "external-a"), opaque("second", "external-b"),
                 product("pair", ("a", "first"), ("b", "second"))),
         "pair", {"a": "x", "b": "y"}),
        ("two-opaque-types-reversed-names",
         changed(lambda p: None, opaque("first", "external-b"), opaque("second", "external-a"),
                 product("pair", ("a", "first"), ("b", "second"))),
         "pair", {"a": "x", "b": "y"}),
        ("residual-with-integer-bound",
         changed(lambda p: None, opaque("first", "external"), over_bound, product("pair", ("a", "first"), ("b", "over-bound"))),
         "pair", {"a": "x", "b": 5}),
        ("residual-with-decimal-not-admitted",
         changed(without_decimals, opaque("first", "external"), product("pair", ("a", "first"), ("b", "decimal"))),
         "pair", {"a": "x", "b": 1.5}),
    ]


def residual_record_cases(cases):
    sources = [(case["id"], case["library"], case["type_id"], case["value"])
               for case in cases if case["operation"] == "value"]
    sources.extend((name, subject, type_id, value) for name, subject, type_id, value in unresolved_value_cases())
    return [
        _case(f"residual-record-{name}-{identity}", "residual_record", "residual-record",
              library=subject, type_id=type_id, value=value, basis=copy.deepcopy(basis))
        for identity, subject, type_id, value in sources
        for name, basis in residual_record_bases()
    ]


def semantic_classification_cases():
    reference = {"source": {"repository": "classification", "revision": "1", "path": "types.json", "content_digest": "c" * 64, "document_id": "types", "declared_revision": None}, "definition_name": "subject", "pointer": ["subject"]}
    provenance = {"operation": "validate", "type_ref": reference, "value_path": []}
    units = ["MissingGraphemeRules", "MissingBytesPolicy", "DecimalNotAdmitted", "IntegerBound", "MissingTagModel", "UnresolvedType", "MembershipBound"]
    tuples = ["UnknownFormat", "UnknownIntegerDomain", "UnknownWrapper", "WrapperPayload", "UnknownSealedTag", "OpaqueType", "UninterpretedExtension", "InvalidProfile", "CertificateMismatch", "ProjectionUnavailable"]
    reasons = [tagged(name) for name in units] + [tagged(name, "detail") for name in tuples]
    groups = [[reason] for reason in reasons]
    groups.extend([[], [tagged("UnknownFormat", "format"), tagged("MembershipBound")],
                   [tagged("MembershipBound"), tagged("UnknownFormat", "format"), tagged("IntegerBound")],
                   [tagged("IntegerBound"), tagged("MembershipBound"), tagged("UnknownFormat", "format")],
                   [tagged("UnknownFormat", "format"), tagged("UnknownFormat", "format")]])
    cases = [_case(f"semantic-classification-{index}", "classification", "semantic-reason-classification",
                  obligations=[{"type_ref": reference, "origin": {"source": reference["source"], "pointer": reference["pointer"]}, "value_path": [], "profile": profile()["reference"], "reason": reason} for reason in group],
                  provenance=provenance) for index, group in enumerate(groups)]
    semantic = lambda reason: {"type_ref": reference, "origin": {"source": reference["source"], "pointer": reference["pointer"]}, "value_path": [], "profile": profile()["reference"], "reason": reason}
    type_obligation = lambda reason: tagged("Type", fields={"value": None, "obligations": [{"source": reference, "destination": reference, "reason": reason}]})
    obligations = [tagged(name) for name in ("BranchInhabitation", "StateBoundExhausted", "BindingBoundExhausted", "BranchBoundExhausted", "UnresolvedUniqueness")]
    obligations += [tagged("ResourceSolverUnknown", tagged("BindingBoundExhausted", "1")), tagged("ResourceCapacityBound", fields={"required": "2", "limit": "1"}), tagged("Inhabitation", fields={"producer": tagged("Initial", "input"), "contract": {"type_ref": reference, "required": True, "nullable": False}})]
    obligations += [type_obligation(tagged(name)) for name in ("ConstraintImplication", "Presence", "UnionRemainder", "Inhabitation", "ObligationBoundExhausted")]
    obligations += [type_obligation(tagged("ExtraField", "extra")), type_obligation(tagged("Meaning", [semantic(tagged("MembershipBound")), semantic(tagged("UnknownFormat", "format"))]))]
    mo_reasons = [tagged("UnknownFormat", "format"), tagged("MissingGraphemeRules"), tagged("MissingBytesPolicy"), tagged("UnknownIntegerDomain", "domain"), tagged("UnknownWrapper", "wrapper"), tagged("WrapperPayload", "wrapper"), tagged("UnknownSealedTag", "tag"), tagged("DecimalNotAdmitted"), tagged("IntegerBound"), tagged("OpaqueType", "opaque"), tagged("MissingTagModel")]
    obligations += [tagged("Meaning", [{**semantic(reason), "value_path": [tagged("Field", "meaning")]}]) for reason in mo_reasons]
    obligations += [tagged("Meaning", [semantic(reason)]) for reason in reasons]
    groups = [[obligation] for obligation in obligations]
    groups += [[], [tagged("Meaning", [])], [tagged("Type", fields={"value": None, "obligations": []})], [type_obligation(tagged("Meaning", []))],
               [tagged("Meaning", [semantic(tagged("UnknownFormat", "format")), semantic(tagged("MembershipBound")), semantic(tagged("IntegerBound"))])],
               [tagged("Meaning", [semantic(tagged("UnknownFormat", "format")), semantic(tagged("MembershipBound"))])]]
    composition_provenance = {"operation": "composition", "input_identity": "request", "input_revision": "7"}
    cases += [_case(f"composition-classification-{index}", "classification", "composition-reason-classification", domain="composition", obligations=group, provenance=composition_provenance) for index, group in enumerate(groups)]
    node = {"reference": reference, "shape": tagged("String", string_spec(format=tagged("Named", "undeclared"))), "description": None, "attributes": [], "extensions": []}
    graph = {"profile": profile(), "nodes": [node], "source_refs": []}
    cases += [_case(f"public-validation-{index}", "classification", "public-validation-meaning-first", entry="value", graph=graph if index < 2 else {**graph, "nodes": []}, reference=reference, value=value)
              for index, value in enumerate([True, "ok", True])]
    cases += [_case("public-validation-value-missing", "classification", "public-validation-value-missing", entry="value", graph=graph, reference=reference)]
    distinct = copy.deepcopy(semantic(tagged("UnknownFormat", "other-format")))
    distinct["type_ref"]["definition_name"] = "different-subject"
    distinct["type_ref"]["source"]["declared_revision"] = "12"
    distinct["origin"]["pointer"] = ["origin", "different"]
    distinct["value_path"] = [tagged("Field", "nested"), tagged("Index", "2")]
    cases.append(_case("semantic-distinct-provenance", "classification", "reason-payload-preservation", obligations=[semantic(tagged("UnknownFormat", "format")), distinct], provenance={**provenance, "value_path": [tagged("Field", "request")]}))
    cases.append(_case("composition-distinct-provenance", "classification", "nested-reason-payload-preservation", domain="composition", provenance=composition_provenance,
                       obligations=[tagged("Type", fields={"value": {"producer": tagged("Initial", "argument"), "path": [tagged("Field", "selection")]}, "obligations": [{"source": reference, "destination": distinct["type_ref"], "reason": tagged("Meaning", [distinct, semantic(tagged("MembershipBound"))])}]})]))
    def reordered(value):
        if isinstance(value, dict): return {key: reordered(item) for key, item in reversed(list(value.items()))}
        if isinstance(value, list): return [reordered(item) for item in value]
        return value
    reason = semantic(tagged("UnknownFormat", "format"))
    cases.append(_case("semantic-field-order", "classification", "residual-set-field-order", obligations=[reason, reordered(reason)], provenance=provenance))
    obligation = tagged("Meaning", [reason])
    cases.append(_case("composition-field-order", "classification", "residual-set-field-order", domain="composition", obligations=[obligation, reordered(obligation)], provenance=composition_provenance))
    return cases


def extra_key_cases():
    reference = {"source": {"repository": "classification", "revision": "1", "path": "types.json", "content_digest": "c" * 64, "document_id": "types", "declared_revision": None}, "definition_name": "subject", "pointer": ["subject"]}
    profile_reference = profile()["reference"]
    with_extra = lambda value: {**value, "extra": 1}
    semantic_base = {"type_ref": reference, "origin": {"source": reference["source"], "pointer": reference["pointer"]},
                     "value_path": [tagged("Field", "step")], "profile": profile_reference, "reason": tagged("UnknownFormat", "format")}
    semantic_provenance = {"operation": "validate", "type_ref": reference, "value_path": []}
    composition_provenance = {"operation": "composition", "input_identity": "request", "input_revision": "7"}
    slot = {"type_ref": reference, "required": True, "nullable": False}
    type_item = {"source": reference, "destination": reference, "reason": tagged("Presence")}
    type_obligation = lambda item, **changes: tagged("Type", fields={"value": None, "obligations": [item], **changes})
    inhabitation = {"producer": tagged("Initial", "input"), "contract": slot}
    solver_unknown = tagged("BindingBoundExhausted", "1")
    node = {"reference": reference, "shape": tagged("String", string_spec(format=tagged("Named", "undeclared"))), "description": None, "attributes": [], "extensions": []}
    graph = {"profile": profile(), "nodes": [node], "source_refs": []}

    def semantic(identity, record_type, obligation=None, provenance=None):
        return _case("extra-key-" + identity, "classification", "extra-key-" + record_type,
                     obligations=[obligation or semantic_base], provenance=provenance or semantic_provenance)

    def composition(identity, record_type, obligation, provenance=None):
        return _case("extra-key-" + identity, "classification", "extra-key-" + record_type, domain="composition",
                     obligations=[obligation], provenance=provenance or composition_provenance)

    def public_validation(identity, record_type, changed_graph):
        return _case("extra-key-" + identity, "classification", "extra-key-" + record_type, entry="value",
                     graph=changed_graph, reference=reference, value=True)

    reason_unit = {**semantic_base, "reason": with_extra(tagged("MembershipBound"))}
    reason_tuple = {**semantic_base, "reason": with_extra(tagged("UnknownFormat", "format"))}
    changed_node = copy.deepcopy(graph)
    changed_node["nodes"][0] = with_extra(node)
    changed_shape = copy.deepcopy(graph)
    changed_shape["nodes"][0]["shape"] = with_extra(node["shape"])
    changed_profile = copy.deepcopy(graph)
    changed_profile["profile"]["reference"] = with_extra(profile_reference)
    return [
        semantic("semantic-obligation", "SemanticObligation", with_extra(semantic_base)),
        semantic("type-ref", "TypeRef", {**semantic_base, "type_ref": with_extra(reference)}),
        semantic("source-ref", "SourceRef", {**semantic_base, "type_ref": {**reference, "source": with_extra(reference["source"])}}),
        semantic("origin", "OccurrenceRef", {**semantic_base, "origin": with_extra(semantic_base["origin"])}),
        semantic("reason-unit", "SemanticReason-unit", reason_unit),
        semantic("reason-tuple", "SemanticReason-tuple", reason_tuple),
        semantic("value-path-step", "PathStep", {**semantic_base, "value_path": [with_extra(tagged("Field", "step"))]}),
        semantic("profile-reference", "ValueReference", {**semantic_base, "profile": with_extra(profile_reference)}),
        semantic("evaluation-provenance", "EvaluationProvenance", provenance=with_extra(semantic_provenance)),
        composition("composition-provenance", "CompositionProvenance", tagged("BranchInhabitation"), with_extra(composition_provenance)),
        composition("composition-meaning", "UnresolvedObligation-meaning", with_extra(tagged("Meaning", [semantic_base]))),
        composition("composition-meaning-obligation", "SemanticObligation-in-composition", tagged("Meaning", [with_extra(semantic_base)])),
        composition("composition-unit", "UnresolvedObligation-unit", with_extra(tagged("BranchInhabitation"))),
        composition("type-outer", "UnresolvedObligation-type", with_extra(type_obligation(type_item))),
        composition("type-fields", "UnresolvedObligation-type-fields", tagged("Type", fields=with_extra({"value": None, "obligations": [type_item]}))),
        composition("type-item", "TypeObligation", type_obligation(with_extra(type_item))),
        composition("type-item-source", "TypeRef-in-type-obligation", type_obligation({**type_item, "source": with_extra(reference)})),
        composition("type-reason-unit", "TypeObligationReason-unit", type_obligation({**type_item, "reason": with_extra(tagged("Presence"))})),
        composition("type-reason-extra-field", "TypeObligationReason-extra-field", type_obligation({**type_item, "reason": with_extra(tagged("ExtraField", "extra"))})),
        composition("type-reason-meaning", "TypeObligationReason-meaning", type_obligation({**type_item, "reason": with_extra(tagged("Meaning", []))})),
        composition("inhabitation-outer", "UnresolvedObligation-inhabitation", with_extra(tagged("Inhabitation", fields=inhabitation))),
        composition("inhabitation-fields", "UnresolvedObligation-inhabitation-fields", tagged("Inhabitation", fields=with_extra(inhabitation))),
        composition("inhabitation-producer", "ProducerRef", tagged("Inhabitation", fields={**inhabitation, "producer": with_extra(tagged("Initial", "input"))})),
        composition("inhabitation-slot", "SlotContract", tagged("Inhabitation", fields={**inhabitation, "contract": with_extra(slot)})),
        composition("resource-capacity-outer", "UnresolvedObligation-resource-capacity", with_extra(tagged("ResourceCapacityBound", fields={"required": "2", "limit": "1"}))),
        composition("resource-capacity-fields", "UnresolvedObligation-resource-capacity-fields", tagged("ResourceCapacityBound", fields=with_extra({"required": "2", "limit": "1"}))),
        composition("resource-solver-outer", "UnresolvedObligation-resource-solver", with_extra(tagged("ResourceSolverUnknown", solver_unknown))),
        composition("resource-solver-inner", "ResourceSolverUnknown", tagged("ResourceSolverUnknown", with_extra(solver_unknown))),
        public_validation("graph", "SemanticGraph", with_extra(graph)),
        public_validation("graph-node", "TypeNode", changed_node),
        public_validation("graph-shape", "TypeShape", changed_shape),
        public_validation("graph-profile", "ValueProfile-reference", changed_profile),
    ]


def tag_before_keys_cases():
    reference = {"source": {"repository": "classification", "revision": "1", "path": "types.json", "content_digest": "c" * 64, "document_id": "types", "declared_revision": None}, "definition_name": "subject", "pointer": ["subject"]}
    composition_provenance = {"operation": "composition", "input_identity": "request", "input_revision": "7"}
    node = {"reference": reference, "shape": tagged("String", string_spec(format=tagged("Named", "undeclared"))), "description": None, "attributes": [], "extensions": []}
    graph = {"profile": profile(), "nodes": [node], "source_refs": []}
    solver = lambda row: tagged("ResourceSolverUnknown", row)
    shape_graph = lambda shape: {**graph, "nodes": [{**node, "shape": shape}]}
    unknown_tag_with_extra = {"tag": "Bogus", "value": "1", "extra": 1}
    unknown_tag_without_value = {"tag": "Bogus"}
    shape_value = string_spec(format=tagged("Named", "undeclared"))
    rows = [
        ("resource-solver-unknown-tag-and-extra-key", "ResourceSolverUnknown-inner-tag-before-keys",
         dict(domain="composition", obligations=[solver(unknown_tag_with_extra)], provenance=composition_provenance)),
        ("resource-solver-unknown-tag-and-missing-value", "ResourceSolverUnknown-inner-tag-before-keys",
         dict(domain="composition", obligations=[solver(unknown_tag_without_value)], provenance=composition_provenance)),
        ("graph-shape-tag-and-extra-key", "TypeShape-tag-before-keys",
         dict(entry="value", graph=shape_graph({"tag": "Bogus", "value": shape_value, "extra": 1}), reference=reference, value=True)),
        ("graph-shape-tag-and-missing-value", "TypeShape-tag-before-keys",
         dict(entry="value", graph=shape_graph({"tag": "Bogus"}), reference=reference, value=True)),
    ]
    return [_case("tag-before-keys-" + identity, "classification", "tag-before-keys-" + record_type, **fields)
            for identity, record_type, fields in rows]


def entry_boundary_cases():
    reference = {"source": {"repository": "classification", "revision": "1", "path": "types.json", "content_digest": "c" * 64, "document_id": "types", "declared_revision": None}, "definition_name": "subject", "pointer": ["subject"]}
    composition_provenance = {"operation": "composition", "input_identity": "request", "input_revision": "7"}
    node = {"reference": reference, "shape": tagged("String", string_spec(format=tagged("Named", "undeclared"))), "description": None, "attributes": [], "extensions": []}
    graph = {"profile": profile(), "nodes": [node], "source_refs": []}
    return [
        _case("composition-domain-with-entry-value", "classification", "composition-domain-before-entry", domain="composition", entry="value", graph=graph, reference=reference, value=True,
              obligations=[tagged("BranchInhabitation")], provenance=composition_provenance),
    ]


def field_order_cases():
    reference = {"source": {"repository": "classification", "revision": "1", "path": "types.json", "content_digest": "c" * 64, "document_id": "types", "declared_revision": None}, "definition_name": "subject", "pointer": ["subject"]}
    provenance = {"operation": "validate", "type_ref": reference, "value_path": []}
    composition_provenance = {"operation": "composition", "input_identity": "request", "input_revision": "7"}
    origin = {"source": reference["source"], "pointer": reference["pointer"], "extra": 1}
    obligation = {"type_ref": reference, "origin": origin, "value_path": [], "profile": profile()["reference"], "reason": tagged("Bogus")}
    type_item = {"source": reference, "destination": reference, "reason": tagged("Presence")}
    value = {"producer": tagged("Bogus"), "path": []}
    return [
        _case("field-order-semantic-origin-before-reason", "classification", "obligation-field-order",
              obligations=[obligation], provenance=provenance),
        _case("field-order-composition-type-value-before-obligations", "classification", "composition-type-field-order",
              domain="composition", obligations=[tagged("Type", fields={"value": value, "obligations": [{**type_item, "extra": 1}]})],
              provenance=composition_provenance),
    ]


def residual_difference_cases():
    reference = {"source": {"repository": "classification", "revision": "1", "path": "types.json", "content_digest": "c" * 64, "document_id": "types", "declared_revision": None}, "definition_name": "subject", "pointer": ["subject"]}
    provenance = {"operation": "validate", "type_ref": reference, "value_path": []}
    node = {"reference": reference, "shape": tagged("String", string_spec(format=tagged("Named", "undeclared"))), "description": None, "attributes": [], "extensions": []}
    graph = {"profile": profile(), "nodes": [node], "source_refs": []}
    nested_profile = {**profile(), "bytes_policy": {**profile()["bytes_policy"], "note": 1}}
    unordered_spec = {**node, "shape": tagged("String", string_spec(format=tagged("Named"), lengths=[{"unit": tagged("Bogus"), "minimum": None, "maximum": None}]))}
    duplicate = {**node, "shape": tagged("String", string_spec(const_value="other"))}
    reason = {"type_ref": reference, "origin": {"source": reference["source"], "pointer": reference["pointer"]}, "value_path": [], "profile": profile()["reference"], "reason": {"tag": "Bogus", "value": "format", "extra": 1}}
    return [
        _case("residual-profile-nested-extra-key", "classification", "residual-profile-nested-extra-key", entry="value", graph={**graph, "profile": nested_profile}, reference=reference, value=True),
        _case("residual-reason-tag-before-keys", "classification", "residual-reason-tag-before-keys", obligations=[reason], provenance=provenance),
        _case("residual-string-spec-field-order", "classification", "residual-string-spec-field-order", entry="value", graph={**graph, "nodes": [unordered_spec]}, reference=reference, value=True),
        _case("residual-duplicate-type-reference", "classification", "residual-duplicate-type-reference", entry="value", graph={**graph, "nodes": [node, duplicate]}, reference=reference, value="ok"),
    ]

NUMBER_TEXTS = ("0", "0.0", "-0.0", "0e-100", "0.000e-100", "0e11", "1e1", "1e9999", "1e10000", "1e-10000")
LONG_EXPONENT_TEXTS = ("1e" + "1" * 5000, "1e-" + "1" * 5000)
LINE_REJECTED_NUMBER_TEXTS = ("1e10000", "1e-10000")


def number_text_cases(subject):
    cases = []
    for index, text in enumerate(NUMBER_TEXTS):
        if text not in LINE_REJECTED_NUMBER_TEXTS:
            for type_id in ("forms-integer", "narrow", "wide", "decimal"):
                cases.append(_case(f"number-text-{index}-{type_id}", "value", "number-text", library=subject,
                                   type_id=type_id, value=NumberText(text)))
        for type_id in ("forms-integer", "decimal"):
            cases.append(_case(f"number-string-{index}-{type_id}", "value", "number-string", library=subject,
                               type_id=type_id, value=text))
    for index, text in enumerate(LONG_EXPONENT_TEXTS):
        cases.append(_case(f"number-string-long-{index}-forms-integer", "value", "number-string", library=subject, type_id="forms-integer", value=text))
    return cases


LARGE_NEGATIVE_EXPONENT_TEXTS = ("1e-9999", "1.5e-9999", "-1e-9999")


def decimal_exponent_cases(subject):
    bounded = copy.deepcopy(subject)
    bounded["nodes"].append({"id": "decimal-max-zero", "shape": tagged("Decimal", {"minimum": None, "maximum": {"mantissa": "0", "scale": "0", "exclusive": False}})})
    bounded["nodes"].append({"id": "decimal-min-one", "shape": tagged("Decimal", {"minimum": {"mantissa": "1", "scale": "0", "exclusive": False}, "maximum": None})})
    return [_case(f"decimal-exponent-{index}-{type_id}", "value", "number-text", library=bounded,
                  type_id=type_id, value=NumberText(text))
            for index, text in enumerate(LARGE_NEGATIVE_EXPONENT_TEXTS) for type_id in ("decimal-max-zero", "decimal-min-one")]


DECIMAL_TEXTS = ("10.0", "1.50e1", "100e-2", "1.0")
CODEC_INTEGER_FORMS = (
    ("number-decimal-string", ("Number", "DecimalString")),
    ("integral", ("IntegralDecimal",)),
    ("decimal-string", ("DecimalString",)),
    ("integral-decimal-string", ("IntegralDecimal", "DecimalString")),
)
CODEC_INTEGER_VALUES = ("0", "5", "-7")
CODEC_DECIMAL_TEXTS = ("0.0", "10.0", "1.5", "0e-100")


def decimal_text_cases(subject):
    cases = []
    for index, text in enumerate(DECIMAL_TEXTS):
        for type_id in ("forms-integer", "narrow", "wide", "decimal"):
            cases.append(_case(f"decimal-text-{index}-{type_id}", "value", "number-text", library=subject,
                               type_id=type_id, value=NumberText(text)))
        for type_id in ("forms-integer", "decimal"):
            cases.append(_case(f"decimal-string-{index}-{type_id}", "value", "number-string", library=subject,
                               type_id=type_id, value=text))
    return cases


def decimal_classification_cases():
    reference = {"source": {"repository": "classification", "revision": "1", "path": "types.json", "content_digest": "c" * 64, "document_id": "types", "declared_revision": None}, "definition_name": "subject", "pointer": ["subject"]}
    named = lambda name: {**reference, "definition_name": name, "pointer": [name]}
    node = lambda name, shape: {"reference": named(name), "shape": shape, "description": None, "attributes": [], "extensions": []}
    nodes = [node("decimal", tagged("Decimal", {"minimum": None, "maximum": None})),
             node("forms-integer", tagged("Integer", integer_spec(domain="default"))),
             node("narrow", tagged("Integer", integer_spec(domain="narrow")))]
    graph = {"profile": profile(), "nodes": nodes, "source_refs": []}
    return [_case(f"public-decimal-{name}-{index}", "classification", "public-validation-number-text", entry="value",
                  graph=graph, reference=named(name), value=NumberText(text))
            for index, text in enumerate(DECIMAL_TEXTS) for name in ("decimal", "forms-integer", "narrow")]


def codec_library(subject):
    codec = copy.deepcopy(subject)
    for name, forms in CODEC_INTEGER_FORMS:
        domain = "codec-" + name
        codec["profile"]["integer_domains"].append({"name": domain, "reference": codec["profile"]["reference"],
                                                    "range": tagged("Unbounded"), "forms": [tagged(form) for form in forms]})
        codec["nodes"].append({"id": domain, "shape": tagged("Integer", integer_spec(domain=domain))})
    return codec


def codec_cases(subject):
    codec = codec_library(subject)
    cases = []
    for name, _ in CODEC_INTEGER_FORMS:
        type_id = "codec-" + name
        for value in CODEC_INTEGER_VALUES:
            cases.append(_case(f"codec-{name}-number-{value}", "value", "codec-integer", library=codec,
                               type_id=type_id, value=NumberText(value)))
            cases.append(_case(f"codec-{name}-integral-{value}", "value", "codec-integer", library=codec,
                               type_id=type_id, value=NumberText(value + ".0")))
            cases.append(_case(f"codec-{name}-decimal-string-{value}", "value", "codec-integer", library=codec,
                               type_id=type_id, value=value))
    for index, text in enumerate(CODEC_DECIMAL_TEXTS):
        cases.append(_case(f"codec-decimal-{index}", "value", "codec-decimal", library=codec,
                           type_id="decimal", value=NumberText(text)))
    return cases



def bounded_grapheme_cases(subject):
    bounded = copy.deepcopy(subject)
    bounded["profile"]["format_bindings"].append({"name": "bounded-graphemes", "reference": bounded["profile"]["reference"],
                                                  "rule": tagged("Bounded", fields={"unit": tagged("Graphemes"), "maximum": "3", "rule": tagged("Text")})})
    bounded["nodes"].append({"id": "bounded-graphemes", "shape": tagged("String", string_spec(format=tagged("Named", "bounded-graphemes")))})
    return [
        _case("c6-bounded-graphemes-identical", "inclusion", "C6", library=bounded, type_id="bounded-graphemes",
              destination_type_id="bounded-graphemes", max_type_obligations="64"),
        _case("bounded-graphemes-accept", "value", "bounded-graphemes", library=bounded, type_id="bounded-graphemes", value="ab"),
        _case("bounded-graphemes-reject", "value", "bounded-graphemes", library=bounded, type_id="bounded-graphemes", value="abcd"),
    ]


def unresolved_reference_cases():
    reference = {"source": {"repository": "classification", "revision": "1", "path": "types.json", "content_digest": "c" * 64, "document_id": "types", "declared_revision": None}, "definition_name": "subject", "pointer": ["subject"]}
    missing = {**reference, "definition_name": "missing", "pointer": ["missing"]}
    node = {"reference": reference, "shape": tagged("String", string_spec()), "description": None, "attributes": [], "extensions": []}
    graph = {"profile": profile(), "nodes": [node], "source_refs": []}
    return [
        _case("mo12-unresolved-reference", "classification", "public-validation-unresolved-reference", entry="value", graph=graph, reference=missing, value="ok"),
        _case("mo12-unresolved-reference-value-missing", "classification", "public-validation-unresolved-reference", entry="value", graph=graph, reference=missing),
    ]



def wire_cases(signature_basis):
    subject = library()
    entrypoints = [{"identity": "Root", "definition": "root"}]
    basis = signature_basis(subject, entrypoints)
    valid = {"schema": "ncoh-checked-generation@5", "basis": basis, "signatures": subject,
             "composition": None, "entrypoints": entrypoints}
    legacy = copy.deepcopy(valid)
    legacy["schema"] = "ncoh-checked-generation@3"
    return [
        _case("wire-v4", "wire", "wire-roundtrip", value=valid),
        _case("wire-v3-rejected", "wire", "wire-invalid", value=legacy),
    ]


DEFAULT_SEED = 38620261011


def sample_and_pair_cases(subject):
    cases = []
    identifier = copy.deepcopy(subject)
    identifier["profile"]["format_bindings"].append({"name": "identifier-one", "reference": identifier["profile"]["reference"],
        "rule": tagged("Identifier", fields={"first_alphabet": "ab", "rest_alphabet": "b", "exact_length": None, "min_length": "1", "max_length": "1", "forbidden": []})})
    identifier["nodes"].append({"id": "identifier-one", "shape": tagged("String", string_spec(format=tagged("Named", "identifier-one")))})
    raw = copy.deepcopy(subject)
    raw["profile"]["bytes_policy"]["alphabet"] = tagged("Standard")
    raw["nodes"].append({"id": "raw-body", "shape": tagged("RawBody", fields={"encoding": "utf-8"})})
    decimal = copy.deepcopy(subject)
    decimal["nodes"].append({"id": "decimal-bounded", "shape": tagged("Decimal", {"minimum": {"mantissa": "25", "scale": "1", "exclusive": False}, "maximum": None})})
    ordered = copy.deepcopy(subject)
    ordered["nodes"].append({"id": "ordered-fields", "shape": tagged("Product", {"fields": [
        {"wire_name": "b", "slot": {"type_id": "narrow", "required": True, "nullable": False}},
        {"wire_name": "a", "slot": {"type_id": "text", "required": True, "nullable": False}}], "extras": tagged("Reject")})})
    alias = copy.deepcopy(subject)
    alias["nodes"].append({"id": "alias-zero-to-nine", "shape": tagged("Alias", fields={"target": "zero-to-nine"})})
    alias["nodes"].append({"id": "alias-zero-to-ten", "shape": tagged("Alias", fields={"target": "zero-to-ten"})})
    meaning = copy.deepcopy(subject)
    meaning["profile"]["numbers"] = {"decimals": False}
    for identity, library, type_id in (
        ("samples-identifier-one", identifier, "identifier-one"),
        ("samples-raw-body", raw, "raw-body"),
        ("samples-decimal-bounded", decimal, "decimal-bounded"),
        ("samples-ordered-fields", ordered, "ordered-fields"),
        ("samples-nullable-extras", subject, "nullable-extras"),
    ):
        cases.append(_case(identity, "samples", "samples", library=library, type_id=type_id, max_type_obligations="64", max_sample_length="32"))
    for identity, source, destination in (
        ("alias-child-zero-to-ten-to-nine", "zero-to-ten", "alias-zero-to-nine"),
        ("alias-child-zero-to-nine-to-ten", "zero-to-nine", "alias-zero-to-ten"),
        ("union-to-text", "union", "text"),
        ("text-to-union", "text", "union"),
        ("union-to-union", "union", "union"),
        ("meaning-same-type", "decimal", "decimal"),
    ):
        cases.append(_case("inclusion-" + identity, "inclusion", "PAIR", library=alias if "alias" in identity else meaning if "meaning" in identity else subject, type_id=source, destination_type_id=destination, max_type_obligations="64"))
    return cases


def field_extra_order_cases(subject):
    fields = [
        {"wire_name": "count", "slot": {"type_id": "narrow", "required": True, "nullable": False}},
        {"wire_name": "label", "slot": {"type_id": "text", "required": True, "nullable": False}},
    ]
    library = copy.deepcopy(subject)
    library["nodes"].append({"id": "fields-allow-extras", "shape": tagged("Product", {"fields": fields, "extras": tagged("Allow", fields={
        "key_format": None, "value": {"type_id": "wide", "nullable": False}})})})
    library["nodes"].append({"id": "fields-reject-extras", "shape": tagged("Product", {"fields": fields, "extras": tagged("Reject")})})
    rows = [
        ("extra-value-before-field-value", "fields-allow-extras", {"x": "bad", "count": "bad", "label": "ok"}),
        ("extra-value-before-missing-field", "fields-allow-extras", {"x": "bad", "label": "ok"}),
        ("extra-value-before-null-field", "fields-allow-extras", {"x": "bad", "count": None, "label": "ok"}),
        ("later-field-before-earlier-field", "fields-allow-extras", {"label": 1, "count": "bad"}),
        ("extra-key-before-field-value", "fields-reject-extras", {"unknown": 1, "count": "bad", "label": "ok"}),
        ("field-value-before-extra-key", "fields-reject-extras", {"count": "bad", "unknown": 1, "label": "ok"}),
    ]
    return [_case("field-extra-order-" + identity, "value", "field-extra-order", library=library, type_id=type_id, value=value)
            for identity, type_id, value in rows]
