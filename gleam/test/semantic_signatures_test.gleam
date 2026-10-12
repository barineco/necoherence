// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{None, Some}
import necoherence/exact_json as json
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_generation_values as values
import necoherence/semantic_signatures as signatures
import necoherence/semantic_types as types

pub fn checked_generation_v4_is_the_only_admitted_root_wire_test() {
  let input =
    json.JsonValueObj([
      #("schema", json.JsonValueStr("ncoh-checked-generation@3")),
      #("basis", json.JsonValueObj([])),
      #("signatures", json.JsonValueObj([])),
      #("composition", json.JsonValueNull),
      #("entrypoints", json.JsonValueArr([])),
    ])
  let assert Ok(wire) = values.encode_wire(input)
  let assert Error(signatures.Wire(decode.UnsupportedSchema(
    "ncoh-checked-generation@3",
  ))) = signatures.admit_generation("{}", wire)
}

pub fn library_shape_wire_roundtrips_wrapper_sealed_union_and_never_test() {
  let shapes = [
    signatures.StringShape(types.StringSpec(
      None,
      [],
      Some("text"),
      None,
      None,
      [],
      None,
    )),
    signatures.SealedShape("sealed", []),
    signatures.TaggedUnionShape(
      signatures.LibraryUnionSpec([
        signatures.LibraryUnionBranch(
          "target",
          "text",
          types.Kind(types.StringKind),
        ),
      ]),
    ),
    signatures.NeverShape,
  ]
  list.each(shapes, fn(shape) {
    let assert Ok(encoded) = signatures.encode_library_shape(shape)
    let assert Ok(decoded) = signatures.decode_library_shape(encoded)
    let assert True = decoded == shape
  })
}

pub fn removed_signature_shape_tags_are_rejected_test() {
  list.each(["CidLink", "Blob", "Record"], fn(tag) {
    let assert Error(_) =
      signatures.decode_library_shape(
        json.JsonValueObj([#("tag", json.JsonValueStr(tag))]),
      )
  })
}

pub fn compatibility_union_closed_field_is_rejected_as_wire_failure_test() {
  let value =
    json.JsonValueObj([
      #("tag", json.JsonValueStr("TaggedUnion")),
      #(
        "value",
        json.JsonValueObj([
          #("branches", json.JsonValueArr([])),
          #("closed", json.JsonValueBool(True)),
        ]),
      ),
    ])
  let assert Error(signatures.Wire(decode.UnknownField([], "closed"))) =
    signatures.decode_library_shape(value)
}
