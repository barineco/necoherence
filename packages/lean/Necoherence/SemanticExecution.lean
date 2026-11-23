-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SemanticCodec
import Necoherence.NetworkEffect
import NecoQuotient.Application

namespace Necoherence.SemanticExecution

open Necoherence.ExactJson Necoherence.SemanticTypes Necoherence.SemanticValidation
open Necoherence.SemanticComposition

inductive ExecutionFailure where
  | value (failure : ValidationFailure)
  | missingArgument (id : InputId)
  | argumentCoverage (condition : String)
  | missingValue (ref : ValueRef)
  | missingProvider (function : FunctionRef)
  | providerCoverage (condition : String)
  | providerEffect (function : FunctionRef)
  | provider (site : SiteId) (message : String)
  | invalidOutcome (site : SiteId) (outcome : OutcomeId)
  | resource (lot : ResourceLotRef) (condition : String)
  | invalidPlan (condition : String)
  | network (failure : NetworkFailure)
  | networkTerminal (terminal : NetworkTerminal)
  deriving Repr

instance : Inhabited ExecutionFailure := ⟨.invalidPlan ""⟩

structure CallResult where
  outcome : OutcomeId
  outputs : List (PortId × SlotValue)

structure NetworkOwner where
  encode : List (PortId × SlotValue) → Except ExecutionFailure AttemptInput
  decode : RawHttpResponse → Except ExecutionFailure CallResult

inductive PreparedCall where
  | ready (input : AttemptInput)
  | completed (result : CallResult)

structure PreparedNetworkOwner where
  prepare : List (PortId × SlotValue) → Except ExecutionFailure PreparedCall
  decode : RawHttpResponse → Except ExecutionFailure CallResult

inductive ProviderImplementation where
  | pure (callback : List (PortId × SlotValue) → Except ExecutionFailure CallResult)
  | preparedHttp (owner : PreparedNetworkOwner)

structure Provider where
  reference : FunctionRef
  implementation : ProviderImplementation

inductive ExecutionResult where
  | success (outputs : List (GoalPortId × SlotValue))
  | failure (embedding : FailureEmbeddingId) (value : SlotValue)
  deriving Repr

structure RuntimeState where
  values : List (ProducerRef × SlotValue)
  resources : List (ResourceLotRef × ResourceLot)

structure RunFailure where
  cause : ExecutionFailure
  network : NetworkState
  deriving Repr

instance : Inhabited RunFailure := ⟨{ cause := default, network := { attempts := [] } }⟩

inductive NetworkInstruction where
  | send (command : SendCommand)
  | observe (started : StartedAttempt)
  deriving Repr

inductive ExecutionObservation where
  | start (observation : StartObservation)
  | host (observation : HostObservation)
  deriving Repr

inductive PendingNetwork where
  | start (invocation : InvocationPlan) (arms : List (OutcomeId × PlanTree))
      (owner : NetworkOwner) (prepared : PreparedAttempt)
  | response (invocation : InvocationPlan) (arms : List (OutcomeId × PlanTree))
      (owner : NetworkOwner) (started : StartedAttempt)

structure Execution where
  private mk ::
  prepared : PreparedCompositionInput
  providers : List Provider
  state : RuntimeState
  tree : PlanTree
  network : NetworkState
  pending : Option PendingNetwork

inductive Progress where
  | completed (result : ExecutionResult) (network : NetworkState)
  | pending (execution : Execution) (instruction : NetworkInstruction)

private def failAt (network : NetworkState) (cause : ExecutionFailure) : Except RunFailure α :=
  .error { cause, network }

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
  for argument in arguments do
    if (arguments.filter (fun candidate => candidate.1 == argument.1)).length != 1 ||
        !prepared.input.initialInputs.any (fun initial => initial.id == argument.1 && initial.source == .argument) then
      throw (.argumentCoverage "unique declared argument identifiers required")
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

def unionSpec (graph : SemanticGraph) : Nat → TypeRef → Option UnionSpec
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
  | .variants => match value with
    | .absent => pure .absent
    | .null => pure .null
    | .present (.obj members) => do
      let some (.str _) := memberValue ((graph.profile.tag.map (fun (model : TagModel) => model.key)).getD "") members |
        throw (.invalidPlan "union guard discriminator")
      let .ok projection := projectSlot graph { typeRef := guard.sourceType, required := true, nullable := false } guard.path |
        throw (.invalidPlan "union guard projection")
      let some spec := unionSpec graph (graph.nodes.length + 1) projection.destination.typeRef |
        throw (.invalidPlan "union guard declaration")
      let some branch := selectUnionBranch graph.profile spec (.obj members) |
        throw (.invalidPlan "union branch selection")
      pure (.variant branch.wireTag)
    | _ => throw (.invalidPlan "union guard shape")

def armApply {K : Type} [DecidableEq K] (arms : List (K × PlanTree)) (key : K) :
    Except K (NecoQuotient.Applied K PlanTree) := do
  let table ← NecoQuotient.keyedBlocksOf arms
  pure (table.apply key)

