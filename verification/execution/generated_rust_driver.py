#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "verification/execution/rust_driver/Cargo.toml"
CARGO = os.environ.get("CARGO", "cargo")
NETWORK_FAILURE_JSON = (ROOT / "verification/execution/rust_driver/src/network_failure.rs").read_text(encoding="utf-8")


def command(argv, *, cwd=ROOT, input=None):
    value = subprocess.run(argv, cwd=cwd, input=input, text=True, capture_output=True)
    if value.returncode: raise RuntimeError(value.stderr or value.stdout)
    return value.stdout


def exact(value):
    if value is None: return "exjson::JsonValue::Null"
    if value is True: return "exjson::JsonValue::Bool(true)"
    if value is False: return "exjson::JsonValue::Bool(false)"
    if isinstance(value, str): return f"exjson::JsonValue::Str({json.dumps(value)}.into())"
    if isinstance(value, list): return "exjson::JsonValue::Arr(vec![" + ",".join(exact(item) for item in value) + "])"
    if isinstance(value, dict): return "exjson::JsonValue::Obj(vec![" + ",".join(f"({json.dumps(key)}.into(),{exact(item)})" for key, item in value.items()) + "])"
    return f"exjson::JsonValue::Num(exjson::BigInt::from({value}))"


def carrier(type_id, value):
    return f"{{let generation=initialize().unwrap();let cx=Context::new(&generation);cx.checked_for::<{type_id}>({exact(value)}).and_then(|checked|{type_id}::read_wire(&cx,checked)).unwrap()}}"


def typed_slot(type_id, contract, value):
    if contract["required"] and not contract["nullable"]: return carrier(type_id, value.get("value"))
    if not contract["required"] and contract["nullable"]:
        return "None" if value["tag"] == "absent" else "Some(rt::Nullable::Null)" if value["tag"] == "null" else f"Some(rt::Nullable::Value({carrier(type_id, value['value'])}))"
    if contract["required"]: return "rt::Nullable::Null" if value["tag"] == "null" else f"rt::Nullable::Value({carrier(type_id, value['value'])})"
    return "None" if value["tag"] == "absent" else f"Some({carrier(type_id, value['value'])})"


def default_slot(type_id, contract):
    value = {"tag": "present", "value": False}
    if contract["nullable"]:
        value = {"tag": "null"}
    elif not contract["required"]:
        value = {"tag": "absent"}
    return typed_slot(type_id, contract, value)


def outcome(exchange, signature, description, fallback=False):
    outcomes = exchange["composition"]["problem"]["signatures"][signature]["outcomes"]
    index = next((i for i, value in enumerate(outcomes) if value["id"] == description["outcome"]), None)
    if index is None and fallback: index = 0
    if index is None: raise ValueError(f"unrepresentable outcome {description['outcome']}")
    supplied = {value["id"]: value["value"] for value in description["outputs"]}
    values = ",".join(f"{port['id']}:{typed_slot(port['contract']['type_id'], port['contract'], supplied[port['id']]) if port['id'] in supplied else default_slot(port['contract']['type_id'], port['contract'])}" for port in outcomes[index]["value_ports"])
    return f"composed::Function{signature}Outcome::Outcome{index}(composed::Function{signature}Outcome{index}{{{values}}})"


def attempt(value):
    provenance = json.dumps(value.get("provenance", "comparison")); ordinal = value.get("ordinal", 0)
    return f'''network::AttemptInput{{attempt:network::AttemptIdentity{{logical:RequestIdentity{{kind:"semantic".into(),provenance:{provenance}.into(),revision:1u8.into()}},ordinal:{ordinal}u8.into()}},instruction:network::HttpWireInstruction{{method:{json.dumps(value['method'])}.into(),target:{json.dumps(value['target'])}.into(),headers:vec![],body:vec![]}},deadline:None,configuration:network::HostConfiguration{{request_body_limit:1024u64.into(),response_body_limit:1024u64.into(),cancellation:None,monotonic_clock:None}}}}'''


