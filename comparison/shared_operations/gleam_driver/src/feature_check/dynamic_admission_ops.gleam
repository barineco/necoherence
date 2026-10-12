// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import feature_check/decode_support.{
  type D, arr_field, is_null, nat_field, obj_val, try,
}
import feature_check/json_value.{type JsonValue, JNull, array, object, string}
import feature_check/request_progression_ops.{
  decode_cost_selection, decode_request_identity, decode_request_input,
  decode_resource_budget, decode_snapshot, encode_request_identity,
  encode_resource_budget, encode_snapshot, encode_start_decision_failure,
  encode_start_decision_result, encode_submit_failure,
}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import necoherence/core
import necoherence/dynamic_admission as admission
import necoherence/request_progression as rp

fn decode_environment_specification(
  value: JsonValue,
) -> D(admission.EnvironmentSpecification) {
  use age <- try(nat_field(value, "maxObservationAge"))
  Ok(admission.EnvironmentSpecification(age))
}

fn decode_capacity_observation(
  value: JsonValue,
) -> D(admission.CapacityObservation) {
  use observed <- try(
    obj_val(value, "observed") |> result.try(decode_resource_budget),
  )
  use observed_at <- try(nat_field(value, "observedAt"))
  Ok(admission.CapacityObservation(observed, observed_at))
}

fn decode_signal_kind(value: JsonValue) -> D(admission.SignalKind) {
  use value <- try(decode_support.as_str(value))
  case value {
    "pendingCompletion" -> Ok(admission.PendingCompletion)
    "pendingCancellation" -> Ok(admission.PendingCancellation)
    other -> Error(decode_support.fail_shape("unknown signal kind " <> other))
  }
}

fn encode_signal_kind(value: admission.SignalKind) -> JsonValue {
  case value {
    admission.PendingCompletion -> string("pendingCompletion")
    admission.PendingCancellation -> string("pendingCancellation")
  }
}

fn decode_admission_signal(value: JsonValue) -> D(admission.AdmissionSignal) {
  use identity_json <- try(obj_val(value, "identity"))
  use identity <- try(decode_request_identity(identity_json))
  use handle_json <- try(obj_val(value, "handle"))
  use handle <- try(decode_support.as_str(handle_json))
  use kind_json <- try(obj_val(value, "kind"))
  use kind <- try(decode_signal_kind(kind_json))
  Ok(admission.AdmissionSignal(identity, rp.ExecutionHandle(handle), kind))
}

fn encode_admission_signal(signal: admission.AdmissionSignal) -> JsonValue {
  object([
    #("identity", encode_request_identity(signal.identity)),
    #("handle", string(signal.handle.value)),
    #("kind", encode_signal_kind(signal.kind)),
  ])
}

fn decode_admission_provenance(
  value: JsonValue,
) -> D(admission.AdmissionProvenance) {
  use future_json <- try(arr_field(value, "futureUses"))
  use future_uses <- try(decode_support.map_list(
    future_json,
    decode_request_identity,
  ))
  use signals_json <- try(arr_field(value, "outstandingSignals"))
  use signals <- try(decode_support.map_list(
    signals_json,
    decode_admission_signal,
  ))
  Ok(admission.AdmissionProvenance(future_uses, signals))
}

fn encode_admission_provenance(
  provenance: admission.AdmissionProvenance,
) -> JsonValue {
  object([
    #(
      "futureUses",
      array(list.map(provenance.future_uses, encode_request_identity)),
    ),
    #(
      "outstandingSignals",
      array(list.map(provenance.outstanding_signals, encode_admission_signal)),
    ),
  ])
}

fn decode_admission_state(
  value: JsonValue,
) -> D(admission.DynamicAdmissionState) {
  use progression_json <- try(obj_val(value, "progression"))
  use progression <- try(decode_snapshot(progression_json))
  use limit_json <- try(obj_val(value, "configuredSafetyLimit"))
  use limit <- try(decode_resource_budget(limit_json))
  use provenance_json <- try(obj_val(value, "provenance"))
  use provenance <- try(decode_admission_provenance(provenance_json))
  Ok(admission.DynamicAdmissionState(progression, limit, provenance))
}