def selectArm {K : Type} [DecidableEq K] (arms : List (K × PlanTree)) (key : K)
    (duplicate : String) (mismatch : String) : Except ExecutionFailure PlanTree :=
  match armApply arms key with
  | .error _ => throw (.invalidPlan duplicate)
  | .ok (.value tree) => pure tree
  | .ok (.residual _) => throw (.invalidPlan mismatch)

private def providerEffectMatches (effect : CompositionEffect) : ProviderImplementation → Bool
  | .pure _ => effect == .pureFunction || effect == .dataOnly
  | .preparedHttp _ => effect == .httpRequestResponse

private def validateProviders (prepared : PreparedCompositionInput) (providers : List Provider) : Except ExecutionFailure Unit := do
  if providers.length != prepared.input.signatures.length then
    throw (.providerCoverage "exact provider coverage required")
  for provider in providers do
    if (providers.filter (fun candidate => candidate.reference == provider.reference)).length != 1 then
      throw (.providerCoverage "unique provider references required")
  for signature in prepared.input.signatures do
    let some provider := providers.find? (fun provider => provider.reference == signature.reference) |
      throw (.missingProvider signature.reference)
    if !providerEffectMatches signature.effect provider.implementation then
      throw (.providerEffect signature.reference)

private def invocationCall (execution : Execution) (invocation : InvocationPlan) :
    Except ExecutionFailure (FunctionSignature × RuntimeState × List (PortId × SlotValue)) := do
  let some signature := execution.prepared.input.signatures.find? (fun s => s.reference == invocation.function) |
    throw (.invalidPlan "function identity mismatch")
  let state ← bindResources signature invocation execution.state
  let arguments ← invocation.bindings.mapM fun (id, binding) => do
    let some port := signature.inputs.find? (fun port => port.id == id) |
      throw (.invalidPlan "input port mismatch")
    let value ← evaluateBinding execution.prepared.graph state binding
    validate execution.prepared.graph port.contract value
    pure (id, value)
  pure (signature, state, arguments)

private def acceptOutcome (execution : Execution) (signature : FunctionSignature)
    (invocation : InvocationPlan) (arms : List (OutcomeId × PlanTree))
    (result : CallResult) : Except ExecutionFailure Execution := do
  let some outcome := signature.outcomes.find? (fun o => o.id == result.outcome) |
    throw (.invalidOutcome invocation.site result.outcome)
  if result.outputs.length != outcome.valuePorts.length then throw (.invalidPlan "output port coverage")
  let values ← outcome.valuePorts.mapM fun port => do
    let some (_, value) := result.outputs.find? (fun p => p.1 == port.id) |
      throw (.invalidPlan "missing output port")
    validate execution.prepared.graph port.contract value
    pure (ProducerRef.invocationOutcome invocation.site outcome.id port.id, value)
  let resources := outcome.producedResources.map fun production =>
    (ResourceLotRef.produced invocation.site outcome.id production.id,
      { id := ⟨production.id.value⟩, tokenType := production.tokenType,
        producer := .invocationOutcome invocation.site outcome.id, revision := production.revision,
        quantity := production.quantity, provenance := production.provenance : ResourceLot })
  let tree ← selectArm arms outcome.id "duplicate outcome branch" "outcome branch mismatch"
  pure { execution with
    state := { execution.state with
      values := execution.state.values ++ values
      resources := execution.state.resources ++ resources }
    tree, pending := none }

private def startHttp (execution : Execution) (invocation : InvocationPlan)
    (arms : List (OutcomeId × PlanTree))
    (arguments : List (PortId × SlotValue)) (owner : NetworkOwner) : Except RunFailure Progress := do
  let input ← (owner.encode arguments).mapError fun cause => { cause, network := execution.network }
  let (network, prepared) ← match Necoherence.prepare execution.network input with
    | .Prepared network prepared => pure (network, prepared)
    | .Rejected network failure => failAt network (.network failure)
  let (network, command) ← match sendCommand network prepared with
    | .CommandReady network command => pure (network, command)
    | .Rejected network failure => failAt network (.network failure)
  let pending := PendingNetwork.start invocation arms owner prepared
  pure (.pending { execution with network, pending := some pending } (.send command))

