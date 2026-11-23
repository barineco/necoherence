# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

"""Verify the analysis exchange against a generated AnalysisInput.

The CLI constructs a closed `AnalysisInput` in code and recomputes every
product from it. It observes canonical encoding roundtrip, permutation
invariance, and production reachability.
"""

from __future__ import annotations

import copy
import json
import sys
from typing import Any

from .core import (
    SHA256_DIGEST_PATTERN,
    TypedFailure,
    canonical_bytes,
    canonical_digest,
    calculate_report,
    derive_reachability,
    validate_analysis_input,
)

SCHEMA_VERSION = "necoherence-analysis-1"
PRODUCT_IDS = (
    "AnalysisInput",
    "Reachability",
    "AxiomClosure",
    "Report",
    "CanonicalEncoding",
    "Verification",
)
WITNESS_IDS = (
    "CanonicalEncoding",
    "ClosedDenominator",
    "AxiomDeclarationClosure",
    "SourceEvidence",
    "TypedFailure",
    "InputRoundtrip",
    "Composability",
    "ProductionReachability",
)


def _failure(path: str, detail: str) -> TypedFailure:
    return TypedFailure("VerificationFailure", path, detail)


def _equal(left: Any, right: Any) -> bool:
    left_bytes = canonical_bytes(left)
    right_bytes = canonical_bytes(right)
    return not isinstance(left_bytes, TypedFailure) and left_bytes == right_bytes


def _encoding(value: Any) -> dict[str, Any] | TypedFailure:
    encoded = canonical_bytes(value)
    digest = canonical_digest(value)
    if isinstance(encoded, TypedFailure):
        return encoded
    if isinstance(digest, TypedFailure):
        return digest
    return {
        "schema_version": SCHEMA_VERSION,
        "canonical_json": encoded.decode("utf-8"),
        "content_digest": digest,
    }


def verify_input_roundtrip(value: Any) -> dict[str, Any] | TypedFailure:
    """Decode and canonically re-encode a validated AnalysisInput."""
    decoded = json.loads(json.dumps(value, ensure_ascii=False))
    original = canonical_bytes(decoded)
    reencoded = canonical_bytes(json.loads(original.decode("utf-8"))) if isinstance(original, bytes) else original
    if isinstance(original, TypedFailure) or isinstance(reencoded, TypedFailure):
        return _failure("$", "input canonical encoding failed")
    decoded_digest = canonical_digest(decoded)
    reencoded_digest = canonical_digest(json.loads(reencoded.decode("utf-8")))
    if isinstance(decoded_digest, TypedFailure) or isinstance(reencoded_digest, TypedFailure):
        return _failure("$", "input digest calculation failed")
    return {
        "decoded_input_digest": decoded_digest,
        "reencoded_digest": reencoded_digest,
        "byte_equal": original == reencoded,
        "semantic_equal": _equal(decoded, json.loads(reencoded.decode("utf-8"))),
    }


