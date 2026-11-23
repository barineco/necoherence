// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/dict
import gleam/dynamic/decode
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import necoherence/composition_plan
import necoherence/exact_json as exact
import necoherence/network_effect as network
import necoherence/request_progression as progression
import necoherence/semantic_generation_decode as generation_decode
import necoherence/semantic_generation_runtime as execution
import necoherence/semantic_signatures as signatures
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import network_failure_json

type SlotDescription {
  SlotDescription(tag: String, value: Option(exact.JsonValue))
}

type ValueDescription {
  ValueDescription(id: String, value: SlotDescription)
}

type HeaderDescription {
  HeaderDescription(name: String, value: List(Int))
}

type RequestDescription {
  RequestDescription(
    method: String,
    target: String,
    headers: List(HeaderDescription),
    body: List(Int),
    ordinal: Int,
    provenance: String,
  )
}

type PrepareDescription {
  PrepareDescription(
    tag: String,
    request: Option(RequestDescription),
    outcome: String,
    outputs: List(ValueDescription),
  )
}

type DecodeDescription {
  DecodeDescription(
    status: Int,
    outcome: String,
    outputs: List(ValueDescription),
    failure: Option(String),
  )
}

type ProviderDescription {
  ProviderDescription(
    reference: String,
    effect: String,
    outcome: String,
    outputs: List(ValueDescription),
    request: Option(RequestDescription),
    decode: List(DecodeDescription),
    signature: Int,
    prepare: List(PrepareDescription),
  )
}

type Observation {
  Observation(
    tag: String,
    kind: String,
    handle: String,
    status: Int,
    headers: List(HeaderDescription),
    body: List(Int),
    request: Int,
    delivery: Int,
  )
}

type Case {
  Case(
    identity: String,
    expected: String,
    exchange: String,
    arguments: List(ValueDescription),
    providers: List(ProviderDescription),
    observations: List(Observation),
  )
}

@external(erlang, "execution_check_ffi", "arguments")
fn arguments() -> List(String)

@external(erlang, "execution_check_ffi", "read_file")
fn read_file(path: String) -> Result(String, Nil)

fn slot_decoder() -> decode.Decoder(SlotDescription) {
  use tag <- decode.field("tag", decode.string)
  use value <- decode.optional_field(
    "value",
    None,
    decode.optional(exact_decoder()),
  )
  decode.success(SlotDescription(tag, value))
}

fn exact_decoder() -> decode.Decoder(exact.JsonValue) {
  decode.one_of(
    decode.optional(decode.bool)
      |> decode.map(fn(value) {
        case value {
          None -> exact.JsonValueNull
          Some(value) -> exact.JsonValueBool(value)
        }
      }),
    or: [
      decode.int |> decode.map(exact.JsonValueNum),
      decode.string |> decode.map(exact.JsonValueStr),
      decode.list(decode.recursive(exact_decoder))
        |> decode.map(exact.JsonValueArr),
      decode.dict(decode.string, decode.recursive(exact_decoder))
        |> decode.map(fn(value) { exact.JsonValueObj(dict.to_list(value)) }),
    ],
  )
}

fn value_decoder() -> decode.Decoder(ValueDescription) {
  use id <- decode.field("id", decode.string)
  use value <- decode.field("value", slot_decoder())
  decode.success(ValueDescription(id, value))
}

fn request_decoder() -> decode.Decoder(RequestDescription) {
  use method <- decode.field("method", decode.string)
  use target <- decode.field("target", decode.string)
  use headers <- decode.field("headers", decode.list(header_decoder()))
  use body <- decode.field("body", decode.list(decode.int))
  use ordinal <- decode.optional_field("ordinal", 0, decode.int)
  use provenance <- decode.optional_field(
    "provenance",
    "comparison",
    decode.string,
  )
  decode.success(RequestDescription(
    method,
    target,
    headers,
    body,
    ordinal,
    provenance,
  ))
}

