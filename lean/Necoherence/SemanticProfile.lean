-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Lean.Data.Json
import Necoherence.SemanticTypes
import Necoherence.Sha256
import Necoherence.SemanticValidation
import Necoherence.SignatureProfileWire

namespace Necoherence.SemanticProfile

open Necoherence.SemanticTypes

inductive ProfileDecodeFailure where
  | invalidJson (message : String)
  | invalidField (path : String) (expected : String)
  | missingField (path : String)
  | unknownField (path : String)
  | basisMismatch
  | digestMismatch
  deriving BEq, Repr

abbrev DecodeM := Except ProfileDecodeFailure

private def field (value : Lean.Json) (path name : String) : DecodeM Lean.Json := do
  match value.getObjVal? name with
  | .ok result => pure result
  | .error _ => .error (.missingField (path ++ "." ++ name))

private def text (value : Lean.Json) (path : String) : DecodeM String :=
  match value with
  | .str result => .ok result
  | _ => .error (.invalidField path "string")

private def natural (value : Lean.Json) (path : String) : DecodeM Nat :=
  match value.getNat? with
  | .ok result => .ok result
  | .error _ => .error (.invalidField path "natural number")

private def boolean (value : Lean.Json) (path : String) : DecodeM Bool :=
  match value with
  | .bool result => .ok result
  | _ => .error (.invalidField path "boolean")

private def array (value : Lean.Json) (path : String) : DecodeM (Array Lean.Json) :=
  match value.getArr? with
  | .ok result => .ok result
  | .error _ => .error (.invalidField path "array")
private def stringArray (value : Lean.Json) (path : String) : DecodeM (List String) := do
  let values ← array value path
  values.toList.mapM fun item => text item path

private def stringField (value : Lean.Json) (path name : String) : DecodeM String := do
  text (← field value path name) (path ++ "." ++ name)

private def natField (value : Lean.Json) (path name : String) : DecodeM Nat := do
  natural (← field value path name) (path ++ "." ++ name)

private def boolField (value : Lean.Json) (path name : String) : DecodeM Bool := do
  boolean (← field value path name) (path ++ "." ++ name)

private def exactKeys (value : Lean.Json) (path : String) (expected : List String) : DecodeM Unit := do
  let object ← match value.getObj? with
    | .ok object => pure object
    | .error _ => throw (.invalidField path "object")
  let keys := object.toList.map Prod.fst
  for key in keys do
    if !expected.contains key then throw (.unknownField (path ++ "." ++ key))
  for key in expected do
    if !(keys.contains key) then throw (.missingField (path ++ "." ++ key))

private def sourceRefs (value : Lean.Json) (expected : List SourceIdentity) : DecodeM (List SourceIdentity) := do
  let rows ← array value "basis.sources"
  if rows.size != expected.length then throw .basisMismatch
  let decoded ← rows.toList.zip expected |>.mapM fun (row, basisSource) => do
    exactKeys row "basis.sources[]" ["repository", "revision", "path", "sha256"]
    let repository ← stringField row "basis.sources[]" "repository"
    let revision ← stringField row "basis.sources[]" "revision"
    let sourcePath ← stringField row "basis.sources[]" "path"
    let digest ← stringField row "basis.sources[]" "sha256"
    if repository != basisSource.repository || revision != basisSource.revision || sourcePath != basisSource.path || digest != basisSource.contentDigest then throw .basisMismatch
    pure basisSource
  pure decoded

private def rangeValues (value : Lean.Json) (path : String) (withProperty : Bool) : DecodeM (List Lean.Json) := do
  let rows ← array value path
  let mut previous : Option Nat := none
  for (row, i) in rows.toList.zipIdx do
    let p := path ++ "[" ++ toString i ++ "]"
    let tuple ← array row p
    let expectedLength := if withProperty then 3 else 2
    if tuple.size != expectedLength then throw (.invalidField p "range tuple")
    let first ← natural tuple[0]! (p ++ "[0]")
    let last ← natural tuple[1]! (p ++ "[1]")
    if first > last || last > 0x10ffff || (first ≤ 0xdfff && 0xd800 ≤ last) || (previous.any (fun prior => first ≤ prior)) then
      throw (.invalidField p "sorted disjoint Unicode scalar range")
    previous := some last
  pure rows.toList

