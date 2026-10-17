// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/io
import gleam/list
import gleam/option.{None}
import gleam/string
import necoherence/exact_json as json
import necoherence/semantic_composition as composition
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_signatures as signatures
import necoherence/semantic_types as types
import semantic_canonical_profile_test as canonical
import semantic_signatures_test as existing
import semantic_test_support as support

fn text(value: String) -> json.JsonValue {
  json.JsonValueStr(value)
}

fn slot(id: String) -> json.JsonValue {
  json.JsonValueObj([
    #("type_id", text(id)),
    #("required", json.JsonValueBool(True)),
    #("nullable", json.JsonValueBool(False)),
  ])
}

fn port(id: String, type_id: String) -> json.JsonValue {
  json.JsonValueObj([#("id", text(id)), #("contract", slot(type_id))])
}

fn library(
  input: Bool,
  output: Bool,
  resource: Bool,
  type_id: String,
  operation: Bool,
) -> json.JsonValue {
  let source =
    json.JsonValueObj([
      #("repository", text("example")),
      #("revision", text("1")),
      #("path", text("source.json")),
      #("content_digest", text(string.repeat("0", 64))),
    ])
  let origin =
    json.JsonValueObj([
      #("source", source),
      #("locator", json.JsonValueArr([text("/output")])),
    ])
  let cause =
    json.JsonValueObj([
      #("tag", text("ValueContract")),
      #("fields", json.JsonValueObj([#("origin", origin)])),
    ])
  let production =
    json.JsonValueObj([
      #("id", text("resource")),
      #("token_type", text(type_id)),
      #("revision", text("7")),
      #("quantity", text("2")),
      #("provenance", text("produced")),
    ])
  let outcome =
    json.JsonValueObj([
      #("id", text("success")),
      #("form", json.JsonValueObj([#("tag", text("Success"))])),
      #("cause", cause),
      #(
        "value_ports",
        json.JsonValueArr(case output {
          True -> [port("output", type_id)]
          False -> []
        }),
      ),
      #(
        "produced_resources",
        json.JsonValueArr(case resource {
          True -> [production]
          False -> []
        }),
      ),
    ])
  let shape = case operation {
    True ->
      json.JsonValueObj([
        #("tag", text("Operation")),
        #(
          "value",
          json.JsonValueObj([
            #(
              "effect",
              json.JsonValueObj([#("tag", text("HttpRequestResponse"))]),
            ),
            #(
              "inputs",
              json.JsonValueArr(case input {
                True -> [port("input", type_id)]
                False -> []
              }),
            ),
            #("outcomes", json.JsonValueArr([outcome])),
          ]),
        ),
      ])
    False ->
      json.JsonValueObj([#("tag", text("Value")), #("value", text(type_id))])
  }
  let assert Ok(profile) = decode.encode_semantic_profile(support.profile())
  json.JsonValueObj([
    #("schema", text("ncoh-type-signatures@1")),
    #("identity", text("operation-library")),
    #("revision", text("7")),
    #("profile", profile),
    #("sources", json.JsonValueArr([source])),
    #("provenance", json.JsonValueArr([])),
    #("groups", json.JsonValueArr([])),
    #("annotations", json.JsonValueArr([])),
    #(
      "nodes",
      json.JsonValueArr([
        json.JsonValueObj([
          #("id", text("unit")),
          #("shape", json.JsonValueObj([#("tag", text("Unit"))])),
        ]),
      ]),
    ),
    #(
      "definitions",
      json.JsonValueArr([
        json.JsonValueObj([
          #("id", text("operation")),
          #("wire_identity", text("operation-wire")),
          #("shape", shape),
        ]),
      ]),
    ),
  ])
}

fn admitted(
  input: Bool,
  output: Bool,
  resource: Bool,
) -> signatures.AdmittedLibrary {
  let assert Ok(library) =
    signatures.decode_library_value(library(
      input,
      output,
      resource,
      "unit",
      True,
    ))
  let graph = signatures.library_graph(library)
  let assert [node] = graph.nodes
  let assert True =
    node.reference
    == types.TypeRef(
      types.SourceRef("ncoh-type-signatures", "1", "", "", "", None),
      "unit",
      [],
    )
  let assert [definition] = signatures.definitions(library)
  let assert True = definition.id == "operation"
  let assert True = definition.wire_identity == "operation-wire"
  let assert signatures.Operation(contract) = definition.shape
  let assert True = contract.effect == types.HttpRequestResponse
  list.each(contract.inputs, fn(port) {
    let assert True = port.id.value == "input"
    let assert True = port.contract.type_ref == node.reference
    let assert True = port.contract.required
    let assert False = port.contract.nullable
  })
  let assert [outcome] = contract.outcomes
  let assert True = outcome.contract.id.value == "success"
  let assert True = outcome.contract.form == composition.Success
  let assert signatures.ValueContract(origin) = outcome.cause
  let assert True = origin.source.repository == "example"
  let assert True = origin.locator == ["/output"]
  list.each(outcome.contract.value_ports, fn(port) {
    let assert True = port.id.value == "output"
    let assert True = port.contract.type_ref == node.reference
  })
  list.each(outcome.contract.produced_resources, fn(production) {
    let assert True = production.id.value == "resource"
    let assert True = production.token_type == node.reference
    let assert True = production.revision == 7
    let assert True = production.quantity == 2
    let assert True = production.provenance == "produced"
  })
  let assert Ok(wire) = signatures.encode_library(library)
  let assert Ok(roundtrip) = signatures.decode_library(wire)
  let assert True = signatures.library_graph(roundtrip) == graph
  let assert True =
    signatures.definitions(roundtrip) == signatures.definitions(library)
  library
}

