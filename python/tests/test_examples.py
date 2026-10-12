# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Runs every file in examples/ and checks it exits cleanly.

Each example asserts its own expected output before printing, so a failing
assertion (a broken example) fails this test via a non-zero exit code
rather than passing unnoticed alongside stale printed output.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import necoherence

_EXAMPLES_DIR = Path(__file__).resolve().parent.parent / "examples"
_EXAMPLE_PATHS = sorted(_EXAMPLES_DIR.glob("*.py"))
_PACKAGE_PATH = Path(necoherence.__file__).resolve().parents[1]


def test_execution_inputs_directory_is_not_empty() -> None:
    assert _EXAMPLE_PATHS


def test_every_execution_input_runs_and_exits_cleanly() -> None:
    for path in _EXAMPLE_PATHS:
        result = subprocess.run(
            [sys.executable, str(path)],
            capture_output=True,
            env={**os.environ, "PYTHONPATH": str(_PACKAGE_PATH)},
            text=True,
            timeout=30,
        )
        assert result.returncode == 0, f"{path.name} failed:\n{result.stdout}\n{result.stderr}"
