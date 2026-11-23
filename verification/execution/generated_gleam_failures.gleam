// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only
fn nested_failure(constructor: String, arguments: List(json.Json)) -> json.Json {
  json.object([
    #("constructor", json.string(constructor)),
    #("arguments", json.preprocessed_array(arguments)),
  ])
}

fn exact_json(value: exact.JsonValue) -> json.Json {
  case value {
    exact.JsonValueNull -> json.null()
    exact.JsonValueBool(value) -> json.bool(value)
    exact.JsonValueNum(value) -> json.int(value)
    exact.JsonValueDec(_) -> panic as "decimal failure output unsupported"
    exact.JsonValueStr(value) -> json.string(value)
    exact.JsonValueArr(items) ->
      json.preprocessed_array(list.map(items, exact_json))
    exact.JsonValueObj(members) ->
      json.object(list.map(members, fn(member) {
        #(member.0, exact_json(member.1))
      }))
  }
}

fn source_ref_json(source: types.SourceRef) -> json.Json {
  json.object([
    #("repository", json.string(source.repository)),
    #("revision", json.string(source.revision)),
    #("path", json.string(source.path)),
    #("contentDigest", json.string(source.content_digest)),
    #("documentId", json.string(source.document_id)),
    #("declaredRevision", case source.declared_revision {
      None -> json.null()
      Some(value) -> json.string(int.to_string(value))
    }),
  ])
}

fn type_ref_json(reference: types.TypeRef) -> json.Json {
  json.object([
    #("source", source_ref_json(reference.source)),
    #("definitionName", json.string(reference.definition_name)),
    #("pointer", json.array(reference.pointer, json.string)),
  ])
}

fn value_type_ref_json(reference: types.TypeRef) -> json.Json {
  json.object([
    #("source", source_ref_json(reference.source)),
    #("definition", json.string(reference.definition_name)),
    #("pointer", json.array(reference.pointer, json.string)),
  ])
}

fn occurrence_ref_json(reference: types.OccurrenceRef) -> json.Json {
  json.object([
    #("source", source_ref_json(reference.source)),
    #("pointer", json.array(reference.pointer, json.string)),
  ])
}

fn path_json(path: types.ValuePath) -> json.Json {
  json.preprocessed_array(list.map(path, fn(step) {
    case step {
      types.Field(name) -> nested_failure("field", [json.string(name)])
      types.Index(index) -> nested_failure("index", [json.string(int.to_string(index))])
      types.Variant(tag) -> nested_failure("variant", [json.string(tag)])
    }
  }))
}