private def gcb : String → Option GraphemeProperty
  | "Other" => some .other | "CR" => some .cr | "LF" => some .lf
  | "Control" => some .control | "Extend" => some .extend | "ZWJ" => some .zwj
  | "Regional_Indicator" => some .regionalIndicator | "Prepend" => some .prepend
  | "SpacingMark" => some .spacingMark | "L" => some .l | "V" => some .v
  | "T" => some .t | "LV" => some .lv | "LVT" => some .lvt | _ => none

private def incb : String → Option IndicProperty
  | "None" => some .other | "Consonant" => some .consonant
  | "Extend" => some .extend | "Linker" => some .linker | _ => none

/-- JCS bytes for the three integer-and-enumeration Unicode tables. Keys are in JCS
order and range rows retain their Unicode order. The profile's `tableSha256`
field binds these exact bytes. -/
def graphemeTableBytes (properties extendedPictographic indicConjunct : List Lean.Json) : String :=
  (Lean.Json.mkObj [
    ("extended_pictographic", .arr extendedPictographic.toArray),
    ("indic_conjunct", .arr indicConjunct.toArray),
    ("properties", .arr properties.toArray)]).compress

/-- A decoded Unicode table carries the checked SHA-256 equality. -/
structure GraphemeTable where
  properties : List Lean.Json
  extendedPictographic : List Lean.Json
  indicConjunct : List Lean.Json
  tableSha256 : String
  checksum : Necoherence.Sha256.digest
    (graphemeTableBytes properties extendedPictographic indicConjunct) = tableSha256

/-- Decodes the profile's three arrays and binds `tableSha256` to their JCS bytes. -/
def decodeGraphemeTable (value : Lean.Json) : DecodeM GraphemeTable := do
  let properties ← rangeValues (← field value "grapheme" "properties") "grapheme.properties" true
  let extendedPictographic ← rangeValues
    (← field value "grapheme" "extended_pictographic") "grapheme.extended_pictographic" false
  let indicConjunct ← rangeValues (← field value "grapheme" "indic_conjunct") "grapheme.indic_conjunct" true
  let tableSha256 ← stringField value "grapheme" "table_sha256"
  if checksum : Necoherence.Sha256.digest
      (graphemeTableBytes properties extendedPictographic indicConjunct) = tableSha256 then
    pure { properties, extendedPictographic, indicConjunct, tableSha256, checksum }
  else throw (.invalidField "grapheme.table_sha256" "matching canonical table SHA-256")

/-- Accepted table decoding implies `tableSha256` equals SHA-256 of the three arrays' JCS bytes. -/
theorem graphemeTableChecksumSound (value : Lean.Json) (table : GraphemeTable)
    (_accepted : decodeGraphemeTable value = .ok table) :
    table.tableSha256 = Necoherence.Sha256.digest
      (graphemeTableBytes table.properties table.extendedPictographic table.indicConjunct) :=
  table.checksum.symm

private abbrev DecodedGrapheme (value : Lean.Json) := { rules : GraphemeRules //
  ∃ table, decodeGraphemeTable value = .ok table ∧ rules.tableSha256 =
    Necoherence.Sha256.digest
      (graphemeTableBytes table.properties table.extendedPictographic table.indicConjunct) }

