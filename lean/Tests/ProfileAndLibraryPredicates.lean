-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SemanticProfile
import Necoherence.SignatureGeneration

namespace Necoherence.Tests.ProfileAndLibraryPredicates

open Lean Necoherence.SemanticTypes Necoherence.SemanticValidation
  Necoherence.TypeSignatures Necoherence.SignatureWire

private def digest : String := String.ofList (List.replicate 64 'a')

private def reference : ProfileRef :=
  { identity := "profile", revision := "4", contentDigest := digest }

private def integerBinding : IntegerDomainBinding :=
  { name := "integer", reference, range := .inclusive (-1) 1,
    forms := [.number, .integralDecimal, .decimalString] }

private def graphemeRules : GraphemeRules :=
  { reference,
    properties := [{ first := 0, last := 1, property := .other }],
    extendedPictographic := [{ first := 2, last := 3 }],
    indicConjunct := [{ first := 4, last := 5, property := .other }] }

private def identifierBinding : FormatBinding :=
  { name := "identifier", reference,
    rule := .identifier "ab" "ab" none 1 (some 4) [] }

private def formatBindings : List FormatBinding :=
  [ identifierBinding,
    { name := "tag-format", reference,
      rule := .choice [.literal "sealed", .literal "other"] },
    { name := "only-ok", reference, rule := .literal "ok" } ]

private def bytesWrapper : Wrapper :=
  { name := "bytes-wrapper", key := "bytes", payload := .bytes }

private def textWrapper : Wrapper :=
  { name := "text-wrapper", key := "text", payload := .text (some "identifier") }

private def wrappers : List Wrapper := [bytesWrapper, textWrapper]

private def nameField : SealedField :=
  { key := "name", required := true,
    leaf := .string { format := some (.named "identifier"), wrapper := some "text-wrapper" } }

private def countField : SealedField :=
  { key := "count", required := false,
    leaf := .integer { domain := some "integer" } }

private def sealedFields : List SealedField := [nameField, countField]

private def validProfile : VersionedSemanticProfile :=
  { reference,
    integerDomains := [integerBinding],
    defaultIntegerDomain := "integer",
    numbers := { decimals := true },
    graphemeRules := some graphemeRules,
    formatBindings,
    bytesPolicy := some {
      reference, paddingOptional := true, alphabet := .either,
      strictPadBits := true, wrapper := some "bytes-wrapper" },
    wrappers,
    tag := some {
      key := "tag", format := some "tag-format",
      sealed := [{ tag := "sealed", fields := sealedFields, extras := .reject }] } }

private def valueProfile (profile : VersionedSemanticProfile := validProfile) : ValueProfile :=
  { reference := profile.reference,
    sourceRefs := profile.sourceRefs,
    integerDomains := profile.integerDomains,
    defaultIntegerDomain := profile.defaultIntegerDomain,
    numbers := profile.numbers,
    graphemeRules := profile.graphemeRules,
    formatBindings := profile.formatBindings,
    wrappers := profile.wrappers,
    tag := profile.tag,
    bytesPolicy := profile.bytesPolicy }

private structure Check where
  name : String
  proposition : String
  passed : Bool
  actual : String

private def profileCheck (name proposition : String) (expected : ProfilePredicate)
    (profile : VersionedSemanticProfile) : Check :=
  match checkProfile profile with
  | .error failure =>
      { name, proposition, passed := failure.predicate == expected,
        actual := reprStr failure }
  | .ok _ => { name, proposition, passed := false, actual := "success" }

private def profileSuccess : Check :=
  match checkProfile validProfile with
  | .ok _ =>
      { name := "profile-valid", proposition := "the valid profile is admitted",
        passed := true, actual := "success" }
  | .error failure =>
      { name := "profile-valid", proposition := "the valid profile is admitted",
        passed := false, actual := reprStr failure }

