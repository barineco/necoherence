-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SignatureGenerationBasis

namespace Necoherence.SignatureComposition
open Lean Necoherence.SemanticTypes Necoherence.SemanticComposition Necoherence.SignatureWire

private def liftJson (result : Except String α) : Except WireFailure α :=
  result.mapError (WireFailure.syntax "$")
private def payload (json : Json) : Except WireFailure Json := do
  keys json ["tag", "value"]
  liftJson (json.getObjVal? "value")
private def fields (json : Json) : Except WireFailure Json := do
  keys json ["tag", "fields"]
  liftJson (json.getObjVal? "fields")
private def unitTag (tag : String) : Json := Json.mkObj [("tag", .str tag)]
private def tupleTag (tag : String) (value : Json) : Json := Json.mkObj [("tag", .str tag), ("value", value)]
private def recordTag (tag : String) (values : List (String × Json)) : Json := Json.mkObj [("tag", .str tag), ("fields", Json.mkObj values)]
instance [Wire α] [Wire β] : Wire (α × β) where
  encode pair := .arr #[encode pair.1, encode pair.2]
  decode json := do
    let pair ← liftJson json.getArr?
    if pair.size != 2 then throw (WireFailure.syntax "$" "pair size")
    pure (← decode pair[0]!, ← decode pair[1]!)
private def typeRef (id : String) : TypeRef :=
  { source := { repository := "ncoh-type-signatures", revision := "1", path := "", contentDigest := "", documentId := "" },
    definitionName := id, pointer := [] }

instance : Wire TypeRef where
  encode value := encode value.definitionName
  decode json := return typeRef (← decode json)
instance : Wire DefinitionRef where
  encode value := encode value.name
  decode json := do
    let ref := typeRef (← decode (α := String) json)
    pure { source := ref.source, name := ref.definitionName }
instance : Wire SlotContract where
  encode value := Json.mkObj [("type_id", encode value.typeRef), ("required", encode value.required), ("nullable", encode value.nullable)]
  decode json := do
    keys json ["type_id", "required", "nullable"]
    pure { typeRef := ← get json "type_id", required := ← get json "required", nullable := ← get json "nullable" }

instance : Wire InputId where
  encode value := encode value.value
  decode json := return ⟨← decode json⟩

instance : Wire PortId where
  encode value := encode value.value
  decode json := return ⟨← decode json⟩

instance : Wire SiteId where
  encode value := encode value.value
  decode json := return ⟨← decode json⟩

instance : Wire OutcomeId where
  encode value := encode value.value
  decode json := return ⟨← decode json⟩

instance : Wire GoalPortId where
  encode value := encode value.value
  decode json := return ⟨← decode json⟩

instance : Wire LotId where
  encode value := encode value.value
  decode json := return ⟨← decode json⟩

instance : Wire RequirementId where
  encode value := encode value.value
  decode json := return ⟨← decode json⟩

instance : Wire ProductionId where
  encode value := encode value.value
  decode json := return ⟨← decode json⟩

instance : Wire GuardId where
  encode value := encode value.value
  decode json := return ⟨← decode json⟩

instance : Wire FailureEmbeddingId where
  encode value := encode value.value
  decode json := return ⟨← decode json⟩

instance : Wire FunctionRef where
  encode value := Json.mkObj [("identity", encode value.identity), ("revision", encode value.revision), ("content_digest", encode value.contentDigest)]
  decode json := do
    keys json ["identity", "revision", "content_digest"]
    pure { identity := ← get json "identity", revision := ← get json "revision", contentDigest := ← get json "content_digest" }

instance : Wire PathStep where
  encode
    | .field value => tupleTag "Field" (encode value)
    | .index value => tupleTag "Index" (encode value)
    | .variant value => tupleTag "Variant" (encode value)
  decode json := do
    match ← get (α := String) json "tag" with
    | "Field" => return .field (← decode (← payload json))
    | "Index" => return .index (← decode (← payload json))
    | "Variant" => return .variant (← decode (← payload json))
    | tag => throw (WireFailure.unknownTag "$.tag" tag)

