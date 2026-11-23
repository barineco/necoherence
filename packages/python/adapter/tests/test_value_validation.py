# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

import pytest

from test_recursive_values import array, context, node, product, union

from necoherence.signature_values import path_steps_json


def _raw(result):
    return None if result is None else (path_steps_json(result[0]), *result[1:])
from necoherence.signature_values import (
    INVALID_DATA_MODEL,
    MISSING_REQUIRED,
    NO_BRANCH_SELECTED,
    ARRAY_LENGTH,
    ExpansionRejected,
    ExpansionRequirements,
    ExpansionUnresolved,
    MemberProof,
    MembershipAccepted,
    MembershipUnresolved,
    ValidatedValue,
    ValidationCertificateMismatch,
    MeaningFailure,
    ValueContext,
    wrong_value_kind,
    variant,
)
from necoherence import signature_values as sv
from necoherence.type_signatures import _graph


def boolean():
    return variant("Boolean", {"const_value": None})


def build():
    return ValueContext(_graph({"profile": {"reference": {"identity": "test", "revision": "1", "content_digest": "0" * 64}, "tag": {"key": "kind", "format": None, "sealed": []}}, "nodes": [
            node("Bool", boolean()),
            node("Never", variant("Never")),
            node("Unit", variant("Unit")),
            node("Opaque", variant("Opaque", {"type_name": "external"})),
            node("Pair", product([("a", "Bool")])),
            node("Items", variant("Array", {"item": {"type_id": "Bool", "nullable": False}, "min_length": "1", "max_length": None})),
            node("Choice", union([("only", "Pair")])),
        ], "definitions": []}))


def rejected(ctx, name, value, path=()):
    expansion = ctx.expand_value(ctx.reference(name), path, value)
    assert isinstance(expansion, ExpansionRejected)
    return expansion.failure


def test_expansion_rejects_each_shape_with_the_lean_condition() -> None:
    ctx = build()
    assert rejected(ctx, "Never", None).condition == INVALID_DATA_MODEL
    assert rejected(ctx, "Unit", 1).condition == wrong_value_kind("unit")
    assert rejected(ctx, "Bool", 1).condition == wrong_value_kind("boolean")
    assert rejected(ctx, "Pair", []).condition == wrong_value_kind("object")
    assert rejected(ctx, "Items", []).condition == ARRAY_LENGTH
    assert rejected(ctx, "Items", {}).condition == wrong_value_kind("array")
    assert rejected(ctx, "Choice", {"kind": "other"}).condition == NO_BRANCH_SELECTED
    missing = rejected(ctx, "Pair", {})
    assert missing.condition == MISSING_REQUIRED
    assert path_steps_json(missing.value_path) == list(("a",))


def test_expansion_reports_children_and_unresolved_nodes() -> None:
    ctx = build()
    children = ctx.expand_value(ctx.reference("Pair"), (), {"a": True})
    assert isinstance(children, ExpansionRequirements)
    assert [(path_steps_json(child.value_path), child.value) for child in children.children] == [(["a"], True)]
    assert isinstance(ctx.expand_value(ctx.reference("Opaque"), (), 1), ExpansionUnresolved)
    assert isinstance(ctx.expand_node(ctx.reference("Bool"), (), True, None), ExpansionUnresolved)


def test_membership_checks_fuel_and_certificate_children() -> None:
    ctx = build()
    reference = ctx.reference("Pair")
    assert isinstance(ctx.check_value_fuel(0, (), reference, (), {"a": True}, None), MembershipUnresolved)
    checked = ctx.validate_value(reference, {"a": True})
    assert isinstance(checked, ValidatedValue)
    assert checked.proof == MemberProof((MemberProof(()),))
    assert isinstance(ctx.check_value_fuel(8, (), reference, (), {"a": True}, checked.proof), MembershipAccepted)
    assert ctx.validate_value(reference, {"a": True}, MemberProof(())) == ValidationCertificateMismatch(
        "missing membership children"
    )
    assert ctx.validate_value(
        reference, {"a": True}, MemberProof((MemberProof(()), MemberProof(())))
    ) == ValidationCertificateMismatch("extra membership children")


