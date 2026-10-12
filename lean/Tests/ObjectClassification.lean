-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SemanticComposition

namespace Necoherence.Tests.ObjectClassification

open Necoherence.ExactJson Necoherence.SemanticTypes Necoherence.SemanticValidation
  Necoherence.SemanticComposition

structure Spelling where
  bytes : String
  text : String
  tag : String
  sealedTag : String
  payload : String
  mime : String
  size : String
  deriving BEq

def original : Spelling :=
  { bytes := "$bytes", text := "$link", tag := "$type", sealedTag := "blob"
    payload := "ref", mime := "mimeType", size := "size" }

def renamed : Spelling :=
  { bytes := "payload", text := "target", tag := "kind", sealedTag := "attachment"
    payload := "source", mime := "media", size := "extent" }

def reference : ProfileRef :=
  { identity := "object-classification", revision := "4", contentDigest := "classification" }

def profile (spelling : Spelling) (mimeRequired : Bool := true)
    (constrainedTag : Bool := true) : VersionedSemanticProfile :=
  let tagRule := if constrainedTag then
    FormatRule.not (.choice [.literal "", .sequence [.text, .literal "#main"]])
  else .text
  let form : SealedForm := {
    tag := spelling.sealedTag
    fields := [
      { key := spelling.payload, required := true
        leaf := .string { format := some (.named spelling.text) } },
      { key := spelling.mime, required := mimeRequired
        leaf := .string { lengths := [{ unit := .unicodeScalars, minimum := some 1 }] } },
      { key := spelling.size, required := true
        leaf := .integer { domain := some "default", minimum := some 1 } }]
    extras := .any }
  { reference
    integerDomains := [{ name := "default", reference, range := .unbounded, forms := [.number] }]
    defaultIntegerDomain := "default"
    bytesPolicy := some {
      reference, paddingOptional := true, alphabet := .standard,
      strictPadBits := true, wrapper := some spelling.bytes }
    formatBindings := [
      { name := spelling.text, reference,
        rule := .identifier "abcdefghijklmnopqrstuvwxyz" "abcdefghijklmnopqrstuvwxyz234567" none 1 none [] },
      { name := spelling.tag, reference, rule := tagRule }]
    wrappers := [
      { name := spelling.bytes, key := spelling.bytes, payload := .bytes },
      { name := spelling.text, key := spelling.text, payload := .text (some spelling.text) }]
    tag := some { key := spelling.tag, format := some spelling.tag, sealed := [form] } }

def source : SourceRef :=
  { repository := "synthetic", revision := "1", path := "types", contentDigest := "d"
    documentId := "objects" }

def typeRef (name : String) : TypeRef :=
  { source, definitionName := name, pointer := [] }

def node (name : String) (shape : TypeShape) : TypeNode :=
  { ref := typeRef name, shape, description := none, attributes := [], extensions := [] }

def graph (semanticProfile : VersionedSemanticProfile) : SemanticGraph :=
  let textName := (semanticProfile.wrappers[1]?).map (fun wrapper => wrapper.name) |>.getD ""
  let sealedTag := semanticProfile.tag.bind (fun model => model.sealed.head?.map (fun form => form.tag)) |>.getD ""
  { profile := semanticProfile
    nodes := [
      node "bytes" (.bytes {}),
      node "text" (.string { wrapper := some textName }),
      node "sealed" (.sealed sealedTag []),
      node "unknown" (.unknown .any),
      node "product" (.product {
        fields := [],
        extras := .allow none { typeRef := typeRef "unknown" } }),
      node "union" (.taggedUnion { branches := [] })]
    sourceRefs := [source] }

def bytesValue (spelling : Spelling) : JsonValue :=
  .obj [(spelling.bytes, .str "AQI=")]

def textValue (spelling : Spelling) : JsonValue :=
  .obj [(spelling.text, .str "bafkreaa")]

def sealedValue (spelling : Spelling) (includeMime : Bool := true)
    (includeBytes : Bool := false) : JsonValue :=
  let required := [
    (spelling.tag, .str spelling.sealedTag),
    (spelling.payload, .str "bafkreaa"),
    (spelling.size, .num 10)]
  let withMime := if includeMime then required ++ [(spelling.mime, .str "image/png")] else required
  .obj (if includeBytes then withMime ++ [(spelling.bytes, .str "AQI=")] else withMime)