instance : Wire SlotValue where
  encode
    | .absent => unitTag "Absent"
    | .null => unitTag "Null"
    | .present value => tupleTag "Present" (encode value)
  decode json := do
    match ← get (α := String) json "tag" with
    | "Absent" => do keys json ["tag"]; pure .absent
    | "Null" => do keys json ["tag"]; pure .null
    | "Present" => return .present (← decode (← payload json))
    | tag => throw (WireFailure.unknownTag "$.tag" tag)

instance : Wire SourceConstraint where
  encode
    | .anyCompatible => unitTag "AnyCompatible"
    | .initialOnly input path => recordTag "InitialOnly" [("input", encode input), ("path", encode path)]
    | .producedBy site outcome port path => recordTag "ProducedBy" [("site", encode site), ("outcome", encode outcome), ("port", encode port), ("path", encode path)]
  decode json := do
    match ← get (α := String) json "tag" with
    | "AnyCompatible" => do keys json ["tag"]; pure .anyCompatible
    | "InitialOnly" => do
      let row ← fields json
      keys row ["input", "path"]
      pure (.initialOnly (← get row "input") (← get row "path"))
    | "ProducedBy" => do
      let row ← fields json
      keys row ["site", "outcome", "port", "path"]
      pure (.producedBy (← get row "site") (← get row "outcome") (← get row "port") (← get row "path"))
    | tag => throw (WireFailure.unknownTag "$.tag" tag)

instance : Wire ResourceLotRef where
  encode
    | .initial value => tupleTag "Initial" (encode value)
    | .produced site outcome production => recordTag "Produced" [("site", encode site), ("outcome", encode outcome), ("production", encode production)]
  decode json := do
    match ← get (α := String) json "tag" with
    | "Initial" => return .initial (← decode (← payload json))
    | "Produced" => do
      let row ← fields json
      keys row ["site", "outcome", "production"]
      pure (.produced (← get row "site") (← get row "outcome") (← get row "production"))
    | tag => throw (WireFailure.unknownTag "$.tag" tag)

instance : Wire ResourceProducer where
  encode
    | .initial identity revision => recordTag "Initial" [("identity", encode identity), ("revision", encode revision)]
    | .invocationOutcome site outcome => recordTag "InvocationOutcome" [("site", encode site), ("outcome", encode outcome)]
  decode json := do
    match ← get (α := String) json "tag" with
    | "Initial" => do
      let row ← fields json
      keys row ["identity", "revision"]
      pure (.initial (← get row "identity") (← get row "revision"))
    | "InvocationOutcome" => do
      let row ← fields json
      keys row ["site", "outcome"]
      pure (.invocationOutcome (← get row "site") (← get row "outcome"))
    | tag => throw (WireFailure.unknownTag "$.tag" tag)

instance : Wire ResourceIdentityConstraint where
  encode
    | .any => unitTag "Any"
    | .exactly value => tupleTag "Exactly" (encode value)
  decode json := do
    match ← get (α := String) json "tag" with
    | "Any" => do keys json ["tag"]; pure .any
    | "Exactly" => return .exactly (← decode (← payload json))
    | tag => throw (WireFailure.unknownTag "$.tag" tag)

instance : Wire Necoherence.BindingMode where
  encode
    | .read => unitTag "Read"
    | .consume => unitTag "Consume"
  decode json := do
    match ← get (α := String) json "tag" with
    | "Read" => do keys json ["tag"]; pure .read
    | "Consume" => do keys json ["tag"]; pure .consume
    | tag => throw (WireFailure.unknownTag "$.tag" tag)

