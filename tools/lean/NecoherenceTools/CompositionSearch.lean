-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import Necoherence.SemanticCodec
import NecoherenceTools.TypedMappingSolver

namespace NecoherenceTools.CompositionSearch
open Necoherence Necoherence.ExactJson Necoherence.SemanticTypes Necoherence.SemanticValidation Necoherence.SemanticComposition

private def replaceModelPath (tagKey : String) : SlotValue → ValuePath → SlotValue → Option SlotValue
  | _, [], replacement => some replacement
  | .present (.obj members), .field name :: rest, replacement => do
    let original := match memberValue name members with
      | none => SlotValue.absent | some .null => .null | some value => .present value
    let next ← replaceModelPath tagKey original rest replacement
    let retained := members.filter (fun member => member.1 != name)
    pure (.present (.obj (match next with
      | .absent => retained | .null => retained ++ [(name, .null)]
      | .present value => retained ++ [(name, value)])))
  | .present (.arr values), .index index :: rest, replacement => do
    let original ← values[index]?
    let next ← replaceModelPath tagKey (.present original) rest replacement
    let value ← match next with | .present value => some value | .null => some JsonValue.null | .absent => none
    pure (.present (.arr ((values.take index) ++ [value] ++ values.drop (index + 1))))
  | value@(.present (.obj members)), .variant tag :: rest, replacement =>
    if memberValue tagKey members == some (.str tag) then replaceModelPath tagKey value rest replacement else none
  | _, _, _ => none

private def refinedModelValues (prepared : PreparedCompositionInput) (state : SearchState)
    (source : AvailableValue) (base : List SlotValue) : List SlotValue := Id.run do
  let mut values := base
  for fact in state.facts do
    if fact.inspected.producer == source.producer then
      let replacements := match fact.exact, fact.refinement with
        | some value, _ => [value]
        | none, some contract => (slotSamples prepared contract).values
        | none, none => []
      let extended := values.flatMap (fun original => replacements.filterMap
        (fun replacement => replaceModelPath ((prepared.graph.profile.tag.map (fun (model : TagModel) => model.key)).getD "") original fact.inspected.path replacement))
      values := (values ++ extended).filter (fun value =>
        match acceptsSlot prepared.graph source.contract value with | .accepted => true | _ => false)
        |>.take prepared.input.bounds.maxBindingCandidates
  return values

private def modelCandidates (prepared : PreparedCompositionInput) (state : SearchState) :
    Enumeration (List (ProducerRef × SlotValue)) := Id.run do
  let mut models : List (List (ProducerRef × SlotValue)) := [[]]
  let mut obligations : List UnresolvedObligation := []
  for source in state.available do
    let supplied := exactValue prepared state { producer := source.producer, path := [] }
    let values := match supplied with
      | some value => [value]
      | none => refinedModelValues prepared state source (slotSamples prepared source.contract).values
    if values.isEmpty then obligations := obligations ++ [.inhabitation source.producer source.contract]
    let extended := models.flatMap (fun model => values.map (fun value => model ++ [(source.producer, value)]))
    if prepared.input.bounds.maxBindingCandidates < extended.length then obligations := obligations ++ [.bindingBoundExhausted]
    models := extended.take prepared.input.bounds.maxBindingCandidates
  return { values := models, obligations, cost := models.length }

private def rawCandidateFromTree (prepared : PreparedCompositionInput)
    (closure : CompositionClosureWitness) (tree : PlanTree) : Except WitnessFailure RawCompositionCandidate := do
  let mut certificates : List ResourceTraceCertificate := []
  for branch in planBranches [] tree do
    let some certificate := closure.nodes.flatMap (·.terminals) |>.find?
      (fun certificate => certificate.trace == branch) | throw (.missingEvidence "program branch certificate")
    certificates := certificates ++ [certificate]
  let mut initialMembership : List (InputId × SlotValue) := []
  for initial in prepared.input.initialInputs do
    let value ← match initial.source with
      | .suppliedValue value => pure value
      | .argument =>
        let some value := (slotSamples prepared initial.contract).values.head? | throw (.initialMembership initial.id)
        pure value
    initialMembership := initialMembership ++ [(initial.id, value)]
  pure {
    plan := { inputIdentity := prepared.input.identity, inputRevision := prepared.input.revision, root := tree },
    witness := { inputSnapshot := prepared.input, initialMembership, resourceTraces := certificates } }

