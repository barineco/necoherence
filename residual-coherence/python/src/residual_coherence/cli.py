# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

"""JSON stdin/stdout command line interface for residual coherence."""

from __future__ import annotations

import json
import sys
from typing import Any, Callable

from .core import TypedFailure, calculate_report, canonical_bytes, derive_reachability, validate_analysis_input
from .normalized_analysis import CanonicalConsumerFailure, build_common_analysis_presentation
from .python_source import AnalysisFailure, extract_sources
from .typed_reachability import (
    ReachabilityReductionFailure,
    diagnose_typed_reachability,
    verify_typed_reachability,
)
from .verification import verify

Failure = TypedFailure | CanonicalConsumerFailure | ReachabilityReductionFailure | AnalysisFailure


def _encode(value: Any) -> str:
    encoded = canonical_bytes(value)
    if isinstance(encoded, TypedFailure):
        return json.dumps(encoded.as_dict(), ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return encoded.decode("utf-8")


def _input_error(detail: str) -> TypedFailure:
    return TypedFailure("InvalidIdentifier", "$", detail)


def _normalized(value: Any) -> dict[str, Any] | CanonicalConsumerFailure:
    encoded = canonical_bytes(value)
    if isinstance(encoded, TypedFailure):
        return CanonicalConsumerFailure("InvalidCanonicalJson", encoded.path, encoded.detail)
    return build_common_analysis_presentation(encoded)


def _python_source(value: Any) -> dict[str, Any] | AnalysisFailure | TypedFailure:
    if not isinstance(value, dict) or set(value) != {"revision", "sources"}:
        return _input_error("expected revision and sources")
    revision, sources = value["revision"], value["sources"]
    if not isinstance(revision, str) or not revision or not isinstance(sources, dict) or any(
        not isinstance(path, str) or not isinstance(source, str) for path, source in sources.items()
    ):
        return _input_error("revision and source map must contain nonempty text")
    return extract_sources(revision, sources)


def _typed(value: Any) -> dict[str, Any] | ReachabilityReductionFailure | TypedFailure:
    if not isinstance(value, dict) or set(value) != {"artifact", "provenance"}:
        return _input_error("expected artifact and provenance")
    artifact, provenance = value["artifact"], value["provenance"]
    if not isinstance(provenance, dict) or any(not isinstance(key, str) or not isinstance(item, str) for key, item in provenance.items()):
        return _input_error("provenance must be a text map")
    return verify_typed_reachability(artifact, provenance)


_COMMANDS: dict[str, Callable[[Any], Any]] = {
    "validate": validate_analysis_input,
    "report": calculate_report,
    "reachability": derive_reachability,
    "verify": verify,
    "normalized-analysis": _normalized,
    "typed-reachability": _typed,
    "python-source": _python_source,
}


def main() -> int:
    """Read one JSON value and write one canonical JSON result."""
    if len(sys.argv) != 2 or sys.argv[1] not in _COMMANDS:
        print(_encode(_input_error("expected one supported command" ).as_dict()), file=sys.stderr)
        return 1
    try:
        value = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(_encode(_input_error(str(exc)).as_dict()), file=sys.stderr)
        return 1
    result = _COMMANDS[sys.argv[1]](value)
    if isinstance(result, (TypedFailure, CanonicalConsumerFailure, ReachabilityReductionFailure, AnalysisFailure)):
        print(_encode(result.as_dict()), file=sys.stderr)
        return 1
    print(_encode(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
