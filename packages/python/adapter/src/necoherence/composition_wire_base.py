# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Wire primitives and identifier codecs shared by the composition wire modules."""

from __future__ import annotations

import copy
import re
from collections.abc import Callable, Mapping, Sequence
from typing import TypeAlias, TypeVar, cast

from . import semantic_composition as composition
from .semantic_composition import (
    ABSENT_VALUE,
    NULL_VALUE,
    FieldStep,
    FunctionRef,
    IndexStep,
    InitialLotRef,
    InputId,
    LotId,
    NullValue,
    OutcomeId,
    PortId,
    PresentValue,
    ProducedLotRef,
    ProductionId,
    SiteId,
    SlotContract,
    UnitGuardArm,
    VariantGuardArm,
    VariantStep,
)
from .signature_values import (
    DecimalLiteral,
    WireFailure,
    exact_encode,
    integer_digits,
    integer_from_digits,
    json_number_parts,
    json_number_text,
)
from .wire_schema import closed

Json: TypeAlias = None | bool | int | str | list["Json"] | dict[str, "Json"]
T = TypeVar("T")

INCLUSION_RULE_VALUES: dict[str, str] = {
    "SameDefinedType": "sameDefinedType",
    "EmptySource": "emptySource",
    "Boolean": "boolean",
    "IntegerIntersection": "integerIntersection",
    "FiniteStrings": "finiteStrings",
    "StringConditions": "stringConditions",
    "BytesLength": "bytesLength",
    "Unit": "unit",
    "UnfoldSource": "unfoldSource",
    "UnfoldDestination": "unfoldDestination",
    "Array": "array",
    "Product": "product",
    "SourceUnion": "sourceUnion",
    "DestinationUnion": "destinationUnion",
}


def wire_record(value: object, keys: Sequence[str], path: str) -> Mapping[str, object]:
    closed(value, tuple(keys), path)
    return cast(Mapping[str, object], value)


def wire_mapping(value: object, path: str) -> Mapping[str, object]:
    if not isinstance(value, Mapping):
        raise WireFailure("Syntax", path, "object expected")
    return cast(Mapping[str, object], value)


def wire_array(value: object, path: str) -> Sequence[object]:
    if not isinstance(value, (list, tuple)):
        raise WireFailure("Syntax", path, "array expected")
    return value


def wire_string(value: object, path: str) -> str:
    if not isinstance(value, str):
        raise WireFailure("Syntax", path, "String expected")
    return value


def wire_boolean(value: object, path: str) -> bool:
    if type(value) is not bool:
        raise WireFailure("Syntax", path, "Bool expected")
    return value


def wire_natural(value: object, path: str) -> int:
    text = wire_string(value, path)
    if re.fullmatch(r"-?[0-9]+", text) is None:
        raise WireFailure("Syntax", path, "expected canonical integer")
    if re.fullmatch(r"0|-?[1-9][0-9]*", text) is None:
        raise WireFailure("Syntax", path, "noncanonical integer")
    if text.startswith("-"):
        raise WireFailure("Syntax", path, "negative natural")
    return integer_from_digits(text)


def wire_json(value: object, path: str) -> Json:
    if value is None or type(value) in (bool, int, str):
        return cast(Json, copy.deepcopy(value))
    if isinstance(value, (list, tuple)):
        return [wire_json(item, f"{path}") for index, item in enumerate(value)]
    if isinstance(value, Mapping):
        result: dict[str, Json] = {}
        for key, item in value.items():
            if not isinstance(key, str):
                raise WireFailure("Syntax", path, value)
            result[key] = wire_json(item, f"{path}.{key}")
        return result
    raise WireFailure("Syntax", path, value)


def wire_sum(value: object, forms: Mapping[str, str | None], path: str) -> tuple[str, object | None]:
    """Read a closed sum as the Lean `get tag` followed by `keys` on the tag and the form."""
    tag = wire_tag(value, path)
    if tag not in forms:
        raise WireFailure("UnknownTag", f"{path}.tag", tag)
    form = forms[tag]
    keys = ("tag",) if form is None else ("tag", form)
    closed = wire_record(value, keys, path)
    return tag, None if form is None else closed[form]


def wire_unit(tag: str) -> dict[str, Json]:
    return {"tag": tag}


def wire_tuple(tag: str, value: Json) -> dict[str, Json]:
    return {"tag": tag, "value": value}


def wire_fields(tag: str, fields: dict[str, Json]) -> dict[str, Json]:
    return {"tag": tag, "fields": fields}


def wire_list(value: object, path: str, decoder: Callable[[object, str], T]) -> tuple[T, ...]:
    return tuple(decoder(item, f"{path}[{index}]") for index, item in enumerate(wire_array(value, path)))


def encode_slot_contract(value: SlotContract) -> dict[str, Json]:
    return {"type_id": value.type_ref.definition_name, "required": value.required, "nullable": value.nullable}


def encode_path_step(value: FieldStep | IndexStep | VariantStep) -> dict[str, Json]:
    if isinstance(value, FieldStep):
        return wire_tuple("Field", value.value)
    if isinstance(value, IndexStep):
        return wire_tuple("Index", str(value.value))
    return wire_tuple("Variant", value.value)


