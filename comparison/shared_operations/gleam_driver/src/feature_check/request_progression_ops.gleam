// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import feature_check/decode_support.{
  type D, arr_field, as_str, fail_shape, is_null, nat_field, nat_to_json,
  obj_val, str_field, try,
}
import feature_check/json_value.{type JsonValue, array, object, string}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import necoherence/request_progression as rp

pub fn decode_request_policy(value: JsonValue) -> D(rp.RequestPolicy) {
  use s <- try(as_str(value))
  case s {
    "latestWins" -> Ok(rp.LatestWins)
    "fifo" -> Ok(rp.Fifo)
    "allExecute" -> Ok(rp.AllExecute)
    other -> Error(fail_shape("unknown policy " <> other))
  }
}

pub fn encode_request_policy(value: rp.RequestPolicy) -> JsonValue {
  case value {
    rp.LatestWins -> string("latestWins")
    rp.Fifo -> string("fifo")
    rp.AllExecute -> string("allExecute")
  }
}

pub fn decode_request_phase(value: JsonValue) -> D(rp.RequestPhase) {
  use s <- try(as_str(value))
  case s {
    "pending" -> Ok(rp.Pending)
    "preparing" -> Ok(rp.Preparing)
    "publishing" -> Ok(rp.Publishing)
    "published" -> Ok(rp.Published)
    "superseded" -> Ok(rp.Superseded)
    "cancelled" -> Ok(rp.Cancelled)
    "failed" -> Ok(rp.Failed)
    other -> Error(fail_shape("unknown phase " <> other))
  }
}

pub fn encode_request_phase(value: rp.RequestPhase) -> JsonValue {
  case value {
    rp.Pending -> string("pending")
    rp.Preparing -> string("preparing")
    rp.Publishing -> string("publishing")
    rp.Published -> string("published")
    rp.Superseded -> string("superseded")
    rp.Cancelled -> string("cancelled")
    rp.Failed -> string("failed")
  }
}

fn decode_request_effect_class(value: JsonValue) -> D(rp.RequestEffectClass) {
  use s <- try(as_str(value))
  case s {
    "pure" -> Ok(rp.PureEffect)
    "orderedEffect" -> Ok(rp.OrderedEffect)
    other -> Error(fail_shape("unknown effect class " <> other))
  }
}

fn encode_request_effect_class(value: rp.RequestEffectClass) -> JsonValue {
  case value {
    rp.PureEffect -> string("pure")
    rp.OrderedEffect -> string("orderedEffect")
  }
}

pub fn decode_request_identity(value: JsonValue) -> D(rp.RequestIdentity) {
  use kind <- try(str_field(value, "kind"))
  use provenance <- try(str_field(value, "provenance"))
  use revision <- try(nat_field(value, "revision"))
  Ok(rp.RequestIdentity(kind, provenance, revision))
}

pub fn encode_request_identity(i: rp.RequestIdentity) -> JsonValue {
  object([
    #("kind", string(i.kind)),
    #("provenance", string(i.provenance)),
    #("revision", nat_to_json(i.revision)),
  ])
}

fn decode_request_footprint(value: JsonValue) -> D(rp.RequestFootprint) {
  use reads_arr <- try(arr_field(value, "reads"))
  use reads <- try(decode_support.map_list(reads_arr, as_str))
  use writes_arr <- try(arr_field(value, "writes"))
  use writes <- try(decode_support.map_list(writes_arr, as_str))
  use effect_class_json <- try(obj_val(value, "effectClass"))
  use effect_class <- try(decode_request_effect_class(effect_class_json))
  Ok(rp.RequestFootprint(reads, writes, effect_class))
}

fn encode_request_footprint(f: rp.RequestFootprint) -> JsonValue {
  object([
    #("reads", array(list.map(f.reads, string))),
    #("writes", array(list.map(f.writes, string))),
    #("effectClass", encode_request_effect_class(f.effect_class)),
  ])
}