def ordinaryValue (spelling : Spelling) : JsonValue :=
  .obj [(spelling.tag, .str "com.example.record"), ("name", .str "a")]

inductive Outcome where | accepted | rejected | unresolved deriving BEq, Repr

def outcome (semanticGraph : SemanticGraph) (name : String) (value : JsonValue) : Outcome :=
  match expandValue semanticGraph (typeRef name) [] value with
  | .requirements _ => .accepted
  | .rejected _ => .rejected
  | .unresolved _ => .unresolved

def rejectedAt (expansion : Expansion) (path : ValuePath)
    (condition : ValueCondition) : Bool :=
  match expansion with
  | .rejected failure => failure.valuePath == path && failure.condition == condition
  | _ => false

inductive ClassKind where | sealed | wrapper | ordinary deriving BEq, Repr

def classKind : ObjectClass → ClassKind
  | .sealed _ => .sealed
  | .wrapper _ => .wrapper
  | .ordinary => .ordinary

def classify (semanticProfile : VersionedSemanticProfile) : JsonValue → ClassKind
  | .obj members => classKind (classOf semanticProfile members)
  | _ => .ordinary

def objectClassPreservation : Bool :=
  let p := profile original
  [classify p (bytesValue original), classify p (textValue original),
    classify p (sealedValue original), classify p (ordinaryValue original)] ==
    [.wrapper, .wrapper, .sealed, .ordinary]

def objectClassInvalid : Bool :=
  let g := graph (profile original)
  outcome g "bytes" (.obj [(original.bytes, .str "?")]) == .rejected &&
    outcome g "sealed" (.obj [(original.tag, .str "x#main")]) == .rejected

def sealedWrapperOrthogonality : Bool :=
  classify (profile original) (sealedValue original true true) == .sealed

def sealedDeclarationOrthogonality : Bool :=
  outcome (graph (profile original true)) "sealed" (sealedValue original false) == .rejected &&
    outcome (graph (profile original false)) "sealed" (sealedValue original false) == .accepted

def dataTagBranches : Bool :=
  let constrained := profile original
  let unconstrained := profile original true false
  tagValueAccepts unconstrained [(original.tag, .str "x#main")] &&
    tagValueAccepts constrained [] &&
    tagValueAccepts constrained [(original.tag, .str "x#other")] &&
    !tagValueAccepts constrained [(original.tag, .str "x#main")] &&
    !tagValueAccepts constrained [(original.tag, .num 1)]

def dataTagFailures : Bool :=
  let g := graph (profile original)
  let rejected := fun name value condition =>
    rejectedAt (expandValue g (typeRef name) [] (.obj [(original.tag, value)]))
      [.field original.tag] condition
  rejected "product" (.str "") .invalidTag &&
    rejected "product" (.num 1) .invalidTag &&
    rejected "sealed" (.str "") .invalidTag &&
    rejected "union" (.str "") .invalidTag

def classificationSpellingRenaming : Bool :=
  let a := profile original
  let b := profile renamed
  [classify a (bytesValue original), classify a (textValue original),
    classify a (sealedValue original), classify a (ordinaryValue original)] ==
  [classify b (bytesValue renamed), classify b (textValue renamed),
    classify b (sealedValue renamed), classify b (ordinaryValue renamed)]

def productUsesOrdinaryGate : Bool :=
  let g := graph (profile original)
  outcome g "product" (bytesValue original) == .rejected &&
    outcome g "product" (ordinaryValue original) == .accepted

def bytesProfile (alphabet : BytesAlphabet) (strictPadBits : Bool) :
    VersionedSemanticProfile :=
  let base := profile original
  { base with bytesPolicy := base.bytesPolicy.map fun policy =>
      { policy with alphabet, strictPadBits } }

def bytesAccepted (semanticProfile : VersionedSemanticProfile) (wire : String) : Bool :=
  outcome (graph semanticProfile) "bytes" (.obj [(original.bytes, .str wire)]) == .accepted

