-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SemanticTypes
import Necoherence.SemanticValidation
import Necoherence.SemanticComposition
import Necoherence.SemanticProfile
import Necoherence.SemanticCodec
import Necoherence.TypeSignatures
import Necoherence.SignatureGeneration
import Necoherence.SignatureComposition
import Necoherence.SemanticExecution
import Necoherence.NetworkHostRetention
import Necoherence.SemanticExecutionQuotient
import Necoherence.SemanticNetwork
import Necoherence.NetworkEffect
import Necoherence.NetworkEffectTest
import Lean

example : ∀ (graph : Necoherence.SemanticTypes.SemanticGraph) (slot : Necoherence.SemanticTypes.SlotContract),
  slot.required = Bool.true →
    ¬Necoherence.SemanticValidation.SlotMember graph slot Necoherence.SemanticTypes.SlotValue.absent := @Necoherence.SemanticValidation.required_absent_rejected

example : ∀ (graph : Necoherence.SemanticTypes.SemanticGraph) (slot : Necoherence.SemanticTypes.SlotContract),
  slot.nullable = Bool.false →
    ¬Necoherence.SemanticValidation.SlotMember graph slot Necoherence.SemanticTypes.SlotValue.null := @Necoherence.SemanticValidation.nonnullable_null_rejected

example : ∀ (graph : Necoherence.SemanticTypes.SemanticGraph) (ref : Necoherence.SemanticTypes.TypeRef)
  (before : Necoherence.ExactJson.JsonValue)
  (defaulted : Necoherence.SemanticValidation.DefaultedValue graph ref before),
  Necoherence.SemanticValidation.ValueMember graph ref [] defaulted.value ∧
    ∀ (application : Necoherence.SemanticValidation.DefaultApplication),
      application ∈ defaulted.applications →
        (Necoherence.SemanticValidation.valueAtPath graph.profile before application.valuePath ==
            Necoherence.SemanticTypes.SlotValue.absent) =
          Bool.true := @Necoherence.SemanticValidation.materialized_value_member

example : ∀ (graph : Necoherence.SemanticTypes.SemanticGraph) (source target : Necoherence.SemanticValidation.ValueRequirement),
  Necoherence.SemanticValidation.MembershipProjection graph source target →
    Necoherence.SemanticValidation.ValueMember graph source.typeRef source.valuePath source.value →
      Necoherence.SemanticValidation.ValueMember graph target.typeRef target.valuePath target.value := @Necoherence.SemanticValidation.projection_member_sound

example : ∀ (graph : Necoherence.SemanticTypes.SemanticGraph)
  (certificate verified : Necoherence.SemanticValidation.ProjectionCertificate)
  (source : Necoherence.SemanticTypes.SlotValue),
  Necoherence.SemanticValidation.checkProjectionCertificate graph certificate = Except.ok verified →
    Necoherence.SemanticValidation.Slots graph certificate.source source →
      certificate.assumptions.all (Necoherence.SemanticValidation.slotAssumptionHolds graph.profile source) =
          Bool.true →
        Necoherence.SemanticValidation.Slots graph certificate.destination
          (Necoherence.SemanticValidation.projectedValue graph.profile source certificate.path) := @Necoherence.SemanticValidation.projectionSlotsSound

example : ∀ (graph : Necoherence.SemanticTypes.SemanticGraph) (slot : Necoherence.SemanticTypes.SlotContract)
  (value : Necoherence.SemanticTypes.SlotValue) (certificate : Necoherence.SemanticValidation.MemberCertificate)
  (checked : Necoherence.SemanticValidation.ValidatedSlot graph slot value),
  Necoherence.SemanticValidation.checkMemberCertificate graph slot value certificate = Except.ok checked →
    Necoherence.SemanticValidation.Slots graph slot value := @Necoherence.SemanticValidation.member_certificate_sound

example : ∀ (graph : Necoherence.SemanticTypes.SemanticGraph) (ref : Necoherence.SemanticTypes.TypeRef)
  (source destination : Necoherence.SemanticTypes.ValuePath) (value : Necoherence.ExactJson.JsonValue),
  Necoherence.SemanticValidation.ValueMember graph ref source value →
    Necoherence.SemanticValidation.ValueMember graph ref destination value := @Necoherence.SemanticValidation.valueMember_path_irrelevant

example : ∀ (graph : Necoherence.SemanticTypes.SemanticGraph) (refs : List Necoherence.SemanticTypes.TypeRef),
  Necoherence.SemanticValidation.AliasClosed graph refs →
    ∀ (ref : Necoherence.SemanticTypes.TypeRef),
      ref ∈ refs →
        ∀ (path : Necoherence.SemanticTypes.ValuePath) (value : Necoherence.ExactJson.JsonValue),
          ¬Necoherence.SemanticValidation.ValueMember graph ref path value := @Necoherence.SemanticValidation.alias_closed_has_no_member

example : ∀ (graphemeRules : Option Necoherence.SemanticTypes.GraphemeRules)
  (source destination : Necoherence.SemanticTypes.FormatRule) (text : String),
  Necoherence.SemanticValidation.formatRuleIncluded source destination = Bool.true →
    Necoherence.SemanticValidation.formatAccepts graphemeRules source text = Bool.true →
      Necoherence.SemanticValidation.formatAccepts graphemeRules destination text = Bool.true := @Necoherence.SemanticValidation.formatRuleIncluded_sound

example : ∀ (graphemeRules : Option Necoherence.SemanticTypes.GraphemeRules) (value text : String),
  Necoherence.SemanticValidation.formatAccepts graphemeRules (Necoherence.SemanticTypes.FormatRule.literal value) text =
    Decidable.decide (text = value) := @Necoherence.SemanticValidation.formatAccepts_literal