def test_array_children_are_requested_in_index_order() -> None:
    ctx = context([node("Bool", boolean()), node("List", array("Bool"))])
    expansion = ctx.expand_value(ctx.reference("List"), (), [True, False])
    assert isinstance(expansion, ExpansionRequirements)
    assert [path_steps_json(child.value_path) for child in expansion.children] == [[0], [1]]


from necoherence import semantic_composition as sc
from necoherence import signature_values as sv
from necoherence.type_signatures import _graph


def integer_profile(forms=("Number",), low="0", high="10"):
    return {
        "default_integer_domain": "i",
        "integer_domains": [
            {
                "name": "i",
                "forms": [variant(form) for form in forms],
                "range": variant("Inclusive", {"minimum": low, "maximum": high}),
            }
        ],
    }


def integer_spec(**changes):
    return {"domain": None, "const_value": None, "enum_values": None, "minimum": None, "maximum": None, **changes}


def test_integer_condition_follows_each_lean_branch() -> None:
    profile = integer_profile(("Number", "IntegralDecimal", "DecimalString"))
    spec = integer_spec()
    assert sv.integer_condition({}, spec, 1) == sv.INTEGER_DOMAIN
    assert sv.integer_condition(profile, spec, "x") == wrong_value_kind("integer")
    assert sv.integer_condition(profile, spec, 11) == sv.INTEGER_DOMAIN
    assert sv.integer_condition(profile, integer_spec(const_value="3"), 4) == sv.CONST_MISMATCH
    assert sv.integer_condition(profile, integer_spec(enum_values=["3"]), 4) == sv.ENUM_MISMATCH
    assert sv.integer_condition(profile, integer_spec(minimum="5"), 4) == sv.BELOW_MINIMUM
    assert sv.integer_condition(profile, integer_spec(maximum="5"), 6) == sv.ABOVE_MAXIMUM
    assert sv.integer_condition(profile, spec, sv.DecimalLiteral("4.0")) is None
    assert sv.integer_condition(profile, spec, sv.DecimalLiteral("4.5")) == wrong_value_kind("integer")
    assert sv.integer_condition(profile, spec, "4") is None
    assert sv.integer_condition(profile, spec, " 4") == wrong_value_kind("integer")
    assert sv.integer_condition(profile, spec, sv.DecimalLiteral("1e999999")) == sv.INTEGER_DOMAIN
    assert sv.integer_condition(profile, spec, "+4") == wrong_value_kind("integer")


def test_decimal_bounds_compare_mathematical_values() -> None:
    bound = {"mantissa": "10", "scale": "1", "exclusive": False}
    spec = {"minimum": bound, "maximum": None}
    assert sv.decimal_condition(spec, "1") is None
    assert sv.decimal_condition(spec, "1.00") is None
    assert sv.decimal_condition(spec, "0.9") == sv.BELOW_MINIMUM
    assert sv.decimal_condition({"minimum": {**bound, "exclusive": True}, "maximum": None}, "1.0") == sv.BELOW_MINIMUM
    assert sv.decimal_condition({"minimum": None, "maximum": {**bound, "exclusive": True}}, "1e0") == sv.ABOVE_MAXIMUM
    assert sv.decimal_condition(spec, "01") == INVALID_DATA_MODEL


def test_decimal_maximum_is_checked_after_minimum_passes() -> None:
    lower = {"mantissa": "5", "scale": "0", "exclusive": False}
    upper = {"mantissa": "5", "scale": "0", "exclusive": True}
    assert sv.decimal_condition({"minimum": lower, "maximum": upper}, "5") == sv.ABOVE_MAXIMUM
    assert sv.decimal_condition({"minimum": lower, "maximum": {**upper, "exclusive": False}}, "5") is None
    assert sv.decimal_condition({"minimum": lower, "maximum": upper}, "4.99") == sv.BELOW_MINIMUM


def string_spec(**changes):
    return {"wrapper": None, "const_value": None, "enum_values": None, "lengths": [], "format": None, **changes}


