# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

import copy
from semantic_invariant_inputs import NUMBER_TEXTS


def ref(name):
    return {"source": {"repository": "default-samples", "revision": "1", "path": "types.json", "content_digest": "a" * 64, "document_id": "defaults", "declared_revision": "7"}, "definition_name": name, "pointer": ["definitions", name]}


def tagged(tag, value=None, *, fields=None):
    return {"tag": tag, **({"fields": fields} if fields is not None else {} if value is None else {"value": value})}


def exact(value):
    if value is None: return tagged("Null")
    if type(value) is bool: return {"tag": "Bool", "value": value}
    if type(value) is int: return {"tag": "Integer", "value": str(value)}
    if type(value) is str: return {"tag": "String", "value": value}
    if isinstance(value, list): return {"tag": "Array", "items": [exact(item) for item in value]}
    return {"tag": "Object", "members": [{"key": key, "value": exact(item)} for key, item in value.items()]}


def field(name, target, required=True, nullable=False):
    reference = ref(target)
    return {"wire_name": name, "slot": {"type_ref": reference, "required": required, "nullable": nullable}, "origin": {"source": reference["source"], "pointer": reference["pointer"]}}


def graph():
    profile_ref = {"identity": "default-values", "revision": "1", "content_digest": "b" * 64}
    profile = {"reference": profile_ref, "source_refs": [], "integer_domains": [{"name": "integer", "reference": profile_ref, "range": tagged("Unbounded"), "forms": [tagged("Number")]}, {"name": "integral", "reference": profile_ref, "range": tagged("Unbounded"), "forms": [tagged("Number"), tagged("IntegralDecimal"), tagged("DecimalString")]}], "default_integer_domain": "integer", "numbers": {"decimals": True}, "grapheme_rules": None, "format_bindings": [], "bytes_policy": None, "wrappers": [], "tag": {"key": "kind", "format": None, "sealed": []}}
    profile["integer_domains"].append({"name": "bounded", "reference": profile_ref, "range": tagged("Inclusive", fields={"minimum": "0", "maximum": "10"}), "forms": [tagged("Number"), tagged("IntegralDecimal"), tagged("DecimalString")]})
    def integer(default):
        return tagged("Integer", {"domain": None, "minimum": None, "maximum": None, "const_value": None, "enum_values": None, "default_value": default})
    def string(default=None, constant=None):
        return tagged("String", {"format": None, "lengths": [], "wrapper": None, "const_value": constant, "enum_values": None, "examples": [], "default_value": default})
    extras = tagged("Allow", fields={"key_format": None, "value": {"type_ref": ref("any"), "nullable": False}})
    leaf = [field("flag", "flag"), field("zero", "alias", False), field("big", "big"), field("empty", "empty"), field("maybe", "text", False, True), field("constant", "constant", False)]
    shapes = {
        "flag": tagged("Boolean", {"const_value": None, "default_value": False}),
        "zero": integer("0"), "big": integer("900719925474099312345678901234567890"), "empty": string(""), "text": string(), "constant": string(constant="fixed"),
        "any": tagged("Unknown", tagged("Any")),
        "alias": tagged("Alias", fields={"target": ref("alias2"), "reference_text": "alias2"}),
        "alias2": tagged("Alias", fields={"target": ref("zero"), "reference_text": "zero"}),
        "leaf": tagged("Product", {"fields": leaf, "extras": extras}),
        "array": tagged("Array", {"item": {"type_ref": ref("leaf"), "nullable": True}, "min_length": None, "max_length": None}),
        "parent": tagged("Product", {"fields": [field("child", "leaf", False, True), field("items", "array", False), field("label", "empty", False)], "extras": extras}),
        "branch_a": tagged("Product", {"fields": [field("kind", "text"), field("payload", "flag"), field("count", "alias", False)], "extras": extras}),
        "branch_b": tagged("Product", {"fields": [field("payload", "empty"), field("kind", "text"), field("count", "alias", False)], "extras": extras}),
        "loop": tagged("Alias", fields={"target": ref("loop"), "reference_text": "loop"}),
        "recursive": tagged("Array", {"item": {"type_ref": ref("recursive"), "nullable": False}, "min_length": None, "max_length": None}),
    }
    shapes["union"] = tagged("TaggedUnion", {"branches": [{"target": ref(target), "wire_tag": tag, "selector": tagged("InternalTag"), "origin": {"source": ref(target)["source"], "pointer": ["branches", tag]}} for tag, target in [("a", "branch_a"), ("b", "branch_b")]]})
    shapes["integral_default"] = tagged("Integer", {"domain": "integral", "minimum": None, "maximum": None, "const_value": None, "enum_values": None, "default_value": "0"})
    shapes["integral"] = tagged("Integer", {"domain": "integral", "minimum": None, "maximum": None, "const_value": None, "enum_values": None, "default_value": None})
    shapes["numeric_default"] = tagged("Product", {"fields": [field("n", "integral_default", False)], "extras": tagged("Reject")})
    shapes["numeric_values"] = tagged("Product", {"fields": [field(f"n{index}", "integral", False) for index in range(len(NUMBER_TEXTS))], "extras": tagged("Reject")})
    shapes["text_wrap"] = tagged("Product", {"fields": [field("empty", "empty")], "extras": tagged("Reject")})
    shapes["decimal"] = tagged("Decimal", {"minimum": None, "maximum": None})
    shapes["decimal_wrap"] = tagged("Product", {"fields": [field("d", "decimal", False)], "extras": tagged("Reject")})
    shapes["integral_decimal_default_ten"] = tagged("Integer", {"domain": "integral", "minimum": None, "maximum": None, "const_value": None, "enum_values": None, "default_value": "10"})
    shapes["integral_decimal_default_one"] = tagged("Integer", {"domain": "integral", "minimum": None, "maximum": None, "const_value": None, "enum_values": None, "default_value": "1"})
    shapes["decimal_text_values"] = tagged("Product", {"fields": [field("ten", "decimal", False), field("one", "decimal", False), field("ten_default", "integral_decimal_default_ten", False), field("one_default", "integral_decimal_default_one", False)], "extras": tagged("Reject")})
    shapes["extras_flag"] = tagged("Product", {"fields": [], "extras": tagged("Allow", fields={"key_format": None, "value": {"type_ref": ref("flag"), "nullable": False}})})
    shapes["bounded_integer"] = tagged("Integer", {"domain": "bounded", "minimum": None, "maximum": None, "const_value": None, "enum_values": None, "default_value": None})
    shapes["bounded_numbers"] = tagged("Product", {"fields": [field("n", "bounded_integer", False)], "extras": tagged("Reject")})
    return {"profile": profile, "source_refs": [], "nodes": [{"reference": ref(name), "shape": shape, "description": None, "attributes": [], "extensions": []} for name, shape in shapes.items()]}