instance : Wire ResourceLot where
  encode value := Json.mkObj [("id", encode value.id), ("token_type", encode value.tokenType), ("producer", encode value.producer), ("revision", encode value.revision), ("quantity", encode value.quantity), ("provenance", encode value.provenance)]
  decode json := do
    keys json ["id", "token_type", "producer", "revision", "quantity", "provenance"]
    pure { id := ← get json "id", tokenType := ← get json "token_type", producer := ← get json "producer", revision := ← get json "revision", quantity := ← get json "quantity", provenance := ← get json "provenance" }

instance : Wire ResourceRequirement where
  encode value := Json.mkObj [("id", encode value.id), ("token_type", encode value.tokenType), ("mode", encode value.mode), ("multiplicity", encode value.multiplicity), ("required_revision", encode value.requiredRevision), ("identity", encode value.identity)]
  decode json := do
    keys json ["id", "token_type", "mode", "multiplicity", "required_revision", "identity"]
    pure { id := ← get json "id", tokenType := ← get json "token_type", mode := ← get json "mode", multiplicity := ← get json "multiplicity", requiredRevision := ← get json "required_revision", identity := ← get json "identity" }

instance : Wire ResourceProduction where
  encode value := Json.mkObj [("id", encode value.id), ("token_type", encode value.tokenType), ("revision", encode value.revision), ("quantity", encode value.quantity), ("provenance", encode value.provenance)]
  decode json := do
    keys json ["id", "token_type", "revision", "quantity", "provenance"]
    pure { id := ← get json "id", tokenType := ← get json "token_type", revision := ← get json "revision", quantity := ← get json "quantity", provenance := ← get json "provenance" }

instance : Wire InitialSource where
  encode
    | .argument => unitTag "Argument"
    | .suppliedValue value => tupleTag "SuppliedValue" (encode value)
  decode json := do
    match ← get (α := String) json "tag" with
    | "Argument" => do keys json ["tag"]; pure .argument
    | "SuppliedValue" => return .suppliedValue (← decode (← payload json))
    | tag => throw (WireFailure.unknownTag "$.tag" tag)

instance : Wire InitialInput where
  encode value := Json.mkObj [("id", encode value.id), ("contract", encode value.contract), ("source", encode value.source), ("resource", encode value.resource)]
  decode json := do
    keys json ["id", "contract", "source", "resource"]
    pure { id := ← get json "id", contract := ← get json "contract", source := ← get json "source", resource := ← get json "resource" }

instance : Wire InputPort where
  encode value := Json.mkObj [("id", encode value.id), ("contract", encode value.contract), ("source_constraint", encode value.sourceConstraint), ("resource_requirement", encode value.resourceRequirement)]
  decode json := do
    keys json ["id", "contract", "source_constraint", "resource_requirement"]
    pure { id := ← get json "id", contract := ← get json "contract", sourceConstraint := ← get json "source_constraint", resourceRequirement := ← get json "resource_requirement" }

instance : Wire OutputPort where
  encode value := Json.mkObj [("id", encode value.id), ("contract", encode value.contract), ("resource_production", encode value.resourceProduction)]
  decode json := do
    keys json ["id", "contract", "resource_production"]
    pure { id := ← get json "id", contract := ← get json "contract", resourceProduction := ← get json "resource_production" }

instance : Wire OutcomeForm where
  encode
    | .success => unitTag "Success"
    | .declaredFailure => unitTag "DeclaredFailure"
  decode json := do
    match ← get (α := String) json "tag" with
    | "Success" => do keys json ["tag"]; pure .success
    | "DeclaredFailure" => do keys json ["tag"]; pure .declaredFailure
    | tag => throw (WireFailure.unknownTag "$.tag" tag)

instance : Wire OutcomeContract where
  encode value := Json.mkObj [("id", encode value.id), ("form", encode value.form), ("value_ports", encode value.valuePorts), ("produced_resources", encode value.producedResources)]
  decode json := do
    keys json ["id", "form", "cause", "value_ports", "produced_resources"]
    let _ : Necoherence.TypeSignatures.OutcomeCause ← get json "cause"
    pure { id := ← get json "id", form := ← get json "form", valuePorts := ← get json "value_ports", producedResources := ← get json "produced_resources" }

