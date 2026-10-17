import Necoherence.SignatureWire

open Lean Necoherence.SemanticTypes Necoherence.SemanticValidation
open Necoherence.TypeSignatures Necoherence.SignatureWire

private def field (json : Json) (key : String) : Except String Json :=
  json.getObjVal? key

private def getWire {α : Type} [Wire α] (json : Json) (key : String) : Except String α := do
  (decode (← field json key)).mapError reprStr

private def pathJson (path : ValuePath) : Json :=
  .arr (path.map fun step =>
    let (tag, value) := match step with
      | .field name => ("Field", name)
      | .index index => ("Index", toString index)
      | .variant name => ("Variant", name)
    Json.mkObj [("tag", .str tag), ("value", .str value)]).toArray

private def outcome (graph : SemanticGraph) (root : TypeRef)
    (input : Json) : Except String Json :=
  match validateValue graph root (Necoherence.ExactJson.fromJson input) with
  | .ok _ => pure (Json.mkObj [
      ("accepted", .bool true), ("condition", .null), ("path", .arr #[])])
  | .error (.value failure) => pure (Json.mkObj [
      ("accepted", .bool false), ("condition", encode failure.condition),
      ("path", pathJson failure.valuePath)])
  | .error failure => throw ("value validation did not resolve: " ++ reprStr failure)

private def checkVectors (json : Json) : Except String (Nat × List String) := do
  let schema : String ← getWire json "schema"
  if schema != "wrapper-base64-vectors@1" then throw ("unsupported vector schema: " ++ schema)
  let profiles ← field json "profiles"
  let typeGraphs ← field json "type_graphs"
  let branches ← (← field json "branches").getArr?
  if branches.size != 25 then throw "expected 25 branches"
  let mut ids : List String := []
  let mut count := 0
  let mut differences : List String := []
  for branch in branches do
    let branchId : String ← getWire branch "id"
    if ids.contains branchId then throw ("duplicate branch: " ++ branchId)
    ids := branchId :: ids
    let profileId : String ← getWire branch "profile"
    let profile : ValueProfile ← (decode (← field profiles profileId)).mapError reprStr
    let graphId : String ← getWire branch "type_graph"
    let typeGraph ← field typeGraphs graphId
    let nodes : List Node ← getWire typeGraph "nodes"
    let rootId : String ← getWire typeGraph "root"
    let library : TypeSignatureLibrary := {
      identity := "wrapper-base64", revision := "1", profile, nodes, definitions := [] }
    let graph := library.graph
    let cases ← (← field branch "cases").getArr?
    if cases.isEmpty then throw ("empty branch: " ++ branchId)
    let mut caseIds : List String := []
    for testCase in cases do
      let caseId : String ← getWire testCase "id"
      if caseIds.contains caseId then throw ("duplicate case: " ++ caseId)
      caseIds := caseId :: caseIds
      let expected ← field testCase "expected"
      let actual ← (outcome graph (typeRef rootId) (← field testCase "input")).mapError
        (fun message => caseId ++ ": " ++ message)
      if actual != expected then
        differences := differences ++ [caseId ++ ": expected " ++ expected.compress ++
          ", actual " ++ actual.compress]
      count := count + 1
  if count != 55 then throw "expected 55 cases"
  pure (count, differences)

def main (args : List String) : IO UInt32 := do
  let path ← match args with
    | [] => pure "../comparison/declaration/wrapper_base64_vectors.json"
    | [path] => pure path
    | _ => throw (IO.userError "expected at most one vector file path")
  let source ← IO.FS.readFile path
  let .ok json := Necoherence.SignatureJson.parse source |
    throw (IO.userError "wrapper/base64 vector JSON parse failed")
  let (count, differences) ← match checkVectors json with
    | .ok result => pure result
    | .error message => throw (IO.userError message)
  for difference in differences do
    IO.eprintln difference
  if !differences.isEmpty then
    throw (IO.userError s!"wrapper/base64 vector mismatches: {differences.length}")
  IO.println s!"wrapper_base64_branches=25 wrapper_base64_cases={count} mismatches=0"
  pure 0
