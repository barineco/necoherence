# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Regression checks for the composition wire against the Lean `get`, `payload`, `fields`, and `liftJson` reads."""

from types import SimpleNamespace
from typing import Any, cast

import pytest

from necoherence import typed_mapping as mapping
from necoherence.composition_wire_base import decode_producer, wire_sum
from necoherence.semantic_composition import (
    InvocationOutcomeProducer,
    PresentAssumption,
    SiteId,
    VariantAssumption,
)
from necoherence.signature_composition_wire import _Context, _decode_assumption, _decode_binding, _decode_field_constraint, _decode_initial_input, _decode_input_port, _decode_outcome, _decode_return, _decode_search_bounds, _decode_tree
from necoherence.signature_values import WireFailure

CONTEXT = _Context({}, {"nodes": []}, {})
SLOT = {"type_id": "text", "required": True, "nullable": False}


def _failure(action) -> tuple[str, str, object]:
    with pytest.raises(WireFailure) as caught:
        action()
    return caught.value.kind, caught.value.path, caught.value.observed


def test_sum_tag_missing_is_a_property_failure_at_the_tag_path() -> None:
    assert _failure(lambda: wire_sum({"value": 1}, {"Present": "value"}, "$.x")) == (
        "Syntax", "$.x.tag", "property not found: tag",
    )


def test_sum_tag_on_a_non_object_is_reported_at_the_tag_path() -> None:
    assert _failure(lambda: wire_sum(["Present"], {"Present": "value"}, "$")) == ("Syntax", "$.tag", "object expected")


def test_sum_tag_that_is_not_a_string_uses_the_string_message() -> None:
    assert _failure(lambda: wire_sum({"tag": 1}, {"Present": "value"}, "$")) == ("Syntax", "$.tag", "String expected")


def test_producer_outcome_fields_are_a_closed_record() -> None:
    assert _failure(lambda: decode_producer(
        {"tag": "InvocationOutcome", "fields": {"site": "s", "outcome": "o", "port": "p", "extra": True}}, "$",
    )) == ("UnknownField", "$.extra", "extra")
    producer = decode_producer({"tag": "InvocationOutcome", "fields": {"site": "s", "outcome": "o", "port": "p"}}, "$")
    assert isinstance(producer, InvocationOutcomeProducer)
    assert (producer.site.value, producer.outcome.value, producer.port.value) == ("s", "o", "p")


def test_producer_outcome_missing_field_is_a_missing_field_failure_at_the_field_path() -> None:
    assert _failure(lambda: decode_producer({"tag": "InvocationOutcome", "fields": {"site": "s", "outcome": "o"}}, "$")) == (
        "Syntax", "$.port", "missing field",
    )


def test_producer_outcome_fields_that_are_not_an_object_fail_at_the_frame_path() -> None:
    assert _failure(lambda: decode_producer({"tag": "InvocationOutcome", "fields": "x"}, "$")) == (
        "Syntax", "$", "object expected",
    )


def test_assumption_variant_fields_are_a_closed_record() -> None:
    assert _failure(lambda: _decode_assumption({"tag": "Variant", "fields": {"path": [], "tag": "t", "extra": 1}}, "$")) == (
        "UnknownField", "$.extra", "extra",
    )
    assert _decode_assumption({"tag": "Variant", "fields": {"path": [], "tag": "t"}}, "$") == VariantAssumption((), "t")


def test_assumption_variant_missing_tag_is_a_missing_field_failure() -> None:
    assert _failure(lambda: _decode_assumption({"tag": "Variant", "fields": {"path": []}}, "$.a")) == (
        "Syntax", "$.a.tag", "missing field",
    )


def test_assumption_index_present_missing_index_is_a_missing_field_failure() -> None:
    assert _failure(lambda: _decode_assumption({"tag": "IndexPresent", "fields": {"path": []}}, "$")) == (
        "Syntax", "$.index", "missing field",
    )


def test_assumption_present_is_a_closed_payload() -> None:
    assert _failure(lambda: _decode_assumption({"tag": "Present", "value": [], "extra": 1}, "$")) == (
        "UnknownField", "$.extra", "extra",
    )
    assert _decode_assumption({"tag": "Present", "value": []}, "$") == PresentAssumption(())


def test_binding_with_an_unknown_tag_is_an_unknown_tag_failure() -> None:
    assert _failure(lambda: _decode_binding(CONTEXT, {"tag": "Other", "fields": {}}, "$")) == (
        "UnknownTag", "$.tag", "Other",
    )


