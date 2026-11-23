-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SignatureProfileWire
import Necoherence.SemanticValidation

namespace Necoherence.FormatProfileAdmission

open Necoherence.SemanticTypes Necoherence.SemanticValidation Necoherence.SignatureWire

private def reference : ProfileRef :=
  { identity := "format-profile", revision := "4", contentDigest := "format-profile" }

private def formats : List FormatRule := [
  .literal "lit",
  .sequence [.literal "a", .literal "b"],
  .optional (.literal "x"),
  .labels "." 2 none none (.literal "a"),
  .bounded .unicodeScalars 1 (.literal "é"),
  .asciiDfa {
    stateCount := 2, initialState := 0, acceptingStates := [1],
    transitions := [{ fromState := 0, first := 97, last := 97, toState := 1 }] },
  .identifier "ab" "ab01" none 1 (some 3) [],
  .timestamp {
    allowSecond60 := false, minimumYear := 2000, maximumYear := 2100,
    rejectUtcYearOutsideRange := true },
  .absoluteUri (some 128),
  .languageTag [],
  .choice [.literal "left", .literal "right"],
  .text,
  .not (.literal "left"),
  .bounded .unicodeScalars 2 .text]

private def profile : VersionedSemanticProfile :=
  { reference
    integerDomains := [{ name := "integer", reference, range := .unbounded, forms := [.number] }]
    defaultIntegerDomain := "integer"
    formatBindings := formats.zipIdx.map fun (rule, index) =>
      { name := "format-" ++ toString index, reference, rule } }

def allGeneralRulesAcceptedAndObserved : Bool :=
  match checkProfile profile with
  | .error _ => false
  | .ok checked =>
    let values := checked.profile.formatBindings.map (·.rule)
    values.length == formats.length &&
      formatAccepts none values[0]! "lit" &&
      formatAccepts none values[1]! "ab" &&
      formatAccepts none values[2]! "x" &&
      formatAccepts none values[2]! "" &&
      formatAccepts none values[3]! "a.a" &&
      formatAccepts none values[4]! "é" &&
      formatAccepts none values[5]! "a" &&
      formatAccepts none values[6]! "a1" &&
      formatAccepts none values[7]! "2024-01-02T03:04:05Z" &&
      formatAccepts none values[8]! "https://example.test/x" &&
      formatAccepts none values[9]! "en-US" &&
      formatAccepts none values[10]! "right" &&
      formatAccepts none values[11]! "anything" &&
      formatAccepts none values[11]! "other" &&
      formatAccepts none values[13]! "ab" &&
      !formatAccepts none values[13]! "abc" &&
      formatAccepts none values[12]! "right" &&
      !formatAccepts none values[0]! "lix" &&
      !formatAccepts none values[1]! "a" &&
      !formatAccepts none values[2]! "y" &&
      !formatAccepts none values[3]! "a" &&
      !formatAccepts none values[4]! "éé" &&
      !formatAccepts none values[5]! "b" &&
      !formatAccepts none values[6]! "1" &&
      !formatAccepts none values[7]! "1999-01-01T00:00:00Z" &&
      !formatAccepts none values[8]! "relative/path" &&
      !formatAccepts none values[9]! "" &&
      !formatAccepts none values[10]! "middle" &&
      !formatAccepts none values[12]! "left"

theorem allGeneralRulesAcceptedAndObserved_sound : allGeneralRulesAcceptedAndObserved = true := by native_decide

end Necoherence.FormatProfileAdmission
