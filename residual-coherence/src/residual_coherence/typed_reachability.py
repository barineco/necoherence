# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

"""Validate and reduce versioned typed reachability artifacts."""

from __future__ import annotations

import copy
from dataclasses import dataclass
import re
from typing import Any, Final, cast

from .core import (
    SHA256_DIGEST_PATTERN,
    TypedFailure,
    calculate_report,
    canonical_bytes,
    canonical_digest,
    validate_analysis_input,
)

ARTIFACT_SCHEMA_VERSION: Final = {"name": "necoherence-typed-reachability", "major": 1}
DIAGNOSTIC_SCHEMA_VERSION: Final = {"name": "necoherence-reachability-diagnostic", "major": 1}
FAILURE_KINDS: Final = frozenset({
    "InvalidArtifactVersion", "InvalidSourceRevision", "IdentifierNormalizationFailure",
    "DuplicateIdentity", "TypeClosureFailure", "ConstructorClosureFailure", "BranchClosureFailure",
    "ReachabilityClosureFailure", "PlaceClosureFailure", "AxiomClosureFailure", "SpanClosureFailure",
    "CorrespondenceClosureFailure", "AnalysisInputFailure", "CanonicalEncodingFailure",
    "VerificationFailure",
})
_IDENTIFIER = re.compile(r"^[a-z]+:[^%#:\x00-\x1f\x7f]+#[a-z]+:[0-9]+:[0-9]+$")


@dataclass(frozen=True)
class ReachabilityReductionFailure:
    kind: str
    path: str = "$"
    detail: str = ""

    def __post_init__(self) -> None:
        if self.kind not in FAILURE_KINDS:
            raise ValueError(f"unknown ReachabilityReductionFailure kind: {self.kind}")

    def as_dict(self) -> dict[str, str]:
        value = {"kind": self.kind, "path": self.path}
        if self.detail:
            value["detail"] = self.detail
        return value


def _failure(kind: str, path: str, detail: str = "") -> ReachabilityReductionFailure:
    return ReachabilityReductionFailure(kind, path, detail)


def _items(value: Any, path: str) -> tuple[list[Any], ReachabilityReductionFailure | None]:
    if not isinstance(value, dict) or set(value) != {"finite_set"} or not isinstance(value["finite_set"], list):
        return [], _failure("TypeClosureFailure", path, "expected finite_set")
    return value["finite_set"], None


def _index(items: list[Any], field: str, path: str) -> tuple[dict[str, dict[str, Any]], ReachabilityReductionFailure | None]:
    result: dict[str, dict[str, Any]] = {}
    for offset, item in enumerate(items):
        if not isinstance(item, dict):
            return {}, _failure("IdentifierNormalizationFailure", f"{path}[{offset}].{field}")
        identifier = item.get(field)
        if not isinstance(identifier, str) or not _IDENTIFIER.fullmatch(identifier):
            return {}, _failure("IdentifierNormalizationFailure", f"{path}[{offset}].{field}")
        if identifier in result:
            return {}, _failure("DuplicateIdentity", f"{path}[{offset}].{field}")
        result[identifier] = item
    return result, None


def _correspondence_row_closed(
    row: Any, type_constructors: dict[str, set[str]], spans: Any,
) -> bool:
    type_id = row.get("type_id") if isinstance(row, dict) else None
    if type_id not in type_constructors:
        return False
    constructors_for_type = type_constructors[type_id]
    if any(row.get(stage) not in constructors_for_type for stage in ("surface_id", "core_id", "native_id")):
        return False
    if any(row.get(stage) not in spans for stage in ("surface_span_id", "core_span_id", "native_span_id")):
        return False
    return True