instance : Wire FunctionForm where
  encode
    | .pure => unitTag "Pure"
    | .declaredTransform => unitTag "DeclaredTransform"
    | .operation value => tupleTag "Operation" (encode value)
  decode json := do
    match ← get (α := String) json "tag" with
    | "Pure" => do keys json ["tag"]; pure .pure
    | "DeclaredTransform" => do keys json ["tag"]; pure .declaredTransform
    | "Operation" => return .operation (← decode (← payload json))
    | tag => throw (WireFailure.unknownTag "$.tag" tag)

instance : Wire CompositionEffect where
  encode
    | .pureFunction => unitTag "PureFunction"
    | .httpRequestResponse => unitTag "HttpRequestResponse"
    | .dataOnly => unitTag "DataOnly"
  decode json := do
    match ← get (α := String) json "tag" with
    | "PureFunction" => do keys json ["tag"]; pure .pureFunction
    | "HttpRequestResponse" => do keys json ["tag"]; pure .httpRequestResponse
    | "DataOnly" => do keys json ["tag"]; pure .dataOnly
    | tag => throw (WireFailure.unknownTag "$.tag" tag)

instance : Wire GuardArm where
  encode
    | .present => unitTag "Present"
    | .absent => unitTag "Absent"
    | .null => unitTag "Null"
    | .unknownVariant => unitTag "UnknownVariant"
    | .accepted => unitTag "Accepted"
    | .rejected => unitTag "Rejected"
    | .variant value => tupleTag "Variant" (encode value)
  decode json := do
    match ← get (α := String) json "tag" with
    | "Present" => do keys json ["tag"]; pure .present
    | "Absent" => do keys json ["tag"]; pure .absent
    | "Null" => do keys json ["tag"]; pure .null
    | "UnknownVariant" => do keys json ["tag"]; pure .unknownVariant
    | "Accepted" => do keys json ["tag"]; pure .accepted
    | "Rejected" => do keys json ["tag"]; pure .rejected
    | "Variant" => return .variant (← decode (← payload json))
    | tag => throw (WireFailure.unknownTag "$.tag" tag)

instance : Wire FailureOrigin where
  encode
    | .function function outcome => recordTag "Function" [("function", encode function), ("outcome", encode outcome)]
    | .guard guard arm => recordTag "Guard" [("guard", encode guard), ("arm", encode arm)]
  decode json := do
    match ← get (α := String) json "tag" with
    | "Function" => do
      let row ← fields json
      keys row ["function", "outcome"]
      pure (.function (← get row "function") (← get row "outcome"))
    | "Guard" => do
      let row ← fields json
      keys row ["guard", "arm"]
      pure (.guard (← get row "guard") (← get row "arm"))
    | tag => throw (WireFailure.unknownTag "$.tag" tag)

instance : Wire FunctionSignature where
  encode value := Json.mkObj [("reference", encode value.reference), ("form", encode value.form), ("effect", encode value.effect), ("inputs", encode value.inputs), ("outcomes", encode value.outcomes), ("resource_inputs", encode value.resourceInputs), ("assumption_ref", encode value.assumptionRef), ("handles_failure", encode value.handlesFailure)]
  decode json := do
    keys json ["reference", "form", "effect", "inputs", "outcomes", "resource_inputs", "assumption_ref", "handles_failure"]
    pure { reference := ← get json "reference", form := ← get json "form", effect := ← get json "effect", inputs := ← get json "inputs", outcomes := ← get json "outcomes", resourceInputs := ← get json "resource_inputs", assumptionRef := ← get json "assumption_ref", handlesFailure := ← get json "handles_failure" }

instance : Wire InvocationSite where
  encode value := Json.mkObj [("id", encode value.id), ("function", encode value.function)]
  decode json := do
    keys json ["id", "function"]
    pure { id := ← get json "id", function := ← get json "function" }

