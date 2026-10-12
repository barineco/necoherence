# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

"""Pure validation, canonical encoding, and residual coherence calculations."""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
from math import gcd
from typing import Any, Final, cast
import json
import re

SCHEMA_VERSION: Final = "necoherence-analysis-1"
SHA256_DIGEST_PATTERN: Final = re.compile(r"^sha256:[0-9a-f]{64}$")
_FAILURE_KINDS: Final = frozenset(
    {
        "InvalidSchemaVersion",
        "InvalidIdentifier",
        "DuplicateIdentifier",
        "InvalidInputTree",
        "RegionPointMismatch",
        "PointRegionMismatch",
        "InvalidPositiveRational",
        "InvalidNonnegativeRational",
        "NonCanonicalRational",
        "UnresolvedReachabilityPoint",
        "ReachabilityEvidenceFailure",
        "TypeClosureFailure",
        "AxiomClosureFailure",
        "SourceEvidenceFailure",
        "CanonicalEncodingFailure",
        "VerificationFailure",
    }
)


@dataclass(frozen=True)
class TypedFailure:
    """A closed analysis failure with a stable kind and diagnostic path."""

    kind: str
    path: str = "$"
    detail: str = ""

    def __post_init__(self) -> None:
        if self.kind not in _FAILURE_KINDS:
            raise ValueError(f"unknown AnalysisFailure kind: {self.kind}")

    def as_dict(self) -> dict[str, str]:
        result = {"kind": self.kind, "path": self.path}
        if self.detail:
            result["detail"] = self.detail
        return result


def _failure(kind: str, path: str, detail: str = "") -> TypedFailure:
    return TypedFailure(kind, path, detail)


def _is_identifier(value: Any) -> bool:
    return isinstance(value, str) and bool(value)


def _finite_values(value: Any, path: str) -> tuple[list[Any], TypedFailure | None]:
    if not isinstance(value, dict) or set(value) != {"finite_set"} or not isinstance(value["finite_set"], list):
        return [], _failure("InvalidIdentifier", path, "expected finite_set wrapper")
    values = value["finite_set"]
    if len({json.dumps(item, ensure_ascii=False, sort_keys=True, separators=(",", ":")) for item in values}) != len(values):
        return [], _failure("DuplicateIdentifier", path)
    return values, None


def _finite_sequence(value: Any, path: str) -> tuple[list[Any] | None, TypedFailure | None]:
    if not isinstance(value, dict) or set(value) != {"finite_sequence"} or not isinstance(value["finite_sequence"], list):
        return None, _failure("InvalidInputTree", path, "expected finite_sequence wrapper")
    return value["finite_sequence"], None


def _finite_map(value: Any, path: str) -> tuple[list[dict[str, Any]] | None, TypedFailure | None]:
    if not isinstance(value, dict) or set(value) != {"finite_map"} or not isinstance(value["finite_map"], list):
        return None, _failure("InvalidIdentifier", path, "expected finite_map wrapper")
    entries = value["finite_map"]
    keys = [entry.get("key") if isinstance(entry, dict) else None for entry in entries]
    if any(not _is_identifier(key) for key in keys) or len(keys) != len(set(keys)):
        return None, _failure("DuplicateIdentifier", path)
    if any(not isinstance(entry, dict) or set(entry) != {"key", "value"} or not _is_identifier(entry["value"]) for entry in entries):
        return None, _failure("InvalidIdentifier", path)
    return entries, None