def test_string_conditions_follow_each_lean_branch() -> None:
    profile = {"format_bindings": [{"name": "digits", "rule": variant("Text")}]}
    assert sv.string_condition(profile, string_spec(), "\ud800") == INVALID_DATA_MODEL
    assert sv.string_condition(profile, string_spec(const_value="a"), "b") == sv.CONST_MISMATCH
    assert sv.string_condition(profile, string_spec(enum_values=["a"]), "b") == sv.ENUM_MISMATCH
    bound = {"unit": variant("Utf8Bytes"), "minimum": "2", "maximum": None}
    assert sv.string_condition(profile, string_spec(lengths=[bound]), "a") == sv.STRING_LENGTH
    graphemes = {"unit": variant("Graphemes"), "minimum": None, "maximum": None}
    assert sv.string_condition(profile, string_spec(lengths=[graphemes]), "a") == sv.STRING_LENGTH
    assert sv.string_condition(profile, string_spec(format=variant("Named", "missing")), "a") is None
    assert sv.sealed_string_condition(profile, string_spec(format=variant("Named", "missing")), "a") == sv.format_condition("missing")
    assert sv.string_condition(profile, string_spec(format=variant("Inline", variant("Not", variant("Text")))), "a") == sv.format_condition("inline")
    assert sv.string_value_condition(profile, string_spec(), 1) == wrong_value_kind("string")
    assert sv.string_value_condition(profile, string_spec(wrapper="w"), "a") == wrong_value_kind("string wrapper")


WRAPPER_BYTES_POLICY = {"alphabet": variant("Standard"), "strict_pad_bits": True, "padding_optional": False, "wrapper": "b"}

WRAPPER_PROFILE = {
    "wrappers": [{"name": "w", "key": "$w", "payload": variant("Text", None)}, {"name": "b", "key": "$b", "payload": variant("Bytes")}],
    "bytes_policy": WRAPPER_BYTES_POLICY,
    "tag": {"key": "kind", "format": None, "sealed": []},
}


def test_wrapper_and_bytes_helpers_follow_lean() -> None:
    profile = WRAPPER_PROFILE
    text, raw = profile["wrappers"]
    assert sv.wrapper_payload_text(profile, text, {"$w": "x"}) == "x"
    assert sv.wrapper_payload_text(profile, text, {"$w": "x", "y": 1}) is None
    assert sv.wrapper_payload_failure(profile, text, {"$w": 1}) == wrong_value_kind("wrapper text")
    assert sv.wrapper_payload_failure(profile, raw, {"$b": "!"}) == sv.INVALID_BYTES
    assert sv.wrapper_payload_failure(profile, raw, {"$b": "YQ=="}) is None
    assert sv.bytes_value_length(profile, {"$b": "YWJj"}) == 3
    assert sv.bytes_value_length(profile, "YWJj") is None
    assert sv.bytes_value_length({}, "YWJj") is None
    policy: dict[str, object] = {**WRAPPER_BYTES_POLICY}
    assert sv.base64_length(policy, "YQ=") is None
    assert sv.base64_length(policy, "YR==") is None
    assert sv.base64_length(policy, "YQ") is None
    assert sv.base64_length({**policy, "padding_optional": True}, "YQ") == 1
    assert sv.base64_length(policy, "Y") is None


