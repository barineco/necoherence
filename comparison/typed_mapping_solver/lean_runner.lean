-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import NecoherenceTools.TypedMappingSolver
import Lean.Data.Json



open Necoherence
open NecoherenceTools
open Lean

namespace TypedMappingSolverRunner

private def jfield (j : Json) (k : String) : Except String Json :=
  j.getObjVal? k

private def jstr (j : Json) (k : String) : Except String String := do
  (← jfield j k).getStr?

private def jnat (j : Json) (k : String) : Except String Nat := do
  (← jfield j k).getNat?

private def jarr (j : Json) (k : String) : Except String (Array Json) := do
  (← jfield j k).getArr?

private def jstrs (j : Json) (k : String) : Except String (List String) := do
  let arr ← jarr j k
  arr.toList.mapM Json.getStr?

private def decTokenKind (s : String) : Except String TokenKind :=
  match s with
  | "input" => .ok .input
  | "output" => .ok .output
  | "failure" => .ok .failure
  | "effect" => .ok .effect
  | "observation" => .ok .observation
  | "accepted" => .ok .accepted
  | other => .error s!"unknown token kind {other}"

private def decToken (j : Json) : Except String ColoredToken := do
  return { target := ← jstr j "target",
           index := ← jnat j "index",
           revision := ← jnat j "revision",
           kind := ← decTokenKind (← jstr j "kind") }

private def decPlace (j : Json) : Except String TypedPlace := do
  return { identity := ← jstr j "identity",
           tokenType := ← jstr j "token_type",
           revision := ← jnat j "revision" }

private def decTransition (j : Json) : Except String TypedTransition := do
  return { identity := ← jstr j "identity",
           inputPlaces := ← jstrs j "input_places",
           outputPlaces := ← jstrs j "output_places",
           failurePlaces := ← jstrs j "failure_places",
           revision := ← jnat j "revision" }

private def decMode (s : String) : Except String BindingMode :=
  match s with
  | "read" => .ok .read
  | "consume" => .ok .consume
  | other => .error s!"unknown binding mode {other}"

private def decBinding (j : Json) : Except String InputBinding := do
  return { transitionId := ← jstr j "transition_id",
           name := ← jstr j "name",
           place := ← jstr j "place",
           tokenType := ← jstr j "token_type",
           identity := ← jstr j "identity",
           provenance := ← jstr j "provenance",
           multiplicity := ← jnat j "multiplicity",
           mode := ← decMode (← jstr j "mode"),
           requiredRevision := ← jnat j "required_revision" }

private def decEdge (j : Json) : Except String (String × String) := do
  let arr ← j.getArr?
  match arr.toList with
  | [a, b] => return (← a.getStr?, ← b.getStr?)
  | _ => .error "edge must be a two-element array"

private partial def decGoal (j : Json) : Except String GoalPredicate := do
  let kind ← jstr j "kind"
  if kind == "place_has_at_least" then
    return .placeHasAtLeast (← jstr j "place") (← jnat j "count")
  else if kind == "place_has_token" then
    return .placeHasToken (← jstr j "place") (← jstr j "target")
      (← jnat j "index") (← jnat j "revision")
  else if kind == "and" then
    let a ← decGoal (← jfield j "a")
    let b ← decGoal (← jfield j "b")
    return .glAnd a b
  else if kind == "or" then
    let a ← decGoal (← jfield j "a")
    let b ← decGoal (← jfield j "b")
    return .glOr a b
  else if kind == "not" then
    return .glNot (← decGoal (← jfield j "a"))
  else
    .error s!"unknown goal kind {kind}"

private def decMarking (j : Json) : Except String Marking := do
  let entries ← jarr j "places"
  let pairs ← entries.toList.mapM fun e => do
    let place ← jstr e "place"
    let toks ← jarr e "tokens"
    let decoded ← toks.toList.mapM decToken
    pure (place, decoded)
  return { places := pairs }

