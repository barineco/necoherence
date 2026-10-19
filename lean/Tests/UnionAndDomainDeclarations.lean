-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SemanticValidation

namespace Necoherence.Tests.UnionAndDomainDeclarations

open Necoherence.ExactJson
open Necoherence.SemanticTypes
open Necoherence.SemanticValidation


def reference : ProfileRef :=
  { identity := "union-and-domains", revision := "1", contentDigest := "declarations" }


def source : SourceRef :=
  { repository := "synthetic", revision := "1", path := "types", contentDigest := "d"
    documentId := "union-and-domains" }


def typeRef (name : String) : TypeRef :=
  { source, definitionName := name, pointer := [] }


def origin : OccurrenceRef :=
  { source, pointer := [] }


def node (name : String) (shape : TypeShape) : TypeNode :=
  { ref := typeRef name, shape, description := none, attributes := [], extensions := [] }


def graphemeRules : GraphemeRules :=
  { reference
    properties := [{ first := 769, last := 769, property := .extend }]
    extendedPictographic := []
    indicConjunct := [] }


def profile : VersionedSemanticProfile :=
  { reference
    integerDomains := [
      { name := "default", reference, range := .inclusive (-10) 10, forms := [.number] },
      { name := "forms", reference, range := .inclusive (-1000) 1000,
        forms := [.number, .integralDecimal, .decimalString] },
      { name := "narrow", reference, range := .inclusive 0 10, forms := [.number] },
      { name := "wide", reference, range := .inclusive 0 100, forms := [.number] }]
    defaultIntegerDomain := "default"
    graphemeRules := some graphemeRules
    formatBindings := [
      { name := "cid-format", reference, rule := .text },
      { name := "mimeType:non-empty", reference, rule := .not (.literal "") },
      { name := "extra-key", reference, rule := .literal "x" }]
    tag := some {
      key := "kind"
      format := none
      sealed := [{
        tag := "blob"
        fields := [
          { key := "ref", required := true, leaf := .string { format := some (.named "cid-format") } },
          { key := "mimeType", required := true,
            leaf := .string { lengths := [{ unit := .unicodeScalars, minimum := some 1 }] } },
          { key := "size", required := true, leaf := .integer {} }]
        extras := .reject }] }
  }


def branch (name wireTag : String) (selector : BranchSelector) : UnionBranch :=
  { target := typeRef name, wireTag, selector, origin }


def selectedTarget (spec : UnionSpec) (value : JsonValue) : Option TypeRef :=
  (selectUnionBranch profile spec value).map (·.target)

def firstTarget (branches : List UnionBranch) : Option TypeRef :=
  branches.head?.map (·.target)


def rejectedAt (expansion : Expansion) (path : ValuePath) (condition : ValueCondition) : Bool :=
  match expansion with
  | .rejected failure => failure.valuePath == path && failure.condition == condition
  | _ => false


def accepted (expansion : Expansion) : Bool :=
  match expansion with
  | .requirements _ => true
  | _ => false


def unionSelectorBranches : Bool :=
  let tagged := branch "tagged" "a" .internalTag
  let shaped := branch "shaped" "legacy" (.memberShape [
    ("kind", .absent), ("cid", .format "cid-format")])
  let string := branch "string" "string" (.kind .string)
  let object := branch "object" "object" (.kind .object)
  let fallback := branch "fallback" "fallback" .otherwise
  let spec : UnionSpec := { branches := [tagged, shaped, string, fallback] }
  let withoutFallback : UnionSpec := { branches := [tagged, shaped, string] }
  let tagFirst := [tagged, object]
  let objectFirst := tagFirst.reverse
  let tagFirstSpec : UnionSpec := { branches := tagFirst }
  let objectFirstSpec : UnionSpec := { branches := objectFirst }
  let taggedValue := JsonValue.obj [("kind", .str "a"), ("x", .num 1)]
  let shapedValue := JsonValue.obj [("cid", .str "B")]
  let stringValue := JsonValue.str "a"
  let fallbackValue := JsonValue.bool true
  let unionNode := node "union" (.taggedUnion spec)
  selectedTarget spec taggedValue == some (typeRef "tagged") &&
    selectedTarget spec shapedValue == some (typeRef "shaped") &&
    selectedTarget spec stringValue == some (typeRef "string") &&
    selectedTarget spec fallbackValue == some (typeRef "fallback") &&
    selectedTarget tagFirstSpec taggedValue == firstTarget tagFirst &&
    selectedTarget objectFirstSpec taggedValue == firstTarget objectFirst &&
    selectedTarget withoutFallback .null == none &&
    expandNode { profile, nodes := [unionNode], sourceRefs := [source] }
      (typeRef "union") [.field "root"] stringValue (some unionNode) ==
        .requirements [{ typeRef := typeRef "string", valuePath := [.field "root"], value := stringValue }] &&
    rejectedAt
      (expandNode { profile, nodes := [], sourceRefs := [source] }
        (typeRef "union") [] .null (some (node "union" (.taggedUnion withoutFallback))))
      [] .noBranchSelected


