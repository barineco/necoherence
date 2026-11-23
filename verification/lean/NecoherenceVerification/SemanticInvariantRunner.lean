-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import NecoherenceGenerator.SignatureGeneration
import NecoherenceGenerator.SemanticRenderer
import NecoherenceVerification.SemanticInvariantOutput
import NecoherenceCompositionSolver.CompositionSearch
import NecoherenceVerification.SemanticReferenceWire

namespace NecoherenceTools.SemanticInvariantRunner
open Lean Necoherence Necoherence.SemanticTypes Necoherence.SemanticValidation Necoherence.SemanticComposition Necoherence.SignatureWire Necoherence.SemanticInvariantDerivation
open NecoherenceTools.SemanticInvariantOutput NecoherenceTools.CompositionSearch NecoherenceTools.SemanticReferenceWire
set_option maxRecDepth 10000
set_option maxHeartbeats 0

inductive RunnerFailure where
  | wire (failure : WireFailure)
  | libraryCheck (failure : Necoherence.TypeSignatures.LibraryCheckFailure)
  | validation (failure : Necoherence.SemanticValidation.ValidationFailure)
  | compositionInput (failure : Necoherence.SemanticComposition.CompositionInputFailure)
  | compositionEngine (failure : Necoherence.SemanticComposition.CompositionEngineFailure)
  | inclusion (failure : Necoherence.SemanticComposition.InclusionFailure)
  | admission (failure : Necoherence.SignatureGeneration.AdmissionFailure)
  | generation (failure : NecoherenceTools.SignatureGeneration.GenerationFailure)
  | renderer (failure : NecoherenceTools.SemanticRenderer.GenerationFailure)
  deriving Repr

instance : MonadLift (Except WireFailure) (Except RunnerFailure) := ⟨Except.mapError RunnerFailure.wire⟩
instance : Coe (Except String α) (Except RunnerFailure α) := ⟨fun result => (liftJson result).mapError RunnerFailure.wire⟩


def sourceRefJson (source : SourceRef) : Json :=
  Json.mkObj [
      ("repository", .str source.repository),
      ("revision", .str source.revision),
      ("path", .str source.path),
      ("content_digest", .str source.contentDigest),
      ("document_id", .str source.documentId),
      ("declared_revision", encode source.declaredRevision)]

def typeRefJson (reference : TypeRef) : Json :=
  Json.mkObj [
    ("source", sourceRefJson reference.source),
    ("definition_name", .str reference.definitionName),
    ("pointer", encode reference.pointer)]

def semanticReasonJson (json : Json) : Except WireFailure SemanticReason := do
  let tuple (build : String → SemanticReason) : Except WireFailure SemanticReason := do
    keys json ["tag", "value"]
    return build (← get json "value")
  let unit (reason : SemanticReason) : Except WireFailure SemanticReason := do
    keys json ["tag"]
    return reason
  match ← get (α := String) json "tag" with
  | "UnknownFormat" => tuple .unknownFormat
  | "MissingGraphemeRules" => unit .missingGraphemeRules
  | "MissingBytesPolicy" => unit .missingBytesPolicy
  | "UnknownIntegerDomain" => tuple .unknownIntegerDomain
  | "UnknownWrapper" => tuple .unknownWrapper
  | "WrapperPayload" => tuple .wrapperPayload
  | "UnknownSealedTag" => tuple .unknownSealedTag
  | "DecimalNotAdmitted" => unit .decimalNotAdmitted
  | "IntegerBound" => unit .integerBound
  | "OpaqueType" => tuple .opaqueType
  | "MissingTagModel" => unit .missingTagModel
  | "UninterpretedExtension" => tuple .uninterpretedExtension
  | "UnresolvedType" => unit .unresolvedType
  | "InvalidProfile" => tuple .invalidProfile
  | "MembershipBound" => unit .membershipBound
  | "CertificateMismatch" => tuple .certificateMismatch
  | "ProjectionUnavailable" => tuple .projectionUnavailable
  | tag => throw (WireFailure.unknownTag "$.tag" tag)

def semanticReasonEncode (reason : SemanticReason) : Json :=
  let (tag, value) := match reason with
    | .unknownFormat name => ("UnknownFormat", some name)
    | .missingGraphemeRules => ("MissingGraphemeRules", none)
    | .missingBytesPolicy => ("MissingBytesPolicy", none)
    | .unknownIntegerDomain name => ("UnknownIntegerDomain", some name)
    | .unknownWrapper name => ("UnknownWrapper", some name)
    | .wrapperPayload name => ("WrapperPayload", some name)
    | .unknownSealedTag name => ("UnknownSealedTag", some name)
    | .decimalNotAdmitted => ("DecimalNotAdmitted", none)
    | .integerBound => ("IntegerBound", none)
    | .opaqueType name => ("OpaqueType", some name)
    | .missingTagModel => ("MissingTagModel", none)
    | .uninterpretedExtension name => ("UninterpretedExtension", some name)
    | .unresolvedType => ("UnresolvedType", none)
    | .invalidProfile name => ("InvalidProfile", some name)
    | .membershipBound => ("MembershipBound", none)
    | .certificateMismatch name => ("CertificateMismatch", some name)
    | .projectionUnavailable name => ("ProjectionUnavailable", some name)
  Json.mkObj ([("tag", .str tag)] ++ value.toList.map (fun value => ("value", .str value)))

