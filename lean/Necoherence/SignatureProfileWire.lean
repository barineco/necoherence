-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Lean.Data.Json
import Necoherence.SemanticTypes

namespace Necoherence.SignatureWire
open Lean Necoherence.SemanticTypes

inductive WireFailure where
  | unsupportedSchema (path schema : String)
  | unknownField (path field : String)
  | unknownTag (path tag : String)
  | syntax (path message : String)
  deriving BEq, Repr, Inhabited

private def WireFailure.prepend (segment : String) : WireFailure → WireFailure
  | .unsupportedSchema path schema => .unsupportedSchema (segment ++ path.drop 1) schema
  | .unknownField path field => .unknownField (segment ++ path.drop 1) field
  | .unknownTag path tag => .unknownTag (segment ++ path.drop 1) tag
  | .syntax path message => .syntax (segment ++ path.drop 1) message

def liftJson (result : Except String α) : Except WireFailure α :=
  result.mapError (WireFailure.syntax "$")
instance : Coe (Except String α) (Except WireFailure α) :=
  ⟨Except.mapError (WireFailure.syntax "$")⟩


class Wire (α : Type) where
  encode : α → Json
  decode : Json → Except WireFailure α

abbrev encode [Wire α] : α → Json := Wire.encode
abbrev decode [Wire α] : Json → Except WireFailure α := Wire.decode

def keys (json : Json) (expected : List String) : Except WireFailure Unit := do
  let object ← liftJson json.getObj?
  let actual := object.toList.map Prod.fst
  if let some field := actual.find? (fun key => !expected.contains key) then
    throw (WireFailure.unknownField ("$." ++ field) field)
  if let some field := expected.find? (fun key => !actual.contains key) then
    throw (WireFailure.syntax ("$." ++ field) "missing field")

def get [Wire α] (json : Json) (key : String) : Except WireFailure α := do
  let value ← match json.getObjVal? key with
    | .ok value => pure value
    | .error message => throw (WireFailure.syntax ("$." ++ key) message)
  (decode value).mapError (WireFailure.prepend ("$." ++ key))

instance : Wire String := ⟨Json.str, fun json => liftJson json.getStr?⟩
instance : Wire Bool := ⟨Json.bool, fun json => liftJson json.getBool?⟩
instance : Wire Int where
  encode value := .str (toString value)
  decode json := do
    let text ← liftJson json.getStr?
    let some value := text.toInt? | throw (WireFailure.syntax "$" "expected canonical integer")
    if toString value != text then throw (WireFailure.syntax "$" "noncanonical integer")
    pure value
instance : Wire Nat where
  encode value := .str (toString value)
  decode json := do
    let value : Int ← decode json
    if value < 0 then throw (WireFailure.syntax "$" "negative natural")
    pure value.toNat
instance [Wire α] : Wire (List α) where
  encode values := .arr (values.map encode).toArray
  decode json := do (← liftJson json.getArr?).toList.mapM decode
instance [Wire α] : Wire (Option α) where
  encode | none => .null | some value => encode value
  decode | .null => pure none | json => return some (← decode json)

private def unitTag (tag : String) : Json := Json.mkObj [("tag", .str tag)]
private def tupleTag (tag : String) (value : Json) : Json := Json.mkObj [("tag", .str tag), ("value", value)]
private def recordTag (tag : String) (fields : List (String × Json)) : Json := Json.mkObj [("tag", .str tag), ("fields", Json.mkObj fields)]
private def payload (json : Json) : Except WireFailure Json := do
  keys json ["tag", "value"]
  liftJson (json.getObjVal? "value")
private def fields (json : Json) : Except WireFailure Json := do
  keys json ["tag", "fields"]
  liftJson (json.getObjVal? "fields")

instance : Wire ProfileRef where
  encode value := Json.mkObj [("identity", encode value.identity), ("revision", encode value.revision), ("content_digest", encode value.contentDigest)]
  decode json := do
    keys json ["identity", "revision", "content_digest"]
    pure { identity := ← get json "identity", revision := ← get json "revision", contentDigest := ← get json "content_digest" }