def sealedFormDeclaration : Bool :=
  let sealedNode := node "sealed" (.sealed "blob" [])
  let graph : SemanticGraph := { profile, nodes := [sealedNode], sourceRefs := [source] }
  let valid := JsonValue.obj [
    ("kind", .str "blob"), ("ref", .str "B"), ("mimeType", .str "image/png"),
    ("size", .num 1)]
  let missingTag := JsonValue.obj [
    ("ref", .str "B"), ("mimeType", .str "image/png"), ("size", .num 1)]
  let emptyMime := JsonValue.obj [
    ("kind", .str "blob"), ("ref", .str "B"), ("mimeType", .str ""),
    ("size", .num 1)]
  accepted (expandValue graph (typeRef "sealed") [] valid) &&
    rejectedAt (expandValue graph (typeRef "sealed") [] missingTag) [] (.wrongValueKind "sealed object") &&
    (match expandValue graph (typeRef "sealed") [] emptyMime with
      | .rejected failure => failure.condition == .stringLength
      | _ => false)


def integerDomainForms : Bool :=
  let spec : IntegerSpec := { domain := some "forms" }
  let unknownNode := node "unknown" (.unknown .any)
  let graph : SemanticGraph := { profile, nodes := [unknownNode], sourceRefs := [source] }
  integerCondition profile spec (.num 1) == none &&
    integerCondition profile spec (.dec "1.0") == none &&
    integerCondition profile spec (.str "1e2") == none &&
    integerCondition profile spec (.str "+1") == some (.wrongValueKind "integer") &&
    integerCondition profile spec (.str "1001") == some .integerDomain &&
    rejectedAt (expandValue graph (typeRef "unknown") [] (.num 11)) [] .integerDomain
def generalDecimalData : Bool :=
  let enabled := { profile with numbers := { decimals := true } }
  let boundedIntegral := {
    profile with
    integerDomains := [{
      name := "forms", reference, range := .inclusive (-10) 10,
      forms := [.number, .integralDecimal] }],
    defaultIntegerDomain := "forms" }
  let priorityEnabled := { boundedIntegral with numbers := { decimals := true } }
  let priorityDisabled := { boundedIntegral with numbers := { decimals := false } }
  let unboundedIntegral := {
    boundedIntegral with integerDomains := [{
      name := "forms", reference, range := .unbounded,
      forms := [.number, .integralDecimal] }] }
  let numberOnly := { profile with
    numbers := { decimals := true },
    integerDomains := [{
      name := "default", reference, range := .inclusive (-10) 10,
      forms := [.number] }],
    defaultIntegerDomain := "default" }
  dataValueAccepts enabled (.dec "-1.25") &&
    dataValueAccepts enabled (.dec "6.02e23") &&
    dataValueAccepts enabled (.arr [.dec "-1.25"]) &&
    dataValueAccepts enabled (.obj [("nested", .arr [.dec "6.02e23"])]) &&
    dataValueAccepts priorityEnabled (.dec "1.0") &&
    dataValueAccepts priorityEnabled (.dec "1.25") &&
    !dataValueAccepts priorityEnabled (.dec "11.0") &&
    integerCondition priorityEnabled {} (.dec "11.0") == some .integerDomain &&
    dataValueAccepts priorityDisabled (.dec "1.0") &&
    !dataValueAccepts priorityDisabled (.dec "11.0") &&
    integerCondition priorityDisabled {} (.dec "11.0") == some .integerDomain &&
    !dataValueAccepts priorityDisabled (.dec "1.25") &&
    dataValueAccepts unboundedIntegral (.dec "1e999999") &&
    dataValueAccepts numberOnly (.dec "11.0") &&
    !dataValueAccepts enabled (.num 11) &&
    !dataValueAccepts enabled (.dec "1.")