def provider_impl(exchange, descriptions):
    methods = []
    for index, description in enumerate(descriptions):
        signature = description.get("signature", 0)
        if description["effect"] == "pure":
            returned = outcome(exchange, signature, description)
            methods.append(f"fn call_{signature}(&mut self,_:composed::Function{signature}Input)->Result<composed::Function{signature}Outcome,execution::ExecutionFailure>{{Ok({returned})}}")
            continue
        prepared = description["prepare"][0]
        prepared_code = f"execution::BindingPreparedCall::Ready(std::sync::Arc::new({attempt(prepared['request'])}))" if prepared["tag"] == "ready" else f"execution::BindingPreparedCall::Completed(OutcomeId({json.dumps(prepared['outcome'])}.into()),{outcome(exchange, signature, prepared, True)})"
        decode_arms = []
        for row in description["decode"]:
            if "failure" in row:
                decode_arms.append(f"Some({row['status']})=>Err(execution::ExecutionFailure::Provider(SiteId({json.dumps(row['failure'].get('site','operation'))}.into()),{json.dumps(row['failure']['message'])}.into()))")
            else: decode_arms.append(f"Some({row['status']})=>Ok({outcome(exchange, signature, row)})")
        outcomes = exchange["composition"]["problem"]["signatures"][signature]["outcomes"]
        ids = ",".join(f"composed::Function{signature}Outcome::Outcome{i}(_)=>{json.dumps(value['id'])}" for i, value in enumerate(outcomes))
        claimed = prepared.get("outcome")
        outcome_id = f"OutcomeId({json.dumps(claimed)}.into())" if claimed and all(value["id"] != claimed for value in outcomes) else f"OutcomeId(match value{{{ids}}}.into())"
        methods.append(f'''fn call_{signature}(&mut self)->execution::NetworkBinding<composed::Function{signature}Input,composed::Function{signature}Outcome>{{execution::NetworkBinding{{transport:execution::NetworkTransport{{encode:Arc::new(|value|Ok(value.clone())),decode:Arc::new(|response|match response.status.to_u64(){{{','.join(decode_arms)},_=>panic!("status")}})}},prepare:Arc::new(|_|Ok({prepared_code}))}}}}''')
    return "struct Host; impl composed::Providers for Host{" + "".join(methods) + "}"


def observation(case, value):
    ready = [row for provider in case["providers"] for row in provider.get("prepare", []) if row["tag"] == "ready"]
    request = attempt(ready[value.get("request", 0)]["request"]); handle = json.dumps(value.get("handle", "handle"))
    if value["tag"] == "start" and value.get("kind") == "started": return f"execution::ExecutionObservation::Start(network::StartObservation::Started{{attempt:({request}).attempt,handle:ExecutionHandle{{value:{handle}.into()}}}})"
    if value["tag"] == "start": return f"{{let request={request};execution::ExecutionObservation::Start(network::StartObservation::StartFailed{{failure:network::NetworkHostFailure{{attempt:request.attempt,stage:network::HostStage::Start,configuration:request.configuration,cause:network::HostFailure::ExecutionStartFailed}},effect:network::EffectStatus::Unknown{{reason:network::UnknownEffectReason::NoResponse}}}})}}"
    return f'''execution::ExecutionObservation::Host(network::HostObservation::Delivered{{delivery:{value.get('delivery',0)}u8.into(),observation:network::AdapterObservation::ResponseObservation{{attempt:({request}).attempt,handle:ExecutionHandle{{value:{handle}.into()}},source_sequence:None,response:network::RawHttpResponse{{status:{value['status']}u16.into(),headers:vec![],body:vec![]}},provenance:network::HeaderProvenance::LibraryNormalized,effect:network::EffectStatus::Unknown{{reason:network::UnknownEffectReason::NoResponse}}}}}})'''


def slot_output(expression, contract):
    if contract["required"] and not contract["nullable"]: return f"present_json(&cx,&{expression})"
    if not contract["required"] and contract["nullable"]: return f'match &{expression}{{None=>json!({{"tag":"absent"}}),Some(rt::Nullable::Null)=>json!({{"tag":"null"}}),Some(rt::Nullable::Value(value))=>present_json(&cx,value)}}'
    if contract["required"]: return f'match &{expression}{{rt::Nullable::Null=>json!({{"tag":"null"}}),rt::Nullable::Value(value)=>present_json(&cx,value)}}'
    return f'match &{expression}{{None=>json!({{"tag":"absent"}}),Some(value)=>present_json(&cx,value)}}'