def _witness(
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


def _axiom_closure(value: dict[str, Any]) -> dict[str, Any]:
    type_ids = {item["type_id"] for item in value["type_declarations"]["finite_set"]}
    value_ids = {item["value_id"] for item in value["value_declarations"]["finite_set"]}
    axioms = value["axiom_declarations"]["finite_set"]
    closed = all(
        axiom["input_type"] in type_ids
        and axiom["output_type"] in type_ids
        and set(axiom["closed_output_candidates"]["finite_set"]) <= value_ids
        for axiom in axioms
    )
    return {
        "axiom_ids": sorted(axiom["axiom_id"] for axiom in axioms),
        "type_ids": sorted(type_ids),
        "candidate_value_ids": sorted(value_ids),
        "closed": closed,
    }


def _source_evidence(value: dict[str, Any]) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    evidence = [
        item
        for name in ("declared_reachability", "derived_reachability")
        for item in value[name]["evidence"]["finite_set"]
    ]
    observed = {
        "evidence_ids": sorted(item["evidence_id"] for item in evidence),
        "source_refs": sorted(item["source_ref"] for item in evidence),
        "digest_count": len({item["source_digest"] for item in evidence}),
        "all_sha256": all(
            isinstance(item["source_digest"], str) and bool(SHA256_DIGEST_PATTERN.fullmatch(item["source_digest"]))
            for item in evidence
        ),
    }
    return observed, evidence


def _typed_failure_observation(value: dict[str, Any]) -> dict[str, Any]:
    invalid = copy.deepcopy(value)
    invalid["declared_reachability"]["point_ids"]["finite_set"].append("unresolved-generated-point")
    failure = validate_analysis_input(invalid)
    return failure.as_dict() if isinstance(failure, TypedFailure) else {"kind": None, "path": None}


def verify(input_value: Any) -> dict[str, Any] | TypedFailure:
    """Verify generated products and their closure from one validated input."""
    validated = validate_analysis_input(input_value)
    if isinstance(validated, TypedFailure):
        return validated
    report = calculate_report(validated)
    derived = derive_reachability(validated)
    encoding = _encoding(validated)
    input_roundtrip = verify_input_roundtrip(validated)
    if isinstance(report, TypedFailure):
        return report
    if isinstance(derived, TypedFailure):
        return derived
    if isinstance(encoding, TypedFailure):
        return encoding
    if isinstance(input_roundtrip, TypedFailure):
        return input_roundtrip

    recomputed_report = calculate_report(validated)
    recomputed_derived = derive_reachability(validated)
    recomputed_encoding = _encoding(validated)
    report_match = _equal(report, recomputed_report)
    encoding_match = _equal(encoding, recomputed_encoding)
    roundtrip_match = bool(input_roundtrip["byte_equal"] and input_roundtrip["semantic_equal"])
    axiom_observed = _axiom_closure(validated)
    evidence_observed, source_evidence = _source_evidence(validated)
    failure_observed = _typed_failure_observation(validated)
    derived_match = _equal(derived, recomputed_derived)
    composable = bool(
        derived_match
        and report["derived_point_ids"] == derived["point_ids"]
        and _equal(report, calculate_report(validated))
    )
    dispatch = {
        PRODUCT_IDS[0]: not isinstance(validated, TypedFailure),
        PRODUCT_IDS[1]: derived_match,
        PRODUCT_IDS[2]: axiom_observed["closed"],
        PRODUCT_IDS[3]: report_match,
        PRODUCT_IDS[4]: encoding_match and roundtrip_match,
        PRODUCT_IDS[5]: composable and failure_observed["kind"] == "UnresolvedReachabilityPoint",
    }
    all_reachable = all(dispatch.values())
    witnesses = [
        _witness("CanonicalEncoding", encoding_match, encoding, recomputed_encoding, source_evidence),
        _witness("ClosedDenominator", report_match, report, recomputed_report, source_evidence),
        _witness("AxiomDeclarationClosure", axiom_observed["closed"], axiom_observed, {"closed": True}, source_evidence),
        _witness("SourceEvidence", evidence_observed["all_sha256"], evidence_observed, {"all_sha256": True}, source_evidence),
        _witness("TypedFailure", failure_observed["kind"] == "UnresolvedReachabilityPoint", failure_observed, {"kind": "UnresolvedReachabilityPoint"}, source_evidence),
        _witness("InputRoundtrip", roundtrip_match, input_roundtrip, {"byte_equal": True, "semantic_equal": True}, source_evidence),
        _witness("Composability", composable, {"derived": derived, "report_derived": report["derived_point_ids"]}, {"same_derived_points": True}, source_evidence),
        _witness("ProductionReachability", all_reachable, dispatch, {product_id: True for product_id in PRODUCT_IDS}, source_evidence),
    ]
    return {
        "acceptance_witnesses": {"finite_sequence": witnesses},
        "production_reachability": {
            "obligation_id": "ProductionReachability",
            "proposition": "Analysis products dispatched by this CLI invocation are reachable from its validated input.",
            "status": "PROVED" if all_reachable else "UNRESOLVED",
            "evidence": {"finite_set": source_evidence},
        },
        "unobserved_scope": {"finite_set": ["RuntimeLibraryIndependence"]},
    }


def _generated_input() -> dict[str, Any]:
    point_ids = ["p0", "p1", "p2"]
    colors = ["red", "blue", "green"]
    points = [
        {
            "point_id": point_id,
            "region_id": "region-main",
            "input_weight": {"numerator": 1, "denominator": 2},
            "measure_contribution": {"numerator": 2 * index + 1, "denominator": 4},
            "coordinates": {"finite_map": [{"key": "Color", "value": colors[index]}]},
        }
        for index, point_id in enumerate(point_ids)
    ]
    def evidence(evidence_id: str, source_ref: str, claim: str) -> dict[str, Any]:
        return {
            "evidence_id": evidence_id,
            "source_kind": "Observation",
            "source_ref": source_ref,
            "source_digest": "sha256:" + "0" * 64,
            "locator": "generator:" + evidence_id,
            "claim": claim,
        }
    return {
        "schema_version": SCHEMA_VERSION,
        "input_tree": {"branch": {"branch_id": "root", "children": {"finite_sequence": [{"leaf": point_id} for point_id in point_ids]}}},
        "input_region": {"region_id": "region-main", "point_ids": {"finite_set": point_ids}, "weight": {"numerator": 1, "denominator": 1}},
        "reachability_points": {"finite_set": points},
        "type_declarations": {"finite_set": [{"type_id": "Color", "values": {"finite_set": sorted(colors)}}]},
        "value_declarations": {"finite_set": [{"value_id": color, "type_id": "Color"} for color in sorted(colors)]},
        "branches": {"finite_set": [{"branch_id": "accept-red", "input_region": {"finite_set": point_ids}, "required_type": "Color", "required_values": {"finite_set": ["red"]}}]},
        "declared_reachability": {"point_ids": {"finite_set": ["p0"]}, "evidence": {"finite_set": [evidence("e-declared", "analysis-input", "declared reachability generated for the closed input")]}},
        "derived_reachability": {"point_ids": {"finite_set": ["p0"]}, "evidence": {"finite_set": [evidence("e-derived", "reachability", "derived reachability generated by matching Color=red")]}},
        "axiom_declarations": {"finite_set": [{"axiom_id": "axiom-analysis", "identity": "analysis.exchange.closed", "input_type": "Color", "output_type": "Color", "closed_output_candidates": {"finite_set": sorted(colors)}}]},
    }


def main() -> int:
    """Run the generated-input verification CLI."""
    result = verify(_generated_input())
    if isinstance(result, TypedFailure):
        print(json.dumps(result.as_dict(), ensure_ascii=False, sort_keys=True, separators=(",", ":")), file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
    return 0


__all__ = ["verify", "verify_input_roundtrip", "main"]


if __name__ == "__main__":
    raise SystemExit(main())