example : ∀ (graphemeRules : Option Necoherence.SemanticTypes.GraphemeRules) (rule : Necoherence.SemanticTypes.FormatRule)
  (text : String),
  Necoherence.SemanticValidation.formatAccepts graphemeRules rule.optional text =
    (text == "" || Necoherence.SemanticValidation.formatAccepts graphemeRules rule text) := @Necoherence.SemanticValidation.formatAccepts_optional

example : ∀ (graphemeRules : Option Necoherence.SemanticTypes.GraphemeRules) (text : String),
  Necoherence.SemanticValidation.formatAccepts graphemeRules (Necoherence.SemanticTypes.FormatRule.sequence []) text =
    (text == "") := @Necoherence.SemanticValidation.formatAccepts_sequence_nil

example : ∀ (graphemeRules : Option Necoherence.SemanticTypes.GraphemeRules) (rule : Necoherence.SemanticTypes.FormatRule)
  (rules : List Necoherence.SemanticTypes.FormatRule) (text : String),
  Necoherence.SemanticValidation.formatAccepts graphemeRules
        (Necoherence.SemanticTypes.FormatRule.sequence (rule :: rules)) text =
      Bool.true ↔
    ∃ (left : String),
      ∃ (right : String),
        text = left ++ right ∧
          Necoherence.SemanticValidation.formatAccepts graphemeRules rule left = Bool.true ∧
            Necoherence.SemanticValidation.formatAccepts graphemeRules
                (Necoherence.SemanticTypes.FormatRule.sequence rules) right =
              Bool.true := @Necoherence.SemanticValidation.formatAccepts_sequence_cons

example : ∀ (graphemeRules : Option Necoherence.SemanticTypes.GraphemeRules) (separator : String) (minimum : Nat)
  (maximum total : Option Nat) (rule : Necoherence.SemanticTypes.FormatRule) (text : String),
  Necoherence.SemanticValidation.formatAccepts graphemeRules
        (Necoherence.SemanticTypes.FormatRule.labels separator minimum maximum total rule) text =
      Bool.true ↔
    separator ≠ "" ∧
      minimum ≤ (Necoherence.SemanticValidation.labelParts separator text).length ∧
        (∀ (bound : Nat),
            maximum = Option.some bound → (Necoherence.SemanticValidation.labelParts separator text).length ≤ bound) ∧
          (∀ (bound : Nat), total = Option.some bound → text.length ≤ bound) ∧
            ∀ (label : String),
              label ∈ Necoherence.SemanticValidation.labelParts separator text →
                Necoherence.SemanticValidation.formatAccepts graphemeRules rule label = Bool.true := @Necoherence.SemanticValidation.formatAccepts_labels

example : ∀ (graphemeRules : Option Necoherence.SemanticTypes.GraphemeRules) (unit : Necoherence.SemanticTypes.StringLengthUnit)
  (maximum : Nat) (rule : Necoherence.SemanticTypes.FormatRule) (text : String),
  Necoherence.SemanticValidation.formatAccepts graphemeRules
      (Necoherence.SemanticTypes.FormatRule.bounded unit maximum rule) text =
    (Necoherence.SemanticValidation.formatWithin graphemeRules unit maximum text &&
      Necoherence.SemanticValidation.formatAccepts graphemeRules rule text) := @Necoherence.SemanticValidation.formatAccepts_bounded

example : ∀ (graph : Necoherence.SemanticTypes.SemanticGraph) (ref : Necoherence.SemanticTypes.TypeRef)
  (path : Necoherence.SemanticTypes.ValuePath) (node : Necoherence.SemanticTypes.TypeNode) (tag : String)
  (refinements : List Necoherence.SemanticTypes.SealedRefinement)
  (members : List (String × Necoherence.ExactJson.JsonValue)) (form : Necoherence.SemanticTypes.SealedForm)
  (key : String) (condition : Necoherence.SemanticTypes.ValueCondition) (observed : Necoherence.ExactJson.JsonValue),
  node.shape = Necoherence.SemanticTypes.TypeShape.sealed tag refinements →
    Necoherence.SemanticValidation.objectMemberFailure graph.profile members = Option.none →
      Necoherence.SemanticValidation.classOf graph.profile members = Necoherence.SemanticTypes.ObjectClass.sealed form →
        form.tag = tag →
          Necoherence.SemanticValidation.sealedFieldsFailure graph.profile form members =
              Option.some (key, condition, observed) →
            Necoherence.SemanticValidation.expandNode graph ref path (Necoherence.ExactJson.JsonValue.obj members)
                (Option.some node) =
              Necoherence.SemanticValidation.Expansion.rejected
                (Necoherence.SemanticValidation.failureAt ref (path ++ [Necoherence.SemanticTypes.PathStep.field key])
                  (Necoherence.SemanticTypes.SlotValue.present observed) condition) := @Necoherence.SemanticValidation.sealedFieldFailureRejects

