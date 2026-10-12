// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import necoherence/network_effect as effect
import necoherence/request_progression as progression

pub type Invocation {
  ReadNetworkState(effect.NetworkState)
  Prepare(effect.NetworkState, effect.AttemptInput)
  SendCommand(effect.NetworkState, effect.PreparedAttempt)
  CancelCommand(effect.NetworkState, effect.StartedAttempt)
  ObserveStart(
    effect.NetworkState,
    effect.PreparedAttempt,
    effect.StartObservation,
  )
  Observe(effect.NetworkState, effect.HostObservation)
  AnnotateEffect(effect.NetworkState, effect.EffectObservation)
  Retry(effect.NetworkState, effect.RetryRequest)
}

fn natural() -> decode.Decoder(Int) {
  use value <- decode.then(decode.int)
  case value >= 0 {
    True -> decode.success(value)
    False -> decode.failure(0, expected: "Nat")
  }
}

fn tagged(
  expected: String,
  placeholder: a,
  variants: fn(String) -> Option(a),
) -> decode.Decoder(a) {
  use tag <- decode.field("tag", decode.string)
  case variants(tag) {
    Some(value) -> decode.success(value)
    None -> decode.failure(placeholder, expected: expected)
  }
}

fn request_identity_decoder() -> decode.Decoder(effect.RequestIdentity) {
  use kind <- decode.field("kind", decode.string)
  use provenance <- decode.field("provenance", decode.string)
  use revision <- decode.field("revision", natural())
  decode.success(progression.RequestIdentity(kind, provenance, revision))
}

fn attempt_identity_decoder() -> decode.Decoder(effect.AttemptIdentity) {
  use logical <- decode.field("logical", request_identity_decoder())
  use ordinal <- decode.field("ordinal", natural())
  decode.success(effect.AttemptIdentity(logical, ordinal))
}

fn evidence_decoder() -> decode.Decoder(effect.OpaqueEvidence) {
  use value <- decode.field("value", decode.string)
  decode.success(effect.OpaqueEvidence(value))
}

fn handle_decoder() -> decode.Decoder(effect.ExecutionHandle) {
  use value <- decode.field("value", decode.string)
  decode.success(effect.ExecutionHandle(value))
}

fn clock_basis_decoder() -> decode.Decoder(effect.ClockBasis) {
  use value <- decode.field("value", decode.string)
  decode.success(effect.ClockBasis(value))
}

fn clock_observation_decoder() -> decode.Decoder(
  effect.MonotonicClockObservation,
) {
  use basis <- decode.field("clockBasis", clock_basis_decoder())
  use value <- decode.field("value", natural())
  decode.success(effect.MonotonicClockObservation(basis, value))
}

fn clock_capability_decoder() -> decode.Decoder(effect.MonotonicClockCapability) {
  use identity <- decode.field("identity", evidence_decoder())
  use basis <- decode.field("clockBasis", clock_basis_decoder())
  decode.success(effect.MonotonicClockCapability(identity, basis))
}

fn cancellation_capability_decoder() -> decode.Decoder(
  effect.CancellationCapability,
) {
  use identity <- decode.field("identity", evidence_decoder())
  decode.success(effect.CancellationCapability(identity))
}

fn deadline_decoder() -> decode.Decoder(effect.Deadline) {
  use basis <- decode.field("clockBasis", clock_basis_decoder())
  use limit <- decode.field("limit", natural())
  use capability <- decode.field("capability", clock_capability_decoder())
  decode.success(effect.Deadline(basis, limit, capability))
}

fn configuration_decoder() -> decode.Decoder(effect.HostConfiguration) {
  use request_limit <- decode.field("requestBodyLimit", natural())
  use response_limit <- decode.field("responseBodyLimit", natural())
  use cancellation <- decode.field(
    "cancellation",
    decode.optional(cancellation_capability_decoder()),
  )
  use clock <- decode.field(
    "monotonicClock",
    decode.optional(clock_capability_decoder()),
  )
  decode.success(effect.HostConfiguration(
    request_limit,
    response_limit,
    cancellation,
    clock,
  ))
}

fn raw_header_decoder() -> decode.Decoder(effect.RawHeaderField) {
  use name <- decode.field("name", decode.string)
  use value <- decode.field("value", decode.list(natural()))
  decode.success(effect.RawHeaderField(name, value))
}

fn instruction_decoder() -> decode.Decoder(effect.HttpWireInstruction) {
  use method <- decode.field("method", decode.string)
  use target <- decode.field("target", decode.string)
  use headers <- decode.field("headers", decode.list(raw_header_decoder()))
  use body <- decode.field("body", decode.list(natural()))
  decode.success(effect.HttpWireInstruction(method, target, headers, body))
}

fn response_decoder() -> decode.Decoder(effect.RawHttpResponse) {
  use status <- decode.field("status", natural())
  use headers <- decode.field("headers", decode.list(raw_header_decoder()))
  use body <- decode.field("body", decode.list(natural()))
  decode.success(effect.RawHttpResponse(status, headers, body))
}

fn input_decoder() -> decode.Decoder(effect.AttemptInput) {
  use attempt <- decode.field("attempt", attempt_identity_decoder())
  use instruction <- decode.field("instruction", instruction_decoder())
  use deadline <- decode.field("deadline", decode.optional(deadline_decoder()))
  use configuration <- decode.field("configuration", configuration_decoder())
  decode.success(effect.AttemptInput(
    attempt,
    instruction,
    deadline,
    configuration,
  ))
}

fn authorization_decoder() -> decode.Decoder(effect.RetryAuthorization) {
  use logical <- decode.field("logical", request_identity_decoder())
  use parent <- decode.field("from", attempt_identity_decoder())
  use next <- decode.field("next", attempt_identity_decoder())
  use protocol_evidence <- decode.field("protocolEvidence", evidence_decoder())
  decode.success(effect.RetryAuthorization(
    logical,
    parent,
    next,
    protocol_evidence,
  ))
}

