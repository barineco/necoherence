# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

from __future__ import annotations

import copy
import json
import os
import re
import subprocess
import sys
import tomllib
from itertools import permutations
from pathlib import Path
from typing import Any

import residual_coherence
from residual_coherence import (
    AnalysisFailure,
    CanonicalConsumerFailure,
    ReachabilityReductionFailure,
    TypedFailure,
    build_common_analysis_presentation,
    calculate_report,
    canonical_bytes,
    classify_relation_findings,
    diagnose_typed_reachability,
    extract_sources,
    reduce_typed_reachability,
    validate_analysis_input,
    validate_typed_reachability,
    verify,
    verify_typed_reachability,
)

ROOT = Path(__file__).resolve().parents[1]
SCHEMA_ROOT = ROOT / "schema"
CLI_ENVIRONMENT = {**os.environ, "PYTHONPATH": str(Path(residual_coherence.__file__).resolve().parents[1])}


def load_schema(name: str) -> dict[str, Any]:
    loaded: dict[str, Any] = json.loads((SCHEMA_ROOT / name).read_text(encoding="utf-8"))
    return loaded


def assert_matches_schema(schema_document: dict[str, Any], value: Any, path: str = "$") -> None:
    """Recursively check value against a JSON Schema document using only the standard library.

    Supports the subset of draft 2020-12 used by the bundled schemas: $ref, $defs, const,
    enum, object (required/properties/additionalProperties), array (items), and string
    (pattern/minLength) constraints.
    """
    defs = schema_document.get("$defs", {})

    def check(schema: dict[str, Any], target: Any, target_path: str) -> None:
        if "$ref" in schema:
            name = schema["$ref"].split("/")[-1]
            check(defs[name], target, target_path)
            return
        if "const" in schema:
            assert target == schema["const"], f"{target_path}: expected const {schema['const']!r}, got {target!r}"
            return
        if "enum" in schema:
            assert target in schema["enum"], f"{target_path}: {target!r} not in {schema['enum']}"
            return
        declared_type = schema.get("type")
        if declared_type == "object":
            assert isinstance(target, dict), f"{target_path}: expected object, got {type(target)}"
            for required_key in schema.get("required", []):
                assert required_key in target, f"{target_path}: missing required key {required_key!r}"
            properties = schema.get("properties", {})
            additional = schema.get("additionalProperties", True)
            for key, item in target.items():
                if key in properties:
                    check(properties[key], item, f"{target_path}.{key}")
                elif isinstance(additional, dict):
                    check(additional, item, f"{target_path}.{key}")
                elif additional is False:
                    raise AssertionError(f"{target_path}: unexpected key {key!r}")
            min_properties = schema.get("minProperties")
            if min_properties is not None:
                assert len(target) >= min_properties, f"{target_path}: has {len(target)} properties, fewer than minProperties {min_properties}"
            max_properties = schema.get("maxProperties")
            if max_properties is not None:
                assert len(target) <= max_properties, f"{target_path}: has {len(target)} properties, more than maxProperties {max_properties}"
            return
        if declared_type == "array":
            assert isinstance(target, list), f"{target_path}: expected array, got {type(target)}"
            items_schema = schema.get("items")
            if items_schema is not None:
                for index, item in enumerate(target):
                    check(items_schema, item, f"{target_path}[{index}]")
            min_items = schema.get("minItems")
            if min_items is not None:
                assert len(target) >= min_items, f"{target_path}: has {len(target)} items, fewer than minItems {min_items}"
            if schema.get("uniqueItems"):
                seen: list[str] = []
                for item in target:
                    encoded = json.dumps(item, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
                    assert encoded not in seen, f"{target_path}: duplicate item under uniqueItems"
                    seen.append(encoded)
            return
        if declared_type == "string":
            assert isinstance(target, str), f"{target_path}: expected string, got {type(target)}"
            pattern = schema.get("pattern")
            if pattern is not None:
                assert re.fullmatch(pattern, target), f"{target_path}: {target!r} does not match {pattern!r}"
            min_length = schema.get("minLength")
            if min_length is not None:
                assert len(target) >= min_length, f"{target_path}: shorter than {min_length}"
            return
        if declared_type == "boolean":
            assert isinstance(target, bool), f"{target_path}: expected boolean, got {type(target)}"
            return
        if declared_type == "integer":
            assert isinstance(target, int) and not isinstance(target, bool), f"{target_path}: expected integer, got {type(target)}"
            minimum = schema.get("minimum")
            if minimum is not None:
                assert target >= minimum, f"{target_path}: {target!r} below minimum {minimum}"
            return
        # CanonicalValue-style multi-type or unconstrained schemas accept any JSON value.

    check({"$ref": schema_document["$ref"]} if "$ref" in schema_document else schema_document, value, path)


def evidence(name: str) -> dict[str, str]:
    return {"evidence_id": name, "source_kind": "Observation", "source_ref": "example", "source_digest": "sha256:" + "0" * 64, "locator": name, "claim": name}


def analysis_input() -> dict[str, Any]:
    points = [
        {"point_id": "p0", "region_id": "r", "input_weight": {"numerator": 1, "denominator": 1}, "measure_contribution": {"numerator": 1, "denominator": 1}, "coordinates": {"finite_map": [{"key": "T", "value": "red"}]}},
        {"point_id": "p1", "region_id": "r", "input_weight": {"numerator": 1, "denominator": 1}, "measure_contribution": {"numerator": 1, "denominator": 1}, "coordinates": {"finite_map": [{"key": "T", "value": "blue"}]}},
    ]
    return {"schema_version": "necoherence-analysis-1", "input_tree": {"branch": {"branch_id": "root", "children": {"finite_sequence": [{"leaf": "p0"}, {"leaf": "p1"}]}}}, "input_region": {"region_id": "r", "point_ids": {"finite_set": ["p0", "p1"]}, "weight": {"numerator": 1, "denominator": 1}}, "reachability_points": {"finite_set": points}, "type_declarations": {"finite_set": [{"type_id": "T", "values": {"finite_set": ["blue", "red"]}}]}, "value_declarations": {"finite_set": [{"value_id": "blue", "type_id": "T"}, {"value_id": "red", "type_id": "T"}]}, "branches": {"finite_set": [{"branch_id": "red", "input_region": {"finite_set": ["p0", "p1"]}, "required_type": "T", "required_values": {"finite_set": ["red"]}}]}, "declared_reachability": {"point_ids": {"finite_set": []}, "evidence": {"finite_set": [evidence("declared")]}}, "derived_reachability": {"point_ids": {"finite_set": ["p0"]}, "evidence": {"finite_set": [evidence("derived")]}}, "axiom_declarations": {"finite_set": [{"axiom_id": "a", "identity": "a", "input_type": "T", "output_type": "T", "closed_output_candidates": {"finite_set": ["blue", "red"]}}]}}


def identifier(category: str, position: int) -> str:
    return f"{category}:sample#{category}:{position}:{position + 1}"


def artifact() -> dict[str, Any]:
    type_id = identifier("type", 1)
    constructors = [identifier("constructor", 2), identifier("constructor", 3)]
    spans = [identifier("span", 4), identifier("span", 5)]
    points = [identifier("point", 6), identifier("point", 7)]
    return {"artifact_schema_version": {"name": "necoherence-typed-reachability", "major": 1}, "source_revision": {"repository": "example", "revision": "r1", "tree_digest": "tree1"}, "finite_closed_type_set": {"finite_set": [{"type_id": type_id, "constructor_ids": {"finite_set": constructors}}]}, "constructor_domain": {"finite_set": [{"constructor_id": constructor, "owner_type_id": type_id, "payload_type_ids": {"finite_sequence": []}} for constructor in constructors]}, "branch_regions": {"finite_set": [{"branch_id": identifier("branch", 8), "region_id": identifier("region", 9), "required_type_id": type_id, "required_constructor_ids": {"finite_set": [constructors[0]]}, "point_ids": {"finite_set": points}, "span_id": spans[0]}]}, "declared_reachability": {"point_ids": {"finite_set": []}, "evidence": {"finite_set": [evidence("d")]}}, "inferred_reachability": {"point_ids": {"finite_set": points}, "evidence": {"finite_set": [evidence("i")]}}, "places": {"finite_set": [{"access": "Read", "place_id": identifier("place", 10), "point_id": points[0], "type_id": type_id, "value_id": constructors[0], "span_id": spans[0]}]}, "axiom_calls": {"finite_set": [{"axiom_id": identifier("axiom", 11), "identity": "example", "input_type_id": type_id, "output_type_id": type_id, "output_candidate_value_ids": {"finite_set": constructors}, "point_id": points[0], "span_id": spans[0]}]}, "source_spans": {"finite_set": [{"span_id": spans[index], "source_path": "sample", "source_digest": "sha256:" + "1" * 64, "start_byte": index + 1, "end_byte": index + 2, "start_line": index + 1, "start_column": 1, "end_line": index + 1, "end_column": 2} for index in range(2)]}, "correspondence": {"finite_set": [{"point_id": points[index], "type_id": type_id, "surface_id": constructors[index], "core_id": constructors[index], "native_id": constructors[index], "surface_span_id": spans[index], "core_span_id": spans[index], "native_span_id": spans[index]} for index in range(2)]}}


def test_roundtrip_permutation_and_preservation() -> None:
    value = analysis_input()
    encoded = canonical_bytes(value)
    assert isinstance(encoded, bytes)
    for rows in permutations(value["reachability_points"]["finite_set"]):
        changed = copy.deepcopy(value)
        changed["reachability_points"]["finite_set"] = list(rows)
        assert canonical_bytes(changed) == encoded
    report = calculate_report(value)
    assert isinstance(report, dict)
    assert report["residual_point_ids"] == {"finite_set": ["p0"]}


def artifact_with_cross_type_correspondence() -> dict[str, Any]:
    """Build an artifact with two declared types where one correspondence row is misscoped.

    The row declares one type but one of its stage values belongs to the other, unrelated
    type. Closure must be checked per row, not against the union of every constructor.
    """
    value = artifact()
    first_type = value["finite_closed_type_set"]["finite_set"][0]["type_id"]
    second_type = identifier("type", 30)
    second_value = identifier("constructor", 31)
    value["finite_closed_type_set"]["finite_set"].append(
        {"type_id": second_type, "constructor_ids": {"finite_set": [second_value]}}
    )
    value["constructor_domain"]["finite_set"].append(
        {"constructor_id": second_value, "owner_type_id": second_type, "payload_type_ids": {"finite_sequence": []}}
    )
    row = value["correspondence"]["finite_set"][0]
    row["type_id"] = first_type
    row["surface_id"] = second_value
    return value


def test_typed_reachability_reduction_and_diagnostic_are_permutation_invariant() -> None:
    value = artifact()
    reduction = reduce_typed_reachability(value)
    diagnostic = diagnose_typed_reachability(value)
    assert isinstance(reduction, dict)
    assert isinstance(diagnostic, dict)
    reordered = copy.deepcopy(value)
    for name in ("finite_closed_type_set", "correspondence", "source_spans"):
        reordered[name]["finite_set"].reverse()
    reordered_reduction = reduce_typed_reachability(reordered)
    reordered_diagnostic = diagnose_typed_reachability(reordered)
    assert isinstance(reordered_reduction, dict)
    assert isinstance(reordered_diagnostic, dict)
    assert canonical_bytes(reordered_reduction) == canonical_bytes(reduction)
    assert canonical_bytes(reordered_diagnostic) == canonical_bytes(diagnostic)


def test_correspondence_closure_is_scoped_to_the_declared_type() -> None:
    value = artifact_with_cross_type_correspondence()
    result = validate_typed_reachability(value)
    assert isinstance(result, ReachabilityReductionFailure)
    assert result.kind == "CorrespondenceClosureFailure"
    assert result.path == f"$.correspondence.{value['correspondence']['finite_set'][0]['point_id']}"


def test_cli_typed_reachability_rejects_cross_type_correspondence() -> None:
    env = CLI_ENVIRONMENT
    payload = {
        "artifact": artifact_with_cross_type_correspondence(),
        "provenance": {"one": "sha256:" + "a" * 64, "two": "sha256:" + "b" * 64},
    }
    run = subprocess.run(
        [sys.executable, "-m", "residual_coherence.cli", "typed-reachability"],
        input=json.dumps(payload), text=True, capture_output=True, cwd=ROOT, env=env,
    )
    assert run.returncode == 1
    failure = json.loads(run.stderr)
    assert failure["kind"] == "CorrespondenceClosureFailure"


def test_invalid_and_generic_source_revision() -> None:
    assert isinstance(validate_analysis_input({}), TypedFailure)
    value = artifact()
    assert isinstance(validate_typed_reachability(value), dict)
    value["source_revision"]["revision"] = "another-revision"
    assert isinstance(validate_typed_reachability(value), dict)
    reduction = reduce_typed_reachability(value)
    assert isinstance(reduction, dict)
    diagnostic = diagnose_typed_reachability(value)
    assert isinstance(diagnostic, dict)
    broken = copy.deepcopy(value)
    broken["source_revision"] = {"revision": "x"}
    assert isinstance(validate_typed_reachability(broken), ReachabilityReductionFailure)


def normalized_structure() -> dict[str, Any]:
    span = {"id": "span:one", "path": "sample", "digest": "sha256:" + "2" * 64, "start_byte": "0", "end_byte": "1", "start_line": "1", "start_column": "1", "end_line": "1", "end_column": "2"}
    return {"schema_version": {"name": "normalized-analysis", "major": "1"}, "source_revision": span["digest"], "language": "python", "declarations": [{"id": "declaration:one", "kind": "local", "name": "one", "type": "type:one", "span": "span:one"}], "types": [{"id": "type:one", "kind": "local", "arguments": [], "span": "span:one"}], "values": [{"id": "value:one", "kind": "local", "type": "type:one", "declaration": "declaration:one", "span": "span:one"}], "operation_inputs": [], "branches": [{"id": "branch:one", "condition": "value:one", "selected": ["value:one"], "span": "span:one"}], "control_flow": [], "place_accesses": [], "external_effects": [], "source_spans": [span], "stage_correspondences": [{"point": "point:one", "source": "one", "resolved": "resolved:one", "lowered": None, "source_span": "span:one", "resolved_span": "span:one", "lowered_span": None}]}


def test_python_source_and_common_findings() -> None:
    extracted = extract_sources("r", {"sample.py": "x: int = 1\n"})
    assert isinstance(extracted, dict)
    assert isinstance(extracted["input"], dict)
    encoded = canonical_bytes(normalized_structure())
    assert isinstance(encoded, bytes)
    presentation = build_common_analysis_presentation(encoded)
    assert isinstance(presentation, dict)
    assert [finding["classification"] for finding in presentation["findings"]["findings"]["finite_sequence"]] == ["Candidate"]
    assert isinstance(presentation["analysis_input"], dict)
    assert isinstance(presentation["report"], dict)
    assert isinstance(build_common_analysis_presentation(b"{}"), CanonicalConsumerFailure)


def test_normalized_schema_name_canonical_bytes_and_findings() -> None:
    structure = normalized_structure()
    encoded = canonical_bytes(structure)
    assert isinstance(encoded, bytes)
    assert canonical_bytes(json.loads(encoded)) == encoded

    old_name = copy.deepcopy(structure)
    old_name["schema_version"]["name"] = "residual-coherence-normalized-analysis"
    old_bytes = canonical_bytes(old_name)
    assert isinstance(old_bytes, bytes)
    decoded = build_common_analysis_presentation(old_bytes)
    assert isinstance(decoded, CanonicalConsumerFailure)
    assert decoded.kind == "UnsupportedSchemaVersion"

    candidate = classify_relation_findings(structure)
    assert isinstance(candidate, dict)
    assert candidate["findings"]["finite_sequence"][0]["classification"] == "Candidate"

    proved_structure = copy.deepcopy(structure)
    proved_structure["stage_correspondences"][0]["lowered"] = "lowered:one"
    proved_structure["stage_correspondences"][0]["lowered_span"] = "span:one"
    proved = classify_relation_findings(proved_structure)
    assert isinstance(proved, dict)
    assert proved["findings"]["finite_sequence"][0]["classification"] == "Proved"

    unclosed_structure = copy.deepcopy(structure)
    unclosed_structure["stage_correspondences"][0]["source"] = "missing-source"
    unclosed = classify_relation_findings(unclosed_structure)
    assert isinstance(unclosed, dict)
    assert unclosed["findings"]["finite_sequence"][0]["classification"] == "Unclosed"


def test_normalized_analysis_without_evidence_is_a_typed_failure() -> None:
    evidence = ("declarations", "types", "values", "branches", "source_spans", "stage_correspondences")
    for name in evidence:
        partial = canonical_bytes({**normalized_structure(), name: []})
        assert isinstance(partial, bytes)
        assert isinstance(build_common_analysis_presentation(partial), CanonicalConsumerFailure)
    empty = canonical_bytes({**normalized_structure(), **{name: [] for name in evidence}})
    assert isinstance(empty, bytes)
    rejected = build_common_analysis_presentation(empty)
    assert isinstance(rejected, CanonicalConsumerFailure)
    assert rejected.kind == "AnalysisInputFailure"


def test_python_source_detection_rules_and_typed_failures() -> None:
    sources = {
        "flags.py": "def flags(a: bool, b: bool):\n    return a and b\n",
        "receiver.py": "class C:\n    def method(self, value: int):\n        return value\n",
        "ambient.py": "CONFIG = 1\ndef read():\n    return CONFIG\n",
    }
    extracted = extract_sources("r", sources)
    assert isinstance(extracted, dict)
    kinds = {
        point["coordinates"]["finite_map"][0]["value"]
        for point in extracted["input"]["reachability_points"]["finite_set"]
    }
    assert {"FlagCartesianProduct", "ReceiverHiding", "AmbientRead"} <= kinds

    failures = {
        "DynamicImport": "__import__('x')\n",
        "Reflection": "getattr(obj, name)\n",
        "UndeclaredExternalOutput": "print('x')\n",
        "UnannotatedAny": "from typing import Any\nx: Any = 1\n",
        "UnclosedExpression": "def broken(:\n    pass\n",
    }
    for expected, source in failures.items():
        result = extract_sources("r", {"sample.py": source})
        assert isinstance(result, AnalysisFailure)
        assert result.kind == expected


def test_cli_all_commands_success_and_failure() -> None:
    commands: dict[str, Any] = {
        "validate": analysis_input(), "report": analysis_input(), "reachability": analysis_input(), "verify": analysis_input(),
        "normalized-analysis": normalized_structure(), "typed-reachability": {"artifact": artifact(), "provenance": {"one": "sha256:" + "a" * 64, "two": "sha256:" + "b" * 64}},
        "python-source": {"revision": "r", "sources": {"x.py": "x: int = 1\n"}},
    }
    for command, payload in commands.items():
        run = subprocess.run([sys.executable, "-m", "residual_coherence.cli", command], input=json.dumps(payload), text=True, capture_output=True, cwd=ROOT, env=CLI_ENVIRONMENT)
        assert run.returncode == 0, run.stderr
        assert json.loads(run.stdout)
    for command in commands:
        run = subprocess.run([sys.executable, "-m", "residual_coherence.cli", command], input="{}", text=True, capture_output=True, cwd=ROOT, env=CLI_ENVIRONMENT)
        assert run.returncode == 1
        assert json.loads(run.stderr)["kind"]


def test_verify_output_matches_analysis_verification_schema() -> None:
    schema = load_schema("analysis-verification.schema.json")
    result = verify(analysis_input())
    assert isinstance(result, dict)
    assert_matches_schema(schema, result)
    assert result["production_reachability"]["status"] in {"PROVED", "REFUTED", "UNRESOLVED"}
    assert "UNPROVED" not in json.dumps(result)


def test_verify_typed_reachability_output_matches_dedicated_schema() -> None:
    schema = load_schema("typed-reachability-verification.schema.json")
    provenance = {"one": "sha256:" + "a" * 64, "two": "sha256:" + "b" * 64}
    result = verify_typed_reachability(artifact(), provenance)
    assert isinstance(result, dict)
    assert_matches_schema(schema, result)

    witnesses = result["acceptance_witnesses"]["finite_sequence"]
    witness_ids = {witness["witness_id"] for witness in witnesses}
    assert witness_ids == {
        "ProjectIndependence", "TypedClosure", "PlaceConnection", "AxiomConnection",
        "RepresentationCorrespondence", "DeterministicReduction", "DiagnosticOnly", "Composability",
    }
    for witness in witnesses:
        assert witness["evidence"]["finite_set"], f"{witness['witness_id']} has empty evidence"
        assert witness["matched"] is True
        assert witness["status"] == "ok"

    products = result["production_reachability"]["finite_sequence"]
    product_ids = {product["product_id"] for product in products}
    assert product_ids == {"ArtifactRequirement", "Reduction", "Diagnostic", "FailureCoverage", "Verification"}
    for product in products:
        assert product["evidence"]["finite_set"], f"{product['product_id']} has empty evidence"
        assert product["status"] == "PROVED"

    # A dedicated type: the typed reachability result does not claim the AnalysisVerification shape.
    analysis_verification_schema = load_schema("analysis-verification.schema.json")
    try:
        assert_matches_schema(analysis_verification_schema, result)
    except AssertionError:
        pass
    else:
        raise AssertionError("typed reachability verification result unexpectedly matches AnalysisVerification")


def test_project_independence_witness_accepts_arbitrary_source_revision() -> None:
    schema = load_schema("typed-reachability-verification.schema.json")
    provenance = {"one": "sha256:" + "a" * 64, "two": "sha256:" + "b" * 64}

    for repository, revision, tree_digest in (
        ("example", "r1", "tree1"),
        ("another-org/another-repo", "rev-9000", "digest-xyz"),
    ):
        value = artifact()
        value["source_revision"] = {"repository": repository, "revision": revision, "tree_digest": tree_digest}
        result = verify_typed_reachability(value, provenance)
        assert isinstance(result, dict)
        assert_matches_schema(schema, result)

        witness = next(w for w in result["acceptance_witnesses"]["finite_sequence"] if w["witness_id"] == "ProjectIndependence")
        assert witness["matched"] is True
        assert witness["status"] == "ok"
        assert witness["observed"]["original_source_revision"] == {"repository": repository, "revision": revision, "tree_digest": tree_digest}
        substituted = witness["observed"]["substituted_source_revision"]
        assert substituted["repository"] != repository
        assert substituted["revision"] != revision
        assert substituted["tree_digest"] != tree_digest
        assert all(field for field in substituted.values())
        assert witness["observed"]["substituted_diagnostic_source_revision"] == substituted
        assert witness["observed"]["substituted_reduction_region_id"] == "source-revision:" + substituted["revision"]
        assert witness["observed"]["non_revision_structure_preserved"] is True

        # The un-substituted diagnostic and reduction still carry this invocation's own revision.
        assert result["diagnostic"]["source_revision"] == {"repository": repository, "revision": revision, "tree_digest": tree_digest}


def test_analysis_input_source_digest_pattern_is_enforced() -> None:
    for bad_digest in ("sha256:x", "sha256:" + "a" * 63, "sha256:" + "g" * 64, "sha256:" + "A" * 64):
        value = analysis_input()
        value["declared_reachability"]["evidence"]["finite_set"][0]["source_digest"] = bad_digest
        result = validate_analysis_input(value)
        assert isinstance(result, TypedFailure), bad_digest
        assert result.kind == "ReachabilityEvidenceFailure"


def test_empty_reachability_evidence_is_rejected() -> None:
    for reachability_key in ("declared_reachability", "derived_reachability"):
        value = analysis_input()
        value[reachability_key]["evidence"]["finite_set"] = []
        result = validate_analysis_input(value)
        assert isinstance(result, TypedFailure), reachability_key
        assert result.kind == "ReachabilityEvidenceFailure"
        assert result.path == f"$.{reachability_key}.evidence"

    for reachability_key in ("declared_reachability", "derived_reachability"):
        env = CLI_ENVIRONMENT
        payload = analysis_input()
        payload[reachability_key]["evidence"]["finite_set"] = []
        run = subprocess.run(
            [sys.executable, "-m", "residual_coherence.cli", "verify"],
            input=json.dumps(payload), text=True, capture_output=True, cwd=ROOT, env=env,
        )
        assert run.returncode == 1, reachability_key
        failure = json.loads(run.stderr)
        assert failure["kind"] == "ReachabilityEvidenceFailure"
        assert failure["path"] == f"$.{reachability_key}.evidence"


def test_all_source_evidence_sets_require_at_least_one_item() -> None:
    schema_names = (
        "analysis-input.schema.json",
        "analysis-verification.schema.json",
        "residual-coherence-report.schema.json",
        "typed-reachability-artifact.schema.json",
        "typed-reachability-verification.schema.json",
    )
    checked = 0
    for name in schema_names:
        schema = load_schema(name)
        for def_name, definition in schema.get("$defs", {}).items():
            if def_name != "SourceEvidenceSet":
                continue
            finite_set = definition["properties"]["finite_set"]
            assert finite_set.get("minItems") == 1, f"{name}: SourceEvidenceSet.finite_set missing minItems=1"
            assert finite_set.get("uniqueItems") is True, f"{name}: SourceEvidenceSet.finite_set missing uniqueItems"
            checked += 1
    assert checked == len(schema_names), f"expected a SourceEvidenceSet def in each of {schema_names}, found {checked}"


def test_provenance_digest_pattern_is_enforced() -> None:
    valid_provenance = {"one": "sha256:" + "a" * 64, "two": "sha256:" + "b" * 64}
    valid_result = verify_typed_reachability(artifact(), valid_provenance)
    assert isinstance(valid_result, dict)

    invalid_provenance_values = (
        {"one": "sha256:x", "two": "sha256:" + "b" * 64},
        {"one": "sha256:" + "a" * 63, "two": "sha256:" + "b" * 64},
        {"one": "sha256:" + "g" * 64, "two": "sha256:" + "b" * 64},
        {"one": "sha256:" + "A" * 64, "two": "sha256:" + "b" * 64},
    )
    for invalid_provenance in invalid_provenance_values:
        result = verify_typed_reachability(artifact(), invalid_provenance)
        assert isinstance(result, ReachabilityReductionFailure), invalid_provenance
        assert result.kind == "VerificationFailure"
        assert result.path == "$.provenance"


def test_provenance_schema_requires_exactly_two_entries() -> None:
    schema = load_schema("typed-reachability-verification.schema.json")
    provenance_schema = schema["$defs"]["TypedReachabilityProvenance"]
    assert provenance_schema.get("minProperties") == 2
    assert provenance_schema.get("maxProperties") == 2

    one_entry = {"one": "sha256:" + "a" * 64}
    three_entries = {"one": "sha256:" + "a" * 64, "two": "sha256:" + "b" * 64, "three": "sha256:" + "c" * 64}
    for provenance in (one_entry, three_entries):
        try:
            assert_matches_schema({"$ref": "#/$defs/TypedReachabilityProvenance", "$defs": schema["$defs"]}, provenance)
        except AssertionError:
            pass
        else:
            raise AssertionError(f"expected schema rejection for provenance with {len(provenance)} entries")


def test_verify_typed_reachability_rejects_one_and_three_entry_provenance() -> None:
    for provenance in (
        {"one": "sha256:" + "a" * 64},
        {"one": "sha256:" + "a" * 64, "two": "sha256:" + "b" * 64, "three": "sha256:" + "c" * 64},
    ):
        result = verify_typed_reachability(artifact(), provenance)
        assert isinstance(result, ReachabilityReductionFailure), provenance
        assert result.kind == "VerificationFailure"
        assert result.path == "$.provenance"


def test_cli_typed_reachability_rejects_one_and_three_entry_provenance() -> None:
    env = CLI_ENVIRONMENT
    for provenance in (
        {"one": "sha256:" + "a" * 64},
        {"one": "sha256:" + "a" * 64, "two": "sha256:" + "b" * 64, "three": "sha256:" + "c" * 64},
    ):
        payload = {"artifact": artifact(), "provenance": provenance}
        run = subprocess.run(
            [sys.executable, "-m", "residual_coherence.cli", "typed-reachability"],
            input=json.dumps(payload), text=True, capture_output=True, cwd=ROOT, env=env,
        )
        assert run.returncode == 1, provenance
        failure = json.loads(run.stderr)
        assert failure["kind"] == "VerificationFailure"
        assert failure["path"] == "$.provenance"


def test_cli_typed_reachability_rejects_invalid_provenance_digest() -> None:
    env = CLI_ENVIRONMENT
    payload = {"artifact": artifact(), "provenance": {"one": "sha256:" + "A" * 64, "two": "sha256:" + "b" * 64}}
    run = subprocess.run(
        [sys.executable, "-m", "residual_coherence.cli", "typed-reachability"],
        input=json.dumps(payload), text=True, capture_output=True, cwd=ROOT, env=env,
    )
    assert run.returncode == 1
    failure = json.loads(run.stderr)
    assert failure["kind"] == "VerificationFailure"
    assert failure["path"] == "$.provenance"


def test_cli_verify_and_typed_reachability_success_output_matches_schemas() -> None:
    env = CLI_ENVIRONMENT
    verify_run = subprocess.run(
        [sys.executable, "-m", "residual_coherence.cli", "verify"],
        input=json.dumps(analysis_input()), text=True, capture_output=True, cwd=ROOT, env=env,
    )
    assert verify_run.returncode == 0, verify_run.stderr
    assert_matches_schema(load_schema("analysis-verification.schema.json"), json.loads(verify_run.stdout))

    typed_payload = {"artifact": artifact(), "provenance": {"one": "sha256:" + "a" * 64, "two": "sha256:" + "b" * 64}}
    typed_run = subprocess.run(
        [sys.executable, "-m", "residual_coherence.cli", "typed-reachability"],
        input=json.dumps(typed_payload), text=True, capture_output=True, cwd=ROOT, env=env,
    )
    assert typed_run.returncode == 0, typed_run.stderr
    assert_matches_schema(load_schema("typed-reachability-verification.schema.json"), json.loads(typed_run.stdout))


def test_public_version_is_the_manifest_version() -> None:
    project = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))["project"]
    assert residual_coherence.__version__ == project["version"]