fn decode_resource_demand(value: JsonValue) -> D(rp.ResourceDemand) {
  use pending <- try(nat_field(value, "pending"))
  use in_flight <- try(nat_field(value, "inFlight"))
  use concurrent <- try(nat_field(value, "concurrent"))
  Ok(rp.ResourceDemand(pending, in_flight, concurrent))
}

fn encode_resource_demand(d: rp.ResourceDemand) -> JsonValue {
  object([
    #("pending", nat_to_json(d.pending)),
    #("inFlight", nat_to_json(d.in_flight)),
    #("concurrent", nat_to_json(d.concurrent)),
  ])
}

fn decode_configured_safety_limit(
  value: JsonValue,
) -> D(rp.ConfiguredSafetyLimit) {
  use resource <- try(str_field(value, "resource"))
  use maximum <- try(nat_field(value, "maximum"))
  Ok(rp.ConfiguredSafetyLimit(resource, maximum))
}

fn encode_configured_safety_limit(l: rp.ConfiguredSafetyLimit) -> JsonValue {
  object([
    #("resource", string(l.resource)),
    #("maximum", nat_to_json(l.maximum)),
  ])
}

pub fn decode_resource_budget(value: JsonValue) -> D(rp.ResourceBudget) {
  use pending_json <- try(obj_val(value, "pendingMaximum"))
  use pending <- try(decode_configured_safety_limit(pending_json))
  use in_flight_json <- try(obj_val(value, "inFlightMaximum"))
  use in_flight <- try(decode_configured_safety_limit(in_flight_json))
  use concurrent_json <- try(obj_val(value, "concurrentMaximum"))
  use concurrent <- try(decode_configured_safety_limit(concurrent_json))
  Ok(rp.ResourceBudget(pending, in_flight, concurrent))
}

pub fn encode_resource_budget(b: rp.ResourceBudget) -> JsonValue {
  object([
    #("pendingMaximum", encode_configured_safety_limit(b.pending_maximum)),
    #("inFlightMaximum", encode_configured_safety_limit(b.in_flight_maximum)),
    #("concurrentMaximum", encode_configured_safety_limit(b.concurrent_maximum)),
  ])
}

fn decode_evidence_version(value: JsonValue) -> D(rp.EvidenceVersion) {
  use identifier <- try(str_field(value, "identifier"))
  use digest <- try(str_field(value, "digest"))
  use artifact_path <- try(str_field(value, "artifactPath"))
  Ok(rp.EvidenceVersion(identifier, digest, artifact_path))
}

fn encode_evidence_version(e: rp.EvidenceVersion) -> JsonValue {
  object([
    #("identifier", string(e.identifier)),
    #("digest", string(e.digest)),
    #("artifactPath", string(e.artifact_path)),
  ])
}

fn decode_permission_denial(value: JsonValue) -> D(rp.PermissionDenial) {
  use s <- try(as_str(value))
  Ok(rp.Denial(s))
}

fn encode_permission_denial(value: rp.PermissionDenial) -> JsonValue {
  let rp.Denial(s) = value
  string(s)
}

fn decode_meaning_permission(value: JsonValue) -> D(rp.MeaningPermission) {
  use tag <- try(str_field(value, "tag"))
  use identity_json <- try(obj_val(value, "identity"))
  use identity <- try(decode_request_identity(identity_json))
  case tag {
    "permitted" -> {
      use evidence_json <- try(arr_field(value, "evidence"))
      use evidence <- try(decode_support.map_list(
        evidence_json,
        decode_evidence_version,
      ))
      Ok(rp.Permitted(identity, evidence))
    }
    "ordered" -> {
      use evidence_json <- try(arr_field(value, "evidence"))
      use evidence <- try(decode_support.map_list(
        evidence_json,
        decode_evidence_version,
      ))
      Ok(rp.Ordered(identity, evidence))
    }
    "denied" -> {
      use reason_json <- try(obj_val(value, "reason"))
      use reason <- try(decode_permission_denial(reason_json))
      Ok(rp.Denied(identity, reason))
    }
    other -> Error(fail_shape("unknown meaning permission tag " <> other))
  }
}

