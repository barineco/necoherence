#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import fields, is_dataclass
from enum import Enum
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import types

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "packages/python/adapter/src")]

import necoherence.network_effect as ne
import necoherence.semantic_composition as sc
import necoherence.semantic_execution as se
from network_failure import network_failure_json
from necoherence.request_progression import ExecutionHandle, RequestIdentity
from necoherence.signature_values import ABSENT, CertificateMismatchFailure, UnresolvedValueFailure, ValueFailure, exact_encode
from necoherence.type_signatures import ExpectedSignatureBasis, admit_signature_generation, encode_expected_signature_basis

GENERATOR_MANIFEST = ROOT / "generator/rust/Cargo.toml"


def render_source(expected, exchange):
    with tempfile.TemporaryDirectory(prefix="ncoh-python-generated-") as directory:
        expected_path = Path(directory) / "expected.json"
        input_path = Path(directory) / "input.json"
        output_path = Path(directory) / "generated.py"
        expected_path.write_text(json.dumps(expected), encoding="utf-8")
        input_path.write_text(exchange, encoding="utf-8")
        completed = subprocess.run(
            ["cargo", "run", "--quiet", "--locked", "--manifest-path", str(GENERATOR_MANIFEST), "--bin", "necoherence-generate", "--", "--target", "python", "--expected", str(expected_path), "--input", str(input_path), "--output", str(output_path)],
            capture_output=True, text=True, check=False,
        )
        if completed.returncode != 0:
            raise RuntimeError(completed.stderr.strip())
        return output_path.read_text(encoding="utf-8")


def attempt_input(description):
    return ne.AttemptInput(
        ne.AttemptIdentity(RequestIdentity("semantic", description.get("provenance", "comparison"), 1), description.get("ordinal", 0)),
        ne.HttpWireInstruction(description["method"], description["target"], tuple(ne.RawHeaderField(value["name"], bytes(value["value"])) for value in description["headers"]), bytes(description["body"])),
        None, ne.HostConfiguration(1024, 1024),
    )


def raw_value(module, value, type_id):
    if value["tag"] == "absent": return ABSENT
    if value["tag"] == "null": return None
    return module.CODECS[type_id][0](value["value"])


def outcome(module, exchange, signature, description, *, fallback=False):
    candidates = [(name, value) for name, value in module.__dict__.items() if name.startswith(f"Outcome{signature}K")]
    selected = next((value for _, value in candidates if getattr(value, "outcome_id", None) == description["outcome"]), None)
    if selected is None and fallback: selected = candidates[0][1]
    if selected is None: raise ValueError(f"unrepresentable outcome {description['outcome']}")
    declared = exchange["composition"]["problem"]["signatures"][signature]["outcomes"]
    contract = next((value for value in declared if value["id"] == description["outcome"]), declared[0] if fallback else None)
    ports = {value["id"]: value["contract"]["type_id"] for value in contract["value_ports"]}
    supplied = {value["id"]: raw_value(module, value["value"], ports[value["id"]]) for value in description["outputs"] if value["id"] in ports}
    return selected(**{field.name: supplied.get(field.name, False) for field in fields(selected)})


def generated_provider(module, exchange, description):
    signature = description.get("signature", 0)
    if description["effect"] == "pure":
        returned = outcome(module, exchange, signature, description)
        return lambda _: returned
    prepared = description["prepare"][0]
    request = attempt_input(prepared["request"]) if prepared["tag"] == "ready" else None
    def decode(response):
        selected = next(value for value in description["decode"] if value["status"] == response.status)
        if "failure" in selected: return se.ProviderFailure(sc.SiteId(selected["failure"].get("site", "operation")), selected["failure"]["message"])
        return outcome(module, exchange, signature, selected)
    def prepare(_):
        if prepared["tag"] == "ready": return se.ReadyCall(request)
        return se.CompletedCall(outcome(module, exchange, signature, prepared, fallback=True))
    claimed = prepared.get("outcome", "")
    return se.NetworkBinding(se.NetworkTransport(lambda _: request, decode), prepare,
        lambda returned: claimed if claimed and not any(getattr(value, "outcome_id", None) == claimed for name, value in module.__dict__.items() if name.startswith(f"Outcome{signature}K")) else returned.outcome_id)


def request_for(case, index):
    ready = [prepared for provider in case["providers"] for prepared in provider.get("prepare", []) if prepared["tag"] == "ready"]
    return attempt_input(ready[index]["request"])


