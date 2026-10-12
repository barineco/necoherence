# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
from typing import Any

from semantic_invariant_inputs import integer_spec, string_spec, tagged

ROOT = Path(__file__).resolve().parents[2]
PUBLIC_FORMATS = (
    "at-identifier", "at-uri", "cid", "datetime", "did", "handle", "nsid",
    "tid", "record-key", "uri", "language",
)


def _observation_module():
    path = ROOT / "tests/observation/profiles.py"
    spec = importlib.util.spec_from_file_location("observation_profiles", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _load(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _library(identity: str, profile: dict[str, Any], nodes: list[dict[str, Any]], root: str) -> dict[str, Any]:
    return {
        "schema": "ncoh-type-signatures@1", "identity": identity, "revision": "4",
        "profile": copy.deepcopy(profile), "sources": [], "provenance": [], "groups": [],
        "annotations": [], "nodes": nodes,
        "definitions": [{"id": "root", "wire_identity": "Root", "shape": tagged("Value", root)}],
    }


def at_library() -> dict[str, Any]:
    profile = _load(ROOT / "presets/atproto-data-model/profile.json")
    nodes = [
        {"id": "binary", "shape": tagged("Bytes", {"minimum": None, "maximum": None})},
        {"id": "reference", "shape": tagged("String", string_spec(wrapper="reference"))},
        {"id": "blob", "shape": tagged("Sealed", fields={"tag": "blob", "refinements": []})},
        {"id": "any", "shape": tagged("Unknown", tagged("Any"))},
        {"id": "unknown-ordinary", "shape": tagged("Unknown", tagged("OrdinaryObject"))},
        {"id": "ordinary", "shape": tagged("Product", {"fields": [], "extras": tagged(
            "Allow", fields={"key_format": None, "value": {"type_id": "any", "nullable": False}})})},
        {"id": "tagged-tag", "shape": tagged("String", string_spec(
            format=tagged("Named", profile["tag"]["format"]),
            const_value="com.example.record",
        ))},
        {"id": "tagged-product", "shape": tagged("Product", {
            "fields": [{"wire_name": "$type", "slot": {
                "type_id": "tagged-tag", "required": True, "nullable": False,
            }}],
            "extras": tagged("Reject"),
        })},
        {"id": "tagged", "shape": tagged("TaggedUnion", {"branches": [{
            "target": "tagged-product", "wire_tag": "com.example.record",
            "selector": tagged("InternalTag"),
        }]})},
        {"id": "integer", "shape": tagged("Integer", integer_spec())},
    ]
    nodes.extend(
        {"id": f"format:{name}", "shape": tagged("String", string_spec(format=tagged("Named", name)))}
        for name in [binding["name"] for binding in profile["format_bindings"]]
    )
    return _library("atproto-data-model-representatives", profile, nodes, "ordinary")


def _identifier_witness(fields: dict[str, Any]) -> str:
    size = int(fields.get("exact_length") or fields.get("min_length") or "1")
    first = fields["first_alphabet"][0]
    rest = fields["rest_alphabet"][0]
    candidate = first + rest * (size - 1)
    forbidden = set(fields.get("forbidden", []))
    if candidate in forbidden:
        candidate = first + (fields["rest_alphabet"][1] if len(fields["rest_alphabet"]) > 1 else first) * (size - 1)
    return candidate


def _rule_witness(rule: dict[str, Any]) -> str:
    tag = rule["tag"]
    value = rule.get("value")
    fields = rule.get("fields", {})
    if tag == "Literal":
        return value
    if tag == "Identifier":
        return _identifier_witness(fields)
    if tag == "Sequence":
        return "".join(_rule_witness(item) for item in value)
    if tag == "Choice":
        return _rule_witness(value[0])
    if tag == "Optional":
        return ""
    if tag == "Bounded":
        return _rule_witness(fields["rule"])
    if tag == "Labels":
        count = int(fields.get("min_count") or "1")
        return ".".join(_rule_witness(fields["rule"]) for _ in range(count))
    if tag == "Timestamp":
        return "2000-01-01T00:00:00Z"
    if tag == "AbsoluteUri":
        return "https://example.com"
    if tag == "LanguageTag":
        return "en"
    raise ValueError(f"no witness constructor for {tag}")


def _case(identity: str, library: dict[str, Any], type_id: str | None = None,
          value: Any = None, *, operation: str = "value", accepted: bool = True) -> dict[str, Any]:
    result = {"id": identity, "operation": operation, "rule": identity, "library": library,
              "spec_status": "Accepted" if accepted else "Rejected"}
    if type_id is not None:
        result.update({"type_id": type_id, "value": value})
    return result


def _format_cases(subject: dict[str, Any]) -> list[dict[str, Any]]:
    bindings = {binding["name"]: binding["rule"] for binding in subject["profile"]["format_bindings"]}
    cases = []
    for name in PUBLIC_FORMATS:
        cases.append(_case(f"at-format-{name}-valid", subject, f"format:{name}", _rule_witness(bindings[name])))
        cases.append(_case(f"at-format-{name}-invalid", subject, f"format:{name}", "", accepted=False))
    return cases


def _at_cases(subject: dict[str, Any]) -> list[dict[str, Any]]:
    bindings = {binding["name"]: binding["rule"] for binding in subject["profile"]["format_bindings"]}
    cid = _rule_witness(bindings["cid"])
    raw_cid = _rule_witness(bindings["cid-raw"])
    cases = [
        _case("at-bytes-wrapper", subject, "binary", {"$bytes": "AQI="}),
        _case("at-link-wrapper", subject, "reference", {"$link": cid}),
        _case("at-sealed-blob", subject, "blob", {"$type": "blob", "ref": {"$link": raw_cid}, "mimeType": "a", "size": 1}),
        _case("at-ordinary-object", subject, "ordinary", {"$type": "com.example.record", "name": "a"}),
        _case("at-tag-wrapper-competition", subject, "blob", {"$type": "blob", "ref": {"$link": raw_cid}, "mimeType": "a", "size": 1, "$bytes": "AQI="}),
        _case("at-invalid-wrapper", subject, "binary", {"$bytes": "?"}, accepted=False),
        _case("at-p1-integral-decimal", subject, "integer", 123.0),
        _case("at-p2-empty-tag", subject, "ordinary", {"$type": ""}, accepted=False),
        _case("at-p2-empty-tag-tagged-union", subject, "tagged", {"$type": ""}, accepted=False),
        _case("at-p2-empty-tag-unknown-any", subject, "any", {"$type": ""}, accepted=False),
        _case("at-p2-empty-tag-unknown-ordinary", subject, "unknown-ordinary", {"$type": ""}, accepted=False),
        _case("at-p3-nonzero-pad-bits", subject, "binary", {"$bytes": "123"}),
    ]
    record_witnesses = {
        "record-key": _rule_witness(bindings["record-key"]),
        "key:tid": _rule_witness(bindings["tid"]),
        "key:nsid": _rule_witness(bindings["nsid"]),
    }
    for name, witness in record_witnesses.items():
        cases.append(_case(f"at-{name}-valid", subject, f"format:{name}", witness))
        cases.append(_case(f"at-{name}-invalid", subject, f"format:{name}", "", accepted=False))
    return cases + _format_cases(subject)


def _observation_cases() -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]]]:
    module = _observation_module()
    libraries = {"json-schema": module.json_schema_library(), "protobuf": module.protobuf_library()}
    inputs = module.representative_inputs()
    rejected = {
        "scalar-above-maximum",
        "missing-required-property",
        "repeated-int32-null",
        "map-int32-null",
    }
    cases = [
        _case(f"{name}-profile", subject, operation="profile")
        for name, subject in libraries.items()
    ] + [
        _case(f"{name}-library", subject, operation="library")
        for name, subject in libraries.items()
    ]
    for row in inputs:
        cases.append(_case(f"{row['profile']}-{row['id']}", libraries[row["profile"]], row["type_id"],
                           row["value"], accepted=row["id"] not in rejected))
    return cases, libraries


