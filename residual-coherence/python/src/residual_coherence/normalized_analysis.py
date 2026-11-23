# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

"""Consume only the canonical ``normalized-analysis`` major-1 schema.

The consumer validates canonical JSON bytes, closed normalized-analysis relations,
findings, the reduced AnalysisInput, and the residual coherence report.
"""

from __future__ import annotations

from dataclasses import dataclass
import json
from typing import Any, Final

from .core import TypedFailure, calculate_report, canonical_bytes, validate_analysis_input

SCHEMA_VERSION: Final = {"name": "normalized-analysis", "major": "1"}
RELATION_GROUPS: Final = (
    "declarations",
    "types",
    "values",
    "operation_inputs",
    "branches",
    "control_flow",
    "place_accesses",
    "external_effects",
    "source_spans",
    "stage_correspondences",
)
_FAILURE_KINDS: Final = frozenset({
    "InvalidCanonicalJson",
    "NonCanonicalJson",
    "UnsupportedSchemaVersion",
    "InvalidStructure",
    "DuplicateIdentifier",
    "ReferenceClosureFailure",
    "AnalysisInputFailure",
    "ReportFailure",
    "PresentationFailure",
})


@dataclass(frozen=True)
class CanonicalConsumerFailure:
    """A closed failure returned while consuming canonical normalized analysis JSON."""

    kind: str
    path: str = "$"
    detail: str = ""

    def __post_init__(self) -> None:
        if self.kind not in _FAILURE_KINDS:
            raise ValueError(f"unknown CanonicalConsumerFailure kind: {self.kind}")

    def as_dict(self) -> dict[str, str]:
        result = {"kind": self.kind, "path": self.path}
        if self.detail:
            result["detail"] = self.detail
        return result


def _failure(kind: str, path: str, detail: str = "") -> CanonicalConsumerFailure:
    return CanonicalConsumerFailure(kind, path, detail)


def _rows(value: Any, path: str) -> tuple[list[dict[str, Any]] | None, CanonicalConsumerFailure | None]:
    if not isinstance(value, list) or any(not isinstance(row, dict) for row in value):
        return None, _failure("InvalidStructure", path, "expected an array of objects")
    return value, None


def _text(value: Any, path: str) -> CanonicalConsumerFailure | None:
    if not isinstance(value, str) or not value:
        return _failure("InvalidStructure", path, "expected a nonempty string")
    return None


def _fields(row: dict[str, Any], required: set[str], path: str) -> CanonicalConsumerFailure | None:
    if set(row) != required:
        return _failure("InvalidStructure", path, "unexpected relation fields")
    return None


def _index(
    rows: list[dict[str, Any]], field: str, path: str,
) -> tuple[dict[str, dict[str, Any]] | None, CanonicalConsumerFailure | None]:
    indexed: dict[str, dict[str, Any]] = {}
    for offset, row in enumerate(rows):
        identifier = row.get(field)
        if not isinstance(identifier, str) or not identifier:
            return None, _failure("InvalidStructure", f"{path}[{offset}].{field}")
        if identifier in indexed:
            return None, _failure("DuplicateIdentifier", f"{path}[{offset}].{field}")
        indexed[identifier] = row
    return indexed, None


def _unique_pairs(
    rows: list[dict[str, Any]], first: str, second: str, path: str,
) -> CanonicalConsumerFailure | None:
    pairs: set[tuple[str, str]] = set()
    for offset, row in enumerate(rows):
        first_value, second_value = row.get(first), row.get(second)
        if not isinstance(first_value, str) or not first_value or not isinstance(second_value, str) or not second_value:
            return _failure("InvalidStructure", f"{path}[{offset}]")
        pair = (first_value, second_value)
        if pair in pairs:
            return _failure("DuplicateIdentifier", f"{path}[{offset}]")
        pairs.add(pair)
    return None


def _reference(identifier: Any, domain: set[str], path: str) -> CanonicalConsumerFailure | None:
    if not isinstance(identifier, str) or identifier not in domain:
        return _failure("ReferenceClosureFailure", path, str(identifier))
    return None


def _references(
    identifiers: Any, domain: set[str], path: str,
) -> CanonicalConsumerFailure | None:
    if not isinstance(identifiers, list):
        return _failure("InvalidStructure", path, "expected an array")
    for position, identifier in enumerate(identifiers):
        failure = _reference(identifier, domain, f"{path}[{position}]")
        if failure:
            return failure
    return None


