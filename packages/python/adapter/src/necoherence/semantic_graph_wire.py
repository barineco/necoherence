# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Wire check of a semantic graph, reading each record as the Lean tools decoder does: the key set first, then the fields in order."""
from __future__ import annotations

from .declaration_wire import BOOLEAN_SPEC, BRANCH_SELECTOR
from .profile_wire import FORMAT_USE, INTEGER_SPEC, STRING_SPEC, VALUE_PROFILE
from .type_signatures import SOURCE_REF, TYPE_REF
from .wire_schema import (
    Check,
    boolean,
    listed,
    nat_text,
    optional,
    record,
    record_case,
    string,
    tuple_case,
    units,
    variant,
)

ORIGIN = record(("source", SOURCE_REF), ("pointer", listed(string)))
from necoherence.declaration_wire import DECIMAL_SPEC
SLOT = record(("type_ref", TYPE_REF), ("required", boolean), ("nullable", boolean))
ELEMENT = record(("type_ref", TYPE_REF), ("nullable", boolean))

UNION_BRANCH = record(("target", TYPE_REF), ("wire_tag", string), ("selector", BRANCH_SELECTOR), ("origin", ORIGIN))
FIELD = record(("wire_name", string), ("slot", SLOT), ("origin", ORIGIN))
EXTRAS = variant({
    "Reject": None,
    "Allow": record_case(record(("key_format", optional(FORMAT_USE)), ("value", ELEMENT))),
}, read_payload=True)
SHAPE = variant({
    "Boolean": tuple_case(BOOLEAN_SPEC),
    "Integer": tuple_case(INTEGER_SPEC),
    "Decimal": tuple_case(DECIMAL_SPEC),
    "String": tuple_case(STRING_SPEC),
    "Unknown": tuple_case(variant(units("Any", "OrdinaryObject"))),
    "Unit": None,
    "Never": None,
    "Alias": record_case(record(("target", TYPE_REF), ("reference_text", string))),
    "Array": tuple_case(record(("item", ELEMENT), ("min_length", optional(nat_text)), ("max_length", optional(nat_text)))),
    "Product": tuple_case(record(("fields", listed(FIELD)), ("extras", EXTRAS))),
    "TaggedUnion": tuple_case(record(("branches", listed(UNION_BRANCH)))),
}, read_payload=True)
NODE = record(
    ("reference", TYPE_REF), ("shape", SHAPE), ("description", optional(string)),
    ("attributes", listed(ORIGIN)), ("extensions", listed(ORIGIN)),
)
SEMANTIC_GRAPH: Check = record(("profile", VALUE_PROFILE), ("nodes", listed(NODE)), ("source_refs", listed(SOURCE_REF)))
