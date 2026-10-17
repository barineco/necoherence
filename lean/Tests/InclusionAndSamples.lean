-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SemanticComposition

namespace Necoherence.Tests.InclusionAndSamples

open Necoherence.ExactJson
open Necoherence.SemanticTypes
open Necoherence.SemanticValidation
open Necoherence.SemanticComposition

private def reference : ProfileRef :=
  { identity := "inclusion-and-samples", revision := "1", contentDigest := "inclusion-and-samples" }

private def source : SourceRef :=
  { repository := "synthetic", revision := "1", path := "types", contentDigest := "inclusion-and-samples"
    documentId := "inclusion-and-samples" }

private def typeRef (name : String) : TypeRef :=
  { source, definitionName := name, pointer := [] }

private def origin : OccurrenceRef :=
  { source, pointer := [] }

private def node (name : String) (shape : TypeShape) : TypeNode :=
  { ref := typeRef name, shape, description := none, attributes := [], extensions := [] }

private def graphemeRules : GraphemeRules :=
  { reference
    properties := [{ first := 769, last := 769, property := .extend }]
    extendedPictographic := []
    indicConjunct := [] }

private def sealedForm : SealedForm :=
  { tag := "sealed"
    fields := [
      { key := "text", required := true, leaf := .string { constValue := some "x" } },
      { key := "count", required := true, leaf := .integer { constValue := some 1 } }]
    extras := .reject }

private def profile : VersionedSemanticProfile :=
  { reference
    integerDomains := [
      { name := "zero-to-ten", reference, range := .inclusive 0 10, forms := [.number] },
      { name := "forms", reference, range := .inclusive 0 10,
        forms := [.number, .integralDecimal, .decimalString] }]
    defaultIntegerDomain := "zero-to-ten"
    graphemeRules := some graphemeRules
    formatBindings := [
      { name := "all-text", reference, rule := .text },
      { name := "not-a", reference, rule := .not (.literal "a") },
      { name := "key-x", reference, rule := .literal "x" }]
    bytesPolicy := some { reference, paddingOptional := true, wrapper := some "bytes" }
    wrappers := [{ name := "bytes", key := "bytes", payload := .bytes }]
    tag := some { key := "tag", format := some "all-text", sealed := [sealedForm] } }

private def graph (nodes : List TypeNode) : SemanticGraph :=
  { profile, nodes, sourceRefs := [source] }

private def contract (name : String) : SlotContract :=
  { typeRef := typeRef name, required := true, nullable := false }

private def field (name target : String) (required : Bool := true)
    (nullable : Bool := false) : FieldSpec :=
  { wireName := name, slot := { typeRef := typeRef target, required, nullable }, origin }

private def branch (target wireTag : String) (selector : BranchSelector := .internalTag) : UnionBranch :=
  { target := typeRef target, wireTag, selector, origin }

private def isAccepted : ValueDecision → Bool
  | .accepted => true
  | _ => false

private def sampleValues (g : SemanticGraph) (name : String)
    (maximum : Nat := 32) : SampleResult JsonValue :=
  sampleValueFuel g { maxSampleLength := maximum } (g.nodes.length + 1) [] (typeRef name)

private def decisionText (g : SemanticGraph) (source destination : SlotContract) : String :=
  match checkAssignable g source destination with
  | .compatible _ => "compatible"
  | .incompatible checked => "incompatible " ++ toString (repr checked.certificate.value)
  | .unknown obligations => "unknown " ++ toString (repr obligations)

private def compatibleWithoutCounterexample
    (g : SemanticGraph) (source destination : SlotContract) : Bool :=
  match checkAssignable g source destination with
  | .compatible checked =>
    let _sound := inclusionWitnessSound g source destination checked
    (sampleValues g source.typeRef.definitionName).values.all fun value =>
      isAccepted (acceptsValue g destination.typeRef value)
  | _ => false

private def incompatibleWithWitness
    (g : SemanticGraph) (source destination : SlotContract) (expected : SlotValue) : Bool :=
  match checkAssignable g source destination with
  | .incompatible checked =>
    let _sound := counterexampleWitnessSound g source destination checked
    checked.certificate.value == expected &&
      isAccepted (acceptsSlot g source expected) &&
      !isAccepted (acceptsSlot g destination expected)
  | _ => false