example : ∀ (graph : Necoherence.SemanticTypes.SemanticGraph) (ref : Necoherence.SemanticTypes.TypeRef)
  (path : Necoherence.SemanticTypes.ValuePath) (node : Necoherence.SemanticTypes.TypeNode) (tag : String)
  (refinements : List Necoherence.SemanticTypes.SealedRefinement)
  (members : List (String × Necoherence.ExactJson.JsonValue)) (form : Necoherence.SemanticTypes.SealedForm),
  node.shape = Necoherence.SemanticTypes.TypeShape.sealed tag refinements →
    Necoherence.SemanticValidation.objectMemberFailure graph.profile members = Option.none →
      Necoherence.SemanticValidation.classOf graph.profile members = Necoherence.SemanticTypes.ObjectClass.sealed form →
        form.tag = tag →
          Necoherence.SemanticValidation.sealedFieldsFailure graph.profile form members = Option.none →
            Necoherence.SemanticValidation.sealedExtrasFailure graph.profile path form members = Option.none →
              Necoherence.SemanticValidation.sealedRefinementFailure graph.profile members refinements = Option.none →
                Necoherence.SemanticValidation.expandNode graph ref path (Necoherence.ExactJson.JsonValue.obj members)
                    (Option.some node) =
                  Necoherence.SemanticValidation.Expansion.requirements [] := @Necoherence.SemanticValidation.sealedValuePreserved

example : ∀ (graph : Necoherence.SemanticTypes.SemanticGraph) (ref : Necoherence.SemanticTypes.TypeRef)
  (path : Necoherence.SemanticTypes.ValuePath) (node : Necoherence.SemanticTypes.TypeNode) (tag : String)
  (refinements : List Necoherence.SemanticTypes.SealedRefinement)
  (members : List (String × Necoherence.ExactJson.JsonValue)) (form : Necoherence.SemanticTypes.SealedForm)
  (key format text : String),
  node.shape = Necoherence.SemanticTypes.TypeShape.sealed tag refinements →
    Necoherence.SemanticValidation.objectMemberFailure graph.profile members = Option.none →
      Necoherence.SemanticValidation.classOf graph.profile members = Necoherence.SemanticTypes.ObjectClass.sealed form →
        form.tag = tag →
          Necoherence.SemanticValidation.sealedFieldsFailure graph.profile form members = Option.none →
            Necoherence.SemanticValidation.sealedExtrasFailure graph.profile path form members = Option.none →
              Necoherence.SemanticValidation.sealedRefinementFailure graph.profile members refinements =
                  Option.some
                    (key, Necoherence.SemanticTypes.ValueCondition.format format,
                      Necoherence.ExactJson.JsonValue.str text) →
                Necoherence.SemanticValidation.expandNode graph ref path (Necoherence.ExactJson.JsonValue.obj members)
                    (Option.some node) =
                  Necoherence.SemanticValidation.Expansion.rejected
                    (Necoherence.SemanticValidation.failureAt ref
                      (path ++ [Necoherence.SemanticTypes.PathStep.field key])
                      (Necoherence.SemanticTypes.SlotValue.present (Necoherence.ExactJson.JsonValue.str text))
                      (Necoherence.SemanticTypes.ValueCondition.format format)) := @Necoherence.SemanticValidation.sealedStringFormatFailureRejects

example : ∀ (graph : Necoherence.SemanticTypes.SemanticGraph) (ref : Necoherence.SemanticTypes.TypeRef)
  (path : Necoherence.SemanticTypes.ValuePath) (node : Necoherence.SemanticTypes.TypeNode) (tag : String)
  (refinements : List Necoherence.SemanticTypes.SealedRefinement)
  (members : List (String × Necoherence.ExactJson.JsonValue)) (form : Necoherence.SemanticTypes.SealedForm)
  (key : String) (integer : Int),
  node.shape = Necoherence.SemanticTypes.TypeShape.sealed tag refinements →
    Necoherence.SemanticValidation.objectMemberFailure graph.profile members = Option.none →
      Necoherence.SemanticValidation.classOf graph.profile members = Necoherence.SemanticTypes.ObjectClass.sealed form →
        form.tag = tag →
          Necoherence.SemanticValidation.sealedFieldsFailure graph.profile form members = Option.none →
            Necoherence.SemanticValidation.sealedExtrasFailure graph.profile path form members = Option.none →
              Necoherence.SemanticValidation.sealedRefinementFailure graph.profile members refinements =
                  Option.some
                    (key, Necoherence.SemanticTypes.ValueCondition.aboveMaximum,
                      Necoherence.ExactJson.JsonValue.num integer) →
                Necoherence.SemanticValidation.expandNode graph ref path (Necoherence.ExactJson.JsonValue.obj members)
                    (Option.some node) =
                  Necoherence.SemanticValidation.Expansion.rejected
                    (Necoherence.SemanticValidation.failureAt ref
                      (path ++ [Necoherence.SemanticTypes.PathStep.field key])
                      (Necoherence.SemanticTypes.SlotValue.present (Necoherence.ExactJson.JsonValue.num integer))
                      Necoherence.SemanticTypes.ValueCondition.aboveMaximum) := @Necoherence.SemanticValidation.sealedIntegerMaximumFailureRejects

example : ∀ (rules : Necoherence.SemanticTypes.GraphemeRules), Necoherence.SemanticValidation.graphemeBoundaries rules "" = [] := @Necoherence.SemanticValidation.graphemeBoundariesEmpty

example : ∀ (rules : Necoherence.SemanticTypes.GraphemeRules) (text : String),
  text.toList ≠ [] →
    0 ∈ Necoherence.SemanticValidation.graphemeBoundaries rules text ∧
      text.toList.length ∈ Necoherence.SemanticValidation.graphemeBoundaries rules text ∧
        List.Pairwise (fun (x1 x2 : Nat) => x1 < x2) (Necoherence.SemanticValidation.graphemeBoundaries rules text) := @Necoherence.SemanticValidation.graphemeBoundariesInvariant

example : ∀ (rules : Necoherence.SemanticTypes.GraphemeRules) (text : String),
  Necoherence.SemanticValidation.graphemeLength rules text =
    (Necoherence.SemanticValidation.graphemeBoundaries rules text).length - 1 := @Necoherence.SemanticValidation.graphemeLengthFromBoundaries

