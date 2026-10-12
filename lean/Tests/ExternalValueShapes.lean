-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SemanticValidation

namespace Necoherence.Tests.ExternalValueShapes

open Necoherence.SemanticTypes
open Necoherence.SemanticValidation

def ref : ProfileRef := { identity := "synthetic-shapes", revision := "r", contentDigest := "d" }

def profile (name : Option String) : VersionedSemanticProfile :=
  let tagRule := name.map
    (fun canonical => FormatRule.not (.sequence [.text, .literal ("#" ++ canonical)]))
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


end Necoherence.Tests.ExternalValueShapes
