-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import Necoherence.SignatureGeneration
import NecoherenceVerification.SemanticInvariantOutput
import NecoherenceVerification.SemanticReferenceWire

open Lean Necoherence Necoherence.SemanticTypes Necoherence.SemanticValidation
open Necoherence.SignatureWire NecoherenceTools.SemanticInvariantOutput NecoherenceTools.SemanticReferenceWire
set_option maxRecDepth 10000

private def elementDecode (json : Json) : Except WireFailure ElementContract := do
  keys json ["type_ref", "nullable"]
  pure { typeRef := ← getWith typeRefDecode json "type_ref", nullable := ← get json "nullable" }
private def fieldDecode (json : Json) : Except WireFailure FieldSpec := do
  keys json ["wire_name", "slot", "origin"]
  pure { wireName := ← get json "wire_name", slot := ← getWith slotContractDecode json "slot", origin := ← getWith occurrenceRefDecode json "origin" }
private def allowDecode (json : Json) : Except WireFailure ExtraMembers := do
  keys json ["key_format", "value"]
  pure (.allow (← get json "key_format") (← getWith elementDecode json "value"))
private def extraDecode (json : Json) : Except WireFailure ExtraMembers := do
  match (← get (α := String) json "tag") with
  | "Reject" => keys json ["tag"]; pure .reject
  | "Allow" => keys json ["tag", "fields"]; getWith allowDecode json "fields"
  | tag => throw (.unknownTag "$.tag" tag)
private def branchDecode (json : Json) : Except WireFailure UnionBranch := do
  keys json ["target", "wire_tag", "selector", "origin"]
  pure { target := ← getWith typeRefDecode json "target", wireTag := ← get json "wire_tag", selector := ← get json "selector", origin := ← getWith occurrenceRefDecode json "origin" }
private def aliasDecode (json : Json) : Except WireFailure TypeShape := do
  keys json ["target", "reference_text"]
  pure (.alias (← getWith typeRefDecode json "target") (← get json "reference_text"))
private def arrayDecode (json : Json) : Except WireFailure TypeShape := do
  keys json ["item", "min_length", "max_length"]
  pure (.array { item := ← getWith elementDecode json "item", minLength := ← get json "min_length", maxLength := ← get json "max_length" })
private def productDecode (json : Json) : Except WireFailure TypeShape := do
  keys json ["fields", "extras"]
  pure (.product { fields := ← getWith (decodeListWith fieldDecode) json "fields", extras := ← getWith extraDecode json "extras" })
private def taggedUnionDecode (json : Json) : Except WireFailure TypeShape := do
  keys json ["branches"]
  pure (.taggedUnion { branches := ← getWith (decodeListWith branchDecode) json "branches" })
private def shapeDecode (json : Json) : Except WireFailure TypeShape := do
  match (← get (α := String) json "tag") with
  | "Boolean" => keys json ["tag", "value"]; return .boolean (← get json "value")
  | "Integer" => keys json ["tag", "value"]; return .integer (← get json "value")
  | "Decimal" => keys json ["tag", "value"]; return .decimal (← get json "value")
  | "String" => keys json ["tag", "value"]; return .string (← get json "value")
  | "Unknown" => keys json ["tag", "value"]; return .unknown (← get json "value")
  | "Unit" => keys json ["tag"]; return .unit
  | "Never" => keys json ["tag"]; return .never
  | "Alias" => keys json ["tag", "fields"]; getWith aliasDecode json "fields"
  | "Array" => keys json ["tag", "value"]; getWith arrayDecode json "value"
  | "Product" => keys json ["tag", "value"]; getWith productDecode json "value"
  | "TaggedUnion" => keys json ["tag", "value"]; getWith taggedUnionDecode json "value"
  | tag => throw (.unknownTag "$.tag" tag)
private def nodeDecode (json : Json) : Except WireFailure TypeNode := do
  keys json ["reference", "shape", "description", "attributes", "extensions"]
  pure { ref := ← getWith typeRefDecode json "reference", shape := ← getWith shapeDecode json "shape", description := ← get json "description", attributes := ← getWith (decodeListWith occurrenceRefDecode) json "attributes", extensions := ← getWith (decodeListWith occurrenceRefDecode) json "extensions" }