def semanticObligationDecode (json : Json) : Except WireFailure SemanticObligation := do
  keys json ["type_ref", "origin", "value_path", "profile", "reason"]
  pure {
    typeRef := ← getWith typeRefDecode json "type_ref"
    origin := ← getWith occurrenceRefDecode json "origin"
    valuePath := ← get json "value_path"
    profile := ← get json "profile"
    reason := ← getWith semanticReasonJson json "reason" }

def semanticObligationEncode (reason : SemanticObligation) : Json :=
  Json.mkObj [("type_ref", typeRefJson reason.typeRef),
    ("origin", Json.mkObj [("source", sourceRefJson reason.origin.source), ("pointer", encode reason.origin.pointer)]),
    ("value_path", encode reason.valuePath), ("profile", encode reason.profile), ("reason", semanticReasonEncode reason.reason)]

def evaluationProvenanceDecode (json : Json) : Except WireFailure EvaluationProvenance := do
  keys json ["operation", "type_ref", "value_path"]
  pure { operation := ← get json "operation", typeRef := ← getWith typeRefDecode json "type_ref", valuePath := ← get json "value_path" }

def evaluationProvenanceEncode (value : EvaluationProvenance) : Json :=
  Json.mkObj [("operation", encode value.operation), ("type_ref", typeRefJson value.typeRef), ("value_path", encode value.valuePath)]

def compositionProvenanceDecode (json : Json) : Except WireFailure CompositionProvenance := do
  keys json ["operation", "input_identity", "input_revision"]
  pure { operation := ← get json "operation", inputIdentity := ← get json "input_identity", inputRevision := ← get json "input_revision" }

def compositionProvenanceEncode (value : CompositionProvenance) : Json :=
  Json.mkObj [("operation", encode value.operation), ("input_identity", encode value.inputIdentity), ("input_revision", encode value.inputRevision)]

def jsonArray (json : Json) (key : String) (decoder : Json → Except WireFailure α) : Except WireFailure (List α) :=
  getWith (decodeListWith decoder) json key

def typeReasonDecode (json : Json) : Except WireFailure TypeObligationReason := do
  let unit (reason : TypeObligationReason) : Except WireFailure TypeObligationReason := do
    keys json ["tag"]
    return reason
  match ← get (α := String) json "tag" with
  | "Meaning" => keys json ["tag", "value"]; return .meaning (← jsonArray json "value" semanticObligationDecode)
  | "ConstraintImplication" => unit .constraintImplication
  | "Presence" => unit .presence
  | "UnionRemainder" => unit .unionRemainder
  | "Inhabitation" => unit .inhabitation
  | "ExtraField" => keys json ["tag", "value"]; return .extraField (← get json "value")
  | "ObligationBoundExhausted" => unit .obligationBoundExhausted
  | tag => throw (.unknownTag "$.tag" tag)

def typeReasonEncode : TypeObligationReason → Json
  | .meaning reasons => Json.mkObj [("tag", .str "Meaning"), ("value", .arr (reasons.map semanticObligationEncode).toArray)]
  | .extraField name => Json.mkObj [("tag", .str "ExtraField"), ("value", .str name)]
  | reason => Json.mkObj [("tag", .str (match reason with
    | .constraintImplication => "ConstraintImplication" | .presence => "Presence"
    | .unionRemainder => "UnionRemainder" | .inhabitation => "Inhabitation"
    | .obligationBoundExhausted => "ObligationBoundExhausted" | _ => ""))]

def fullSlotEncode (value : SlotContract) : Json :=
  Json.mkObj [("type_ref", typeRefJson value.typeRef), ("required", encode value.required), ("nullable", encode value.nullable)]

def typeObligationDecode (json : Json) : Except WireFailure TypeObligation := do
  keys json ["source", "destination", "reason"]
  let source ← getWith typeRefDecode json "source"
  let destination ← getWith typeRefDecode json "destination"
  pure {
    pair := { source := { typeRef := source, required := true, nullable := false }, destination := { typeRef := destination, required := true, nullable := false } }
    path := []
    reason := ← getWith typeReasonDecode json "reason" }

def typeObligationRowDecode (json : Json) : Except WireFailure (Option ValueRef × List TypeObligation) := do
  keys json ["value", "obligations"]
  pure (← get json "value", ← jsonArray json "obligations" typeObligationDecode)

def inhabitationRowDecode (json : Json) : Except WireFailure (ProducerRef × SlotContract) := do
  keys json ["producer", "contract"]
  pure (← get json "producer", ← getWith slotContractDecode json "contract")

def resourceCapacityRowDecode (json : Json) : Except WireFailure (Nat × Nat) := do
  keys json ["required", "limit"]
  pure (← get json "required", ← get json "limit")

def resourceSolverReasonDecode (json : Json) : Except WireFailure Necoherence.UnknownReason := do
  match ← get (α := String) json "tag" with
  | "BindingBoundExhausted" => keys json ["tag", "value"]; return .bindingBoundExhausted (← get json "value")
  | "SearchStepBoundExhausted" => keys json ["tag", "value"]; return .searchStepBoundExhausted (← get json "value")
  | tag => throw (.unknownTag "$.tag" tag)

