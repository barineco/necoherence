-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import Necoherence.SignatureGeneration
import NecoherenceTools.SemanticInvariantOutput

open Lean Necoherence Necoherence.SemanticTypes Necoherence.SemanticValidation
open Necoherence.SignatureWire NecoherenceTools.SemanticInvariantOutput
set_option maxRecDepth 10000

private def field (json : Json) (key : String) : Except String Json := json.getObjVal? key
private def wire {α : Type} [Wire α] (json : Json) : Except String α := (decode json).mapError reprStr
private def getWire {α : Type} [Wire α] (json : Json) (key : String) : Except String α := do wire (← field json key)
private def sourceDecode (json : Json) : Except String SourceRef := do
  pure { repository := ← getWire json "repository", revision := ← getWire json "revision", path := ← getWire json "path", contentDigest := ← getWire json "content_digest", documentId := ← getWire json "document_id", declaredRevision := ← getWire json "declared_revision" }
private def refDecode (json : Json) : Except String TypeRef := do
  pure { source := ← sourceDecode (← field json "source"), definitionName := ← getWire json "definition_name", pointer := ← getWire json "pointer" }
private def originDecode (json : Json) : Except String OccurrenceRef := do
  pure { source := ← sourceDecode (← field json "source"), pointer := ← getWire json "pointer" }
private def listDecode {α : Type} (decoder : Json → Except String α) (json : Json) : Except String (List α) := do
  (← json.getArr?).toList.mapM decoder
private def slotDecode (json : Json) : Except String SlotContract := do
  pure { typeRef := ← refDecode (← field json "type_ref"), required := ← getWire json "required", nullable := ← getWire json "nullable" }
private def elementDecode (json : Json) : Except String ElementContract := do
  pure { typeRef := ← refDecode (← field json "type_ref"), nullable := ← getWire json "nullable" }
private def fieldDecode (json : Json) : Except String FieldSpec := do
  pure { wireName := ← getWire json "wire_name", slot := ← slotDecode (← field json "slot"), origin := ← originDecode (← field json "origin") }
private def extraDecode (json : Json) : Except String ExtraMembers := do
  match (← getWire (α := String) json "tag") with
  | "Reject" => pure .reject
  | "Allow" =>
    let json ← field json "fields"
    pure (.allow (← getWire json "key_format") (← elementDecode (← field json "value")))
  | tag => throw ("extra members tag: " ++ tag)
private def branchDecode (json : Json) : Except String UnionBranch := do
  pure { target := ← refDecode (← field json "target"), wireTag := ← getWire json "wire_tag", selector := ← getWire json "selector", origin := ← originDecode (← field json "origin") }
private def shapeDecode (json : Json) : Except String TypeShape := do
  match (← getWire (α := String) json "tag") with
  | "Boolean" => return .boolean (← getWire json "value")
  | "Integer" => return .integer (← getWire json "value")
  | "String" => return .string (← getWire json "value")
  | "Unknown" => return .unknown (← getWire json "value")
  | "Unit" => return .unit
  | "Never" => return .never
  | "Alias" =>
    let json ← field json "fields"
    return .alias (← refDecode (← field json "target")) (← getWire json "reference_text")
  | "Array" =>
    let json ← field json "value"
    return .array { item := ← elementDecode (← field json "item"), minLength := ← getWire json "min_length", maxLength := ← getWire json "max_length" }
  | "Product" =>
    let json ← field json "value"
    return .product { fields := ← listDecode fieldDecode (← field json "fields"), extras := ← extraDecode (← field json "extras") }
  | "TaggedUnion" =>
    let json ← field json "value"
    return .taggedUnion { branches := ← listDecode branchDecode (← field json "branches") }
  | tag => throw ("type shape: " ++ tag)
private def nodeDecode (json : Json) : Except String TypeNode := do
  pure { ref := ← refDecode (← field json "reference"), shape := ← shapeDecode (← field json "shape"), description := ← getWire json "description", attributes := ← listDecode originDecode (← field json "attributes"), extensions := ← listDecode originDecode (← field json "extensions") }
private def graphDecode (json : Json) : Except String SemanticGraph := do
  pure { profile := ← getWire json "profile", nodes := ← listDecode nodeDecode (← field json "nodes"), sourceRefs := ← listDecode sourceDecode (← field json "source_refs") }

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
      ("origin", originJson failure.origin), ("value_path", stepsJson failure.valuePath),
      ("condition", .str (conditionName failure.condition)), ("reference_trace", .arr (failure.referenceTrace.map refJson).toArray)]
  | .unresolved obligations => Json.mkObj [("id", id), ("status", .str "Unresolved"), ("obligations", .arr (obligations.map obligationJson).toArray)]
  | .certificateMismatch condition => Json.mkObj [("id", id), ("status", .str "CertificateMismatch"), ("condition", .str condition)]

private partial def uniqueWire : Necoherence.ExactJson.JsonValue → Bool
  | .arr items => items.all uniqueWire
  | .obj members => (members.map (·.1)).eraseDups.length == members.length && members.all (fun member => uniqueWire member.2)
  | _ => true

private def evaluate (input : Json) : Except String Json := do
  let id ← field input "id"
  let graph ← graphDecode (← field input "graph")
  let ref ← refDecode (← field input "reference")
  let before : Necoherence.ExactJson.JsonValue ← getWire input "before"
  let tamper : Bool ← getWire input "tamper"
  match input.getObjVal? "wire" with
  | .ok wire =>
    let text ← wire.getStr?
    if !uniqueWire before then return Json.mkObj [("id", id), ("status", .str "Wire"), ("classification", .str "DuplicateField")]
    match Json.parse text with
    | .error _ => return Json.mkObj [("id", id), ("status", .str "Wire"), ("classification", .str "Syntax")]
    | .ok parsed =>
      let expected ← Necoherence.ExactJson.toJson before
      if parsed.compress != expected.compress then throw "wire and exact input differ"
  | .error _ => pure ()
  match materializeDefaults graph ref before with
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
      fields := fields ++ [("certificates", .arr (forged.map fun item => Json.bool (checkDefaultApplications graph before defaulted.value (item :: rest))).toArray)]
    return Json.mkObj fields

def main : IO Unit := do
  let input ← IO.getStdin
  let output ← IO.getStdout
  repeat
    let line ← input.getLine
    if line.isEmpty then break
    let json ← match Json.parse line with
      | .ok json => pure json
      | .error message => throw (IO.userError message)
    let result ← match evaluate json with
      | .ok result => pure result
      | .error message => throw (IO.userError message)
    output.putStrLn result.compress
