# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

import copy
import types

import pytest
from necoherence import network_effect as ne
from necoherence.request_progression import ExecutionHandle, RequestIdentity
from necoherence.signature_values import Completed, HttpBinding, Ready, ValueFailure

from necoherence.type_signatures import AdmissionFailure, ExpectedSignatureBasis, admit_signature_generation, signature_basis
from necoherence_tools.signature_renderer import render_checked, render_expected
from test_profile_predicate_vectors import invalid_exchange
from v4_samples import library


def checked():
    value=library(); entries=[{"identity":"root","definition":"root"}]; basis=signature_basis(value,entries)
    exchange={"schema":"ncoh-checked-generation@4","basis":basis,"signatures":value,"composition":None,"entrypoints":entries}
    return admit_signature_generation(ExpectedSignatureBasis(basis),exchange)


def test_renderer_compiles_and_roundtrips_product_and_wrapper():
    module=types.ModuleType("generated"); source=render_checked(checked()); exec(source,module.__dict__)
    decode,encode=module.CODECS["product"]
    wire={"name":{"text":"x"}}
    assert encode(decode(wire))==wire
    assert module.examples("text")==("x",)


def test_generated_product_decoder_rejects_undeclared_member():
    module=types.ModuleType("generated_extra_rejection"); exec(render_checked(checked()),module.__dict__)
    decode,_=module.CODECS["product"]
    with pytest.raises(ValueFailure,match="UnexpectedField"):
        decode({"name":{"text":"x"},"undeclared":True})


def test_renderer_roundtrips_sealed_union_decimal_and_bytes():
    module=types.ModuleType("generated"); exec(render_checked(checked()),module.__dict__)
    for reference,wire in (
        ("sealed",{"kind":"sealed","label":"x"}),
        ("union",{"kind":"sealed","label":"x"}),
        ("decimal",__import__("necoherence.signature_values",fromlist=["DecimalLiteral"]).DecimalLiteral("1.25")),
        ("bytes",{"bytes":"AQI="}),
    ):
        decode,encode=module.CODECS[reference]
        assert encode(decode(wire))==wire


def test_never_carrier_rejects_construction():
    module=types.ModuleType("generated"); exec(render_checked(checked()),module.__dict__)
    carrier=module.__dict__[module.TYPE_NAMES["never"]]
    try: carrier()
    except TypeError: pass
    else: raise AssertionError("never carrier was inhabited")


def test_renderer_and_codegen_entrance_reject_pr01_before_generation():
    basis, exchange = invalid_exchange()
    with pytest.raises(AdmissionFailure) as caught:
        render_expected(ExpectedSignatureBasis(basis), exchange)
    assert caught.value.cause.predicate == "PR01"


def operation_checked():
    value=library()
    value["nodes"].append({"id":"flag","shape":{"tag":"Boolean","value":{"const_value":None,"default_value":None}}})
    contract={"type_id":"flag","required":True,"nullable":False}
    operation={
        "id":"operation","wire_identity":"operation",
        "shape":{"tag":"Operation","value":{
            "effect":{"tag":"HttpRequestResponse"},
            "inputs":[{"id":"request","contract":contract}],
            "outcomes":[
                {"id":"ok","form":{"tag":"Success"},"cause":{"tag":"ValueContract","fields":{"origin":{}}},
                 "value_ports":[{"id":"value","contract":contract}],"produced_resources":[]},
                {"id":"denied","form":{"tag":"DeclaredFailure"},"cause":{"tag":"ExternalCondition","fields":{"specification":{}}},
                 "value_ports":[{"id":"failure","contract":contract}],"produced_resources":[]},
            ],
        }},
    }
    value["definitions"].append(operation)
    entries=[{"identity":"operation","definition":"operation"}]
    basis=signature_basis(value,entries)
    exchange={"schema":"ncoh-checked-generation@4","basis":basis,"signatures":value,"composition":None,"entrypoints":entries}
    return admit_signature_generation(ExpectedSignatureBasis(basis),exchange)


