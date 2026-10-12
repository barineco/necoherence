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
  .not (.literal "left")]

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
      formatAccepts values[0]! "lit" &&
      formatAccepts values[1]! "ab" &&
      formatAccepts values[3]! "a.a" &&
      formatAccepts values[4]! "é" &&
      formatAccepts values[5]! "a" &&
      formatAccepts values[6]! "a1" &&
      formatAccepts values[7]! "2024-01-02T03:04:05Z" &&
      formatAccepts values[8]! "https://example.test/x" &&
      formatAccepts values[9]! "en-US" &&
      formatAccepts values[10]! "right" &&
      formatAccepts values[11]! "anything" &&
      formatAccepts values[12]! "right"

private def deeplyNestedRule : FormatRule :=
  (List.range 140).foldl (fun rule _ => .optional rule) (.literal "deep")

def depthAbove128Accepted : Bool :=
  formatAccepts deeplyNestedRule "deep"

def malformedCanonicalProfileRejected : Bool :=
  match decode (α := VersionedSemanticProfile) (Lean.Json.mkObj [("representation", .null)]) with
  | .error _ => true
  | .ok _ => false

end Necoherence.FormatProfileAdmission