private def produceResourceTrace (prepared : PreparedCompositionInput) (state : SearchState) (terminal : ReturnPlan) :
    Except UnresolvedObligation (Option ResourceTraceCertificate) := do
  let trace : BranchTrace := { steps := state.trace, terminal }
  let (lowered, correspondence) ← (lowerResourceTrace prepared trace).mapError (fun failure => match failure with
    | .unknown obligation => obligation | .invalid _ => UnresolvedObligation.branchBoundExhausted)
  if lowered.bound.maxBindings < candidateBindingCount lowered then
    throw (.resourceSolverUnknown (.bindingBoundExhausted lowered.bound.maxBindings))
  if lowered.bound.maxSearchSteps < correspondence.executionOrder.length then
    throw (.resourceSolverUnknown (.searchStepBoundExhausted lowered.bound.maxSearchSteps))
  match pathReplay lowered lowered.marking correspondence.executionOrder with
  | none => pure none
  | some finalMarking =>
    if !evalGoal finalMarking lowered.goal then pure none
    else
      let reachability : ReachabilityWitness := { path := correspondence.executionOrder, finalMarking }
      let acyclicity ← match checkWellFoundedness lowered with
        | .wellFounded witness => pure witness
        | .unknown reason => throw (.resourceSolverUnknown reason)
        | _ => throw .branchBoundExhausted
      let models := modelCandidates prepared state
      let mut found : Option ResourceTraceCertificate := none
      for model in models.values do
        if found.isNone then
          let certificate : ResourceTraceCertificate := {
            trace, lowering := lowered, correspondence,
            reachability, acyclicity, valueSources := model }
          match verifyResourceTrace prepared trace certificate with
          | .ok _ => found := some certificate
          | .error _ => pure ()
      if found.isSome then pure found
      else match models.obligations with
        | obligation :: _ => throw obligation
        | [] => throw .branchBoundExhausted

private def enumerateClosureNode (prepared : PreparedCompositionInput) (state : SearchState) :
    CompositionClosureNode × List UnresolvedObligation × Nat := Id.run do
  let returns := enumerateReturns prepared state
  let invocations := enumerateInvocations prepared state
  let guards := enumerateGuards prepared state
  let mut terminals : List ResourceTraceCertificate := []
  let mut obligations := returns.obligations ++ invocations.obligations ++ guards.obligations
  for terminal in returns.values do
    match produceResourceTrace prepared state terminal with
    | .ok (some certificate) => terminals := terminals ++ [certificate]
    | .ok none => pure ()
    | .error obligation => obligations := obligations ++ [obligation]
  return ({ state, actions := invocations.values ++ guards.values, terminals }, obligations,
    returns.cost + invocations.cost + guards.cost)

private def expandCompositionClosure (prepared : PreparedCompositionInput) :
    Nat → List SearchState → CompositionClosureWitness → CompositionClosureWitness
  | 0, frontier, witness => { witness with frontier }
  | _ + 1, [], witness => { witness with frontier := [] }
  | fuel + 1, state :: pending, witness =>
    if witness.nodes.any (fun node => node.state == state) then
      expandCompositionClosure prepared fuel pending witness
    else
      let (node, obligations, cost) := enumerateClosureNode prepared state
      let successors := node.actions.flatMap (fun action =>
        ((actionSuccessors prepared state action).toOption.map (fun values => values.map (·.2))).getD [])
      let next := { witness with
        nodes := witness.nodes ++ [node], steps := witness.steps + 1,
        bindingCandidates := witness.bindingCandidates + cost,
        branchNodes := witness.branchNodes + successors.length,
        obligations := witness.obligations ++ obligations }
      if prepared.input.bounds.maxBindingCandidates < next.bindingCandidates ||
          prepared.input.bounds.maxBranchNodes < next.branchNodes then
        { next with
          frontier := successors ++ pending,
          obligations := next.obligations ++ [if prepared.input.bounds.maxBindingCandidates < next.bindingCandidates then
            .bindingBoundExhausted else .branchBoundExhausted] }
      else expandCompositionClosure prepared fuel (successors ++ pending) next

