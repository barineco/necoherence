# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from typing import Any

import pytest
from neco_quotient_encoding import JsonArray, JsonNumber, JsonObject, JsonString, JsonValue, Ok, Parse, decode_canonical

from necoherence import encode_semantic_residual
from necoherence.semantic_residual_record import SEMANTIC_RESIDUAL_SCHEMA, SemanticResidualFailure
from necoherence.signature_values import UnresolvedValueFailure, ValueContext, exact_from_json
from test_semantic_graph_wire import _graph, _node, _reference

BASIS = {
    "signature_schema": "ncoh-type-signatures@1",
    "library_identity": "residual-record",
    "library_revision": "1",
    "profile": {"identity": "profile", "revision": "1", "content_digest": "a" * 64},
    "graph_sha256": "1" * 64,
    "metadata_sha256": "3" * 64,
    "entrypoints_sha256": "6" * 64,
    "provenance_sha256": "2" * 64,
    "problem_sha256": None,
    "observations_sha256": None,
}

VALUE = {"a": 1, "list": [2, {"c": None, "d": "x"}], "flag": True}


def _allow(target: str) -> dict[str, Any]:
    return {"tag": "Allow", "fields": {"key_format": None, "value": {"type_ref": _reference(target), "nullable": False}}}


def _context() -> ValueContext:
    graph = _graph()
    shape = {"tag": "Product", "value": {"fields": [], "extras": _allow("ghost")}}
    other = {"tag": "Product", "value": {"fields": [], "extras": _allow("phantom")}}
    graph["nodes"] = [_node("holder", shape), _node("other", other)]
    return ValueContext(graph)


def _obligations() -> list[Any]:
    context = _context()
    found = context.meaning_obligations([_reference("holder"), _reference("other")])
    assert len(found) == 2
    return list(found)


def _encode(obligations: list[Any]) -> bytes:
    return encode_semantic_residual(BASIS, _reference("holder"), exact_from_json(VALUE), obligations)


def _decoded(data: bytes) -> JsonObject:
    result = decode_canonical(data)
    assert isinstance(result, Ok)
    assert isinstance(result.value, JsonObject)
    return result.value


def _field(record: JsonObject, name: str) -> JsonValue:
    return dict(record.fields)[name]


def test_permutation_of_obligations_and_repetition_keep_the_bytes() -> None:
    found = _obligations()
    expected = _encode(found)
    assert _encode(list(reversed(found))) == expected
    assert _encode([*found, found[0]]) == expected
    assert _encode([*found, *found]) == expected


def test_roundtrip_reads_four_fields_and_one_residual_per_distinct_obligation() -> None:
    found = _obligations()
    record = _decoded(_encode([*found, found[1]]))
    assert sorted(name for name, _ in record.fields) == ["basis", "input", "residuals", "schema"]
    assert _field(record, "schema") == JsonString(SEMANTIC_RESIDUAL_SCHEMA)
    residuals = _field(record, "residuals")
    assert isinstance(residuals, JsonArray)
    assert len(residuals.items) == 2


def test_values_are_written_as_tagged_records_without_json_numbers() -> None:
    data = _encode(_obligations())
    assert b'{"tag":"Integer","value":"1"}' in data
    assert b'{"tag":"Integer","value":"2"}' in data
    assert b'{"tag":"Null"}' in data
    assert b'{"tag":"Bool","value":true}' in data

    def numbers(value: JsonValue) -> int:
        if isinstance(value, JsonNumber):
            return 1
        if isinstance(value, JsonArray):
            return sum(numbers(item) for item in value.items)
        if isinstance(value, JsonObject):
            return sum(numbers(child) for _, child in value.fields)
        return 0

    assert numbers(_decoded(data)) == 0


def test_residual_entries_carry_every_field_of_the_obligation() -> None:
    record = _decoded(_encode(_obligations()))
    residuals = _field(record, "residuals")
    assert isinstance(residuals, JsonArray)
    for item in residuals.items:
        assert isinstance(item, JsonObject)
        assert sorted(name for name, _ in item.fields) == ["origin", "profile", "reason", "type_ref", "value_path"]


def test_an_encoding_failure_is_kept_in_the_raised_failure() -> None:
    with pytest.raises(SemanticResidualFailure) as caught:
        encode_semantic_residual(BASIS, _reference("holder"), exact_from_json({"a": "\ud800"}), _obligations())
    assert isinstance(caught.value.failure.condition, Parse)


def test_the_context_still_reports_the_obligations_it_encodes() -> None:
    with pytest.raises(UnresolvedValueFailure) as caught:
        _context().validate(_reference("holder"), exact_from_json(VALUE))
    assert _encode(list(caught.value.obligations))
