-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SemanticValidation

namespace Necoherence.Tests.ExternalValueShapes

open Necoherence.SemanticTypes
open Necoherence.SemanticValidation

def ref : ProfileRef := { identity := "synthetic-shapes", revision := "r", contentDigest := "d" }

def profile (name : Option String) : VersionedSemanticProfile :=
  let tagRule := name.map
    (fun formatName => FormatRule.not (.sequence [.text, .literal ("#" ++ formatName)]))
    |>.getD .text
  let sealed : SealedForm := {
    tag := "bl"
    fields := [
      { key := "rf", required := true
        leaf := .string { format := some (.named "target") } },
      { key := "mt", required := true
        leaf := .string { lengths := [{ unit := .unicodeScalars, minimum := some 1 }] } },
      { key := "sz", required := true
        leaf := .integer { minimum := some 1 } }]
    extras := .any }
  { reference := ref
    integerDomains := [{ name := "default", reference := ref, range := .unbounded, forms := [.number] }]
    defaultIntegerDomain := "default"
    bytesPolicy := some { reference := ref, paddingOptional := true, wrapper := some "payload" }
    formatBindings := [
      { name := "target", reference := ref, rule := .identifier "abcdefghijklmnopqrstuvwxyz" "abcdefghijklmnopqrstuvwxyz234567" none 1 none [] },
      { name := "kind", reference := ref, rule := tagRule },
      { name := "tag", reference := ref, rule := .literal "doc" }]
    wrappers := [
      { name := "payload", key := "payload", payload := .bytes },
      { name := "target", key := "target", payload := .text (some "target") }]
    tag := some { key := "kind", format := some "kind", sealed := [sealed] } }

def graph (name : Option String) : SemanticGraph :=
  { profile := profile name, nodes := [], sourceRefs := [] }

def bytesOf (members : List (String × Necoherence.ExactJson.JsonValue)) : Option Nat :=
  bytesValueLength (profile none) (Necoherence.ExactJson.JsonValue.obj members)

def linkOf (members : List (String × Necoherence.ExactJson.JsonValue)) : Bool :=
  wrapperTextAccepts (profile none) (Necoherence.ExactJson.JsonValue.obj members)

def linkText : String := "bafkreaa"

def bytesShapesDecided : Bool :=
  bytesOf [("payload", .str "AAAA")] == some 3 &&
  bytesOf [("payload", .str "AAAA"), ("extra", .str "x")] == none &&
  bytesOf [("extra", .str "x"), ("payload", .str "AAAA")] == none &&
  bytesOf [("payload", .str "AAAA"), ("payload", .str "AAAA")] == none &&
  bytesOf [("target", .str "AAAA")] == none &&
  bytesOf [] == none

theorem bytesShapesDecided_sound : bytesShapesDecided = true := by native_decide

def unwrappedBytesProfile : VersionedSemanticProfile :=
  { profile none with
    bytesPolicy := some {
      reference := ref
      paddingOptional := true
      alphabet := .either
      strictPadBits := false
      wrapper := none } }

def unwrappedBytesShapesDecided : Bool :=
  bytesValueLength unwrappedBytesProfile (.str "-_8") == some 2 &&
  bytesValueLength unwrappedBytesProfile (.obj [("payload", .str "-_8")]) == none

theorem unwrappedBytesShapesDecided_sound : unwrappedBytesShapesDecided = true := by native_decide

def linkShapesDecided : Bool :=
  linkOf [("target", .str linkText)] &&
  !linkOf [("target", .str linkText), ("extra", .str "x")] &&
  !linkOf [("extra", .str "x"), ("target", .str linkText)] &&
  !linkOf [("target", .str linkText), ("target", .str linkText)] &&
  !linkOf [("payload", .str linkText)] &&
  !linkOf []

theorem linkShapesDecided_sound : linkShapesDecided = true := by native_decide

def decimalSource : SourceRef :=
  { repository := "synthetic-shapes", revision := "r", path := "decimal", contentDigest := "d",
    documentId := "decimal-shapes" }

