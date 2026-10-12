-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import NecoherenceTools.SignatureGeneration
import NecoherenceTools.SemanticRenderer
import NecoherenceTools.SemanticInvariantOutput
import NecoherenceTools.CompositionSearch

namespace NecoherenceTools.SemanticInvariantRunner
open Lean Necoherence Necoherence.SemanticTypes Necoherence.SemanticValidation Necoherence.SemanticComposition Necoherence.SignatureWire Necoherence.SemanticInvariantDerivation
open NecoherenceTools.SemanticInvariantOutput NecoherenceTools.CompositionSearch
set_option maxRecDepth 10000
set_option maxHeartbeats 0


def typeRefJson (reference : TypeRef) : Json :=
  Json.mkObj [
    ("source", Json.mkObj [
      ("repository", .str reference.source.repository),
      ("revision", .str reference.source.revision),
      ("path", .str reference.source.path),
      ("content_digest", .str reference.source.contentDigest),
      ("document_id", .str reference.source.documentId),
      ("declared_revision", encode reference.source.declaredRevision)]),
    ("definition_name", .str reference.definitionName),
    ("pointer", encode reference.pointer)]

def valueJudgement (library : Library) (typeId : String)
    (value : Necoherence.ExactJson.JsonValue) : Except WireFailure Json := do
  let _ ← (Necoherence.TypeSignatures.checkLibrary library).mapError (fun failure => WireFailure.syntax "$" (reprStr failure))
  let ref : TypeRef ← decode (.str typeId)
  match validateValue library.graph ref value with
  | .ok _ => pure (Json.mkObj [("status", .str "Accepted")])
  | .error (.value failure) => pure (Json.mkObj [("status", .str "Rejected"),
      ("type_ref", typeRefJson failure.typeRef),
      ("path", pathJson failure.valuePath), ("condition", .str (conditionName failure.condition)),
      ("trace", encode (failure.referenceTrace.map (·.definitionName)))])
  | .error (.unresolved _) => pure (Json.mkObj [("status", .str "Unresolved")])
  | .error reason => throw (WireFailure.syntax "$" (reprStr reason))

def graphemeJudgement (library : Library) (text : String) : Except WireFailure Json := do
  let _ ← (Necoherence.TypeSignatures.checkLibrary library).mapError (fun failure => WireFailure.syntax "$" (reprStr failure))
  let some rules := library.profile.graphemeRules | throw (WireFailure.syntax "$" "grapheme rules required")
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

def compositionJudgement (library : Library) (json : Json) : Except WireFailure Json := do
  let (problem, causes) ← Necoherence.SignatureComposition.decodeProblem library json
  let prepared ← (Necoherence.SignatureComposition.prepare library
    (Necoherence.SignatureGeneration.basis library []).graphSha256 problem causes).mapError (fun failure => WireFailure.syntax "$" (reprStr failure))
  let decision ← (derive prepared).mapError (fun failure => WireFailure.syntax "$" (reprStr failure))
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
      (Necoherence.SignatureGeneration.basis library []).graphSha256 anyInput anyCauses).mapError (fun failure => WireFailure.syntax "$" (reprStr failure))
    let anyDecision ← (derive anyPrepared).mapError (fun failure => WireFailure.syntax "$" (reprStr failure))
    let .solved checked := anyDecision | throw (WireFailure.syntax "$" "AnyFeasible derivation did not solve")
    let derivation ← derivationEncode library anyProblem checked.candidate.raw
    let composition := Json.mkObj [("problem", anyProblem), ("derivation", derivation)]
    let some definition := library.definitions.head? | throw (WireFailure.syntax "$" "witness entrypoint definition required")
    let entrypoints : List Necoherence.SignatureGeneration.Entrypoint := [{ identity := "invariant", definition := definition.id }]
    let exchange : Necoherence.SignatureGeneration.Input := {
      basis := Necoherence.SignatureGeneration.basis library entrypoints (some composition), signatures := library,
      composition := some composition, entrypoints }
    let _ ← (NecoherenceTools.SignatureComposition.generate exchange exchange.basis).mapError (fun failure => WireFailure.syntax "$" (reprStr failure))
    fields := fields ++ [("exchange", encode exchange)]
  pure (Json.mkObj fields)

def verifyExchange (input : Necoherence.SignatureGeneration.Input)
    (expected : Necoherence.SignatureGeneration.Basis) : Except WireFailure Unit := do
  let _ ← (Necoherence.SignatureGeneration.admit input expected).mapError (fun failure => WireFailure.syntax "$" (reprStr failure))
  let _ ← (NecoherenceTools.SignatureComposition.generate input expected).mapError (fun failure => WireFailure.syntax "$" (reprStr failure))
  pure ()