def compositionObligationDecode (json : Json) : Except WireFailure UnresolvedObligation := do
  let unit (reason : UnresolvedObligation) : Except WireFailure UnresolvedObligation := do
    keys json ["tag"]
    return reason
  match ← get (α := String) json "tag" with
  | "Meaning" => keys json ["tag", "value"]; return .meaning (← jsonArray json "value" semanticObligationDecode)
  | "Type" =>
    keys json ["tag", "fields"]
    let (value, reasons) ← getWith typeObligationRowDecode json "fields"
    return .type value reasons
  | "Inhabitation" =>
    keys json ["tag", "fields"]
    let (producer, contract) ← getWith inhabitationRowDecode json "fields"
    return .inhabitation producer contract
  | "BranchInhabitation" => unit .branchInhabitation
  | "UnresolvedUniqueness" => unit .unresolvedUniqueness
  | "StateBoundExhausted" => unit .stateBoundExhausted
  | "BindingBoundExhausted" => unit .bindingBoundExhausted
  | "BranchBoundExhausted" => unit .branchBoundExhausted
  | "ResourceCapacityBound" =>
    keys json ["tag", "fields"]
    let (required, limit) ← getWith resourceCapacityRowDecode json "fields"
    return .resourceCapacityBound required limit
  | "ResourceSolverUnknown" =>
    keys json ["tag", "value"]
    return .resourceSolverUnknown (← getWith resourceSolverReasonDecode json "value")
  | tag => throw (.unknownTag "$.tag" tag)

def compositionObligationEncode : UnresolvedObligation → Json
  | .meaning reasons => Json.mkObj [("tag", .str "Meaning"), ("value", .arr (reasons.map semanticObligationEncode).toArray)]
  | .type value reasons => Json.mkObj [("tag", .str "Type"), ("fields", Json.mkObj [("value", encode value),
      ("obligations", .arr (reasons.map fun item => Json.mkObj [("source", typeRefJson item.pair.source.typeRef),
        ("destination", typeRefJson item.pair.destination.typeRef), ("reason", typeReasonEncode item.reason)]).toArray)])]
  | .inhabitation producer contract => Json.mkObj [("tag", .str "Inhabitation"), ("fields", Json.mkObj [("producer", encode producer), ("contract", fullSlotEncode contract)])]
  | .resourceCapacityBound required limit => Json.mkObj [("tag", .str "ResourceCapacityBound"), ("fields", Json.mkObj [("required", encode required), ("limit", encode limit)])]
  | .resourceSolverUnknown reason => Json.mkObj [("tag", .str "ResourceSolverUnknown"), ("value", match reason with
    | .bindingBoundExhausted limit => Json.mkObj [("tag", .str "BindingBoundExhausted"), ("value", encode limit)]
    | .searchStepBoundExhausted limit => Json.mkObj [("tag", .str "SearchStepBoundExhausted"), ("value", encode limit)])]
  | reason => Json.mkObj [("tag", .str (match reason with
    | .branchInhabitation => "BranchInhabitation" | .unresolvedUniqueness => "UnresolvedUniqueness"
    | .stateBoundExhausted => "StateBoundExhausted" | .bindingBoundExhausted => "BindingBoundExhausted"
    | .branchBoundExhausted => "BranchBoundExhausted" | _ => ""))]

inductive ClassificationInput where
  | composition (reasons : List UnresolvedObligation) (provenance : CompositionProvenance)
  | semantic (reasons : List SemanticObligation) (provenance : EvaluationProvenance)
  | publicValidation (graph : SemanticGraph) (reference : TypeRef) (value : Necoherence.ExactJson.JsonValue)

def publicValidationShapeDecode (json : Json) : Except WireFailure StringSpec := do
  match ← get (α := String) json "tag" with
  | "String" => keys json ["tag", "value"]; get json "value"
  | tag => throw (.unknownTag "$.tag" tag)

def publicValidationNodeDecode (json : Json) : Except WireFailure TypeNode := do
  keys json ["reference", "shape", "description", "attributes", "extensions"]
  let spec ← getWith publicValidationShapeDecode json "shape"
  pure { ref := ← getWith typeRefDecode json "reference", shape := .string spec, description := none, attributes := [], extensions := [] }

def publicValidationGraph (raw : Json) : Except WireFailure SemanticGraph := do
  keys raw ["profile", "nodes", "source_refs"]
  let profile : Necoherence.TypeSignatures.ValueProfile ← get raw "profile"
  let nodes ← jsonArray raw "nodes" publicValidationNodeDecode
  pure { profile := {
    reference := profile.reference, sourceRefs := profile.sourceRefs,
    integerDomains := profile.integerDomains, defaultIntegerDomain := profile.defaultIntegerDomain,
    numbers := profile.numbers, graphemeRules := profile.graphemeRules, bytesPolicy := profile.bytesPolicy,
    formatBindings := profile.formatBindings, wrappers := profile.wrappers, tag := profile.tag }, nodes }

def classificationInput (json : Json) : Except WireFailure ClassificationInput := do
  if (json.getObjValAs? String "domain").toOption == some "composition" then
    pure (.composition (← jsonArray json "obligations" compositionObligationDecode)
      (← getWith compositionProvenanceDecode json "provenance"))
  else if (json.getObjValAs? String "entry").toOption == some "value" then
    pure (.publicValidation (← getWith publicValidationGraph json "graph")
      (← getWith typeRefDecode json "reference")
      (Necoherence.ExactJson.fromJson (← liftJson (json.getObjVal? "value"))))
  else
    pure (.semantic (← jsonArray json "obligations" semanticObligationDecode)
      (← getWith evaluationProvenanceDecode json "provenance"))

