// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import feature_check/decode_support.{
  type D, arr_field, as_str, fail_shape, obj_val, str_field, try,
}
import feature_check/json_value.{
  type JsonValue, JNull, JObject, array, object, string,
}
import gleam/list
import necoherence/call

pub type FunctionForm {
  FormIdentity
  FormConst(value: JsonValue)
  FormGetField(name: String)
  FormSetField(name: String, value: JsonValue)
  FormWrap(tag: String)
}

pub fn decode_function_form(value: JsonValue) -> D(FunctionForm) {
  use kind <- try(str_field(value, "kind"))
  case kind {
    "identity" -> Ok(FormIdentity)
    "const" -> {
      use v <- try(obj_val(value, "value"))
      Ok(FormConst(v))
    }
    "getField" -> {
      use name <- try(str_field(value, "name"))
      Ok(FormGetField(name))
    }
    "setField" -> {
      use name <- try(str_field(value, "name"))
      use v <- try(obj_val(value, "value"))
      Ok(FormSetField(name, v))
    }
    "wrap" -> {
      use tag <- try(str_field(value, "tag"))
      Ok(FormWrap(tag))
    }
    other -> Error(fail_shape("unknown function form kind " <> other))
  }
}

pub fn apply_function_form(form: FunctionForm, x: JsonValue) -> JsonValue {
  case form {
    FormIdentity -> x
    FormConst(v) -> v
    FormGetField(n) ->
      case x {
        JObject(fields) ->
          case list.find(fields, fn(entry) { entry.0 == n }) {
            Ok(#(_, v)) -> v
            Error(_) -> JNull
          }
        _ -> JNull
      }
    FormSetField(n, v) ->
      case x {
        JObject(fields) ->
          case list.any(fields, fn(entry) { entry.0 == n }) {
            True ->
              JObject(
                list.map(fields, fn(entry) {
                  case entry.0 == n {
                    True -> #(n, v)
                    False -> entry
                  }
                }),
              )
            False -> JObject(list.append(fields, [#(n, v)]))
          }
        _ -> JObject([#(n, v)])
      }
    FormWrap(t) -> object([#("tag", string(t)), #("value", x)])
  }
}

pub fn decode_request(value: JsonValue) -> D(call.Request(JsonValue)) {
  use payload <- try(obj_val(value, "payload"))
  use fields_arr <- try(arr_field(value, "fields"))
  use fields <- try(decode_support.map_list(fields_arr, as_str))
  Ok(call.Request(payload, fields))
}

pub fn decode_immediate(
  value: JsonValue,
) -> D(call.Immediate(JsonValue, JsonValue)) {
  use identity <- try(str_field(value, "identity"))
  use required_arr <- try(arr_field(value, "required"))
  use required <- try(decode_support.map_list(required_arr, as_str))
  use output_json <- try(obj_val(value, "output"))
  use form <- try(decode_function_form(output_json))
  Ok(call.immediate_of(identity, required, apply_function_form(form, _)))
}

pub fn decode_deferred(
  value: JsonValue,
) -> D(call.Deferred(JsonValue, JsonValue)) {
  use identity <- try(str_field(value, "identity"))
  use required_arr <- try(arr_field(value, "required"))
  use required <- try(decode_support.map_list(required_arr, as_str))
  use output_json <- try(obj_val(value, "output"))
  use form <- try(decode_function_form(output_json))
  Ok(call.deferred_of(identity, required, apply_function_form(form, _)))
}

pub fn encode_call_result(value: call.CallResult(JsonValue)) -> JsonValue {
  case value {
    call.CallOk(v) -> object([#("tag", string("ok")), #("value", v)])
    call.CallFailed(f) ->
      object([
        #("tag", string("failed")),
        #("declaration", string(f.declaration)),
        #("fields", array(list.map(f.fields, string))),
      ])
  }
}

pub fn op_call_immediate_of(input: JsonValue) -> D(JsonValue) {
  use decl <- try(decode_immediate(input))
  Ok(
    object([
      #("identity", string(decl.identity)),
      #("required", array(list.map(decl.required, string))),
    ]),
  )
}

pub fn op_call_deferred_of(input: JsonValue) -> D(JsonValue) {
  use decl <- try(decode_deferred(input))
  Ok(
    object([
      #("identity", string(decl.identity)),
      #("required", array(list.map(decl.required, string))),
    ]),
  )
}

pub fn op_call_io(input: JsonValue) -> D(JsonValue) {
  use decl_json <- try(obj_val(input, "declaration"))
  use decl <- try(decode_immediate(decl_json))
  use req_json <- try(obj_val(input, "request"))
  use req <- try(decode_request(req_json))
  Ok(encode_call_result(call.io(decl, req)))
}

pub fn op_call_issue(input: JsonValue) -> D(JsonValue) {
  use decl_json <- try(obj_val(input, "declaration"))
  use decl <- try(decode_deferred(decl_json))
  use req_json <- try(obj_val(input, "request"))
  use req <- try(decode_request(req_json))
  Ok(encode_call_result(call.issue(decl, req)))
}