def encode_slot_value(value: object) -> dict[str, Json]:
    if value is ABSENT_VALUE or value.__class__.__name__ == "AbsentValue":
        return wire_unit("Absent")
    if value is NULL_VALUE or isinstance(value, NullValue):
        return wire_unit("Null")
    if isinstance(value, PresentValue):
        return wire_tuple("Present", exact_encode(value.value))
    raise TypeError("unknown slot value")


def decode_function_ref(value: object, path: str) -> FunctionRef:
    row = wire_record(value, ("identity", "revision", "content_digest"), path)
    return FunctionRef(
        wire_string(row["identity"], f"{path}.identity"),
        wire_string(row["revision"], f"{path}.revision"),
        wire_string(row["content_digest"], f"{path}.content_digest"),
    )


def encode_function_ref(value: FunctionRef) -> dict[str, Json]:
    return {"identity": value.identity, "revision": value.revision, "content_digest": value.content_digest}


def decode_resource_lot_ref(value: object, path: str) -> InitialLotRef | ProducedLotRef:
    tag, item = wire_sum(value, {"Initial": "value", "Produced": "fields"}, path)
    if tag == "Initial":
        return InitialLotRef(LotId(wire_string(item, path)))
    row = wire_record(item, ("site", "outcome", "production"), path)
    return ProducedLotRef(SiteId(wire_string(row["site"], f"{path}.site")), OutcomeId(wire_string(row["outcome"], f"{path}.outcome")), ProductionId(wire_string(row["production"], f"{path}.production")))


def encode_resource_lot_ref(value: InitialLotRef | ProducedLotRef) -> dict[str, Json]:
    if isinstance(value, InitialLotRef):
        return wire_tuple("Initial", value.id.value)
    return wire_fields("Produced", {"site": value.site.value, "outcome": value.outcome.value, "production": value.production.value})


def encode_guard_arm(value: UnitGuardArm | VariantGuardArm) -> dict[str, Json]:
    if isinstance(value, VariantGuardArm):
        return wire_tuple("Variant", value.tag)
    return wire_unit({UnitGuardArm.PRESENT: "Present", UnitGuardArm.ABSENT: "Absent", UnitGuardArm.NULL: "Null", UnitGuardArm.UNKNOWN_VARIANT: "UnknownVariant", UnitGuardArm.ACCEPTED: "Accepted", UnitGuardArm.REJECTED: "Rejected"}[value])


def decode_producer(value: object, path: str) -> composition.ProducerRef:
    tag, payload_value = wire_sum(value, {"Initial": "value", "InvocationOutcome": "fields"}, path)
    if tag == "Initial":
        return composition.InitialProducer(InputId(wire_string(payload_value, path)))
    row = wire_record(payload_value, ("site", "outcome", "port"), path)
    return composition.InvocationOutcomeProducer(
        SiteId(wire_string(row["site"], f"{path}.site")), OutcomeId(wire_string(row["outcome"], f"{path}.outcome")),
        PortId(wire_string(row["port"], f"{path}.port")),
    )


def wire_get(value: object, key: str) -> object:
    """Read a field as the Lean `get` does, without the closed-object check of `wire_record`."""
    row = wire_mapping(value, "$")
    if key not in row:
        raise WireFailure("Syntax", "$", f"property not found: {key}")
    return row[key]


def wire_key(value: object, key: str, path: str) -> object:
    """Read a field as the Lean `get json key`, whose failure is at `path.key`."""
    if not isinstance(value, Mapping):
        raise WireFailure("Syntax", f"{path}.{key}", "object expected")
    if key not in value:
        raise WireFailure("Syntax", f"{path}.{key}", f"property not found: {key}")
    return value[key]


def wire_tag(value: object, path: str) -> str:
    """Read the tag as the Lean `get (α := String) json "tag"`."""
    return wire_string(wire_key(value, "tag", path), f"{path}.tag")


def wire_frame(value: object, key: str, path: str) -> object:
    """Read a field as the Lean `liftJson (json.getObjVal? key)`, whose failure and value keep the path of `value`."""
    if not isinstance(value, Mapping):
        raise WireFailure("Syntax", path, "object expected")
    if key not in value:
        raise WireFailure("Syntax", path, f"property not found: {key}")
    return value[key]


def _number_text(value: object) -> str | None:
    """The number text that the Lean `canonicalJson` writes, or None when the value is not a JSON number."""
    if isinstance(value, DecimalLiteral):
        return json_number_text(*json_number_parts(value.spelling))
    if type(value) is int:
        return integer_digits(value)
    return None


def json_equal(left: object, right: object) -> bool:
    """Compare two wire values as the Lean `sameJson` does: numbers by the text that the Lean `canonicalJson` writes, and other values by their JSON kind, so that a boolean never equals an integer."""
    left_number, right_number = _number_text(left), _number_text(right)
    if left_number is not None or right_number is not None:
        return left_number == right_number
    if type(left) is not type(right):
        return False
    if isinstance(left, Mapping):
        assert isinstance(right, Mapping)
        return left.keys() == right.keys() and all(json_equal(left[key], right[key]) for key in left)
    if isinstance(left, (list, tuple)):
        assert isinstance(right, (list, tuple))
        return len(left) == len(right) and all(json_equal(a, b) for a, b in zip(left, right, strict=True))
    return bool(left == right)
