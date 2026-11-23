# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

import json
import posixpath
import re
import subprocess
import sys
import tomllib
from collections.abc import Iterable, Mapping
from pathlib import Path, PurePosixPath

import pytest

ROOT = Path(__file__).resolve().parents[1]

PERMISSIVE = "MIT"
COPYLEFT = "AGPL-3.0-only"
MANIFESTS = frozenset({"lakefile.toml", "gleam.toml", "Cargo.toml", "package.json", "pyproject.toml"})
TREE_DESCRIPTION_FILES = frozenset({"REUSE.toml", ".gitignore", ".gitattributes"})
PACKAGE_NAME_FORMS = ("Necoherence{camel}", "necoherence_{snake}", "necoherence-{stem}", "necoherence.{stem}")
STRING_LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"|\'((?:[^\'\\]|\\.)*)\'|`([^`]*)`')
PATH_CALL_OPEN = re.compile(r"(?:os\.path\.join|PurePosixPath|PureWindowsPath|PurePath|Path)\([^\"'`()]*$")


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


def scope_members(
    declared: Mapping[str, frozenset[str]],
    manifests: Mapping[str, str],
    scopes: list[PurePosixPath],
) -> dict[PurePosixPath, dict[str, list[str]]]:
    members: dict[PurePosixPath, dict[str, list[str]]] = {scope: {} for scope in scopes}
    for name, identifiers in declared.items():
        scope = scope_of(name, scopes)
        if scope is not None:
            members[scope].setdefault(" AND ".join(sorted(identifiers)) or "none", []).append(name)
    for name, identifier in manifests.items():
        scope = scope_of(name, scopes)
        if scope is not None:
            members[scope].setdefault(identifier, []).append(f"{name} (manifest)")
    return members


def scope_violations(
    declared: Mapping[str, frozenset[str]],
    manifests: Mapping[str, str],
    scopes: list[PurePosixPath],
) -> list[str]:
    members = scope_members(declared, manifests, scopes)
    return [
        f"{scope}: " + "; ".join(f"{identifier}: {sorted(names)[:5]}" for identifier, names in sorted(licenses.items()))
        for scope, licenses in members.items()
        if len(licenses) > 1
    ]


def copyleft_scopes(
    declared: Mapping[str, frozenset[str]],
    manifests: Mapping[str, str],
    scopes: list[PurePosixPath],
) -> list[PurePosixPath]:
    return [scope for scope, licenses in scope_members(declared, manifests, scopes).items() if set(licenses) == {COPYLEFT}]


def manifest_licenses(root: Path, files: Iterable[str]) -> dict[str, str]:
    return {
        name: identifier
        for name in files
        if (text := readable_text(root / name)) is not None and (identifier := manifest_license(name, text)) is not None
    }


def package_names(scopes: Iterable[PurePosixPath]) -> list[str]:
    stems = sorted({"-".join(reversed(scope.parts)) for scope in scopes})
    return [
        form.format(stem=stem, snake=stem.replace("-", "_"), camel="".join(part.capitalize() for part in stem.split("-")))
        for stem in stems
        for form in PACKAGE_NAME_FORMS
    ]


def package_name_pattern(scopes: Iterable[PurePosixPath]) -> re.Pattern[str]:
    return re.compile("|".join(re.escape(name) for name in package_names(scopes)))


def assembled_values(line: str) -> list[str]:
    matches = list(STRING_LITERAL.finditer(line))
    values: list[str] = []
    current: str | None = None
    in_path_call = False
    for index, match in enumerate(matches):
        literal = next(group for group in match.groups() if group is not None)
        gap = line[matches[index - 1].end():match.start()].strip() if index else None
        joined = None
        if current is not None:
            if gap == "+":
                joined = current + literal
            elif gap == "/" or (gap == "," and in_path_call):
                joined = posixpath.join(current, literal)
        if joined is None:
            if current is not None:
                values.append(current)
            in_path_call = PATH_CALL_OPEN.search(line[:match.start()]) is not None
            current = literal
        else:
            current = joined
    if current is not None:
        values.append(current)
    return values