def test_sealed_and_data_helpers_follow_lean() -> None:
    form = {
        "tag": "sealed",
        "fields": [
            {"key": "label", "required": True, "leaf": variant("String", string_spec())},
            {"key": "count", "required": False, "leaf": variant("Integer", integer_spec())},
        ],
        "extras": variant("Reject"),
    }
    profile = {**WRAPPER_PROFILE, **integer_profile(), "tag": {"key": "kind", "format": None, "sealed": [form]}}
    members = {"kind": "sealed", "label": "x"}
    assert sv.classOf(profile, members) == ("Sealed", form)
    assert sv.sealed_fields_failure(profile, form, {"kind": "sealed"}) == ("label", sv.MISSING_REQUIRED, None)
    assert sv.sealed_fields_failure(profile, form, {**members, "count": "1"}) == ("count", wrong_value_kind("integer"), "1")
    assert sv.sealed_fields_failure(profile, form, {**members, "label": 1}) == ("label", wrong_value_kind("string"), 1)
    assert sv.sealed_fields_failure(profile, form, {**members, "count": 3}) is None
    sealed_context = sv.ValueContext(_graph({"profile": profile, "nodes": [node("S", variant("Sealed", {"tag": "sealed", "refinements": []}))], "definitions": []}))
    failure = rejected(sealed_context, "S", {**members, "extra": 1})
    assert (path_steps_json(failure.value_path), failure.condition, failure.observed.value) == (["extra"], sv.unexpected_field("extra"), 1)
    refinement = {"key": "label", "leaf": variant("String", string_spec(const_value="y"))}
    assert sv.sealed_refinement_failure(profile, members, [refinement]) == ("label", sv.CONST_MISMATCH, "x")
    assert sv.tag_member_failure(profile, {"kind": 1}) == ("kind", sv.INVALID_TAG, 1)
    assert sv.tag_member_failure(profile, {"kind": "\ud800"}) == ("kind", INVALID_DATA_MODEL, "\ud800")
    assert sv.object_member_failure(profile, sv.JsonObject([("a", 1), ("a", 2)]))[1] == sv.duplicate_field("a")
    assert _raw(sv.data_value_failure(profile, (), {"a": ["\ud800"]})) == (["a", 0], INVALID_DATA_MODEL, "\ud800")
    assert _raw(sv.data_value_failure(profile, (), 11)) == ([], sv.INTEGER_DOMAIN, 11)
    assert _raw(sv.data_value_failure(profile, (), {"$w": 1})) == ([], wrong_value_kind("wrapper text"), {"$w": 1})
    assert _raw(sv.data_value_failure(profile, (), {**members, "extra": 1})) == (["extra"], sv.unexpected_field("extra"), 1)


def test_sealed_expansion_rejects_unknown_members_before_refinements() -> None:
    form = {"tag": "sealed", "fields": [], "extras": variant("Reject")}
    profile = {"reference": {"identity": "p", "revision": "1", "content_digest": "0" * 64}, "tag": {"key": "kind", "format": None, "sealed": [form]}}
    refinement = {"key": "kind", "leaf": variant("String", string_spec(const_value="y"))}
    ctx = sv.ValueContext(_graph({"profile": profile, "nodes": [node("S", variant("Sealed", {"tag": "sealed", "refinements": [refinement]}))], "definitions": []}))
    failure = rejected(ctx, "S", {"kind": "sealed", "extra": 1})
    assert failure.condition == sv.unexpected_field("extra")
    assert path_steps_json(failure.value_path) == list(("extra",))


def certificate_fixture():
    ctx = build()
    graph = ctx.graph
    slot = sc.SlotContract(sc.TypeRef(ctx.reference("Pair")["source"], "Pair", ()), True, False)
    value = sc.PresentValue({"a": True})
    checked = sc.validate_slot(ctx, slot, value)
    assert isinstance(checked, sc.ValidatedSlot)
    return graph, slot, value, checked.certificate


def test_value_derivation_rejects_a_value_outside_the_contract_with_a_proof() -> None:
    ctx = build()
    reference = ctx.reference("Pair")
    checked = ctx.validate_value(reference, {"a": True})
    assert isinstance(checked, ValidatedValue)
    assert isinstance(ctx.validate_value(reference, {"a": 1}, checked.proof), sv.ValidationValueFailure)
    graph, slot, _, _ = certificate_fixture()
    optional = sc.SlotContract(slot.type_ref, False, True)
    assert isinstance(sc.validate_slot(sv.ValueContext(graph), optional, sc.ABSENT_VALUE), sc.ValidatedSlot)


def test_validated_results_are_constructed_only_by_their_check_functions() -> None:
    with pytest.raises(TypeError):
        ValidatedValue(object(), MemberProof(()))
    _, _, _, certificate = certificate_fixture()
    with pytest.raises(TypeError):
        sc.ValidatedSlot(object(), certificate)


def test_source_revisions_are_read_from_the_graph_top_level() -> None:
    graph, slot, value, _ = certificate_fixture()
    source = {"repository": "r", "revision": "1", "path": "p", "content_digest": "0" * 64}
    identity = {"repository": "r", "revision": "0", "path": "q", "content_digest": "1" * 64}
    revised = {**graph, "source_refs": [source], "profile": {**graph["profile"], "source_refs": [identity]}}
    assert sc.SemanticBasis.of(revised).sources == (source,)
    checked = sc.validate_slot(sv.ValueContext(revised), slot, value)
    assert isinstance(checked, sc.ValidatedSlot)
    assert checked.certificate.source_refs == (source,)
    projection = sc.project_slot(slot, (), (), sv.ValueContext(revised))
    assert isinstance(projection, sc.ProjectionCertificate)
    assert projection.source_refs == (source,)


