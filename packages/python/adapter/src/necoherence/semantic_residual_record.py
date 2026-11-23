# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

from collections.abc import Mapping, Sequence

from neco_quotient_encoding import (
    EncodingFailure,
    Err,
    JsonArray,
    JsonBool,
    JsonNull,
    JsonNumber,
    JsonObject,
    JsonString,
    JsonValue,
    canonical_bytes,
    normalize_residuals,
)

from .signature_values import exact_encode
from .type_signatures import decode_signature_basis, encode_semantic_obligations, encode_type_ref

SEMANTIC_RESIDUAL_SCHEMA = "necoherence.semantic-residual.v1"


class SemanticResidualFailure(ValueError):
    def __init__(self, failure: EncodingFailure) -> None:
        super().__init__(failure.operation)
        self.failure = failure


def _neco(value: object) -> JsonValue:
    if value is None:
        return JsonNull()
    if isinstance(value, bool):
        return JsonBool(value)
    if isinstance(value, int):
        return JsonNumber(str(value))
    if isinstance(value, str):
        return JsonString(value)
    if isinstance(value, Mapping):
        return JsonObject(tuple((key, _neco(child)) for key, child in value.items()))
    if isinstance(value, (list, tuple)):
        return JsonArray(tuple(_neco(child) for child in value))
    raise TypeError("wire value required")


def encode_semantic_residual(
    basis: object,
    type_ref: Mapping[str, object],
    value: object,
    obligations: Sequence[Mapping[str, object]],
) -> bytes:
    basis_wire = _neco(decode_signature_basis(basis))
    type_ref_wire = _neco(encode_type_ref(type_ref))
    value_wire = _neco(exact_encode(value))
    obligations_wire = tuple(_neco(item) for item in encode_semantic_obligations(obligations))
    residuals = normalize_residuals(obligations_wire)
    if isinstance(residuals, Err):
        raise SemanticResidualFailure(residuals.failure)
    record = JsonObject((
        ("schema", JsonString(SEMANTIC_RESIDUAL_SCHEMA)),
        ("basis", basis_wire),
        ("input", JsonObject((("type_ref", type_ref_wire), ("value", value_wire)))),
        ("residuals", JsonArray(residuals.value)),
    ))
    encoded = canonical_bytes(record)
    if isinstance(encoded, Err):
        raise SemanticResidualFailure(encoded.failure)
    return encoded.value

