// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/result
import necoherence/exact_json as json
import necoherence/semantic_generation_values as values

pub fn decimal_text_keeps_the_to_json_spelling_of_the_canonical_text_test() {
  let assert Ok(json.JsonValueDec("10")) = values.parse_wire("10.0")
  let assert Ok(json.JsonValueDec("1")) = values.parse_wire("1.0")
  let assert Ok(json.JsonValueDec("0")) = values.parse_wire("0.0")
  let assert Ok(json.JsonValueDec("-7")) = values.parse_wire("-7.0")
  let assert Ok(json.JsonValueDec("1.5")) = values.parse_wire("1.50")
  let assert Ok(json.JsonValueDec("0.01")) = values.parse_wire("1.0e-2")
  let assert Ok(json.JsonValueDec("0.25")) = values.parse_wire("2.50e-1")
  let assert Ok(json.JsonValueDec("123.456")) = values.parse_wire("123.456")
  let assert Ok(json.JsonValueDec("0.0000001")) = values.parse_wire("1e-7")
  let assert Ok(json.JsonValueNum(150)) = values.parse_wire("1.5e2")
  let assert Ok(json.JsonValueNum(100)) = values.parse_wire("1e2")
}

pub fn json_spelling_writes_a_decimal_with_a_point_for_its_integer_value_test() {
  let assert Ok("10.0") = values.json_spelling(json.JsonValueDec("10"))
  let assert Ok("1.0") = values.json_spelling(json.JsonValueDec("1"))
  let assert Ok("0.0") = values.json_spelling(json.JsonValueDec("0"))
  let assert Ok("-7.0") = values.json_spelling(json.JsonValueDec("-7"))
  let assert Ok("12345678901.0") =
    values.json_spelling(json.JsonValueDec("12345678901"))
  let assert Ok("1.5") = values.json_spelling(json.JsonValueDec("1.5"))
  let assert Ok("0.01") = values.json_spelling(json.JsonValueDec("0.01"))
  let assert Ok("0.0000001") =
    values.json_spelling(json.JsonValueDec("0.0000001"))
  let assert Ok("150") = values.json_spelling(json.JsonValueNum(150))
}

pub fn json_spelling_keeps_a_canonical_decimal_spelling_through_the_wire_test() {
  let assert Ok("10.0") =
    values.parse_wire("10.0") |> result.try(values.json_spelling)
  let assert Ok("-7.0") =
    values.parse_wire("-7.0") |> result.try(values.json_spelling)
  let assert Ok("0.01") =
    values.parse_wire("0.01") |> result.try(values.json_spelling)
  let assert Ok("123.456") =
    values.parse_wire("123.456") |> result.try(values.json_spelling)
}

pub fn json_spelling_writes_object_members_in_key_order_test() {
  let assert Ok("{\"a\":2,\"b\":1.0}") =
    values.json_spelling(
      json.JsonValueObj([
        #("b", json.JsonValueDec("1")),
        #("a", json.JsonValueNum(2)),
      ]),
    )
}

pub fn integral_decimal_value_spells_an_integer_with_a_point_test() {
  assert values.integral_decimal_value(5) == json.JsonValueDec("5.0")
  assert values.integral_decimal_value(0) == json.JsonValueDec("0.0")
  assert values.integral_decimal_value(-7) == json.JsonValueDec("-7.0")
}

pub fn decimal_string_value_spells_an_integer_as_a_string_test() {
  assert values.decimal_string_value(5) == json.JsonValueStr("5")
  assert values.decimal_string_value(0) == json.JsonValueStr("0")
  assert values.decimal_string_value(-7) == json.JsonValueStr("-7")
}
