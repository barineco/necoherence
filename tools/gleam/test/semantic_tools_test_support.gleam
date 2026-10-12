// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import gleam/option.{None}
import gleam/string
import necoherence/exact_json as json
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_generation_values as values
import necoherence/semantic_signatures as signatures
import necoherence/semantic_types as types

pub fn profile() -> types.SemanticProfile {
  let reference = types.ProfileRef("profile", "4", string.repeat("a", 64))
  types.SemanticProfile(
    reference,
    [],
    [
      types.IntegerDomainBinding("integer", reference, types.Unbounded, [
        types.Number,
      ]),
    ],
    "integer",
    types.NumberModel(True),
    None,
    [types.FormatBinding("text", reference, types.Text)],
    None,
    [],
    None,
  )
}

pub fn library() -> json.JsonValue {
  let assert Ok(profile) = decode.encode_semantic_profile(profile())
  let assert Ok(unit) = signatures.encode_library_shape(signatures.UnitShape)
  json.JsonValueObj([
    #("schema", json.JsonValueStr("ncoh-type-signatures@1")),
    #("identity", json.JsonValueStr("test-library")),
    #("revision", json.JsonValueStr("4")),
    #("profile", profile),
    #("sources", json.JsonValueArr([])),
    #("provenance", json.JsonValueArr([])),
    #("groups", json.JsonValueArr([])),
    #("annotations", json.JsonValueArr([])),
    #(
      "nodes",
      json.JsonValueArr([
        json.JsonValueObj([
          #("id", json.JsonValueStr("unit")),
          #("shape", unit),
        ]),
      ]),
    ),
    #(
      "definitions",
      json.JsonValueArr([
        json.JsonValueObj([
          #("id", json.JsonValueStr("entry")),
          #("wire_identity", json.JsonValueStr("Entry")),
          #(
            "shape",
            json.JsonValueObj([
              #("tag", json.JsonValueStr("Value")),
              #("value", json.JsonValueStr("unit")),
            ]),
          ),
        ]),
      ]),
    ),
  ])
}

pub fn wire(value: json.JsonValue) -> String {
  let assert Ok(encoded) = values.encode_wire(value)
  encoded
}

pub fn field(value: json.JsonValue, name: String) -> json.JsonValue {
  let assert Ok(value) = signatures.field(value, name)
  value
}