fn lineage_decoder() -> decode.Decoder(effect.AttemptLineage) {
  use tag <- decode.field("tag", decode.string)
  case tag {
    "Root" -> decode.success(effect.Root)
    "RetryOf" -> {
      use authorization <- decode.field(
        "authorization",
        authorization_decoder(),
      )
      decode.success(effect.RetryOf(authorization))
    }
    _ -> decode.failure(effect.Root, expected: "AttemptLineage")
  }
}

fn prepared_decoder() -> decode.Decoder(effect.PreparedAttempt) {
  use input <- decode.field("input", input_decoder())
  use lineage <- decode.field("lineage", lineage_decoder())
  decode.success(effect.PreparedAttempt(input, lineage))
}

fn started_decoder() -> decode.Decoder(effect.StartedAttempt) {
  use prepared <- decode.field("prepared", prepared_decoder())
  use handle <- decode.field("handle", handle_decoder())
  decode.success(effect.StartedAttempt(prepared, handle))
}

fn provenance_decoder() -> decode.Decoder(effect.HeaderProvenance) {
  tagged("HeaderProvenance", effect.WireObserved, fn(tag) {
    case tag {
      "WireObserved" -> Some(effect.WireObserved)
      "LibraryObserved" -> Some(effect.LibraryObserved)
      "LibraryNormalized" -> Some(effect.LibraryNormalized)
      _ -> None
    }
  })
}

fn witness_source_decoder() -> decode.Decoder(effect.EffectWitnessSource) {
  tagged("EffectWitnessSource", effect.Adapter, fn(tag) {
    case tag {
      "Adapter" -> Some(effect.Adapter)
      "Protocol" -> Some(effect.Protocol)
      _ -> None
    }
  })
}

fn witness_decoder() -> decode.Decoder(effect.EffectWitness) {
  use attempt <- decode.field("attempt", attempt_identity_decoder())
  use source <- decode.field("source", witness_source_decoder())
  use evidence <- decode.field("evidence", evidence_decoder())
  decode.success(effect.EffectWitness(attempt, source, evidence))
}

fn unknown_reason_decoder() -> decode.Decoder(effect.UnknownEffectReason) {
  tagged("UnknownEffectReason", effect.NoResponse, fn(tag) {
    case tag {
      "NoResponse" -> Some(effect.NoResponse)
      "Cancellation" -> Some(effect.CancellationReason)
      "Deadline" -> Some(effect.DeadlineReason)
      "HostFailure" -> Some(effect.HostFailure)
      "ProtocolWitnessMissing" -> Some(effect.ProtocolWitnessMissing)
      "LateSignal" -> Some(effect.LateSignal)
      _ -> None
    }
  })
}

fn effect_status_decoder() -> decode.Decoder(effect.EffectStatus) {
  use tag <- decode.field("tag", decode.string)
  case tag {
    "Unknown" -> {
      use reason <- decode.field("reason", unknown_reason_decoder())
      decode.success(effect.Unknown(reason))
    }
    "NoEffect" -> {
      use witness <- decode.field("witness", witness_decoder())
      decode.success(effect.NoEffect(witness))
    }
    "EffectOccurred" -> {
      use witness <- decode.field("witness", witness_decoder())
      decode.success(effect.EffectOccurred(witness))
    }
    _ ->
      decode.failure(
        effect.Unknown(effect.NoResponse),
        expected: "EffectStatus",
      )
  }
}

fn effect_observation_decoder() -> decode.Decoder(effect.EffectObservation) {
  use attempt <- decode.field("attempt", attempt_identity_decoder())
  use status <- decode.field("status", effect_status_decoder())
  decode.success(effect.EffectObservation(attempt, status))
}

fn host_stage_decoder() -> decode.Decoder(effect.HostStage) {
  tagged("HostStage", effect.Start, fn(tag) {
    case tag {
      "Start" -> Some(effect.Start)
      "RequestWrite" -> Some(effect.RequestWrite)
      "ResponseHeaders" -> Some(effect.ResponseHeaders)
      "ResponseBody" -> Some(effect.ResponseBody)
      "Cancel" -> Some(effect.Cancel)
      "Deadline" -> Some(effect.DeadlineStage)
      _ -> None
    }
  })
}

fn timeout_cause_decoder() -> decode.Decoder(effect.HostTimeoutCause) {
  tagged("HostTimeoutCause", effect.LibraryReported, fn(tag) {
    case tag {
      "LibraryReported" -> Some(effect.LibraryReported)
      "SocketReported" -> Some(effect.SocketReported)
      "PoolAcquisition" -> Some(effect.PoolAcquisition)
      "HostOperation" -> Some(effect.HostOperation)
      _ -> None
    }
  })
}

fn host_failure_decoder() -> decode.Decoder(effect.HostFailure) {
  use tag <- decode.field("tag", decode.string)
  case tag {
    "UnsupportedUriScheme" -> decode.success(effect.UnsupportedUriScheme)
    "InvalidHostConfiguration" ->
      decode.success(effect.InvalidHostConfiguration)
    "ExecutionStartFailed" -> decode.success(effect.ExecutionStartFailed)
    "NameResolutionFailed" -> decode.success(effect.NameResolutionFailed)
    "ConnectionFailed" -> decode.success(effect.ConnectionFailed)
    "RequestWriteFailed" -> decode.success(effect.RequestWriteFailed)
    "ResponseHeadersFailed" -> decode.success(effect.ResponseHeadersFailed)
    "ResponseBodyFailed" -> decode.success(effect.ResponseBodyFailed)
    "ResponseBodyLimitExceeded" ->
      decode.success(effect.ResponseBodyLimitExceeded)
    "MalformedResponse" -> decode.success(effect.MalformedResponse)
    "HeaderRepresentationUnavailable" ->
      decode.success(effect.HeaderRepresentationUnavailable)
    "RequestHeaderEncodingUnavailable" ->
      decode.success(effect.RequestHeaderEncodingUnavailable)
    "CancellationRejected" -> decode.success(effect.CancellationRejected)
    "DeadlineControlUnavailable" ->
      decode.success(effect.DeadlineControlUnavailable)
    "Timeout" -> {
      use stage <- decode.field("stage", host_stage_decoder())
      use cause <- decode.field("cause", timeout_cause_decoder())
      decode.success(effect.Timeout(stage, cause))
    }
    "HostRuntimeFailure" -> decode.success(effect.HostRuntimeFailure)
    "HostClosed" -> decode.success(effect.HostClosed)
    _ -> decode.failure(effect.HostRuntimeFailure, expected: "HostFailure")
  }
}