def generate_preset_cases() -> list[dict[str, Any]]:
    at = at_library()
    observation, _ = _observation_cases()
    cases = [_case("at-profile", at, operation="profile"), _case("at-library", at, operation="library")]
    return cases + _at_cases(at) + observation


SIGMA = {
    "$bytes": "$octets", "$link": "$reference", "$type": "$kind", "binary": "octet-wrapper",
    "reference": "reference-wrapper", "blob": "binary-blob", "ref": "reference-field",
    "mimeType": "media-type", "size": "byte-count", "int64": "signed-64",
    **{name: f"renamed-{name}" for name in (
        "at-identifier", "at-uri", "cid", "datetime", "did", "handle", "nsid", "tid",
        "record-key", "uri", "language", "cid-raw", "cid-dagcbor", "union-tag",
        "tag-not-main", "non-empty", "key:tid", "key:nsid")},
}
JSON_SCHEMA_SIGMA = {"required": "required-renamed"}
PROTOBUF_SIGMA = {"int32": "integer-32-renamed"}


def _renamed(value: Any, mapping: dict[str, str]) -> Any:
    if isinstance(value, str):
        if value in mapping:
            return mapping[value]
        for old, new in sorted(mapping.items(), key=lambda item: len(item[0]), reverse=True):
            if value.endswith(":" + old):
                return value[:-(len(old))] + new
        return value
    if isinstance(value, list):
        return [_renamed(item, mapping) for item in value]
    if isinstance(value, dict):
        return {key: _renamed(item, mapping) for key, item in value.items()}
    return value