pub fn operation_input_uses_graph_node_source_test() {
  let _ = admitted(True, False, False)
}

pub fn operation_output_uses_graph_node_source_test() {
  let _ = admitted(False, True, False)
}

pub fn produced_resource_uses_graph_node_source_test() {
  let _ = admitted(False, False, True)
}

pub fn combined_operation_and_entrypoint_is_admitted_test() {
  let library = admitted(True, True, True)
  let entries =
    json.JsonValueArr([
      json.JsonValueObj([
        #("identity", text("entry")),
        #("definition", text("operation")),
      ]),
    ])
  let assert Ok(wire) = signatures.encode_library(library)
  let assert Ok(#(expected, exchange)) =
    signatures.assemble_generation(wire, json.JsonValueNull, entries)
  let assert Ok(checked) = signatures.admit_generation(expected, exchange)
  let assert True =
    signatures.definitions(signatures.checked_library(checked))
    == signatures.definitions(library)
}

pub fn unresolved_operation_slots_keep_existing_failure_test() {
  list.each(
    [#(True, False, False), #(False, True, False), #(False, False, True)],
    fn(row) {
      let #(input, output, resource) = row
      let assert Error(signatures.Invalid("unresolved definition type")) =
        signatures.decode_library_value(library(
          input,
          output,
          resource,
          "missing",
          True,
        ))
    },
  )
}

pub fn value_definition_control_keeps_type_source_test() {
  let assert Ok(admitted) =
    signatures.decode_library_value(library(False, False, False, "unit", False))
  let assert [node] = signatures.library_graph(admitted).nodes
  let assert True = signatures.type_ref(admitted, "unit") == node.reference
  let assert [
    signatures.SignatureDefinition(
      "operation",
      "operation-wire",
      signatures.Value("unit"),
    ),
  ] = signatures.definitions(admitted)
  let assert Error(signatures.Invalid("unresolved definition type")) =
    signatures.decode_library_value(library(
      False,
      False,
      False,
      "missing",
      False,
    ))
}

fn replace_member(
  value: json.JsonValue,
  key: String,
  replacement: json.JsonValue,
) -> json.JsonValue {
  let assert json.JsonValueObj(members) = value
  json.JsonValueObj(
    list.map(members, fn(member) {
      case member.0 == key {
        True -> #(key, replacement)
        False -> member
      }
    }),
  )
}

pub fn resource_scalar_failures_keep_generic_wire_paths_test() {
  let subject = library(False, False, True, "unit", True)
  let assert json.JsonValueObj(members) = subject
  let assert Ok(json.JsonValueArr([definition])) =
    list.key_find(members, "definitions")
  let assert json.JsonValueObj(definition_members) = definition
  let assert Ok(shape) = list.key_find(definition_members, "shape")
  let assert json.JsonValueObj(shape_members) = shape
  let assert Ok(operation) = list.key_find(shape_members, "value")
  let assert json.JsonValueObj(operation_members) = operation
  let assert Ok(json.JsonValueArr([outcome])) =
    list.key_find(operation_members, "outcomes")
  let assert json.JsonValueObj(outcome_members) = outcome
  let assert Ok(json.JsonValueArr([production])) =
    list.key_find(outcome_members, "produced_resources")
  let assert Ok(reference) = decode.encode_type_ref(support.reference("unit"))
  let generic = replace_member(production, "token_type", reference)
  list.each(
    [
      #("id", json.JsonValueBool(False)),
      #("revision", text("01")),
      #("revision", text("-1")),
      #("quantity", text("x")),
      #("quantity", json.JsonValueBool(False)),
      #("provenance", json.JsonValueBool(False)),
    ],
    fn(row) {
      let #(field, value) = row
      let assert Error(expected) =
        decode.decode_resource_production(replace_member(generic, field, value))
      let production = replace_member(production, field, value)
      let outcome =
        replace_member(
          outcome,
          "produced_resources",
          json.JsonValueArr([production]),
        )
      let operation =
        replace_member(operation, "outcomes", json.JsonValueArr([outcome]))
      let shape = replace_member(shape, "value", operation)
      let definition = replace_member(definition, "shape", shape)
      let input =
        replace_member(subject, "definitions", json.JsonValueArr([definition]))
      let assert Error(signatures.Wire(actual)) =
        signatures.decode_library_value(input)
      let assert True = actual == expected
    },
  )
}

pub fn main() {
  operation_input_uses_graph_node_source_test()
  operation_output_uses_graph_node_source_test()
  produced_resource_uses_graph_node_source_test()
  combined_operation_and_entrypoint_is_admitted_test()
  unresolved_operation_slots_keep_existing_failure_test()
  resource_scalar_failures_keep_generic_wire_paths_test()
  let assert Error(_) = value_definition_control_keeps_type_source_test()
  let assert Error(_) =
    existing.checked_generation_v4_is_the_only_admitted_root_wire_test()
  existing.library_shape_wire_roundtrips_wrapper_sealed_union_and_never_test()
  existing.removed_signature_shape_tags_are_rejected_test()
  let assert Error(_) =
    existing.compatibility_union_closed_field_is_rejected_as_wire_failure_test()
  let assert Ok(_) =
    canonical.canonical_profile_roundtrip_preserves_declarations_test()
  canonical.canonical_format_wire_roundtrips_every_constructor_test()
  let assert Error(_) =
    canonical.canonical_profile_admission_preserves_typed_failure_test()
  canonical.canonical_value_failure_roundtrip_preserves_wire_test()
  io.println(
    "7 operation source tests and 8 related library/generation tests passed",
  )
}