fn encode_admission_state(state: admission.DynamicAdmissionState) -> JsonValue {
  object([
    #("progression", encode_snapshot(state.progression)),
    #(
      "configuredSafetyLimit",
      encode_resource_budget(state.configured_safety_limit),
    ),
    #("provenance", encode_admission_provenance(state.provenance)),
  ])
}

fn decode_admission_input(
  value: JsonValue,
) -> D(admission.DynamicAdmissionInput) {
  use state_json <- try(obj_val(value, "state"))
  use state <- try(decode_admission_state(state_json))
  use request_json <- try(obj_val(value, "request"))
  use request <- try(decode_request_input(request_json))
  use environment_json <- try(obj_val(value, "environmentSpecification"))
  use environment <- try(decode_environment_specification(environment_json))
  use capacity_json <- try(obj_val(value, "capacityObservation"))
  use capacity <- try(decode_capacity_observation(capacity_json))
  use observed_at <- try(nat_field(value, "observedAt"))
  use start_json <- try(obj_val(value, "start"))
  use start <- try(case is_null(start_json) {
    True -> Ok(None)
    False -> decode_cost_selection(start_json) |> result.map(Some)
  })
  Ok(admission.DynamicAdmissionInput(
    state,
    request,
    environment,
    capacity,
    observed_at,
    start,
  ))
}

fn encode_admission_failure(
  value: admission.DynamicAdmissionFailure,
) -> JsonValue {
  case value {
    admission.CapacityObservationUnavailable(age, max_age) ->
      object([
        #("tag", string("capacityObservationUnavailable")),
        #("age", decode_support.nat_to_json(age)),
        #("maxAge", decode_support.nat_to_json(max_age)),
      ])
    admission.ResourceCoordinateMismatch(a, b) ->
      object([
        #("tag", string("resourceCoordinateMismatch")),
        #("configuredResource", string(a)),
        #("observedResource", string(b)),
      ])
    admission.ConfiguredSafetyLimitExceeded(resource, occupied, allowed) ->
      object([
        #("tag", string("configuredSafetyLimitExceeded")),
        #("resource", string(resource)),
        #("occupied", decode_support.nat_to_json(occupied)),
        #("allowed", decode_support.nat_to_json(allowed)),
      ])
    admission.MeaningDenied(identity, rp.Denial(reason)) ->
      object([
        #("tag", string("meaningDenied")),
        #("identity", encode_request_identity(identity)),
        #("reason", string(reason)),
      ])
    admission.PermissionIdentityMismatch(a, b) ->
      object([
        #("tag", string("permissionIdentityMismatch")),
        #("requestIdentity", encode_request_identity(a)),
        #("permissionIdentity", encode_request_identity(b)),
      ])
    admission.AdapterBindingUnavailable(i) ->
      identity_failure("adapterBindingUnavailable", i)
    admission.BindingSelectionMismatch(i) ->
      identity_failure("bindingSelectionMismatch", i)
    admission.ProgressionSubmitFailure(f) ->
      object([
        #("tag", string("progressionSubmitFailure")),
        #("failure", encode_submit_failure(f)),
      ])
    admission.ProgressionStartFailure(f) ->
      object([
        #("tag", string("progressionStartFailure")),
        #("failure", encode_start_decision_failure(f)),
      ])
    admission.ProvenanceRetentionRequired(i) ->
      identity_failure("provenanceRetentionRequired", i)
    admission.AdmissionUnknownRequest(i) ->
      identity_failure("unknownRequest", i)
    admission.AdmissionRequestNotTerminal(i) ->
      identity_failure("requestNotTerminal", i)
  }
}

fn identity_failure(tag: String, identity: rp.RequestIdentity) -> JsonValue {
  object([
    #("tag", string(tag)),
    #("identity", encode_request_identity(identity)),
  ])
}

