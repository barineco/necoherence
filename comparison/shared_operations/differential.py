# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT


from __future__ import annotations

import argparse
import json
import sys
from typing import Any

from . import generator, properties
from .generator import ALL_OPERATIONS, SURFACE, Req, json_canon
from .implementations import Implementation, ImplementationError, build_implementations


def fail_invalid_mismatch(
    reference_name: str,
    candidate_name: str,
    query_index: int,
    query_text: str,
    expected_kind: str,
    reference_result: Any,
    candidate_result: Any,
) -> None:
    report = {
        "kind": "invalid_query_mismatch",
        "reference": reference_name,
        "candidate": candidate_name,
        "query_index": query_index,
        "query": query_text,
        "expected_failure_kind": expected_kind,
        f"{reference_name}_result": reference_result,
        f"{candidate_name}_result": candidate_result,
    }
    print(json.dumps(report, indent=2, ensure_ascii=False), file=sys.stderr)
    raise SystemExit(1)


def _without_detail(res: Any) -> Any:
    if not isinstance(res, dict):
        return res
    failure = res.get("failure")
    if not isinstance(failure, dict):
        return res
    trimmed_failure = {k: v for k, v in failure.items() if k != "detail"}
    return {**res, "failure": trimmed_failure}


def invalid_results_agree(reference_result: Any, candidate_result: Any) -> bool:
    return json_canon(_without_detail(reference_result)) == json_canon(_without_detail(candidate_result))


def audit_surface(impl: Implementation) -> None:
    result = impl.run(json.dumps({"kind": "surface"}))
    if not isinstance(result, dict) or result.get("kind") != "surface":
        raise SystemExit(f"{impl.name}: surface query did not return kind=surface: {result!r}")
    features = result.get("features")
    if not isinstance(features, list):
        raise SystemExit(f"{impl.name}: surface reply is missing the features array: {result!r}")

    seen_features: list[str] = []
    pairs: list[tuple[str, str]] = []
    for entry in features:
        if not isinstance(entry, dict) or "feature" not in entry or "operations" not in entry:
            raise SystemExit(f"{impl.name}: malformed feature entry: {entry!r}")
        feature = entry["feature"]
        seen_features.append(feature)
        ops = entry["operations"]
        if not isinstance(ops, list):
            raise SystemExit(f"{impl.name}: malformed operations list for {feature}: {ops!r}")
        for op in ops:
            pairs.append((feature, op))
        if len(ops) != len(set(ops)):
            dupes = [o for o in ops if ops.count(o) > 1]
            raise SystemExit(f"{impl.name}: duplicate operations in {feature}: {sorted(set(dupes))}")

    if len(seen_features) != len(set(seen_features)):
        dupes = [f for f in seen_features if seen_features.count(f) > 1]
        raise SystemExit(f"{impl.name}: duplicate features: {sorted(set(dupes))}")

    expected_pairs = set(ALL_OPERATIONS)
    actual_pairs = set(pairs)
    missing = expected_pairs - actual_pairs
    extra = actual_pairs - expected_pairs
    if missing or extra:
        raise SystemExit(f"{impl.name}: surface mismatch. missing={sorted(missing)} extra={sorted(extra)}")

    expected_feature_order = [f for f, _ in SURFACE]
    if seen_features != expected_feature_order:
        raise SystemExit(f"{impl.name}: surface order differs. expected={expected_feature_order} actual={seen_features}")
    for (feature, expected_ops), entry in zip(SURFACE, features):
        if entry["operations"] != expected_ops:
            raise SystemExit(
                f"{impl.name}: operation order differs for {feature}. expected={expected_ops} actual={entry['operations']}"
            )

    print(f"{impl.name}: surface OK ({len(actual_pairs)} operations across {len(seen_features)} feature families)")


def run_surface_audit(implementations: list[Implementation]) -> None:
    for impl in implementations:
        audit_surface(impl)
    print(
        f"surface: all {len(implementations)} implementations match the declared "
        f"{len(SURFACE)}-family, {len(ALL_OPERATIONS)}-operation surface"
    )


def check_numeric_invalid(implementations: list[Implementation]) -> None:
    resource = generator.RESOURCE_IDS[1]
    for bad in generator.INVALID_INTS:
        world = [{"resource": resource, "revision": bad}]
        text = json.dumps({"kind": "evaluate", "requests": [generator.req("core", "lookup", {"world": world, "resource": resource})]})
        for impl in implementations:
            result = impl.run(text)
            if not isinstance(result, dict) or result.get("kind") != "invalid":
                generator.coverage_failure("numeric invalid input was accepted", {"implementation": impl.name, "input": text, "result": result})


def run_invariants(implementations: list[Implementation]) -> None:
    for implementation in implementations:
        properties.run_implementation_properties(implementation)
        print(f"{implementation.name}: generated invariant properties OK")


def run_differential(implementations: list[Implementation]) -> None:
    requests: list[Req] = properties.generated_differential_requests()
    generator.check_all_operations_covered(requests)
    generator.check_domain_coverage(requests)
    chunk_count = properties.compare_to_lean(implementations, requests)

    invalid_queries = generator.build_invalid_queries()
    reference = implementations[0]
    reference_invalid = [reference.run(generator.render_invalid_query(entry)) for entry in invalid_queries]

    for candidate in implementations[1:]:
        for index, (entry, reference_result) in enumerate(zip(invalid_queries, reference_invalid)):
            text = generator.render_invalid_query(entry)
            candidate_result = candidate.run(text)
            expected_kind = entry["expected_kind"]
            for result in (reference_result, candidate_result):
                failure = result.get("failure") if isinstance(result, dict) and result.get("kind") == "invalid" else None
                if not isinstance(failure, dict) or failure.get("kind") != expected_kind:
                    fail_invalid_mismatch(reference.name, candidate.name, index, text, expected_kind, reference_result, candidate_result)
            if not invalid_results_agree(reference_result, candidate_result):
                fail_invalid_mismatch(reference.name, candidate.name, index, text, expected_kind, reference_result, candidate_result)

    check_numeric_invalid(implementations)
    print(
        f"differential OK: {len(requests)} valid requests in {chunk_count} chunks "
        f"(size={generator.DIFFERENTIAL_CHUNK_SIZE}) + {len(invalid_queries)} invalid queries "
        f"across {len(implementations)} implementations"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--surface", action="store_true")
    mode.add_argument("--invariants", action="store_true")
    arguments = parser.parse_args()
    try:
        implementations = build_implementations()
        run_surface_audit(implementations)
        if arguments.surface:
            return
        run_invariants(implementations)
        if arguments.invariants:
            return
        run_differential(implementations)
    except ImplementationError as exc:
        raise SystemExit(f"implementation failure: {exc}") from exc


if __name__ == "__main__":
    main()