def copyleft_targets(declared: Mapping[str, frozenset[str]], scopes: Iterable[PurePosixPath]) -> frozenset[str]:
    copyleft_only = {name for name, identifiers in declared.items() if identifiers == {COPYLEFT}}
    mixed_directories = {
        parent.as_posix()
        for name, identifiers in declared.items()
        if identifiers != {COPYLEFT}
        for parent in PurePosixPath(name).parents
    }
    directories = {
        parent.as_posix()
        for name in copyleft_only
        for parent in PurePosixPath(name).parents
        if parent != PurePosixPath(".")
    } - mixed_directories
    return frozenset(copyleft_only | directories | {scope.as_posix() for scope in scopes})


def copyleft_references(name: str, text: str, *, targets: frozenset[str], names: re.Pattern[str]) -> list[str]:
    path = PurePosixPath(name)
    if path.suffix == ".md" or path.name in TREE_DESCRIPTION_FILES:
        return []
    hits = []
    for number, line in enumerate(text.splitlines(), 1):
        values = assembled_values(line)
        located = any(
            posixpath.normpath(posixpath.join(base, value)) in targets
            for value in values
            if value
            for base in (path.parent.as_posix(), ".")
        )
        if names.search(line) or any(names.search(value) for value in values) or located:
            hits.append(f"{name}:{number}: {line.strip()[:120]}")
    return hits


SOURCE_SUFFIXES = frozenset({".rs", ".py", ".ts", ".java", ".gleam", ".lean"})
DECLARATION_BASENAMES = MANIFESTS | {"lakefile.lean"}
LAKEFILE_PACKAGE = re.compile(r"^\s*package\s+(?:«([^»]+)»|([A-Za-z_][\w.]*))", re.MULTILINE)
REQUIREMENT_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
CARGO_DEPENDENCY_TABLES = ("dependencies", "dev-dependencies", "build-dependencies")


def declared_package_names(name: str, text: str) -> list[str]:
    basename = PurePosixPath(name).name
    if basename == "lakefile.lean":
        return [first or second for first, second in LAKEFILE_PACKAGE.findall(text)]
    if basename == "package.json":
        value = json.loads(text).get("name")
        return [value] if isinstance(value, str) else []
    if basename not in MANIFESTS:
        return []
    document = tomllib.loads(text)
    if basename == "Cargo.toml":
        tables = [document.get("package", {}), document.get("lib", {})]
    elif basename == "pyproject.toml":
        tables = [document.get("project", {})]
    else:
        tables = [document]
    return [table["name"] for table in tables if isinstance(table, dict) and isinstance(table.get("name"), str)]


def agpl_package_names(
    root: Path, files: Iterable[str], scopes: list[PurePosixPath], agpl_scopes: Iterable[PurePosixPath]
) -> dict[str, list[str]]:
    agpl = set(agpl_scopes)
    return {
        name: declared
        for name in files
        if PurePosixPath(name).name in DECLARATION_BASENAMES
        and scope_of(name, scopes) in agpl
        and (text := readable_text(root / name)) is not None
        and (declared := declared_package_names(name, text))
    }


def name_forms(declared: Iterable[str]) -> frozenset[str]:
    return frozenset(form for value in declared for form in (value, value.replace("-", "_")))


def name_boundary_pattern(names: Iterable[str]) -> re.Pattern[str]:
    alternatives = "|".join(re.escape(name) for name in sorted(names, key=len, reverse=True))
    return re.compile(rf"(?<![\w-])(?:{alternatives})(?![\w-])")


def dependency_keys(name: str, text: str) -> list[str]:
    basename = PurePosixPath(name).name
    if basename == "package.json":
        document = json.loads(text)
        return [key for section in ("dependencies", "devDependencies") for key in (document.get(section) or {})]
    if basename not in MANIFESTS:
        return []
    document = tomllib.loads(text)
    if basename == "Cargo.toml":
        containers = [document, *(table for table in document.get("target", {}).values() if isinstance(table, dict))]
        keys: list[str] = []
        for container in containers:
            for section in CARGO_DEPENDENCY_TABLES:
                for key, value in container.get(section, {}).items():
                    keys.append(key)
                    if isinstance(value, dict) and isinstance(value.get("package"), str):
                        keys.append(value["package"])
        return keys
    if basename == "pyproject.toml":
        project = document.get("project", {})
        requirements = list(project.get("dependencies", []))
        for group in project.get("optional-dependencies", {}).values():
            requirements.extend(group)
        return [match.group(0) for requirement in requirements if (match := REQUIREMENT_NAME.match(requirement))]
    if basename == "gleam.toml":
        return [key for section in ("dependencies", "dev-dependencies") for key in document.get(section, {})]
    return []