def test_integer_binding_resolves_named_and_default_domains_as_lean() -> None:
    profile = _meaning_profile()
    domain = profile["integer_domains"][0]
    assert sv.integer_binding(profile, None) == domain
    assert sv.integer_binding(profile, "main") == domain
    assert sv.integer_binding(profile, "missing") is None


def _meaning_profile():
    return {
        "reference": {"identity": "profile", "revision": "1", "content_digest": "a" * 64},
        "source_refs": [],
        "integer_domains": [{"name": "main", "reference": {"identity": "profile", "revision": "1", "content_digest": "a" * 64},
                             "range": variant("Unbounded"), "forms": [variant("Number")]}],
        "default_integer_domain": "main",
        "numbers": {"decimals": False},
        "grapheme_rules": None,
        "format_bindings": [],
        "bytes_policy": None,
        "wrappers": [],
        "tag": None,
    }


def test_unknown_integer_domain_returns_mo04_at_the_node_path() -> None:
    shape = variant("Integer", {"domain": "", "const_value": None, "enum_values": None,
                                "minimum": None, "maximum": None, "default_value": None})
    context = ValueContext(_graph({"profile": _meaning_profile(), "nodes": [{"id": "count", "shape": shape}], "definitions": []}))
    with pytest.raises(MeaningFailure) as caught:
        context.check_meaning("count")
    assert (caught.value.predicate, caught.value.type_ref["definition_name"], caught.value.location) == ("MO04", "count", ())


def test_allowed_extras_type_is_a_meaning_child_of_the_product() -> None:
    bag = variant("Product", {"fields": [], "extras": variant("Allow", fields={"key_format": None, "value": {"type_id": "odd", "nullable": False}})})
    odd = variant("Integer", {"domain": "missing", "const_value": None, "enum_values": None,
                              "minimum": None, "maximum": None, "default_value": None})
    context = ValueContext(_graph({"profile": _meaning_profile(), "nodes": [{"id": "bag", "shape": bag}, {"id": "odd", "shape": odd}], "definitions": []}))
    with pytest.raises(MeaningFailure) as caught:
        context.check_meaning("bag")
    assert (caught.value.predicate, caught.value.type_ref["definition_name"]) == ("MO04", "odd")


def test_grapheme_property_takes_the_first_declared_range() -> None:
    rows = [{"first": "0", "last": "100", "property": variant("L")}, {"first": "65", "last": "66", "property": variant("V")}]
    assert sv._table_property(sv._grapheme_table(rows), 65) == "L"


def test_a_decimal_exponent_longer_than_the_integer_digit_limit_is_compared_as_digits() -> None:
    long_exponent = "1" * 5000
    assert sv.decimal_magnitude_exceeds_range_digits(0, 10, f"1e{long_exponent}")
    assert not sv.decimal_magnitude_exceeds_range_digits(0, 10, f"0e{long_exponent}")
    assert sv.integer_condition(integer_profile(("DecimalString",)), integer_spec(), f"1e{long_exponent}") == sv.INTEGER_DOMAIN


def test_wire_object_members_are_checked_in_key_order_as_lean_parses_them() -> None:
    profile = {**WRAPPER_PROFILE, **integer_profile()}
    assert _raw(sv.data_value_failure(profile, (), sv.exact_from_json(sv.decode_wire_json('{"zeta":11,"alpha":12}')))) == (["alpha"], sv.INTEGER_DOMAIN, 12)


def test_exact_object_members_are_checked_in_document_order_as_lean_lists_are() -> None:
    profile = {**WRAPPER_PROFILE, **integer_profile()}
    assert _raw(sv.data_value_failure(profile, (), sv.JsonObject([("zeta", 11), ("alpha", 12)]))) == (["zeta"], sv.INTEGER_DOMAIN, 11)
