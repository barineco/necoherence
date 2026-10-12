# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Invocation-time finite domains for the network-effect comparison.

Stateful domains receive authoritative states and tokens from the Lean runner,
then derive one-field forgeries and transition inputs without stored outputs.
"""

from __future__ import annotations

from copy import deepcopy
from itertools import permutations, product
from typing import Any, Iterable, Iterator, Sequence

METHODS = ("", "GET", "POST", "PATCH", "é", "GET\n")
TARGETS = (
    "http://127.0.0.1/",
    "https://example.test/%C3%A9",
    "/relative",
    "http:///missing-authority",
    "ftp://example.test/resource",
    "http://[::1]/?q=a%20b",
    "http://example.test/\ncontrol",
)
_PERMUTED_HEADERS = (
    ("x-a", (1,)),
    ("X-A", (2,)),
    ("x-empty", ()),
)
HEADER_SEQUENCES = (
    (),
    *(tuple(order) for order in permutations(_PERMUTED_HEADERS)),
    (("x-binary", (0, 127, 128, 255)),),
    (("é", tuple("é".encode("utf-8"))),),
    (("\ud800", (1,)),),
    (
        ("x-a", (1,)),
        ("x-a", (2,)),
        ("x-b", (3,)),
        ("x-c", (4,)),
    ),
)
BODY_BYTES = (
    (),
    (0,),
    (127,),
    (128,),
    (255,),
    (0, 255),
    tuple(range(7)),
    tuple(range(8)),
)
RESPONSE_STATUSES = (200, 201, 204, 301, 404, 409, 429, 500, 503)
HOST_STAGES = ("Start", "RequestWrite", "ResponseHeaders", "ResponseBody", "Cancel", "Deadline")
TIMEOUT_CAUSES = ("LibraryReported", "SocketReported", "PoolAcquisition", "HostOperation")
OPERATIONS = (
    "readNetworkState",
    "prepare",
    "sendCommand",
    "cancelCommand",
    "observeStart",
    "observe",
    "annotateEffect",
    "retry",
)
LEDGER_VARIANTS = (
    "empty",
    "valid-root",
    "duplicate-key",
    "non-root-first",
    "ordinal-gap",
    "lineage-mismatch",
    "authorization-reuse",
    "disposition-mismatch",
    "delivery-mismatch",
)
LIMIT_RELATIONS = ("below", "equal", "above")


def finite_domains() -> dict[str, tuple[Any, ...]]:
    """Return every named finite value domain."""
    return {
        "method": METHODS,
        "target": TARGETS,
        "headers": HEADER_SEQUENCES,
        "body": BODY_BYTES,
        "responseStatus": RESPONSE_STATUSES,
        "responseHeaders": HEADER_SEQUENCES,
        "responseBody": BODY_BYTES,
        "ledger": LEDGER_VARIANTS,
        "operation": OPERATIONS,
        "hostStage": HOST_STAGES,
        "timeoutCause": TIMEOUT_CAUSES,
        "sourceDeliveryRelation": ("same-order", "reverse-order"),
        "clockBasis": ("matching", "mismatching"),
        "clockValue": ("before", "equal", "above"),
        "effect": ("NoEffect", "EffectOccurred", "Unknown", "conflicting-witness"),
        "retry": (
            "allowed",
            "denied",
            "settled-parent",
            "unsettled-parent",
            "maximum-parent",
            "old-parent",
            "logical-mismatch",
            "ordinal-gap",
            "authorization-reuse",
            "prepared-before-send",
        ),
        "requestLimitRelation": LIMIT_RELATIONS,
        "responseLimitRelation": LIMIT_RELATIONS,
    }


def _pairwise_rows(
    dimensions: Sequence[tuple[str, Sequence[Any]]],
) -> tuple[dict[str, Any], ...]:
    ordered = sorted(
        enumerate(dimensions),
        key=lambda item: (-len(item[1][1]), item[0]),
    )
    names = [dimension[0] for _, dimension in ordered]
    values = [tuple(dimension[1]) for _, dimension in ordered]
    if not names:
        return ()
    if len(names) == 1:
        return tuple({names[0]: value} for value in values[0])
    rows = [
        {names[0]: left, names[1]: right}
        for left, right in product(values[0], values[1])
    ]
    for index in range(2, len(names)):
        fresh_name = names[index]
        fresh_values = values[index]
        previous = tuple(zip(names[:index], values[:index]))
        uncovered = {
            (previous_name, previous_value, fresh_name, fresh_value)
            for previous_name, previous_values in previous
            for previous_value, fresh_value in product(previous_values, fresh_values)
        }
        for row in rows:
            selected = max(
                fresh_values,
                key=lambda fresh_value: (
                    sum(
                        (
                            previous_name,
                            row[previous_name],
                            fresh_name,
                            fresh_value,
                        )
                        in uncovered
                        for previous_name, _ in previous
                    ),
                    -fresh_values.index(fresh_value),
                ),
            )
            row[fresh_name] = selected
            for previous_name, _ in previous:
                uncovered.discard(
                    (
                        previous_name,
                        row[previous_name],
                        fresh_name,
                        selected,
                    )
                )
        while uncovered:
            previous_name, previous_value, _, fresh_value = min(
                uncovered,
                key=repr,
            )
            row = {
                previous_name: previous_value,
                fresh_name: fresh_value,
            }
            for candidate_name, candidate_values in previous:
                if candidate_name in row:
                    continue
                selected = next(
                    (
                        candidate
                        for candidate in candidate_values
                        if (
                            candidate_name,
                            candidate,
                            fresh_name,
                            fresh_value,
                        )
                        in uncovered
                    ),
                    candidate_values[0],
                )
                row[candidate_name] = selected
            rows.append(row)
            for candidate_name, _ in previous:
                uncovered.discard(
                    (
                        candidate_name,
                        row[candidate_name],
                        fresh_name,
                        fresh_value,
                    )
                )
    original_names = tuple(name for name, _ in dimensions)
    return tuple(
        {name: row[name] for name in original_names}
        for row in rows
    )


def pairwise_coverage() -> dict[str, dict[str, int]]:
    dimensions = _model_dimensions()
    rows = _pairwise_rows(dimensions)
    result: dict[str, dict[str, int]] = {}
    for left_index, (left_name, left_values) in enumerate(dimensions):
        for right_name, right_values in dimensions[left_index + 1 :]:
            observed = {
                (row[left_name], row[right_name])
                for row in rows
            }
            result[f"{left_name}×{right_name}"] = {
                "covered": len(observed),
                "required": len(left_values) * len(right_values),
            }
    return result


def _wire(method: str, target: str, headers: tuple, body: tuple) -> dict[str, Any]:
    return {
        "method": method,
        "target": target,
        "headers": [{"name": name, "value": list(value)} for name, value in headers],
        "body": list(body),
    }


def _identity(revision: int = 0) -> dict[str, Any]:
    return {"kind": "generated", "provenance": "runtime", "revision": revision}


def _attempt(ordinal: int = 0, *, revision: int = 0) -> dict[str, Any]:
    return {"logical": _identity(revision), "ordinal": ordinal}


def _configuration() -> dict[str, Any]:
    return {
        "requestBodyLimit": 256,
        "responseBodyLimit": 256,
        "cancellation": {"identity": {"value": "generated-cancel"}},
        "monotonicClock": {"identity": {"value": "generated-clock"}, "clockBasis": {"value": "generated"}},
    }


def _input(method: str, target: str, headers: tuple, body: tuple, ordinal: int = 0) -> dict[str, Any]:
    return {"attempt": _attempt(ordinal), "instruction": _wire(method, target, headers, body), "deadline": None, "configuration": _configuration()}


def _prepared(value: dict[str, Any]) -> dict[str, Any]:
    return {"input": value, "lineage": {"tag": "Root"}}


def _named_state_variants(value: dict[str, Any]) -> dict[str, dict[str, Any]]:
    record = {"input": value, "lineage": {"tag": "Root"}, "disposition": {"tag": "Prepared"}, "firstDelivery": None, "late": []}
    non_root = {**record, "input": {**value, "attempt": _attempt(1)}}
    ordinal_gap = {**record, "input": {**value, "attempt": _attempt(2)}}
    authorization = {
        "logical": _identity(),
        "from": _attempt(),
        "next": _attempt(1),
        "protocolEvidence": {"value": "reused"},
    }
    lineage_mismatch = {**record, "lineage": {"tag": "RetryOf", "authorization": deepcopy(authorization)}}
    retry_one_input = deepcopy(value)
    retry_one_input["attempt"] = _attempt(1)
    retry_two_input = deepcopy(value)
    retry_two_input["attempt"] = _attempt(2)
    retry_one = {
        **record,
        "input": retry_one_input,
        "lineage": {"tag": "RetryOf", "authorization": deepcopy(authorization)},
    }
    retry_two = {
        **record,
        "input": retry_two_input,
        "lineage": {"tag": "RetryOf", "authorization": deepcopy(authorization)},
    }
    disposition_mismatch = {**record, "disposition": {"tag": "Started", "handle": {"value": "unrecorded"}}}
    delivery_mismatch = {**record, "firstDelivery": {"delivery": 2, "observation": {"tag": "ResponseObservation", "attempt": value["attempt"], "handle": {"value": "unrecorded"}, "sourceSequence": None, "response": {"status": 200, "headers": [], "body": []}, "provenance": {"tag": "WireObserved"}, "effect": {"tag": "Unknown", "reason": {"tag": "NoResponse"}}}}}
    return {
        "empty": {"attempts": []},
        "valid-root": {"attempts": [record]},
        "duplicate-key": {"attempts": [record, record]},
        "non-root-first": {"attempts": [non_root]},
        "ordinal-gap": {"attempts": [record, ordinal_gap]},
        "lineage-mismatch": {"attempts": [lineage_mismatch]},
        "authorization-reuse": {"attempts": [record, retry_one, retry_two]},
        "disposition-mismatch": {"attempts": [disposition_mismatch]},
        "delivery-mismatch": {"attempts": [delivery_mismatch]},
    }


def _state_variants(value: dict[str, Any]) -> tuple[dict[str, Any], ...]:
    return tuple(_named_state_variants(value).values())


def _operation_arguments(operation: str, value: dict[str, Any]) -> dict[str, Any]:
    prepared = _prepared(value)
    started = {"prepared": prepared, "handle": {"value": "generated-handle"}}
    identity = value["attempt"]
    status = {"tag": "Unknown", "reason": {"tag": "NoResponse"}}
    if operation == "prepare":
        return {"input": value}
    if operation == "sendCommand":
        return {"prepared": prepared}
    if operation == "cancelCommand":
        return {"started": started}
    if operation == "observeStart":
        return {"prepared": prepared, "observation": {"tag": "Started", "attempt": identity, "handle": started["handle"]}}
    if operation == "observe":
        return {"observation": {"tag": "Pending", "attempt": identity, "handle": started["handle"]}}
    if operation == "annotateEffect":
        return {"effect": {"attempt": identity, "status": status}}
    if operation == "retry":
        authorization = {"logical": identity["logical"], "from": identity, "next": _attempt(1), "protocolEvidence": {"value": "generated"}}
        return {"request": {"permission": {"tag": "RetryAllowed", "authorization": authorization}, "instruction": value["instruction"], "deadline": None, "configuration": value["configuration"]}}
    return {}


def _model_dimensions() -> tuple[tuple[str, Sequence[Any]], ...]:
    return (
        ("operation", OPERATIONS),
        ("method", METHODS),
        ("target", TARGETS),
        ("headers", HEADER_SEQUENCES),
        ("body", BODY_BYTES),
        ("ledger", LEDGER_VARIANTS),
        ("requestLimitRelation", LIMIT_RELATIONS),
        ("responseLimitRelation", LIMIT_RELATIONS),
    )


def _related_limit(length: int, relation: str) -> int:
    if relation == "below":
        return max(0, length - 1)
    if relation == "equal":
        return length
    return length + 1


def generate_model_cases(
    limit: int | None = None,
) -> Iterator[tuple[tuple[str, ...], dict[str, Any]]]:
    for count, row in enumerate(_pairwise_rows(_model_dimensions()), start=1):
        input_value = _input(
            row["method"],
            row["target"],
            row["headers"],
            row["body"],
        )
        input_value["configuration"]["requestBodyLimit"] = _related_limit(
            len(row["body"]),
            row["requestLimitRelation"],
        )
        input_value["configuration"]["responseBodyLimit"] = _related_limit(
            len(row["body"]),
            row["responseLimitRelation"],
        )
        invocation = {
            "operation": row["operation"],
            "state": _named_state_variants(input_value)[row["ledger"]],
        }
        invocation.update(_operation_arguments(row["operation"], input_value))
        yield (
            (
                "pairwise-model",
                f"operation:{row['operation']}",
                f"ledger:{row['ledger']}",
                f"request-limit:{row['requestLimitRelation']}",
                f"response-limit:{row['responseLimitRelation']}",
            ),
            invocation,
        )
        if limit is not None and count >= limit:
            return


def generate_model_invocations(limit: int | None = None) -> Iterator[dict[str, Any]]:
    for _, invocation in generate_model_cases(limit):
        yield invocation


def generate_invocations(*, full: bool = False, limit: int | None = None) -> Iterable[dict[str, Any]]:
    """Generate canonical or pairwise-covered model-domain invocations."""
    if full:
        return generate_model_invocations(limit)
    return ({"operation": "readNetworkState", "state": {"attempts": []}},)


def stateful_seed_invocation() -> dict[str, Any]:
    clock = {"identity": {"value": "generated-clock"}, "clockBasis": {"value": "generated"}}
    value = _input("GET", "http://127.0.0.1/", (), ())
    value["deadline"] = {
        "clockBasis": {"value": "generated"},
        "limit": 10,
        "capability": deepcopy(clock),
    }
    value["configuration"]["monotonicClock"] = clock
    return {"operation": "prepare", "state": {"attempts": []}, "input": value}


def _mutated(value: dict[str, Any], path: tuple[str, ...], replacement: Any) -> dict[str, Any]:
    changed = deepcopy(value)
    target = changed
    for part in path[:-1]:
        target = target[part]
    target[path[-1]] = deepcopy(replacement)
    return changed


def _forged_lineage(prepared: dict[str, Any]) -> dict[str, Any]:
    attempt = prepared["input"]["attempt"]
    return {
        "tag": "RetryOf",
        "authorization": {
            "logical": deepcopy(attempt["logical"]),
            "from": deepcopy(attempt),
            "next": {**deepcopy(attempt), "ordinal": attempt["ordinal"] + 1},
            "protocolEvidence": {"value": "forged-lineage"},
        },
    }


def generate_field_mutations(kind: str, value: dict[str, Any]) -> Iterator[dict[str, Any]]:
    """Yield semantic one-field forgeries of an authoritative Lean value."""
    if kind not in ("prepared", "started"):
        raise ValueError(f"unknown token kind: {kind}")
    prepared_prefix = ("prepared",) if kind == "started" else ()
    prepared = value["prepared"] if kind == "started" else value
    mutations: list[tuple[str, tuple[str, ...], Any]] = [
        ("identity", prepared_prefix + ("input", "attempt", "logical", "revision"), 1),
        ("instruction.method", prepared_prefix + ("input", "instruction", "method"), "POST"),
        ("instruction.target", prepared_prefix + ("input", "instruction", "target"), "https://example.test/forged"),
        ("instruction.headers", prepared_prefix + ("input", "instruction", "headers"), [{"name": "x-forged", "value": [1]}]),
        ("instruction.body", prepared_prefix + ("input", "instruction", "body"), [1]),
        ("deadline", prepared_prefix + ("input", "deadline", "limit"), 11),
        ("configuration.requestBodyLimit", prepared_prefix + ("input", "configuration", "requestBodyLimit"), 257),
        ("configuration.responseBodyLimit", prepared_prefix + ("input", "configuration", "responseBodyLimit"), 257),
        ("configuration.cancellation", prepared_prefix + ("input", "configuration", "cancellation", "identity", "value"), "forged-cancel"),
        ("configuration.monotonicClock", prepared_prefix + ("input", "configuration", "monotonicClock", "identity", "value"), "forged-clock"),
        ("lineage", prepared_prefix + ("lineage",), _forged_lineage(prepared)),
    ]
    if kind == "started":
        mutations.append(("handle", ("handle", "value"), "forged-handle"))
    for field, path, replacement in mutations:
        yield {"field": field, "value": _mutated(value, path, replacement)}


def _effect(attempt: dict[str, Any], tag: str = "Unknown", reason: str = "NoResponse") -> dict[str, Any]:
    if tag == "Unknown":
        return {"tag": tag, "reason": {"tag": reason}}
    return {
        "tag": tag,
        "witness": {
            "attempt": deepcopy(attempt),
            "source": {"tag": "Adapter"},
            "evidence": {"value": f"generated-{tag}"},
        },
    }


def _adapter_observation(
    kind: str,
    prepared: dict[str, Any],
    handle: dict[str, Any],
    source_sequence: int | None,
) -> dict[str, Any]:
    input_value = prepared["input"]
    attempt = input_value["attempt"]
    common = {
        "attempt": deepcopy(attempt),
        "handle": deepcopy(handle),
        "sourceSequence": source_sequence,
    }
    if kind == "response":
        return {
            "tag": "ResponseObservation",
            **common,
            "response": {"status": 200, "headers": [], "body": []},
            "provenance": {"tag": "WireObserved"},
            "effect": _effect(attempt),
        }
    if kind == "cancel":
        return {
            "tag": "CancellationObservation",
            **common,
            "effect": _effect(attempt, reason="Cancellation"),
        }
    if kind == "deadline":
        return {
            "tag": "DeadlineObservation",
            **common,
            "deadline": deepcopy(input_value["deadline"]),
            "observedAt": {"clockBasis": deepcopy(input_value["deadline"]["clockBasis"]), "value": 10},
            "effect": _effect(attempt, reason="Deadline"),
        }
    if kind == "failure":
        return {
            "tag": "FailureObservation",
            **common,
            "failure": {
                "attempt": deepcopy(attempt),
                "stage": {"tag": "ResponseBody"},
                "configuration": deepcopy(input_value["configuration"]),
                "cause": {"tag": "HostRuntimeFailure"},
            },
            "effect": _effect(attempt, reason="HostFailure"),
        }
    raise ValueError(f"unknown observation kind: {kind}")


def generate_race_observations(
    prepared: dict[str, Any],
    handle: dict[str, Any],
    order: tuple[str, ...],
    source_sequences: Sequence[int] | None = None,
) -> Iterator[dict[str, Any]]:
    sources = (
        tuple(range(len(order)))
        if source_sequences is None
        else tuple(source_sequences)
    )
    if len(sources) != len(order):
        raise ValueError("source sequence count must equal delivery count")
    for delivery, (kind, source_sequence) in enumerate(zip(order, sources)):
        yield {
            "tag": "Delivered",
            "delivery": delivery,
            "observation": _adapter_observation(
                kind,
                prepared,
                handle,
                source_sequence,
            ),
        }

def generate_timeout_observations(
    prepared: dict[str, Any],
    handle: dict[str, Any],
) -> Iterator[tuple[dict[str, str], dict[str, Any]]]:
    for pair in generate_timeout_pairs():
        observation = _adapter_observation("failure", prepared, handle, None)
        observation["failure"]["stage"] = {"tag": pair["stage"]}
        observation["failure"]["cause"] = {
            "tag": "Timeout",
            "stage": {"tag": pair["stage"]},
            "cause": {"tag": pair["cause"]},
        }
        yield pair, {
            "tag": "Delivered",
            "delivery": 0,
            "observation": observation,
        }



def generate_observation_mutations(
    prepared: dict[str, Any],
    handle: dict[str, Any],
) -> Iterator[dict[str, Any]]:
    response = {
        "tag": "Delivered",
        "delivery": 0,
        "observation": _adapter_observation("response", prepared, handle, None),
    }
    witnessed_response = deepcopy(response)
    witnessed_response["observation"]["effect"] = _effect(
        prepared["input"]["attempt"],
        "NoEffect",
    )
    failure = {
        "tag": "Delivered",
        "delivery": 0,
        "observation": _adapter_observation("failure", prepared, handle, None),
    }
    timeout = deepcopy(failure)
    timeout["observation"]["failure"]["cause"] = {
        "tag": "Timeout",
        "stage": {"tag": "ResponseBody"},
        "cause": {"tag": "LibraryReported"},
    }
    deadline = {
        "tag": "Delivered",
        "delivery": 0,
        "observation": _adapter_observation("deadline", prepared, handle, None),
    }
    mutations = (
        ("identity", response, ("observation", "attempt", "logical", "revision"), 1),
        ("handle", response, ("observation", "handle", "value"), "forged-handle"),
        ("failure.attempt", failure, ("observation", "failure", "attempt", "logical", "revision"), 1),
        ("failure.stage", failure, ("observation", "failure", "stage", "tag"), "ResponseHeaders"),
        ("timeout.outerStage", timeout, ("observation", "failure", "stage", "tag"), "ResponseHeaders"),
        ("timeout.innerStage", timeout, ("observation", "failure", "cause", "stage", "tag"), "ResponseHeaders"),
        ("deadline", deadline, ("observation", "deadline", "limit"), 11),
        ("clock.basis", deadline, ("observation", "observedAt", "clockBasis", "value"), "other"),
        ("clock.value", deadline, ("observation", "observedAt", "value"), 9),
        ("effect.witness", witnessed_response, ("observation", "effect", "witness", "evidence", "value"), "forged-effect"),
        ("configuration.requestBodyLimit", failure, ("observation", "failure", "configuration", "requestBodyLimit"), 257),
        ("configuration.responseBodyLimit", failure, ("observation", "failure", "configuration", "responseBodyLimit"), 257),
        ("configuration.cancellation", failure, ("observation", "failure", "configuration", "cancellation", "identity", "value"), "forged-cancel"),
        ("configuration.monotonicClock", failure, ("observation", "failure", "configuration", "monotonicClock", "identity", "value"), "forged-clock"),
    )
    for field, observation, path, replacement in mutations:
        yield {"field": field, "value": _mutated(observation, path, replacement)}


def conflicting_delivery(observation: dict[str, Any]) -> dict[str, Any]:
    return _mutated(observation, ("observation", "response", "body"), [1])


def retry_request(prepared: dict[str, Any], *, allowed: bool) -> dict[str, Any]:
    attempt = prepared["input"]["attempt"]
    if allowed:
        permission = {
            "tag": "RetryAllowed",
            "authorization": {
                "logical": deepcopy(attempt["logical"]),
                "from": deepcopy(attempt),
                "next": {**deepcopy(attempt), "ordinal": attempt["ordinal"] + 1},
                "protocolEvidence": {"value": "generated-retry"},
            },
        }
    else:
        permission = {
            "tag": "RetryDenied",
            "logical": deepcopy(attempt["logical"]),
            "parent": deepcopy(attempt),
            "evidence": {"value": "generated-denial"},
        }
    return {
        "permission": permission,
        "instruction": deepcopy(prepared["input"]["instruction"]),
        "deadline": deepcopy(prepared["input"]["deadline"]),
        "configuration": deepcopy(prepared["input"]["configuration"]),
    }


def effect_observation(attempt: dict[str, Any], tag: str) -> dict[str, Any]:
    return {"attempt": deepcopy(attempt), "status": _effect(attempt, tag)}


def generate_clock_invocations() -> Iterator[dict[str, Any]]:
    for basis_relation, value_relation in product(
        ("matching", "mismatching"),
        ("before", "equal", "above"),
    ):
        value = _input("GET", "http://127.0.0.1/", (), ())
        capability = {
            "identity": {"value": "generated-clock"},
            "clockBasis": {"value": "generated"},
        }
        value["deadline"] = {
            "clockBasis": {"value": "generated"},
            "limit": {"before": 9, "equal": 10, "above": 11}[value_relation],
            "capability": deepcopy(capability),
        }
        value["configuration"]["monotonicClock"] = (
            deepcopy(capability)
            if basis_relation == "matching"
            else {
                "identity": {"value": "other-clock"},
                "clockBasis": {"value": "other"},
            }
        )
        yield {"operation": "prepare", "state": {"attempts": []}, "input": value}


def _started_observation_state(
    value: dict[str, Any],
    handle: dict[str, Any],
) -> dict[str, Any]:
    return {
        "attempts": [
            {
                "input": value,
                "lineage": {"tag": "Root"},
                "disposition": {"tag": "Started", "handle": handle},
                "firstDelivery": None,
                "late": [],
            }
        ]
    }


def _response_dimensions() -> tuple[tuple[str, Sequence[Any]], ...]:
    return (
        ("status", RESPONSE_STATUSES),
        ("headers", HEADER_SEQUENCES),
        ("body", BODY_BYTES),
        ("responseLimitRelation", LIMIT_RELATIONS),
    )


def response_pairwise_coverage() -> dict[str, dict[str, int]]:
    dimensions = _response_dimensions()
    rows = _pairwise_rows(dimensions)
    result: dict[str, dict[str, int]] = {}
    for left_index, (left_name, left_values) in enumerate(dimensions):
        for right_name, right_values in dimensions[left_index + 1 :]:
            result[f"{left_name}×{right_name}"] = {
                "covered": len(
                    {
                        (row[left_name], row[right_name])
                        for row in rows
                    }
                ),
                "required": len(left_values) * len(right_values),
            }
    return result


def generate_response_cases(
) -> Iterator[tuple[tuple[str, ...], dict[str, Any]]]:
    for row in _pairwise_rows(_response_dimensions()):
        value = _input("GET", "http://127.0.0.1/", (), ())
        value["configuration"]["responseBodyLimit"] = _related_limit(
            len(row["body"]),
            row["responseLimitRelation"],
        )
        handle = {"value": "generated-response-handle"}
        response = {
            "tag": "ResponseObservation",
            "attempt": value["attempt"],
            "handle": handle,
            "sourceSequence": 9,
            "response": {
                "status": row["status"],
                "headers": [
                    {"name": name, "value": list(field_value)}
                    for name, field_value in row["headers"]
                ],
                "body": list(row["body"]),
            },
            "provenance": {"tag": "WireObserved"},
            "effect": _effect(value["attempt"]),
        }
        yield (
            (
                "response-pairwise",
                f"response-status:{row['status']}",
                f"response-limit:{row['responseLimitRelation']}",
            ),
            {
                "operation": "observe",
                "state": _started_observation_state(value, handle),
                "observation": {
                    "tag": "Delivered",
                    "delivery": 0,
                    "observation": response,
                },
            },
        )


def generate_observation_invocations() -> Iterator[dict[str, Any]]:
    value = _input("GET", "http://127.0.0.1/", (("x-a", (1,)), ("x-a", (2,))), (0, 255))
    attempt = value["attempt"]
    handle = {"value": "generated-handle"}
    state = _started_observation_state(value, handle)
    response = {"tag": "ResponseObservation", "attempt": attempt, "handle": handle, "sourceSequence": None, "response": {"status": 200, "headers": [{"name": "x-a", "value": [1]}, {"name": "x-a", "value": [2]}], "body": [0, 255]}, "provenance": {"tag": "WireObserved"}, "effect": {"tag": "Unknown", "reason": {"tag": "NoResponse"}}}
    base = {"operation": "observe", "state": state}
    yield {**base, "observation": {"tag": "Delivered", "delivery": 0, "observation": response}}
    for source in (0, 1):
        yield {**base, "observation": {"tag": "Delivered", "delivery": 0, "observation": {**response, "sourceSequence": source}}}
    yield {**base, "observation": {"tag": "Delivered", "delivery": 1, "observation": response}}
    yield {**base, "observation": {"tag": "Delivered", "delivery": 0, "observation": {**response, "response": {**response["response"], "body": [255, 0]}}}}
    yield {**base, "observation": {"tag": "Delivered", "delivery": 0, "observation": {**response, "handle": {"value": "malformed"}}}}


def generate_malformed_invocations() -> Iterator[dict[str, Any]]:
    yield {"operation": "unknown", "state": {"attempts": []}}
    yield {"operation": "readNetworkState"}
    yield {"operation": "observe", "state": {"attempts": []}, "observation": {"tag": "Pending", "attempt": _attempt(), "handle": {"value": "h"}}}


def generate_timeout_pairs() -> Iterator[dict[str, str]]:
    for stage, cause in product(HOST_STAGES, TIMEOUT_CAUSES):
        yield {"stage": stage, "cause": cause}


def generate_race_orders() -> Iterator[tuple[str, ...]]:
    """Yield each terminal kind as a delivery winner."""
    yield from (
        ("response", "cancel", "deadline", "failure"),
        ("cancel", "response", "deadline", "failure"),
        ("deadline", "failure", "response", "cancel"),
        ("failure", "deadline", "cancel", "response"),
    )


def generate_race_cases() -> Iterator[dict[str, Any]]:
    for order in generate_race_orders():
        aligned = tuple(range(len(order)))
        yield {
            "order": order,
            "sourceSequences": aligned,
            "relation": "same-order",
        }
        yield {
            "order": order,
            "sourceSequences": tuple(reversed(aligned)),
            "relation": "reverse-order",
        }


__all__ = [
    "BODY_BYTES",
    "HEADER_SEQUENCES",
    "HOST_STAGES",
    "METHODS",
    "OPERATIONS",
    "RESPONSE_STATUSES",
    "TARGETS",
    "TIMEOUT_CAUSES",
    "conflicting_delivery",
    "effect_observation",
    "finite_domains",
    "generate_clock_invocations",
    "generate_field_mutations",
    "generate_invocations",
    "generate_malformed_invocations",
    "generate_model_cases",
    "generate_observation_invocations",
    "generate_observation_mutations",
    "generate_race_cases",
    "generate_race_observations",
    "generate_race_orders",
    "generate_response_cases",
    "generate_timeout_observations",
    "generate_timeout_pairs",
    "pairwise_coverage",
    "response_pairwise_coverage",
    "retry_request",
    "stateful_seed_invocation",
]
