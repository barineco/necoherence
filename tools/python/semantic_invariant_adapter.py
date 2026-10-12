# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

"""JSONL adapter for the shared declaration comparison."""
from __future__ import annotations

import json
import sys
from functools import lru_cache
from pathlib import Path
from types import ModuleType

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "python" / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))

from necoherence.signature_values import MeaningFailure, ValueContext, ValueFailure, WireFailure
from necoherence.type_signatures import AdmissionFailure, DeclarationFailure, ExpectedSignatureBasis, admit_signature_generation, checkLibrary, checkProfile, decode_generation, encode_generation, signature_basis
from necoherence_tools.inclusion_samples import compatible, sample_values
from necoherence_tools.signature_renderer import render_checked


def admitted_generation(library):
    entries = [{"identity": row["id"], "definition": row["id"]} for row in library["definitions"][:1]]
    basis = signature_basis(library, entries)
    value = {"schema":"ncoh-checked-generation@4","basis":basis,"signatures":library,"composition":None,"entrypoints":entries}
    return admit_signature_generation(ExpectedSignatureBasis(basis), value)


def _failure(identity, error):
    if isinstance(error, ValueFailure):
        return {"id":identity,"status":"Rejected","failure":{"kind":"Value","type_ref":error.type_ref,"condition":error.condition,"path":list(error.value_path),"trace":[reference["definition_name"] if isinstance(reference,dict) else reference for reference in error.reference_trace]}}
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
    try:
        if kind=="wire":
            decoded=decode_generation(case["value"])
            return {"id":identity,"status":"Accepted","encoded":json.loads(encode_generation(decoded))}
        if kind=="profile":
            checkProfile(case["profile"]); return {"id":identity,"status":"Accepted"}
        if kind=="library":
            checkLibrary(case["library"]); return {"id":identity,"status":"Accepted"}
        if kind=="construction_witness":
            admit_signature_generation(ExpectedSignatureBasis(case["expected_basis"]),case["exchange"]); return {"id":identity,"status":"Accepted"}
        library=case["library"]; checked=admitted_generation(library); context=checked.values
        if kind=="value":
            context.validate(case["type_id"],case["value"]); return {"id":identity,"status":"Accepted"}
        if kind=="codec":
            module=ModuleType("generated_semantic_library"); exec(render_checked(checked),module.__dict__)
            decode,encode=module.CODECS[case["type_id"]]; encoded=encode(decode(case["value"]))
            return {"id":identity,"status":"Accepted","encoded":encoded}
        if kind=="inclusion":
            result=compatible(context,case["source"]["type_id"],case["destination"]["type_id"],int(case.get("max_obligations",64)))
            return {"id":identity,**result}
        if kind=="samples":
            result=sample_values(context,int(case.get("fuel",8)),(),case["type_id"],int(case.get("max_sample_length",4096)))
            return {"id":identity,"values":list(result.values),"sampleBound":result.sampleBound,"possible":result.possible}
        if kind=="renderer":
            source=render_checked(checked); compile(source,"<generated>","exec"); return {"id":identity,"status":"Accepted"}
        raise ValueError("unsupported input kind")
    except (MeaningFailure,ValueFailure,WireFailure,DeclarationFailure,AdmissionFailure) as error:
        return _failure(identity,error)


def main():
    for line in sys.stdin:
        identity="unknown"
        try:
            case=json.loads(line); identity=case.get("id",identity); result=evaluate(case)
        except Exception as error:
            result=_failure(identity,error)
        print(json.dumps(result,ensure_ascii=False,separators=(",",":"),default=str),flush=True)


if __name__=="__main__": main()
