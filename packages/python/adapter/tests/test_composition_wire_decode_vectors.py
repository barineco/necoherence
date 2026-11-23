# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

from typing import Any

import pytest

from necoherence.semantic_composition import TypeRef
from necoherence.semantic_identity import type_identity
from necoherence.type_signatures import signature_basis
from necoherence.signature_composition_wire import ExternalConditionCause, Origin, SourceIdentity, ValueContractCause, _Context, _decode_inclusion, _decode_outcome_cause
from necoherence.signature_values import WireFailure
from necoherence.type_signatures import _graph
from test_semantic_composition import inclusion_certificate, library

SOURCE = {"repository": "r", "revision": "1", "path": "p", "content_digest": "d"}
SOURCE_REF = {
    "repository": "ncoh-type-signatures",
    "revision": "1",
    "path": "",
    "content_digest": "",
    "document_id": "",
    "declared_revision": None,
}
GRAPH = {"nodes": [{"id": "Token", "reference": {"source": SOURCE_REF, "definition_name": "Token", "pointer": []}, "shape": {}}]}


def _failure(action: Any) -> tuple[str, str, str]:
    with pytest.raises(WireFailure) as caught:
        action()
    return caught.value.kind, caught.value.path, str(caught.value.observed)


def test_value_contract_cause_is_decoded_as_a_typed_origin() -> None:
    value = {"tag": "ValueContract", "fields": {"origin": {"source": SOURCE, "locator": ["operation"]}}}
    assert _decode_outcome_cause(value, "$") == ValueContractCause(Origin(SourceIdentity("r", "1", "p", "d"), ("operation",)))


def test_external_condition_cause_is_decoded_as_a_typed_specification() -> None:
    value = {"tag": "ExternalCondition", "fields": {"specification": {"source": SOURCE, "locator": []}}}
    assert _decode_outcome_cause(value, "$") == ExternalConditionCause(Origin(SourceIdentity("r", "1", "p", "d"), ()))


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ({}, ("Syntax", "$.tag", "property not found: tag")),
        ({"tag": 1}, ("Syntax", "$.tag", "String expected")),
        ({"tag": "Other"}, ("UnknownTag", "$.tag", "Other")),
        ({"tag": "ValueContract"}, ("Syntax", "$.fields", "missing field")),
        ({"tag": "ValueContract", "fields": {}}, ("Syntax", "$.origin", "missing field")),
        (
            {"tag": "ValueContract", "fields": {"origin": {"source": {"repository": "r"}, "locator": []}}},
            ("Syntax", "$.origin.source.revision", "missing field"),
        ),
        (
            {"tag": "ValueContract", "fields": {"origin": {"source": SOURCE, "locator": []}}, "extra": 1},
            ("UnknownField", "$.extra", "extra"),
        ),
    ],
)
def test_outcome_cause_reports_the_lean_failure_at_the_get_path(value: object, expected: tuple[str, str, str]) -> None:
    assert _failure(lambda: _decode_outcome_cause(value, "$")) == expected


def test_inclusion_source_shape_is_decoded_before_the_comparison() -> None:
    declarations = library()
    certificate = inclusion_certificate(declarations)
    certificate["pairs"][0]["source_shape"] = {"tag": "Bogus"}
    assert _failure(lambda: _decode_inclusion(_Context(declarations, _graph(declarations), signature_basis(declarations, [])), certificate, "$.p")) == (
        "UnknownTag",
        "$.p.source_shape.tag",
        "Bogus",
    )


def test_inclusion_shape_mismatch_is_reported_at_the_certificate_path() -> None:
    declarations = library()
    certificate = inclusion_certificate(declarations)
    certificate["pairs"][0]["source_shape"] = {"tag": "Unit"}
    assert _failure(lambda: _decode_inclusion(_Context(declarations, _graph(declarations), signature_basis(declarations, [])), certificate, "$.p")) == (
        "Syntax",
        "$.p",
        "inclusion shape mismatch",
    )


def test_inclusion_rule_without_tag_is_reported_at_the_rule_frame() -> None:
    declarations = library()
    certificate = inclusion_certificate(declarations)
    certificate["pairs"][0]["rule"] = {}
    assert _failure(lambda: _decode_inclusion(_Context(declarations, _graph(declarations), signature_basis(declarations, [])), certificate, "$.p")) == (
        "Syntax",
        "$.p.tag",
        "property not found: tag",
    )


def test_inclusion_missing_destination_shape_is_reported_at_its_field() -> None:
    declarations = library()
    certificate = inclusion_certificate(declarations)
    certificate["pairs"][0].pop("destination_shape")
    assert _failure(lambda: _decode_inclusion(_Context(declarations, _graph(declarations), signature_basis(declarations, [])), certificate, "$.p")) == (
        "Syntax",
        "$.p.destination_shape",
        "missing field",
    )