def largeExponentIntegerDomains : Bool :=
  let int64Profile := {
    profile with
    integerDomains := [{
      name := "int64", reference, range := .inclusive (-9223372036854775808) 9223372036854775807,
      forms := [.number, .integralDecimal, .decimalString] }]
    defaultIntegerDomain := "int64" }
  integerCondition int64Profile {} (.str "1e100000000") == some .integerDomain &&
    integerCondition int64Profile {} (.dec "-1e100000000") == some .integerDomain


def integerDomainOrthogonality : Bool :=
  let narrow : IntegerSpec := { domain := some "narrow" }
  let wide : IntegerSpec := { domain := some "wide" }
  let narrowed := { profile with integerDomains := profile.integerDomains.map fun binding =>
    if binding.name == "narrow" then { binding with range := .inclusive 0 9 } else binding }
  integerCondition profile narrow (.num 10) == none &&
    integerCondition narrowed narrow (.num 10) == some .integerDomain &&
    integerCondition profile wide (.num 10) == none &&
    integerCondition narrowed wide (.num 10) == none &&
    integerCondition profile {} (.num 1) == none &&
    integerCondition narrowed {} (.num 1) == none


def stringLengthUnits : Bool :=
  let bytes : StringSpec := {
    lengths := [{ unit := .utf8Bytes, minimum := some 2, maximum := some 2 }] }
  let scalars : StringSpec := {
    lengths := [{ unit := .unicodeScalars, minimum := some 1, maximum := some 1 }] }
  let clusters : StringSpec := {
    lengths := [{ unit := .graphemes, minimum := some 1, maximum := some 1 }] }
  let all : StringSpec := { lengths := [
    { unit := .utf8Bytes, maximum := some 2 },
    { unit := .unicodeScalars, maximum := some 1 }] }
  stringCondition profile bytes "é" == none &&
    stringCondition profile scalars "é" == none &&
    stringCondition profile clusters "é" == none &&
    stringCondition profile all "é" == none &&
    stringCondition profile all "éé" == some .stringLength


def stringLengthOrthogonality : Bool :=
  let stringA : StringSpec := {
    lengths := [{ unit := .unicodeScalars, maximum := some 1 }] }
  let changedA : StringSpec := {
    lengths := [{ unit := .unicodeScalars, maximum := some 0 }] }
  let stringB : StringSpec := {
    lengths := [{ unit := .utf8Bytes, maximum := some 2 }] }
  stringCondition profile stringA "é" == none &&
    stringCondition profile changedA "é" == some .stringLength &&
    stringCondition profile stringB "é" == none


def productGraph (name : String) (extras : ExtraMembers) : SemanticGraph :=
  { profile
    nodes := [node name (.product { fields := [], extras }), node "unknown" (.unknown .any)]
    sourceRefs := [source] }


def productExtras : Bool :=
  let rejectGraph := productGraph "reject" .reject
  let allowGraph := productGraph "allow" (.allow none { typeRef := typeRef "unknown" })
  let keyedGraph := productGraph "keyed"
    (.allow (some (.named "extra-key")) { typeRef := typeRef "unknown" })
  let additional := JsonValue.obj [("x", .num 1)]
  rejectedAt (expandValue rejectGraph (typeRef "reject") [] additional)
      [.field "x"] (.unexpectedField "x") &&
    accepted (expandValue allowGraph (typeRef "allow") [] additional) &&
    rejectedAt (expandValue keyedGraph (typeRef "keyed") [] (.obj [("y", .num 1)]))
      [.field "y"] (.keyFormat "y") &&
    accepted (expandValue allowGraph (typeRef "allow") [] (.obj [("x", .null)])) &&
    accepted (expandValue rejectGraph (typeRef "reject") [] (.obj [("kind", .str "free")]))


def productExtrasOrthogonality : Bool :=
  let allow : ExtraMembers := .allow none { typeRef := typeRef "unknown" }
  let additional := JsonValue.obj [("x", .num 1)]
  let declaredOnly := JsonValue.obj []
  accepted (expandValue (productGraph "a" allow) (typeRef "a") [] additional) &&
    rejectedAt (expandValue (productGraph "a" .reject) (typeRef "a") [] additional)
      [.field "x"] (.unexpectedField "x") &&
    accepted (expandValue (productGraph "a" .reject) (typeRef "a") [] declaredOnly) &&
    accepted (expandValue (productGraph "b" allow) (typeRef "b") [] additional)