example : ∀ (graph : Necoherence.SemanticTypes.SemanticGraph) (source destination : Necoherence.SemanticTypes.SlotContract)
  (checked : Necoherence.SemanticComposition.CheckedInclusion graph source destination)
  (value : Necoherence.SemanticTypes.SlotValue),
  Necoherence.SemanticValidation.Slots graph source value → Necoherence.SemanticValidation.Slots graph destination value := @Necoherence.SemanticComposition.inclusionWitnessSound

example : ∀ (graph : Necoherence.SemanticTypes.SemanticGraph) (refs : List Necoherence.SemanticTypes.TypeRef)
  (checked : Necoherence.SemanticComposition.CheckedEmptyTypes graph refs) (ref : Necoherence.SemanticTypes.TypeRef)
  (path : Necoherence.SemanticTypes.ValuePath) (value : Necoherence.ExactJson.JsonValue),
  Necoherence.SemanticValidation.ValueMember graph ref path value → ¬ref ∈ refs := @Necoherence.SemanticComposition.emptyTypesSound

example : ∀ (graph : Necoherence.SemanticTypes.SemanticGraph) (source destination : Necoherence.SemanticTypes.SlotContract)
  (checked : Necoherence.SemanticComposition.CheckedCounterexample graph source destination),
  Necoherence.SemanticValidation.Slots graph source checked.certificate.value ∧
    ¬Necoherence.SemanticValidation.Slots graph destination checked.certificate.value := @Necoherence.SemanticComposition.counterexampleWitnessSound

example : ∀ (input : Necoherence.SolverInput) (witness : Necoherence.ReachabilityWitness)
  (checked : Necoherence.SemanticComposition.CheckedReachability input witness),
  Necoherence.PathExec input input.marking witness.path witness.finalMarking ∧
    Necoherence.pathEnabled input input.marking witness.path = Bool.true ∧
      Necoherence.evalGoal witness.finalMarking input.goal = Bool.true := @Necoherence.SemanticComposition.resourceWitnessSound

example : ∀ (input : Necoherence.SolverInput) (witness : Necoherence.ClosureWitness)
  (checked : Necoherence.SemanticComposition.CheckedClosure input witness) (path : List String)
  (finish : Necoherence.Marking),
  Necoherence.PathExec input input.marking path finish → Necoherence.evalGoal finish input.goal = Bool.false := @Necoherence.SemanticComposition.resourceClosureSound

example : ∀ (input : Necoherence.SolverInput) (witness : Necoherence.AcyclicWitness)
  (checked : Necoherence.SemanticComposition.CheckedAcyclic input witness) (before cycle : List String)
  (start : Necoherence.Marking),
  Necoherence.PathExec input input.marking before start → cycle ≠ [] → ¬Necoherence.PathExec input start cycle start := @Necoherence.SemanticComposition.resourceAcyclicSound

example : ∀ (prepared : Necoherence.SemanticComposition.PreparedCompositionInput)
  (trace : Necoherence.SemanticComposition.BranchTrace)
  (checked : Necoherence.SemanticComposition.CheckedResourceTrace prepared trace),
  Necoherence.PathExec checked.lowered checked.lowered.marking checked.correspondence.executionOrder
      checked.certificate.reachability.finalMarking ∧
    (∀ (marking : Necoherence.Marking) (bindings : List Necoherence.InputBinding) (place : String),
        Necoherence.checkReadConsumeAtomicity (Necoherence.tokensAt marking place)
            (Necoherence.consumedAt bindings marking place)
            (Necoherence.tokensAt (Necoherence.applyConsumption marking bindings) place) =
          Bool.true) ∧
      ∀ (transition : Necoherence.TypedTransition),
        Necoherence.producedToken transition =
          { target := transition.identity, index := 0, revision := transition.revision,
            kind := Necoherence.TokenKind.output } := @Necoherence.SemanticComposition.resourceLoweringSimulation

example : ∀ (prepared : Necoherence.SemanticComposition.PreparedCompositionInput)
  (state : Necoherence.SemanticComposition.SearchState) (reference : Necoherence.SemanticComposition.ValueRef)
  (projection : Necoherence.SemanticValidation.ProjectionCertificate)
  (certificate : Necoherence.SemanticComposition.InclusionCertificate)
  (destination : Necoherence.SemanticTypes.SlotContract)
  (constraint : Necoherence.SemanticComposition.SourceConstraint),
  Necoherence.SemanticComposition.BindingJustified prepared state
      (Necoherence.SemanticComposition.BindingExpr.source reference projection
        (Necoherence.SemanticComposition.BindingCompatibility.inclusion certificate))
      destination constraint →
    ∃ (computed : Necoherence.SemanticValidation.ProjectionCertificate),
      Necoherence.SemanticComposition.effectiveProjection prepared state reference = Except.ok computed ∧
        constraint.accepts reference = Bool.true ∧
          ∀ (sourceValue : Necoherence.SemanticTypes.SlotValue),
            Necoherence.SemanticValidation.Slots prepared.graph computed.source sourceValue →
              computed.assumptions.all
                    (Necoherence.SemanticValidation.slotAssumptionHolds prepared.graph.profile sourceValue) =
                  Bool.true →
                Necoherence.SemanticValidation.Slots prepared.graph destination
                  (Necoherence.SemanticValidation.projectedValue prepared.graph.profile sourceValue computed.path) := @Necoherence.SemanticComposition.sourceBindingSemanticSound