instance : Wire SourceIdentity where
  encode value := Json.mkObj [("repository", encode value.repository), ("revision", encode value.revision), ("path", encode value.path), ("content_digest", encode value.contentDigest)]
  decode json := do
    keys json ["repository", "revision", "path", "content_digest"]
    pure { repository := ← get json "repository", revision := ← get json "revision", path := ← get json "path", contentDigest := ← get json "content_digest" }

instance : Wire Origin where
  encode value := Json.mkObj [("source", encode value.source), ("locator", encode value.locator)]
  decode json := do
    keys json ["source", "locator"]
    pure { source := ← get json "source", locator := ← get json "locator" }

instance : Wire IntegerDomain where
  encode
    | .unbounded => unitTag "Unbounded"
    | .inclusive minimum maximum => recordTag "Inclusive" [("minimum", encode minimum), ("maximum", encode maximum)]
  decode json := do
    match ← get (α := String) json "tag" with
    | "Unbounded" => do keys json ["tag"]; pure .unbounded
    | "Inclusive" => do
      let row ← fields json
      keys row ["minimum", "maximum"]
      pure (.inclusive (← get row "minimum") (← get row "maximum"))
    | tag => throw (.unknownTag "$.tag" tag)

instance : Wire IntegerForm where
  encode
    | .number => unitTag "Number"
    | .integralDecimal => unitTag "IntegralDecimal"
    | .decimalString => unitTag "DecimalString"
  decode json := do
    match ← get (α := String) json "tag" with
    | "Number" => keys json ["tag"]; pure .number
    | "IntegralDecimal" => keys json ["tag"]; pure .integralDecimal
    | "DecimalString" => keys json ["tag"]; pure .decimalString
    | tag => throw (.unknownTag "$.tag" tag)

instance : Wire IntegerDomainBinding where
  encode value := Json.mkObj [
    ("name", encode value.name), ("reference", encode value.reference),
    ("range", encode value.range), ("forms", encode value.forms)]
  decode json := do
    keys json ["name", "reference", "range", "forms"]
    let name ← get json "name"
    let reference ← get json "reference"
    let range ← get json "range"
    let forms ← get json "forms"
    pure { name, reference, range, forms }

instance : Wire NumberModel where
  encode value := Json.mkObj [("decimals", encode value.decimals)]
  decode json := do
    keys json ["decimals"]
    pure { decimals := ← get json "decimals" }

instance : Wire BytesAlphabet where
  encode
    | .standard => unitTag "Standard"
    | .urlSafe => unitTag "UrlSafe"
    | .either => unitTag "Either"
  decode json := do
    match ← get (α := String) json "tag" with
    | "Standard" => keys json ["tag"]; pure .standard
    | "UrlSafe" => keys json ["tag"]; pure .urlSafe
    | "Either" => keys json ["tag"]; pure .either
    | tag => throw (.unknownTag "$.tag" tag)

instance : Wire StringLengthUnit where
  encode
    | .utf8Bytes => unitTag "Utf8Bytes"
    | .unicodeScalars => unitTag "UnicodeScalars"
    | .graphemes => unitTag "Graphemes"
  decode json := do
    match ← get (α := String) json "tag" with
    | "Utf8Bytes" => keys json ["tag"]; pure .utf8Bytes
    | "UnicodeScalars" => keys json ["tag"]; pure .unicodeScalars
    | "Graphemes" => keys json ["tag"]; pure .graphemes
    | tag => throw (.unknownTag "$.tag" tag)