def slotContract (json : Json) : Except WireFailure SlotContract := do
  let id : String ← get json "type_id"
  let required : Bool ← get json "required"
  let nullable : Bool ← get json "nullable"
  pure { typeRef := ← decode (.str id), required, nullable }

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
    Except WireFailure Json := do
  let _ ← (Necoherence.TypeSignatures.checkLibrary library).mapError
    (fun failure => WireFailure.syntax "$" (reprStr failure))
  let ref : TypeRef ← decode (.str typeId)
  let bounds : SearchBounds := { maxTypeObligations := fuel, maxSampleLength := maximum }
  let result := sampleValueFuel library.graph bounds
    (min fuel (library.graph.nodes.length + 1)) [] ref
  let accepted := result.values.all fun value => match acceptsValue library.graph ref value with
    | .accepted => true
    | _ => false
  pure (Json.mkObj [("status", .str (if accepted then "Accepted" else "Rejected")),
    ("sample_bound", toJson (result.obligations.contains .sampleBound)),
    ("sample_count", toJson result.values.length)])

def wireFailureJson : WireFailure → Json
  | .unsupportedSchema path _ => Json.mkObj [("status", .str "Rejected"),
      ("failure_kind", .str "Wire"), ("classification", .str "UnsupportedSchema"),
      ("path", .str path)]
  | .unknownField path _ => Json.mkObj [("status", .str "Rejected"),
      ("failure_kind", .str "Wire"), ("classification", .str "UnknownField"),
      ("path", .str path)]
  | .unknownTag path _ => Json.mkObj [("status", .str "Rejected"),
      ("failure_kind", .str "Wire"), ("classification", .str "UnknownTag"),
      ("path", .str path)]
  | .syntax path _ => Json.mkObj [("status", .str "Rejected"),
      ("failure_kind", .str "Wire"), ("classification", .str "Syntax"),
      ("path", .str path)]

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
    (candidates : Array Json) : Except WireFailure Json := do
  let _ ← (Necoherence.TypeSignatures.checkLibrary library).mapError (fun failure => WireFailure.syntax "$" (reprStr failure))
  for candidate in candidates do
    let value := SlotValue.present (Necoherence.ExactJson.fromJson candidate)
    if (validateSlot library.graph source value).isOk then
      match validateSlot library.graph destination value with
      | .error (.value failure) => do
        let certificate : CounterexampleCertificate := {
          basis := SemanticBasis.of library.graph, source, destination, value, destinationFailure := failure }
        let _ ← (verifyCounterexample library.graph source destination certificate).mapError (fun failure => WireFailure.syntax "$" (reprStr failure))
        return Json.mkObj ([("classification", .str "Incompatible"),
          ("value", (← slotJson value))] ++ failureFields failure)
      | _ => pure ()
  match checkAssignable library.graph source destination with
  | .compatible _ => pure (Json.mkObj [("classification", .str "Compatible")])
  | .unknown _ => pure (Json.mkObj [("classification", .str "Unknown")])
  | .incompatible checked => pure (Json.mkObj
      ([("classification", .str "Incompatible"), ("value", (← slotJson checked.certificate.value))] ++
        failureFields checked.certificate.destinationFailure))

def projectionPath (json : Json) : Except WireFailure ValuePath := do
  (← liftJson json.getArr?).toList.mapM fun step => do
    let tag : String ← get step "tag"
    match tag with
    | "Field" => return .field (← get step "value")
    | "Index" =>
      let value : String ← get step "value"
      let some index := value.toNat? | throw (WireFailure.syntax "$" "invalid projection index")
      return .index index
    | _ => throw (WireFailure.syntax "$" "invalid projection step")

def projectionFailureName : ProjectionFailure → String
  | .wrongShape _ _ => "WrongShape" | .missingField _ _ => "MissingField"
  | .missingVariant _ _ => "MissingVariant" | .branchAssumptionRequired _ _ => "BranchAssumptionRequired"
  | .unresolved _ => "Unresolved" | .certificateMismatch _ => "CertificateMismatch"
  | .variantSelectionUndetermined _ _ => "VariantSelectionUndetermined"

