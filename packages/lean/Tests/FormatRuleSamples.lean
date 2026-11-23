-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SignatureGeneration

namespace Necoherence.Tests.FormatRuleSamples

open Necoherence.SemanticTypes
open Necoherence.SemanticValidation
open Necoherence.SemanticComposition
open Necoherence.TypeSignatures

private def reference : ProfileRef :=
  { identity := "synthetic", revision := "1", contentDigest := "samples" }

private def library (rule : FormatRule) : TypeSignatureLibrary :=
  { identity := "samples", revision := "1",
    profile := {
      reference,
      formatBindings := [{ name := "subject", reference, rule }] },
    sources := [], definitions := [],
    nodes := [{ id := "text", shape := .string { format := some (.named "subject") } }] }

private def sampleSlots (rule : FormatRule) : List SlotValue :=
  let graph := (library rule).graph
  match graph.nodes.find? (·.ref.definitionName == "text") with
  | none => []
  | some node =>
    let contract : SlotContract := { typeRef := node.ref, required := true, nullable := false }
    let goalPort : GoalPort := { id := ⟨"goal"⟩, contract, sourceConstraint := .anyCompatible }
    let goal : GoalSpec := { outputs := [goalPort], failures := [], finalResources := [] }
    let input : CompositionInput := {
      identity := "composition", revision := "1", basis := SemanticBasis.of graph,
      signatures := [], initialInputs := [], initialResources := [], goal,
      invocationDomain := {
        identity := "domain", revision := "1", sites := [], permittedProjections := [],
        permittedConstructions := [], permittedTransforms := [], guards := [] },
      allowedEffects := [], explicitOrder := [], bounds := {} }
    match prepareDirectComposition graph input (fun _ _ => .ok ()) (fun _ _ => []) with
    | .error _ => []
    | .ok prepared => (slotSamples prepared contract).values

private def hasSamples (rule : FormatRule) : Bool := !(sampleSlots rule).isEmpty

private def yields (rule : FormatRule) (text : String) : Bool :=
  (sampleSlots rule).contains (.present (.str text))

private def part : FormatRule := .literal "a"

private def twoStates : DfaSpec :=
  { stateCount := 2, initialState := 0, acceptingStates := [1],
    transitions := [{ fromState := 0, first := 97, last := 97, toState := 1 }] }

private def calendar : CalendarRule :=
  { allowSecond60 := false, minimumYear := 2000, maximumYear := 2100, rejectUtcYearOutsideRange := true }

private def cases : List (String × FormatRule) := [
  ("literal", .literal "lit"),
  ("sequence of literals", .sequence [.literal "ab", .literal "cd"]),
  ("sequence with optional", .sequence [.literal "a", .optional (.literal "b")]),
  ("optional", .optional (.literal "x")),
  ("choice", .choice [.literal "left", .literal "right"]),
  ("labels with a one-character separator", .labels "." 2 none none part),
  ("labels with a multi-character separator", .labels "::" 2 none none part),
  ("bounded", .bounded .unicodeScalars 1 (.literal "é")),
  ("ascii dfa", .asciiDfa twoStates),
  ("identifier", .identifier "ab" "ab01" none 1 (some 3) ["bad"]),
  ("timestamp", .timestamp calendar),
  ("absolute uri", .absoluteUri (some 64)),
  ("language tag", .languageTag ["i-test"])]

private def caseHasSamples (name : String) : Bool :=
  match cases.find? (·.1 == name) with
  | some entry => hasSamples entry.2
  | none => false

theorem literalHasSamples : caseHasSamples "literal" = true := by native_decide
theorem sequenceOfLiteralsHasSamples : caseHasSamples "sequence of literals" = true := by native_decide
theorem sequenceWithOptionalHasSamples : caseHasSamples "sequence with optional" = true := by native_decide
theorem optionalHasSamples : caseHasSamples "optional" = true := by native_decide
theorem choiceHasSamples : caseHasSamples "choice" = true := by native_decide
theorem singleCharacterSeparatorLabelsHaveSamples :
    caseHasSamples "labels with a one-character separator" = true := by native_decide
theorem multiCharacterSeparatorLabelsHaveSamples :
    caseHasSamples "labels with a multi-character separator" = true := by native_decide
theorem boundedHasSamples : caseHasSamples "bounded" = true := by native_decide
theorem asciiDfaHasSamples : caseHasSamples "ascii dfa" = true := by native_decide
theorem identifierHasSamples : caseHasSamples "identifier" = true := by native_decide
theorem timestampHasSamples : caseHasSamples "timestamp" = true := by native_decide
theorem absoluteUriHasSamples : caseHasSamples "absolute uri" = true := by native_decide
theorem languageTagHasSamples : caseHasSamples "language tag" = true := by native_decide

theorem multiCharacterSeparatorLabelsYieldWholeSeparatorJoin :
    yields (.labels "::" 2 none none part) "a::a" = true := by native_decide

theorem sequenceYieldsConcatenation :
    yields (.sequence [.literal "ab", .literal "cd"]) "abcd" = true := by native_decide

theorem sequenceYieldsEachPartVariation :
    yields (.sequence [.literal "a", .optional (.literal "b")]) "ab" = true := by native_decide

theorem timestampYieldsFirstInstantOfMinimumYear :
    yields (.timestamp calendar) "2000-01-01T00:00:00Z" = true := by native_decide

end Necoherence.Tests.FormatRuleSamples
