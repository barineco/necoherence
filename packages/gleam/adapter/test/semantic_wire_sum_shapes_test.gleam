// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import necoherence/admission_failure as admission
import necoherence/exact_json as json
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_generation_values as values
import necoherence/semantic_signatures as signatures

fn tag(name: String) -> json.JsonValue {
  json.JsonValueObj([#("tag", json.JsonValueStr(name))])
}

fn tag_with_extra_key(name: String) -> json.JsonValue {
  json.JsonValueObj([
    #("tag", json.JsonValueStr(name)),
    #("extra", json.JsonValueNull),
  ])
}

fn natural(text: String) -> json.JsonValue {
  json.JsonValueStr(text)
}

fn array_shape(minimum: json.JsonValue) -> json.JsonValue {
  json.JsonValueObj([
    #("tag", json.JsonValueStr("Array")),
    #(
      "value",
      json.JsonValueObj([
        #(
          "item",
          json.JsonValueObj([
            #("type_id", json.JsonValueStr("element")),
            #("nullable", json.JsonValueBool(False)),
          ]),
        ),
        #("min_length", minimum),
        #("max_length", json.JsonValueNull),
      ]),
    ),
  ])
}

fn decimal_shape(scale: String) -> json.JsonValue {
  json.JsonValueObj([
    #("tag", json.JsonValueStr("Decimal")),
    #(
      "value",
      json.JsonValueObj([
        #(
          "minimum",
          json.JsonValueObj([
            #("mantissa", natural("1")),
            #("scale", natural(scale)),
            #("exclusive", json.JsonValueBool(False)),
          ]),
        ),
        #("maximum", json.JsonValueNull),
      ]),
    ),
  ])
}

pub fn generated_sum_decoders_report_an_unknown_tag_before_the_keys_test() {
  let assert Error(decode.UnknownTag(_, "Bogus")) =
    decode.decode_binding_mode(tag_with_extra_key("Bogus"))
  let assert Error(decode.UnknownTag(_, "Bogus")) =
    decode.decode_token_kind(tag_with_extra_key("Bogus"))
  let assert Error(decode.UnknownTag(_, "Bogus")) =
    decode.decode_producer_ref(tag_with_extra_key("Bogus"))
  let assert Error(decode.UnknownTag(_, "Bogus")) =
    decode.decode_format_use(tag_with_extra_key("Bogus"))
  let assert Error(decode.UnknownTag(_, "Bogus")) =
    decode.decode_sealed_leaf(tag_with_extra_key("Bogus"))
  let assert Error(decode.UnknownTag(_, "Bogus")) =
    decode.decode_field_presence(tag_with_extra_key("Bogus"))
}

pub fn generated_sum_decoders_check_the_keys_after_a_known_tag_test() {
  let assert Error(decode.UnknownField(_, "extra")) =
    decode.decode_binding_mode(tag_with_extra_key("Read"))
  let assert Error(decode.UnknownField(_, "extra")) =
    decode.decode_field_presence(tag_with_extra_key("Required"))
}

pub fn library_sum_decoders_report_an_unknown_tag_before_the_keys_test() {
  let assert Error(signatures.Wire(decode.UnknownTag(_, "Bogus"))) =
    signatures.decode_library_shape(
      json.JsonValueObj([
        #("tag", json.JsonValueStr("Unknown")),
        #("value", tag_with_extra_key("Bogus")),
      ]),
    )
  let assert Error(signatures.Wire(decode.UnknownTag(_, "Bogus"))) =
    signatures.decode_library_shape(
      json.JsonValueObj([
        #("tag", json.JsonValueStr("Bogus")),
        #("extra", json.JsonValueNull),
      ]),
    )
}

pub fn library_natural_fields_reject_a_negative_value_test() {
  let assert Error(signatures.Wire(decode.SyntaxFailure(_, _))) =
    signatures.decode_library_shape(array_shape(natural("-1")))
  let assert Error(signatures.Wire(decode.SyntaxFailure(_, _))) =
    signatures.decode_library_shape(decimal_shape("-1"))
  let assert Ok(_) = signatures.decode_library_shape(array_shape(natural("0")))
  let assert Ok(_) = signatures.decode_library_shape(decimal_shape("0"))
}

