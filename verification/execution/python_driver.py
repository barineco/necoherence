#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "packages/python/adapter/src"))

import necoherence.network_effect as ne
import necoherence.semantic_composition as sc
import necoherence.semantic_execution as se
from network_failure import network_failure_json
from necoherence.request_progression import ExecutionHandle, RequestIdentity
from necoherence.type_signatures import ExpectedSignatureBasis, admit_signature_generation
from necoherence.signature_values import UnresolvedValueFailure, exact_encode


def checked(exchange):
    raw = json.loads(exchange)
    admitted = admit_signature_generation(ExpectedSignatureBasis.of_exchange(raw), exchange).admitted_composition
    return admitted.prepared, admitted


def slot(value):
    return {"absent": sc.ABSENT_VALUE, "null": sc.NULL_VALUE, "present": sc.PresentValue(value.get("value"))}[value["tag"]]


def attempt_input(description):
    return ne.AttemptInput(ne.AttemptIdentity(RequestIdentity("semantic", description.get("provenance", "comparison"), 1), description.get("ordinal", 0)),
        ne.HttpWireInstruction(description["method"], description["target"], tuple(ne.RawHeaderField(value["name"], bytes(value["value"])) for value in description["headers"]), bytes(description["body"])), None,
        ne.HostConfiguration(1024, 1024))


def providers(case, references):
    result = []
    for description in case["providers"]:
        ref = references[description.get("signature", 0)] if description["reference"] == "declared" else sc.FunctionRef("other", "1", "0" * 64)
        if description["effect"] == "pure":
            returned = se.CallResult(sc.OutcomeId(description["outcome"]), tuple((sc.PortId(value["id"]), slot(value["value"])) for value in description["outputs"]))
            implementation = se.PureProvider(lambda _, returned=returned: returned)
        else:
            prepared = description["prepare"][0]
            def prepare(_, prepared=prepared):
                return se.CompletedCall(call_result(prepared)) if prepared["tag"] == "completed" else se.ReadyCall(attempt_input(prepared["request"]))
            def decode(response, description=description):
                decoded = next(value for value in description["decode"] if value["status"] == response.status)
                if "failure" in decoded:
                    return se.ProviderFailure(sc.SiteId("operation"), decoded["failure"]["message"])
                return se.CallResult(sc.OutcomeId(decoded["outcome"]), tuple((sc.PortId(value["id"]), slot(value["value"])) for value in decoded["outputs"]))
            implementation = se.PreparedHttpProvider(se.PreparedNetworkOwner(prepare, decode))
        result.append(se.Provider(ref, implementation))
    return tuple(result)


def slot_json(value):
    if isinstance(value, sc.AbsentValue): return {"tag": "absent"}
    if isinstance(value, sc.NullValue): return {"tag": "null"}
    return {"tag": "present", "value": value.value}


def call_result(description):
    return se.CallResult(sc.OutcomeId(description["outcome"]), tuple((sc.PortId(value["id"]), slot(value["value"])) for value in description["outputs"]))


def function_json(value):
    return {"identity": value.identity, "revision": value.revision, "contentDigest": value.content_digest}


def type_json(value):
    source = value["source"]
    return {"source": {"repository": source["repository"], "revision": source["revision"],
            "path": source["path"], "contentDigest": source["content_digest"],
            "documentId": source["document_id"], "declaredRevision": source.get("declared_revision")},
            "definition": value["definition_name"], "pointer": list(value["pointer"])}


def path_json(value):
    result = []
    for step in value:
        if isinstance(step, sc.FieldStep):
            result.append({"field": step.value})
        elif isinstance(step, sc.IndexStep):
            result.append({"index": step.value})
        else:
            result.append({"variant": step.value})
    return result


def failure_path_json(value):
    return path_json(value)


def producer_json(value):
    if isinstance(value, sc.InitialProducer):
        return {"constructor": "initial", "arguments": [value.id.value]}
    return {"constructor": "invocationOutcome", "arguments": [
        value.site.value, value.outcome.value, value.port.value,
    ]}


def value_ref_json(value):
    return {"producer": producer_json(value.producer), "path": path_json(value.path)}


def lot_json(value):
    if isinstance(value, sc.InitialLotRef):
        return {"constructor": "initial", "arguments": [value.id.value]}
    return {"constructor": "produced", "arguments": [
        value.site.value, value.outcome.value, value.production.value,
    ]}


def semantic_reason_json(value):
    tag = value["tag"]
    arguments = [] if "value" not in value else [value["value"]]
    return {"constructor": tag[:1].lower() + tag[1:], "arguments": arguments}


def semantic_obligation_json(value):
    return {
        "typeRef": type_json(value["type_ref"]),
        "valuePath": path_json(value["value_path"]),
        "reason": semantic_reason_json(value["reason"]),
    }