private def formatInclusionSound : Bool :=
  let excluded := FormatRule.not (.literal "a")
  let choice := FormatRule.choice [.literal "x", excluded]
  let cases := [
    (FormatRule.literal "a", FormatRule.text, ["a"]),
    (excluded, choice, ["", "aa"])]
  cases.all fun (source, destination, samples) =>
    formatRuleIncluded source destination &&
      samples.all fun text => !formatAccepts source text || formatAccepts destination text

private def formatGraph : SemanticGraph :=
  graph [
    node "text-string" (.string { format := some (.named "all-text") }),
    node "not-a-string" (.string { format := some (.named "not-a") })]

private def c1 : Bool :=
  compatibleWithoutCounterexample formatGraph (contract "not-a-string") (contract "not-a-string")

private def i1 : Bool :=
  incompatibleWithWitness formatGraph (contract "text-string") (contract "not-a-string")
    (.present (.str "a"))

private def c2Graph : SemanticGraph :=
  graph [
    node "any" (.unknown .any),
    node "c2-source" (.product { fields := [], extras :=
      (.allow (some (.inline (.literal "x"))) { typeRef := typeRef "any" }) }),
    node "c2-destination" (.product { fields := [], extras :=
      (.allow (some (.inline .text)) { typeRef := typeRef "any" }) })]

private def c2 : Bool :=
  compatibleWithoutCounterexample c2Graph (contract "c2-source") (contract "c2-destination")

private def rulePOrderGraph : SemanticGraph :=
  graph [
    node "order-text" (.string {}),
    node "order-integer" (.integer {}),
    node "order-source" (.product {
      fields := [field "text" "order-text", field "integer" "order-integer"]
      extras := .reject }),
    node "order-destination" (.product {
      fields := [field "integer" "order-integer", field "text" "order-text"]
      extras := .reject })]

private def rulePOrder : Bool :=
  compatibleWithoutCounterexample rulePOrderGraph
    (contract "order-source") (contract "order-destination")

private def rulePSourceFieldGraph : SemanticGraph :=
  graph [
    node "source-field-integer" (.integer {}),
    node "source-field-source" (.product {
      fields := [field "x" "source-field-integer"]
      extras := .reject }),
    node "source-field-destination" (.product {
      fields := []
      extras := .allow (some (.inline (.literal "x")))
        { typeRef := typeRef "source-field-integer" } })]

private def rulePSourceField : Bool :=
  compatibleWithoutCounterexample rulePSourceFieldGraph
    (contract "source-field-source") (contract "source-field-destination")

private def rulePExtrasValueGraph : SemanticGraph :=
  graph [
    node "extras-zero-to-nine" (.integer {
      domain := some "zero-to-ten", minimum := some 0, maximum := some 9 }),
    node "extras-zero-to-ten" (.integer {
      domain := some "zero-to-ten", minimum := some 0, maximum := some 10 }),
    node "extras-value-source" (.product {
      fields := []
      extras := .allow (some (.inline (.literal "x")))
        { typeRef := typeRef "extras-zero-to-nine" } }),
    node "extras-value-destination" (.product {
      fields := []
      extras := .allow (some (.inline (.literal "x")))
        { typeRef := typeRef "extras-zero-to-ten" } })]

private def rulePExtrasValue : Bool :=
  compatibleWithoutCounterexample rulePExtrasValueGraph
    (contract "extras-value-source") (contract "extras-value-destination")

private def rulePExtrasValueReverse : Bool :=
  incompatibleWithWitness rulePExtrasValueGraph
    (contract "extras-value-destination") (contract "extras-value-source")
    (.present (.obj [("x", .num 10)]))

private def rulePExtrasFieldGraph (required : Bool) : SemanticGraph :=
  graph [
    node "extras-field-zero-to-nine" (.integer {
      domain := some "zero-to-ten", minimum := some 0, maximum := some 9 }),
    node "extras-field-zero-to-ten" (.integer {
      domain := some "zero-to-ten", minimum := some 0, maximum := some 10 }),
    node "extras-field-source" (.product {
      fields := []
      extras := .allow none { typeRef := typeRef "extras-field-zero-to-nine" } }),
    node "extras-field-destination" (.product {
      fields := [field "y" "extras-field-zero-to-ten" required]
      extras := .allow none { typeRef := typeRef "extras-field-zero-to-ten" } })]

private def rulePExtrasOptionalField : Bool :=
  let g := rulePExtrasFieldGraph false
  compatibleWithoutCounterexample g
    (contract "extras-field-source") (contract "extras-field-destination")

