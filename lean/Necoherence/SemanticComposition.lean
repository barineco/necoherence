-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SemanticValidation
import Necoherence.TypedMapping

namespace Necoherence.SemanticComposition

open Necoherence.ExactJson
open Necoherence.SemanticTypes
open Necoherence.SemanticValidation

structure SemanticBasis where
  profile : VersionedSemanticProfile
  sources : List SourceRef
  deriving BEq, Repr

def SemanticBasis.of (graph : SemanticGraph) : SemanticBasis :=
  { profile := graph.profile, sources := graph.sourceRefs }

structure FunctionRef where
  identity : String
  revision : String
  contentDigest : String
  deriving Repr, DecidableEq

structure InputId where
  value : String
  deriving Repr, DecidableEq
structure PortId where
  value : String
  deriving Repr, DecidableEq
structure SiteId where
  value : String
  deriving Repr, DecidableEq
structure OutcomeId where
  value : String
  deriving Repr, DecidableEq
structure GoalPortId where
  value : String
  deriving Repr, DecidableEq
structure LotId where
  value : String
  deriving Repr, DecidableEq
structure RequirementId where
  value : String
  deriving Repr, DecidableEq
structure ProductionId where
  value : String
  deriving Repr, DecidableEq
structure GuardId where
  value : String
  deriving Repr, DecidableEq
structure FailureEmbeddingId where
  value : String
  deriving Repr, DecidableEq

structure TypePair where
  source : SlotContract
  destination : SlotContract
  sourceTag : Option String := none
  deriving Repr, DecidableEq

inductive InclusionRule where
  | sameDefinedType | emptySource | boolean | integerIntersection | finiteStrings
  | stringConditions | bytesLength | unit
  | unfoldSource | unfoldDestination | array | product | sourceUnion | destinationUnion
  deriving Repr, DecidableEq

structure PairEntry where
  pair : TypePair
  sourceShape : TypeShape
  destinationShape : TypeShape
  rule : InclusionRule
  children : List Nat
  deriving Repr, DecidableEq

structure InclusionCertificate where
  basis : SemanticBasis
  source : SlotContract
  destination : SlotContract
  emptyTypes : List TypeRef
  pairs : List PairEntry
  root : Nat
  deriving BEq, Repr

inductive TypeObligationReason where
  | meaning (obligations : List SemanticObligation)
  | constraintImplication | presence | unionRemainder | extraField (name : String)
  | inhabitation | obligationBoundExhausted
  deriving BEq, Repr

structure TypeObligation where
  pair : TypePair
  path : ValuePath
  reason : TypeObligationReason
  deriving BEq, Repr

structure CounterexampleCertificate where
  basis : SemanticBasis
  source : SlotContract
  destination : SlotContract
  value : SlotValue
  destinationFailure : ValueFailure
  deriving BEq, Repr

inductive InclusionFailure where
  | basisMismatch | contractMismatch | undefinedMeaning (obligations : List SemanticObligation)
  | missingPair | pairMismatch (index : Nat) | ruleMismatch (index : Nat)
  | childCoverage (index : Nat) | forgedEmptiness | counterexampleMismatch
  | unresolved (obligation : TypeObligation)
  deriving BEq, Repr

inductive ProducerRef where
  | initial (id : InputId)
  | invocationOutcome (site : SiteId) (outcome : OutcomeId) (port : PortId)
  deriving Repr, DecidableEq

structure ValueRef where
  producer : ProducerRef
  path : ValuePath
  deriving Repr, DecidableEq

inductive SourceConstraint where
  | anyCompatible | initialOnly (id : InputId) (path : ValuePath)
  | producedBy (site : SiteId) (outcome : OutcomeId) (port : PortId) (path : ValuePath)
  deriving Repr, DecidableEq

def SourceConstraint.accepts : SourceConstraint → ValueRef → Bool
  | .anyCompatible, _ => true
  | .initialOnly expected path, ⟨.initial actual, actualPath⟩ =>
      expected == actual && path == actualPath
  | .producedBy s o p path, ⟨.invocationOutcome s' o' p', actualPath⟩ =>
      s == s' && o == o' && p == p' && path == actualPath
  | _, _ => false

inductive ResourceLotRef where
  | initial (id : LotId)
  | produced (site : SiteId) (outcome : OutcomeId) (production : ProductionId)
  deriving Repr, DecidableEq

inductive ResourceProducer where
  | initial (identity revision : String)
  | invocationOutcome (site : SiteId) (outcome : OutcomeId)
  deriving Repr, DecidableEq

inductive ResourceIdentityConstraint where
  | any | exactly (producer : ResourceProducer)
  deriving Repr, DecidableEq

structure ResourceLot where
  id : LotId
  tokenType : TypeRef
  producer : ResourceProducer
  revision : Nat
  quantity : Nat
  provenance : String
  deriving Repr, DecidableEq

structure ResourceRequirement where
  id : RequirementId
  tokenType : TypeRef
  mode : BindingMode
  multiplicity : Nat
  requiredRevision : Nat
  identity : ResourceIdentityConstraint
  deriving Repr, DecidableEq

structure ResourceProduction where
  id : ProductionId
  tokenType : TypeRef
  revision : Nat
  quantity : Nat
  provenance : String
  deriving Repr, DecidableEq

inductive InitialSource where
  | argument | suppliedValue (value : SlotValue)
  deriving BEq, Repr

structure InitialInput where
  id : InputId
  contract : SlotContract
  source : InitialSource
  resource : Option LotId
  deriving BEq, Repr

structure InputPort where
  id : PortId
  contract : SlotContract
  sourceConstraint : SourceConstraint
  resourceRequirement : Option RequirementId
  deriving Repr, DecidableEq

structure OutputPort where
  id : PortId
  contract : SlotContract
  resourceProduction : Option ProductionId
  deriving Repr, DecidableEq

inductive OutcomeForm where
  | success | declaredFailure
  deriving Repr, DecidableEq

structure OutcomeContract where
  id : OutcomeId
  form : OutcomeForm
  valuePorts : List OutputPort
  producedResources : List ResourceProduction
  deriving Repr, DecidableEq

inductive FunctionForm where
  | pure | operation (definition : DefinitionRef) | declaredTransform
  deriving Repr, DecidableEq

inductive CompositionEffect where
  | pureFunction | httpRequestResponse | dataOnly
  deriving Repr, DecidableEq

inductive GuardArm where
  | present | absent | null | variant (tag : String) | unknownVariant | accepted | rejected
  deriving Repr, DecidableEq

inductive FailureOrigin where
  | function (function : FunctionRef) (outcome : OutcomeId)
  | guard (guard : GuardId) (arm : GuardArm)
  deriving Repr, DecidableEq

structure FunctionSignature where
  reference : FunctionRef
  form : FunctionForm
  effect : CompositionEffect
  inputs : List InputPort
  outcomes : List OutcomeContract
  resourceInputs : List ResourceRequirement
  assumptionRef : String
  handlesFailure : Option FailureOrigin := none
  deriving Repr, DecidableEq

structure InvocationSite where
  id : SiteId
  function : FunctionRef
  deriving Repr, DecidableEq

structure PermittedProjection where
  sourceType : TypeRef
  path : ValuePath
  deriving Repr, DecidableEq

inductive GuardKind where
  | presence | variants | validate (contract : SlotContract)
  deriving Repr, DecidableEq

structure DeclaredGuard where
  id : GuardId
  sourceType : TypeRef
  path : ValuePath
  kind : GuardKind
  deriving Repr, DecidableEq

inductive FieldPresence where
  | required | optional
  deriving Repr, DecidableEq

structure FieldConstraint where
  field : String
  source : SourceConstraint
  presence : FieldPresence
  deriving Repr, DecidableEq

structure ConstructionRule where
  identity : String
  typeRef : TypeRef
  nestedFields : List (String × String)
  fieldConstraints : List FieldConstraint := []
  deriving Repr, DecidableEq

def ConstructionRule.fieldConstraint (rule : ConstructionRule) (name : String) : SourceConstraint :=
  ((rule.fieldConstraints.find? (fun item => item.field == name)).map (·.source)).getD .anyCompatible

def ConstructionRule.fieldRequired (rule : ConstructionRule) (name : String) : Bool :=
  rule.fieldConstraints.any (fun item => item.field == name && item.presence == .required)

structure InvocationDomain where
  identity : String
  revision : String
  sites : List InvocationSite
  permittedProjections : List PermittedProjection
  permittedConstructions : List ConstructionRule
  permittedTransforms : List FunctionRef
  guards : List DeclaredGuard
  deriving Repr, DecidableEq

structure ResourceGoal where
  lot : ResourceLotRef
  multiplicity : Nat
  revision : Nat
  deriving Repr, DecidableEq

structure GoalPort where
  id : GoalPortId
  contract : SlotContract
  sourceConstraint : SourceConstraint
  deriving Repr, DecidableEq

structure FailureEmbedding where
  id : FailureEmbeddingId
  origin : FailureOrigin
  contract : SlotContract
  finalResources : List ResourceGoal
  deriving Repr, DecidableEq

structure GoalSpec where
  outputs : List GoalPort
  failures : List FailureEmbedding
  finalResources : List ResourceGoal
  deriving Repr, DecidableEq

inductive SelectionPolicy where
  | requireUnique | anyFeasible
  deriving Repr, DecidableEq

structure ResourceBounds where
  maxBindings : Nat
  maxSearchSteps : Nat
  maxTokens : Nat
  deriving Repr, DecidableEq

structure SearchBounds where
  maxExpandedStates : Nat := 10000
  maxBindingCandidates : Nat := 100000
  maxTypeObligations : Nat := 10000
  maxBranchNodes : Nat := 100000
  maxSampleLength : Nat := 32
  resourceBounds : Option ResourceBounds := none
  deriving Repr, DecidableEq

inductive SampleObligation where
  | sampleBound
  deriving Repr, DecidableEq

structure SampleResult (α : Type) where
  values : List α
  obligations : List SampleObligation := []
  deriving Repr, DecidableEq

structure CompositionInput where
  identity : String
  revision : String
  basis : SemanticBasis
  signatures : List FunctionSignature
  initialInputs : List InitialInput
  initialResources : List ResourceLot
  goal : GoalSpec
  invocationDomain : InvocationDomain
  allowedEffects : List CompositionEffect
  explicitOrder : List (SiteId × SiteId)
  selectionPolicy : Option SelectionPolicy := none
  bounds : SearchBounds
  deriving Repr

inductive CompositionInputFailure where
  | basisMismatch
  | duplicateIdentity (kind identity : String)
  | unresolvedType (ref : TypeRef) | unresolvedFunction (ref : FunctionRef)
  | invalidSignature (ref : FunctionRef) (reason : String)
  | invalidInitialValue (id : InputId) (failure : ValueFailure)
  | invalidInvocationDomain (reason : String) | invalidResourceDeclaration (reason : String)
  deriving Repr


inductive BindingCompatibility where
  | inclusion (certificate : InclusionCertificate)
  | suppliedValue (value : SlotValue)
  deriving BEq, Repr

inductive BindingExpr where
  | source (value : ValueRef) (projection : ProjectionCertificate) (compatibility : BindingCompatibility)
  | product (construction : String) (typeRef : TypeRef) (fields : List (String × BindingExpr))
  deriving BEq, Repr

structure ResourceBinding where
  requirement : RequirementId
  lot : ResourceLotRef
  inclusion : InclusionCertificate
  deriving BEq, Repr

structure InvocationPlan where
  site : SiteId
  function : FunctionRef
  bindings : List (PortId × BindingExpr)
  resources : List ResourceBinding
  deriving BEq, Repr

inductive ReturnPlan where
  | success (outputs : List (GoalPortId × BindingExpr))
  | failure (embedding : FailureEmbeddingId) (value : BindingExpr)
  deriving BEq, Repr

inductive PlanTree where
  | invoke (rank : Nat) (invocation : InvocationPlan) (arms : List (OutcomeId × PlanTree))
      (emptyOutcomes : List OutcomeId)
  | guard (rank : Nat) (guard : GuardId) (inspected : ValueRef) (arms : List (GuardArm × PlanTree))
  | returnValue (rank : Nat) (terminal : ReturnPlan)
  deriving BEq, Repr

def PlanTree.rank : PlanTree → Nat
  | .invoke rank _ _ _ | .guard rank _ _ _ | .returnValue rank _ => rank

mutual
  def treeNodeCount : PlanTree → Nat
    | .returnValue _ _ => 1
    | .invoke _ _ arms _ => 1 + outcomeNodeCount arms
    | .guard _ _ _ arms => 1 + guardNodeCount arms
  def outcomeNodeCount : List (OutcomeId × PlanTree) → Nat
    | [] => 0
    | (_, child) :: rest => treeNodeCount child + outcomeNodeCount rest
  def guardNodeCount : List (GuardArm × PlanTree) → Nat
    | [] => 0
    | (_, child) :: rest => treeNodeCount child + guardNodeCount rest
end

structure CompositionPlan where
  inputIdentity : String
  inputRevision : String
  root : PlanTree
  deriving BEq, Repr

inductive TraceStep where
  | invocation (invocation : InvocationPlan) (outcome : OutcomeId)
  | guard (guard : GuardId) (inspected : ValueRef) (arm : GuardArm)
  deriving BEq, Repr

structure BranchTrace where
  steps : List TraceStep
  terminal : ReturnPlan
  deriving BEq, Repr

structure ResourceLotCorrespondence where
  lot : ResourceLotRef
  place : String
  producer : ResourceProducer
  tokenTarget : String
  tokenType : String
  revision : Nat
  quantity : Nat
  provenance : String
  deriving Repr, DecidableEq

structure ValueCorrespondence where
  producer : ProducerRef
  place : String
  tokenTarget : String
  revision : Nat
  deriving Repr, DecidableEq

structure NormalizedResourceBinding where
  transition : String
  lot : ResourceLotRef
  read : Nat
  consume : Nat
  requiredRevision : Nat
  deriving Repr, DecidableEq

structure ResourceCorrespondence where
  lots : List ResourceLotCorrespondence
  values : List ValueCorrespondence
  normalizedBindings : List NormalizedResourceBinding
  executionOrder : List String
  deriving Repr, DecidableEq

structure ResourceTraceCertificate where
  trace : BranchTrace
  lowering : SolverInput
  correspondence : ResourceCorrespondence
  reachability : ReachabilityWitness
  acyclicity : AcyclicWitness
  valueSources : List (ProducerRef × SlotValue)
  deriving Repr

structure CompositionWitness where
  inputSnapshot : CompositionInput
  initialMembership : List (InputId × SlotValue)
  resourceTraces : List ResourceTraceCertificate
  deriving Repr

inductive WitnessFailure where
  | inputRevisionMismatch | initialMembership (id : InputId)
  | producerMismatch (ref : ValueRef) | projectionMismatch (failure : ProjectionFailure)
  | sourceConstraintMismatch (ref : ValueRef) | inclusion (failure : InclusionFailure)
  | suppliedValueMismatch (ref : ValueRef) | constructionMismatch (ref : TypeRef)
  | missingBinding (identity : String) | signatureMismatch (site : SiteId)
  | guardNotDominating (ref : ValueRef) | incompleteBranchCoverage (identity : String)
  | failureEmbeddingMismatch (id : FailureEmbeddingId) | goalMismatch | rankViolation
  | resourceLoweringMismatch (reason : String) | resourceReplayMismatch (reason : String)
  | forgedClosure (reason : String) | forgedAcyclicity (reason : String) | missingEvidence (reason : String)
  deriving Repr

inductive UnresolvedObligation where
  | type (value : Option ValueRef) (obligations : List TypeObligation)
  | meaning (obligations : List SemanticObligation)
  | inhabitation (producer : ProducerRef) (contract : SlotContract)
  | stateBoundExhausted | bindingBoundExhausted | branchBoundExhausted
  | resourceSolverUnknown (reason : Necoherence.UnknownReason)
  | resourceCapacityBound (required limit : Nat)
  | unresolvedUniqueness
  deriving Repr

inductive LoweringFailure where
  | invalid (reason : String) | unknown (obligation : UnresolvedObligation)
  deriving Repr

inductive CompositionEngineFailure where
  | contractViolation (reason : String) | resource (failure : SolverFailure)
  | witness (failure : WitnessFailure)
  deriving Repr

structure AvailableValue where
  producer : ProducerRef
  contract : SlotContract
  resource : Option ResourceLotRef
  deriving Repr, DecidableEq

structure BranchFact where
  guard : GuardId
  inspected : ValueRef
  arm : GuardArm
  refinement : Option SlotContract := none
  assumptions : List ProjectionAssumption := []
  exact : Option SlotValue := none
  deriving BEq, Repr

structure SearchState where
  available : List AvailableValue
  usedSites : List SiteId
  usedGuards : List GuardId
  facts : List BranchFact
  trace : List TraceStep
  pendingFailure : Option FailureOrigin
  deriving BEq, Repr

deriving instance BEq for BindingMode
deriving instance BEq for ResourceRequirement
deriving instance BEq for FunctionSignature
deriving instance BEq for CompositionInput

private def listIndex [DecidableEq α] (value : α) : List α → Nat
  | [] => 0
  | head :: rest => if value = head then 0 else 1 + listIndex value rest

private def distinctFuel [DecidableEq α] : Nat → List α → List α
  | 0, _ => []
  | _ + 1, [] => []
  | fuel + 1, head :: rest =>
    head :: distinctFuel fuel (rest.filter (fun value => decide (value ≠ head)))

private def distinct [DecidableEq α] (items : List α) : List α := distinctFuel items.length items

private theorem distinctFuel_mem [DecidableEq α] (fuel : Nat) (items : List α)
    (bounded : items.length ≤ fuel) (value : α) (present : value ∈ items) :
    value ∈ distinctFuel fuel items := by
  induction fuel generalizing items with
  | zero =>
    cases items with
    | nil => simp at present
    | cons head rest => simp at bounded
  | succ fuel ih =>
    cases items with
    | nil => simp at present
    | cons head rest =>
      by_cases same : value = head
      · subst same
        simp [distinctFuel]
      · have later : value ∈ rest := (List.mem_cons.mp present).resolve_left same
        have filtered : value ∈ rest.filter (fun item => decide (item ≠ head)) :=
          List.mem_filter.mpr ⟨later, by simp [same]⟩
        have smaller : (rest.filter (fun item => decide (item ≠ head))).length ≤ fuel := by
          have := List.length_filter_le (fun item => decide (item ≠ head)) rest
          simp only [List.length_cons] at bounded
          omega
        simp only [distinctFuel, List.mem_cons]
        exact Or.inr (ih _ smaller filtered)

private theorem distinct_mem [DecidableEq α] (items : List α) (value : α) (present : value ∈ items) :
    value ∈ distinct items :=
  distinctFuel_mem items.length items (Nat.le_refl _) value present

private theorem emptyList_of_isEmpty (items : List α) (empty : items.isEmpty = true) : items = [] := by
  cases items <;> simp_all