def decode_canonical_structure(canonical_json: bytes) -> dict[str, Any] | CanonicalConsumerFailure:
    """Decode, validate, and byte-compare canonical normalized analysis JSON."""
    if not isinstance(canonical_json, bytes):
        return _failure("InvalidCanonicalJson", "$", "expected UTF-8 bytes")
    try:
        decoded = json.loads(canonical_json.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        return _failure("InvalidCanonicalJson", "$", str(exc))
    reencoded = canonical_bytes(decoded)
    if isinstance(reencoded, TypedFailure):
        return _failure("InvalidCanonicalJson", reencoded.path, reencoded.detail)
    if reencoded != canonical_json:
        return _failure("NonCanonicalJson", "$")
    return validate_normalized_analysis_structure(decoded)


def validate_normalized_analysis_structure(value: Any) -> dict[str, Any] | CanonicalConsumerFailure:
    """Validate normalized relation groups and every internal reference."""
    if not isinstance(value, dict):
        return _failure("InvalidStructure", "$")
    required = {"schema_version", "source_revision", "language", *RELATION_GROUPS}
    if set(value) != required:
        return _failure("InvalidStructure", "$")
    if value["schema_version"] != SCHEMA_VERSION:
        return _failure("UnsupportedSchemaVersion", "$.schema_version")
    source_failure = _text(value["source_revision"], "$.source_revision")
    if source_failure:
        return source_failure
    if value["language"] not in {"gleam", "python"}:
        return _failure("InvalidStructure", "$.language")

    groups: dict[str, list[dict[str, Any]]] = {}
    for name in RELATION_GROUPS:
        rows, failure = _rows(value[name], f"$.{name}")
        if failure:
            return failure
        groups[name] = rows or []

    row_shapes = {
        "declarations": {"id", "kind", "name", "type", "span"},
        "types": {"id", "kind", "arguments", "span"},
        "values": {"id", "kind", "type", "declaration", "span"},
        "operation_inputs": {"operation", "parameter", "value", "type", "position", "span"},
        "branches": {"id", "condition", "selected", "span"},
        "control_flow": {"id", "source", "target", "branch"},
        "place_accesses": {"place", "access", "point", "value", "type", "span"},
        "external_effects": {"id", "operation", "kind", "inputs", "result_type", "span"},
        "source_spans": {"id", "path", "digest", "start_byte", "end_byte", "start_line", "start_column", "end_line", "end_column"},
        "stage_correspondences": {"point", "source", "resolved", "lowered", "source_span", "resolved_span", "lowered_span"},
    }
    for name, rows in groups.items():
        for offset, row in enumerate(rows):
            failure = _fields(row, row_shapes[name], f"$.{name}[{offset}]")
            if failure:
                return failure

    declarations, failure = _index(groups["declarations"], "id", "$.declarations")
    if failure:
        return failure
    types, failure = _index(groups["types"], "id", "$.types")
    if failure:
        return failure
    values, failure = _index(groups["values"], "id", "$.values")
    if failure:
        return failure
    branches, failure = _index(groups["branches"], "id", "$.branches")
    if failure:
        return failure
    edges, failure = _index(groups["control_flow"], "id", "$.control_flow")
    if failure:
        return failure
    effects, failure = _index(groups["external_effects"], "id", "$.external_effects")
    if failure:
        return failure
    spans, failure = _index(groups["source_spans"], "id", "$.source_spans")
    if failure:
        return failure
    correspondences, failure = _index(groups["stage_correspondences"], "point", "$.stage_correspondences")
    if failure:
        return failure
    if failure := _unique_pairs(groups["operation_inputs"], "operation", "position", "$.operation_inputs"):
        return failure

    type_ids = set(types or {})
    declaration_ids = set(declarations or {})
    value_ids = set(values or {})
    branch_ids = set(branches or {})
    span_ids = set(spans or {})
    source_points = {row["source"] for row in (correspondences or {}).values()}

    for offset, row in enumerate(groups["declarations"]):
        for field, domain in (("id", declaration_ids), ("kind", None), ("name", None), ("type", type_ids), ("span", span_ids)):
            if domain is None:
                if failure := _text(row[field], f"$.declarations[{offset}].{field}"):
                    return failure
            elif failure := _reference(row[field], domain, f"$.declarations[{offset}].{field}"):
                return failure
    for offset, row in enumerate(groups["types"]):
        if failure := _text(row["kind"], f"$.types[{offset}].kind"):
            return failure
        if failure := _references(row["arguments"], type_ids, f"$.types[{offset}].arguments"):
            return failure
        if failure := _reference(row["span"], span_ids, f"$.types[{offset}].span"):
            return failure
    for offset, row in enumerate(groups["values"]):
        if failure := _text(row["kind"], f"$.values[{offset}].kind"):
            return failure
        for field, domain in (("type", type_ids), ("declaration", declaration_ids), ("span", span_ids)):
            if failure := _reference(row[field], domain, f"$.values[{offset}].{field}"):
                return failure
    for offset, row in enumerate(groups["operation_inputs"]):
        for field in ("operation", "parameter", "position"):
            if failure := _text(row[field], f"$.operation_inputs[{offset}].{field}"):
                return failure
        for field, domain in (("value", value_ids), ("type", type_ids), ("span", span_ids)):
            if failure := _reference(row[field], domain, f"$.operation_inputs[{offset}].{field}"):
                return failure
    for offset, row in enumerate(groups["branches"]):
        if failure := _reference(row["condition"], value_ids, f"$.branches[{offset}].condition"):
            return failure
        if failure := _references(row["selected"], value_ids, f"$.branches[{offset}].selected"):
            return failure
        if failure := _reference(row["span"], span_ids, f"$.branches[{offset}].span"):
            return failure
    for offset, row in enumerate(groups["control_flow"]):
        for field in ("source", "target"):
            if failure := _reference(row[field], source_points, f"$.control_flow[{offset}].{field}"):
                return failure
        if row["branch"] is not None and (failure := _reference(row["branch"], branch_ids, f"$.control_flow[{offset}].branch")):
            return failure
    for offset, row in enumerate(groups["place_accesses"]):
        if row["access"] not in {"read", "write"}:
            return _failure("InvalidStructure", f"$.place_accesses[{offset}].access")
        for field, domain in (("point", source_points), ("value", value_ids), ("type", type_ids), ("span", span_ids)):
            if failure := _reference(row[field], domain, f"$.place_accesses[{offset}].{field}"):
                return failure
    for offset, row in enumerate(groups["external_effects"]):
        for field in ("operation", "kind"):
            if failure := _text(row[field], f"$.external_effects[{offset}].{field}"):
                return failure
        if failure := _references(row["inputs"], value_ids, f"$.external_effects[{offset}].inputs"):
            return failure
        for field, domain in (("result_type", type_ids), ("span", span_ids)):
            if failure := _reference(row[field], domain, f"$.external_effects[{offset}].{field}"):
                return failure
    for offset, row in enumerate(groups["source_spans"]):
        for field in ("id", "path", "digest", "start_byte", "end_byte", "start_line", "start_column", "end_line", "end_column"):
            if failure := _text(row[field], f"$.source_spans[{offset}].{field}"):
                return failure
        if row["digest"] != value["source_revision"]:
            return _failure("ReferenceClosureFailure", f"$.source_spans[{offset}].digest")
    for offset, row in enumerate(groups["stage_correspondences"]):
        for field in ("point", "source", "resolved"):
            if failure := _text(row[field], f"$.stage_correspondences[{offset}].{field}"):
                return failure
        for field in ("source_span", "resolved_span"):
            if failure := _reference(row[field], span_ids, f"$.stage_correspondences[{offset}].{field}"):
                return failure
        lowered, lowered_span = row["lowered"], row["lowered_span"]
        if (lowered is None) != (lowered_span is None):
            return _failure("ReferenceClosureFailure", f"$.stage_correspondences[{offset}]")
        if lowered is not None and (failure := _text(lowered, f"$.stage_correspondences[{offset}].lowered")):
            return failure
        if lowered_span is not None and (failure := _reference(lowered_span, span_ids, f"$.stage_correspondences[{offset}].lowered_span")):
            return failure
    return value


def _source_values(structure: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {
        row["id"].removeprefix("value:"): row
        for row in structure["values"]
        if row["id"].startswith("value:")
    }


def _closed_correspondences(structure: dict[str, Any]) -> dict[str, dict[str, Any]]:
    values = _source_values(structure)
    return {
        row["point"]: row
        for row in structure["stage_correspondences"]
        if (source_value := values.get(row["source"])) is not None
        and source_value["span"] == row["source_span"]
    }


def classify_relation_findings(structure: dict[str, Any]) -> dict[str, Any] | CanonicalConsumerFailure:
    """Classify each correspondence by its closed stage relation."""
    checked = validate_normalized_analysis_structure(structure)
    if isinstance(checked, CanonicalConsumerFailure):
        return checked
    spans = {row["id"]: row for row in checked["source_spans"]}
    closed = _closed_correspondences(checked)
    findings = []
    for row in checked["stage_correspondences"]:
        if row["point"] not in closed:
            classification = "Unclosed"
        elif row["lowered"] is None:
            classification = "Candidate"
        else:
            classification = "Proved"
        findings.append({
            "finding_id": row["point"],
            "classification": classification,
            "source_span": spans[row["source_span"]],
            "relation_evidence": {
                "source": row["source"],
                "resolved": row["resolved"],
                "lowered": row["lowered"],
            },
        })
    return {"findings": {"finite_sequence": findings}}


def _source_evidence(
    evidence_id: str, span: dict[str, Any], claim: str,
) -> dict[str, str]:
    return {
        "evidence_id": evidence_id,
        "source_kind": "Observation",
        "source_ref": span["path"],
        "source_digest": span["digest"],
        "locator": span["id"],
        "claim": claim,
    }


def reduce_normalized_analysis_structure(structure: dict[str, Any]) -> dict[str, Any] | CanonicalConsumerFailure:
    """Reduce closed normalized-analysis relationships to an AnalysisInput."""
    checked = validate_normalized_analysis_structure(structure)
    if isinstance(checked, CanonicalConsumerFailure):
        return checked

    spans = {row["id"]: row for row in checked["source_spans"]}
    source_values = _source_values(checked)
    closed = _closed_correspondences(checked)
    correspondence_by_source = {
        row["source"]: row
        for row in closed.values()
    }
    region_id = "normalized:" + checked["source_revision"]
    points = []
    correspondence_evidence = []
    for correspondence in checked["stage_correspondences"]:
        source_value = source_values.get(correspondence["source"])
        if source_value is None or correspondence["point"] not in closed:
            continue
        point_id = correspondence["point"]
        points.append({
            "point_id": point_id,
            "region_id": region_id,
            "input_weight": {"numerator": 1, "denominator": 1},
            "measure_contribution": {"numerator": 1, "denominator": 1},
            "coordinates": {"finite_map": [{"key": source_value["type"], "value": source_value["id"]}]},
        })
        correspondence_evidence.append(_source_evidence(
            "normalized:correspondence:" + point_id,
            spans[correspondence["source_span"]],
            "normalized stage correspondence " + point_id,
        ))

    branch_rows = []
    branch_evidence = []
    for branch in checked["branches"]:
        selected_by_type: dict[str, list[str]] = {}
        regions_by_type: dict[str, list[str]] = {}
        for value_id in branch["selected"]:
            value = next(row for row in checked["values"] if row["id"] == value_id)
            correspondence = correspondence_by_source.get(value_id.removeprefix("value:"))
            if correspondence is None:
                continue
            selected_by_type.setdefault(value["type"], []).append(value_id)
            regions_by_type.setdefault(value["type"], []).append(correspondence["point"])
        for type_id in sorted(selected_by_type):
            branch_id = branch["id"] + ":" + type_id
            branch_rows.append({
                "branch_id": branch_id,
                "input_region": {"finite_set": sorted(set(regions_by_type[type_id]))},
                "required_type": type_id,
                "required_values": {"finite_set": sorted(set(selected_by_type[type_id]))},
            })
            branch_evidence.append(_source_evidence(
                "normalized:branch:" + branch_id,
                spans[branch["span"]],
                "normalized branch " + branch["id"] + " for " + type_id,
            ))

    declared_points = {
        correspondence_by_source[edge["target"]]["point"]
        for edge in checked["control_flow"]
        if edge["target"] in correspondence_by_source
    }
    for branch in branch_rows:
        declared_points.update(branch["input_region"]["finite_set"])
    declared_evidence = list(correspondence_evidence)
    for edge in checked["control_flow"]:
        target = correspondence_by_source.get(edge["target"])
        if target is not None:
            declared_evidence.append(_source_evidence(
                "normalized:control-flow:" + edge["id"],
                spans[target["source_span"]],
                "normalized control-flow target " + edge["target"],
            ))

    values_by_type: dict[str, list[str]] = {row["id"]: [] for row in checked["types"]}
    for value in checked["values"]:
        values_by_type[value["type"]].append(value["id"])

    axiom_rows = []
    for effect in checked["external_effects"]:
        input_types = sorted({
            next(row for row in checked["values"] if row["id"] == value_id)["type"]
            for value_id in effect["inputs"]
        })
        candidates = sorted(values_by_type[effect["result_type"]])
        for input_type in input_types:
            axiom_rows.append({
                "axiom_id": effect["id"] + ":" + input_type,
                "identity": effect["operation"],
                "input_type": input_type,
                "output_type": effect["result_type"],
                "closed_output_candidates": {"finite_set": candidates},
            })

    point_ids = [point["point_id"] for point in points]
    analysis_input = {
        "schema_version": "necoherence-analysis-1",
        "input_tree": {
            "branch": {
                "branch_id": "normalized-root",
                "children": {"finite_sequence": [{"leaf": point_id} for point_id in point_ids]},
            },
        },
        "input_region": {
            "region_id": region_id,
            "point_ids": {"finite_set": point_ids},
            "weight": {"numerator": 1, "denominator": 1},
        },
        "reachability_points": {"finite_set": points},
        "type_declarations": {
            "finite_set": [
                {"type_id": type_id, "values": {"finite_set": value_ids}}
                for type_id, value_ids in values_by_type.items()
            ],
        },
        "value_declarations": {
            "finite_set": [
                {"value_id": row["id"], "type_id": row["type"]}
                for row in checked["values"]
            ],
        },
        "branches": {"finite_set": branch_rows},
        "declared_reachability": {
            "point_ids": {"finite_set": sorted(declared_points)},
            "evidence": {"finite_set": declared_evidence},
        },
        "derived_reachability": {
            "point_ids": {"finite_set": []},
            "evidence": {"finite_set": branch_evidence},
        },
        "axiom_declarations": {"finite_set": axiom_rows},
    }
    validated = validate_analysis_input(analysis_input)
    if isinstance(validated, TypedFailure):
        return _failure("AnalysisInputFailure", validated.path, validated.kind)
    return validated


def build_common_analysis_presentation(canonical_json: bytes) -> dict[str, Any] | CanonicalConsumerFailure:
    """Build the input shared by every presentation projection."""
    structure = decode_canonical_structure(canonical_json)
    if isinstance(structure, CanonicalConsumerFailure):
        return structure
    findings = classify_relation_findings(structure)
    if isinstance(findings, CanonicalConsumerFailure):
        return findings
    analysis_input = reduce_normalized_analysis_structure(structure)
    if isinstance(analysis_input, CanonicalConsumerFailure):
        return analysis_input
    report = calculate_report(analysis_input)
    if isinstance(report, TypedFailure):
        return _failure("ReportFailure", report.path, report.kind)
    return {
        "validated_structure": structure,
        "findings": findings,
        "analysis_input": analysis_input,
        "report": report,
    }


def table_projection(presentation: dict[str, Any]) -> list[dict[str, Any]]:
    return list(presentation["findings"]["findings"]["finite_sequence"])


def lsp_diagnostic_projection(presentation: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        {"message": finding["classification"], "range": finding["source_span"]}
        for finding in table_projection(presentation)
    ]


def semantic_token_projection(presentation: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        {"classification": finding["classification"], "span": finding["source_span"]}
        for finding in table_projection(presentation)
    ]


def hover_projection(presentation: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        {"contents": finding["relation_evidence"], "range": finding["source_span"]}
        for finding in table_projection(presentation)
    ]


def code_lens_projection(presentation: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        {"title": finding["classification"], "range": finding["source_span"]}
        for finding in table_projection(presentation)
    ]


__all__ = [
    "SCHEMA_VERSION",
    "RELATION_GROUPS",
    "CanonicalConsumerFailure",
    "decode_canonical_structure",
    "validate_normalized_analysis_structure",
    "classify_relation_findings",
    "reduce_normalized_analysis_structure",
    "build_common_analysis_presentation",
    "table_projection",
    "lsp_diagnostic_projection",
    "semantic_token_projection",
    "hover_projection",
    "code_lens_projection",
]
