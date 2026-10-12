// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import feature_check/call_ops.{apply_function_form, decode_function_form}
import feature_check/decode_support.{
  type D, arr_field, as_arr, as_str, fail_shape, nat_field, nat_to_json, obj_val,
  str_field, try,
}
import feature_check/json_value.{
  type JsonValue, JArray, JNull, array, object, string, to_json_string,
}
import gleam/list
import necoherence/call
import necoherence/iteration

fn encode_stage_projection_failed(
  s: iteration.StageProjectionFailed,
) -> JsonValue {
  object([
    #("position", nat_to_json(s.position)),
    #("declaration", string(s.failure.declaration)),
    #("fields", array(list.map(s.failure.fields, string))),
  ])
}

pub fn decode_fold_req(value: JsonValue) -> D(iteration.FoldReq(JsonValue)) {
  use step_json <- try(obj_val(value, "step"))
  use step <- try(call_ops.decode_immediate(step_json))
  use seed <- try(obj_val(value, "seed"))
  use count <- try(nat_field(value, "count"))
  use fields_arr <- try(arr_field(value, "stepFields"))
  use step_fields <- try(decode_support.map_list(fields_arr, as_str))
  Ok(iteration.FoldReq(step, seed, count, step_fields))
}

fn encode_fold_outcome(value: iteration.FoldOutcome(JsonValue)) -> JsonValue {
  case value {
    iteration.FoldTrace(states) ->
      object([#("tag", string("trace")), #("states", array(states))])
    iteration.FoldStopped(states, stopped) ->
      object([
        #("tag", string("stopped")),
        #("states", array(states)),
        #("stopped", encode_stage_projection_failed(stopped)),
      ])
  }
}

pub type StepOutcomeForm {
  FormSettled
  FormAdvance(measure: Int)
}

fn decode_step_outcome_form(value: JsonValue) -> D(StepOutcomeForm) {
  use tag <- try(str_field(value, "tag"))
  case tag {
    "settled" -> Ok(FormSettled)
    "advance" -> {
      use m <- try(nat_field(value, "measure"))
      Ok(FormAdvance(m))
    }
    other -> Error(fail_shape("unknown step outcome tag " <> other))
  }
}

fn decode_recurse_table(
  value: JsonValue,
) -> D(List(#(JsonValue, StepOutcomeForm))) {
  use arr <- try(as_arr(value))
  decode_support.map_list(arr, fn(entry) {
    use payload <- try(obj_val(entry, "payload"))
    use outcome_json <- try(obj_val(entry, "outcome"))
    use form <- try(decode_step_outcome_form(outcome_json))
    Ok(#(payload, form))
  })
}

fn recurse_step_output(
  table: List(#(JsonValue, StepOutcomeForm)),
  next_of: fn(JsonValue) -> JsonValue,
  state: JsonValue,
) -> iteration.StepOutcome(JsonValue) {
  case list.find(table, fn(entry) { entry.0 == state }) {
    Ok(#(_, FormSettled)) -> iteration.Settled(state)
    Ok(#(_, FormAdvance(m))) -> iteration.Advance(next_of(state), m)
    Error(_) -> iteration.Settled(state)
  }
}

pub fn decode_recurse_req(
  value: JsonValue,
) -> D(iteration.RecurseReq(JsonValue)) {
  use required_arr <- try(arr_field(value, "required"))
  use required <- try(decode_support.map_list(required_arr, as_str))
  use table_json <- try(obj_val(value, "table"))
  use table <- try(decode_recurse_table(table_json))
  use next_json <- try(obj_val(value, "next"))
  use next_form <- try(decode_function_form(next_json))
  use seed <- try(obj_val(value, "seed"))
  use fields_arr <- try(arr_field(value, "stepFields"))
  use step_fields <- try(decode_support.map_list(fields_arr, as_str))
  let identity = "necoherence.iteration.recurse.adapter.step"
  let step =
    call.immediate_of(identity, required, recurse_step_output(
      table,
      apply_function_form(next_form, _),
      _,
    ))
  Ok(iteration.RecurseReq(step, seed, step_fields))
}

fn encode_recurse_outcome(
  value: iteration.RecurseOutcome(JsonValue),
) -> JsonValue {
  case value {
    iteration.RecurseSettled(v, steps) ->
      object([
        #("tag", string("settled")),
        #("value", v),
        #("steps", nat_to_json(steps)),
      ])
    iteration.RecurseDidNotDecrease(position, state, measure, prev) ->
      object([
        #("tag", string("did_not_decrease")),
        #("position", nat_to_json(position)),
        #("state", state),
        #("measure", nat_to_json(measure)),
        #("previousMeasure", nat_to_json(prev)),
      ])
    iteration.RecurseProjectionFailed(last_state, stopped) ->
      object([
        #("tag", string("projection_failed")),
        #("lastState", last_state),
        #("stopped", encode_stage_projection_failed(stopped)),
      ])
  }
}

fn json_elements(value: JsonValue) -> List(JsonValue) {
  case value {
    JArray(items) -> items
    _ -> []
  }
}

fn closure_elem_to_json(s: String) -> JsonValue {
  case json_value.parse(s) {
    Ok(v) -> v
    Error(_) -> JNull
  }
}

fn closure_elem_of_json(value: JsonValue) -> String {
  to_json_string(value)
}

pub fn decode_closure_req(value: JsonValue) -> D(iteration.ClosureReq(String)) {
  use step_field_json <- try(obj_val(value, "step"))
  use identity <- try(str_field(step_field_json, "identity"))
  use required_arr <- try(arr_field(step_field_json, "required"))
  use required <- try(decode_support.map_list(required_arr, as_str))
  use output_json <- try(obj_val(step_field_json, "output"))
  use form <- try(decode_function_form(output_json))
  let step =
    call.immediate_of(
      identity,
      required,
      fn(cs: iteration.ClosureState(String)) {
        let elems_json = array(list.map(cs.elements, closure_elem_to_json))
        let produced_json = apply_function_form(form, elems_json)
        list.map(json_elements(produced_json), closure_elem_of_json)
      },
    )
  use carrier_arr <- try(arr_field(value, "carrier"))
  let carrier = list.map(carrier_arr, closure_elem_of_json)
  use seed_arr <- try(arr_field(value, "seed"))
  let seed = list.map(seed_arr, closure_elem_of_json)
  use fields_arr <- try(arr_field(value, "stepFields"))
  use step_fields <- try(decode_support.map_list(fields_arr, as_str))
  Ok(iteration.ClosureReq(step, carrier, seed, step_fields))
}

fn encode_closure_elems(elems: List(String)) -> JsonValue {
  array(list.map(elems, closure_elem_to_json))
}

fn encode_closure_outcome(
  value: iteration.ClosureOutcome(String),
) -> JsonValue {
  case value {
    iteration.Fixpoint(result, position) ->
      object([
        #("tag", string("fixpoint")),
        #("result", encode_closure_elems(result)),
        #("position", nat_to_json(position)),
      ])
    iteration.Violation(position, current, produced) ->
      object([
        #("tag", string("violation")),
        #("position", nat_to_json(position)),
        #("current", encode_closure_elems(current)),
        #("produced", encode_closure_elems(produced)),
      ])
    iteration.ClosureProjectionFailed(current, stopped) ->
      object([
        #("tag", string("projection_failed")),
        #("current", encode_closure_elems(current)),
        #("stopped", encode_stage_projection_failed(stopped)),
      ])
  }
}

pub fn op_iteration_fold(input: JsonValue) -> D(JsonValue) {
  use req <- try(decode_fold_req(input))
  Ok(encode_fold_outcome(iteration.fold(req)))
}

pub fn op_iteration_recurse(input: JsonValue) -> D(JsonValue) {
  use req <- try(decode_recurse_req(input))
  Ok(encode_recurse_outcome(iteration.recurse(req)))
}

pub fn op_iteration_closure(input: JsonValue) -> D(JsonValue) {
  use req <- try(decode_closure_req(input))
  Ok(encode_closure_outcome(iteration.closure(req)))
}