private def graphDecode (json : Json) : Except WireFailure SemanticGraph := do
  keys json ["profile", "nodes", "source_refs"]
  pure { profile := ← get json "profile", nodes := ← getWith (decodeListWith nodeDecode) json "nodes", sourceRefs := ← get json "source_refs" }

private def sourceJson (source : SourceRef) : Json := Json.mkObj [
  ("repository", .str source.repository), ("revision", .str source.revision), ("path", .str source.path),
  ("content_digest", .str source.contentDigest), ("document_id", .str source.documentId), ("declared_revision", encode source.declaredRevision)]
private def refJson (ref : TypeRef) : Json := Json.mkObj [("source", sourceJson ref.source), ("definition_name", .str ref.definitionName), ("pointer", encode ref.pointer)]
private def originJson (origin : OccurrenceRef) : Json := Json.mkObj [("source", sourceJson origin.source), ("pointer", encode origin.pointer)]
private def stepsJson (path : ValuePath) : Json := .arr (path.map fun step =>
  let (tag, value) := match step with | .field name => ("Field", name) | .index index => ("Index", toString index) | .variant tag => ("Variant", tag)
  Json.mkObj [("tag", .str tag), ("value", .str value)]).toArray
private def applicationJson (application : DefaultApplication) : Json := Json.mkObj [
  ("value_path", stepsJson application.valuePath), ("type_ref", refJson application.typeRef),
  ("origin", originJson application.origin), ("value", encode application.value)]
private def applicationsJson (applications : List DefaultApplication) : Json := .arr (applications.map applicationJson).toArray
private def reasonJson (reason : SemanticReason) : Json :=
  let (tag, value) : String × Option String := match reason with
    | .unknownFormat name => ("UnknownFormat", some name)
    | .missingGraphemeRules => ("MissingGraphemeRules", none)
    | .missingBytesPolicy => ("MissingBytesPolicy", none)
    | .unknownIntegerDomain name => ("UnknownIntegerDomain", some name)
    | .unknownWrapper name => ("UnknownWrapper", some name)
    | .wrapperPayload name => ("WrapperPayload", some name)
    | .unknownSealedTag tag => ("UnknownSealedTag", some tag)
    | .decimalNotAdmitted => ("DecimalNotAdmitted", none)
    | .integerBound => ("IntegerBound", none)
    | .opaqueType name => ("OpaqueType", some name)
    | .missingTagModel => ("MissingTagModel", none)
    | .uninterpretedExtension key => ("UninterpretedExtension", some key)
    | .unresolvedType => ("UnresolvedType", none)
    | .invalidProfile condition => ("InvalidProfile", some condition)
    | .membershipBound => ("MembershipBound", none)
    | .certificateMismatch condition => ("CertificateMismatch", some condition)
    | .projectionUnavailable condition => ("ProjectionUnavailable", some condition)
  Json.mkObj ([("tag", .str tag)] ++ value.toList.map fun text => ("value", Json.str text))
private def obligationJson (obligation : SemanticObligation) : Json := Json.mkObj [
  ("type_ref", refJson obligation.typeRef), ("origin", originJson obligation.origin),
  ("value_path", stepsJson obligation.valuePath), ("profile", encode obligation.profile), ("reason", reasonJson obligation.reason)]
private def failed (id : Json) (failure : ValidationFailure) : Json :=
  match failure with
  | .value failure => Json.mkObj [("id", id), ("status", .str "Rejected"), ("type_ref", refJson failure.typeRef),
      ("definition_ref", Json.mkObj [("source", sourceJson failure.definitionRef.source),
        ("name", .str failure.definitionRef.name)]), ("origin", originJson failure.origin),
      ("value_path", stepsJson failure.valuePath), ("condition", encode failure.condition),
      ("observed", encode failure.observed), ("reference_trace", .arr (failure.referenceTrace.map refJson).toArray)]
  | .unresolved obligations => Json.mkObj [("id", id), ("status", .str "Unresolved"), ("obligations", .arr (obligations.map obligationJson).toArray)]
  | .certificateMismatch condition => Json.mkObj [("id", id), ("status", .str "CertificateMismatch"), ("condition", .str condition)]