def projectionJudgement (library : Library) (source destination : SlotContract)
    (path : ValuePath) (producer : Json) (candidates : Array Json) : Except WireFailure Json := do
  let _ ← (Necoherence.TypeSignatures.checkLibrary library).mapError (fun failure => WireFailure.syntax "$" (reprStr failure))
  match projectSlot library.graph source path [] with
  | .error failure => pure (Json.mkObj [("status", .str "Rejected"),
      ("rejection", .str (projectionFailureName failure))])
  | .ok projected => do
    for candidate in candidates do
      let tag : String ← get candidate "tag"
      let value ← match tag with
        | "Absent" => pure SlotValue.absent
        | "Null" => pure SlotValue.null
        | "Present" => pure (SlotValue.present (Necoherence.ExactJson.fromJson (← candidate.getObjVal? "value")))
        | _ => throw (WireFailure.syntax "$" "invalid candidate slot")
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
    (value : Necoherence.ExactJson.JsonValue) : Except WireFailure Json := do
  let entrypoints := library.definitions.map fun definition =>
    ({ identity := definition.id, definition := definition.id } : Necoherence.SignatureGeneration.Entrypoint)
  let before := Necoherence.SignatureGeneration.basis library entrypoints
  let after := Necoherence.SignatureGeneration.basis changed entrypoints
  let _ ← (Necoherence.SignatureGeneration.admit
    { basis := before, signatures := library, entrypoints } before).mapError (fun failure => WireFailure.syntax "$" (reprStr failure))
  let _ ← (Necoherence.SignatureGeneration.admit
    { basis := after, signatures := changed, entrypoints } after).mapError (fun failure => WireFailure.syntax "$" (reprStr failure))
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
  match Necoherence.SignatureGeneration.admit { basis, signatures := library, entrypoints } basis with
  | .ok _ => Json.mkObj [("status", .str "Accepted")]
  | .error _ => Json.mkObj [("status", .str "Rejected"), ("rejection", .str "InvalidProfile")]

def judgement (json : Json) : Except WireFailure Json := do
  let id : String ← get json "id"
  let kind : String ← get json "kind"
  let result ← match kind with
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
        throw (WireFailure.syntax "$.max_sample_length" "natural number required")
      let some fuel := fuelText.toNat? |
        throw (WireFailure.syntax "$.max_type_obligations" "natural number required")
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
      let expected : Necoherence.SignatureGeneration.Basis ← get json "expected_basis"
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
      let source ← slotContract (← json.getObjVal? "source")
      let destination ← slotContract (← json.getObjVal? "destination")
      inclusionJudgement library source destination
        (← liftJson (← liftJson (json.getObjVal? "candidates")).getArr?)
    | "projection" => do
      let library ← get json "library"
      let source ← slotContract (← json.getObjVal? "source")
      let destination ← slotContract (← json.getObjVal? "destination")
      let path ← projectionPath (← json.getObjVal? "path")
      projectionJudgement library source destination path (← json.getObjVal? "producer")
        (← liftJson (← liftJson (json.getObjVal? "candidate_slots")).getArr?)
    | "grapheme" => graphemeJudgement (← get json "library") (← get json "text")
    | "construction_solver" => compositionJudgement (← get json "library") (← json.getObjVal? "problem")
    | _ => throw (WireFailure.syntax "$" "unknown invariant input kind")
  let object ← liftJson result.getObj?
  pure (Json.mkObj ([("id", .str id)] ++ object.toList))

def renderCodec (json : Json) : Except WireFailure String := do
  let library : Library ← get json "library"
  let entrypoints := library.definitions.map fun definition =>
    ({ identity := definition.id, definition := definition.id } : Necoherence.SignatureGeneration.Entrypoint)
  let input : Necoherence.SignatureGeneration.Input := {
    basis := Necoherence.SignatureGeneration.basis library entrypoints,
    signatures := library, entrypoints }
  let source ← (NecoherenceTools.SignatureGeneration.generate input input.basis).mapError (fun failure => WireFailure.syntax "$" (reprStr failure))
  let branches ← library.nodes.mapM fun node => do
    let ref : TypeRef ← decode (.str node.id)
    let index ← (NecoherenceTools.SemanticRenderer.nodeIndex library.graph ref).mapError (fun failure => WireFailure.syntax "$" (reprStr failure))
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
    "    match Necoherence.SignatureJson.parse line >>= codecJudgement with\n" ++
    "    | .ok result => output.putStrLn result.compress\n" ++
    "    | .error reason => error.putStrLn reason; return 1\n  return 0\n")

end NecoherenceTools.SemanticInvariantRunner

def main (args : List String) : IO UInt32 := do
  let input ← IO.getStdin
  let output ← IO.getStdout
  let error ← IO.getStderr
  if args == ["--render-codec"] then
    let parsed := Necoherence.SignatureJson.parse (← input.getLine)
    match parsed.mapError (Necoherence.SignatureWire.WireFailure.syntax "$") >>=
        NecoherenceTools.SemanticInvariantRunner.renderCodec with
    | .ok source => output.putStr source; return 0
    | .error reason => error.putStrLn (reprStr reason); return 1
  repeat
    let line ← input.getLine
    if line.isEmpty then break
    if line.trimAscii.toString.isEmpty then continue
    match (Necoherence.SignatureJson.parse line).mapError
        (Necoherence.SignatureWire.WireFailure.syntax "$") >>=
        NecoherenceTools.SemanticInvariantRunner.judgement with
    | .ok result => output.putStrLn result.compress
    | .error reason => error.putStrLn (reprStr reason); return 1
  return 0
