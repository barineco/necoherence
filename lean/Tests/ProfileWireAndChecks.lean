-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SignatureGenerationBasis

open Necoherence.SemanticTypes Necoherence.TypeSignatures Necoherence.SignatureWire

private def reference : ProfileRef :=
  { identity := "profile", revision := "4", contentDigest := String.ofList (List.replicate 64 'a') }

private def roundtrip [BEq α] [Wire α] (value : α) : Bool :=
  let document := encode value
  match decode document with
  | .ok decoded => decoded == value && encode decoded == document
  | .error _ => false

private def addField (json : Lean.Json) (key : String) (value : Lean.Json) : Lean.Json :=
  match json.getObj? with
  | .ok object => Lean.Json.mkObj (object.toList ++ [(key, value)])
  | .error _ => json

private def replaceField (json : Lean.Json) (key : String) (value : Lean.Json) : Lean.Json :=
  match json.getObj? with
  | .ok object => Lean.Json.mkObj ((object.toList.filter (fun field => field.1 != key)) ++ [(key, value)])
  | .error _ => json

private def rejectsUnknownField [Wire α] (field : String) (json : Lean.Json) : Bool :=
  match decode (α := α) json with
  | .error (.unknownField _ actual) => actual == field
  | _ => false

private def rejectsUnknownTag [Wire α] (tag : String) (json : Lean.Json) : Bool :=
  match decode (α := α) json with
  | .error (.unknownTag _ actual) => actual == tag
  | _ => false


private def formats : List FormatRule :=
  [ .asciiDfa {
      stateCount := 1
      initialState := 0
      acceptingStates := [0]
      transitions := [] }
  , .timestamp {
      allowSecond60 := false
      minimumYear := 0
      maximumYear := 9999
      rejectUtcYearOutsideRange := true }
  , .choice [.text]
  , .identifier "a" "a" none 1 (some 2) []
  , .absoluteUri none
  , .languageTag []
  , .literal "x"
  , .sequence [.text]
  , .optional .text
  , .labels "." 1 none none .text
  , .bounded .unicodeScalars 2 .text
  , .text
  , .not (.literal "x") ]

private def profile : VersionedSemanticProfile :=
  { reference
    integerDomains := [{
      name := "integer"
      reference
      range := .inclusive (-1) 1
      forms := [.number, .integralDecimal, .decimalString] }]
    defaultIntegerDomain := "integer"
    numbers := { decimals := true }
    formatBindings := formats.zipIdx.map fun (rule, index) =>
      { name := "f" ++ toString index
        reference
        rule }
    bytesPolicy := some {
      reference
      paddingOptional := true
      alphabet := .either
      strictPadBits := true
      wrapper := some "bytes" }
    wrappers := [
      { name := "bytes"
        key := "bytes"
        payload := .bytes },
      { name := "text"
        key := "text"
        payload := .text none }]
    tag := some {
      key := "tag"
      format := none
      sealed := [{
        tag := "sealed"
        fields := []
        extras := .reject }] } }
private def valueProfile : ValueProfile :=
  { reference := profile.reference
    sourceRefs := profile.sourceRefs
    integerDomains := profile.integerDomains
    defaultIntegerDomain := profile.defaultIntegerDomain
    numbers := profile.numbers
    graphemeRules := profile.graphemeRules
    formatBindings := profile.formatBindings
    bytesPolicy := profile.bytesPolicy
    wrappers := profile.wrappers
    tag := profile.tag }

private def library : TypeSignatureLibrary :=
  { identity := "library"
    revision := "4"
    profile := valueProfile
    nodes := []
    definitions := [] }

private def input : Necoherence.SignatureGeneration.Input :=
  { basis := Necoherence.SignatureGeneration.basis library []
    signatures := library
    entrypoints := [] }

private def shapes : List Shape :=
  [ Shape.unknown .any
  , Shape.unknown .ordinaryObject
  , Shape.unit
  , Shape.boolean {}
  , Shape.integer { domain := some "integer" }
  , Shape.decimal {}
  , Shape.string {}
  , Shape.bytes {}
  , Shape.product {
      fields := []
      extras := .reject }
  , Shape.array {
      item := { typeId := "unit" } }
  , Shape.taggedUnion { branches := [{
      target := "unit"
      wireTag := "unit"
      selector := .kind .null }] }
  , Shape.sealed "sealed" []
  , Shape.never
  , Shape.alias "unit"
  , Shape.rawBody "raw"
  , Shape.opaque "opaque" ]

private def conditions : List ValueCondition :=
  [ .missingRequired, .nullNotAllowed, .wrongValueKind "string", .constMismatch,
    .enumMismatch, .belowMinimum, .aboveMaximum, .integerDomain, .stringLength,
    .arrayLength, .bytesLength, .format "f", .invalidBytes, .invalidWrapper "text",
    .invalidTag, .reservedForm, .noBranchSelected, .keyFormat "key", .uninhabited,
    .duplicateField "key", .unexpectedField "key", .invalidDataModel, .referenceCycle ]