instance : Wire GraphemeProperty where
  encode
    | .other => unitTag "Other"
    | .cr => unitTag "Cr"
    | .lf => unitTag "Lf"
    | .control => unitTag "Control"
    | .extend => unitTag "Extend"
    | .zwj => unitTag "Zwj"
    | .regionalIndicator => unitTag "RegionalIndicator"
    | .prepend => unitTag "Prepend"
    | .spacingMark => unitTag "SpacingMark"
    | .l => unitTag "L"
    | .v => unitTag "V"
    | .t => unitTag "T"
    | .lv => unitTag "Lv"
    | .lvt => unitTag "Lvt"
  decode json := do
    match ← get (α := String) json "tag" with
    | "Other" => do keys json ["tag"]; pure .other
    | "Cr" => do keys json ["tag"]; pure .cr
    | "Lf" => do keys json ["tag"]; pure .lf
    | "Control" => do keys json ["tag"]; pure .control
    | "Extend" => do keys json ["tag"]; pure .extend
    | "Zwj" => do keys json ["tag"]; pure .zwj
    | "RegionalIndicator" => do keys json ["tag"]; pure .regionalIndicator
    | "Prepend" => do keys json ["tag"]; pure .prepend
    | "SpacingMark" => do keys json ["tag"]; pure .spacingMark
    | "L" => do keys json ["tag"]; pure .l
    | "V" => do keys json ["tag"]; pure .v
    | "T" => do keys json ["tag"]; pure .t
    | "Lv" => do keys json ["tag"]; pure .lv
    | "Lvt" => do keys json ["tag"]; pure .lvt
    | tag => throw (.unknownTag "$.tag" tag)

instance : Wire IndicProperty where
  encode
    | .other => unitTag "Other"
    | .consonant => unitTag "Consonant"
    | .extend => unitTag "Extend"
    | .linker => unitTag "Linker"
  decode json := do
    match ← get (α := String) json "tag" with
    | "Other" => do keys json ["tag"]; pure .other
    | "Consonant" => do keys json ["tag"]; pure .consonant
    | "Extend" => do keys json ["tag"]; pure .extend
    | "Linker" => do keys json ["tag"]; pure .linker
    | tag => throw (.unknownTag "$.tag" tag)

instance : Wire EffectPoint where
  encode
    | .httpRequestResponse => unitTag "HttpRequestResponse"
    | .dataOnly => unitTag "DataOnly"
  decode json := do
    match ← get (α := String) json "tag" with
    | "HttpRequestResponse" => do keys json ["tag"]; pure .httpRequestResponse
    | "DataOnly" => do keys json ["tag"]; pure .dataOnly
    | tag => throw (.unknownTag "$.tag" tag)

instance : Wire CodepointRange where
  encode value := Json.mkObj [("first", encode value.first), ("last", encode value.last)]
  decode json := do
    keys json ["first", "last"]
    pure { first := ← get json "first", last := ← get json "last" }

instance : Wire GraphemeRange where
  encode value := Json.mkObj [("first", encode value.first), ("last", encode value.last), ("property", encode value.property)]
  decode json := do
    keys json ["first", "last", "property"]
    pure { first := ← get json "first", last := ← get json "last", property := ← get json "property" }

instance : Wire IndicRange where
  encode value := Json.mkObj [("first", encode value.first), ("last", encode value.last), ("property", encode value.property)]
  decode json := do
    keys json ["first", "last", "property"]
    pure { first := ← get json "first", last := ← get json "last", property := ← get json "property" }

instance : Wire GraphemeComponent where
  encode value := Json.mkObj [("unicode_version", encode value.unicodeVersion), ("uax29_revision", encode value.uax29Revision), ("cluster_profile", encode value.clusterProfile)]
  decode json := do
    keys json ["unicode_version", "uax29_revision", "cluster_profile"]
    pure { unicodeVersion := ← get json "unicode_version", uax29Revision := ← get json "uax29_revision", clusterProfile := ← get json "cluster_profile" }

instance : Wire GraphemeSource where
  encode value := Json.mkObj [("role", encode value.role), ("origin", encode value.origin)]
  decode json := do
    keys json ["role", "origin"]
    pure { role := ← get json "role", origin := ← get json "origin" }

instance : Wire GraphemeRules where
  encode value := Json.mkObj [("reference", encode value.reference), ("component", encode value.component), ("table_sha256", encode value.tableSha256), ("sources", encode value.sources), ("properties", encode value.properties), ("extended_pictographic", encode value.extendedPictographic), ("indic_conjunct", encode value.indicConjunct)]
  decode json := do
    keys json ["reference", "component", "table_sha256", "sources", "properties", "extended_pictographic", "indic_conjunct"]
    pure { reference := ← get json "reference", component := ← get json "component", tableSha256 := ← get json "table_sha256", sources := ← get json "sources", properties := ← get json "properties", extendedPictographic := ← get json "extended_pictographic", indicConjunct := ← get json "indic_conjunct" }

