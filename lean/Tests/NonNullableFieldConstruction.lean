-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SignatureGeneration

namespace Necoherence.Tests.NonNullableFieldConstruction

open Necoherence.SemanticTypes
open Necoherence.SemanticValidation
open Necoherence.SemanticComposition
open Necoherence.TypeSignatures

private def library (nullable : Bool) : TypeSignatureLibrary :=
  { identity := "nullability", revision := "1",
    profile := {
      reference := { identity := "synthetic", revision := "1", contentDigest := "nullability" } },
    sources := [], definitions := [],
    nodes := [
      { id := "empty", shape := .unit },
      { id := "holder", shape := .product { fields := [
        { wireName := "slot", slot := { typeId := "empty", required := true, nullable } }] } }] }

private def typeNamed (graph : SemanticGraph) (name : String) : Option TypeRef :=
  (graph.nodes.find? (·.ref.definitionName == name)).map (·.ref)

private def nullSource : InputId := ⟨"null-source"⟩

private def constructionOutcome (nullable : Bool) : Option (Except WitnessFailure Unit) := do
  let graph := (library nullable).graph
  let empty ← typeNamed graph "empty"
  let holder ← typeNamed graph "holder"
  let sourceContract : SlotContract := { typeRef := empty, required := true, nullable := false }
  let goalContract : SlotContract := { typeRef := holder, required := true, nullable := false }
  let goalPort : GoalPort := { id := ⟨"goal"⟩, contract := goalContract, sourceConstraint := .anyCompatible }
  let goal : GoalSpec := { outputs := [goalPort], failures := [], finalResources := [] }
  let input : CompositionInput := {
    identity := "composition", revision := "1", basis := SemanticBasis.of graph,
    signatures := [],
    initialInputs := [{ id := nullSource, contract := sourceContract, source := .suppliedValue (.present .null), resource := none }],
    initialResources := [],
    goal := goal,
    invocationDomain := {
      identity := "domain", revision := "1", sites := [], permittedProjections := [],
      permittedConstructions := [{ identity := "build", typeRef := holder, nestedFields := [] }],
      permittedTransforms := [], guards := [] },
    allowedEffects := [], explicitOrder := [], bounds := {} }
  let .ok prepared := prepareDirectComposition graph input (fun _ _ => .ok ()) (fun _ _ => []) | none
  let state : SearchState := {
    available := [{ producer := .initial nullSource, contract := sourceContract, resource := none }],
    usedSites := [], usedGuards := [], facts := [], trace := [], pendingFailure := none }
  let .ok projection := projectSlot graph sourceContract [] | none
  let binding : BindingExpr := .product "build" holder
    [("slot", .source ⟨.initial nullSource, []⟩ projection (.suppliedValue (.present .null)))]
  pure ((checkBinding prepared state binding goalContract .anyCompatible).map fun _ => ())

def presentNullIntoNonNullableFieldRejected : Bool :=
  match constructionOutcome false, typeNamed (library false).graph "holder" with
  | some (.error (.constructionMismatch reference)), some holder => reference == holder
  | _, _ => false

theorem presentNullIntoNonNullableFieldRejected_sound :
    presentNullIntoNonNullableFieldRejected = true := by native_decide

def presentNullIntoNullableFieldAccepted : Bool :=
  match constructionOutcome true with
  | some (.ok _) => true
  | _ => false

theorem presentNullIntoNullableFieldAccepted_sound :
    presentNullIntoNullableFieldAccepted = true := by native_decide

end Necoherence.Tests.NonNullableFieldConstruction