private def checks : List (String × Bool) :=
  [ ("profile", roundtrip profile)
  , ("profile-reference", roundtrip reference)
  , ("integer-domain", roundtrip (IntegerDomain.inclusive (-1) 1))
  , ("integer-form", roundtrip IntegerForm.decimalString)
  , ("integer-binding", roundtrip ({
      name := "integer", reference, range := .inclusive (-1) 1,
      forms := [.number, .integralDecimal, .decimalString] } : IntegerDomainBinding))
  , ("number-model", roundtrip profile.numbers)
  , ("bytes-alphabet", roundtrip BytesAlphabet.either)
  , ("bytes-policy", roundtrip ({
      reference, paddingOptional := true, alphabet := .either,
      strictPadBits := true, wrapper := some "bytes" } : BytesPolicy))
  , ("wrapper-payload", roundtrip (WrapperPayload.text none))
  , ("wrapper", roundtrip ({
      name := "bytes", key := "bytes", payload := .bytes } : Wrapper))
  , ("sealed-leaf", roundtrip (SealedLeaf.string {}))
  , ("sealed-field", roundtrip ({ key := "x", required := true, leaf := .string {} } : SealedField))
  , ("sealed-extras", roundtrip SealedExtras.reject)
  , ("sealed-form", roundtrip ({
      tag := "sealed", fields := [], extras := .reject } : SealedForm))
  , ("tag-model", roundtrip ({
      key := "tag", format := none,
      sealed := [{ tag := "sealed", fields := [], extras := .reject }] } : TagModel))
  , ("shapes", shapes.all roundtrip)
  , ("conditions", conditions.all roundtrip)
  , ("text", roundtrip FormatRule.text)
  , ("not", roundtrip (FormatRule.not .text))
  , ("graphemes", roundtrip StringLengthUnit.graphemes)
  , ("reject-v3-schema", match decode (α := Necoherence.SignatureGeneration.Input)
        (replaceField (encode input) "schema" (.str "ncoh-checked-generation@3")) with
      | .error (.unsupportedSchema _ schema) => schema == "ncoh-checked-generation@3" | _ => false)
  , ("reject-v3-profile-field", rejectsUnknownField (α := VersionedSemanticProfile)
      "representation" (addField (encode profile) "representation" .null))
  , ("reject-cid-format", rejectsUnknownTag (α := FormatRule) "Cid"
      (Lean.Json.mkObj [("tag", .str "Cid")]))
  , ("reject-cid-link-shape", rejectsUnknownTag (α := Shape) "CidLink"
      (Lean.Json.mkObj [("tag", .str "CidLink")]))
  , ("reject-blob-shape", rejectsUnknownTag (α := Shape) "Blob"
      (Lean.Json.mkObj [("tag", .str "Blob")]))
  , ("reject-record-shape", rejectsUnknownTag (α := Shape) "Record"
      (Lean.Json.mkObj [("tag", .str "Record")]))
  , ("reject-known-values", rejectsUnknownField (α := StringSpec) "known_values"
      (addField (encode ({} : StringSpec)) "known_values" (.arr #[])))
  , ("reject-min-length", rejectsUnknownField (α := StringSpec) "min_length"
      (addField (encode ({} : StringSpec)) "min_length" (.str "0")))
  , ("reject-max-length", rejectsUnknownField (α := StringSpec) "max_length"
      (addField (encode ({} : StringSpec)) "max_length" (.str "1")))
  , ("reject-min-graphemes", rejectsUnknownField (α := StringSpec) "min_graphemes"
      (addField (encode ({} : StringSpec)) "min_graphemes" (.str "0")))
  , ("reject-max-graphemes", rejectsUnknownField (α := StringSpec) "max_graphemes"
      (addField (encode ({} : StringSpec)) "max_graphemes" (.str "1")))
  , ("reject-union-closed", rejectsUnknownField
      (α := Necoherence.TypeSignatures.UnionSpec) "closed"
      (addField (encode ({ branches := [] } : Necoherence.TypeSignatures.UnionSpec))
        "closed" (.bool true)))
  , ("reject-unsupported-format", rejectsUnknownTag (α := FormatRule) "UnsupportedFormatRule"
      (Lean.Json.mkObj [("tag", .str "UnsupportedFormatRule")]))
  , ("reject-noncanonical-nat", match decode (α := Nat) (.str "01") with
      | .error (.syntax _ _) => true | _ => false)
  , ("reject-extra-record-field", rejectsUnknownField (α := StringSpec) "extra"
      (addField (encode ({} : StringSpec)) "extra" .null)) ] ++
    formats.zipIdx.map fun (rule, index) => ("format-" ++ toString index, roundtrip rule)

def main : IO Unit := do
  let mut failed := false
  for (name, passed) in checks do
    if passed then IO.println (name ++ ": ok")
    else
      failed := true
      IO.eprintln (name ++ ": failed")
  if failed then throw (IO.userError "profile wire checks failed")
