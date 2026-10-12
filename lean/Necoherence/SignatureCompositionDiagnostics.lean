-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SignatureCompositionDiagnosticsSchema
import Necoherence.SignatureCompositionStateWire

namespace Necoherence.SignatureCompositionDiagnostics
open Lean Necoherence.SemanticTypes Necoherence.SemanticComposition Necoherence.SignatureWire

private def resolveProducer (input : CompositionInput) : ProducerRef → Bool
  | .initial id => input.initialInputs.any (fun value => value.id == id)
  | .invocationOutcome site outcome port => (input.invocationDomain.sites.find? (fun value => value.id == site)).any fun invocation =>
      (input.signatures.find? (fun value => value.reference == invocation.function)).any fun function =>
        (function.outcomes.find? (fun value => value.id == outcome)).any fun result => result.valuePorts.any (fun value => value.id == port)
private def resolveLot (input : CompositionInput) : ResourceLotRef → Bool
  | .initial id => input.initialResources.any (fun lot => lot.id == id)
  | .produced site outcome production => (input.invocationDomain.sites.find? (fun value => value.id == site)).any fun invocation =>
      (input.signatures.find? (fun value => value.reference == invocation.function)).any fun function =>
        (function.outcomes.find? (fun value => value.id == outcome)).any fun result => result.producedResources.any (fun value => value.id == production)

private def reachesType (library : Necoherence.TypeSignatures.TypeSignatureLibrary) (typeId : String) :
    Nat → List String → List String → Bool
  | 0, _, _ => false
  | _ + 1, [], _ => false
  | fuel + 1, id :: pending, seen =>
    if id == typeId then true
    else if seen.contains id then reachesType library typeId fuel pending seen
    else
      let children := (library.nodes.find? (fun node => node.id == id)).map
        (fun node => node.shape.references) |>.getD []
      reachesType library typeId fuel (pending ++ children) (id :: seen)

private def targetContainsType (library : Necoherence.TypeSignatures.TypeSignatureLibrary)
    (target : Necoherence.TypeSignatures.Target) (typeId : String) : Bool :=
  let roots : List String := match target with
    | .type id => [id]
    | .definition id => match (library.definitions.find? (fun definition => definition.id == id)).map (·.shape) with
      | some (Necoherence.TypeSignatures.DefinitionShape.value root) => [root]
      | some (Necoherence.TypeSignatures.DefinitionShape.message root) => [root]
      | _ => []
    | .outcome definition outcome =>
      match (library.definitions.find? (fun candidate => candidate.id == definition)).map (·.shape) with
      | some (Necoherence.TypeSignatures.DefinitionShape.operation operation) =>
        (operation.outcomes.find? (fun candidate => candidate.id == outcome)).map
          (fun candidate => candidate.valuePorts.map (·.contract.typeId)) |>.getD []
      | _ => []
    | _ => []
  let bound := library.nodes.length + roots.length +
    library.nodes.foldl (fun count node => count + node.shape.references.length) 1
  reachesType library typeId bound roots []

