# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

import copy
import json
import sys
from dataclasses import replace

from necoherence.signature_values import UnresolvedValueFailure, ValueContext, ValueFailure, WireFailure, encode_wire_json, exact_decode, exact_encode


def plain(value):
    return json.loads(encode_wire_json(value))


def path(value):
    return [{"tag": "Index" if type(step) is int else "Field", "value": str(step)} for step in value]


def application(value):
    return {"value_path": path(value.value_path), "type_ref": plain(value.type_ref), "origin": plain(value.origin), "value": exact_encode(value.value)}


def evaluate(case):
    context = ValueContext(case["graph"])
    before = exact_decode(case["before"])
    try:
        result = context.decode_with_defaults(case["reference"], case["wire"]) if "wire" in case else context.materialize_defaults(case["reference"], before)
        second = context.materialize_defaults(case["reference"], result.value)
        row = {"id": case["id"], "status": "Accepted", "value": exact_encode(result.value), "applications": [application(item) for item in result.applications], "second_value": exact_encode(second.value), "second_applications": [application(item) for item in second.applications], "input": exact_encode(before)}
        if case["tamper"]:
            first = result.applications[0]
            wrong_ref = plain(first.type_ref)
            wrong_ref["source"]["document_id"] += "-forged"
            wrong_origin = plain(first.origin)
            wrong_origin["pointer"].append("forged")
            forged = [replace(first, type_ref=wrong_ref), replace(first, origin=wrong_origin), replace(first, value_path=(*first.value_path, "forged")), replace(first, value=True)]
            row["certificates"] = [context.check_default_applications(before, result.value, (item, *result.applications[1:])) for item in forged]
        return row
    except WireFailure as failure:
        return {"id": case["id"], "status": "Wire", "classification": "DuplicateField" if failure.kind == "DuplicateField" else "Syntax"}
    except UnresolvedValueFailure as failure:
        return {"id": case["id"], "status": "Unresolved", "obligations": plain(failure.obligations)}
    except ValueFailure as failure:
        if failure.condition in ("MembershipBound", "UnresolvedType"):
            return {"id": case["id"], "status": "Unresolved", "obligations": [{"type_ref": plain(failure.type_ref), "origin": plain(failure.origin), "value_path": path(failure.value_path), "profile": case["graph"]["profile"]["reference"], "reason": {"tag": failure.condition}}]}
        observed = {"tag": "Absent"} if failure.condition == "MissingRequired" else {"tag": "Null"} if failure.condition == "NullNotAllowed" else {"tag": "Present", "value": exact_encode(failure.observed)}
        return {"id": case["id"], "status": "Rejected", "type_ref": plain(failure.type_ref), "origin": plain(failure.origin), "value_path": path(failure.value_path), "condition": failure.condition, "observed": observed, "reference_trace": [plain(item) for item in failure.reference_trace]}


if __name__ == "__main__":
    for line in sys.stdin:
        print(json.dumps(evaluate(json.loads(line)), separators=(",", ":"), ensure_ascii=False))
