# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

from __future__ import annotations

import subprocess
from collections.abc import Iterable
from pathlib import Path, PurePosixPath
from typing import NamedTuple

import pytest

ROOT = Path(__file__).resolve().parents[1]


class Division(NamedTuple):
    directories: frozenset[str]
    exact: bool


def exact(*names: str) -> Division:
    return Division(frozenset(names), True)


def contains(*names: str) -> Division:
    return Division(frozenset(names), False)


LANGUAGES = ("rust", "python", "typescript", "java", "gleam")

DIVISIONS: dict[str, Division] = {
    ".": exact(".github", "LICENSES", "docs", "generator", "packages", "residual-coherence", "solver", "tests", "verification"),
    "packages": exact("lean", *LANGUAGES),
    "packages/lean": contains("Necoherence", "Tests"),
    **{f"packages/{language}": exact("adapter") for language in LANGUAGES},
    **{f"packages/{language}/adapter": contains("http", "src") for language in LANGUAGES},
    **{f"packages/{language}/adapter/http": contains("src") for language in LANGUAGES},
    "generator": exact("rust", "lean"),
    "solver": exact("rust", "lean", "verification", "composition"),
    "solver/composition": exact("rust", "lean", "verification"),
    "residual-coherence": exact("python", "schema", "lean"),
    "verification": exact("declaration", "execution", "lean", "network_effect", "observation", "presets", "rust", "shared_operations"),
    "tests": exact(),
}


def tracked_files(root: Path) -> list[str]:
    listed = subprocess.run(["git", "ls-files", "-z"], cwd=root, check=True, capture_output=True).stdout
    return sorted(name for name in listed.decode("utf-8").split("\0") if name)


def child_directories(files: Iterable[str], node: str) -> frozenset[str]:
    base = PurePosixPath(node)
    found: set[str] = set()
    for name in files:
        parent = PurePosixPath(name).parent
        if parent != base and base in parent.parents:
            found.add(parent.relative_to(base).parts[0])
    return frozenset(found)


def mismatch(files: Iterable[str], node: str, division: Division) -> str | None:
    listed = list(files)
    actual = child_directories(listed, node)
    missing = division.directories - actual
    unexpected = actual - division.directories if division.exact else frozenset()
    if not missing and not unexpected:
        return None
    return f"{node}: missing {sorted(missing)}, unexpected {sorted(unexpected)}"


@pytest.fixture(scope="module")
def files() -> list[str]:
    return tracked_files(ROOT)


@pytest.mark.parametrize("node", sorted(DIVISIONS))
def test_node_directories_match_the_declared_divisions(files: list[str], node: str) -> None:
    assert mismatch(files, node, DIVISIONS[node]) is None


def test_every_declared_node_is_a_directory_in_the_tree(files: list[str]) -> None:
    for node in DIVISIONS:
        if node != ".":
            assert child_directories(files, PurePosixPath(node).parent.as_posix()) >= {PurePosixPath(node).name}, node


@pytest.mark.parametrize(
    ("node", "files"),
    [
        (
            "residual-coherence",
            [
                "residual-coherence/README.md",
                "residual-coherence/pyproject.toml",
                "residual-coherence/src/residual_coherence/core.py",
                "residual-coherence/tests/test_public_api.py",
                "residual-coherence/examples/typed-reachability-minimal.json",
                "residual-coherence/schema/analysis-input.schema.json",
                "residual-coherence/lean/lakefile.toml",
            ],
        ),
        ("generator", ["generator/rust/Cargo.toml", "generator/lean/lakefile.toml", "generator/python/setup.py"]),
        ("solver", ["solver/rust/Cargo.toml", "solver/lean/lakefile.toml", "solver/composition/rust/Cargo.toml", "solver/verification/a.py", "solver/python/setup.py"]),
        ("packages/python", ["packages/python/adapter/src/a.py", "packages/python/http/src/a.py"]),
    ],
)
def test_layout_check_rejects_a_directory_outside_the_divisions(node: str, files: list[str]) -> None:
    assert mismatch(files, node, DIVISIONS[node]) is not None
