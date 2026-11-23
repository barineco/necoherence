# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

import copy
import json
import sys
from collections.abc import Mapping
from dataclasses import replace

from necoherence.composition_wire_base import wire_key
from necoherence.declaration_wire import exact_json
from necoherence.semantic_graph_wire import SEMANTIC_GRAPH
from necoherence.signature_values import AbsentValue, CertificateMismatchFailure, DecimalLiteral, NullValue, UnresolvedValueFailure, ValueContext, ValueFailure, WireFailure, decode_wire_json, encode_wire_json, exact_decode, exact_encode, exact_from_json, integer_digits, json_output_number
from necoherence.signature_values import FieldStep, IndexStep, VariantStep
from necoherence.type_signatures import TYPE_REF
from necoherence.wire_schema import boolean


def plain(value):
    return json.loads(encode_wire_json(value))


def canonical(value):
    if isinstance(value, DecimalLiteral): return ("number", json_output_number(value).text)
    if type(value) is int: return ("number", integer_digits(value))
    if isinstance(value, Mapping): return ("object", tuple(sorted((key, canonical(item)) for key, item in value.items())))
    if isinstance(value, list): return ("array", tuple(canonical(item) for item in value))
    return ("value", value)


def step_tag(step):
    if type(step) is int or isinstance(step, IndexStep):
        return "Index"
    if isinstance(step, VariantStep):
        return "Variant"
    return "Field"


def path(value):
    return [{"tag": step_tag(step), "value": str(getattr(step, "value", step))} for step in value]


def application(value):
    return {"value_path": path(value.value_path), "type_ref": plain(value.type_ref), "origin": plain(value.origin), "value": exact_encode(value.value)}


def obligation(value):
    return {"type_ref": plain(value["type_ref"]), "origin": plain(value["origin"]), "value_path": path(value["value_path"]), "profile": plain(value["profile"]), "reason": plain(value["reason"])}


def unique_exact(value):
    if value["tag"] == "Array": return all(unique_exact(item) for item in value["items"])
    if value["tag"] == "Object":
        keys = [member["key"] for member in value["members"]]
        return len(set(keys)) == len(keys) and all(unique_exact(member["value"]) for member in value["members"])
    return True


def check_input(case):
    SEMANTIC_GRAPH(wire_key(case, "graph", "$"), "$.graph")
    TYPE_REF(wire_key(case, "reference", "$"), "$.reference")
    exact_json(wire_key(case, "before", "$"), "$.before")
    boolean(wire_key(case, "tamper", "$"), "$.tamper")


def evaluate(case):
    try:
        check_input(case)
    except WireFailure as failure:
        return {"id": case["id"], "status": "Wire", "classification": failure.kind, "path": failure.path}
    context = ValueContext(case["graph"])
    before = exact_decode(case["before"])
    try:
        if "wire" in case:
            if not unique_exact(case["before"]): return {"id": case["id"], "status": "Wire", "classification": "DuplicateField", "path": "$"}
            if canonical(exact_from_json(decode_wire_json(case["wire"]))) != canonical(before):
                raise RuntimeError("wire and exact input differ")
            result = context.decode_with_defaults(case["reference"], case["wire"])
        else:
            result = context.materialize_defaults(case["reference"], before)
        second = context.materialize_defaults(case["reference"], result.value)
        row = {"id": case["id"], "status": "Accepted", "value": exact_encode(result.value), "applications": [application(item) for item in result.applications], "second_value": exact_encode(second.value), "second_applications": [application(item) for item in second.applications], "input": exact_encode(before)}
        if case["tamper"]:
            first = result.applications[0]
            wrong_ref = plain(first.type_ref)
            wrong_ref["source"]["document_id"] += "-forged"
            wrong_origin = plain(first.origin)
            wrong_origin["pointer"].append("forged")
            forged = [replace(first, type_ref=wrong_ref), replace(first, origin=wrong_origin), replace(first, value_path=(*first.value_path, FieldStep("forged"))), replace(first, value=True)]
            row["certificates"] = [context.check_default_applications(before, result.value, (item, *result.applications[1:])) for item in forged]
        return row
    except WireFailure as failure:
        return {"id": case["id"], "status": "Wire", "classification": failure.kind, "path": "$"}
    except UnresolvedValueFailure as failure:
        return {"id": case["id"], "status": "Unresolved", "obligations": [obligation(item) for item in failure.obligations]}
    except CertificateMismatchFailure as failure:
        return {"id": case["id"], "status": "CertificateMismatch", "condition": failure.condition}
    except ValueFailure as failure:
        condition = {"tag": failure.condition.tag.value}
        if failure.condition.value is not None:
            condition["value"] = failure.condition.value
        if isinstance(failure.observed, AbsentValue):
            observed = {"tag": "Absent"}
        elif isinstance(failure.observed, NullValue):
            observed = {"tag": "Null"}
        else:
            observed = {"tag": "Present", "value": exact_encode(failure.observed.value)}
        return {"id": case["id"], "status": "Rejected", "type_ref": plain(failure.type_ref), "definition_ref": plain(failure.definition_ref), "origin": plain(failure.origin), "value_path": path(failure.value_path), "condition": condition, "observed": observed, "reference_trace": [plain(item) for item in failure.reference_trace]}


if __name__ == "__main__":
    for line in sys.stdin:
        case = json.loads(line)
        try:
            row = evaluate(case)
        except Exception as failure:
            row = {"id": case["id"], "status": "AdapterFailure", "message": f"{type(failure).__name__}: {failure}"}
        print(json.dumps(row, separators=(",", ":"), ensure_ascii=False))