private def rulePExtrasRequiredField : Bool :=
  let g := rulePExtrasFieldGraph true
  incompatibleWithWitness g
    (contract "extras-field-source") (contract "extras-field-destination")
    (.present (.obj []))

private def i2Graph : SemanticGraph :=
  graph [
    node "tag-x" (.string { constValue := some "x" }),
    node "i2-source" (.product { fields := [], extras := .reject }),
    node "i2-destination" (.product {
      fields := [field "tag" "tag-x" false], extras := .reject })]

private def i2 : Bool :=
  incompatibleWithWitness i2Graph (contract "i2-source") (contract "i2-destination")
    (.present (.obj [("tag", .str "y")]))

private def unionGraph : SemanticGraph :=
  let payload := node "payload" (.product { fields := [], extras := .reject })
  graph [payload,
    node "c3-source" (.taggedUnion { branches := [branch "payload" "a"] }),
    node "c3-destination" (.taggedUnion {
      branches := [branch "payload" "a", branch "payload" "b"] }),
    node "i3-source" (.taggedUnion {
      branches := [branch "payload" "a", branch "payload" "b"] }),
    node "i3-destination" (.taggedUnion { branches := [branch "payload" "a"] })]

private def c3 : Bool :=
  compatibleWithoutCounterexample unionGraph (contract "c3-source") (contract "c3-destination")

private def i3 : Bool :=
  incompatibleWithWitness unionGraph (contract "i3-source") (contract "i3-destination")
    (.present (.obj [("tag", .str "b")]))

private def integerGraph : SemanticGraph :=
  graph [
    node "zero-to-nine" (.integer { domain := some "zero-to-ten", minimum := some 0, maximum := some 9 }),
    node "zero-to-ten" (.integer { domain := some "zero-to-ten", minimum := some 0, maximum := some 10 })]

private def c4 : Bool :=
  compatibleWithoutCounterexample integerGraph (contract "zero-to-nine") (contract "zero-to-ten")

private def i4 : Bool :=
  incompatibleWithWitness integerGraph (contract "zero-to-ten") (contract "zero-to-nine")
    (.present (.num 10))

private def lengthGraph : SemanticGraph :=
  graph [
    node "scalar-one" (.string { lengths := [{ unit := .unicodeScalars, maximum := some 1 }] }),
    node "scalar-two" (.string { lengths := [{ unit := .unicodeScalars, maximum := some 2 }] })]

private def c5 : Bool :=
  compatibleWithoutCounterexample lengthGraph (contract "scalar-one") (contract "scalar-two")

private def i5 : Bool :=
  incompatibleWithWitness lengthGraph (contract "scalar-two") (contract "scalar-one")
    (.present (.str "aa"))

private def i6Graph : SemanticGraph :=
  graph [
    node "any" (.unknown .any),
    node "i6-source" (.product { fields := [], extras :=
      (.allow (some (.inline (.literal "x"))) { typeRef := typeRef "any" }) }),
    node "i6-destination" (.product { fields := [], extras := .reject })]

private def i6 : Bool :=
  incompatibleWithWitness i6Graph (contract "i6-source") (contract "i6-destination")
    (.present (.obj [("x", .obj [])]))

private def i7Graph : SemanticGraph :=
  graph [node "bytes-source" (.bytes {}), node "ordinary-object" (.unknown .ordinaryObject)]

private def i7 : Bool :=
  incompatibleWithWitness i7Graph (contract "bytes-source") (contract "ordinary-object")
    (.present (.obj [("bytes", .str "")]))

private def formatSamplesAccepted : Bool :=
  let g := graph [
    node "text-format" (.string { format := some (.named "all-text") }),
    node "not-format" (.string { format := some (.named "not-a") })]
  ["text-format", "not-format"].all fun name =>
    let samples := sampleValues g name
    !samples.values.isEmpty && samples.values.all fun value => isAccepted (acceptsValue g (typeRef name) value)

private def hasObjectMember (name : String) : JsonValue → Bool
  | .obj members => members.any (fun member => member.1 == name)
  | _ => false