fn encode_admission_decision(value: admission.AdmissionDecision) -> JsonValue {
  case value {
    admission.Submitted(state, accepted) ->
      object([
        #("tag", string("submitted")),
        #("state", encode_admission_state(state)),
        #(
          "accepted",
          object([#("identity", encode_request_identity(accepted.identity))]),
        ),
      ])
    admission.Started(state, result) ->
      object([
        #("tag", string("started")),
        #("state", encode_admission_state(state)),
        #("result", encode_start_decision_result(result)),
      ])
    admission.Coalesced(state, identity) ->
      object([
        #("tag", string("coalesced")),
        #("state", encode_admission_state(state)),
        #("identity", encode_request_identity(identity)),
      ])
  }
}

fn encode_witness(value: admission.ProvenanceErasureWitness) -> JsonValue {
  case value {
    admission.Erased(i) -> identity_failure("erased", i)
    admission.Retained(i, reason) ->
      object([
        #("tag", string("retained")),
        #("identity", encode_request_identity(i)),
        #("reason", string(reason)),
      ])
  }
}

fn encode_coalescing_witness(value: admission.CoalescingWitness) -> JsonValue {
  case value {
    admission.CoalescedRequest(i) -> identity_failure("coalesced", i)
    admission.NotCoalesced(reason) ->
      object([#("tag", string("notCoalesced")), #("reason", string(reason))])
  }
}

fn encode_admission_result(
  value: admission.DynamicAdmissionResult,
) -> JsonValue {
  object([
    #("effectiveBudget", encode_resource_budget(value.effective_budget)),
    #("admissionDecision", encode_admission_decision(value.admission_decision)),
    #(
      "futureUseSet",
      array(list.map(value.future_use_set.identities, encode_request_identity)),
    ),
    #(
      "outstandingSignalSet",
      array(list.map(
        value.outstanding_signal_set.signals,
        encode_admission_signal,
      )),
    ),
    #("provenanceErasureWitness", case value.provenance_erasure_witness {
      None -> JNull
      Some(w) -> encode_witness(w)
    }),
    #("coalescingWitness", encode_coalescing_witness(value.coalescing_witness)),
  ])
}

fn encode_admission_outcome(
  value: core.Outcome(
    admission.DynamicAdmissionResult,
    admission.DynamicAdmissionFailure,
    Nil,
    Nil,
  ),
) -> JsonValue {
  case value {
    core.Applied(result) ->
      object([
        #("tag", string("applied")),
        #("value", encode_admission_result(result)),
      ])
    core.Rejected(failure) ->
      object([
        #("tag", string("rejected")),
        #("failure", encode_admission_failure(failure)),
      ])
    core.Conflicted(_) | core.BoundaryFailed(_) -> JNull
  }
}

fn encode_elision_outcome(
  value: core.Outcome(
    #(admission.DynamicAdmissionState, admission.ProvenanceErasureWitness),
    admission.DynamicAdmissionFailure,
    Nil,
    Nil,
  ),
) -> JsonValue {
  case value {
    core.Applied(#(state, witness)) ->
      object([
        #("tag", string("applied")),
        #("state", encode_admission_state(state)),
        #("witness", encode_witness(witness)),
      ])
    core.Rejected(failure) ->
      object([
        #("tag", string("rejected")),
        #("failure", encode_admission_failure(failure)),
      ])
    core.Conflicted(_) | core.BoundaryFailed(_) -> JNull
  }
}

pub fn op_dynamic_admission_elide_admission_provenance(
  input: JsonValue,
) -> D(JsonValue) {
  use state <- try(
    obj_val(input, "state") |> result.try(decode_admission_state),
  )
  use identity <- try(
    obj_val(input, "identity") |> result.try(decode_request_identity),
  )
  Ok(
    encode_elision_outcome(admission.elide_admission_provenance(state, identity)),
  )
}

pub fn op_dynamic_admission_admit_dynamic_request(
  input: JsonValue,
) -> D(JsonValue) {
  use value <- try(decode_admission_input(input))
  Ok(encode_admission_outcome(admission.admit_dynamic_request(value)))
}