def test_external_operation_uses_typed_preparation_and_network_result_paths():
    module=types.ModuleType("generated_operation")
    exec(render_checked(operation_checked()),module.__dict__)
    arguments_name,_=module.ENTRYPOINT_SHAPES["operation"]
    arguments=module.__dict__[arguments_name](request=True)
    outcomes=[value for value in module.__dict__.values() if getattr(value,"outcome_id",None)]
    ok=next(value for value in outcomes if value.outcome_id=="ok")
    denied=next(value for value in outcomes if value.outcome_id=="denied")
    effects={"start":0,"observe":0,"decode":0}

    class Adapter:
        def start(self,command):
            effects["start"]+=1
            return ne.Started(command.prepared.input.attempt,ExecutionHandle("generated-operation"))

        def observe(self,started):
            effects["observe"]+=1
            response=ne.ResponseObservation(
                started.prepared.input.attempt,
                started.handle,
                0,
                ne.RawHttpResponse(200,(),()),
                ne.HeaderProvenance.WIRE_OBSERVED,
                ne.Unknown(ne.UnknownEffectReason.NO_RESPONSE),
            )
            return ne.DeliveredObservation(0,response)

    logical=RequestIdentity("generated","operation",1)
    attempt=ne.AttemptInput(
        ne.AttemptIdentity(logical,0),
        ne.HttpWireInstruction("POST","http://127.0.0.1:1/",(),()),
        None,
        ne.HostConfiguration(8,8),
    )
    def decode(settled):
        effects["decode"]+=1
        assert settled.prepared.input==attempt
        return ok(value=False)

    started=HttpBinding(ne.NetworkState(()),Adapter(),lambda _:Ready(attempt),decode)
    assert module.ENTRYPOINTS["operation"](arguments,started).value is False
    assert effects=={"start":1,"observe":1,"decode":1}

    completed=HttpBinding(
        ne.NetworkState(()),
        Adapter(),
        lambda _:Completed(denied(failure=True)),
        lambda _:pytest.fail("synchronous completion decoded a network result"),
    )
    assert module.ENTRYPOINTS["operation"](arguments,completed).failure is True
    assert effects=={"start":1,"observe":1,"decode":1}

    undeclared=HttpBinding(ne.NetworkState(()),Adapter(),lambda _:Ready(attempt),lambda _:object())
    with pytest.raises(TypeError,match="undeclared operation outcome"):
        module.ENTRYPOINTS["operation"](arguments,undeclared)

    success=HttpBinding(ne.NetworkState(()),Adapter(),lambda _:Completed(ok(value=True)),decode)
    with pytest.raises(TypeError,match="declared external failure"):
        module.ENTRYPOINTS["operation"](arguments,success)

    original_identity=denied.outcome_id
    denied.outcome_id="ok"
    try:
        mismatch=HttpBinding(ne.NetworkState(()),Adapter(),lambda _:Completed(denied(failure=True)),decode)
        with pytest.raises(TypeError,match="identity mismatch"):
            module.ENTRYPOINTS["operation"](arguments,mismatch)
    finally:
        denied.outcome_id=original_identity

    with pytest.raises(TypeError,match="external operations require HttpBinding"):
        module.ENTRYPOINTS["operation"](arguments,lambda _:ok(value=False))


def composition_checked():
    value=library()
    value["nodes"].append({"id":"flag","shape":{"tag":"Boolean","value":{"const_value":None,"default_value":None}}})
    contract={"type_id":"flag","required":True,"nullable":False}
    reference={"identity":"worker","revision":"1","content_digest":"b"*64}
    signature={
        "reference":reference,"form":{"tag":"Pure"},"effect":{"tag":"DataOnly"},"inputs":[],
        "outcomes":[{"id":"ok","form":{"tag":"Success"},"cause":{"tag":"ValueContract","fields":{"origin":{}}},
                     "value_ports":[{"id":"value","contract":contract}],"produced_resources":[]}],
    }
    producer={"tag":"InvocationOutcome","fields":{"site":"worker-site","outcome":"ok","port":"value"}}
    binding={"tag":"Source","fields":{"value":{"producer":producer,"path":[]},"projection":{},"compatibility":{"tag":"Inclusion","value":[]}}}
    terminal={"rank":"1","node":{"tag":"Return","value":{"tag":"Success","value":[["result",binding]]}}}
    root={"rank":"0","node":{"tag":"Invoke","fields":{
        "invocation":{"site":"worker-site","function":reference,"bindings":[],"resources":[]},
        "arms":[["ok",terminal]],"empty_outcomes":[]}}}
    problem={
        "identity":"compose","revision":"1","signatures":[signature],"initial_inputs":[],
        "goal":{"outputs":[{"id":"result","contract":contract,"source_constraint":{"tag":"AnyCompatible"}}],
                "failures":[],"final_resources":[]},
    }
    composition={"problem":problem,"derivation":{"plan":{"root":root}}}
    entries=[]
    basis=signature_basis(value,entries,composition)
    exchange={"schema":"ncoh-checked-generation@4","basis":basis,"signatures":value,"composition":composition,"entrypoints":entries}
    return admit_signature_generation(ExpectedSignatureBasis(basis),exchange)


def test_composition_codegen_uses_v4_declaration_and_executes_plan():
    module=types.ModuleType("generated_composition")
    exec(render_checked(composition_checked()),module.__dict__)
    arguments_name,result_name=module.ENTRYPOINT_SHAPES["compose"]
    outcome=next(value for value in module.__dict__.values() if getattr(value,"outcome_id",None)=="ok")
    providers=module.Providers(worker=lambda _:outcome(value=True))
    result=module.ENTRYPOINTS["compose"](module.__dict__[arguments_name](),providers)
    assert type(result).__name__==result_name
    assert result.result is True
    invalid=module.Providers(worker=lambda _:object())
    with pytest.raises(TypeError,match="undeclared outcome type"):
        module.ENTRYPOINTS["compose"](module.__dict__[arguments_name](),invalid)


def test_composition_admission_rejects_incomplete_branch_coverage():
    checked=composition_checked()
    exchange=copy.deepcopy(checked.input)
    exchange["composition"]["derivation"]["plan"]["root"]["node"]["fields"]["arms"]=[]
    exchange["basis"]=signature_basis(exchange["signatures"],exchange["entrypoints"],exchange["composition"])
    with pytest.raises(AdmissionFailure,match="IncompleteBranchCoverage"):
        admit_signature_generation(ExpectedSignatureBasis(exchange["basis"]),exchange)