def validate_typed_reachability(value: Any) -> dict[str, Any] | ReachabilityReductionFailure:
    if not isinstance(value, dict) or value.get("artifact_schema_version") != ARTIFACT_SCHEMA_VERSION:
        return _failure("InvalidArtifactVersion", "$.artifact_schema_version")
    source_revision = value.get("source_revision")
    if (
        not isinstance(source_revision, dict)
        or set(source_revision) != {"repository", "revision", "tree_digest"}
        or any(not isinstance(source_revision.get(field), str) or not source_revision[field] for field in source_revision)
    ):
        return _failure("InvalidSourceRevision", "$.source_revision")
    required = {"artifact_schema_version", "source_revision", "finite_closed_type_set", "constructor_domain", "branch_regions", "declared_reachability", "inferred_reachability", "places", "axiom_calls", "source_spans", "correspondence"}
    if set(value) != required:
        return _failure("InvalidArtifactVersion", "$", "unexpected fields")
    type_items, failure = _items(value["finite_closed_type_set"], "$.finite_closed_type_set")
    if failure:
        return failure
    types, failure = _index(type_items or [], "type_id", "$.finite_closed_type_set.finite_set")
    if failure:
        return failure
    constructor_items, failure = _items(value["constructor_domain"], "$.constructor_domain")
    if failure:
        return _failure("ConstructorClosureFailure", failure.path)
    constructors, failure = _index(constructor_items or [], "constructor_id", "$.constructor_domain.finite_set")
    if failure:
        return failure
    type_constructors: dict[str, set[str]] = {}
    for type_id, declaration in (types or {}).items():
        ids, item_failure = _items(declaration.get("constructor_ids"), f"$.finite_closed_type_set.{type_id}.constructor_ids")
        if item_failure or any(not isinstance(identifier, str) for identifier in ids or []):
            return _failure("TypeClosureFailure", f"$.finite_closed_type_set.{type_id}.constructor_ids")
        if len(ids or []) != len(set(ids or [])):
            return _failure("DuplicateIdentity", f"$.finite_closed_type_set.{type_id}.constructor_ids")
        type_constructors[type_id] = set(ids or [])
    for constructor_id, declaration in (constructors or {}).items():
        owner = declaration.get("owner_type_id")
        payload = declaration.get("payload_type_ids")
        if owner not in types or constructor_id not in type_constructors.get(owner, set()) or not isinstance(payload, dict) or set(payload) != {"finite_sequence"} or any(item not in types for item in payload["finite_sequence"]):
            return _failure("ConstructorClosureFailure", f"$.constructor_domain.{constructor_id}")
    if set(constructors or {}) != set().union(*type_constructors.values()) if type_constructors else set(constructors or {}):
        return _failure("ConstructorClosureFailure", "$.constructor_domain")
    span_items, failure = _items(value["source_spans"], "$.source_spans")
    if failure:
        return _failure("SpanClosureFailure", failure.path)
    spans, failure = _index(span_items or [], "span_id", "$.source_spans.finite_set")
    if failure:
        return failure
    for span_id, span in (spans or {}).items():
        if not isinstance(span.get("source_path"), str) or not span["source_path"] or not re.fullmatch(r"sha256:[0-9a-f]{64}", str(span.get("source_digest"))) or any(not isinstance(span.get(name), int) or isinstance(span.get(name), bool) for name in ("start_byte","end_byte","start_line","start_column","end_line","end_column")) or span["start_byte"] > span["end_byte"] or min(span["start_line"],span["start_column"],span["end_line"],span["end_column"]) < 1:
            return _failure("SpanClosureFailure", f"$.source_spans.{span_id}")
    correspondence_items, failure = _items(value["correspondence"], "$.correspondence")
    if failure:
        return _failure("CorrespondenceClosureFailure", failure.path)
    correspondence, failure = _index(correspondence_items or [], "point_id", "$.correspondence.finite_set")
    if failure:
        return failure
    for point_id, row in (correspondence or {}).items():
        if not _correspondence_row_closed(row, type_constructors, spans):
            return _failure("CorrespondenceClosureFailure", f"$.correspondence.{point_id}")
    point_ids = set(correspondence or {})
    branch_items, failure = _items(value["branch_regions"], "$.branch_regions")
    if failure:
        return _failure("BranchClosureFailure", failure.path)
    branches, failure = _index(branch_items or [], "branch_id", "$.branch_regions.finite_set")
    if failure:
        return failure
    for branch_id, branch in (branches or {}).items():
        required_constructor_ids, required_failure = _items(branch.get("required_constructor_ids"), f"$.branch_regions.{branch_id}.required_constructor_ids")
        branch_points, points_failure = _items(branch.get("point_ids"), f"$.branch_regions.{branch_id}.point_ids")
        required_type = branch.get("required_type_id")
        if required_failure or points_failure or not branch_points or required_type not in types or any(item not in type_constructors[required_type] for item in required_constructor_ids) or any(item not in point_ids for item in branch_points) or branch.get("span_id") not in spans or not isinstance(branch.get("region_id"), str) or not _IDENTIFIER.fullmatch(branch["region_id"]):
            return _failure("BranchClosureFailure", f"$.branch_regions.{branch_id}")
    for claim_name in ("declared_reachability", "inferred_reachability"):
        claim = value[claim_name]
        ids, ids_failure = _items(claim.get("point_ids") if isinstance(claim, dict) else None, f"$.{claim_name}.point_ids")
        evidence, evidence_failure = _items(claim.get("evidence") if isinstance(claim, dict) else None, f"$.{claim_name}.evidence")
        if ids_failure or evidence_failure or any(item not in point_ids for item in ids or []) or not evidence:
            return _failure("ReachabilityClosureFailure", f"$.{claim_name}")
    place_items, failure = _items(value["places"], "$.places")
    if failure:
        return _failure("PlaceClosureFailure", failure.path)
    places, failure = _index(place_items or [], "place_id", "$.places.finite_set")
    if failure:
        return failure
    for place_id, place in (places or {}).items():
        if place.get("access") not in {"Read","Write"} or place.get("point_id") not in point_ids or place.get("type_id") not in types or place.get("value_id") not in type_constructors[place["type_id"]] or place.get("span_id") not in spans:
            return _failure("PlaceClosureFailure", f"$.places.{place_id}")
    axiom_items, failure = _items(value["axiom_calls"], "$.axiom_calls")
    if failure:
        return _failure("AxiomClosureFailure", failure.path)
    axioms, failure = _index(axiom_items or [], "axiom_id", "$.axiom_calls.finite_set")
    if failure:
        return failure
    for axiom_id, axiom in (axioms or {}).items():
        candidates, candidate_failure = _items(axiom.get("output_candidate_value_ids"), f"$.axiom_calls.{axiom_id}.output_candidate_value_ids")
        output_type = axiom.get("output_type_id")
        if candidate_failure or axiom.get("input_type_id") not in types or output_type not in types or any(item not in type_constructors[output_type] for item in candidates or []) or axiom.get("point_id") not in point_ids or axiom.get("span_id") not in spans or not isinstance(axiom.get("identity"), str) or not axiom["identity"]:
            return _failure("AxiomClosureFailure", f"$.axiom_calls.{axiom_id}")
    return value


