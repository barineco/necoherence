// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import feature_check/decode_support.{
  type D, arr_field, fail_shape, nat_field, nat_to_json, obj_val, str_field, try,
}
import feature_check/json_value.{type JsonValue, JString, array, object, string}
import necoherence/transition

pub type AdvanceForm {
  ConsumeImmediately(outputs: List(JsonValue))
  ReprocessAlways(outputs: List(JsonValue))
  ConsumeAfter(rounds: Int, outputs_per_round: List(JsonValue))
}

pub fn decode_advance_form(value: JsonValue) -> D(AdvanceForm) {
  use mode <- try(str_field(value, "mode"))
  case mode {
    "consumeImmediately" -> {
      use arr <- try(arr_field(value, "outputs"))
      Ok(ConsumeImmediately(arr))
    }
    "reprocessAlways" -> {
      use arr <- try(arr_field(value, "outputs"))
      Ok(ReprocessAlways(arr))
    }
    "consumeAfter" -> {
      use rounds <- try(nat_field(value, "rounds"))
      use arr <- try(arr_field(value, "outputsPerRound"))
      Ok(ConsumeAfter(rounds, arr))
    }
    other -> Error(fail_shape("unknown advance mode " <> other))
  }
}

fn round_of(state: JsonValue) -> Int {
  case decode_support.obj_val(state, "round") {
    Ok(JString(s)) -> {
      case decode_support.nat_of_str(s) {
        Ok(n) -> n
        Error(_) -> 0
      }
    }
    _ -> 0
  }
}

fn state_with_round(n: Int) -> JsonValue {
  object([#("round", nat_to_json(n))])
}

fn advance_eval(
  form: AdvanceForm,
) -> fn(JsonValue, JsonValue) -> transition.Consumption(JsonValue, JsonValue) {
  fn(state, _input) {
    case form {
      ConsumeImmediately(outputs) -> transition.Consumed(state, outputs)
      ReprocessAlways(outputs) -> transition.Reprocess(state, outputs)
      ConsumeAfter(rounds, outputs) -> {
        let r = round_of(state) + 1
        let new_state = state_with_round(r)
        case r >= rounds {
          True -> transition.Consumed(new_state, outputs)
          False -> transition.Reprocess(new_state, outputs)
        }
      }
    }
  }
}

fn encode_step_failure(value: transition.StepFailure) -> JsonValue {
  case value {
    transition.ReprocessLimitExhausted(n) ->
      object([
        #("tag", string("reprocess_limit_exhausted")),
        #("applications", nat_to_json(n)),
      ])
    transition.CapacityExceeded(c, a) ->
      object([
        #("tag", string("capacity_exceeded")),
        #("capacity", nat_to_json(c)),
        #("attempted", nat_to_json(a)),
      ])
  }
}

fn encode_step_transition(
  value: transition.StepTransition(JsonValue, JsonValue),
) -> JsonValue {
  case value {
    transition.Settled(s, o, n) ->
      object([
        #("tag", string("settled")),
        #("state", s),
        #("outputs", array(o)),
        #("applications", nat_to_json(n)),
      ])
    transition.Failed(s, o, f) ->
      object([
        #("tag", string("failed")),
        #("state", s),
        #("outputs", array(o)),
        #("failure", encode_step_failure(f)),
      ])
  }
}

pub fn op_step_transition_step(input: JsonValue) -> D(JsonValue) {
  use state <- try(obj_val(input, "state"))
  use inp <- try(obj_val(input, "input"))
  use advance_json <- try(obj_val(input, "advance"))
  use form <- try(decode_advance_form(advance_json))
  use limit_n <- try(nat_field(input, "limit"))
  use capacity_n <- try(nat_field(input, "capacity"))
  case limit_n > 0 {
    False -> Error(fail_shape("limit must be positive"))
    True -> {
      let assert Ok(limit) = transition.positive_limit_new(limit_n)
      let assert Ok(capacity) = transition.capacity_new(capacity_n)
      Ok(
        encode_step_transition(transition.step(
          state,
          inp,
          advance_eval(form),
          limit,
          capacity,
        )),
      )
    }
  }
}