partial def advance (execution : Execution) : Except RunFailure Progress :=
  match execution.tree with
  | .returnValue _ (.success outputs) => do
    let result : Except ExecutionFailure ExecutionResult := do
      let values ← outputs.mapM fun (id, binding) => do
        let some port := execution.prepared.input.goal.outputs.find? (fun port => port.id == id) |
          throw (.invalidPlan "goal port mismatch")
        let value ← evaluateBinding execution.prepared.graph execution.state binding
        validate execution.prepared.graph port.contract value
        pure (id, value)
      for resource in execution.prepared.input.goal.finalResources do
        let some (_, lot) := execution.state.resources.find? (fun p => p.1 == resource.lot) |
          throw (.resource resource.lot "missing final lot")
        if lot.quantity < resource.multiplicity || lot.revision != resource.revision then
          throw (.resource resource.lot "final resource mismatch")
      pure (.success values)
    match result with
    | .ok value => pure (.completed value execution.network)
    | .error cause => failAt execution.network cause
  | .returnValue _ (.failure embedding binding) => do
    let result : Except ExecutionFailure ExecutionResult := do
      let some failure := execution.prepared.input.goal.failures.find? (fun e => e.id == embedding) |
        throw (.invalidPlan "failure embedding mismatch")
      let value ← evaluateBinding execution.prepared.graph execution.state binding
      validate execution.prepared.graph failure.contract value
      pure (.failure embedding value)
    match result with
    | .ok value => pure (.completed value execution.network)
    | .error cause => failAt execution.network cause
  | .guard _ id inspected arms =>
    let next : Except ExecutionFailure PlanTree := do
      let some guard := execution.prepared.input.invocationDomain.guards.find? (fun guard => guard.id == id) |
        throw (.invalidPlan "guard identity mismatch")
      let value ← lookup execution.prepared.graph execution.state inspected
      let arm ← inspectGuard execution.prepared.graph guard value
      selectArm arms arm "duplicate guard branch" "guard branch mismatch"
    match next with
    | .error cause => failAt execution.network cause
    | .ok tree => advance { execution with tree }
  | .invoke _ invocation arms _ =>
    match invocationCall execution invocation with
    | .error cause => failAt execution.network cause
    | .ok (signature, state, arguments) =>
      let execution := { execution with state }
      match execution.providers.find? (fun provider => provider.reference == invocation.function) with
      | none => failAt execution.network (.missingProvider invocation.function)
      | some provider =>
        match provider.implementation with
        | .pure callback =>
          match callback arguments with
          | .error cause => failAt execution.network cause
          | .ok result =>
            match acceptOutcome execution signature invocation arms result with
            | .error cause => failAt execution.network cause
            | .ok execution => advance execution
        | .preparedHttp owner =>
          match owner.prepare arguments with
          | .error cause => failAt execution.network cause
          | .ok (.ready input) =>
            startHttp execution invocation arms arguments
              { encode := fun _ => .ok input, decode := owner.decode }
          | .ok (.completed result) =>
            match acceptOutcome execution signature invocation arms result with
            | .error cause => failAt execution.network cause
            | .ok execution => advance execution

def start (prepared : PreparedCompositionInput) (checked : CheckedComposition prepared)
    (providers : List Provider) (arguments : List (InputId × SlotValue))
    (network : NetworkState) : Except RunFailure Progress := do
  let network ← match readNetworkState network with
    | .Read network => pure network
    | .Rejected network failure => failAt network (.network failure)
  let _ ← (validateProviders prepared providers).mapError fun cause => { cause, network }
  let state ← (initialState prepared arguments).mapError fun cause => { cause, network }
  advance { prepared, providers, state, tree := checked.candidate.raw.plan.root, network, pending := none }

def resume (execution : Execution) (observation : ExecutionObservation) : Except RunFailure Progress := do
  match execution.pending, observation with
  | some (.start invocation arms owner prepared), .start observation =>
    match observeStart execution.network prepared observation with
    | .Started network started =>
      let pending := PendingNetwork.response invocation arms owner started
      pure (.pending { execution with network, pending := some pending } (.observe started))
    | .Terminal network settled => failAt network (.networkTerminal settled.terminal)
    | .Rejected network failure => failAt network (.network failure)
    | _ => failAt execution.network (.invalidPlan "network start result")
  | some (.response invocation arms owner started), .host observation =>
    match Necoherence.observe execution.network observation with
    | .Pending network nextStarted =>
      let pending := PendingNetwork.response invocation arms owner nextStarted
      pure (.pending { execution with network, pending := some pending } (.observe nextStarted))
    | .Terminal network settled =>
      match settled.terminal.outcome with
      | .Response response _ =>
        match owner.decode response with
        | .error cause => failAt network cause
        | .ok result =>
          let execution := { execution with network, pending := none }
          let some signature := execution.prepared.input.signatures.find? (fun s => s.reference == invocation.function) |
            failAt network (.invalidPlan "function identity mismatch")
          match acceptOutcome execution signature invocation arms result with
          | .error cause => failAt network cause
          | .ok execution => advance execution
      | _ => failAt network (.networkTerminal settled.terminal)
    | .Duplicate network _ _ | .Late network _ _ =>
      pure (.pending { execution with network } (.observe started))
    | .Rejected network failure => failAt network (.network failure)
    | .Started network _ => failAt network (.invalidPlan "completion delivered a start result")
  | none, _ => failAt execution.network (.invalidPlan "only pending executions may resume")
  | _, _ => failAt execution.network (.invalidPlan "network observation kind mismatch")

end Necoherence.SemanticExecution
