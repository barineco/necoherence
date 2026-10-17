# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

import copy


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
    profile = {"reference": profile_ref, "source_refs": [], "integer_domains": [{"name": "integer", "reference": profile_ref, "range": tagged("Unbounded"), "forms": [tagged("Number")]}], "default_integer_domain": "integer", "numbers": {"decimals": True}, "grapheme_rules": None, "format_bindings": [], "bytes_policy": None, "wrappers": [], "tag": {"key": "kind", "format": None, "sealed": []}}
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
    return rows