private def profileChecks : List Check :=
  [ profileCheck "PR-01" "empty profile identity returns PR-01" .pr01
      { validProfile with reference := { reference with identity := "" } },
    profileCheck "PR-02" "duplicate integer-domain names return PR-02" .pr02
      { validProfile with integerDomains := [integerBinding, integerBinding] },
    profileCheck "PR-03" "reversed integer-domain bounds return PR-03" .pr03
      { validProfile with integerDomains := [{ integerBinding with range := .inclusive 2 1 }] },
    profileCheck "PR-04" "an empty integer-domain forms list returns PR-04" .pr04
      { validProfile with integerDomains := [{ integerBinding with forms := [] }] },
    profileCheck "PR-05" "an unresolved default integer domain returns PR-05" .pr05
      { validProfile with defaultIntegerDomain := "missing" },
    profileCheck "PR-06" "duplicate format names return PR-06" .pr06
      { validProfile with formatBindings := formatBindings ++ [identifierBinding] },
    profileCheck "PR-07" "an empty identifier alphabet returns PR-07" .pr07
      { validProfile with formatBindings :=
          { name := "identifier", reference,
            rule := .identifier "" "ab" none 1 (some 4) [] } :: formatBindings.tail! },
    profileCheck "PR-08" "duplicate wrapper keys return PR-08" .pr08
      { validProfile with wrappers :=
          [bytesWrapper, { textWrapper with key := "bytes" }] },
    profileCheck "PR-09" "an unresolved text payload format returns PR-09" .pr09
      { validProfile with wrappers :=
          [bytesWrapper, { textWrapper with payload := .text (some "missing") }] },
    profileCheck "PR-10" "a bytes policy naming a text wrapper returns PR-10" .pr10
      { validProfile with bytesPolicy := (validProfile.bytesPolicy.map
          fun policy => { policy with wrapper := some "text-wrapper" }) },
    profileCheck "PR-11" "a tag key colliding with a wrapper key returns PR-11" .pr11
      { validProfile with tag := (validProfile.tag.map fun tag => { tag with key := "text" }) },
    profileCheck "PR-12" "an unresolved tag format returns PR-12" .pr12
      { validProfile with tag := (validProfile.tag.map
          fun tag => { tag with format := some "missing" }) },
    profileCheck "PR-13" "duplicate sealed tags return PR-13" .pr13
      { validProfile with tag := (validProfile.tag.map
          fun tag => { tag with sealed := tag.sealed ++ tag.sealed }) },
    profileCheck "PR-14" "duplicate sealed field keys return PR-14" .pr14
      { validProfile with tag := (validProfile.tag.map fun tag =>
          { tag with sealed := [
              SealedForm.mk "sealed" (sealedFields ++ [nameField]) .reject] }) },
    profileCheck "PR-15" "an unresolved sealed integer domain returns PR-15" .pr15
      { validProfile with tag := (validProfile.tag.map fun tag =>
          { tag with sealed := [SealedForm.mk "sealed"
              [nameField,
                SealedField.mk "count" false (.integer { domain := some "missing" })]
              .reject] }) },
    profileCheck "PR-16" "a reversed grapheme range returns PR-16" .pr16
      { validProfile with graphemeRules := (some
          { graphemeRules with properties := [GraphemeRange.mk 2 1 .other] }) } ]

private def source : SourceRef :=
  { repository := "synthetic", revision := "1", path := "types",
    contentDigest := digest, documentId := "predicate-tests" }

private def typeRef (name : String) : TypeRef :=
  { source, definitionName := name, pointer := [] }

private def occurrence : OccurrenceRef := { source, pointer := [] }

private def semanticNode (name : String) (shape : TypeShape) : TypeNode :=
  { ref := typeRef name, shape, description := none, attributes := [], extensions := [] }

private def meaningCheck (name proposition : String) (expected : MeaningObligation)
    (profile : VersionedSemanticProfile) (shape : TypeShape) : Check :=
  let ref := typeRef "subject"
  let graph : SemanticGraph := { profile, nodes := [semanticNode "subject" shape] }
  match checkMeaningDefined graph [ref] with
  | .error failure =>
      { name, proposition, passed := failure.predicate == expected,
        actual := reprStr failure }
  | .ok _ => { name, proposition, passed := false, actual := "success" }

private def meaningSuccess : Check :=
  let ref := typeRef "subject"
  let graph : SemanticGraph := { profile := validProfile, nodes := [semanticNode "subject" .unit] }
  match checkMeaningDefined graph [ref] with
  | .ok _ =>
      { name := "meaning-valid", proposition := "a unit node has no meaning obligation",
        passed := true, actual := "success" }
  | .error failure =>
      { name := "meaning-valid", proposition := "a unit node has no meaning obligation",
        passed := false, actual := reprStr failure }

