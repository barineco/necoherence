#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
LEAN_RUNNER = (HERE / "lean_runner.lean").read_text(encoding="utf-8")
NETWORK_FAILURE_JSON = LEAN_RUNNER[
    LEAN_RUNNER.index("private def stageName"):
    LEAN_RUNNER.index("private def failureJson")
].replace("private def", "def")


def command(argv, *, cwd=ROOT):
    result = subprocess.run(argv, cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return result.stdout


def lean_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def type_index(exchange, type_id):
    return next(index for index, node in enumerate(exchange["signatures"]["nodes"]) if node["id"] == type_id)


def raw(exchange, type_id, value):
    index = type_index(exchange, type_id)
    shape = exchange["signatures"]["nodes"][index]["shape"]
    tag = shape["tag"]
    if tag == "Boolean": return f"Generated.Raw{index}.mk {'true' if value else 'false'}"
    if tag == "String": return f"Generated.Raw{index}.mk {lean_string(value)}"
    if tag == "Unit": return f"Generated.Raw{index}.mk"
    if tag == "Array": return f"Generated.Raw{index}.mk [{','.join(raw(exchange, shape['value']['item']['type_id'], item) for item in value)}]"
    if tag == "Product":
        fields = [raw(exchange, field["slot"]["type_id"], value[field["wire_name"]]) for field in shape["value"]["fields"]]
        return f"Generated.Raw{index}.mk {' '.join(f'({field})' for field in fields)} []"
    if tag == "Sealed": return f"Generated.Raw{index}.mk (exact {lean_string(json.dumps(value, separators=(',', ':')))})"
    if tag == "TaggedUnion":
        key = exchange["signatures"]["profile"]["tag"]["key"]
        branch = next((branch for branch in shape["value"]["branches"] if branch["selector"]["tag"] == "InternalTag" and branch["wire_tag"] == value[key]), None)
        branch = branch or next(branch for branch in shape["value"]["branches"] if branch["selector"]["tag"] == "Otherwise")
        branch_index = shape["value"]["branches"].index(branch)
        return f"Generated.Raw{index}.branch{branch_index} ({raw(exchange, branch['target'], value)})"
    raise ValueError(f"unsupported Lean carrier {tag}")


def typed_slot(exchange, contract, value):
    present = raw(exchange, contract["type_id"], value.get("value")) if value["tag"] == "present" else None
    if contract["required"] and not contract["nullable"]: return present
    if not contract["required"] and contract["nullable"]:
        return ".absent" if value["tag"] == "absent" else ".null" if value["tag"] == "null" else f".present ({present})"
    if contract["required"]: return "none" if value["tag"] == "null" else f"some ({present})"
    return "none" if value["tag"] == "absent" else f"some ({present})"


def outcome(exchange, signature, description, fallback=False):
    outcomes = exchange["composition"]["problem"]["signatures"][signature]["outcomes"]
    index = next((index for index, value in enumerate(outcomes) if value["id"] == description["outcome"]), None)
    if index is None and fallback: index = 0
    if index is None: raise ValueError(f"unrepresentable outcome {description['outcome']}")
    supplied = {value["id"]: value["value"] for value in description["outputs"]}
    values = []
    for port in outcomes[index]["value_ports"]:
        value = supplied.get(port["id"])
        if value is None:
            value = {"tag": "null"} if port["contract"]["nullable"] else {"tag": "absent"} if not port["contract"]["required"] else {"tag": "present", "value": False}
        values.append(typed_slot(exchange, port["contract"], value))
    return f"Generated.Outcome{signature}.k{index}" + (" " + " ".join(f"({value})" for value in values) if values else "")


def attempt(value):
    return f'''({{ attempt := {{ logical := {{ kind := "semantic", provenance := {lean_string(value.get("provenance", "comparison"))}, revision := 1 }}, ordinal := {value.get("ordinal", 0)} }}, instruction := {{ method := {lean_string(value["method"])}, target := {lean_string(value["target"])}, headers := [], body := [] }}, deadline := none, configuration := {{ requestBodyLimit := 1024, responseBodyLimit := 1024, cancellation := none, monotonicClock := none }} }} : AttemptInput)'''


def providers(exchange, case):
    fields = []
    for description in case["providers"]:
        signature = description.get("signature", 0)
        if description["effect"] == "pure":
            fields.append(f"call{signature} := fun _ => pure ({outcome(exchange, signature, description)})")
            continue
        prepared = description["prepare"][0]
        if prepared["tag"] == "ready":
            prepared_code = f"pure (.ready ({attempt(prepared['request'])}))"
        else:
            definition = exchange["composition"]["problem"]["signatures"][signature]["form"]["value"]
            prepared_code = f"do\n            let some contract := outcomeContract {lean_string(definition)} {lean_string(prepared['outcome'])} | throw (.invalidPlan \"outcome contract\")\n            pure (.completed contract ({outcome(exchange, signature, prepared, True)}))"
        decodes = []
        for row in description["decode"]:
            returned = f"throw (.provider ⟨\"operation\"⟩ {lean_string(row['failure']['message'])})" if "failure" in row else f"pure ({outcome(exchange, signature, row)})"
            decodes.append(f"if response.status == {row['status']} then {returned}")
        decode = " else ".join(decodes) + " else throw (.provider ⟨\"operation\"⟩ \"missing decode behavior\")"
        declared = exchange["composition"]["problem"]["signatures"][signature]["outcomes"]
        arms = " | ".join(f".k{index} _ => {lean_string(value['id'])}" for index, value in enumerate(declared))
        claimed = prepared.get("outcome")
        outcome_id = lean_string(claimed) if claimed and not any(value["id"] == claimed for value in declared) else f"fun | {arms}"
        if outcome_id.startswith("fun"):
            outcome_id_code = outcome_id
        else:
            outcome_id_code = f"fun _ => {outcome_id}"
        fields.append(f'''call{signature} := {{
          transport := {{ encode := fun _ => pure ({attempt(prepared.get("request", {"method":"GET","target":"http://127.0.0.1/execution"}))}), decode := fun response => {decode} }},
          prepare := fun _ => {prepared_code}, outcomeId := {outcome_id_code} }}''')
    return "{ " + ", ".join(fields) + " }"


def observation(case, value):
    ready = [row for provider in case["providers"] for row in provider.get("prepare", []) if row["tag"] == "ready"]
    request = attempt(ready[value.get("request", 0)]["request"])
    handle = lean_string(value.get("handle", "handle"))
    if value["tag"] == "start" and value.get("kind") == "started":
        return f".start (.Started ({request}).attempt ⟨{handle}⟩)"
    if value["tag"] == "start":
        return f".start (.StartFailed {{ attempt := ({request}).attempt, stage := .Start, configuration := ({request}).configuration, cause := .ExecutionStartFailed }} (.Unknown .NoResponse))"
    return f".host (.Delivered {value.get('delivery', 0)} (.ResponseObservation ({request}).attempt ⟨{handle}⟩ .none {{ status := {value['status']}, headers := [], body := [] }} .LibraryNormalized (.Unknown .NoResponse)))"


def slot_json(exchange, expression, contract):
    index = type_index(exchange, contract["type_id"])
    present = f"slotPresent (Generated.encodeJson{index} {expression})"
    if contract["required"] and not contract["nullable"]: return present
    if not contract["required"] and contract["nullable"]: return f"match {expression} with | .absent => slotTag \"absent\" | .null => slotTag \"null\" | .present value => slotPresent (Generated.encodeJson{index} value)"
    if contract["required"]: return f"match {expression} with | none => slotTag \"null\" | some value => slotPresent (Generated.encodeJson{index} value)"
    return f"match {expression} with | none => slotTag \"absent\" | some value => slotPresent (Generated.encodeJson{index} value)"


def runner(exchange, case, exchange_path):
    problem = exchange["composition"]["problem"]
    arguments = {value["id"]: value["value"] for value in case["arguments"]}
    argument_fields = []
    for index, initial in enumerate(problem["initial_inputs"]):
        if initial["source"]["tag"] == "Argument":
            argument_fields.append(f"argument{index} := {typed_slot(exchange, initial['contract'], arguments[initial['id']])}")
    outcomes = []
    goals = problem["goal"]["outputs"]
    success_values = [f"Json.arr #[.str {lean_string(goal['id'])}, {slot_json(exchange, f'value.{index + 1}', goal['contract'])}]" for index, goal in enumerate(goals)]
    success_pattern = "value" if len(goals) != 1 else "value"
    success_expression = slot_json(exchange, "value", goals[0]["contract"])
    outcomes.append(f"| .success value => obj [(\"tag\", .str \"success\"), (\"outcome\", .arr #[.arr #[.str {lean_string(goals[0]['id'])}, {success_expression}]])] ")
    for index, failure in enumerate(problem["goal"]["failures"]):
        outcomes.append(f"| .failure{index} value => obj [(\"tag\", .str \"failure\"), (\"embedding\", .str {lean_string(failure['id'])}), (\"value\", {slot_json(exchange, 'value', failure['contract'])})]")
    observations = ",".join(observation(case, value) for value in case["observations"])
    return f'''

open Lean Necoherence Necoherence.SemanticExecution Necoherence.SemanticTypes Necoherence.SemanticValidation Necoherence.SemanticComposition Necoherence.TypeSignatures
def obj (members : List (String × Json)) : Json := Json.mkObj members
def exact (wire : String) : Necoherence.ExactJson.JsonValue := Necoherence.ExactJson.fromJson ((Json.parse wire).toOption.getD .null)
def slotTag (tag : String) : Json := obj [("tag", .str tag)]
def slotPresent (value : Except String Json) : Json := obj [("tag", .str "present"), ("value", value.toOption.getD .null)]
def nestedFailure (constructor : String) (arguments : List Json := []) : Json :=
  obj [("constructor", .str constructor), ("arguments", .arr arguments.toArray)]
def semanticReasonJson : SemanticReason → Json
  | .unknownFormat name => nestedFailure "unknownFormat" [.str name]
  | .missingGraphemeRules => nestedFailure "missingGraphemeRules"
  | .missingBytesPolicy => nestedFailure "missingBytesPolicy"
  | .unknownIntegerDomain name => nestedFailure "unknownIntegerDomain" [.str name]
  | .unknownWrapper name => nestedFailure "unknownWrapper" [.str name]
  | .wrapperPayload name => nestedFailure "wrapperPayload" [.str name]
  | .unknownSealedTag tag => nestedFailure "unknownSealedTag" [.str tag]
  | .decimalNotAdmitted => nestedFailure "decimalNotAdmitted"
  | .integerBound => nestedFailure "integerBound"
  | .opaqueType name => nestedFailure "opaqueType" [.str name]
  | .missingTagModel => nestedFailure "missingTagModel"
  | .uninterpretedExtension key => nestedFailure "uninterpretedExtension" [.str key]
  | .unresolvedType => nestedFailure "unresolvedType"
  | .invalidProfile condition => nestedFailure "invalidProfile" [.str condition]
  | .membershipBound => nestedFailure "membershipBound"
  | .certificateMismatch condition => nestedFailure "certificateMismatch" [.str condition]
  | .projectionUnavailable condition => nestedFailure "projectionUnavailable" [.str condition]
def sourceRefJson (source : SourceRef) : Json := obj [
  ("repository", .str source.repository), ("revision", .str source.revision),
  ("path", .str source.path), ("contentDigest", .str source.contentDigest),
  ("documentId", .str source.documentId),
  ("declaredRevision", match source.declaredRevision with | none => .null | some value => .str (toString value))]
def typeRefJson (reference : TypeRef) : Json := obj [
  ("source", sourceRefJson reference.source), ("definitionName", .str reference.definitionName),
  ("pointer", .arr (reference.pointer.map Json.str).toArray)]
def occurrenceRefJson (reference : OccurrenceRef) : Json := obj [
  ("source", sourceRefJson reference.source), ("pointer", .arr (reference.pointer.map Json.str).toArray)]
def pathJson (path : ValuePath) : Json := .arr (path.map (fun
  | .field name => nestedFailure "field" [.str name]
  | .index index => nestedFailure "index" [.str (toString index)]
  | .variant tag => nestedFailure "variant" [.str tag])).toArray
def valueTypeRefJson (reference : TypeRef) : Json := obj [
  ("source", sourceRefJson reference.source), ("definition", .str reference.definitionName),
  ("pointer", .arr (reference.pointer.map Json.str).toArray)]
def valuePathJson (path : ValuePath) : Json := .arr (path.map (fun
  | .field name => obj [("field", .str name)]
  | .index index => obj [("index", toJson index)]
  | .variant tag => obj [("variant", .str tag)])).toArray
def semanticObligationJson (obligation : SemanticObligation) : Json := obj [
  ("typeRef", valueTypeRefJson obligation.typeRef), ("valuePath", valuePathJson obligation.valuePath),
  ("reason", semanticReasonJson obligation.reason)]
def valueFailureJson (failure : ValueFailure) : Json := obj [
  ("typeRef", valueTypeRefJson failure.typeRef),
  ("definitionRef", obj [("source", sourceRefJson failure.definitionRef.source), ("name", .str failure.definitionRef.name)]),
  ("origin", occurrenceRefJson failure.origin), ("valuePath", valuePathJson failure.valuePath),
  ("condition", Necoherence.SignatureWire.encode failure.condition),
  ("observed", Necoherence.SignatureWire.encode failure.observed),
  ("referenceTrace", .arr (failure.referenceTrace.map valueTypeRefJson).toArray)]
def validationFailureJson : ValidationFailure → Json
  | .value failure => nestedFailure "value" [valueFailureJson failure]
  | .unresolved obligations => nestedFailure "unresolved" [.arr (obligations.map semanticObligationJson).toArray]
  | .certificateMismatch condition => nestedFailure "certificateMismatch" [.str condition]
def producerRefJson : ProducerRef → Json
  | .initial id => nestedFailure "initial" [.str id.value]
  | .invocationOutcome site outcome port => nestedFailure "invocationOutcome" [.str site.value, .str outcome.value, .str port.value]
def valueRefJson (reference : ValueRef) : Json := obj [
  ("producer", producerRefJson reference.producer), ("path", pathJson reference.path)]
def typeObligationReasonJson : TypeObligationReason → Json
  | .meaning obligations => nestedFailure "meaning" [.arr (obligations.map semanticObligationJson).toArray]
  | .constraintImplication => nestedFailure "constraintImplication"
  | .presence => nestedFailure "presence"
  | .unionRemainder => nestedFailure "unionRemainder"
  | .extraField name => nestedFailure "extraField" [.str name]
  | .inhabitation => nestedFailure "inhabitation"
  | .obligationBoundExhausted => nestedFailure "obligationBoundExhausted"
def slotContractJson (contract : SlotContract) : Json := obj [
  ("typeRef", typeRefJson contract.typeRef), ("required", .bool contract.required),
  ("nullable", .bool contract.nullable)]
def typeObligationJson (obligation : TypeObligation) : Json := obj [
  ("pair", obj [("source", slotContractJson obligation.pair.source),
    ("destination", slotContractJson obligation.pair.destination)]),
  ("path", pathJson obligation.path), ("reason", typeObligationReasonJson obligation.reason)]
def inclusionFailureJson : InclusionFailure → Json
  | .basisMismatch => nestedFailure "basisMismatch"
  | .contractMismatch => nestedFailure "contractMismatch"
  | .undefinedMeaning obligations => nestedFailure "undefinedMeaning" [.arr (obligations.map semanticObligationJson).toArray]
  | .missingPair => nestedFailure "missingPair"
  | .pairMismatch index => nestedFailure "pairMismatch" [.str (toString index)]
  | .ruleMismatch index => nestedFailure "ruleMismatch" [.str (toString index)]
  | .childCoverage index => nestedFailure "childCoverage" [.str (toString index)]
  | .forgedEmptiness => nestedFailure "forgedEmptiness"
  | .counterexampleMismatch => nestedFailure "counterexampleMismatch"
  | .unresolved obligation => nestedFailure "unresolved" [typeObligationJson obligation]
def projectionFailureJson : ProjectionFailure → Json
  | .wrongShape reference path => nestedFailure "wrongShape" [typeRefJson reference, pathJson path]
  | .missingField reference name => nestedFailure "missingField" [typeRefJson reference, .str name]
  | .missingVariant reference tag => nestedFailure "missingVariant" [typeRefJson reference, .str tag]
  | .branchAssumptionRequired path tag => nestedFailure "branchAssumptionRequired" [pathJson path, .str tag]
  | .variantSelectionUndetermined path tag => nestedFailure "variantSelectionUndetermined" [pathJson path, .str tag]
  | .unresolved obligations => nestedFailure "unresolved" [.arr (obligations.map semanticObligationJson).toArray]
  | .certificateMismatch condition => nestedFailure "certificateMismatch" [.str condition]
def functionRefJson (reference : FunctionRef) : Json := obj [("identity", .str reference.identity), ("revision", .str reference.revision), ("contentDigest", .str reference.contentDigest)]
def profileRefJson (reference : ProfileRef) : Json := obj [("identity", .str reference.identity), ("revision", .str reference.revision), ("contentDigest", .str reference.contentDigest)]
def profilePredicateCode : Necoherence.SemanticTypes.ProfilePredicate → String
  | .pr01 => "pr01" | .pr02 => "pr02" | .pr03 => "pr03" | .pr04 => "pr04"
  | .pr05 => "pr05" | .pr06 => "pr06" | .pr07 => "pr07" | .pr08 => "pr08"
  | .pr09 => "pr09" | .pr10 => "pr10" | .pr11 => "pr11" | .pr12 => "pr12"
  | .pr13 => "pr13" | .pr14 => "pr14" | .pr15 => "pr15" | .pr16 => "pr16"
def libraryPredicateCode : Necoherence.TypeSignatures.LibraryPredicate → String
  | .lb01 => "lb01" | .lb02 => "lb02" | .lb03 => "lb03" | .lb04 => "lb04"
  | .lb05 => "lb05" | .lb06 => "lb06" | .lb07 => "lb07" | .lb08 => "lb08"
  | .lb09 => "lb09" | .lb10 => "lb10" | .lb11 => "lb11" | .lb12 => "lb12"
  | .lb13 => "lb13" | .lb14 => "lb14" | .lb15 => "lb15" | .lb16 => "lb16"
  | .lb17 => "lb17" | .lb18 => "lb18" | .lb19 => "lb19"
def libraryCheckFailureJson : Necoherence.TypeSignatures.LibraryCheckFailure → Json
  | .profile failure => nestedFailure "profile" [profileRefJson failure.reference, .str (profilePredicateCode failure.predicate), toJson failure.location]
  | .library failure => nestedFailure "library" [toJson failure.reference, .str (libraryPredicateCode failure.predicate), toJson failure.location]
def compositionInputFailureJson : CompositionInputFailure → Json
  | .basisMismatch => nestedFailure "basisMismatch"
  | .duplicateIdentity kind identity => nestedFailure "duplicateIdentity" [.str kind, .str identity]
  | .unresolvedType reference => nestedFailure "unresolvedType" [typeRefJson reference]
  | .unresolvedFunction reference => nestedFailure "unresolvedFunction" [functionRefJson reference]
  | .invalidSignature reference reason => nestedFailure "invalidSignature" [functionRefJson reference, .str reason]
  | .invalidInitialValue id failure => nestedFailure "invalidInitialValue" [.str id.value, valueFailureJson failure]
  | .siteEffectNotPermitted site effect => nestedFailure "siteEffectNotPermitted" [.str site.value, Necoherence.SignatureWire.encode effect]
  | .transformNotPermitted reference => nestedFailure "transformNotPermitted" [functionRefJson reference]
  | .emptyGoal => nestedFailure "emptyGoal"
  | .goalSourceConstraintUndefined port constraint => nestedFailure "goalSourceConstraintUndefined" [.str port.value, Necoherence.SignatureWire.encode constraint]
  | .failureEmbeddingOriginUndefined embedding origin => nestedFailure "failureEmbeddingOriginUndefined" [.str embedding.value, Necoherence.SignatureWire.encode origin]
  | .constructionNotProduct identity reference => nestedFailure "constructionNotProduct" [.str identity, typeRefJson reference]
  | .fieldConstraintUnknownField identity field => nestedFailure "fieldConstraintUnknownField" [.str identity, .str field]
  | .constrainedNestedField identity field => nestedFailure "constrainedNestedField" [.str identity, .str field]
  | .constructionFieldSourceUndefined identity constraint => nestedFailure "constructionFieldSourceUndefined" [.str identity, Necoherence.SignatureWire.encode constraint]
  | .nestedFieldUndeclared identity field => nestedFailure "nestedFieldUndeclared" [.str identity, .str field]
  | .nestedConstructionMismatch identity field target reference => nestedFailure "nestedConstructionMismatch" [.str identity, .str field, .str target, typeRefJson reference]
  | .cyclicConstruction identity => nestedFailure "cyclicConstruction" [.str identity]
  | .explicitSiteOrderInvalid before after => nestedFailure "explicitSiteOrderInvalid" [.str before.value, .str after.value]
  | .invalidEmptyTypeClosure failure => nestedFailure "invalidEmptyTypeClosure" [inclusionFailureJson failure]
  | .invalidResourceDeclaration reason => nestedFailure "invalidResourceDeclaration" [.str reason]
  | .invalidLibrary failure => nestedFailure "invalidLibrary" [libraryCheckFailureJson failure]
def witnessFailureJson : WitnessFailure → Json
  | .inputRevisionMismatch => nestedFailure "inputRevisionMismatch"
  | .initialMembership id => nestedFailure "initialMembership" [.str id.value]
  | .producerMismatch reference => nestedFailure "producerMismatch" [valueRefJson reference]
  | .projectionMismatch failure => nestedFailure "projectionMismatch" [projectionFailureJson failure]
  | .sourceConstraintMismatch reference => nestedFailure "sourceConstraintMismatch" [valueRefJson reference]
  | .inclusion failure => nestedFailure "inclusion" [inclusionFailureJson failure]
  | .suppliedValueMismatch reference => nestedFailure "suppliedValueMismatch" [valueRefJson reference]
  | .constructionMismatch reference => nestedFailure "constructionMismatch" [typeRefJson reference]
  | .missingBinding identity => nestedFailure "missingBinding" [.str identity]
  | .signatureMismatch site => nestedFailure "signatureMismatch" [.str site.value]
  | .guardNotDominating reference => nestedFailure "guardNotDominating" [valueRefJson reference]
  | .incompleteBranchCoverage identity => nestedFailure "incompleteBranchCoverage" [.str identity]
  | .failureEmbeddingMismatch id => nestedFailure "failureEmbeddingMismatch" [.str id.value]
  | .goalMismatch => nestedFailure "goalMismatch"
  | .rankViolation => nestedFailure "rankViolation"
  | .resourceLoweringMismatch reason => nestedFailure "resourceLoweringMismatch" [.str reason]
  | .resourceReplayMismatch reason => nestedFailure "resourceReplayMismatch" [.str reason]
  | .forgedClosure reason => nestedFailure "forgedClosure" [.str reason]
  | .forgedAcyclicity reason => nestedFailure "forgedAcyclicity" [.str reason]
  | .missingEvidence reason => nestedFailure "missingEvidence" [.str reason]
{NETWORK_FAILURE_JSON}
def failureJson : ExecutionFailure → Json
  | .value failure => obj [("tag",.str "value"),("detail",validationFailureJson failure)]
  | .provider site message => obj [("tag",.str "provider"),("site",.str site.value),("message",.str message)]
  | .invalidPlan condition => obj [("tag",.str "invalidPlan"),("condition",.str condition)]
  | .network failure => obj [("tag",.str "network"),("detail",networkFailureJson failure)]
  | .networkTerminal terminal =>
    let stageName : HostStage → String := fun | .Start => "Start" | .RequestWrite => "RequestWrite" | .ResponseHeaders => "ResponseHeaders" | .ResponseBody => "ResponseBody" | .Cancel => "Cancel" | .Deadline => "Deadline"
    let hostFailureName : HostFailure → String := fun | .UnsupportedUriScheme => "UnsupportedUriScheme" | .InvalidHostConfiguration => "InvalidHostConfiguration" | .ExecutionStartFailed => "ExecutionStartFailed" | .NameResolutionFailed => "NameResolutionFailed" | .ConnectionFailed => "ConnectionFailed" | .RequestWriteFailed => "RequestWriteFailed" | .ResponseHeadersFailed => "ResponseHeadersFailed" | .ResponseBodyFailed => "ResponseBodyFailed" | .ResponseBodyLimitExceeded => "ResponseBodyLimitExceeded" | .MalformedResponse => "MalformedResponse" | .HeaderRepresentationUnavailable => "HeaderRepresentationUnavailable" | .RequestHeaderEncodingUnavailable => "RequestHeaderEncodingUnavailable" | .CancellationRejected => "CancellationRejected" | .DeadlineControlUnavailable => "DeadlineControlUnavailable" | .Timeout _ _ => "Timeout" | .HostRuntimeFailure => "HostRuntimeFailure" | .HostClosed => "HostClosed"
    let reasonName : UnknownEffectReason → String := fun | .NoResponse => "NoResponse" | .Cancellation => "Cancellation" | .Deadline => "Deadline" | .HostFailure => "HostFailure" | .ProtocolWitnessMissing => "ProtocolWitnessMissing" | .LateSignal => "LateSignal"
    let (outcome,stage,cause) : String × Json × Json := match terminal.outcome with | .Failed failure => ("Failed",Json.str (stageName failure.stage),Json.str (hostFailureName failure.cause)) | .Response _ _ => ("Response",Json.null,Json.null) | .Cancelled => ("Cancelled",Json.null,Json.null) | .DeadlineExceeded _ _ => ("DeadlineExceeded",Json.null,Json.null)
    let (effect,reason) : String × Json := match terminal.effect with | .NoEffect _ => ("NoEffect",Json.null) | .EffectOccurred _ => ("EffectOccurred",Json.null) | .Unknown reason => ("Unknown",Json.str (reasonName reason))
    obj [("tag",.str "networkTerminal"),("outcome",.str outcome),("stage",stage),("cause",cause),("effect",.str effect),("reason",reason)]
  | value => obj [("tag",.str "generatedFailure"),("detail",.str (reprStr value))]
def resultJson : Generated.Result → Json
  {' '.join(outcomes)}
partial def drive (progress : List Json) (observations : List ExecutionObservation) : Except RunFailure Generated.RunProgress → Json
  | .error failure => obj [("case",.str {lean_string(case['case'])}),("progress",.arr progress.toArray),("failure",failureJson failure.cause)]
  | .ok (.completed result _) => obj [("case",.str {lean_string(case['case'])}),("progress",.arr (progress ++ [obj [("tag",.str "completed")]]).toArray),("result",resultJson result)]
  | .ok (.pending execution instruction) => match observations with
    | [] => obj [("case",.str {lean_string(case['case'])}),("progress",.arr progress.toArray),("driverFailure",.str "observation required")]
    | observed :: rest =>
      let item := obj [("tag",.str "pending"),("instruction",.str (match instruction with | .send _ => "send" | .observe _ => "observe"))]
      drive (progress ++ [item]) rest (Generated.resume execution observed)
def start (progress : List Json) (observations : List ExecutionObservation) : Except Generated.StartFailure Generated.RunProgress → Json
  | .error (.preparation failure) => obj [("case",.str {lean_string(case['case'])}),("progress",.arr progress.toArray),("failure",obj [("tag",.str "preparation"),("detail",compositionInputFailureJson failure)])]
  | .error (.composition failure) => obj [("case",.str {lean_string(case['case'])}),("progress",.arr progress.toArray),("failure",obj [("tag",.str "composition"),("detail",witnessFailureJson failure)])]
  | .error (.execution failure) => obj [("case",.str {lean_string(case['case'])}),("progress",.arr progress.toArray),("failure",failureJson failure.cause)]
  | .ok value => drive progress observations (.ok value)
def main : IO UInt32 := do
  let .ok input := Necoherence.SignatureGeneration.decodeInput (← IO.FS.readFile {lean_string(str(exchange_path))}) | throw (IO.userError "exchange")
  let outcomeContract : String → String → Option Necoherence.TypeSignatures.OutcomeContract := fun definition identity => do
    let declared ← input.signatures.definitions.find? (fun value => value.id == definition)
    let .operation operation := declared.shape | none
    match operation.outcomes.find? (fun value => value.id == identity) with
    | some outcome => some outcome
    | none => operation.outcomes.head?
  let providers : Generated.Providers := {providers(exchange, case)}
  let arguments : Generated.Arguments := {{ {', '.join(argument_fields)} }}
  let row := start [] [{observations}] (Generated.run providers arguments {{ attempts := [] }})
  IO.println row.compress
  return 0
'''


document = json.loads(Path(sys.argv[1]).read_text())
scratch = Path(sys.argv[2]); scratch.mkdir(parents=True, exist_ok=True)
rows = []
for number, case in enumerate(document["cases"]):
    try:
        exchange = json.loads(case["exchange"])
        exchange_path = scratch / f"case-{number}.json"
        exchange_path.write_text(case["exchange"])
        rendered = command(["lake", "env", "lean", "--run", str(HERE / "generated_lean_render.lean"), str(exchange_path)], cwd=ROOT / "generator/lean")
        source = scratch / f"case-{number}.lean"
        source.write_text("import Necoherence.SignatureGeneration\n" + rendered + runner(exchange, case, exchange_path))
        output = command(["lake", "env", "lean", "--run", str(source)], cwd=ROOT / "generator/lean")
        rows.append(json.loads(output.splitlines()[-1]))
    except Exception as failure:
        rows.append({"case": case["case"], "progress": [], "driverFailure": f"{failure.__class__.__name__}: {failure}"})
print(json.dumps(rows, separators=(",", ":")))