fn value_path_json(path: types.ValuePath) -> json.Json {
  json.preprocessed_array(list.map(path, fn(step) {
    case step {
      types.Field(name) -> json.object([#("field", json.string(name))])
      types.Index(index) -> json.object([#("index", json.int(index))])
      types.Variant(tag) -> json.object([#("variant", json.string(tag))])
    }
  }))
}

fn semantic_reason_json(reason: types.SemanticReason) -> json.Json {
  case reason {
    types.UnknownFormatReason(name) -> nested_failure("unknownFormat", [json.string(name)])
    types.MissingGraphemeRulesReason -> nested_failure("missingGraphemeRules", [])
    types.MissingBytesPolicyReason -> nested_failure("missingBytesPolicy", [])
    types.UnknownIntegerDomainReason(name) -> nested_failure("unknownIntegerDomain", [json.string(name)])
    types.UnknownWrapperReason(name) -> nested_failure("unknownWrapper", [json.string(name)])
    types.WrapperPayloadReason(name) -> nested_failure("wrapperPayload", [json.string(name)])
    types.UnknownSealedTagReason(tag) -> nested_failure("unknownSealedTag", [json.string(tag)])
    types.DecimalNotAdmittedReason -> nested_failure("decimalNotAdmitted", [])
    types.IntegerBoundReason -> nested_failure("integerBound", [])
    types.OpaqueTypeReason(name) -> nested_failure("opaqueType", [json.string(name)])
    types.MissingTagModelReason -> nested_failure("missingTagModel", [])
    types.UnresolvedTypeReason -> nested_failure("unresolvedType", [])
    types.MembershipBoundReason -> nested_failure("membershipBound", [])
    types.UninterpretedExtensionReason(key) ->
      nested_failure("uninterpretedExtension", [json.string(key)])
    types.InvalidProfileReason(condition) ->
      nested_failure("invalidProfile", [json.string(condition)])
    types.CertificateMismatchReason(condition) ->
      nested_failure("certificateMismatch", [json.string(condition)])
    types.ProjectionUnavailableReason(condition) ->
      nested_failure("projectionUnavailable", [json.string(condition)])
  }
}

fn semantic_obligation_json(obligation: types.SemanticObligation) -> json.Json {
  json.object([
    #("typeRef", value_type_ref_json(obligation.type_ref)),
    #("valuePath", value_path_json(obligation.value_path)),
    #("reason", semantic_reason_json(obligation.reason)),
  ])
}

fn value_failure_json(failure: types.ValueFailure) -> json.Json {
  let assert Ok(condition) = generation_decode.encode_value_condition(failure.condition)
  let assert Ok(observed) = generation_decode.encode_slot_value(failure.observed)
  json.object([
    #("typeRef", value_type_ref_json(failure.type_ref)),
    #("definitionRef", json.object([
      #("source", source_ref_json(failure.type_ref.source)),
      #("name", json.string(failure.type_ref.definition_name)),
    ])),
    #("origin", occurrence_ref_json(failure.origin)),
    #("valuePath", value_path_json(failure.value_path)),
    #("condition", exact_json(condition)),
    #("observed", exact_json(observed)),
    #("referenceTrace", json.preprocessed_array(list.map(failure.reference_trace, value_type_ref_json))),
  ])
}

fn validation_failure_json(failure: validation.ValidationFailure) -> json.Json {
  case failure {
    validation.Rejected(value) -> nested_failure("value", [value_failure_json(value)])
    validation.Unresolved(obligations) -> nested_failure("unresolved", [json.preprocessed_array(list.map(obligations, semantic_obligation_json))])
    validation.CertificateMismatchFailure(condition) -> nested_failure("certificateMismatch", [json.string(condition)])
  }
}

fn value_ref_json(reference: composition.ValueRef) -> json.Json {
  let producer = case reference.producer {
    composition.Initial(id) -> nested_failure("initial", [json.string(id.value)])
    composition.InvocationOutcome(site, outcome, port) ->
      nested_failure("invocationOutcome", [
        json.string(site.value),
        json.string(outcome.value),
        json.string(port.value),
      ])
  }
  json.object([
    #("producer", producer),
    #("path", path_json(reference.path)),
  ])
}

fn slot_contract_json(contract: types.SlotContract) -> json.Json {
  json.object([
    #("typeRef", type_ref_json(contract.type_ref)),
    #("required", json.bool(contract.required)),
    #("nullable", json.bool(contract.nullable)),
  ])
}

fn type_obligation_json(obligation: composition.TypeObligation) -> json.Json {
  let reason = case obligation.reason {
    composition.TypeMeaning(obligations) -> nested_failure("meaning", [
      json.preprocessed_array(list.map(obligations, semantic_obligation_json)),
    ])
    composition.ConstraintImplication -> nested_failure("constraintImplication", [])
    composition.TypePresence -> nested_failure("presence", [])
    composition.UnionRemainder -> nested_failure("unionRemainder", [])
    composition.ExtraField(name) -> nested_failure("extraField", [json.string(name)])
    composition.TypeInhabitation -> nested_failure("inhabitation", [])
    composition.ObligationBoundExhausted -> nested_failure("obligationBoundExhausted", [])
  }
  json.object([
    #("pair", json.object([
      #("source", slot_contract_json(obligation.pair.source)),
      #("destination", slot_contract_json(obligation.pair.destination)),
    ])),
    #("path", path_json(obligation.path)),
    #("reason", reason),
  ])
}