fn encode_meaning_permission(value: rp.MeaningPermission) -> JsonValue {
  case value {
    rp.Permitted(identity, evidence) ->
      object([
        #("tag", string("permitted")),
        #("identity", encode_request_identity(identity)),
        #("evidence", array(list.map(evidence, encode_evidence_version))),
      ])
    rp.Ordered(identity, evidence) ->
      object([
        #("tag", string("ordered")),
        #("identity", encode_request_identity(identity)),
        #("evidence", array(list.map(evidence, encode_evidence_version))),
      ])
    rp.Denied(identity, reason) ->
      object([
        #("tag", string("denied")),
        #("identity", encode_request_identity(identity)),
        #("reason", encode_permission_denial(reason)),
      ])
  }
}

fn decode_execution_handle(value: JsonValue) -> D(rp.ExecutionHandle) {
  use s <- try(as_str(value))
  Ok(rp.ExecutionHandle(s))
}

fn encode_execution_handle(h: rp.ExecutionHandle) -> JsonValue {
  string(h.value)
}

pub fn decode_cost_selection(value: JsonValue) -> D(rp.CostSelection) {
  use tag <- try(str_field(value, "tag"))
  use identity <- try(
    obj_val(value, "identity") |> result.try(decode_request_identity),
  )
  use evidence <- try(
    obj_val(value, "evidence") |> result.try(decode_evidence_version),
  )
  use cost <- try(nat_field(value, "cost"))
  case tag {
    "executeNow" -> Ok(rp.ExecuteNow(identity, evidence, cost))
    "remainPending" -> Ok(rp.RemainPending(identity, evidence, cost))
    other -> Error(fail_shape("unknown cost selection tag " <> other))
  }
}

fn encode_cost_selection(value: rp.CostSelection) -> JsonValue {
  case value {
    rp.ExecuteNow(identity, evidence, cost) ->
      object([
        #("tag", string("executeNow")),
        #("identity", encode_request_identity(identity)),
        #("evidence", encode_evidence_version(evidence)),
        #("cost", nat_to_json(cost)),
      ])
    rp.RemainPending(identity, evidence, cost) ->
      object([
        #("tag", string("remainPending")),
        #("identity", encode_request_identity(identity)),
        #("evidence", encode_evidence_version(evidence)),
        #("cost", nat_to_json(cost)),
      ])
  }
}

fn decode_request_entry(value: JsonValue) -> D(rp.RequestEntry) {
  use identity <- try(
    obj_val(value, "identity") |> result.try(decode_request_identity),
  )
  use footprint <- try(
    obj_val(value, "footprint") |> result.try(decode_request_footprint),
  )
  use demand <- try(
    obj_val(value, "demand") |> result.try(decode_resource_demand),
  )
  use phase <- try(obj_val(value, "phase") |> result.try(decode_request_phase))
  use permission <- try(
    obj_val(value, "meaningPermission") |> result.try(decode_meaning_permission),
  )
  use selection_json <- try(obj_val(value, "costSelection"))
  use selection <- try(case is_null(selection_json) {
    True -> Ok(None)
    False -> decode_cost_selection(selection_json) |> result.map(Some)
  })
  use handle_json <- try(obj_val(value, "executionHandle"))
  use handle <- try(case is_null(handle_json) {
    True -> Ok(None)
    False -> decode_execution_handle(handle_json) |> result.map(Some)
  })
  Ok(rp.RequestEntry(
    identity,
    footprint,
    demand,
    phase,
    permission,
    selection,
    handle,
  ))
}