private def sampleGraph : SemanticGraph :=
  let selectorProduct := node "selector-product" (.product {
    fields := [field "shape" "shape-text" false], extras := .reject })
  graph [
    node "bytes" (.bytes {}),
    node "sealed" (.sealed "sealed" []),
    node "shape-text" (.string { format := some (.named "all-text") }),
    selectorProduct,
    node "kind-string" (.string {}),
    node "otherwise-boolean" (.boolean {}),
    node "selector-union" (.taggedUnion { branches := [
      branch "selector-product" "internal" .internalTag,
      branch "selector-product" "shape" (.memberShape [("shape", .format "all-text")]),
      branch "kind-string" "string" (.kind .string),
      branch "otherwise-boolean" "otherwise" .otherwise] }),
    node "integer-forms" (.integer { domain := some "forms" }),
    node "bytes-length" (.string {
      lengths := [{ unit := .utf8Bytes, minimum := some 2, maximum := some 2 }] }),
    node "scalar-length" (.string {
      lengths := [{ unit := .unicodeScalars, minimum := some 2, maximum := some 2 }] }),
    node "grapheme-length" (.string {
      lengths := [{ unit := .graphemes, minimum := some 2, maximum := some 2 }] }),
    node "any" (.unknown .any),
    node "extras" (.product { fields := [], extras :=
      (.allow (some (.named "key-x")) { typeRef := typeRef "any" }) })]

private def samplesAccepted (name : String) : Bool :=
  let samples := sampleValues sampleGraph name
  !samples.values.isEmpty &&
    samples.values.all fun value => isAccepted (acceptsValue sampleGraph (typeRef name) value)

private def wrapperSamplesAccepted : Bool :=
  samplesAccepted "bytes" && (sampleValues sampleGraph "bytes").values.any (hasObjectMember "bytes")

private def sealedSamplesAccepted : Bool :=
  samplesAccepted "sealed" && (sampleValues sampleGraph "sealed").values.any (hasObjectMember "tag")

private def selectorSamplesAccepted : Bool :=
  let values := (sampleValues sampleGraph "selector-union").values
  samplesAccepted "selector-union" &&
    values.any (hasObjectMember "tag") &&
    values.any (hasObjectMember "shape") &&
    values.any (fun value => match value with | .str _ => true | _ => false) &&
    values.any (fun value => match value with | .bool _ => true | _ => false)

private def integerSamplesAccepted : Bool :=
  let values := (sampleValues sampleGraph "integer-forms").values
  samplesAccepted "integer-forms" &&
    values.contains (.num 0) && values.contains (.dec "0") && values.contains (.str "0")

private def lengthSamplesAccepted : Bool :=
  ["bytes-length", "scalar-length", "grapheme-length"].all fun name =>
    samplesAccepted name && (sampleValues sampleGraph name).values.contains (.str "aa")

private def extrasSamplesAccepted : Bool :=
  samplesAccepted "extras" && (sampleValues sampleGraph "extras").values.any (hasObjectMember "x")


private def sampleText (name : String) : String :=
  toString (repr (sampleValues sampleGraph name))

private def sampleBoundObligation : Bool :=
  let g := graph [node "long" (.string { constValue := some "aaaa" })]
  let samples := sampleValues g "long" 3
  samples.values.isEmpty && samples.obligations.contains .sampleBound

private def fieldCombinationGraph : SemanticGraph :=
  let fields := ["a", "b", "c", "d"].map (fun name => field name "flag")
  graph [
    node "flag" (.boolean {}),
    node "four-fields" (.product { fields, extras := .reject })]

private def sampleBoundFieldCombination : Bool :=
  let bounded := sampleValues fieldCombinationGraph "four-fields" 3
  let unbounded := sampleValues fieldCombinationGraph "four-fields" 4
  bounded.values.isEmpty && bounded.obligations.contains .sampleBound &&
    !unbounded.values.isEmpty && unbounded.obligations.isEmpty

private structure Check where
  name : String
  result : Bool
  actual : String

private def cidRule : FormatRule :=
  .choice (["bafkrei", "bafyrei"].map fun leading => .sequence [
    .literal leading, .identifier "abcdefgh" "abcdefgh" (some 1) 1 (some 1) [],
    .identifier "abcdefghijklmnopqrstuvwxyz234567" "abcdefghijklmnopqrstuvwxyz234567" (some 50) 50 (some 50) [],
    .identifier "aeimquy4" "aeimquy4" (some 1) 1 (some 1) []])

private def boundedGraph (rule : FormatRule) : SemanticGraph :=
  graph [
    node "scalar" (.string { format := some (.inline rule) }),
    node "getRecord-parameters" (.product {
      fields := [field "repo" "scalar", field "collection" "scalar",
        field "rkey" "scalar", field "cid" "scalar" false], extras := .reject }),
    node "errorBody" (.product {
      fields := [field "error" "scalar", field "message" "scalar" false], extras := .reject }),
    node "cid-holder" (.product { fields := [field "cid" "scalar"], extras := .reject })]

