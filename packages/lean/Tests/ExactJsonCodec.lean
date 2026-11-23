-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SignatureGeneration

open Lean Necoherence.ExactJson Necoherence.SemanticTypes
open Necoherence.SemanticCodec Necoherence.SemanticValidation

private def require (condition : Bool) (message : String) : IO Unit :=
  if condition then pure () else throw (IO.userError message)

private def library : Necoherence.TypeSignatures.TypeSignatureLibrary :=
  { identity := "codec-values", revision := "2",
    profile := {
      reference := { identity := "value-only", revision := "2", contentDigest := "codec-values" },
      integerDomains := [{ name := "integers", reference := { identity := "integer-domain", revision := "1", contentDigest := "integers" }, range := .unbounded, forms := [.number] }],
      defaultIntegerDomain := "integers",
      bytesPolicy := some {
        reference := { identity := "bytes", revision := "1", contentDigest := "bytes" },
        paddingOptional := true, wrapper := some "bytes" }
      wrappers := [{ name := "bytes", key := "$bytes", payload := .bytes }] },
    sources := [], definitions := [], nodes := [
      { id := "bytes", shape := .bytes {} },
      { id := "fixed", shape := .integer { defaultValue := some 7 } },
      { id := "choice", shape := .string { enumValues := some ["yes", "no"] } },
      { id := "nullable", shape := .string {} },
      { id := "object", shape := .product { fields := [
        { wireName := "fixed", slot := { typeId := "fixed", required := true, nullable := false } },
        { wireName := "choice", slot := { typeId := "choice", required := true, nullable := false } },
        { wireName := "requiredNullable", slot := { typeId := "nullable", required := true, nullable := true } }] } }] }

#guard (match Json.parse "0" with | .ok json => fromJson json == .num 0 | .error _ => false)
#guard (match Json.parse "0e11" with | .ok json => fromJson json == .num 0 | .error _ => false)
#guard (match Json.parse "0.0" with | .ok json => fromJson json == .dec "0" | .error _ => false)
#guard (match Json.parse "0e-100" with | .ok json => fromJson json == .dec "0" | .error _ => false)
#guard (match Json.parse "-0e-100" with | .ok json => fromJson json == .dec "0" | .error _ => false)
#guard (match Json.parse "0.000e-100" with | .ok json => fromJson json == .dec "0" | .error _ => false)
#guard (match Json.parse "1.5" with | .ok json => fromJson json == .dec "1.5" | .error _ => false)

private def decimalSource : SourceRef :=
  { repository := "synthetic", revision := "1", path := "codec-decimal",
    contentDigest := "codec-decimal", documentId := "codec-decimal" }

private def decimalRef : TypeRef := { source := decimalSource, definitionName := "amount", pointer := [] }

private def decimalProfileRef : ProfileRef :=
  { identity := "codec-decimal", revision := "1", contentDigest := "codec-decimal" }

private def decimalGraph : SemanticGraph :=
  { profile := { reference := decimalProfileRef, numbers := { decimals := true } },
    nodes := [{ ref := decimalRef, shape := .decimal {}, description := none, attributes := [], extensions := [] }] }

private def decodesAsDecimal (text : String) : Bool :=
  match Json.parse text with
  | .ok json =>
      match validateValue decimalGraph decimalRef (fromJson json) with
      | .ok _ => true
      | .error _ => false
  | .error _ => false

#guard decodesAsDecimal "0.0" == true
#guard decodesAsDecimal "0e-100" == true
#guard decodesAsDecimal "-0e-100" == true
#guard decodesAsDecimal "0.000e-100" == true
#guard decodesAsDecimal "1.5" == true

#guard admissionFailure "1e10000" == some "exponent too large"
#guard admissionFailure "1e9999" == none
#guard admissionFailure "\"e10000\"" == none
#guard (match boundedJsonParse "1e10000" with | .error message => message == "exponent too large" | .ok _ => false)
#guard (match Necoherence.ExactJson.toJson (.dec "1e10000") with | .error _ => true | .ok _ => false)

private def kindName : JsonValue → String
  | .null => "null" | .bool _ => "bool" | .num _ => "num" | .dec _ => "dec"
  | .str _ => "str" | .arr _ => "arr" | .obj _ => "obj"

private def keepsKind (value : JsonValue) : Bool :=
  match Necoherence.ExactJson.toJson value with
  | .ok written =>
    kindName (fromJson written) == kindName value &&
      (match Json.parse (Necoherence.ExactJson.compressJson written) with
        | .ok reread => kindName (fromJson reread) == kindName value
        | .error _ => false)
  | .error _ => false