def classificationOutput : ClassificationInput → Except RunnerFailure Json
  | .composition reasons provenance => do
    let classified := classifyUnresolvedObligations provenance reasons
    let stopsOf := (classified.obligations.flatMap UnresolvedObligation.atoms).filter (fun (reason : UnresolvedObligation) => classifyDispositions reason.classifications == ReasonDisposition.stopped)
    let (status, residuals, stops) := match classified with
      | .ok result => match result.status with
        | .resolved => ("Resolved", [], [])
        | .residual residuals => ("Residual", residuals.values, [])
        | .stopped residuals stops => ("Stopped", residuals.values, stops)
      | .error failure => ("Failed", failure.residuals.values, stopsOf)
    let failures := (classified.obligations.flatMap UnresolvedObligation.atoms).filter (fun (reason : UnresolvedObligation) => classifyDispositions reason.classifications == ReasonDisposition.failed)
    let arr := fun (values : List UnresolvedObligation) => Json.arr (values.map compositionObligationEncode).toArray
    return Json.mkObj [("domain", .str "composition"), ("status", .str status), ("obligations", arr classified.obligations),
      ("residuals", arr residuals), ("stops", arr stops), ("failures", arr failures), ("provenance", compositionProvenanceEncode classified.provenance)]
  | input => do
    let (reasons, provenance) ← match input with
      | .publicValidation graph reference value =>
        match validateValue graph reference value with
        | .error (.unresolved reasons) => pure (reasons, ({ operation := "validate", typeRef := reference, valuePath := [] } : EvaluationProvenance))
        | .error failure => throw (RunnerFailure.validation failure)
        | .ok _ => throw (RunnerFailure.wire (WireFailure.syntax "$" "unresolved public validation required"))
      | .semantic reasons provenance => pure (reasons, provenance)
      | .composition _ _ => throw (RunnerFailure.wire (WireFailure.syntax "$" "composition input is classified separately"))
    let classified := classifyValueDecision provenance (.unresolved reasons)
    let (status, provenance, residuals, stops) := match classified with
      | .ok result => match result.status with
        | .resolved => ("Resolved", result.evaluation.provenance, [], [])
        | .residual residuals => ("Residual", result.evaluation.provenance, residuals.values, [])
        | .stopped residuals stops => ("Stopped", result.evaluation.provenance, residuals.values, stops)
      | .error failure => ("Failed", failure.provenance, failure.residuals.values, reasons.filter (fun reason => reason.reason.disposition == ReasonDisposition.stopped))
    let reasons := match classified.decision with | .unresolved reasons => reasons | _ => []
    let arr := fun (values : List SemanticObligation) => Json.arr (values.map semanticObligationEncode).toArray
    pure (Json.mkObj [("status", .str status), ("obligations", arr reasons), ("residuals", arr residuals),
      ("stops", arr stops), ("failures", arr (reasons.filter (fun reason => reason.reason.disposition == ReasonDisposition.failed))),
      ("provenance", evaluationProvenanceEncode provenance)])

def classificationJudgement (json : Json) : Except RunnerFailure Json :=
  match classificationInput json with
  | .error failure => pure (wireFailureJson failure)
  | .ok input => classificationOutput input

def valueJudgement (library : Library) (typeId : String)
    (value : Necoherence.ExactJson.JsonValue) : Except RunnerFailure Json := do
  let _ ← (Necoherence.TypeSignatures.checkLibrary library).mapError RunnerFailure.libraryCheck
  let ref : TypeRef ← decode (.str typeId)
  match validateValue library.graph ref value with
  | .ok _ => pure (Json.mkObj [("status", .str "Accepted")])
  | .error (.value failure) => pure (Json.mkObj [("status", .str "Rejected"),
      ("type_ref", typeRefJson failure.typeRef),
      ("path", pathJson failure.valuePath), ("condition", .str (conditionName failure.condition)),
      ("trace", encode (failure.referenceTrace.map (·.definitionName)))])
  | .error (.unresolved _) => pure (Json.mkObj [("status", .str "Unresolved")])
  | .error reason => throw (RunnerFailure.validation reason)

def graphemeJudgement (library : Library) (text : String) : Except RunnerFailure Json := do
  let _ ← (Necoherence.TypeSignatures.checkLibrary library).mapError RunnerFailure.libraryCheck
  let some rules := library.profile.graphemeRules | throw (RunnerFailure.wire (WireFailure.syntax "$" "grapheme rules required"))
  pure (Json.mkObj [("boundaries", toJson (graphemeBoundaries rules text)),
    ("count", toJson (graphemeLength rules text))])

def producerStrings : ProducerRef → List String
  | .initial id => ["initial", id.value]
  | .invocationOutcome site outcome port => ["outcome", site.value, outcome.value, port.value]
def bindingPathStrings (path : ValuePath) : List String := path.map fun step => match step with
  | .field name => "field:" ++ name | .index index => "index:" ++ toString index | .variant tag => "variant:" ++ tag
