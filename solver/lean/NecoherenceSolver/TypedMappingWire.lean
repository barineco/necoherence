-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import NecoherenceSolver.TypedMappingSolver
import Lean.Data.Json

open Necoherence
open NecoherenceTools
open Lean

namespace TypedMappingSolverRunner


def jfield (j : Json) (k : String) : Except String Json :=
  j.getObjVal? k

def jstr (j : Json) (k : String) : Except String String := do
  (← jfield j k).getStr?

def jnat (j : Json) (k : String) : Except String Nat := do
  (← jfield j k).getNat?

def jarr (j : Json) (k : String) : Except String (Array Json) := do
  (← jfield j k).getArr?

def jstrs (j : Json) (k : String) : Except String (List String) := do
  let arr ← jarr j k
  arr.toList.mapM Json.getStr?

def decTokenKind (s : String) : Except String TokenKind :=
  match s with
  | "input" => .ok .input
  | "output" => .ok .output
  | "failure" => .ok .failure
  | "effect" => .ok .effect
  | "observation" => .ok .observation
  | "accepted" => .ok .accepted
  | other => .error s!"unknown token kind {other}"

def decToken (j : Json) : Except String ColoredToken := do
  return { target := ← jstr j "target",
           index := ← jnat j "index",
           revision := ← jnat j "revision",
           kind := ← decTokenKind (← jstr j "kind") }

def decPlace (j : Json) : Except String TypedPlace := do
  return { identity := ← jstr j "identity",
           tokenType := ← jstr j "token_type",
           revision := ← jnat j "revision" }

def decTransition (j : Json) : Except String TypedTransition := do
  return { identity := ← jstr j "identity",
           inputPlaces := ← jstrs j "input_places",
           outputPlaces := ← jstrs j "output_places",
           failurePlaces := ← jstrs j "failure_places",
           revision := ← jnat j "revision" }

def decMode (s : String) : Except String BindingMode :=
  match s with
  | "read" => .ok .read
  | "consume" => .ok .consume
  | other => .error s!"unknown binding mode {other}"

def decBinding (j : Json) : Except String InputBinding := do
  return { transitionId := ← jstr j "transition_id",
           name := ← jstr j "name",
           place := ← jstr j "place",
           tokenType := ← jstr j "token_type",
           identity := ← jstr j "identity",
           provenance := ← jstr j "provenance",
           multiplicity := ← jnat j "multiplicity",
           mode := ← decMode (← jstr j "mode"),
           requiredRevision := ← jnat j "required_revision" }

def decEdge (j : Json) : Except String (String × String) := do
  let arr ← j.getArr?
  match arr.toList with
  | [a, b] => return (← a.getStr?, ← b.getStr?)
  | _ => .error "edge must be a two-element array"

partial def decGoal (j : Json) : Except String GoalPredicate := do
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

def decMarking (j : Json) : Except String Marking := do
  let entries ← jarr j "places"
  let pairs ← entries.toList.mapM fun e => do
    let place ← jstr e "place"
    let toks ← jarr e "tokens"
    let decoded ← toks.toList.mapM decToken
    pure (place, decoded)
  return { places := pairs }

def decBound (j : Json) : Except String DomainBound := do
  return { targetIdentity := ← jstr j "target_identity",
           index := ← jnat j "index",
           revision := ← jnat j "revision",
           maxBindings := ← jnat j "max_bindings",
           maxSearchSteps := ← jnat j "max_search_steps" }

def decInput (j : Json) : Except String SolverInput := do
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



def encTokenKind : TokenKind → String
  | .input => "input"
  | .output => "output"
  | .failure => "failure"
  | .effect => "effect"
  | .observation => "observation"
  | .accepted => "accepted"

def encToken (t : ColoredToken) : Json :=
  Json.mkObj [("target", toJson t.target), ("index", toJson t.index),
    ("revision", toJson t.revision),
    ("kind", toJson (encTokenKind t.kind))]

def encMarking (m : Marking) : Json :=
  Json.mkObj [("places", Json.arr (m.places.toArray.map fun (p, ts) =>
    Json.mkObj [("place", toJson p),
                ("tokens", Json.arr (ts.toArray.map encToken))]))]

def encMode : BindingMode → String
  | .read => "read"
  | .consume => "consume"

def encBinding (b : InputBinding) : Json :=
  Json.mkObj [("transition_id", toJson b.transitionId),
    ("name", toJson b.name), ("place", toJson b.place),
    ("token_type", toJson b.tokenType),
    ("identity", toJson b.identity),
    ("provenance", toJson b.provenance),
    ("multiplicity", toJson b.multiplicity),
    ("mode", toJson (encMode b.mode)),
    ("required_revision", toJson b.requiredRevision)]

def encInvalid : InvalidReason → Json
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

def encUnknown : UnknownReason → Json
  | .bindingBoundExhausted n =>
      Json.mkObj [("kind", toJson "binding_bound_exhausted"),
                  ("limit", toJson n)]
  | .searchStepBoundExhausted n =>
      Json.mkObj [("kind", toJson "search_step_bound_exhausted"),
                  ("limit", toJson n)]

def encEnabledList (s : EnabledSet) : Json :=
  Json.arr (s.enabled.toArray.map fun e =>
    Json.mkObj [("transition_id", toJson e.transitionId),
                ("bindings", Json.arr (e.bindings.toArray.map encBinding))])

def encEnabledResult : EnabledResult → Json
  | .enabledSet s => Json.mkObj [("status", toJson "enabled_set"),
                                 ("enabled", encEnabledList s)]
  | .invalid r => Json.mkObj [("status", toJson "invalid"),
                              ("reason", encInvalid r)]

def encReachability : ReachabilityResult → Json
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

def encDeadlock : DeadlockResult → Json
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

def encCycleWitness (w : CycleWitness) : Json :=
  Json.mkObj
    [("prefix_path", Json.arr (w.prefixPath.toArray.map toJson)),
     ("cycle_path", Json.arr (w.cyclePath.toArray.map toJson)),
     ("cycle_start", encMarking w.cycleStart),
     ("cycle_end", encMarking w.cycleEnd),
     ("measure_decreasing", toJson w.measureDecreasing)]

def encAcyclicWitness (w : AcyclicWitness) : Json :=
  Json.mkObj
    [("explored_markings",
      Json.arr (w.exploredMarkings.toArray.map encMarking)),
     ("steps", toJson w.steps),
     ("frontier", Json.arr (w.frontier.toArray.map encMarking))]

def encWellFounded : WellFoundednessResult → Json
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

end TypedMappingSolverRunner