private partial def uniqueWire : Necoherence.ExactJson.JsonValue → Bool
  | .arr items => items.all uniqueWire
  | .obj members => (members.map (·.1)).eraseDups.length == members.length && members.all (fun member => uniqueWire member.2)
  | _ => true

private def evaluateDecoded (input id : Json) (graph : SemanticGraph) (ref : TypeRef)
    (before : Necoherence.ExactJson.JsonValue) (tamper : Bool) : Except String Json := do
  let mut decoded := before
  match input.getObjVal? "wire" with
  | .ok wire =>
    let text ← wire.getStr?
    if !uniqueWire before then return Json.mkObj [("id", id), ("status", .str "Wire"), ("classification", .str "DuplicateField"), ("path", .str "$")]
    match Necoherence.ExactJson.boundedJsonParse text with
    | .error _ => return Json.mkObj [("id", id), ("status", .str "Wire"), ("classification", .str "Syntax"), ("path", .str "$")]
    | .ok parsed =>
      let expected ← Necoherence.ExactJson.toJson before
      let canonical ← Necoherence.ExactJson.toJson (Necoherence.ExactJson.fromJson parsed)
      if Necoherence.ExactJson.compressJson canonical != Necoherence.ExactJson.compressJson expected then throw "wire and exact input differ"
      decoded := Necoherence.ExactJson.fromJson parsed
  | .error _ => pure ()
  match materializeDefaults graph ref decoded with
  | .error failure => return failed id failure
  | .ok defaulted =>
    let second ← (materializeDefaults graph ref defaulted.value).mapError reprStr
    let mut fields := [("id", id), ("status", .str "Accepted"), ("value", encode defaulted.value),
      ("applications", applicationsJson defaulted.applications), ("second_value", encode second.value),
      ("second_applications", applicationsJson second.applications), ("input", encode before)]
    if tamper then
      let first :: rest := defaulted.applications | throw "application required for certificate probe"
      let wrongRef := { first.typeRef with source := { first.typeRef.source with documentId := first.typeRef.source.documentId ++ "-forged" } }
      let forged : List DefaultApplication := [
        { first with typeRef := wrongRef },
        { first with origin := { first.origin with pointer := first.origin.pointer ++ ["forged"] } },
        { first with valuePath := first.valuePath ++ [.field "forged"] },
        { first with value := .bool true }]
      fields := fields ++ [("certificates", .arr (forged.map fun item => Json.bool (checkDefaultApplications graph decoded defaulted.value (item :: rest))).toArray)]
    return Json.mkObj fields

private def decodeCase (input : Json) :
    Except WireFailure (SemanticGraph × TypeRef × Necoherence.ExactJson.JsonValue × Bool) := do
  pure (← getWith graphDecode input "graph", ← getWith typeRefDecode input "reference", ← get input "before", ← get input "tamper")

private def evaluate (input : Json) : Except String Json := do
  let id ← (input.getObjVal? "id")
  match decodeCase input with
  | .error failure => return Json.mkObj [("id", id), ("status", .str "Wire"), ("classification", .str (wireFailureClassification failure)), ("path", .str (wireFailurePath failure))]
  | .ok (graph, ref, before, tamper) => evaluateDecoded input id graph ref before tamper

def main : IO Unit := do
  let input ← IO.getStdin
  let output ← IO.getStdout
  repeat
    let line ← input.getLine
    if line.isEmpty then break
    let json ← match Necoherence.ExactJson.boundedJsonParse line with
      | .ok json => pure json
      | .error message => throw (IO.userError message)
    let result ← match evaluate json with
      | .ok result => pure result
      | .error message => throw (IO.userError message)
    output.putStrLn (Necoherence.ExactJson.compressJson result)
