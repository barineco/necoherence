# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

"""Checked entry points for Python signature source generation."""
from __future__ import annotations

from necoherence.signature_values import sum_tag
from necoherence.type_signatures import AdmissionFailure, CheckedSignatureGeneration, ExpectedSignatureBasis, admit_signature_generation, checkLibrary
from .signature_codegen import render_signatures


def render_checked(checked) -> str:
    if type(checked) is not CheckedSignatureGeneration:
        raise TypeError("render_checked requires CheckedSignatureGeneration")
    checkLibrary(checked.input["signatures"])
    definitions = {definition["id"] for definition in checked.input["signatures"]["definitions"]}
    if any(entry["definition"] not in definitions for entry in checked.input["entrypoints"]):
        raise AdmissionFailure("GN01")
    if any(sum_tag(node["shape"]) == "Opaque" for node in checked.input["signatures"]["nodes"]):
        raise AdmissionFailure("GN02")
    return render_signatures(checked)


def render_expected(expected_basis, exchange: str) -> str:
    if type(expected_basis) is not ExpectedSignatureBasis:
        raise TypeError("expected basis required")
    return render_checked(admit_signature_generation(expected_basis, exchange))
