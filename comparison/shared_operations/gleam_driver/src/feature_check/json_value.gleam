// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/float
import gleam/int
import gleam/list
import gleam/string

pub type JsonValue {
  JNull
  JBool(Bool)
  JNumber(Float)
  JString(String)
  JArray(List(JsonValue))
  JObject(List(#(String, JsonValue)))
}

pub fn object(fields: List(#(String, JsonValue))) -> JsonValue {
  JObject(fields)
}

pub fn array(items: List(JsonValue)) -> JsonValue {
  JArray(items)
}

pub fn string(value: String) -> JsonValue {
  JString(value)
}

pub fn bool(value: Bool) -> JsonValue {
  JBool(value)
}

pub fn get_field(value: JsonValue, name: String) -> JsonValue {
  case value {
    JObject(fields) ->
      case list.find(fields, fn(entry) { entry.0 == name }) {
        Ok(#(_, v)) -> v
        Error(_) -> JNull
      }
    _ -> JNull
  }
}

pub fn set_field(
  value: JsonValue,
  name: String,
  field: JsonValue,
) -> JsonValue {
  case value {
    JObject(fields) ->
      case list.any(fields, fn(entry) { entry.0 == name }) {
        True ->
          JObject(
            list.map(fields, fn(entry) {
              case entry.0 == name {
                True -> #(name, field)
                False -> entry
              }
            }),
          )
        False -> JObject(list.append(fields, [#(name, field)]))
      }
    _ -> JObject([#(name, field)])
  }
}


pub fn to_json_string(value: JsonValue) -> String {
  case value {
    JNull -> "null"
    JBool(True) -> "true"
    JBool(False) -> "false"
    JNumber(n) -> float_to_string(n)
    JString(s) -> encode_string(s)
    JArray(items) ->
      "[" <> string.join(list.map(items, to_json_string), ",") <> "]"
    JObject(fields) ->
      "{"
      <> string.join(
        list.map(fields, fn(entry) {
          encode_string(entry.0) <> ":" <> to_json_string(entry.1)
        }),
        ",",
      )
      <> "}"
  }
}

fn float_to_string(n: Float) -> String {
  case float.truncate(n) |> int.to_float == n {
    True -> int.to_string(float.truncate(n))
    False -> float.to_string(n)
  }
}

fn encode_string(s: String) -> String {
  "\""
  <> string.to_graphemes(s)
  |> list.map(escape_grapheme)
  |> string.join("")
  <> "\""
}

fn escape_grapheme(g: String) -> String {
  case g {
    "\"" -> "\\\""
    "\\" -> "\\\\"
    "\n" -> "\\n"
    "\r" -> "\\r"
    "\t" -> "\\t"
    _ -> g
  }
}


pub fn parse(input: String) -> Result(JsonValue, String) {
  case parse_value(string.trim(input) |> string.to_graphemes) {
    Ok(#(value, rest)) ->
      case skip_ws(rest) {
        [] -> Ok(value)
        _ -> Error("trailing content")
      }
    Error(e) -> Error(e)
  }
}

fn skip_ws(chars: List(String)) -> List(String) {
  case chars {
    [c, ..rest] if c == " " || c == "\n" || c == "\t" || c == "\r" ->
      skip_ws(rest)
    _ -> chars
  }
}

fn parse_value(
  chars: List(String),
) -> Result(#(JsonValue, List(String)), String) {
  case skip_ws(chars) {
    [] -> Error("unexpected end of input")
    ["\"", ..rest] -> parse_string(rest, "")
    ["{", ..rest] -> parse_object(skip_ws(rest), [])
    ["[", ..rest] -> parse_array(skip_ws(rest), [])
    ["t", "r", "u", "e", ..rest] -> Ok(#(JBool(True), rest))
    ["f", "a", "l", "s", "e", ..rest] -> Ok(#(JBool(False), rest))
    ["n", "u", "l", "l", ..rest] -> Ok(#(JNull, rest))
    _ -> parse_number(chars)
  }
}

fn parse_string(
  chars: List(String),
  acc: String,
) -> Result(#(JsonValue, List(String)), String) {
  case chars {
    [] -> Error("unterminated string")
    ["\"", ..rest] -> Ok(#(JString(acc), rest))
    ["\\", "\"", ..rest] -> parse_string(rest, acc <> "\"")
    ["\\", "\\", ..rest] -> parse_string(rest, acc <> "\\")
    ["\\", "n", ..rest] -> parse_string(rest, acc <> "\n")
    ["\\", "r", ..rest] -> parse_string(rest, acc <> "\r")
    ["\\", "t", ..rest] -> parse_string(rest, acc <> "\t")
    ["\\", "/", ..rest] -> parse_string(rest, acc <> "/")
    [c, ..rest] -> parse_string(rest, acc <> c)
  }
}

fn is_number_char(c: String) -> Bool {
  c == "-"
  || c == "+"
  || c == "."
  || c == "e"
  || c == "E"
  || ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
  |> list.contains(c)
}

fn parse_number(
  chars: List(String),
) -> Result(#(JsonValue, List(String)), String) {
  let #(digits, rest) = take_while(chars, is_number_char)
  case digits {
    "" -> Error("invalid token")
    _ ->
      case float.parse(digits) {
        Ok(n) -> Ok(#(JNumber(n), rest))
        Error(_) ->
          case int.parse(digits) {
            Ok(n) -> Ok(#(JNumber(int.to_float(n)), rest))
            Error(_) -> Error("invalid number " <> digits)
          }
      }
  }
}

fn take_while(
  chars: List(String),
  predicate: fn(String) -> Bool,
) -> #(String, List(String)) {
  take_while_acc(chars, predicate, "")
}

fn take_while_acc(
  chars: List(String),
  predicate: fn(String) -> Bool,
  acc: String,
) -> #(String, List(String)) {
  case chars {
    [c, ..rest] ->
      case predicate(c) {
        True -> take_while_acc(rest, predicate, acc <> c)
        False -> #(acc, chars)
      }
    [] -> #(acc, [])
  }
}

fn parse_array(
  chars: List(String),
  acc: List(JsonValue),
) -> Result(#(JsonValue, List(String)), String) {
  case skip_ws(chars) {
    ["]", ..rest] -> Ok(#(JArray(list.reverse(acc)), rest))
    _ -> {
      use #(value, rest) <- try_result(parse_value(chars))
      case skip_ws(rest) {
        [",", ..rest2] -> parse_array(skip_ws(rest2), [value, ..acc])
        ["]", ..rest2] -> Ok(#(JArray(list.reverse([value, ..acc])), rest2))
        _ -> Error("expected , or ] in array")
      }
    }
  }
}

fn parse_object(
  chars: List(String),
  acc: List(#(String, JsonValue)),
) -> Result(#(JsonValue, List(String)), String) {
  case skip_ws(chars) {
    ["}", ..rest] -> Ok(#(JObject(list.reverse(acc)), rest))
    ["\"", ..rest] -> {
      use #(key_value, rest2) <- try_result(parse_string(rest, ""))
      let assert JString(key) = key_value
      case skip_ws(rest2) {
        [":", ..rest3] -> {
          use #(value, rest4) <- try_result(parse_value(skip_ws(rest3)))
          case skip_ws(rest4) {
            [",", ..rest5] ->
              parse_object(skip_ws(rest5), [#(key, value), ..acc])
            ["}", ..rest5] ->
              Ok(#(JObject(list.reverse([#(key, value), ..acc])), rest5))
            _ -> Error("expected , or } in object")
          }
        }
        _ -> Error("expected : in object")
      }
    }
    _ -> Error("expected string key in object")
  }
}

fn try_result(
  result: Result(a, String),
  next: fn(a) -> Result(b, String),
) -> Result(b, String) {
  case result {
    Ok(value) -> next(value)
    Error(e) -> Error(e)
  }
}