def _map_typed_failure(failure: TypedFailure) -> ReachabilityReductionFailure:
    return _failure("AnalysisInputFailure", failure.path, failure.kind + (f": {failure.detail}" if failure.detail else ""))


def reduce_typed_reachability(value: Any) -> dict[str, Any] | ReachabilityReductionFailure:
    validated = validate_typed_reachability(value)
    if isinstance(validated, ReachabilityReductionFailure):
        return validated
    correspondence = sorted(validated["correspondence"]["finite_set"], key=lambda row: row["point_id"].encode("utf-8"))
    spans = {row["span_id"]: row for row in validated["source_spans"]["finite_set"]}
    branch_rows = validated["branch_regions"]["finite_set"]
    region_id = "source-revision:" + validated["source_revision"]["revision"]
    points = []
    values: dict[str, str] = {}
    for row in correspondence:
        span = spans[row["surface_span_id"]]
        for stage in ("surface_id","core_id","native_id"):
            previous = values.get(row[stage])
            if previous is not None and previous != row["type_id"]:
                return _failure("AnalysisInputFailure", "$.value_declarations", "one value has multiple types")
            values[row[stage]] = row["type_id"]
        points.append({"point_id":row["point_id"],"region_id":region_id,"input_weight":{"numerator":1,"denominator":1},"measure_contribution":{"numerator":1,"denominator":1},"coordinates":{"finite_map":[{"key":row["type_id"],"value":row["surface_id"]},{"key":"core_id","value":row["core_id"]},{"key":"native_id","value":row["native_id"]},{"key":"primary_span_id","value":row["surface_span_id"]},{"key":"source_path","value":span["source_path"]},{"key":"surface_id","value":row["surface_id"]},{"key":"type_id","value":row["type_id"]}]}})
    for place in validated["places"]["finite_set"]:
        values[place["value_id"]] = place["type_id"]
    branches = [{"branch_id":row["branch_id"],"input_region":{"finite_set":row["point_ids"]["finite_set"]},"required_type":row["required_type_id"],"required_values":{"finite_set":row["required_constructor_ids"]["finite_set"]}} for row in branch_rows]
    analysis_input = {
        "schema_version":"necoherence-analysis-1",
        "input_tree":{"branch":{"branch_id":"typed-reachability-root","children":{"finite_sequence":[{"leaf":row["point_id"]} for row in correspondence]}}},
        "input_region":{"region_id":region_id,"point_ids":{"finite_set":[row["point_id"] for row in correspondence]},"weight":{"numerator":1,"denominator":1}},
        "reachability_points":{"finite_set":points},
        "type_declarations":{"finite_set":[{"type_id":row["type_id"],"values":{"finite_set":row["constructor_ids"]["finite_set"]}} for row in validated["finite_closed_type_set"]["finite_set"]]},
        "value_declarations":{"finite_set":[{"value_id":value_id,"type_id":type_id} for value_id,type_id in sorted(values.items())]},
        "branches":{"finite_set":branches},
        "declared_reachability":validated["declared_reachability"],
        "derived_reachability":validated["inferred_reachability"],
        "axiom_declarations":{"finite_set":[{"axiom_id":row["axiom_id"],"identity":row["identity"],"input_type":row["input_type_id"],"output_type":row["output_type_id"],"closed_output_candidates":row["output_candidate_value_ids"]} for row in validated["axiom_calls"]["finite_set"]]},
    }
    checked = validate_analysis_input(analysis_input)
    if isinstance(checked, TypedFailure):
        return _map_typed_failure(checked)
    return checked