fn network_host_failure_decoder() -> decode.Decoder(effect.NetworkHostFailure) {
  use attempt <- decode.field("attempt", attempt_identity_decoder())
  use stage <- decode.field("stage", host_stage_decoder())
  use configuration <- decode.field("configuration", configuration_decoder())
  use cause <- decode.field("cause", host_failure_decoder())
  decode.success(effect.NetworkHostFailure(attempt, stage, configuration, cause))
}

fn outcome_decoder() -> decode.Decoder(effect.NetworkOutcome) {
  use tag <- decode.field("tag", decode.string)
  case tag {
    "Response" -> {
      use response <- decode.field("response", response_decoder())
      use provenance <- decode.field("provenance", provenance_decoder())
      decode.success(effect.Response(response, provenance))
    }
    "Failed" -> {
      use failure <- decode.field("failure", network_host_failure_decoder())
      decode.success(effect.Failed(failure))
    }
    "Cancelled" -> decode.success(effect.Cancelled)
    "DeadlineExceeded" -> {
      use deadline <- decode.field("deadline", deadline_decoder())
      use observed <- decode.field("observedAt", clock_observation_decoder())
      decode.success(effect.DeadlineExceeded(deadline, observed))
    }
    _ -> decode.failure(effect.Cancelled, expected: "NetworkOutcome")
  }
}

fn terminal_decoder() -> decode.Decoder(effect.NetworkTerminal) {
  use outcome <- decode.field("outcome", outcome_decoder())
  use status <- decode.field("effect", effect_status_decoder())
  decode.success(effect.NetworkTerminal(outcome, status))
}

fn source_sequence_decoder() -> decode.Decoder(effect.SourceSequence) {
  decode.map(decode.optional(natural()), fn(value) {
    case value {
      None -> effect.NoSource
      Some(ordinal) -> effect.Source(ordinal)
    }
  })
}

fn adapter_observation_decoder() -> decode.Decoder(effect.AdapterObservation) {
  use tag <- decode.field("tag", decode.string)
  use attempt <- decode.field("attempt", attempt_identity_decoder())
  use handle <- decode.field("handle", handle_decoder())
  use source <- decode.field("sourceSequence", source_sequence_decoder())
  case tag {
    "ResponseObservation" -> {
      use response <- decode.field("response", response_decoder())
      use provenance <- decode.field("provenance", provenance_decoder())
      use status <- decode.field("effect", effect_status_decoder())
      decode.success(effect.ResponseObservation(
        attempt,
        handle,
        source,
        response,
        provenance,
        status,
      ))
    }
    "FailureObservation" -> {
      use failure <- decode.field("failure", network_host_failure_decoder())
      use status <- decode.field("effect", effect_status_decoder())
      decode.success(effect.FailureObservation(
        attempt,
        handle,
        source,
        failure,
        status,
      ))
    }
    "CancellationObservation" -> {
      use status <- decode.field("effect", effect_status_decoder())
      decode.success(effect.CancellationObservation(
        attempt,
        handle,
        source,
        status,
      ))
    }
    "DeadlineObservation" -> {
      use deadline <- decode.field("deadline", deadline_decoder())
      use observed <- decode.field("observedAt", clock_observation_decoder())
      use status <- decode.field("effect", effect_status_decoder())
      decode.success(effect.DeadlineObservation(
        attempt,
        handle,
        source,
        deadline,
        observed,
        status,
      ))
    }
    _ ->
      decode.failure(
        effect.CancellationObservation(
          attempt,
          handle,
          source,
          effect.Unknown(effect.NoResponse),
        ),
        expected: "AdapterObservation",
      )
  }
}

fn delivered_decoder() -> decode.Decoder(effect.DeliveredObservation) {
  use delivery <- decode.field("delivery", natural())
  use observation <- decode.field("observation", adapter_observation_decoder())
  decode.success(effect.DeliveredObservation(delivery, observation))
}

fn late_decoder() -> decode.Decoder(effect.LateObservation) {
  use delivered <- decode.field("delivered", delivered_decoder())
  decode.success(effect.LateObservation(delivered))
}

fn disposition_decoder() -> decode.Decoder(effect.AttemptDisposition) {
  use tag <- decode.field("tag", decode.string)
  case tag {
    "Prepared" -> decode.success(effect.Prepared)
    "CommandIssued" -> decode.success(effect.CommandIssued)
    "Started" -> {
      use handle <- decode.field("handle", handle_decoder())
      decode.success(effect.Started(handle))
    }
    "Settled" -> {
      use handle <- decode.field("handle", decode.optional(handle_decoder()))
      use terminal <- decode.field("terminal", terminal_decoder())
      decode.success(effect.Settled(handle, terminal))
    }
    _ -> decode.failure(effect.Prepared, expected: "AttemptDisposition")
  }
}

fn record_decoder() -> decode.Decoder(effect.AttemptRecord) {
  use input <- decode.field("input", input_decoder())
  use lineage <- decode.field("lineage", lineage_decoder())
  use disposition <- decode.field("disposition", disposition_decoder())
  use first_delivery <- decode.field(
    "firstDelivery",
    decode.optional(delivered_decoder()),
  )
  use late <- decode.field("late", decode.list(late_decoder()))
  decode.success(effect.AttemptRecord(
    input,
    lineage,
    disposition,
    first_delivery,
    late,
  ))
}

fn state_decoder() -> decode.Decoder(effect.NetworkState) {
  use attempts <- decode.field("attempts", decode.list(record_decoder()))
  decode.success(effect.NetworkState(attempts))
}

