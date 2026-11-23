// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import necoherence/exact_json as json
import necoherence/semantic_generation_values as values

/// Lean `ExactJson.boundedJsonParse` rejects a lone high surrogate escape in a string.
pub fn lone_high_surrogate_is_rejected_test() {
  let assert Error(values.UnpairedSurrogate) = values.parse_wire("\"\\ud800\"")
  let assert Error(values.UnpairedSurrogate) = values.parse_wire("\"\\ud83d\"")
  let assert Error(values.UnpairedSurrogate) =
    values.parse_wire("\"\\ud83d\\u0041\"")
}

/// Lean `ExactJson.boundedJsonParse` rejects a lone low surrogate escape in a string.
pub fn lone_low_surrogate_is_rejected_test() {
  let assert Error(values.UnpairedSurrogate) = values.parse_wire("\"\\udc00\"")
  let assert Error(values.UnpairedSurrogate) =
    values.parse_wire("{\"k\\ud800\":1}")
}

/// Lean `ExactJson.boundedJsonParse` accepts a high surrogate escape followed by a low surrogate escape.
pub fn surrogate_pair_is_accepted_test() {
  let assert Ok(json.JsonValueStr("\u{1F600}")) =
    values.parse_wire("\"\\ud83d\\ude00\"")
}

/// Lean `ExactJson.boundedJsonParse` rejects an exponent of 10000 in magnitude outside the strings.
pub fn exponent_at_limit_is_rejected_test() {
  let assert Error(values.ExponentTooLarge) = values.parse_wire("1e10000")
  let assert Error(values.ExponentTooLarge) = values.parse_wire("[1E10000]")
  let assert Error(values.ExponentTooLarge) = values.parse_wire("[1e+10000]")
  let assert Error(values.ExponentTooLarge) = values.parse_wire("[1e-10000]")
  let assert Error(values.ExponentTooLarge) =
    values.parse_wire(
      "{\"reference\":{\"identity\":\"p\"},\"integer_domains\":[{\"range\":1e10000}]}",
    )
}

/// Lean `ExactJson.boundedJsonParse` admits an exponent below 10000 and an exponent written inside a string.
pub fn exponent_below_limit_is_accepted_test() {
  let assert Ok(json.JsonValueArr([json.JsonValueStr("1e10000")])) =
    values.parse_wire("[\"1e10000\"]")
  let assert Ok(_) = values.parse_wire("[1e9999]")
}

/// Lean admits the whole text before the parse, so the first failure in text order decides the outcome.
pub fn admission_precedes_syntax_and_orders_by_text_test() {
  let assert Error(values.ExponentTooLarge) = values.parse_wire("[x,1e10000]")
  let assert Error(values.UnpairedSurrogate) =
    values.parse_wire("{\"a\":\"\\ud800\",\"b\":1e10000}")
  let assert Error(values.UnpairedSurrogate) =
    values.parse_wire("[\"\\ud800\", 1e10000]")
}

/// An invalid escape is a syntax failure, not an admitted surrogate.
pub fn invalid_escape_is_syntax_failure_test() {
  let assert Error(values.InvalidSyntax) = values.parse_wire("\"\\uzzzz\"")
}

pub fn duplicate_object_key_is_a_syntax_failure_at_parse_test() {
  let assert Error(values.InvalidSyntax) =
    values.parse_wire("{\"a\":1,\"a\":2}")
  let assert Error(values.InvalidSyntax) =
    values.parse_wire("{\"x\":{\"y\":1,\"y\":2}}")
  let assert Error(values.InvalidSyntax) =
    values.parse_wire("[{\"y\":1,\"y\":2}]")
  let assert Error(values.InvalidSyntax) =
    values.parse_wire("{\"x\":1,\"\\u0078\":2}")
  let assert Error(values.InvalidSyntax) =
    values.parse_wire("{\"\\u0078\":1,\"x\":2}")
  let assert Error(values.InvalidSyntax) =
    values.parse_wire("{\"\\u0078\":1,\"\\u0078\":2}")
  let assert Ok(json.JsonValueObj([
    #("a", json.JsonValueNum(1)),
    #("b", json.JsonValueNum(2)),
  ])) = values.parse_wire("{\"a\":1,\"b\":2}")
}

pub fn repeated_member_of_an_exact_value_is_a_duplicate_field_test() {
  let assert Error(values.DuplicateField("a")) =
    values.unique_members(
      json.JsonValueObj([#("a", json.JsonValueNull), #("a", json.JsonValueNull)]),
    )
  let assert Error(values.DuplicateField("y")) =
    values.unique_members(
      json.JsonValueArr([
        json.JsonValueObj([
          #("x", json.JsonValueNull),
          #("y", json.JsonValueNull),
          #("y", json.JsonValueNull),
        ]),
      ]),
    )
  let assert Ok(Nil) =
    values.unique_members(
      json.JsonValueObj([#("a", json.JsonValueNull), #("b", json.JsonValueNull)]),
    )
}

pub fn object_members_are_ordered_by_code_point_test() {
  let assert Ok(json.JsonValueObj([
    #("\u{FFFF}", json.JsonValueNum(2)),
    #("\u{10000}", json.JsonValueNum(1)),
  ])) = values.parse_wire("{\"\\uD800\\uDC00\":1,\"\\uFFFF\":2}")
}
