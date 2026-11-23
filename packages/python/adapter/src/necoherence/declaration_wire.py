# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Typed wire checks for type signature libraries, mirroring the Lean SignatureWire instances."""
from __future__ import annotations

from typing import Any

from .profile_wire import (
    FORMAT_USE, INTEGER_SPEC, ORIGIN, PROFILE_REF, SEALED_REFINEMENT, SOURCE_IDENTITY,
    STRING_SPEC, VALUE_PROFILE,
)
from .signature_values import DecimalLiteral, JsonFailure, WireFailure, decode_wire_json
from .wire_schema import (
    UNIT, boolean, closed, direct, each_element, flat_case, int_text, listed, nat_text, optional, record,
    record_case, string, tuple_case, units, variant,
)


def decimal_text(value: Any, path: str) -> None:
    string(value, path)
    if value != value.strip(" \t\n\r"):
        raise WireFailure("Syntax", path, "decimal whitespace")
    try:
        number = decode_wire_json(value)
    except JsonFailure:
        raise WireFailure("Syntax", path, "invalid exact decimal") from None
    if type(number) is not int and not isinstance(number, DecimalLiteral):
        raise WireFailure("Syntax", path, "invalid exact decimal")


def exact_json(value: Any, path: str) -> None:
    _EXACT_JSON(value, path)


_EXACT_JSON = variant({
    "Null": UNIT,
    "Bool": tuple_case(boolean),
    "Integer": tuple_case(int_text),
    "Decimal": flat_case(("text", decimal_text)),
    "String": tuple_case(string),
    "Array": flat_case(("items", direct(each_element(exact_json)))),
    "Object": flat_case(("members", direct(each_element(record(
        ("key", string), ("value", direct(exact_json)),
    ))))),
})

TARGET = variant({
    "Library": UNIT,
    "Group": tuple_case(string),
    "Definition": tuple_case(string),
    "Type": tuple_case(string),
    "Outcome": record_case(record(("definition", string), ("outcome", string))),
})
ANNOTATION = record(("target", TARGET), ("key", string), ("value", exact_json))
PROVENANCE_BINDING = record(("target", TARGET), ("origins", listed(ORIGIN)))
DEFINITION_GROUP = record(("id", string), ("members", listed(string)))

SLOT = record(("type_id", string), ("required", boolean), ("nullable", boolean))
FIELD = record(("wire_name", string), ("slot", SLOT))
PORT = record(("id", string), ("contract", SLOT))
RESOURCE_PRODUCTION = record(
    ("id", string), ("token_type", string), ("revision", nat_text), ("quantity", nat_text),
    ("provenance", string),
)
OUTCOME_CAUSE = variant({
    "ValueContract": record_case(record(("origin", ORIGIN))),
    "ExternalCondition": record_case(record(("specification", ORIGIN))),
})
OUTCOME_CONTRACT = record(
    ("id", string), ("form", variant(units("Success", "DeclaredFailure"))), ("cause", OUTCOME_CAUSE),
    ("value_ports", listed(PORT)), ("produced_resources", listed(RESOURCE_PRODUCTION)),
)
OPERATION_CONTRACT = record(
    ("effect", variant(units("HttpRequestResponse", "DataOnly"))), ("inputs", listed(PORT)),
    ("outcomes", listed(OUTCOME_CONTRACT)),
)

DECIMAL_BOUND = record(("mantissa", int_text), ("scale", nat_text), ("exclusive", boolean))
DECIMAL_SPEC = record(("minimum", optional(DECIMAL_BOUND)), ("maximum", optional(DECIMAL_BOUND)))
VALUE_KIND = variant(units("Null", "Boolean", "Number", "String", "Array", "Object"))
MEMBER_TEST = variant({"Absent": UNIT, "Format": tuple_case(string)})
MEMBER_CHECK = record(("key", string), ("test", MEMBER_TEST))
BRANCH_SELECTOR = variant({
    "InternalTag": UNIT,
    "MemberShape": tuple_case(listed(MEMBER_CHECK)),
    "Kind": tuple_case(VALUE_KIND),
    "Otherwise": UNIT,
})
ELEMENT_CONTRACT = record(("type_id", string), ("nullable", boolean))
EXTRA_MEMBERS = variant({
    "Reject": UNIT,
    "Allow": record_case(record(("key_format", optional(FORMAT_USE)), ("value", ELEMENT_CONTRACT))),
})
PRODUCT_SPEC = record(("fields", listed(FIELD)), ("extras", EXTRA_MEMBERS))
ARRAY_SPEC = record(
    ("item", ELEMENT_CONTRACT), ("min_length", optional(nat_text)), ("max_length", optional(nat_text)),
)
UNION_BRANCH = record(("target", string), ("wire_tag", string), ("selector", BRANCH_SELECTOR))
UNION_SPEC = record(("branches", listed(UNION_BRANCH)))
BOOLEAN_SPEC = record(("const_value", optional(boolean)), ("default_value", optional(boolean)))
LENGTH_SPEC = record(("minimum", optional(nat_text)), ("maximum", optional(nat_text)))

SHAPE = variant({
    "Unknown": tuple_case(variant(units("Any", "OrdinaryObject"))),
    "Unit": UNIT,
    "Boolean": tuple_case(BOOLEAN_SPEC),
    "Integer": tuple_case(INTEGER_SPEC),
    "Decimal": tuple_case(DECIMAL_SPEC),
    "String": tuple_case(STRING_SPEC),
    "Bytes": tuple_case(LENGTH_SPEC),
    "Product": tuple_case(PRODUCT_SPEC),
    "Array": tuple_case(ARRAY_SPEC),
    "TaggedUnion": tuple_case(UNION_SPEC),
    "Sealed": record_case(record(("tag", string), ("refinements", listed(SEALED_REFINEMENT)))),
    "Never": UNIT,
    "Alias": record_case(record(("target", string))),
    "RawBody": record_case(record(("encoding", string))),
    "Opaque": record_case(record(("type_name", string))),
})
NODE = record(("id", string), ("shape", SHAPE))

DEFINITION_SHAPE = variant({
    "Value": tuple_case(string),
    "Symbol": tuple_case(string),
    "Operation": tuple_case(OPERATION_CONTRACT),
    "Message": tuple_case(string),
})
DEFINITION = record(("id", string), ("wire_identity", string), ("shape", DEFINITION_SHAPE))

LIBRARY = record(
    ("schema", string), ("identity", string), ("revision", string), ("profile", VALUE_PROFILE),
    ("sources", listed(SOURCE_IDENTITY)), ("provenance", listed(PROVENANCE_BINDING)),
    ("groups", listed(DEFINITION_GROUP)), ("annotations", listed(ANNOTATION)),
    ("nodes", listed(NODE)), ("definitions", listed(DEFINITION)),
)
SIGNATURE_BASIS = record(
    ("signature_schema", string), ("library_identity", string), ("library_revision", string),
    ("profile", PROFILE_REF), ("graph_sha256", string), ("provenance_sha256", string),
    ("metadata_sha256", string), ("problem_sha256", optional(string)),
    ("observations_sha256", optional(string)), ("entrypoints_sha256", string),
)
_GOAL_OBSERVATION_KEYS = ("outputs", "failures", "final_resources", "effects", "residuals", "execution_failures", "provenance")


def GOAL_OBSERVATIONS(value, path):
    closed(value, _GOAL_OBSERVATION_KEYS, path)
EXPECTED_SIGNATURE_BASIS = record(("basis", SIGNATURE_BASIS), ("observations", optional(GOAL_OBSERVATIONS)))
ENTRYPOINT = record(("identity", string), ("definition", string))
