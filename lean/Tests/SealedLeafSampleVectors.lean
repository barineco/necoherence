-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SignatureWire
import Necoherence.SemanticComposition

open Lean Necoherence.SemanticTypes Necoherence.SemanticValidation Necoherence.SemanticComposition
open Necoherence.TypeSignatures Necoherence.SignatureWire

private def field (json : Json) (key : String) : Except String Json :=
  json.getObjVal? key

private def getWire {α : Type} [Wire α] (json : Json) (key : String) : Except String α := do
  (decode (← field json key)).mapError reprStr

private def samplesJson (graph : SemanticGraph) : Except String Json := do
  let root := typeRef "value"
  let samples := sampleValueFuel graph { maxSampleLength := 32 } (graph.nodes.length + 1) [] root
  for value in samples.values do
    match acceptsValue graph root value with
    | .accepted => pure ()
    | decision => throw ("sample rejected: " ++ reprStr decision)
  pure (.arr (← samples.values.mapM Necoherence.ExactJson.toJson).toArray)

private def checkVectors (json : Json) (emit : Bool) : Except String (Nat × List String) := do
  let schema : String ← getWire json "schema"
  if schema != "sealed-leaf-sample-vectors@1" then throw ("unsupported vector schema: " ++ schema)
  let profile : ValueProfile ← getWire json "profile"
  let cases ← (← field json "cases").getArr?
  let mut ids : List String := []
  let mut lines : List String := []
  for testCase in cases do
    let caseId : String ← getWire testCase "id"
    if ids.contains caseId then throw ("duplicate case: " ++ caseId)
    ids := caseId :: ids
    let nodes : List Node ← (decode (Json.arr #[Json.mkObj [
      ("id", .str "value"), ("shape", ← field testCase "sealed")]])).mapError reprStr
    let library : TypeSignatureLibrary := {
      identity := "sealed-leaf-samples", revision := "1", profile, nodes, definitions := [] }
    let actual ← (samplesJson library.graph).mapError (fun message => caseId ++ ": " ++ message)
    if emit then
      lines := lines ++ [Json.mkObj [("id", .str caseId), ("samples", actual)] |>.compress]
    else
      let expected ← field testCase "expected"
      if actual != expected then
        lines := lines ++ [caseId ++ ": expected " ++ expected.compress ++ ", actual " ++ actual.compress]
  pure (cases.size, lines)

def main (args : List String) : IO UInt32 := do
  let (path, emit) ← match args with
    | [] => pure ("../comparison/declaration/sealed_leaf_sample_vectors.json", false)
    | ["--emit", path] => pure (path, true)
    | [path] => pure (path, false)
    | _ => throw (IO.userError "expected [--emit] [vector file path]")
  let source ← IO.FS.readFile path
  let .ok json := Necoherence.SignatureJson.parse source |
    throw (IO.userError "sealed leaf sample vector JSON parse failed")
  let (count, lines) ← match checkVectors json emit with
    | .ok result => pure result
    | .error message => throw (IO.userError message)
  for line in lines do
    if emit then IO.println line else IO.eprintln line
  if !emit && !lines.isEmpty then
    throw (IO.userError s!"sealed leaf sample vector mismatches: {lines.length}")
  if !emit then IO.println s!"sealed_leaf_sample_cases={count} mismatches=0"
  pure 0