def diagnose_typed_reachability(value: Any) -> dict[str, Any] | ReachabilityReductionFailure:
    validated = validate_typed_reachability(value)
    if isinstance(validated, ReachabilityReductionFailure):
        return validated
    reduced = reduce_typed_reachability(validated)
    if isinstance(reduced, ReachabilityReductionFailure):
        return reduced
    report = calculate_report(reduced)
    if isinstance(report, TypedFailure):
        return _map_typed_failure(report)
    spans = {row["span_id"]: row for row in validated["source_spans"]["finite_set"]}
    correspondence = {row["point_id"]: row for row in validated["correspondence"]["finite_set"]}
    locations = []
    for point_id in report["residual_point_ids"]["finite_set"]:
        row = correspondence[point_id]
        span = spans[row["surface_span_id"]]
        locations.append({"point_id":point_id,"span_id":row["surface_span_id"],"source_path":span["source_path"],"start_line":span["start_line"],"start_column":span["start_column"],"end_line":span["end_line"],"end_column":span["end_column"],"_start_byte":span["start_byte"],"_end_byte":span["end_byte"]})
    locations.sort(key=lambda item:(item["source_path"].encode("utf-8"),item["_start_byte"],item["_end_byte"],item["point_id"].encode("utf-8")))
    for priority, location in enumerate(locations, 1):
        location["priority"] = priority
        del location["_start_byte"]
        del location["_end_byte"]
    return {"diagnostic_schema_version":DIAGNOSTIC_SCHEMA_VERSION,"artifact_schema_version":validated["artifact_schema_version"],"source_revision":validated["source_revision"],"residual_coherence":report,"locations":{"finite_sequence":locations},"diagnostic_only":True}


def _independent_source_revision(source_revision: dict[str, Any]) -> dict[str, str]:
    return {
        field: "independent-check:" + str(source_revision.get(field, ""))
        for field in ("repository", "revision", "tree_digest")
    }


def _without_source_revision(value: dict[str, Any]) -> dict[str, Any]:
    return {key: item for key, item in value.items() if key != "source_revision"}


