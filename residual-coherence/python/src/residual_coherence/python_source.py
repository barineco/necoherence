# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

"""Experimentally apply Necoherence principles to declared Python sources.

This module analyzes a finite, explicitly declared set of Python source strings
with an AST-based extractor and produces a versioned ``AnalysisInput`` plus
source evidence. It checks the three experimental pollution rules
``FlagCartesianProduct``, ``ReceiverHiding``, and ``AmbientRead``. It reports
closed, typed failures for ``DynamicImport``, ``Reflection``,
``UndeclaredExternalOutput``, ``UnannotatedAny``, and ``UnclosedExpression``.

The supported scope is the declared finite source set, the documented extraction
rules, the ``python-source`` CLI command, and the public ``extract_sources`` and
``extract_paths`` import API. Complete Python semantics and compiler-frontend
equivalence remain unobserved. The analyzer does not claim either equivalence.
"""

from __future__ import annotations

import ast
from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path
from typing import Any

SCHEMA_VERSION = "necoherence-analysis-1"


@dataclass(frozen=True)
class AnalysisFailure:
    kind: str
    path: str
    detail: str = ""

    def as_dict(self) -> dict[str, str]:
        result = {"kind": self.kind, "path": self.path}
        if self.detail:
            result["detail"] = self.detail
        return result


def _failure(kind: str, path: str, detail: str = "") -> AnalysisFailure:
    return AnalysisFailure(kind, path, detail)


def _source_digest(source: str) -> str:
    return "sha256:" + sha256(source.encode("utf-8")).hexdigest()


def _source_evidence(path: str, source: str, line: int, claim: str) -> dict[str, Any]:
    evidence_key = f"{path}:{line}:{claim}"
    return {
        "evidence_id": "source-" + sha256(evidence_key.encode("utf-8")).hexdigest()[:12],
        "source_kind": "Repository",
        "source_ref": path,
        "source_digest": _source_digest(source),
        "locator": f"line:{line}:column:0",
        "claim": claim,
    }


def _is_static_projection(call: ast.Call) -> bool:
    return (
        isinstance(call.func, ast.Name)
        and call.func.id == "getattr"
        and len(call.args) == 3
        and isinstance(call.args[2], (ast.Name, ast.Constant))
    )


def _forbidden(tree: ast.AST, path: str) -> AnalysisFailure | None:
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            name = node.func.id if isinstance(node.func, ast.Name) else node.func.attr if isinstance(node.func, ast.Attribute) else ""
            if name in {"__import__", "import_module"}:
                return _failure("DynamicImport", path, f"line {node.lineno}")
            if name in {"getattr", "setattr", "hasattr", "delattr", "vars", "dir"} and not _is_static_projection(node):
                return _failure("Reflection", path, f"line {node.lineno}")
            if isinstance(node.func, ast.Name) and name in {"print", "open"}:
                return _failure("UndeclaredExternalOutput", path, f"line {node.lineno}")
        if isinstance(node, (ast.arg, ast.AnnAssign)):
            annotation = node.annotation
            if isinstance(annotation, ast.Name) and annotation.id == "Any":
                return _failure("UnannotatedAny", path, f"line {node.lineno}")
    return None


def _pollution_points(path: str, source: str, tree: ast.Module) -> list[tuple[str, int, str]]:
    points: list[tuple[str, int, str]] = []
    module_names = {
        node.targets[0].id
        for node in tree.body
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name)
    }
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            bool_args = [arg.arg for arg in node.args.args if isinstance(arg.annotation, ast.Name) and arg.annotation.id == "bool"]
            if len(bool_args) >= 2:
                points.append(("FlagCartesianProduct", node.lineno, node.name))
            if node.args.args and node.args.args[0].arg in {"self", "cls"}:
                points.append(("ReceiverHiding", node.lineno, node.name))
            local_names = {arg.arg for arg in node.args.args}
            local_names.update(
                target.id
                for child in ast.walk(node)
                for target in ([child.target] if isinstance(child, ast.AnnAssign) else child.targets if isinstance(child, ast.Assign) else [])
                if isinstance(target, ast.Name)
            )
            reads = {child.id for child in ast.walk(node) if isinstance(child, ast.Name) and isinstance(child.ctx, ast.Load)}
            ambient = sorted((reads & module_names) - local_names)
            if ambient:
                points.append(("AmbientRead", node.lineno, node.name + ":" + ",".join(ambient)))
    return points