fn encode_request_entry(e: rp.RequestEntry) -> JsonValue {
  object([
    #("identity", encode_request_identity(e.identity)),
    #("footprint", encode_request_footprint(e.footprint)),
    #("demand", encode_resource_demand(e.demand)),
    #("phase", encode_request_phase(e.phase)),
    #("meaningPermission", encode_meaning_permission(e.meaning_permission)),
    #("costSelection", case e.cost_selection {
      None -> json_value.JNull
      Some(s) -> encode_cost_selection(s)
    }),
    #("executionHandle", case e.execution_handle {
      None -> json_value.JNull
      Some(h) -> encode_execution_handle(h)
    }),
  ])
}

pub fn decode_snapshot(value: JsonValue) -> D(rp.RequestProgressionSnapshot) {
  use policy_json <- try(obj_val(value, "policy"))
  use policy <- try(decode_request_policy(policy_json))
  use budget_json <- try(obj_val(value, "budget"))
  use budget <- try(decode_resource_budget(budget_json))
  use current_json <- try(obj_val(value, "currentIdentity"))
  use current <- try(case is_null(current_json) {
    True -> Ok(None)
    False -> decode_request_identity(current_json) |> result.map(Some)
  })
  use entries_json <- try(arr_field(value, "entries"))
  use entries <- try(decode_support.map_list(entries_json, decode_request_entry))
  use revision <- try(nat_field(value, "revision"))
  Ok(rp.RequestProgressionSnapshot(policy, budget, current, entries, revision))
}

pub fn encode_snapshot(s: rp.RequestProgressionSnapshot) -> JsonValue {
  object([
    #("policy", encode_request_policy(s.policy)),
    #("budget", encode_resource_budget(s.budget)),
    #("currentIdentity", case s.current_identity {
      None -> json_value.JNull
      Some(i) -> encode_request_identity(i)
    }),
    #("entries", array(list.map(s.entries, encode_request_entry))),
    #("revision", nat_to_json(s.revision)),
  ])
}

pub fn decode_request_input(value: JsonValue) -> D(rp.RequestInput) {
  use identity <- try(
    obj_val(value, "identity") |> result.try(decode_request_identity),
  )
  use footprint <- try(
    obj_val(value, "footprint") |> result.try(decode_request_footprint),
  )
  use demand <- try(
    obj_val(value, "demand") |> result.try(decode_resource_demand),
  )
  use permission <- try(
    obj_val(value, "permission") |> result.try(decode_meaning_permission),
  )
  Ok(rp.RequestInput(identity, footprint, demand, permission))
}

pub fn decode_accepted(value: JsonValue) -> D(rp.Accepted) {
  use identity <- try(
    obj_val(value, "identity") |> result.try(decode_request_identity),
  )
  Ok(rp.Accepted(identity))
}