def _typed_witness(
    witness_id: str, matched: bool, observed: Any, expected: Any, evidence: list[dict[str, Any]],
) -> dict[str, Any]:
    return {
        "witness_id": witness_id,
        "status": "ok" if matched else "error",
        "observed": observed,
        "expected": expected,
        "matched": matched,
        "evidence": {"finite_set": evidence},
    }


def _typed_evidence(evidence_id: str, source_ref: str, claim: str, source_value: Any) -> dict[str, Any] | ReachabilityReductionFailure:
    digest = canonical_digest(source_value)
    if isinstance(digest, TypedFailure):
        return _failure("CanonicalEncodingFailure", "$", "evidence digest calculation failed")
    return {
        "evidence_id": evidence_id,
        "source_kind": "Observation",
        "source_ref": source_ref,
        "source_digest": digest,
        "locator": "typed-reachability:" + evidence_id,
        "claim": claim,
    }


def _product(product_id: str, proposition: str, matched: bool, evidence: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "product_id": product_id,
        "proposition": proposition,
        "status": "PROVED" if matched else "UNRESOLVED",
        "evidence": {"finite_set": evidence},
    }


def verify_typed_reachability(value: Any, provenance: dict[str, str]) -> dict[str, Any] | ReachabilityReductionFailure:
    """Verify a typed reachability artifact by recomputing each witness from this invocation's input."""
    validated = validate_typed_reachability(value)
    if isinstance(validated, ReachabilityReductionFailure):
        return validated
    reduced = reduce_typed_reachability(value)
    if isinstance(reduced, ReachabilityReductionFailure):
        return reduced
    diagnostic = diagnose_typed_reachability(value)
    if isinstance(diagnostic, ReachabilityReductionFailure):
        return diagnostic
    first = canonical_bytes(reduced)
    second_reduction = reduce_typed_reachability(value)
    if isinstance(second_reduction, ReachabilityReductionFailure):
        return second_reduction
    second = canonical_bytes(second_reduction)
    reduced_digest = canonical_digest(reduced)
    if isinstance(first, TypedFailure) or isinstance(second, TypedFailure) or isinstance(reduced_digest, TypedFailure):
        return _failure("CanonicalEncodingFailure", "$", "reduction canonical encoding failed")
    determinism_matched = first == second
    if len(provenance) != 2 or any(not isinstance(item, str) or not SHA256_DIGEST_PATTERN.fullmatch(item) for item in provenance.values()):
        return _failure("VerificationFailure", "$.provenance")

    source_revision = validated["source_revision"]
    types = {row["type_id"]: set(row["constructor_ids"]["finite_set"]) for row in validated["finite_closed_type_set"]["finite_set"]}
    spans = {row["span_id"] for row in validated["source_spans"]["finite_set"]}
    point_ids = {row["point_id"] for row in validated["correspondence"]["finite_set"]}

    substituted_revision = _independent_source_revision(source_revision)
    substituted_artifact = copy.deepcopy(validated)
    substituted_artifact["source_revision"] = substituted_revision
    substituted_validated = validate_typed_reachability(substituted_artifact)
    substituted_reduced = reduce_typed_reachability(substituted_artifact)
    substituted_diagnostic = diagnose_typed_reachability(substituted_artifact)
    project_accepted = (
        isinstance(substituted_validated, dict)
        and isinstance(substituted_reduced, dict)
        and isinstance(substituted_diagnostic, dict)
    )
    project_revision_preserved = project_accepted and cast(dict[str, Any], substituted_diagnostic).get("source_revision") == substituted_revision
    project_region_rebased = project_accepted and str(
        cast(dict[str, Any], substituted_reduced)["input_region"]["region_id"]
    ) == "source-revision:" + substituted_revision["revision"]
    non_revision_structure_preserved = (
        canonical_bytes(_without_source_revision(validated)) == canonical_bytes(_without_source_revision(substituted_artifact))
    )
    project_matched = bool(
        project_accepted and project_revision_preserved and project_region_rebased and non_revision_structure_preserved
    )
    project_observed = {
        "original_source_revision": source_revision,
        "substituted_source_revision": substituted_revision,
        "substituted_artifact_accepted": project_accepted,
        "substituted_diagnostic_source_revision": (
            cast(dict[str, Any], substituted_diagnostic).get("source_revision") if project_accepted else None
        ),
        "substituted_reduction_region_id": (
            cast(dict[str, Any], substituted_reduced)["input_region"]["region_id"] if project_accepted else None
        ),
        "non_revision_structure_preserved": non_revision_structure_preserved,
    }
    project_expected = {
        "substituted_artifact_accepted": True,
        "substituted_diagnostic_source_revision": substituted_revision,
        "substituted_reduction_region_id": "source-revision:" + substituted_revision["revision"],
        "non_revision_structure_preserved": True,
    }
    project_evidence = _typed_evidence(
        "e-project-independence",
        "source_revision",
        "source project identity is accepted as input and preserved, without requiring one project-specific value",
        project_observed,
    )
    if isinstance(project_evidence, ReachabilityReductionFailure):
        return project_evidence

    closure_evidence = _typed_evidence("e-typed-closure", "validated-artifact-and-reduction", "validate_typed_reachability and validate_analysis_input both accepted this input", {"reduced_digest": reduced_digest})
    if isinstance(closure_evidence, ReachabilityReductionFailure):
        return closure_evidence
    closure_matched = isinstance(validated, dict) and isinstance(reduced, dict)

    places = validated["places"]["finite_set"]
    place_closed = [
        place["place_id"]
        for place in places
        if place.get("point_id") in point_ids
        and place.get("type_id") in types
        and place.get("value_id") in types.get(place.get("type_id"), set())
        and place.get("span_id") in spans
    ]
    place_observed = {"place_count": len(places), "closed_count": len(place_closed)}
    place_matched = len(place_closed) == len(places)
    place_evidence = _typed_evidence("e-place-connection", "places", "every place is closed over point, type, constructor value, and span", place_observed)
    if isinstance(place_evidence, ReachabilityReductionFailure):
        return place_evidence

    axiom_calls = validated["axiom_calls"]["finite_set"]
    axiom_closed = [
        axiom["axiom_id"]
        for axiom in axiom_calls
        if axiom.get("input_type_id") in types
        and axiom.get("output_type_id") in types
        and set(axiom.get("output_candidate_value_ids", {}).get("finite_set", [])) <= types.get(axiom.get("output_type_id"), set())
        and axiom.get("point_id") in point_ids
        and axiom.get("span_id") in spans
    ]
    axiom_observed = {"axiom_count": len(axiom_calls), "closed_count": len(axiom_closed)}
    axiom_matched = len(axiom_closed) == len(axiom_calls)
    axiom_evidence = _typed_evidence("e-axiom-connection", "axiom_calls", "every axiom call is closed over input/output type, output candidates, point, and span", axiom_observed)
    if isinstance(axiom_evidence, ReachabilityReductionFailure):
        return axiom_evidence

    correspondence_rows = validated["correspondence"]["finite_set"]
    correspondence_closed = [
        row["point_id"]
        for row in correspondence_rows
        if _correspondence_row_closed(row, types, spans)
    ]
    correspondence_observed = {"correspondence_count": len(correspondence_rows), "closed_count": len(correspondence_closed)}
    correspondence_matched = len(correspondence_closed) == len(correspondence_rows)
    correspondence_evidence = _typed_evidence("e-representation-correspondence", "correspondence", "every correspondence is closed over type, three-stage constructor, and three-stage span", correspondence_observed)
    if isinstance(correspondence_evidence, ReachabilityReductionFailure):
        return correspondence_evidence

    determinism_observed = {"first_digest": reduced_digest, "second_bytes_equal": determinism_matched}
    determinism_evidence = _typed_evidence("e-deterministic-reduction", "reduction", "two reductions of the same input produce identical canonical bytes", determinism_observed)
    if isinstance(determinism_evidence, ReachabilityReductionFailure):
        return determinism_evidence

    diagnostic_matched = bool(
        diagnostic.get("diagnostic_only") is True
        and diagnostic.get("source_revision") == source_revision
        and diagnostic.get("artifact_schema_version") == validated["artifact_schema_version"]
    )
    diagnostic_observed = {
        "diagnostic_only": diagnostic.get("diagnostic_only"),
        "source_revision": diagnostic.get("source_revision"),
        "artifact_schema_version": diagnostic.get("artifact_schema_version"),
    }
    diagnostic_evidence = _typed_evidence("e-diagnostic-only", "diagnostic", "the diagnostic is marked diagnostic_only and retains the input artifact schema version and source revision", diagnostic_observed)
    if isinstance(diagnostic_evidence, ReachabilityReductionFailure):
        return diagnostic_evidence

    recomputed_report = calculate_report(reduced)
    if isinstance(recomputed_report, TypedFailure):
        return _map_typed_failure(recomputed_report)
    composability_matched = canonical_bytes(recomputed_report) == canonical_bytes(diagnostic["residual_coherence"])
    composability_observed = {"recomputed_report_digest": canonical_digest(recomputed_report), "diagnostic_report_digest": canonical_digest(diagnostic["residual_coherence"])}
    composability_evidence = _typed_evidence("e-composability", "residual_coherence", "the report recomputed from the reduction matches the diagnostic residual_coherence", composability_observed)
    if isinstance(composability_evidence, ReachabilityReductionFailure):
        return composability_evidence

    witnesses = [
        _typed_witness("ProjectIndependence", project_matched, project_observed, project_expected, [project_evidence]),
        _typed_witness("TypedClosure", closure_matched, {"artifact_valid": isinstance(validated, dict), "analysis_input_valid": isinstance(reduced, dict)}, {"artifact_valid": True, "analysis_input_valid": True}, [closure_evidence]),
        _typed_witness("PlaceConnection", place_matched, place_observed, {"closed_count": place_observed["place_count"]}, [place_evidence]),
        _typed_witness("AxiomConnection", axiom_matched, axiom_observed, {"closed_count": axiom_observed["axiom_count"]}, [axiom_evidence]),
        _typed_witness("RepresentationCorrespondence", correspondence_matched, correspondence_observed, {"closed_count": correspondence_observed["correspondence_count"]}, [correspondence_evidence]),
        _typed_witness("DeterministicReduction", determinism_matched, determinism_observed, {"second_bytes_equal": True}, [determinism_evidence]),
        _typed_witness("DiagnosticOnly", diagnostic_matched, diagnostic_observed, {"diagnostic_only": True, "source_revision": source_revision, "artifact_schema_version": validated["artifact_schema_version"]}, [diagnostic_evidence]),
        _typed_witness("Composability", composability_matched, composability_observed, {"recomputed_report_digest": composability_observed["diagnostic_report_digest"], "diagnostic_report_digest": composability_observed["diagnostic_report_digest"]}, [composability_evidence]),
    ]

    products = [
        _product("ArtifactRequirement", "The typed reachability artifact validates against its closure requirements.", closure_matched, [closure_evidence]),
        _product("Reduction", "The artifact reduces deterministically to a validated AnalysisInput.", determinism_matched and closure_matched, [determinism_evidence]),
        _product("Diagnostic", "The diagnostic is diagnostic-only and retains its source artifact identity.", diagnostic_matched, [diagnostic_evidence]),
        _product(
            "FailureCoverage",
            "Places, axiom calls, and representation correspondences are individually closed over the validated artifact.",
            place_matched and axiom_matched and correspondence_matched and closure_matched,
            [place_evidence, axiom_evidence, correspondence_evidence],
        ),
        _product(
            "Verification",
            "All acceptance witnesses for this typed reachability artifact matched.",
            all(witness["matched"] for witness in witnesses),
            [project_evidence, composability_evidence],
        ),
    ]

    return {
        "acceptance_witnesses": {"finite_sequence": witnesses},
        "production_reachability": {"finite_sequence": products},
        "reduction_digest": reduced_digest,
        "diagnostic": diagnostic,
        "provenance": provenance,
        "unobserved_scope": {"finite_set": ["RuntimeLibraryIndependence"]},
    }


__all__ = ["ReachabilityReductionFailure", "validate_typed_reachability", "reduce_typed_reachability", "diagnose_typed_reachability", "verify_typed_reachability"]