private def meaningChecks : List Check :=
  [ meaningCheck "MO-01" "an unresolved node format returns MO-01" .mo01 validProfile
      (.string { format := some (.named "missing") }),
    meaningCheck "MO-02" "grapheme length without grapheme rules returns MO-02" .mo02
      { validProfile with graphemeRules := none }
      (.string { lengths := [{ unit := .graphemes, minimum := some 1 }] }),
    meaningCheck "MO-03" "bytes without a bytes policy returns MO-03" .mo03
      { validProfile with bytesPolicy := none } (.bytes {}),
    meaningCheck "MO-04" "an unresolved integer domain returns MO-04" .mo04 validProfile
      (.integer { domain := some "missing" }),
    meaningCheck "MO-05" "an unresolved string wrapper returns MO-05" .mo05 validProfile
      (.string { wrapper := some "missing" }),
    meaningCheck "MO-06" "a string using a bytes wrapper returns MO-06" .mo06 validProfile
      (.string { wrapper := some "bytes-wrapper" }),
    meaningCheck "MO-07" "an unresolved sealed tag returns MO-07" .mo07 validProfile
      (.sealed "missing" []),
    meaningCheck "MO-08" "a decimal node disabled by the profile returns MO-08" .mo08
      { validProfile with numbers := { decimals := false } } (.decimal {}),
    meaningCheck "MO-09" "an integer bound outside its domain returns MO-09" .mo09 validProfile
      (.integer { domain := some "integer", minimum := some (-2) }),
    meaningCheck "MO-10" "an opaque node returns MO-10" .mo10 validProfile
      (.opaque "external"),
    meaningCheck "MO-11" "an internal-tag union without a tag model returns MO-11" .mo11
      { validProfile with tag := none }
      (.taggedUnion (Necoherence.SemanticTypes.UnionSpec.mk [
        Necoherence.SemanticTypes.UnionBranch.mk (typeRef "subject") "other" .internalTag occurrence])) ]

private def node (id : String) (shape : Shape) : Node := { id, shape }
private def unitNode : Node := node "unit" .unit
private def field (name target : String) : Field :=
  { wireName := name, slot := { typeId := target, required := true, nullable := false } }
private def branch (target wireTag : String) (selector : BranchSelector) :
    Necoherence.TypeSignatures.UnionBranch :=
  { target, wireTag, selector }

private def libraryWith (nodes : List Node) (profile : ValueProfile := valueProfile) :
    TypeSignatureLibrary :=
  { identity := "library", revision := "4", profile,
    nodes, definitions := [{ id := "entry", wireIdentity := "entry", shape := .value "unit" }] }

private def validLibrary : TypeSignatureLibrary := libraryWith [unitNode]

private def libraryCheck (name proposition : String) (expected : LibraryPredicate)
    (library : TypeSignatureLibrary) : Check :=
  match checkLibrary library with
  | .error (.library failure) =>
      { name, proposition, passed := failure.predicate == expected,
        actual := reprStr failure }
  | .error (.profile failure) =>
      { name, proposition, passed := false, actual := reprStr failure }
  | .ok _ => { name, proposition, passed := false, actual := "success" }

private def librarySuccess : Check :=
  match checkLibrary validLibrary with
  | .ok _ =>
      { name := "library-valid", proposition := "the valid library is admitted",
        passed := true, actual := "success" }
  | .error failure =>
      { name := "library-valid", proposition := "the valid library is admitted",
        passed := false, actual := reprStr failure }

private def productNode (id : String) (fields : List Field)
    (extras : Necoherence.TypeSignatures.ExtraMembers := .reject) : Node :=
  node id (.product { fields, extras })

private def unionNode (branches : List Necoherence.TypeSignatures.UnionBranch) : Node :=
  node "union" (.taggedUnion { branches })

private def internalTagLibrary (secondTag : String := "b") : TypeSignatureLibrary :=
  libraryWith [
    unitNode,
    node "tag-a" (.string { constValue := some "a" }),
    node "tag-b" (.string { constValue := some secondTag }),
    productNode "product-a" [field "$type" "tag-a"],
    productNode "product-b" [field "$type" "tag-b"],
    unionNode [branch "product-a" "a" .internalTag,
      branch "product-b" secondTag .internalTag]]
    (valueProfile { validProfile with tag := some { key := "$type", format := none, sealed := [] } })