fn inclusion_failure_json(failure: composition.InclusionFailure) -> json.Json {
  case failure {
    composition.InclusionBasisMismatch -> nested_failure("basisMismatch", [])
    composition.ContractMismatch -> nested_failure("contractMismatch", [])
    composition.UndefinedMeaning(obligations) -> nested_failure("undefinedMeaning", [
      json.preprocessed_array(list.map(obligations, semantic_obligation_json)),
    ])
    composition.MissingPair -> nested_failure("missingPair", [])
    composition.PairMismatch(index) -> nested_failure("pairMismatch", [json.string(int.to_string(index))])
    composition.RuleMismatch(index) -> nested_failure("ruleMismatch", [json.string(int.to_string(index))])
    composition.ChildCoverage(index) -> nested_failure("childCoverage", [json.string(int.to_string(index))])
    composition.ForgedEmptiness -> nested_failure("forgedEmptiness", [])
    composition.CounterexampleMismatch -> nested_failure("counterexampleMismatch", [])
    composition.InclusionUnresolved(obligation) -> nested_failure("unresolved", [type_obligation_json(obligation)])
  }
}

fn projection_failure_json(failure: validation.ProjectionFailure) -> json.Json {
  case failure {
    validation.WrongShape(reference, path) -> nested_failure("wrongShape", [type_ref_json(reference), path_json(path)])
    validation.MissingField(reference, name) -> nested_failure("missingField", [type_ref_json(reference), json.string(name)])
    validation.MissingVariant(reference, tag) -> nested_failure("missingVariant", [type_ref_json(reference), json.string(tag)])
    validation.BranchAssumptionRequired(path, tag) -> nested_failure("branchAssumptionRequired", [path_json(path), json.string(tag)])
    validation.VariantSelectionUndetermined(path, tag) -> nested_failure("variantSelectionUndetermined", [path_json(path), json.string(tag)])
    validation.ProjectionUnresolved(obligations) -> nested_failure("unresolved", [json.preprocessed_array(list.map(obligations, semantic_obligation_json))])
    validation.CertificateMismatch(condition) -> nested_failure("certificateMismatch", [json.string(condition)])
  }
}

