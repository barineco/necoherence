# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

import json
import re
import subprocess
import sys
import tomllib
from collections.abc import Iterable, Mapping
from pathlib import Path, PurePosixPath

import pytest

ROOT = Path(__file__).resolve().parents[1]

PERMISSIVE = "MIT"
MANIFESTS = frozenset({"lakefile.toml", "gleam.toml", "Cargo.toml", "package.json", "pyproject.toml"})
DEPENDENCY_RECORDS = MANIFESTS | {"Cargo.lock", "lake-manifest.json", "manifest.toml", "package-lock.json"}
TOOLS_NAME = re.compile(r"NecoherenceTools|necoherence_tools|necoherence-tools|necoherence\.tools")
TOOLS_DIRECTORY = re.compile(r"(?<![\w.-])tools/|\.\./tools(?![\w.-])")
TOOLS_IMPORT = re.compile(
    r"^\s*import\s+NecoherenceTools\b"
    r"|^\s*(?:import|from)\s+necoherence_tools\b"
    r"|^\s*import\s+(?:static\s+)?necoherence\.tools\b"
)
TOOLS_SOURCE_REFERENCE = {
    ".rs": re.compile(r"^\s*(?:pub\s+)?(?:use|extern\s+crate)\s+necoherence_tools\b|\bnecoherence_tools\s*::"),
    ".java": re.compile(r"\bnecoherence\.tools\."),
    **{
        suffix: re.compile(r"[\"']necoherence-tools(?:/[^\"']*)?[\"']")
        for suffix in (".ts", ".tsx", ".mts", ".cts", ".js", ".mjs", ".cjs")
    },
}


def tracked_files(root: Path) -> list[str]:
    listed = subprocess.run(["git", "ls-files", "-z"], cwd=root, check=True, capture_output=True).stdout
    return sorted(name for name in listed.decode("utf-8").split("\0") if name)


def declared_licenses(root: Path) -> dict[str, frozenset[str]]:
    report = subprocess.run(
        [sys.executable, "-m", "reuse", "--root", str(root), "spdx"],
        check=True, capture_output=True, text=True,
    ).stdout
    declared: dict[str, set[str]] = {}
    current: str | None = None
    for line in report.splitlines():
        if line.startswith("FileName: "):
            current = line.removeprefix("FileName: ").removeprefix("./")
            declared[current] = set()
        elif line.startswith("LicenseInfoInFile: ") and current is not None:
            declared[current].add(line.removeprefix("LicenseInfoInFile: "))
    return {name: frozenset(identifiers) for name, identifiers in declared.items()}


def license_scopes(files: Iterable[str]) -> list[PurePosixPath]:
    return sorted(
        {PurePosixPath(name).parent for name in files if PurePosixPath(name).name == "LICENSE"} - {PurePosixPath(".")},
        key=lambda scope: len(scope.parts),
        reverse=True,
    )


def scope_of(name: str, scopes: list[PurePosixPath]) -> PurePosixPath | None:
    path = PurePosixPath(name)
    return next((scope for scope in scopes if scope in path.parents), None)


def manifest_license(name: str, text: str) -> str | None:
    basename = PurePosixPath(name).name
    if basename == "package.json":
        value = json.loads(text).get("license")
        return value if isinstance(value, str) else None
    if basename not in MANIFESTS:
        return None
    document = tomllib.loads(text)
    if basename == "gleam.toml":
        licences = document.get("licences")
        return " AND ".join(licences) if isinstance(licences, list) and licences else None
    table = document.get("package" if basename == "Cargo.toml" else "project", {})
    value = table.get("license") if isinstance(table, dict) else None
    if isinstance(value, dict):
        value = value.get("text")
    return value if isinstance(value, str) else None


def scope_violations(
    declared: Mapping[str, frozenset[str]],
    manifests: Mapping[str, str],
    scopes: list[PurePosixPath],
) -> list[str]:
    members: dict[PurePosixPath, dict[str, list[str]]] = {scope: {} for scope in scopes}
    for name, identifiers in declared.items():
        scope = scope_of(name, scopes)
        if scope is not None:
            members[scope].setdefault(" AND ".join(sorted(identifiers)) or "none", []).append(name)
    for name, identifier in manifests.items():
        scope = scope_of(name, scopes)
        if scope is not None:
            members[scope].setdefault(identifier, []).append(f"{name} (manifest)")
    return [
        f"{scope}: " + "; ".join(f"{identifier}: {sorted(names)[:5]}" for identifier, names in sorted(licenses.items()))
        for scope, licenses in members.items()
        if len(licenses) > 1
    ]


def tool_references(name: str, text: str, *, in_permissive_scope: bool) -> list[str]:
    path = PurePosixPath(name)
    dependency_record = path.name in DEPENDENCY_RECORDS
    strict = in_permissive_scope or dependency_record
    source_reference = TOOLS_SOURCE_REFERENCE.get(path.suffix)
    documentation = path.suffix == ".md"
    hits = []
    for number, line in enumerate(text.splitlines(), 1):
        named = strict and TOOLS_NAME.search(line)
        located = strict and not documentation and TOOLS_DIRECTORY.search(line)
        if named or located or TOOLS_IMPORT.search(line) or (source_reference and source_reference.search(line)):
            hits.append(f"{name}:{number}: {line.strip()[:120]}")
    return hits


