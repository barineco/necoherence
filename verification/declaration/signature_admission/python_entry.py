# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

"""Python execution entry for the shared signature admission comparison.

Stdin is one JSON object with `exchange` (the exchange value as a JSON string) and
`expected_basis`; stdout is one JSON object: `accepted` with the normalized checked value, or
`failed` with the failure in the shared form. With `--batch`, each stdin line is one such
request and each stdout line is the result of the request on the same line; a request that ends
with an exception is written as `{"error": ...}` and the next request is processed.

The entry answers the runtime admission, with `"mode": "admission"` or without `mode`. The generator
boundary is compared through the Rust generator command alone.

The reason strings follow the Lean entry: a wire failure kind is written in lower camel case,
and a JSON syntax failure of the exchange is `exchange_json`.
"""
from __future__ import annotations

import json
import sys

from neco_quotient_certificate import (
    CheckMismatched,
    Condition,
    Matched,
    Mismatched,
    PrerequisiteEstablished,
    PrerequisiteFailed,
    ProjectionCertificateOnly,
    ProjectionDifferent,
    ProjectionMatched,
    ProjectionRecomputedOnly,
    UncheckedByDecode,
    UncheckedBySource,
)
from necoherence.signature_values import JsonFailure, WireFailure
from necoherence.type_signatures import (
    AdmissionFailure,
    decode_expected_signature_basis,
    Composition,
    CompositionInput,
    Certificate,
    EntrypointDuplicate,
    EntrypointsEmpty,
    EntrypointIdentityEmpty,
    ExpectedSignatureBasis,
    Generation,
    Library,
    UnresolvedEntrypoint,
    UnsupportedSchema,
    Wire,
    admit_signature_generation,
)

CONDITIONS = (
    Condition.DECODE,
    Condition.SOURCE,
    Condition.COORDINATE,
    Condition.OBSERVATIONS,
    Condition.DIGEST,
    Condition.RESIDUAL,
)
STATUS_NAMES = {
    Matched: "Matched",
    Mismatched: "Mismatched",
    UncheckedByDecode: "UncheckedByDecode",
    UncheckedBySource: "UncheckedBySource",
}

def _status(mismatch, condition):
    return STATUS_NAMES[type(mismatch.status_at(condition))]


PROJECTION_RESULTS = {
    ProjectionMatched: "matched",
    ProjectionCertificateOnly: "certificateOnly",
    ProjectionRecomputedOnly: "recomputedOnly",
    ProjectionDifferent: "different",
}


def _digests(checks):
    if not isinstance(checks.decode, PrerequisiteEstablished):
        return None
    return {name: PROJECTION_RESULTS[type(result)] for name, result in checks.decode.children.items()}


def _condition_failures(checks):
    failures = []
    if isinstance(checks.decode, PrerequisiteFailed):
        failures.append(checks.decode.failure)
    if isinstance(checks.source, PrerequisiteFailed):
        failures.append(checks.source.failure)
    elif isinstance(checks.source, PrerequisiteEstablished):
        children = checks.source.children
        for result in (children.coordinate, children.observations, children.residual):
            if isinstance(result, CheckMismatched):
                failures.append(result.failure)
    return failures


def _certificate_failure(mismatch):
    checks = mismatch.checks
    return {
        "kind": "certificate",
        "conditions": {condition.value: _status(mismatch, condition) for condition in CONDITIONS},
        "digests": _digests(checks),
        "failures": [
            {"condition": failure.condition.value, "operation": failure.operation}
            for failure in _condition_failures(checks)
        ],
        "origin": {
            "rule_revision": mismatch.origin.rule_revision,
            "source_identity": mismatch.origin.source_identity,
            "source_revision": mismatch.origin.source_revision,
        },
        "provenance": mismatch.provenance,
    }


def _lower_camel(name: str) -> str:
    return name[:1].lower() + name[1:]


def _reject_constant(text: str):
    raise ValueError(text)


