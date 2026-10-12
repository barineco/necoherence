-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SemanticInvariantDerivation
import Necoherence.SignatureCompositionDiagnostics

namespace Necoherence.SignatureCompositionWire
open Lean Necoherence.SemanticTypes Necoherence.SemanticComposition Necoherence.SignatureWire Necoherence.SemanticInvariantWire Necoherence.SemanticInvariantDerivation


def stateEncode (library : Library) (state : SearchState) : Except WireFailure Json := do
  let trace ← state.trace.mapM (stepEncode library)
  pure (Json.mkObj [("available", encode state.available), ("used_sites", encode state.usedSites),
    ("used_guards", encode state.usedGuards), ("facts", encode state.facts),
    ("trace", .arr trace.toArray), ("pending_failure", encode state.pendingFailure)])

def stateDecode (library : Library) (json : Json) : Except WireFailure SearchState := do
  keys json ["available", "used_sites", "used_guards", "facts", "trace", "pending_failure"]
  let trace ← (← liftJson ((← liftJson (json.getObjVal? "trace")).getArr?)).toList.mapM (stepDecode library)
  pure {
    available := ← get json "available"
    usedSites := ← get json "used_sites"
    usedGuards := ← get json "used_guards"
    facts := ← get json "facts"
    trace
    pendingFailure := ← get json "pending_failure" }

private def choiceDecode (library : Library) (json : Json) : Except WireFailure LocalAction := do
  let row ← fields json
  match ← get (α := String) json "tag" with
  | "Invoke" =>
    keys row ["invocation", "outcomes", "empty_outcomes"]
    pure (.invocation (← invocationDecode library (← liftJson (row.getObjVal? "invocation"))))
  | "Guard" =>
    keys row ["guard", "inspected", "arms"]
    pure (.guard (← get row "guard") (← get row "inspected"))
  | _ => throw (WireFailure.syntax "$" "unknown closure choice")

private def choiceEncode (library : Library) (prepared : PreparedCompositionInput) (state : SearchState)
    (action : LocalAction) : Except WireFailure Json := do
  let successors ← (closureActionSuccessors prepared state action).mapError
    (fun failure => WireFailure.syntax "$" (reprStr failure))
  match action with
  | .invocation invocation =>
    let some function := prepared.input.signatures.find? (fun function => function.reference == invocation.function) |
      throw (WireFailure.syntax "$" "unresolved closure function")
    let outcomes := successors.filterMap fun (step, _) => match step with | .invocation _ outcome => some outcome | _ => none
    let empty := function.outcomes.filterMap fun outcome => if outcomes.contains outcome.id then none else some outcome.id
    pure (recordTag "Invoke" [("invocation", ← invocationEncode library invocation), ("outcomes", encode outcomes), ("empty_outcomes", encode empty)])
  | .guard guard inspected =>
    let arms := successors.filterMap fun (step, _) => match step with | .guard _ _ arm => some arm | _ => none
    pure (recordTag "Guard" [("guard", encode guard), ("inspected", encode inspected), ("arms", encode arms)])

private def sameJson (a b : Json) : Bool :=
  Necoherence.SignatureGeneration.canonicalJson a == Necoherence.SignatureGeneration.canonicalJson b

