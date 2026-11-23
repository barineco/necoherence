# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

import subprocess
import sys

import necoherence
import pytest


def _run(code: str) -> str:
    process = subprocess.run(
        [sys.executable, "-c", code], capture_output=True, text=True, check=True,
        env={"PYTHONPATH": str(__import__("pathlib").Path(necoherence.__file__).resolve().parents[1])},
    )
    return process.stdout.strip()


def test_every_exported_name_resolves_to_its_defining_module() -> None:
    for name in necoherence.__all__:
        assert hasattr(necoherence, name), name
        assert name in dir(necoherence)


def test_importing_the_package_loads_no_feature_module() -> None:
    loaded = _run(
        "import sys, necoherence; print(sorted(m for m in sys.modules if m.startswith('necoherence.')))"
    )
    assert loaded == "[]"


def test_using_one_name_loads_only_the_modules_it_needs() -> None:
    loaded = _run(
        "import sys, necoherence; necoherence.store_of; "
        "print(sorted(m for m in sys.modules if m.startswith('necoherence.')))"
    )
    assert "network_effect" not in loaded and "semantic_composition" not in loaded
    assert "necoherence.store" in loaded


def test_an_unknown_name_is_an_attribute_error() -> None:
    with pytest.raises(AttributeError):
        necoherence.no_such_name  # noqa: B018
