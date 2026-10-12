# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

import json

from profiles import (
    OBSERVATION_ROOT,
    json_schema_library,
    json_schema_representative_inputs,
    load_json_schema_profile,
    load_protobuf_profile,
    protobuf_library,
    protobuf_representative_inputs,
)


def canonical_json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def test_profile_files_are_canonical_json() -> None:
    for name in ("json-schema", "protobuf"):
        path = OBSERVATION_ROOT / name / "profile.json"
        text = path.read_text(encoding="utf-8")
        assert text == canonical_json(json.loads(text)) + "\n"


def test_json_schema_profile_declares_the_observation_semantics() -> None:
    profile = load_json_schema_profile()
    domain = profile["integer_domains"]
    assert domain == [
        {
            "name": "integer",
            "reference": profile["reference"],
            "range": {"tag": "Unbounded"},
            "forms": [{"tag": "Number"}, {"tag": "IntegralDecimal"}],
        }
    ]
    assert profile["numbers"] == {"decimals": True}
    assert profile["format_bindings"] == []
    assert profile["bytes_policy"] is None
    assert profile["wrappers"] == []
    assert profile["tag"] is None


def test_json_schema_library_has_only_the_representative_branches() -> None:
    subject = json_schema_library()
    assert [node["id"] for node in subject["nodes"]] == [
        "schema",
        "integer",
        "scalar-string",
        "object",
        "array",
    ]
    assert {row["id"] for row in json_schema_representative_inputs()} == {
        "schema-null",
        "schema-object",
        "schema-array",
        "integer-integral-decimal",
        "scalar-at-maximum",
        "scalar-above-maximum",
        "required-property",
        "missing-required-property",
        "additional-property",
        "array-item",
    }


def test_protobuf_profile_declares_protojson_semantics() -> None:
    profile = load_protobuf_profile()
    domains = {domain["name"]: domain for domain in profile["integer_domains"]}
    assert set(domains) == {"int32", "uint32", "int64", "uint64", "value-number"}
    assert domains["int32"]["range"]["fields"] == {
        "minimum": "-2147483648",
        "maximum": "2147483647",
    }
    assert domains["uint32"]["range"]["fields"] == {
        "minimum": "0",
        "maximum": "4294967295",
    }
    assert domains["int64"]["range"]["fields"] == {
        "minimum": "-9223372036854775808",
        "maximum": "9223372036854775807",
    }
    assert domains["uint64"]["range"]["fields"] == {
        "minimum": "0",
        "maximum": "18446744073709551615",
    }
    assert domains["value-number"]["range"] == {"tag": "Unbounded"}
    assert all(
        domain["forms"]
        == [{"tag": "Number"}, {"tag": "IntegralDecimal"}, {"tag": "DecimalString"}]
        for domain in domains.values()
    )
    assert profile["numbers"] == {"decimals": True}
    assert profile["bytes_policy"] == {
        "reference": profile["reference"],
        "padding_optional": True,
        "alphabet": {"tag": "Either"},
        "strict_pad_bits": False,
        "wrapper": None,
    }
    assert profile["wrappers"] == []
    assert profile["tag"] is None


def test_protobuf_library_has_only_the_representative_branches() -> None:
    subject = protobuf_library()
    assert [node["id"] for node in subject["nodes"]] == [
        "int32",
        "uint32",
        "int64",
        "uint64",
        "bytes",
        "value",
        "repeated-int32",
        "map-int32",
        "repeated-value",
        "map-value",
        "struct",
        "list-value",
    ]
    nodes = {node["id"]: node["shape"] for node in subject["nodes"]}
    assert nodes["repeated-int32"]["value"]["item"] == {
        "type_id": "int32", "nullable": False}
    assert nodes["map-int32"]["value"]["extras"]["fields"]["value"] == {
        "type_id": "int32", "nullable": False}
    assert nodes["repeated-value"]["value"]["item"] == {
        "type_id": "value", "nullable": False}
    assert nodes["map-value"]["value"]["extras"]["fields"]["value"] == {
        "type_id": "value", "nullable": False}
    assert nodes["struct"]["value"]["extras"]["fields"]["value"]["nullable"] is True
    assert nodes["list-value"]["value"]["item"]["nullable"] is True
    representatives = {row["id"]: row for row in protobuf_representative_inputs()}
    assert representatives["repeated-int32-null"]["value"] == [None]
    assert representatives["map-int32-null"]["value"] == {"key": None}
    assert representatives["repeated-value-null"]["value"] == [None]
    assert representatives["map-value-null"]["value"] == {"key": None}
    identities = set(representatives)
    assert {
        "int32-minimum",
        "int32-maximum",
        "uint32-minimum",
        "uint32-maximum",
        "int64-minimum",
        "int64-maximum",
        "uint64-minimum",
        "uint64-maximum",
        "int32-decimal-string",
        "uint64-integral-exponent",
        "bytes-url-safe-unpadded",
        "value-null",
        "value-number",
        "value-object",
        "value-array",
        "struct",
        "list-value",
        "repeated-int32-null",
        "map-int32-null",
        "repeated-value-null",
        "map-value-null",
    } <= identities
