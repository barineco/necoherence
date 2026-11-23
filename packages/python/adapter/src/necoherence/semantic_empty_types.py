# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Checked empty semantic types for the preparation of composition inputs."""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass

from .semantic_composition import (
    InclusionFailure,
    SemanticGraph,
    TypeRef,
    UnitInclusionFailure,
    _find_type,
    _mapping,
    _nodes,
    _sequence,
    _type_ref_from_native,
)
from .signature_values import ValueContext, integer, payload, string_condition

_checked_value_token = object()


@dataclass(frozen=True, slots=True, init=False)
class CheckedEmptyTypes:
    refs: tuple[TypeRef, ...]

    def __init__(self, token: object, refs: tuple[TypeRef, ...]) -> None:
        if token is not _checked_value_token:
            raise TypeError("checked empty types require verification")
        object.__setattr__(self, "refs", refs)


def _shape(node: Mapping[str, object]) -> Mapping[str, object]:
    return _mapping(node.get("shape"), "type shape")


def _spec(shape: Mapping[str, object]) -> Mapping[str, object]:
    return _mapping(payload(shape) or {}, "shape specification")


def _nat_range_empty(minimum: object, maximum: object) -> bool:
    return minimum is not None and maximum is not None and integer(maximum) < integer(minimum)


def _string_finite(spec: Mapping[str, object]) -> object | None:
    if spec.get("const_value") is not None:
        return [spec["const_value"]]
    return spec.get("enum_values")


def _string_empty(context: ValueContext, spec: Mapping[str, object]) -> bool:
    if spec.get("wrapper") is not None:
        return False
    values = _string_finite(spec)
    if values is None:
        return False
    return all(
        string_condition(context.profile, spec, value) is not None
        for value in _sequence(values, "strings")
    )


def _empty_row(
    graph: SemanticGraph, context: ValueContext, refs: tuple[TypeRef, ...], reference: TypeRef
) -> bool:
    node = _find_type(graph, reference)
    if node is None:
        return False
    shape = _shape(node)
    tag = shape.get("tag")
    spec = _spec(shape)
    if tag == "Alias":
        return _type_ref_from_native(spec.get("target")) in refs
    if tag == "String":
        return _string_empty(context, spec)
    if tag == "Bytes":
        return _nat_range_empty(spec.get("minimum"), spec.get("maximum"))
    if tag == "Product":
        return any(
            bool(slot.get("required"))
            and not bool(slot.get("nullable"))
            and _type_ref_from_native(slot["type_ref"]) in refs
            for value in _sequence(spec.get("fields", ()), "fields")
            for slot in (_mapping(_mapping(value, "field").get("slot"), "slot"),)
        )
    if tag == "Array":
        item = _mapping(spec.get("item"), "array item")
        return _nat_range_empty(spec.get("min_length"), spec.get("max_length")) or (
            integer(spec.get("min_length") or 0) > 0
            and not bool(item.get("nullable"))
            and _type_ref_from_native(item["type_ref"]) in refs
        )
    if tag == "TaggedUnion":
        return all(
            _type_ref_from_native(_mapping(value, "branch")["target"]) in refs
            for value in _sequence(spec.get("branches", ()), "branches")
        )
    return False


def verify_empty_types(
    context: ValueContext, refs: Sequence[TypeRef]
) -> CheckedEmptyTypes | InclusionFailure:
    graph: SemanticGraph = context.graph
    checked_refs = tuple(refs)
    if any(reference in checked_refs[:index] for index, reference in enumerate(checked_refs)) or not all(
        _empty_row(graph, context, checked_refs, reference) for reference in checked_refs
    ):
        return UnitInclusionFailure.FORGED_EMPTINESS
    return CheckedEmptyTypes(_checked_value_token, checked_refs)


def empty_types(context: ValueContext) -> tuple[TypeRef, ...]:
    graph: SemanticGraph = context.graph
    distinct: list[TypeRef] = []
    for value in _nodes(graph):
        reference = _type_ref_from_native(_mapping(value, "node")["reference"])
        if reference not in distinct:
            distinct.append(reference)
    return _prune_empty_types(graph, context, len(tuple(_nodes(graph))) + 1, tuple(distinct))


def _prune_empty_types(
    graph: SemanticGraph, context: ValueContext, fuel: int, refs: tuple[TypeRef, ...]
) -> tuple[TypeRef, ...]:
    for _ in range(fuel):
        retained = tuple(reference for reference in refs if _empty_row(graph, context, refs, reference))
        if len(retained) == len(refs):
            return retained
        refs = retained
    return refs