private def decBound (j : Json) : Except String DomainBound := do
  return { targetIdentity := ← jstr j "target_identity",
           index := ← jnat j "index",
           revision := ← jnat j "revision",
           maxBindings := ← jnat j "max_bindings",
           maxSearchSteps := ← jnat j "max_search_steps" }

private def decInput (j : Json) : Except String SolverInput := do
  let places ← jarr j "places"
  let transitions ← jarr j "transitions"
  let bindings ← jarr j "bindings"
  let graphJ ← jfield j "graph"
  let edgesJ ← jarr graphJ "edges"
  let edges ← edgesJ.toList.mapM decEdge
  return { places := ← places.toList.mapM decPlace,
           transitions := ← transitions.toList.mapM decTransition,
           bindings := ← bindings.toList.mapM decBinding,
           goal := ← decGoal (← jfield j "goal"),
           graph := { places := ← jstrs graphJ "places",
                      transitions := ← jstrs graphJ "transitions",
                      edges := edges,
                      revision := ← jnat graphJ "revision" },
           marking := ← decMarking (← jfield j "marking"),
           bound := ← decBound (← jfield j "bound") }



private def encTokenKind : TokenKind → String
  | .input => "input"
  | .output => "output"
  | .failure => "failure"
  | .effect => "effect"
  | .observation => "observation"
  | .accepted => "accepted"

private def encToken (t : ColoredToken) : Json :=
  Json.mkObj [("target", toJson t.target), ("index", toJson t.index),
    ("revision", toJson t.revision),
    ("kind", toJson (encTokenKind t.kind))]

private def encMarking (m : Marking) : Json :=
  Json.mkObj [("places", Json.arr (m.places.toArray.map fun (p, ts) =>
    Json.mkObj [("place", toJson p),
                ("tokens", Json.arr (ts.toArray.map encToken))]))]

private def encMode : BindingMode → String
  | .read => "read"
  | .consume => "consume"

private def encBinding (b : InputBinding) : Json :=
  Json.mkObj [("transition_id", toJson b.transitionId),
    ("name", toJson b.name), ("place", toJson b.place),
    ("token_type", toJson b.tokenType),
    ("identity", toJson b.identity),
    ("provenance", toJson b.provenance),
    ("multiplicity", toJson b.multiplicity),
    ("mode", toJson (encMode b.mode)),
    ("required_revision", toJson b.requiredRevision)]

private def encInvalid : InvalidReason → Json
  | .unknownPlace p =>
      Json.mkObj [("kind", toJson "unknown_place"), ("place", toJson p)]
  | .unknownTransition t =>
      Json.mkObj [("kind", toJson "unknown_transition"),
                  ("transition_id", toJson t)]
  | .unknownInputPlace t p =>
      Json.mkObj [("kind", toJson "unknown_input_place"),
                  ("transition_id", toJson t), ("place", toJson p)]
  | .missingInputBinding t p =>
      Json.mkObj [("kind", toJson "missing_input_binding"),
                  ("transition_id", toJson t), ("place", toJson p)]
  | .duplicateTransitionIdentity identity =>
      Json.mkObj [("kind", toJson "duplicate_transition_identity"),
                  ("identity", toJson identity)]
  | .typeMismatch p e a =>
      Json.mkObj [("kind", toJson "type_mismatch"), ("place", toJson p),
                  ("expected", toJson e), ("actual", toJson a)]
  | .multiplicityMismatch t n e a =>
      Json.mkObj [("kind", toJson "multiplicity_mismatch"),
                  ("transition_id", toJson t), ("name", toJson n),
                  ("expected", toJson e), ("actual", toJson a)]
  | .revisionMismatch t n e a =>
      Json.mkObj [("kind", toJson "revision_mismatch"),
                  ("transition_id", toJson t), ("name", toJson n),
                  ("expected", toJson e), ("actual", toJson a)]
  | .identityMismatch t n =>
      Json.mkObj [("kind", toJson "identity_mismatch"),
                  ("transition_id", toJson t), ("name", toJson n)]
  | .dependencyMismatch t p =>
      Json.mkObj [("kind", toJson "dependency_mismatch"),
                  ("transition_id", toJson t), ("place", toJson p)]