def _rational(value: Any, path: str, positive: bool) -> tuple[dict[str, int] | None, TypedFailure | None]:
    kind = "InvalidPositiveRational" if positive else "InvalidNonnegativeRational"
    if not isinstance(value, dict) or set(value) != {"numerator", "denominator"}:
        return None, _failure(kind, path)
    numerator, denominator = value["numerator"], value["denominator"]
    if not isinstance(numerator, int) or isinstance(numerator, bool) or not isinstance(denominator, int) or isinstance(denominator, bool):
        return None, _failure(kind, path)
    if denominator <= 0 or numerator < (1 if positive else 0):
        return None, _failure(kind, path)
    divisor = gcd(numerator, denominator)
    normalized = {"numerator": numerator // divisor, "denominator": denominator // divisor}
    if normalized != value:
        return None, _failure("NonCanonicalRational", path)
    return normalized, None


def _canonical(value: Any) -> Any:
    if isinstance(value, dict):
        if set(value) == {"finite_set"} and isinstance(value["finite_set"], list):
            items = [_canonical(item) for item in value["finite_set"]]
            items.sort(key=lambda item: _canonical_json(item))
            return {"finite_set": items}
        if set(value) == {"finite_sequence"} and isinstance(value["finite_sequence"], list):
            return {"finite_sequence": [_canonical(item) for item in value["finite_sequence"]]}
        if set(value) == {"finite_map"} and isinstance(value["finite_map"], list):
            entries = [{"key": _canonical(item["key"]), "value": _canonical(item["value"])} for item in value["finite_map"]]
            entries.sort(key=lambda item: _canonical_json(item["key"]))
            return {"finite_map": entries}
        return {key: _canonical(value[key]) for key in sorted(value)}
    if isinstance(value, list):
        return [_canonical(item) for item in value]
    return value


def _canonical_json(value: Any) -> str:
    return json.dumps(_canonical(value), ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def canonical_bytes(value: Any) -> bytes | TypedFailure:
    """Return canonical UTF-8 JSON bytes for a JSON-compatible value."""
    try:
        return _canonical_json(value).encode("utf-8")
    except (TypeError, ValueError, UnicodeError) as exc:
        return _failure("CanonicalEncodingFailure", "$", str(exc))


def canonical_digest(value: Any) -> str | TypedFailure:
    """Return the SHA-256 digest of canonical UTF-8 JSON bytes."""
    encoded = canonical_bytes(value)
    if isinstance(encoded, TypedFailure):
        return encoded
    return "sha256:" + sha256(encoded).hexdigest()


def _identifiers(items: list[dict[str, Any]], field: str, path: str) -> tuple[dict[str, dict[str, Any]], TypedFailure | None]:
    result: dict[str, dict[str, Any]] = {}
    for index, item in enumerate(items):
        identifier = item.get(field)
        if not _is_identifier(identifier):
            return {}, _failure("InvalidIdentifier", f"{path}[{index}].{field}")
        normalized_identifier = cast(str, identifier)
        if normalized_identifier in result:
            return {}, _failure("DuplicateIdentifier", f"{path}[{index}].{field}")
        result[normalized_identifier] = item
    return result, None


def _tree_ids(tree: Any, path: str) -> tuple[set[str] | None, TypedFailure | None]:
    if not isinstance(tree, dict):
        return None, _failure("InvalidInputTree", path)
    if set(tree) == {"leaf"} and _is_identifier(tree["leaf"]):
        return {tree["leaf"]}, None
    if set(tree) != {"branch"} or not isinstance(tree["branch"], dict):
        return None, _failure("InvalidInputTree", path)
    branch = tree["branch"]
    if not _is_identifier(branch.get("branch_id")) or set(branch) != {"branch_id", "children"}:
        return None, _failure("InvalidInputTree", path)
    children, failure = _finite_sequence(branch["children"], f"{path}.branch.children")
    if failure:
        return None, failure
    result: set[str] = set()
    for index, child in enumerate(children or []):
        child_ids, failure = _tree_ids(child, f"{path}.branch.children.finite_sequence[{index}]")
        if failure:
            return None, failure
        result.update(child_ids or set())
    return result, None


def _evidence(values: Any, path: str) -> tuple[list[dict[str, Any]] | None, TypedFailure | None]:
    items, failure = _finite_values(values, path)
    if failure:
        return None, _failure("SourceEvidenceFailure", path)
    if not items or any(not isinstance(item, dict) for item in items):
        return None, _failure("SourceEvidenceFailure", path)
    evidence, failure = _identifiers(cast(list[dict[str, Any]], items), "evidence_id", path)
    if failure:
        return None, _failure("SourceEvidenceFailure", failure.path)
    for evidence_id, item in evidence.items():
        if item.get("source_kind") not in {"Architecture", "Design", "Lean", "Specification", "Repository", "Observation"} or not _is_identifier(item.get("source_ref")) or not _is_identifier(item.get("locator")) or not _is_identifier(item.get("claim")):
            return None, _failure("SourceEvidenceFailure", f"{path}.{evidence_id}")
        digest = item.get("source_digest")
        if not isinstance(digest, str) or not SHA256_DIGEST_PATTERN.fullmatch(digest):
            return None, _failure("SourceEvidenceFailure", f"{path}.{evidence_id}.source_digest")
    return list(evidence.values()), None


def validate_analysis_input(value: Any) -> dict[str, Any] | TypedFailure:
    """Validate and return a closed, normalized AnalysisInput."""
    if not isinstance(value, dict) or value.get("schema_version") != SCHEMA_VERSION:
        return _failure("InvalidSchemaVersion", "$.schema_version")
    required = {"schema_version", "input_tree", "input_region", "reachability_points", "type_declarations", "value_declarations", "branches", "declared_reachability", "derived_reachability", "axiom_declarations"}
    if set(value) != required:
        return _failure("InvalidIdentifier", "$")
    tree_ids, failure = _tree_ids(value["input_tree"], "$.input_tree")
    if failure:
        return failure
    region = value["input_region"]
    if not isinstance(region, dict) or not _is_identifier(region.get("region_id")):
        return _failure("InvalidIdentifier", "$.input_region.region_id")
    region_ids, failure = _finite_values(region.get("point_ids"), "$.input_region.point_ids")
    if failure:
        return _failure("RegionPointMismatch", "$.input_region.point_ids")
    region_weight, failure = _rational(region.get("weight"), "$.input_region.weight", True)
    if failure:
        return failure
    points, failure = _finite_values(value["reachability_points"], "$.reachability_points")
    if failure:
        return failure
    point_map, failure = _identifiers(points or [], "point_id", "$.reachability_points.finite_set")
    if failure:
        return failure
    point_ids = set(point_map or {})
    if set(region_ids or []) != point_ids or point_ids != (tree_ids or set()):
        return _failure("RegionPointMismatch", "$.input_region.point_ids")
    for point_id, point in (point_map or {}).items():
        if point.get("region_id") != region["region_id"]:
            return _failure("PointRegionMismatch", f"$.reachability_points.{point_id}.region_id")
        if _rational(point.get("input_weight"), f"$.reachability_points.{point_id}.input_weight", True)[1] or _rational(point.get("measure_contribution"), f"$.reachability_points.{point_id}.measure_contribution", False)[1]:
            return _failure("InvalidPositiveRational", f"$.reachability_points.{point_id}")
        coordinates, coordinate_failure = _finite_map(point.get("coordinates"), f"$.reachability_points.{point_id}.coordinates")
        if coordinate_failure:
            return coordinate_failure
    types, failure = _finite_values(value["type_declarations"], "$.type_declarations")
    if failure:
        return failure
    type_map, failure = _identifiers(types or [], "type_id", "$.type_declarations.finite_set")
    if failure:
        return failure
    type_values: dict[str, set[str]] = {}
    for type_id, declaration in (type_map or {}).items():
        entries, entry_failure = _finite_values(declaration.get("values"), f"$.type_declarations.{type_id}.values")
        if entry_failure or any(not _is_identifier(item) for item in entries or []):
            return _failure("TypeClosureFailure", f"$.type_declarations.{type_id}")
        type_values[type_id] = set(entries or [])
    values, failure = _finite_values(value["value_declarations"], "$.value_declarations")
    if failure:
        return failure
    value_map, failure = _identifiers(values or [], "value_id", "$.value_declarations.finite_set")
    if failure:
        return failure
    value_types = {item["value_id"]: item["type_id"] for item in values or []}
    if any(item["type_id"] not in type_map or item["value_id"] not in type_values[item["type_id"]] for item in values or []):
        return _failure("TypeClosureFailure", "$.value_declarations")
    branches, failure = _finite_values(value["branches"], "$.branches")
    if failure:
        return failure
    branch_map, failure = _identifiers(branches or [], "branch_id", "$.branches.finite_set")
    if failure:
        return failure
    for branch_id, branch in branch_map.items():
        regions, region_failure = _finite_values(branch.get("input_region"), f"$.branches.{branch_id}.input_region")
        required_values, required_values_failure = _finite_values(branch.get("required_values"), f"$.branches.{branch_id}.required_values")
        required_type = branch.get("required_type")
        if region_failure or required_values_failure or not isinstance(required_type, str) or required_type not in type_map or any(item not in point_ids for item in regions) or any(item not in type_values.get(required_type, set()) for item in required_values):
            return _failure("TypeClosureFailure", f"$.branches.{branch_id}")
    for reachability_key in ("declared_reachability", "derived_reachability"):
        reach = value[reachability_key]
        ids, ids_failure = _finite_values(reach.get("point_ids") if isinstance(reach, dict) else None, f"$.{reachability_key}.point_ids")
        if ids_failure or any(item not in point_ids for item in ids or []):
            return _failure("UnresolvedReachabilityPoint", f"$.{reachability_key}.point_ids")
        if _evidence(reach.get("evidence") if isinstance(reach, dict) else None, f"$.{reachability_key}.evidence")[1]:
            return _failure("ReachabilityEvidenceFailure", f"$.{reachability_key}.evidence")
    axioms, failure = _finite_values(value["axiom_declarations"], "$.axiom_declarations")
    if failure:
        return failure
    for index, axiom in enumerate(axioms):
        if not isinstance(axiom, dict):
            return _failure("AxiomClosureFailure", f"$.axiom_declarations[{index}]")
        candidates, candidate_failure = _finite_values(axiom.get("closed_output_candidates"), f"$.axiom_declarations[{index}].closed_output_candidates")
        if candidate_failure or any(item not in value_map for item in candidates) or axiom.get("input_type") not in type_map or axiom.get("output_type") not in type_map or not _is_identifier(axiom.get("axiom_id")) or not _is_identifier(axiom.get("identity")):
            return _failure("AxiomClosureFailure", f"$.axiom_declarations[{index}]")
    return cast(dict[str, Any], _canonical(value))


def derive_reachability(value: Any) -> dict[str, Any] | TypedFailure:
    """Derive reachable points from closed branch requirements."""
    validated = validate_analysis_input(value)
    if isinstance(validated, TypedFailure):
        return validated
    points = {item["point_id"]: item for item in validated["reachability_points"]["finite_set"]}
    reachable: set[str] = set()
    for branch in validated["branches"]["finite_set"]:
        regions = set(branch["input_region"]["finite_set"])
        candidates = set(branch["required_values"]["finite_set"])
        for point_id, point in points.items():
            if point_id not in regions:
                continue
            coordinates = {entry["key"]: entry["value"] for entry in point["coordinates"]["finite_map"]}
            if coordinates.get(branch["required_type"]) in candidates:
                reachable.add(point_id)
    evidence = validated["derived_reachability"]["evidence"]
    return {"point_ids": {"finite_set": sorted(reachable)}, "evidence": evidence}


def calculate_report(value: Any) -> dict[str, Any] | TypedFailure:
    """Calculate declared, derived, and residual extents."""
    validated = validate_analysis_input(value)
    if isinstance(validated, TypedFailure):
        return validated
    derived = derive_reachability(validated)
    if isinstance(derived, TypedFailure):
        return derived
    points = {item["point_id"]: item for item in validated["reachability_points"]["finite_set"]}
    declared_ids = set(validated["declared_reachability"]["point_ids"]["finite_set"])
    derived_ids = set(derived["point_ids"]["finite_set"])
    def total(ids: set[str]) -> dict[str, int]:
        numerator, denominator = 0, 1
        for point_id in ids:
            rational = points[point_id]["measure_contribution"]
            numerator = numerator * rational["denominator"] + rational["numerator"] * denominator
            denominator *= rational["denominator"]
            divisor = gcd(numerator, denominator)
            numerator //= divisor
            denominator //= divisor
        return {"numerator": numerator, "denominator": denominator}
    residual_ids = derived_ids - declared_ids
    return {
        "schema_version": SCHEMA_VERSION,
        "declared_point_ids": {"finite_set": sorted(declared_ids)},
        "derived_point_ids": {"finite_set": sorted(derived_ids)},
        "residual_point_ids": {"finite_set": sorted(residual_ids)},
        "residual_inhabited": bool(residual_ids),
        "declared_extent": total(declared_ids),
        "derived_extent": total(derived_ids),
        "residual_extent": total(residual_ids),
        "source_evidence": {"finite_set": validated["declared_reachability"]["evidence"]["finite_set"] + validated["derived_reachability"]["evidence"]["finite_set"]},
    }


__all__ = ["canonical_bytes", "canonical_digest", "validate_analysis_input", "derive_reachability", "calculate_report", "TypedFailure", "SHA256_DIGEST_PATTERN"]