private def internalTagSuccess : Check :=
  match checkLibrary internalTagLibrary with
  | .ok _ =>
      { name := "distinct-internal-tags",
        proposition := "distinct internal tags admit both product branches",
        passed := true, actual := "success" }
  | .error failure =>
      { name := "distinct-internal-tags",
        proposition := "distinct internal tags admit both product branches",
        passed := false, actual := reprStr failure }

private def libraryChecks : List Check :=
  [ libraryCheck "LB-01" "an unresolved alias returns LB-01" .lb01
      (libraryWith [unitNode, node "alias" (.alias "missing")]),
    libraryCheck "LB-02" "duplicate product field names return LB-02" .lb02
      (libraryWith [unitNode, productNode "product" [field "value" "unit", field "value" "unit"]]),
    libraryCheck "LB-03" "a product field colliding with a wrapper key returns LB-03" .lb03
      (libraryWith [unitNode, productNode "product" [field "text" "unit"]]),
    libraryCheck "LB-04" "duplicate union wire tags return LB-04" .lb04
      (libraryWith [unitNode, unionNode
        [branch "unit" "same" (.kind .null), branch "unit" "same" (.kind .boolean)]]),
    libraryCheck "LB-05" "a branch after otherwise returns LB-05" .lb05
      (libraryWith [unitNode, unionNode
        [branch "unit" "fallback" .otherwise, branch "unit" "null" (.kind .null)]]),
    libraryCheck "LB-06" "an empty union wire tag returns LB-06" .lb06
      (libraryWith [unitNode, unionNode [branch "unit" "" (.kind .null)]]),
    libraryCheck "LB-07" "an internal wire tag outside the tag format returns LB-07" .lb07
      (libraryWith [unitNode, productNode "target" [],
        unionNode [branch "target" "outside" .internalTag]]),
    libraryCheck "LB-08" "a sealed tag targeting a product returns LB-08" .lb08
      (libraryWith [unitNode, productNode "target" [],
        unionNode [branch "target" "sealed" .internalTag]]),
    libraryCheck "LB-09" "an unresolved member-shape format returns LB-09" .lb09
      (libraryWith [unitNode, unionNode
        [branch "unit" "member" (.memberShape [("key", .format "missing")])]]),
    libraryCheck "LB-10" "an unresolved sealed refinement field returns LB-10" .lb10
      (libraryWith [unitNode, node "sealed-node"
        (.sealed "sealed" [{ key := "missing", leaf := .string {} }])]),
    libraryCheck "LB-11" "an internal-tag branch targeting a scalar returns LB-11" .lb11
      (libraryWith [unitNode, unionNode [branch "unit" "other" .internalTag]]),
    libraryCheck "LB-12" "an unresolved extras key format returns LB-12" .lb12
      (libraryWith [unitNode, productNode "product" []
        (.allow (some (.named "missing")) { typeId := "unit" })]),
    libraryCheck "LB-13" "an unresolved string wrapper returns LB-13" .lb13
      (libraryWith [unitNode, node "string" (.string { wrapper := some "missing" })]),
    libraryCheck "LB-14" "reversed integer bounds return LB-14" .lb14
      (libraryWith [unitNode, node "integer" (.integer { minimum := some 2, maximum := some 1 })]),
    libraryCheck "LB-15" "reversed decimal bounds return LB-15" .lb15
      (libraryWith [unitNode, node "decimal" (.decimal {
        minimum := some { mantissa := 2, scale := 0, exclusive := false },
        maximum := some { mantissa := 1, scale := 0, exclusive := false } })]),
    libraryCheck "LB-16" "reversed array bounds return LB-16" .lb16
      (libraryWith [unitNode, node "array" (.array {
        item := { typeId := "unit" }, minimum := some 2, maximum := some 1 })]),
    libraryCheck "LB-17" "a product tag field rejecting the wire tag returns LB-17" .lb17
      (libraryWith [unitNode,
        node "tag-value" (.string { constValue := some "different" }),
        productNode "target" [field "tag" "tag-value"],
        unionNode [branch "target" "other" .internalTag]]),
    libraryCheck "LB-18" "duplicate selectors return LB-18" .lb18
      (libraryWith [unitNode, unionNode
        [branch "unit" "first" (.kind .null), branch "unit" "second" (.kind .null)]]),
    libraryCheck "LB-19" "a string const outside its format returns LB-19" .lb19
      (libraryWith [unitNode, node "string" (.string {
        format := some (.named "only-ok"), constValue := some "bad" })]),
    internalTagSuccess,
    libraryCheck "duplicate-internal-tags" "duplicate internal tags return LB-04" .lb04
      (internalTagLibrary "a"),
    libraryCheck "duplicate-member-shapes" "duplicate member shapes return LB-18" .lb18
      (libraryWith [unitNode, unionNode [
        branch "unit" "first" (.memberShape [("key", .absent)]),
        branch "unit" "second" (.memberShape [("key", .absent)])]]) ]