instance : Wire PermittedProjection where
  encode value := Json.mkObj [("source_type", encode value.sourceType), ("path", encode value.path)]
  decode json := do
    keys json ["source_type", "path"]
    pure { sourceType := ← get json "source_type", path := ← get json "path" }

instance : Wire GuardKind where
  encode
    | .presence => unitTag "Presence"
    | .variants => unitTag "Variants"
    | .validate value => tupleTag "Validate" (encode value)
  decode json := do
    match ← get (α := String) json "tag" with
    | "Presence" => do keys json ["tag"]; pure .presence
    | "Variants" => do keys json ["tag"]; pure .variants
    | "Validate" => return .validate (← decode (← payload json))
    | tag => throw (WireFailure.unknownTag "$.tag" tag)

instance : Wire DeclaredGuard where
  encode value := Json.mkObj [("id", encode value.id), ("source_type", encode value.sourceType), ("path", encode value.path), ("kind", encode value.kind)]
  decode json := do
    keys json ["id", "source_type", "path", "kind"]
    pure { id := ← get json "id", sourceType := ← get json "source_type", path := ← get json "path", kind := ← get json "kind" }

instance : Wire FieldPresence where
  encode
    | .required => unitTag "Required"
    | .optional => unitTag "Optional"
  decode json := do
    match ← get (α := String) json "tag" with
    | "Required" => do keys json ["tag"]; pure .required
    | "Optional" => do keys json ["tag"]; pure .optional
    | tag => throw (WireFailure.unknownTag "$.tag" tag)

instance : Wire FieldConstraint where
  encode value := Json.mkObj [("field", encode value.field), ("source", encode value.source), ("presence", encode value.presence)]
  decode json := do
    keys json ["field", "source", "presence"]
    pure { field := ← get json "field", source := ← get json "source", presence := ← get json "presence" }

instance : Wire ConstructionRule where
  encode value := Json.mkObj [("identity", encode value.identity), ("type_id", encode value.typeRef), ("nested_fields", encode value.nestedFields), ("field_constraints", encode value.fieldConstraints)]
  decode json := do
    keys json ["identity", "type_id", "nested_fields", "field_constraints"]
    pure { identity := ← get json "identity", typeRef := ← get json "type_id", nestedFields := ← get json "nested_fields", fieldConstraints := ← get json "field_constraints" }

instance : Wire InvocationDomain where
  encode value := Json.mkObj [("identity", encode value.identity), ("revision", encode value.revision), ("sites", encode value.sites), ("permitted_projections", encode value.permittedProjections), ("permitted_constructions", encode value.permittedConstructions), ("permitted_transforms", encode value.permittedTransforms), ("guards", encode value.guards)]
  decode json := do
    keys json ["identity", "revision", "sites", "permitted_projections", "permitted_constructions", "permitted_transforms", "guards"]
    pure { identity := ← get json "identity", revision := ← get json "revision", sites := ← get json "sites", permittedProjections := ← get json "permitted_projections", permittedConstructions := ← get json "permitted_constructions", permittedTransforms := ← get json "permitted_transforms", guards := ← get json "guards" }

instance : Wire ResourceGoal where
  encode value := Json.mkObj [("lot", encode value.lot), ("multiplicity", encode value.multiplicity), ("revision", encode value.revision)]
  decode json := do
    keys json ["lot", "multiplicity", "revision"]
    pure { lot := ← get json "lot", multiplicity := ← get json "multiplicity", revision := ← get json "revision" }

instance : Wire GoalPort where
  encode value := Json.mkObj [("id", encode value.id), ("contract", encode value.contract), ("source_constraint", encode value.sourceConstraint)]
  decode json := do
    keys json ["id", "contract", "source_constraint"]
    pure { id := ← get json "id", contract := ← get json "contract", sourceConstraint := ← get json "source_constraint" }