fn composition_input_failure_json(failure: composition.CompositionInputFailure) -> json.Json {
  case failure {
    composition.InputBasisMismatch -> nested_failure("basisMismatch", [])
    composition.DuplicateIdentity(kind, identity) -> nested_failure("duplicateIdentity", [json.string(kind), json.string(identity)])
    composition.UnresolvedType(reference) -> nested_failure("unresolvedType", [type_ref_json(reference)])
    composition.UnresolvedFunction(reference) -> nested_failure("unresolvedFunction", [json.object([
      #("identity", json.string(reference.identity)),
      #("revision", json.string(reference.revision)),
      #("contentDigest", json.string(reference.content_digest)),
    ])])
    composition.InvalidSignature(reference, reason) -> nested_failure("invalidSignature", [json.object([
      #("identity", json.string(reference.identity)),
      #("revision", json.string(reference.revision)),
      #("contentDigest", json.string(reference.content_digest)),
    ]), json.string(reason)])
    composition.InvalidInitialValue(id, failure) -> nested_failure("invalidInitialValue", [json.string(id.value), value_failure_json(failure)])
    composition.SiteEffectNotPermitted(composition.SiteId(site), effect) -> nested_failure("siteEffectNotPermitted", [json.string(site), wire_effect(effect)])
    composition.TransformNotPermitted(reference) -> nested_failure("transformNotPermitted", [function_ref_json(reference)])
    composition.EmptyGoal -> nested_failure("emptyGoal", [])
    composition.GoalSourceConstraintUndefined(composition.GoalPortId(port), constraint) -> nested_failure("goalSourceConstraintUndefined", [json.string(port), wire_source_constraint(constraint)])
    composition.FailureEmbeddingOriginUndefined(composition.FailureEmbeddingId(embedding), origin) -> nested_failure("failureEmbeddingOriginUndefined", [json.string(embedding), wire_failure_origin(origin)])
    composition.ConstructionNotProduct(identity, reference) -> nested_failure("constructionNotProduct", [json.string(identity), type_ref_json(reference)])
    composition.FieldConstraintUnknownField(identity, field) -> nested_failure("fieldConstraintUnknownField", [json.string(identity), json.string(field)])
    composition.ConstrainedNestedField(identity, field) -> nested_failure("constrainedNestedField", [json.string(identity), json.string(field)])
    composition.ConstructionFieldSourceUndefined(identity, constraint) -> nested_failure("constructionFieldSourceUndefined", [json.string(identity), wire_field_constraint(constraint)])
    composition.NestedFieldUndeclared(identity, field) -> nested_failure("nestedFieldUndeclared", [json.string(identity), json.string(field)])
    composition.NestedConstructionMismatch(identity, field, nested, reference) -> nested_failure("nestedConstructionMismatch", [json.string(identity), json.string(field), json.string(nested), type_ref_json(reference)])
    composition.CyclicConstruction(identity) -> nested_failure("cyclicConstruction", [json.string(identity)])
    composition.ExplicitSiteOrderInvalid(composition.SiteId(before), composition.SiteId(after)) -> nested_failure("explicitSiteOrderInvalid", [json.string(before), json.string(after)])
    composition.InvalidEmptyTypeClosure(failure) -> nested_failure("invalidEmptyTypeClosure", [inclusion_failure_json(failure)])
    composition.InvalidResourceDeclaration(reason) -> nested_failure("invalidResourceDeclaration", [json.string(reason)])
    composition.InvalidLibrary(failure) -> nested_failure("invalidLibrary", [library_check_failure_json(failure)])
  }
}

fn library_check_failure_json(failure: types.LibraryCheckFailure) -> json.Json {
  case failure {
    types.ProfileCheck(failure) ->
      nested_failure("profile", [
        json.object([
          #("identity", json.string(failure.reference.identity)),
          #("revision", json.string(failure.reference.revision)),
          #("contentDigest", json.string(failure.reference.content_digest)),
        ]),
        json.string(profile_predicate_code(failure.predicate)),
        json.array(failure.location, json.string),
      ])
    types.LibraryCheck(failure) ->
      nested_failure("library", [
        json.string(failure.reference),
        json.string(library_predicate_code(failure.predicate)),
        json.array(failure.location, json.string),
      ])
  }
}


