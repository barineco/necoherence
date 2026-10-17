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
