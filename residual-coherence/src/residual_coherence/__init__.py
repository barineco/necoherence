# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

"""Public API for residual coherence validation and reduction."""

from importlib.metadata import version as _distribution_version

from .core import (
    TypedFailure,
    calculate_report,
    canonical_bytes,
    canonical_digest,
    derive_reachability,
    validate_analysis_input,
)
from .normalized_analysis import (
    CanonicalConsumerFailure,
    build_common_analysis_presentation,
    classify_relation_findings,
    decode_canonical_structure,
    reduce_normalized_analysis_structure,
    validate_normalized_analysis_structure,
)
from .python_source import AnalysisFailure, extract_paths, extract_sources
from .typed_reachability import (
    ReachabilityReductionFailure,
    diagnose_typed_reachability,
    reduce_typed_reachability,
    validate_typed_reachability,
    verify_typed_reachability,
)
from .verification import verify, verify_input_roundtrip

__version__ = _distribution_version("residual-coherence")

__all__ = [
    "AnalysisFailure",
    "CanonicalConsumerFailure",
    "ReachabilityReductionFailure",
    "TypedFailure",
    "build_common_analysis_presentation",
    "calculate_report",
    "canonical_bytes",
    "canonical_digest",
    "classify_relation_findings",
    "decode_canonical_structure",
    "derive_reachability",
    "diagnose_typed_reachability",
    "extract_paths",
    "extract_sources",
    "reduce_normalized_analysis_structure",
    "reduce_typed_reachability",
    "validate_analysis_input",
    "validate_normalized_analysis_structure",
    "validate_typed_reachability",
    "verify",
    "verify_input_roundtrip",
    "verify_typed_reachability",
]