private def references (library : Necoherence.TypeSignatures.TypeSignatureLibrary) (input : CompositionInput)
    (name : String) (json : Json) : Except WireFailure Unit := do
  match name with
  | "TypeId" =>
    let id ← liftJson json.getStr?
    if !library.nodes.any (fun node => node.id == id) then throw (WireFailure.syntax "$" "unresolved diagnostic type_id")
  | "DefinitionId" =>
    let id ← liftJson json.getStr?
    if !library.definitions.any (fun definition => definition.id == id) then throw (WireFailure.syntax "$" "unresolved diagnostic definition")
  | "FunctionRef" =>
    let reference : FunctionRef ← decode json
    if !input.signatures.any (fun function => function.reference == reference) then throw (WireFailure.syntax "$" "unresolved diagnostic function")
  | "ProducerRef" =>
    let producer : ProducerRef ← decode json
    if !resolveProducer input producer then throw (WireFailure.syntax "$" "unresolved diagnostic producer")
  | "ResourceLotRef" =>
    let lot : ResourceLotRef ← decode json
    if !resolveLot input lot then throw (WireFailure.syntax "$" "unresolved diagnostic lot")
  | "SourceIdentity" =>
    let identity : Necoherence.SemanticTypes.SourceIdentity ← decode json
    let synthetic : Necoherence.SemanticTypes.SourceIdentity := {
      repository := "ncoh-type-signatures@1", revision := library.revision,
      path := library.identity, contentDigest := (Necoherence.SignatureGeneration.basis library []).graphSha256 }
    if identity != synthetic && !library.sources.contains identity && !library.profile.sourceRefs.contains identity then
      throw (WireFailure.syntax "$" "unresolved diagnostic source")
  | "AnnotationTarget" =>
    let target : Necoherence.TypeSignatures.Target ← decode json
    if !Necoherence.TypeSignatures.targetValid library target then throw (WireFailure.syntax "$" "unresolved diagnostic target")
  | "ValueFailure" =>
    let target : Necoherence.TypeSignatures.Target ← get json "target"
    let id : String ← get json "type_id"
    if !targetContainsType library target id then throw (WireFailure.syntax "$" "diagnostic target does not contain type_id")
  | "SemanticBasis" =>
    let supplied : Necoherence.SignatureGeneration.Basis ← decode json
    if supplied != Necoherence.SignatureGeneration.basis library [] then throw (WireFailure.syntax "$" "diagnostic basis mismatch")
  | "MissingSupply" =>
    let site : Option SiteId ← get json "site"
    let port : String ← get json "port"
    let valid := match site with
      | none => input.goal.outputs.any (fun output => output.id.value == port)
      | some site => (input.invocationDomain.sites.find? (fun value => value.id == site)).any fun invocation =>
          (input.signatures.find? (fun function => function.reference == invocation.function)).any fun function =>
            function.inputs.any (fun input => input.id.value == port)
    if !valid then throw (WireFailure.syntax "$" "unresolved diagnostic destination")
  | "InvocationPlan" =>
    let site : SiteId ← get json "site"
    let function : FunctionRef ← get json "function"
    if !input.invocationDomain.sites.any (fun invocation => invocation.id == site && invocation.function == function) then
      throw (WireFailure.syntax "$" "unresolved diagnostic invocation")
    let some declaration := input.signatures.find? (fun declaration => declaration.reference == function) |
      throw (WireFailure.syntax "$" "unresolved diagnostic function")
    for pair in (← liftJson ((← liftJson (json.getObjVal? "bindings")).getArr?)) do
      let id ← liftJson ((← liftJson pair.getArr?)[0]!.getStr?)
      if !declaration.inputs.any (fun port => port.id.value == id) then throw (WireFailure.syntax "$" "unresolved diagnostic input port")
    for binding in (← liftJson ((← liftJson (json.getObjVal? "resources")).getArr?)) do
      let id : String ← get binding "requirement"
      if !declaration.resourceInputs.any (fun requirement => requirement.id.value == id) then
        throw (WireFailure.syntax "$" "unresolved diagnostic resource requirement")
  | "ReturnPlan" =>
    if (← get (α := String) json "tag") == "Success" then
      for pair in (← liftJson ((← liftJson (json.getObjVal? "value")).getArr?)) do
        let id ← liftJson ((← liftJson pair.getArr?)[0]!.getStr?)
        if !input.goal.outputs.any (fun output => output.id.value == id) then throw (WireFailure.syntax "$" "unresolved diagnostic goal port")
    else
      let id : String ← get (← liftJson (json.getObjVal? "fields")) "embedding"
      if !input.goal.failures.any (fun embedding => embedding.id.value == id) then throw (WireFailure.syntax "$" "unresolved diagnostic failure embedding")
  | "BindingExpr" =>
    if (← get (α := String) json "tag") == "Product" then
      let construction : String ← get (← liftJson (json.getObjVal? "fields")) "construction"
      if !input.invocationDomain.permittedConstructions.any (fun rule => rule.identity == construction) then
        throw (WireFailure.syntax "$" "unresolved diagnostic construction")
  | "TraceStep" =>
    let row ← liftJson (json.getObjVal? "fields")
    if (← get (α := String) json "tag") == "Guard" then
      let guard : GuardId ← get row "guard"
      if !input.invocationDomain.guards.any (fun declaration => declaration.id == guard) then
        throw (WireFailure.syntax "$" "unresolved diagnostic guard")
    else
      let invocation ← liftJson (row.getObjVal? "invocation")
      let function : FunctionRef ← get invocation "function"
      let outcome : OutcomeId ← get row "outcome"
      if !(input.signatures.find? (fun declaration => declaration.reference == function)).any
          (fun declaration => declaration.outcomes.any (fun result => result.id == outcome)) then
        throw (WireFailure.syntax "$" "unresolved diagnostic outcome")
  | _ => pure ()