private def boundedInput (g : SemanticGraph) (maximum : Nat) : CompositionInput :=
  { identity := "bounded", revision := "1", basis := SemanticBasis.of g, signatures := []
    initialInputs := [{ id := ⟨"initial"⟩, contract := contract "scalar", source := .argument, resource := none }]
    initialResources := []
    goal := {
      outputs := ["getRecord-parameters", "errorBody"].map fun name =>
        { id := ⟨name⟩, contract := contract name, sourceConstraint := .anyCompatible }
      failures := []
      finalResources := [] }
    invocationDomain := {
      identity := "domain", revision := "1", sites := []
      permittedProjections := [], permittedConstructions := [], permittedTransforms := [], guards := [] }
    allowedEffects := [], explicitOrder := [], bounds := { maxSampleLength := maximum } }

private def boundedComparison (rule : FormatRule) (text : String) : Bool :=
  let g := boundedGraph rule
  [text.length - 1, text.length].all fun maximum =>
    let bounds : SearchBounds := { maxSampleLength := maximum }
    let comparisons := ["getRecord-parameters", "errorBody"].all fun name =>
      let samples := inclusionSamplesBounded g (typeRef "scalar") (typeRef name) bounds
      let decision := checkAssignableBounded g (contract "scalar") (contract name) bounds
      if maximum < text.length then
        samples.values.isEmpty && samples.obligations.contains .sampleBound &&
          match decision with | .unknown _ => true | _ => false
      else
        samples.values.contains (.str text) &&
          match decision with
          | .incompatible checked => match checked.certificate.value with
            | .present (.str value) => value.length == text.length &&
              isAccepted (acceptsValue g (typeRef "scalar") (.str value)) &&
              checked.certificate.destinationFailure.condition == .wrongValueKind "object"
            | _ => false
          | _ => false
    let control := match projectSlot g (contract "cid-holder") [.field "cid"] with
      | .ok checked => match checkAssignableBounded g checked.destination (contract "scalar") bounds with
        | .compatible _ => true | _ => false
      | _ => false
    let excluded := match prepareDirectComposition g (boundedInput g maximum) (fun _ _ => .ok ()) (fun _ _ => []) with
      | .ok prepared =>
        let candidates := enumerateReturns prepared (initialState prepared)
        candidates.values.isEmpty &&
          if maximum < text.length then !candidates.obligations.isEmpty else candidates.obligations.isEmpty
      | _ => false
    comparisons && control && excluded

private def boundedProductCandidates : Bool :=
  let g := graph [
    node "boolean" (.boolean {}),
    node "source" (.product {
      fields := []
      extras := .allow none { typeRef := typeRef "boolean" } }),
    node "destination" (.product { fields := [field "long-key" "boolean" false], extras := .reject })]
  [0, 1].all fun maximum =>
    let samples := inclusionSamplesBounded g (typeRef "source") (typeRef "destination")
      { maxSampleLength := maximum }
    let present := samples.values.any fun value => match value with
      | .obj members => members.any fun (key, _) => key == "long-key"
      | _ => false
    present == (maximum == 1) &&
      (maximum == 1 || samples.obligations.contains .sampleBound) &&
      samples.values.all fun value => isAccepted (acceptsValue g (typeRef "source") value)