private def encUnknown : UnknownReason → Json
  | .bindingBoundExhausted n =>
      Json.mkObj [("kind", toJson "binding_bound_exhausted"),
                  ("limit", toJson n)]
  | .searchStepBoundExhausted n =>
      Json.mkObj [("kind", toJson "search_step_bound_exhausted"),
                  ("limit", toJson n)]

private def encEnabledList (s : EnabledSet) : Json :=
  Json.arr (s.enabled.toArray.map fun e =>
    Json.mkObj [("transition_id", toJson e.transitionId),
                ("bindings", Json.arr (e.bindings.toArray.map encBinding))])

private def encEnabledResult : EnabledResult → Json
  | .enabledSet s => Json.mkObj [("status", toJson "enabled_set"),
                                 ("enabled", encEnabledList s)]
  | .invalid r => Json.mkObj [("status", toJson "invalid"),
                              ("reason", encInvalid r)]

private def encReachability : ReachabilityResult → Json
  | .invalid r => Json.mkObj [("status", toJson "invalid"),
                              ("reason", encInvalid r)]
  | .reachable w =>
      Json.mkObj [("status", toJson "reachable"),
                  ("path", Json.arr (w.path.toArray.map toJson)),
                  ("final_marking", encMarking w.finalMarking)]
  | .unknown r => Json.mkObj [("status", toJson "unknown"),
                              ("reason", encUnknown r)]
  | .unreachable w =>
      Json.mkObj [("status", toJson "unreachable"),
                  ("closure_witness",
                    Json.mkObj [("explored_markings",
                      Json.arr (w.exploredMarkings.toArray.map encMarking)),
                      ("steps", toJson w.steps),
                      ("frontier",
                        Json.arr (w.frontier.toArray.map encMarking))])]

private def encDeadlock : DeadlockResult → Json
  | .deadlocked w =>
      Json.mkObj [("status", toJson "deadlocked"),
                  ("marking", encMarking w.marking)]
  | .invalid r => Json.mkObj [("status", toJson "invalid"),
                              ("reason", encInvalid r)]
  | .notDeadlocked s =>
      Json.mkObj [("status", toJson "not_deadlocked"),
                  ("enabled", encEnabledList s)]
  | .unknown r => Json.mkObj [("status", toJson "unknown"),
                              ("reason", encUnknown r)]

private def encCycleWitness (w : CycleWitness) : Json :=
  Json.mkObj
    [("prefix_path", Json.arr (w.prefixPath.toArray.map toJson)),
     ("cycle_path", Json.arr (w.cyclePath.toArray.map toJson)),
     ("cycle_start", encMarking w.cycleStart),
     ("cycle_end", encMarking w.cycleEnd),
     ("measure_decreasing", toJson w.measureDecreasing)]

private def encAcyclicWitness (w : AcyclicWitness) : Json :=
  Json.mkObj
    [("explored_markings",
      Json.arr (w.exploredMarkings.toArray.map encMarking)),
     ("steps", toJson w.steps),
     ("frontier", Json.arr (w.frontier.toArray.map encMarking))]

private def encWellFounded : WellFoundednessResult → Json
  | .invalid r => Json.mkObj [("status", toJson "invalid"),
                              ("reason", encInvalid r)]
  | .notWellFounded w =>
      Json.mkObj [("status", toJson "not_well_founded"),
                  ("witness", encCycleWitness w)]
  | .unknown r => Json.mkObj [("status", toJson "unknown"),
                              ("reason", encUnknown r)]
  | .wellFounded w =>
      Json.mkObj [("status", toJson "well_founded"),
                  ("witness", encAcyclicWitness w)]

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
    "../../comparison/typed_mapping_solver/fixtures.json"
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
     ("solver_module", toJson "NecoherenceTools.TypedMappingSolver"),
     ("producer_kind", toJson "public-api"),
     ("results", Json.arr results)]
  IO.println (Json.compress out)

#eval main
