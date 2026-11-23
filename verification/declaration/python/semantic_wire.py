# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

"""Wire checks of the classification inputs.

Each check reads a record as the Lean tools decoders do: the key set first, then the fields in the order of the Lean decode.
"""
from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from necoherence.composition_wire_base import wire_key, wire_tag
from necoherence.profile_wire import PROFILE_REF, STRING_SPEC, VALUE_PROFILE
from necoherence.semantic_graph_wire import SLOT
from necoherence.signature_values import WireFailure
from necoherence.type_signatures import SOURCE_REF, TYPE_REF
from necoherence.wire_schema import closed, listed, nat_text, optional, record, record_case, string, tuple_case, units, variant

PATH_STEP = variant({"Field": tuple_case(string), "Index": tuple_case(nat_text), "Variant": tuple_case(string)})
VALUE_PATH = listed(PATH_STEP)
PRODUCER = variant({
    "Initial": tuple_case(string),
    "InvocationOutcome": record_case(record(("site", string), ("outcome", string), ("port", string))),
})
VALUE_REF = record(("producer", PRODUCER), ("path", VALUE_PATH))

_SEMANTIC_REASON_VALUE_TAGS = (
    "UnknownFormat", "UnknownIntegerDomain", "UnknownWrapper", "WrapperPayload", "UnknownSealedTag", "OpaqueType",
    "UninterpretedExtension", "InvalidProfile", "CertificateMismatch", "ProjectionUnavailable",
)
_SEMANTIC_REASON_UNIT_TAGS = (
    "MissingGraphemeRules", "MissingBytesPolicy", "DecimalNotAdmitted", "IntegerBound", "MissingTagModel",
    "UnresolvedType", "MembershipBound",
)
SEMANTIC_REASON = variant({
    **{tag: tuple_case(string) for tag in _SEMANTIC_REASON_VALUE_TAGS},
    **units(*_SEMANTIC_REASON_UNIT_TAGS),
}, read_payload=True)


def semantic_obligation(value: Any, path: str) -> None:
    closed(value, ("type_ref", "origin", "value_path", "profile", "reason"), path)
    TYPE_REF(value["type_ref"], f"{path}.type_ref")
    origin = value["origin"]
    closed(origin, ("source", "pointer"), f"{path}.origin")
    SOURCE_REF(origin["source"], f"{path}.origin.source")
    listed(string)(origin["pointer"], f"{path}.origin.pointer")
    VALUE_PATH(value["value_path"], f"{path}.value_path")
    PROFILE_REF(value["profile"], f"{path}.profile")
    SEMANTIC_REASON(value["reason"], f"{path}.reason")


SEMANTIC_OBLIGATIONS = listed(semantic_obligation)
TYPE_OBLIGATION_REASON = variant({
    "Meaning": tuple_case(SEMANTIC_OBLIGATIONS),
    **units("ConstraintImplication", "Presence", "UnionRemainder", "Inhabitation", "ObligationBoundExhausted"),
    "ExtraField": tuple_case(string),
}, read_payload=True)
EVALUATION_PROVENANCE = record(("operation", string), ("type_ref", TYPE_REF), ("value_path", VALUE_PATH))
COMPOSITION_PROVENANCE = record(("operation", string), ("input_identity", string), ("input_revision", string))


def _type_obligation(value: Any, path: str) -> None:
    closed(value, ("source", "destination", "reason"), path)
    TYPE_REF(value["source"], f"{path}.source")
    TYPE_REF(value["destination"], f"{path}.destination")
    TYPE_OBLIGATION_REASON(value["reason"], f"{path}.reason")


def _type_unresolved(value: Any, path: str) -> None:
    closed(value, ("value", "obligations"), path)
    optional(VALUE_REF)(value["value"], f"{path}.value")
    listed(_type_obligation)(value["obligations"], f"{path}.obligations")


def _solver_unknown(value: Any, path: str) -> None:
    tag = wire_tag(value, path)
    if tag not in ("BindingBoundExhausted", "SearchStepBoundExhausted"):
        raise WireFailure("UnknownTag", f"{path}.tag", tag)
    closed(value, ("tag", "value"), path)
    nat_text(value["value"], f"{path}.value")


UNRESOLVED_OBLIGATION = variant({
    "Meaning": tuple_case(SEMANTIC_OBLIGATIONS),
    "Type": record_case(_type_unresolved),
    "Inhabitation": record_case(record(("producer", PRODUCER), ("contract", SLOT))),
    **units("BranchInhabitation", "UnresolvedUniqueness", "StateBoundExhausted", "BindingBoundExhausted", "BranchBoundExhausted"),
    "ResourceCapacityBound": record_case(record(("required", nat_text), ("limit", nat_text))),
    "ResourceSolverUnknown": tuple_case(_solver_unknown),
}, read_payload=True)


def _public_validation_node(value: Any, path: str) -> None:
    closed(value, ("reference", "shape", "description", "attributes", "extensions"), path)
    shape = value["shape"]
    tag = wire_tag(shape, f"{path}.shape")
    if tag != "String":
        raise WireFailure("UnknownTag", f"{path}.shape.tag", tag)
    closed(shape, ("tag", "value"), f"{path}.shape")
    STRING_SPEC(shape["value"], f"{path}.shape.value")
    TYPE_REF(value["reference"], f"{path}.reference")


def _public_validation_graph(value: Any, path: str) -> None:
    closed(value, ("profile", "nodes", "source_refs"), path)
    VALUE_PROFILE(value["profile"], f"{path}.profile")
    listed(_public_validation_node)(value["nodes"], f"{path}.nodes")


def check_classification_input(case: Mapping[str, Any]) -> None:
    """Check the obligations and the provenance, or the graph and the reference, of a classification input."""
    if case.get("domain") == "composition":
        listed(UNRESOLVED_OBLIGATION)(wire_key(case, "obligations", "$"), "$.obligations")
        COMPOSITION_PROVENANCE(wire_key(case, "provenance", "$"), "$.provenance")
    elif case.get("entry") == "value":
        _public_validation_graph(wire_key(case, "graph", "$"), "$.graph")
        TYPE_REF(wire_key(case, "reference", "$"), "$.reference")
        if "value" not in case:
            raise WireFailure("Syntax", "$", "property not found: value")
    else:
        SEMANTIC_OBLIGATIONS(wire_key(case, "obligations", "$"), "$.obligations")
        EVALUATION_PROVENANCE(wire_key(case, "provenance", "$"), "$.provenance")