def _rename_input(value: Any, mapping: dict[str, str]) -> Any:
    if isinstance(value, list):
        return [_rename_input(item, mapping) for item in value]
    if isinstance(value, dict):
        return {
            mapping.get(key, key): _rename_input(item, mapping)
            for key, item in value.items()
        }
    return _renamed(value, mapping)

def _profile_digest(profile: dict[str, Any]) -> None:
    reference = profile["reference"]
    old_digest = reference["content_digest"]

    def blank(value: Any) -> Any:
        if isinstance(value, list):
            return [blank(item) for item in value]
        if isinstance(value, dict):
            result = {key: blank(item) for key, item in value.items()}
            if (value.get("identity") == reference["identity"] and value.get("revision") == reference["revision"]
                    and value.get("content_digest") == old_digest):
                result["content_digest"] = ""
            return result
        return value

    digest = hashlib.sha256(json.dumps(blank(profile), ensure_ascii=False, sort_keys=True,
                                      separators=(",", ":")).encode()).hexdigest()

    def replace(value: Any) -> None:
        if isinstance(value, list):
            for item in value:
                replace(item)
        elif isinstance(value, dict):
            if (value.get("identity") == reference["identity"] and value.get("revision") == reference["revision"]
                    and value.get("content_digest") == old_digest):
                value["content_digest"] = digest
            for item in value.values():
                replace(item)

    replace(profile)


def sigma_case(case: dict[str, Any]) -> tuple[dict[str, Any], dict[str, str]]:
    identity = case["library"]["identity"]
    mapping = SIGMA if identity == "atproto-data-model-representatives" else (
        JSON_SCHEMA_SIGMA if identity == "json-schema-2020-12-observation" else PROTOBUF_SIGMA)
    renamed = _renamed(copy.deepcopy(case), mapping)
    if case["operation"] == "value":
        renamed["value"] = _rename_input(case["value"], mapping)
    _profile_digest(renamed["library"]["profile"])
    renamed["id"] = "sigma-" + case["id"]
    return renamed, mapping


def rename_decision(decision: dict[str, Any], mapping: dict[str, str]) -> dict[str, Any]:
    return _renamed(copy.deepcopy(decision), mapping)