private def textKeepsKind (text : String) : Bool :=
  match Json.parse text with
  | .ok json => keepsKind (fromJson json)
  | .error _ => false

private def spelled (value : JsonValue) : String :=
  match Necoherence.ExactJson.toJson value with
  | .ok written => Necoherence.ExactJson.compressJson written
  | .error message => message

#guard textKeepsKind "0"
#guard textKeepsKind "0.0"
#guard textKeepsKind "10"
#guard textKeepsKind "10.0"
#guard textKeepsKind "1.5"
#guard textKeepsKind "0e-100"
#guard textKeepsKind "1e-100"
#guard textKeepsKind "1.2300e+99"
#guard keepsKind (.dec "0") && keepsKind (.dec "10") && keepsKind (.dec "1.2300e+99") && keepsKind (.dec "0e-100")

#guard spelled (.dec "0") == "0.0"
#guard spelled (.dec "0e-100") == "0.0"
#guard spelled (.dec "10") == "10.0"
#guard spelled (.dec "1.5") == "1.5"
#guard spelled (.dec "1e-100") == "0.0000000001e-90"
#guard spelled (.num 10) == "10"
#guard Necoherence.ExactJson.compressJson (Json.num ⟨0, 100⟩) == "0.0"
#guard Necoherence.ExactJson.compressJson (Json.mkObj [("b", .arr #[.null, .bool true, .num (-3)]), ("a", .str "x\"y")]) ==
  (Json.mkObj [("b", .arr #[.null, .bool true, .num (-3)]), ("a", .str "x\"y")]).compress

def main : IO UInt32 := do
  let graph := library.graph
  let some bytesNode := graph.nodes.find? (·.ref.definitionName == "bytes") | throw (IO.userError "bytes node")
  let some objectNode := graph.nodes.find? (·.ref.definitionName == "object") | throw (IO.userError "object node")
  for wire in ["AQI", "AQI="] do
    let value := JsonValue.obj [("$bytes", .str wire)]
    let .ok decoded := bytesDecode graph.profile value | throw (IO.userError "bytes decode")
    require (decoded.data == [1, 2]) "decoded bytes differ"
    let .ok checked := construct graph bytesNode.ref (bytesEncode graph.profile) decoded |
      throw (IO.userError "bytes construction")
    require (bytesEncode graph.profile checked.value == value) "bytes wire spelling differs"
  let native : Bytes := { data := [1, 2] }
  require (bytesEncode graph.profile native == .obj [("$bytes", .str "AQI=")]) "native base64 differs"
  let changed : Bytes := { data := [255], wire := some "AQI" }
  require (bytesEncode graph.profile changed == .obj [("$bytes", .str "/w==")]) "bytes data change ignored"
  let urlProfile := { graph.profile with bytesPolicy := graph.profile.bytesPolicy.map fun policy =>
    { policy with alphabet := .urlSafe } }
  let .ok urlDecoded := bytesDecode urlProfile (.obj [("$bytes", .str "-_8=")]) |
    throw (IO.userError "URL-safe bytes decode")
  require (urlDecoded.data == [251, 255]) "URL-safe decoded bytes differ"
  require (bytesEncode urlProfile { data := [251, 255] } == .obj [("$bytes", .str "-_8=")])
    "URL-safe encoded bytes differ"
  for data in [[], [0], [0, 1], [0, 1, 2], [0, 1, 2, 255]] do
    require (decodeBase64 .standard (encodeBase64 data) == some data) "base64 roundtrip differs"
  let .ok integer := Json.parse "9007199254740993" | throw (IO.userError "exact integer parse")
  require (fromJson integer == .num 9007199254740993) "exact integer precision differs"
  let before := JsonValue.obj [("choice", .str "yes"), ("requiredNullable", .null)]
  let .ok defaulted := materializeDefaults graph objectNode.ref before |
    throw (IO.userError "default materialization")
  require (valueAtPath graph.profile defaulted.value [.field "fixed"] == .present (.num 7))
    "default value differs"
  require (defaulted.applications.map (·.valuePath) == [[.field "fixed"]]) "default evidence differs"
  require (!checkDefaultApplications graph before defaulted.value
    (defaulted.applications.map fun application => { application with value := .num 8 })) "forged default evidence admitted"
  IO.println "codec bytes_spellings=2 native_bytes=2 base64_roundtrip=5 precision=1 defaults=1 tamper=1"
  pure 0