def _tree(point_ids: list[str]) -> dict[str, Any]:
    if len(point_ids) == 1:
        return {"leaf": point_ids[0]}
    return {"branch": {"branch_id": "python-ast", "children": {"finite_sequence": [{"leaf": point_id} for point_id in point_ids]}}}


def extract_sources(revision: str, sources: dict[str, str]) -> dict[str, Any] | AnalysisFailure:
    if not sources:
        return _failure("UnclosedExpression", "$", "the declared source set is empty")
    evidence: list[dict[str, Any]] = []
    pollution: list[tuple[str, str, int, str]] = []
    for path, source in sorted(sources.items()):
        try:
            tree = ast.parse(source, filename=path)
        except SyntaxError as error:
            return _failure("UnclosedExpression", path, str(error))
        failure = _forbidden(tree, path)
        if failure:
            return failure
        evidence.append(_source_evidence(path, source, 1, "Python source was parsed into the finite analysis input."))
        pollution.extend((kind, path, line, detail) for kind, line, detail in _pollution_points(path, source, tree))
    point_specs = [("p-baseline", "Baseline", 1, 1)]
    for index, (kind, path, line, detail) in enumerate(sorted(pollution), 1):
        point_specs.append((f"p-{kind.lower()}-{index}", kind, 1, 1))
        source = sources[path]
        evidence.append(_source_evidence(path, source, line, f"{kind} structure: {detail}"))
    point_ids = [item[0] for item in point_specs]
    declared_ids = ["p-baseline"]
    values = sorted({item[1] for item in point_specs})
    input_value = {
        "schema_version": SCHEMA_VERSION,
        "input_tree": _tree(point_ids),
        "input_region": {"region_id": "python-source", "point_ids": {"finite_set": point_ids}, "weight": {"numerator": 1, "denominator": 1}},
        "reachability_points": {"finite_set": [{"point_id": point_id, "region_id": "python-source", "input_weight": {"numerator": 1, "denominator": 1}, "measure_contribution": {"numerator": numerator, "denominator": denominator}, "coordinates": {"finite_map": [{"key": "ReachabilityKind", "value": kind}]}} for point_id, kind, numerator, denominator in point_specs]},
        "type_declarations": {"finite_set": [{"type_id": "ReachabilityKind", "values": {"finite_set": values}}]},
        "value_declarations": {"finite_set": [{"value_id": value, "type_id": "ReachabilityKind"} for value in values]},
        "branches": {"finite_set": [{"branch_id": "python-ast", "input_region": {"finite_set": point_ids}, "required_type": "ReachabilityKind", "required_values": {"finite_set": values}}]},
        "declared_reachability": {"point_ids": {"finite_set": declared_ids}, "evidence": {"finite_set": evidence}},
        "derived_reachability": {"point_ids": {"finite_set": point_ids}, "evidence": {"finite_set": evidence}},
        "axiom_declarations": {"finite_set": [{"axiom_id": "python-ast", "identity": "python.ast.closed", "input_type": "ReachabilityKind", "output_type": "ReachabilityKind", "closed_output_candidates": {"finite_set": values}}]},
    }
    return {"source_revision": {"revision": revision, "source_digest": _source_digest("".join(sources[path] for path in sorted(sources)))}, "input": input_value, "source_evidence": {"finite_set": evidence}}


def extract_paths(revision: str, paths: list[Path]) -> dict[str, Any] | AnalysisFailure:
    sources: dict[str, str] = {}
    for path in sorted(paths):
        try:
            sources[str(path)] = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            return _failure("UnclosedExpression", str(path), str(error))
    return extract_sources(revision, sources)