instance : Wire BytesPolicy where
  encode value := Json.mkObj [
    ("reference", encode value.reference), ("padding_optional", encode value.paddingOptional),
    ("alphabet", encode value.alphabet), ("strict_pad_bits", encode value.strictPadBits),
    ("wrapper", encode value.wrapper)]
  decode json := do
    keys json ["reference", "padding_optional", "alphabet", "strict_pad_bits", "wrapper"]
    let reference ← get json "reference"
    let paddingOptional ← get json "padding_optional"
    let alphabet ← get json "alphabet"
    let strictPadBits ← get json "strict_pad_bits"
    let wrapper ← get json "wrapper"
    pure { reference, paddingOptional, alphabet, strictPadBits, wrapper }

instance : Wire CalendarRule where
  encode value := Json.mkObj [("allow_second_60", encode value.allowSecond60), ("minimum_year", encode value.minimumYear), ("maximum_year", encode value.maximumYear), ("rejectUtcYearOutsideRange", encode value.rejectUtcYearOutsideRange)]
  decode json := do
    keys json ["allow_second_60", "minimum_year", "maximum_year", "rejectUtcYearOutsideRange"]
    pure { allowSecond60 := ← get json "allow_second_60", minimumYear := ← get json "minimum_year", maximumYear := ← get json "maximum_year", rejectUtcYearOutsideRange := ← get json "rejectUtcYearOutsideRange" }

instance : Wire DfaTransition where
  encode value := Json.mkObj [("from_state", encode value.fromState), ("first", encode value.first), ("last", encode value.last), ("to_state", encode value.toState)]
  decode json := do
    keys json ["from_state", "first", "last", "to_state"]
    pure { fromState := ← get json "from_state", first := ← get json "first", last := ← get json "last", toState := ← get json "to_state" }

instance : Wire DfaSpec where
  encode value := Json.mkObj [("state_count", encode value.stateCount), ("initial_state", encode value.initialState), ("accepting_states", encode value.acceptingStates), ("transitions", encode value.transitions)]
  decode json := do
    keys json ["state_count", "initial_state", "accepting_states", "transitions"]
    pure { stateCount := ← get json "state_count", initialState := ← get json "initial_state", acceptingStates := ← get json "accepting_states", transitions := ← get json "transitions" }

instance : Wire LengthSpec where
  encode value := Json.mkObj [("minimum", encode value.minimum), ("maximum", encode value.maximum)]
  decode json := do
    keys json ["minimum", "maximum"]
    pure { minimum := ← get json "minimum", maximum := ← get json "maximum" }

instance : Wire BooleanSpec where
  encode value := Json.mkObj [("const_value", encode value.constValue), ("default_value", encode value.defaultValue)]
  decode json := do
    keys json ["const_value", "default_value"]
    pure { constValue := ← get json "const_value", defaultValue := ← get json "default_value" }


partial def encodeFormat : FormatRule → Json
  | .literal value => tupleTag "Literal" (encode value)
  | .sequence value => tupleTag "Sequence" (.arr (value.map encodeFormat).toArray)
  | .optional value => tupleTag "Optional" (encodeFormat value)
  | .labels separator minCount maxCount totalMax rule => recordTag "Labels" [("separator", encode separator), ("min_count", encode minCount), ("max_count", encode maxCount), ("total_max", encode totalMax), ("rule", encodeFormat rule)]
  | .bounded unit maximum rule => recordTag "Bounded" [("unit", encode unit), ("maximum", encode maximum), ("rule", encodeFormat rule)]
  | .asciiDfa value => tupleTag "AsciiDfa" (encode value)
  | .timestamp value => tupleTag "Timestamp" (encode value)
  | .choice value => tupleTag "Choice" (.arr (value.map encodeFormat).toArray)
  | .identifier firstAlphabet restAlphabet exactLength minLength maxLength forbidden => recordTag "Identifier" [("first_alphabet", encode firstAlphabet), ("rest_alphabet", encode restAlphabet), ("exact_length", encode exactLength), ("min_length", encode minLength), ("max_length", encode maxLength), ("forbidden", encode forbidden)]
  | .absoluteUri maxBytes => recordTag "AbsoluteUri" [("max_bytes", encode maxBytes)]
  | .languageTag grandfathered => recordTag "LanguageTag" [("grandfathered", encode grandfathered)]
  | .text => unitTag "Text"
  | .not rule => tupleTag "Not" (encodeFormat rule)