fn retry_permission_decoder() -> decode.Decoder(effect.RetryPermission) {
  use tag <- decode.field("tag", decode.string)
  case tag {
    "RetryAllowed" -> {
      use authorization <- decode.field(
        "authorization",
        authorization_decoder(),
      )
      decode.success(effect.RetryAllowed(authorization))
    }
    "RetryDenied" -> {
      use logical <- decode.field("logical", request_identity_decoder())
      use parent <- decode.field("parent", attempt_identity_decoder())
      use evidence <- decode.field("evidence", evidence_decoder())
      decode.success(effect.RetryDenied(logical, parent, evidence))
    }
    _ ->
      decode.failure(
        effect.RetryDenied(
          progression.RequestIdentity("", "", 0),
          effect.AttemptIdentity(progression.RequestIdentity("", "", 0), 0),
          effect.OpaqueEvidence(""),
        ),
        expected: "RetryPermission",
      )
  }
}

fn retry_request_decoder() -> decode.Decoder(effect.RetryRequest) {
  use permission <- decode.field("permission", retry_permission_decoder())
  use instruction <- decode.field("instruction", instruction_decoder())
  use deadline <- decode.field("deadline", decode.optional(deadline_decoder()))
  use configuration <- decode.field("configuration", configuration_decoder())
  decode.success(effect.RetryRequest(
    permission,
    instruction,
    deadline,
    configuration,
  ))
}

fn start_observation_decoder() -> decode.Decoder(effect.StartObservation) {
  use tag <- decode.field("tag", decode.string)
  case tag {
    "Started" -> {
      use attempt <- decode.field("attempt", attempt_identity_decoder())
      use handle <- decode.field("handle", handle_decoder())
      decode.success(effect.StartedObservation(attempt, handle))
    }
    "StartFailed" -> {
      use failure <- decode.field("failure", network_host_failure_decoder())
      use status <- decode.field("effect", effect_status_decoder())
      decode.success(effect.StartFailed(failure, status))
    }
    _ ->
      decode.failure(
        effect.StartedObservation(
          effect.AttemptIdentity(progression.RequestIdentity("", "", 0), 0),
          effect.ExecutionHandle(""),
        ),
        expected: "StartObservation",
      )
  }
}

fn host_observation_decoder() -> decode.Decoder(effect.HostObservation) {
  use tag <- decode.field("tag", decode.string)
  case tag {
    "Pending" -> {
      use attempt <- decode.field("attempt", attempt_identity_decoder())
      use handle <- decode.field("handle", handle_decoder())
      decode.success(effect.Pending(attempt, handle))
    }
    "Delivered" -> {
      use delivery <- decode.field("delivery", natural())
      use observation <- decode.field(
        "observation",
        adapter_observation_decoder(),
      )
      decode.success(effect.Delivered(delivery, observation))
    }
    _ ->
      decode.failure(
        effect.Pending(
          effect.AttemptIdentity(progression.RequestIdentity("", "", 0), 0),
          effect.ExecutionHandle(""),
        ),
        expected: "HostObservation",
      )
  }
}

pub fn invocation_decoder() -> decode.Decoder(Invocation) {
  use operation <- decode.field("operation", decode.string)
  use state <- decode.field("state", state_decoder())
  case operation {
    "readNetworkState" -> decode.success(ReadNetworkState(state))
    "prepare" -> {
      use input <- decode.field("input", input_decoder())
      decode.success(Prepare(state, input))
    }
    "sendCommand" -> {
      use prepared <- decode.field("prepared", prepared_decoder())
      decode.success(SendCommand(state, prepared))
    }
    "cancelCommand" -> {
      use started <- decode.field("started", started_decoder())
      decode.success(CancelCommand(state, started))
    }
    "observeStart" -> {
      use prepared <- decode.field("prepared", prepared_decoder())
      use observation <- decode.field(
        "observation",
        start_observation_decoder(),
      )
      decode.success(ObserveStart(state, prepared, observation))
    }
    "observe" -> {
      use observation <- decode.field("observation", host_observation_decoder())
      decode.success(Observe(state, observation))
    }
    "annotateEffect" -> {
      use observation <- decode.field("effect", effect_observation_decoder())
      decode.success(AnnotateEffect(state, observation))
    }
    "retry" -> {
      use request <- decode.field("request", retry_request_decoder())
      decode.success(Retry(state, request))
    }
    _ -> decode.failure(ReadNetworkState(state), expected: "operation")
  }
}