example : ∀ (prepared : Necoherence.SemanticComposition.PreparedCompositionInput)
  (state : Necoherence.SemanticComposition.SearchState) (reference : Necoherence.SemanticComposition.ValueRef)
  (projection : Necoherence.SemanticValidation.ProjectionCertificate) (value : Necoherence.SemanticTypes.SlotValue)
  (destination : Necoherence.SemanticTypes.SlotContract)
  (constraint : Necoherence.SemanticComposition.SourceConstraint),
  Necoherence.SemanticComposition.BindingJustified prepared state
      (Necoherence.SemanticComposition.BindingExpr.source reference projection
        (Necoherence.SemanticComposition.BindingCompatibility.suppliedValue value))
      destination constraint →
    Necoherence.SemanticValidation.Slots prepared.graph destination value := @Necoherence.SemanticComposition.suppliedBindingSemanticSound

example : ∀ (prepared : Necoherence.SemanticComposition.PreparedCompositionInput)
  (state : Necoherence.SemanticComposition.SearchState) (invocation : Necoherence.SemanticComposition.InvocationPlan)
  (checked : Necoherence.SemanticComposition.InvocationJustified prepared state invocation),
  (∀ (port : Necoherence.SemanticComposition.InputPort),
      port ∈ checked.function.inputs →
        ∃ (binding : Necoherence.SemanticComposition.PortId × Necoherence.SemanticComposition.BindingExpr),
          binding ∈ invocation.bindings ∧
            binding.fst = port.id ∧
              Necoherence.SemanticComposition.BindingJustified prepared state binding.snd port.contract
                port.sourceConstraint) ∧
    ∀ (requirement : Necoherence.SemanticComposition.ResourceRequirement),
      requirement ∈ checked.function.resourceInputs →
        ∃ (binding : Necoherence.SemanticComposition.ResourceBinding),
          binding ∈ invocation.resources ∧
            binding.requirement = requirement.id ∧
              ∃ (declaration : Necoherence.SemanticComposition.LotDeclaration),
                Necoherence.SemanticComposition.declaredLot prepared.input binding.lot = Option.some declaration ∧
                  declaration.revision = requirement.requiredRevision ∧
                    Nonempty
                      (Necoherence.SemanticComposition.CheckedInclusion prepared.graph
                        (Necoherence.SemanticComposition.presentContract declaration.tokenType)
                        (Necoherence.SemanticComposition.presentContract requirement.tokenType)) := @Necoherence.SemanticComposition.compositionBindingSound

example : ∀ (prepared : Necoherence.SemanticComposition.PreparedCompositionInput)
  (state : Necoherence.SemanticComposition.SearchState) (rank : Nat)
  (invocation : Necoherence.SemanticComposition.InvocationPlan)
  (arms : List (Necoherence.SemanticComposition.OutcomeId × Necoherence.SemanticComposition.PlanTree))
  (empty : List Necoherence.SemanticComposition.OutcomeId),
  Necoherence.SemanticComposition.PlanJustified prepared state
      (Necoherence.SemanticComposition.PlanTree.invoke rank invocation arms empty) →
    ∃ (function : Necoherence.SemanticComposition.FunctionSignature),
      Necoherence.SemanticComposition.siteSignature prepared.input invocation.site = Option.some function ∧
        ¬invocation.site ∈ state.usedSites ∧
          ∀ (outcome : Necoherence.SemanticComposition.OutcomeContract),
            outcome ∈ function.outcomes →
              Necoherence.SemanticComposition.OutcomeImpossible prepared.graph outcome ∨
                ∃ (child : Necoherence.SemanticComposition.PlanTree),
                  (outcome.id, child) ∈ arms ∧
                    rank < child.rank ∧
                      Necoherence.SemanticComposition.PlanJustified prepared
                        (Necoherence.SemanticComposition.afterInvocation state invocation outcome) child := @Necoherence.SemanticComposition.compositionBranchSound

example : ∀ (prepared : Necoherence.SemanticComposition.PreparedCompositionInput)
  (checked : Necoherence.SemanticComposition.CheckedComposition prepared),
  ∃ (branch : Necoherence.SemanticComposition.BranchTrace),
    branch ∈ Necoherence.SemanticComposition.planBranches [] checked.candidate.raw.plan.root ∧
      ∃ (outputs : List (Necoherence.SemanticComposition.GoalPortId × Necoherence.SemanticComposition.BindingExpr)),
        branch.terminal = Necoherence.SemanticComposition.ReturnPlan.success outputs ∧
          ∃ (evidence : Necoherence.SemanticComposition.CheckedResourceTrace prepared branch),
            Necoherence.SemanticComposition.GoalValues prepared evidence.terminal.outputs ∧
              Necoherence.PathExec evidence.lowered evidence.lowered.marking evidence.certificate.reachability.path
                evidence.certificate.reachability.finalMarking := @Necoherence.SemanticComposition.compositionGoalReachable

example : ∀ (prepared : Necoherence.SemanticComposition.PreparedCompositionInput)
  (checked : Necoherence.SemanticComposition.CheckedComposition prepared),
  Necoherence.SemanticComposition.PlanJustified prepared (Necoherence.SemanticComposition.initialState prepared)
      checked.candidate.raw.plan.root ∧
    ∀ (branch : Necoherence.SemanticComposition.BranchTrace),
      branch ∈ Necoherence.SemanticComposition.planBranches [] checked.candidate.raw.plan.root →
        ∃ (evidence : Necoherence.SemanticComposition.CheckedResourceTrace prepared branch),
          Necoherence.PathExec evidence.lowered evidence.lowered.marking evidence.certificate.reachability.path
              evidence.certificate.reachability.finalMarking ∧
            Necoherence.evalGoal evidence.certificate.reachability.finalMarking evidence.lowered.goal = Bool.true ∧
              ∀ (leading cycle : List String) (start : Necoherence.Marking),
                Necoherence.PathExec evidence.lowered evidence.lowered.marking leading start →
                  cycle ≠ [] → ¬Necoherence.PathExec evidence.lowered start cycle start := @Necoherence.SemanticComposition.checkedWitnessSound

