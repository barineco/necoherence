-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SemanticCodec
import Necoherence.NetworkEffect

namespace Necoherence.SemanticExecution

open Necoherence.ExactJson Necoherence.SemanticTypes Necoherence.SemanticValidation
open Necoherence.SemanticComposition

inductive ExecutionFailure where
  | value (failure : ValidationFailure)
  | missingArgument (id : InputId)
  | missingValue (ref : ValueRef)
  | provider (site : SiteId) (message : String)
  | invalidOutcome (site : SiteId) (outcome : OutcomeId)
  | resource (lot : ResourceLotRef) (condition : String)
  | invalidPlan (condition : String)
  | network (failure : NetworkFailure)
  | networkTerminal (terminal : NetworkTerminal)
  | networkPending (started : StartedAttempt)
  deriving Repr


instance : Inhabited ExecutionFailure := ⟨.invalidPlan ""⟩
structure CallResult where
  outcome : OutcomeId
  outputs : List (PortId × SlotValue)

abbrev Provider := InvocationSite → List (PortId × SlotValue) → IO (Except ExecutionFailure CallResult)

inductive ExecutionResult where
  | success (outputs : List (GoalPortId × SlotValue))
  | failure (embedding : FailureEmbeddingId) (value : SlotValue)
  deriving Repr

structure RuntimeState where
  values : List (ProducerRef × SlotValue)
  resources : List (ResourceLotRef × ResourceLot)

partial def project (tagKey : String) : SlotValue → ValuePath → Except ExecutionFailure SlotValue
  | value, [] => pure value
  | .present (.obj members), .field name :: rest => project tagKey (Necoherence.SemanticCodec.fieldValue members name) rest
  | .present (.arr items), .index index :: rest =>
    match items[index]? with
    | some .null => project tagKey .null rest
    | some value => project tagKey (.present value) rest
    | none => .error (.invalidPlan "array projection outside value")
  | .present (.obj members), .variant tag :: rest =>
    if memberValue tagKey members == some (.str tag) then project tagKey (.present (.obj members)) rest
    else .error (.invalidPlan "variant projection mismatch")
  | _, _ => .error (.invalidPlan "projection shape mismatch")

def lookup (graph : SemanticGraph) (state : RuntimeState) (ref : ValueRef) : Except ExecutionFailure SlotValue := do
  let some (_, value) := state.values.find? (fun p => p.1 == ref.producer) | throw (.missingValue ref)
  project ((graph.profile.tag.map (fun (model : TagModel) => model.key)).getD "") value ref.path

partial def evaluateBinding (graph : SemanticGraph) (state : RuntimeState) : BindingExpr → Except ExecutionFailure SlotValue
  | .source ref _ _ => lookup graph state ref
  | .product _ _ fields => do
    let members ← fields.mapM fun (name, binding) => do
      match ← evaluateBinding graph state binding with
      | .absent => pure []
      | .null => pure [(name, JsonValue.null)]
      | .present value => pure [(name, value)]
    pure (.present (.obj members.flatten))

def validate (graph : SemanticGraph) (contract : SlotContract) (value : SlotValue) : Except ExecutionFailure Unit := do
  let _ ← (validateSlot graph contract value).mapError ExecutionFailure.value
  pure ()

def initialState (prepared : PreparedCompositionInput) (arguments : List (InputId × SlotValue)) : Except ExecutionFailure RuntimeState := do
  let values ← prepared.input.initialInputs.mapM fun initial => do
    let value ← match initial.source with
      | .suppliedValue value => pure value
      | .argument =>
        match arguments.find? (fun p => p.1 == initial.id) with
        | some (_, value) => pure value
        | none => throw (.missingArgument initial.id)
    validate prepared.graph initial.contract value
    pure (ProducerRef.initial initial.id, value)
  pure { values, resources := prepared.input.initialResources.map fun lot => (.initial lot.id, lot) }

def bindResources (signature : FunctionSignature) (invocation : InvocationPlan) (state : RuntimeState) : Except ExecutionFailure RuntimeState := do
  let mut resources := state.resources
  for binding in invocation.resources do
    let some requirement := signature.resourceInputs.find? (fun r => r.id == binding.requirement) |
      throw (.invalidPlan "resource requirement mismatch")
    let some (_, lot) := resources.find? (fun p => p.1 == binding.lot) |
      throw (.resource binding.lot "missing lot")
    if lot.revision != requirement.requiredRevision then throw (.resource binding.lot "revision mismatch")
    if lot.quantity < requirement.multiplicity then throw (.resource binding.lot "insufficient quantity")
    if requirement.mode == .consume then
      resources := resources.map fun (ref, existing) =>
        if ref == binding.lot then (ref, { existing with quantity := existing.quantity - requirement.multiplicity })
        else (ref, existing)
  pure { state with resources }

private def unionSpec (graph : SemanticGraph) : Nat → TypeRef → Option UnionSpec
  | 0, _ => none
  | fuel + 1, ref => do
    let node ← graph.findType ref
    match node.shape with
    | .taggedUnion spec => pure spec
    | .alias target _ => unionSpec graph fuel target
    | _ => none