fn object(fields: List(#(String, json.Json))) -> json.Json {
  json.object(fields)
}

fn tag(name: String) -> json.Json {
  object([#("tag", json.string(name))])
}

fn encode_request_identity(value: effect.RequestIdentity) -> json.Json {
  object([
    #("kind", json.string(value.kind)),
    #("provenance", json.string(value.provenance)),
    #("revision", json.int(value.revision)),
  ])
}

fn encode_attempt_identity(value: effect.AttemptIdentity) -> json.Json {
  object([
    #("logical", encode_request_identity(value.logical)),
    #("ordinal", json.int(value.ordinal)),
  ])
}

fn encode_evidence(value: effect.OpaqueEvidence) -> json.Json {
  object([#("value", json.string(value.value))])
}

fn encode_handle(value: effect.ExecutionHandle) -> json.Json {
  object([#("value", json.string(value.value))])
}

fn encode_clock_basis(value: effect.ClockBasis) -> json.Json {
  object([#("value", json.string(value.value))])
}

fn encode_clock_observation(
  value: effect.MonotonicClockObservation,
) -> json.Json {
  object([
    #("clockBasis", encode_clock_basis(value.clock_basis)),
    #("value", json.int(value.value)),
  ])
}

fn encode_clock_capability(
  value: effect.MonotonicClockCapability,
) -> json.Json {
  object([
    #("identity", encode_evidence(value.identity)),
    #("clockBasis", encode_clock_basis(value.clock_basis)),
  ])
}

fn encode_cancellation_capability(
  value: effect.CancellationCapability,
) -> json.Json {
  object([#("identity", encode_evidence(value.identity))])
}

fn encode_deadline(value: effect.Deadline) -> json.Json {
  object([
    #("clockBasis", encode_clock_basis(value.clock_basis)),
    #("limit", json.int(value.limit)),
    #("capability", encode_clock_capability(value.capability)),
  ])
}

fn encode_configuration(value: effect.HostConfiguration) -> json.Json {
  object([
    #("requestBodyLimit", json.int(value.request_body_limit)),
    #("responseBodyLimit", json.int(value.response_body_limit)),
    #(
      "cancellation",
      json.nullable(value.cancellation, encode_cancellation_capability),
    ),
    #(
      "monotonicClock",
      json.nullable(value.monotonic_clock, encode_clock_capability),
    ),
  ])
}

fn encode_raw_header(value: effect.RawHeaderField) -> json.Json {
  object([
    #("name", json.string(value.name)),
    #("value", json.array(value.value, json.int)),
  ])
}

fn encode_instruction(value: effect.HttpWireInstruction) -> json.Json {
  object([
    #("method", json.string(value.method)),
    #("target", json.string(value.target)),
    #("headers", json.array(value.headers, encode_raw_header)),
    #("body", json.array(value.body, json.int)),
  ])
}

fn encode_response(value: effect.RawHttpResponse) -> json.Json {
  object([
    #("status", json.int(value.status)),
    #("headers", json.array(value.headers, encode_raw_header)),
    #("body", json.array(value.body, json.int)),
  ])
}

fn encode_input(value: effect.AttemptInput) -> json.Json {
  object([
    #("attempt", encode_attempt_identity(value.attempt)),
    #("instruction", encode_instruction(value.instruction)),
    #("deadline", json.nullable(value.deadline, encode_deadline)),
    #("configuration", encode_configuration(value.configuration)),
  ])
}

fn encode_authorization(value: effect.RetryAuthorization) -> json.Json {
  object([
    #("logical", encode_request_identity(value.logical)),
    #("from", encode_attempt_identity(value.from)),
    #("next", encode_attempt_identity(value.next)),
    #("protocolEvidence", encode_evidence(value.protocol_evidence)),
  ])
}

fn encode_lineage(value: effect.AttemptLineage) -> json.Json {
  case value {
    effect.Root -> tag("Root")
    effect.RetryOf(authorization) ->
      object([
        #("tag", json.string("RetryOf")),
        #("authorization", encode_authorization(authorization)),
      ])
  }
}

fn encode_prepared(value: effect.PreparedAttempt) -> json.Json {
  object([
    #("input", encode_input(value.input)),
    #("lineage", encode_lineage(value.lineage)),
  ])
}

fn encode_started(value: effect.StartedAttempt) -> json.Json {
  object([
    #("prepared", encode_prepared(value.prepared)),
    #("handle", encode_handle(value.handle)),
  ])
}

fn encode_provenance(value: effect.HeaderProvenance) -> json.Json {
  case value {
    effect.WireObserved -> tag("WireObserved")
    effect.LibraryObserved -> tag("LibraryObserved")
    effect.LibraryNormalized -> tag("LibraryNormalized")
  }
}

fn encode_witness_source(value: effect.EffectWitnessSource) -> json.Json {
  case value {
    effect.Adapter -> tag("Adapter")
    effect.Protocol -> tag("Protocol")
  }
}

fn encode_witness(value: effect.EffectWitness) -> json.Json {
  object([
    #("attempt", encode_attempt_identity(value.attempt)),
    #("source", encode_witness_source(value.source)),
    #("evidence", encode_evidence(value.evidence)),
  ])
}

fn encode_unknown_reason(value: effect.UnknownEffectReason) -> json.Json {
  case value {
    effect.NoResponse -> tag("NoResponse")
    effect.CancellationReason -> tag("Cancellation")
    effect.DeadlineReason -> tag("Deadline")
    effect.HostFailure -> tag("HostFailure")
    effect.ProtocolWitnessMissing -> tag("ProtocolWitnessMissing")
    effect.LateSignal -> tag("LateSignal")
  }
}

fn encode_effect_status(value: effect.EffectStatus) -> json.Json {
  case value {
    effect.Unknown(reason) ->
      object([
        #("tag", json.string("Unknown")),
        #("reason", encode_unknown_reason(reason)),
      ])
    effect.NoEffect(witness) ->
      object([
        #("tag", json.string("NoEffect")),
        #("witness", encode_witness(witness)),
      ])
    effect.EffectOccurred(witness) ->
      object([
        #("tag", json.string("EffectOccurred")),
        #("witness", encode_witness(witness)),
      ])
  }
}

fn host_stage_name(value: effect.HostStage) -> String {
  case value {
    effect.Start -> "Start"
    effect.RequestWrite -> "RequestWrite"
    effect.ResponseHeaders -> "ResponseHeaders"
    effect.ResponseBody -> "ResponseBody"
    effect.Cancel -> "Cancel"
    effect.DeadlineStage -> "Deadline"
  }
}

fn timeout_cause_name(value: effect.HostTimeoutCause) -> String {
  case value {
    effect.LibraryReported -> "LibraryReported"
    effect.SocketReported -> "SocketReported"
    effect.PoolAcquisition -> "PoolAcquisition"
    effect.HostOperation -> "HostOperation"
  }
}

fn encode_host_failure(value: effect.HostFailure) -> json.Json {
  let name = case value {
    effect.UnsupportedUriScheme -> "UnsupportedUriScheme"
    effect.InvalidHostConfiguration -> "InvalidHostConfiguration"
    effect.ExecutionStartFailed -> "ExecutionStartFailed"
    effect.NameResolutionFailed -> "NameResolutionFailed"
    effect.ConnectionFailed -> "ConnectionFailed"
    effect.RequestWriteFailed -> "RequestWriteFailed"
    effect.ResponseHeadersFailed -> "ResponseHeadersFailed"
    effect.ResponseBodyFailed -> "ResponseBodyFailed"
    effect.ResponseBodyLimitExceeded -> "ResponseBodyLimitExceeded"
    effect.MalformedResponse -> "MalformedResponse"
    effect.HeaderRepresentationUnavailable -> "HeaderRepresentationUnavailable"
    effect.RequestHeaderEncodingUnavailable ->
      "RequestHeaderEncodingUnavailable"
    effect.CancellationRejected -> "CancellationRejected"
    effect.DeadlineControlUnavailable -> "DeadlineControlUnavailable"
    effect.HostRuntimeFailure -> "HostRuntimeFailure"
    effect.HostClosed -> "HostClosed"
    effect.Timeout(_, _) -> "Timeout"
  }
  case value {
    effect.Timeout(stage, cause) ->
      object([
        #("tag", json.string(name)),
        #("stage", tag(host_stage_name(stage))),
        #("cause", tag(timeout_cause_name(cause))),
      ])
    _ -> tag(name)
  }
}

fn encode_network_host_failure(value: effect.NetworkHostFailure) -> json.Json {
  object([
    #("attempt", encode_attempt_identity(value.attempt)),
    #("stage", tag(host_stage_name(value.stage))),
    #("configuration", encode_configuration(value.configuration)),
    #("cause", encode_host_failure(value.cause)),
  ])
}

fn encode_outcome(value: effect.NetworkOutcome) -> json.Json {
  case value {
    effect.Response(response, provenance) ->
      object([
        #("tag", json.string("Response")),
        #("response", encode_response(response)),
        #("provenance", encode_provenance(provenance)),
      ])
    effect.Failed(failure) ->
      object([
        #("tag", json.string("Failed")),
        #("failure", encode_network_host_failure(failure)),
      ])
    effect.Cancelled -> tag("Cancelled")
    effect.DeadlineExceeded(deadline, observed) ->
      object([
        #("tag", json.string("DeadlineExceeded")),
        #("deadline", encode_deadline(deadline)),
        #("observedAt", encode_clock_observation(observed)),
      ])
  }
}

fn encode_terminal(value: effect.NetworkTerminal) -> json.Json {
  object([
    #("outcome", encode_outcome(value.outcome)),
    #("effect", encode_effect_status(value.effect)),
  ])
}

fn encode_source_sequence(value: effect.SourceSequence) -> json.Json {
  case value {
    effect.NoSource -> json.null()
    effect.Source(ordinal) -> json.int(ordinal)
  }
}

fn encode_adapter_observation(value: effect.AdapterObservation) -> json.Json {
  case value {
    effect.ResponseObservation(
      attempt,
      handle,
      source,
      response,
      provenance,
      status,
    ) ->
      object([
        #("tag", json.string("ResponseObservation")),
        #("attempt", encode_attempt_identity(attempt)),
        #("handle", encode_handle(handle)),
        #("sourceSequence", encode_source_sequence(source)),
        #("response", encode_response(response)),
        #("provenance", encode_provenance(provenance)),
        #("effect", encode_effect_status(status)),
      ])
    effect.FailureObservation(attempt, handle, source, failure, status) ->
      object([
        #("tag", json.string("FailureObservation")),
        #("attempt", encode_attempt_identity(attempt)),
        #("handle", encode_handle(handle)),
        #("sourceSequence", encode_source_sequence(source)),
        #("failure", encode_network_host_failure(failure)),
        #("effect", encode_effect_status(status)),
      ])
    effect.CancellationObservation(attempt, handle, source, status) ->
      object([
        #("tag", json.string("CancellationObservation")),
        #("attempt", encode_attempt_identity(attempt)),
        #("handle", encode_handle(handle)),
        #("sourceSequence", encode_source_sequence(source)),
        #("effect", encode_effect_status(status)),
      ])
    effect.DeadlineObservation(
      attempt,
      handle,
      source,
      deadline,
      observed,
      status,
    ) ->
      object([
        #("tag", json.string("DeadlineObservation")),
        #("attempt", encode_attempt_identity(attempt)),
        #("handle", encode_handle(handle)),
        #("sourceSequence", encode_source_sequence(source)),
        #("deadline", encode_deadline(deadline)),
        #("observedAt", encode_clock_observation(observed)),
        #("effect", encode_effect_status(status)),
      ])
  }
}

fn encode_delivered(value: effect.DeliveredObservation) -> json.Json {
  object([
    #("delivery", json.int(value.delivery)),
    #("observation", encode_adapter_observation(value.observation)),
  ])
}

fn encode_late(value: effect.LateObservation) -> json.Json {
  object([#("delivered", encode_delivered(value.delivered))])
}

fn encode_disposition(value: effect.AttemptDisposition) -> json.Json {
  case value {
    effect.Prepared -> tag("Prepared")
    effect.CommandIssued -> tag("CommandIssued")
    effect.Started(handle) ->
      object([
        #("tag", json.string("Started")),
        #("handle", encode_handle(handle)),
      ])
    effect.Settled(handle, terminal) ->
      object([
        #("tag", json.string("Settled")),
        #("handle", json.nullable(handle, encode_handle)),
        #("terminal", encode_terminal(terminal)),
      ])
  }
}

fn encode_record(value: effect.AttemptRecord) -> json.Json {
  object([
    #("input", encode_input(value.input)),
    #("lineage", encode_lineage(value.lineage)),
    #("disposition", encode_disposition(value.disposition)),
    #("firstDelivery", json.nullable(value.first_delivery, encode_delivered)),
    #("late", json.array(value.late, encode_late)),
  ])
}

fn encode_state(value: effect.NetworkState) -> json.Json {
  object([#("attempts", json.array(value.attempts, encode_record))])
}

fn encode_state_violation(value: effect.NetworkStateViolation) -> json.Json {
  case value {
    effect.DuplicateAttemptKey(attempt) ->
      object([
        #("tag", json.string("DuplicateAttemptKey")),
        #("attempt", encode_attempt_identity(attempt)),
      ])
    effect.NonRootFirstAttempt(attempt) ->
      object([
        #("tag", json.string("NonRootFirstAttempt")),
        #("attempt", encode_attempt_identity(attempt)),
      ])
    effect.OrdinalGap(attempt) ->
      object([
        #("tag", json.string("OrdinalGap")),
        #("attempt", encode_attempt_identity(attempt)),
      ])
    effect.LineageMismatch(attempt) ->
      object([
        #("tag", json.string("LineageMismatch")),
        #("attempt", encode_attempt_identity(attempt)),
      ])
    effect.RetryAuthorizationReuse(authorization) ->
      object([
        #("tag", json.string("RetryAuthorizationReuse")),
        #("authorization", encode_authorization(authorization)),
      ])
    effect.DispositionEvidenceMismatch(attempt) ->
      object([
        #("tag", json.string("DispositionEvidenceMismatch")),
        #("attempt", encode_attempt_identity(attempt)),
      ])
    effect.DeliveryLogMismatch(attempt) ->
      object([
        #("tag", json.string("DeliveryLogMismatch")),
        #("attempt", encode_attempt_identity(attempt)),
      ])
  }
}

fn attempt_condition_name(value: effect.AttemptCondition) -> String {
  case value {
    effect.IsPrepared -> "IsPrepared"
    effect.IsCommandIssued -> "IsCommandIssued"
    effect.IsStarted -> "IsStarted"
    effect.IsSettled -> "IsSettled"
  }
}

fn token_field_name(value: effect.AttemptTokenField) -> String {
  case value {
    effect.Instruction -> "Instruction"
    effect.DeadlineField -> "Deadline"
    effect.Configuration -> "Configuration"
    effect.Lineage -> "Lineage"
    effect.Handle -> "Handle"
  }
}

fn observation_field_name(value: effect.ObservationField) -> String {
  case value {
    effect.FailureConfiguration -> "FailureConfiguration"
    effect.FailureStage -> "FailureStage"
    effect.DeadlineValue -> "DeadlineValue"
    effect.ClockBasisValue -> "ClockBasisValue"
    effect.ClockObservationValue -> "ClockObservationValue"
    effect.EffectWitnessValue -> "EffectWitnessValue"
  }
}

fn capability_name(value: effect.CapabilityKind) -> String {
  case value {
    effect.CancellationCapabilityKind -> "Cancellation"
    effect.MonotonicClock -> "MonotonicClock"
  }
}

fn encode_failure(value: effect.NetworkFailure) -> json.Json {
  case value {
    effect.InvalidWireInstruction(method) ->
      object([
        #("tag", json.string("InvalidWireInstruction")),
        #("method", json.string(method)),
      ])
    effect.InvalidDeadline -> tag("InvalidDeadline")
    effect.InvalidNetworkState(violation) ->
      object([
        #("tag", json.string("InvalidNetworkState")),
        #("violation", encode_state_violation(violation)),
      ])
    effect.RootAttemptRequired(attempt) ->
      object([
        #("tag", json.string("RootAttemptRequired")),
        #("attempt", encode_attempt_identity(attempt)),
      ])
    effect.DuplicateAttempt(attempt) ->
      object([
        #("tag", json.string("DuplicateAttempt")),
        #("attempt", encode_attempt_identity(attempt)),
      ])
    effect.UnknownAttempt(attempt) ->
      object([
        #("tag", json.string("UnknownAttempt")),
        #("attempt", encode_attempt_identity(attempt)),
      ])
    effect.AttemptConditionMismatch(attempt, expected, actual) ->
      object([
        #("tag", json.string("AttemptConditionMismatch")),
        #("attempt", encode_attempt_identity(attempt)),
        #("expected", json.string(attempt_condition_name(expected))),
        #("actual", json.string(attempt_condition_name(actual))),
      ])
    effect.AttemptTokenMismatch(attempt, field) ->
      object([
        #("tag", json.string("AttemptTokenMismatch")),
        #("attempt", encode_attempt_identity(attempt)),
        #("field", json.string(token_field_name(field))),
      ])
    effect.ObservationRelationMismatch(attempt, field) ->
      object([
        #("tag", json.string("ObservationRelationMismatch")),
        #("attempt", encode_attempt_identity(attempt)),
        #("field", json.string(observation_field_name(field))),
      ])
    effect.RequiredCapabilityUnavailable(attempt, capability) ->
      object([
        #("tag", json.string("RequiredCapabilityUnavailable")),
        #("attempt", encode_attempt_identity(attempt)),
        #("capability", json.string(capability_name(capability))),
      ])
    effect.CommandAlreadyIssued(attempt) ->
      object([
        #("tag", json.string("CommandAlreadyIssued")),
        #("attempt", encode_attempt_identity(attempt)),
      ])
    effect.IdentityMismatch(expected, actual) ->
      object([
        #("tag", json.string("IdentityMismatch")),
        #("expected", encode_attempt_identity(expected)),
        #("actual", encode_attempt_identity(actual)),
      ])
    effect.HandleMismatch(expected, actual) ->
      object([
        #("tag", json.string("HandleMismatch")),
        #("expected", encode_handle(expected)),
        #("actual", encode_handle(actual)),
      ])
    effect.ClockBasisMismatch(expected, actual) ->
      object([
        #("tag", json.string("ClockBasisMismatch")),
        #("expected", encode_clock_basis(expected)),
        #("actual", encode_clock_basis(actual)),
      ])
    effect.DeadlineNotReached(deadline, observed) ->
      object([
        #("tag", json.string("DeadlineNotReached")),
        #("deadline", encode_deadline(deadline)),
        #("observedAt", encode_clock_observation(observed)),
      ])
    effect.DeliveryOrderViolation(attempt, expected, actual) ->
      object([
        #("tag", json.string("DeliveryOrderViolation")),
        #("attempt", encode_attempt_identity(attempt)),
        #("expected", json.int(expected)),
        #("actual", json.int(actual)),
      ])
    effect.ConflictingDelivery(attempt, delivery, old, fresh) ->
      object([
        #("tag", json.string("ConflictingDelivery")),
        #("attempt", encode_attempt_identity(attempt)),
        #("delivery", json.int(delivery)),
        #("old", encode_adapter_observation(old)),
        #("fresh", encode_adapter_observation(fresh)),
      ])
    effect.MalformedAdapterObservation -> tag("MalformedAdapterObservation")
    effect.Host(failure) ->
      object([
        #("tag", json.string("Host")),
        #("failure", encode_network_host_failure(failure)),
      ])
    effect.RetryNotPermitted(attempt) ->
      object([
        #("tag", json.string("RetryNotPermitted")),
        #("attempt", encode_attempt_identity(attempt)),
      ])
    effect.RetryIdentityMismatch(expected, actual) ->
      object([
        #("tag", json.string("RetryIdentityMismatch")),
        #("expected", encode_request_identity(expected)),
        #("actual", encode_request_identity(actual)),
      ])
    effect.RetryParentMismatch(expected, actual) ->
      object([
        #("tag", json.string("RetryParentMismatch")),
        #("expected", encode_attempt_identity(expected)),
        #("actual", encode_attempt_identity(actual)),
      ])
    effect.RetryParentNotSettled(attempt) ->
      object([
        #("tag", json.string("RetryParentNotSettled")),
        #("attempt", encode_attempt_identity(attempt)),
      ])
    effect.RetryOrderViolation(expected, actual) ->
      object([
        #("tag", json.string("RetryOrderViolation")),
        #("expected", encode_attempt_identity(expected)),
        #("actual", encode_attempt_identity(actual)),
      ])
    effect.RetryAuthorizationAlreadyUsed(authorization) ->
      object([
        #("tag", json.string("RetryAuthorizationAlreadyUsed")),
        #("authorization", encode_authorization(authorization)),
      ])
    effect.EffectWitnessMissing(attempt) ->
      object([
        #("tag", json.string("EffectWitnessMissing")),
        #("attempt", encode_attempt_identity(attempt)),
      ])
    effect.EffectKnowledgeConflict(attempt) ->
      object([
        #("tag", json.string("EffectKnowledgeConflict")),
        #("attempt", encode_attempt_identity(attempt)),
      ])
  }
}

fn rejected(
  state: effect.NetworkState,
  failure: effect.NetworkFailure,
) -> json.Json {
  object([
    #("result", json.string("Rejected")),
    #("state", encode_state(state)),
    #("failure", encode_failure(failure)),
  ])
}

fn encode_read_step(value: effect.ReadStateStep) -> json.Json {
  case value {
    effect.Read(state) ->
      object([
        #("result", json.string("Read")),
        #("state", encode_state(state)),
      ])
    effect.ReadRejected(state, failure) -> rejected(state, failure)
  }
}

fn encode_prepare_step(value: effect.PrepareStep) -> json.Json {
  case value {
    effect.PreparedResult(state, prepared) ->
      object([
        #("result", json.string("Prepared")),
        #("state", encode_state(state)),
        #("prepared", encode_prepared(prepared)),
      ])
    effect.PrepareRejected(state, failure) -> rejected(state, failure)
  }
}

fn encode_send_command(value: effect.SendCommand) -> json.Json {
  object([#("prepared", encode_prepared(value.prepared))])
}

fn encode_cancel_command(value: effect.CancelCommand) -> json.Json {
  object([
    #("attempt", encode_attempt_identity(value.attempt)),
    #("handle", encode_handle(value.handle)),
    #("capability", encode_cancellation_capability(value.capability)),
  ])
}

fn encode_command_step(
  value: effect.CommandStep(a),
  encode_command: fn(a) -> json.Json,
) -> json.Json {
  case value {
    effect.CommandReady(state, command) ->
      object([
        #("result", json.string("CommandReady")),
        #("state", encode_state(state)),
        #("command", encode_command(command)),
      ])
    effect.CommandRejected(state, failure) -> rejected(state, failure)
  }
}

fn encode_settled(value: effect.SettledAttempt) -> json.Json {
  object([
    #("prepared", encode_prepared(value.prepared)),
    #("handle", json.nullable(value.handle, encode_handle)),
    #("terminal", encode_terminal(value.terminal)),
  ])
}

fn encode_network_step(value: effect.NetworkStep) -> json.Json {
  case value {
    effect.StartedStep(state, started) ->
      object([
        #("result", json.string("Started")),
        #("state", encode_state(state)),
        #("started", encode_started(started)),
      ])
    effect.PendingStep(state, started) ->
      object([
        #("result", json.string("Pending")),
        #("state", encode_state(state)),
        #("started", encode_started(started)),
      ])
    effect.TerminalStep(state, settled) ->
      object([
        #("result", json.string("Terminal")),
        #("state", encode_state(state)),
        #("settled", encode_settled(settled)),
      ])
    effect.LateStep(state, settled, late) ->
      object([
        #("result", json.string("Late")),
        #("state", encode_state(state)),
        #("settled", encode_settled(settled)),
        #("late", encode_late(late)),
      ])
    effect.DuplicateStep(state, attempt, delivery) ->
      object([
        #("result", json.string("Duplicate")),
        #("state", encode_state(state)),
        #("attempt", encode_attempt_identity(attempt)),
        #("delivery", json.int(delivery)),
      ])
    effect.NetworkRejected(state, failure) -> rejected(state, failure)
  }
}

fn encode_state_step(value: effect.StateStep) -> json.Json {
  case value {
    effect.Applied(state) ->
      object([
        #("result", json.string("Applied")),
        #("state", encode_state(state)),
      ])
    effect.StateRejected(state, failure) -> rejected(state, failure)
  }
}

pub fn execute(invocation: Invocation) -> json.Json {
  case invocation {
    ReadNetworkState(state) ->
      encode_read_step(effect.read_network_state(state))
    Prepare(state, input) -> encode_prepare_step(effect.prepare(state, input))
    SendCommand(state, prepared) ->
      encode_command_step(
        effect.send_command(state, prepared),
        encode_send_command,
      )
    CancelCommand(state, started) ->
      encode_command_step(
        effect.cancel_command(state, started),
        encode_cancel_command,
      )
    ObserveStart(state, prepared, observation) ->
      encode_network_step(effect.observe_start(state, prepared, observation))
    Observe(state, observation) ->
      encode_network_step(effect.observe(state, observation))
    AnnotateEffect(state, observation) ->
      encode_state_step(effect.annotate_effect(state, observation))
    Retry(state, request) -> encode_prepare_step(effect.retry(state, request))
  }
}