fn wire_tag(tag: String) -> json.Json {
  json.object([#("tag", json.string(tag))])
}

fn wire_tuple(tag: String, value: json.Json) -> json.Json {
  json.object([#("tag", json.string(tag)), #("value", value)])
}

fn wire_record(tag: String, fields: List(#(String, json.Json))) -> json.Json {
  json.object([#("tag", json.string(tag)), #("fields", json.object(fields))])
}

fn wire_effect(effect: composition.CompositionEffect) -> json.Json {
  case effect {
    composition.PureFunction -> wire_tag("PureFunction")
    composition.HttpRequestResponse -> wire_tag("HttpRequestResponse")
    composition.DataOnly -> wire_tag("DataOnly")
  }
}

fn wire_path_step(step: types.PathStep) -> json.Json {
  case step {
    types.Field(name) -> wire_tuple("Field", json.string(name))
    types.Index(index) -> wire_tuple("Index", json.int(index))
    types.Variant(tag) -> wire_tuple("Variant", json.string(tag))
  }
}

fn wire_source_constraint(constraint: composition.SourceConstraint) -> json.Json {
  case constraint {
    composition.AnyCompatible -> wire_tag("AnyCompatible")
    composition.InitialOnly(composition.InputId(input), path) ->
      wire_record("InitialOnly", [
        #("input", json.string(input)),
        #("path", json.array(path, wire_path_step)),
      ])
    composition.ProducedBy(
      composition.SiteId(site),
      composition.OutcomeId(outcome),
      composition.PortId(port),
      path,
    ) ->
      wire_record("ProducedBy", [
        #("site", json.string(site)),
        #("outcome", json.string(outcome)),
        #("port", json.string(port)),
        #("path", json.array(path, wire_path_step)),
      ])
  }
}

fn wire_function_ref(reference: composition.FunctionRef) -> json.Json {
  json.object([
    #("identity", json.string(reference.identity)),
    #("revision", json.string(reference.revision)),
    #("content_digest", json.string(reference.content_digest)),
  ])
}

fn wire_guard_arm(arm: composition.GuardArm) -> json.Json {
  case arm {
    composition.GuardPresent -> wire_tag("Present")
    composition.GuardAbsent -> wire_tag("Absent")
    composition.GuardNull -> wire_tag("Null")
    composition.GuardVariant(tag) -> wire_tuple("Variant", json.string(tag))
    composition.UnknownVariant -> wire_tag("UnknownVariant")
    composition.GuardAccepted -> wire_tag("Accepted")
    composition.GuardRejected -> wire_tag("Rejected")
  }
}

fn wire_failure_origin(origin: composition.FailureOrigin) -> json.Json {
  case origin {
    composition.FunctionFailure(function, composition.OutcomeId(outcome)) ->
      wire_record("Function", [
        #("function", wire_function_ref(function)),
        #("outcome", json.string(outcome)),
      ])
    composition.GuardFailure(composition.GuardId(guard), arm) ->
      wire_record("Guard", [
        #("guard", json.string(guard)),
        #("arm", wire_guard_arm(arm)),
      ])
  }
}

fn wire_field_constraint(constraint: composition.FieldConstraint) -> json.Json {
  json.object([
    #("field", json.string(constraint.field)),
    #("source", wire_source_constraint(constraint.source)),
    #(
      "presence",
      wire_tag(case constraint.presence {
        composition.Required -> "Required"
        composition.Optional -> "Optional"
      }),
    ),
  ])
}

fn witness_failure_json(failure: resource_witness.WitnessFailure) -> json.Json {
  case failure {
    resource_witness.InputRevisionMismatch -> nested_failure("inputRevisionMismatch", [])
    resource_witness.InitialMembership(id) -> nested_failure("initialMembership", [json.string(id.value)])
    resource_witness.ProducerMismatch(reference) -> nested_failure("producerMismatch", [value_ref_json(reference)])
    resource_witness.ProjectionMismatch(failure) -> nested_failure("projectionMismatch", [projection_failure_json(failure)])
    resource_witness.SourceConstraintMismatch(reference) -> nested_failure("sourceConstraintMismatch", [value_ref_json(reference)])
    resource_witness.InclusionMismatch(failure) -> nested_failure("inclusion", [inclusion_failure_json(failure)])
    resource_witness.SuppliedValueMismatch(reference) -> nested_failure("suppliedValueMismatch", [value_ref_json(reference)])
    resource_witness.ConstructionMismatch(reference) -> nested_failure("constructionMismatch", [type_ref_json(reference)])
    resource_witness.MissingBinding(identity) -> nested_failure("missingBinding", [json.string(identity)])
    resource_witness.SignatureMismatch(site) -> nested_failure("signatureMismatch", [json.string(site.value)])
    resource_witness.GuardNotDominating(reference) -> nested_failure("guardNotDominating", [value_ref_json(reference)])
    resource_witness.IncompleteBranchCoverage(identity) -> nested_failure("incompleteBranchCoverage", [json.string(identity)])
    resource_witness.FailureEmbeddingMismatch(id) -> nested_failure("failureEmbeddingMismatch", [json.string(id.value)])
    resource_witness.GoalMismatch -> nested_failure("goalMismatch", [])
    resource_witness.RankViolation -> nested_failure("rankViolation", [])
    resource_witness.ResourceLoweringMismatch(reason) -> nested_failure("resourceLoweringMismatch", [json.string(reason)])
    resource_witness.ResourceReplayMismatch(reason) -> nested_failure("resourceReplayMismatch", [json.string(reason)])
    resource_witness.ForgedClosure(reason) -> nested_failure("forgedClosure", [json.string(reason)])
    resource_witness.ForgedAcyclicity(reason) -> nested_failure("forgedAcyclicity", [json.string(reason)])
    resource_witness.MissingEvidence(reason) -> nested_failure("missingEvidence", [json.string(reason)])
  }
}

fn function_ref_json(function: composition.FunctionRef) -> json.Json {
  json.object([
    #("identity", json.string(function.identity)),
    #("revision", json.string(function.revision)),
    #("contentDigest", json.string(function.content_digest)),
  ])
}

fn lot_json(lot: composition.ResourceLotRef) -> json.Json {
  case lot {
    composition.InitialLot(composition.LotId(id)) ->
      nested_failure("initial", [json.string(id)])
    composition.ProducedLot(
      composition.SiteId(site),
      composition.OutcomeId(outcome),
      composition.ProductionId(production),
    ) ->
      nested_failure("produced", [
        json.string(site),
        json.string(outcome),
        json.string(production),
      ])
  }
}

fn stage_name(stage: network.HostStage) -> String {
  case stage {
    network.Start -> "Start"
    network.RequestWrite -> "RequestWrite"
    network.ResponseHeaders -> "ResponseHeaders"
    network.ResponseBody -> "ResponseBody"
    network.Cancel -> "Cancel"
    network.DeadlineStage -> "Deadline"
  }
}

fn host_failure_name(cause: network.HostFailure) -> String {
  case cause {
    network.UnsupportedUriScheme -> "UnsupportedUriScheme"
    network.InvalidHostConfiguration -> "InvalidHostConfiguration"
    network.ExecutionStartFailed -> "ExecutionStartFailed"
    network.NameResolutionFailed -> "NameResolutionFailed"
    network.ConnectionFailed -> "ConnectionFailed"
    network.RequestWriteFailed -> "RequestWriteFailed"
    network.ResponseHeadersFailed -> "ResponseHeadersFailed"
    network.ResponseBodyFailed -> "ResponseBodyFailed"
    network.ResponseBodyLimitExceeded -> "ResponseBodyLimitExceeded"
    network.MalformedResponse -> "MalformedResponse"
    network.HeaderRepresentationUnavailable -> "HeaderRepresentationUnavailable"
    network.RequestHeaderEncodingUnavailable ->
      "RequestHeaderEncodingUnavailable"
    network.CancellationRejected -> "CancellationRejected"
    network.DeadlineControlUnavailable -> "DeadlineControlUnavailable"
    network.Timeout(_, _) -> "Timeout"
    network.HostRuntimeFailure -> "HostRuntimeFailure"
    network.HostClosed -> "HostClosed"
  }
}

fn unknown_effect_reason_name(reason: network.UnknownEffectReason) -> String {
  case reason {
    network.NoResponse -> "NoResponse"
    network.CancellationReason -> "Cancellation"
    network.DeadlineReason -> "Deadline"
    network.HostFailure -> "HostFailure"
    network.ProtocolWitnessMissing -> "ProtocolWitnessMissing"
    network.LateSignal -> "LateSignal"
  }
}

fn failure_json(failure: runtime.ExecutionFailure) -> String {
  let value = case failure {
    runtime.InvalidPlan(condition) -> json.object([#("tag", json.string("invalidPlan")), #("condition", json.string(condition))])
    runtime.ProviderFailure(composition.SiteId(site), message) -> json.object([#("tag", json.string("provider")), #("site", json.string(site)), #("message", json.string(message))])
    runtime.NetworkTerminal(network.NetworkTerminal(outcome, effect)) -> {
      let #(outcome_name, stage, cause) = case outcome {
        network.Failed(network.NetworkHostFailure(_, stage, _, cause)) -> #("Failed", json.string(stage_name(stage)), json.string(host_failure_name(cause)))
        network.Response(_, _) -> #("Response", json.null(), json.null())
        network.Cancelled -> #("Cancelled", json.null(), json.null())
        network.DeadlineExceeded(_, _) -> #("DeadlineExceeded", json.null(), json.null())
      }
      let #(effect_name, reason) = case effect {
        network.NoEffect(_) -> #("NoEffect", json.null())
        network.EffectOccurred(_) -> #("EffectOccurred", json.null())
        network.Unknown(reason) -> #("Unknown", json.string(unknown_effect_reason_name(reason)))
      }
      json.object([#("tag", json.string("networkTerminal")), #("outcome", json.string(outcome_name)), #("stage", stage), #("cause", cause), #("effect", json.string(effect_name)), #("reason", reason)])
    }
    runtime.Network(failure) -> json.object([
      #("tag", json.string("network")),
      #("detail", network_failure_json.encode(failure)),
    ])
    runtime.Value(failure) -> json.object([
      #("tag", json.string("value")),
      #("detail", validation_failure_json(failure)),
    ])
    runtime.MissingArgument(composition.InputId(id)) -> json.object([#("tag", json.string("missingArgument")), #("input", json.string(id))])
    runtime.ArgumentCoverage(condition) -> json.object([#("tag", json.string("argumentCoverage")), #("condition", json.string(condition))])
    runtime.ProviderCoverage(condition) -> json.object([#("tag", json.string("providerCoverage")), #("condition", json.string(condition))])
    runtime.MissingProvider(function) -> json.object([#("tag", json.string("missingProvider")), #("function", function_ref_json(function))])
    runtime.ProviderEffect(function) -> json.object([#("tag", json.string("providerEffect")), #("function", function_ref_json(function))])
    runtime.InvalidOutcome(composition.SiteId(site), composition.OutcomeId(outcome)) -> json.object([#("tag", json.string("invalidOutcome")), #("site", json.string(site)), #("outcome", json.string(outcome))])
    runtime.Resource(lot, condition) -> json.object([#("tag", json.string("resource")), #("lot", lot_json(lot)), #("condition", json.string(condition))])
    runtime.MissingValue(reference) -> json.object([#("tag", json.string("missingValue")), #("detail", value_ref_json(reference))])
  }
  json.to_string(value)
}

fn profile_predicate_code(predicate: types.ProfilePredicate) -> String {
  case predicate {
    types.Pr01 -> "pr01"
    types.Pr02 -> "pr02"
    types.Pr03 -> "pr03"
    types.Pr04 -> "pr04"
    types.Pr05 -> "pr05"
    types.Pr06 -> "pr06"
    types.Pr07 -> "pr07"
    types.Pr08 -> "pr08"
    types.Pr09 -> "pr09"
    types.Pr10 -> "pr10"
    types.Pr11 -> "pr11"
    types.Pr12 -> "pr12"
    types.Pr13 -> "pr13"
    types.Pr14 -> "pr14"
    types.Pr15 -> "pr15"
    types.Pr16 -> "pr16"
  }
}

fn library_predicate_code(predicate: types.LibraryPredicate) -> String {
  case predicate {
    types.Lb01 -> "lb01"
    types.Lb02 -> "lb02"
    types.Lb03 -> "lb03"
    types.Lb04 -> "lb04"
    types.Lb05 -> "lb05"
    types.Lb06 -> "lb06"
    types.Lb07 -> "lb07"
    types.Lb08 -> "lb08"
    types.Lb09 -> "lb09"
    types.Lb10 -> "lb10"
    types.Lb11 -> "lb11"
    types.Lb12 -> "lb12"
    types.Lb13 -> "lb13"
    types.Lb14 -> "lb14"
    types.Lb15 -> "lb15"
    types.Lb16 -> "lb16"
    types.Lb17 -> "lb17"
    types.Lb18 -> "lb18"
    types.Lb19 -> "lb19"
  }
}
