# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

import ast
import os
import shutil
import subprocess
import sys
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

import necoherence
import pytest

_PACKAGE = Path(necoherence.__file__).resolve().parent
_PROJECT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class Mutation:
    broken_property: str
    module: str
    definition: str
    rewrite: Callable[[ast.AST], bool]


def _flip_comparison(source: type[ast.cmpop], target: type[ast.cmpop], operand: str) -> Callable[[ast.AST], bool]:
    def rewrite(node: ast.AST) -> bool:
        if not isinstance(node, ast.Compare) or len(node.ops) != 1 or not isinstance(node.ops[0], source):
            return False
        names = {child.attr for child in ast.walk(node) if isinstance(child, ast.Attribute)}
        if operand not in names:
            return False
        node.ops = [target()]
        return True

    return rewrite


def _pop_first_instead_of_last(node: ast.AST) -> bool:
    if (
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "pop"
        and not node.args
    ):
        node.args = [ast.Constant(0)]
        return True
    return False


def _drop_required_field(field: str) -> Callable[[ast.AST], bool]:
    def rewrite(node: ast.AST) -> bool:
        if not isinstance(node, ast.Tuple):
            return False
        kept = [element for element in node.elts if not (isinstance(element, ast.Constant) and element.value == field)]
        if len(kept) == len(node.elts):
            return False
        node.elts = kept
        return True

    return rewrite


MUTATIONS = (
    Mutation(
        "latest-wins admits only the current request",
        "request_progression",
        "_policy_order_allowed",
        _flip_comparison(ast.Eq, ast.NotEq, "current_identity"),
    ),
    Mutation(
        "a parent segment removes the most recent segment",
        "files",
        "_normalize_segments",
        _pop_first_instead_of_last,
    ),
    Mutation(
        "a declared write failure stops the replacement",
        "files",
        "_replace",
        _flip_comparison(ast.In, ast.NotIn, "write_failures"),
    ),
    Mutation(
        "fold takes its bound as an input field",
        "iteration",
        "fold",
        _drop_required_field("count"),
    ),
)


def _definition(tree: ast.Module, name: str) -> ast.AST:
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == name:
            return node
        targets = node.targets if isinstance(node, ast.Assign) else [node.target] if isinstance(node, ast.AnnAssign) else []
        if any(isinstance(target, ast.Name) and target.id == name for target in targets):
            return node
    raise LookupError(f"definition {name} is not in the module")


def _mutated_package(directory: Path, mutation: Mutation | None) -> Path:
    root = directory / "packages"
    shutil.copytree(_PACKAGE, root / "necoherence", ignore=shutil.ignore_patterns("__pycache__"))
    if mutation is not None:
        path = root / "necoherence" / f"{mutation.module}.py"
        tree = ast.parse(path.read_text(encoding="utf-8"))
        applied = [node for node in ast.walk(_definition(tree, mutation.definition)) if mutation.rewrite(node)]
        assert len(applied) == 1, f"{mutation.broken_property}: expected one rewritten node, found {len(applied)}"
        path.write_text(ast.unparse(ast.fix_missing_locations(tree)) + "\n", encoding="utf-8")
    return root


def _run_suite(packages: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable, "-m", "pytest", "-q", "-x", "-p", "no:cacheprovider",
            "-o", f"pythonpath={packages}",
            "--ignore", str(Path(__file__).resolve()),
            str(_PROJECT / "tests"),
        ],
        cwd=_PROJECT,
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        text=True,
        capture_output=True,
        timeout=600,
    )


def test_suite_accepts_the_unchanged_package(tmp_path: Path) -> None:
    result = _run_suite(_mutated_package(tmp_path, None))
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize("mutation", MUTATIONS, ids=[mutation.broken_property for mutation in MUTATIONS])
def test_suite_rejects_a_package_that_breaks_the_property(mutation: Mutation, tmp_path: Path) -> None:
    result = _run_suite(_mutated_package(tmp_path, mutation))
    assert result.returncode == 1, result.stdout + result.stderr