def agpl_package_references(name: str, text: str, *, names: frozenset[str]) -> list[str]:
    path = PurePosixPath(name)
    forms = names | {form.replace("_", "-") for form in names}
    hits = [f"{name}: dependency {key}" for key in dependency_keys(name, text) if key in forms or key.replace("-", "_") in names]
    if path.suffix in SOURCE_SUFFIXES and names:
        pattern = name_boundary_pattern(names)
        hits.extend(
            f"{name}:{number}: {line.strip()[:120]}"
            for number, line in enumerate(text.splitlines(), 1)
            if pattern.search(line)
        )
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
    manifests = manifest_licenses(ROOT, files)
    assert scope_violations(declared, manifests, scopes) == []


def test_permissive_files_do_not_reference_copyleft_files_or_scopes(
    files: list[str], declared: dict[str, frozenset[str]]
) -> None:
    permissive = sorted(name for name, identifiers in declared.items() if identifiers == {PERMISSIVE})
    scopes = copyleft_scopes(declared, manifest_licenses(ROOT, files), license_scopes(files))
    targets = copyleft_targets(declared, scopes)
    names = package_name_pattern(scopes)
    assert permissive
    assert scopes
    assert targets
    hits = [
        hit
        for name in permissive
        if (text := readable_text(ROOT / name)) is not None
        for hit in copyleft_references(name, text, targets=targets, names=names)
    ]
    assert hits == []


SCOPES = license_scopes(tracked_files(ROOT))
AGPL_SCOPES = copyleft_scopes(declared_licenses(ROOT), manifest_licenses(ROOT, tracked_files(ROOT)), SCOPES)
NESTED_SCOPE = next(scope for scope in SCOPES if scope not in AGPL_SCOPES and any(agpl in scope.parents for agpl in AGPL_SCOPES))
AGPL_SCOPE = next(scope for scope in AGPL_SCOPES if scope in NESTED_SCOPE.parents)
MIT_SCOPE = next(scope for scope in SCOPES if scope not in AGPL_SCOPES and not any(other in scope.parents for other in SCOPES))
PACKAGE_NAMES = package_names([AGPL_SCOPE])
AGPL_DECLARED_NAMES = agpl_package_names(ROOT, tracked_files(ROOT), SCOPES, AGPL_SCOPES)
AGPL_NAMES = name_forms(name for names in AGPL_DECLARED_NAMES.values() for name in names)


def declared_name_in(basename: str) -> str | None:
    return next(
        (names[0] for manifest, names in sorted(AGPL_DECLARED_NAMES.items()) if PurePosixPath(manifest).name == basename),
        None,
    )


def test_agpl_package_names_are_read_from_the_tree() -> None:
    assert AGPL_DECLARED_NAMES
    assert AGPL_NAMES
    assert declared_name_in("Cargo.toml") is not None


def test_permissive_files_do_not_depend_on_agpl_packages(files: list[str], declared: dict[str, frozenset[str]]) -> None:
    permissive = sorted(name for name, identifiers in declared.items() if identifiers == {PERMISSIVE})
    assert permissive
    assert AGPL_NAMES
    hits = [
        hit
        for name in permissive
        if (text := readable_text(ROOT / name)) is not None
        for hit in agpl_package_references(name, text, names=AGPL_NAMES)
    ]
    assert hits == []