def _failure(error: AdmissionFailure):
    cause = error.cause
    if isinstance(error, Certificate):
        return _certificate_failure(cause)
    if isinstance(error, EntrypointsEmpty):
        return {"kind": "entrypoints_empty"}
    if isinstance(error, EntrypointIdentityEmpty):
        return {"kind": "entrypoint_identity_empty"}
    if isinstance(error, EntrypointDuplicate):
        return {"kind": "entrypoint_duplicate", "identity": cause}
    if isinstance(error, UnresolvedEntrypoint):
        identity, definition = cause
        return {"kind": "entrypoint_unresolved", "identity": identity, "definition": definition}
    if isinstance(error, UnsupportedSchema):
        return {"kind": "schema", "actual": cause}
    if isinstance(error, Library):
        return {"kind": "declaration", "reason": cause.predicate.lower()}
    if isinstance(error, Composition):
        return {"kind": "composition", "reason": _lower_camel(type(cause).__name__)}
    if isinstance(error, CompositionInput):
        return {"kind": "composition", "reason": _lower_camel(type(cause).__name__)}
    if isinstance(error, Wire):
        return {"kind": "composition", "reason": _lower_camel(cause.kind)}
    if isinstance(error, Generation):
        if isinstance(cause, JsonFailure):
            return {"kind": "decode", "reason": "exchange_json"}
        return {"kind": "decode", "reason": "exchange." + _lower_camel(cause.kind)}
    raise TypeError(f"unmapped admission failure {error.kind}")


class RequestFailure(Exception):
    def __init__(self, reason):
        self.reason = reason


def _request_failure(reason):
    return {"result": "failed", "failure": {"kind": "request", "reason": reason}}


def _parse_request(line):
    try:
        request = json.loads(line, parse_constant=_reject_constant)
    except ValueError:
        raise RequestFailure("request_json") from None
    if type(request) is not dict:
        raise RequestFailure("request_exchange")
    if type(request.get("exchange")) is not str:
        raise RequestFailure("request_exchange")
    if "expected_basis" not in request:
        raise RequestFailure("request_expected_basis")
    if type(request["expected_basis"]) is not dict:
        raise RequestFailure("expected_basis.syntax")
    try:
        expected = decode_expected_signature_basis(request["expected_basis"])
    except WireFailure as error:
        raise RequestFailure("expected_basis." + _lower_camel(error.kind)) from None
    mode = request.get("mode", "admission")
    if mode != "admission":
        raise RequestFailure("request_mode")
    return request["exchange"], expected


def admit_entry(exchange, expected):
    try:
        checked = admit_signature_generation(expected, exchange)
    except AdmissionFailure as error:
        return {"result": "failed", "failure": _failure(error)}
    value = checked.input
    entrypoints = sorted(
        ({"identity": entry["identity"], "definition": entry["definition"]} for entry in value["entrypoints"]),
        key=lambda entry: entry["identity"],
    )
    composition = None if value["composition"] is None else {"problem_sha256": value["basis"]["problem_sha256"]}
    return {
        "result": "accepted",
        "checked": {
            "basis": value["basis"],
            "library": {"identity": value["signatures"]["identity"], "revision": value["signatures"]["revision"]},
            "entrypoints": entrypoints,
            "composition": composition,
        },
    }


def process_line(line):
    try:
        exchange, expected = _parse_request(line)
    except RequestFailure as failure:
        return _request_failure(failure.reason)
    return admit_entry(exchange, expected)


def render(line):
    return json.dumps(process_line(line), ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def render_guarded(line):
    try:
        return render(line)
    except Exception as error:
        return json.dumps({"error": f"{type(error).__name__}: {error}"}, ensure_ascii=False, sort_keys=True)


def request_lines(text):
    lines = text.split("\n")
    if lines[-1] == "":
        lines.pop()
    return lines


def main(arguments):
    sys.stdout.reconfigure(encoding="utf-8")
    text = sys.stdin.buffer.read().decode("utf-8")
    if arguments == ["--batch"]:
        for line in request_lines(text):
            print(render_guarded(line), flush=True)
    else:
        print(render(text), flush=True)


if __name__ == "__main__":
    main(sys.argv[1:])
