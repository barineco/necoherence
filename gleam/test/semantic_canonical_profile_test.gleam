// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{None}
import gleam/string
import necoherence/exact_json as json
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import semantic_test_support as support

pub fn canonical_profile_roundtrip_preserves_stage_five_declarations_test() {
  let value = support.profile()
  let assert Ok(encoded) = decode.encode_semantic_profile(value)
  let assert Ok(decoded) = decode.decode_semantic_profile(encoded)
  let assert True = decoded == value
  let assert Ok(reencoded) = decode.encode_semantic_profile(decoded)
  let assert True = reencoded == encoded
  let assert Ok(_) = validation.check_profile(decoded)
}

pub fn canonical_format_wire_roundtrips_every_constructor_test() {
  let rules = [
    types.AsciiDfa(types.DfaSpec(1, 0, [0], [])),
    types.Timestamp(types.CalendarRule(False, 0, 9999, True)),
    types.Choice([types.Text]),
    types.Identifier("a", "a", None, 1, 2, []),
    types.AbsoluteUri(8),
    types.LanguageTag([]),
    types.Literal("x"),
    types.Sequence([types.Text]),
    types.Optional(types.Text),
    types.Labels(".", 1, None, None, types.Text),
    types.Bounded(types.UnicodeScalars, 2, types.Text),
    types.Text,
    types.Not(types.Literal("x")),
  ]
  list.each(rules, fn(rule) {
    let assert Ok(encoded) = decode.encode_format_rule(rule)
    let assert Ok(decoded) = decode.decode_format_rule(encoded)
    let assert True = decoded == rule
  })
}

pub fn canonical_profile_admission_preserves_typed_failure_test() {
  let invalid =
    types.SemanticProfile(
      ..support.profile(),
      reference: types.ProfileRef("", "4", "digest"),
    )
  let assert Error(types.ProfileFailure(_, types.Pr01, ["profile"])) =
    validation.check_profile(invalid)
}

pub fn canonical_value_failure_roundtrip_preserves_stage_five_wire_test() {
  let source =
    types.SourceRef(
      "repo",
      "revision",
      "path",
      string.repeat("a", 64),
      "document",
      None,
    )
  let reference = types.TypeRef(source, "text", ["shape"])
  let value =
    types.ValueFailure(
      reference,
      types.DefinitionRef(source, "text"),
      types.OccurrenceRef(source, ["shape"]),
      [types.Field("payload"), types.Index(0)],
      types.InvalidWrapperCondition("text"),
      types.Present(json.JsonValueStr("observed")),
      [reference],
    )
  let assert Ok(encoded) = decode.encode_value_failure(value)
  let assert Ok(decoded) = decode.decode_value_failure(encoded)
  let assert True = decoded == value
  let assert Ok(reencoded) = decode.encode_value_failure(decoded)
  let assert True = reencoded == encoded
}
