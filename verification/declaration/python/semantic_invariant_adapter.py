# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

"""JSONL adapter for the shared declaration comparison."""
from __future__ import annotations

import json
import sys
from collections.abc import Mapping
from functools import lru_cache
from pathlib import Path

import neco_quotient_certificate as nqc

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "packages" / "python" / "adapter" / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from necoherence.signature_values import MeaningFailure, ValueContext, ValueFailure, WireFailure, UnresolvedValueFailure
from necoherence.signature_values import FieldStep, IndexStep, RawJsonNumber, VariantStep, decode_wire_json, exact_decode, exact_encode, exact_from_json, path_step_json, path_steps_json
from necoherence.signature_support import classify_unresolved_obligations, unresolved_atoms_with
from necoherence.signature_values import declared_type_ref, classify_semantic_obligations, semantic_obligations_with
from necoherence.type_signatures import AdmissionFailure, DeclarationFailure, ExpectedSignatureBasis, admit_signature_generation, checkLibrary, checkProfile, decode_generation, encode_generation, signature_basis
from necoherence.semantic_residual_record import encode_semantic_residual
from semantic_wire import check_classification_input


def _outcome_parts(evaluation):
    match evaluation:
        case nqc.Resolved(judgment):
            return "Resolved", judgment, ()
        case nqc.Residual(judgment, residuals):
            return "Residual", judgment, residuals.values
        case nqc.Stopped(judgment, residuals, _):
            return "Stopped", judgment, residuals.values
    return "Failed", evaluation, evaluation.residuals.values


def _record(evaluation, reasons_with):
    status, judgment, residuals = _outcome_parts(evaluation)
    return {
        "status": status,
        "obligations": judgment.obligations,
        "residuals": residuals,
        "stops": reasons_with(judgment.obligations, "Stopped"),
        "failures": reasons_with(judgment.obligations, "Failed"),
        "provenance": judgment.provenance,
    }


def composition_record(obligations, provenance):
    return _record(classify_unresolved_obligations(obligations, provenance), unresolved_atoms_with)


def semantic_record(obligations, provenance):
    return _record(classify_semantic_obligations(obligations, provenance), semantic_obligations_with)