def bytesPolicyDeclarations : Bool :=
  let standard := bytesProfile .standard true
  let urlSafe := bytesProfile .urlSafe true
  let either := bytesProfile .either true
  let loose := bytesProfile .standard false
  bytesAccepted standard "+/8=" &&
    !bytesAccepted standard "-_8=" &&
    bytesAccepted urlSafe "-_8=" &&
    !bytesAccepted urlSafe "+/8=" &&
    bytesAccepted either "+/8=" &&
    bytesAccepted either "-_8=" &&
    bytesAccepted either "+_8=" &&
    bytesAccepted standard "/w==" &&
    !bytesAccepted standard "/x==" &&
    bytesAccepted loose "/x=="

def wrapperStringGraph : SemanticGraph :=
  let p := profile original
  { profile := p
    nodes := [node "wrapped-text" (.string {
      format := some (.named original.text)
      lengths := [{ unit := .unicodeScalars, minimum := some 1, maximum := some 3 }]
      wrapper := some original.text })]
    sourceRefs := [source] }

def rejectionCondition (semanticGraph : SemanticGraph) (name : String)
    (value : JsonValue) : Option ValueCondition :=
  match expandValue semanticGraph (typeRef name) [] value with
  | .rejected failure => some failure.condition
  | _ => none

def wrapperStringValidation : Bool :=
  let g := wrapperStringGraph
  let wrapped := fun text => JsonValue.obj [(original.text, .str text)]
  outcome g "wrapped-text" (wrapped "x") == .accepted &&
    rejectionCondition g "wrapped-text" (wrapped "abcd") == some .stringLength &&
    rejectionCondition g "wrapped-text" (wrapped "X") == some (.format original.text) &&
    rejectionCondition g "wrapped-text" (.str "x") ==
      some (.wrongValueKind "string wrapper") &&
    rejectionCondition g "wrapped-text" (bytesValue original) ==
      some (.wrongValueKind "string wrapper")

def wrapperStringSamples : Bool :=
  let g := wrapperStringGraph
  let samples := (sampleValueFuel g { maxSampleLength := 8 } 2 [] (typeRef "wrapped-text")).values
  samples.contains (.obj [(original.text, .str "a")]) &&
    samples.all fun value =>
      match value with
      | .obj [(key, .str _)] => key == original.text && outcome g "wrapped-text" value == .accepted
      | _ => false

def distinctWrapperInclusion : Bool :=
  let base := profile original
  let other : Wrapper :=
    { name := "other-text-wrapper", key := "other-text", payload := .text (some original.text) }
  let g : SemanticGraph :=
    { profile := { base with wrappers := base.wrappers ++ [other] }
      nodes := [
        node "first-text" (.string { wrapper := some original.text }),
        node "other-text" (.string { wrapper := some other.name })]
      sourceRefs := [source] }
  let contract := fun name =>
    ({ typeRef := typeRef name, required := true, nullable := false } : SlotContract)
  match checkAssignable g (contract "first-text") (contract "other-text") with
  | .compatible _ => false
  | .incompatible _ | .unknown _ => true



def checks : List (String × Bool) := [
  ("object-class-preservation", objectClassPreservation),
  ("object-class-invalid", objectClassInvalid),
  ("sealed-wrapper-orthogonality", sealedWrapperOrthogonality),
  ("sealed-declaration-orthogonality", sealedDeclarationOrthogonality),
  ("data-tag-branches", dataTagBranches),
  ("data-tag-failures", dataTagFailures),
  ("classification-spelling-renaming", classificationSpellingRenaming),
  ("bytes-policy-declarations", bytesPolicyDeclarations),
  ("wrapper-string-validation", wrapperStringValidation),
  ("wrapper-string-samples", wrapperStringSamples),
  ("distinct-wrapper-inclusion", distinctWrapperInclusion),
  ("ordinary-gate", productUsesOrdinaryGate)]

def runChecks : IO Unit := do
  for (name, accepted) in checks do
    if accepted then IO.println (name ++ ": ok")
    else throw (IO.userError (name ++ ": failed"))

end Necoherence.Tests.ObjectClassification

def main : IO Unit := Necoherence.Tests.ObjectClassification.runChecks
