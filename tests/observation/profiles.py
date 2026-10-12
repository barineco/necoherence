# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any, cast


OBSERVATION_ROOT = Path(__file__).resolve().parent


def tagged(tag: str, value: Any = None, *, fields: dict[str, Any] | None = None) -> dict[str, Any]:
    if fields is not None:
        return {"tag": tag, "fields": fields}
    return {"tag": tag} if value is None else {"tag": tag, "value": value}


def string_spec(**changes: Any) -> dict[str, Any]:
    value: dict[str, Any] = {
        "format": None,
        "lengths": [],
        "wrapper": None,
        "const_value": None,
        "enum_values": None,
        "examples": [],
        "default_value": None,
    }
    value.update(changes)
    return value


def integer_spec(**changes: Any) -> dict[str, Any]:
    value: dict[str, Any] = {
        "domain": None,
        "minimum": None,
        "maximum": None,
        "const_value": None,
        "enum_values": None,
        "default_value": None,
    }
    value.update(changes)
    return value


def load_profile(name: str) -> dict[str, Any]:
    path = OBSERVATION_ROOT / name / "profile.json"
    return cast(dict[str, Any], json.loads(path.read_text(encoding="utf-8")))


def load_json_schema_profile() -> dict[str, Any]:
    return load_profile("json-schema")


def load_protobuf_profile() -> dict[str, Any]:
    return load_profile("protobuf")


def library(identity: str, profile: dict[str, Any], nodes: list[dict[str, Any]], root: str) -> dict[str, Any]:
    return {
        "schema": "ncoh-type-signatures@1",
        "identity": identity,
        "revision": "4",
        "profile": copy.deepcopy(profile),
        "sources": [],
        "provenance": [],
        "groups": [],
        "annotations": [],
        "nodes": nodes,
        "definitions": [
            {"id": "root", "wire_identity": "Root", "shape": tagged("Value", root)}
        ],
    }


def element(type_id: str, *, nullable: bool = False) -> dict[str, Any]:
    return {"type_id": type_id, "nullable": nullable}


def field(type_id: str, wire_name: str, *, required: bool, nullable: bool = False) -> dict[str, Any]:
    return {
        "wire_name": wire_name,
        "slot": {"type_id": type_id, "required": required, "nullable": nullable},
    }


def product(fields: list[dict[str, Any]], extras: dict[str, Any]) -> dict[str, Any]:
    return tagged("Product", {"fields": fields, "extras": extras})


def array(item: str, *, nullable: bool = False) -> dict[str, Any]:
    return tagged(
        "Array",
        {"item": element(item, nullable=nullable), "min_length": None, "max_length": None},
    )


def json_schema_library() -> dict[str, Any]:
    nodes = [
        {"id": "schema", "shape": tagged("Unknown", tagged("Any"))},
        {"id": "integer", "shape": tagged("Integer", integer_spec())},
        {
            "id": "scalar-string",
            "shape": tagged(
                "String",
                string_spec(
                    lengths=[
                        {"unit": tagged("UnicodeScalars"), "minimum": None, "maximum": "1"}
                    ]
                ),
            ),
        },
        {
            "id": "object",
            "shape": product(
                [field("schema", "required", required=True, nullable=True)],
                tagged(
                    "Allow",
                    fields={"key_format": None, "value": element("schema", nullable=True)},
                ),
            ),
        },
        {"id": "array", "shape": array("schema", nullable=True)},
    ]
    return library("json-schema-2020-12-observation", load_json_schema_profile(), nodes, "schema")


def protobuf_library() -> dict[str, Any]:
    nodes = [
        {"id": name, "shape": tagged("Integer", integer_spec(domain=name))}
        for name in ("int32", "uint32", "int64", "uint64")
    ]
    nodes.extend(
        [
            {"id": "bytes", "shape": tagged("Bytes", {"minimum": None, "maximum": None})},
            {"id": "value", "shape": tagged("Unknown", tagged("Any"))},
            {"id": "repeated-int32", "shape": array("int32", nullable=False)},
            {
                "id": "map-int32",
                "shape": product(
                    [],
                    tagged(
                        "Allow",
                        fields={"key_format": None, "value": element("int32", nullable=False)},
                    ),
                ),
            },
            {"id": "repeated-value", "shape": array("value", nullable=False)},
            {
                "id": "map-value",
                "shape": product(
                    [],
                    tagged(
                        "Allow",
                        fields={"key_format": None, "value": element("value", nullable=False)},
                    ),
                ),
            },
            {
                "id": "struct",
                "shape": product(
                    [],
                    tagged(
                        "Allow",
                        fields={"key_format": None, "value": element("value", nullable=True)},
                    ),
                ),
            },
            {"id": "list-value", "shape": array("value", nullable=True)},
        ]
    )
    return library("protobuf-proto3-protojson-observation", load_protobuf_profile(), nodes, "value")


def representative(
    identity: str, profile: str, type_id: str, value: Any
) -> dict[str, Any]:
    return {"id": identity, "profile": profile, "type_id": type_id, "value": value}


def json_schema_representative_inputs() -> tuple[dict[str, Any], ...]:
    return (
        representative("schema-null", "json-schema", "schema", None),
        representative("schema-object", "json-schema", "schema", {"member": 1}),
        representative("schema-array", "json-schema", "schema", [1, "two"]),
        representative("integer-integral-decimal", "json-schema", "integer", 1.0),
        representative("scalar-at-maximum", "json-schema", "scalar-string", "é"),
        representative("scalar-above-maximum", "json-schema", "scalar-string", "éa"),
        representative("required-property", "json-schema", "object", {"required": None}),
        representative("missing-required-property", "json-schema", "object", {}),
        representative(
            "additional-property",
            "json-schema",
            "object",
            {"required": None, "additional": True},
        ),
        representative("array-item", "json-schema", "array", [None, {}, []]),
    )


def protobuf_representative_inputs() -> tuple[dict[str, Any], ...]:
    integer_bounds = (
        ("int32", -2147483648, 2147483647),
        ("uint32", 0, 4294967295),
        ("int64", -9223372036854775808, 9223372036854775807),
        ("uint64", 0, 18446744073709551615),
    )
    integer_inputs = tuple(
        representative(f"{name}-minimum", "protobuf", name, minimum)
        for name, minimum, _ in integer_bounds
    ) + tuple(
        representative(f"{name}-maximum", "protobuf", name, maximum)
        for name, _, maximum in integer_bounds
    )
    return integer_inputs + (
        representative("int32-decimal-string", "protobuf", "int32", "1"),
        representative("uint64-integral-exponent", "protobuf", "uint64", 1.0e18),
        representative("bytes-url-safe-unpadded", "protobuf", "bytes", "-_8"),
        representative("value-null", "protobuf", "value", None),
        representative("value-number", "protobuf", "value", 1.5),
        representative("value-object", "protobuf", "value", {"member": True}),
        representative("value-array", "protobuf", "value", [None, 1]),
        representative("struct", "protobuf", "struct", {"member": None}),
        representative("list-value", "protobuf", "list-value", [None, 1]),
        representative("repeated-int32-null", "protobuf", "repeated-int32", [None]),
        representative("map-int32-null", "protobuf", "map-int32", {"key": None}),
        representative("repeated-value-null", "protobuf", "repeated-value", [None]),
        representative("map-value-null", "protobuf", "map-value", {"key": None}),
    )


def representative_inputs() -> tuple[dict[str, Any], ...]:
    return json_schema_representative_inputs() + protobuf_representative_inputs()