def test_binding_source_compatibility_fields_are_a_closed_record() -> None:
    value = {"tag": "Source", "fields": {"value": {}, "projection": {}, "compatibility": {
        "tag": "SuppliedValue", "fields": {"value": {"tag": "Absent"}, "extra": 1},
    }}}
    assert _failure(lambda: _decode_binding(CONTEXT, value, "$")) == ("UnknownField", "$.extra", "extra")


def test_binding_source_compatibility_with_an_unknown_tag_is_an_unknown_tag_failure() -> None:
    value = {"tag": "Source", "fields": {"value": {}, "projection": {}, "compatibility": {"tag": "Other"}}}
    assert _failure(lambda: _decode_binding(CONTEXT, value, "$")) == ("UnknownTag", "$.tag", "Other")


def test_binding_product_reads_the_fields_pairs_before_the_construction() -> None:
    assert _failure(lambda: _decode_binding(
        CONTEXT, {"tag": "Product", "fields": {"construction": "c", "type_id": "t", "fields": [["x"]]}}, "$",
    )) == ("Syntax", "$", "construction field pair size")
    assert _failure(lambda: _decode_binding(CONTEXT, {"tag": "Product", "fields": {"fields": []}}, "$")) == (
        "Syntax", "$.construction", "missing field",
    )


def test_return_unknown_tag_is_an_unknown_tag_failure() -> None:
    assert _failure(lambda: _decode_return(CONTEXT, {"tag": "Other"}, "$")) == ("UnknownTag", "$.tag", "Other")


def test_return_success_pair_size_uses_the_output_message() -> None:
    assert _failure(lambda: _decode_return(CONTEXT, {"tag": "Success", "value": [["x"]]}, "$")) == (
        "Syntax", "$", "output pair size",
    )


def test_return_failure_fields_are_a_closed_record() -> None:
    value = {"tag": "Failure", "fields": {"embedding": "e", "value": {}, "extra": 1}}
    assert _failure(lambda: _decode_return(CONTEXT, value, "$")) == ("UnknownField", "$.extra", "extra")


def test_tree_with_an_unknown_node_is_an_unknown_tag_failure() -> None:
    assert _failure(lambda: _decode_tree(CONTEXT, {"rank": "0", "node": {"tag": "X"}}, "$")) == (
        "UnknownTag", "$.tag", "X",
    )


def test_initial_input_reads_the_id_before_the_source() -> None:
    value = {"id": 1, "contract": SLOT, "source": {"tag": "Other"}, "resource": None}
    assert _failure(lambda: _decode_initial_input(value, "$")) == ("Syntax", "$.id", "String expected")


def test_input_port_reads_the_id_before_the_source_constraint() -> None:
    value = {"id": 1, "contract": SLOT, "source_constraint": {"tag": "Other"}, "resource_requirement": None}
    assert _failure(lambda: _decode_input_port(value, "$")) == ("Syntax", "$.id", "String expected")


def test_field_constraint_reads_the_field_before_the_source_and_presence() -> None:
    value = {"field": 1, "source": {"tag": "Other"}, "presence": {"tag": "Required"}}
    assert _failure(lambda: _decode_field_constraint(value, "$")) == ("Syntax", "$.field", "String expected")


def test_outcome_reads_the_cause_before_the_id() -> None:
    value = {"id": 1, "form": {"tag": "Other"}, "cause": {}, "value_ports": [], "produced_resources": []}
    assert _failure(lambda: _decode_outcome(value, "$")) == ("Syntax", "$.cause.tag", "property not found: tag")


def test_outcome_reads_the_id_before_the_form() -> None:
    cause = {"tag": "ValueContract", "fields": {"origin": {"source": {"repository": "r", "revision": "1", "path": "p", "content_digest": "d"}, "locator": []}}}
    value = {"id": 1, "form": {"tag": "Other"}, "cause": cause, "value_ports": [], "produced_resources": []}
    assert _failure(lambda: _decode_outcome(value, "$")) == ("Syntax", "$.id", "String expected")


def test_search_bounds_reads_the_resource_bounds_before_the_sample_length() -> None:
    value = {
        "max_expanded_states": "1",
        "max_binding_candidates": "1",
        "max_type_obligations": "1",
        "max_branch_nodes": "1",
        "resource_bounds": "x",
        "max_sample_length": "y",
    }
    assert _failure(lambda: _decode_search_bounds(value, "$")) == ("Syntax", "$.resource_bounds", "object expected")


