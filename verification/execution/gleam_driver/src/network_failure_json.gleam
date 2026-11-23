// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/json
import necoherence/network_effect as effect

fn object(fields: List(#(String, json.Json))) -> json.Json {
  json.object(fields)
}

fn tag(name: String) -> json.Json {
  object([#("tag", json.string(name))])
}

fn request_identity(value: effect.RequestIdentity) -> json.Json {
  object([
    #("kind", json.string(value.kind)),
    #("provenance", json.string(value.provenance)),
    #("revision", json.int(value.revision)),
  ])
}

fn attempt_identity(value: effect.AttemptIdentity) -> json.Json {
  object([
    #("logical", request_identity(value.logical)),
    #("ordinal", json.int(value.ordinal)),
  ])
}

fn handle(value: effect.ExecutionHandle) -> json.Json {
  object([#("value", json.string(value.value))])
}

fn evidence(value: effect.OpaqueEvidence) -> json.Json {
  object([#("value", json.string(value.value))])
}

fn clock_basis(value: effect.ClockBasis) -> json.Json {
  object([#("value", json.string(value.value))])
}

fn clock_observation(value: effect.MonotonicClockObservation) -> json.Json {
  object([
    #("clockBasis", clock_basis(value.clock_basis)),
    #("value", json.int(value.value)),
  ])
}

fn clock_capability(value: effect.MonotonicClockCapability) -> json.Json {
  object([
    #("identity", evidence(value.identity)),
    #("clockBasis", clock_basis(value.clock_basis)),
  ])
}

fn cancellation_capability(value: effect.CancellationCapability) -> json.Json {
  object([#("identity", evidence(value.identity))])
}

fn deadline(value: effect.Deadline) -> json.Json {
  object([
    #("clockBasis", clock_basis(value.clock_basis)),
    #("limit", json.int(value.limit)),
    #("capability", clock_capability(value.capability)),
  ])
}

fn configuration(value: effect.HostConfiguration) -> json.Json {
  object([
    #("requestBodyLimit", json.int(value.request_body_limit)),
    #("responseBodyLimit", json.int(value.response_body_limit)),
    #(
      "cancellation",
      json.nullable(value.cancellation, cancellation_capability),
    ),
    #("monotonicClock", json.nullable(value.monotonic_clock, clock_capability)),
  ])
}

fn authorization(value: effect.RetryAuthorization) -> json.Json {
  object([
    #("logical", request_identity(value.logical)),
    #("from", attempt_identity(value.from)),
    #("next", attempt_identity(value.next)),
    #("protocolEvidence", evidence(value.protocol_evidence)),
  ])
}

fn header(value: effect.RawHeaderField) -> json.Json {
  object([
    #("name", json.string(value.name)),
    #("value", json.array(byte_values(value.value), json.int)),
  ])
}

fn response(value: effect.RawHttpResponse) -> json.Json {
  object([
    #("status", json.int(value.status)),
    #("headers", json.array(value.headers, header)),
    #("body", json.array(byte_values(value.body), json.int)),
  ])
}

fn provenance(value: effect.HeaderProvenance) -> json.Json {
  case value {
    effect.WireObserved -> tag("WireObserved")
    effect.LibraryObserved -> tag("LibraryObserved")
    effect.LibraryNormalized -> tag("LibraryNormalized")
  }
}

fn witness_source(value: effect.EffectWitnessSource) -> json.Json {
  case value {
    effect.Adapter -> tag("Adapter")
    effect.Protocol -> tag("Protocol")
  }
}

fn witness(value: effect.EffectWitness) -> json.Json {
  object([
    #("attempt", attempt_identity(value.attempt)),
    #("source", witness_source(value.source)),
    #("evidence", evidence(value.evidence)),
  ])
}

fn unknown_reason(value: effect.UnknownEffectReason) -> json.Json {
  tag(case value {
    effect.NoResponse -> "NoResponse"
    effect.CancellationReason -> "Cancellation"
    effect.DeadlineReason -> "Deadline"
    effect.HostFailure -> "HostFailure"
    effect.ProtocolWitnessMissing -> "ProtocolWitnessMissing"
    effect.LateSignal -> "LateSignal"
  })
}

fn effect_status(value: effect.EffectStatus) -> json.Json {
  case value {
    effect.Unknown(reason) ->
      object([
        #("tag", json.string("Unknown")),
        #("reason", unknown_reason(reason)),
      ])
    effect.NoEffect(value) ->
      object([#("tag", json.string("NoEffect")), #("witness", witness(value))])
    effect.EffectOccurred(value) ->
      object([
        #("tag", json.string("EffectOccurred")),
        #("witness", witness(value)),
      ])
  }
}

fn host_stage(value: effect.HostStage) -> String {
  case value {
    effect.Start -> "Start"
    effect.RequestWrite -> "RequestWrite"
    effect.ResponseHeaders -> "ResponseHeaders"
    effect.ResponseBody -> "ResponseBody"
    effect.Cancel -> "Cancel"
    effect.DeadlineStage -> "Deadline"
  }
}

fn timeout_cause(value: effect.HostTimeoutCause) -> String {
  case value {
    effect.LibraryReported -> "LibraryReported"
    effect.SocketReported -> "SocketReported"
    effect.PoolAcquisition -> "PoolAcquisition"
    effect.HostOperation -> "HostOperation"
  }
}

fn host_failure(value: effect.HostFailure) -> json.Json {
  case value {
    effect.Timeout(stage, cause) ->
      object([
        #("tag", json.string("Timeout")),
        #("stage", tag(host_stage(stage))),
        #("cause", tag(timeout_cause(cause))),
      ])
    effect.UnsupportedUriScheme -> tag("UnsupportedUriScheme")
    effect.InvalidHostConfiguration -> tag("InvalidHostConfiguration")
    effect.ExecutionStartFailed -> tag("ExecutionStartFailed")
    effect.NameResolutionFailed -> tag("NameResolutionFailed")
    effect.ConnectionFailed -> tag("ConnectionFailed")
    effect.RequestWriteFailed -> tag("RequestWriteFailed")
    effect.ResponseHeadersFailed -> tag("ResponseHeadersFailed")
    effect.ResponseBodyFailed -> tag("ResponseBodyFailed")
    effect.ResponseBodyLimitExceeded -> tag("ResponseBodyLimitExceeded")
    effect.MalformedResponse -> tag("MalformedResponse")
    effect.HeaderRepresentationUnavailable ->
      tag("HeaderRepresentationUnavailable")
    effect.RequestHeaderEncodingUnavailable ->
      tag("RequestHeaderEncodingUnavailable")
    effect.CancellationRejected -> tag("CancellationRejected")
    effect.DeadlineControlUnavailable -> tag("DeadlineControlUnavailable")
    effect.HostRuntimeFailure -> tag("HostRuntimeFailure")
    effect.HostClosed -> tag("HostClosed")
  }
}

fn network_host_failure(value: effect.NetworkHostFailure) -> json.Json {
  object([
    #("attempt", attempt_identity(value.attempt)),
    #("stage", tag(host_stage(value.stage))),
    #("configuration", configuration(value.configuration)),
    #("cause", host_failure(value.cause)),
  ])
}

fn source_sequence(value: effect.SourceSequence) -> json.Json {
  case value {
    effect.NoSource -> json.null()
    effect.Source(value) -> json.int(value)
  }
}

fn adapter_observation(value: effect.AdapterObservation) -> json.Json {
  case value {
    effect.ResponseObservation(
      attempt,
      execution_handle,
      source,
      raw,
      source_provenance,
      status,
    ) ->
      object([
        #("tag", json.string("ResponseObservation")),
        #("attempt", attempt_identity(attempt)),
        #("handle", handle(execution_handle)),
        #("sourceSequence", source_sequence(source)),
        #("response", response(raw)),
        #("provenance", provenance(source_provenance)),
        #("effect", effect_status(status)),
      ])
    effect.FailureObservation(
      attempt,
      execution_handle,
      source,
      failure,
      status,
    ) ->
      object([
        #("tag", json.string("FailureObservation")),
        #("attempt", attempt_identity(attempt)),
        #("handle", handle(execution_handle)),
        #("sourceSequence", source_sequence(source)),
        #("failure", network_host_failure(failure)),
        #("effect", effect_status(status)),
      ])
    effect.CancellationObservation(attempt, execution_handle, source, status) ->
      object([
        #("tag", json.string("CancellationObservation")),
        #("attempt", attempt_identity(attempt)),
        #("handle", handle(execution_handle)),
        #("sourceSequence", source_sequence(source)),
        #("effect", effect_status(status)),
      ])
    effect.DeadlineObservation(
      attempt,
      execution_handle,
      source,
      limit,
      observed,
      status,
    ) ->
      object([
        #("tag", json.string("DeadlineObservation")),
        #("attempt", attempt_identity(attempt)),
        #("handle", handle(execution_handle)),
        #("sourceSequence", source_sequence(source)),
        #("deadline", deadline(limit)),
        #("observedAt", clock_observation(observed)),
        #("effect", effect_status(status)),
      ])
  }
}

fn state_violation(value: effect.NetworkStateViolation) -> json.Json {
  case value {
    effect.DuplicateAttemptKey(attempt) ->
      object([
        #("tag", json.string("DuplicateAttemptKey")),
        #("attempt", attempt_identity(attempt)),
      ])
    effect.NonRootFirstAttempt(attempt) ->
      object([
        #("tag", json.string("NonRootFirstAttempt")),
        #("attempt", attempt_identity(attempt)),
      ])
    effect.OrdinalGap(attempt) ->
      object([
        #("tag", json.string("OrdinalGap")),
        #("attempt", attempt_identity(attempt)),
      ])
    effect.ChainMismatch(attempt) ->
      object([
        #("tag", json.string("ChainMismatch")),
        #("attempt", attempt_identity(attempt)),
      ])
    effect.RetryAuthorizationReuse(value) ->
      object([
        #("tag", json.string("RetryAuthorizationReuse")),
        #("authorization", authorization(value)),
      ])
    effect.DispositionEvidenceMismatch(attempt) ->
      object([
        #("tag", json.string("DispositionEvidenceMismatch")),
        #("attempt", attempt_identity(attempt)),
      ])
    effect.DeliveryLogMismatch(attempt) ->
      object([
        #("tag", json.string("DeliveryLogMismatch")),
        #("attempt", attempt_identity(attempt)),
      ])
  }
}

fn attempt_condition(value: effect.AttemptCondition) -> String {
  case value {
    effect.IsPrepared -> "IsPrepared"
    effect.IsCommandIssued -> "IsCommandIssued"
    effect.IsStarted -> "IsStarted"
    effect.IsSettled -> "IsSettled"
  }
}

fn token_field(value: effect.AttemptTokenField) -> String {
  case value {
    effect.Instruction -> "Instruction"
    effect.DeadlineField -> "Deadline"
    effect.Configuration -> "Configuration"
    effect.Chain -> "Chain"
    effect.Handle -> "Handle"
  }
}

fn observation_field(value: effect.ObservationField) -> String {
  case value {
    effect.FailureConfiguration -> "FailureConfiguration"
    effect.FailureStage -> "FailureStage"
    effect.DeadlineValue -> "DeadlineValue"
    effect.ClockBasisValue -> "ClockBasisValue"
    effect.ClockObservationValue -> "ClockObservationValue"
    effect.EffectWitnessValue -> "EffectWitnessValue"
  }
}

fn capability(value: effect.CapabilityKind) -> String {
  case value {
    effect.CancellationCapabilityKind -> "Cancellation"
    effect.MonotonicClock -> "MonotonicClock"
  }
}

pub fn encode(value: effect.NetworkFailure) -> json.Json {
  case value {
    effect.InvalidWireInstruction(method) ->
      object([
        #("tag", json.string("InvalidWireInstruction")),
        #("method", json.string(method)),
      ])
    effect.InvalidDeadline -> tag("InvalidDeadline")
    effect.InvalidNetworkState(value) ->
      object([
        #("tag", json.string("InvalidNetworkState")),
        #("violation", state_violation(value)),
      ])
    effect.RootAttemptRequired(attempt) ->
      object([
        #("tag", json.string("RootAttemptRequired")),
        #("attempt", attempt_identity(attempt)),
      ])
    effect.DuplicateAttempt(attempt) ->
      object([
        #("tag", json.string("DuplicateAttempt")),
        #("attempt", attempt_identity(attempt)),
      ])
    effect.UnknownAttempt(attempt) ->
      object([
        #("tag", json.string("UnknownAttempt")),
        #("attempt", attempt_identity(attempt)),
      ])
    effect.AttemptConditionMismatch(attempt, expected, actual) ->
      object([
        #("tag", json.string("AttemptConditionMismatch")),
        #("attempt", attempt_identity(attempt)),
        #("expected", json.string(attempt_condition(expected))),
        #("actual", json.string(attempt_condition(actual))),
      ])
    effect.AttemptTokenMismatch(attempt, field) ->
      object([
        #("tag", json.string("AttemptTokenMismatch")),
        #("attempt", attempt_identity(attempt)),
        #("field", json.string(token_field(field))),
      ])
    effect.ObservationRelationMismatch(attempt, field) ->
      object([
        #("tag", json.string("ObservationRelationMismatch")),
        #("attempt", attempt_identity(attempt)),
        #("field", json.string(observation_field(field))),
      ])
    effect.RequiredCapabilityUnavailable(attempt, value) ->
      object([
        #("tag", json.string("RequiredCapabilityUnavailable")),
        #("attempt", attempt_identity(attempt)),
        #("capability", json.string(capability(value))),
      ])
    effect.CommandAlreadyIssued(attempt) ->
      object([
        #("tag", json.string("CommandAlreadyIssued")),
        #("attempt", attempt_identity(attempt)),
      ])
    effect.IdentityMismatch(expected, actual) ->
      object([
        #("tag", json.string("IdentityMismatch")),
        #("expected", attempt_identity(expected)),
        #("actual", attempt_identity(actual)),
      ])
    effect.HandleMismatch(expected, actual) ->
      object([
        #("tag", json.string("HandleMismatch")),
        #("expected", handle(expected)),
        #("actual", handle(actual)),
      ])
    effect.ClockBasisMismatch(expected, actual) ->
      object([
        #("tag", json.string("ClockBasisMismatch")),
        #("expected", clock_basis(expected)),
        #("actual", clock_basis(actual)),
      ])
    effect.DeadlineNotReached(limit, observed) ->
      object([
        #("tag", json.string("DeadlineNotReached")),
        #("deadline", deadline(limit)),
        #("observedAt", clock_observation(observed)),
      ])
    effect.DeliveryOrderViolation(attempt, expected, actual) ->
      object([
        #("tag", json.string("DeliveryOrderViolation")),
        #("attempt", attempt_identity(attempt)),
        #("expected", json.int(expected)),
        #("actual", json.int(actual)),
      ])
    effect.ConflictingDelivery(attempt, delivery, old, fresh) ->
      object([
        #("tag", json.string("ConflictingDelivery")),
        #("attempt", attempt_identity(attempt)),
        #("delivery", json.int(delivery)),
        #("old", adapter_observation(old)),
        #("fresh", adapter_observation(fresh)),
      ])
    effect.MalformedAdapterObservation -> tag("MalformedAdapterObservation")
    effect.Host(failure) ->
      object([
        #("tag", json.string("Host")),
        #("failure", network_host_failure(failure)),
      ])
    effect.RetryNotPermitted(attempt) ->
      object([
        #("tag", json.string("RetryNotPermitted")),
        #("attempt", attempt_identity(attempt)),
      ])
    effect.RetryIdentityMismatch(expected, actual) ->
      object([
        #("tag", json.string("RetryIdentityMismatch")),
        #("expected", request_identity(expected)),
        #("actual", request_identity(actual)),
      ])
    effect.RetryParentMismatch(expected, actual) ->
      object([
        #("tag", json.string("RetryParentMismatch")),
        #("expected", attempt_identity(expected)),
        #("actual", attempt_identity(actual)),
      ])
    effect.RetryParentNotSettled(attempt) ->
      object([
        #("tag", json.string("RetryParentNotSettled")),
        #("attempt", attempt_identity(attempt)),
      ])
    effect.RetryOrderViolation(expected, actual) ->
      object([
        #("tag", json.string("RetryOrderViolation")),
        #("expected", attempt_identity(expected)),
        #("actual", attempt_identity(actual)),
      ])
    effect.RetryAuthorizationAlreadyUsed(value) ->
      object([
        #("tag", json.string("RetryAuthorizationAlreadyUsed")),
        #("authorization", authorization(value)),
      ])
    effect.EffectWitnessMissing(attempt) ->
      object([
        #("tag", json.string("EffectWitnessMissing")),
        #("attempt", attempt_identity(attempt)),
      ])
    effect.EffectKnowledgeConflict(attempt) ->
      object([
        #("tag", json.string("EffectKnowledgeConflict")),
        #("attempt", attempt_identity(attempt)),
      ])
  }
}

fn byte_values(bytes: BitArray) -> List(Int) {
  case bytes {
    <<byte, rest:bits>> -> [byte, ..byte_values(rest)]
    _ -> []
  }
}