def _thaw_json(value):
    if isinstance(value, Mapping):
        return {key: _thaw_json(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_thaw_json(item) for item in value]
    return value


def admitted_generation(library):
    entries = [{"identity": row["id"], "definition": row["id"]} for row in library["definitions"][:1]]
    basis = signature_basis(library, entries)
    value = {"schema":"ncoh-checked-generation@5","basis":basis,"signatures":library,"composition":None,"entrypoints":entries}
    return admit_signature_generation(ExpectedSignatureBasis(basis, None), value)


def _unresolved(identity, error, reference):
    result = semantic_record(error.obligations, {"operation": "validate", "type_ref": reference, "value_path": []})
    return {"id": identity, "status": "Unresolved", "classification": {key: _thaw_json(value) for key, value in result.items()}}


def _failure(identity, error):
    if isinstance(error, ValueFailure):
        condition = {"tag": error.condition.tag.value}
        if error.condition.value is not None:
            condition["value"] = error.condition.value
        return {"id":identity,"status":"Rejected","failure":{"kind":"Value","type_ref":error.type_ref,"condition":condition,"path":path_steps_json(error.value_path),"trace":[reference["definition_name"] if isinstance(reference,dict) else reference for reference in error.reference_trace]}}
    if isinstance(error, MeaningFailure):
        return {"id":identity,"status":"Rejected","failure":{"kind":"Meaning","predicate":error.predicate,"location":list(error.location),"reference":error.type_ref}}
    if isinstance(error, DeclarationFailure):
        return {"id":identity,"status":"Rejected","failure":{"kind":"Declaration","predicate":error.predicate,"location":list(error.location),"reference":error.reference}}
    if isinstance(error, WireFailure):
        return {"id":identity,"status":"Rejected","failure":{"kind":"Wire","classification":error.kind,"path":error.path}}
    if isinstance(error, AdmissionFailure):
        cause=error.cause
        if isinstance(cause,(MeaningFailure,ValueFailure,DeclarationFailure,WireFailure)): return _failure(identity,cause)
        return {"id":identity,"status":"Rejected","failure":{"kind":"Admission","classification":error.kind}}
    return {"id":identity,"status":"Rejected","failure":{"kind":"Runtime","classification":type(error).__name__}}


def evaluate(case):
    identity=case["id"]; kind=case["kind"]
    context=None
    try:
        if kind == "classification":
            try:
                check_classification_input(case)
            except WireFailure as failure:
                return {"id": identity, "status": "Rejected", "failure_kind": "Wire", "classification": failure.kind, "path": failure.path}
            if case.get("domain") == "composition":
                return {"id": identity, "domain": case.get("domain"), **{key: _thaw_json(value) for key, value in composition_record(case["obligations"], case["provenance"]).items()}}
            elif case.get("entry") == "value":
                try:
                    context=ValueContext(case["graph"])
                    context.validate(case["reference"], exact_from_json(case["value"]))
                except UnresolvedValueFailure as error:
                    result = semantic_record(error.obligations, {"operation": "validate", "type_ref": context.reference(case["reference"]), "value_path": []})
                    return {"id": identity, **{key: _thaw_json(value) for key, value in result.items()}}
                return {"id": identity, "status": "Resolved"}
            else:
                result = semantic_record(case["obligations"], case["provenance"])
            return {"id": identity, "domain": case.get("domain"), **{key: _thaw_json(value) for key, value in result.items()}}
        if kind=="wire":
            decoded=decode_generation(case["value"])
            return {"id":identity,"status":"Accepted","encoded":json.loads(encode_generation(decoded))}
        if kind=="profile":
            checkProfile(case["profile"]); return {"id":identity,"status":"Accepted"}
        if kind=="library":
            checkLibrary(case["library"]); return {"id":identity,"status":"Accepted"}
            admit_signature_generation(ExpectedSignatureBasis(case["expected_basis"]),case["exchange"]); return {"id":identity,"status":"Accepted"}
        library=case["library"]; checked=admitted_generation(library); context=checked.values
        if kind=="value":
            context.validate(case["type_id"],exact_from_json(case["value"])); return {"id":identity,"status":"Accepted"}
        if kind=="residual_record":
            value=exact_from_json(case["value"])
            reference=declared_type_ref(context.reference(case["type_id"]))
            try:
                context.validate(case["type_id"],value)
            except ValueFailure:
                return {"id":identity,"status":"not-unresolved"}
            except UnresolvedValueFailure as error:
                result=semantic_record(error.obligations, {"operation": "validate", "type_ref": reference, "value_path": []})
                if result["residuals"]:
                    encoded=encode_semantic_residual(case["basis"],reference,value,result["residuals"])
                    return {"id":identity,"status":"encoded","bytes":encoded.hex()}
            return {"id":identity,"status":"not-unresolved"}
        raise ValueError("unsupported input kind")
    except UnresolvedValueFailure as error:
        return _unresolved(identity, error, context.reference(case["type_id"]))
    except (MeaningFailure,ValueFailure,WireFailure,DeclarationFailure,AdmissionFailure) as error:
        return _failure(identity,error)


def _render(value):
    if isinstance(value, (FieldStep, IndexStep, VariantStep)): return _render(path_step_json(value))
    if isinstance(value, RawJsonNumber): return value.text
    if value is None: return "null"
    if isinstance(value, bool): return "true" if value else "false"
    if isinstance(value, int): return str(value)
    if isinstance(value, Mapping): return "{" + ",".join(json.dumps(str(key), ensure_ascii=False) + ":" + _render(item) for key, item in value.items()) + "}"
    if isinstance(value, (list, tuple)): return "[" + ",".join(_render(item) for item in value) + "]"
    return json.dumps(value, ensure_ascii=False, default=str)


def main():
    sys.set_int_max_str_digits(0)
    for line in sys.stdin:
        identity="unknown"
        try:
            case=decode_wire_json(line); identity=case.get("id",identity); result=evaluate(case)
        except Exception as error:
            result=_failure(identity,error)
        print(_render(result),flush=True)


if __name__=="__main__": main()