def validation_failure_json(value):
    if isinstance(value, UnresolvedValueFailure):
        return {"constructor": "unresolved", "arguments": [[semantic_obligation_json(item) for item in value.obligations]]}
    condition = {"tag": value.condition.tag.value}
    if value.condition.value is not None:
        condition["value"] = value.condition.value
    if isinstance(value.observed, sc.AbsentValue):
        observed = {"tag": "Absent"}
    elif isinstance(value.observed, sc.NullValue):
        observed = {"tag": "Null"}
    else:
        observed = {"tag": "Present", "value": exact_encode(value.observed.value)}
    failure = {
        "typeRef": type_json(value.type_ref),
        "definitionRef": {"source": type_json(value.type_ref)["source"], "name": value.definition_ref["name"]},
        "origin": {"source": type_json(value.type_ref)["source"], "pointer": list(value.origin["pointer"])},
        "valuePath": failure_path_json(value.value_path),
        "condition": condition,
        "observed": observed,
        "referenceTrace": [type_json(item) for item in value.reference_trace],
    }
    return {"constructor": "value", "arguments": [failure]}


def failure_json(value):
    tag = value.__class__.__name__
    if isinstance(value, se.MissingArgument): return {"tag": tag, "input": value.id.value}
    if isinstance(value, (se.ArgumentCoverage, se.ProviderCoverage, se.InvalidPlan)): return {"tag": tag, "condition": value.condition}
    if isinstance(value, (se.MissingProvider, se.ProviderEffect)): return {"tag": tag, "function": function_json(value.function)}
    if isinstance(value, se.ProviderFailure): return {"tag": tag, "site": value.site.value, "message": value.message}
    if isinstance(value, se.InvalidOutcome): return {"tag": tag, "site": value.site.value, "outcome": value.outcome.value}
    if isinstance(value, se.ResourceFailure): return {"tag": tag, "lot": lot_json(value.lot), "condition": value.condition}
    if isinstance(value, se.NetworkTerminalFailure):
        terminal = value.terminal
        failed = terminal.outcome if isinstance(terminal.outcome, ne.Failed) else None
        return {"tag": tag, "outcome": terminal.outcome.__class__.__name__,
                "stage": failed.failure.stage.value if failed else None,
                "cause": failed.failure.cause.__class__.__name__ if failed else None,
                "effect": terminal.effect.__class__.__name__,
                "reason": terminal.effect.reason.value if isinstance(terminal.effect, ne.Unknown) else None}
    if isinstance(value, se.ValueFailure): return {"tag": tag, "detail": validation_failure_json(value.failure)}
    if isinstance(value, se.MissingValue): return {"tag": tag, "detail": value_ref_json(value.ref)}
    return {"tag": tag, "detail": network_failure_json(value.failure)}


def request_for(case, index):
    ready = [prepared for provider in case["providers"] for prepared in provider.get("prepare", []) if prepared["tag"] == "ready"]
    return attempt_input(ready[index]["request"] if ready else case["providers"][0]["request"])


def run(case):
    prepared, composition = checked(case["exchange"])
    references = [signature.reference for signature in prepared.input.signatures] or [sc.FunctionRef("unused", "0", "0" * 64)]
    arguments = tuple((sc.InputId(value["id"]), slot(value["value"])) for value in case["arguments"])
    current = se.start(composition, providers(case, references), arguments, ne.empty_network_state())
    progress = []
    observations = iter(case["observations"])
    while isinstance(current, se.Pending):
        progress.append({"tag": "pending", "instruction": "send" if isinstance(current.instruction, se.Send) else "observe"})
        observation = next(observations)
        request = request_for(case, observation.get("request", 0))
        handle = ExecutionHandle(observation.get("handle", "handle"))
        if observation["tag"] == "start" and observation["kind"] == "started":
            supplied = se.StartObservation(ne.Started(request.attempt, handle))
        elif observation["tag"] == "start":
            failure = ne.NetworkHostFailure(request.attempt, ne.HostStage.START, request.configuration, ne.ExecutionStartFailed())
            supplied = se.StartObservation(ne.StartFailed(failure, ne.Unknown(ne.UnknownEffectReason.NO_RESPONSE)))
        else:
            response = ne.ResponseObservation(request.attempt, handle, None, ne.RawHttpResponse(observation["status"], tuple(ne.RawHeaderField(value["name"], bytes(value["value"])) for value in observation["headers"]), bytes(observation["body"])), ne.HeaderProvenance.LIBRARY_NORMALIZED, ne.Unknown(ne.UnknownEffectReason.NO_RESPONSE))
            supplied = se.HostObservation(ne.DeliveredObservation(observation.get("delivery", 0), response))
        current = se.resume(current.execution, supplied)
    if isinstance(current, se.RunFailure):
        return {"case": case["case"], "progress": progress, "failure": failure_json(current.cause)}
    progress.append({"tag": "completed"})
    if isinstance(current.result, se.Success):
        result = {"tag": "success", "outcome": [[item.value, slot_json(value)] for item, value in current.result.outputs]}
    else:
        result = {"tag": "failure", "embedding": current.result.embedding.value, "value": slot_json(current.result.value)}
    return {"case": case["case"], "progress": progress, "result": result}


document = json.loads(Path(sys.argv[1]).read_text())
rows = []
for case in document["cases"]:
    try:
        rows.append(run(case))
    except Exception as failure:
        rows.append({
            "case": case["case"],
            "progress": [],
            "driverFailure": f"{failure.__class__.__name__}: {failure}",
        })
print(json.dumps(rows, separators=(",", ":")))
