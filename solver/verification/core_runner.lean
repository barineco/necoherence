-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import NecoherenceSolver.TypedMappingSolver
import NecoherenceSolver.TypedMappingWire
import Lean.Data.Json

open Necoherence
open NecoherenceTools
open Lean
open TypedMappingSolverRunner

private def encValidate : Option InvalidReason → Json
  | none => Json.mkObj [("status", toJson "valid")]
  | some r => Json.mkObj [("status", toJson "invalid"), ("reason", encInvalid r)]

private def encMarkingOption : Option Marking → Json
  | none => Json.null
  | some m => encMarking m

private def encCore (input : SolverInput) (path : List String) : Json :=
  Json.mkObj
    [("validate", encValidate (validate input)),
     ("derive_enabled", encEnabledResult (deriveEnabled input)),
     ("binding_bound_exceeded", toJson (bindingBoundExceeded input)),
     ("path_replay", encMarkingOption (pathReplay input input.marking path)),
     ("step_at", Json.arr (path.toArray.map fun name =>
        encMarkingOption (stepAt input input.marking name)))]

private def fail (message : String) : IO α := do
  IO.eprintln s!"core_runner: {message}"
  IO.Process.exit 1

def main : IO Unit := do
  let path := (← IO.getEnv "TMS_CASES").getD "../verification/core_cases.json"
  let text ← IO.FS.readFile path
  let doc ← match Json.parse text with
    | .error e => fail s!"cannot parse {path}: {e}"
    | .ok d => pure d
  let arr ← match doc.getObjVal? "cases" >>= Json.getArr? with
    | .error e => fail s!"bad cases: {e}"
    | .ok a => pure a
  let mut results : Array Json := #[]
  for c in arr do
    let name ← match c.getObjVal? "name" >>= Json.getStr? with
      | .error e => fail s!"bad case name: {e}"
      | .ok s => pure s
    let input ← match c.getObjVal? "input" >>= decInput with
      | .error e => fail s!"cannot decode case {name}: {e}"
      | .ok i => pure i
    let steps ← match c.getObjVal? "path" >>= Json.getArr? with
      | .error e => fail s!"bad path in case {name}: {e}"
      | .ok a => match a.toList.mapM Json.getStr? with
        | .error e => fail s!"bad path in case {name}: {e}"
        | .ok l => pure l
    results := results.push
      (Json.mkObj [("case", toJson name), ("operations", encCore input steps)])
  IO.println (Json.compress (Json.mkObj
    [("producer", toJson "lean"), ("results", Json.arr results)]))

#eval main