def cases():
    base = graph()
    rows = []
    def add(identity, target, value, *, subject=None, tamper=False, wire=None):
        rows.append({"id": identity, "graph": copy.deepcopy(subject or base), "reference": ref(target), "before": exact(value), "tamper": tamper, **({"wire": wire} if wire is not None else {})})
    add("scalar_defaults", "leaf", {}, tamper=True)
    add("retained_order_null_extras", "leaf", {"2": False, "maybe": None, "flag": True, "1": 0})
    add("explicit_values", "leaf", {"empty": "given", "big": 123, "zero": 9, "flag": True})
    add("invalid_explicit_value", "leaf", {"flag": "invalid"})
    add("nonnull_null", "leaf", {"flag": None})
    add("nested_array", "parent", {"items": [{}, None, {"empty": "given"}], "child": {"maybe": None}})
    add("missing_structures", "parent", {})
    add("null_child", "parent", {"child": None})
    add("root_primitive", "flag", True)
    add("root_alias", "alias", 17)
    add("root_constant", "constant", "fixed")
    add("union_a", "union", {"extra": 0, "kind": "a"})
    add("union_b", "union", {"count": 4, "kind": "b", "extra": False})
    add("absent_tag", "union", {})
    add("unknown_tag", "union", {"kind": "unknown"})
    add("nonstring_tag", "union", {"kind": 0})
    other = copy.deepcopy(base)
    next(node for node in other["nodes"] if node["reference"]["definition_name"] == "union")["shape"]["value"]["branches"][0]["selector"] = tagged("Otherwise")
    add("other_selector", "union", {"kind": "a"}, subject=other)
    member_kind = copy.deepcopy(base)
    member_kind_branches = next(node for node in member_kind["nodes"] if node["reference"]["definition_name"] == "union")["shape"]["value"]["branches"]
    member_kind_branches[0]["selector"] = tagged("MemberShape", [{"key": "extra", "test": tagged("Absent")}])
    member_kind_branches[1]["selector"] = tagged("Kind", tagged("Object"))
    add("member_shape_and_kind_selectors", "union", {"kind": "a"}, subject=member_kind)
    invalid = copy.deepcopy(base)
    next(node for node in invalid["nodes"] if node["reference"]["definition_name"] == "zero")["shape"]["value"]["minimum"] = "1"
    add("invalid_default_root_priority", "leaf", {"flag": "invalid"}, subject=invalid)
    add("unresolved_root", "missing", {})
    add("alias_cycle_fuel", "loop", False)
    recursive = copy.deepcopy(base)
    recursive["nodes"] = [node for node in recursive["nodes"] if node["reference"]["definition_name"] == "recursive"]
    add("finite_recursive_value", "recursive", [[[[]]], []], subject=recursive)
    nonnull_array = copy.deepcopy(base)
    next(node for node in nonnull_array["nodes"] if node["reference"]["definition_name"] == "array")["shape"]["value"]["item"]["nullable"] = False
    add("nonnull_array_null", "array", [None], subject=nonnull_array)
    required_structure = copy.deepcopy(base)
    next(node for node in required_structure["nodes"] if node["reference"]["definition_name"] == "parent")["shape"]["value"]["fields"][0]["slot"]["required"] = True
    add("required_structure_is_not_created", "parent", {}, subject=required_structure)
    rejected = copy.deepcopy(base)
    next(node for node in rejected["nodes"] if node["reference"]["definition_name"] == "leaf")["shape"]["value"]["extras"] = tagged("Reject")
    add("rejected_extras", "leaf", {"extra": False}, subject=rejected)
    missing_constant = copy.deepcopy(base)
    next(node for node in missing_constant["nodes"] if node["reference"]["definition_name"] == "leaf")["shape"]["value"]["fields"][-1]["slot"]["required"] = True
    add("const_does_not_fill", "leaf", {}, subject=missing_constant)
    add("wire_defaults", "leaf", {"maybe": None}, wire='{"maybe":null}')
    add("invalid_wire", "leaf", None, wire="{")
    duplicate = {"tag": "Object", "members": [{"key": "flag", "value": exact(False)}, {"key": "flag", "value": exact(True)}]}
    add("pure_duplicate", "leaf", {})
    rows[-1]["before"] = copy.deepcopy(duplicate)
    add("pure_duplicate_invalid_default_priority", "leaf", {}, subject=invalid)
    rows[-1]["before"] = copy.deepcopy(duplicate)
    add("duplicate_wire", "leaf", {}, wire='{"flag":false,"flag":true}')
    rows[-1]["before"] = copy.deepcopy(duplicate)
    optional_missing = copy.deepcopy(base)
    optional_missing["nodes"] = [{"reference": ref("optional_root"), "shape": tagged("Product", {"fields": [field("optional", "gone", False)], "extras": tagged("Reject")}), "description": None, "attributes": [], "extensions": []}]
    add("optional_missing_meaning", "optional_root", {}, subject=optional_missing)
    unknown_format = copy.deepcopy(base)
    next(node for node in unknown_format["nodes"] if node["reference"]["definition_name"] == "empty")["shape"]["value"]["format"] = tagged("Named", "missing_format")
    add("unknown_format_default_meaning", "leaf", {}, subject=unknown_format)
    residual_before = {"tag": "Object", "members": [{"key": "flag", "value": {"tag": "Bool", "value": True, "extra": 1}}]}
    add("residual_before_member_extra_key", "leaf", {"flag": True})
    rows[-1]["before"] = copy.deepcopy(residual_before)
    add("residual_before_member_unknown_tag", "leaf", {"flag": True})
    rows[-1]["before"] = {"tag": "Object", "members": [{"key": "flag", "value": {"tag": "Bogus"}}]}
    add("residual_before_unknown_root_tag", "leaf", {})
    rows[-1]["before"] = {"tag": "Bogus"}
    nested_profile = copy.deepcopy(base)
    nested_profile["profile"]["numbers"] = {**nested_profile["profile"]["numbers"], "note": 1}
    add("residual_profile_nested_extra_key", "leaf", {}, subject=nested_profile)
    string_order = copy.deepcopy(base)
    next(node for node in string_order["nodes"] if node["reference"]["definition_name"] == "empty")["shape"]["value"]["format"] = tagged("Named")
    next(node for node in string_order["nodes"] if node["reference"]["definition_name"] == "empty")["shape"]["value"]["lengths"] = [{"unit": tagged("Bogus"), "minimum": None, "maximum": None}]
    add("residual_string_spec_field_order", "empty", "", subject=string_order)
    duplicate_reference = copy.deepcopy(base)
    duplicate_reference["nodes"].append({"reference": ref("leaf"), "shape": tagged("Boolean", {"const_value": None, "default_value": True}), "description": None, "attributes": [], "extensions": []})
    add("residual_duplicate_reference_first_node", "leaf", {}, subject=duplicate_reference)
    unresolved_field = copy.deepcopy(base)
    unresolved_field["nodes"] = [node for node in unresolved_field["nodes"] if node["reference"]["definition_name"] != "flag"]
    add("unresolved_nested_field", "leaf", {"flag": True}, subject=unresolved_field)
    rows.append({"id": "missing_graph", "reference": ref("leaf"), "before": exact({}), "tamper": False})
    rows.append({"id": "missing_reference", "graph": copy.deepcopy(base), "before": exact({}), "tamper": False})
    rows.append({"id": "missing_before", "graph": copy.deepcopy(base), "reference": ref("leaf"), "tamper": False})
    rows.append({"id": "missing_tamper", "graph": copy.deepcopy(base), "reference": ref("leaf"), "before": exact({})})
    add_extra_key_cases(add, rows, base)
    add_number_cases(add, rows, base)
    add_decimal_text_cases(add, rows, base)
    add_object_key_cases(add, rows)
    return rows