fn tagged_fields(
  name: String,
  fields: List(#(String, json.JsonValue)),
) -> json.JsonValue {
  json.JsonValueObj([
    #("tag", json.JsonValueStr(name)),
    #("fields", json.JsonValueObj(fields)),
  ])
}

fn assert_nat_rejected(
  result: Result(a, decode.DecodeFailure),
  path: String,
) -> Nil {
  let assert Error(failure) = result
  let assert "Syntax" = decode.failure_classification(failure)
  let assert True = decode.failure_path(failure) == path
  Nil
}

pub fn nat_fields_reject_a_negative_value_as_syntax_at_the_field_path_test() {
  assert_nat_rejected(
    decode.decode_format_rule(
      tagged_fields("Bounded", [
        #("unit", tag("Utf8Bytes")),
        #("maximum", json.JsonValueStr("-5")),
        #("rule", tag("Text")),
      ]),
    ),
    "$.maximum",
  )
  assert_nat_rejected(
    decode.decode_format_rule(
      tagged_fields("Labels", [
        #("separator", json.JsonValueStr(".")),
        #("min_count", json.JsonValueStr("-5")),
        #("max_count", json.JsonValueNull),
        #("total_max", json.JsonValueNull),
        #("rule", tag("Text")),
      ]),
    ),
    "$.min_count",
  )
  assert_nat_rejected(
    decode.decode_format_rule(
      tagged_fields("Identifier", [
        #("first_alphabet", json.JsonValueStr("a")),
        #("rest_alphabet", json.JsonValueStr("a")),
        #("exact_length", json.JsonValueNull),
        #("min_length", json.JsonValueStr("-5")),
        #("max_length", json.JsonValueNull),
        #("forbidden", json.JsonValueArr([])),
      ]),
    ),
    "$.min_length",
  )
  assert_nat_rejected(
    decode.decode_format_rule(
      tagged_fields("AbsoluteUri", [#("max_bytes", json.JsonValueStr("-5"))]),
    ),
    "$.max_bytes",
  )
  assert_nat_rejected(
    decode.decode_calendar_rule(
      json.JsonValueObj([
        #("allow_second_60", json.JsonValueBool(False)),
        #("minimum_year", json.JsonValueStr("-5")),
        #("maximum_year", json.JsonValueStr("2100")),
        #("rejectUtcYearOutsideRange", json.JsonValueBool(False)),
      ]),
    ),
    "$.minimum_year",
  )
  assert_nat_rejected(
    decode.decode_dfa_spec(
      json.JsonValueObj([
        #("state_count", json.JsonValueStr("-5")),
        #("initial_state", json.JsonValueStr("0")),
        #("accepting_states", json.JsonValueArr([])),
        #("transitions", json.JsonValueArr([])),
      ]),
    ),
    "$.state_count",
  )
  assert_nat_rejected(
    decode.decode_dfa_transition(
      json.JsonValueObj([
        #("from_state", json.JsonValueStr("-5")),
        #("first", json.JsonValueStr("0")),
        #("last", json.JsonValueStr("0")),
        #("to_state", json.JsonValueStr("0")),
      ]),
    ),
    "$.from_state",
  )
  assert_nat_rejected(
    decode.decode_grapheme_range(
      json.JsonValueObj([
        #("first", json.JsonValueStr("-5")),
        #("last", json.JsonValueStr("0")),
        #("property", tag("Other")),
      ]),
    ),
    "$.first",
  )
  assert_nat_rejected(
    decode.decode_codepoint_range(
      json.JsonValueObj([
        #("first", json.JsonValueStr("-5")),
        #("last", json.JsonValueStr("0")),
      ]),
    ),
    "$.first",
  )
  assert_nat_rejected(
    decode.decode_length_spec(
      json.JsonValueObj([
        #("minimum", json.JsonValueStr("-5")),
        #("maximum", json.JsonValueNull),
      ]),
    ),
    "$.minimum",
  )
}

pub fn exact_json_decoder_reports_the_wire_failure_kinds_test() {
  let assert Error(decode.UnknownTag(_, "Bogus")) =
    decode.decode_exact(tag_with_extra_key("Bogus"))
  let assert Error(decode.UnknownField(_, "extra")) =
    decode.decode_exact(tag_with_extra_key("Null"))
  let assert Error(decode.SyntaxFailure(_, _)) =
    decode.decode_exact(json.JsonValueObj([]))
  let assert Ok(json.JsonValueNull) = decode.decode_exact(tag("Null"))
}

pub fn exponent_at_ten_thousand_is_rejected_and_below_it_accepted_test() {
  let assert Ok(_) = values.parse_wire("1e9999")
  let assert Error(values.ExponentTooLarge) = values.parse_wire("1e10000")
  let assert Error(values.ExponentTooLarge) = values.parse_wire("1E+10000")
  let assert Error(values.ExponentTooLarge) = values.parse_wire("1e-10000")
}

pub fn exchange_with_a_duplicate_object_key_fails_in_the_json_stage_test() {
  let assert Error(admission.Generation(signatures.Json(values.InvalidSyntax))) =
    signatures.admit_generation(
      "{\"basis\":{\"signature_schema\":\"s\",\"library_identity\":\"l\",\"library_revision\":\"1\",\"profile\":{\"identity\":\"p\",\"revision\":\"1\",\"content_digest\":\"d\"},\"graph_sha256\":\"g\",\"provenance_sha256\":\"p\",\"metadata_sha256\":\"m\",\"problem_sha256\":null,\"observations_sha256\":null,\"entrypoints_sha256\":\"e\"},\"observations\":null}",
      "{\"schema\":\"a\",\"schema\":\"b\"}",
    )
}
