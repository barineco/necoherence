# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Canonical identity encodings of semantic types and functions."""

from __future__ import annotations

from collections.abc import Sequence
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .semantic_composition import TypeRef


def encode_tuple(parts: Sequence[str]) -> str:
    return "".join(f"{len(part.encode('utf-8'))}:{part}" for part in parts)


def type_identity(reference: TypeRef) -> str:
    source = reference.source
    declared_revision = source.get("declared_revision")
    return encode_tuple(
        (
            "type",
            str(source.get("repository", "")),
            str(source.get("revision", "")),
            str(source.get("path", "")),
            str(source.get("content_digest", "")),
            str(source.get("document_id", "")),
            "some" if declared_revision is not None else "none",
            "" if declared_revision is None else str(declared_revision),
            reference.definition_name,
            encode_tuple(tuple(str(value) for value in reference.pointer)),
        )
    )


def function_identity(reference: object) -> str:
    return encode_tuple(
        (
            str(getattr(reference, "identity")),
            str(getattr(reference, "revision")),
            str(getattr(reference, "content_digest")),
        )
    )