def runner(exchange, case):
    problem = exchange["composition"]["problem"]
    arguments_by_id = {value["id"]: value["value"] for value in case["arguments"]}
    args = ",".join(f"{value['id']}:{typed_slot(value['contract']['type_id'], value['contract'], arguments_by_id[value['id']])}" for value in problem["initial_inputs"] if value["source"]["tag"] == "Argument")
    observations = ",".join(observation(case, value) for value in case["observations"])
    success_fields = ",".join(f"{goal['id']}" for goal in problem["goal"]["outputs"])
    success_json = ",".join(f"json!([{json.dumps(goal['id'])},{slot_output(goal['id'], goal['contract'])}])" for goal in problem["goal"]["outputs"])
    failure_arms = []
    for index, failure in enumerate(problem["goal"]["failures"]):
        failure_arms.append(f'composed::Result::Failure{index}(value)=>json!({{"tag":"failure","embedding":{json.dumps(failure["id"])},"value":{slot_output("value", failure["contract"])}}})')
    result_arms = f'composed::Result::Success(composed::Success{{{success_fields}}})=>json!({{"tag":"success","outcome":[{success_json}]}})' + ("," + ",".join(failure_arms) if failure_arms else "")
    return f'''
use std::sync::Arc;
use necoherence::semantic_execution as execution;
use necoherence::semantic_composition as composition;
use necoherence::semantic_types as semantic;
use necoherence::network_effect as network;
use necoherence::request_progression::{{ExecutionHandle,RequestIdentity}};
use necoherence::semantic_composition::{{OutcomeId,SiteId}};
use necoherence::exact_json as exjson;
use serde_json::json;
use std::io::Write;
mod network_failure {{
{NETWORK_FAILURE_JSON}
}}
{provider_impl(exchange, case['providers'])}
fn exact(value:&exjson::JsonValue)->serde_json::Value{{match value{{exjson::JsonValue::Null=>serde_json::Value::Null,exjson::JsonValue::Bool(v)=>json!(v),exjson::JsonValue::Num(v)=>json!(v.to_string()),exjson::JsonValue::Dec(v)=>json!(v),exjson::JsonValue::Str(v)=>json!(v),exjson::JsonValue::Arr(v)=>serde_json::Value::Array(v.iter().map(exact).collect()),exjson::JsonValue::Obj(v)=>serde_json::Value::Object(v.iter().map(|(k,v)|(k.clone(),exact(v))).collect())}}}}
fn present_json<T:WireValue>(cx:&Context<'_>,value:&T)->serde_json::Value{{json!({{"tag":"present","value":exact(&value.write_wire(cx).unwrap())}})}}
fn nested(constructor:&str,arguments:Vec<serde_json::Value>)->serde_json::Value{{json!({{"constructor":constructor,"arguments":arguments}})}}
fn source_ref_json(value:&semantic::SourceRef)->serde_json::Value{{json!({{"repository":value.repository,"revision":value.revision,"path":value.path,"contentDigest":value.content_digest,"documentId":value.document_id,"declaredRevision":value.declared_revision.as_ref().map(ToString::to_string)}})}}
fn type_ref_json(value:&semantic::TypeRef)->serde_json::Value{{json!({{"source":source_ref_json(&value.source),"definitionName":value.definition_name.as_ref(),"pointer":value.pointer.as_ref()}})}}
fn value_type_ref_json(value:&semantic::TypeRef)->serde_json::Value{{json!({{"source":source_ref_json(&value.source),"definition":value.definition_name.as_ref(),"pointer":value.pointer.as_ref()}})}}
fn occurrence_ref_json(value:&semantic::OccurrenceRef)->serde_json::Value{{json!({{"source":source_ref_json(&value.source),"pointer":value.pointer.as_ref()}})}}
fn path_json(value:&[semantic::PathStep])->serde_json::Value{{serde_json::Value::Array(value.iter().map(|step|match step{{semantic::PathStep::Field(name)=>nested("field",vec![json!(name)]),semantic::PathStep::Index(index)=>nested("index",vec![json!(index.to_string())]),semantic::PathStep::Variant(tag)=>nested("variant",vec![json!(tag)])}}).collect())}}
fn value_path_json(value:&[semantic::PathStep])->serde_json::Value{{serde_json::Value::Array(value.iter().map(|step|match step{{semantic::PathStep::Field(name)=>json!({{"field":name}}),semantic::PathStep::Index(index)=>json!({{"index":index.to_string().parse::<u64>().unwrap()}}),semantic::PathStep::Variant(tag)=>json!({{"variant":tag}})}}).collect())}}
fn semantic_reason_json(value:&semantic::SemanticReason)->serde_json::Value{{match value{{semantic::SemanticReason::UnknownFormat(value)=>nested("unknownFormat",vec![json!(value)]),semantic::SemanticReason::MissingGraphemeRules=>nested("missingGraphemeRules",vec![]),semantic::SemanticReason::MissingBytesPolicy=>nested("missingBytesPolicy",vec![]),semantic::SemanticReason::UnknownIntegerDomain(value)=>nested("unknownIntegerDomain",vec![json!(value)]),semantic::SemanticReason::UnknownWrapper(value)=>nested("unknownWrapper",vec![json!(value)]),semantic::SemanticReason::WrapperPayload(value)=>nested("wrapperPayload",vec![json!(value)]),semantic::SemanticReason::UnknownSealedTag(value)=>nested("unknownSealedTag",vec![json!(value)]),semantic::SemanticReason::DecimalNotAdmitted=>nested("decimalNotAdmitted",vec![]),semantic::SemanticReason::IntegerBound=>nested("integerBound",vec![]),semantic::SemanticReason::OpaqueType(value)=>nested("opaqueType",vec![json!(value)]),semantic::SemanticReason::MissingTagModel=>nested("missingTagModel",vec![]),semantic::SemanticReason::UninterpretedExtension(value)=>nested("uninterpretedExtension",vec![json!(value)]),semantic::SemanticReason::UnresolvedType=>nested("unresolvedType",vec![]),semantic::SemanticReason::InvalidProfile(value)=>nested("invalidProfile",vec![json!(value)]),semantic::SemanticReason::MembershipBound=>nested("membershipBound",vec![]),semantic::SemanticReason::CertificateMismatch(value)=>nested("certificateMismatch",vec![json!(value)]),semantic::SemanticReason::ProjectionUnavailable(value)=>nested("projectionUnavailable",vec![json!(value)])}}}}
fn semantic_obligation_json(value:&semantic::SemanticObligation)->serde_json::Value{{json!({{"typeRef":value_type_ref_json(&value.type_ref),"valuePath":value_path_json(&value.value_path),"reason":semantic_reason_json(&value.reason)}})}}
fn value_failure_json(value:&semantic::ValueFailure)->serde_json::Value{{let encoded:serde_json::Value=serde_json::from_str(&necoherence::semantic_exchange::encode_diagnostic(value).unwrap()).unwrap();json!({{"typeRef":value_type_ref_json(&value.type_ref),"definitionRef":{{"source":source_ref_json(&value.definition_ref.source),"name":value.definition_ref.name.as_ref()}},"origin":occurrence_ref_json(&value.origin),"valuePath":value_path_json(&value.value_path),"condition":encoded["condition"],"observed":encoded["observed"],"referenceTrace":value.reference_trace.iter().map(value_type_ref_json).collect::<Vec<_>>()}})}}
fn validation_failure_json(value:&execution::ValidationFailure)->serde_json::Value{{match value{{execution::ValidationFailure::Value(failure)=>nested("value",vec![value_failure_json(failure)]),execution::ValidationFailure::Unresolved(obligations)=>nested("unresolved",vec![serde_json::Value::Array(obligations.iter().map(semantic_obligation_json).collect())]),execution::ValidationFailure::CertificateMismatch(condition)=>nested("certificateMismatch",vec![json!(condition)])}}}}
fn producer_ref_json(value:&composition::ProducerRef)->serde_json::Value{{match value{{composition::ProducerRef::Initial(id)=>nested("initial",vec![json!(id.0)]),composition::ProducerRef::InvocationOutcome{{site,outcome,port}}=>nested("invocationOutcome",vec![json!(site.0),json!(outcome.0),json!(port.0)])}}}}
fn value_ref_json(value:&composition::ValueRef)->serde_json::Value{{json!({{"producer":producer_ref_json(&value.producer),"path":path_json(&value.path)}})}}
fn slot_contract_json(value:&semantic::SlotContract)->serde_json::Value{{json!({{"typeRef":type_ref_json(&value.type_ref),"required":value.required,"nullable":value.nullable}})}}
fn type_reason_json(value:&composition::TypeObligationReason)->serde_json::Value{{match value{{composition::TypeObligationReason::Meaning(values)=>nested("meaning",vec![serde_json::Value::Array(values.iter().map(semantic_obligation_json).collect())]),composition::TypeObligationReason::ConstraintImplication=>nested("constraintImplication",vec![]),composition::TypeObligationReason::Presence=>nested("presence",vec![]),composition::TypeObligationReason::UnionRemainder=>nested("unionRemainder",vec![]),composition::TypeObligationReason::ExtraField(value)=>nested("extraField",vec![json!(value)]),composition::TypeObligationReason::Inhabitation=>nested("inhabitation",vec![]),composition::TypeObligationReason::ObligationBoundExhausted=>nested("obligationBoundExhausted",vec![])}}}}
fn type_obligation_json(value:&composition::TypeObligation)->serde_json::Value{{json!({{"pair":{{"source":slot_contract_json(&value.pair.source),"destination":slot_contract_json(&value.pair.destination)}},"path":path_json(&value.path),"reason":type_reason_json(&value.reason)}})}}
fn inclusion_failure_json(value:&composition::InclusionFailure)->serde_json::Value{{match value{{composition::InclusionFailure::BasisMismatch=>nested("basisMismatch",vec![]),composition::InclusionFailure::ContractMismatch=>nested("contractMismatch",vec![]),composition::InclusionFailure::UndefinedMeaning(values)=>nested("undefinedMeaning",vec![serde_json::Value::Array(values.iter().map(semantic_obligation_json).collect())]),composition::InclusionFailure::MissingPair=>nested("missingPair",vec![]),composition::InclusionFailure::PairMismatch(index)=>nested("pairMismatch",vec![json!(index.to_string())]),composition::InclusionFailure::RuleMismatch(index)=>nested("ruleMismatch",vec![json!(index.to_string())]),composition::InclusionFailure::ChildCoverage(index)=>nested("childCoverage",vec![json!(index.to_string())]),composition::InclusionFailure::ForgedEmptiness=>nested("forgedEmptiness",vec![]),composition::InclusionFailure::CounterexampleMismatch=>nested("counterexampleMismatch",vec![]),composition::InclusionFailure::Unresolved(value)=>nested("unresolved",vec![type_obligation_json(value)])}}}}
fn projection_failure_json(value:&composition::ProjectionFailure)->serde_json::Value{{match value{{composition::ProjectionFailure::WrongShape{{type_ref,path}}=>nested("wrongShape",vec![type_ref_json(type_ref),path_json(path)]),composition::ProjectionFailure::MissingField{{type_ref,name}}=>nested("missingField",vec![type_ref_json(type_ref),json!(name)]),composition::ProjectionFailure::MissingVariant{{type_ref,tag}}=>nested("missingVariant",vec![type_ref_json(type_ref),json!(tag)]),composition::ProjectionFailure::BranchAssumptionRequired{{path,tag}}=>nested("branchAssumptionRequired",vec![path_json(path),json!(tag)]),composition::ProjectionFailure::VariantSelectionUndetermined{{path,tag}}=>nested("variantSelectionUndetermined",vec![path_json(path),json!(tag)]),composition::ProjectionFailure::Unresolved(values)=>nested("unresolved",vec![serde_json::Value::Array(values.iter().map(semantic_obligation_json).collect())]),composition::ProjectionFailure::CertificateMismatch(value)=>nested("certificateMismatch",vec![json!(value)])}}}}
fn function_detail_json(reference:&composition::FunctionRef)->serde_json::Value{{json!({{"identity":reference.identity,"revision":reference.revision,"contentDigest":reference.content_digest}})}}
fn wire_json<T:necoherence::semantic_exchange::WireEncode+?Sized>(value:&T)->serde_json::Value{{serde_json::to_value(necoherence::semantic_exchange::Wire(value)).unwrap()}}
fn library_check_json(value:&necoherence::type_signatures::LibraryCheckFailure)->serde_json::Value{{match value{{necoherence::type_signatures::LibraryCheckFailure::Profile(failure)=>nested("profile",vec![json!({{"identity":failure.reference.identity,"revision":failure.reference.revision,"contentDigest":failure.reference.content_digest}}),json!(format!("{{:?}}",failure.predicate).to_lowercase()),json!(failure.location)]),necoherence::type_signatures::LibraryCheckFailure::Library(failure)=>nested("library",vec![json!(failure.reference),json!(format!("{{:?}}",failure.predicate).to_lowercase()),json!(failure.location)])}}}}
fn composition_input_failure_json(value:&composition::CompositionInputFailure)->serde_json::Value{{match value{{composition::CompositionInputFailure::BasisMismatch=>nested("basisMismatch",vec![]),composition::CompositionInputFailure::DuplicateIdentity{{kind,identity}}=>nested("duplicateIdentity",vec![json!(kind),json!(identity)]),composition::CompositionInputFailure::UnresolvedType(reference)=>nested("unresolvedType",vec![type_ref_json(reference)]),composition::CompositionInputFailure::UnresolvedFunction(reference)=>nested("unresolvedFunction",vec![function_detail_json(reference)]),composition::CompositionInputFailure::InvalidSignature{{function,reason}}=>nested("invalidSignature",vec![function_detail_json(function),json!(reason.text())]),composition::CompositionInputFailure::InvalidInitialValue{{input,failure}}=>nested("invalidInitialValue",vec![json!(input.0),value_failure_json(failure)]),composition::CompositionInputFailure::SiteEffectNotPermitted{{site,effect}}=>nested("siteEffectNotPermitted",vec![json!(site.0),wire_json(effect)]),composition::CompositionInputFailure::TransformNotPermitted(reference)=>nested("transformNotPermitted",vec![function_detail_json(reference)]),composition::CompositionInputFailure::EmptyGoal=>nested("emptyGoal",vec![]),composition::CompositionInputFailure::GoalSourceConstraintUndefined{{port,constraint}}=>nested("goalSourceConstraintUndefined",vec![json!(port.0),wire_json(constraint)]),composition::CompositionInputFailure::FailureEmbeddingOriginUndefined{{embedding,origin}}=>nested("failureEmbeddingOriginUndefined",vec![json!(embedding.0),wire_json(origin)]),composition::CompositionInputFailure::ConstructionNotProduct{{identity,type_ref}}=>nested("constructionNotProduct",vec![json!(identity),type_ref_json(type_ref)]),composition::CompositionInputFailure::FieldConstraintUnknownField{{identity,field}}=>nested("fieldConstraintUnknownField",vec![json!(identity),json!(field)]),composition::CompositionInputFailure::ConstrainedNestedField{{identity,field}}=>nested("constrainedNestedField",vec![json!(identity),json!(field)]),composition::CompositionInputFailure::ConstructionFieldSourceUndefined{{identity,constraint}}=>nested("constructionFieldSourceUndefined",vec![json!(identity),wire_json(constraint)]),composition::CompositionInputFailure::NestedFieldUndeclared{{identity,field}}=>nested("nestedFieldUndeclared",vec![json!(identity),json!(field)]),composition::CompositionInputFailure::NestedConstructionMismatch{{identity,field,nested:target,type_ref}}=>nested("nestedConstructionMismatch",vec![json!(identity),json!(field),json!(target),type_ref_json(type_ref)]),composition::CompositionInputFailure::CyclicConstruction{{identity}}=>nested("cyclicConstruction",vec![json!(identity)]),composition::CompositionInputFailure::ExplicitSiteOrderInvalid{{before,after}}=>nested("explicitSiteOrderInvalid",vec![json!(before.0),json!(after.0)]),composition::CompositionInputFailure::InvalidEmptyTypeClosure(failure)=>nested("invalidEmptyTypeClosure",vec![inclusion_failure_json(failure)]),composition::CompositionInputFailure::InvalidResourceDeclaration(reason)=>nested("invalidResourceDeclaration",vec![json!(reason)]),composition::CompositionInputFailure::InvalidLibrary(failure)=>nested("invalidLibrary",vec![library_check_json(failure)])}}}}
fn witness_failure_json(value:&composition::WitnessFailure)->serde_json::Value{{match value{{composition::WitnessFailure::InputRevisionMismatch=>nested("inputRevisionMismatch",vec![]),composition::WitnessFailure::InitialMembership(value)=>nested("initialMembership",vec![json!(value.0)]),composition::WitnessFailure::ProducerMismatch(value)=>nested("producerMismatch",vec![value_ref_json(value)]),composition::WitnessFailure::ProjectionMismatch(value)=>nested("projectionMismatch",vec![projection_failure_json(value)]),composition::WitnessFailure::SourceConstraintMismatch(value)=>nested("sourceConstraintMismatch",vec![value_ref_json(value)]),composition::WitnessFailure::Inclusion(value)=>nested("inclusion",vec![inclusion_failure_json(value)]),composition::WitnessFailure::SuppliedValueMismatch(value)=>nested("suppliedValueMismatch",vec![value_ref_json(value)]),composition::WitnessFailure::ConstructionMismatch(value)=>nested("constructionMismatch",vec![type_ref_json(value)]),composition::WitnessFailure::MissingBinding(value)=>nested("missingBinding",vec![json!(value)]),composition::WitnessFailure::SignatureMismatch(value)=>nested("signatureMismatch",vec![json!(value.0)]),composition::WitnessFailure::GuardNotDominating(value)=>nested("guardNotDominating",vec![value_ref_json(value)]),composition::WitnessFailure::IncompleteBranchCoverage(value)=>nested("incompleteBranchCoverage",vec![json!(value)]),composition::WitnessFailure::FailureEmbeddingMismatch(value)=>nested("failureEmbeddingMismatch",vec![json!(value.0)]),composition::WitnessFailure::GoalMismatch=>nested("goalMismatch",vec![]),composition::WitnessFailure::RankViolation=>nested("rankViolation",vec![]),composition::WitnessFailure::ResourceLoweringMismatch(value)=>nested("resourceLoweringMismatch",vec![json!(value)]),composition::WitnessFailure::ResourceReplayMismatch(value)=>nested("resourceReplayMismatch",vec![json!(value)]),composition::WitnessFailure::ForgedClosure(value)=>nested("forgedClosure",vec![json!(value)]),composition::WitnessFailure::ForgedAcyclicity(value)=>nested("forgedAcyclicity",vec![json!(value)]),composition::WitnessFailure::MissingEvidence(value)=>nested("missingEvidence",vec![json!(value)]),}}}}
fn failure_json(value:&execution::ExecutionFailure)->serde_json::Value{{match value{{
 execution::ExecutionFailure::Provider(site,message)=>json!({{"tag":"provider","site":site.0,"message":message}}),
 execution::ExecutionFailure::InvalidPlan(condition)=>json!({{"tag":"invalidPlan","condition":condition}}),
 execution::ExecutionFailure::NetworkTerminal(terminal)=>{{let (outcome,stage,cause)=match &terminal.outcome{{network::NetworkOutcome::Failed{{failure}}=>("Failed",Some(format!("{{:?}}",failure.stage)),Some(format!("{{:?}}",failure.cause))),network::NetworkOutcome::Response{{..}}=>("Response",None,None),network::NetworkOutcome::Cancelled=>("Cancelled",None,None),network::NetworkOutcome::DeadlineExceeded{{..}}=>("DeadlineExceeded",None,None)}};let (effect,reason)=match &terminal.effect{{network::EffectStatus::NoEffect{{..}}=>("NoEffect",None),network::EffectStatus::EffectOccurred{{..}}=>("EffectOccurred",None),network::EffectStatus::Unknown{{reason}}=>("Unknown",Some(format!("{{:?}}",reason)))}};json!({{"tag":"networkTerminal","outcome":outcome,"stage":stage,"cause":cause,"effect":effect,"reason":reason}})}},
 execution::ExecutionFailure::Network(failure)=>json!({{"tag":"network","detail":network_failure::json(failure)}}),
 execution::ExecutionFailure::Value(failure)=>json!({{"tag":"value","detail":validation_failure_json(failure)}}),
 failure_value=>json!({{"tag":format!("{{:?}}",failure_value).split(['(',' ']).next().unwrap_or("failure"),"detail":format!("{{:?}}",failure_value)}})}}}}
 fn main(){{let generation=initialize().unwrap();let cx=Context::new(&generation);let observations:Vec<execution::ExecutionObservation>=vec![{observations}];let mut index=0usize;let mut progress=vec![];let prepared=match composed::prepare(&generation){{Ok(prepared)=>prepared,Err(composed::PrepareFailure::Preparation(failure))=>{{writeln!(std::io::stdout(),"{{}}",json!({{"case":{json.dumps(case['case'])},"progress":progress,"failure":{{"tag":"preparation","detail":composition_input_failure_json(&failure)}}}})).unwrap();return}},Err(composed::PrepareFailure::CompositionAbsent)=>panic!("composition is absent")}};let mut current=composed::run(&prepared,Host,composed::Arguments{{{args}}},Default::default());loop{{match current{{Err(failure)=>{{writeln!(std::io::stdout(),"{{}}",json!({{"case":{json.dumps(case['case'])},"progress":progress,"failure":failure_json(&failure.cause)}})).unwrap();break}},Ok(composed::RunProgress::Pending(execution,instruction))=>{{progress.push(json!({{"tag":"pending","instruction":match instruction{{execution::NetworkInstruction::Send=>"send",execution::NetworkInstruction::Observe=>"observe"}}}}));current=composed::resume(execution,observations[index].clone());index+=1}},Ok(composed::RunProgress::Completed(result,_))=>{{progress.push(json!({{"tag":"completed"}}));let result=match result{{{result_arms}}};writeln!(std::io::stdout(),"{{}}",json!({{"case":{json.dumps(case['case'])},"progress":progress,"result":result}})).unwrap();break}}}}}}}}
'''