private def pattern (expression text : String) : Bool :=
  if expression == "^(0|[1-9][0-9]*)$" then text.toNat?.any (fun value => toString value == text)
  else if expression == "^(0|-?[1-9][0-9]*)$" then text.toInt?.any (fun value => toString value == text)
  else if expression == "^[0-9a-f]{64}$" then
    text.utf8ByteSize == 64 && text.toList.all (fun character => character.isDigit || ('a' ≤ character && character ≤ 'f'))
  else match Necoherence.SignatureJson.parse text with
    | .ok (.num _) => true
    | _ => false

private partial def validate (registry : Json) (library : Necoherence.TypeSignatures.TypeSignatureLibrary)
    (input : CompositionInput) (schema value : Json) : Except WireFailure Unit := do
  if schema == Json.bool false then throw (WireFailure.syntax "$" "diagnostic extra array item")
  if schema == Json.bool true then return
  if let .ok reference := schema.getObjValAs? String "$ref" then
    let name := (reference.drop "#/$defs/".length).toString
    validate registry library input (← registry.getObjVal? name) value
    references library input name value
    return
  if let .ok expected := liftJson (schema.getObjVal? "const") then
    if value != expected then throw (WireFailure.syntax "$" "diagnostic tag mismatch")
  for key in ["oneOf", "anyOf"] do
    if let .ok variants := schema.getObjValAs? (Array Json) key then
      if !(variants.toList.any (fun variant => (validate registry library input variant value).isOk)) then
        throw (WireFailure.syntax "$" "diagnostic variant mismatch")
      return
  if let .ok kind := schema.getObjValAs? String "type" then
    match kind with
    | "null" => if value != .null then throw (WireFailure.syntax "$" "diagnostic null expected")
    | "boolean" => let _ ← liftJson value.getBool?; pure ()
    | "string" =>
      let text ← liftJson value.getStr?
      if let .ok expression := schema.getObjValAs? String "pattern" then
        if !pattern expression text then throw (WireFailure.syntax "$" "diagnostic string domain")
    | "object" =>
      let object ← liftJson value.getObj?
      let properties ← liftJson ((← liftJson (schema.getObjVal? "properties")).getObj?)
      let required ← liftJson (schema.getObjValAs? (Array String) "required")
      for key in required do
        let _ ← liftJson (value.getObjVal? key)
      for (key, member) in object.toList do
        let property ← liftJson (properties[key]?.toExcept "diagnostic closed object field")
        validate registry library input property member
    | "array" =>
      let values ← liftJson value.getArr?
      if let .ok minimum := schema.getObjValAs? Nat "minItems" then
        if values.size < minimum then throw (WireFailure.syntax "$" "diagnostic short array")
      if let .ok maximum := schema.getObjValAs? Nat "maxItems" then
        if maximum < values.size then throw (WireFailure.syntax "$" "diagnostic long array")
      let initialItems := (schema.getObjValAs? (Array Json) "prefixItems").toOption.getD #[]
      for index in [:values.size] do
        let child ← match initialItems[index]? with
          | some child => pure child
          | none => liftJson (schema.getObjVal? "items")
        validate registry library input child values[index]!
    | _ => throw (WireFailure.syntax "$" "unsupported diagnostic schema type")

def check (library : Necoherence.TypeSignatures.TypeSignatureLibrary) (input : CompositionInput)
    (name : String) (json : Json) : Except WireFailure Unit := do
  let registry ← Necoherence.SignatureJson.parse schemaText
  validate registry library input (Json.mkObj [("$ref", .str ("#/$defs/" ++ name))]) json

end Necoherence.SignatureCompositionDiagnostics