def inspectGuard (graph : SemanticGraph) (guard : DeclaredGuard) (value : SlotValue) : Except ExecutionFailure GuardArm := do
  match guard.kind with
  | .presence => match value with
    | .absent => pure .absent | .null => pure .null | .present _ => pure .present
  | .validate target => match validateSlot graph target value with
    | .ok _ => pure .accepted
    | .error (.value _) => pure .rejected
    | .error failure => throw (.value failure)
  | .variants =>
    let .present (.obj members) := value | throw (.invalidPlan "union guard shape")
    let some (.str tag) := memberValue ((graph.profile.tag.map (fun (model : TagModel) => model.key)).getD "") members | throw (.invalidPlan "union guard discriminator")
    let .ok projection := projectSlot graph { typeRef := guard.sourceType, required := true, nullable := false } guard.path |
      throw (.invalidPlan "union guard projection")
    let some spec := unionSpec graph (graph.nodes.length + 1) projection.destination.typeRef |
      throw (.invalidPlan "union guard declaration")
    pure (if spec.branches.any (fun branch => branch.wireTag == tag) then .variant tag else .unknownVariant)

private partial def executeTree (prepared : PreparedCompositionInput) (provider : Provider)
    (state : RuntimeState) : PlanTree → IO (Except ExecutionFailure ExecutionResult)
  | .returnValue _ (.success outputs) => pure do
    let values ← outputs.mapM fun (id, binding) => do
      let some port := prepared.input.goal.outputs.find? (fun port => port.id == id) |
        throw (.invalidPlan "goal port mismatch")
      let value ← evaluateBinding prepared.graph state binding
      validate prepared.graph port.contract value
      pure (id, value)
    for resource in prepared.input.goal.finalResources do
      let some (_, lot) := state.resources.find? (fun p => p.1 == resource.lot) |
        throw (.resource resource.lot "missing final lot")
      if lot.quantity < resource.multiplicity || lot.revision != resource.revision then
        throw (.resource resource.lot "final resource mismatch")
    pure (.success values)
  | .returnValue _ (.failure embedding binding) => pure do
    let some failure := prepared.input.goal.failures.find? (fun e => e.id == embedding) |
      throw (.invalidPlan "failure embedding mismatch")
    let value ← evaluateBinding prepared.graph state binding
    validate prepared.graph failure.contract value
    pure (.failure embedding value)
  | .guard _ id inspected arms => do
    let next : Except ExecutionFailure PlanTree := do
      let some guard := prepared.input.invocationDomain.guards.find? (fun guard => guard.id == id) |
        throw (ExecutionFailure.invalidPlan "guard identity mismatch")
      let value ← lookup prepared.graph state inspected
      let arm ← inspectGuard prepared.graph guard value
      let some (_, tree) := arms.find? (fun pair => pair.1 == arm) |
        throw (.invalidPlan "guard branch mismatch")
      pure tree
    match next with
    | .error failure => pure (.error failure)
    | .ok tree => executeTree prepared provider state tree
  | .invoke _ invocation arms _ => do
    let call : Except ExecutionFailure (FunctionSignature × RuntimeState × List (PortId × SlotValue)) := do
      let some signature := prepared.input.signatures.find? (fun s => s.reference == invocation.function) |
        throw (ExecutionFailure.invalidPlan "function identity mismatch")
      let state ← bindResources signature invocation state
      let arguments ← invocation.bindings.mapM fun (id, binding) => do
        let some port := signature.inputs.find? (fun port => port.id == id) |
          throw (.invalidPlan "input port mismatch")
        let value ← evaluateBinding prepared.graph state binding
        validate prepared.graph port.contract value
        pure (id, value)
      pure (signature, state, arguments)
    match call with
    | .error failure => pure (.error failure)
    | .ok (signature, state, arguments) =>
      let result ← provider { id := invocation.site, function := invocation.function } arguments
      let next : Except ExecutionFailure (RuntimeState × PlanTree) := do
        let result ← result
        let some outcome := signature.outcomes.find? (fun o => o.id == result.outcome) |
          throw (.invalidOutcome invocation.site result.outcome)
        if result.outputs.length != outcome.valuePorts.length then throw (.invalidPlan "output port coverage")
        let values ← outcome.valuePorts.mapM fun port => do
          let some (_, value) := result.outputs.find? (fun p => p.1 == port.id) |
            throw (.invalidPlan "missing output port")
          validate prepared.graph port.contract value
          pure (ProducerRef.invocationOutcome invocation.site outcome.id port.id, value)
        let resources := outcome.producedResources.map fun production =>
          (ResourceLotRef.produced invocation.site outcome.id production.id,
            { id := ⟨production.id.value⟩, tokenType := production.tokenType,
              producer := .invocationOutcome invocation.site outcome.id, revision := production.revision,
              quantity := production.quantity, provenance := production.provenance : ResourceLot })
        let some (_, tree) := arms.find? (fun arm => arm.1 == outcome.id) |
          throw (.invalidPlan "outcome branch mismatch")
        pure ({ state with values := state.values ++ values, resources := state.resources ++ resources }, tree)
      match next with
      | .error failure => pure (.error failure)
      | .ok (state, tree) => executeTree prepared provider state tree

def executeCandidate (prepared : PreparedCompositionInput) (checked : VerifiedCompositionCandidate prepared)
    (provider : Provider) (arguments : List (InputId × SlotValue)) : IO (Except ExecutionFailure ExecutionResult) := do
  match initialState prepared arguments with
  | .error failure => pure (.error failure)
  | .ok state => executeTree prepared provider state checked.raw.plan.root

def execute (prepared : PreparedCompositionInput) (checked : CheckedComposition prepared)
    (provider : Provider) (arguments : List (InputId × SlotValue)) : IO (Except ExecutionFailure ExecutionResult) :=
  executeCandidate prepared checked.candidate provider arguments

end Necoherence.SemanticExecution