def closureDecode (library : Library) (problem : Json) (prepared : PreparedCompositionInput)
    (json : Json) : Except WireFailure CompositionClosureWitness := do
  keys json ["input_snapshot", "root", "states"]
  if !sameJson (← liftJson (json.getObjVal? "input_snapshot")) problem then throw (WireFailure.syntax "$" "closure input snapshot mismatch")
  let root : Nat ← get json "root"
  let rows ← liftJson ((← liftJson (json.getObjVal? "states")).getArr?)
  let states ← rows.toList.mapM fun row => do stateDecode library (← liftJson (row.getObjVal? "state"))
  let some rootState := states[root]? | throw (WireFailure.syntax "$" "closure root index")
  if rootState != closureInitialState prepared then throw (WireFailure.syntax "$" "closure initial state mismatch")
  let nodes ← rows.toList.mapM fun row => do
    keys row ["state", "terminals", "choices", "rejected_connections", "missing_supply"]
    for diagnostic in (← liftJson ((← liftJson (row.getObjVal? "rejected_connections")).getArr?)) do
      Necoherence.SignatureCompositionDiagnostics.check library prepared.input "ConnectionFailure" diagnostic
    for diagnostic in (← liftJson ((← liftJson (row.getObjVal? "missing_supply")).getArr?)) do
      Necoherence.SignatureCompositionDiagnostics.check library prepared.input "MissingSupply" diagnostic
    let state ← stateDecode library (← liftJson (row.getObjVal? "state"))
    let mut terminals : List ResourceTraceCertificate := []
    for terminal in (← liftJson ((← liftJson (row.getObjVal? "terminals")).getArr?)) do
      keys terminal ["terminal", "assessment"]
      Necoherence.SignatureCompositionDiagnostics.check library prepared.input "ReturnPlan" (← liftJson (terminal.getObjVal? "terminal"))
      let terminalPlan ← returnDecode library (← liftJson (terminal.getObjVal? "terminal"))
      let assessment ← liftJson (terminal.getObjVal? "assessment")
      Necoherence.SignatureCompositionDiagnostics.check library prepared.input "TerminalAssessment" assessment
      if (← get (α := String) assessment "tag") == "Feasible" then
        let certificate ← resourceDecode library (← payload assessment)
        if certificate.trace.terminal != terminalPlan then throw (WireFailure.syntax "$" "terminal assessment mismatch")
        terminals := terminals ++ [certificate]
    let actions ← (← liftJson ((← liftJson (row.getObjVal? "choices")).getArr?)).toList.mapM fun coverage => do
      keys coverage ["choice", "children"]
      Necoherence.SignatureCompositionDiagnostics.check library prepared.input "ChoiceCoverage" coverage
      let choice ← liftJson (coverage.getObjVal? "choice")
      let action ← choiceDecode library choice
      if !sameJson choice (← choiceEncode library prepared state action) then throw (WireFailure.syntax "$" "closure choice coverage mismatch")
      let indices : List Nat ← get coverage "children"
      let successors ← (closureActionSuccessors prepared state action).mapError
        (fun failure => WireFailure.syntax "$" (reprStr failure))
      if indices.length != successors.length then throw (WireFailure.syntax "$" "closure child coverage mismatch")
      for (index, (_, expected)) in indices.zip successors do
        let some supplied := states[index]? | throw (WireFailure.syntax "$" "closure successor index")
        if supplied != expected then throw (WireFailure.syntax "$" "closure successor state mismatch")
      pure action
    pure ({ state, actions, terminals } : CompositionClosureNode)
  let candidates := nodes.foldl (fun count node => count + closureBindingCandidates prepared node.state) 0
  let branches ← nodes.foldlM (fun count node => node.actions.foldlM (fun count action => do
    pure (count + (← (closureActionSuccessors prepared node.state action).mapError
      (fun failure => WireFailure.syntax "$" (reprStr failure))).length)) count) 0
  pure {
    inputIdentity := prepared.input.identity
    inputRevision := prepared.input.revision
    nodes
    steps := nodes.length - 1
    bindingCandidates := candidates
    branchNodes := branches
    frontier := []
    obligations := [] }


private def projectDerivation (library : Library) (problem : Json) (prepared : PreparedCompositionInput)
    (json : Json) : Except WireFailure RawComposition := do
  keys json ["plan", "witness", "selection"]
  let plan ← liftJson (json.getObjVal? "plan")
  keys plan ["input_identity", "input_revision", "root"]
  let witness ← liftJson (json.getObjVal? "witness")
  keys witness ["input_snapshot", "initial_membership", "resource_traces"]
  if !sameJson (← liftJson (witness.getObjVal? "input_snapshot")) problem then throw (WireFailure.syntax "$" "input snapshot mismatch")
  let tree ← treeDecode library (← liftJson (plan.getObjVal? "root"))
  let selectionJson ← liftJson (json.getObjVal? "selection")
  let selection ← match ← get (α := String) selectionJson "tag" with
    | "AnyFeasible" => do keys selectionJson ["tag"]; pure SelectionEvidence.anyFeasible
    | "Unique" => do
      let row ← fields selectionJson
      keys row ["closure", "canonical_plan"]
      let _ : String ← get row "canonical_plan"
      let closure ← closureDecode library problem prepared (← liftJson (row.getObjVal? "closure"))
      pure (.unique closure (canonicalPlanKey prepared tree))
    | _ => throw (WireFailure.syntax "$" "unknown selection evidence")
  let traces ← (← liftJson ((← liftJson (witness.getObjVal? "resource_traces")).getArr?)).toList.mapM (resourceDecode library)
  pure {
    plan := { inputIdentity := ← get plan "input_identity", inputRevision := ← get plan "input_revision", root := tree }
    witness := { inputSnapshot := prepared.input, initialMembership := ← get witness "initial_membership", resourceTraces := traces }
    selection }

structure DerivationWire where
  exactJson : Json
  proofProjection : RawComposition

def decodeDerivation (library : Library) (problem : Json) (prepared : PreparedCompositionInput)
    (json : Json) : Except WireFailure DerivationWire := do
  let proofProjection ← projectDerivation library problem prepared json
  pure { exactJson := json, proofProjection }

def encodeDerivation (wire : DerivationWire) : Json := wire.exactJson

end Necoherence.SignatureCompositionWire