example : ∀ (prepared : Necoherence.SemanticComposition.PreparedCompositionInput)
  (checked : Necoherence.SemanticComposition.CheckedComposition prepared),
  prepared.input.selectionPolicy ≠ Option.some Necoherence.SemanticComposition.SelectionPolicy.anyFeasible →
    ∃ (closure : Necoherence.SemanticComposition.CompositionClosureWitness),
      Nonempty (Necoherence.SemanticComposition.CheckedCompositionClosure prepared closure) ∧
        Necoherence.SemanticComposition.programKeys prepared closure =
          [Necoherence.SemanticComposition.canonicalPlanKey prepared checked.candidate.raw.plan.root] := @Necoherence.SemanticComposition.uniqueSelectionSound

example : ∀ (prepared : Necoherence.SemanticComposition.PreparedCompositionInput)
  (checked : Necoherence.SemanticComposition.CheckedUnreachable prepared),
  checked.witness.frontier = [] ∧
    checked.witness.obligations = [] ∧
      (∀ (node : Necoherence.SemanticComposition.CompositionClosureNode),
          node ∈ checked.witness.nodes →
            ∀ (action : Necoherence.SemanticComposition.LocalAction),
              action ∈ node.actions →
                ∀
                  (successors :
                    List (Necoherence.SemanticComposition.TraceStep × Necoherence.SemanticComposition.SearchState)),
                  Necoherence.SemanticComposition.actionSuccessors prepared node.state action = Except.ok successors →
                    ∀ (next : Necoherence.SemanticComposition.TraceStep × Necoherence.SemanticComposition.SearchState),
                      next ∈ successors →
                        (checked.witness.nodes.any
                            fun (node : Necoherence.SemanticComposition.CompositionClosureNode) =>
                            node.state == next.snd) =
                          Bool.true) ∧
        ∀ (tree : Necoherence.SemanticComposition.PlanTree),
          tree ∈ (Necoherence.SemanticComposition.rootPrograms prepared checked.witness).values → False := @Necoherence.SemanticComposition.compositionClosureSound

example : ∀ (prepared : Necoherence.SemanticComposition.PreparedCompositionInput)
  (checked : Necoherence.SemanticComposition.CheckedComposition prepared),
  Necoherence.SemanticComposition.PlanEdgesRanked checked.candidate.raw.plan.root := @Necoherence.SemanticComposition.compositionRankSound

example : ∀ (prepared : Necoherence.SemanticComposition.PreparedCompositionInput)
  (state : Necoherence.SemanticComposition.SearchState) (binding : Necoherence.SemanticComposition.BindingExpr)
  (destination : Necoherence.SemanticTypes.SlotContract)
  (constraint : Necoherence.SemanticComposition.SourceConstraint),
  Necoherence.SemanticComposition.BindingJustified prepared state binding destination constraint →
    constraint ≠ Necoherence.SemanticComposition.SourceConstraint.anyCompatible →
      ∃ (reference : Necoherence.SemanticComposition.ValueRef),
        ∃ (projection : Necoherence.SemanticValidation.ProjectionCertificate),
          ∃ (evidence : Necoherence.SemanticComposition.BindingCompatibility),
            binding = Necoherence.SemanticComposition.BindingExpr.source reference projection evidence ∧
              constraint.accepts reference = Bool.true := @Necoherence.SemanticComposition.bindingSourceConstraintSound

example : ∀ (prepared : Necoherence.SemanticComposition.PreparedCompositionInput)
  (state : Necoherence.SemanticComposition.SearchState) (construction : String)
  (reference : Necoherence.SemanticTypes.TypeRef) (fields : List (String × Necoherence.SemanticComposition.BindingExpr))
  (destination : Necoherence.SemanticTypes.SlotContract)
  (constraint : Necoherence.SemanticComposition.SourceConstraint),
  Necoherence.SemanticComposition.BindingJustified prepared state
      (Necoherence.SemanticComposition.BindingExpr.product construction reference fields) destination constraint →
    ∃ (rule : Necoherence.SemanticComposition.ConstructionRule),
      ∃ (product : Necoherence.SemanticTypes.ProductSpec),
        List.find?
              (fun (candidate : Necoherence.SemanticComposition.ConstructionRule) =>
                candidate.identity == construction && candidate.typeRef == reference)
              prepared.input.invocationDomain.permittedConstructions =
            Option.some rule ∧
          Necoherence.SemanticComposition.resolvedShape prepared.graph reference =
              Option.some (Necoherence.SemanticTypes.TypeShape.product product) ∧
            (∀ (field : Necoherence.SemanticTypes.FieldSpec),
                field ∈ product.fields →
                  rule.fieldRequired field.wireName = Bool.true →
                    field.wireName ∈
                      List.map (fun (x : String × Necoherence.SemanticComposition.BindingExpr) => x.fst) fields) ∧
              ∀ (entry : String × Necoherence.SemanticComposition.BindingExpr),
                entry ∈ fields →
                  rule.fieldConstraint entry.fst ≠ Necoherence.SemanticComposition.SourceConstraint.anyCompatible →
                    ∃ (source : Necoherence.SemanticComposition.ValueRef),
                      ∃ (projection : Necoherence.SemanticValidation.ProjectionCertificate),
                        ∃ (evidence : Necoherence.SemanticComposition.BindingCompatibility),
                          entry.snd = Necoherence.SemanticComposition.BindingExpr.source source projection evidence ∧
                            (rule.fieldConstraint entry.fst).accepts source = Bool.true := @Necoherence.SemanticComposition.constructionFieldConstraintSound

