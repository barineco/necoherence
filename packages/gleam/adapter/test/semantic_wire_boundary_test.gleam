// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{None, Some}
import necoherence/exact_json as json
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_generation_values as values
import necoherence/semantic_signatures as signatures

pub fn zero_with_large_exponent_has_canonical_form_zero_test() {
  let assert Ok("0") = signatures.canonical(json.JsonValueDec("0e11"))
}

fn decimal_tag(text: String) -> json.JsonValue {
  json.JsonValueObj([
    #("tag", json.JsonValueStr("Decimal")),
    #("text", json.JsonValueStr(text)),
  ])
}

pub fn zero_decimal_text_is_kept_as_decimal_text_test() {
  let assert Ok(json.JsonValueDec("0.0")) =
    decode.decode_exact(decimal_tag("0.0"))
  let assert Ok(json.JsonValueDec("0e-100")) =
    decode.decode_exact(decimal_tag("0e-100"))
  let assert Ok(json.JsonValueDec("0.000e-100")) =
    decode.decode_exact(decimal_tag("0.000e-100"))
  let assert Ok(json.JsonValueDec("0")) = values.parse_wire("0.0")
  let assert Ok(json.JsonValueDec("0")) = values.parse_wire("-0.0")
}

pub fn exponent_scan_reads_only_exponents_outside_strings_test() {
  let assert Some("exponent too large") = json.admission_failure("1e10000")
  let assert Some("exponent too large") = json.admission_failure("1E+10000")
  let assert None = json.admission_failure("1e9999")
  let assert None = json.admission_failure("\"e10000\"")
}

pub fn decimal_at_the_exponent_limit_has_no_canonical_form_test() {
  let assert Error(signatures.Json(values.ExponentTooLarge)) =
    signatures.canonical(json.JsonValueDec("1e10000"))
  let assert Error(signatures.Json(values.ExponentTooLarge)) =
    signatures.canonical(
      json.JsonValueArr([
        json.JsonValueObj([#("nested", json.JsonValueDec("1e-10000"))]),
      ]),
    )
  let assert Error(values.ExponentTooLarge) =
    values.encode_wire(json.JsonValueDec("1e10000"))
}

pub fn exponent_below_the_limit_is_accepted_test() {
  let assert Ok(_) = values.parse_wire("1e42")
  let assert Ok(_) = values.parse_wire("1e9999")
}

pub fn exponent_magnitude_at_the_limit_is_rejected_for_both_signs_test() {
  list.each(
    [
      "1e-10000", "1E-10000", "1e-4294967296", "1e99999999999999999999",
      "1e-99999999999999999999", "1e-000010000", "1e000010000",
    ],
    fn(text) {
      let assert Error(values.ExponentTooLarge) = values.parse_wire(text)
    },
  )
}

pub fn exponent_magnitude_below_the_limit_compares_by_value_test() {
  list.each(["1e-9999", "1e-42", "1e-000009999"], fn(text) {
    let assert Ok(json.JsonValueDec(_)) = values.parse_wire(text)
  })
  let assert Ok(json.JsonValueNum(100_000)) = values.parse_wire("1e+000000005")
}

pub fn positive_exponent_at_the_limit_is_rejected_test() {
  let assert Error(_) = values.parse_wire("1e10000")
  let assert Error(_) = values.parse_wire("1E+10000")
}

pub fn lone_high_surrogate_escape_is_rejected_test() {
  let assert Error(values.UnpairedSurrogate) = values.parse_wire("\"\\ud800\"")
}

pub fn lone_low_surrogate_escape_is_rejected_test() {
  let assert Error(values.UnpairedSurrogate) = values.parse_wire("\"\\udc00\"")
}

pub fn high_surrogate_followed_by_text_is_rejected_test() {
  let assert Error(values.UnpairedSurrogate) =
    values.parse_wire("\"\\ud83d\\u0061\"")
}

pub fn paired_surrogate_escape_is_accepted_test() {
  let assert Ok(json.JsonValueStr("😀")) =
    values.parse_wire("\"\\ud83d\\ude00\"")
}