partial def decodeFormat (json : Json) : Except WireFailure FormatRule := do
  match ← get (α := String) json "tag" with
  | "Literal" => return .literal (← decode (← payload json))
  | "Sequence" => return .sequence (← (← liftJson (← payload json).getArr?).toList.mapM decodeFormat)
  | "Optional" => return .optional (← decodeFormat (← payload json))
  | "Labels" => let row ← fields json; keys row ["separator", "min_count", "max_count", "total_max", "rule"]; return .labels (← get row "separator") (← get row "min_count") (← get row "max_count") (← get row "total_max") (← decodeFormat (← liftJson (row.getObjVal? "rule")))
  | "Bounded" => let row ← fields json; keys row ["unit", "maximum", "rule"]; return .bounded (← get row "unit") (← get row "maximum") (← decodeFormat (← liftJson (row.getObjVal? "rule")))
  | "AsciiDfa" => return .asciiDfa (← decode (α := DfaSpec) (← payload json))
  | "Timestamp" => return .timestamp (← decode (α := CalendarRule) (← payload json))
  | "Choice" => return .choice (← (← liftJson (← payload json).getArr?).toList.mapM decodeFormat)
  | "Identifier" => do
    let row ← fields json
    keys row ["first_alphabet", "rest_alphabet", "exact_length", "min_length", "max_length", "forbidden"]
    pure (.identifier (← get (α := String) row "first_alphabet") (← get (α := String) row "rest_alphabet") (← get (α := Option Nat) row "exact_length") (← get (α := Nat) row "min_length") (← get (α := Option Nat) row "max_length") (← get (α := List String) row "forbidden"))
  | "AbsoluteUri" => do
    let row ← fields json
    keys row ["max_bytes"]
    pure (.absoluteUri (← get (α := Option Nat) row "max_bytes"))
  | "LanguageTag" => do
    let row ← fields json
    keys row ["grandfathered"]
    pure (.languageTag (← get (α := List String) row "grandfathered"))
  | "Text" => keys json ["tag"]; pure .text
  | "Not" => return .not (← decodeFormat (← payload json))
  | tag => throw (.unknownTag "$.tag" tag)
instance : Wire FormatRule := ⟨encodeFormat, decodeFormat⟩

instance : Wire LengthBound where
  encode value := Json.mkObj [
    ("unit", encode value.unit), ("minimum", encode value.minimum), ("maximum", encode value.maximum)]
  decode json := do
    keys json ["unit", "minimum", "maximum"]
    pure { unit := ← get json "unit", minimum := ← get json "minimum", maximum := ← get json "maximum" }

instance : Wire FormatUse where
  encode
    | .named name => tupleTag "Named" (encode name)
    | .inline rule => tupleTag "Inline" (encode rule)
  decode json := do
    match ← get (α := String) json "tag" with
    | "Named" => return .named (← decode (← payload json))
    | "Inline" => return .inline (← decode (← payload json))
    | tag => throw (.unknownTag "$.tag" tag)

instance : Wire IntegerSpec where
  encode value := Json.mkObj [
    ("domain", encode value.domain), ("minimum", encode value.minimum),
    ("maximum", encode value.maximum), ("const_value", encode value.constValue),
    ("enum_values", encode value.enumValues), ("default_value", encode value.defaultValue)]
  decode json := do
    keys json ["domain", "minimum", "maximum", "const_value", "enum_values", "default_value"]
    pure {
      domain := ← get json "domain", minimum := ← get json "minimum",
      maximum := ← get json "maximum", constValue := ← get json "const_value",
      enumValues := ← get json "enum_values", defaultValue := ← get json "default_value" }