instance : Wire FailureEmbedding where
  encode value := Json.mkObj [("id", encode value.id), ("origin", encode value.origin), ("contract", encode value.contract), ("final_resources", encode value.finalResources)]
  decode json := do
    keys json ["id", "origin", "contract", "final_resources"]
    pure { id := ← get json "id", origin := ← get json "origin", contract := ← get json "contract", finalResources := ← get json "final_resources" }

instance : Wire GoalSpec where
  encode value := Json.mkObj [("outputs", encode value.outputs), ("failures", encode value.failures), ("final_resources", encode value.finalResources)]
  decode json := do
    keys json ["outputs", "failures", "final_resources"]
    pure { outputs := ← get json "outputs", failures := ← get json "failures", finalResources := ← get json "final_resources" }

instance : Wire SelectionPolicy where
  encode
    | .requireUnique => unitTag "RequireUnique"
    | .anyFeasible => unitTag "AnyFeasible"
  decode json := do
    match ← get (α := String) json "tag" with
    | "RequireUnique" => do keys json ["tag"]; pure .requireUnique
    | "AnyFeasible" => do keys json ["tag"]; pure .anyFeasible
    | tag => throw (WireFailure.unknownTag "$.tag" tag)

instance : Wire ResourceBounds where
  encode value := Json.mkObj [("max_bindings", encode value.maxBindings), ("max_search_steps", encode value.maxSearchSteps), ("max_tokens", encode value.maxTokens)]
  decode json := do
    keys json ["max_bindings", "max_search_steps", "max_tokens"]
    pure { maxBindings := ← get json "max_bindings", maxSearchSteps := ← get json "max_search_steps", maxTokens := ← get json "max_tokens" }

instance : Wire SearchBounds where
  encode value := Json.mkObj [("max_expanded_states", encode value.maxExpandedStates), ("max_binding_candidates", encode value.maxBindingCandidates), ("max_type_obligations", encode value.maxTypeObligations), ("max_branch_nodes", encode value.maxBranchNodes), ("resource_bounds", encode value.resourceBounds), ("max_sample_length", encode value.maxSampleLength)]
  decode json := do
    keys json ["max_expanded_states", "max_binding_candidates", "max_type_obligations", "max_branch_nodes", "resource_bounds", "max_sample_length"]
    pure { maxExpandedStates := ← get json "max_expanded_states", maxBindingCandidates := ← get json "max_binding_candidates", maxTypeObligations := ← get json "max_type_obligations", maxBranchNodes := ← get json "max_branch_nodes", resourceBounds := ← get json "resource_bounds", maxSampleLength := ← get json "max_sample_length" }

structure CauseBinding where
  function : FunctionRef
  outcome : OutcomeId
  cause : Necoherence.TypeSignatures.OutcomeCause
  deriving Repr, DecidableEq

def signatureContract (causes : List CauseBinding) (function : FunctionSignature) :
    Except String Necoherence.TypeSignatures.OperationContract := do
  let outcomes ← function.outcomes.mapM fun outcome => do
    let some binding := causes.find? (fun binding => binding.function == function.reference && binding.outcome == outcome.id) |
      throw "missing outcome cause"
    pure ({
      id := outcome.id.value
      form := match outcome.form with | .success => .success | .declaredFailure => .declaredFailure
      cause := binding.cause
      valuePorts := outcome.valuePorts.map fun port =>
        { id := port.id.value, contract := { typeId := port.contract.typeRef.definitionName, required := port.contract.required, nullable := port.contract.nullable } }
      producedResources := outcome.producedResources.map fun production =>
        { id := production.id.value, tokenType := production.tokenType.definitionName, revision := production.revision, quantity := production.quantity, provenance := production.provenance }
    } : Necoherence.TypeSignatures.OutcomeContract)
  pure {
    effect := match function.effect with | .httpRequestResponse => .httpRequestResponse | _ => .dataOnly
    inputs := function.inputs.map fun port =>
      { id := port.id.value, contract := { typeId := port.contract.typeRef.definitionName, required := port.contract.required, nullable := port.contract.nullable } }
    outcomes := outcomes }