partial def bindingRows (destination : String) : BindingExpr → List Json
  | .source value _ _ => [Json.mkObj [("destination", .str destination),
      ("producer", encode (producerStrings value.producer)), ("path", encode (bindingPathStrings value.path))]]
  | .product construction _ fields =>
    Json.mkObj [("destination", .str destination), ("producer", encode (["construction", construction] : List String)),
      ("path", .arr #[])] :: fields.flatMap (fun (name, binding) => bindingRows ("construction:" ++ construction ++ ":" ++ name) binding)
partial def treeBindingRows : PlanTree → List Json
  | .returnValue _ (.success outputs) => outputs.flatMap (fun (id, binding) => bindingRows ("goal:" ++ id.value) binding)
  | .returnValue _ (.failure _ _) => []
  | .invoke _ _ arms _ => arms.flatMap (fun (_, child) => treeBindingRows child)
  | .guard _ _ _ arms => arms.flatMap (fun (_, child) => treeBindingRows child)

def replaceField (json : Json) (key : String) (value : Json) : Except WireFailure Json := do
  let fields ← liftJson json.getObj?
  pure (Json.mkObj ((fields.toList.filter (fun field => field.1 != key)) ++ [(key, value)]))

def compositionJudgement (library : Library) (json : Json) : Except RunnerFailure Json := do
  let (problem, causes) ← Necoherence.SignatureComposition.decodeProblem library json
  let prepared ← (Necoherence.SignatureComposition.prepare library
    (Necoherence.SignatureGeneration.basis library []).graphSha256 problem causes).mapError RunnerFailure.compositionInput
  let decision ← (derive prepared).mapError RunnerFailure.compositionEngine
  let classification := match decision with
    | .solved _ => "Solved" | .unreachable _ => "Unreachable"
    | .ambiguous _ _ => "Ambiguous" | .unknown _ _ => "Unknown"
  let candidates : List PlanTree := match decision with
    | .solved checked => [checked.candidate.raw.plan.root]
    | _ => []
  let bindings := (candidates.flatMap treeBindingRows).eraseDups.mergeSort
    (fun a b => Necoherence.SignatureGeneration.canonicalJson a ≤ Necoherence.SignatureGeneration.canonicalJson b)
  let mut fields := [("classification", .str classification), ("bindings", .arr bindings.toArray)]
  if classification == "Solved" then
    let anyProblem ← replaceField json "selection_policy" (Json.mkObj [("tag", .str "AnyFeasible")])
    let (anyInput, anyCauses) ← Necoherence.SignatureComposition.decodeProblem library anyProblem
    let anyPrepared ← (Necoherence.SignatureComposition.prepare library
      (Necoherence.SignatureGeneration.basis library []).graphSha256 anyInput anyCauses).mapError RunnerFailure.compositionInput
    let anyDecision ← (derive anyPrepared).mapError RunnerFailure.compositionEngine
    let .solved checked := anyDecision | throw (RunnerFailure.wire (WireFailure.syntax "$" "AnyFeasible derivation did not solve"))
    let derivation ← derivationEncode library anyProblem checked.candidate.raw
    let composition := Json.mkObj [("problem", anyProblem), ("derivation", derivation)]
    let some definition := library.definitions.head? | throw (RunnerFailure.wire (WireFailure.syntax "$" "witness entrypoint definition required"))
    let entrypoints : List Necoherence.SignatureGeneration.Entrypoint := [{ identity := "invariant", definition := definition.id }]
    let exchange : Necoherence.SignatureGeneration.Input := {
      basis := Necoherence.SignatureGeneration.basis library entrypoints (some composition), signatures := library,
      composition := some composition, entrypoints }
    let _ ← (NecoherenceTools.SignatureComposition.generate exchange (Necoherence.SignatureGeneration.ExpectedBasis.ofInput exchange)).mapError RunnerFailure.generation
    fields := fields ++ [("exchange", encode exchange)]
  pure (Json.mkObj fields)

def verifyExchange (input : Necoherence.SignatureGeneration.Input)
    (expected : Necoherence.SignatureGeneration.ExpectedBasis) : Except RunnerFailure Unit := do
  let _ ← (Necoherence.SignatureGeneration.admit input expected).mapError RunnerFailure.admission
  let _ ← (NecoherenceTools.SignatureComposition.generate input expected).mapError RunnerFailure.generation
  pure ()

def failureFields (failure : ValueFailure) : List (String × Json) :=
  [("type_ref", typeRefJson failure.typeRef), ("path", pathJson failure.valuePath),
    ("condition", .str (conditionName failure.condition))]

def profilePredicateName : ProfilePredicate → String
  | .pr01 => "PR01" | .pr02 => "PR02" | .pr03 => "PR03" | .pr04 => "PR04"
  | .pr05 => "PR05" | .pr06 => "PR06" | .pr07 => "PR07" | .pr08 => "PR08"
  | .pr09 => "PR09" | .pr10 => "PR10" | .pr11 => "PR11" | .pr12 => "PR12"
  | .pr13 => "PR13" | .pr14 => "PR14" | .pr15 => "PR15" | .pr16 => "PR16"

def libraryPredicateName : Necoherence.TypeSignatures.LibraryPredicate → String
  | .lb01 => "LB01" | .lb02 => "LB02" | .lb03 => "LB03" | .lb04 => "LB04"
  | .lb05 => "LB05" | .lb06 => "LB06" | .lb07 => "LB07" | .lb08 => "LB08"
  | .lb09 => "LB09" | .lb10 => "LB10" | .lb11 => "LB11" | .lb12 => "LB12"
  | .lb13 => "LB13" | .lb14 => "LB14" | .lb15 => "LB15" | .lb16 => "LB16"
  | .lb17 => "LB17" | .lb18 => "LB18" | .lb19 => "LB19"

def profileJudgement (profile : VersionedSemanticProfile) : Json :=
  match checkProfile profile with
  | .ok _ => Json.mkObj [("status", .str "Accepted")]
  | .error failure => Json.mkObj [("status", .str "Rejected"),
      ("predicate", .str (profilePredicateName failure.predicate)),
      ("path", encode failure.location)]

def checkedLibraryJudgement (library : Library) : Json :=
  match Necoherence.TypeSignatures.checkLibrary library with
  | .ok _ => Json.mkObj [("status", .str "Accepted")]
  | .error (.profile failure) => Json.mkObj [("status", .str "Rejected"),
      ("predicate", .str (profilePredicateName failure.predicate)),
      ("path", encode failure.location)]
  | .error (.library failure) => Json.mkObj [("status", .str "Rejected"),
      ("predicate", .str (libraryPredicateName failure.predicate)),
      ("path", encode failure.location)]

def samplesJudgement (library : Library) (typeId : String) (maximum fuel : Nat) :
    Except RunnerFailure Json := do
  let _ ← (Necoherence.TypeSignatures.checkLibrary library).mapError
    RunnerFailure.libraryCheck
  let ref : TypeRef ← decode (.str typeId)
  let bounds : SearchBounds := { maxTypeObligations := fuel, maxSampleLength := maximum }
  let result := sampleValueFuel library.graph bounds
    (min fuel (library.graph.nodes.length + 1)) [] ref
  let accepted := result.values.all fun value => match acceptsValue library.graph ref value with
    | .accepted => true
    | _ => false
  pure (Json.mkObj [("status", .str (if accepted then "Accepted" else "Rejected")),
    ("sample_bound", toJson (result.obligations.contains .sampleBound)),
    ("sample_count", toJson result.values.length),
    ("values", .arr (result.values.map encodeExact).toArray)])

def wireJudgement (json : Json) : Json :=
  match decode (α := Necoherence.SignatureGeneration.Input) json with
  | .ok input => Json.mkObj [("status", .str "Accepted"), ("encoded", encode input)]
  | .error failure => wireFailureJson failure

def slotJson : SlotValue → Except WireFailure Json
  | .absent => pure (Json.mkObj [("tag", .str "Absent")])
  | .null => pure (Json.mkObj [("tag", .str "Null")])
  | .present value => do pure (Json.mkObj [("tag", .str "Present"),
      ("value", (← Necoherence.ExactJson.toJson value))])

def inclusionJudgement (library : Library) (source destination : SlotContract)
    (candidates : Array Json) : Except RunnerFailure Json := do
  let _ ← (Necoherence.TypeSignatures.checkLibrary library).mapError RunnerFailure.libraryCheck
  for candidate in candidates do
    let value := SlotValue.present (Necoherence.ExactJson.fromJson candidate)
    if (validateSlot library.graph source value).isOk then
      match validateSlot library.graph destination value with
      | .error (.value failure) => do
        let certificate : CounterexampleCertificate := {
          basis := SemanticBasis.of library.graph, source, destination, value, destinationFailure := failure }
        let _ ← (verifyCounterexample library.graph source destination certificate).mapError RunnerFailure.inclusion
        return Json.mkObj ([("classification", .str "Incompatible"),
          ("value", (← slotJson value))] ++ failureFields failure)
      | _ => pure ()
  match checkAssignable library.graph source destination with
  | .compatible _ => pure (Json.mkObj [("classification", .str "Compatible")])
  | .unknown _ => pure (Json.mkObj [("classification", .str "Unknown")])
  | .incompatible checked => pure (Json.mkObj
      ([("classification", .str "Incompatible"), ("value", (← slotJson checked.certificate.value))] ++
        failureFields checked.certificate.destinationFailure))

def projectionStepDecode (step : Json) : Except WireFailure PathStep := do
  match ← get (α := String) step "tag" with
  | "Field" => keys step ["tag", "value"]; return .field (← get step "value")
  | "Index" =>
    keys step ["tag", "value"]
    let value : String ← get step "value"
    let some index := value.toNat? | throw (WireFailure.syntax "$.value" "invalid projection index")
    return .index index
  | tag => throw (.unknownTag "$.tag" tag)

def projectionPath (json : Json) : Except WireFailure ValuePath :=
  decodeListWith projectionStepDecode json

def candidateSlotDecode (candidate : Json) : Except WireFailure SlotValue := do
  match ← get (α := String) candidate "tag" with
  | "Absent" => keys candidate ["tag"]; pure .absent
  | "Null" => keys candidate ["tag"]; pure .null
  | "Present" =>
    keys candidate ["tag", "value"]
    pure (.present (Necoherence.ExactJson.fromJson (← liftJson (candidate.getObjVal? "value"))))
  | tag => throw (.unknownTag "$.tag" tag)

def projectionFailureName : ProjectionFailure → String
  | .wrongShape _ _ => "WrongShape" | .missingField _ _ => "MissingField"
  | .missingVariant _ _ => "MissingVariant" | .branchAssumptionRequired _ _ => "BranchAssumptionRequired"
  | .unresolved _ => "Unresolved" | .certificateMismatch _ => "CertificateMismatch"
  | .variantSelectionUndetermined _ _ => "VariantSelectionUndetermined"

def projectionJudgement (library : Library) (source destination : SlotContract)
    (path : ValuePath) (producer : Json) (candidates : List SlotValue) : Except RunnerFailure Json := do
  let _ ← (Necoherence.TypeSignatures.checkLibrary library).mapError RunnerFailure.libraryCheck
  match projectSlot library.graph source path [] with
  | .error failure => pure (Json.mkObj [("status", .str "Rejected"),
      ("rejection", .str (projectionFailureName failure))])
  | .ok projected => do
    for value in candidates do
      if (validateSlot library.graph projected.destination value).isOk &&
          !(validateSlot library.graph destination value).isOk then
        return Json.mkObj [("status", .str "Rejected"), ("rejection", .str "Incompatible")]
    match checkAssignable library.graph projected.destination destination with
    | .compatible _ => pure (Json.mkObj [("status", .str "Accepted"),
        ("binding", Json.mkObj [("producer", producer), ("path", encode (bindingPathStrings path)),
          ("compatibility", .str "Compatible")])])
    | .incompatible _ => pure (Json.mkObj [("status", .str "Rejected"), ("rejection", .str "Incompatible")])
    | .unknown _ => pure (Json.mkObj [("status", .str "Rejected"), ("rejection", .str "Unknown")])

def libraryJudgement (library changed : Library) (typeId : String)
    (value : Necoherence.ExactJson.JsonValue) : Except RunnerFailure Json := do
  let entrypoints := library.definitions.map fun definition =>
    ({ identity := definition.id, definition := definition.id } : Necoherence.SignatureGeneration.Entrypoint)
  let before := Necoherence.SignatureGeneration.basis library entrypoints
  let after := Necoherence.SignatureGeneration.basis changed entrypoints
  let _ ← (Necoherence.SignatureGeneration.admit
    { basis := before, signatures := library, entrypoints } { basis := before, observations := none }).mapError RunnerFailure.admission
  let _ ← (Necoherence.SignatureGeneration.admit
    { basis := after, signatures := changed, entrypoints } { basis := after, observations := none }).mapError RunnerFailure.admission
  let beforeValue ← valueJudgement library typeId value
  let afterValue ← valueJudgement changed typeId value
  pure (Json.mkObj [("graph_equal", toJson (before.graphSha256 == after.graphSha256)),
    ("provenance_equal", toJson (before.provenanceSha256 == after.provenanceSha256)),
    ("metadata_equal", toJson (before.metadataSha256 == after.metadataSha256)),
    ("before", (← beforeValue.getObjVal? "status")), ("after", (← afterValue.getObjVal? "status"))])

def profileAdmissionJudgement (library : Library) : Json :=
  let entrypoints := library.definitions.map fun definition =>
    ({ identity := definition.id, definition := definition.id } : Necoherence.SignatureGeneration.Entrypoint)
  let basis := Necoherence.SignatureGeneration.basis library entrypoints
  match Necoherence.SignatureGeneration.admit { basis, signatures := library, entrypoints } { basis, observations := none } with
  | .ok _ => Json.mkObj [("status", .str "Accepted")]
  | .error _ => Json.mkObj [("status", .str "Rejected"), ("rejection", .str "InvalidProfile")]

def judgement (json : Json) : Except RunnerFailure Json := do
  let id : String ← get json "id"
  let kind : String ← get json "kind"
  let result ← match kind with
    | "classification" => classificationJudgement json
    | "profile" => do
      let library : Library ← get json "library"
      pure (profileJudgement library.graph.profile)
    | "library" => do
      let library : Library ← get json "library"
      pure (checkedLibraryJudgement library)
    | "wire" => pure (wireJudgement (← json.getObjVal? "value"))
    | "samples" => do
      let maximumText : String ← get json "max_sample_length"
      let fuelText : String ← get json "max_type_obligations"
      let some maximum := maximumText.toNat? |
        throw (RunnerFailure.wire (WireFailure.syntax "$.max_sample_length" "natural number required"))
      let some fuel := fuelText.toNat? |
        throw (RunnerFailure.wire (WireFailure.syntax "$.max_type_obligations" "natural number required"))
      samplesJudgement (← get json "library") (← get json "type_id") maximum fuel
    | "inclusion_by_id" => do
      let library : Library ← get json "library"
      let sourceRef : TypeRef ← decode (.str (← get json "type_id"))
      let destinationRef : TypeRef ← decode (.str (← get json "destination_type_id"))
      inclusionJudgement library
        { typeRef := sourceRef, required := true, nullable := false }
        { typeRef := destinationRef, required := true, nullable := false } #[]
    | "construction_witness" => do
      let input : Necoherence.SignatureGeneration.Input ← get json "exchange"
      let expected : Necoherence.SignatureGeneration.ExpectedBasis ← get json "expected_basis"
      pure (match verifyExchange input expected with
        | .ok _ => Json.mkObj [("status", .str "Accepted")]
        | .error _ => Json.mkObj [("status", .str "Rejected"), ("rejection", .str "Witness")])
    | "profile_admission" =>
      pure (match (get json "library" : Except WireFailure Library) with
        | .ok library => profileAdmissionJudgement library
        | .error _ => Json.mkObj [("status", .str "Rejected"), ("rejection", .str "InvalidProfile")])
    | "value" => valueJudgement (← get json "library") (← get json "type_id") (Necoherence.ExactJson.fromJson (← json.getObjVal? "value"))
    | "library_invariant" => do
      let library ← get json "library"
      let changed ← get json "changed_library"
      let typeId ← get json "type_id"
      libraryJudgement library changed typeId (Necoherence.ExactJson.fromJson (← json.getObjVal? "value"))
    | "inclusion" => do
      let library ← get json "library"
      let source : SlotContract ← get json "source"
      let destination : SlotContract ← get json "destination"
      inclusionJudgement library source destination
        (← liftJson (← liftJson (json.getObjVal? "candidates")).getArr?)
    | "projection" => do
      let library ← get json "library"
      let source : SlotContract ← get json "source"
      let destination : SlotContract ← get json "destination"
      let path ← getWith projectionPath json "path"
      projectionJudgement library source destination path (← json.getObjVal? "producer")
        (← jsonArray json "candidate_slots" candidateSlotDecode)
    | "grapheme" => graphemeJudgement (← get json "library") (← get json "text")
    | "construction_solver" => compositionJudgement (← get json "library") (← json.getObjVal? "problem")
    | _ => throw (RunnerFailure.wire (WireFailure.syntax "$" "unknown invariant input kind"))
  let object ← liftJson result.getObj?
  pure (Json.mkObj ([("id", .str id)] ++ object.toList))

def renderCodec (json : Json) : Except RunnerFailure String := do
  let library : Library ← get json "library"
  let entrypoints := library.definitions.map fun definition =>
    ({ identity := definition.id, definition := definition.id } : Necoherence.SignatureGeneration.Entrypoint)
  let input : Necoherence.SignatureGeneration.Input := {
    basis := Necoherence.SignatureGeneration.basis library entrypoints,
    signatures := library, entrypoints }
  let source ← (NecoherenceTools.SignatureGeneration.generate input (Necoherence.SignatureGeneration.ExpectedBasis.ofInput input)).mapError RunnerFailure.generation
  let branches ← library.nodes.mapM fun node => do
    let ref : TypeRef ← decode (.str node.id)
    let index ← (NecoherenceTools.SemanticRenderer.nodeIndex library.graph ref).mapError RunnerFailure.renderer
    let n := toString index
    pure ("  | " ++ reprStr node.id ++ " => codecResult id (Generated.decode" ++ n ++ " value) Generated.encodeJson" ++ n ++ "\n")
  pure ("import NecoherenceTools.SemanticInvariantOutput\nimport Necoherence.SignatureJson\n" ++ source ++
    "\nopen Lean Necoherence.SemanticTypes Necoherence.SemanticValidation NecoherenceTools.SemanticInvariantOutput\n" ++
    "def codecResult (id : String) (decoded : Except ValidationFailure α) (encode : α → Except String Json) : Except String Json := do\n" ++
    "  match decoded with\n" ++
    "  | .ok value => pure (Json.mkObj [(\"id\", .str id), (\"status\", .str \"Accepted\"), (\"encoded\", (← encode value))])\n" ++
    "  | .error (.value failure) => pure (Json.mkObj [(\"id\", .str id), (\"status\", .str \"Rejected\"), (\"path\", pathJson failure.valuePath), (\"condition\", .str (conditionName failure.condition))])\n" ++
    "  | .error reason => throw (reprStr reason)\n" ++
    "def codecJudgement (json : Json) : Except String Json := do\n" ++
    "  let id ← (← json.getObjVal? \"id\").getStr?\n" ++
    "  let typeId ← (← json.getObjVal? \"type_id\").getStr?\n" ++
    "  let value ← json.getObjVal? \"value\"\n" ++
    "  match typeId with\n" ++ String.join branches ++
    "  | _ => throw \"unknown codec type\"\n" ++
    "def main : IO UInt32 := do\n" ++
    "  let input ← IO.getStdin\n  let output ← IO.getStdout\n  let error ← IO.getStderr\n" ++
    "  repeat\n    let line ← input.getLine\n    if line.isEmpty then break\n" ++
    "    if line.trimAscii.toString.isEmpty then continue\n" ++
    "    match (Necoherence.SignatureJson.parse line).mapError (fun failure => reprStr failure) >>= codecJudgement with\n" ++
    "    | .ok result => output.putStrLn (Necoherence.ExactJson.compressJson result)\n" ++
    "    | .error reason => error.putStrLn reason; return 1\n  return 0\n")

end NecoherenceTools.SemanticInvariantRunner

def main (args : List String) : IO UInt32 := do
  let input ← IO.getStdin
  let output ← IO.getStdout
  let error ← IO.getStderr
  if args == ["--render-codec"] then
    let parsed := (Necoherence.SignatureJson.parse (← input.getLine)).mapError NecoherenceTools.SemanticInvariantRunner.RunnerFailure.wire
    match parsed >>=
        NecoherenceTools.SemanticInvariantRunner.renderCodec with
    | .ok source => output.putStr source; return 0
    | .error reason => error.putStrLn (reprStr reason); return 1
  repeat
    let line ← input.getLine
    if line.isEmpty then break
    if line.trimAscii.toString.isEmpty then continue
    match (Necoherence.SignatureJson.parse line).mapError NecoherenceTools.SemanticInvariantRunner.RunnerFailure.wire >>=
        NecoherenceTools.SemanticInvariantRunner.judgement with
    | .ok result => output.putStrLn (Necoherence.ExactJson.compressJson result)
    | .error reason => error.putStrLn (reprStr reason); return 1
  return 0
