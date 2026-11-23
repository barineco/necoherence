// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import feature_check/call_ops
import feature_check/core_ops
import feature_check/decode_support.{
  type DecodeFailure, DecodeFailure, JsonSyntax, QueryShape, UnknownFeature,
  UnknownOperation, failure_kind_str, obj_val, str_field, try,
}
import feature_check/dynamic_admission_ops
import feature_check/file_effect_ops
import feature_check/iteration_ops
import feature_check/json_value.{
  type JsonValue, JArray, JObject, JString, array, object, parse, string,
  to_json_string,
}
import feature_check/reconcile_ops
import feature_check/record_ops
import feature_check/request_progression_ops
import feature_check/step_transition_ops
import feature_check/store_ops
import gleam/list

@external(erlang, "feature_check_ffi", "read_stdin")
fn read_stdin() -> String

@external(erlang, "feature_check_ffi", "print_line")
fn print_line(text: String) -> Nil

/// The finite feature/operation inventory in a fixed order, matching the
/// Lean FeatureCheck adapter exactly.
pub fn surface_entries() -> List(#(String, List(String))) {
  [
    #("core", ["lookup", "bump", "commandOf", "apply"]),
    #("call", ["immediateOf", "deferredOf", "io", "issue"]),
    #("iteration", ["fold", "recurse", "closure"]),
    #("store", ["storeOf", "storeEntries", "observe", "apply", "worldOf"]),
    #("record", ["recordOf", "recordOnBasis", "hasEdge"]),
    #("reconcile", ["reconcile", "coherent"]),
    #("request_progression", [
      "empty", "submit", "decideStart", "applyStartObservation",
      "applyCompletionObservation", "decideCancel", "derivePending",
      "deriveInFlight", "deriveConcurrent",
    ]),
    #("dynamic_admission", ["elideAdmissionProvenance", "admitDynamicRequest"]),
    #("step_transition", ["step"]),
    #("file_effect", [
      "normalizePath",
      "lookupDigest",
      "setDigest",
      "track",
      "read",
      "replace",
    ]),
  ]
}

fn known_features() -> List(String) {
  list.map(surface_entries(), fn(e) { e.0 })
}

fn surface_json() -> JsonValue {
  object([
    #("kind", string("surface")),
    #(
      "features",
      array(
        list.map(surface_entries(), fn(entry) {
          object([
            #("feature", string(entry.0)),
            #("operations", array(list.map(entry.1, string))),
          ])
        }),
      ),
    ),
  ])
}