def decimalRef : TypeRef := { source := decimalSource, definitionName := "decimal", pointer := [] }

def decimalBound (mantissa : Int) (scale : Nat) (exclusive : Bool := false) : DecimalBound :=
  { mantissa := mantissa, scale := scale, exclusive := exclusive }

def decimalSpec (minimum maximum : Option DecimalBound) : DecimalSpec :=
  { minimum := minimum, maximum := maximum }

def decimalNode (minimum maximum : Option DecimalBound) : TypeNode :=
  { ref := decimalRef
    shape := .decimal (decimalSpec minimum maximum)
    description := none
    attributes := []
    extensions := [] }

def decimalGraph (minimum maximum : Option DecimalBound) : SemanticGraph :=
  { profile := { profile none with numbers := { decimals := true } }
    nodes := [decimalNode minimum maximum]
    sourceRefs := [decimalSource] }

def decimalAccepted (minimum maximum : Option DecimalBound) (text : String) : Bool :=
  acceptsValue (decimalGraph minimum maximum) decimalRef (.dec text) == .accepted

def decimalRejectedBy (minimum maximum : Option DecimalBound) (text : String)
    (condition : ValueCondition) : Bool :=
  match acceptsValue (decimalGraph minimum maximum) decimalRef (.dec text) with
  | .rejected failure => failure.condition == condition
  | _ => false

def decimalBoundsDecided : Bool :=
  decimalAccepted none (some (decimalBound 1 0)) "1.0" &&
  decimalAccepted none (some (decimalBound 1 0)) "1" &&
  decimalAccepted none (some (decimalBound 1 0)) "0.5" &&
  decimalRejectedBy none (some (decimalBound 1 0)) "1.5" .aboveMaximum &&
  decimalRejectedBy none (some (decimalBound 1 0 true)) "1.0" .aboveMaximum &&
  decimalAccepted (some (decimalBound (-1) 0)) none "-0.5" &&
  decimalRejectedBy (some (decimalBound 0 0)) none "-0.5" .belowMinimum &&
  decimalAccepted (some (decimalBound 25 1)) (some (decimalBound 25 1)) "2.50" &&
  decimalRejectedBy none (some (decimalBound 25 1 true)) "2.50" .aboveMaximum &&
  decimalRejectedBy (some (decimalBound 25 1 true)) none "2.50" .belowMinimum &&
  decimalAccepted none (some (decimalBound 1200 0)) "1200.0" &&
  decimalRejectedBy none (some (decimalBound 12 0)) "1200" .aboveMaximum &&
  decimalAccepted none (some (decimalBound 0 0)) "0.0" &&
  decimalRejectedBy (some (decimalBound 0 0 true)) none "0.0" .belowMinimum &&
  decimalRejectedBy none (some (decimalBound (-1) 0)) "0.0" .aboveMaximum &&
  decimalRejectedBy (some (decimalBound 1 0)) none "0.0" .belowMinimum &&
  decimalAccepted (some (decimalBound (-2) 0)) (some (decimalBound 0 0)) "-1.5" &&
  decimalRejectedBy none (some (decimalBound (-2) 0)) "-1.5" .aboveMaximum &&
  decimalAccepted (some (decimalBound (-125) 2)) none "-1.25" &&
  decimalAccepted none (some (decimalBound 1 2)) "0.001" &&
  decimalRejectedBy none (some (decimalBound 1 2)) "0.02" .aboveMaximum &&
  decimalAccepted none none "1.0" &&
  decimalRejectedBy (some (decimalBound 1 0)) (some (decimalBound 1 0 true)) "1" .aboveMaximum &&
  decimalRejectedBy (some (decimalBound 1 0 true)) (some (decimalBound 1 0)) "1" .belowMinimum &&
  decimalRejectedBy (some (decimalBound 1 0 true)) (some (decimalBound 1 0 true)) "1" .belowMinimum &&
  decimalRejectedBy none none "1." .invalidDataModel

theorem decimalBoundsDecided_sound : decimalBoundsDecided = true := by native_decide


end Necoherence.Tests.ExternalValueShapes