def add_extra_key_cases(add, rows, base):
    def node(graph, name):
        return next(item for item in graph["nodes"] if item["reference"]["definition_name"] == name)

    def shape(graph, name):
        return node(graph, name)["shape"]

    def row(graph, name):
        return shape(graph, name)["value"]

    def changed(change):
        graph = copy.deepcopy(base)
        change(graph)
        return graph

    def extra(value):
        value["extra"] = 1

    leaf_field = lambda graph: row(graph, "leaf")["fields"][0]
    union_branch = lambda graph: row(graph, "union")["branches"][0]
    allow_fields = lambda graph: row(graph, "leaf")["extras"]["fields"]
    cases = [
        ("graph", "leaf", lambda graph: extra(graph)),
        ("node", "leaf", lambda graph: extra(node(graph, "leaf"))),
        ("node_reference", "leaf", lambda graph: extra(node(graph, "leaf")["reference"])),
        ("node_reference_source", "leaf", lambda graph: extra(node(graph, "leaf")["reference"]["source"])),
        ("node_attribute", "leaf", lambda graph: node(graph, "leaf").update({"attributes": [{"source": ref("leaf")["source"], "pointer": ["attribute"], "extra": 1}]})),
        ("graph_source_ref", "leaf", lambda graph: graph.update({"source_refs": [{**ref("leaf")["source"], "extra": 1}]})),
        ("field", "leaf", lambda graph: extra(leaf_field(graph))),
        ("field_slot", "leaf", lambda graph: extra(leaf_field(graph)["slot"])),
        ("field_slot_type_ref", "leaf", lambda graph: extra(leaf_field(graph)["slot"]["type_ref"])),
        ("field_origin", "leaf", lambda graph: extra(leaf_field(graph)["origin"])),
        ("extras_allow", "leaf", lambda graph: extra(row(graph, "leaf")["extras"])),
        ("extras_allow_fields", "leaf", lambda graph: extra(allow_fields(graph))),
        ("extras_allow_element", "leaf", lambda graph: extra(allow_fields(graph)["value"])),
        ("extras_reject", "leaf", lambda graph: row(graph, "leaf").update({"extras": {"tag": "Reject", "extra": 1}})),
        ("array_item_element", "array", lambda graph: extra(row(graph, "array")["item"])),
        ("branch", "union", lambda graph: extra(union_branch(graph))),
        ("branch_target", "union", lambda graph: extra(union_branch(graph)["target"])),
        ("branch_origin", "union", lambda graph: extra(union_branch(graph)["origin"])),
        ("shape_boolean", "flag", lambda graph: extra(shape(graph, "flag"))),
        ("shape_integer", "zero", lambda graph: extra(shape(graph, "zero"))),
        ("shape_string", "empty", lambda graph: extra(shape(graph, "empty"))),
        ("shape_unknown", "any", lambda graph: extra(shape(graph, "any"))),
        ("shape_alias", "alias", lambda graph: extra(shape(graph, "alias"))),
        ("shape_alias_fields", "alias", lambda graph: extra(shape(graph, "alias")["fields"])),
        ("shape_alias_target", "alias", lambda graph: extra(shape(graph, "alias")["fields"]["target"])),
        ("shape_array", "array", lambda graph: extra(shape(graph, "array"))),
        ("shape_array_row", "array", lambda graph: extra(row(graph, "array"))),
        ("shape_product", "leaf", lambda graph: extra(shape(graph, "leaf"))),
        ("shape_product_row", "leaf", lambda graph: extra(row(graph, "leaf"))),
        ("shape_tagged_union", "union", lambda graph: extra(shape(graph, "union"))),
        ("shape_tagged_union_row", "union", lambda graph: extra(row(graph, "union"))),
        ("shape_unit", "unit", lambda graph: graph["nodes"].append({"reference": ref("unit"), "shape": {"tag": "Unit", "extra": 1}, "description": None, "attributes": [], "extensions": []})),
        ("shape_never", "never", lambda graph: graph["nodes"].append({"reference": ref("never"), "shape": {"tag": "Never", "extra": 1}, "description": None, "attributes": [], "extensions": []})),
    ]
    for identity, target, change in cases:
        add("extra_key_" + identity, target, {}, subject=changed(change))
    add("extra_key_request_reference", "leaf", {})
    rows[-1]["reference"]["extra"] = 1
    add_shape_tag_cases(add, base)


