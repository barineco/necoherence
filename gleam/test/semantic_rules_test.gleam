// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/string
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import semantic_test_support as support

fn rules() -> types.GraphemeRules {
  types.GraphemeRules(
    support.profile_ref(),
    [types.GraphemeRange(0x0301, 0x0301, types.Extend)],
    [],
    [],
    types.GraphemeComponent("16.0.0", "45", "default"),
    string.repeat("c", 64),
    [],
  )
}

pub fn public_grapheme_boundaries_and_count_test() {
  let value = rules()
  let assert [0, 2] = validation.grapheme_boundaries(value, "á")
  let assert 1 = validation.grapheme_count(value, "á")
  let assert [] = validation.grapheme_boundaries(value, "")
  let assert 0 = validation.grapheme_count(value, "")
}

pub fn native_grapheme_rules_wire_roundtrip_test() {
  let value = rules()
  let assert Ok(encoded) = decode.encode_grapheme_rules(value)
  let assert Ok(decoded) = decode.decode_grapheme_rules(encoded)
  let assert True = decoded == value
}