def observation(case, value):
    request = request_for(case, value.get("request", 0))
    handle = ExecutionHandle(value.get("handle", "handle"))
    if value["tag"] == "start" and value.get("kind") == "started": return se.StartObservation(ne.Started(request.attempt, handle))
    if value["tag"] == "start":
        failure = ne.NetworkHostFailure(request.attempt, ne.HostStage.START, request.configuration, ne.ExecutionStartFailed())
        return se.StartObservation(ne.StartFailed(failure, ne.Unknown(ne.UnknownEffectReason.NO_RESPONSE)))
    response = ne.ResponseObservation(request.attempt, handle, None,
        ne.RawHttpResponse(value["status"], tuple(ne.RawHeaderField(item["name"], bytes(item["value"])) for item in value["headers"]), bytes(value["body"])),
        ne.HeaderProvenance.LIBRARY_NORMALIZED, ne.Unknown(ne.UnknownEffectReason.NO_RESPONSE))
    return se.HostObservation(ne.DeliveredObservation(value.get("delivery", 0), response))


def plain(value):
    if isinstance(value, Mapping): return {name: plain(member) for name, member in value.items()}
    if isinstance(value, (list, tuple)): return [plain(item) for item in value]
    return value


def slot_json(module, value, contract):
    if value is ABSENT: return {"tag": "absent"}
    if value is None and contract["nullable"]: return {"tag": "null"}
    return {"tag": "present", "value": plain(module.CODECS[contract["type_id"]][1](value))}


def failure_json(value):
    tag = value.__class__.__name__
    if isinstance(value, se.InvalidPlan): return {"tag": "invalidPlan", "condition": value.condition}
    if isinstance(value, se.ProviderFailure): return {"tag": "provider", "site": value.site.value, "message": value.message}
    if isinstance(value, se.NetworkTerminalFailure):
        outcome = value.terminal.outcome
        failed = outcome.failure if isinstance(outcome, ne.Failed) else None
        effect = value.terminal.effect
        return {"tag": "networkTerminal", "outcome": outcome.__class__.__name__,
            "stage": failed.stage.value if failed else None, "cause": failed.cause.__class__.__name__ if failed else None,
            "effect": effect.__class__.__name__, "reason": effect.reason.value if isinstance(effect, ne.Unknown) else None}
    if isinstance(value, se.NetworkFailure):
        return {"tag": "network", "detail": network_failure_json(value.failure)}
    if isinstance(value, se.ValueFailure):
        return {"tag": "value", "detail": validation_failure_json(value.failure)}
    return {"tag": tag[0].lower() + tag[1:], "detail": repr(value)}


def source_json(value):
    return {
        "repository": value["repository"], "revision": value["revision"],
        "path": value["path"], "contentDigest": value["content_digest"],
        "documentId": value["document_id"], "declaredRevision": value["declared_revision"],
    }


def type_ref_json(value):
    return {
        "source": source_json(value.source), "definitionName": value.definition_name,
        "pointer": list(value.pointer),
    }


def value_type_ref_json(value):
    return {"source": source_json(value.source), "definition": value.definition_name, "pointer": list(value.pointer)}


def path_json(value):
    return [failure_detail(item) for item in value]


def step_path_json(value):
    result = []
    for step in value:
        if isinstance(step, sc.FieldStep):
            result.append({"field": step.value})
        elif isinstance(step, sc.IndexStep):
            result.append({"index": step.value})
        else:
            result.append({"variant": step.value})
    return result


def semantic_reason_json(value):
    tag = value["tag"]
    arguments = [] if "value" not in value else [value["value"]]
    return {"constructor": tag[:1].lower() + tag[1:], "arguments": arguments}


def semantic_obligation_json(value):
    reference = value["type_ref"]
    return {
        "typeRef": {
            "source": source_json(reference["source"]), "definition": reference["definition_name"],
            "pointer": list(reference["pointer"]),
        },
        "valuePath": step_path_json(value["value_path"]),
        "reason": semantic_reason_json(value["reason"]),
    }


def value_failure_json(value):
    reference = value.type_ref
    type_ref = value_type_ref_json(reference) if isinstance(reference, sc.TypeRef) else {
        "source": source_json(reference["source"]),
        "definition": reference["definition_name"],
        "pointer": list(reference["pointer"]),
    }
    reference_source = reference.source if isinstance(reference, sc.TypeRef) else reference["source"]
    reference_name = reference.definition_name if isinstance(reference, sc.TypeRef) else reference["definition_name"]
    reference_pointer = reference.pointer if isinstance(reference, sc.TypeRef) else reference["pointer"]
    definition = value.definition_ref or {"source": reference_source, "name": reference_name}
    origin = value.origin or {"source": reference_source, "pointer": reference_pointer}
    condition = {"tag": value.condition.tag.value}
    if value.condition.value is not None:
        condition["value"] = value.condition.value
    if isinstance(value.observed, sc.AbsentValue):
        observed = {"tag": "Absent"}
    elif isinstance(value.observed, sc.NullValue):
        observed = {"tag": "Null"}
    else:
        observed = {"tag": "Present", "value": exact_encode(value.observed.value)}
    return {
        "typeRef": type_ref,
        "definitionRef": None if definition is None else {
            "source": source_json(definition["source"]), "name": definition["name"],
        },
        "origin": None if origin is None else {
            "source": source_json(origin["source"]), "pointer": list(origin["pointer"]),
        },
        "valuePath": step_path_json(value.value_path), "condition": condition,
        "observed": observed,
        "referenceTrace": [value_type_ref_json(item) for item in value.reference_trace],
    }