private def grapheme (value : Lean.Json) (reference : ProfileRef) (expectedSources : List SourceIdentity) :
    DecodeM (DecodedGrapheme value) := do
  let path := "grapheme"
  exactKeys value path ["version","properties","extended_pictographic","indic_conjunct","uax29_revision","profile","ranges","sources","table_sha256"]
  let sourceRows ← array (← field value path "sources") "grapheme.sources"
  let roles := ["grapheme_break_property","emoji_data","derived_core_properties","grapheme_break_test","license","uax29"]
  let sources ← sourceRows.toList.mapM fun row => do
    exactKeys row "grapheme.sources[]" ["role","path"]
    let role ← stringField row "grapheme.sources[]" "role"
    let sourcePath ← stringField row "grapheme.sources[]" "path"
    if !roles.contains role then throw (.invalidField "grapheme.sources.role" "Unicode source role")
    let some source := expectedSources.find? (fun source => source.path == sourcePath) |
      throw .basisMismatch
    pure { role, origin := { source, locator := [] } : GraphemeSource }
  if sources.length != roles.length || roles.any (fun role => (sources.filter (·.role == role)).length != 1) then
    throw (.invalidField "grapheme.sources" "six unique Unicode source roles")
  if (← stringField value path "version") != "16.0.0" || (← natField value path "uax29_revision") != 45 || (← stringField value path "profile") != "C1-1-default-extended-grapheme-cluster-no-tailoring" || (← stringField value path "ranges") != "inclusive Unicode scalar values represented as integers" then
    throw (.invalidField path "pinned Unicode 16.0 UAX #29 revision 45 profile")
  let certified ← match decoded : decodeGraphemeTable value with
    | .error failure => throw failure
    | .ok table => pure (⟨table, decoded⟩ : { table // decodeGraphemeTable value = .ok table })
  let table := certified.val
  let propertyRows := table.properties
  let epRows := table.extendedPictographic
  let indicRows := table.indicConjunct
  let tableSha256 := table.tableSha256
  let properties ← propertyRows.mapM fun row => do
    let tuple := (← array row "grapheme.properties[]").toList
    let first ← natural tuple[0]! "properties.first"
    let last ← natural tuple[1]! "properties.last"
    let name ← text tuple[2]! "properties.property"
    let property ← match gcb name with
      | some value => pure value
      | none => throw (.invalidField "properties.property" "GCB property")
    pure { first, last, property }
  let extendedPictographic ← epRows.mapM fun row => do
    let tuple := (← array row "grapheme.extended_pictographic[]").toList
    pure { first := (← natural tuple[0]! "ep.first"), last := (← natural tuple[1]! "ep.last") }
  let indicConjunct ← indicRows.mapM fun row => do
    let tuple := (← array row "grapheme.indic_conjunct[]").toList
    let name ← text tuple[2]! "indic.property"
    let property ← match incb name with
      | some value => pure value
      | none => throw (.invalidField "indic.property" "InCB property")
    pure { first := (← natural tuple[0]! "indic.first"), last := (← natural tuple[1]! "indic.last"), property }
  pure ⟨{ reference, properties, extendedPictographic, indicConjunct, component := {}, tableSha256, sources },
    table, certified.property, table.checksum.symm⟩

/-- Accepted grapheme decoding retains the digest of the decoded table's JCS bytes. -/
theorem graphemeDecodeChecksumSound (value : Lean.Json) (reference : ProfileRef)
    (sources : List SourceIdentity) (rules : DecodedGrapheme value)
    (_accepted : grapheme value reference sources = .ok rules) :
    ∃ table, decodeGraphemeTable value = .ok table ∧ rules.val.tableSha256 =
      Necoherence.Sha256.digest
        (graphemeTableBytes table.properties table.extendedPictographic table.indicConjunct) :=
  rules.property

inductive ProfileAdmissionFailure where
  | syntax (failure : ProfileDecodeFailure)
  | wire (failure : Necoherence.SignatureWire.WireFailure)
  | profile (failure : ProfileFailure)
  deriving BEq, Repr

def decodeCanonical (expected : ProfileRef) (expectedSources : List SourceIdentity)
    (value : Lean.Json) : Except ProfileAdmissionFailure CheckedProfile := do
  let profile ← (Necoherence.SignatureWire.decode value).mapError
    ProfileAdmissionFailure.wire
  if profile.reference != expected || profile.sourceRefs != expectedSources then
    throw (.syntax .basisMismatch)
  (Necoherence.SemanticValidation.checkProfile profile).mapError ProfileAdmissionFailure.profile

def decodeProfileJson (expected : ProfileRef) (expectedSources : List SourceIdentity)
    (expectedProfileBytes input : String) : Except ProfileAdmissionFailure CheckedProfile := do
  if expected.contentDigest.isEmpty || input != expectedProfileBytes then
    throw (.syntax .digestMismatch)
  let parsed ← match Lean.Json.parse input with
    | .ok json => pure json
    | .error message => throw (.syntax (.invalidJson message))
  decodeCanonical expected expectedSources parsed
end Necoherence.SemanticProfile