fn dispatch(
  feature: String,
  operation: String,
  input: JsonValue,
) -> decode_support.D(JsonValue) {
  case feature, operation {
    "core", "lookup" -> core_ops.op_core_lookup(input)
    "core", "bump" -> core_ops.op_core_bump(input)
    "core", "commandOf" -> core_ops.op_core_command_of(input)
    "core", "apply" -> core_ops.op_core_apply(input)
    "call", "immediateOf" -> call_ops.op_call_immediate_of(input)
    "call", "deferredOf" -> call_ops.op_call_deferred_of(input)
    "call", "io" -> call_ops.op_call_io(input)
    "call", "issue" -> call_ops.op_call_issue(input)
    "iteration", "fold" -> iteration_ops.op_iteration_fold(input)
    "iteration", "recurse" -> iteration_ops.op_iteration_recurse(input)
    "iteration", "closure" -> iteration_ops.op_iteration_closure(input)
    "store", "storeOf" -> store_ops.op_store_store_of(input)
    "store", "storeEntries" -> store_ops.op_store_store_entries(input)
    "store", "observe" -> store_ops.op_store_observe(input)
    "store", "apply" -> store_ops.op_store_apply(input)
    "store", "worldOf" -> store_ops.op_store_world_of(input)
    "record", "recordOf" -> record_ops.op_record_record_of(input)
    "record", "recordOnBasis" -> record_ops.op_record_record_on_basis(input)
    "record", "hasEdge" -> record_ops.op_record_has_edge(input)
    "reconcile", "reconcile" -> reconcile_ops.op_reconcile_reconcile(input)
    "reconcile", "coherent" -> reconcile_ops.op_reconcile_coherent(input)
    "request_progression", "empty" ->
      request_progression_ops.op_request_progression_empty(input)
    "request_progression", "submit" ->
      request_progression_ops.op_request_progression_submit(input)
    "request_progression", "decideStart" ->
      request_progression_ops.op_request_progression_decide_start(input)
    "request_progression", "applyStartObservation" ->
      request_progression_ops.op_request_progression_apply_start_observation(
        input,
      )
    "request_progression", "applyCompletionObservation" ->
      request_progression_ops.op_request_progression_apply_completion_observation(
        input,
      )
    "request_progression", "decideCancel" ->
      request_progression_ops.op_request_progression_decide_cancel(input)
    "request_progression", "derivePending" ->
      request_progression_ops.op_request_progression_derive_pending(input)
    "request_progression", "deriveInFlight" ->
      request_progression_ops.op_request_progression_derive_in_flight(input)
    "request_progression", "deriveConcurrent" ->
      request_progression_ops.op_request_progression_derive_concurrent(input)
    "dynamic_admission", "elideAdmissionProvenance" ->
      dynamic_admission_ops.op_dynamic_admission_elide_admission_provenance(
        input,
      )
    "dynamic_admission", "admitDynamicRequest" ->
      dynamic_admission_ops.op_dynamic_admission_admit_dynamic_request(input)
    "step_transition", "step" ->
      step_transition_ops.op_step_transition_step(input)
    "file_effect", "normalizePath" ->
      file_effect_ops.op_file_effect_normalize_path(input)
    "file_effect", "lookupDigest" ->
      file_effect_ops.op_file_effect_lookup_digest(input)
    "file_effect", "setDigest" ->
      file_effect_ops.op_file_effect_set_digest(input)
    "file_effect", "track" -> file_effect_ops.op_file_effect_track(input)
    "file_effect", "read" -> file_effect_ops.op_file_effect_read(input)
    "file_effect", "replace" -> file_effect_ops.op_file_effect_replace(input)
    _, _ ->
      case list.contains(known_features(), feature) {
        True ->
          Error(DecodeFailure(UnknownOperation, feature <> "." <> operation))
        False -> Error(DecodeFailure(UnknownFeature, feature))
      }
  }
}

fn process_request(value: JsonValue) -> decode_support.D(JsonValue) {
  use feature <- try(str_field(value, "feature"))
  use operation <- try(str_field(value, "operation"))
  use input <- try(obj_val(value, "input"))
  use result <- try(dispatch(feature, operation, input))
  Ok(
    object([
      #("feature", string(feature)),
      #("operation", string(operation)),
      #("result", result),
    ]),
  )
}

fn top_kind(value: JsonValue) -> decode_support.D(String) {
  case value {
    JObject(fields) ->
      case list.find(fields, fn(entry) { entry.0 == "kind" }) {
        Ok(#(_, JString(s))) -> Ok(s)
        _ ->
          Error(DecodeFailure(QueryShape, "missing or invalid top-level kind"))
      }
    _ -> Error(DecodeFailure(QueryShape, "missing or invalid top-level kind"))
  }
}

fn decode_query(value: JsonValue) -> decode_support.D(JsonValue) {
  use kind <- try(top_kind(value))
  case kind {
    "surface" -> Ok(surface_json())
    "evaluate" ->
      case value {
        JObject(fields) ->
          case list.find(fields, fn(entry) { entry.0 == "requests" }) {
            Ok(#(_, JArray(items))) -> {
              use results <- try(decode_support.map_list(items, process_request))
              Ok(
                object([
                  #("kind", string("results")),
                  #("results", array(results)),
                ]),
              )
            }
            _ ->
              Error(DecodeFailure(
                QueryShape,
                "missing or invalid requests array",
              ))
          }
        _ ->
          Error(DecodeFailure(QueryShape, "missing or invalid requests array"))
      }
    other -> Error(DecodeFailure(QueryShape, "unknown query kind " <> other))
  }
}

fn render_invalid(f: DecodeFailure) -> JsonValue {
  object([
    #("kind", string("invalid")),
    #(
      "failure",
      object([
        #("kind", string(failure_kind_str(f.kind))),
        #("detail", string(f.detail)),
      ]),
    ),
  ])
}

fn run(input: String) -> JsonValue {
  case parse(input) {
    Error(msg) -> render_invalid(DecodeFailure(JsonSyntax, msg))
    Ok(value) ->
      case decode_query(value) {
        Ok(result) -> result
        Error(f) -> render_invalid(f)
      }
  }
}

pub fn main() -> Nil {
  print_line(to_json_string(run(read_stdin())))
}