example : ∀ (prepared : Necoherence.SemanticComposition.PreparedCompositionInput)
  (state : Necoherence.SemanticComposition.SearchState) (construction : String)
  (reference : Necoherence.SemanticTypes.TypeRef) (fields : List (String × Necoherence.SemanticComposition.BindingExpr))
  (destination : Necoherence.SemanticTypes.SlotContract)
  (constraint : Necoherence.SemanticComposition.SourceConstraint),
  Necoherence.SemanticComposition.BindingJustified prepared state
      (Necoherence.SemanticComposition.BindingExpr.product construction reference fields) destination constraint →
    ∃ (rule : Necoherence.SemanticComposition.ConstructionRule),
      ∃ (product : Necoherence.SemanticTypes.ProductSpec),
        List.find?
              (fun (candidate : Necoherence.SemanticComposition.ConstructionRule) =>
                candidate.identity == construction && candidate.typeRef == reference)
              prepared.input.invocationDomain.permittedConstructions =
            Option.some rule ∧
          Necoherence.SemanticComposition.resolvedShape prepared.graph reference =
              Option.some (Necoherence.SemanticTypes.TypeShape.product product) ∧
            ∀ (field : Necoherence.SemanticTypes.FieldSpec),
              field ∈ product.fields →
                rule.fieldRequired field.wireName = Bool.true →
                  ∃ (entry : String × Necoherence.SemanticComposition.BindingExpr),
                    entry ∈ fields ∧
                      entry.fst = field.wireName ∧
                        (∃ (declared : Necoherence.SemanticTypes.FieldSpec),
                            declared ∈ product.fields ∧
                              declared.wireName = entry.fst ∧
                                Necoherence.SemanticComposition.BindingJustified prepared state entry.snd declared.slot
                                  (rule.fieldConstraint entry.fst)) ∧
                          (rule.fieldConstraint entry.fst ≠
                              Necoherence.SemanticComposition.SourceConstraint.anyCompatible →
                            ∃ (source : Necoherence.SemanticComposition.ValueRef),
                              ∃ (projection : Necoherence.SemanticValidation.ProjectionCertificate),
                                ∃ (evidence : Necoherence.SemanticComposition.BindingCompatibility),
                                  entry.snd =
                                      Necoherence.SemanticComposition.BindingExpr.source source projection evidence ∧
                                    (rule.fieldConstraint entry.fst).accepts source = Bool.true) := @Necoherence.SemanticComposition.constructionRequiredFieldSound

example : ∀ {α : Type} {graph : Necoherence.SemanticTypes.SemanticGraph} {ref : Necoherence.SemanticTypes.TypeRef}
  {encode : α → Necoherence.ExactJson.JsonValue} (value : Necoherence.SemanticCodec.CheckedValue α graph ref encode),
  Necoherence.SemanticValidation.ValueMember graph ref [] (encode value.value) := @Necoherence.SemanticCodec.constructedMember

example : ∀ (value : Lean.Json) (table : Necoherence.SemanticProfile.GraphemeTable),
  Necoherence.SemanticProfile.decodeGraphemeTable value = Except.ok table →
    table.tableSha256 =
      Necoherence.Sha256.digest
        (Necoherence.SemanticProfile.graphemeTableBytes table.properties table.extendedPictographic table.indicConjunct) := @Necoherence.SemanticProfile.graphemeTableChecksumSound

example : ∀ (value : Lean.Json) (reference : Necoherence.SemanticTypes.ProfileRef)
  (sources : List Necoherence.SemanticTypes.SourceIdentity) (rules : Necoherence.SemanticProfile.DecodedGrapheme value),
  Necoherence.SemanticProfile.grapheme value reference sources = Except.ok rules →
    ∃ (table : Necoherence.SemanticProfile.GraphemeTable),
      Necoherence.SemanticProfile.decodeGraphemeTable value = Except.ok table ∧
        rules.val.tableSha256 =
          Necoherence.Sha256.digest
            (Necoherence.SemanticProfile.graphemeTableBytes table.properties table.extendedPictographic
              table.indicConjunct) := @Necoherence.SemanticProfile.graphemeDecodeChecksumSound

example : ∀ (library : Necoherence.TypeSignatures.TypeSignatureLibrary)
  (checked : Necoherence.TypeSignatures.CheckedLibrary library),
  Necoherence.TypeSignatures.libraryDeclarationValid library = Bool.true := @Necoherence.TypeSignatures.signatureStructureSound

example : ∀ (library : Necoherence.TypeSignatures.TypeSignatureLibrary)
  (checked : Necoherence.TypeSignatures.CheckedLibrary library) (node : Necoherence.TypeSignatures.Node),
  node ∈ library.nodes →
    ∀ (id : Necoherence.TypeSignatures.TypeId),
      id ∈ node.shape.references →
        ∃ (declared : Necoherence.TypeSignatures.Node), declared ∈ library.nodes ∧ declared.id = id := @Necoherence.TypeSignatures.signatureReferencesSound

