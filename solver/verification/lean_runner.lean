-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import NecoherenceSolver.TypedMappingSolver
import NecoherenceSolver.TypedMappingWire
import Lean.Data.Json



open Necoherence
open NecoherenceTools
open Lean

namespace TypedMappingSolverRunner

private def encOperations (input : SolverInput) : Json :=
  Json.mkObj
    [("derive_enabled", encEnabledResult (deriveEnabled input)),
     ("check_reachability", encReachability (checkReachability input)),
     ("check_deadlock", encDeadlock (checkDeadlock input)),
     ("check_well_foundedness",
       encWellFounded (checkWellFoundedness input))]

end TypedMappingSolverRunner

open TypedMappingSolverRunner in
def main : IO Unit := do
  let path := (← IO.getEnv "TMS_FIXTURES").getD
    "../verification/fixtures.json"
  let text ← IO.FS.readFile path
  let doc ← match Json.parse text with
    | .error e =>
        IO.eprintln s!"lean_runner: cannot parse {path}: {e}"
        IO.Process.exit 1
    | .ok d => pure d
  let casesJ ← match doc.getObjVal? "cases" with
    | .error e =>
        IO.eprintln s!"lean_runner: bad fixtures: {e}"
        IO.Process.exit 1
    | .ok c => pure c
  let arr ← match casesJ.getArr? with
    | .error e =>
        IO.eprintln s!"lean_runner: bad cases: {e}"
        IO.Process.exit 1
    | .ok a => pure a
  let mut results : Array Json := #[]
  for c in arr do
    let name ← match c.getObjVal? "name" with
      | .ok n => match n.getStr? with
        | .ok s => pure s
        | .error e =>
            IO.eprintln s!"lean_runner: bad case name: {e}"
            IO.Process.exit 1
      | .error e =>
          IO.eprintln s!"lean_runner: bad case name: {e}"
          IO.Process.exit 1
    match c.getObjVal? "input" with
    | .error e =>
        IO.eprintln s!"lean_runner: case {name} lacks input: {e}"
        IO.Process.exit 1
    | .ok inputJ =>
        match decInput inputJ with
        | .error e =>
            IO.eprintln s!"lean_runner: cannot decode case {name}: {e}"
            IO.Process.exit 1
        | .ok input =>
            results := results.push
              (Json.mkObj [("case", toJson name),
                           ("operations", encOperations input)])
  let out := Json.mkObj
    [("producer", toJson "lean"),
     ("solver_module", toJson "NecoherenceSolver.TypedMappingSolver"),
     ("producer_kind", toJson "public-api"),
     ("results", Json.arr results)]
  IO.println (Json.compress out)

#eval main