fn encode_accepted(a: rp.Accepted) -> JsonValue {
  object([#("identity", encode_request_identity(a.identity))])
}

pub fn decode_running(value: JsonValue) -> D(rp.Running) {
  use identity <- try(
    obj_val(value, "identity") |> result.try(decode_request_identity),
  )
  use handle <- try(
    obj_val(value, "handle") |> result.try(decode_execution_handle),
  )
  Ok(rp.Running(identity, handle))
}

fn encode_running(r: rp.Running) -> JsonValue {
  object([
    #("identity", encode_request_identity(r.identity)),
    #("handle", encode_execution_handle(r.handle)),
  ])
}

fn decode_starting(value: JsonValue) -> D(rp.Starting) {
  use identity <- try(
    obj_val(value, "identity") |> result.try(decode_request_identity),
  )
  use command <- try(
    obj_val(value, "command") |> result.try(decode_adapter_command),
  )
  Ok(rp.Starting(identity, command))
}

fn encode_starting(s: rp.Starting) -> JsonValue {
  object([
    #("identity", encode_request_identity(s.identity)),
    #("command", encode_adapter_command(s.command)),
  ])
}

fn encode_adapter_command(value: rp.AdapterCommand) -> JsonValue {
  case value {
    rp.StartCommand(identity, footprint) ->
      object([
        #("tag", string("startCommand")),
        #("identity", encode_request_identity(identity)),
        #("footprint", encode_request_footprint(footprint)),
      ])
    rp.CancelCommand(identity, handle) ->
      object([
        #("tag", string("cancelCommand")),
        #("identity", encode_request_identity(identity)),
        #("handle", encode_execution_handle(handle)),
      ])
  }
}

fn decode_adapter_command(value: JsonValue) -> D(rp.AdapterCommand) {
  use tag <- try(str_field(value, "tag"))
  use identity <- try(
    obj_val(value, "identity") |> result.try(decode_request_identity),
  )
  case tag {
    "startCommand" -> {
      use footprint <- try(
        obj_val(value, "footprint") |> result.try(decode_request_footprint),
      )
      Ok(rp.StartCommand(identity, footprint))
    }
    "cancelCommand" -> {
      use handle <- try(
        obj_val(value, "handle") |> result.try(decode_execution_handle),
      )
      Ok(rp.CancelCommand(identity, handle))
    }
    other -> Error(fail_shape("unknown adapter command tag " <> other))
  }
}

fn decode_adapter_signal(value: JsonValue) -> D(rp.AdapterSignal(JsonValue)) {
  use tag <- try(str_field(value, "tag"))
  use identity <- try(
    obj_val(value, "identity") |> result.try(decode_request_identity),
  )
  use handle <- try(
    obj_val(value, "handle") |> result.try(decode_execution_handle),
  )
  case tag {
    "started" -> Ok(rp.Started(identity, handle))
    "completed" -> {
      use result <- try(obj_val(value, "value"))
      Ok(rp.Completed(identity, handle, result))
    }
    "cancelledAtAdapter" -> Ok(rp.CancelledAtAdapter(identity, handle))
    other -> Error(fail_shape("unknown adapter signal tag " <> other))
  }
}

fn decode_adapter_failure(value: JsonValue) -> D(rp.AdapterFailure) {
  use tag <- try(str_field(value, "tag"))
  use identity <- try(
    obj_val(value, "identity") |> result.try(decode_request_identity),
  )
  case tag {
    "startAdapterFailure" -> {
      use detail <- try(str_field(value, "detail"))
      Ok(rp.StartAdapterFailure(identity, detail))
    }
    "completionAdapterFailure" -> {
      use handle <- try(
        obj_val(value, "handle") |> result.try(decode_execution_handle),
      )
      use detail <- try(str_field(value, "detail"))
      Ok(rp.CompletionAdapterFailure(identity, handle, detail))
    }
    "cancellationAdapterFailure" -> {
      use handle <- try(
        obj_val(value, "handle") |> result.try(decode_execution_handle),
      )
      use detail <- try(str_field(value, "detail"))
      Ok(rp.CancellationAdapterFailure(identity, handle, detail))
    }
    other -> Error(fail_shape("unknown adapter failure tag " <> other))
  }
}

pub fn decode_adapter_result(
  value: JsonValue,
) -> D(rp.AdapterResult(JsonValue)) {
  use tag <- try(str_field(value, "tag"))
  case tag {
    "appliedSignal" -> {
      use signal <- try(
        obj_val(value, "signal") |> result.try(decode_adapter_signal),
      )
      Ok(rp.AppliedSignal(signal))
    }
    "adapterFailed" -> {
      use failure <- try(
        obj_val(value, "failure") |> result.try(decode_adapter_failure),
      )
      Ok(rp.AdapterFailed(failure))
    }
    other -> Error(fail_shape("unknown adapter result tag " <> other))
  }
}

pub fn encode_submit_failure(value: rp.SubmitFailure) -> JsonValue {
  case value {
    rp.SubmitDuplicateIdentity(identity) ->
      object([
        #("tag", string("duplicateIdentity")),
        #("identity", encode_request_identity(identity)),
      ])
    rp.SubmitPendingLimitExceeded(demand, budget) ->
      object([
        #("tag", string("pendingLimitExceeded")),
        #("demand", encode_resource_demand(demand)),
        #("budget", encode_resource_budget(budget)),
      ])
  }
}

fn encode_submit_result(value: rp.SubmitResult) -> JsonValue {
  case value {
    rp.SubmitAccepted(snapshot, accepted) ->
      object([
        #("tag", string("accepted")),
        #("snapshot", encode_snapshot(snapshot)),
        #("accepted", encode_accepted(accepted)),
      ])
    rp.SubmitRejected(snapshot, failure) ->
      object([
        #("tag", string("submitRejected")),
        #("snapshot", encode_snapshot(snapshot)),
        #("failure", encode_submit_failure(failure)),
      ])
  }
}

pub fn encode_start_decision_failure(
  value: rp.StartDecisionFailure,
) -> JsonValue {
  case value {
    rp.StartUnknownRequest(i) -> identity_failure("unknownRequest", i)
    rp.StartRequestNotPending(i) -> identity_failure("requestNotPending", i)
    rp.StartPolicyOrderBlocked(i) -> identity_failure("policyOrderBlocked", i)
    rp.StartPermissionDenied(i, r) ->
      object([
        #("tag", string("permissionDenied")),
        #("identity", encode_request_identity(i)),
        #("reason", encode_permission_denial(r)),
      ])
    rp.StartPermissionIdentityMismatch(a, b) ->
      mismatch_failure("permissionIdentityMismatch", a, b)
    rp.StartPermissionNotOrdered(i) ->
      identity_failure("permissionNotOrdered", i)
    rp.StartCostSelectionIdentityMismatch(a, b) ->
      mismatch_failure("costSelectionIdentityMismatch", a, b)
    rp.StartInFlightLimitExceeded(d, b) ->
      budget_failure("inFlightLimitExceeded", d, b)
    rp.StartConcurrentLimitExceeded(d, b) ->
      budget_failure("concurrentLimitExceeded", d, b)
  }
}

fn identity_failure(tag: String, identity: rp.RequestIdentity) -> JsonValue {
  object([
    #("tag", string(tag)),
    #("identity", encode_request_identity(identity)),
  ])
}

fn mismatch_failure(
  tag: String,
  a: rp.RequestIdentity,
  b: rp.RequestIdentity,
) -> JsonValue {
  object([
    #("tag", string(tag)),
    #("identity", encode_request_identity(a)),
    #("other", encode_request_identity(b)),
  ])
}

fn budget_failure(
  tag: String,
  demand: rp.ResourceDemand,
  budget: rp.ResourceBudget,
) -> JsonValue {
  object([
    #("tag", string(tag)),
    #("demand", encode_resource_demand(demand)),
    #("budget", encode_resource_budget(budget)),
  ])
}

pub fn encode_start_decision_result(
  value: rp.StartDecisionResult,
) -> JsonValue {
  case value {
    rp.Execute(snapshot, starting, command) ->
      object([
        #("tag", string("execute")),
        #("snapshot", encode_snapshot(snapshot)),
        #("starting", encode_starting(starting)),
        #("command", encode_adapter_command(command)),
      ])
    rp.Deferred(snapshot, accepted) ->
      object([
        #("tag", string("deferred")),
        #("snapshot", encode_snapshot(snapshot)),
        #("accepted", encode_accepted(accepted)),
      ])
    rp.StartDecisionRejected(snapshot, failure) ->
      object([
        #("tag", string("rejected")),
        #("snapshot", encode_snapshot(snapshot)),
        #("failure", encode_start_decision_failure(failure)),
      ])
  }
}

fn encode_start_observation_failure(
  value: rp.StartObservationFailure,
) -> JsonValue {
  case value {
    rp.StartObservationUnknownRequest(i) ->
      identity_failure("unknownRequest", i)
    rp.StartRequestNotStarting(i) -> identity_failure("requestNotStarting", i)
    rp.StartIdentityMismatch(a, b) ->
      mismatch_failure("startIdentityMismatch", a, b)
    rp.StartSignalMismatch(i) -> identity_failure("startSignalMismatch", i)
    rp.StartAdapterFailureObserved(i, detail) ->
      object([
        #("tag", string("startAdapterFailureObserved")),
        #("identity", encode_request_identity(i)),
        #("detail", string(detail)),
      ])
  }
}

fn encode_start_observation_result(
  value: rp.StartObservationResult,
) -> JsonValue {
  case value {
    rp.StartObservationPublishing(snapshot, running) ->
      object([
        #("tag", string("publishing")),
        #("snapshot", encode_snapshot(snapshot)),
        #("running", encode_running(running)),
      ])
    rp.StartObservationFailed(snapshot, failure) ->
      object([
        #("tag", string("failed")),
        #("snapshot", encode_snapshot(snapshot)),
        #("failure", encode_start_observation_failure(failure)),
      ])
  }
}

fn encode_completion_observation_failure(
  value: rp.CompletionObservationFailure,
) -> JsonValue {
  case value {
    rp.CompletionUnknown(i) -> identity_failure("unknownCompletion", i)
    rp.CompletionNotRunning(i) -> identity_failure("completionNotRunning", i)
    rp.CompletionHandleMismatch(i) -> identity_failure("handleMismatch", i)
    rp.CompletionIdentityMismatch(a, b) ->
      mismatch_failure("completionIdentityMismatch", a, b)
    rp.CompletionSignalMismatch(i) ->
      identity_failure("completionSignalMismatch", i)
    rp.CompletionAdapterFailureObserved(i, detail) ->
      object([
        #("tag", string("completionAdapterFailureObserved")),
        #("identity", encode_request_identity(i)),
        #("detail", string(detail)),
      ])
    rp.CancellationAdapterFailureObserved(i, detail) ->
      object([
        #("tag", string("cancellationAdapterFailureObserved")),
        #("identity", encode_request_identity(i)),
        #("detail", string(detail)),
      ])
  }
}

fn encode_completion_observation_result(
  value: rp.CompletionObservationResult(JsonValue),
) -> JsonValue {
  case value {
    rp.CompletionApplied(snapshot, identity, result) ->
      object([
        #("tag", string("applied")),
        #("snapshot", encode_snapshot(snapshot)),
        #("identity", encode_request_identity(identity)),
        #("value", result),
      ])
    rp.CompletionSuperseded(snapshot, identity) ->
      object([
        #("tag", string("superseded")),
        #("snapshot", encode_snapshot(snapshot)),
        #("identity", encode_request_identity(identity)),
      ])
    rp.CompletionCancelled(snapshot, identity) ->
      object([
        #("tag", string("cancelled")),
        #("snapshot", encode_snapshot(snapshot)),
        #("identity", encode_request_identity(identity)),
      ])
    rp.CompletionObservationFailed(snapshot, failure) ->
      object([
        #("tag", string("failed")),
        #("snapshot", encode_snapshot(snapshot)),
        #("failure", encode_completion_observation_failure(failure)),
      ])
  }
}

fn encode_cancel_failure(value: rp.CancelFailure) -> JsonValue {
  case value {
    rp.CancelUnknownRequest(i) -> identity_failure("unknownRequest", i)
    rp.CancelRequestAlreadyTerminal(i) ->
      identity_failure("requestAlreadyTerminal", i)
    rp.CancelMissingExecutionHandle(i) ->
      identity_failure("missingExecutionHandle", i)
  }
}

fn encode_cancel_decision_result(value: rp.CancelDecisionResult) -> JsonValue {
  case value {
    rp.CancelledDecision(snapshot, identity) ->
      object([
        #("tag", string("cancelled")),
        #("snapshot", encode_snapshot(snapshot)),
        #("identity", encode_request_identity(identity)),
      ])
    rp.CancelCommandDecision(snapshot, running, command) ->
      object([
        #("tag", string("cancelCommand")),
        #("snapshot", encode_snapshot(snapshot)),
        #("running", encode_running(running)),
        #("command", encode_adapter_command(command)),
      ])
    rp.CancelDecisionRejected(snapshot, failure) ->
      object([
        #("tag", string("rejected")),
        #("snapshot", encode_snapshot(snapshot)),
        #("failure", encode_cancel_failure(failure)),
      ])
  }
}

pub fn op_request_progression_empty(input: JsonValue) -> D(JsonValue) {
  use policy <- try(
    obj_val(input, "policy") |> result.try(decode_request_policy),
  )
  use budget <- try(
    obj_val(input, "budget") |> result.try(decode_resource_budget),
  )
  Ok(encode_snapshot(rp.empty(policy, budget)))
}

pub fn op_request_progression_submit(input: JsonValue) -> D(JsonValue) {
  use snapshot <- try(obj_val(input, "snapshot") |> result.try(decode_snapshot))
  use request <- try(
    obj_val(input, "request") |> result.try(decode_request_input),
  )
  Ok(encode_submit_result(rp.submit(snapshot, request)))
}

pub fn op_request_progression_decide_start(input: JsonValue) -> D(JsonValue) {
  use snapshot <- try(obj_val(input, "snapshot") |> result.try(decode_snapshot))
  use accepted <- try(obj_val(input, "accepted") |> result.try(decode_accepted))
  use selection <- try(
    obj_val(input, "selection") |> result.try(decode_cost_selection),
  )
  Ok(
    encode_start_decision_result(rp.decide_start(snapshot, accepted, selection)),
  )
}

pub fn op_request_progression_apply_start_observation(
  input: JsonValue,
) -> D(JsonValue) {
  use snapshot <- try(obj_val(input, "snapshot") |> result.try(decode_snapshot))
  use starting <- try(obj_val(input, "starting") |> result.try(decode_starting))
  use observed <- try(
    obj_val(input, "observed") |> result.try(decode_adapter_result),
  )
  Ok(
    encode_start_observation_result(rp.apply_start_observation(
      snapshot,
      starting,
      observed,
    )),
  )
}

pub fn op_request_progression_apply_completion_observation(
  input: JsonValue,
) -> D(JsonValue) {
  use snapshot <- try(obj_val(input, "snapshot") |> result.try(decode_snapshot))
  use running <- try(obj_val(input, "running") |> result.try(decode_running))
  use observed <- try(
    obj_val(input, "observed") |> result.try(decode_adapter_result),
  )
  Ok(
    encode_completion_observation_result(rp.apply_completion_observation(
      snapshot,
      running,
      observed,
    )),
  )
}

pub fn op_request_progression_decide_cancel(input: JsonValue) -> D(JsonValue) {
  use snapshot <- try(obj_val(input, "snapshot") |> result.try(decode_snapshot))
  use identity <- try(
    obj_val(input, "identity") |> result.try(decode_request_identity),
  )
  Ok(encode_cancel_decision_result(rp.decide_cancel(snapshot, identity)))
}

pub fn op_request_progression_derive_pending(input: JsonValue) -> D(JsonValue) {
  use snapshot <- try(obj_val(input, "snapshot") |> result.try(decode_snapshot))
  Ok(encode_resource_demand(rp.derive_pending(snapshot)))
}

pub fn op_request_progression_derive_in_flight(
  input: JsonValue,
) -> D(JsonValue) {
  use snapshot <- try(obj_val(input, "snapshot") |> result.try(decode_snapshot))
  Ok(encode_resource_demand(rp.derive_in_flight(snapshot)))
}

pub fn op_request_progression_derive_concurrent(
  input: JsonValue,
) -> D(JsonValue) {
  use snapshot <- try(obj_val(input, "snapshot") |> result.try(decode_snapshot))
  Ok(encode_resource_demand(rp.derive_concurrent(snapshot)))
}
