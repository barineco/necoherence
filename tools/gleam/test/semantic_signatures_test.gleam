// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import gleam/string
import necoherence/exact_json as json
import necoherence/semantic_generation_values as values
import necoherence/semantic_signatures as signatures
import necoherence_tools/renderer
import semantic_tools_test_support as support

fn checked() -> signatures.CheckedGeneration {
  let library = support.library()
  let library_wire = support.wire(library)
  let entries =
    json.JsonValueArr([
      json.JsonValueObj([
        #("identity", json.JsonValueStr("entry")),
        #("definition", json.JsonValueStr("entry")),
      ]),
    ])
  let assert Ok(assembled) =
    signatures.assemble_generation(library_wire, json.JsonValueNull, entries)
  let assert Ok(checked) = signatures.admit_generation(assembled.0, assembled.1)
  checked
}

pub fn declared_identifier_encoding_is_total_for_gleam_test() {
  let assert "Entry" = renderer.upper_identifier("entry", "Type")
  let assert "entry" = renderer.lower_identifier("entry", "value")
  let assert True = renderer.upper_identifier("é", "Type") != ""
}

pub fn renderer_emits_checked_generation_and_unit_codec_test() {
  let assert Ok(source) = renderer.render_signatures(checked())
  let assert True = string.contains(source, "required_generation")
  let assert True = string.contains(source, "pub fn decode_unit")
  let assert True = string.contains(source, "pub fn encode_unit")
  let assert False = string.contains(source, "known_values")
}

pub fn v4_generation_roundtrip_preserves_exact_wire_test() {
  let library_wire = support.wire(support.library())
  let entries =
    json.JsonValueArr([
      json.JsonValueObj([
        #("identity", json.JsonValueStr("entry")),
        #("definition", json.JsonValueStr("entry")),
      ]),
    ])
  let assert Ok(assembled) =
    signatures.assemble_generation(library_wire, json.JsonValueNull, entries)
  let assert Ok(checked) = signatures.admit_generation(assembled.0, assembled.1)
  let assert Ok(encoded_library) =
    signatures.encode_library(signatures.checked_library(checked))
  let assert Ok(decoded_library) = signatures.decode_library(encoded_library)
  let assert Ok(reencoded_library) = signatures.encode_library(decoded_library)
  assert reencoded_library == encoded_library
  let assert Ok(encoded_basis) = signatures.encode_basis(checked)
  assert encoded_basis == assembled.0
  let assert Ok(encoded) = signatures.encode_checked(checked)
  assert encoded == assembled.1
  let assert Ok(value) = values.parse_wire(encoded)
  let assert json.JsonValueStr("ncoh-checked-generation@4") =
    support.field(value, "schema")
}
