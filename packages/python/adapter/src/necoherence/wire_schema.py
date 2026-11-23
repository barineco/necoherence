# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Typed checks for the signature wire, mirroring the Lean Wire instances.

A check validates one decoded JSON value at a path and raises WireFailure with one of the Lean kinds: UnsupportedSchema, UnknownField, UnknownTag, or Syntax. The path follows the Lean get and keys rules. A record field is at the path of the field. A list element adds its index to the path of the list, except under each_element, which keeps the path of the list as the Lean decodeExact does for the items of an exact JSON value. A variant payload keeps the path of the enclosing value. A direct field keeps the path of its record, as the Lean code decodes it without a get.
"""
from __future__ import annotations

import copy
import re
from collections.abc import Callable, Mapping
from typing import Any

from .signature_values import JsonFailure, WireFailure, decode_wire_json

Check = Callable[[Any, str], None]
_Case = tuple[str, Check]
UNIT: None = None

_USIZE_SIZE = 2**64
_JSON_NUMBER_SPELLING = re.compile(r"(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:([eE])([+-]?)([0-9]+))?")


class _Direct:
    def __init__(self, check: Check) -> None:
        self.check = check


def closed(value: Any, names: tuple[str, ...], path: str) -> None:
    if not isinstance(value, Mapping):
        raise WireFailure("Syntax", path, "object expected")
    actual = set(value)
    extra = sorted(actual.difference(names))
    if extra:
        raise WireFailure("UnknownField", f"{path}.{extra[0]}", extra[0])
    for name in names:
        if name not in actual:
            raise WireFailure("Syntax", f"{path}.{name}", "missing field")


def string(value: Any, path: str) -> None:
    if type(value) is not str:
        raise WireFailure("Syntax", path, "String expected")


def boolean(value: Any, path: str) -> None:
    if type(value) is not bool:
        raise WireFailure("Syntax", path, "Bool expected")


def int_text(value: Any, path: str) -> None:
    string(value, path)
    if re.fullmatch(r"-?[0-9]+", value) is None:
        raise WireFailure("Syntax", path, "expected canonical integer")
    if re.fullmatch(r"0|-?[1-9][0-9]*", value) is None:
        raise WireFailure("Syntax", path, "noncanonical integer")


def nat_text(value: Any, path: str) -> None:
    int_text(value, path)
    if value.startswith("-"):
        raise WireFailure("Syntax", path, "negative natural")


def optional(check: Check) -> Check:
    def run(value: Any, path: str) -> None:
        if value is not None:
            check(value, path)
    return run


def each_element(check: Check) -> Check:
    def run(value: Any, path: str) -> None:
        if type(value) is not list:
            raise WireFailure("Syntax", path, "array expected")
        for item in value:
            check(item, path)
    return run


def listed(check: Check) -> Check:
    def run(value: Any, path: str) -> None:
        if type(value) is not list:
            raise WireFailure("Syntax", path, "array expected")
        for index, item in enumerate(value):
            check(item, f"{path}[{index}]")
    return run


def direct(check: Check) -> _Direct:
    return _Direct(check)


def record(*fields: tuple[str, Check | _Direct]) -> Check:
    names = tuple(name for name, _ in fields)

    def run(value: Any, path: str) -> None:
        closed(value, names, path)
        for name, check in fields:
            if isinstance(check, _Direct):
                check.check(value[name], path)
            else:
                check(value[name], f"{path}.{name}")
    return run


def tuple_case(check: Check) -> _Case:
    return ("value", check)


def record_case(check: Check) -> _Case:
    return ("fields", check)


def flat_case(*fields: tuple[str, Check | _Direct]) -> _Case:
    return ("flat", record(("tag", string), *fields))


def units(*names: str) -> dict[str, _Case | None]:
    return {name: UNIT for name in names}


def variant(cases: dict[str, _Case | None], *, read_payload: bool = False) -> Check:
    def run(value: Any, path: str) -> None:
        if type(value) is not dict:
            raise WireFailure("Syntax", f"{path}.tag", "object expected")
        if "tag" not in value:
            raise WireFailure("Syntax", f"{path}.tag", "property not found: tag")
        tag = value["tag"]
        if type(tag) is not str:
            raise WireFailure("Syntax", f"{path}.tag", "String expected")
        if tag not in cases:
            raise WireFailure("UnknownTag", f"{path}.tag", tag)
        case = cases[tag]
        if case is None:
            closed(value, ("tag",), path)
            return
        kind, check = case
        if kind == "flat":
            check(value, path)
            return
        field = "value" if kind == "value" else "fields"
        closed(value, ("tag", field), path)
        check(value[field], f"{path}.{field}" if read_payload else path)
    return run


def json_number_grammar(spelling: str) -> tuple[str, str, str, str, str, str]:
    matched = _JSON_NUMBER_SPELLING.fullmatch(spelling)
    if matched is None: raise ValueError("JSON number required")
    sign, whole, fraction, marker, exponent_sign, exponent = matched.groups(); fraction = fraction or ""
    if len(fraction) > _USIZE_SIZE: raise ValueError("too many decimals")
    return sign, whole, fraction, marker, exponent_sign, exponent


def wire_document(value: Any) -> Any:
    if isinstance(value, (bytes, bytearray)):
        try:
            value = bytes(value).decode("utf-8")
        except UnicodeDecodeError as error:
            raise JsonFailure(str(error)) from None
    if type(value) is not str:
        return copy.deepcopy(value)
    return decode_wire_json(value)