fn prepare_decoder() -> decode.Decoder(PrepareDescription) {
  use tag <- decode.field("tag", decode.string)
  use request <- decode.optional_field(
    "request",
    None,
    decode.optional(request_decoder()),
  )
  use outcome <- decode.optional_field("outcome", "", decode.string)
  use outputs <- decode.optional_field(
    "outputs",
    [],
    decode.list(value_decoder()),
  )
  decode.success(PrepareDescription(tag, request, outcome, outputs))
}

fn header_decoder() -> decode.Decoder(HeaderDescription) {
  use name <- decode.field("name", decode.string)
  use value <- decode.field("value", decode.list(decode.int))
  decode.success(HeaderDescription(name, value))
}

fn failure_decoder() -> decode.Decoder(String) {
  use message <- decode.field("message", decode.string)
  decode.success(message)
}

fn decode_decoder() -> decode.Decoder(DecodeDescription) {
  use status <- decode.field("status", decode.int)
  use outcome <- decode.optional_field("outcome", "", decode.string)
  use outputs <- decode.optional_field(
    "outputs",
    [],
    decode.list(value_decoder()),
  )
  use failure <- decode.optional_field(
    "failure",
    None,
    decode.optional(failure_decoder()),
  )
  decode.success(DecodeDescription(status, outcome, outputs, failure))
}

fn provider_decoder() -> decode.Decoder(ProviderDescription) {
  use reference <- decode.field("reference", decode.string)
  use effect <- decode.field("effect", decode.string)
  use outcome <- decode.optional_field("outcome", "", decode.string)
  use outputs <- decode.optional_field(
    "outputs",
    [],
    decode.list(value_decoder()),
  )
  use request <- decode.optional_field(
    "request",
    None,
    decode.optional(request_decoder()),
  )
  use decode_rows <- decode.optional_field(
    "decode",
    [],
    decode.list(decode_decoder()),
  )
  use signature <- decode.optional_field("signature", 0, decode.int)
  use prepare <- decode.optional_field(
    "prepare",
    [],
    decode.list(prepare_decoder()),
  )
  decode.success(ProviderDescription(
    reference,
    effect,
    outcome,
    outputs,
    request,
    decode_rows,
    signature,
    prepare,
  ))
}

fn observation_decoder() -> decode.Decoder(Observation) {
  use tag <- decode.field("tag", decode.string)
  use kind <- decode.optional_field("kind", "", decode.string)
  use handle <- decode.optional_field("handle", "handle", decode.string)
  use status <- decode.optional_field("status", 0, decode.int)
  use headers <- decode.optional_field(
    "headers",
    [],
    decode.list(header_decoder()),
  )
  use body <- decode.optional_field("body", [], decode.list(decode.int))
  use request <- decode.optional_field("request", 0, decode.int)
  use delivery <- decode.optional_field("delivery", 0, decode.int)
  decode.success(Observation(
    tag,
    kind,
    handle,
    status,
    headers,
    body,
    request,
    delivery,
  ))
}

fn case_decoder() -> decode.Decoder(Case) {
  use identity <- decode.field("case", decode.string)
  use expected <- decode.field("expected", decode.string)
  use exchange <- decode.field("exchange", decode.string)
  use arguments <- decode.field("arguments", decode.list(value_decoder()))
  use providers <- decode.field("providers", decode.list(provider_decoder()))
  use observations <- decode.field(
    "observations",
    decode.list(observation_decoder()),
  )
  decode.success(Case(
    identity,
    expected,
    exchange,
    arguments,
    providers,
    observations,
  ))
}

fn document_decoder() -> decode.Decoder(List(Case)) {
  use cases <- decode.field("cases", decode.list(case_decoder()))
  decode.success(cases)
}

fn slot(value: SlotDescription) -> types.SlotValue(exact.JsonValue) {
  case value {
    SlotDescription("absent", _) -> types.Absent
    SlotDescription("null", _) -> types.Null
    SlotDescription(_, Some(value)) -> types.Present(value)
    SlotDescription(_, None) -> types.Present(exact.JsonValueNull)
  }
}