def add_shape_tag_cases(add, base):
    def appended(shape):
        graph = copy.deepcopy(base)
        graph["nodes"].append({"reference": ref("bogus"), "shape": shape, "description": None, "attributes": [], "extensions": []})
        return graph
    add("unknown_tag_shape", "leaf", {}, subject=appended({"tag": "Bogus"}))
    add("unknown_tag_shape_with_extra_key", "leaf", {}, subject=appended({"tag": "Bogus", "extra": 1}))
    add("unknown_kind_tag_with_extra_key", "leaf", {}, subject=appended({"tag": "Unknown", "value": {"tag": "Bogus", "extra": 1}}))


def add_number_cases(add, rows, base):
    limited = ("1e10000", "1e-10000")

    def decimal(text):
        return {"tag": "Decimal", "text": text}

    def object_of(members):
        return {"tag": "Object", "members": [{"key": key, "value": value} for key, value in members]}

    add("integral_default_zero", "numeric_default", {})
    for index, text in enumerate(NUMBER_TEXTS):
        add(f"integral_string_{index}", "numeric_values", {})
        rows[-1]["before"] = object_of([(f"n{index}", {"tag": "String", "value": text})])
    for index, text in enumerate(NUMBER_TEXTS):
        add(f"decimal_value_{index}", "decimal_wrap", {})
        rows[-1]["before"] = object_of([("d", decimal(text))])
    explicit = object_of([(f"n{index}", decimal(text)) for index, text in enumerate(NUMBER_TEXTS) if text not in limited])
    add("numeric_values_explicit", "numeric_values", {})
    rows[-1]["before"] = explicit
    wire_texts = [text for text in NUMBER_TEXTS if text not in limited]
    wire_numbers = ",".join(f'"n{index}":{text}' for index, text in enumerate(NUMBER_TEXTS) if text in wire_texts)
    add("numeric_values_wire", "numeric_values", {}, wire="{" + wire_numbers + "}")
    wire_reading = {"0": {"tag": "Integer", "value": "0"}, "0.0": decimal("0"), "-0.0": decimal("0"), "0e-100": decimal("0"), "0.000e-100": decimal("0"), "0e11": {"tag": "Integer", "value": "0"}, "1e1": {"tag": "Integer", "value": "10"}, "1e9999": {"tag": "Integer", "value": "1" + "0" * 9999}}
    rows[-1]["before"] = object_of([(f"n{index}", wire_reading[text]) for index, text in enumerate(NUMBER_TEXTS) if text in wire_texts])
    bad_spec = copy.deepcopy(base)
    bad_spec["nodes"].append({"reference": ref("bad_decimal"), "shape": tagged("Decimal", {"minimum": None, "maximum": None, "extra": 1}), "description": None, "attributes": [], "extensions": []})
    add("decimal_spec_unknown_field", "leaf", {}, subject=bad_spec)
    add("wire_exponent_limit", "numeric_values", {}, wire='{"n8":1e10000}')
    rows[-1]["before"] = object_of([("n8", {"tag": "Integer", "value": "1" + "0" * 10000})])
    add("wire_negative_exponent_limit", "numeric_values", {}, wire='{"n9":1e-10000}')
    rows[-1]["before"] = object_of([("n9", decimal("0." + "0" * 9999 + "1"))])
    add("wire_lone_surrogate", "text_wrap", {}, wire='{"empty":"\\uD800"}')
    rows[-1]["before"] = object_of([("empty", {"tag": "String", "value": "\ufffd"})])
    add("wire_surrogate_pair", "text_wrap", {}, wire='{"empty":"\\uD83D\\uDE00"}')
    rows[-1]["before"] = object_of([("empty", {"tag": "String", "value": "\U0001F600"})])