document = json.loads(Path(sys.argv[1]).read_text())
scratch = Path(sys.argv[2])
shutil.rmtree(scratch, ignore_errors=True)
(scratch / "src/bin").mkdir(parents=True)
rendered = {}
rows = []
bins = []
for number, case in enumerate(document["cases"]):
    try:
        exchange = json.loads(case["exchange"])
        source = rendered.get(case["exchange"])
        if source is None:
            source = command([CARGO, "run", "--locked", "--quiet", "--manifest-path", str(MANIFEST), "--bin", "render"], input=case["exchange"])
            rendered[case["exchange"]] = source
        (scratch / "src/bin" / f"case-{number}.rs").write_text(source + runner(exchange, case))
        bins.append((number, case))
    except Exception as failure:
        rows.append({"case": case["case"], "progress": [], "driverFailure": f"{failure.__class__.__name__}: {failure}"})
manifest = f'[package]\nname="generated-execution"\nversion="0.0.0"\nedition="2021"\nautobins=false\n\n[workspace]\n\n[dependencies]\nnecoherence={{path={json.dumps(str(ROOT / "packages/rust/adapter"))}}}\nserde_json={{version="1",features=["arbitrary_precision"]}}\n'
manifest += "".join(f'\n[[bin]]\nname="case-{number}"\npath="src/bin/case-{number}.rs"\n' for number, _ in bins)
(scratch / "Cargo.toml").write_text(manifest)
for number, case in bins:
    try:
        rows.append(json.loads(command([CARGO, "run", "--quiet", "--manifest-path", str(scratch / "Cargo.toml"), "--bin", f"case-{number}"], cwd=ROOT)))
    except Exception as failure:
        rows.append({"case": case["case"], "progress": [], "driverFailure": f"{failure.__class__.__name__}: {failure}"})
print(json.dumps(rows, separators=(",", ":")))