def checkOperation (library : Necoherence.TypeSignatures.TypeSignatureLibrary) (graphDigest : String)
    (causes : List CauseBinding) (function : FunctionSignature) (reference : DefinitionRef) :
    Except CompositionInputFailure Unit := do
  let invalid := CompositionInputFailure.invalidSignature function.reference
  let some definition := library.definitions.find? (fun definition => definition.id == reference.name) |
    throw (invalid "unresolved operation identity")
  let .operation base := definition.shape | throw (invalid "definition is not an operation")
  if function.reference.identity != definition.wireIdentity || function.reference.revision != library.revision ||
      function.reference.contentDigest != graphDigest then throw (invalid "operation identity basis")
  let extended ← (signatureContract causes function).mapError invalid
  let expectedEffect : CompositionEffect := match base.effect with
    | .httpRequestResponse => .httpRequestResponse
    | .dataOnly => .dataOnly
  if function.effect != expectedEffect then throw (invalid "operation effect")
  if !Necoherence.TypeSignatures.operationExtensionValid base extended library then
    throw (invalid "base outcome preservation or external supplement")

def prepare (library : Necoherence.TypeSignatures.TypeSignatureLibrary) (graphDigest : String)
    (input : CompositionInput) (causes : List CauseBinding) : Except CompositionInputFailure PreparedCompositionInput := do
  let _ ← (Necoherence.TypeSignatures.checkLibrary library).mapError
    (fun reason => .invalidInvocationDomain (reprStr reason))
  for function in input.signatures do
    let contract ← (signatureContract causes function).mapError (CompositionInputFailure.invalidSignature function.reference)
    if !contract.outcomes.all (Necoherence.TypeSignatures.outcomeValid library) then
      throw (.invalidSignature function.reference "outcome cause or external failure value")
  prepareDirectComposition library.graph input (checkOperation library graphDigest causes)
    (fun function _ => Necoherence.SemanticValidation.meaningObligations library.graph
      (function.inputs.map (·.contract.typeRef) ++ function.resourceInputs.map (·.tokenType) ++
        function.outcomes.flatMap (fun outcome => outcome.valuePorts.map (·.contract.typeRef) ++ outcome.producedResources.map (·.tokenType))))

def decodeProblem (library : Necoherence.TypeSignatures.TypeSignatureLibrary)
    (json : Json) : Except WireFailure (CompositionInput × List CauseBinding) := do
  keys json ["identity", "revision", "basis", "signatures", "initial_inputs", "initial_resources", "goal",
    "invocation_domain", "allowed_effects", "explicit_order", "selection_policy", "bounds"]
  let supplied : Necoherence.SignatureGeneration.Basis ← get json "basis"
  let expected := Necoherence.SignatureGeneration.basis library []
  if supplied != expected then
    throw (WireFailure.syntax "$.basis" "composition signature basis mismatch")
  let signatureRows ← liftJson (← liftJson (json.getObjVal? "signatures")).getArr?
  let signatures ← signatureRows.toList.mapM (decode (α := FunctionSignature))
  let causes ← signatureRows.toList.flatMapM fun row => do
    let reference : FunctionRef ← get row "reference"
    let outcomes ← liftJson (← liftJson (row.getObjVal? "outcomes")).getArr?
    outcomes.toList.mapM fun outcome => do
      pure { function := reference, outcome := ← get outcome "id", cause := ← get outcome "cause" }
  let input : CompositionInput := {
    identity := ← get json "identity"
    revision := ← get json "revision"
    basis := SemanticBasis.of library.graph
    signatures := signatures
    initialInputs := ← get json "initial_inputs"
    initialResources := ← get json "initial_resources"
    goal := ← get json "goal"
    invocationDomain := ← get json "invocation_domain"
    allowedEffects := ← get json "allowed_effects"
    explicitOrder := ← get json "explicit_order"
    selectionPolicy := ← get json "selection_policy"
    bounds := ← get json "bounds" }
  pure (input, causes)

end Necoherence.SignatureComposition