private def admissionProfile : VersionedSemanticProfile :=
  { validProfile with reference := { reference with identity := "" } }

private def jsonAdmission : Check :=
  let text := (encode admissionProfile).compress
  match Necoherence.SemanticProfile.decodeProfileJson admissionProfile.reference [] text text with
  | .error (.profile failure) =>
      { name := "checked-admission-profile-json",
        proposition := "profile JSON decoding returns typed PR-01",
        passed := failure.predicate == .pr01, actual := reprStr failure }
  | .error failure =>
      { name := "checked-admission-profile-json",
        proposition := "profile JSON decoding returns typed PR-01",
        passed := false, actual := reprStr failure }
  | .ok _ =>
      { name := "checked-admission-profile-json",
        proposition := "profile JSON decoding returns typed PR-01",
        passed := false, actual := "success" }

private def wireAdmission : Check :=
  match Necoherence.SemanticProfile.decodeCanonical admissionProfile.reference []
      (encode admissionProfile) with
  | .error (.profile failure) =>
      { name := "checked-admission-wire",
        proposition := "wire decoding returns typed PR-01",
        passed := failure.predicate == .pr01, actual := reprStr failure }
  | .error failure =>
      { name := "checked-admission-wire",
        proposition := "wire decoding returns typed PR-01",
        passed := false, actual := reprStr failure }
  | .ok _ =>
      { name := "checked-admission-wire",
        proposition := "wire decoding returns typed PR-01",
        passed := false, actual := "success" }

private def generationAdmission : Check :=
  let library := libraryWith [unitNode] (valueProfile admissionProfile)
  let entrypoints : List Necoherence.SignatureGeneration.Entrypoint :=
    [{ identity := "entry", definition := "entry" }]
  let expected := Necoherence.SignatureGeneration.basis library entrypoints
  let input : Necoherence.SignatureGeneration.Input :=
    { basis := expected, signatures := library, entrypoints }
  match Necoherence.SignatureGeneration.admitBasis input expected with
  | .error (.library (.profile failure)) =>
      { name := "checked-admission-generation-basis",
        proposition := "generation basis admission returns typed PR-01",
        passed := failure.predicate == .pr01, actual := reprStr failure }
  | .error failure =>
      { name := "checked-admission-generation-basis",
        proposition := "generation basis admission returns typed PR-01",
        passed := false, actual := reprStr failure }
  | .ok _ =>
      { name := "checked-admission-generation-basis",
        proposition := "generation basis admission returns typed PR-01",
        passed := false, actual := "success" }

private def checks : List Check :=
  [profileSuccess] ++ profileChecks ++ [meaningSuccess] ++ meaningChecks ++
    [librarySuccess] ++ libraryChecks ++ [jsonAdmission, wireAdmission, generationAdmission]

private def printCheck (check : Check) : IO Bool := do
  if check.passed then
    IO.println (check.name ++ ": ok")
    pure true
  else
    IO.eprintln (check.name ++ ": failed")
    IO.eprintln ("  proposition: " ++ check.proposition)
    IO.eprintln ("  actual: " ++ check.actual)
    pure false


def run : IO Unit := do
  let results ← checks.mapM printCheck
  if !results.all id then
    throw (IO.userError "profile and library predicate checks failed")

end Necoherence.Tests.ProfileAndLibraryPredicates

def main : IO Unit :=
  Necoherence.Tests.ProfileAndLibraryPredicates.run