def add_decimal_text_cases(add, rows, base):
    def decimal(text):
        return {"tag": "Decimal", "text": text}

    def object_of(members):
        return {"tag": "Object", "members": [{"key": key, "value": value} for key, value in members]}

    add("decimal_text_defaults_absent", "decimal_text_values", {})
    add("decimal_text_wire", "decimal_text_values", {}, wire='{"ten":10.0,"one":1.0,"ten_default":1.0}')
    rows[-1]["before"] = object_of([("ten", decimal("10.0")), ("one", decimal("1.0")), ("ten_default", decimal("1.0"))])
    add("decimal_text_duplicate_wire", "decimal_text_values", {}, wire='{"ten":10.0,"ten":1.0}')
    add("decimal_text_nested_duplicate_wire", "parent", {}, wire='{"child":{"flag":true,"flag":false}}')
    add("decimal_text_escaped_duplicate_wire", "leaf", {}, wire='{"flag":true,"\\u0066lag":false}')


def add_object_key_cases(add, rows):
    def decimal(text):
        return {"tag": "Decimal", "text": text}

    def object_of(members):
        return {"tag": "Object", "members": [{"key": key, "value": value} for key, value in members]}

    for identity, members in (
        ("object_two_failing_keys_document_order", [("b", decimal("1.5")), ("a", decimal("2.5"))]),
        ("object_two_failing_keys_key_order", [("a", decimal("2.5")), ("b", decimal("1.5"))]),
        ("object_three_failing_keys_document_order", [("c", decimal("3.5")), ("a", decimal("2.5")), ("b", decimal("1.5"))]),
    ):
        add(identity, "extras_flag", {})
        rows[-1]["before"] = object_of(members)
    add("object_two_failing_keys_wire_document_order", "extras_flag", {}, wire='{"b":1.5,"a":2.5}')
    rows[-1]["before"] = object_of([("b", decimal("1.5")), ("a", decimal("2.5"))])
    for identity, text in (("maximum", "1e10000"), ("minimum", "1e-10000"), ("long", "1e" + "1" * 5000)):
        add("bounded_decimal_string_" + identity, "bounded_numbers", {})
        rows[-1]["before"] = object_of([("n", {"tag": "String", "value": text})])