private def certifyAll {α : Type} (items : List α) (predicate : α → Prop)
    [DecidablePred predicate] (failure : WitnessFailure) :
    Except WitnessFailure { proof : Unit // ∀ item ∈ items, predicate item } :=
  match items with
  | [] => .ok ⟨(), by simp⟩
  | head :: rest =>
    if h : predicate head then
      match certifyAll rest predicate failure with
      | .error error => .error error
      | .ok checked => .ok ⟨(), by
          intro item present
          rcases List.mem_cons.mp present with same | later
          · subst item; exact h
          · exact checked.property item later⟩
    else .error failure

structure CheckedReachability (input : SolverInput) (witness : ReachabilityWitness) : Type where
  valid : Necoherence.validate input = none
  withinBindings : bindingBoundExceeded input = false
  withinSteps : witness.path.length ≤ input.bound.maxSearchSteps
  replay : pathReplay input input.marking witness.path = some witness.finalMarking
  goal : evalGoal witness.finalMarking input.goal = true

def verifyReachabilityWitness (input : SolverInput) (witness : ReachabilityWitness) :
    Except WitnessFailure (CheckedReachability input witness) :=
  if hvalid : Necoherence.validate input = none then
    if hbindings : bindingBoundExceeded input = false then
      if hsteps : witness.path.length ≤ input.bound.maxSearchSteps then
        if hreplay : pathReplay input input.marking witness.path = some witness.finalMarking then
          if hgoal : evalGoal witness.finalMarking input.goal = true then
            .ok { valid := hvalid, withinBindings := hbindings, withinSteps := hsteps
                  replay := hreplay, goal := hgoal }
          else .error (.resourceReplayMismatch "terminal resource goal")
        else .error (.resourceReplayMismatch "enabled path or final marking")
      else .error (.resourceReplayMismatch "path step bound")
    else .error (.resourceReplayMismatch "binding bound")
  else .error (.resourceReplayMismatch "invalid resource declaration")

theorem resourceWitnessSound (input : SolverInput) (witness : ReachabilityWitness)
    (checked : CheckedReachability input witness) :
    PathExec input input.marking witness.path witness.finalMarking ∧
    pathEnabled input input.marking witness.path = true ∧
    evalGoal witness.finalMarking input.goal = true :=
  ⟨pathReplay_implies_pathExec input checked.valid checked.replay,
   pathReplayEnabled input input.marking witness.path checked.replay, checked.goal⟩

private def successorCovered (input : SolverInput) (markings : List Marking)
    (marking : Marking) (transition : TypedTransition) : Prop :=
  match stepAt input marking transition.identity with
  | none => True
  | some next => next ∈ markings

private def successorRanked (input : SolverInput) (order : List Marking)
    (marking : Marking) (transition : TypedTransition) : Prop :=
  match stepAt input marking transition.identity with
  | none => True
  | some next => listIndex marking order < listIndex next order

private instance (input : SolverInput) (markings : List Marking)
    (marking : Marking) (transition : TypedTransition) :
    Decidable (successorCovered input markings marking transition) := by
  unfold successorCovered
  split <;> infer_instance

private instance (input : SolverInput) (order : List Marking)
    (marking : Marking) (transition : TypedTransition) :
    Decidable (successorRanked input order marking transition) := by
  unfold successorRanked
  split <;> infer_instance

private def successorsCoveredAt (input : SolverInput) (markings : List Marking) (marking : Marking) : Bool :=
  input.transitions.all fun transition => decide (successorCovered input markings marking transition)

private def rankedAt (input : SolverInput) (order : List Marking) (marking : Marking) : Bool :=
  input.transitions.all fun transition => decide (successorRanked input order marking transition)

structure CheckedResourceClosure (input : SolverInput) (markings : List Marking) : Type where
  valid : Necoherence.validate input = none
  withinBindings : bindingBoundExceeded input = false
  initial : input.marking ∈ markings
  unique : markings.Nodup
  covered : ∀ marking ∈ markings, ∀ transition ∈ input.transitions,
    successorCovered input markings marking transition

private def verifyFiniteResourceClosure (input : SolverInput) (markings : List Marking)
    (steps : Nat) (frontier : List Marking) :
    Except WitnessFailure (CheckedResourceClosure input markings) :=
  if hvalid : Necoherence.validate input = none then
    if hbindings : bindingBoundExceeded input = false then
      if frontier ≠ [] || steps != markings.length || input.bound.maxSearchSteps < steps then
        .error (.forgedClosure "frontier, steps, or resource bound")
      else if hroot : input.marking ∈ markings then
        if unique : markings.Nodup then
          if hcoverage : markings.all (successorsCoveredAt input markings) = true then
            have covered : ∀ marking ∈ markings, ∀ transition ∈ input.transitions,
                successorCovered input markings marking transition := by
              intro marking present transition declared
              have here := (List.all_eq_true.mp hcoverage) marking present
              have edge := (List.all_eq_true.mp here) transition declared
              exact of_decide_eq_true edge
            .ok { valid := hvalid, withinBindings := hbindings, initial := hroot, unique := unique,
                  covered := covered }
          else .error (.forgedClosure "enabled successor omitted")
        else .error (.forgedClosure "duplicated explored marking")
      else .error (.forgedClosure "initial marking omitted")
    else .error (.forgedClosure "resource binding bound")
  else .error (.forgedClosure "invalid resource declaration")

structure CheckedClosure (input : SolverInput) (witness : ClosureWitness) : Type where
  closure : CheckedResourceClosure input witness.exploredMarkings
  noGoal : ∀ marking ∈ witness.exploredMarkings, evalGoal marking input.goal = false

def verifyClosureWitness (input : SolverInput) (witness : ClosureWitness) :
    Except WitnessFailure (CheckedClosure input witness) := do
  let closure ← verifyFiniteResourceClosure input witness.exploredMarkings witness.steps witness.frontier
  if h : witness.exploredMarkings.all (fun marking => !(evalGoal marking input.goal)) = true then
    have noGoal : ∀ marking ∈ witness.exploredMarkings, evalGoal marking input.goal = false := by
      intro marking present
      have goal := (List.all_eq_true.mp h) marking present
      simpa using goal
    pure { closure := closure, noGoal := noGoal }
  else throw (.forgedClosure "closed marking satisfies the goal")

private theorem resourceClosure_path (input : SolverInput) (markings : List Marking)
    (checked : CheckedResourceClosure input markings) {start finish : Marking} {path : List String}
    (present : start ∈ markings) (execution : PathExec input start path finish) :
    finish ∈ markings := by
  revert present
  induction execution with
  | nil _ => exact fun present => present
  | @cons start middle finish identity rest head tail ih =>
    intro present
    obtain ⟨transition, declared, same, enabled, applied⟩ := head
    have replay := step_implies_stepAt input start identity middle checked.valid
      ⟨transition, declared, same, enabled, applied⟩
    have covered := checked.covered start present transition declared
    simp only [successorCovered, same, replay] at covered
    exact ih covered

theorem resourceClosureSound (input : SolverInput) (witness : ClosureWitness)
    (checked : CheckedClosure input witness) (path : List String) (finish : Marking)
    (execution : PathExec input input.marking path finish) :
    evalGoal finish input.goal = false :=
  checked.noGoal finish (resourceClosure_path input witness.exploredMarkings checked.closure
    checked.closure.initial execution)

private def topologicalMarkings (input : SolverInput) :
    Nat → List Marking → List Marking → List Marking
  | 0, _, ordered => ordered
  | _ + 1, [], ordered => ordered
  | fuel + 1, remaining, ordered =>
    let root := remaining.find? fun candidate => remaining.all fun predecessor =>
      input.transitions.all fun transition =>
        match stepAt input predecessor transition.identity with
        | none => true
        | some next => decide (next ≠ candidate)
    match root with
    | none => ordered
    | some selected => topologicalMarkings input fuel
        (remaining.filter (fun marking => decide (marking ≠ selected))) (ordered ++ [selected])

structure CheckedAcyclic (input : SolverInput) (witness : AcyclicWitness) : Type where
  closure : CheckedResourceClosure input witness.exploredMarkings
  order : List Marking
  increasing : ∀ marking ∈ witness.exploredMarkings, ∀ transition ∈ input.transitions,
    successorRanked input order marking transition

def verifyAcyclicWitness (input : SolverInput) (witness : AcyclicWitness) :
    Except WitnessFailure (CheckedAcyclic input witness) := do
  let closure ← verifyFiniteResourceClosure input witness.exploredMarkings witness.steps witness.frontier
  let order := topologicalMarkings input witness.exploredMarkings.length witness.exploredMarkings []
  if h : witness.exploredMarkings.all (rankedAt input order) = true then
    have increasing : ∀ marking ∈ witness.exploredMarkings, ∀ transition ∈ input.transitions,
        successorRanked input order marking transition := by
      intro marking present transition declared
      have here := (List.all_eq_true.mp h) marking present
      have edge := (List.all_eq_true.mp here) transition declared
      exact of_decide_eq_true edge
    pure { closure := closure, order := order, increasing := increasing }
  else throw (.forgedAcyclicity "closed resource graph contains a cycle")

private theorem resourceAcyclic_path_rank (input : SolverInput) (witness : AcyclicWitness)
    (checked : CheckedAcyclic input witness) {start finish : Marking} {path : List String}
    (present : start ∈ witness.exploredMarkings) (execution : PathExec input start path finish) :
    finish ∈ witness.exploredMarkings ∧
    listIndex start checked.order + path.length ≤ listIndex finish checked.order := by
  revert present
  induction execution with
  | nil _ => exact fun present => ⟨present, by simp⟩
  | @cons start middle finish identity rest head tail ih =>
    intro present
    obtain ⟨transition, declared, same, enabled, applied⟩ := head
    have replay := step_implies_stepAt input start identity middle checked.closure.valid
      ⟨transition, declared, same, enabled, applied⟩
    have covered := checked.closure.covered start present transition declared
    have increasing := checked.increasing start present transition declared
    simp only [successorCovered, successorRanked, same, replay] at covered increasing
    have later := ih covered
    refine ⟨later.1, ?_⟩
    simp only [List.length_cons]
    omega

theorem resourceAcyclicSound (input : SolverInput) (witness : AcyclicWitness)
    (checked : CheckedAcyclic input witness) (before cycle : List String) (start : Marking)
    (reached : PathExec input input.marking before start) (nonempty : cycle ≠ []) :
    ¬ PathExec input start cycle start := by
  intro execution
  have present := resourceClosure_path input witness.exploredMarkings checked.closure
    checked.closure.initial reached
  have rank := (resourceAcyclic_path_rank input witness checked present execution).2
  have positive : 0 < cycle.length := by
    cases cycle with
    | nil => exact absurd rfl nonempty
    | cons _ _ => simp
  omega

def encodeTuple (parts : List String) : String :=
  String.join (parts.map (fun part => toString (utf8Length part) ++ ":" ++ part))

def typeIdentity (reference : TypeRef) : String :=
  encodeTuple ["type", reference.source.repository, reference.source.revision, reference.source.path,
    reference.source.contentDigest, reference.source.documentId,
    if reference.source.declaredRevision.isSome then "some" else "none",
    reference.source.declaredRevision.map toString |>.getD "", reference.definitionName,
    encodeTuple reference.pointer]

def functionIdentity (reference : FunctionRef) : String :=
  encodeTuple [reference.identity, reference.revision, reference.contentDigest]

def producerIdentity : ProducerRef → String
  | .initial id => encodeTuple ["initial-value", id.value]
  | .invocationOutcome site outcome port =>
    encodeTuple ["outcome-value", site.value, outcome.value, port.value]

def lotIdentity : ResourceLotRef → String
  | .initial id => encodeTuple ["initial-lot", id.value]
  | .produced site outcome production =>
    encodeTuple ["produced-lot", site.value, outcome.value, production.value]

def invocationIdentity (invocation : InvocationPlan) (outcome : OutcomeId) : String :=
  encodeTuple ["invocation", invocation.site.value, functionIdentity invocation.function, outcome.value]

def productionIdentity (site : SiteId) (outcome : OutcomeId) (production : ProductionId) : String :=
  encodeTuple ["resource-production", site.value, outcome.value, production.value]

private def signature (input : CompositionInput) (reference : FunctionRef) : Option FunctionSignature :=
  input.signatures.find? (fun candidate => decide (candidate.reference = reference))

private def siteSignature (input : CompositionInput) (site : SiteId) : Option FunctionSignature := do
  let declaration ← input.invocationDomain.sites.find? (fun candidate => decide (candidate.id = site))
  signature input declaration.function

private def declaredValue (input : CompositionInput) :
    ProducerRef → Option (SlotContract × Option ResourceLotRef)
  | .initial id => do
    let initial ← input.initialInputs.find? (fun candidate => candidate.id == id)
    pure (initial.contract, initial.resource.map ResourceLotRef.initial)
  | .invocationOutcome site outcome port => do
    let function ← siteSignature input site
    let outcome ← function.outcomes.find? (fun candidate => candidate.id == outcome)
    let output ← outcome.valuePorts.find? (fun candidate => candidate.id == port)
    pure (output.contract, output.resourceProduction.map (ResourceLotRef.produced site outcome.id))

private def presentContract (reference : TypeRef) : SlotContract :=
  { typeRef := reference, required := true, nullable := false }

mutual
  def bindingSources : BindingExpr → List ValueRef
    | .source value _ _ => [value]
    | .product _ _ fields => fieldBindingSources fields
  def fieldBindingSources : List (String × BindingExpr) → List ValueRef
    | [] => []
    | (_, binding) :: rest => bindingSources binding ++ fieldBindingSources rest
end

private def pairRefs (table : List PairEntry) : List (TypeRef × TypeRef) :=
  table.map (fun entry => (entry.pair.source.typeRef, entry.pair.destination.typeRef))

def PresenceIncluded (source destination : SlotContract) : Prop :=
  (source.required = false → destination.required = false) ∧
  (source.nullable = true → destination.nullable = true)

private instance (source destination : SlotContract) : Decidable (PresenceIncluded source destination) :=
  inferInstanceAs (Decidable ((source.required = false → destination.required = false) ∧
    (source.nullable = true → destination.nullable = true)))

def Assignable (graph : SemanticGraph) (source destination : SlotContract) : Prop :=
  MeaningDefined graph source.typeRef ∧ MeaningDefined graph destination.typeRef ∧
    ∀ value, SlotMember graph source value → SlotMember graph destination value

private def PairSimulation (graph : SemanticGraph) (table : List PairEntry)
    (source destination : TypeRef) : Prop :=
  ∀ path value children,
    expandValue graph source path value = .requirements children →
    (∀ child ∈ children, ValueMember graph child.typeRef child.valuePath child.value) →
    (∀ child ∈ children, ∀ target, (child.typeRef, target) ∈ pairRefs table →
      ValueMember graph target child.valuePath child.value) →
    ValueMember graph destination path value

structure CheckedPairTable (graph : SemanticGraph) (table : List PairEntry) : Type where
  simulation : ∀ entry ∈ table, PairSimulation graph table
    entry.pair.source.typeRef entry.pair.destination.typeRef

private theorem pairTable_member_sound (graph : SemanticGraph) (table : List PairEntry)
    (checked : CheckedPairTable graph table) (source : TypeRef) (path : ValuePath) (value : JsonValue)
    (member : ValueMember graph source path value) :
    ∀ destination, (source, destination) ∈ pairRefs table →
      ValueMember graph destination path value := by
  induction member with
  | step source path value children expansion members ih =>
    intro destination related
    obtain ⟨entry, present, same⟩ := List.mem_map.mp related
    have sourceSame : entry.pair.source.typeRef = source := congrArg Prod.fst same
    have destinationSame : entry.pair.destination.typeRef = destination := congrArg Prod.snd same
    have simulation := checked.simulation entry present
    rw [sourceSame, destinationSame] at simulation
    exact simulation path value children expansion members ih

structure CheckedInclusion (graph : SemanticGraph) (source destination : SlotContract) where
  certificate : InclusionCertificate
  sourceMeaning : MeaningDefined graph source.typeRef
  destinationMeaning : MeaningDefined graph destination.typeRef
  presence : PresenceIncluded source destination
  values : ∀ path value, ValueMember graph source.typeRef path value →
    ValueMember graph destination.typeRef path value

theorem inclusionWitnessSound (graph : SemanticGraph) (source destination : SlotContract)
    (checked : CheckedInclusion graph source destination) :
    ∀ value, Slots graph source value → Slots graph destination value := by
  intro value member
  refine ⟨checked.destinationMeaning, ?_⟩
  cases member.2 with
  | absent optional => exact .absent destination (checked.presence.1 optional)
  | null nullable => exact .null destination (checked.presence.2 nullable)
  | present value present => exact .present destination value (checked.values [] value present)

theorem checkedInclusionAssignable (graph : SemanticGraph) (source destination : SlotContract)
    (checked : CheckedInclusion graph source destination) :
    Assignable graph source destination := by
  refine ⟨checked.sourceMeaning, checked.destinationMeaning, ?_⟩
  intro value member
  exact (inclusionWitnessSound graph source destination checked value
    ⟨checked.sourceMeaning, member⟩).2

private def lowerContainedInt (source destination : Option Int) : Bool :=
  match destination, source with
  | none, _ => true
  | some bound, some minimum => bound ≤ minimum
  | some _, none => false

private def upperContainedInt (source destination : Option Int) : Bool :=
  match destination, source with
  | none, _ => true
  | some bound, some maximum => maximum ≤ bound
  | some _, none => false

private def lowerContainedNat (source destination : Option Nat) : Bool :=
  match destination, source with
  | none, _ => true
  | some bound, some minimum => bound ≤ minimum
  | some bound, none => bound == 0

private def upperContainedNat (source destination : Option Nat) : Bool :=
  match destination, source with
  | none, _ => true
  | some bound, some maximum => maximum ≤ bound
  | some _, none => false

private theorem lengthContained_sound (smin smax dmin dmax : Option Nat)
    (lower : lowerContainedNat smin dmin = true)
    (upper : upperContainedNat smax dmax = true)
    (value : Nat) (accepted : lengthAccepts smin smax value = true) :
    lengthAccepts dmin dmax value = true := by
  cases smin <;> cases smax <;> cases dmin <;> cases dmax <;>
    simp_all [lowerContainedNat, upperContainedNat, lengthAccepts] <;> omega

private def integerFinite (spec : IntegerSpec) : Option (List Int) :=
  match spec.constValue with
  | some value => some [value]
  | none => spec.enumValues


private def integerLower (profile : VersionedSemanticProfile) (spec : IntegerSpec) : Option Int :=
  match integerBinding profile spec.domain with
  | none => none
  | some binding =>
    match binding.range with
    | .unbounded => spec.minimum
    | .inclusive minimum _ => some (max minimum (spec.minimum.getD minimum))

private def integerUpper (profile : VersionedSemanticProfile) (spec : IntegerSpec) : Option Int :=
  match integerBinding profile spec.domain with
  | none => none
  | some binding =>
    match binding.range with
    | .unbounded => spec.maximum
    | .inclusive _ maximum => some (min maximum (spec.maximum.getD maximum))
private def integerNumberOnly (profile : VersionedSemanticProfile) (spec : IntegerSpec) : Bool :=
  match integerBinding profile spec.domain with
  | some binding =>
    match binding.forms with
    | [.number] => true
    | _ => false
  | none => false

private def integerRuleCheck (graph : SemanticGraph) (source destination : IntegerSpec) : Bool :=
  integerNumberOnly graph.profile source && integerNumberOnly graph.profile destination &&
    source.domain == destination.domain &&
    match integerFinite source with
    | some values => values.all fun value =>
        if integerCondition graph.profile source (.num value) == none then
          integerCondition graph.profile destination (.num value) == none
        else true
    | none =>
      destination.constValue.isNone && destination.enumValues.isNone &&
        lowerContainedInt source.minimum destination.minimum &&
        upperContainedInt source.maximum destination.maximum

private theorem integerValueForBinding_num_eq (binding : IntegerDomainBinding)
    (value actual : Int)
    (found : integerValueForBinding binding (.num value) = some actual) :
    actual = value := by
  unfold integerValueForBinding at found
  obtain ⟨form, member, formFound⟩ := List.exists_of_findSome?_eq_some found
  cases form <;> simp [integerValueForForm] at formFound
  exact formFound.symm

private theorem integerCondition_none_iff (profile : VersionedSemanticProfile)
    (spec : IntegerSpec) (value : Int) :
    integerCondition profile spec (.num value) = none ↔
      (integerInDomain profile spec.domain (.num value) = true ∧
       (∀ c, spec.constValue = some c → c = value) ∧
       (∀ vs, spec.enumValues = some vs → value ∈ vs) ∧
       (∀ m, spec.minimum = some m → m ≤ value) ∧
       (∀ m, spec.maximum = some m → value ≤ m)) := by
  unfold integerCondition integerInDomain
  cases hb : integerBinding profile spec.domain with
  | none => simp [hb]
  | some binding =>
    cases hv : integerValueForBinding binding (.num value) with
    | none => simp [hb, hv]
    | some actual =>
      have actualSame := integerValueForBinding_num_eq binding value actual hv
      subst actual
      cases hc : spec.constValue <;> cases he : spec.enumValues <;>
        cases hm : spec.minimum <;> cases hx : spec.maximum <;>
        by_cases hr : integerRangeAccepts binding.range value = true <;>
        simp [hb, hv, hc, he, hm, hx, hr, Int.not_lt] <;>
        (repeat' split) <;> (try simp_all) <;> omega

private theorem stringCondition_none_iff (profile : VersionedSemanticProfile)
    (spec : StringSpec) (value : String) :
    stringCondition profile spec value = none ↔
      (unicodeValid value = true ∧
       (∀ c, spec.constValue = some c → c = value) ∧
       (∀ vs, spec.enumValues = some vs → value ∈ vs) ∧
       lengthBoundsFailure profile value spec.lengths = none ∧
       (∀ name, spec.format = some (.named name) → ∀ binding,
         profile.formatBindings.find? (fun binding => binding.name == name) = some binding →
         formatAccepts binding.rule value = true) ∧
       (∀ rule, spec.format = some (.inline rule) → formatAccepts rule value = true)) := by
  unfold stringCondition
  simp only [formatAcceptsFast_eq]
  cases hc : spec.constValue <;> cases he : spec.enumValues <;>
    cases hl : lengthBoundsFailure profile value spec.lengths <;>
    cases hf : spec.format with
    | none =>
      by_cases hu : unicodeValid value = true <;>
        simp [hc, he, hl, hf, hu] <;> (repeat' split) <;> simp_all
    | some use =>
      cases use with
      | named name =>
        cases hb : profile.formatBindings.find? (fun binding => binding.name == name) <;>
          by_cases hu : unicodeValid value = true <;>
          simp [hc, he, hl, hf, hb, hu] <;> (repeat' split) <;> (try simp_all)
      | inline rule =>
        by_cases hu : unicodeValid value = true <;>
          simp [hc, he, hl, hf, hu] <;> (repeat' split) <;> simp_all

private theorem integer_finite_member (profile : VersionedSemanticProfile)
    (spec : IntegerSpec) (values : List Int) (finite : integerFinite spec = some values)
    (value : Int) (accepted : integerCondition profile spec (.num value) = none) :
    value ∈ values := by
  have parts := (integerCondition_none_iff profile spec value).mp accepted
  cases hconst : spec.constValue with
  | some expected =>
    have expectedSame : expected = value := parts.2.1 expected hconst
    have valuesSame : values = [expected] := by
      simpa [integerFinite, hconst] using finite.symm
    simp [valuesSame, expectedSame]
  | none =>
    cases henum : spec.enumValues with
    | none => simp [integerFinite, hconst, henum] at finite
    | some enumerated =>
      have valuesSame : values = enumerated := by
        simpa [integerFinite, hconst, henum] using finite.symm
      subst valuesSame
      exact parts.2.2.1 _ henum

private theorem integerRuleCheck_sound (graph : SemanticGraph)
    (source destination : IntegerSpec) (checked : integerRuleCheck graph source destination = true)
    (value : Int) (accepted : integerCondition graph.profile source (.num value) = none) :
    integerCondition graph.profile destination (.num value) = none := by
  have checks :
      ((integerNumberOnly graph.profile source = true ∧
          integerNumberOnly graph.profile destination = true) ∧
        source.domain = destination.domain) ∧
      (match integerFinite source with
      | some values => values.all fun value =>
          if integerCondition graph.profile source (.num value) == none then
            integerCondition graph.profile destination (.num value) == none
          else true
      | none =>
        destination.constValue.isNone && destination.enumValues.isNone &&
          lowerContainedInt source.minimum destination.minimum &&
          upperContainedInt source.maximum destination.maximum) = true := by
    simpa [integerRuleCheck, Bool.and_eq_true] using checked
  have sourceNumber := checks.1.1.1
  have destinationNumber := checks.1.1.2
  have sameDomain := checks.1.2
  have ruleChecked := checks.2
  cases finite : integerFinite source with
  | some values =>
    have all : values.all (fun value =>
        if (integerCondition graph.profile source (.num value) == none) = true then
          integerCondition graph.profile destination (.num value) == none
        else true) = true := by
      simpa [finite] using ruleChecked
    have here := List.all_eq_true.mp all value
      (integer_finite_member graph.profile source values finite value accepted)
    simpa [accepted] using here
  | none =>
    cases sourceConst : source.constValue with
    | some constant => simp [integerFinite, sourceConst] at finite
    | none =>
      cases sourceEnum : source.enumValues with
      | some values => simp [integerFinite, sourceConst, sourceEnum] at finite
      | none =>
        cases destinationConst : destination.constValue <;>
          cases destinationEnum : destination.enumValues <;>
          cases sourceMin : source.minimum <;>
          cases destinationMin : destination.minimum <;>
          cases sourceMax : source.maximum <;>
          cases destinationMax : destination.maximum <;>
          simp_all [lowerContainedInt, upperContainedInt, integerCondition_none_iff] <;>
          omega

private def stringFinite (spec : StringSpec) : Option (List String) :=
  match spec.constValue with
  | some value => some [value]
  | none => spec.enumValues

def formatIncluded (profile : VersionedSemanticProfile)
    (source destination : Option String) : Bool :=
  match destination with
  | none => true
  | some destination => match source with
    | none => false
    | some source =>
      match profile.formatBindings.find? (fun binding => binding.name == source),
          profile.formatBindings.find? (fun binding => binding.name == destination) with
      | some source, some destination => formatRuleIncluded source.rule destination.rule
      | _, _ => false

private theorem formatIncluded_sound (profile : VersionedSemanticProfile)
    (source destination : Option String) (value : String)
    (included : formatIncluded profile source destination = true)
    (accepted : ∀ name, source = some name → ∀ binding,
      profile.formatBindings.find? (fun binding => binding.name == name) = some binding →
      formatAccepts binding.rule value = true) :
    ∀ name, destination = some name → ∀ binding,
      profile.formatBindings.find? (fun binding => binding.name == name) = some binding →
      formatAccepts binding.rule value = true := by
  intro name named binding found
  subst destination
  cases source with
  | none => simp [formatIncluded] at included
  | some source =>
    cases lookup : profile.formatBindings.find? (fun binding => binding.name == source) with
    | none => simp [formatIncluded, lookup] at included
    | some sourceBinding =>
      have rules : formatRuleIncluded sourceBinding.rule binding.rule = true := by
        simpa [formatIncluded, lookup, found] using included
      exact formatRuleIncluded_sound _ _ value rules (accepted source rfl sourceBinding lookup)

private def lengthBoundsIncluded (source destination : List LengthBound) : Bool :=
  destination.all fun target =>
    source.any fun candidate =>
      decide (candidate.unit = target.unit) &&
        lowerContainedNat candidate.minimum target.minimum &&
        upperContainedNat candidate.maximum target.maximum

private theorem lengthBoundsFailure_accepts_member (profile : VersionedSemanticProfile)
    (value : String) (bounds : List LengthBound)
    (accepted : lengthBoundsFailure profile value bounds = none)
    (bound : LengthBound) (present : bound ∈ bounds) :
    ∃ length, lengthInUnit profile bound.unit value = some length ∧
      lengthAccepts bound.minimum bound.maximum length = true := by
  induction bounds with
  | nil => simp at present
  | cons head rest ih =>
    simp only [lengthBoundsFailure] at accepted
    cases measured : lengthInUnit profile head.unit value with
    | none => simp [measured] at accepted
    | some length =>
      cases valid : lengthAccepts head.minimum head.maximum length
      · simp [measured, valid] at accepted
      · rcases List.mem_cons.mp present with same | later
        · subst bound
          exact ⟨length, measured, valid⟩
        · have tailAccepted : lengthBoundsFailure profile value rest = none := by
            simpa [lengthBoundsFailure, measured, valid] using accepted
          exact ih tailAccepted later

private theorem lengthBoundsIncluded_sound (profile : VersionedSemanticProfile)
    (source destination : List LengthBound) (value : String)
    (included : lengthBoundsIncluded source destination = true)
    (accepted : lengthBoundsFailure profile value source = none) :
    lengthBoundsFailure profile value destination = none := by
  induction destination with
  | nil => rfl
  | cons target rest ih =>
    have checks := List.all_eq_true.mp included target List.mem_cons_self
    rw [List.any_eq_true] at checks
    obtain ⟨candidate, candidatePresent, checked⟩ := checks
    simp only [Bool.and_eq_true] at checked
    have sameUnit := checked.1.1
    have lower := checked.1.2
    have upper := checked.2
    have unitSame : candidate.unit = target.unit := of_decide_eq_true sameUnit
    obtain ⟨length, measured, sourceAccepts⟩ :=
      lengthBoundsFailure_accepts_member profile value source accepted candidate candidatePresent
    have targetAccepts :=
      lengthContained_sound candidate.minimum candidate.maximum target.minimum target.maximum
        lower upper length sourceAccepts
    have tailIncluded : lengthBoundsIncluded source rest = true := by
      exact List.all_eq_true.mpr fun bound present =>
        List.all_eq_true.mp included bound (List.mem_cons_of_mem target present)
    simpa [lengthBoundsFailure, ← unitSame, measured, targetAccepts] using
      ih tailIncluded

private def stringRuleCheck (_graph : SemanticGraph) (source destination : StringSpec) : Bool :=
  decide ({ source with lengths := [] } = { destination with lengths := [] }) &&
    lengthBoundsIncluded source.lengths destination.lengths

private theorem string_finite_member (profile : VersionedSemanticProfile)
    (spec : StringSpec) (values : List String) (finite : stringFinite spec = some values)
    (value : String) (accepted : stringCondition profile spec value = none) :
    value ∈ values := by
  have parts := (stringCondition_none_iff profile spec value).mp accepted
  cases hconst : spec.constValue with
  | some expected =>
    have expectedSame : expected = value := parts.2.1 expected hconst
    have valuesSame : values = [expected] := by
      simpa [stringFinite, hconst] using finite.symm
    simp [valuesSame, expectedSame]
  | none =>
    cases henum : spec.enumValues with
    | none => simp [stringFinite, hconst, henum] at finite
    | some enumerated =>
      have valuesSame : values = enumerated := by
        simpa [stringFinite, hconst, henum] using finite.symm
      subst valuesSame
      exact parts.2.2.1 _ henum

private theorem stringRuleCheck_sound (graph : SemanticGraph)
    (source destination : StringSpec) (checked : stringRuleCheck graph source destination = true)
    (value : String) (accepted : stringCondition graph.profile source value = none) :
    stringCondition graph.profile destination value = none := by
  have checks : { source with lengths := [] } = { destination with lengths := [] } ∧
      lengthBoundsIncluded source.lengths destination.lengths = true := by
    simpa [stringRuleCheck, Bool.and_eq_true] using checked
  have shape : destination = { source with lengths := destination.lengths } := by
    cases source
    cases destination
    simp only [StringSpec.mk.injEq] at checks ⊢
    simp_all
  have parts := (stringCondition_none_iff graph.profile source value).mp accepted
  rw [shape, stringCondition_none_iff]
  exact ⟨parts.1, parts.2.1, parts.2.2.1,
    lengthBoundsIncluded_sound graph.profile source.lengths destination.lengths value
      checks.2 parts.2.2.2.1,
    parts.2.2.2.2.1, parts.2.2.2.2.2⟩

private theorem stringValueRuleCheck_sound (graph : SemanticGraph)
    (source destination : StringSpec) (checked : stringRuleCheck graph source destination = true)
    (value : JsonValue) (accepted : stringValueCondition graph.profile source value = none) :
    stringValueCondition graph.profile destination value = none := by
  have checkParts :
      { source with lengths := [] } = { destination with lengths := [] } ∧
        lengthBoundsIncluded source.lengths destination.lengths = true := by
    simpa [stringRuleCheck, Bool.and_eq_true] using checked
  have checks : { source with lengths := [] } = { destination with lengths := [] } :=
    checkParts.1
  have shape : destination = { source with lengths := destination.lengths } := by
    cases source
    cases destination
    simp only [StringSpec.mk.injEq] at checks ⊢
    simp_all
  have destinationWrapper : destination.wrapper = source.wrapper := by rw [shape]
  unfold stringValueCondition at accepted ⊢
  cases sourceWrapper : source.wrapper with
  | none =>
    cases value <;> simp [sourceWrapper, destinationWrapper] at accepted ⊢
    exact stringRuleCheck_sound graph source destination checked _ accepted
  | some name =>
    cases value <;> simp [sourceWrapper, destinationWrapper] at accepted ⊢
    case obj members =>
      cases classification : classOf graph.profile members <;>
        simp [sourceWrapper, destinationWrapper, classification] at accepted ⊢
      case wrapper wrapper =>
        by_cases same : wrapper.name = name
        · simp [same] at accepted ⊢
          cases payload : wrapperPayloadText graph.profile wrapper (.obj members) with
          | none => simpa [payload] using accepted
          | some text =>
            simp [payload] at accepted ⊢
            exact stringRuleCheck_sound graph source destination checked text accepted
        · simp [same] at accepted


private structure CheckedChildren (table : List PairEntry) (required : List (TypeRef × TypeRef)) : Type where
  present : ∀ pair ∈ required, pair ∈ pairRefs table

private def checkChildCoverage (table : List PairEntry) (entry : PairEntry)
    (required : List (TypeRef × TypeRef)) : Except InclusionFailure (CheckedChildren table required) :=
  let actual := entry.children.filterMap (fun index =>
    (table[index]?).map (fun child => (child.pair.source.typeRef, child.pair.destination.typeRef)))
  if actual.length != entry.children.length ||
      !required.all (fun pair => decide (pair ∈ actual)) ||
      !actual.all (fun pair => decide (pair ∈ required)) then
    .error (.childCoverage 0)
  else if h : required.all (fun pair => decide (pair ∈ pairRefs table)) = true then
    have present : ∀ pair ∈ required, pair ∈ pairRefs table := by
      intro pair member
      exact of_decide_eq_true ((List.all_eq_true.mp h) pair member)
    .ok { present := present }
  else .error (.childCoverage 0)

private theorem integer_pair_simulation (graph : SemanticGraph) (table : List PairEntry)
    (source destination : TypeRef) (snode dnode : TypeNode) (sspec dspec : IntegerSpec)
    (slookup : graph.findType source = some snode) (dlookup : graph.findType destination = some dnode)
    (sshape : snode.shape = .integer sspec) (dshape : dnode.shape = .integer dspec)
    (check : integerRuleCheck graph sspec dspec = true) :
    PairSimulation graph table source destination := by
  intro path value children expansion members mapped
  have sourceMember : ValueMember graph source path value := .step source path value children expansion members
  obtain ⟨integer, same, accepted⟩ := integer_member_has_integer_value
    graph source path snode sspec slookup sshape value sourceMember
  have checkParts := check
  simp only [integerRuleCheck, Bool.and_eq_true] at checkParts
  have sourceNumber : integerNumberOnly graph.profile sspec = true := checkParts.1.1.1
  unfold integerNumberOnly at sourceNumber
  cases binding : integerBinding graph.profile sspec.domain with
  | none => simp [binding] at sourceNumber
  | some domain =>
    have forms : domain.forms = [.number] := by
      cases listed : domain.forms with
      | nil => simp [binding, listed] at sourceNumber
      | cons form rest =>
        cases form <;> cases rest with
        | nil => first | rfl | simp [binding, listed] at sourceNumber |
            simp [binding, listed] at sourceNumber
        | cons next tail => simp [binding, listed] at sourceNumber
    simp [binding, integerValueForBinding, forms] at same
    cases value with
    | num actual =>
      simp [integerValueForBinding, integerValueForForm] at same
      subst integer
      have target := integerRuleCheck_sound graph sspec dspec check actual accepted
      exact .step destination path (.num actual) []
        (by simp [expandValue, expandNode, dlookup, dshape, target]) (by simp)
    | null => simp [integerValueForBinding, integerValueForForm] at same
    | bool value => simp [integerValueForBinding, integerValueForForm] at same
    | dec text => simp [integerValueForBinding, integerValueForForm] at same
    | str text => simp [integerValueForBinding, integerValueForForm] at same
    | arr items => simp [integerValueForBinding, integerValueForForm] at same
    | obj entries => simp [integerValueForBinding, integerValueForForm] at same

private theorem string_pair_simulation (graph : SemanticGraph) (table : List PairEntry)
    (source destination : TypeRef) (snode dnode : TypeNode) (sspec dspec : StringSpec)
    (slookup : graph.findType source = some snode) (dlookup : graph.findType destination = some dnode)
    (sshape : snode.shape = .string sspec) (dshape : dnode.shape = .string dspec)
    (check : stringRuleCheck graph sspec dspec = true) :
    PairSimulation graph table source destination := by
  intro path value children expansion members mapped
  have accepted : stringValueCondition graph.profile sspec value = none := by
    cases condition : stringValueCondition graph.profile sspec value with
    | none => rfl
    | some condition => simp [expandValue, expandNode, slookup, sshape, condition] at expansion
  have target := stringValueRuleCheck_sound graph sspec dspec check value accepted
  exact .step destination path value []
    (by simp [expandValue, expandNode, dlookup, dshape, target]) (by simp)

private theorem array_pair_simulation (graph : SemanticGraph) (table : List PairEntry)
    (source destination : TypeRef) (snode dnode : TypeNode) (sspec dspec : ArraySpec)
    (slookup : graph.findType source = some snode) (dlookup : graph.findType destination = some dnode)
    (sshape : snode.shape = .array sspec) (dshape : dnode.shape = .array dspec)
    (lower : lowerContainedNat sspec.minLength dspec.minLength = true)
    (upper : upperContainedNat sspec.maxLength dspec.maxLength = true)
    (nullable : (!sspec.item.nullable || dspec.item.nullable) = true)
    (related : (sspec.item.typeRef, dspec.item.typeRef) ∈ pairRefs table) :
    PairSimulation graph table source destination := by
  intro path value children expansion members mapped
  cases value with
  | arr items =>
    have slength : lengthAccepts sspec.minLength sspec.maxLength items.length = true := by
      cases length : lengthAccepts sspec.minLength sspec.maxLength items.length <;>
        simp_all [expandValue, expandNode, slookup, sshape]
    have childrenSame : children = items.zipIdx.flatMap (fun (item, index) =>
        elementRequirements sspec.item (path ++ [.index index]) item) := by
      simpa [expandValue, expandNode, slookup, sshape, slength] using expansion.symm
    subst children
    let targetChildren := items.zipIdx.flatMap (fun (item, index) =>
      elementRequirements dspec.item (path ++ [.index index]) item)
    refine .step destination path (.arr items) targetChildren ?_ ?_
    · have dlength := lengthContained_sound _ _ _ _ lower upper _ slength
      simp [expandValue, expandNode, dlookup, dshape, dlength, targetChildren]
    · intro child present
      obtain ⟨⟨item, index⟩, declared, childPresent⟩ := List.mem_flatMap.mp present
      cases item with
      | null =>
        cases destinationNullable : dspec.item.nullable
        · have sourceNonnullable : sspec.item.nullable = false := by
            cases sourceNullable : sspec.item.nullable
            · rfl
            · simp [sourceNullable, destinationNullable] at nullable
          have same : child = {
              typeRef := dspec.item.typeRef
              valuePath := path ++ [.index index]
              value := JsonValue.null } := by
            simpa [elementRequirements, destinationNullable] using childPresent
          subst child
          have sourcePresent : ({
              typeRef := sspec.item.typeRef
              valuePath := path ++ [.index index]
              value := JsonValue.null } : ValueRequirement) ∈
              items.zipIdx.flatMap (fun (item, index) =>
                elementRequirements sspec.item (path ++ [.index index]) item) :=
            List.mem_flatMap.mpr ⟨(.null, index), declared, by
              simp [elementRequirements, sourceNonnullable]⟩
          exact mapped _ sourcePresent dspec.item.typeRef related
        · simp [elementRequirements, destinationNullable] at childPresent
      | bool actual | num actual | dec actual | str actual | arr actual | obj actual =>
        simp [elementRequirements] at childPresent
        subst child
        apply mapped {
          typeRef := sspec.item.typeRef
          valuePath := path ++ [.index index]
          value := _ }
        · exact List.mem_flatMap.mpr ⟨_, declared, by simp [elementRequirements]⟩
        · exact related
  | null => simp [expandValue, expandNode, slookup, sshape] at expansion
  | bool _ => simp [expandValue, expandNode, slookup, sshape] at expansion
  | num _ => simp [expandValue, expandNode, slookup, sshape] at expansion
  | dec _ => simp [expandValue, expandNode, slookup, sshape] at expansion
  | str _ => simp [expandValue, expandNode, slookup, sshape] at expansion
  | obj _ => simp [expandValue, expandNode, slookup, sshape] at expansion

private theorem same_shape_pair_simulation (graph : SemanticGraph) (table : List PairEntry)
    (source destination : TypeRef) (snode dnode : TypeNode)
    (slookup : graph.findType source = some snode) (dlookup : graph.findType destination = some dnode)
    (same : snode.shape = dnode.shape) : PairSimulation graph table source destination := by
  intro path value children expansion members mapped
  exact .step destination path value children
    (same_shape_expansion_requirements graph source destination snode dnode path value children
      slookup dlookup same expansion) members

private theorem alias_source_pair_simulation (graph : SemanticGraph) (table : List PairEntry)
    (source destination target : TypeRef) (node : TypeNode) (text : String)
    (lookup : graph.findType source = some node) (shape : node.shape = .alias target text)
    (related : (target, destination) ∈ pairRefs table) :
    PairSimulation graph table source destination := by
  intro path value children expansion members mapped
  have same : children = [{ typeRef := target, valuePath := path, value }] := by
    simpa [expandValue, expandNode, lookup, shape] using expansion.symm
  subst children
  exact mapped { typeRef := target, valuePath := path, value } (by simp) destination related

private theorem alias_destination_pair_simulation (graph : SemanticGraph) (table : List PairEntry)
    (source destination target : TypeRef) (node : TypeNode) (text : String)
    (lookup : graph.findType destination = some node) (shape : node.shape = .alias target text)
    (inner : PairSimulation graph table source target) :
    PairSimulation graph table source destination := by
  intro path value children expansion members mapped
  exact .step destination path value [{ typeRef := target, valuePath := path, value }]
    (by simp [expandValue, expandNode, lookup, shape])
    (by
      intro child present
      have same : child = { typeRef := target, valuePath := path, value } := by simpa using present
      subst child
      exact inner path value children expansion members mapped)


private def fieldNamed (fields : List FieldSpec) (name : String) : Option FieldSpec :=
  fields.find? (fun field => field.wireName == name)

private theorem memberValue_mem (entries : List (String × JsonValue)) (key : String)
    (value : JsonValue) (found : memberValue key entries = some value) :
    (key, value) ∈ entries := by
  unfold memberValue at found
  cases selected : entries.find? (fun member => member.1 == key) with
  | none => simp [selected] at found
  | some entry =>
    have present := List.mem_of_find?_eq_some selected
    have named := List.find?_some selected
    obtain ⟨entryKey, entryValue⟩ := entry
    rw [selected] at found
    simp at found
    subst entryValue
    have same : entryKey = key := beq_iff_eq.mp named
    subst entryKey
    exact present

private def extraAllowsKey (profile : VersionedSemanticProfile)
    (keyFormat : Option FormatUse) (key : String) : Bool :=
  (keyFormat.map (fun use => formatUseAccepts profile use key)).getD true

private def productFieldPairs (graph : SemanticGraph)
    (source destination : ProductSpec) : List (TypeRef × TypeRef) :=
  let destinationPairs := destination.fields.filterMap fun field =>
    match fieldNamed source.fields field.wireName with
    | some sourceField => some (sourceField.slot.typeRef, field.slot.typeRef)
    | none =>
      if field.slot.required ||
          (graph.profile.tag.map (fun tag => field.wireName == tag.key)).getD false then none
      else match source.extras with
        | .reject => none
        | .allow _ sourceContract => some (sourceContract.typeRef, field.slot.typeRef)
  let sourceExtraPairs := source.fields.filterMap fun field =>
    if (fieldNamed destination.fields field.wireName).isSome then none
    else match destination.extras with
      | .reject => none
      | .allow _ contract => some (field.slot.typeRef, contract.typeRef)
  let extrasPairs := match source.extras, destination.extras with
    | .allow _ sourceContract, .allow _ destinationContract =>
      [(sourceContract.typeRef, destinationContract.typeRef)]
    | _, _ => []
  destinationPairs ++ sourceExtraPairs ++ extrasPairs

private def typeRejectsNull (graph : SemanticGraph) (ref : TypeRef) : Bool :=
  match expandValue graph ref [] .null with
  | .rejected _ => true
  | _ => false

private theorem typeRejectsNull_no_member (graph : SemanticGraph) (ref : TypeRef)
    (rejected : typeRejectsNull graph ref = true) :
    ¬ValueMember graph ref [] .null := by
  intro member
  obtain ⟨children, expansion, _⟩ := member_expansion_has_members graph ref [] .null member
  simp [typeRejectsNull, expansion] at rejected


private def productRuleShapeCheck (graph : SemanticGraph)
    (source destination : ProductSpec) : Bool :=
  destination.fields.all (fun destinationField =>
    match fieldNamed source.fields destinationField.wireName with
    | some sourceField => decide (PresenceIncluded sourceField.slot destinationField.slot)
    | none =>
      !destinationField.slot.required &&
      !(graph.profile.tag.map
        (fun tag => destinationField.wireName == tag.key)).getD false &&
      match source.extras with
      | .reject => false
      | .allow _ sourceContract =>
        ((!sourceContract.nullable && typeRejectsNull graph sourceContract.typeRef) ||
          destinationField.slot.nullable)) &&
  source.fields.all (fun sourceField =>
    match fieldNamed destination.fields sourceField.wireName with
    | some _ => true
    | none =>
      (graph.profile.tag.map (fun tag => sourceField.wireName == tag.key)).getD false ||
      match destination.extras with
      | .reject => false
      | .allow keyFormat contract =>
        unicodeValid sourceField.wireName &&
        extraAllowsKey graph.profile keyFormat sourceField.wireName &&
        (!sourceField.slot.nullable || contract.nullable)) &&
  match source.extras, destination.extras with
  | .reject, _ => true
  | .allow _ _, .reject => false
  | .allow sourceKey sourceContract, .allow destinationKey destinationContract =>
    formatUseIncluded graph.profile sourceKey destinationKey &&
    (!sourceContract.nullable || destinationContract.nullable)

private def productRuleCheck (graph : SemanticGraph) (table : List PairEntry)
    (source destination : ProductSpec) : Bool :=
  destination.fields.all (fun destinationField =>
    match fieldNamed source.fields destinationField.wireName with
    | some sourceField =>
      decide (PresenceIncluded sourceField.slot destinationField.slot) &&
      decide ((sourceField.slot.typeRef, destinationField.slot.typeRef) ∈ pairRefs table)
    | none =>
      !destinationField.slot.required &&
      !(graph.profile.tag.map
        (fun tag => destinationField.wireName == tag.key)).getD false &&
      match source.extras with
      | .reject => false
      | .allow _ sourceContract =>
        (((!sourceContract.nullable && typeRejectsNull graph sourceContract.typeRef) ||
          destinationField.slot.nullable) &&
        decide ((sourceContract.typeRef, destinationField.slot.typeRef) ∈ pairRefs table))) &&
  source.fields.all (fun sourceField =>
    match fieldNamed destination.fields sourceField.wireName with
    | some _ => true
    | none =>
      (graph.profile.tag.map (fun tag => sourceField.wireName == tag.key)).getD false ||
      match destination.extras with
      | .reject => false
      | .allow keyFormat contract =>
        unicodeValid sourceField.wireName &&
        extraAllowsKey graph.profile keyFormat sourceField.wireName &&
        (!sourceField.slot.nullable || contract.nullable) &&
        decide ((sourceField.slot.typeRef, contract.typeRef) ∈ pairRefs table)) &&
  match source.extras, destination.extras with
  | .reject, _ => true
  | .allow _ _, .reject => false
  | .allow sourceKey sourceContract, .allow destinationKey destinationContract =>
    formatUseIncluded graph.profile sourceKey destinationKey &&
    (!sourceContract.nullable || destinationContract.nullable) &&
    decide ((sourceContract.typeRef, destinationContract.typeRef) ∈ pairRefs table)

private theorem boolean_pair_simulation (graph : SemanticGraph) (table : List PairEntry)
    (source destination : TypeRef) (snode dnode : TypeNode) (sspec dspec : BooleanSpec)
    (slookup : graph.findType source = some snode) (dlookup : graph.findType destination = some dnode)
    (sshape : snode.shape = .boolean sspec) (dshape : dnode.shape = .boolean dspec)
    (included : dspec.constValue = none ∨ sspec.constValue = dspec.constValue) :
    PairSimulation graph table source destination := by
  intro path value children expansion members mapped
  cases value with
  | bool actual =>
    have accepted : (sspec.constValue.map (· != actual)).getD false = false := by
      cases condition : (sspec.constValue.map (· != actual)).getD false <;>
        simp_all [expandValue, expandNode, slookup, sshape]
    have target : (dspec.constValue.map (· != actual)).getD false = false := by
      rcases included with empty | same
      · simp [empty]
      · simpa [same] using accepted
    exact .step destination path (.bool actual) []
      (by simp [expandValue, expandNode, dlookup, dshape, target]) (by simp)
  | null => simp [expandValue, expandNode, slookup, sshape] at expansion
  | num _ => simp [expandValue, expandNode, slookup, sshape] at expansion
  | dec _ => simp [expandValue, expandNode, slookup, sshape] at expansion
  | str _ => simp [expandValue, expandNode, slookup, sshape] at expansion
  | arr _ => simp [expandValue, expandNode, slookup, sshape] at expansion
  | obj _ => simp [expandValue, expandNode, slookup, sshape] at expansion

private def resolveOption {α ε : Type} (option : Option α) (failure : ε) :
    Except ε { value : α // option = some value } :=
  match found : option with
  | none => .error failure
  | some value => .ok ⟨value, rfl⟩

private theorem mapped_nodup_identity_unique {α β : Type} (items : List α) (key : α → β)
    (unique : (items.map key).Nodup) (first second : α) (left : first ∈ items) (right : second ∈ items)
    (same : key first = key second) : first = second := by
  induction items generalizing first second with
  | nil => simp at left
  | cons head rest ih =>
    have excluded := (List.nodup_cons.mp unique).1
    have tailUnique := (List.nodup_cons.mp unique).2
    rcases List.mem_cons.mp left with firstHead | firstTail
    · subst first
      rcases List.mem_cons.mp right with secondHead | secondTail
      · exact secondHead.symm
      · have forbidden : key head ∈ rest.map key :=
          List.mem_map.mpr ⟨second, secondTail, same.symm⟩
        exact False.elim (excluded forbidden)
    · rcases List.mem_cons.mp right with secondHead | secondTail
      · subst second
        have forbidden : key head ∈ rest.map key :=
          List.mem_map.mpr ⟨first, firstTail, same⟩
        exact False.elim (excluded forbidden)
      · exact ih tailUnique first second firstTail secondTail same

private theorem find_sound {α : Type} (items : List α) (predicate : α → Bool) (item : α)
    (found : items.find? predicate = some item) : item ∈ items ∧ predicate item = true := by
  induction items with
  | nil => simp at found
  | cons head rest ih =>
    cases condition : predicate head with
    | true =>
      have same : head = item := by simpa [List.find?, condition] using found
      subst item
      exact ⟨List.mem_cons_self, condition⟩
    | false =>
      have later : rest.find? predicate = some item := by simpa [List.find?, condition] using found
      have result := ih later
      exact ⟨List.mem_cons_of_mem head result.1, result.2⟩


def selectorDisjoint (left right : UnionBranch) : Bool :=
  match left.selector, right.selector with
  | .internalTag, .internalTag => left.wireTag != right.wireTag
  | .kind left, .kind right => decide (left ≠ right)
  | .internalTag, .kind right | .kind right, .internalTag => decide (right ≠ .object)
  | _, _ => false

theorem disjointSelector_sound (profile : VersionedSemanticProfile)
    (left right : UnionBranch) (value : JsonValue)
    (disjoint : selectorDisjoint left right = true) :
    ¬ (selectorMatches profile left value = true ∧
      selectorMatches profile right value = true) := by
  cases leftSelector : left.selector <;> cases rightSelector : right.selector
  all_goals simp [selectorDisjoint, leftSelector, rightSelector] at disjoint
  case internalTag.internalTag =>
    intro both
    cases value <;> simp [selectorMatches, leftSelector, rightSelector] at both
    split at both <;> simp_all
    split at both <;> simp_all
    exact disjoint (both.1.symm.trans both.2)
  case internalTag.kind kind =>
    cases kind <;> cases value <;>
      simp [selectorMatches, valueKindMatches, leftSelector, rightSelector] at disjoint ⊢
  case kind.internalTag kind =>
    cases kind <;> cases value <;>
      simp [selectorMatches, valueKindMatches, leftSelector, rightSelector] at disjoint ⊢
  case kind.kind leftKind rightKind =>
    cases leftKind <;> cases rightKind <;> cases value <;>
      simp [selectorMatches, valueKindMatches, leftSelector, rightSelector] at disjoint ⊢

private def selectorsEqual (source destination : UnionBranch) : Bool :=
  match source.selector, destination.selector with
  | .internalTag, .internalTag => source.wireTag == destination.wireTag
  | .memberShape source, .memberShape destination => decide (source = destination)
  | .kind source, .kind destination => decide (source = destination)
  | .otherwise, .otherwise => true
  | _, _ => false

private theorem selectorsEqual_matches (profile : VersionedSemanticProfile)
    (source destination : UnionBranch) (value : JsonValue)
    (same : selectorsEqual source destination = true) :
    selectorMatches profile source value = selectorMatches profile destination value := by
  cases sourceSelector : source.selector <;> cases destinationSelector : destination.selector <;>
    simp [selectorsEqual, selectorMatches, sourceSelector, destinationSelector,
      beq_iff_eq] at same ⊢ <;>
    simp_all

private def disjointFromAll (destination : UnionBranch) (sources : List UnionBranch) : Bool :=
  sources.all (selectorDisjoint destination)

private def unionBranchPairs : List UnionBranch → List UnionBranch →
    Option (List (TypeRef × TypeRef))
  | [], _ => some []
  | _ :: _, [] => none
  | sources@(source :: rest), destination :: destinations =>
    if selectorsEqual source destination then
      (unionBranchPairs rest destinations).map
        (fun pairs => (source.target, destination.target) :: pairs)
    else if disjointFromAll destination sources then
      unionBranchPairs sources destinations
    else none

private def ruleUChildPairs (source destination : UnionSpec) : List (TypeRef × TypeRef) :=
  (unionBranchPairs source.branches destination.branches).getD []

private theorem unionBranchPairs_self (branches : List UnionBranch) :
    unionBranchPairs branches branches =
      some (branches.map (fun branch => (branch.target, branch.target))) := by
  induction branches with
  | nil => rfl
  | cons branch rest ih =>
    have self : selectorsEqual branch branch = true := by
      cases selector : branch.selector <;>
        simp [selectorsEqual, selector]
    simp [unionBranchPairs, self, ih]

private def hasOtherwise (branches : List UnionBranch) : Bool :=
  branches.any (fun branch => branch.selector == .otherwise)

private def ruleUCoverage (source destination : UnionSpec) : Bool :=
  if hasOtherwise source.branches then decide (source = destination)
  else (unionBranchPairs source.branches destination.branches).isSome

private theorem mapped_union_selection (profile : VersionedSemanticProfile)
    (sources destinations : List UnionBranch) (pairs : List (TypeRef × TypeRef))
    (value : JsonValue) (branch : UnionBranch)
    (mapped : unionBranchPairs sources destinations = some pairs)
    (selected : selectUnionBranch profile { branches := sources } value = some branch) :
    ∃ target, selectUnionBranch profile { branches := destinations } value =
        some target ∧ (branch.target, target.target) ∈ pairs := by
  induction destinations generalizing sources pairs branch with
  | nil =>
    cases sources <;> simp [unionBranchPairs, selectUnionBranch] at mapped selected
  | cons destination destinations ih =>
    cases sources with
    | nil => simp [selectUnionBranch] at selected
    | cons source rest =>
      unfold unionBranchPairs at mapped
      split at mapped
      next same =>
        cases tail : unionBranchPairs rest destinations with
        | none => simp [tail] at mapped
        | some tailPairs =>
          simp [tail] at mapped
          subst pairs
          have sameMatches := selectorsEqual_matches profile source destination value same
          unfold selectUnionBranch at selected ⊢
          simp only [List.find?_cons]
          rw [← sameMatches]
          cases accepted : selectorMatches profile source value with
          | false =>
            simp [accepted] at selected ⊢
            obtain ⟨target, targetSelected, related⟩ :=
              ih rest tailPairs branch tail selected
            exact ⟨target, targetSelected, Or.inr related⟩
          | true =>
            simp [accepted] at selected ⊢
            subst branch
            exact Or.inl rfl
      next different =>
        split at mapped
        next disjoint =>
          have branchPresent : branch ∈ source :: rest := by
            exact List.mem_of_find?_eq_some selected
          have branchDisjoint := List.all_eq_true.mp disjoint branch branchPresent
          have branchAccepted : selectorMatches profile branch value = true := by
            change List.find? (fun candidate => selectorMatches profile candidate value)
              (source :: rest) = some branch at selected
            exact List.find?_some (p := fun candidate => selectorMatches profile candidate value)
              (l := source :: rest) selected
          have destinationRejected : selectorMatches profile destination value = false := by
            cases destinationAccepted : selectorMatches profile destination value
            · rfl
            · exact False.elim
                ((disjointSelector_sound profile destination branch value branchDisjoint)
                  ⟨destinationAccepted, branchAccepted⟩)
          obtain ⟨target, targetSelected, related⟩ :=
            ih (source :: rest) pairs branch mapped selected
          refine ⟨target, ?_, related⟩
          change List.find? (fun candidate => selectorMatches profile candidate value)
            destinations = some target at targetSelected
          change List.find? (fun candidate => selectorMatches profile candidate value)
            (destination :: destinations) = some target
          simp [destinationRejected, targetSelected]
        next overlapping => simp at mapped

private theorem ruleUCoverage_selection (profile : VersionedSemanticProfile)
    (source destination : UnionSpec) (value : JsonValue) (branch : UnionBranch)
    (coverage : ruleUCoverage source destination = true)
    (selected : selectUnionBranch profile source value = some branch) :
    ∃ target, selectUnionBranch profile destination value = some target ∧
      (branch.target, target.target) ∈ ruleUChildPairs source destination := by
  unfold ruleUCoverage at coverage
  split at coverage
  next otherwise =>
    have same : source = destination := of_decide_eq_true coverage
    subst destination
    refine ⟨branch, selected, ?_⟩
    have present : branch ∈ source.branches := List.mem_of_find?_eq_some selected
    unfold ruleUChildPairs
    rw [unionBranchPairs_self]
    simp only [Option.getD_some, List.mem_map]
    exact ⟨branch, present, rfl⟩
  next noOtherwise =>
    have mappedSome : (unionBranchPairs source.branches destination.branches).isSome = true := by
      simpa using coverage
    cases mapping : unionBranchPairs source.branches destination.branches with
    | none => simp [mapping] at mappedSome
    | some mappedPairs =>
      obtain ⟨target, targetSelected, related⟩ :=
        mapped_union_selection profile source.branches destination.branches mappedPairs
          value branch mapping selected
      exact ⟨target, targetSelected, by simpa [ruleUChildPairs, mapping] using related⟩

private theorem ruleU_sound (graph : SemanticGraph) (table : List PairEntry)
    (source destination : TypeRef) (snode dnode : TypeNode) (sspec dspec : UnionSpec)
    (slookup : graph.findType source = some snode) (dlookup : graph.findType destination = some dnode)
    (sshape : snode.shape = .taggedUnion sspec) (dshape : dnode.shape = .taggedUnion dspec)
    (coverage : ∀ value branch, selectUnionBranch graph.profile sspec value = some branch →
      ∃ target, selectUnionBranch graph.profile dspec value = some target ∧
        (branch.target, target.target) ∈ pairRefs table) :
    PairSimulation graph table source destination := by
  intro path value children expansion members mapped
  have sourceSelected :
      ∃ branch, selectUnionBranch graph.profile sspec value = some branch ∧
        children = [{ typeRef := branch.target, valuePath := path, value }] := by
    cases value with
    | null =>
      cases selected : selectUnionBranch graph.profile sspec .null with
      | none => simp [expandValue, expandNode, slookup, sshape, selected] at expansion
      | some branch =>
        exact ⟨branch, rfl, by
          simpa [expandValue, expandNode, slookup, sshape, selected] using expansion.symm⟩
    | bool current =>
      cases selected : selectUnionBranch graph.profile sspec (.bool current) with
      | none => simp [expandValue, expandNode, slookup, sshape, selected] at expansion
      | some branch =>
        exact ⟨branch, rfl, by
          simpa [expandValue, expandNode, slookup, sshape, selected] using expansion.symm⟩
    | num current =>
      cases selected : selectUnionBranch graph.profile sspec (.num current) with
      | none => simp [expandValue, expandNode, slookup, sshape, selected] at expansion
      | some branch =>
        exact ⟨branch, rfl, by
          simpa [expandValue, expandNode, slookup, sshape, selected] using expansion.symm⟩
    | dec current =>
      cases selected : selectUnionBranch graph.profile sspec (.dec current) with
      | none => simp [expandValue, expandNode, slookup, sshape, selected] at expansion
      | some branch =>
        exact ⟨branch, rfl, by
          simpa [expandValue, expandNode, slookup, sshape, selected] using expansion.symm⟩
    | str current =>
      cases selected : selectUnionBranch graph.profile sspec (.str current) with
      | none => simp [expandValue, expandNode, slookup, sshape, selected] at expansion
      | some branch =>
        exact ⟨branch, rfl, by
          simpa [expandValue, expandNode, slookup, sshape, selected] using expansion.symm⟩
    | arr current =>
      cases selected : selectUnionBranch graph.profile sspec (.arr current) with
      | none => simp [expandValue, expandNode, slookup, sshape, selected] at expansion
      | some branch =>
        exact ⟨branch, rfl, by
          simpa [expandValue, expandNode, slookup, sshape, selected] using expansion.symm⟩
    | obj entries =>
      cases prelude : objectMemberFailure graph.profile entries with
      | some failure =>
        simp [expandValue, expandNode, slookup, sshape, prelude] at expansion
      | none =>
        cases selected : selectUnionBranch graph.profile sspec (.obj entries) with
        | none =>
          simp [expandValue, expandNode, slookup, sshape, prelude, selected] at expansion
        | some branch =>
          exact ⟨branch, rfl, by
            simpa [expandValue, expandNode, slookup, sshape, prelude, selected]
              using expansion.symm⟩
  obtain ⟨branch, selected, identity⟩ := sourceSelected
  subst children
  obtain ⟨target, targetSelected, related⟩ := coverage value branch selected
  exact .step destination path value
    [{ typeRef := target.target, valuePath := path, value }] (by
      cases value with
      | obj entries =>
        have prelude : objectMemberFailure graph.profile entries = none := by
          cases found : objectMemberFailure graph.profile entries with
          | none => rfl
          | some failure =>
            simp [expandValue, expandNode, slookup, sshape, found] at expansion
        simp [expandValue, expandNode, dlookup, dshape, prelude, targetSelected]
      | null => simp [expandValue, expandNode, dlookup, dshape, targetSelected]
      | bool current => simp [expandValue, expandNode, dlookup, dshape, targetSelected]
      | num current => simp [expandValue, expandNode, dlookup, dshape, targetSelected]
      | dec current => simp [expandValue, expandNode, dlookup, dshape, targetSelected]
      | str current => simp [expandValue, expandNode, dlookup, dshape, targetSelected]
      | arr current => simp [expandValue, expandNode, dlookup, dshape, targetSelected])
    (by
      intro child present
      have same : child = { typeRef := target.target, valuePath := path, value } := by
        simpa using present
      subst child
      exact mapped { typeRef := branch.target, valuePath := path, value }
        (by simp) target.target related)


theorem ruleP_sound (graph : SemanticGraph) (table : List PairEntry)
    (source destination : TypeRef) (snode dnode : TypeNode) (sspec dspec : ProductSpec)
    (slookup : graph.findType source = some snode) (dlookup : graph.findType destination = some dnode)
    (sshape : snode.shape = .product sspec) (dshape : dnode.shape = .product dspec)
    (checked : productRuleCheck graph table sspec dspec = true) :
    PairSimulation graph table source destination := by
  intro path value children expansion members mapped
  cases value with
  | obj entries =>
    have sourceMember : ValueMember graph source path (.obj entries) :=
      .step source path (.obj entries) children expansion members
    have rootedSource := valueMember_path_irrelevant graph source path [] (.obj entries) sourceMember
    have sourceAccepted :=
      product_accepted_of_value graph source snode sspec slookup sshape entries rootedSource
    obtain ⟨duplicate, tag, classified, sourceFieldsAccepted, sourceExtrasAccepted⟩ :=
      sourceAccepted
    have sourceExtraCondition :=
      extraMembersFailure_of_extra_values graph sspec entries sourceExtrasAccepted
    have sourcePrelude : objectMemberFailure graph.profile entries = none := by
      simp [objectMemberFailure, duplicate, tag]
    cases sourceFieldExpansion :
        slotRequirements graph source path entries sspec.fields with
    | rejected failure =>
      simp [expandValue, expandNode, slookup, sshape, sourcePrelude, classified,
        sourceExtraCondition, productRequirements, sourceFieldExpansion] at expansion
    | unresolved obligations =>
      simp [expandValue, expandNode, slookup, sshape, sourcePrelude, classified,
        sourceExtraCondition, productRequirements, sourceFieldExpansion] at expansion
    | requirements sourceFieldChildren =>
      have childrenIdentity :
          children = sourceFieldChildren ++
            extraFieldRequirements graph path sspec entries := by
        simpa [expandValue, expandNode, slookup, sshape, sourcePrelude, classified,
          sourceExtraCondition, productRequirements, sourceFieldExpansion] using expansion.symm
      have mappedField (sourceField destinationField : FieldSpec)
          (sourceDeclared : sourceField ∈ sspec.fields)
          (sameName : sourceField.wireName = destinationField.wireName)
          (related :
            (sourceField.slot.typeRef, destinationField.slot.typeRef) ∈ pairRefs table)
          (actual : JsonValue)
          (found : memberValue destinationField.wireName entries = some actual)
          (notNull : actual ≠ .null) :
          ValueMember graph destinationField.slot.typeRef [] actual := by
        have sourceFound : memberValue sourceField.wireName entries = some actual := by
          simpa [sameName] using found
        let fieldChild : ValueRequirement := {
          typeRef := sourceField.slot.typeRef
          valuePath := path ++ [.field sourceField.wireName]
          value := actual }
        have fieldChildPresent : fieldChild ∈ sourceFieldChildren := by
          exact slotRequirements_contains_field graph source path entries sspec.fields
            sourceFieldChildren sourceFieldExpansion sourceField sourceDeclared actual
            sourceFound notNull
        have transported := mapped _ (by
          rw [childrenIdentity]
          exact List.mem_append_left _ fieldChildPresent) destinationField.slot.typeRef related
        exact valueMember_path_irrelevant graph _ _ [] _ transported
      simp only [productRuleCheck, Bool.and_eq_true] at checked
      obtain ⟨⟨destinationChecked, sourceChecked⟩, extrasChecked⟩ := checked
      have destinationFieldsAccepted :
          ∀ field ∈ dspec.fields, FieldValueAccepted graph field entries := by
        intro destinationField destinationDeclared
        have fieldCheck := List.all_eq_true.mp destinationChecked
          destinationField destinationDeclared
        cases sourceFound : fieldNamed sspec.fields destinationField.wireName with
        | none =>
          simp [sourceFound] at fieldCheck
          rcases fieldCheck with ⟨⟨optional, tagFree⟩, extraCheck⟩
          have sourceFieldFree :
              sspec.fields.any
                (fun field => field.wireName == destinationField.wireName) = false := by
            rw [List.any_eq_false]
            intro field declared
            unfold fieldNamed at sourceFound
            exact List.find?_eq_none.mp sourceFound field declared
          cases sourceExtras : sspec.extras with
          | reject => simp [sourceExtras] at extraCheck
          | allow keyFormat sourceContract =>
            simp only [sourceExtras, Bool.and_eq_true, decide_eq_true_eq] at extraCheck
            have nullIncluded :
                (sourceContract.nullable = false ∧
                  typeRejectsNull graph sourceContract.typeRef = true) ∨
                destinationField.slot.nullable = true := by
              simpa [Bool.and_eq_true, Bool.or_eq_true] using extraCheck.1
            have related :
                (sourceContract.typeRef, destinationField.slot.typeRef) ∈ pairRefs table :=
              extraCheck.2
            cases found : memberValue destinationField.wireName entries with
            | none => simpa [FieldValueAccepted, found] using optional
            | some actual =>
              have present :
                  (destinationField.wireName, actual) ∈ entries :=
                memberValue_mem entries destinationField.wireName actual found
              cases actual with
              | null =>
                have sourceExtra := sourceExtrasAccepted destinationField.wireName .null
                  present sourceFieldFree tagFree
                simp [ExtraValueAccepted, sourceExtras] at sourceExtra
                have destinationNullable : destinationField.slot.nullable = true := by
                  rcases nullIncluded with sourceRejects | destinationNullable
                  · rcases sourceExtra.2.2 with sourceNullable | sourceMember
                    · simp [sourceNullable] at sourceRejects
                    · exact False.elim
                        (typeRejectsNull_no_member graph sourceContract.typeRef
                          sourceRejects.2 sourceMember)
                  · exact destinationNullable
                simpa [FieldValueAccepted, found] using destinationNullable
              | bool actual | num actual | dec actual | str actual | arr actual | obj actual =>
                have required := extraFieldRequirements_contains graph path sspec entries
                  destinationField.wireName _ present sourceFieldFree tagFree
                  keyFormat sourceContract sourceExtras (by intro equal; contradiction)
                have transported := mapped _ (by
                  rw [childrenIdentity]
                  exact List.mem_append_right _ required)
                  destinationField.slot.typeRef related
                simpa [FieldValueAccepted, found] using
                  valueMember_path_irrelevant graph _ _ [] _ transported
        | some sourceField =>
          simp only [sourceFound, Bool.and_eq_true, decide_eq_true_eq] at fieldCheck
          have sourceDeclared : sourceField ∈ sspec.fields := by
            exact List.mem_of_find?_eq_some (by simpa [fieldNamed] using sourceFound)
          have sameName : sourceField.wireName = destinationField.wireName := by
            have named := List.find?_some (by simpa [fieldNamed] using sourceFound)
            simpa using beq_iff_eq.mp named
          have sourceFieldAccepted := sourceFieldsAccepted sourceField sourceDeclared
          cases found : memberValue destinationField.wireName entries with
          | none =>
            have sourceObserved : memberValue sourceField.wireName entries = none := by
              simpa [sameName] using found
            simp [FieldValueAccepted, sourceObserved] at sourceFieldAccepted
            simpa [FieldValueAccepted, found] using
              fieldCheck.1.1 sourceFieldAccepted
          | some actual =>
            cases actual with
            | null =>
              have sourceObserved :
                  memberValue sourceField.wireName entries = some .null := by
                simpa [sameName] using found
              simp [FieldValueAccepted, sourceObserved] at sourceFieldAccepted
              simpa [FieldValueAccepted, found] using
                fieldCheck.1.2 sourceFieldAccepted
            | bool actual | num actual | dec actual | str actual | arr actual | obj actual =>
              simpa [FieldValueAccepted, found] using
                mappedField sourceField destinationField sourceDeclared sameName fieldCheck.2 _
                  found (by intro equal; contradiction)
      have destinationExtrasAccepted :
          ∀ key value, (key, value) ∈ entries →
            dspec.fields.any (fun field => field.wireName == key) = false →
            (graph.profile.tag.map (fun tag => key == tag.key)).getD false = false →
            ExtraValueAccepted graph dspec key value := by
        intro key actual present destinationFieldFree tagFree
        cases sourceFound : fieldNamed sspec.fields key with
        | some sourceField =>
          have sourceDeclared : sourceField ∈ sspec.fields :=
            List.mem_of_find?_eq_some (by simpa [fieldNamed] using sourceFound)
          have sourceName : sourceField.wireName = key := by
            have named := List.find?_some (by simpa [fieldNamed] using sourceFound)
            exact beq_iff_eq.mp named
          have sourceFieldAccepted := sourceFieldsAccepted sourceField sourceDeclared
          have sourceRule := List.all_eq_true.mp sourceChecked sourceField sourceDeclared
          have destinationMissing : fieldNamed dspec.fields sourceField.wireName = none := by
            unfold fieldNamed
            apply List.find?_eq_none.mpr
            intro field fieldPresent
            rw [List.any_eq_false] at destinationFieldFree
            have different := destinationFieldFree field fieldPresent
            simpa [sourceName] using different
          rw [destinationMissing] at sourceRule
          have notTag :
              (graph.profile.tag.map
                (fun tag => sourceField.wireName == tag.key)).getD false = false := by
            simpa [sourceName] using tagFree
          simp [notTag] at sourceRule
          cases destinationExtras : dspec.extras with
          | reject => simp [destinationExtras] at sourceRule
          | allow keyFormat contract =>
            simp [destinationExtras, extraAllowsKey, Bool.and_eq_true,
              decide_eq_true_eq] at sourceRule
            have found : memberValue sourceField.wireName entries = some actual := by
              exact memberValue_of_mem_unique entries sourceField.wireName actual duplicate
                (by simpa [sourceName] using present)
            have destinationFound : memberValue key entries = some actual := by
              rw [← sourceName]
              exact found
            simp [FieldValueAccepted, found] at sourceFieldAccepted
            have keyAccepted :
                (keyFormat.map
                  (fun use => !formatUseAccepts graph.profile use key)).getD false = false := by
              cases keyFormat with
              | none => rfl
              | some use =>
                rw [← sourceName]
                simpa using sourceRule.1.1.2
            have nullableIncluded :
                sourceField.slot.nullable = true → contract.nullable = true := by
              intro sourceNullable
              rcases sourceRule.1.2 with sourceNonnullable | destinationNullable
              · rw [sourceNullable] at sourceNonnullable
                contradiction
              · exact destinationNullable
            simp only [ExtraValueAccepted, destinationExtras]
            refine ⟨(by rw [← sourceName]; exact sourceRule.1.1.1), keyAccepted, ?_⟩
            cases actual with
            | null => exact Or.inl (nullableIncluded sourceFieldAccepted)
            | bool actual | num actual | dec actual | str actual | arr actual | obj actual =>
              let destinationSlot : SlotContract := {
                typeRef := contract.typeRef
                required := false
                nullable := contract.nullable }
              let destinationField : FieldSpec := {
                wireName := key
                slot := destinationSlot
                origin := sourceField.origin }
              exact mappedField sourceField destinationField sourceDeclared sourceName
                sourceRule.2 _ destinationFound (by intro equal; contradiction)
        | none =>
          have sourceFieldFree :
              sspec.fields.any (fun field => field.wireName == key) = false := by
            rw [List.any_eq_false]
            intro field fieldPresent
            unfold fieldNamed at sourceFound
            exact List.find?_eq_none.mp sourceFound field fieldPresent
          have sourceExtra := sourceExtrasAccepted key actual present sourceFieldFree tagFree
          cases sourceExtras : sspec.extras with
          | reject => simp [ExtraValueAccepted, sourceExtras] at sourceExtra
          | allow sourceKey sourceContract =>
            cases destinationExtras : dspec.extras with
            | reject => simp [sourceExtras, destinationExtras] at extrasChecked
            | allow destinationKey destinationContract =>
              simp [sourceExtras, destinationExtras, Bool.and_eq_true,
                decide_eq_true_eq] at extrasChecked
              simp [ExtraValueAccepted, sourceExtras] at sourceExtra
              rcases sourceExtra with ⟨unicode, sourceKeyAccepted, sourceValue⟩
              simp only [ExtraValueAccepted, destinationExtras]
              have nullableIncluded :
                  sourceContract.nullable = true → destinationContract.nullable = true := by
                intro sourceNullable
                rcases extrasChecked.1.2 with sourceNonnullable | destinationNullable
                · rw [sourceNullable] at sourceNonnullable
                  contradiction
                · exact destinationNullable
              refine ⟨unicode,
                formatUseIncluded_sound graph.profile sourceKey destinationKey key
                  extrasChecked.1.1 sourceKeyAccepted, ?_⟩
              cases actual with
              | null =>
                cases sourceNullable : sourceContract.nullable
                · right
                  rcases sourceValue with impossible | sourceMember
                  · simp [sourceNullable] at impossible
                  · let sourceChild : ValueRequirement :=
                      { typeRef := sourceContract.typeRef,
                        valuePath := path ++ [.field key], value := .null }
                    have sourceElement : sourceChild ∈
                        elementRequirements sourceContract (path ++ [.field key]) .null := by
                      simp [sourceChild, elementRequirements, sourceNullable]
                    have required := extraFieldRequirements_contains_element graph path sspec entries
                      key .null present sourceFieldFree tagFree sourceKey sourceContract sourceExtras
                      sourceChild sourceElement
                    have transported := mapped _ (by
                      rw [childrenIdentity]
                      exact List.mem_append_right _ required)
                      destinationContract.typeRef extrasChecked.2
                    exact valueMember_path_irrelevant graph _ _ [] _ transported
                · exact Or.inl (nullableIncluded (by simpa using sourceNullable))
              | bool actual | num actual | dec actual | str actual | arr actual | obj actual =>
                have required := extraFieldRequirements_contains graph path sspec entries key _
                  present sourceFieldFree tagFree sourceKey sourceContract sourceExtras
                    (by simp)
                have transported := mapped _ (by
                  rw [childrenIdentity]
                  exact List.mem_append_right _ required)
                  destinationContract.typeRef extrasChecked.2
                exact valueMember_path_irrelevant graph _ _ [] _ transported
      have destinationAccepted : ProductValueAccepted graph dspec entries :=
        ⟨duplicate, tag, classified, destinationFieldsAccepted, destinationExtrasAccepted⟩
      exact valueMember_path_irrelevant graph destination [] path (.obj entries)
        (product_expansion_transport graph destination dnode dspec dlookup dshape entries
          destinationAccepted)
  | null => simp [expandValue, expandNode, slookup, sshape] at expansion
  | bool _ => simp [expandValue, expandNode, slookup, sshape] at expansion
  | num _ => simp [expandValue, expandNode, slookup, sshape] at expansion
  | dec _ => simp [expandValue, expandNode, slookup, sshape] at expansion
  | str _ => simp [expandValue, expandNode, slookup, sshape] at expansion
  | arr _ => simp [expandValue, expandNode, slookup, sshape] at expansion

private def EmptyExpansion (graph : SemanticGraph) (refs : List TypeRef) (ref : TypeRef) : Prop :=
  ∀ path value children, expandValue graph ref path value = .requirements children →
    ∃ child ∈ children, child.typeRef ∈ refs

structure CheckedEmptyTypes (graph : SemanticGraph) (refs : List TypeRef) : Type where
  expansion : ∀ ref ∈ refs, EmptyExpansion graph refs ref

theorem emptyTypesSound (graph : SemanticGraph) (refs : List TypeRef)
    (checked : CheckedEmptyTypes graph refs) (ref : TypeRef) (path : ValuePath) (value : JsonValue)
    (member : ValueMember graph ref path value) : ref ∉ refs := by
  induction member with
  | step ref path value children expansion members ih =>
    intro empty
    obtain ⟨child, present, emptyChild⟩ := checked.expansion ref empty path value children expansion
    exact ih child present emptyChild

private def natRangeEmpty (minimum maximum : Option Nat) : Bool :=
  match minimum, maximum with
  | some minimum, some maximum => maximum < minimum
  | _, _ => false

private theorem natRangeEmpty_sound (minimum maximum : Option Nat)
    (empty : natRangeEmpty minimum maximum = true) (value : Nat)
    (accepted : lengthAccepts minimum maximum value = true) : False := by
  cases minimum <;> cases maximum <;>
    simp_all [natRangeEmpty, lengthAccepts] <;> omega

private def integerRangeEmpty (profile : VersionedSemanticProfile) (spec : IntegerSpec) : Bool :=
  match integerLower profile spec, integerUpper profile spec with
  | some minimum, some maximum => maximum < minimum
  | _, _ => false

private theorem integerRangeEmpty_sound (profile : VersionedSemanticProfile) (spec : IntegerSpec)
    (empty : integerRangeEmpty profile spec = true) (value : Int)
    (accepted : integerCondition profile spec (.num value) = none) : False := by
  obtain ⟨hd, -, -, hmin, hmax⟩ :=
    (integerCondition_none_iff profile spec value).mp accepted
  unfold integerInDomain at hd
  cases binding : integerBinding profile spec.domain with
  | none => simp [binding] at hd
  | some domain =>
    simp only [binding] at hd
    cases parsed : integerValueForBinding domain (.num value) with
    | none =>
      rw [integerValueForBindingInRange_number] at hd
      simp [parsed] at hd
    | some actual =>
      have actualSame := integerValueForBinding_num_eq domain value actual parsed
      subst actual
      rw [integerValueForBindingInRange_number] at hd
      simp [parsed] at hd
      cases range : domain.range <;>
        cases hsm : spec.minimum <;> cases hsx : spec.maximum
      all_goals unfold integerRangeEmpty integerLower integerUpper at empty
      all_goals simp [binding, range, hsm, hsx] at empty
      all_goals simp [integerRangeAccepts, range] at hd
      all_goals simp [hsm] at hmin
      all_goals simp [hsx] at hmax
      all_goals try simp [Int.instMax, Int.instMin, maxOfLe, minOfLe] at empty
      all_goals repeat' split at empty
      all_goals omega

private theorem required_field_requirement (graph : SemanticGraph) (ref : TypeRef)
    (path : ValuePath) (entries : List (String × JsonValue)) (fields : List FieldSpec)
    (children : List ValueRequirement)
    (expansion : slotRequirements graph ref path entries fields = .requirements children)
    (field : FieldSpec) (declared : field ∈ fields)
    (required : field.slot.required = true) (nonnull : field.slot.nullable = false) :
    ∃ child ∈ children, child.typeRef = field.slot.typeRef := by
  induction fields generalizing children with
  | nil => simp at declared
  | cons first rest ih =>
    cases hv : memberValue first.wireName entries with
    | none =>
      have optional : first.slot.required = false := by
        cases h : first.slot.required
        · rfl
        · simp [slotRequirements, hv, h] at expansion
      have tail : slotRequirements graph ref path entries rest = .requirements children := by
        cases ht : slotRequirements graph ref path entries rest <;>
          simpa [slotRequirements, hv, optional, ht] using expansion
      rcases List.mem_cons.mp declared with equal | present
      · subst field
        simp [required] at optional
      · exact ih children tail present
    | some value =>
      cases value with
      | null =>
        have nullable : first.slot.nullable = true := by
          cases h : first.slot.nullable
          · simp [slotRequirements, hv, h] at expansion
          · rfl
        have tail : slotRequirements graph ref path entries rest = .requirements children := by
          cases ht : slotRequirements graph ref path entries rest <;>
            simpa [slotRequirements, hv, nullable, ht] using expansion
        rcases List.mem_cons.mp declared with equal | present
        · subst field
          simp [nonnull] at nullable
        · exact ih children tail present
      | bool b | num b | dec b | str b | arr b | obj b =>
        cases ht : slotRequirements graph ref path entries rest with
        | rejected failure => simp [slotRequirements, hv, ht] at expansion
        | unresolved obligations => simp [slotRequirements, hv, ht] at expansion
        | requirements tail =>
          have identity : children =
              { typeRef := first.slot.typeRef, valuePath := path ++ [.field first.wireName],
                value := (memberValue first.wireName entries).getD .null } :: tail := by
            simpa [slotRequirements, hv, ht] using expansion.symm
          subst children
          rcases List.mem_cons.mp declared with equal | present
          · subst field
            exact ⟨_, List.mem_cons_self, rfl⟩
          · obtain ⟨child, member, same⟩ := ih tail ht present
            exact ⟨child, List.mem_cons_of_mem _ member, same⟩

private theorem no_integer_expansion (graph : SemanticGraph) (ref : TypeRef) (node : TypeNode)
    (spec : IntegerSpec) (lookup : graph.findType ref = some node) (shape : node.shape = .integer spec)
    (rejected : ∀ value, integerCondition graph.profile spec value ≠ none) :
    EmptyExpansion graph refs ref := by
  intro path value children expansion
  cases condition : integerCondition graph.profile spec value with
  | none => exact False.elim (rejected value condition)
  | some reason => simp [expandValue, expandNode, lookup, shape, condition] at expansion

private theorem no_string_expansion (graph : SemanticGraph) (ref : TypeRef) (node : TypeNode)
    (spec : StringSpec) (lookup : graph.findType ref = some node) (shape : node.shape = .string spec)
    (wrapperNone : spec.wrapper = none)
    (rejected : ∀ value, stringCondition graph.profile spec value ≠ none) :
    EmptyExpansion graph refs ref := by
  intro path value children expansion
  cases value <;> try simp [expandValue, expandNode, lookup, shape,
    stringValueCondition, wrapperNone] at expansion
  case str value =>
    cases condition : stringCondition graph.profile spec value with
    | none => exact False.elim (rejected value condition)
    | some reason => simp [expandValue, expandNode, lookup, shape,
        stringValueCondition, wrapperNone, condition] at expansion

private theorem alias_empty_expansion (graph : SemanticGraph) (refs : List TypeRef) (ref : TypeRef)
    (node : TypeNode) (target : TypeRef) (text : String) (lookup : graph.findType ref = some node)
    (shape : node.shape = .alias target text) (childEmpty : target ∈ refs) :
    EmptyExpansion graph refs ref := by
  intro path value children expansion
  have identity : children = [{ typeRef := target, valuePath := path, value }] := by
    simpa [expandValue, expandNode, lookup, shape] using expansion.symm
  subst children
  exact ⟨_, List.mem_cons_self, childEmpty⟩

private theorem bytes_empty_expansion (graph : SemanticGraph) (refs : List TypeRef) (ref : TypeRef)
    (node : TypeNode) (spec : LengthSpec) (lookup : graph.findType ref = some node)
    (shape : node.shape = .bytes spec) (empty : natRangeEmpty spec.minimum spec.maximum = true) :
    EmptyExpansion graph refs ref := by
  intro path value children expansion
  cases decoded : bytesValueLength graph.profile value with
  | none => simp [expandValue, expandNode, lookup, shape, decoded] at expansion
  | some size =>
    have accepted : lengthAccepts spec.minimum spec.maximum size = true := by
      cases accepted : lengthAccepts spec.minimum spec.maximum size
      · simp [expandValue, expandNode, lookup, shape, decoded, accepted] at expansion
      · rfl
    exact False.elim (natRangeEmpty_sound _ _ empty _ accepted)

private theorem product_empty_expansion (graph : SemanticGraph) (refs : List TypeRef) (ref : TypeRef)
    (node : TypeNode) (spec : ProductSpec) (lookup : graph.findType ref = some node)
    (shape : node.shape = .product spec) (field : FieldSpec) (declared : field ∈ spec.fields)
    (required : field.slot.required = true) (nonnull : field.slot.nullable = false)
    (blocked : field.slot.typeRef ∈ refs) : EmptyExpansion graph refs ref := by
  intro path value children expansion
  cases value <;> try simp [expandValue, expandNode, lookup, shape] at expansion
  case obj entries =>
    repeat' (first | contradiction | split at expansion)
    all_goals try simp_all only [reduceCtorEq]
    unfold productRequirements at expansion
    cases fieldsExpansion : slotRequirements graph ref path entries spec.fields with
    | rejected failure => simp [fieldsExpansion] at expansion
    | unresolved obligations => simp [fieldsExpansion] at expansion
    | requirements fields =>
      have identity :
          children = fields ++ extraFieldRequirements graph path spec entries := by
        simpa [fieldsExpansion] using expansion.symm
      subst children
      obtain ⟨child, present, same⟩ := required_field_requirement graph ref path entries spec.fields
        fields fieldsExpansion field declared required nonnull
      exact ⟨child, List.mem_append_left _ present, by simpa [same] using blocked⟩

private theorem array_range_empty_expansion (graph : SemanticGraph) (refs : List TypeRef) (ref : TypeRef)
    (node : TypeNode) (spec : ArraySpec) (lookup : graph.findType ref = some node)
    (shape : node.shape = .array spec) (empty : natRangeEmpty spec.minLength spec.maxLength = true) :
    EmptyExpansion graph refs ref := by
  intro path value children expansion
  cases value <;> try simp [expandValue, expandNode, lookup, shape] at expansion
  case arr items =>
    have accepted : lengthAccepts spec.minLength spec.maxLength items.length = true := by
      cases accepted : lengthAccepts spec.minLength spec.maxLength items.length
      · simp [expandValue, expandNode, lookup, shape, accepted] at expansion
      · rfl
    exact False.elim (natRangeEmpty_sound _ _ empty _ accepted)

private theorem array_minimum_empty_expansion (graph : SemanticGraph) (refs : List TypeRef) (ref : TypeRef)
    (node : TypeNode) (spec : ArraySpec) (lookup : graph.findType ref = some node)
    (shape : node.shape = .array spec)
    (blocked : 0 < spec.minLength.getD 0 ∧ spec.item.nullable = false ∧ spec.item.typeRef ∈ refs) :
    EmptyExpansion graph refs ref := by
  intro path value children expansion
  cases value <;> try simp [expandValue, expandNode, lookup, shape] at expansion
  case arr items =>
    have accepted : lengthAccepts spec.minLength spec.maxLength items.length = true := by
      cases accepted : lengthAccepts spec.minLength spec.maxLength items.length
      · simp [expandValue, expandNode, lookup, shape, accepted] at expansion
      · rfl
    have nonempty : items ≠ [] := by
      intro same
      subst items
      have bound := lengthAccepts_minimum _ _ _ accepted
      have lower := blocked.1
      simp only [List.length_nil] at bound
      omega
    cases items with
    | nil => exact False.elim (nonempty rfl)
    | cons first rest =>
      have accepted' : lengthAccepts spec.minLength spec.maxLength (rest.length + 1) = true := by
        simpa using accepted
      have identity : children =
          (first :: rest).zipIdx.flatMap (fun (item, index) =>
            elementRequirements spec.item (path ++ [.index index]) item) := by
        simpa [expandValue, expandNode, lookup, shape, accepted'] using expansion.symm
      subst children
      let child : ValueRequirement :=
        { typeRef := spec.item.typeRef, valuePath := path ++ [.index 0], value := first }
      refine ⟨child, ?_, blocked.2.2⟩
      cases first <;> simp [child, elementRequirements, blocked.2.1]

private theorem union_empty_expansion (graph : SemanticGraph) (refs : List TypeRef) (ref : TypeRef)
    (node : TypeNode) (spec : UnionSpec) (lookup : graph.findType ref = some node)
    (shape : node.shape = .taggedUnion spec)
    (blocked : ∀ branch ∈ spec.branches, branch.target ∈ refs) : EmptyExpansion graph refs ref := by
  intro path value children expansion
  have sourceSelected :
      ∃ branch, selectUnionBranch graph.profile spec value = some branch ∧
        children = [{ typeRef := branch.target, valuePath := path, value }] := by
    cases value with
    | null =>
      cases selected : selectUnionBranch graph.profile spec .null with
      | none => simp [expandValue, expandNode, lookup, shape, selected] at expansion
      | some branch =>
        exact ⟨branch, rfl, by
          simpa [expandValue, expandNode, lookup, shape, selected] using expansion.symm⟩
    | bool current =>
      cases selected : selectUnionBranch graph.profile spec (.bool current) with
      | none => simp [expandValue, expandNode, lookup, shape, selected] at expansion
      | some branch =>
        exact ⟨branch, rfl, by
          simpa [expandValue, expandNode, lookup, shape, selected] using expansion.symm⟩
    | num current =>
      cases selected : selectUnionBranch graph.profile spec (.num current) with
      | none => simp [expandValue, expandNode, lookup, shape, selected] at expansion
      | some branch =>
        exact ⟨branch, rfl, by
          simpa [expandValue, expandNode, lookup, shape, selected] using expansion.symm⟩
    | dec current =>
      cases selected : selectUnionBranch graph.profile spec (.dec current) with
      | none => simp [expandValue, expandNode, lookup, shape, selected] at expansion
      | some branch =>
        exact ⟨branch, rfl, by
          simpa [expandValue, expandNode, lookup, shape, selected] using expansion.symm⟩
    | str current =>
      cases selected : selectUnionBranch graph.profile spec (.str current) with
      | none => simp [expandValue, expandNode, lookup, shape, selected] at expansion
      | some branch =>
        exact ⟨branch, rfl, by
          simpa [expandValue, expandNode, lookup, shape, selected] using expansion.symm⟩
    | arr current =>
      cases selected : selectUnionBranch graph.profile spec (.arr current) with
      | none => simp [expandValue, expandNode, lookup, shape, selected] at expansion
      | some branch =>
        exact ⟨branch, rfl, by
          simpa [expandValue, expandNode, lookup, shape, selected] using expansion.symm⟩
    | obj entries =>
      cases prelude : objectMemberFailure graph.profile entries with
      | some failure =>
        simp [expandValue, expandNode, lookup, shape, prelude] at expansion
      | none =>
        cases selected : selectUnionBranch graph.profile spec (.obj entries) with
        | none => simp [expandValue, expandNode, lookup, shape, prelude, selected] at expansion
        | some branch =>
          exact ⟨branch, rfl, by
            simpa [expandValue, expandNode, lookup, shape, prelude, selected]
              using expansion.symm⟩
  obtain ⟨branch, selected, identity⟩ := sourceSelected
  subst children
  have declared : branch ∈ spec.branches := by
    unfold selectUnionBranch at selected
    exact List.mem_of_find?_eq_some selected
  exact ⟨_, List.mem_cons_self, blocked branch declared⟩


private def checkEmptyRow (graph : SemanticGraph) (refs : List TypeRef) (ref : TypeRef) :
    Except InclusionFailure { proof : Unit // EmptyExpansion graph refs ref } := do
  let found ← resolveOption (graph.findType ref) InclusionFailure.forgedEmptiness
  match shape : found.val.shape with
  | .alias target text =>
    if childEmpty : target ∈ refs then
      pure ⟨(), alias_empty_expansion graph refs ref found.val target text found.property shape childEmpty⟩
    else throw .forgedEmptiness
  | .integer _ => throw .forgedEmptiness
  | .string spec =>
    match wrapperNone : spec.wrapper with
    | some _ => throw .forgedEmptiness
    | none =>
      match finite : stringFinite spec with
      | some values =>
        if rejected : values.all (fun value => stringCondition graph.profile spec value != none) = true then
          pure ⟨(), no_string_expansion graph ref found.val spec found.property shape wrapperNone (by
            intro value accepted
            have present := string_finite_member graph.profile spec values finite value accepted
            have impossible := (List.all_eq_true.mp rejected) value present
            simp [accepted] at impossible <;> exact absurd impossible (by decide))⟩
        else throw .forgedEmptiness
      | none => throw .forgedEmptiness
  | .bytes spec =>
    if empty : natRangeEmpty spec.minimum spec.maximum = true then
      pure ⟨(), bytes_empty_expansion graph refs ref found.val spec found.property shape empty⟩
    else throw .forgedEmptiness
  | .product spec =>
    let blocked ← resolveOption (spec.fields.find? (fun field => decide
      (field.slot.required = true ∧ field.slot.nullable = false ∧ field.slot.typeRef ∈ refs)))
      InclusionFailure.forgedEmptiness
    have field := find_sound spec.fields _ blocked.val blocked.property
    have conditions := of_decide_eq_true field.2
    pure ⟨(), product_empty_expansion graph refs ref found.val spec found.property shape blocked.val field.1
      conditions.1 conditions.2.1 conditions.2.2⟩
  | .array spec =>
    if empty : natRangeEmpty spec.minLength spec.maxLength = true then
      pure ⟨(), array_range_empty_expansion graph refs ref found.val spec found.property shape empty⟩
    else if blocked : 0 < spec.minLength.getD 0 ∧
        spec.item.nullable = false ∧ spec.item.typeRef ∈ refs then
      pure ⟨(), array_minimum_empty_expansion graph refs ref found.val spec found.property shape blocked⟩
    else throw .forgedEmptiness
  | .taggedUnion spec =>
    if blocked : ∀ branch ∈ spec.branches, branch.target ∈ refs then
      pure ⟨(), union_empty_expansion graph refs ref found.val spec found.property shape blocked⟩
    else throw .forgedEmptiness
  | _ => throw .forgedEmptiness

def verifyEmptyTypes (graph : SemanticGraph) (refs : List TypeRef) :
    Except InclusionFailure (CheckedEmptyTypes graph refs) := do
  if unique : refs.Nodup then
    let rec checkRows (remaining : List TypeRef) :
        Except InclusionFailure { proof : Unit // ∀ ref ∈ remaining, EmptyExpansion graph refs ref } :=
      match remaining with
      | [] => .ok ⟨(), by simp⟩
      | ref :: rest => do
        let checked ← checkEmptyRow graph refs ref
        let later ← checkRows rest
        pure ⟨(), by
          intro actual present
          rcases List.mem_cons.mp present with same | remaining
          · subst actual; exact checked.property
          · exact later.property actual remaining⟩
    let checked ← checkRows refs
    pure { expansion := checked.property }
  else throw .forgedEmptiness

private def pruneEmptyTypes (graph : SemanticGraph) : Nat → List TypeRef → List TypeRef
  | 0, refs => refs
  | fuel + 1, refs =>
    let retained := refs.filter (fun ref => match checkEmptyRow graph refs ref with
      | .ok _ => true | .error _ => false)
    if retained.length = refs.length then retained else pruneEmptyTypes graph fuel retained

def emptyTypes (graph : SemanticGraph) : List TypeRef :=
  pruneEmptyTypes graph (graph.nodes.length + 1) (distinct (graph.nodes.map (·.ref)))

private def checkPairFuel (graph : SemanticGraph) (emptyRefs : List TypeRef)
    (empty : CheckedEmptyTypes graph emptyRefs) (table : List PairEntry) :
    Nat → (entry : PairEntry) → Except InclusionFailure
      { proof : Unit // PairSimulation graph table entry.pair.source.typeRef entry.pair.destination.typeRef }
  | 0, entry => .error (.unresolved { pair := entry.pair, path := [], reason := .obligationBoundExhausted })
  | fuel + 1, entry => do
    let source := entry.pair.source.typeRef
    let destination := entry.pair.destination.typeRef
    let sourceNode ← resolveOption (graph.findType source) (.pairMismatch 0)
    let destinationNode ← resolveOption (graph.findType destination) (.pairMismatch 0)
    let snode := sourceNode.val
    let dnode := destinationNode.val
    if entry.sourceShape != snode.shape || entry.destinationShape != dnode.shape ||
        entry.pair.sourceTag.isSome then throw (.pairMismatch 0)
    if vacuous : source ∈ emptyRefs then
      if entry.rule != .emptySource then throw (.ruleMismatch 0)
      let _ ← checkChildCoverage table entry []
      pure ⟨(), by
        intro path value children expansion members mapped
        exact False.elim (emptyTypesSound graph emptyRefs empty source path value
          (.step source path value children expansion members) vacuous)⟩
    else if same : snode.shape = dnode.shape then
      if entry.rule != .sameDefinedType then throw (.ruleMismatch 0)
      let _ ← checkChildCoverage table entry []
      pure ⟨(), same_shape_pair_simulation graph table source destination snode dnode
        sourceNode.property destinationNode.property same⟩
    else
      match sshape : snode.shape, dshape : dnode.shape with
      | .alias target text, _ =>
        if entry.rule != .unfoldSource then throw (.ruleMismatch 0)
        let children ← checkChildCoverage table entry [(target, destination)]
        pure ⟨(), alias_source_pair_simulation graph table source destination target snode text
          sourceNode.property sshape (children.present _ (by simp))⟩
      | _, .alias target text =>
        if entry.rule != .unfoldDestination then throw (.ruleMismatch 0)
        let _ ← checkChildCoverage table entry [(source, target)]
        let childFound ← resolveOption (table.find? (fun item => decide
          (item.pair.source.typeRef = source ∧ item.pair.destination.typeRef = target))) InclusionFailure.missingPair
        let child := childFound.val
        let inner ← checkPairFuel graph emptyRefs empty table fuel child
        have childIdentity : child.pair.source.typeRef = source ∧ child.pair.destination.typeRef = target :=
          of_decide_eq_true (find_sound table _ child childFound.property).2
        pure ⟨(), alias_destination_pair_simulation graph table source destination target dnode text
          destinationNode.property dshape (by simpa [childIdentity.1, childIdentity.2] using inner.property)⟩
      | .boolean sspec, .boolean dspec =>
        if entry.rule != .boolean then throw (.ruleMismatch 0)
        let _ ← checkChildCoverage table entry []
        if included : dspec.constValue = none ∨ sspec.constValue = dspec.constValue then
          pure ⟨(), boolean_pair_simulation graph table source destination snode dnode sspec dspec
            sourceNode.property destinationNode.property sshape dshape included⟩
        else throw (.unresolved { pair := entry.pair, path := [], reason := .constraintImplication })
      | .integer sspec, .integer dspec =>
        if entry.rule != .integerIntersection then throw (.ruleMismatch 0)
        let _ ← checkChildCoverage table entry []
        if included : integerRuleCheck graph sspec dspec = true then
          pure ⟨(), integer_pair_simulation graph table source destination snode dnode sspec dspec
            sourceNode.property destinationNode.property sshape dshape included⟩
        else throw (.unresolved { pair := entry.pair, path := [], reason := .constraintImplication })
      | .string sspec, .string dspec =>
        if entry.rule != .stringConditions && entry.rule != .finiteStrings then throw (.ruleMismatch 0)
        let _ ← checkChildCoverage table entry []
        if included : stringRuleCheck graph sspec dspec = true then
          pure ⟨(), string_pair_simulation graph table source destination snode dnode sspec dspec
            sourceNode.property destinationNode.property sshape dshape included⟩
        else throw (.unresolved { pair := entry.pair, path := [], reason := .constraintImplication })
      | .array sspec, .array dspec =>
        if entry.rule != .array then throw (.ruleMismatch 0)
        let children ← checkChildCoverage table entry
          [(sspec.item.typeRef, dspec.item.typeRef)]
        if lower : lowerContainedNat sspec.minLength dspec.minLength = true then
          if upper : upperContainedNat sspec.maxLength dspec.maxLength = true then
            if nullable : (!sspec.item.nullable || dspec.item.nullable) = true then
              pure ⟨(), array_pair_simulation graph table source destination snode dnode sspec dspec
                sourceNode.property destinationNode.property sshape dshape lower upper nullable
                  (children.present _ (by simp))⟩
            else throw (.unresolved { pair := entry.pair, path := [], reason := .constraintImplication })
          else throw (.unresolved { pair := entry.pair, path := [], reason := .constraintImplication })
        else throw (.unresolved { pair := entry.pair, path := [], reason := .constraintImplication })
      | .product sspec, .product dspec =>
        if entry.rule != .product then throw (.ruleMismatch 0)
        let _ ← checkChildCoverage table entry (productFieldPairs graph sspec dspec)
        if included : productRuleCheck graph table sspec dspec = true then
          pure ⟨(), ruleP_sound graph table source destination snode dnode sspec dspec
            sourceNode.property destinationNode.property sshape dshape included⟩
        else throw (.unresolved {
          pair := entry.pair, path := [], reason := .extraField "product rule P" })
      | .bytes _, .bytes _ =>
        throw (.unresolved { pair := entry.pair, path := [], reason := .constraintImplication })
      | .taggedUnion sspec, .taggedUnion dspec =>
        if entry.rule != .sourceUnion then throw (.ruleMismatch 0)
        let children ← checkChildCoverage table entry (ruleUChildPairs sspec dspec)
        if coverageCheck : ruleUCoverage sspec dspec = true then
          have coverage : ∀ value branch,
              selectUnionBranch graph.profile sspec value = some branch →
              ∃ target, selectUnionBranch graph.profile dspec value = some target ∧
                (branch.target, target.target) ∈ pairRefs table := by
            intro value branch selected
            obtain ⟨target, targetSelected, related⟩ :=
              ruleUCoverage_selection graph.profile sspec dspec value branch coverageCheck selected
            exact ⟨target, targetSelected, children.present _ related⟩
          pure ⟨(), ruleU_sound graph table source destination snode dnode sspec dspec
            sourceNode.property destinationNode.property sshape dshape coverage⟩
        else throw (.unresolved { pair := entry.pair, path := [], reason := .unionRemainder })
      | _, _ => throw (.unresolved { pair := entry.pair, path := [], reason := .constraintImplication })

private def checkPairTable (graph : SemanticGraph) (emptyRefs : List TypeRef)
    (empty : CheckedEmptyTypes graph emptyRefs) (table : List PairEntry) :
    Except InclusionFailure (CheckedPairTable graph table) :=
  let rec checkRows (rows : List PairEntry) :
      Except InclusionFailure { proof : Unit // ∀ row ∈ rows, PairSimulation graph table
        row.pair.source.typeRef row.pair.destination.typeRef } :=
    match rows with
    | [] => .ok ⟨(), by simp⟩
    | row :: rest =>
      match checkPairFuel graph emptyRefs empty table (graph.nodes.length + 1) row with
      | .error failure => .error failure
      | .ok checked =>
        match checkRows rest with
        | .error failure => .error failure
        | .ok later => .ok ⟨(), by
            intro entry present
            rcases List.mem_cons.mp present with same | remaining
            · subst entry; exact checked.property
            · exact later.property entry remaining⟩
  match checkRows table with
  | .error failure => .error failure
  | .ok checked => .ok { simulation := checked.property }

def verifyInclusion (graph : SemanticGraph) (source destination : SlotContract)
    (certificate : InclusionCertificate) :
    Except InclusionFailure (CheckedInclusion graph source destination) :=
  let rootMatches := match certificate.pairs[certificate.root]? with
    | none => false
    | some entry => entry.pair.source.typeRef == source.typeRef &&
        entry.pair.destination.typeRef == destination.typeRef && entry.pair.sourceTag.isNone
  if certificate.basis != SemanticBasis.of graph ||
      certificate.source != source || certificate.destination != destination || !rootMatches then
    .error .basisMismatch
  else
    match sm : meaningObligations graph [source.typeRef], dm : meaningObligations graph [destination.typeRef] with
    | [], [] =>
      if presence : PresenceIncluded source destination then
        if related : (source.typeRef, destination.typeRef) ∈ pairRefs certificate.pairs then
          match verifyEmptyTypes graph certificate.emptyTypes with
          | .error failure => .error failure
          | .ok empty =>
            match checkPairTable graph certificate.emptyTypes empty certificate.pairs with
            | .error failure => .error failure
            | .ok table => .ok
              { certificate, sourceMeaning := sm, destinationMeaning := dm, presence
                values := fun path value member => pairTable_member_sound graph certificate.pairs
                  table source.typeRef path value member destination.typeRef related }
        else .error .missingPair
      else .error (.unresolved { pair := { source, destination }, path := [], reason := .presence })
    | sourceReasons, destinationReasons => .error (.undefinedMeaning (sourceReasons ++ destinationReasons))

private def describePair (graph : SemanticGraph) (emptyRefs : List TypeRef) (source destination : TypeRef) :
    Except TypeObligation (PairEntry × List (TypeRef × TypeRef)) := do
  let pair : TypePair := { source := presentContract source, destination := presentContract destination }
  let some snode := graph.findType source |
    throw { pair, path := [], reason := .meaning (meaningObligations graph [source]) }
  let some dnode := graph.findType destination |
    throw { pair, path := [], reason := .meaning (meaningObligations graph [destination]) }
  let row := fun rule => ({
    pair, sourceShape := snode.shape, destinationShape := dnode.shape,
    rule, children := [] } : PairEntry)
  if source ∈ emptyRefs then pure (row .emptySource, [])
  else if snode.shape == dnode.shape then pure (row .sameDefinedType, [])
  else match snode.shape, dnode.shape with
    | .alias target _, _ => pure (row .unfoldSource, [(target, destination)])
    | _, .alias target _ => pure (row .unfoldDestination, [(source, target)])
    | .boolean source, .boolean destination =>
      if destination.constValue.isNone || source.constValue == destination.constValue then
        pure (row .boolean, [])
      else throw { pair, path := [], reason := .constraintImplication }
    | .integer source, .integer destination =>
      if integerRuleCheck graph source destination then pure (row .integerIntersection, [])
      else throw { pair, path := [], reason := .constraintImplication }
    | .string source, .string destination =>
      if stringRuleCheck graph source destination then pure (row .stringConditions, [])
      else throw { pair, path := [], reason := .constraintImplication }
    | .array source, .array destination =>
      if lowerContainedNat source.minLength destination.minLength &&
          upperContainedNat source.maxLength destination.maxLength &&
          (!source.item.nullable || destination.item.nullable) then
        pure (row .array, [(source.item.typeRef, destination.item.typeRef)])
      else throw { pair, path := [], reason := .constraintImplication }
    | .product source, .product destination =>
      if productRuleShapeCheck graph source destination then
        pure (row .product, productFieldPairs graph source destination)
      else throw { pair, path := [], reason := .presence }
    | .bytes _, .bytes _ =>
      throw { pair, path := [], reason := .constraintImplication }
    | .taggedUnion source, .taggedUnion destination =>
      if ruleUCoverage source destination then pure (row .sourceUnion, ruleUChildPairs source destination)
      else throw { pair, path := [], reason := .unionRemainder }
    | _, _ => throw { pair, path := [], reason := .constraintImplication }

private def inclusionTable (graph : SemanticGraph) (emptyRefs : List TypeRef) :
    Nat → List (TypeRef × TypeRef) → List (TypeRef × TypeRef) →
      List (PairEntry × List (TypeRef × TypeRef)) → Except TypeObligation (List PairEntry)
  | 0, [], _, rows =>
    let refs := rows.map (fun (entry, _) => (entry.pair.source.typeRef, entry.pair.destination.typeRef))
    .ok (rows.map (fun (entry, children) => { entry with children := children.map (fun child => listIndex child refs) }))
  | 0, (source, destination) :: _, _, _ =>
    .error {
      pair := { source := presentContract source, destination := presentContract destination },
      path := [], reason := .obligationBoundExhausted }
  | fuel + 1, [], seen, rows => inclusionTable graph emptyRefs 0 [] seen rows
  | fuel + 1, pair :: pending, seen, rows =>
    if pair ∈ seen then inclusionTable graph emptyRefs fuel pending seen rows
    else do
      let described ← describePair graph emptyRefs pair.1 pair.2
      inclusionTable graph emptyRefs fuel (described.2 ++ pending) (pair :: seen) (rows ++ [described])

structure CheckedCounterexample (graph : SemanticGraph) (source destination : SlotContract) where
  certificate : CounterexampleCertificate
  sourceMember : Slots graph source certificate.value
  destinationRejected : ¬ SlotMember graph destination certificate.value

inductive CompatibilityDecision (graph : SemanticGraph) (source destination : SlotContract) where
  | compatible (checked : CheckedInclusion graph source destination)
  | incompatible (checked : CheckedCounterexample graph source destination)
  | unknown (obligations : List TypeObligation)

private def structuralAssignable (graph : SemanticGraph) (emptyRefs : List TypeRef)
    (source destination : SlotContract) (maxObligations : Nat) : CompatibilityDecision graph source destination :=
  match inclusionTable graph emptyRefs maxObligations [(source.typeRef, destination.typeRef)] [] [] with
  | .error obligation => .unknown [obligation]
  | .ok pairs =>
    let certificate : InclusionCertificate :=
      { basis := SemanticBasis.of graph, source, destination, emptyTypes := emptyRefs, pairs, root := 0 }
    match verifyInclusion graph source destination certificate with
    | .ok checked => .compatible checked
    | .error (.undefinedMeaning obligations) =>
      .unknown [{ pair := { source, destination }, path := [], reason := .meaning obligations }]
    | .error (.unresolved obligation) => .unknown [obligation]
    | .error _ => .unknown [{ pair := { source, destination }, path := [], reason := .constraintImplication }]

private def resolvedShapeFuel (graph : SemanticGraph) : Nat → TypeRef → Option TypeShape
  | 0, _ => none
  | fuel + 1, reference => do
    let node ← graph.findType reference
    match node.shape with
    | .alias target _ => resolvedShapeFuel graph fuel target
    | shape => some shape

private def resolvedShape (graph : SemanticGraph) (reference : TypeRef) : Option TypeShape :=
  resolvedShapeFuel graph (graph.nodes.length + 1) reference

private structure LotDeclaration where
  tokenType : TypeRef
  producer : ResourceProducer
  revision : Nat
  quantity : Nat
  provenance : String
  deriving Repr, DecidableEq

private def declaredLot (input : CompositionInput) : ResourceLotRef → Option LotDeclaration
  | .initial id => do
    let lot ← input.initialResources.find? (fun lot => lot.id == id)
    pure {
      tokenType := lot.tokenType, producer := lot.producer, revision := lot.revision,
      quantity := lot.quantity, provenance := lot.provenance }
  | .produced site outcome production => do
    let function ← siteSignature input site
    let branch ← function.outcomes.find? (fun candidate => candidate.id == outcome)
    let production ← branch.producedResources.find? (fun candidate => candidate.id == production)
    pure {
      tokenType := production.tokenType, producer := .invocationOutcome site outcome,
      revision := production.revision, quantity := production.quantity, provenance := production.provenance }

private def uniqueIds (kind : String) (identities : List String) :
    Except CompositionInputFailure Unit :=
  let rec go (seen : List String) : List String → Except CompositionInputFailure Unit
    | [] => .ok ()
    | identity :: rest =>
      if identity == "" || seen.contains identity then .error (.duplicateIdentity kind identity)
      else go (identity :: seen) rest
  go [] identities

private def checkType (graph : SemanticGraph) (reference : TypeRef) :
    Except CompositionInputFailure Unit :=
  if (graph.findType reference).isSome then .ok () else .error (.unresolvedType reference)

private def constraintPathDefined (graph : SemanticGraph) (contract : SlotContract) (path : ValuePath) : Bool :=
  let assumptions := (path.zipIdx).filterMap fun (step, index) =>
    match step with
    | .variant tag => some (ProjectionAssumption.variant (path.take index) tag)
    | _ => none
  (projectSlot graph contract path assumptions).isOk

private def sourceConstraintDefined (graph : SemanticGraph) (input : CompositionInput) : SourceConstraint → Bool
  | .anyCompatible => true
  | .initialOnly id path =>
    ((declaredValue input (.initial id)).map (fun contract =>
      constraintPathDefined graph contract.1 path)).getD false
  | .producedBy site outcome port path =>
    ((declaredValue input (.invocationOutcome site outcome port)).map (fun contract =>
      constraintPathDefined graph contract.1 path)).getD false

private def failureOriginDefined (input : CompositionInput) : FailureOrigin → Bool
  | .function reference outcome =>
    ((signature input reference).map fun function =>
      function.outcomes.any (fun branch => branch.id == outcome && branch.form == .declaredFailure)).getD false
  | .guard id _ => input.invocationDomain.guards.any (fun declaration => declaration.id == id)

private def constructionReachable (rules : List ConstructionRule) :
    Nat → List String → List String → List String
  | 0, _, seen => seen
  | _ + 1, [], seen => seen
  | fuel + 1, identity :: pending, seen =>
    if seen.contains identity then constructionReachable rules fuel pending seen
    else
      let children := ((rules.find? (fun rule => rule.identity == identity)).map
        (fun rule => rule.nestedFields.map (·.2))).getD []
      constructionReachable rules fuel (children ++ pending) (identity :: seen)

private def validateCompositionInput (graph : SemanticGraph) (input : CompositionInput)
    (operationChecker : FunctionSignature → DefinitionRef → Except CompositionInputFailure Unit) :
    Except CompositionInputFailure Unit := do
  if input.basis != SemanticBasis.of graph then throw .basisMismatch
  uniqueIds "input" (input.initialInputs.map (·.id.value))
  uniqueIds "site" (input.invocationDomain.sites.map (·.id.value))
  uniqueIds "lot" (input.initialResources.map (·.id.value))
  uniqueIds "goal" (input.goal.outputs.map (·.id.value))
  uniqueIds "failure embedding" (input.goal.failures.map (·.id.value))
  uniqueIds "function" (input.signatures.map (fun function => functionIdentity function.reference))
  uniqueIds "guard" (input.invocationDomain.guards.map (·.id.value))
  for function in input.signatures do
    let invalid := CompositionInputFailure.invalidSignature function.reference
    if function.reference.identity == "" || function.reference.revision == "" ||
        function.reference.contentDigest == "" || function.assumptionRef == "" ||
        function.outcomes.isEmpty then throw (invalid "identity, revision, digest, assumptions, or outcomes")
    uniqueIds "input port" (function.inputs.map (·.id.value))
    uniqueIds "outcome" (function.outcomes.map (·.id.value))
    uniqueIds "resource requirement" (function.resourceInputs.map (·.id.value))
    match function.form with
    | .pure | .declaredTransform =>
      if function.effect != .pureFunction then throw (invalid "pure function effect")
    | .operation reference => operationChecker function reference
    for port in function.inputs do
      checkType graph port.contract.typeRef
      if !sourceConstraintDefined graph input port.sourceConstraint then throw (invalid "input source constraint")
      if (port.resourceRequirement.map (fun requirement =>
          !function.resourceInputs.any (fun declared => declared.id == requirement))).getD false then
        throw (invalid "input resource requirement")
    for requirement in function.resourceInputs do
      checkType graph requirement.tokenType
      if requirement.multiplicity == 0 then throw (invalid "zero resource multiplicity")
    for outcome in function.outcomes do
      uniqueIds "output port" (outcome.valuePorts.map (·.id.value))
      uniqueIds "resource production" (outcome.producedResources.map (·.id.value))
      for port in outcome.valuePorts do
        checkType graph port.contract.typeRef
        if (port.resourceProduction.map (fun production =>
            !outcome.producedResources.any (fun declared => declared.id == production))).getD false then
          throw (invalid "output resource production")
      for production in outcome.producedResources do checkType graph production.tokenType
    if (function.handlesFailure.map (fun origin => !failureOriginDefined input origin)).getD false then
      throw (invalid "failure handler origin")
  for site in input.invocationDomain.sites do
    let some function := signature input site.function | throw (.unresolvedFunction site.function)
    if !input.allowedEffects.contains function.effect then
      throw (.invalidInvocationDomain "site effect is not permitted")
    if function.form == .declaredTransform && !input.invocationDomain.permittedTransforms.contains function.reference then
      throw (.invalidInvocationDomain "transform is not permitted")
  for initial in input.initialInputs do
    checkType graph initial.contract.typeRef
    match initial.source with
    | .suppliedValue value =>
      match acceptsSlot graph initial.contract value with
      | .rejected failure => throw (.invalidInitialValue initial.id failure)
      | _ => pure ()
    | .argument => pure ()
    if (initial.resource.map (fun id => !input.initialResources.any (fun lot => lot.id == id))).getD false then
      throw (.invalidResourceDeclaration "initial backing lot")
  for lot in input.initialResources do
    checkType graph lot.tokenType
    match lot.producer with
    | .initial identity revision =>
      if identity == "" || revision == "" || lot.provenance == "" then
        throw (.invalidResourceDeclaration "initial producer or provenance")
    | _ => throw (.invalidResourceDeclaration "initial lot has an invocation producer")
  if input.goal.outputs.isEmpty then throw (.invalidInvocationDomain "empty goal")
  for goal in input.goal.outputs do
    checkType graph goal.contract.typeRef
    if !sourceConstraintDefined graph input goal.sourceConstraint then throw (.invalidInvocationDomain "goal source constraint")
  for embedding in input.goal.failures do
    checkType graph embedding.contract.typeRef
    if !failureOriginDefined input embedding.origin then throw (.invalidInvocationDomain "failure embedding origin")
  for projection in input.invocationDomain.permittedProjections do checkType graph projection.sourceType
  uniqueIds "construction" (input.invocationDomain.permittedConstructions.map (·.identity))
  let constructionEdges := input.invocationDomain.permittedConstructions.foldl
    (fun count rule => count + rule.nestedFields.length) 0
  for construction in input.invocationDomain.permittedConstructions do
    checkType graph construction.typeRef
    let some (.product product) := resolvedShape graph construction.typeRef |
      throw (.invalidInvocationDomain "construction is not a product")
    uniqueIds "nested field" (construction.nestedFields.map (·.1))
    uniqueIds "field constraint" (construction.fieldConstraints.map (·.field))
    for constraint in construction.fieldConstraints do
      if !product.fields.any (fun field => field.wireName == constraint.field) then
        throw (.invalidInvocationDomain "field constraint field")
      if construction.nestedFields.any (fun nested => nested.1 == constraint.field) then
        throw (.invalidInvocationDomain "nested field source constraint")
      if !sourceConstraintDefined graph input constraint.source then
        throw (.invalidInvocationDomain "construction field source constraint")
    for (name, nested) in construction.nestedFields do
      let some field := product.fields.find? (fun field => field.wireName == name) |
        throw (.invalidInvocationDomain "nested field")
      if !input.invocationDomain.permittedConstructions.any
          (fun rule => rule.identity == nested && rule.typeRef == field.slot.typeRef) then
        throw (.invalidInvocationDomain "nested construction rule and type")
      let reached := constructionReachable input.invocationDomain.permittedConstructions
        (input.invocationDomain.permittedConstructions.length + constructionEdges + 1) [nested] []
      if reached.contains construction.identity then throw (.invalidInvocationDomain "cyclic construction rules")
  for guard in input.invocationDomain.guards do
    checkType graph guard.sourceType
    match guard.kind with
    | .validate contract => checkType graph contract.typeRef
    | _ => pure ()
  for (before, after) in input.explicitOrder do
    if before == after || (siteSignature input before).isNone || (siteSignature input after).isNone then
      throw (.invalidInvocationDomain "explicit site order")
  for goal in input.goal.finalResources ++ input.goal.failures.flatMap (·.finalResources) do
    if (declaredLot input goal.lot).isNone then throw (.invalidResourceDeclaration "terminal resource lot")
  pure ()

structure PreparedCompositionInput where
  graph : SemanticGraph
  input : CompositionInput
  operationChecker : FunctionSignature → DefinitionRef → Except CompositionInputFailure Unit
  operationMeaning : FunctionSignature → DefinitionRef → List SemanticObligation
  validated : validateCompositionInput graph input operationChecker = .ok ()
  emptyRefs : List TypeRef
  emptyComputed : emptyRefs = emptyTypes graph
  emptyChecked : CheckedEmptyTypes graph emptyRefs

def prepareDirectComposition (graph : SemanticGraph) (input : CompositionInput)
    (operationChecker : FunctionSignature → DefinitionRef → Except CompositionInputFailure Unit)
    (operationMeaning : FunctionSignature → DefinitionRef → List SemanticObligation) :
    Except CompositionInputFailure PreparedCompositionInput :=
  match checked : validateCompositionInput graph input operationChecker with
  | .error failure => .error failure
  | .ok () =>
    let refs := emptyTypes graph
    match verifyEmptyTypes graph refs with
    | .error _ => .error (.invalidInvocationDomain "invalid empty-type closure")
    | .ok emptyChecked =>
      .ok { graph, input, operationChecker, operationMeaning, validated := checked, emptyRefs := refs, emptyComputed := rfl, emptyChecked }

def OutcomeImpossible (graph : SemanticGraph) (outcome : OutcomeContract) : Prop :=
  ∃ port ∈ outcome.valuePorts, ∀ value, ¬ Slots graph port.contract value

private def outcomeEmpty (prepared : PreparedCompositionInput) (outcome : OutcomeContract) : Bool :=
  outcome.valuePorts.all (fun port => (meaningObligations prepared.graph [port.contract.typeRef]).isEmpty) &&
    outcome.valuePorts.any (fun port => port.contract.required && !port.contract.nullable &&
      decide (port.contract.typeRef ∈ prepared.emptyRefs))

theorem outcomeEmptySound (prepared : PreparedCompositionInput) (outcome : OutcomeContract)
    (empty : outcomeEmpty prepared outcome = true) : OutcomeImpossible prepared.graph outcome := by
  unfold outcomeEmpty at empty
  simp only [Bool.and_eq_true] at empty
  have blocked := empty.2
  obtain ⟨port, declared, condition⟩ := List.any_eq_true.mp blocked
  have conditions : port.contract.required = true ∧ port.contract.nullable = false ∧
      port.contract.typeRef ∈ prepared.emptyRefs := by
    simpa [and_assoc] using condition
  refine ⟨port, declared, ?_⟩
  intro value member
  cases member.2 with
  | absent optional => simp [conditions.1] at optional
  | null nullable => simp [conditions.2.1] at nullable
  | present value accepted =>
    exact emptyTypesSound prepared.graph prepared.emptyRefs prepared.emptyChecked _ [] value accepted conditions.2.2

private structure LoweredPhase where
  identity : String
  revision : Nat
  valueReads : List ProducerRef := []
  reads : List (ResourceLotRef × Nat)
  consumes : List (ResourceLotRef × Nat)
  outputs : List String
  deriving BEq, Repr

private def addRequirement (requirements : List (ResourceLotRef × Nat))
    (lot : ResourceLotRef) (count : Nat) (consume : Bool) : List (ResourceLotRef × Nat) :=
  if requirements.any (fun item => item.1 == lot) then
    requirements.map (fun (reference, previous) =>
      (reference, if reference == lot then if consume then previous + count else max previous count else previous))
  else requirements ++ [(lot, count)]

private def exactlyOne {α : Type} (items : List α) (predicate : α → Bool)
    (reason : String) : Except LoweringFailure α :=
  match items.filter predicate with
  | [item] => .ok item
  | _ => .error (.invalid reason)

private structure LoweringAccumulator where
  lots : List ResourceLotCorrespondence := []
  values : List ValueCorrespondence := []
  marking : Marking := { places := [] }
  places : List TypedPlace := []
  phases : List LoweredPhase := []
  available : List ProducerRef := []
  usedSites : List SiteId := []
  usedGuards : List GuardId := []

private def tokenCapacity (input : CompositionInput) : Nat :=
  (input.bounds.resourceBounds.map (·.maxTokens)).getD 100000

private def lowerInitial (input : CompositionInput) : Except LoweringFailure LoweringAccumulator := do
  let mut result : LoweringAccumulator := {}
  for lot in input.initialResources do
    let reference := ResourceLotRef.initial lot.id
    let place := lotIdentity reference
    let .initial identity revision := lot.producer |
      throw (.invalid "initial lot producer")
    let target := encodeTuple ["initial-resource", identity, revision, lot.id.value]
    if tokenCapacity input < lot.quantity then
      throw (.unknown (.resourceCapacityBound lot.quantity (tokenCapacity input)))
    let tokenType := typeIdentity lot.tokenType
    result := { result with
      places := result.places ++ [{ identity := place, tokenType, revision := lot.revision }]
      marking := { places := result.marking.places ++ [(place, List.replicate lot.quantity
        { target, index := 0, revision := lot.revision, kind := .input })] }
      lots := result.lots ++ [{
        lot := reference, place, producer := lot.producer,
        tokenTarget := target, tokenType, revision := lot.revision, quantity := lot.quantity, provenance := lot.provenance }] }
  for initial in input.initialInputs do
    let producer := ProducerRef.initial initial.id
    let place := producerIdentity producer
    result := { result with
      places := result.places ++ [{ identity := place, tokenType := typeIdentity initial.contract.typeRef, revision := 0 }]
      marking := { places := result.marking.places ++ [(place, [{ target := place, index := 0, revision := 0, kind := .input }])] }
      available := result.available ++ [producer]
      values := result.values ++ [{ producer, place, tokenTarget := place, revision := 0 }] }
  pure result

private def lowerTraceSteps (prepared : PreparedCompositionInput) (steps : List TraceStep)
    (initial : LoweringAccumulator) : Except LoweringFailure LoweringAccumulator := do
  let input := prepared.input
  let mut result := initial
  for step in steps do
    match step with
    | .guard id inspected _ =>
      if result.usedGuards.contains id ||
          !input.invocationDomain.guards.any (fun guard => guard.id == id) ||
          !result.available.contains inspected.producer then throw (.invalid "guard declaration or producer")
      result := { result with
        usedGuards := result.usedGuards ++ [id],
        phases := result.phases ++ [{
          identity := encodeTuple ["guard", id.value, producerIdentity inspected.producer],
          revision := 0, valueReads := [inspected.producer], reads := [], consumes := [], outputs := [] }] }
    | .invocation invocation outcomeId =>
      if result.usedSites.contains invocation.site then throw (.invalid "site fired twice")
      let some function := siteSignature input invocation.site | throw (.invalid "site signature")
      if function.reference != invocation.function then throw (.invalid "function revision")
      let some outcome := function.outcomes.find? (fun candidate => candidate.id == outcomeId) |
        throw (.invalid "invocation outcome")
      if invocation.bindings.length != function.inputs.length ||
          invocation.resources.length != function.resourceInputs.length then throw (.invalid "binding coverage")
      let mut reads : List (ResourceLotRef × Nat) := []
      let mut consumes : List (ResourceLotRef × Nat) := []
      let mut valueReads : List ProducerRef := []
      for port in function.inputs do
        let (_, binding) ← exactlyOne invocation.bindings (fun item => item.1 == port.id) "input binding"
        let sources := bindingSources binding
        for source in sources do
          if !result.available.contains source.producer then throw (.invalid "value producer is not earlier")
          if !valueReads.contains source.producer then valueReads := valueReads ++ [source.producer]
          match declaredValue input source.producer with
          | some (_, some lot) => reads := addRequirement reads lot 1 false
          | _ => pure ()
        match port.resourceRequirement with
        | none => pure ()
        | some requirement =>
          let backing ← exactlyOne invocation.resources (fun binding => binding.requirement == requirement) "backing requirement"
          match sources with
          | [source] =>
            if (declaredValue input source.producer).bind (·.2) != some backing.lot then
              throw (.invalid "port resource backing differs")
          | _ => throw (.invalid "resource backed input must have one producer")
      for requirement in function.resourceInputs do
        let binding ← exactlyOne invocation.resources (fun binding => binding.requirement == requirement.id) "resource binding"
        let some lot := result.lots.find? (fun lot => lot.lot == binding.lot) |
          throw (.invalid "resource producer unavailable")
        let some declaration := declaredLot input binding.lot | throw (.invalid "resource declaration")
        if declaration.revision != requirement.requiredRevision ||
            (requirement.identity != .any && requirement.identity != .exactly declaration.producer) then
          throw (.invalid "resource identity or revision")
        match verifyInclusion prepared.graph (presentContract declaration.tokenType)
            (presentContract requirement.tokenType) binding.inclusion with
        | .error _ => throw (.invalid "resource type inclusion")
        | .ok _ => pure ()
        match requirement.mode with
        | .read => reads := addRequirement reads lot.lot requirement.multiplicity false
        | .consume => consumes := addRequirement consumes lot.lot requirement.multiplicity true
      let identity := invocationIdentity invocation outcomeId
      let mut outputs : List String := []
      for port in outcome.valuePorts do
        let producer := ProducerRef.invocationOutcome invocation.site outcomeId port.id
        let place := producerIdentity producer
        result := { result with
          places := result.places ++ [{ identity := place, tokenType := typeIdentity port.contract.typeRef, revision := 0 }]
          values := result.values ++ [{ producer, place, tokenTarget := identity, revision := 0 }]
          available := result.available ++ [producer] }
        outputs := outputs ++ [place]
      result := { result with
        usedSites := result.usedSites ++ [invocation.site],
        phases := result.phases ++ [{ identity, revision := 0, valueReads, reads, consumes, outputs }] }
      for production in outcome.producedResources do
        let reference := ResourceLotRef.produced invocation.site outcomeId production.id
        let place := lotIdentity reference
        let target := productionIdentity invocation.site outcomeId production.id
        if tokenCapacity input < production.quantity then
          throw (.unknown (.resourceCapacityBound production.quantity (tokenCapacity input)))
        let tokenType := typeIdentity production.tokenType
        result := { result with
          places := result.places ++ [{ identity := place, tokenType, revision := production.revision }]
          lots := result.lots ++ [{
            lot := reference, place,
            producer := .invocationOutcome invocation.site outcomeId, tokenTarget := target,
            tokenType, revision := production.revision, quantity := production.quantity,
            provenance := production.provenance }]
          phases := result.phases ++ [{
            identity := target, revision := production.revision,
            reads := [], consumes := [], outputs := List.replicate production.quantity place }] }
  pure result

private def lowerResourceTraceCore (prepared : PreparedCompositionInput) (trace : BranchTrace) (finalGoals : Bool) :
    Except LoweringFailure (SolverInput × ResourceCorrespondence) := do
  let input := prepared.input
  let accumulated ← lowerTraceSteps prepared trace.steps (← lowerInitial input)
  let root := encodeTuple ["control", "0"]
  let mut places := accumulated.places ++ [{ identity := root, tokenType := "control", revision := 0 }]
  let mut marking : Marking := { places := accumulated.marking.places ++
    [(root, [{ target := "control-root", index := 0, revision := 0, kind := .input }])] }
  let mut previousControl := root
  let mut previousTarget := "control-root"
  let mut previousRevision := 0
  let mut transitions : List TypedTransition := []
  let mut bindings : List InputBinding := []
  let mut normalized : List NormalizedResourceBinding := []
  let mut order : List String := []
  let mut maximumTokens := marking.places.foldl (fun count item => count + item.2.length) 0
  for (phase, index) in accumulated.phases.zipIdx do
    let permit := encodeTuple ["permit", phase.identity]
    places := places ++ [{ identity := permit, tokenType := "control", revision := 0 }]
    marking := { places := marking.places ++
      [(permit, [{ target := permit, index := 0, revision := 0, kind := .input }])] }
    let nextControl := encodeTuple ["control", toString (index + 1)]
    places := places ++ [{ identity := nextControl, tokenType := "control", revision := phase.revision }]
    let mut inputPlaces := [previousControl, permit]
    let mut selected : List InputBinding :=
      [{ transitionId := phase.identity, name := "order", place := previousControl,
         tokenType := "control", identity := previousTarget, provenance := "selected branch order",
         multiplicity := 1, mode := .consume, requiredRevision := previousRevision },
       { transitionId := phase.identity, name := "permit", place := permit, tokenType := "control",
         identity := permit, provenance := "finite site permit", multiplicity := 1, mode := .consume,
         requiredRevision := 0 }]
    for producer in phase.valueReads do
      let some value := accumulated.values.find? (fun value => value.producer == producer) |
        throw (.invalid "input value correspondence unavailable")
      let some (declaration, _) := declaredValue input producer |
        throw (.invalid "input value declaration unavailable")
      inputPlaces := inputPlaces ++ [value.place]
      selected := selected ++ [{
        transitionId := phase.identity, name := encodeTuple ["value-read", value.place],
        place := value.place, tokenType := typeIdentity declaration.typeRef,
        identity := value.tokenTarget, provenance := producerIdentity producer,
        multiplicity := 1, mode := .read, requiredRevision := value.revision }]
    for reference in distinct ((phase.reads ++ phase.consumes).map (·.1)) do
      let some lot := accumulated.lots.find? (fun lot => lot.lot == reference) |
        throw (.invalid "normalized lot")
      let read := ((phase.reads.find? (fun item => item.1 == reference)).map (·.2)).getD 0
      let consume := ((phase.consumes.find? (fun item => item.1 == reference)).map (·.2)).getD 0
      inputPlaces := inputPlaces ++ [lot.place]
      for (name, mode, count) in [("read", BindingMode.read, read), ("consume", BindingMode.consume, consume)] do
        if count != 0 then
          selected := selected ++ [{
            transitionId := phase.identity, name := encodeTuple [name, lot.place],
            place := lot.place, tokenType := lot.tokenType, identity := lot.tokenTarget,
            provenance := lot.provenance, multiplicity := count, mode, requiredRevision := lot.revision }]
      normalized := normalized ++ [{
        transition := phase.identity, lot := reference, read, consume,
        requiredRevision := lot.revision }]
    let outputPlaces := phase.outputs ++ [nextControl]
    maximumTokens := maximumTokens + outputPlaces.length + 1
    transitions := transitions ++ [{
      identity := phase.identity, inputPlaces, outputPlaces,
      failurePlaces := [], revision := phase.revision }]
    bindings := bindings ++ selected
    order := order ++ [phase.identity]
    previousControl := nextControl
    previousTarget := phase.identity
    previousRevision := phase.revision
  if tokenCapacity input < maximumTokens then
    throw (.unknown (.resourceCapacityBound maximumTokens (tokenCapacity input)))
  let mut goal := GoalPredicate.placeHasToken previousControl previousTarget 0 previousRevision
  let (returnBindings, finalResources) ← match trace.terminal with
    | .success outputs => pure (outputs.map (·.2), if finalGoals then input.goal.finalResources else [])
    | .failure id value => do
      let some embedding := input.goal.failures.find? (fun embedding => embedding.id == id) |
        throw (.invalid "failure embedding")
      pure ([value], embedding.finalResources)
  for binding in returnBindings do
    for source in bindingSources binding do
      let some correspondence := accumulated.values.find? (fun value => value.producer == source.producer) |
        throw (.invalid "return value producer")
      goal := .glAnd goal (.placeHasToken correspondence.place correspondence.tokenTarget 0 correspondence.revision)
      match declaredValue input source.producer with
      | some (_, some reference) =>
        let some lot := accumulated.lots.find? (fun lot => lot.lot == reference) |
          throw (.invalid "return backing lot")
        goal := .glAnd goal (.placeHasAtLeast lot.place 1)
      | _ => pure ()
  for requirement in finalResources do
    let some lot := accumulated.lots.find? (fun lot => lot.lot == requirement.lot) |
      throw (.invalid "terminal resource producer")
    if lot.revision != requirement.revision then throw (.invalid "terminal resource revision")
    goal := .glAnd goal (.placeHasAtLeast lot.place requirement.multiplicity)
  let graph : DeclarationGraph :=
    { places := places.map (·.identity), transitions := transitions.map (·.identity),
      edges := transitions.flatMap (fun transition =>
        transition.inputPlaces.map (fun place => (place, transition.identity)) ++
        transition.outputPlaces.map (fun place => (transition.identity, place))), revision := 0 }
  let bound : DomainBound :=
    { targetIdentity := input.identity, index := 0, revision := 0,
      maxBindings := (input.bounds.resourceBounds.map (·.maxBindings)).getD bindings.length,
      maxSearchSteps := (input.bounds.resourceBounds.map (·.maxSearchSteps)).getD (transitions.length + 1) }
  let lowered : SolverInput := { places, transitions, bindings, goal, graph, marking, bound }
  if (Necoherence.validate lowered).isSome then throw (.invalid "resource declaration rejected")
  if ¬ (places.map (·.identity)).Nodup then throw (.invalid "resource place identity collision")
  pure (lowered, {
    lots := accumulated.lots, values := accumulated.values,
    normalizedBindings := normalized, executionOrder := order })

def lowerResourceTrace (prepared : PreparedCompositionInput) (trace : BranchTrace) :
    Except LoweringFailure (SolverInput × ResourceCorrespondence) :=
  lowerResourceTraceCore prepared trace true


def initialState (prepared : PreparedCompositionInput) : SearchState :=
  { available := prepared.input.initialInputs.map (fun initial =>
      { producer := .initial initial.id, contract := initial.contract,
        resource := initial.resource.map ResourceLotRef.initial }),
    usedSites := [], usedGuards := [], facts := [], trace := [], pendingFailure := none }

private def relativeAssumption (leading : ValuePath) : ProjectionAssumption → Option ProjectionAssumption :=
  let trim := fun path => if leading == path.take leading.length then some (path.drop leading.length) else none
  fun assumption => match assumption with
    | .present path => (trim path).map ProjectionAssumption.present
    | .nonNull path => (trim path).map ProjectionAssumption.nonNull
    | .variant path tag => (trim path).map (fun path => .variant path tag)
    | .indexPresent path index => (trim path).map (fun path => .indexPresent path index)

private def projectionBasis (state : SearchState) (value : ValueRef) :
    Except WitnessFailure (SlotContract × ValuePath × List ProjectionAssumption) := do
  let some source := state.available.find? (fun source => source.producer == value.producer) |
    throw (.producerMismatch value)
  let refined := state.facts.reverse.find? (fun fact =>
    fact.inspected.producer == value.producer && fact.refinement.isSome &&
      fact.inspected.path == value.path.take fact.inspected.path.length)
  let (contract, leading) := match refined with
    | some fact => (fact.refinement.getD source.contract, fact.inspected.path)
    | none => (source.contract, [])
  let assumptions := state.facts.filter (fun fact => fact.inspected.producer == value.producer)
    |>.flatMap (fun fact => fact.assumptions.filterMap (relativeAssumption leading))
  if leading != value.path.take leading.length then throw (.guardNotDominating value)
  pure (contract, leading, assumptions)

private def effectiveProjection (prepared : PreparedCompositionInput) (state : SearchState) (value : ValueRef) :
    Except WitnessFailure ProjectionCertificate := do
  let (contract, leading, assumptions) ← projectionBasis state value
  (projectSlot prepared.graph contract (value.path.drop leading.length) assumptions).mapError WitnessFailure.projectionMismatch

def exactValue (prepared : PreparedCompositionInput) (state : SearchState)
    (value : ValueRef) : Option SlotValue :=
  match state.facts.reverse.find? (fun fact => fact.inspected.producer == value.producer &&
      fact.exact.isSome && fact.inspected.path == value.path.take fact.inspected.path.length) with
  | some fact => fact.exact.map (fun supplied =>
      projectedValue prepared.graph.profile supplied (value.path.drop fact.inspected.path.length))
  | none => match value.producer with
    | .initial id => do
      let initial ← prepared.input.initialInputs.find? (fun initial => initial.id == id)
      match initial.source with
      | .argument => none
      | .suppliedValue supplied =>
        some (projectedValue prepared.graph.profile supplied value.path)
    | _ => none

private def pathPermitted (input : CompositionInput) (source : SlotContract) (path : ValuePath) : Bool :=
  path.isEmpty || input.invocationDomain.permittedProjections.any
    (fun projection => projection.sourceType == source.typeRef && projection.path == path) ||
    input.invocationDomain.guards.any (fun guard => guard.sourceType == source.typeRef && guard.path == path)

private def sampleVarint (value : Nat) : List Nat :=
  if value < 128 then [value]
  else (value % 128 + 128) :: sampleVarint (value / 128)
termination_by value
decreasing_by exact Nat.div_lt_self (by omega) (by decide)

private def sampleBase32Digit (value : Nat) : Char :=
  Char.ofNat (if value < 26 then 'a'.toNat + value else '2'.toNat + value - 26)

private def sampleBase32 (bytes : List Nat) : String :=
  let rec drain (bits buffer : Nat) (output : List Char) : Nat × Nat × List Char :=
    if bits < 5 then (bits, buffer, output)
    else drain (bits - 5) (buffer % 2 ^ (bits - 5))
      (sampleBase32Digit ((buffer / 2 ^ (bits - 5)) % 32) :: output)
  termination_by bits
  let rec encode (bits buffer : Nat) (output : List Char) : List Nat → String
    | [] =>
      let output := if bits == 0 then output
        else sampleBase32Digit ((buffer * 2 ^ (5 - bits)) % 32) :: output
      String.ofList output.reverse
    | byte :: rest =>
      let (bits, buffer, output) := drain (bits + 8) (buffer * 256 + byte) output
      encode bits buffer output rest
  encode 0 0 [] bytes

private def timestampSample (rule : CalendarRule) : String :=
  let year := toString rule.minimumYear
  String.ofList (List.replicate (4 - year.length) '0') ++ year ++ "-01-01T00:00:00Z"

private def dfaShortestWord (spec : DfaSpec) : Nat → List (Nat × List Char) → List Nat → Option String
  | 0, _, _ => none
  | fuel + 1, frontier, visited =>
    match frontier.find? (fun (state, _) => spec.acceptingStates.contains state) with
    | some (_, path) => some (String.ofList path.reverse)
    | none =>
      let reached := frontier.flatMap fun (state, path) =>
        (spec.transitions.filter (·.fromState == state)).map fun transition =>
          (transition.toState, Char.ofNat transition.first :: path)
      let fresh := reached.foldl (fun (kept : List (Nat × List Char)) entry =>
        if visited.contains entry.1 || kept.any (·.1 == entry.1) then kept else kept ++ [entry]) []
      dfaShortestWord spec fuel fresh (visited ++ fresh.map (·.1))

private def identifierSamples (first rest : String) (exactLength : Option Nat) (minimum : Nat)
    (forbidden : List String) (accepts : String → Bool) : List String :=
  let lengths := match exactLength with
    | some length => [length]
    | none => (List.range (forbidden.length + 1)).map (fun extra => max minimum 1 + extra)
  let candidates := lengths.flatMap fun length =>
    first.toList.flatMap fun head =>
      if length == 1 then [String.singleton head]
      else rest.toList.map fun tail => String.ofList (head :: List.replicate (length - 1) tail)
  (candidates.find? accepts).toList

private def sequenceSamples (limit : Nat) (parts : List (List String)) : List String :=
  match parts.mapM List.head? with
  | none => []
  | some heads =>
    let varied := (List.range parts.length).flatMap fun index =>
      ((parts[index]?.getD []).drop 1).map fun sample => String.join (heads.set index sample)
    (String.join heads :: varied).take limit

private def formatRuleSamplesFuel (limit : Nat) : Nat → FormatRule → List String
  | 0, _ => []
  | fuel + 1, rule =>
    let inner := formatRuleSamplesFuel limit fuel
    let candidates := match rule with
      | .literal value => [value]
      | .sequence parts => sequenceSamples limit (parts.map inner)
      | .optional part => "" :: inner part
      | .choice rules => rules.flatMap inner
      | .labels separator minimum _ _ part =>
        (inner part).map fun sample => String.intercalate separator (List.replicate (max minimum 1) sample)
      | .bounded _ _ part => inner part
      | .asciiDfa spec => (dfaShortestWord spec (spec.stateCount + 1) [(spec.initialState, [])] [spec.initialState]).toList
      | .identifier first rest exactLength minimum _ forbidden =>
        identifierSamples first rest exactLength minimum forbidden (formatAccepts rule)
      | .timestamp calendar => [timestampSample calendar]
      | .absoluteUri _ => (["a:", "a:b"].find? (formatAccepts rule)).toList
      | .languageTag _ => ["aa"]
      | .text => ["", "a"]
      | .not child =>
        let excluded := inner child
        ["", "a", "aa"] ++ excluded ++ excluded.map (· ++ "x")
    (candidates.filter (formatAccepts rule)).take limit

theorem formatRuleSamplesFuel_sound (limit fuel : Nat) (rule : FormatRule) (text : String)
    (present : text ∈ formatRuleSamplesFuel limit fuel rule) :
    formatAccepts rule text = true := by
  cases fuel with
  | zero => simp [formatRuleSamplesFuel] at present
  | succ fuel =>
    exact (List.mem_filter.mp (List.mem_of_mem_take present)).2

private def formatSamples (profile : VersionedSemanticProfile) (format : Option String) (limit : Nat) :
    List String :=
  ((format.bind (fun name => profile.formatBindings.find? (fun binding => binding.name == name))).toList).flatMap
    fun binding => formatRuleSamplesFuel limit (formatRuleDepth binding.rule) binding.rule

private def integerSample (form : IntegerForm) (value : Int) : JsonValue :=
  match form with
  | .number => .num value
  | .integralDecimal => .dec (toString value)
  | .decimalString => .str (toString value)

private def formatUseSamples (profile : VersionedSemanticProfile)
    (use : Option FormatUse) (limit : Nat) : List String :=
  match use with
  | none => ["x"]
  | some (.named name) => formatSamples profile (some name) limit
  | some (.inline rule) => formatRuleSamplesFuel limit (formatRuleDepth rule) rule

private def sampleValueCandidatesFuel (graph : SemanticGraph) :
    Nat → List TypeRef → TypeRef → List JsonValue
  | 0, _, _ => []
  | fuel + 1, seen, reference =>
    if seen.contains reference then []
    else
      let recurse := fun target => sampleValueCandidatesFuel graph fuel (reference :: seen) target
      let candidates := match graph.findType reference with
        | none => []
        | some node => match node.shape with
          | .boolean spec => spec.constValue.map (fun value => [JsonValue.bool value]) |>.getD [.bool false, .bool true]
          | .integer spec =>
            let binding := integerBinding graph.profile spec.domain
            let domain := match binding.map (fun binding : IntegerDomainBinding => binding.range) with
              | some (.inclusive minimum maximum) => [minimum, maximum]
              | _ => []
            let values := spec.constValue.toList ++ spec.enumValues.getD [] ++
              spec.minimum.toList ++ spec.maximum.toList ++ domain ++ [0, 1, -1]
            match binding with
            | none => []
            | some binding => binding.forms.flatMap fun form => values.map (integerSample form)
          | .decimal spec =>
            let bounds : List DecimalBound := spec.minimum.toList ++ spec.maximum.toList
            (bounds.map fun (bound : DecimalBound) =>
              JsonValue.dec (toString bound.mantissa ++ "e-" ++ toString bound.scale)) ++
              [JsonValue.dec "0.0", JsonValue.dec "1.0", JsonValue.dec "-1.0"]
          | .string spec =>
            let lengths := spec.lengths.flatMap fun (bound : LengthBound) =>
              bound.minimum.toList ++ bound.maximum.toList
            let texts := spec.constValue.toList ++ spec.enumValues.getD [] ++ spec.examples ++
              formatUseSamples graph.profile spec.format (fuel + 1) ++ ["", "a"] ++
              lengths.map (fun length => String.ofList (List.replicate length 'a'))
            match spec.wrapper with
            | none => texts.map JsonValue.str
            | some name =>
              match graph.profile.wrappers.find? (fun (wrapper : Wrapper) => wrapper.name == name) with
              | none => []
              | some wrapper => texts.map fun text => JsonValue.obj [(wrapper.key, .str text)]
          | .bytes spec =>
            match graph.profile.bytesPolicy with
            | none => []
            | some policy =>
              let lengths := spec.minimum.toList ++ spec.maximum.toList ++ [0, 1]
              let (quad, one, two) := match policy.alphabet with
                | .urlSafe => ("____", "_w==", "__8=")
                | .standard | .either => ("////", "/w==", "//8=")
              let wire := fun length =>
                String.join (List.replicate (length / 3) quad) ++
                  match length % 3 with | 1 => one | 2 => two | _ => ""
              match policy.wrapper with
              | none => lengths.map fun length => JsonValue.str (wire length)
              | some name =>
                match graph.profile.wrappers.find? (fun (wrapper : Wrapper) => wrapper.name == name) with
                | none => []
                | some wrapper =>
                  lengths.map fun length => JsonValue.obj [(wrapper.key, .str (wire length))]
          | .sealed sealedTag refinements =>
            match graph.profile.tag with
            | none => []
            | some tag =>
              match tag.sealed.find? (fun (form : SealedForm) => form.tag == sealedTag) with
              | none => []
              | some form =>
                let leafFor := fun (field : SealedField) =>
                  (refinements.find? (fun (refinement : SealedRefinement) =>
                    refinement.key == field.key)).map
                      (fun (refinement : SealedRefinement) => refinement.leaf) |>.getD field.leaf
                let fieldSample := fun (field : SealedField) =>
                  match leafFor field with
                  | SealedLeaf.string spec =>
                    (((spec.constValue.orElse (fun _ => spec.enumValues.bind List.head?)).orElse
                      (fun _ => spec.examples.head?)).orElse
                      (fun _ => (formatUseSamples graph.profile spec.format 1).head?)).map JsonValue.str
                  | SealedLeaf.integer spec =>
                    (spec.constValue.orElse (fun _ => spec.enumValues.bind List.head?)).orElse
                      (fun _ => spec.minimum.orElse (fun _ => spec.maximum)) |>.map JsonValue.num
                match (form.fields.filter (fun (field : SealedField) => field.required)).mapM
                    (fun (field : SealedField) =>
                      (fieldSample field).map (fun value => (field.key, value))) with
                | none => []
                | some fields => [JsonValue.obj ((tag.key, JsonValue.str form.tag) :: fields)]
          | .never => []
          | .rawBody _ => []
          | .unit => [.null]
          | .unknown _ => [.obj [], .null, .bool false, .num 0, .str "", .arr []]
          | .alias target _ => recurse target
          | .array spec =>
            (spec.minLength.toList ++ spec.maxLength.toList ++ [0, 1]).flatMap fun length =>
              if length == 0 then [.arr []]
              else
                let values := (if spec.item.nullable then [JsonValue.null] else []) ++
                  recurse spec.item.typeRef
                values.map (fun value => .arr (List.replicate length value))
          | .product spec =>
            let rec construct : List FieldSpec → List (List (String × JsonValue))
              | [] => [[]]
              | field :: rest =>
                let remaining := construct rest
                let values := recurse field.slot.typeRef
                let here : List (Option JsonValue) := (if !field.slot.required then [none] else []) ++
                  (if field.slot.nullable then [some JsonValue.null] else []) ++ values.map some
                (here.flatMap fun (value : Option JsonValue) => remaining.map fun (fields : List (String × JsonValue)) =>
                  match value with | none => fields | some value => (field.wireName, value) :: fields).take (fuel + 1)
            let base := (construct spec.fields).map JsonValue.obj
            let extras := match spec.extras with
              | .reject => []
              | .allow keyFormat contract =>
                (formatUseSamples graph.profile keyFormat 1).flatMap fun key =>
                  (recurse contract.typeRef).take 1 |>.map fun value => JsonValue.obj [(key, value)]
            base ++ extras
          | .taggedUnion spec =>
            let tagKey := (graph.profile.tag.map (fun (model : TagModel) => model.key)).getD ""
            spec.branches.flatMap fun (branch : UnionBranch) =>
              (recurse branch.target).filterMap fun (value : JsonValue) =>
                match branch.selector, value with
                | .internalTag, .obj members =>
                  some (JsonValue.obj ((tagKey, JsonValue.str branch.wireTag) ::
                    members.filter (fun member => member.1 != tagKey)))
                | .memberShape tests, .obj members =>
                  let shaped := tests.foldl (fun (current : List (String × JsonValue))
                      (test : String × MemberTest) =>
                    match test.2 with
                    | .absent => current.filter (fun member => member.1 != test.1)
                    | .format name =>
                      match (formatSamples graph.profile (some name) 1).head? with
                      | none => current
                      | some text => (test.1, JsonValue.str text) ::
                        current.filter (fun member => member.1 != test.1)) members
                  some (JsonValue.obj shaped)
                | .kind _, _ | .otherwise, _ => some value
                | _, _ => none
          | .opaque _ => []
      candidates.filter (fun value => match acceptsValue graph reference value with | .accepted => true | _ => false)

private theorem sampleValueCandidatesFuel_sound (graph : SemanticGraph) (fuel : Nat)
    (seen : List TypeRef) (reference : TypeRef) (value : JsonValue)
    (present : value ∈ sampleValueCandidatesFuel graph fuel seen reference) :
    acceptsValue graph reference value = .accepted := by
  cases fuel with
  | zero => simp [sampleValueCandidatesFuel] at present
  | succ fuel =>
    simp only [sampleValueCandidatesFuel] at present
    split at present
    · simp at present
    · have accepted := (List.mem_filter.mp present).2
      cases decision : acceptsValue graph reference value <;>
        simp [decision] at accepted ⊢

private def sampleWithinBound (maximum : Nat) : JsonValue → Bool
  | .str text | .dec text => text.length ≤ maximum
  | .arr items => items.length ≤ maximum
  | .obj members => members.length ≤ maximum
  | _ => true

def sampleValueFuel (graph : SemanticGraph) (bounds : SearchBounds)
    (fuel : Nat) (seen : List TypeRef) (reference : TypeRef) : SampleResult JsonValue :=
  let candidates := sampleValueCandidatesFuel graph fuel seen reference
  let values := candidates.filter (sampleWithinBound bounds.maxSampleLength)
  { values
    obligations := if values.length = candidates.length then [] else [.sampleBound] }

theorem sampleValueFuel_sound (graph : SemanticGraph) (bounds : SearchBounds)
    (fuel : Nat) (seen : List TypeRef) (reference : TypeRef) (value : JsonValue)
    (present : value ∈ (sampleValueFuel graph bounds fuel seen reference).values) :
    acceptsValue graph reference value = .accepted := by
  apply sampleValueCandidatesFuel_sound graph fuel seen reference value
  exact (List.mem_filter.mp present).1

def slotSamples (prepared : PreparedCompositionInput) (contract : SlotContract) : SampleResult SlotValue :=
  let generated := sampleValueFuel prepared.graph prepared.input.bounds
    (min prepared.input.bounds.maxTypeObligations (prepared.graph.nodes.length + 1)) [] contract.typeRef
  let values :=
    ((if !contract.required then [SlotValue.absent] else []) ++
      (if contract.nullable then [SlotValue.null] else []) ++
      generated.values.map SlotValue.present).filter (fun value =>
        match acceptsSlot prepared.graph contract value with | .accepted => true | _ => false)
  { values, obligations := generated.obligations }

theorem slotSamples_sound (prepared : PreparedCompositionInput) (contract : SlotContract)
    (value : SlotValue) (present : value ∈ (slotSamples prepared contract).values) :
    acceptsSlot prepared.graph contract value = .accepted := by
  have accepted := (List.mem_filter.mp present).2
  cases decision : acceptsSlot prepared.graph contract value <;>
    simp [decision] at accepted ⊢

private def valuePossible (prepared : PreparedCompositionInput) (state : SearchState)
    (reference : ValueRef) (contract : SlotContract) : Bool :=
  match exactValue prepared state reference with
  | some supplied => match acceptsSlot prepared.graph contract supplied with | .accepted => true | _ => false
  | none =>
    let samples := slotSamples prepared contract
    !samples.values.isEmpty || !samples.obligations.isEmpty

private theorem valuePossible_of_sample_obligation (prepared : PreparedCompositionInput)
    (state : SearchState) (reference : ValueRef) (contract : SlotContract)
    (unknown : exactValue prepared state reference = none)
    (omitted : (slotSamples prepared contract).obligations ≠ []) :
    valuePossible prepared state reference contract = true := by
  unfold valuePossible
  rw [unknown]
  cases obligations : (slotSamples prepared contract).obligations with
  | nil => exact absurd obligations omitted
  | cons head tail => simp [obligations]

private def certifyProjection (graph : SemanticGraph) (certificate : ProjectionCertificate) :
    Except WitnessFailure { checked : ProjectionCertificate //
      checkProjectionCertificate graph certificate = .ok checked } :=
  match checked : checkProjectionCertificate graph certificate with
  | .error failure => .error (.projectionMismatch failure)
  | .ok result => .ok ⟨result, rfl⟩

private def bindingAllowsPresentNull (prepared : PreparedCompositionInput) (state : SearchState) :
    BindingExpr → Bool
  | .product _ _ _ => false
  | .source reference _ _ =>
    match exactValue prepared state reference with
    | some (.present .null) => true
    | some _ => false
    | none => match effectiveProjection prepared state reference with
      | .error _ => true
      | .ok projection => match acceptsValue prepared.graph projection.destination.typeRef .null with
        | .rejected _ => false | _ => true

private def discriminatorSafe (prepared : PreparedCompositionInput) (state : SearchState) :
    BindingExpr → Bool
  | .product _ _ _ => false
  | .source reference _ _ =>
    let safe := fun value => match value with
      | SlotValue.absent => true
      | .present (.str text) =>
        let members := [((prepared.graph.profile.tag.map (fun (model : TagModel) => model.key)).getD "", .str text)]
        tagValueAccepts prepared.graph.profile members &&
          classOf prepared.graph.profile members == .ordinary
      | _ => false
    match exactValue prepared state reference with
    | some value => safe value
    | none => match effectiveProjection prepared state reference with
      | .error _ => false
      | .ok projection =>
        match resolvedShape prepared.graph projection.destination.typeRef with
        | some (.string spec) => !projection.destination.nullable &&
            ((stringFinite spec).map (fun values => values.all (fun text =>
              if stringCondition prepared.graph.profile spec text == none then safe (.present (.str text)) else true))).getD false
        | _ => false

inductive BindingJudgment where
  | binding (binding : BindingExpr) (destination : SlotContract) (constraint : SourceConstraint)
  | fields (rule : ConstructionRule) (product : ProductSpec) (entries : List (String × BindingExpr))

inductive Justified (prepared : PreparedCompositionInput) (state : SearchState) :
    BindingJudgment → Prop where
  | source (reference : ValueRef) (projection computed : ProjectionCertificate)
      (certificate : InclusionCertificate) (destination : SlotContract) (constraint : SourceConstraint)
      (available : state.available.any (fun source => source.producer == reference.producer) = true)
      (sourceAllowed : constraint.accepts reference = true)
      (projected : effectiveProjection prepared state reference = .ok computed)
      (certificateMatches : (projection == computed) = true)
      (projectionChecked : ∃ checked, checkProjectionCertificate prepared.graph computed = .ok checked)
      (included : CheckedInclusion prepared.graph computed.destination destination) :
      Justified prepared state
        (.binding (.source reference projection (.inclusion certificate)) destination constraint)
  | suppliedValue (reference : ValueRef) (projection computed : ProjectionCertificate)
      (supplied : SlotValue) (destination : SlotContract) (constraint : SourceConstraint)
      (available : state.available.any (fun source => source.producer == reference.producer) = true)
      (sourceAllowed : constraint.accepts reference = true)
      (projected : effectiveProjection prepared state reference = .ok computed)
      (certificateMatches : (projection == computed) = true)
      (projectionChecked : ∃ checked, checkProjectionCertificate prepared.graph computed = .ok checked)
      (exact : (exactValue prepared state reference == some supplied) = true)
      (sourceMember : ValidatedSlot prepared.graph computed.destination supplied)
      (destinationMember : ValidatedSlot prepared.graph destination supplied) :
      Justified prepared state
        (.binding (.source reference projection (.suppliedValue supplied)) destination constraint)
  | product (construction : String) (reference : TypeRef) (fields : List (String × BindingExpr))
      (destination : SlotContract) (rule : ConstructionRule) (product : ProductSpec)
      (permitted : prepared.input.invocationDomain.permittedConstructions.find?
        (fun candidate => candidate.identity == construction && candidate.typeRef == reference) = some rule)
      (rootType : reference = destination.typeRef)
      (resolved : resolvedShape prepared.graph reference = some (.product product))
      (unique : (fields.map (·.1)).Nodup)
      (required : ∀ field ∈ product.fields, (field.slot.required || rule.fieldRequired field.wireName) = true →
        field.wireName ∈ fields.map (·.1))
      (typed : Justified prepared state (.fields rule product fields))
      (meaning : MeaningDefined prepared.graph reference) :
      Justified prepared state
        (.binding (.product construction reference fields) destination .anyCompatible)
  | noFields (rule : ConstructionRule) (product : ProductSpec) :
      Justified prepared state (.fields rule product [])
  | consFields (rule : ConstructionRule) (product : ProductSpec) (name : String) (child : BindingExpr)
      (rest : List (String × BindingExpr)) (field : FieldSpec)
      (declared : field ∈ product.fields) (named : field.wireName = name)
      (typed : Justified prepared state (.binding child field.slot (rule.fieldConstraint name)))
      (later : Justified prepared state (.fields rule product rest)) :
      Justified prepared state (.fields rule product ((name, child) :: rest))

abbrev BindingJustified (prepared : PreparedCompositionInput) (state : SearchState)
    (binding : BindingExpr) (destination : SlotContract) (constraint : SourceConstraint) : Prop :=
  Justified prepared state (.binding binding destination constraint)

abbrev FieldsJustified (prepared : PreparedCompositionInput) (state : SearchState)
    (rule : ConstructionRule) (product : ProductSpec) (entries : List (String × BindingExpr)) : Prop :=
  Justified prepared state (.fields rule product entries)

theorem FieldsJustified.entry {prepared : PreparedCompositionInput} {state : SearchState}
    {rule : ConstructionRule} {product : ProductSpec} {fields : List (String × BindingExpr)}
    (typed : FieldsJustified prepared state rule product fields) :
    ∀ entry ∈ fields, ∃ field ∈ product.fields, field.wireName = entry.1 ∧
      BindingJustified prepared state entry.2 field.slot (rule.fieldConstraint entry.1) := by
  cases typed with
  | noFields => intro entry present; simp at present
  | consFields _ _ name child rest field declared named justified later =>
    intro entry present
    rcases List.mem_cons.mp present with same | remaining
    · subst entry
      exact ⟨field, declared, named, justified⟩
    · exact FieldsJustified.entry later entry remaining

private structure CheckedSourceBase (prepared : PreparedCompositionInput) (state : SearchState)
    (reference : ValueRef) (projection : ProjectionCertificate) (constraint : SourceConstraint) : Type where
  computed : ProjectionCertificate
  available : state.available.any (fun source => source.producer == reference.producer) = true
  sourceAllowed : constraint.accepts reference = true
  projected : effectiveProjection prepared state reference = .ok computed
  same : (projection == computed) = true
  projectionChecked : ∃ checked, checkProjectionCertificate prepared.graph computed = .ok checked

private def checkSourceBase (prepared : PreparedCompositionInput) (state : SearchState)
    (reference : ValueRef) (projection : ProjectionCertificate) (constraint : SourceConstraint) :
    Except WitnessFailure (CheckedSourceBase prepared state reference projection constraint) := do
  if sourceAllowed : constraint.accepts reference = true then
    if available : state.available.any (fun source => source.producer == reference.producer) = true then
      let some source := state.available.find? (fun source => source.producer == reference.producer) |
        throw (.producerMismatch reference)
      if !pathPermitted prepared.input source.contract reference.path then
        throw (.projectionMismatch (.certificateMismatch "projection outside finite domain"))
      match projected : effectiveProjection prepared state reference with
      | .error failure => throw failure
      | .ok computed =>
        if same : (projection == computed) = true then
          if !valuePossible prepared state reference computed.destination then
            throw (.missingEvidence "no accepted value for producer")
          let projectionChecked ← certifyProjection prepared.graph computed
          pure { computed, available, sourceAllowed, projected, same,
                 projectionChecked := ⟨projectionChecked.val, projectionChecked.property⟩ }
        else throw (.projectionMismatch (.certificateMismatch "source, projection, or dominating guard"))
    else throw (.producerMismatch reference)
  else throw (.sourceConstraintMismatch reference)


private def checkBindingFuel (prepared : PreparedCompositionInput) (state : SearchState) :
    Nat → (binding : BindingExpr) → (destination : SlotContract) → (constraint : SourceConstraint) →
      Except WitnessFailure { proof : Unit // BindingJustified prepared state binding destination constraint }
  | 0, _, destination, _ => .error (.constructionMismatch destination.typeRef)
  | fuel + 1, .source reference projection (.inclusion certificate), destination, constraint => do
    let base ← checkSourceBase prepared state reference projection constraint
    let inclusion ← (verifyInclusion prepared.graph base.computed.destination destination certificate).mapError
      WitnessFailure.inclusion
    pure ⟨(), .source reference projection base.computed certificate destination constraint
      base.available base.sourceAllowed base.projected base.same base.projectionChecked inclusion⟩
  | fuel + 1, .source reference projection (.suppliedValue supplied), destination, constraint => do
    let base ← checkSourceBase prepared state reference projection constraint
    if exact : (exactValue prepared state reference == some supplied) = true then
      let sourceMember ← (validateSlot prepared.graph base.computed.destination supplied).mapError
        (fun _ => WitnessFailure.suppliedValueMismatch reference)
      let destinationMember ← (validateSlot prepared.graph destination supplied).mapError
        (fun _ => WitnessFailure.suppliedValueMismatch reference)
      pure ⟨(), .suppliedValue reference projection base.computed supplied destination constraint
        base.available base.sourceAllowed base.projected base.same base.projectionChecked exact
        sourceMember destinationMember⟩
    else throw (.suppliedValueMismatch reference)
  | fuel + 1, .product construction reference fields, destination, constraint => do
    if hconstraint : constraint = .anyCompatible then
      if rootType : reference = destination.typeRef then
        if permitted : prepared.input.invocationDomain.permittedConstructions.any
            (fun candidate => candidate.identity == construction && candidate.typeRef == reference) = true then
          let ruleFound ← resolveOption (prepared.input.invocationDomain.permittedConstructions.find?
            (fun candidate => candidate.identity == construction && candidate.typeRef == reference))
            (WitnessFailure.constructionMismatch reference)
          let rule := ruleFound.val
          match resolved : resolvedShape prepared.graph reference with
          | some (.product product) =>
            if unique : (fields.map (·.1)).Nodup then
              let rec checkFields (entries : List (String × BindingExpr)) :
                  Except WitnessFailure { proof : Unit //
                    FieldsJustified prepared state rule product entries } :=
                match entries with
                | [] => .ok ⟨(), .noFields rule product⟩
                | (name, child) :: rest => do
                  let fieldFound ← resolveOption (product.fields.find? (fun field => decide (field.wireName = name)))
                    (WitnessFailure.constructionMismatch reference)
                  let field := fieldFound.val
                  match child with
                  | .product nested _ _ =>
                    if !rule.nestedFields.any (fun item => item.1 == name && item.2 == nested) then
                      throw (.constructionMismatch reference)
                  | _ => pure ()
                  if !field.slot.nullable && bindingAllowsPresentNull prepared state child then
                    throw (.constructionMismatch reference)
                  let checked ← checkBindingFuel prepared state fuel child field.slot (rule.fieldConstraint name)
                  let later ← checkFields rest
                  have found := (find_sound product.fields _ field fieldFound.property).1
                  have identity : field.wireName = name :=
                    of_decide_eq_true (find_sound product.fields _ field fieldFound.property).2
                  pure ⟨(), .consFields rule product name child rest field found identity checked.property later.property⟩
              let typed ← checkFields fields
              if hrequired : product.fields.all (fun field =>
                  !(field.slot.required || rule.fieldRequired field.wireName) || (fields.map (·.1)).contains field.wireName) = true then
                match hmeaning : meaningObligations prepared.graph [reference] with
                | [] =>
                  have required : ∀ field ∈ product.fields,
                      (field.slot.required || rule.fieldRequired field.wireName) = true →
                      field.wireName ∈ fields.map (·.1) := by
                    intro field declared isRequired
                    have here := (List.all_eq_true.mp hrequired) field declared
                    simpa [isRequired] using here
                  have justified : BindingJustified prepared state (.product construction reference fields)
                      destination .anyCompatible :=
                    .product construction reference fields destination rule product ruleFound.property
                      rootType resolved unique required typed.property hmeaning
                  pure ⟨(), by subst hconstraint; exact justified⟩
                | obligations => throw (.inclusion (.undefinedMeaning obligations))
              else throw (.constructionMismatch reference)
            else throw (.constructionMismatch reference)
          | _ => throw (.constructionMismatch reference)
        else throw (.constructionMismatch reference)
      else throw (.constructionMismatch reference)
    else throw (.constructionMismatch reference)

def checkBinding (prepared : PreparedCompositionInput) (state : SearchState)
    (binding : BindingExpr) (destination : SlotContract) (constraint : SourceConstraint) :
    Except WitnessFailure { proof : Unit // BindingJustified prepared state binding destination constraint } :=
  checkBindingFuel prepared state (prepared.input.invocationDomain.permittedConstructions.length + 2)
    binding destination constraint

private def evaluateGuardArm (prepared : PreparedCompositionInput) (guard : DeclaredGuard)
    (contract : SlotContract) (value : SlotValue) : Except WitnessFailure GuardArm :=
  match guard.kind with
  | .validate target => match acceptsSlot prepared.graph target value with
    | .accepted => .ok .accepted
    | .rejected _ => .ok .rejected
    | .unresolved _ => .error (.missingEvidence "validation guard meaning")
  | .presence => .ok (match value with | .absent => .absent | .null => .null | .present _ => .present)
  | .variants => match value with
    | .absent => .ok .absent
    | .null => .ok .null
    | .present (.obj members) => do
      let some (.str tag) := memberValue ((prepared.graph.profile.tag.map (fun (model : TagModel) => model.key)).getD "") members |
        throw (.missingEvidence "union discriminator")
      let some (.taggedUnion spec) := resolvedShape prepared.graph contract.typeRef |
        throw (.missingEvidence "union guard source")
      let some branch := selectUnionBranch prepared.graph.profile spec (.obj members) |
        throw (.missingEvidence "union branch selection")
      pure (.variant branch.wireTag)
    | _ => .error (.missingEvidence "union guard value")

private def guardArms (prepared : PreparedCompositionInput) (state : SearchState)
    (guard : DeclaredGuard) (inspected : ValueRef) : Except WitnessFailure (List GuardArm) := do
  if state.usedGuards.contains guard.id then throw (.guardNotDominating inspected)
  let some source := state.available.find? (fun source => source.producer == inspected.producer) |
    throw (.producerMismatch inspected)
  if source.contract.typeRef != guard.sourceType || inspected.path != guard.path then
    throw (.guardNotDominating inspected)
  let projected ← effectiveProjection prepared state inspected
  match exactValue prepared state inspected with
  | some value => pure [← evaluateGuardArm prepared guard projected.destination value]
  | none =>
    match guard.kind with
    | .validate contract =>
      let obligations := meaningObligations prepared.graph [contract.typeRef]
      if !obligations.isEmpty then throw (.inclusion (.undefinedMeaning obligations))
      pure [.accepted, .rejected]
    | .presence | .variants =>
      let absent := if !projected.destination.required then [GuardArm.absent] else []
      let null := if projected.destination.nullable then [GuardArm.null] else []
      let present ← match guard.kind with
        | .presence => pure [GuardArm.present]
        | .variants =>
          let some (.taggedUnion spec) := resolvedShape prepared.graph projected.destination.typeRef |
            throw (.guardNotDominating inspected)
          pure (spec.branches.map (fun branch => GuardArm.variant branch.wireTag))
        | _ => pure []
      pure (absent ++ null ++ present)

private def afterInvocation (state : SearchState) (invocation : InvocationPlan) (outcome : OutcomeContract) : SearchState :=
  { state with
    available := state.available ++ outcome.valuePorts.map (fun port =>
      { producer := .invocationOutcome invocation.site outcome.id port.id, contract := port.contract,
        resource := port.resourceProduction.map (ResourceLotRef.produced invocation.site outcome.id) })
    usedSites := state.usedSites ++ [invocation.site]
    trace := state.trace ++ [.invocation invocation outcome.id]
    pendingFailure := match outcome.form with
      | .success => none | .declaredFailure => some (.function invocation.function outcome.id) }

private def afterGuard (prepared : PreparedCompositionInput) (state : SearchState)
    (guard : DeclaredGuard) (inspected : ValueRef) (arm : GuardArm) :
    Except WitnessFailure SearchState := do
  let projected ← effectiveProjection prepared state inspected
  let assumptions := match arm with | .variant tag => [.variant inspected.path tag] | _ => []
  let refinement := match guard.kind, arm with
    | .validate contract, .accepted => some contract
    | _, .present | _, .unknownVariant =>
      some { projected.destination with required := true, nullable := false }
    | _, _ => none
  let exact := match arm with
    | .absent => some SlotValue.absent | .null => some SlotValue.null
    | _ => exactValue prepared state inspected
  pure { state with
    usedGuards := state.usedGuards ++ [guard.id]
    facts := state.facts ++ [{ guard := guard.id, inspected, arm, assumptions, refinement, exact }]
    trace := state.trace ++ [.guard guard.id inspected arm]
    pendingFailure := match state.pendingFailure with
      | some origin@(.function _ _) | some origin@(.guard _ .rejected) => some origin
      | _ => match arm with
        | .absent | .null | .unknownVariant | .rejected => some (.guard guard.id arm)
        | _ => state.pendingFailure }

private def stateLots (input : CompositionInput) (state : SearchState) : List ResourceLotRef :=
  input.initialResources.map (fun lot => .initial lot.id) ++
    state.trace.flatMap (fun step => match step with
      | .invocation invocation outcome =>
        ((siteSignature input invocation.site).bind (fun function =>
          function.outcomes.find? (fun branch => branch.id == outcome))).map
          (fun branch => branch.producedResources.map (fun production =>
            .produced invocation.site outcome production.id)) |>.getD []
      | _ => [])

private structure RejectedValue (graph : SemanticGraph) (reference : TypeRef) (path : ValuePath) (value : JsonValue) where
  failure : ValueFailure
  rejected : ¬ ValueMember graph reference path value

private def rejectValueFuel (graph : SemanticGraph) :
    Nat → (reference : TypeRef) → (path : ValuePath) → (value : JsonValue) →
      Option (RejectedValue graph reference path value)
  | 0, _, _, _ => none
  | fuel + 1, reference, path, value =>
    match expansion : expandValue graph reference path value with
    | .unresolved _ => none
    | .rejected failure =>
      have rejected : ¬ ValueMember graph reference path value := by
        intro member
        obtain ⟨children, accepted, _⟩ := member_expansion_has_members graph reference path value member
        rw [expansion] at accepted
        cases accepted
      some { failure, rejected }
    | .requirements children =>
      let rec rejectedChild (requests : List ValueRequirement) :
          Option (Σ request : ValueRequirement,
            { evidence : RejectedValue graph request.typeRef request.valuePath request.value // request ∈ requests }) :=
        match requests with
        | [] => none
        | child :: rest =>
          match rejectValueFuel graph fuel child.typeRef child.valuePath child.value with
          | some failure => some ⟨child, failure, List.mem_cons_self⟩
          | none => match rejectedChild rest with
            | none => none
            | some later => some ⟨later.1, later.2.val, List.mem_cons_of_mem child later.2.property⟩
      match rejectedChild children with
      | none => none
      | some child =>
        let failure := child.2.val
        have rejected : ¬ ValueMember graph reference path value := by
          intro member
          obtain ⟨actual, accepted, members⟩ := member_expansion_has_members graph reference path value member
          have same : actual = children := by
            rw [expansion] at accepted
            exact Expansion.requirements.inj accepted.symm
          subst actual
          exact failure.rejected (members child.1 child.2.property)
        some { failure := failure.failure, rejected }

private def rejectionFailure (reference : TypeRef) (value : SlotValue) (condition : ValueCondition) : ValueFailure :=
  { typeRef := reference, definitionRef := { source := reference.source, name := reference.definitionName },
    origin := { source := reference.source, pointer := reference.pointer }, valuePath := [],
    condition, observed := value, referenceTrace := [] }

def verifyCounterexample (graph : SemanticGraph) (source destination : SlotContract)
    (certificate : CounterexampleCertificate) :
    Except InclusionFailure (CheckedCounterexample graph source destination) := do
  if certificate.basis != SemanticBasis.of graph || certificate.source != source ||
      certificate.destination != destination then throw .basisMismatch
  let sourceMember ← (validateSlot graph source certificate.value).mapError (fun _ => InclusionFailure.counterexampleMismatch)
  match hv : certificate.value with
  | .absent =>
    if required : destination.required = true then
      if certificate.destinationFailure != rejectionFailure destination.typeRef .absent .missingRequired then
        throw .counterexampleMismatch
      pure {
        certificate, sourceMember := ⟨sourceMember.meaning, sourceMember.member⟩,
        destinationRejected := by rw [hv]; exact required_absent_rejected graph destination required }
    else throw .counterexampleMismatch
  | .null =>
    if nonnull : destination.nullable = false then
      if certificate.destinationFailure != rejectionFailure destination.typeRef .null .nullNotAllowed then
        throw .counterexampleMismatch
      pure {
        certificate, sourceMember := ⟨sourceMember.meaning, sourceMember.member⟩,
        destinationRejected := by rw [hv]; exact nonnullable_null_rejected graph destination nonnull }
    else throw .counterexampleMismatch
  | .present value =>
    let some rejected := rejectValueFuel graph
      ((Necoherence.ExactJson.jsonSize value + 1) * (graph.nodes.length + 1)) destination.typeRef [] value |
      throw .counterexampleMismatch
    if rejected.failure != certificate.destinationFailure then throw .counterexampleMismatch
    pure {
      certificate, sourceMember := ⟨sourceMember.meaning, sourceMember.member⟩,
      destinationRejected := by
        rw [hv]
        exact fun member => rejected.rejected (present_has_value_member graph destination value member) }

private def inclusionSamples (graph : SemanticGraph) (source destination : TypeRef)
    (maxObligations : Nat) : SampleResult JsonValue :=
  let bounds : SearchBounds := { maxTypeObligations := maxObligations }
  let generated := sampleValueFuel graph bounds
    (min maxObligations (graph.nodes.length + 1)) [] source
  let candidates := match resolvedShape graph source, resolvedShape graph destination with
    | some (.product source), some (.product destination) =>
      let missingFields := destination.fields.flatMap fun (field : FieldSpec) =>
        if source.fields.any (fun declared => declared.wireName == field.wireName) then []
        else (generated.values.take 1).flatMap fun (sample : JsonValue) => match sample with
          | .obj members =>
            [JsonValue.null, .bool true, .str "x", .str "y", .num 0].map fun value =>
              JsonValue.obj ((field.wireName, value) :: members)
          | _ => []
      let extraValues := match source.extras with
        | .reject => []
        | .allow keyFormat contract =>
          (formatUseSamples graph.profile keyFormat 1).flatMap fun key =>
            (sampleValueFuel graph bounds
              (min maxObligations (graph.nodes.length + 1)) [] contract.typeRef).values.map
              fun value => JsonValue.obj [(key, value)]
      missingFields ++ extraValues
    | _, _ => []
  let additional := candidates.filter fun value =>
    sampleWithinBound bounds.maxSampleLength value &&
      match acceptsValue graph source value with | .accepted => true | _ => false
  { values := generated.values ++ additional
    obligations := generated.obligations ++
      if additional.length = candidates.length then [] else [.sampleBound] }

private theorem inclusionSamples_sound (graph : SemanticGraph) (source destination : TypeRef)
    (maxObligations : Nat) (value : JsonValue)
    (present : value ∈ (inclusionSamples graph source destination maxObligations).values) :
    acceptsValue graph source value = .accepted := by
  simp only [inclusionSamples, List.mem_append] at present
  rcases present with generated | additional
  · exact sampleValueFuel_sound graph { maxTypeObligations := maxObligations }
      (min maxObligations (graph.nodes.length + 1)) [] source value generated
  · have accepted := (List.mem_filter.mp additional).2
    simp only [Bool.and_eq_true] at accepted
    cases decision : acceptsValue graph source value <;>
      simp [decision] at accepted ⊢

private def checkAssignableWithEmpty (graph : SemanticGraph) (emptyRefs : List TypeRef)
    (source destination : SlotContract) (maxObligations : Nat) : CompatibilityDecision graph source destination :=
  match structuralAssignable graph emptyRefs source destination maxObligations with
  | .compatible checked => .compatible checked
  | .incompatible checked => .incompatible checked
  | .unknown obligations =>
    let preparedSamples := inclusionSamples graph source.typeRef destination.typeRef maxObligations
    let samples := (if !source.required then [SlotValue.absent] else []) ++
      (if source.nullable then [.null] else []) ++ preparedSamples.values.map SlotValue.present
    let rec counterexample : List SlotValue → Option (CheckedCounterexample graph source destination)
      | [] => none
      | value :: rest =>
        let failure := match value with
          | .absent => if destination.required then some (rejectionFailure destination.typeRef value .missingRequired) else none
          | .null => if !destination.nullable then some (rejectionFailure destination.typeRef value .nullNotAllowed) else none
          | .present actual => (rejectValueFuel graph ((Necoherence.ExactJson.jsonSize actual + 1) *
              (graph.nodes.length + 1)) destination.typeRef [] actual).map (·.failure)
        match failure with
        | none => counterexample rest
        | some destinationFailure =>
          let certificate : CounterexampleCertificate :=
            { basis := SemanticBasis.of graph, source, destination, value, destinationFailure }
          match verifyCounterexample graph source destination certificate with
          | .ok checked => some checked
          | .error _ => counterexample rest
    match counterexample samples with
    | some checked => .incompatible checked
    | none => .unknown obligations

def checkAssignable (graph : SemanticGraph) (source destination : SlotContract)
    (maxObligations : Nat := 10000) : CompatibilityDecision graph source destination :=
  checkAssignableWithEmpty graph (emptyTypes graph) source destination maxObligations

theorem counterexampleWitnessSound (graph : SemanticGraph) (source destination : SlotContract)
    (checked : CheckedCounterexample graph source destination) :
    Slots graph source checked.certificate.value ∧ ¬ Slots graph destination checked.certificate.value :=
  ⟨checked.sourceMember, fun member => checked.destinationRejected member.2⟩

structure InvocationJustified (prepared : PreparedCompositionInput) (state : SearchState)
    (invocation : InvocationPlan) where
  function : FunctionSignature
  resolved : siteSignature prepared.input invocation.site = some function
  outcomeUnique : (function.outcomes.map (·.id)).Nodup
  identity : function.reference = invocation.function
  fresh : invocation.site ∉ state.usedSites
  inputs : ∀ port ∈ function.inputs, ∃ binding ∈ invocation.bindings,
    binding.1 = port.id ∧ BindingJustified prepared state binding.2 port.contract port.sourceConstraint
  resources : ∀ requirement ∈ function.resourceInputs, ∃ binding ∈ invocation.resources,
    binding.requirement = requirement.id ∧ ∃ declaration,
      declaredLot prepared.input binding.lot = some declaration ∧
      declaration.revision = requirement.requiredRevision ∧
      Nonempty (CheckedInclusion prepared.graph (presentContract declaration.tokenType) (presentContract requirement.tokenType))
  order : ∀ edge ∈ prepared.input.explicitOrder, edge.2 = invocation.site → edge.1 ∈ state.usedSites

private def usesActualFailure (state : SearchState) (origin : FailureOrigin) (sources : List ValueRef) : Bool :=
  match origin with
  | .function reference outcome =>
    let latest := state.trace.reverse.findSome? (fun step => match step with
      | .invocation invocation selected =>
        if invocation.function == reference && selected == outcome then some invocation.site else none
      | _ => none)
    match latest with
    | none => false
    | some actual => sources.any (fun source => match source.producer with
        | .invocationOutcome site selected _ => site == actual && selected == outcome
        | _ => false)
  | .guard id _ =>
    match state.facts.reverse.find? (fun fact => fact.guard == id) with
    | none => false
    | some fact => sources.any (fun source => source.producer == fact.inspected.producer &&
        fact.inspected.path == source.path.take fact.inspected.path.length)

private def checkInvocation (prepared : PreparedCompositionInput) (state : SearchState)
    (invocation : InvocationPlan) : Except WitnessFailure (InvocationJustified prepared state invocation) := do
  let functionFound ← resolveOption (siteSignature prepared.input invocation.site) (.signatureMismatch invocation.site)
  let function := functionFound.val
  let outcomeUnique : { proof : Unit // (function.outcomes.map (·.id)).Nodup } ←
    if unique : (function.outcomes.map (·.id)).Nodup then .ok ⟨(), unique⟩
    else .error (.incompleteBranchCoverage invocation.site.value)
  match function.form with
  | .operation definition =>
    let obligations := prepared.operationMeaning function definition
    if !obligations.isEmpty then throw (.inclusion (.undefinedMeaning obligations))
  | _ => pure ()
  if identity : function.reference = invocation.function then
    if fresh : invocation.site ∉ state.usedSites then
      if function.handlesFailure != state.pendingFailure then throw (.signatureMismatch invocation.site)
      match function.handlesFailure with
      | none => pure ()
      | some origin =>
        if !usesActualFailure state origin (invocation.bindings.flatMap (fun binding => bindingSources binding.2)) then
          throw (.missingEvidence "handler must receive the current failure value")
      if invocation.bindings.length != function.inputs.length ||
          invocation.resources.length != function.resourceInputs.length then throw (.missingBinding invocation.site.value)
      let rec checkPorts (ports : List InputPort) :
          Except WitnessFailure { proof : Unit // ∀ port ∈ ports, ∃ binding ∈ invocation.bindings,
            binding.1 = port.id ∧ BindingJustified prepared state binding.2 port.contract port.sourceConstraint } :=
        match ports with
        | [] => .ok ⟨(), by simp⟩
        | port :: rest => do
          let found ← resolveOption (invocation.bindings.find? (fun binding => decide (binding.1 = port.id)))
            (.missingBinding port.id.value)
          let binding := found.val
          if (invocation.bindings.filter (fun item => item.1 == port.id)).length != 1 then
            throw (.missingBinding port.id.value)
          let checked ← checkBinding prepared state binding.2 port.contract port.sourceConstraint
          match port.resourceRequirement with
          | none => pure ()
          | some requirement =>
            let some resource := invocation.resources.find? (fun resource => resource.requirement == requirement) |
              throw (.missingBinding requirement.value)
            match bindingSources binding.2 with
            | [source] =>
              if (declaredValue prepared.input source.producer).bind (·.2) != some resource.lot then
                throw (.resourceLoweringMismatch "input backing producer")
            | _ => throw (.resourceLoweringMismatch "input backing needs one producer")
          let later ← checkPorts rest
          pure ⟨(), by
            intro item present
            rcases List.mem_cons.mp present with same | remaining
            · subst item
              have correct := find_sound invocation.bindings _ binding found.property
              exact ⟨binding, correct.1, of_decide_eq_true correct.2, checked.property⟩
            · exact later.property item remaining⟩
      let ports ← checkPorts function.inputs
      let rec checkResources (requirements : List ResourceRequirement) :
          Except WitnessFailure { proof : Unit // ∀ requirement ∈ requirements,
            ∃ binding ∈ invocation.resources, binding.requirement = requirement.id ∧ ∃ declaration,
              declaredLot prepared.input binding.lot = some declaration ∧
              declaration.revision = requirement.requiredRevision ∧
              Nonempty (CheckedInclusion prepared.graph (presentContract declaration.tokenType) (presentContract requirement.tokenType)) } :=
        match requirements with
        | [] => .ok ⟨(), by simp⟩
        | requirement :: rest => do
          let found ← resolveOption (invocation.resources.find? (fun binding => decide (binding.requirement = requirement.id)))
            (.missingBinding requirement.id.value)
          let binding := found.val
          if (invocation.resources.filter (fun item => item.requirement == requirement.id)).length != 1 ||
              !(stateLots prepared.input state).contains binding.lot then throw (.missingBinding requirement.id.value)
          let lotFound ← resolveOption (declaredLot prepared.input binding.lot)
            (.resourceLoweringMismatch "resource lot declaration")
          let declaration := lotFound.val
          if revision : declaration.revision = requirement.requiredRevision then
            if requirement.identity != .any && requirement.identity != .exactly declaration.producer then
              throw (.resourceLoweringMismatch "resource producer identity")
            let included ← (verifyInclusion prepared.graph (presentContract declaration.tokenType)
              (presentContract requirement.tokenType) binding.inclusion).mapError WitnessFailure.inclusion
            let later ← checkResources rest
            pure ⟨(), by
              intro item present
              rcases List.mem_cons.mp present with same | remaining
              · subst item
                have correct := find_sound invocation.resources _ binding found.property
                exact ⟨binding, correct.1, of_decide_eq_true correct.2, declaration,
                  lotFound.property, revision, ⟨included⟩⟩
              · exact later.property item remaining⟩
          else throw (.resourceLoweringMismatch "required resource revision")
      let resources ← checkResources function.resourceInputs
      if order : prepared.input.explicitOrder.all (fun edge =>
          if edge.2 == invocation.site then state.usedSites.contains edge.1 else true) = true then
        pure {
          function, resolved := functionFound.property, outcomeUnique := outcomeUnique.property, identity, fresh,
          inputs := ports.property, resources := resources.property,
          order := by
            intro edge declared after
            have here := (List.all_eq_true.mp order) edge declared
            simpa [after] using here }
      else throw .rankViolation
    else throw (.signatureMismatch invocation.site)
  else throw (.signatureMismatch invocation.site)

private def modelValue (profile : VersionedSemanticProfile)
    (model : List (ProducerRef × SlotValue)) (reference : ValueRef) : Option SlotValue :=
  ((model.find? (fun source => source.1 == reference.producer)).map (·.2)).map
    (fun value => projectedValue profile value reference.path)

structure EvaluatedBinding (graph : SemanticGraph) (destination : SlotContract) where
  value : SlotValue
  checked : ValidatedSlot graph destination value

private def evaluateBindingFuel (prepared : PreparedCompositionInput) (model : List (ProducerRef × SlotValue)) :
    Nat → BindingExpr → (destination : SlotContract) → Except WitnessFailure (EvaluatedBinding prepared.graph destination)
  | 0, _, destination => .error (.constructionMismatch destination.typeRef)
  | fuel + 1, .source reference _ _, destination => do
    let some value := modelValue prepared.graph.profile model reference |
      throw (.producerMismatch reference)
    let checked ← (validateSlot prepared.graph destination value).mapError
      (fun _ => WitnessFailure.missingEvidence "model input membership")
    pure { value, checked }
  | fuel + 1, .product _ reference fields, destination => do
    let some (.product product) := resolvedShape prepared.graph reference |
      throw (.constructionMismatch reference)
    let mut members : List (String × JsonValue) := []
    for (name, child) in fields do
      let some field := product.fields.find? (fun field => field.wireName == name) |
        throw (.constructionMismatch reference)
      let evaluated ← evaluateBindingFuel prepared model fuel child field.slot
      match evaluated.value with
      | .absent => pure ()
      | .null => members := members ++ [(name, .null)]
      | .present value => members := members ++ [(name, value)]
    let value := SlotValue.present (.obj members)
    let checked ← (validateSlot prepared.graph destination value).mapError
      (fun _ => WitnessFailure.constructionMismatch reference)
    pure { value, checked }

def evaluateBinding (prepared : PreparedCompositionInput) (model : List (ProducerRef × SlotValue))
    (binding : BindingExpr) (destination : SlotContract) : Except WitnessFailure (EvaluatedBinding prepared.graph destination) :=
  evaluateBindingFuel prepared model (prepared.input.invocationDomain.permittedConstructions.length + 2) binding destination

theorem evaluatedBindingSound (graph : SemanticGraph) (destination : SlotContract)
    (evaluated : EvaluatedBinding graph destination) : Slots graph destination evaluated.value :=
  ⟨evaluated.checked.meaning, evaluated.checked.member⟩

structure TerminalJustified (prepared : PreparedCompositionInput) (state : SearchState) (terminal : ReturnPlan) : Type where
  successBindings : ∀ outputs, terminal = .success outputs →
    ∀ goal ∈ prepared.input.goal.outputs, ∃ binding ∈ outputs, binding.1 = goal.id ∧
      BindingJustified prepared state binding.2 goal.contract goal.sourceConstraint
  failureBinding : ∀ embedding value, terminal = .failure embedding value →
    ∃ declaration ∈ prepared.input.goal.failures, declaration.id = embedding ∧
      state.pendingFailure = some declaration.origin ∧
      BindingJustified prepared state value declaration.contract .anyCompatible

private def checkTerminal (prepared : PreparedCompositionInput) (state : SearchState) (terminal : ReturnPlan) :
    Except WitnessFailure (TerminalJustified prepared state terminal) := do
  match hterm : terminal with
  | .success outputs =>
    if state.pendingFailure.isSome || outputs.length != prepared.input.goal.outputs.length then throw .goalMismatch
    let rec checkGoals (goals : List GoalPort) :
        Except WitnessFailure { proof : Unit // ∀ goal ∈ goals,
          ∃ binding ∈ outputs, binding.1 = goal.id ∧
            BindingJustified prepared state binding.2 goal.contract goal.sourceConstraint } :=
      match goals with
      | [] => .ok ⟨(), by simp⟩
      | goal :: rest => do
        let found ← resolveOption (outputs.find? (fun binding => decide (binding.1 = goal.id))) WitnessFailure.goalMismatch
        if (outputs.filter (fun binding => binding.1 == goal.id)).length != 1 then throw .goalMismatch
        let binding := found.val
        let checked ← checkBinding prepared state binding.2 goal.contract goal.sourceConstraint
        let later ← checkGoals rest
        pure ⟨(), by
          intro item present
          rcases List.mem_cons.mp present with same | remaining
          · subst item
            have correct := find_sound outputs _ binding found.property
            exact ⟨binding, correct.1, of_decide_eq_true correct.2, checked.property⟩
          · exact later.property item remaining⟩
    let checked ← checkGoals prepared.input.goal.outputs
    have successBindings : ∀ actual, terminal = .success actual →
        ∀ goal ∈ prepared.input.goal.outputs, ∃ binding ∈ actual, binding.1 = goal.id ∧
          BindingJustified prepared state binding.2 goal.contract goal.sourceConstraint := by
      intro actual same
      rw [hterm] at same
      cases same
      exact checked.property
    have failureBinding : ∀ embedding value, terminal = .failure embedding value →
        ∃ declaration ∈ prepared.input.goal.failures, declaration.id = embedding ∧
          state.pendingFailure = some declaration.origin ∧
          BindingJustified prepared state value declaration.contract .anyCompatible := by
      intro embedding value impossible
      rw [hterm] at impossible
      cases impossible
    pure { successBindings, failureBinding }
  | .failure embedding value =>
    let found ← resolveOption (prepared.input.goal.failures.find? (fun declaration => decide (declaration.id = embedding)))
      (.failureEmbeddingMismatch embedding)
    let declaration := found.val
    if pending : state.pendingFailure = some declaration.origin then
      if !usesActualFailure state declaration.origin (bindingSources value) then
        throw (.failureEmbeddingMismatch embedding)
      let checked ← checkBinding prepared state value declaration.contract .anyCompatible
      have successBindings : ∀ outputs, terminal = .success outputs →
          ∀ goal ∈ prepared.input.goal.outputs, ∃ binding ∈ outputs, binding.1 = goal.id ∧
            BindingJustified prepared state binding.2 goal.contract goal.sourceConstraint := by
        intro outputs impossible
        rw [hterm] at impossible
        cases impossible
      have failureBinding : ∀ actual actualValue, terminal = .failure actual actualValue →
          ∃ declaration ∈ prepared.input.goal.failures, declaration.id = actual ∧
            state.pendingFailure = some declaration.origin ∧
            BindingJustified prepared state actualValue declaration.contract .anyCompatible := by
        intro actual actualValue same
        rw [hterm] at same
        cases same
        have correct := find_sound prepared.input.goal.failures _ declaration found.property
        exact ⟨declaration, correct.1, of_decide_eq_true correct.2, pending, checked.property⟩
      pure { successBindings, failureBinding }
    else throw (.failureEmbeddingMismatch embedding)

private def verifyModel (prepared : PreparedCompositionInput) (state : SearchState)
    (model : List (ProducerRef × SlotValue)) : Except WitnessFailure Unit := do
  if model.length != state.available.length then throw (.missingEvidence "model producer coverage")
  for source in state.available do
    let some (_, value) := model.find? (fun candidate => candidate.1 == source.producer) |
      throw (.producerMismatch { producer := source.producer, path := [] })
    if (model.filter (fun candidate => candidate.1 == source.producer)).length != 1 then
      throw (.missingEvidence "duplicated model producer")
    let _ ← (validateSlot prepared.graph source.contract value).mapError
      (fun _ => WitnessFailure.missingEvidence "model producer membership")
    match source.producer with
    | .initial id =>
      let some initial := prepared.input.initialInputs.find? (fun initial => initial.id == id) |
        throw (.initialMembership id)
      match initial.source with
      | .argument => pure ()
      | .suppliedValue expected =>
        if expected != value then throw (.suppliedValueMismatch { producer := source.producer, path := [] })
    | _ => pure ()
  let mut current := initialState prepared
  for step in state.trace do
    match step with
    | .invocation invocation outcomeId =>
      let justified ← checkInvocation prepared current invocation
      for port in justified.function.inputs do
        let some (_, binding) := invocation.bindings.find? (fun binding => binding.1 == port.id) |
          throw (.missingBinding port.id.value)
        let _ ← evaluateBinding prepared model binding port.contract
      let some outcome := justified.function.outcomes.find? (fun outcome => outcome.id == outcomeId) |
        throw (.incompleteBranchCoverage outcomeId.value)
      current := afterInvocation current invocation outcome
    | .guard id inspected expected =>
      let some guard := prepared.input.invocationDomain.guards.find? (fun guard => guard.id == id) |
        throw (.guardNotDominating inspected)
      let projected ← effectiveProjection prepared current inspected
      let some value := modelValue prepared.graph.profile model inspected | throw (.producerMismatch inspected)
      let actual ← evaluateGuardArm prepared guard projected.destination value
      if actual != expected then throw (.guardNotDominating inspected)
      current ← afterGuard prepared current guard inspected expected
  if current != state then throw (.missingEvidence "model branch state")

def GoalValues (prepared : PreparedCompositionInput) (outputs : List (GoalPortId × SlotValue)) : Prop :=
  ∀ goal ∈ prepared.input.goal.outputs, ∃ value, (goal.id, value) ∈ outputs ∧ Slots prepared.graph goal.contract value

structure CheckedTerminalValues (prepared : PreparedCompositionInput) (terminal : ReturnPlan) : Type where
  outputs : List (GoalPortId × SlotValue)
  success : ∀ bindings, terminal = .success bindings → GoalValues prepared outputs

private def verifyTerminalValues (prepared : PreparedCompositionInput) (state : SearchState)
    (terminal : ReturnPlan) (model : List (ProducerRef × SlotValue)) :
    Except WitnessFailure (CheckedTerminalValues prepared terminal) := do
  let _ ← checkTerminal prepared state terminal
  verifyModel prepared state model
  match hterm : terminal with
  | .failure id binding =>
    let some embedding := prepared.input.goal.failures.find? (fun embedding => embedding.id == id) |
      throw (.failureEmbeddingMismatch id)
    let _ ← evaluateBinding prepared model binding embedding.contract
    have success : ∀ bindings, terminal = .success bindings → GoalValues prepared [] := by
      intro bindings impossible
      rw [hterm] at impossible
      cases impossible
    pure { outputs := [], success }
  | .success bindings =>
    let rec evaluateGoals (goals : List GoalPort) :
        Except WitnessFailure { outputs : List (GoalPortId × SlotValue) //
          ∀ goal ∈ goals, ∃ value, (goal.id, value) ∈ outputs ∧ Slots prepared.graph goal.contract value } :=
      match goals with
      | [] => .ok ⟨[], by simp⟩
      | goal :: rest => do
        let some (_, binding) := bindings.find? (fun binding => binding.1 == goal.id) | throw .goalMismatch
        let evaluated ← evaluateBinding prepared model binding goal.contract
        let later ← evaluateGoals rest
        pure ⟨(goal.id, evaluated.value) :: later.val, by
          intro item present
          rcases List.mem_cons.mp present with same | remaining
          · subst item
            exact ⟨evaluated.value, List.mem_cons_self, evaluatedBindingSound _ _ evaluated⟩
          · obtain ⟨value, present, accepted⟩ := later.property item remaining
            exact ⟨value, List.mem_cons_of_mem _ present, accepted⟩⟩
    let checked ← evaluateGoals prepared.input.goal.outputs
    have success : ∀ actual, terminal = .success actual → GoalValues prepared checked.val := by
      intro actual same
      exact checked.property
    pure { outputs := checked.val, success }

structure CheckedResourceTrace (prepared : PreparedCompositionInput) (trace : BranchTrace) where
  certificate : ResourceTraceCertificate
  lowered : SolverInput
  correspondence : ResourceCorrespondence
  recomputed : lowerResourceTrace prepared trace = .ok (lowered, correspondence)
  prescribedOrder : certificate.reachability.path = correspondence.executionOrder
  resource : CheckedReachability lowered certificate.reachability
  acyclic : CheckedAcyclic lowered certificate.acyclicity
  terminal : CheckedTerminalValues prepared trace.terminal

private def traceState (prepared : PreparedCompositionInput) (trace : BranchTrace) :
    Except WitnessFailure SearchState := do
  let mut state := initialState prepared
  for step in trace.steps do
    match step with
    | .invocation invocation outcomeId =>
      let justified ← checkInvocation prepared state invocation
      let some outcome := justified.function.outcomes.find? (fun outcome => outcome.id == outcomeId) |
        throw (.incompleteBranchCoverage outcomeId.value)
      state := afterInvocation state invocation outcome
    | .guard id inspected arm =>
      let some guard := prepared.input.invocationDomain.guards.find? (fun guard => guard.id == id) |
        throw (.guardNotDominating inspected)
      let arms ← guardArms prepared state guard inspected
      if !arms.contains arm then throw (.incompleteBranchCoverage id.value)
      state ← afterGuard prepared state guard inspected arm
  pure state

def verifyResourceTrace (prepared : PreparedCompositionInput) (trace : BranchTrace)
    (certificate : ResourceTraceCertificate) : Except WitnessFailure (CheckedResourceTrace prepared trace) := do
  if certificate.trace != trace then throw (.resourceLoweringMismatch "branch trace")
  let state ← traceState prepared trace
  let terminal ← verifyTerminalValues prepared state trace.terminal certificate.valueSources
  match recomputed : lowerResourceTrace prepared trace with
  | .error _ => throw (.resourceLoweringMismatch "selected resources")
  | .ok (lowered, correspondence) =>
    if certificate.lowering ≠ lowered || certificate.correspondence ≠ correspondence then
      throw (.resourceLoweringMismatch "resource input or correspondence")
    if prescribedOrder : certificate.reachability.path = correspondence.executionOrder then
      let resource ← verifyReachabilityWitness lowered certificate.reachability
      let acyclic ← verifyAcyclicWitness lowered certificate.acyclicity
      pure { certificate, lowered, correspondence, recomputed, prescribedOrder, resource, acyclic, terminal }
    else throw (.resourceLoweringMismatch "prescribed resource order")

theorem resourceLoweringSimulation (prepared : PreparedCompositionInput) (trace : BranchTrace)
    (checked : CheckedResourceTrace prepared trace) :
    PathExec checked.lowered checked.lowered.marking checked.correspondence.executionOrder
      checked.certificate.reachability.finalMarking ∧
    (∀ marking bindings place,
      checkReadConsumeAtomicity (tokensAt marking place) (consumedAt bindings marking place)
        (tokensAt (applyConsumption marking bindings) place) = true) ∧
    (∀ transition, producedToken transition =
      { target := transition.identity, index := 0, revision := transition.revision, kind := .output }) := by
  refine ⟨?_, fun marking bindings place => readConsumeAtomicity marking bindings place, producedTokenColor⟩
  simpa [checked.prescribedOrder] using (resourceWitnessSound _ _ checked.resource).1

mutual
  def planBranches (leading : List TraceStep) : PlanTree → List BranchTrace
    | .returnValue _ terminal => [{ steps := leading, terminal }]
    | .invoke _ invocation arms _ => invocationBranches leading invocation arms
    | .guard _ id inspected arms => guardBranches leading id inspected arms
  def invocationBranches (leading : List TraceStep) (invocation : InvocationPlan) :
      List (OutcomeId × PlanTree) → List BranchTrace
    | [] => []
    | (outcome, child) :: rest =>
      planBranches (leading ++ [.invocation invocation outcome]) child ++ invocationBranches leading invocation rest
  def guardBranches (leading : List TraceStep) (id : GuardId) (inspected : ValueRef) :
      List (GuardArm × PlanTree) → List BranchTrace
    | [] => []
    | (arm, child) :: rest =>
      planBranches (leading ++ [.guard id inspected arm]) child ++ guardBranches leading id inspected rest
end

inductive PlanJudgment where
  | tree (state : SearchState) (tree : PlanTree)
  | outcomeArms (state : SearchState) (rank : Nat) (invocation : InvocationPlan)
      (outcomes : List OutcomeContract) (arms : List (OutcomeId × PlanTree))
  | guardArms (state : SearchState) (rank : Nat) (declaration : DeclaredGuard) (inspected : ValueRef)
      (partition : List GuardArm) (arms : List (GuardArm × PlanTree))

inductive PlanJ (prepared : PreparedCompositionInput) : PlanJudgment → Prop where
  | terminal (state : SearchState) (rank : Nat) (terminal : ReturnPlan)
      (checked : TerminalJustified prepared state terminal) :
      PlanJ prepared (.tree state (.returnValue rank terminal))
  | invocation (state : SearchState) (rank : Nat) (invocation : InvocationPlan)
      (arms : List (OutcomeId × PlanTree)) (empty : List OutcomeId)
      (checked : InvocationJustified prepared state invocation)
      (emptySound : ∀ outcome ∈ checked.function.outcomes, outcome.id ∈ empty →
        OutcomeImpossible prepared.graph outcome)
      (coverage : (arms.map (·.1)).Nodup ∧
        ∀ outcome ∈ checked.function.outcomes, outcome.id ∈ empty ∨
          ∃ child, (outcome.id, child) ∈ arms)
      (children : PlanJ prepared (.outcomeArms state rank invocation checked.function.outcomes arms)) :
      PlanJ prepared (.tree state (.invoke rank invocation arms empty))
  | guard (state : SearchState) (rank : Nat) (id : GuardId) (inspected : ValueRef)
      (arms : List (GuardArm × PlanTree)) (declaration : DeclaredGuard)
      (declared : declaration ∈ prepared.input.invocationDomain.guards ∧ declaration.id = id)
      (partition : List GuardArm)
      (computed : guardArms prepared state declaration inspected = .ok partition)
      (coverage : (arms.map (·.1)).Nodup ∧ ∀ arm ∈ partition, ∃ child, (arm, child) ∈ arms)
      (children : PlanJ prepared (.guardArms state rank declaration inspected partition arms)) :
      PlanJ prepared (.tree state (.guard rank id inspected arms))
  | noOutcomeArms (state : SearchState) (rank : Nat) (invocation : InvocationPlan)
      (outcomes : List OutcomeContract) :
      PlanJ prepared (.outcomeArms state rank invocation outcomes [])
  | consOutcomeArms (state : SearchState) (rank : Nat) (invocation : InvocationPlan)
      (outcomes : List OutcomeContract) (id : OutcomeId) (child : PlanTree)
      (rest : List (OutcomeId × PlanTree)) (outcome : OutcomeContract)
      (declared : outcome ∈ outcomes) (named : outcome.id = id) (increasing : rank < child.rank)
      (typed : PlanJ prepared (.tree (afterInvocation state invocation outcome) child))
      (later : PlanJ prepared (.outcomeArms state rank invocation outcomes rest)) :
      PlanJ prepared (.outcomeArms state rank invocation outcomes ((id, child) :: rest))
  | noGuardArms (state : SearchState) (rank : Nat) (declaration : DeclaredGuard) (inspected : ValueRef)
      (partition : List GuardArm) :
      PlanJ prepared (.guardArms state rank declaration inspected partition [])
  | consGuardArms (state : SearchState) (rank : Nat) (declaration : DeclaredGuard) (inspected : ValueRef)
      (partition : List GuardArm) (arm : GuardArm) (child : PlanTree) (rest : List (GuardArm × PlanTree))
      (member : arm ∈ partition) (next : SearchState)
      (transition : afterGuard prepared state declaration inspected arm = .ok next)
      (increasing : rank < child.rank)
      (typed : PlanJ prepared (.tree next child))
      (later : PlanJ prepared (.guardArms state rank declaration inspected partition rest)) :
      PlanJ prepared (.guardArms state rank declaration inspected partition ((arm, child) :: rest))

abbrev PlanJustified (prepared : PreparedCompositionInput) (state : SearchState) (tree : PlanTree) : Prop :=
  PlanJ prepared (.tree state tree)

theorem PlanJ.outcomeChildren {prepared : PreparedCompositionInput} {state : SearchState} {rank : Nat}
    {invocation : InvocationPlan} {outcomes : List OutcomeContract} {arms : List (OutcomeId × PlanTree)}
    (typed : PlanJ prepared (.outcomeArms state rank invocation outcomes arms)) :
    ∀ arm ∈ arms, ∃ outcome ∈ outcomes, outcome.id = arm.1 ∧ rank < arm.2.rank ∧
      PlanJustified prepared (afterInvocation state invocation outcome) arm.2 := by
  cases typed with
  | noOutcomeArms => intro arm present; simp at present
  | consOutcomeArms _ _ _ _ id child rest outcome declared named increasing typed later =>
    intro arm present
    rcases List.mem_cons.mp present with same | remaining
    · subst arm
      exact ⟨outcome, declared, named, increasing, typed⟩
    · exact PlanJ.outcomeChildren later arm remaining

theorem PlanJ.guardChildren {prepared : PreparedCompositionInput} {state : SearchState} {rank : Nat}
    {declaration : DeclaredGuard} {inspected : ValueRef} {partition : List GuardArm}
    {arms : List (GuardArm × PlanTree)}
    (typed : PlanJ prepared (.guardArms state rank declaration inspected partition arms)) :
    ∀ arm ∈ arms, arm.1 ∈ partition ∧ ∃ next,
      afterGuard prepared state declaration inspected arm.1 = .ok next ∧
        rank < arm.2.rank ∧ PlanJustified prepared next arm.2 := by
  cases typed with
  | noGuardArms => intro arm present; simp at present
  | consGuardArms _ _ _ _ _ arm child rest member next transition increasing typed later =>
    intro entry present
    rcases List.mem_cons.mp present with same | remaining
    · subst entry
      exact ⟨member, next, transition, increasing, typed⟩
    · exact PlanJ.guardChildren later entry remaining

private def verifyPlanTreeFuel (prepared : PreparedCompositionInput) :
    Nat → (state : SearchState) → (tree : PlanTree) →
      Except WitnessFailure { proof : Unit // PlanJustified prepared state tree }
  | 0, _, _ => .error .rankViolation
  | fuel + 1, state, .returnValue rank terminal => do
    let checked ← checkTerminal prepared state terminal
    pure ⟨(), .terminal state rank terminal checked⟩
  | fuel + 1, state, .invoke rank invocation arms empty => do
    let checked ← checkInvocation prepared state invocation
    if partition : empty.Nodup ∧
        (∀ outcome ∈ checked.function.outcomes, outcome.id ∈ empty ↔ outcomeEmpty prepared outcome = true) ∧
        (∀ id ∈ empty, id ∈ checked.function.outcomes.map (·.id)) ∧
        (∀ id ∈ empty, id ∉ arms.map (·.1)) then
      if unique : (arms.map (·.1)).Nodup then
        if coverage : ∀ outcome ∈ checked.function.outcomes,
            outcome.id ∈ empty ∨ outcome.id ∈ arms.map (·.1) then
          let rec checkOutcomeArms (entries : List (OutcomeId × PlanTree)) :
              Except WitnessFailure { proof : Unit //
                PlanJ prepared (.outcomeArms state rank invocation checked.function.outcomes entries) } :=
            match entries with
            | [] => .ok ⟨(), .noOutcomeArms state rank invocation checked.function.outcomes⟩
            | (id, child) :: rest => do
              let found ← resolveOption (checked.function.outcomes.find? (fun outcome => decide (outcome.id = id)))
                (.incompleteBranchCoverage id.value)
              if increasing : rank < child.rank then
                let typed ← verifyPlanTreeFuel prepared fuel (afterInvocation state invocation found.val) child
                let later ← checkOutcomeArms rest
                have declared := find_sound checked.function.outcomes _ found.val found.property
                pure ⟨(), .consOutcomeArms state rank invocation checked.function.outcomes id child rest found.val
                  declared.1 (of_decide_eq_true declared.2) increasing typed.property later.property⟩
              else throw .rankViolation
          let children ← checkOutcomeArms arms
          have covered : ∀ outcome ∈ checked.function.outcomes, outcome.id ∈ empty ∨
              ∃ child, (outcome.id, child) ∈ arms := by
            intro outcome present
            rcases coverage outcome present with omitted | included
            · exact .inl omitted
            · obtain ⟨⟨id, child⟩, declared, same⟩ := List.mem_map.mp included
              have identity : id = outcome.id := same
              subst identity
              exact .inr ⟨child, declared⟩
          have emptySound : ∀ outcome ∈ checked.function.outcomes, outcome.id ∈ empty →
              OutcomeImpossible prepared.graph outcome := by
            intro outcome declared omitted
            exact outcomeEmptySound prepared outcome ((partition.2.1 outcome declared).mp omitted)
          pure ⟨(), .invocation state rank invocation arms empty checked emptySound ⟨unique, covered⟩ children.property⟩
        else throw (.incompleteBranchCoverage invocation.site.value)
      else throw (.incompleteBranchCoverage invocation.site.value)
    else throw (.incompleteBranchCoverage invocation.site.value)
  | fuel + 1, state, .guard rank id inspected arms => do
    let found ← resolveOption (prepared.input.invocationDomain.guards.find? (fun guard => decide (guard.id = id)))
      (.guardNotDominating inspected)
    match computed : guardArms prepared state found.val inspected with
    | .error failure => throw failure
    | .ok partition =>
      if unique : (arms.map (·.1)).Nodup then
        if coverage : partition.all (fun arm => (arms.map (·.1)).contains arm) = true then
          let rec checkGuardArms (entries : List (GuardArm × PlanTree)) :
              Except WitnessFailure { proof : Unit //
                PlanJ prepared (.guardArms state rank found.val inspected partition entries) } :=
            match entries with
            | [] => .ok ⟨(), .noGuardArms state rank found.val inspected partition⟩
            | (arm, child) :: rest => do
              if member : arm ∈ partition then
                match transition : afterGuard prepared state found.val inspected arm with
                | .error failure => throw failure
                | .ok next =>
                  if increasing : rank < child.rank then
                    let typed ← verifyPlanTreeFuel prepared fuel next child
                    let later ← checkGuardArms rest
                    pure ⟨(), .consGuardArms state rank found.val inspected partition arm child rest member next
                      transition increasing typed.property later.property⟩
                  else throw .rankViolation
              else throw (.incompleteBranchCoverage id.value)
          let children ← checkGuardArms arms
          have covered : ∀ arm ∈ partition, ∃ child, (arm, child) ∈ arms := by
            intro arm present
            have included := (List.all_eq_true.mp coverage) arm present
            have membership : arm ∈ arms.map (·.1) := by simpa using included
            obtain ⟨⟨identity, child⟩, declared, same⟩ := List.mem_map.mp membership
            have identity' : identity = arm := same
            subst identity'
            exact ⟨child, declared⟩
          have declared := find_sound prepared.input.invocationDomain.guards _ found.val found.property
          pure ⟨(), .guard state rank id inspected arms found.val
            ⟨declared.1, of_decide_eq_true declared.2⟩ partition computed ⟨unique, covered⟩ children.property⟩
        else throw (.incompleteBranchCoverage id.value)
      else throw (.incompleteBranchCoverage id.value)

structure RawCompositionCandidate where
  plan : CompositionPlan
  witness : CompositionWitness
  deriving Repr

structure VerifiedCompositionCandidate (prepared : PreparedCompositionInput) where
  raw : RawCompositionCandidate
  typed : PlanJustified prepared (initialState prepared) raw.plan.root
  branches : ∀ branch ∈ planBranches [] raw.plan.root, Nonempty (CheckedResourceTrace prepared branch)
  success : ∃ branch ∈ planBranches [] raw.plan.root, ∃ outputs, branch.terminal = .success outputs

def verifyCompositionCandidate (prepared : PreparedCompositionInput) (raw : RawCompositionCandidate) :
    Except WitnessFailure (VerifiedCompositionCandidate prepared) := do
  if raw.plan.inputIdentity != prepared.input.identity || raw.plan.inputRevision != prepared.input.revision ||
      raw.witness.inputSnapshot != prepared.input then throw .inputRevisionMismatch
  if raw.witness.initialMembership.length != prepared.input.initialInputs.length then
    throw (.missingEvidence "initial member coverage")
  for initial in prepared.input.initialInputs do
    let some (_, value) := raw.witness.initialMembership.find? (fun member => member.1 == initial.id) |
      throw (.initialMembership initial.id)
    if (raw.witness.initialMembership.filter (fun member => member.1 == initial.id)).length != 1 then
      throw (.initialMembership initial.id)
    let _ ← (validateSlot prepared.graph initial.contract value).mapError (fun _ => WitnessFailure.initialMembership initial.id)
    match initial.source with
    | .argument => pure ()
    | .suppliedValue expected => if value != expected then throw (.initialMembership initial.id)
  if prepared.input.bounds.maxBranchNodes < treeNodeCount raw.plan.root then throw .rankViolation
  let typed ← verifyPlanTreeFuel prepared prepared.input.bounds.maxBranchNodes (initialState prepared) raw.plan.root
  let branches := planBranches [] raw.plan.root
  if branches.length != raw.witness.resourceTraces.length then throw (.missingEvidence "branch resource coverage")
  let rec checkBranches (remaining : List BranchTrace) :
      Except WitnessFailure { proof : Unit // ∀ branch ∈ remaining, Nonempty (CheckedResourceTrace prepared branch) } :=
    match remaining with
    | [] => .ok ⟨(), by simp⟩
    | branch :: rest => do
      let some certificate := raw.witness.resourceTraces.find? (fun certificate => certificate.trace == branch) |
        throw (.missingEvidence "branch resource trace")
      if (raw.witness.resourceTraces.filter (fun certificate => certificate.trace == branch)).length != 1 then
        throw (.missingEvidence "duplicated branch resource trace")
      let checked ← verifyResourceTrace prepared branch certificate
      let later ← checkBranches rest
      pure ⟨(), by
        intro actual present
        rcases List.mem_cons.mp present with same | remaining
        · subst actual; exact ⟨checked⟩
        · exact later.property actual remaining⟩
  let checkedBranches ← checkBranches branches
  match found : branches.find? (fun branch => match branch.terminal with | .success _ => true | _ => false) with
  | none => throw .goalMismatch
  | some branch =>
    have correct := find_sound branches _ branch found
    have successful : ∃ outputs, branch.terminal = .success outputs := by
      cases terminal : branch.terminal with
      | success outputs => exact ⟨outputs, rfl⟩
      | failure _ _ => simp [terminal] at correct
    pure {
      raw, typed := typed.property, branches := checkedBranches.property,
      success := ⟨branch, correct.1, successful⟩ }

inductive LocalAction where
  | invocation (invocation : InvocationPlan)
  | guard (guard : GuardId) (inspected : ValueRef)
  deriving BEq, Repr

structure CompositionClosureNode where
  state : SearchState
  actions : List LocalAction
  terminals : List ResourceTraceCertificate
  deriving Repr

structure CompositionClosureWitness where
  inputIdentity : String
  inputRevision : String
  nodes : List CompositionClosureNode
  steps : Nat
  bindingCandidates : Nat
  branchNodes : Nat
  frontier : List SearchState
  obligations : List UnresolvedObligation
  deriving Repr

inductive SelectionEvidence where
  | anyFeasible
  | unique (complete : CompositionClosureWitness) (canonicalPlan : String)
  deriving Repr

structure RawComposition where
  plan : CompositionPlan
  witness : CompositionWitness
  selection : SelectionEvidence
  deriving Repr

structure Enumeration (α : Type) where
  values : List α := []
  obligations : List UnresolvedObligation := []
  cost : Nat := 0

private def capped (limit : Nat) (values : List α) (reason : UnresolvedObligation) : Enumeration α :=
  { values := values.take limit,
    obligations := if limit < values.length then [reason] else [], cost := values.length }

private def bindingFailureObligation (failure : WitnessFailure) : List UnresolvedObligation :=
  match failure with
  | .inclusion (.undefinedMeaning obligations) => [.meaning obligations]
  | .inclusion (.unresolved obligation) => [.type none [obligation]]
  | .projectionMismatch (.unresolved obligations) => [.meaning obligations]
  | .missingEvidence _ => [.branchBoundExhausted]
  | _ => []

private def enumerateBindingsFuel (prepared : PreparedCompositionInput) (state : SearchState) :
    Nat → SlotContract → SourceConstraint → Enumeration BindingExpr
  | 0, _, _ => { obligations := [.branchBoundExhausted] }
  | fuel + 1, destination, constraint => Id.run do
    let mut result : Enumeration BindingExpr := {}
    for source in state.available do
      let paths := distinct ([] :: (prepared.input.invocationDomain.permittedProjections.filter
          (fun projection => projection.sourceType == source.contract.typeRef)).map (·.path) ++
        (state.facts.filter (fun fact => fact.inspected.producer == source.producer)).map (·.inspected.path))
      for path in paths do
        let value : ValueRef := { producer := source.producer, path }
        if !constraint.accepts value then continue
        result := { result with cost := result.cost + 1 }
        match effectiveProjection prepared state value with
        | .error failure => result := { result with obligations := result.obligations ++ bindingFailureObligation failure }
        | .ok projection =>
          let (binding, obligations) := match exactValue prepared state value with
            | some supplied => match acceptsSlot prepared.graph destination supplied with
              | .accepted => (some (BindingExpr.source value projection (.suppliedValue supplied)), [])
              | .rejected _ => (none, [])
              | .unresolved obligations => (none, [UnresolvedObligation.meaning obligations])
            | none => match checkAssignableWithEmpty prepared.graph prepared.emptyRefs
                projection.destination destination prepared.input.bounds.maxTypeObligations with
              | .compatible included => (some (.source value projection (.inclusion included.certificate)), [])
              | .incompatible _ => (none, [])
              | .unknown obligations => (none, [UnresolvedObligation.type (some value) obligations])
          result := { result with obligations := result.obligations ++ obligations }
          match binding with
          | some binding =>
            match checkBinding prepared state binding destination constraint with
            | .ok _ => result := { result with values := result.values ++ [binding] }
            | .error failure => result := { result with obligations := result.obligations ++ bindingFailureObligation failure }
          | none => pure ()
    if constraint == .anyCompatible then
      for rule in prepared.input.invocationDomain.permittedConstructions do
        if rule.typeRef == destination.typeRef then
          match resolvedShape prepared.graph rule.typeRef with
          | some (.product product) =>
            let mut products : List (List (String × BindingExpr)) := [[]]
            for field in product.fields do
              let choices := enumerateBindingsFuel prepared state fuel field.slot (rule.fieldConstraint field.wireName)
              let allowed := choices.values.filter (fun choice => match choice with
                | .source _ _ _ => true
                | .product child _ _ => rule.nestedFields.any
                  (fun nested => nested.1 == field.wireName && nested.2 == child))
              result := { result with obligations := result.obligations ++ choices.obligations, cost := result.cost + choices.cost }
              let extended := (if field.slot.required || rule.fieldRequired field.wireName then [] else products) ++
                products.flatMap (fun fields => (allowed.take (prepared.input.bounds.maxBindingCandidates + 1)).map
                  (fun binding => fields ++ [(field.wireName, binding)]))
              if prepared.input.bounds.maxBindingCandidates < extended.length then
                result := { result with obligations := result.obligations ++ [.bindingBoundExhausted] }
              products := extended.take prepared.input.bounds.maxBindingCandidates
              if products.isEmpty then break
            for fields in products do
              let binding := BindingExpr.product rule.identity rule.typeRef fields
              match checkBinding prepared state binding destination constraint with
              | .ok _ => result := { result with values := result.values ++ [binding] }
              | .error failure => result := { result with obligations := result.obligations ++ bindingFailureObligation failure }
          | _ => pure ()
    let limited := capped prepared.input.bounds.maxBindingCandidates result.values .bindingBoundExhausted
    return { result with values := limited.values, obligations := result.obligations ++ limited.obligations }

private def enumerateBindings (prepared : PreparedCompositionInput) (state : SearchState)
    (destination : SlotContract) (constraint : SourceConstraint) : Enumeration BindingExpr :=
  enumerateBindingsFuel prepared state (prepared.input.invocationDomain.permittedConstructions.length + 2)
    destination constraint

private def enumerateResources (prepared : PreparedCompositionInput) (state : SearchState)
    (requirement : ResourceRequirement) : Enumeration ResourceBinding := Id.run do
  let mut result : Enumeration ResourceBinding := {}
  for lot in stateLots prepared.input state do
    match declaredLot prepared.input lot with
    | none => pure ()
    | some declaration =>
      if declaration.revision == requirement.requiredRevision &&
          (requirement.identity == .any || requirement.identity == .exactly declaration.producer) then
        result := { result with cost := result.cost + 1 }
        match checkAssignableWithEmpty prepared.graph prepared.emptyRefs (presentContract declaration.tokenType)
            (presentContract requirement.tokenType) prepared.input.bounds.maxTypeObligations with
        | .compatible included => result := { result with values := result.values ++
            [{ requirement := requirement.id, lot, inclusion := included.certificate }] }
        | .incompatible _ => pure ()
        | .unknown obligations => result := { result with obligations := result.obligations ++ [.type none obligations] }
  return result

private def prefixResources (prepared : PreparedCompositionInput) (steps : List TraceStep) :
    Except LoweringFailure Bool := do
  let (lowered, correspondence) ← lowerResourceTraceCore prepared { steps, terminal := .success [] } false
  if lowered.bound.maxBindings < candidateBindingCount lowered then
    throw (.unknown (.resourceSolverUnknown (.bindingBoundExhausted lowered.bound.maxBindings)))
  if lowered.bound.maxSearchSteps < correspondence.executionOrder.length then
    throw (.unknown (.resourceSolverUnknown (.searchStepBoundExhausted lowered.bound.maxSearchSteps)))
  pure (pathReplay lowered lowered.marking correspondence.executionOrder).isSome

def enumerateInvocations (prepared : PreparedCompositionInput) (state : SearchState) :
    Enumeration LocalAction := Id.run do
  let mut result : Enumeration LocalAction := {}
  for site in prepared.input.invocationDomain.sites do
    if !state.usedSites.contains site.id then
      match siteSignature prepared.input site.id with
      | none => pure ()
      | some function =>
        if !(function.outcomes.all (outcomeEmpty prepared)) &&
            function.handlesFailure == state.pendingFailure &&
            prepared.input.explicitOrder.all (fun edge =>
              if edge.2 == site.id then state.usedSites.contains edge.1 else true) then
          let mut inputs : List (List (PortId × BindingExpr)) := [[]]
          for port in function.inputs do
            let choices := enumerateBindings prepared state port.contract port.sourceConstraint
            result := { result with obligations := result.obligations ++ choices.obligations, cost := result.cost + choices.cost }
            let extended := inputs.flatMap (fun selected => choices.values.map (fun binding => selected ++ [(port.id, binding)]))
            if prepared.input.bounds.maxBindingCandidates < extended.length then
              result := { result with obligations := result.obligations ++ [.bindingBoundExhausted] }
            inputs := extended.take prepared.input.bounds.maxBindingCandidates
          let mut resources : List (List ResourceBinding) := [[]]
          for requirement in function.resourceInputs do
            let choices := enumerateResources prepared state requirement
            result := { result with obligations := result.obligations ++ choices.obligations, cost := result.cost + choices.cost }
            let extended := resources.flatMap (fun selected => choices.values.map (fun binding => selected ++ [binding]))
            if prepared.input.bounds.maxBindingCandidates < extended.length then
              result := { result with obligations := result.obligations ++ [.bindingBoundExhausted] }
            resources := extended.take prepared.input.bounds.maxBindingCandidates
          for bindings in inputs do
            for selectedResources in resources do
              let invocation : InvocationPlan :=
                { site := site.id, function := function.reference, bindings, resources := selectedResources }
              match checkInvocation prepared state invocation with
              | .error failure => result := { result with obligations := result.obligations ++ bindingFailureObligation failure }
              | .ok _ =>
                let mut possible := true
                for outcome in function.outcomes.filter (fun outcome => !outcomeEmpty prepared outcome) do
                  match prefixResources prepared (state.trace ++ [.invocation invocation outcome.id]) with
                  | .ok true => pure ()
                  | .ok false | .error (.invalid _) => possible := false
                  | .error (.unknown obligation) =>
                    possible := false
                    result := { result with obligations := result.obligations ++ [obligation] }
                if possible then result := { result with values := result.values ++ [.invocation invocation] }
  return result

def enumerateGuards (prepared : PreparedCompositionInput) (state : SearchState) :
    Enumeration LocalAction := Id.run do
  let mut result : Enumeration LocalAction := {}
  for guard in prepared.input.invocationDomain.guards do
    if !state.usedGuards.contains guard.id then
      for source in state.available do
        if source.contract.typeRef == guard.sourceType then
          let inspected : ValueRef := { producer := source.producer, path := guard.path }
          match guardArms prepared state guard inspected with
          | .ok _ => result := { result with values := result.values ++ [.guard guard.id inspected], cost := result.cost + 1 }
          | .error failure => result := { result with obligations := result.obligations ++ bindingFailureObligation failure }
  return result

def enumerateReturns (prepared : PreparedCompositionInput) (state : SearchState) :
    Enumeration ReturnPlan := Id.run do
  let mut result : Enumeration ReturnPlan := {}
  match state.pendingFailure with
  | none =>
    let mut outputs : List (List (GoalPortId × BindingExpr)) := [[]]
    for goal in prepared.input.goal.outputs do
      let choices := enumerateBindings prepared state goal.contract goal.sourceConstraint
      result := { result with obligations := result.obligations ++ choices.obligations, cost := result.cost + choices.cost }
      let extended := outputs.flatMap (fun selected => choices.values.map (fun binding => selected ++ [(goal.id, binding)]))
      if prepared.input.bounds.maxBindingCandidates < extended.length then
        result := { result with obligations := result.obligations ++ [.bindingBoundExhausted] }
      outputs := extended.take prepared.input.bounds.maxBindingCandidates
    for selectedOutputs in outputs do
      let terminal := ReturnPlan.success selectedOutputs
      match checkTerminal prepared state terminal with
      | .ok _ => result := { result with values := result.values ++ [terminal] }
      | .error failure => result := { result with obligations := result.obligations ++ bindingFailureObligation failure }
  | some origin =>
    for embedding in prepared.input.goal.failures do
      if embedding.origin == origin then
        let choices := enumerateBindings prepared state embedding.contract .anyCompatible
        result := { result with obligations := result.obligations ++ choices.obligations, cost := result.cost + choices.cost }
        for binding in choices.values do
          let terminal := ReturnPlan.failure embedding.id binding
          match checkTerminal prepared state terminal with
          | .ok _ => result := { result with values := result.values ++ [terminal] }
          | .error failure => result := { result with obligations := result.obligations ++ bindingFailureObligation failure }
  return result

def actionSuccessors (prepared : PreparedCompositionInput) (state : SearchState)
    (action : LocalAction) : Except WitnessFailure (List (TraceStep × SearchState)) := do
  match action with
  | .invocation invocation =>
    let checked ← checkInvocation prepared state invocation
    pure ((checked.function.outcomes.filter (fun outcome => !outcomeEmpty prepared outcome)).map (fun outcome =>
      (.invocation invocation outcome.id, afterInvocation state invocation outcome)))
  | .guard id inspected =>
    let some guard := prepared.input.invocationDomain.guards.find? (fun guard => guard.id == id) |
      throw (.guardNotDominating inspected)
    let arms ← guardArms prepared state guard inspected
    arms.mapM (fun arm => do pure (.guard id inspected arm, ← afterGuard prepared state guard inspected arm))

def closureInitialState (prepared : PreparedCompositionInput) : SearchState := initialState prepared

def closureActionSuccessors (prepared : PreparedCompositionInput) (state : SearchState)
    (action : LocalAction) : Except WitnessFailure (List (TraceStep × SearchState)) :=
  actionSuccessors prepared state action

def closureBindingCandidates (prepared : PreparedCompositionInput) (state : SearchState) : Nat :=
  (enumerateReturns prepared state).cost + (enumerateInvocations prepared state).cost +
    (enumerateGuards prepared state).cost

private def findClosureNode (witness : CompositionClosureWitness) (state : SearchState) : Option CompositionClosureNode :=
  witness.nodes.find? (fun node => node.state == state)

private def enumeratePrograms (prepared : PreparedCompositionInput) (witness : CompositionClosureWitness) :
    Nat → SearchState → Enumeration PlanTree
  | 0, _ => { obligations := [.branchBoundExhausted] }
  | fuel + 1, state => Id.run do
    let some node := findClosureNode witness state |
      return { obligations := [.stateBoundExhausted] }
    let rank := state.trace.length
    let mut result : Enumeration PlanTree :=
      { values := node.terminals.map (fun certificate => .returnValue rank certificate.trace.terminal) }
    for action in node.actions do
      match actionSuccessors prepared state action with
      | .error failure => result := { result with obligations := result.obligations ++ bindingFailureObligation failure }
      | .ok successors =>
        let mut choices : List (List (TraceStep × PlanTree)) := [[]]
        for (step, next) in successors do
          let child := enumeratePrograms prepared witness fuel next
          result := { result with obligations := result.obligations ++ child.obligations, cost := result.cost + child.cost }
          let extended := choices.flatMap (fun selected => child.values.map (fun tree => selected ++ [(step, tree)]))
          if prepared.input.bounds.maxBranchNodes < extended.length then
            result := { result with obligations := result.obligations ++ [.branchBoundExhausted] }
          choices := extended.take prepared.input.bounds.maxBranchNodes
        for choice in choices do
          match action with
          | .invocation invocation =>
            let arms := choice.filterMap (fun (step, tree) => match step with
              | .invocation _ outcome => some (outcome, tree) | _ => none)
            let omitted := ((siteSignature prepared.input invocation.site).map (fun function =>
              (function.outcomes.filter (outcomeEmpty prepared)).map (·.id))).getD []
            result := { result with values := result.values ++ [.invoke rank invocation arms omitted] }
          | .guard id inspected =>
            let arms := choice.filterMap (fun (step, tree) => match step with
              | .guard _ _ arm => some (arm, tree) | _ => none)
            result := { result with values := result.values ++ [.guard rank id inspected arms] }
    if result.values.any (fun tree => prepared.input.bounds.maxBranchNodes < treeNodeCount tree) then
      result := { result with obligations := result.obligations ++ [.branchBoundExhausted] }
    result := { result with
      values := result.values.filter (fun tree => treeNodeCount tree ≤ prepared.input.bounds.maxBranchNodes) }
    let limited := capped prepared.input.bounds.maxBranchNodes result.values .branchBoundExhausted
    return { result with values := limited.values, obligations := result.obligations ++ limited.obligations }

mutual
  private def hasSuccess : PlanTree → Bool
    | .returnValue _ (.success _) => true
    | .returnValue _ (.failure _ _) => false
    | .invoke _ _ arms _ => outcomesHaveSuccess arms
    | .guard _ _ _ arms => guardsHaveSuccess arms
  private def outcomesHaveSuccess : List (OutcomeId × PlanTree) → Bool
    | [] => false
    | (_, child) :: rest => hasSuccess child || outcomesHaveSuccess rest
  private def guardsHaveSuccess : List (GuardArm × PlanTree) → Bool
    | [] => false
    | (_, child) :: rest => hasSuccess child || guardsHaveSuccess rest
end

def rootPrograms (prepared : PreparedCompositionInput) (witness : CompositionClosureWitness) : Enumeration PlanTree :=
  let programs := enumeratePrograms prepared witness
    (prepared.input.invocationDomain.sites.length + prepared.input.invocationDomain.guards.length + 1)
    (initialState prepared)
  { programs with values := programs.values.filter hasSuccess }

def encodeValuePath (path : ValuePath) : String :=
  encodeTuple (path.map (fun step => match step with
    | .field name => encodeTuple ["field", name]
    | .index index => encodeTuple ["index", toString index]
    | .variant tag => encodeTuple ["variant", tag]))

def encodeGuardArm : GuardArm → String
  | .present => encodeTuple ["present"] | .absent => encodeTuple ["absent"]
  | .null => encodeTuple ["null"] | .variant tag => encodeTuple ["variant", tag]
  | .unknownVariant => encodeTuple ["unknown-variant"] | .accepted => encodeTuple ["accepted"]
  | .rejected => encodeTuple ["rejected"]

mutual
  private def bindingKey : BindingExpr → String
    | .source value _ _ => encodeTuple ["source", producerIdentity value.producer, encodeValuePath value.path]
    | .product rule reference fields =>
      encodeTuple ["product", rule, typeIdentity reference,
        encodeTuple ((fieldKeys fields).mergeSort (fun a b => compare a b != .gt))]
  private def fieldKeys : List (String × BindingExpr) → List String
    | [] => []
    | (name, binding) :: rest => encodeTuple [name, bindingKey binding] :: fieldKeys rest
end

private def invocationKey (invocation : InvocationPlan) : String :=
  let inputs := invocation.bindings.map (fun (id, binding) => encodeTuple [id.value, bindingKey binding])
  let resources := invocation.resources.map (fun binding =>
    encodeTuple [binding.requirement.value, lotIdentity binding.lot])
  encodeTuple [invocation.site.value, functionIdentity invocation.function,
    encodeTuple (inputs.mergeSort (fun a b => compare a b != .gt)),
    encodeTuple (resources.mergeSort (fun a b => compare a b != .gt))]

private def returnKey : ReturnPlan → String
  | .success outputs => encodeTuple ("success" ::
      (outputs.map (fun (id, binding) => encodeTuple [id.value, bindingKey binding])).mergeSort (fun a b => compare a b != .gt))
  | .failure id binding => encodeTuple ["failure", id.value, bindingKey binding]

mutual
  private def controlKey : PlanTree → String
    | .returnValue _ terminal => returnKey terminal
    | .invoke _ invocation arms empty =>
      encodeTuple ["invoke", invocationKey invocation,
        encodeTuple ((outcomeKeys arms).mergeSort (fun a b => compare a b != .gt)),
        encodeTuple ((empty.map (·.value)).mergeSort (fun a b => compare a b != .gt))]
    | .guard _ id value arms =>
      encodeTuple ["guard", id.value, producerIdentity value.producer, encodeValuePath value.path,
        encodeTuple ((guardKeys arms).mergeSort (fun a b => compare a b != .gt))]
  private def outcomeKeys : List (OutcomeId × PlanTree) → List String
    | [] => []
    | (id, child) :: rest => encodeTuple [id.value, controlKey child] :: outcomeKeys rest
  private def guardKeys : List (GuardArm × PlanTree) → List String
    | [] => []
    | (arm, child) :: rest => encodeTuple [encodeGuardArm arm, controlKey child] :: guardKeys rest
end

private def linearIndependent (prepared : PreparedCompositionInput) : PlanTree → Option (List String × String)
  | .returnValue _ terminal => some ([], returnKey terminal)
  | .guard _ _ _ _ => none
  | .invoke _ invocation [(outcome, child)] [] => do
    let function ← siteSignature prepared.input invocation.site
    if function.effect != .pureFunction || !function.resourceInputs.all (fun requirement => requirement.mode == .read) ||
        !function.outcomes.all (fun branch => branch.producedResources.isEmpty) then none
    else do
      let (calls, terminal) ← linearIndependent prepared child
      pure (encodeTuple [invocationKey invocation, outcome.value] :: calls, terminal)
  | _ => none

def canonicalPlanKey (prepared : PreparedCompositionInput) (tree : PlanTree) : String :=
  match linearIndependent prepared tree with
  | none => controlKey tree
  | some (calls, terminal) =>
    encodeTuple ["pure-dependency-graph", encodeTuple (calls.mergeSort (fun a b => compare a b != .gt)), terminal]

private def programKeys (prepared : PreparedCompositionInput) (witness : CompositionClosureWitness) : List String :=
  distinct ((rootPrograms prepared witness).values.map (canonicalPlanKey prepared))

structure CheckedLocalNode (prepared : PreparedCompositionInput) (node : CompositionClosureNode) : Type where
  actionCoverage : (node.actions == (enumerateInvocations prepared node.state).values ++
    (enumerateGuards prepared node.state).values) = true
  terminalEvidence : ∀ certificate ∈ node.terminals,
    Nonempty (CheckedResourceTrace prepared { steps := node.state.trace, terminal := certificate.trace.terminal })

private def verifyLocalNode (prepared : PreparedCompositionInput) (node : CompositionClosureNode) :
    Except WitnessFailure (CheckedLocalNode prepared node) := do
  let invocations := enumerateInvocations prepared node.state
  let guards := enumerateGuards prepared node.state
  let returns := enumerateReturns prepared node.state
  if !invocations.obligations.isEmpty || !guards.obligations.isEmpty || !returns.obligations.isEmpty then
    throw (.forgedClosure "unresolved local meaning or binding obligations")
  if coverage : (node.actions == invocations.values ++ guards.values) = true then
    let mut expected : List ReturnPlan := []
    for terminal in returns.values do
      let trace : BranchTrace := { steps := node.state.trace, terminal }
      match lowerResourceTrace prepared trace with
      | .error _ => throw (.forgedClosure "unresolved terminal resource lowering")
      | .ok (lowered, correspondence) =>
        if lowered.bound.maxBindings < candidateBindingCount lowered ||
            lowered.bound.maxSearchSteps < correspondence.executionOrder.length then
          throw (.forgedClosure "terminal resource bound")
        match pathReplay lowered lowered.marking correspondence.executionOrder with
        | none => pure ()
        | some finalMarking => if evalGoal finalMarking lowered.goal then expected := expected ++ [terminal]
    if (node.terminals.map (·.trace.terminal)) != expected then
      throw (.forgedClosure "terminal alternatives omitted or added")
    let rec checkTerminals (certificates : List ResourceTraceCertificate) :
        Except WitnessFailure { proof : Unit // ∀ certificate ∈ certificates,
          Nonempty (CheckedResourceTrace prepared { steps := node.state.trace, terminal := certificate.trace.terminal }) } :=
      match certificates with
      | [] => .ok ⟨(), by simp⟩
      | certificate :: rest => do
        let checked ← verifyResourceTrace prepared { steps := node.state.trace, terminal := certificate.trace.terminal } certificate
        let later ← checkTerminals rest
        pure ⟨(), by
          intro actual present
          rcases List.mem_cons.mp present with same | remaining
          · subst actual; exact ⟨checked⟩
          · exact later.property actual remaining⟩
    let terminals ← checkTerminals node.terminals
    pure { actionCoverage := coverage, terminalEvidence := terminals.property }
  else throw (.forgedClosure "typed invocation or guard successor coverage")

structure CheckedCompositionClosure (prepared : PreparedCompositionInput) (witness : CompositionClosureWitness) : Type where
  localNodes : ∀ node ∈ witness.nodes, Nonempty (CheckedLocalNode prepared node)
  initial : witness.nodes.any (fun node => node.state == initialState prepared) = true
  successors : ∀ node ∈ witness.nodes, ∀ action ∈ node.actions, ∀ nexts,
    actionSuccessors prepared node.state action = .ok nexts →
    ∀ next ∈ nexts, witness.nodes.any (fun node => node.state == next.2) = true
  frontier : witness.frontier = []
  obligations : witness.obligations = []

def verifyCompositionClosure (prepared : PreparedCompositionInput) (witness : CompositionClosureWitness) :
    Except WitnessFailure (CheckedCompositionClosure prepared witness) := do
  if witness.inputIdentity != prepared.input.identity || witness.inputRevision != prepared.input.revision then
    throw .inputRevisionMismatch
  if witness.steps != witness.nodes.length - 1 || prepared.input.bounds.maxExpandedStates < witness.steps ||
      prepared.input.bounds.maxBindingCandidates < witness.bindingCandidates ||
      prepared.input.bounds.maxBranchNodes < witness.branchNodes then throw (.forgedClosure "composition bounds")
  let actualBindingCandidates := witness.nodes.foldl (fun count node =>
    count + (enumerateReturns prepared node.state).cost + (enumerateInvocations prepared node.state).cost +
      (enumerateGuards prepared node.state).cost) 0
  let actualBranchNodes := witness.nodes.foldl (fun count node =>
    count + node.actions.foldl (fun count action =>
      count + ((actionSuccessors prepared node.state action).toOption.map List.length).getD 0) 0) 0
  if witness.bindingCandidates != actualBindingCandidates || witness.branchNodes != actualBranchNodes then
    throw (.forgedClosure "local binding or branch counts")
  if frontierEmpty : witness.frontier.isEmpty = true then
    if obligationsEmpty : witness.obligations.isEmpty = true then
      if initial : witness.nodes.any (fun node => node.state == initialState prepared) = true then
        let rec checkNodes (nodes : List CompositionClosureNode) :
            Except WitnessFailure { proof : Unit // ∀ node ∈ nodes, Nonempty (CheckedLocalNode prepared node) } :=
          match nodes with
          | [] => .ok ⟨(), by simp⟩
          | node :: rest => do
            let checked ← verifyLocalNode prepared node
            let later ← checkNodes rest
            pure ⟨(), by
              intro actual present
              rcases List.mem_cons.mp present with same | remaining
              · subst actual; exact ⟨checked⟩
              · exact later.property actual remaining⟩
        let nodes ← checkNodes witness.nodes
        let rec checkSuccessors (nodes : List CompositionClosureNode) :
            Except WitnessFailure { proof : Unit // ∀ node ∈ nodes, ∀ action ∈ node.actions, ∀ nexts,
              actionSuccessors prepared node.state action = .ok nexts →
              ∀ next ∈ nexts, witness.nodes.any (fun node => node.state == next.2) = true } :=
          match nodes with
          | [] => .ok ⟨(), by simp⟩
          | node :: rest => do
            let rec checkActions (actions : List LocalAction) :
                Except WitnessFailure { proof : Unit // ∀ action ∈ actions, ∀ nexts,
                  actionSuccessors prepared node.state action = .ok nexts →
                  ∀ next ∈ nexts, witness.nodes.any (fun node => node.state == next.2) = true } :=
              match actions with
              | [] => .ok ⟨(), by simp⟩
              | action :: rest => do
                match computed : actionSuccessors prepared node.state action with
                | .error failure => throw failure
                | .ok nexts =>
                  if covered : nexts.all (fun next => witness.nodes.any (fun node => node.state == next.2)) = true then
                    let later ← checkActions rest
                    pure ⟨(), by
                      intro actual present outcomes same
                      rcases List.mem_cons.mp present with identity | remaining
                      · subst actual
                        have equal : nexts = outcomes := Except.ok.inj (computed.symm.trans same)
                        subst outcomes
                        exact List.all_eq_true.mp covered
                      · exact later.property actual remaining outcomes same⟩
                  else throw (.forgedClosure "typed successor state omitted")
            let checked ← checkActions node.actions
            let later ← checkSuccessors rest
            pure ⟨(), by
              intro actual present
              rcases List.mem_cons.mp present with same | remaining
              · subst actual; exact checked.property
              · exact later.property actual remaining⟩
        let successors ← checkSuccessors witness.nodes
        let enumeration := rootPrograms prepared witness
        if !enumeration.obligations.isEmpty then throw (.forgedClosure "unresolved finite program frontier")
        pure {
          localNodes := nodes.property, initial, successors := successors.property,
          frontier := emptyList_of_isEmpty _ frontierEmpty,
          obligations := emptyList_of_isEmpty _ obligationsEmpty }
      else throw (.forgedClosure "initial composition state omitted")
    else throw (.forgedClosure "unresolved composition obligations")
  else throw (.forgedClosure "unexplored composition frontier")

inductive SelectionJustified (prepared : PreparedCompositionInput) (candidate : VerifiedCompositionCandidate prepared) : Prop where
  | anyFeasible (explicit : prepared.input.selectionPolicy = some .anyFeasible) :
      SelectionJustified prepared candidate
  | unique (closure : CompositionClosureWitness) (checked : CheckedCompositionClosure prepared closure)
      (key : String) (only : programKeys prepared closure = [key])
      (selected : canonicalPlanKey prepared candidate.raw.plan.root = key) :
      SelectionJustified prepared candidate

structure CheckedComposition (prepared : PreparedCompositionInput) where
  candidate : VerifiedCompositionCandidate prepared
  selection : SelectionJustified prepared candidate

def verifyComposition (prepared : PreparedCompositionInput) (raw : RawComposition) :
    Except WitnessFailure (CheckedComposition prepared) := do
  let candidate ← verifyCompositionCandidate prepared { plan := raw.plan, witness := raw.witness }
  match raw.selection with
  | .anyFeasible =>
    if explicit : prepared.input.selectionPolicy = some .anyFeasible then
      pure { candidate, selection := .anyFeasible explicit }
    else throw (.missingEvidence "AnyFeasible policy must be explicit")
  | .unique closure key =>
    if prepared.input.selectionPolicy == some .anyFeasible then
      throw (.missingEvidence "unique evidence does not select the requested policy")
    let checked ← verifyCompositionClosure prepared closure
    if only : programKeys prepared closure = [key] then
      if selected : canonicalPlanKey prepared candidate.raw.plan.root = key then
        pure { candidate, selection := .unique closure checked key only selected }
      else throw (.missingEvidence "selected program differs from canonical unique program")
    else throw (.missingEvidence "closed domain does not have one canonical program")

structure CheckedUnreachable (prepared : PreparedCompositionInput) where
  witness : CompositionClosureWitness
  closure : CheckedCompositionClosure prepared witness
  noPrograms : programKeys prepared witness = []

inductive CompositionDecision (prepared : PreparedCompositionInput) where
  | solved (composition : CheckedComposition prepared)
  | unreachable (closure : CheckedUnreachable prepared)
  | unknown (obligations : List UnresolvedObligation) (frontier : List SearchState)
  | ambiguous (candidates : List (VerifiedCompositionCandidate prepared))
      (distinct : ∃ first ∈ candidates, ∃ second ∈ candidates,
        canonicalPlanKey prepared first.raw.plan.root ≠ canonicalPlanKey prepared second.raw.plan.root)

private def verifyAmbiguity (prepared : PreparedCompositionInput)
    (candidates : List (VerifiedCompositionCandidate prepared)) :
    Except CompositionEngineFailure { proof : Unit // ∃ first ∈ candidates, ∃ second ∈ candidates,
      canonicalPlanKey prepared first.raw.plan.root ≠ canonicalPlanKey prepared second.raw.plan.root } :=
  match candidates with
  | [] => .error (.contractViolation "ambiguity needs checked candidates")
  | first :: rest =>
    match found : rest.find? (fun candidate => decide
        (canonicalPlanKey prepared first.raw.plan.root ≠ canonicalPlanKey prepared candidate.raw.plan.root)) with
    | none => .error (.contractViolation "ambiguity needs distinct canonical programs")
    | some second => .ok ⟨(), by
        have correct := find_sound rest _ second found
        exact ⟨first, List.mem_cons_self, second, List.mem_cons_of_mem first correct.1,
          of_decide_eq_true correct.2⟩⟩


def decideAmbiguous (prepared : PreparedCompositionInput)
    (candidates : List (VerifiedCompositionCandidate prepared)) :
    Except CompositionEngineFailure (CompositionDecision prepared) := do
  let distinction ← verifyAmbiguity prepared candidates
  return .ambiguous candidates distinction.property

def decideUnreachable (prepared : PreparedCompositionInput) (closure : CompositionClosureWitness)
    (checked : CheckedCompositionClosure prepared closure) :
    Except CompositionEngineFailure (CompositionDecision prepared) :=
  if noPrograms : programKeys prepared closure = [] then
    .ok (.unreachable { witness := closure, closure := checked, noPrograms })
  else .error (.contractViolation "closed program keys lack checked candidates")

theorem compositionGoalReachable (prepared : PreparedCompositionInput) (checked : CheckedComposition prepared) :
    ∃ branch ∈ planBranches [] checked.candidate.raw.plan.root,
      ∃ outputs, branch.terminal = .success outputs ∧
        ∃ evidence : CheckedResourceTrace prepared branch,
          GoalValues prepared evidence.terminal.outputs ∧
          PathExec evidence.lowered evidence.lowered.marking evidence.certificate.reachability.path
            evidence.certificate.reachability.finalMarking := by
  obtain ⟨branch, present, outputs, successful⟩ := checked.candidate.success
  obtain ⟨evidence⟩ := checked.candidate.branches branch present
  exact ⟨branch, present, outputs, successful, evidence,
    evidence.terminal.success outputs successful, (resourceWitnessSound _ _ evidence.resource).1⟩

theorem checkedWitnessSound (prepared : PreparedCompositionInput) (checked : CheckedComposition prepared) :
    PlanJustified prepared (initialState prepared) checked.candidate.raw.plan.root ∧
    (∀ branch ∈ planBranches [] checked.candidate.raw.plan.root,
      ∃ evidence : CheckedResourceTrace prepared branch,
        PathExec evidence.lowered evidence.lowered.marking evidence.certificate.reachability.path
          evidence.certificate.reachability.finalMarking ∧
        evalGoal evidence.certificate.reachability.finalMarking evidence.lowered.goal = true ∧
        ∀ leading cycle start, PathExec evidence.lowered evidence.lowered.marking leading start →
          cycle ≠ [] → ¬ PathExec evidence.lowered start cycle start) := by
  refine ⟨checked.candidate.typed, ?_⟩
  intro branch present
  obtain ⟨evidence⟩ := checked.candidate.branches branch present
  have sound := resourceWitnessSound _ _ evidence.resource
  exact ⟨evidence, sound.1, sound.2.2,
    fun leading cycle start reached nonempty => resourceAcyclicSound _ _ evidence.acyclic leading cycle start reached nonempty⟩

theorem uniqueSelectionSound (prepared : PreparedCompositionInput) (checked : CheckedComposition prepared)
    (required : prepared.input.selectionPolicy ≠ some .anyFeasible) :
    ∃ closure, Nonempty (CheckedCompositionClosure prepared closure) ∧
      programKeys prepared closure = [canonicalPlanKey prepared checked.candidate.raw.plan.root] := by
  cases checked.selection with
  | anyFeasible explicit => exact False.elim (required explicit)
  | unique closure evidence key only selected => exact ⟨closure, ⟨evidence⟩, by simpa [selected] using only⟩

theorem compositionClosureSound (prepared : PreparedCompositionInput) (checked : CheckedUnreachable prepared) :
    checked.witness.frontier = [] ∧ checked.witness.obligations = [] ∧
    (∀ node ∈ checked.witness.nodes, ∀ action ∈ node.actions, ∀ successors,
      actionSuccessors prepared node.state action = .ok successors →
      ∀ next ∈ successors, checked.witness.nodes.any (fun node => node.state == next.2) = true) ∧
    (∀ tree ∈ (rootPrograms prepared checked.witness).values, False) := by
  refine ⟨checked.closure.frontier, checked.closure.obligations, checked.closure.successors, ?_⟩
  intro tree present
  have keyPresent : canonicalPlanKey prepared tree ∈ programKeys prepared checked.witness := by
    apply distinct_mem
    exact List.mem_map.mpr ⟨tree, present, rfl⟩
  simpa [checked.noPrograms] using keyPresent

mutual
  def PlanEdgesRanked : PlanTree → Prop
    | .returnValue _ _ => True
    | .invoke rank _ arms _ => OutcomeEdgesRanked rank arms
    | .guard rank _ _ arms => GuardEdgesRanked rank arms
  def OutcomeEdgesRanked (rank : Nat) : List (OutcomeId × PlanTree) → Prop
    | [] => True
    | (_, child) :: rest => rank < child.rank ∧ PlanEdgesRanked child ∧ OutcomeEdgesRanked rank rest
  def GuardEdgesRanked (rank : Nat) : List (GuardArm × PlanTree) → Prop
    | [] => True
    | (_, child) :: rest => rank < child.rank ∧ PlanEdgesRanked child ∧ GuardEdgesRanked rank rest
end

mutual
  private theorem justified_edges_ranked (prepared : PreparedCompositionInput) (state : SearchState)
      (tree : PlanTree) (justified : PlanJustified prepared state tree) : PlanEdgesRanked tree := by
    cases tree with
    | returnValue _ _ => trivial
    | invoke rank invocation arms empty =>
      cases justified with
      | invocation _ _ _ _ _ checked emptySound coverage children =>
        apply justified_outcome_edges prepared rank arms
        intro arm present
        obtain ⟨outcome, _, _, increasing, typed⟩ := PlanJ.outcomeChildren children arm present
        exact ⟨increasing, afterInvocation state invocation outcome, typed⟩
    | guard rank id inspected arms =>
      cases justified with
      | guard _ _ _ _ _ declaration declared partition computed coverage children =>
        apply justified_guard_edges prepared rank arms
        intro arm present
        obtain ⟨_, next, _, increasing, typed⟩ := PlanJ.guardChildren children arm present
        exact ⟨increasing, next, typed⟩
  private theorem justified_outcome_edges (prepared : PreparedCompositionInput) (rank : Nat)
      (arms : List (OutcomeId × PlanTree))
      (children : ∀ arm ∈ arms, rank < arm.2.rank ∧ ∃ state, PlanJustified prepared state arm.2) :
      OutcomeEdgesRanked rank arms := by
    cases arms with
    | nil => trivial
    | cons arm rest =>
      obtain ⟨increasing, state, typed⟩ := children arm List.mem_cons_self
      exact ⟨increasing, justified_edges_ranked prepared state arm.2 typed,
        justified_outcome_edges prepared rank rest
          (fun child present => children child (List.mem_cons_of_mem arm present))⟩
  private theorem justified_guard_edges (prepared : PreparedCompositionInput) (rank : Nat)
      (arms : List (GuardArm × PlanTree))
      (children : ∀ arm ∈ arms, rank < arm.2.rank ∧ ∃ state, PlanJustified prepared state arm.2) :
      GuardEdgesRanked rank arms := by
    cases arms with
    | nil => trivial
    | cons arm rest =>
      obtain ⟨increasing, state, typed⟩ := children arm List.mem_cons_self
      exact ⟨increasing, justified_edges_ranked prepared state arm.2 typed,
        justified_guard_edges prepared rank rest
          (fun child present => children child (List.mem_cons_of_mem arm present))⟩
end

theorem compositionRankSound (prepared : PreparedCompositionInput) (checked : CheckedComposition prepared) :
    PlanEdgesRanked checked.candidate.raw.plan.root :=
  justified_edges_ranked prepared (initialState prepared) _ checked.candidate.typed

theorem compositionBindingSound (prepared : PreparedCompositionInput) (state : SearchState)
    (invocation : InvocationPlan) (checked : InvocationJustified prepared state invocation) :
    (∀ port ∈ checked.function.inputs, ∃ binding ∈ invocation.bindings,
      binding.1 = port.id ∧ BindingJustified prepared state binding.2 port.contract port.sourceConstraint) ∧
    (∀ requirement ∈ checked.function.resourceInputs, ∃ binding ∈ invocation.resources,
      binding.requirement = requirement.id ∧ ∃ declaration,
        declaredLot prepared.input binding.lot = some declaration ∧
        declaration.revision = requirement.requiredRevision ∧
        Nonempty (CheckedInclusion prepared.graph (presentContract declaration.tokenType) (presentContract requirement.tokenType))) :=
  ⟨checked.inputs, checked.resources⟩

theorem sourceBindingSemanticSound (prepared : PreparedCompositionInput) (state : SearchState)
    (reference : ValueRef) (projection : ProjectionCertificate) (certificate : InclusionCertificate)
    (destination : SlotContract) (constraint : SourceConstraint)
    (justified : BindingJustified prepared state (.source reference projection (.inclusion certificate)) destination constraint) :
    ∃ computed, effectiveProjection prepared state reference = .ok computed ∧
      constraint.accepts reference = true ∧
      ∀ sourceValue, Slots prepared.graph computed.source sourceValue →
        computed.assumptions.all (slotAssumptionHolds prepared.graph.profile sourceValue) = true →
        Slots prepared.graph destination (projectedValue prepared.graph.profile sourceValue computed.path) := by
  cases justified with
  | source _ _ computed _ _ _ available allowed projected same checkedProjection included =>
    obtain ⟨verified, projectionCheck⟩ := checkedProjection
    refine ⟨computed, projected, allowed, ?_⟩
    intro value accepted guarded
    exact inclusionWitnessSound prepared.graph computed.destination destination included _
      (projectionSlotsSound prepared.graph computed verified value projectionCheck accepted guarded)

theorem suppliedBindingSemanticSound (prepared : PreparedCompositionInput) (state : SearchState)
    (reference : ValueRef) (projection : ProjectionCertificate) (value : SlotValue)
    (destination : SlotContract) (constraint : SourceConstraint)
    (justified : BindingJustified prepared state (.source reference projection (.suppliedValue value)) destination constraint) :
    Slots prepared.graph destination value := by
  cases justified with
  | suppliedValue _ _ _ _ _ _ _ _ _ _ _ _ sourceMember destinationMember =>
    exact ⟨destinationMember.meaning, destinationMember.member⟩
theorem bindingSourceConstraintSound (prepared : PreparedCompositionInput) (state : SearchState)
    (binding : BindingExpr) (destination : SlotContract) (constraint : SourceConstraint)
    (justified : BindingJustified prepared state binding destination constraint)
    (constrained : constraint ≠ .anyCompatible) :
    ∃ reference projection evidence, binding = .source reference projection evidence ∧
      constraint.accepts reference = true := by
  cases justified with
  | source reference projection computed certificate destination constraint available allowed projected same checked included =>
    exact ⟨reference, projection, .inclusion certificate, rfl, allowed⟩
  | suppliedValue reference projection computed supplied destination constraint available allowed projected same checked exactValue sourceMember destinationMember =>
    exact ⟨reference, projection, .suppliedValue supplied, rfl, allowed⟩
  | product => exact False.elim (constrained rfl)

/-- Justified construction retains fields selected by `fieldRequired` and the
`fieldConstraint` declared by the matching permitted construction. -/
theorem constructionFieldConstraintSound (prepared : PreparedCompositionInput) (state : SearchState)
    (construction : String) (reference : TypeRef) (fields : List (String × BindingExpr))
    (destination : SlotContract) (constraint : SourceConstraint)
    (justified : BindingJustified prepared state (.product construction reference fields) destination constraint) :
    ∃ rule product, prepared.input.invocationDomain.permittedConstructions.find?
        (fun candidate => candidate.identity == construction && candidate.typeRef == reference) = some rule ∧
      resolvedShape prepared.graph reference = some (.product product) ∧
      (∀ field ∈ product.fields, rule.fieldRequired field.wireName = true →
        field.wireName ∈ fields.map (·.1)) ∧
      ∀ entry ∈ fields, rule.fieldConstraint entry.1 ≠ .anyCompatible →
        ∃ source projection evidence, entry.2 = .source source projection evidence ∧
          (rule.fieldConstraint entry.1).accepts source = true := by
  cases justified with
  | product _ _ _ _ rule product permitted rootType resolved unique required typed meaning =>
    refine ⟨rule, product, permitted, resolved, ?_, ?_⟩
    · intro field present demanded
      exact required field present (by simp [demanded])
    · intro entry present constrained
      obtain ⟨field, declared, named, child⟩ := FieldsJustified.entry typed entry present
      exact bindingSourceConstraintSound prepared state entry.2 field.slot
        (rule.fieldConstraint entry.1) child constrained

/-- Every field selected by a permitted construction's `fieldRequired` declaration
has a justified binding satisfying its `fieldConstraint`. -/
theorem constructionRequiredFieldSound (prepared : PreparedCompositionInput) (state : SearchState)
    (construction : String) (reference : TypeRef) (fields : List (String × BindingExpr))
    (destination : SlotContract) (constraint : SourceConstraint)
    (justified : BindingJustified prepared state (.product construction reference fields) destination constraint) :
    ∃ rule product, prepared.input.invocationDomain.permittedConstructions.find?
        (fun candidate => candidate.identity == construction && candidate.typeRef == reference) = some rule ∧
      resolvedShape prepared.graph reference = some (.product product) ∧
      ∀ field ∈ product.fields, rule.fieldRequired field.wireName = true →
        ∃ entry ∈ fields, entry.1 = field.wireName ∧
          (∃ declared ∈ product.fields, declared.wireName = entry.1 ∧
            BindingJustified prepared state entry.2 declared.slot (rule.fieldConstraint entry.1)) ∧
          (rule.fieldConstraint entry.1 ≠ .anyCompatible →
            ∃ source projection evidence, entry.2 = .source source projection evidence ∧
              (rule.fieldConstraint entry.1).accepts source = true) := by
  cases justified with
  | product _ _ _ _ rule product permitted rootType resolved unique required typed meaning =>
    refine ⟨rule, product, permitted, resolved, ?_⟩
    intro field present demanded
    have included := required field present (by simp [demanded])
    obtain ⟨entry, member, named⟩ := List.mem_map.mp included
    obtain ⟨declared, declaredMember, declaredName, child⟩ := FieldsJustified.entry typed entry member
    refine ⟨entry, member, named, ⟨declared, declaredMember, declaredName, child⟩, ?_⟩
    exact bindingSourceConstraintSound prepared state entry.2 declared.slot
      (rule.fieldConstraint entry.1) child


theorem selectedResourceStepSimulation (prepared : PreparedCompositionInput) (trace : BranchTrace)
    (checked : CheckedResourceTrace prepared trace) (before after : Marking) (identity : String)
    (step : Step checked.lowered before identity after) :
    ∃ transition ∈ checked.lowered.transitions, transition.identity = identity ∧
      (∀ binding ∈ bindingsFor checked.lowered identity,
        binding.multiplicity ≤ ((tokensAt before binding.place).filter
          (fun token => token.target == binding.identity && token.revision == binding.requiredRevision)).length) ∧
      after = applyBranchAt before transition (bindingsFor checked.lowered identity) ∧
      (∀ place, checkReadConsumeAtomicity (tokensAt before place)
        (consumedAt (bindingsFor checked.lowered identity) before place)
        (tokensAt (applyConsumption before (bindingsFor checked.lowered identity)) place) = true) ∧
      (producedToken transition).target = transition.identity ∧
      (producedToken transition).revision = transition.revision := by
  obtain ⟨transition, present, same, enabled, applied⟩ := step
  refine ⟨transition, present, same, ?_, applied.symm, ?_, rfl, rfl⟩
  · intro binding selected
    have satisfied := (List.all_eq_true.mp enabled) binding selected
    simpa [bindingSatisfiedAt] using satisfied
  · exact fun place => readConsumeAtomicity before (bindingsFor checked.lowered identity) place

theorem successfulTerminalTyped (prepared : PreparedCompositionInput) (state : SearchState)
    (bindings : List (GoalPortId × BindingExpr)) (model : List (ProducerRef × SlotValue))
    (checked : CheckedTerminalValues prepared (.success bindings))
    (_verified : verifyTerminalValues prepared state (.success bindings) model = .ok checked) :
    GoalValues prepared checked.outputs :=
  checked.success bindings rfl

theorem compositionBranchSound (prepared : PreparedCompositionInput) (state : SearchState)
    (rank : Nat) (invocation : InvocationPlan) (arms : List (OutcomeId × PlanTree)) (empty : List OutcomeId)
    (justified : PlanJustified prepared state (.invoke rank invocation arms empty)) :
    ∃ function, siteSignature prepared.input invocation.site = some function ∧
      invocation.site ∉ state.usedSites ∧
      ∀ outcome ∈ function.outcomes, OutcomeImpossible prepared.graph outcome ∨
        ∃ child, (outcome.id, child) ∈ arms ∧ rank < child.rank ∧
          PlanJustified prepared (afterInvocation state invocation outcome) child := by
  cases justified with
  | invocation _ _ _ _ _ checked emptySound coverage children =>
    refine ⟨checked.function, checked.resolved, checked.fresh, ?_⟩
    intro outcome declared
    rcases coverage.2 outcome declared with omitted | selected
    · exact .inl (emptySound outcome declared omitted)
    · obtain ⟨child, selected⟩ := selected
      obtain ⟨actual, actualDeclared, identity, increasing, typed⟩ :=
        PlanJ.outcomeChildren children (outcome.id, child) selected
      have uniqueOutcome : ∀ first ∈ checked.function.outcomes, ∀ second ∈ checked.function.outcomes,
          first.id = second.id → first = second := by
        intro first firstPresent second secondPresent sameId
        exact mapped_nodup_identity_unique _ (·.id) checked.outcomeUnique first second firstPresent secondPresent sameId
      have sameOutcome : actual = outcome := uniqueOutcome actual actualDeclared outcome declared identity
      subst actual
      exact .inr ⟨child, selected, increasing, typed⟩

end Necoherence.SemanticComposition
