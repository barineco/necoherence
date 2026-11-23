// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{None, Some}
import necoherence/admission_failure as admission
import necoherence/composition_plan
import necoherence/exact_json as json
import necoherence/inclusion
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_generation_values as values
import necoherence/semantic_signatures as signatures
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import semantic_test_support as support

fn expected_basis() -> String {
  "{\"basis\":{\"signature_schema\":\"ncoh-type-signatures@1\",\"library_identity\":\"library\",\"library_revision\":\"1\",\"profile\":{\"identity\":\"profile\",\"revision\":\"1\",\"content_digest\":\"digest\"},\"graph_sha256\":\"graph\",\"provenance_sha256\":\"provenance\",\"metadata_sha256\":\"metadata\",\"problem_sha256\":null,\"observations_sha256\":null,\"entrypoints_sha256\":\"entrypoints\"},\"observations\":null}"
}

pub fn checked_generation_v5_is_the_only_admitted_root_wire_test() {
  let input =
    json.JsonValueObj([
      #("schema", json.JsonValueStr("ncoh-checked-generation@3")),
      #("basis", json.JsonValueObj([])),
      #("signatures", json.JsonValueObj([])),
      #("composition", json.JsonValueNull),
      #("entrypoints", json.JsonValueArr([])),
    ])
  let assert Ok(wire) = values.encode_wire(input)
  let assert Error(admission.UnsupportedSchema("ncoh-checked-generation@3")) =
    signatures.admit_generation(expected_basis(), wire)
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

pub fn inclusion_rule_wire_decodes_same_defined_type_and_unit_one_to_one_test() {
  let wire = json.JsonValueObj([#("tag", json.JsonValueStr("SameDefinedType"))])
  let assert Ok(encoded) = values.encode_wire(wire)
  let assert Ok(restored) = values.parse_wire(encoded)
  let assert Ok(composition_plan.SameDefinedType) =
    decode.decode_inclusion_rule(restored)
  let assert Ok(composition_plan.InclusionUnit) =
    decode.decode_inclusion_rule(
      json.JsonValueObj([#("tag", json.JsonValueStr("Unit"))]),
    )
}

pub fn equal_primitive_and_product_require_same_defined_type_test() {
  let graph =
    support.graph([
      support.node(
        "boolean-source",
        types.BooleanShape(types.BooleanSpec(None, None)),
      ),
      support.node(
        "boolean-destination",
        types.BooleanShape(types.BooleanSpec(None, None)),
      ),
      support.node(
        "product-source",
        types.ProductShape(types.ProductSpec([], types.RejectExtras)),
      ),
      support.node(
        "product-destination",
        types.ProductShape(types.ProductSpec([], types.RejectExtras)),
      ),
    ])
  list.each(
    [
      #(
        "boolean-source",
        "boolean-destination",
        composition_plan.InclusionBoolean,
      ),
      #(
        "product-source",
        "product-destination",
        composition_plan.InclusionProduct,
      ),
    ],
    fn(pair) {
      let source = types.SlotContract(support.reference(pair.0), True, False)
      let destination =
        types.SlotContract(support.reference(pair.1), True, False)
      let assert inclusion.Compatible(certificate) =
        inclusion.check_assignable(
          validation.prepare(graph),
          source,
          destination,
          10,
        )
      let assert [entry] = certificate.pairs
      let assert composition_plan.SameDefinedType = entry.rule
      let forged =
        composition_plan.InclusionCertificate(
          certificate.basis,
          certificate.source,
          certificate.destination,
          certificate.empty_types,
          [
            composition_plan.PairEntry(
              entry.pair,
              entry.source_shape,
              entry.destination_shape,
              pair.2,
              entry.children,
            ),
          ],
          certificate.root,
        )
      let assert Error(composition_plan.RuleMismatch(0)) =
        inclusion.verify_inclusion(
          validation.prepare(graph),
          source,
          destination,
          forged,
        )
    },
  )
}