def validation_failure_json(value):
    if isinstance(value, UnresolvedValueFailure):
        return {"constructor": "unresolved", "arguments": [[semantic_obligation_json(item) for item in value.obligations]]}
    if isinstance(value, CertificateMismatchFailure):
        return {"constructor": "certificateMismatch", "arguments": [value.condition]}
    return {"constructor": "value", "arguments": [value_failure_json(value)]}


def argument(value):
    if isinstance(value, sc.TypeRef): return type_ref_json(value)
    if isinstance(value, sc.FunctionRef): return {
        "identity": value.identity, "revision": value.revision, "contentDigest": value.content_digest,
    }
    if isinstance(value, sc.ValueRef): return {
        "producer": failure_detail(value.producer), "path": path_json(value.path),
    }
    if isinstance(value, ValueFailure): return value_failure_json(value)
    if isinstance(value, Mapping): return {name: argument(member) for name, member in value.items()}
    if isinstance(value, (list, tuple)): return [argument(item) for item in value]
    if isinstance(value, Enum): return value.value
    if is_dataclass(value): return failure_detail(value)
    if hasattr(value, "value"): return argument(value.value)
    return value


def failure_detail(value):
    name = value.__class__.__name__
    constructors = {
        "FieldStep": "field", "IndexStep": "index", "VariantStep": "variant",
        "InitialProducer": "initial", "InvocationOutcomeProducer": "invocationOutcome",
    }
    if isinstance(value, sc.UnresolvedProjection):
        return {"constructor": "unresolved", "arguments": [argument(value.obligations)]}
    if isinstance(value, sc.ProjectionCertificateMismatch):
        return {"constructor": "certificateMismatch", "arguments": [value.condition]}
    values = [argument(getattr(value, field.name)) for field in fields(value)] if is_dataclass(value) else []
    return {
        "constructor": constructors.get(name, name[:1].lower() + name[1:]),
        "arguments": values,
    }


def execute(module, case, exchange):
    providers = module.Providers(**{f"call{index}": generated_provider(module, exchange, description) for index, description in enumerate(case["providers"])})
    initial = {value["id"]: value["contract"]["type_id"] for value in exchange["composition"]["problem"]["initial_inputs"]}
    arguments = module.Arguments(**{value["id"]: raw_value(module, value["value"], initial[value["id"]]) for value in case["arguments"]})
    progress = []
    generation = module.initialize()
    if isinstance(generation, module.InitializePreparation):
        return {"case": case["case"], "progress": progress, "failure": {"tag": "preparation", "detail": failure_detail(generation.failure)}}
    if isinstance(generation, module.InitializeAdmission):
        raise generation.failure
    current = module.run(generation, providers, arguments, ne.empty_network_state())
    if isinstance(current, module.StartExecution):
        current = current.failure
    observations = iter(case["observations"])
    while isinstance(current, module.RunPending):
        progress.append({"tag": "pending", "instruction": "send" if isinstance(current.instruction, se.Send) else "observe"})
        current = module.resume(current.execution, observation(case, next(observations)))
    if isinstance(current, se.RunFailure):
        return {"case": case["case"], "progress": progress, "failure": failure_json(current.cause)}
    progress.append({"tag": "completed"})
    result = current.result
    if isinstance(result, module.ResultSuccess):
        goals = exchange["composition"]["problem"]["goal"]["outputs"]
        values = [[goal["id"], slot_json(module, getattr(result, field.name), goal["contract"])] for field, goal in zip(fields(result), goals)]
        terminal = {"tag": "success", "outcome": values}
    else:
        index = int(result.__class__.__name__.removeprefix("ResultFailure"))
        failure = exchange["composition"]["problem"]["goal"]["failures"][index]
        terminal = {"tag": "failure", "embedding": failure["id"], "value": slot_json(module, result.value, failure["contract"])}
    return {"case": case["case"], "progress": progress, "result": terminal}


document = json.loads(Path(sys.argv[1]).read_text())
modules = {}
rows = []
for case in document["cases"]:
    try:
        exchange = json.loads(case["exchange"])
        key = case["exchange"]
        if key not in modules:
            admit_signature_generation(ExpectedSignatureBasis.of_exchange(exchange), key)
            source = render_source(json.loads(encode_expected_signature_basis(ExpectedSignatureBasis.of_exchange(exchange))), key)
            compile(source, "<generated-composition>", "exec")
            module = types.ModuleType(f"generated_{len(modules)}")
            sys.modules[module.__name__] = module
            exec(source, module.__dict__)
            modules[key] = module
        rows.append(execute(modules[key], case, exchange))
    except Exception as failure:
        rows.append({"case": case["case"], "progress": [], "driverFailure": f"{failure.__class__.__name__}: {failure}"})
print(json.dumps(rows, separators=(",", ":")))
