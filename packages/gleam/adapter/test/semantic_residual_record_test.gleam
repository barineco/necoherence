// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import neco_quotient_encoding/canonical
import neco_quotient_encoding/json as quotient_json
import necoherence/exact_json as json
import necoherence/semantic_residual_record as record
import necoherence/semantic_signatures as signatures
import necoherence/semantic_types as types
import semantic_test_support as support

fn basis() -> signatures.GenerationRequirement {
  signatures.GenerationRequirement(
    "ncoh-type-signatures@1",
    "residual-library",
    "4",
    support.profile_ref(),
    string.repeat("1", 64),
    string.repeat("2", 64),
    string.repeat("3", 64),
    Some(string.repeat("4", 64)),
    None,
    string.repeat("6", 64),
  )
}

fn obligation(
  name: String,
  path: types.ValuePath,
  reason: types.SemanticReason,
) -> types.SemanticObligation {
  types.SemanticObligation(
    support.reference(name),
    path,
    reason,
    support.occurrence(),
    support.profile_ref(),
  )
}

fn obligations() -> List(types.SemanticObligation) {
  [
    obligation(
      "a",
      [types.Field("x"), types.Index(3)],
      types.UnresolvedTypeReason,
    ),
    obligation("b", [], types.OpaqueTypeReason("external")),
    obligation("c", [types.Variant("v")], types.MissingTagModelReason),
  ]
}

fn value() -> json.JsonValue {
  json.JsonValueObj([
    #("count", json.JsonValueNum(12)),
    #(
      "nested",
      json.JsonValueArr([
        json.JsonValueObj([#("flag", json.JsonValueBool(True))]),
        json.JsonValueDec("1.5"),
        json.JsonValueNull,
      ]),
    ),
  ])
}

fn encoded(items: List(types.SemanticObligation)) -> BitArray {
  let assert Ok(bytes) =
    record.encode_semantic_residual(
      basis(),
      support.reference("subject"),
      value(),
      items,
    )
  bytes
}

fn members(
  value: quotient_json.JsonValue,
) -> List(#(String, quotient_json.JsonValue)) {
  let assert quotient_json.JsonObject(members) = value
  members
}

fn member(
  value: quotient_json.JsonValue,
  key: String,
) -> quotient_json.JsonValue {
  let assert Ok(found) = list.key_find(members(value), key)
  found
}

pub fn reversed_obligations_give_the_same_bytes_test() {
  assert encoded(list.reverse(obligations())) == encoded(obligations())
}

pub fn repeated_obligation_gives_the_same_bytes_test() {
  assert encoded(list.append(obligations(), obligations()))
    == encoded(obligations())
}

pub fn decoded_record_has_four_fields_test() {
  let assert Ok(decoded) = canonical.decode_canonical(encoded(obligations()))
  let keys =
    list.sort(list.map(members(decoded), fn(pair) { pair.0 }), string.compare)
  assert keys == ["basis", "input", "residuals", "schema"]
  assert member(decoded, "schema")
    == quotient_json.JsonString(record.semantic_residual_schema)
  let assert quotient_json.JsonArray(residuals) = member(decoded, "residuals")
  assert list.length(residuals) == 3
  list.each(residuals, fn(residual) {
    let keys =
      list.sort(
        list.map(members(residual), fn(pair) { pair.0 }),
        string.compare,
      )
    assert keys == ["origin", "profile", "reason", "type_ref", "value_path"]
  })
}

pub fn decoded_residual_count_ignores_repeats_test() {
  let assert Ok(decoded) =
    canonical.decode_canonical(
      encoded(list.append(obligations(), obligations())),
    )
  let assert quotient_json.JsonArray(residuals) = member(decoded, "residuals")
  assert list.length(residuals) == 3
}

pub fn value_is_written_as_tagged_records_test() {
  let assert Ok(decoded) = canonical.decode_canonical(encoded(obligations()))
  let written = member(member(decoded, "input"), "value")
  assert member(written, "tag") == quotient_json.JsonString("Object")
  let assert quotient_json.JsonArray(entries) = member(written, "members")
  let assert Ok(count) =
    list.find(entries, fn(entry) {
      member(entry, "key") == quotient_json.JsonString("count")
    })
  let counted = member(count, "value")
  assert member(counted, "tag") == quotient_json.JsonString("Integer")
  assert member(counted, "value") == quotient_json.JsonString("12")
}

pub fn no_json_number_appears_in_the_bytes_test() {
  let assert Ok(decoded) = canonical.decode_canonical(encoded(obligations()))
  assert !contains_number(decoded)
  let assert Ok(text) = bit_array.to_string(encoded(obligations()))
  assert string.contains(text, "\"value\":\"3\"")
}

fn contains_number(value: quotient_json.JsonValue) -> Bool {
  case value {
    quotient_json.JsonNumber(_) -> True
    quotient_json.JsonArray(items) -> list.any(items, contains_number)
    quotient_json.JsonObject(pairs) ->
      list.any(pairs, fn(pair) { contains_number(pair.1) })
    _ -> False
  }
}