def dependency_cases() -> list[tuple[str, str, bool, str]]:
    cargo = declared_name_in("Cargo.toml") or ""
    cases = [
        ("mit/Cargo.toml", '[package]\nname = "mit"\n\n[dependencies]\nnecoherence = "0.2"\n', False, "dep-permissive-only"),
        ("mit/src/lib.rs", "use necoherence::core::Nat;\n", False, "dep-rust-permissive-use"),
        ("mit/Cargo.toml", f'[dependencies]\n{cargo} = {{ path = "../x" }}\n', True, "dep-cargo-agpl-crate"),
        ("mit/src/lib.rs", f"use {cargo.replace('-', '_')}::solve;\n", True, "dep-rust-agpl-use"),
        ("mit/Cargo.toml", f'[dependencies]\n{cargo} = "0.2"\n', True, "mutation-key-replaced"),
        ("mit/Cargo.toml", f'[dependencies]\nnecoherence = "0.2"\n\n[dev-dependencies]\n{cargo} = "0.2"\n', True, "mutation-dev-only"),
        ("mit/Cargo.toml", f'[dependencies]\n{cargo} = {{ version = "0.2" }}\n', True, "mutation-version-only"),
    ]
    for basename, template, label in (
        ("pyproject.toml", '[project]\nname = "mit"\ndependencies = ["{name}>=1"]\n', "python"),
        ("package.json", '{{"name": "mit", "dependencies": {{"{name}": "1"}}}}\n', "package-json"),
        ("gleam.toml", 'name = "mit"\n\n[dependencies]\n{name} = ">= 1.0.0"\n', "gleam"),
    ):
        agpl = declared_name_in(basename)
        if agpl is not None:
            cases.append((f"mit/{basename}", template.format(name=agpl), True, f"dep-{label}-agpl-package"))
    return cases


@pytest.mark.parametrize(
    ("name", "text", "rejected"),
    [case[:3] for case in dependency_cases()],
    ids=[case[3] for case in dependency_cases()],
)
def test_package_reference_check_rejects_agpl_packages(name: str, text: str, rejected: bool) -> None:
    assert bool(agpl_package_references(name, text, names=AGPL_NAMES)) is rejected


def test_package_reference_check_respects_word_boundaries() -> None:
    longer = f"{declared_name_in('Cargo.toml')}-extra"
    assert agpl_package_references("mit/src/lib.rs", f"use {longer.replace('-', '_')}::x;\n", names=AGPL_NAMES) == []


@pytest.mark.parametrize(
    ("declared", "manifests", "rejected"),
    [
        ({f"{AGPL_SCOPE}/src/a.py": frozenset({COPYLEFT}), f"{AGPL_SCOPE}/src/b.py": frozenset({PERMISSIVE})}, {}, True),
        ({f"{MIT_SCOPE}/src/a.py": frozenset({PERMISSIVE}), f"{MIT_SCOPE}/src/b.py": frozenset({COPYLEFT})}, {}, True),
        ({f"{MIT_SCOPE}/src/a.py": frozenset()}, {f"{MIT_SCOPE}/pyproject.toml": PERMISSIVE}, True),
        ({f"{AGPL_SCOPE}/rust/lib.rs": frozenset({COPYLEFT})}, {f"{AGPL_SCOPE}/rust/Cargo.toml": PERMISSIVE}, True),
        (
            {f"{AGPL_SCOPE}/src/a.py": frozenset({COPYLEFT}), f"{NESTED_SCOPE}/a.json": frozenset({PERMISSIVE})},
            {f"{AGPL_SCOPE}/pyproject.toml": COPYLEFT},
            False,
        ),
        (
            {f"{MIT_SCOPE}/src/a.py": frozenset({PERMISSIVE}), f"{MIT_SCOPE}/src/added.py": frozenset({PERMISSIVE})},
            {f"{MIT_SCOPE}/pyproject.toml": PERMISSIVE},
            False,
        ),
    ],
    ids=["tool-declared-permissive", "package-declared-copyleft", "undeclared", "manifest-differs", "nested-scope", "added-permissive"],
)
def test_scope_check_rejects_mixed_declarations(
    declared: dict[str, frozenset[str]], manifests: dict[str, str], rejected: bool
) -> None:
    assert bool(scope_violations(declared, manifests, SCOPES)) is rejected


AGPL_PROGRAM = "verification/execution/agpl_program"
AGPL_FILE = f"{AGPL_SCOPE}/src/tool.py"

REFERENCE_DECLARED = {
    AGPL_FILE: frozenset({COPYLEFT}),
    f"{AGPL_SCOPE}/README.md": frozenset({PERMISSIVE}),
    f"{NESTED_SCOPE}/a.json": frozenset({PERMISSIVE}),
    AGPL_PROGRAM + "/Cargo.toml": frozenset({COPYLEFT}),
    AGPL_PROGRAM + "/src/main.rs": frozenset({COPYLEFT}),
    "verification/execution/guarded.py": frozenset({COPYLEFT}),
    "verification/execution/helper.py": frozenset({PERMISSIVE}),
}


