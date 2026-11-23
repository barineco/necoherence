// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import feature_check/json_value.{
  type JsonValue, JArray, JBool, JNull, JObject, JString,
}
import gleam/int
import gleam/list
import gleam/string

pub type FailureKind {
  JsonSyntax
  QueryShape
  UnknownFeature
  UnknownOperation
  InputShape
}

pub fn failure_kind_str(kind: FailureKind) -> String {
  case kind {
    JsonSyntax -> "json_syntax"
    QueryShape -> "query_shape"
    UnknownFeature -> "unknown_feature"
    UnknownOperation -> "unknown_operation"
    InputShape -> "input_shape"
  }
}

pub type DecodeFailure {
  DecodeFailure(kind: FailureKind, detail: String)
}

pub type D(a) =
  Result(a, DecodeFailure)

pub fn fail_shape(detail: String) -> DecodeFailure {
  DecodeFailure(InputShape, detail)
}

pub fn obj_val(value: JsonValue, key: String) -> D(JsonValue) {
  case value {
    JObject(fields) ->
      case list.find(fields, fn(entry) { entry.0 == key }) {
        Ok(#(_, v)) -> Ok(v)
        Error(_) -> Error(fail_shape("missing field " <> key))
      }
    _ -> Error(fail_shape("expected object for field " <> key))
  }
}

pub fn as_str(value: JsonValue) -> D(String) {
  case value {
    JString(s) -> Ok(s)
    _ -> Error(fail_shape("expected string"))
  }
}

pub fn as_arr(value: JsonValue) -> D(List(JsonValue)) {
  case value {
    JArray(items) -> Ok(items)
    _ -> Error(fail_shape("expected array"))
  }
}

pub fn as_bool(value: JsonValue) -> D(Bool) {
  case value {
    JBool(b) -> Ok(b)
    _ -> Error(fail_shape("expected bool"))
  }
}

fn is_digit(c: String) -> Bool {
  list.contains(["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"], c)
}

pub fn nat_of_str(s: String) -> D(Int) {
  case s == "" {
    True -> Error(fail_shape("empty integer"))
    False ->
      case list.all(string.to_graphemes(s), is_digit) {
        False -> Error(fail_shape("invalid integer"))
        True ->
          case int.parse(s) {
            Ok(n) -> Ok(n)
            Error(_) -> Error(fail_shape("invalid integer"))
          }
      }
  }
}

pub fn nat_field(value: JsonValue, key: String) -> D(Int) {
  use v <- try(obj_val(value, key))
  use s <- try(as_str(v))
  nat_of_str(s)
}

pub fn str_field(value: JsonValue, key: String) -> D(String) {
  use v <- try(obj_val(value, key))
  as_str(v)
}

pub fn arr_field(value: JsonValue, key: String) -> D(List(JsonValue)) {
  use v <- try(obj_val(value, key))
  as_arr(v)
}

pub fn nat_to_json(n: Int) -> JsonValue {
  JString(int.to_string(n))
}

pub fn try(result: D(a), next: fn(a) -> D(b)) -> D(b) {
  case result {
    Ok(v) -> next(v)
    Error(e) -> Error(e)
  }
}

pub fn map_list(items: List(a), f: fn(a) -> D(b)) -> D(List(b)) {
  case items {
    [] -> Ok([])
    [head, ..rest] -> {
      use h <- try(f(head))
      use t <- try(map_list(rest, f))
      Ok([h, ..t])
    }
  }
}

pub fn is_null(value: JsonValue) -> Bool {
  case value {
    JNull -> True
    _ -> False
  }
}