def unionDeclarationOrthogonality : Bool :=
  let first := branch "first" "a" .internalTag
  let second := branch "second" "second" (.kind .string)
  let unionA : UnionSpec := { branches := [first, second] }
  let changedA : UnionSpec := { branches := [{ first with selector := .kind .array }, second] }
  let unionB : UnionSpec := { branches := [first, second] }
  let value := JsonValue.obj [("kind", .str "a")]
  selectedTarget unionA value == some (typeRef "first") &&
    selectedTarget changedA value == none &&
    selectedTarget unionA (.str "x") == some (typeRef "second") &&
    selectedTarget changedA (.str "x") == some (typeRef "second") &&
    selectedTarget unionB value == some (typeRef "first")


def projectionSelection : Bool :=
  let target := node "target" .unit
  let selected := branch "target" "a" .internalTag
  let directUnion := node "direct" (.taggedUnion { branches := [selected] })
  let shapeFirst := branch "shape" "shape" (.memberShape [("x", .absent)])
  let guardedUnion := node "guarded" (.taggedUnion { branches := [shapeFirst, selected] })
  let directGraph : SemanticGraph := { profile, nodes := [directUnion, target], sourceRefs := [source] }
  let guardedGraph : SemanticGraph := {
    profile, nodes := [guardedUnion, target, node "shape" .unit], sourceRefs := [source] }
  let directSource : SlotContract :=
    { typeRef := typeRef "direct", required := true, nullable := false }
  let guardedSource : SlotContract :=
    { typeRef := typeRef "guarded", required := true, nullable := false }
  let directResult := projectSlot directGraph directSource [.variant "a"] [.variant [] "a"]
  let guardedResult := projectSlot guardedGraph guardedSource [.variant "a"] [.variant [] "a"]
  (match directResult with
    | .ok certificate => certificate.destination.typeRef == typeRef "target"
    | .error _ => false) &&
    (match guardedResult with
      | .error (.variantSelectionUndetermined [] "a") => true
      | _ => false)


def elementNullability : Bool :=
  let nodes := [
    node "string" (.string {}),
    node "integer" (.integer {}),
    node "unknown" (.unknown .any),
    node "nullable-string-array" (.array {
      item := { typeRef := typeRef "string", nullable := true } }),
    node "string-array" (.array {
      item := { typeRef := typeRef "string", nullable := false } }),
    node "unknown-array" (.array {
      item := { typeRef := typeRef "unknown", nullable := false } }),
    node "unknown-map" (.product {
      fields := [],
      extras := .allow none { typeRef := typeRef "unknown", nullable := false } }),
    node "integer-map" (.product {
      fields := [],
      extras := .allow none { typeRef := typeRef "integer", nullable := false } })]
  let graph : SemanticGraph := { profile, nodes, sourceRefs := [source] }
  let accepts := fun name value => acceptsValue graph (typeRef name) value == .accepted
  accepts "nullable-string-array" (.arr [.null]) &&
    !accepts "string-array" (.arr [.null]) &&
    accepts "unknown-array" (.arr [.null]) &&
    accepts "unknown-map" (.obj [("x", .null)]) &&
    !accepts "integer-map" (.obj [("x", .null)])


def checks : List (String × Bool) := [
  ("union-selector-branches", unionSelectorBranches),
  ("sealed-form-declaration", sealedFormDeclaration),
  ("integer-domain-forms", integerDomainForms),
  ("general-decimal-data", generalDecimalData),
  ("integer-domain-orthogonality", integerDomainOrthogonality),
  ("string-length-units", stringLengthUnits),
  ("string-length-orthogonality", stringLengthOrthogonality),
  ("product-extras", productExtras),
  ("product-extras-orthogonality", productExtrasOrthogonality),
  ("element-nullability", elementNullability),
  ("union-and-projection-orthogonality", unionDeclarationOrthogonality && projectionSelection)]


def runChecks : IO Unit := do
  for (name, result) in checks do
    if result then IO.println (name ++ ": ok")
    else throw (IO.userError (name ++ ": failed"))

end Necoherence.Tests.UnionAndDomainDeclarations


def main : IO Unit :=
  Necoherence.Tests.UnionAndDomainDeclarations.runChecks