def readable_text(path: Path) -> str | None:
    if path.is_symlink() or not path.is_file():
        return None
    data = path.read_bytes()
    return None if b"\0" in data else data.decode("utf-8", errors="replace")


@pytest.fixture(scope="module")
def files() -> list[str]:
    return tracked_files(ROOT)


@pytest.fixture(scope="module")
def declared() -> dict[str, frozenset[str]]:
    return declared_licenses(ROOT)


def test_tree_is_reuse_compliant() -> None:
    result = subprocess.run([sys.executable, "-m", "reuse", "--root", str(ROOT), "lint"], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr


def test_each_license_scope_declares_one_license_in_files_and_manifests(
    files: list[str], declared: dict[str, frozenset[str]]
) -> None:
    scopes = license_scopes(files)
    assert scopes
    manifests = {
        name: identifier
        for name in files
        if (text := readable_text(ROOT / name)) is not None and (identifier := manifest_license(name, text)) is not None
    }
    assert scope_violations(declared, manifests, scopes) == []


def test_permissive_files_do_not_reference_the_tools(files: list[str], declared: dict[str, frozenset[str]]) -> None:
    scopes = license_scopes(files)
    permissive = sorted(name for name, identifiers in declared.items() if identifiers == {PERMISSIVE})
    assert permissive
    hits = [
        hit
        for name in permissive
        if (text := readable_text(ROOT / name)) is not None
        for hit in tool_references(name, text, in_permissive_scope=scope_of(name, scopes) is not None)
    ]
    assert hits == []


SCOPES = [PurePosixPath("python"), PurePosixPath("tools"), PurePosixPath("residual-coherence/schema"), PurePosixPath("residual-coherence")]


@pytest.mark.parametrize(
    ("declared", "manifests", "rejected"),
    [
        ({"tools/python/src/a.py": frozenset({"AGPL-3.0-only"}), "tools/python/src/b.py": frozenset({"MIT"})}, {}, True),
        ({"python/src/a.py": frozenset({"MIT"}), "python/src/b.py": frozenset({"AGPL-3.0-only"})}, {}, True),
        ({"python/src/a.py": frozenset()}, {"python/pyproject.toml": "MIT"}, True),
        ({"tools/rust/src/lib.rs": frozenset({"AGPL-3.0-only"})}, {"tools/rust/Cargo.toml": "MIT"}, True),
        (
            {"residual-coherence/src/a.py": frozenset({"AGPL-3.0-only"}), "residual-coherence/schema/a.json": frozenset({"MIT"})},
            {"residual-coherence/pyproject.toml": "AGPL-3.0-only"},
            False,
        ),
        ({"python/src/a.py": frozenset({"MIT"}), "python/src/added.py": frozenset({"MIT"})}, {"python/pyproject.toml": "MIT"}, False),
    ],
    ids=["tool-declared-permissive", "package-declared-copyleft", "undeclared", "manifest-differs", "nested-scope", "added-permissive"],
)
def test_scope_check_rejects_mixed_declarations(
    declared: dict[str, frozenset[str]], manifests: dict[str, str], rejected: bool
) -> None:
    assert bool(scope_violations(declared, manifests, SCOPES)) is rejected


@pytest.mark.parametrize(
    ("name", "text", "in_permissive_scope", "rejected"),
    [
        ("lean/Necoherence.lean", "import NecoherenceTools.TypedMappingSolver\n", True, True),
        ("rust/Cargo.toml", '[dependencies]\nsolver = { path = "../tools/rust" }\n', True, True),
        ("comparison/declaration/semantic_axioms.py", "import necoherence_tools\n", False, True),
        ("comparison/network_effect/ts_driver.ts", 'import { solve } from "necoherence-tools";\n', False, True),
        ("comparison/network_effect/java_driver/Driver.java", "var renderer = new necoherence.tools.renderer.Renderer();\n", False, True),
        ("rust/src/lib.rs", "use necoherence_tools::solver;\n", True, True),
        ("comparison/declaration/semantic_axioms.py", 'command = ["cargo", "run", "--manifest-path", "necoherence-tools/Cargo.toml"]\n', False, False),
        ("python/README.md", "The design tools live in the tools/ directory.\n", True, False),
    ],
    ids=[
        "lean-import", "rust-path-dependency", "python-import", "typescript-import",
        "java-reference", "rust-use", "separate-process", "documentation-path",
    ],
)
def test_reference_check_rejects_dependencies_on_the_tools(
    name: str, text: str, in_permissive_scope: bool, rejected: bool
) -> None:
    assert bool(tool_references(name, text, in_permissive_scope=in_permissive_scope)) is rejected