fn slot_json(value: types.SlotValue(exact.JsonValue)) -> json.Json {
  case value {
    types.Absent -> json.object([#("tag", json.string("absent"))])
    types.Null -> json.object([#("tag", json.string("null"))])
    types.Present(value) ->
      json.object([
        #("tag", json.string("present")),
        #("value", exact_json(value)),
      ])
  }
}

fn exact_json(value: exact.JsonValue) -> json.Json {
  case value {
    exact.JsonValueNull -> json.null()
    exact.JsonValueBool(value) -> json.bool(value)
    exact.JsonValueNum(value) -> json.int(value)
    exact.JsonValueDec(_) -> panic as "decimal output unsupported"
    exact.JsonValueStr(value) -> json.string(value)
    exact.JsonValueArr(items) ->
      json.preprocessed_array(list.map(items, exact_json))
    exact.JsonValueObj(members) ->
      json.object(
        list.map(members, fn(member) { #(member.0, exact_json(member.1)) }),
      )
  }
}

fn attempt_input(request: RequestDescription) -> network.AttemptInput {
  let RequestDescription(method, target, headers, body, ordinal, provenance) =
    request
  network.AttemptInput(
    network.AttemptIdentity(
      progression.RequestIdentity("semantic", provenance, 1),
      ordinal,
    ),
    network.HttpWireInstruction(
      method,
      target,
      list.map(headers, fn(value) {
        network.RawHeaderField(value.name, bytes_of(value.value))
      }),
      bytes_of(body),
    ),
    None,
    network.HostConfiguration(1024, 1024, None, None),
  )
}

fn provider(
  description: ProviderDescription,
  references: List(composition_plan.FunctionRef),
) -> execution.Provider {
  let assert Ok(reference) =
    references |> list.drop(description.signature) |> list.first
  let actual = case description.reference {
    "declared" -> reference
    _ ->
      composition_plan.FunctionRef(
        "other",
        "1",
        "0000000000000000000000000000000000000000000000000000000000000000",
      )
  }
  let result = fn(outcome: String, outputs: List(ValueDescription)) {
    execution.OutcomeValues(
      composition_plan.OutcomeId(outcome),
      list.map(outputs, fn(value) {
        #(composition_plan.PortId(value.id), slot(value.value))
      }),
    )
  }
  let returned = result(description.outcome, description.outputs)
  case description.effect, description.request {
    "pure", _ ->
      execution.Provider(actual, execution.Pure(fn(_) { Ok(returned) }))
    _, _ -> {
      let assert [prepared, ..] = description.prepare
      execution.Provider(
        actual,
        execution.PreparedHttp(
          execution.PreparedNetworkOwner(
            fn(_) {
              case prepared {
                PrepareDescription("completed", _, outcome, outputs) ->
                  Ok(execution.CompletedOutcome(result(outcome, outputs)))
                PrepareDescription(_, Some(request), _, _) ->
                  Ok(execution.Ready(attempt_input(request)))
                _ -> panic as "HTTP preparation required"
              }
            },
            fn(response) {
              let network.RawHttpResponse(status, _, _) = response
              case
                list.find(description.decode, fn(value) {
                  value.status == status
                })
              {
                Error(_) ->
                  Error(execution.ProviderFailure(
                    composition_plan.SiteId("operation"),
                    "missing decode behavior",
                  ))
                Ok(decoded) ->
                  case decoded.failure {
                    Some(message) ->
                      Error(execution.ProviderFailure(
                        composition_plan.SiteId("operation"),
                        message,
                      ))
                    None -> Ok(result(decoded.outcome, decoded.outputs))
                  }
              }
            },
          ),
        ),
      )
    }
  }
}

fn failure_json(failure: execution.ExecutionFailure) -> json.Json {
  case failure {
    execution.MissingArgument(composition_plan.InputId(id)) ->
      json.object([
        #("tag", json.string("MissingArgument")),
        #("input", json.string(id)),
      ])
    execution.ArgumentCoverage(condition) ->
      json.object([
        #("tag", json.string("ArgumentCoverage")),
        #("condition", json.string(condition)),
      ])
    execution.ProviderCoverage(condition) ->
      json.object([
        #("tag", json.string("ProviderCoverage")),
        #("condition", json.string(condition)),
      ])
    execution.InvalidPlan(condition) ->
      json.object([
        #("tag", json.string("InvalidPlan")),
        #("condition", json.string(condition)),
      ])
    execution.MissingProvider(function) ->
      function_failure("MissingProvider", function)
    execution.ProviderEffect(function) ->
      function_failure("ProviderEffect", function)
    execution.ProviderFailure(composition_plan.SiteId(site), message) ->
      json.object([
        #("tag", json.string("ProviderFailure")),
        #("site", json.string(site)),
        #("message", json.string(message)),
      ])
    execution.InvalidOutcome(
      composition_plan.SiteId(site),
      composition_plan.OutcomeId(outcome),
    ) ->
      json.object([
        #("tag", json.string("InvalidOutcome")),
        #("site", json.string(site)),
        #("outcome", json.string(outcome)),
      ])
    execution.Resource(lot, condition) ->
      json.object([
        #("tag", json.string("Resource")),
        #("lot", lot_json(lot)),
        #("condition", json.string(condition)),
      ])
    execution.NetworkTerminal(terminal) -> terminal_failure(terminal)
    execution.Network(value) ->
      json.object([
        #("tag", json.string("Network")),
        #("detail", network_failure_json.encode(value)),
      ])
    execution.Value(value) ->
      json.object([
        #("tag", json.string("Value")),
        #("detail", validation_failure_json(value)),
      ])
    execution.MissingValue(value) ->
      json.object([
        #("tag", json.string("MissingValue")),
        #("detail", value_ref_json(value)),
      ])
  }
}

fn nested(constructor: String, arguments: List(json.Json)) -> json.Json {
  json.object([
    #("constructor", json.string(constructor)),
    #("arguments", json.array(arguments, fn(value) { value })),
  ])
}

fn type_json(reference: types.TypeRef) -> json.Json {
  let types.TypeRef(source, definition, pointer) = reference
  let types.SourceRef(
    repository,
    revision,
    path,
    content_digest,
    document_id,
    declared_revision,
  ) = source
  json.object([
    #(
      "source",
      json.object([
        #("repository", json.string(repository)),
        #("revision", json.string(revision)),
        #("path", json.string(path)),
        #("contentDigest", json.string(content_digest)),
        #("documentId", json.string(document_id)),
        #(
          "declaredRevision",
          option.map(declared_revision, json.int) |> option.unwrap(json.null()),
        ),
      ]),
    ),
    #("definition", json.string(definition)),
    #("pointer", json.array(pointer, json.string)),
  ])
}

fn path_json(path: types.ValuePath) -> json.Json {
  json.array(path, fn(step) {
    case step {
      types.Field(name) -> json.object([#("field", json.string(name))])
      types.Index(index) -> json.object([#("index", json.int(index))])
      types.Variant(tag) -> json.object([#("variant", json.string(tag))])
    }
  })
}

fn producer_json(producer: composition_plan.ProducerRef) -> json.Json {
  case producer {
    composition_plan.Initial(composition_plan.InputId(id)) ->
      nested("initial", [json.string(id)])
    composition_plan.InvocationOutcome(
      composition_plan.SiteId(site),
      composition_plan.OutcomeId(outcome),
      composition_plan.PortId(port),
    ) ->
      nested("invocationOutcome", [
        json.string(site),
        json.string(outcome),
        json.string(port),
      ])
  }
}

fn value_ref_json(reference: composition_plan.ValueRef) -> json.Json {
  let composition_plan.ValueRef(producer, path) = reference
  json.object([
    #("producer", producer_json(producer)),
    #("path", path_json(path)),
  ])
}

fn lot_json(lot: composition_plan.ResourceLotRef) -> json.Json {
  case lot {
    composition_plan.InitialLot(composition_plan.LotId(id)) ->
      nested("initial", [json.string(id)])
    composition_plan.ProducedLot(
      composition_plan.SiteId(site),
      composition_plan.OutcomeId(outcome),
      composition_plan.ProductionId(production),
    ) ->
      nested("produced", [
        json.string(site),
        json.string(outcome),
        json.string(production),
      ])
  }
}

fn source_json(source: types.SourceRef) -> json.Json {
  let types.SourceRef(
    repository,
    revision,
    path,
    content_digest,
    document_id,
    declared_revision,
  ) = source
  json.object([
    #("repository", json.string(repository)),
    #("revision", json.string(revision)),
    #("path", json.string(path)),
    #("contentDigest", json.string(content_digest)),
    #("documentId", json.string(document_id)),
    #(
      "declaredRevision",
      option.map(declared_revision, json.int) |> option.unwrap(json.null()),
    ),
  ])
}

fn value_failure_json(failure: types.ValueFailure) -> json.Json {
  let assert Ok(condition) =
    generation_decode.encode_value_condition(failure.condition)
  let assert Ok(observed) =
    generation_decode.encode_slot_value(failure.observed)
  json.object([
    #("typeRef", type_json(failure.type_ref)),
    #(
      "definitionRef",
      json.object([
        #("source", source_json(failure.definition_ref.source)),
        #("name", json.string(failure.definition_ref.name)),
      ]),
    ),
    #(
      "origin",
      json.object([
        #("source", source_json(failure.origin.source)),
        #("pointer", json.array(failure.origin.pointer, json.string)),
      ]),
    ),
    #("valuePath", path_json(failure.value_path)),
    #("condition", exact_json(condition)),
    #("observed", exact_json(observed)),
    #("referenceTrace", json.array(failure.reference_trace, type_json)),
  ])
}

fn semantic_reason_json(reason: types.SemanticReason) -> json.Json {
  case reason {
    types.UnknownFormatReason(name) ->
      nested("unknownFormat", [json.string(name)])
    types.MissingGraphemeRulesReason -> nested("missingGraphemeRules", [])
    types.MissingBytesPolicyReason -> nested("missingBytesPolicy", [])
    types.UnknownIntegerDomainReason(name) ->
      nested("unknownIntegerDomain", [json.string(name)])
    types.UnknownWrapperReason(name) ->
      nested("unknownWrapper", [json.string(name)])
    types.WrapperPayloadReason(name) ->
      nested("wrapperPayload", [json.string(name)])
    types.UnknownSealedTagReason(tag) ->
      nested("unknownSealedTag", [json.string(tag)])
    types.DecimalNotAdmittedReason -> nested("decimalNotAdmitted", [])
    types.IntegerBoundReason -> nested("integerBound", [])
    types.OpaqueTypeReason(name) -> nested("opaqueType", [json.string(name)])
    types.MissingTagModelReason -> nested("missingTagModel", [])
    types.UnresolvedTypeReason -> nested("unresolvedType", [])
    types.MembershipBoundReason -> nested("membershipBound", [])
    types.UninterpretedExtensionReason(key) ->
      nested("uninterpretedExtension", [json.string(key)])
    types.InvalidProfileReason(condition) ->
      nested("invalidProfile", [json.string(condition)])
    types.CertificateMismatchReason(condition) ->
      nested("certificateMismatch", [json.string(condition)])
    types.ProjectionUnavailableReason(condition) ->
      nested("projectionUnavailable", [json.string(condition)])
  }
}

fn semantic_obligation_json(obligation: types.SemanticObligation) -> json.Json {
  json.object([
    #("typeRef", type_json(obligation.type_ref)),
    #("valuePath", path_json(obligation.value_path)),
    #("reason", semantic_reason_json(obligation.reason)),
  ])
}

fn validation_failure_json(failure: validation.ValidationFailure) -> json.Json {
  case failure {
    validation.Rejected(value) -> nested("value", [value_failure_json(value)])
    validation.Unresolved(obligations) ->
      nested("unresolved", [
        json.preprocessed_array(list.map(obligations, semantic_obligation_json)),
      ])
    validation.CertificateMismatchFailure(condition) ->
      nested("certificateMismatch", [json.string(condition)])
  }
}

fn function_failure(
  tag: String,
  function: composition_plan.FunctionRef,
) -> json.Json {
  let composition_plan.FunctionRef(identity, revision, digest) = function
  json.object([
    #("tag", json.string(tag)),
    #(
      "function",
      json.object([
        #("identity", json.string(identity)),
        #("revision", json.string(revision)),
        #("contentDigest", json.string(digest)),
      ]),
    ),
  ])
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

fn terminal_failure(terminal: network.NetworkTerminal) -> json.Json {
  let network.NetworkTerminal(outcome, effect) = terminal
  let #(outcome_name, stage, cause) = case outcome {
    network.Failed(failure) -> {
      let network.NetworkHostFailure(_, stage, _, cause) = failure
      #(
        "Failed",
        json.string(stage_name(stage)),
        json.string(host_failure_name(cause)),
      )
    }
    network.Response(_, _) -> #("Response", json.null(), json.null())
    network.Cancelled -> #("Cancelled", json.null(), json.null())
    network.DeadlineExceeded(_, _) -> #(
      "DeadlineExceeded",
      json.null(),
      json.null(),
    )
  }
  let #(effect_name, reason) = case effect {
    network.NoEffect(_) -> #("NoEffect", json.null())
    network.EffectOccurred(_) -> #("EffectOccurred", json.null())
    network.Unknown(reason) -> #(
      "Unknown",
      json.string(unknown_effect_reason_name(reason)),
    )
  }
  json.object([
    #("tag", json.string("NetworkTerminal")),
    #("outcome", json.string(outcome_name)),
    #("stage", stage),
    #("cause", cause),
    #("effect", json.string(effect_name)),
    #("reason", reason),
  ])
}

fn progress_json(instruction: execution.NetworkInstruction) -> json.Json {
  json.object([
    #("tag", json.string("pending")),
    #(
      "instruction",
      json.string(case instruction {
        execution.Send(_) -> "send"
        execution.Observe(_) -> "observe"
      }),
    ),
  ])
}

fn result_json(value: execution.ExecutionResult) -> json.Json {
  case value {
    execution.Success(outputs) ->
      json.object([
        #("tag", json.string("success")),
        #(
          "outcome",
          json.preprocessed_array(
            list.map(outputs, fn(output) {
              let composition_plan.GoalPortId(name) = output.0
              json.preprocessed_array([json.string(name), slot_json(output.1)])
            }),
          ),
        ),
      ])
    execution.Failure(embedding, value) -> {
      let composition_plan.FailureEmbeddingId(name) = embedding
      json.object([
        #("tag", json.string("failure")),
        #("embedding", json.string(name)),
        #("value", slot_json(value)),
      ])
    }
  }
}