private def checks : List Check := [
  { name := "Product-additional-candidates-bound", result := boundedProductCandidates,
    actual := "additional object member omitted at 0 and sampled at 1" },
  { name := "generic-scalar-product-L-minus-one-L", result := boundedComparison (.literal "generic") "generic",
    actual := "bounded inclusion, typed counterexample, cid field and composition" },
  { name := "CID-two-Products-58-59", result := boundedComparison cidRule ("bafkrei" ++ String.ofList (List.replicate 52 'a')),
    actual := "canonical CID rule, getRecord parameters and errorBody" },
  { name := "format-inclusion-sound", result := formatInclusionSound,
    actual := "text and choice rules" },
  { name := "C1-compatible-no-counterexample", result := c1,
    actual := decisionText formatGraph (contract "not-a-string") (contract "not-a-string") },
  { name := "C2-compatible-no-counterexample", result := c2,
    actual := decisionText c2Graph (contract "c2-source") (contract "c2-destination") },
  { name := "P-field-order-compatible", result := rulePOrder,
    actual := decisionText rulePOrderGraph
      (contract "order-source") (contract "order-destination") },
  { name := "P-source-field-to-extras-compatible", result := rulePSourceField,
    actual := decisionText rulePSourceFieldGraph
      (contract "source-field-source") (contract "source-field-destination") },
  { name := "P-extras-value-inclusion-compatible", result := rulePExtrasValue,
    actual := decisionText rulePExtrasValueGraph
      (contract "extras-value-source") (contract "extras-value-destination") },
  { name := "P-extras-value-reverse-incompatible", result := rulePExtrasValueReverse,
    actual := decisionText rulePExtrasValueGraph
      (contract "extras-value-destination") (contract "extras-value-source") },
  { name := "P-extras-to-optional-field-compatible", result := rulePExtrasOptionalField,
    actual := decisionText (rulePExtrasFieldGraph false)
      (contract "extras-field-source") (contract "extras-field-destination") },
  { name := "P-extras-to-required-field-incompatible", result := rulePExtrasRequiredField,
    actual := decisionText (rulePExtrasFieldGraph true)
      (contract "extras-field-source") (contract "extras-field-destination") },
  { name := "C3-compatible-no-counterexample", result := c3,
    actual := decisionText unionGraph (contract "c3-source") (contract "c3-destination") },
  { name := "C4-compatible-no-counterexample", result := c4,
    actual := decisionText integerGraph (contract "zero-to-nine") (contract "zero-to-ten") },
  { name := "C5-compatible-no-counterexample", result := c5,
    actual := decisionText lengthGraph (contract "scalar-one") (contract "scalar-two") },
  { name := "I1-incompatible-valid-counterexample", result := i1,
    actual := decisionText formatGraph (contract "text-string") (contract "not-a-string") },
  { name := "I2-incompatible-valid-counterexample", result := i2,
    actual := decisionText i2Graph (contract "i2-source") (contract "i2-destination") },
  { name := "I3-incompatible-valid-counterexample", result := i3,
    actual := decisionText unionGraph (contract "i3-source") (contract "i3-destination") },
  { name := "I4-incompatible-valid-counterexample", result := i4,
    actual := decisionText integerGraph (contract "zero-to-ten") (contract "zero-to-nine") },
  { name := "I5-incompatible-valid-counterexample", result := i5,
    actual := decisionText lengthGraph (contract "scalar-two") (contract "scalar-one") },
  { name := "I6-incompatible-valid-counterexample", result := i6,
    actual := decisionText i6Graph (contract "i6-source") (contract "i6-destination") },
  { name := "I7-incompatible-valid-counterexample", result := i7,
    actual := decisionText i7Graph (contract "bytes-source") (contract "ordinary-object") },
  { name := "format-samples-accepted", result := formatSamplesAccepted,
    actual := "text and not samples are nonempty and accepted" },
  { name := "type-samples-accepted-wrapper", result := wrapperSamplesAccepted,
    actual := sampleText "bytes" },
  { name := "type-samples-accepted-sealed", result := sealedSamplesAccepted,
    actual := sampleText "sealed" },
  { name := "type-samples-accepted-selectors", result := selectorSamplesAccepted,
    actual := sampleText "selector-union" },
  { name := "type-samples-accepted-integer", result := integerSamplesAccepted,
    actual := sampleText "integer-forms" },
  { name := "type-samples-accepted-lengths", result := lengthSamplesAccepted,
    actual := sampleText "bytes-length" ++ "; " ++ sampleText "scalar-length" ++ "; " ++
      sampleText "grapheme-length" },
  { name := "type-samples-accepted-extras", result := extrasSamplesAccepted,
    actual := sampleText "extras" },
  { name := "sample-bound-obligation", result := sampleBoundObligation,
    actual := "maxSampleLength=3, candidate length=4" },
  { name := "sample-bound-field-combination", result := sampleBoundFieldCombination,
    actual := toString (repr (sampleValues fieldCombinationGraph "four-fields" 3)) ++ "; " ++
      toString (repr (sampleValues fieldCombinationGraph "four-fields" 4)) }]

private def runChecks : IO Unit := do
  let mut failed := false
  for check in checks do
    if check.result then
      IO.println (check.name ++ ": ok")
    else
      failed := true
      IO.eprintln (check.name ++ ": failed; actual=" ++ check.actual)
  if failed then throw (IO.userError "inclusion and sample checks failed")

end Necoherence.Tests.InclusionAndSamples

def main : IO Unit :=
  Necoherence.Tests.InclusionAndSamples.runChecks