private def buildCompositionClosure (prepared : PreparedCompositionInput) : CompositionClosureWitness :=
  let state := initialState prepared
  let (root, obligations, cost) := enumerateClosureNode prepared state
  let successors := root.actions.flatMap (fun action =>
    ((actionSuccessors prepared state action).toOption.map (fun values => values.map (·.2))).getD [])
  expandCompositionClosure prepared prepared.input.bounds.maxExpandedStates successors
    { inputIdentity := prepared.input.identity, inputRevision := prepared.input.revision, nodes := [root],
      steps := 0, bindingCandidates := cost, branchNodes := successors.length, frontier := [], obligations }

def derive (prepared : PreparedCompositionInput) : Except CompositionEngineFailure (CompositionDecision prepared) := do
  let initialObligations := prepared.input.initialInputs.flatMap (fun initial =>
    meaningObligations prepared.graph [initial.contract.typeRef] ++
      (match initial.source with
       | .argument => []
       | .suppliedValue value => match acceptsSlot prepared.graph initial.contract value with
         | .unresolved obligations => obligations | _ => []))
  if !initialObligations.isEmpty then return .unknown [.meaning initialObligations] [initialState prepared]
  let closure := buildCompositionClosure prepared
  let programs := rootPrograms prepared closure
  let mut candidates : List (VerifiedCompositionCandidate prepared) := []
  let mut keys : List String := []
  let mut obligations := closure.obligations ++ programs.obligations
  for tree in programs.values do
    let key := canonicalPlanKey prepared tree
    if !keys.contains key then
      match rawCandidateFromTree prepared closure tree with
      | .error failure => throw (.witness failure)
      | .ok raw =>
        match verifyCompositionCandidate prepared raw with
        | .error failure => throw (.witness failure)
        | .ok checked =>
          candidates := candidates ++ [checked]
          keys := keys ++ [key]
  if prepared.input.selectionPolicy == some .anyFeasible then
    match candidates with
    | candidate :: _ =>
      let checked ← (verifyComposition prepared {
        plan := candidate.raw.plan, witness := candidate.raw.witness,
        selection := .anyFeasible }).mapError CompositionEngineFailure.witness
      return .solved checked
    | [] => pure ()
  if !closure.frontier.isEmpty then obligations := obligations ++ [.stateBoundExhausted]
  if prepared.input.selectionPolicy != some .anyFeasible && 2 ≤ candidates.length then
    return (← decideAmbiguous prepared candidates)
  if !obligations.isEmpty then
    if !candidates.isEmpty && prepared.input.selectionPolicy != some .anyFeasible then
      obligations := obligations ++ [.unresolvedUniqueness]
    let frontier := if closure.frontier.isEmpty && !programs.obligations.isEmpty then
      [initialState prepared] else closure.frontier
    return .unknown obligations frontier
  let checkedClosure ← (verifyCompositionClosure prepared closure).mapError CompositionEngineFailure.witness
  match candidates with
  | [] => return (← decideUnreachable prepared closure checkedClosure)
  | [candidate] =>
    let checked ← (verifyComposition prepared {
      plan := candidate.raw.plan, witness := candidate.raw.witness,
      selection := .unique closure (canonicalPlanKey prepared candidate.raw.plan.root) }).mapError CompositionEngineFailure.witness
    return .solved checked
  | _ =>
    return (← decideAmbiguous prepared candidates)

end NecoherenceTools.CompositionSearch