fn request_for(
  case_value: Case,
  index: Int,
) -> Result(network.AttemptInput, Nil) {
  let ready =
    case_value.providers
    |> list.flat_map(fn(provider) { provider.prepare })
    |> list.filter(fn(prepared) { prepared.tag == "ready" })
  case ready |> list.drop(index) |> list.first {
    Ok(PrepareDescription(_, Some(request), _, _)) -> Ok(attempt_input(request))
    _ -> Error(Nil)
  }
}

fn drive(
  identity: String,
  case_value: Case,
  observations: List(Observation),
  progress: List(json.Json),
  current: Result(execution.Progress, execution.RunFailure),
) -> json.Json {
  case current {
    Error(execution.RunFailure(cause, _)) ->
      json.object([
        #("case", json.string(identity)),
        #("progress", json.preprocessed_array(progress)),
        #("failure", failure_json(cause)),
      ])
    Ok(execution.Completed(result, _)) ->
      json.object([
        #("case", json.string(identity)),
        #(
          "progress",
          json.preprocessed_array(
            list.append(progress, [
              json.object([#("tag", json.string("completed"))]),
            ]),
          ),
        ),
        #("result", result_json(result)),
      ])
    Ok(execution.Pending(suspended, instruction)) -> {
      let assert [observation, ..rest] = observations
      let request_index = observation.request
      let assert Ok(request) = request_for(case_value, request_index)
      let network.AttemptInput(attempt, _, _, configuration) = request
      let handle = network.ExecutionHandle(observation.handle)
      let supplied = case observation.tag, observation.kind {
        "start", "started" ->
          execution.Start(network.StartedObservation(attempt, handle))
        "start", _ ->
          execution.Start(network.StartFailed(
            network.NetworkHostFailure(
              attempt,
              network.Start,
              configuration,
              network.ExecutionStartFailed,
            ),
            network.Unknown(network.NoResponse),
          ))
        _, _ ->
          execution.Host(network.Delivered(
            observation.delivery,
            network.ResponseObservation(
              attempt,
              handle,
              network.NoSource,
              network.RawHttpResponse(
                observation.status,
                list.map(observation.headers, fn(value) {
                  network.RawHeaderField(value.name, bytes_of(value.value))
                }),
                bytes_of(observation.body),
              ),
              network.LibraryNormalized,
              network.Unknown(network.NoResponse),
            ),
          ))
      }
      drive(
        identity,
        case_value,
        rest,
        list.append(progress, [progress_json(instruction)]),
        execution.resume(suspended, supplied),
      )
    }
  }
}

fn driver_failure(identity: String, failure: String) -> json.Json {
  json.object([
    #("case", json.string(identity)),
    #("progress", json.preprocessed_array([])),
    #("driverFailure", json.string(failure)),
  ])
}

fn run(case_value: Case) -> json.Json {
  case signatures.admit_generation(case_value.expected, case_value.exchange) {
    Error(failure) ->
      driver_failure(case_value.identity, string.inspect(failure))
    Ok(generation) ->
      case signatures.checked_composition(generation) {
        None ->
          driver_failure(
            case_value.identity,
            "generated exchange has no composition",
          )
        Some(checked) -> run_checked(case_value, checked)
      }
  }
}

fn run_checked(case_value: Case, checked) -> json.Json {
  let references = case
    composition_plan.prepared_input(composition_plan.checked_prepared(checked)).signatures
  {
    signatures ->
      case list.map(signatures, fn(signature) { signature.reference }) {
        [] -> [
          composition_plan.FunctionRef(
            "unused",
            "0",
            "0000000000000000000000000000000000000000000000000000000000000000",
          ),
        ]
        values -> values
      }
  }
  let implementations =
    list.map(case_value.providers, fn(value) { provider(value, references) })
  let arguments =
    list.map(case_value.arguments, fn(value) {
      #(composition_plan.InputId(value.id), slot(value.value))
    })
  drive(
    case_value.identity,
    case_value,
    case_value.observations,
    [],
    execution.start_composition(
      checked,
      implementations,
      arguments,
      network.empty_state(),
    ),
  )
}

pub fn main() {
  let assert [path] = arguments()
  let assert Ok(contents) = read_file(path)
  let assert Ok(cases) = json.parse(contents, document_decoder())
  cases
  |> list.map(run)
  |> json.preprocessed_array
  |> json.to_string
  |> io.println
}

fn bytes_of(values: List(Int)) -> BitArray {
  list.fold(values, <<>>, fn(bytes, value) { <<bytes:bits, value>> })
}
