# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Regression checks that the derivation record decodes check the key set before they read a field, as the Lean `keys` does."""

from __future__ import annotations

import copy
from types import SimpleNamespace
from typing import Any, cast

import pytest

from necoherence.type_signatures import signature_basis
from necoherence.signature_composition_wire import _Context, _decode_inclusion, _decode_projection_certificate
from necoherence.signature_values import WireFailure
from necoherence.type_signatures import _graph
from test_semantic_composition import inclusion_certificate, library

PROFILE = {"identity": "test", "revision": "1", "content_digest": "0" * 64}
SOURCE_REF = {
    "repository": "r",
    "revision": "1",
    "path": "p",
    "content_digest": "d",
    "document_id": "",
    "declared_revision": None,
}
CONTRACT = {"type_id": "truth", "required": True, "nullable": False}


def _failure(action: Any) -> tuple[str, str, str]:
    with pytest.raises(WireFailure) as caught:
        action()
    return caught.value.kind, caught.value.path, str(caught.value.observed)


def _inclusion_failure(certificate: dict[str, Any]) -> tuple[str, str, str]:
    declarations = library()
    context = _Context(declarations, _graph(declarations), signature_basis(declarations, []))
    return _failure(lambda: _decode_inclusion(context, certificate, "$.p"))


def test_inclusion_certificate_with_an_extra_key_is_an_unknown_field() -> None:
    certificate = inclusion_certificate(library())
    certificate["extra"] = 1
    assert _inclusion_failure(certificate) == ("UnknownField", "$.p.extra", "extra")


def test_inclusion_certificate_reports_the_keys_before_a_basis_mismatch() -> None:
    certificate = inclusion_certificate(library())
    certificate["basis"] = {}
    certificate["extra"] = 1
    assert _inclusion_failure(certificate) == ("UnknownField", "$.p.extra", "extra")


def test_inclusion_certificate_missing_a_key_is_a_missing_field() -> None:
    certificate = inclusion_certificate(library())
    certificate.pop("root")
    assert _inclusion_failure(certificate) == ("Syntax", "$.p.root", "missing field")


def test_inclusion_pair_row_with_an_extra_key_is_an_unknown_field() -> None:
    certificate = inclusion_certificate(library())
    certificate["pairs"][0]["extra"] = 1
    assert _inclusion_failure(certificate) == ("UnknownField", "$.p.extra", "extra")


def test_inclusion_pair_row_reports_the_keys_before_reading_the_pair() -> None:
    certificate = inclusion_certificate(library())
    certificate["pairs"][0]["pair"] = {}
    certificate["pairs"][0]["extra"] = 1
    assert _inclusion_failure(certificate) == ("UnknownField", "$.p.extra", "extra")


def _resource_certificate() -> dict[str, Any]:
    return {
        "trace": {},
        "lowering": {},
        "correspondence": {"lots": [], "values": [], "normalized_bindings": [], "execution_order": []},
        "reachability": {},
        "acyclicity": {},
        "value_sources": [],
    }


def _projection_certificate() -> dict[str, Any]:
    return {
        "profile": copy.deepcopy(PROFILE),
        "source_refs": [copy.deepcopy(SOURCE_REF)],
        "source": copy.deepcopy(CONTRACT),
        "path": [],
        "assumptions": [],
        "destination": copy.deepcopy(CONTRACT),
    }


def test_projection_certificate_accepts_its_declared_records() -> None:
    certificate = _decode_projection_certificate(_projection_certificate(), "$.p")
    assert certificate.profile == PROFILE


def test_projection_profile_with_an_extra_key_is_an_unknown_field() -> None:
    certificate = _projection_certificate()
    certificate["profile"]["extra"] = 1
    assert _failure(lambda: _decode_projection_certificate(certificate, "$.p")) == ("UnknownField", "$.p.profile.extra", "extra")


def test_projection_source_ref_with_an_extra_key_is_an_unknown_field() -> None:
    certificate = _projection_certificate()
    certificate["source_refs"][0]["extra"] = 1
    assert _failure(lambda: _decode_projection_certificate(certificate, "$.p")) == (
        "UnknownField", "$.p.source_refs[0].extra", "extra",
    )