example : ∀ (base extended : Necoherence.TypeSignatures.OperationContract)
  (library : Necoherence.TypeSignatures.TypeSignatureLibrary),
  Necoherence.TypeSignatures.operationExtensionValid base extended library = Bool.true →
    ∀ (outcome : Necoherence.TypeSignatures.OutcomeContract), outcome ∈ base.outcomes → outcome ∈ extended.outcomes := @Necoherence.TypeSignatures.signatureBaseOutcomesPreserved

example : ∀ (operation : Necoherence.TypeSignatures.OperationContract) (handled : List String)
  (checked : { _proof : Unit // Necoherence.TypeSignatures.OutcomesCovered operation handled })
  (outcome : Necoherence.TypeSignatures.OutcomeContract), outcome ∈ operation.outcomes → outcome.id ∈ handled := @Necoherence.TypeSignatures.signatureOutcomeCoverageSound

example : ∀ (operation : Necoherence.TypeSignatures.OperationContract) (handled : List String),
  Necoherence.TypeSignatures.OutcomesCovered operation handled →
    ∀ (outcome : Necoherence.TypeSignatures.OutcomeContract),
      outcome ∈ operation.outcomes →
        ∀ (specification : Necoherence.SemanticTypes.Origin),
          outcome.cause = Necoherence.TypeSignatures.OutcomeCause.externalCondition specification → outcome.id ∈ handled := @Necoherence.TypeSignatures.externalOutcomeCoverageSound

example : ∀ (library : Necoherence.TypeSignatures.TypeSignatureLibrary) (annotations : List Necoherence.TypeSignatures.Annotation)
  (groups : List Necoherence.TypeSignatures.DefinitionGroup),
  ({ schema := library.schema, identity := library.identity, revision := library.revision, profile := library.profile,
        sources := library.sources, provenance := library.provenance, groups := groups, annotations := annotations,
        nodes := library.nodes, definitions := library.definitions } : Necoherence.TypeSignatures.TypeSignatureLibrary).graph =
    library.graph := @Necoherence.TypeSignatures.signatureMetadataOrthogonality

example : ∀ (input : Necoherence.SignatureGeneration.Input) (checked : Necoherence.SignatureGeneration.CheckedInput input),
  input.basis = Necoherence.SignatureGeneration.basis input.signatures input.entrypoints input.composition := @Necoherence.SignatureGeneration.signatureBasisSound

example : ∀ (library : Necoherence.TypeSignatures.TypeSignatureLibrary) (annotations : List Necoherence.TypeSignatures.Annotation)
  (groups : List Necoherence.TypeSignatures.DefinitionGroup),
  Necoherence.SignatureGeneration.graphProjection
      ({ schema := library.schema, identity := library.identity, revision := library.revision, profile := library.profile, sources := library.sources, provenance := library.provenance, groups := groups, annotations := annotations, nodes := library.nodes, definitions := library.definitions } : Necoherence.TypeSignatures.TypeSignatureLibrary) =
    Necoherence.SignatureGeneration.graphProjection library := @Necoherence.SignatureGeneration.signatureWireMetadataOrthogonality

example : ∀ (prepared : Necoherence.SemanticComposition.PreparedCompositionInput)
  (state : Necoherence.SemanticComposition.SearchState) (rank : Nat)
  (invocation : Necoherence.SemanticComposition.InvocationPlan)
  (arms : List (Necoherence.SemanticComposition.OutcomeId × Necoherence.SemanticComposition.PlanTree))
  (empty : List Necoherence.SemanticComposition.OutcomeId),
  Necoherence.SemanticComposition.PlanJustified prepared state
      (Necoherence.SemanticComposition.PlanTree.invoke rank invocation arms empty) →
    ∀ (function : Necoherence.SemanticComposition.InvocationJustified prepared state invocation)
      (outcome : Necoherence.SemanticComposition.OutcomeContract),
      outcome ∈ function.function.outcomes →
        ∀ (cause : Necoherence.SignatureComposition.CauseBinding),
          cause.function = function.function.reference →
            cause.outcome = outcome.id →
              ∀ (specification : Necoherence.SemanticTypes.Origin),
                cause.cause = Necoherence.TypeSignatures.OutcomeCause.externalCondition specification →
                  ¬Necoherence.SemanticComposition.OutcomeImpossible prepared.graph outcome →
                    ∃ (child : Necoherence.SemanticComposition.PlanTree), (outcome.id, child) ∈ arms := @Necoherence.SignatureComposition.signatureExternalInvocationCovered

open Lean in
run_meta do
  let allowed : List Name := [`propext, `Quot.sound, `Classical.choice]
  let env ← getEnv
  let mut checked := 0
  for module in [`Necoherence.SemanticTypes, `Necoherence.SemanticValidation, `Necoherence.SemanticComposition, `Necoherence.SemanticProfile, `Necoherence.SemanticCodec, `Necoherence.TypeSignatures, `Necoherence.SignatureGeneration, `Necoherence.SignatureComposition, `Necoherence.SemanticExecution, `Necoherence.SemanticExecutionQuotient, `Necoherence.SemanticNetwork, `Necoherence.NetworkEffect, `Necoherence.NetworkEffectTest, `Necoherence.NetworkHostRetention] do
    let some index := env.header.moduleNames.findIdx? (· == module) | throwError "{module} is not imported"
    let some data := env.header.moduleData[index]? | throwError "{module} has no data"
    for info in data.constants do
      match info with
      | .thmInfo _ | .defnInfo _ =>
        let axioms ← collectAxioms info.name
        let outside := axioms.filter (fun used => !allowed.contains used)
        unless outside.isEmpty do
          throwError "{info.name} depends on the axioms {outside}"
        checked := checked + 1
      | _ => pure ()
  if checked == 0 then throwError "no declaration was checked"