def quoted(value: str) -> list[str]:
    return [f'"{part}"' for part in value.split("/")]


def split_literal(value: str) -> str:
    cut = len(value) // 2
    return f'name = "{value[:cut]}" + "{value[cut:]}"\n'


def separated_path(value: str) -> str:
    return f"str(ROOT / {' / '.join(quoted(value))})\n"


def joined_path(value: str) -> str:
    return f"os.path.join(ROOT, {', '.join(quoted(value))})\n"


def constructed_path(value: str) -> str:
    return f"Path({', '.join(quoted(value))})\n"


REFERENCE_CASES = [
    ("lean/Necoherence.lean", f"import {PACKAGE_NAMES[0]}.TypedMappingSolver\n", True, "lean-import"),
    ("rust/Cargo.toml", f'[dependencies]\nsolver = {{ path = "../{AGPL_SCOPE}/src" }}\n', True, "rust-path-dependency"),
    ("verification/execution/runner.py", f"import {PACKAGE_NAMES[1]}\n", True, "python-import"),
    ("verification/network_effect/ts_consumer.ts", f'import {{ solve }} from "{PACKAGE_NAMES[2]}";\n', True, "typescript-import"),
    ("verification/network_effect/java_consumer/Consumer.java", f"var renderer = new {PACKAGE_NAMES[3]}.renderer.Renderer();\n", True, "java-reference"),
    ("rust/src/lib.rs", f"use {PACKAGE_NAMES[1]}::solver;\n", True, "rust-use"),
    (
        "verification/execution/runner.py",
        f'command = ["cargo", "run", "--manifest-path", "{PACKAGE_NAMES[2]}/Cargo.toml"]\n',
        True,
        "separate-process",
    ),
    (
        "verification/execution/runner.py",
        'subprocess.run(["cargo", "run", "--manifest-path", str(HERE / "agpl_program" / "Cargo.toml")])\n',
        True,
        "split-path-directory",
    ),
    ("verification/execution/runner.py", 'subprocess.run([str(HERE / "guarded.py")])\n', True, "split-path-file"),
    (
        "verification/execution/runner.py",
        f'command = ["cargo", "run", "--manifest-path", "{AGPL_FILE}"]\n',
        True,
        "root-relative-path",
    ),
    ("verification/execution/runner.py", separated_path(AGPL_FILE), True, "root-joined-file"),
    ("verification/execution/runner.py", separated_path(AGPL_SCOPE.as_posix()), True, "root-joined-scope-with-document"),
    ("verification/execution/runner.py", joined_path(AGPL_FILE), True, "os-path-join-file"),
    ("verification/execution/runner.py", constructed_path(AGPL_FILE), True, "path-arguments-file"),
    ("verification/execution/runner.py", split_literal(AGPL_FILE), True, "concatenated-file"),
    ("verification/execution/runner.py", split_literal(PACKAGE_NAMES[2]), True, "concatenated-package-name"),
    ("verification/execution/runner.py", 'subprocess.run([str(HERE / "helper.py")])\n', False, "permissive-sibling"),
    ("verification/execution/runner.py", separated_path(f"{NESTED_SCOPE}/a.json"), False, "permissive-nested-scope"),
    ("python/README.md", f"The design tools live in the {AGPL_SCOPE}/ directory.\n", False, "documentation-path"),
    ("REUSE.toml", f'path = ["{AGPL_FILE}"]\n', False, "reuse-tree-description"),
    (".gitignore", f"{AGPL_SCOPE}/target/\n", False, "gitignore-tree-description"),
    (".gitattributes", f"{AGPL_FILE} text\n", False, "gitattributes-tree-description"),
]


@pytest.mark.parametrize(
    ("name", "text", "rejected"),
    [case[:3] for case in REFERENCE_CASES],
    ids=[case[3] for case in REFERENCE_CASES],
)
def test_reference_check_rejects_copyleft_references(name: str, text: str, rejected: bool) -> None:
    references = copyleft_references(
        name,
        text,
        targets=copyleft_targets(REFERENCE_DECLARED, [AGPL_SCOPE]),
        names=package_name_pattern([AGPL_SCOPE]),
    )
    assert bool(references) is rejected