instance : Wire StringSpec where
  encode value := Json.mkObj [
    ("format", encode value.format), ("lengths", encode value.lengths),
    ("wrapper", encode value.wrapper), ("const_value", encode value.constValue),
    ("enum_values", encode value.enumValues), ("examples", encode value.examples),
    ("default_value", encode value.defaultValue)]
  decode json := do
    keys json ["format", "lengths", "wrapper", "const_value", "enum_values", "examples",
      "default_value"]
    pure {
      format := ← get json "format", lengths := ← get json "lengths",
      wrapper := ← get json "wrapper", constValue := ← get json "const_value",
      enumValues := ← get json "enum_values", examples := ← get json "examples",
      defaultValue := ← get json "default_value" }

instance : Wire WrapperPayload where
  encode
    | .bytes => unitTag "Bytes"
    | .text format => tupleTag "Text" (encode format)
  decode json := do
    match ← get (α := String) json "tag" with
    | "Bytes" => keys json ["tag"]; pure .bytes
    | "Text" => return .text (← decode (← payload json))
    | tag => throw (.unknownTag "$.tag" tag)

instance : Wire Wrapper where
  encode value := Json.mkObj [
    ("name", encode value.name), ("key", encode value.key), ("payload", encode value.payload)]
  decode json := do
    keys json ["name", "key", "payload"]
    pure { name := ← get json "name", key := ← get json "key", payload := ← get json "payload" }

instance : Wire SealedLeaf where
  encode
    | .string spec => tupleTag "String" (encode spec)
    | .integer spec => tupleTag "Integer" (encode spec)
  decode json := do
    match ← get (α := String) json "tag" with
    | "String" => return .string (← decode (← payload json))
    | "Integer" => return .integer (← decode (← payload json))
    | tag => throw (.unknownTag "$.tag" tag)

instance : Wire SealedField where
  encode value := Json.mkObj [
    ("key", encode value.key), ("required", encode value.required), ("leaf", encode value.leaf)]
  decode json := do
    keys json ["key", "required", "leaf"]
    pure { key := ← get json "key", required := ← get json "required", leaf := ← get json "leaf" }

instance : Wire SealedExtras where
  encode
    | .reject => unitTag "Reject"
    | .any => unitTag "Any"
  decode json := do
    match ← get (α := String) json "tag" with
    | "Reject" => keys json ["tag"]; pure .reject
    | "Any" => keys json ["tag"]; pure .any
    | tag => throw (.unknownTag "$.tag" tag)

instance : Wire SealedForm where
  encode value := Json.mkObj [
    ("tag", encode value.tag), ("fields", encode value.fields), ("extras", encode value.extras)]
  decode json := do
    keys json ["tag", "fields", "extras"]
    pure { tag := ← get json "tag", fields := ← get json "fields", extras := ← get json "extras" }

instance : Wire TagModel where
  encode value := Json.mkObj [
    ("key", encode value.key), ("format", encode value.format), ("sealed", encode value.sealed)]
  decode json := do
    keys json ["key", "format", "sealed"]
    pure { key := ← get json "key", format := ← get json "format", sealed := ← get json "sealed" }

instance : Wire FormatBinding where
  encode value := Json.mkObj [("name", encode value.name), ("reference", encode value.reference), ("rule", encode value.rule)]
  decode json := do
    keys json ["name", "reference", "rule"]
    pure { name := ← get json "name", reference := ← get json "reference", rule := ← get json "rule" }

