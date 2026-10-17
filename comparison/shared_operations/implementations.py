# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT


from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
DRIVERS = Path(__file__).resolve().parent
RUN_TIMEOUT = 300
BUILD_TIMEOUT = 1800


class ImplementationError(RuntimeError):
    pass


def require_executable(name: str) -> str:
    found = shutil.which(name)
    if not found:
        raise ImplementationError(f"{name} not found on PATH")
    return found


def build(command: list[str], cwd: Path) -> str:
    try:
        process = subprocess.run(command, cwd=str(cwd), capture_output=True, text=True, timeout=BUILD_TIMEOUT)
    except subprocess.TimeoutExpired as exc:
        raise ImplementationError(f"build timed out after {BUILD_TIMEOUT}s: {' '.join(command)}") from exc
    if process.returncode != 0:
        raise ImplementationError(f"build exited {process.returncode}: {' '.join(command)}\n{process.stderr}")
    return process.stdout


def run_subprocess(command: list[str], stdin_text: str, cwd: Path) -> str:
    try:
        process = subprocess.run(
            command, input=stdin_text, cwd=str(cwd), capture_output=True, text=True, timeout=RUN_TIMEOUT
        )
    except subprocess.TimeoutExpired as exc:
        raise ImplementationError(f"command timed out after {RUN_TIMEOUT}s: {' '.join(command)}") from exc
    if process.returncode != 0:
        raise ImplementationError(f"command exited {process.returncode}: {' '.join(command)}\nstderr:\n{process.stderr}")
    lines = process.stdout.strip().splitlines()
    if not lines:
        raise ImplementationError(f"command produced no output: {' '.join(command)}\nstderr:\n{process.stderr}")
    return lines[-1]


def parse_result(name: str, raw_line: str) -> Any:
    try:
        return json.loads(raw_line)
    except json.JSONDecodeError as exc:
        raise ImplementationError(f"{name}: invalid JSON on stdout: {exc}\nraw: {raw_line[:2000]}") from exc


class Implementation:
    name: str
    command: list[str]
    cwd: Path

    def run(self, stdin_text: str) -> Any:
        return parse_result(self.name, run_subprocess(self.command, stdin_text, self.cwd))


class LeanImpl(Implementation):
    name = "lean"

    def __init__(self) -> None:
        self.cwd = DRIVERS / "lean_driver"
        build([require_executable("lake"), "build", "feature-check"], self.cwd)
        self.command = [str(self.cwd / ".lake" / "build" / "bin" / "feature-check")]


class PythonImpl(Implementation):
    name = "python"

    def __init__(self) -> None:
        self.cwd = ROOT
        self.command = [sys.executable, str(DRIVERS / "python_driver.py")]


class RustImpl(Implementation):
    name = "rust"

    def __init__(self) -> None:
        self.cwd = DRIVERS / "rust_driver"
        output = build([require_executable("cargo"), "build", "--locked", "--message-format=json"], self.cwd)
        executables = [
            message["executable"]
            for message in map(json.loads, output.splitlines())
            if message.get("reason") == "compiler-artifact"
            and message.get("target", {}).get("name") == "shared_operations_driver"
            and message.get("executable")
        ]
        if not executables:
            raise ImplementationError("cargo build produced no shared_operations_driver executable")
        self.command = [executables[-1]]


class TypeScriptImpl(Implementation):
    name = "typescript"

    def __init__(self) -> None:
        self.cwd = ROOT / "typescript"
        tsx = self.cwd / "node_modules" / ".bin" / "tsx"
        if not tsx.exists():
            raise ImplementationError(f"{tsx} not found; install the TypeScript dependencies with npm ci")
        self.command = [str(tsx), str(DRIVERS / "ts_driver.ts")]


def java_tool(tool: str) -> str:
    java_home = os.environ.get("JAVA_HOME")
    if java_home:
        candidate = Path(java_home) / "bin" / tool
        if candidate.exists():
            return str(candidate)
    return require_executable(tool)


class JavaImpl(Implementation):
    name = "java"

    def __init__(self) -> None:
        self.cwd = ROOT / "java"
        self._classes = tempfile.TemporaryDirectory(prefix="shared-operations-java-")
        sources = sorted(str(path) for path in (self.cwd / "src" / "main" / "java").rglob("*.java"))
        sources += sorted(str(path) for path in (DRIVERS / "java_driver").glob("*.java"))
        build([java_tool("javac"), "-d", self._classes.name, *sources], self.cwd)
        self.command = [
            java_tool("java"),
            "-Dfile.encoding=UTF-8",
            "-Dstdout.encoding=UTF-8",
            "-Dstderr.encoding=UTF-8",
            "-cp",
            self._classes.name,
            "necoherence.comparison.FeatureCheck",
        ]


class GleamImpl(Implementation):
    name = "gleam"

    def __init__(self) -> None:
        self.cwd = DRIVERS / "gleam_driver"
        build([require_executable("gleam"), "build"], self.cwd)
        code_paths = sorted(str(path) for path in (self.cwd / "build" / "dev" / "erlang").glob("*/ebin") if path.is_dir())
        if not code_paths:
            raise ImplementationError("Gleam Erlang build produced no ebin directories")
        self.command = [require_executable("erl"), "-noshell"]
        for path in code_paths:
            self.command.extend(["-pa", path])
        self.command.extend(["-eval", "feature_check:main().", "-s", "init", "stop"])


def build_implementations() -> list[Implementation]:
    return [LeanImpl(), PythonImpl(), RustImpl(), TypeScriptImpl(), JavaImpl(), GleamImpl()]
