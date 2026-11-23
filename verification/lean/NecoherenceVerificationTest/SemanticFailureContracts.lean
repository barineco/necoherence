-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import NecoherenceVerification.SemanticInvariantRunner
import Necoherence.SemanticInvariantWire

open Lean Necoherence.SemanticTypes Necoherence.SemanticValidation Necoherence.SemanticComposition Necoherence.TypeSignatures
open NecoherenceTools.SemanticInvariantRunner

private def requireContract (condition : Bool) (message : String) : IO Unit :=
  if !condition then throw (IO.userError message) else pure ()

private def contractSource : SourceRef :=
  { repository := "contract", revision := "1", path := "types.json", contentDigest := "c", documentId := "types", declaredRevision := none }

private def contractSubject : TypeRef := { source := contractSource, definitionName := "subject", pointer := ["subject"] }

private def contractProfile : ProfileRef := { identity := "profile", revision := "1", contentDigest := "d" }

private def contractObligation : SemanticObligation :=
  { typeRef := contractSubject, origin := { source := contractSource, pointer := [] },
    valuePath := [.field "items", .index 0], profile := contractProfile, reason := .unknownFormat "format" }

private def legacyMeaningItem : Json :=
  Json.mkObj [("type_ref", typeRefJson contractSubject), ("predicate", Json.mkObj [("tag", .str "Mo01")]),
    ("location", .arr #[.str "meaning"])]

/-- The Meaning tag carries SemanticObligation values only: the legacy predicate and location shape and the SemanticMeaning tag are rejected. -/
def checkMeaningWire : IO Unit := do
  match compositionObligationDecode (Json.mkObj [("tag", .str "Meaning"), ("value", .arr #[legacyMeaningItem])]) with
  | .error _ => pure ()
  | .ok _ => throw (IO.userError "legacy Meaning shape decoded")
  match compositionObligationDecode (Json.mkObj [("tag", .str "SemanticMeaning"), ("value", .arr #[])]) with
  | .error _ => pure ()
  | .ok _ => throw (IO.userError "SemanticMeaning tag decoded")
  let encoded := compositionObligationEncode (.meaning [contractObligation])
  match encoded.getObjValAs? String "tag" with
  | .ok "Meaning" => pure ()
  | _ => throw (IO.userError "Meaning tag encoding")
  match compositionObligationDecode encoded with
  | .ok (.meaning [decoded]) => requireContract (decoded == contractObligation) "SemanticObligation Meaning roundtrip"
  | _ => throw (IO.userError "SemanticObligation Meaning decoding")
  IO.println "semantic_meaning_wire=single_tag legacy=rejected location=value_path"

private def contractLibrary : TypeSignatureLibrary :=
  { identity := "contract", revision := "1",
    profile := { reference := { identity := "synthetic", revision := "1", contentDigest := "contract" } },
    sources := [], definitions := [],
    nodes := [
      { id := "empty", shape := .unit },
      { id := "holder", shape := .product { fields := [
        { wireName := "slot", slot := { typeId := "empty", required := true, nullable := false } }] } }] }

private def namedContractType (graph : SemanticGraph) (name : String) : Option TypeRef :=
  (graph.nodes.find? (·.ref.definitionName == name)).map (·.ref)

private def contractInput (graph : SemanticGraph) (outputs : List GoalPort) (order : List (SiteId × SiteId))
    (constructions : List ConstructionRule) : CompositionInput := {
  identity := "composition", revision := "1", basis := SemanticBasis.of graph,
  signatures := [], initialInputs := [], initialResources := [],
  goal := { outputs, failures := [], finalResources := [] },
  invocationDomain := {
    identity := "domain", revision := "1", sites := [], permittedProjections := [],
    permittedConstructions := constructions, permittedTransforms := [], guards := [] },
  allowedEffects := [], explicitOrder := order, bounds := {} }

/-- Invocation domain failures name the offending element with a typed constructor. -/
def checkInvocationDomainConstructors : IO Unit := do
  let graph := contractLibrary.graph
  let some holder := namedContractType graph "holder" | throw (IO.userError "holder type missing")
  let some empty := namedContractType graph "empty" | throw (IO.userError "empty type missing")
  let goalPort : GoalPort :=
    { id := ⟨"goal"⟩, contract := { typeRef := holder, required := true, nullable := false }, sourceConstraint := .anyCompatible }
  match prepareDirectComposition graph (contractInput graph [] [] []) (fun _ _ => .ok ()) (fun _ _ => []) with
  | .error .emptyGoal => pure ()
  | _ => throw (IO.userError "empty goal is not typed")
  match prepareDirectComposition graph (contractInput graph [goalPort] [(⟨"site"⟩, ⟨"site"⟩)] []) (fun _ _ => .ok ()) (fun _ _ => []) with
  | .error (.explicitSiteOrderInvalid before after) =>
      requireContract (before.value == "site" && after.value == "site") "explicit site order identities"
  | _ => throw (IO.userError "explicit site order is not typed")
  match prepareDirectComposition graph (contractInput graph [goalPort] []
      [{ identity := "build", typeRef := empty, nestedFields := [] }]) (fun _ _ => .ok ()) (fun _ _ => []) with
  | .error (.constructionNotProduct identity reference) =>
      requireContract (identity == "build" && reference == empty) "construction identity and type"
  | _ => throw (IO.userError "construction that is not a product is not typed")
  match prepareDirectComposition graph (contractInput graph [goalPort] []
      [{ identity := "build", typeRef := holder, nestedFields := [("missing", "absent")] }]) (fun _ _ => .ok ()) (fun _ _ => []) with
  | .error (.nestedFieldUndeclared identity field) =>
      requireContract (identity == "build" && field == "missing") "undeclared nested field identity"
  | _ => throw (IO.userError "undeclared nested field is not typed")
  match prepareDirectComposition graph (contractInput graph [goalPort] []
      [{ identity := "build", typeRef := holder, nestedFields := [("slot", "absent")] }]) (fun _ _ => .ok ()) (fun _ _ => []) with
  | .error (.nestedConstructionMismatch identity field target reference) =>
      requireContract (identity == "build" && field == "slot" && target == "absent" && reference == empty) "nested construction identity and type"
  | _ => throw (IO.userError "unmatched nested construction is not typed")
  let missingSource : GoalPort :=
    { id := ⟨"goal"⟩, contract := { typeRef := holder, required := true, nullable := false },
      sourceConstraint := .initialOnly ⟨"missing"⟩ [] }
  match prepareDirectComposition graph (contractInput graph [missingSource] [] []) (fun _ _ => .ok ()) (fun _ _ => []) with
  | .error (.goalSourceConstraintUndefined port constraint) =>
      requireContract (port.value == "goal" && (match constraint with | .initialOnly id _ => id.value == "missing" | _ => false))
        "goal source constraint identity"
  | _ => throw (IO.userError "undefined goal source constraint is not typed")
  let failureInput := contractInput graph [goalPort] [] []
  let failureEmbedding : FailureEmbedding :=
    { id := ⟨"failure"⟩, origin := .function { identity := "absent", revision := "1", contentDigest := "d" } ⟨"outcome"⟩,
      contract := { typeRef := holder, required := true, nullable := false }, finalResources := [] }
  match prepareDirectComposition graph { failureInput with goal := { outputs := [goalPort], failures := [failureEmbedding], finalResources := [] } }
      (fun _ _ => .ok ()) (fun _ _ => []) with
  | .error (.failureEmbeddingOriginUndefined embedding origin) =>
      requireContract (embedding.value == "failure" && (match origin with | .function reference _ => reference.identity == "absent" | _ => false))
        "failure embedding origin identity"
  | _ => throw (IO.userError "undefined failure embedding origin is not typed")
  match prepareDirectComposition graph (contractInput graph [goalPort] []
      [{ identity := "build", typeRef := holder, nestedFields := [], fieldConstraints := [{ field := "absent", source := .anyCompatible, presence := .required }] }])
      (fun _ _ => .ok ()) (fun _ _ => []) with
  | .error (.fieldConstraintUnknownField identity field) =>
      requireContract (identity == "build" && field == "absent") "unknown field constraint identity"
  | _ => throw (IO.userError "unknown field constraint is not typed")
  match prepareDirectComposition graph (contractInput graph [goalPort] []
      [{ identity := "build", typeRef := holder, nestedFields := [("slot", "absent")],
         fieldConstraints := [{ field := "slot", source := .anyCompatible, presence := .required }] }])
      (fun _ _ => .ok ()) (fun _ _ => []) with
  | .error (.constrainedNestedField identity field) =>
      requireContract (identity == "build" && field == "slot") "constrained nested field identity"
  | _ => throw (IO.userError "constrained nested field is not typed")
  IO.println "invocation_domain=typed empty_goal=ok explicit_order=ok construction_product=ok nested=ok constraints=ok"

private def renameMember (json : Json) (oldKey newKey : String) : Json :=
  match json.getObj? with
  | .ok object => Json.mkObj (object.toList.map fun (key, value) => ((if key == oldKey then newKey else key), value))
  | .error _ => json

private def schemaDigest : String := String.ofList (List.replicate 64 'a')

private def schemaObligation : SemanticObligation :=
  let holder := Necoherence.TypeSignatures.typeRef "holder"
  { typeRef := holder, origin := { source := holder.source, pointer := ["items"] },
    valuePath := [.field "items", .index 0],
    profile := { identity := "profile", revision := "1", contentDigest := schemaDigest },
    reason := .unknownFormat "format" }

/-- The diagnostic schema accepts SemanticObligation values inside UnresolvedObligation and inside the closure TerminalAssessment, and rejects the legacy type_id shape. -/
def checkSemanticObligationSchema : IO Unit := do
  let input := contractInput contractLibrary.graph [] [] []
  let meaning := compositionObligationEncode (.meaning [schemaObligation])
  match Necoherence.SignatureCompositionDiagnostics.check contractLibrary input "UnresolvedObligation" meaning with
  | .ok _ => pure ()
  | .error failure => throw (IO.userError ("UnresolvedObligation Meaning rejected: " ++ reprStr failure))
  let unknown := Json.mkObj [("tag", .str "Unknown"), ("value", .arr #[meaning])]
  match Necoherence.SignatureCompositionDiagnostics.check contractLibrary input "TerminalAssessment" unknown with
  | .ok _ => pure ()
  | .error failure => throw (IO.userError ("TerminalAssessment Unknown rejected: " ++ reprStr failure))
  let legacyItem := renameMember (semanticObligationEncode schemaObligation) "type_ref" "type_id"
  let legacy := Json.mkObj [("tag", .str "Meaning"), ("value", .arr #[legacyItem])]
  match Necoherence.SignatureCompositionDiagnostics.check contractLibrary input "UnresolvedObligation" legacy with
  | .error _ => pure ()
  | .ok _ => throw (IO.userError "legacy type_id obligation accepted")
  let foreignSource := { (Necoherence.TypeSignatures.typeRef "").source with repository := "foreign" }
  let foreign : SemanticObligation := { schemaObligation with origin := { source := foreignSource, pointer := [] } }
  match Necoherence.SignatureCompositionDiagnostics.check contractLibrary input "SemanticObligation" (semanticObligationEncode foreign) with
  | .error (.syntax "$" "unresolved diagnostic source") => pure ()
  | .error failure => throw (IO.userError ("unresolved obligation source is not typed: " ++ reprStr failure))
  | .ok _ => throw (IO.userError "unresolved obligation source accepted")
  IO.println "semantic_obligation_schema=type_ref origin=occurrence closure=checked legacy=rejected source=checked"

private def permissionFunction (form : FunctionForm) : FunctionSignature :=
  { reference := { identity := "permission", revision := "1", contentDigest := "p" }, form, effect := .pureFunction,
    inputs := [], outcomes := [{ id := ⟨"done"⟩, form := .success, valuePorts := [], producedResources := [] }],
    resourceInputs := [], assumptionRef := "assumption", handlesFailure := none }

private def siteInput (signature : FunctionSignature) (allowed : List CompositionEffect) (transforms : List FunctionRef) :
    CompositionInput :=
  let base := contractInput contractLibrary.graph [] [] []
  { base with signatures := [signature], allowedEffects := allowed, invocationDomain := { base.invocationDomain with sites := [{ id := ⟨"site"⟩, function := signature.reference }], permittedTransforms := transforms } }

/-- Site effects and transforms name the offending function with a typed constructor. -/
def checkInvocationPermissions : IO Unit := do
  let graph := contractLibrary.graph
  let plain := permissionFunction .pure
  match prepareDirectComposition graph (siteInput plain [] []) (fun _ _ => .ok ()) (fun _ _ => []) with
  | .error (.siteEffectNotPermitted site effect) =>
      requireContract (site.value == "site" && effect == .pureFunction) "site effect identity and effect"
  | _ => throw (IO.userError "site effect outside allowedEffects is not typed")
  let transform := permissionFunction .declaredTransform
  match prepareDirectComposition graph (siteInput transform [.pureFunction] []) (fun _ _ => .ok ()) (fun _ _ => []) with
  | .error (.transformNotPermitted reference) =>
      requireContract (reference == transform.reference) "transform reference"
  | _ => throw (IO.userError "transform outside permittedTransforms is not typed")
  IO.println "invocation_permissions=typed site_effect=ok transform=ok"

private def cyclicLibrary : TypeSignatureLibrary :=
  { contractLibrary with nodes := contractLibrary.nodes ++ [{ id := "chain", shape := .product { fields := [
    { wireName := "next", slot := { typeId := "chain", required := false, nullable := false } }] } }] }

/-- Construction closure failures name the offending construction with a typed constructor. -/
def checkConstructionClosure : IO Unit := do
  let graph := contractLibrary.graph
  let some holder := namedContractType graph "holder" | throw (IO.userError "holder type missing")
  let holderGoal : GoalPort := { id := ⟨"goal"⟩, contract := { typeRef := holder, required := true, nullable := false }, sourceConstraint := .anyCompatible }
  let sourced : ConstructionRule := { identity := "build", typeRef := holder, nestedFields := [], fieldConstraints := [{ field := "slot", source := .initialOnly ⟨"missing"⟩ [], presence := .required }] }
  match prepareDirectComposition graph (contractInput graph [holderGoal] [] [sourced]) (fun _ _ => .ok ()) (fun _ _ => []) with
  | .error (.constructionFieldSourceUndefined identity constraint) =>
      requireContract (identity == "build" && constraint.field == "slot") "construction field source identity"
  | _ => throw (IO.userError "undefined construction field source is not typed")
  let cyclic := cyclicLibrary.graph
  let some chain := namedContractType cyclic "chain" | throw (IO.userError "chain type missing")
  let chainGoal : GoalPort := { id := ⟨"goal"⟩, contract := { typeRef := chain, required := true, nullable := false }, sourceConstraint := .anyCompatible }
  let looping : ConstructionRule := { identity := "build", typeRef := chain, nestedFields := [("next", "build")] }
  match prepareDirectComposition cyclic (contractInput cyclic [chainGoal] [] [looping]) (fun _ _ => .ok ()) (fun _ _ => []) with
  | .error (.cyclicConstruction identity) => requireContract (identity == "build") "cyclic construction identity"
  | _ => throw (IO.userError "cyclic construction is not typed")
  IO.println "construction_closure=typed field_source=ok cycle=ok"

private def valueFailureTarget (name : String) : Json :=
  Json.mkObj [("tag", .str "Type"), ("value", .str name)]

private def definitionRefJson (reference : DefinitionRef) : Json :=
  Json.mkObj [("source", sourceRefJson reference.source), ("name", .str reference.name)]
private def definitionNamed (name : String) : Json :=
  definitionRefJson { source := (Necoherence.TypeSignatures.typeRef "holder").source, name := name }
private def absentValue : Json := Necoherence.SignatureWire.encode SlotValue.absent
private def valueFailureDefinitionLibrary : TypeSignatureLibrary :=
  { contractLibrary with definitions := [
      { id := "holder", wireIdentity := "holder", shape := .value "holder" },
      { id := "empty-definition", wireIdentity := "empty-definition", shape := .value "empty" }] }
private def valueFailureCheck (json : Json) :=
  Necoherence.SignatureCompositionDiagnostics.check valueFailureDefinitionLibrary (contractInput contractLibrary.graph [] [] []) "ValueFailure" json
private def requireRejected (label : String) (json : Json) : IO Unit :=
  match valueFailureCheck json with
  | .error _ => pure ()
  | .ok _ => throw (IO.userError (label ++ " accepted"))
private def requireRejectedBy (label reason : String) (json : Json) : IO Unit :=
  match valueFailureCheck json with
  | .error (.syntax "$" found) => requireContract (found == reason) (label ++ " reason: " ++ found)
  | .error failure => throw (IO.userError (label ++ " untyped: " ++ reprStr failure))
  | .ok _ => throw (IO.userError (label ++ " accepted"))
private def valueFailureWith (members : List (String × Json)) : Json :=
  let holder := Necoherence.TypeSignatures.typeRef "holder"
  Json.mkObj ([("type_ref", typeRefJson holder),
    ("origin", Json.mkObj [("source", sourceRefJson holder.source), ("pointer", .arr #[.str "items"])]),
    ("value_path", .arr #[]), ("condition", Json.mkObj [("tag", .str "MissingRequired")]),
    ("reference_trace", .arr #[typeRefJson holder])] ++ members)

private def legacyValueFailure : Json :=
  Json.mkObj [("type_id", .str "holder"), ("target", valueFailureTarget "holder"),
    ("origin", Json.mkObj [("source", Json.mkObj [("repository", .str "ncoh-type-signatures"), ("revision", .str "1"),
      ("path", .str "holder"), ("content_digest", .str schemaDigest)]), ("locator", .arr #[.str "items"])]),
    ("value_path", .arr #[]), ("condition", Json.mkObj [("tag", .str "MissingRequired")]),
    ("observed", .str "absent"), ("reference_trace", .arr #[.str "holder"])]

/-- The diagnostic ValueFailure names its definition with a DefinitionRef and its observed value with a SlotValue, and rejects the target, string observed, type_id, unresolved definition, and untyped definition forms. -/
def checkValueFailureSchema : IO Unit := do
  match valueFailureCheck (valueFailureWith [("definition_ref", definitionNamed "holder"), ("observed", absentValue)]) with
  | .ok _ => pure ()
  | .error failure => throw (IO.userError ("ValueFailure definition_ref form rejected: " ++ reprStr failure))
  requireRejected "legacy target form" (valueFailureWith [("definition_ref", definitionNamed "holder"), ("target", valueFailureTarget "holder"), ("observed", absentValue)])
  requireRejected "string observed form" (valueFailureWith [("definition_ref", definitionNamed "holder"), ("observed", .str "absent")])
  requireRejected "legacy type_id form" legacyValueFailure
  requireRejectedBy "unresolved definition_ref" "unresolved diagnostic definition" (valueFailureWith [("definition_ref", definitionNamed "missing"), ("observed", absentValue)])
  requireRejectedBy "definition_ref without type_ref" "diagnostic definition does not contain type_ref" (valueFailureWith [("definition_ref", definitionNamed "empty-definition"), ("observed", absentValue)])
  IO.println "value_failure_schema=definition_ref observed=slot_value legacy=rejected definition=typed"

/-- The SourceRef wire keeps document_id and declared_revision, so a source reference round-trips with its document identity. -/
def checkSourceRefWire : IO Unit := do
  let source : SourceRef := { repository := "wire", revision := "1", path := "types.json", contentDigest := schemaDigest, documentId := "types-document", declaredRevision := some 7 }
  let encoded := Necoherence.SignatureWire.encode source
  match Necoherence.SignatureWire.decode (α := SourceRef) encoded with
  | .ok decoded => requireContract (decoded == source) "SourceRef wire round-trip"
  | .error failure => throw (IO.userError ("SourceRef wire decode: " ++ reprStr failure))
  match encoded.getObjValAs? String "document_id" with
  | .ok "types-document" => pure ()
  | _ => throw (IO.userError "SourceRef document_id encoding")
  match encoded.getObjVal? "declared_revision" with
  | .ok (.str "7") => pure ()
  | _ => throw (IO.userError "SourceRef declared_revision encoding")
  IO.println "source_ref_wire=roundtrip document_id=kept declared_revision=kept"

/-- The composition empty closure wraps the typed inclusion failure in invalidEmptyTypeClosure and accepts an empty reference set. -/
def checkEmptyTypeClosure : IO Unit := do
  let graph := contractLibrary.graph
  let some unitRef := namedContractType graph "empty" | throw (IO.userError "unit type missing")
  match verifyEmptyClosureInput graph [unitRef] with
  | .error (.invalidEmptyTypeClosure .forgedEmptiness) => pure ()
  | .error failure => throw (IO.userError ("empty closure failure is not wrapped: " ++ reprStr failure))
  | .ok _ => throw (IO.userError "non-empty type accepted in the composition empty closure")
  match verifyEmptyClosureInput graph [] with
  | .ok _ => pure ()
  | .error failure => throw (IO.userError ("empty closure rejected the empty set: " ++ reprStr failure))
  IO.println "empty_type_closure=wrapped invalid_empty_type_closure=typed"

private def invalidProfileLibrary : TypeSignatureLibrary :=
  { contractLibrary with profile := { contractLibrary.profile with reference := { contractLibrary.profile.reference with identity := "" } } }

def checkRunnerFailureKeepsLibraryCheck : IO Unit := do
  match samplesJudgement invalidProfileLibrary "holder" 3 5 with
  | .error (.libraryCheck (.profile _)) => pure ()
  | .error failure => throw (IO.userError ("library check failure is not typed: " ++ reprStr failure))
  | .ok _ => throw (IO.userError "invalid profile library accepted")
  IO.println "runner_failure=libraryCheck profile=typed"

def checkSharedReferenceDecoders : IO Unit := do
  match NecoherenceTools.SemanticReferenceWire.typeRefDecode (typeRefJson contractSubject) with
  | .ok decoded => requireContract (decoded == contractSubject) "TypeRef shared decode round-trip"
  | .error failure => throw (IO.userError ("TypeRef shared decode: " ++ reprStr failure))
  let slot : SlotContract := { typeRef := contractSubject, required := true, nullable := false }
  match NecoherenceTools.SemanticReferenceWire.slotContractDecode (fullSlotEncode slot) with
  | .ok decoded => requireContract (decoded == slot) "SlotContract shared decode round-trip"
  | .error failure => throw (IO.userError ("SlotContract shared decode: " ++ reprStr failure))
  let origin : OccurrenceRef := { source := contractSource, pointer := [] }
  match NecoherenceTools.SemanticReferenceWire.occurrenceRefDecode (Json.mkObj [("source", sourceRefJson contractSource), ("pointer", .arr #[])]) with
  | .ok decoded => requireContract (decoded == origin) "OccurrenceRef shared decode round-trip"
  | .error failure => throw (IO.userError ("OccurrenceRef shared decode: " ++ reprStr failure))
  IO.println "shared_reference_wire=roundtrip"

def runSemanticFailureContracts : IO Unit := do
  checkMeaningWire
  checkInvocationDomainConstructors
  checkInvocationPermissions
  checkConstructionClosure
  checkSemanticObligationSchema
  checkValueFailureSchema
  checkSourceRefWire
  checkEmptyTypeClosure
  checkRunnerFailureKeepsLibraryCheck
  checkSharedReferenceDecoders

#eval runSemanticFailureContracts
