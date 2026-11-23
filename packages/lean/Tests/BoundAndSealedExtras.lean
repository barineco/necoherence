-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SemanticComposition

namespace Necoherence.Tests.BoundAndSealedExtras

open Necoherence.ExactJson Necoherence.SemanticTypes Necoherence.SemanticValidation
  Necoherence.SemanticComposition

def reference : ProfileRef :=
  { identity := "bound-and-sealed-extras", revision := "1", contentDigest := "d" }

def ref : TypeRef :=
  { source := { repository := "t", revision := "1", path := "", contentDigest := "", documentId := "" }
    definitionName := "value", pointer := [] }

def nodeOf (shape : TypeShape) : TypeNode :=
  { ref, shape, description := none, attributes := [], extensions := [] }

def expand (profile : VersionedSemanticProfile) (shape : TypeShape) (value : JsonValue) :
    Expansion :=
  let node := nodeOf shape
  expandNode { profile, nodes := [node] } ref [] value (some node)

def accepted (expansion : Expansion) : Bool :=
  match expansion with
  | .requirements [] => true
  | _ => false

def rejectedWith (condition : ValueCondition) (expansion : Expansion) : Bool :=
  match expansion with
  | .rejected failure => failure.condition == condition
  | _ => false

def decimalProfile : VersionedSemanticProfile :=
  { reference, numbers := { decimals := true } }

def range (minimumExclusive maximumExclusive : Bool) : TypeShape :=
  .decimal {
    minimum := some { mantissa := 10, scale := 0, exclusive := minimumExclusive }
    maximum := some { mantissa := 100, scale := 0, exclusive := maximumExclusive } }

def decimalVerdict (minimumExclusive maximumExclusive : Bool) (text : String) : Option ValueCondition :=
  match expand decimalProfile (range minimumExclusive maximumExclusive) (.dec text) with
  | .requirements [] => none
  | .rejected failure => some failure.condition
  | _ => some .invalidDataModel

def decimalBoundsDecided : Bool :=
  decimalVerdict false true "5" == some .belowMinimum &&
  decimalVerdict false true "10" == none &&
  decimalVerdict false true "50" == none &&
  decimalVerdict false true "100" == some .aboveMaximum &&
  decimalVerdict false true "1e1" == none &&
  decimalVerdict false true "0.5e2" == none &&
  decimalVerdict false true "0.5e1" == some .belowMinimum &&
  decimalVerdict false true "9.99" == some .belowMinimum &&
  decimalVerdict false true "99.99" == none &&
  decimalVerdict false true "1e2" == some .aboveMaximum &&
  decimalVerdict false true "1e3" == some .aboveMaximum &&
  decimalVerdict false true "-50" == some .belowMinimum &&
  decimalVerdict true true "10" == some .belowMinimum &&
  decimalVerdict true true "1e1" == some .belowMinimum &&
  decimalVerdict true true "10.01" == none &&
  decimalVerdict false false "100" == none &&
  decimalVerdict false false "1e2" == none &&
  decimalVerdict false false "0.5e2" == none &&
  decimalVerdict false false "100.01" == some .aboveMaximum

theorem decimalBoundsDecided_sound : decimalBoundsDecided = true := by native_decide

def sealedProfile (extras : SealedExtras) : VersionedSemanticProfile :=
  let form : SealedForm := {
    tag := "doc"
    fields := [{ key := "name", required := true, leaf := .string {} }]
    extras }
  { reference, tag := some { key := "kind", format := none, sealed := [form] } }

def sealedShape : TypeShape := .sealed "doc" []

def sealedVerdict (extras : SealedExtras) (members : List (String × JsonValue)) : Expansion :=
  expand (sealedProfile extras) sealedShape (.obj members)

def base : List (String × JsonValue) := [("kind", .str "doc"), ("name", .str "n")]

def duplicated : JsonValue := .obj [("a", .str "x"), ("a", .str "y")]

def sealedExtrasDecided : Bool :=
  accepted (sealedVerdict .reject base) &&
  rejectedWith (.unexpectedField "extra") (sealedVerdict .reject (base ++ [("extra", .str "x")])) &&
  rejectedWith (.unexpectedField "extra")
    (sealedVerdict .reject (base ++ [("extra", duplicated)])) &&
  accepted (sealedVerdict .any base) &&
  accepted (sealedVerdict .any (base ++ [("extra", .str "x")])) &&
  rejectedWith (.duplicateField "a") (sealedVerdict .any (base ++ [("extra", duplicated)]))

theorem sealedExtrasDecided_sound : sealedExtrasDecided = true := by native_decide

def languageAccepts (grandfathered : List String) (text : String) : Bool :=
  formatAccepts none (.languageTag grandfathered) text

def languageTagsDecided : Bool :=
  languageAccepts ["en-GB-oed"] "en-GB-oed" &&
  languageAccepts ["en-GB-oed"] "en-gb-oed" &&
  languageAccepts ["en-GB-oed"] "EN-GB-OED" &&
  !languageAccepts [] "en-GB-oed" &&
  languageAccepts [] "en-GB" &&
  languageAccepts ["en-GB-oed"] "de-DE" &&
  !languageAccepts ["en-GB-oed"] "en-GB-oe" &&
  !languageAccepts ["en-GB-oed"] "1" &&
  !languageAccepts ["en-GB-oed"] "" &&
  !languageAccepts [] "" &&
  languageAccepts [""] ""

theorem languageTagsDecided_sound : languageTagsDecided = true := by native_decide

def rawRef : TypeRef := { ref with definitionName := "raw" }

def bytesProfile (wrapper : Option String) : VersionedSemanticProfile :=
  { reference
    bytesPolicy := some { reference, paddingOptional := true, wrapper }
    wrappers := [{ name := "payload", key := "payload", payload := .bytes }] }

def rawGraph (wrapper : Option String) : SemanticGraph :=
  { profile := bytesProfile wrapper
    nodes := [{ nodeOf (.rawBody "raw") with ref := rawRef }, nodeOf (.bytes {})] }

def samplesOf (graph : SemanticGraph) (target : TypeRef) : List JsonValue :=
  (sampleValueFuel graph { maxSampleLength := 32 } 4 [] target).values

def rawBodySamplesDecided (wrapper : Option String) : Bool :=
  let graph := rawGraph wrapper
  let raw := samplesOf graph rawRef
  !raw.isEmpty && raw == samplesOf graph ref &&
    raw.all (fun value => accepted (expandValue graph rawRef [] value))

theorem rawBodySamplesDecided_plain : rawBodySamplesDecided none = true := by native_decide

theorem rawBodySamplesDecided_wrapped :
    rawBodySamplesDecided (some "payload") = true := by native_decide

end Necoherence.Tests.BoundAndSealedExtras