instance : Wire ValueCondition where
  encode
    | .missingRequired => unitTag "MissingRequired"
    | .nullNotAllowed => unitTag "NullNotAllowed"
    | .wrongValueKind value => tupleTag "WrongValueKind" (encode value)
    | .constMismatch => unitTag "ConstMismatch"
    | .enumMismatch => unitTag "EnumMismatch"
    | .belowMinimum => unitTag "BelowMinimum"
    | .aboveMaximum => unitTag "AboveMaximum"
    | .integerDomain => unitTag "IntegerDomain"
    | .stringLength => unitTag "StringLength"
    | .arrayLength => unitTag "ArrayLength"
    | .bytesLength => unitTag "BytesLength"
    | .format value => tupleTag "Format" (encode value)
    | .invalidBytes => unitTag "InvalidBytes"
    | .invalidWrapper value => tupleTag "InvalidWrapper" (encode value)
    | .invalidTag => unitTag "InvalidTag"
    | .reservedForm => unitTag "ReservedForm"
    | .noBranchSelected => unitTag "NoBranchSelected"
    | .keyFormat value => tupleTag "KeyFormat" (encode value)
    | .uninhabited => unitTag "Uninhabited"
    | .duplicateField value => tupleTag "DuplicateField" (encode value)
    | .unexpectedField value => tupleTag "UnexpectedField" (encode value)
    | .invalidDataModel => unitTag "InvalidDataModel"
    | .referenceCycle => unitTag "ReferenceCycle"
  decode json := do
    match ← get (α := String) json "tag" with
    | "MissingRequired" => keys json ["tag"]; pure .missingRequired
    | "NullNotAllowed" => keys json ["tag"]; pure .nullNotAllowed
    | "WrongValueKind" => return .wrongValueKind (← decode (← payload json))
    | "ConstMismatch" => keys json ["tag"]; pure .constMismatch
    | "EnumMismatch" => keys json ["tag"]; pure .enumMismatch
    | "BelowMinimum" => keys json ["tag"]; pure .belowMinimum
    | "AboveMaximum" => keys json ["tag"]; pure .aboveMaximum
    | "IntegerDomain" => keys json ["tag"]; pure .integerDomain
    | "StringLength" => keys json ["tag"]; pure .stringLength
    | "ArrayLength" => keys json ["tag"]; pure .arrayLength
    | "BytesLength" => keys json ["tag"]; pure .bytesLength
    | "Format" => return .format (← decode (← payload json))
    | "InvalidBytes" => keys json ["tag"]; pure .invalidBytes
    | "InvalidWrapper" => return .invalidWrapper (← decode (← payload json))
    | "InvalidTag" => keys json ["tag"]; pure .invalidTag
    | "ReservedForm" => keys json ["tag"]; pure .reservedForm
    | "NoBranchSelected" => keys json ["tag"]; pure .noBranchSelected
    | "KeyFormat" => return .keyFormat (← decode (← payload json))
    | "Uninhabited" => keys json ["tag"]; pure .uninhabited
    | "DuplicateField" => return .duplicateField (← decode (← payload json))
    | "UnexpectedField" => return .unexpectedField (← decode (← payload json))
    | "InvalidDataModel" => keys json ["tag"]; pure .invalidDataModel
    | "ReferenceCycle" => keys json ["tag"]; pure .referenceCycle
    | tag => throw (.unknownTag "$.tag" tag)

instance : Wire VersionedSemanticProfile where
  encode value := Json.mkObj [
    ("reference", encode value.reference), ("source_refs", encode value.sourceRefs),
    ("integer_domains", encode value.integerDomains),
    ("default_integer_domain", encode value.defaultIntegerDomain), ("numbers", encode value.numbers),
    ("grapheme_rules", encode value.graphemeRules), ("format_bindings", encode value.formatBindings),
    ("bytes_policy", encode value.bytesPolicy), ("wrappers", encode value.wrappers), ("tag", encode value.tag)]
  decode json := do
    keys json ["reference", "source_refs", "integer_domains", "default_integer_domain", "numbers",
      "grapheme_rules", "format_bindings", "bytes_policy", "wrappers", "tag"]
    pure {
      reference := ← get json "reference"
      sourceRefs := ← get json "source_refs"
      integerDomains := ← get json "integer_domains"
      defaultIntegerDomain := ← get json "default_integer_domain"
      numbers := ← get json "numbers"
      graphemeRules := ← get json "grapheme_rules"
      formatBindings := ← get json "format_bindings"
      bytesPolicy := ← get json "bytes_policy"
      wrappers := ← get json "wrappers"
      tag := ← get json "tag" }

end Necoherence.SignatureWire
