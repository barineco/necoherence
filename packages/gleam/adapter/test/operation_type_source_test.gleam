// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import necoherence/composition_plan
import necoherence/exact_json as json
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_generation_values as values
import necoherence/semantic_signatures as signatures
import necoherence/semantic_types as types
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

fn outcome_id(value: json.JsonValue, id: String) -> json.JsonValue {
  case value {
    json.JsonValueObj(members) ->
      json.JsonValueObj(
        list.map(members, fn(member) {
          case member.0 {
            "id" -> #("id", text(id))
            _ -> member
          }
        }),
      )
    _ -> value
  }
}

fn replace_outcomes(
  value: json.JsonValue,
  outcomes: List(json.JsonValue),
) -> json.JsonValue {
  case value {
    json.JsonValueObj(members) ->
      json.JsonValueObj(
        list.map(members, fn(member) {
          case member.0 {
            "outcomes" -> #("outcomes", json.JsonValueArr(outcomes))
            _ -> #(member.0, replace_outcomes(member.1, outcomes))
          }
        }),
      )
    json.JsonValueArr(items) ->
      json.JsonValueArr(
        list.map(items, fn(item) { replace_outcomes(item, outcomes) }),
      )
    _ -> value
  }
}

pub fn provenance_digest_orders_operation_outcomes_by_id_test() {
  let base = library(False, False, False, "unit", True)
  let assert json.JsonValueObj(library_members) = base
  let assert Ok(json.JsonValueArr([json.JsonValueObj(definition_members)])) =
    list.key_find(library_members, "definitions")
  let assert Ok(json.JsonValueObj(shape_members)) =
    list.key_find(definition_members, "shape")
  let assert Ok(json.JsonValueObj(operation_members)) =
    list.key_find(shape_members, "value")
  let assert Ok(json.JsonValueArr([outcome])) =
    list.key_find(operation_members, "outcomes")
  let declared =
    replace_outcomes(base, [
      outcome_id(outcome, "second"),
      outcome_id(outcome, "first"),
    ])
  let ordered =
    replace_outcomes(base, [
      outcome_id(outcome, "first"),
      outcome_id(outcome, "second"),
    ])
  let assert Ok(declared) = signatures.decode_library_value(declared)
  let assert Ok(ordered) = signatures.decode_library_value(ordered)
  let assert Ok(#(_, declared_provenance, _)) =
    signatures.signature_digests(declared)
  let assert Ok(#(_, ordered_provenance, _)) =
    signatures.signature_digests(ordered)
  let assert True = declared_provenance == ordered_provenance
  let assert Ok("0.0000000001e-90") =
    signatures.canonical(json.JsonValueDec("1e-100"))
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
  let assert True = outcome.contract.form == composition_plan.Success
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

pub fn signature_composition_outcome_decodes_type_id_test() {
  let raw = library(False, True, False, "unit", True)
  let assert json.JsonValueObj(library_members) = raw
  let assert Ok(json.JsonValueArr([json.JsonValueObj(definition_members)])) =
    list.key_find(library_members, "definitions")
  let assert Ok(json.JsonValueObj(shape_members)) =
    list.key_find(definition_members, "shape")
  let assert Ok(json.JsonValueObj(operation_members)) =
    list.key_find(shape_members, "value")
  let assert Ok(json.JsonValueArr([json.JsonValueObj(outcome_members)])) =
    list.key_find(operation_members, "outcomes")
  let assert Ok(json.JsonValueArr([json.JsonValueObj(port_members)])) =
    list.key_find(outcome_members, "value_ports")
  let outcome =
    json.JsonValueObj(
      list.map(outcome_members, fn(member) {
        case member.0 {
          "value_ports" -> #(
            member.0,
            json.JsonValueArr([
              json.JsonValueObj(
                list.append(port_members, [
                  #("resource_production", json.JsonValueNull),
                ]),
              ),
            ]),
          )
          _ -> member
        }
      }),
    )
  let admitted = admitted(False, True, False)
  let assert Ok(#(contract, _)) =
    decode.decode_outcome_contract(outcome, fn(_) { Ok(Nil) })
  let assert [port] = contract.value_ports
  let assert [node] = signatures.library_graph(admitted).nodes
  let assert True = port.contract.type_ref == node.reference
}

fn inclusion_certificate(
  admitted: signatures.AdmittedLibrary,
  source_shape: json.JsonValue,
) -> json.JsonValue {
  let assert Ok(basis) =
    signatures.generation_basis(
      admitted,
      json.JsonValueNull,
      json.JsonValueArr([]),
    )
  let contract = slot("unit")
  let assert Ok(destination_shape) =
    signatures.encode_library_shape(signatures.UnitShape)
  json.JsonValueObj([
    #("basis", basis),
    #("source", contract),
    #("destination", contract),
    #("empty_types", json.JsonValueArr([])),
    #(
      "pairs",
      json.JsonValueArr([
        json.JsonValueObj([
          #(
            "pair",
            json.JsonValueObj([
              #("source", contract),
              #("destination", contract),
              #("source_tag", json.JsonValueNull),
            ]),
          ),
          #("source_shape", source_shape),
          #("destination_shape", destination_shape),
          #("rule", json.JsonValueObj([#("tag", text("SameDefinedType"))])),
          #("children", json.JsonValueArr([])),
        ]),
      ]),
    ),
    #("root", text("0")),
  ])
}

fn decode_inclusion(
  admitted: signatures.AdmittedLibrary,
  wire: json.JsonValue,
) -> Result(composition_plan.InclusionCertificate, signatures.Failure) {
  decode.decode_inclusion_certificate(
    wire,
    signatures.derivation_decoder(admitted),
  )
  |> result.map_error(signatures.Wire)
}

pub fn inclusion_certificate_wire_roundtrip_uses_semantic_shapes_test() {
  let admitted = admitted(False, False, False)
  let assert Ok(source_shape) =
    signatures.encode_library_shape(signatures.UnitShape)
  let wire = inclusion_certificate(admitted, source_shape)
  let assert Ok(encoded) = values.encode_wire(wire)
  let assert Ok(restored) = values.parse_wire(encoded)
  let assert Ok(certificate) = decode_inclusion(admitted, restored)
  let assert [entry] = certificate.pairs
  let assert [node] = signatures.library_graph(admitted).nodes
  let assert True = entry.source_shape == node.shape
  let assert True = entry.destination_shape == node.shape
}

pub fn inclusion_certificate_rejects_declared_shape_mismatch_test() {
  let admitted = admitted(False, False, False)
  let assert Ok(mismatch) =
    signatures.encode_library_shape(
      signatures.BooleanShape(types.BooleanSpec(None, None)),
    )
  let assert Error(signatures.Wire(decode.SyntaxFailure(
    _,
    "inclusion shape mismatch",
  ))) = decode_inclusion(admitted, inclusion_certificate(admitted, mismatch))
}

pub fn unresolved_operation_slots_reject_unresolved_definition_types_with_lb01_test() {
  list.each(
    [#(True, False, False), #(False, True, False), #(False, False, True)],
    fn(row) {
      let #(input, output, resource) = row
      let assert Error(signatures.LibraryRejected(types.LibraryCheck(types.LibraryFailure(
        _,
        types.Lb01,
        _,
      )))) =
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
  let assert Error(signatures.LibraryRejected(types.LibraryCheck(types.LibraryFailure(
    _,
    types.Lb01,
    _,
  )))) =
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
  let generic = replace_member(production, "token_type", text("unit"))
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
      let containers = [
        "definitions", "[0]", "shape", "outcomes", "[0]", "produced_resources",
        "[0]",
      ]
      let expected =
        list.fold(list.reverse(containers), expected, fn(failure, segment) {
          decode.prepend_path(segment, failure)
        })
      let assert decode.SyntaxFailure(expected_path, _) = expected
      let assert decode.SyntaxFailure(actual_path, _) = actual
      let assert True = actual_path == expected_path
    },
  )
}

fn replace_key(
  value: json.JsonValue,
  key: String,
  replacement: json.JsonValue,
) -> json.JsonValue {
  case value {
    json.JsonValueObj(members) ->
      json.JsonValueObj(
        list.map(members, fn(member) {
          case member.0 == key {
            True -> #(key, replacement)
            False -> #(member.0, replace_key(member.1, key, replacement))
          }
        }),
      )
    json.JsonValueArr(items) ->
      json.JsonValueArr(
        list.map(items, fn(item) { replace_key(item, key, replacement) }),
      )
    _ -> value
  }
}

fn production(id: String) -> json.JsonValue {
  json.JsonValueObj([
    #("id", text(id)),
    #("token_type", text("unit")),
    #("revision", text("7")),
    #("quantity", text("2")),
    #("provenance", text("produced")),
  ])
}

pub fn distinct_produced_resource_ids_are_admitted_test() {
  let value =
    replace_key(
      library(False, False, True, "unit", True),
      "produced_resources",
      json.JsonValueArr([production("stock"), production("fuel")]),
    )
  let assert Ok(_) = signatures.decode_library_value(value)
}

pub fn duplicate_produced_resource_ids_are_rejected_with_lb01_test() {
  let value =
    replace_key(
      library(False, False, True, "unit", True),
      "produced_resources",
      json.JsonValueArr([production("stock"), production("stock")]),
    )
  let assert Error(signatures.LibraryRejected(types.LibraryCheck(types.LibraryFailure(
    _,
    types.Lb01,
    _,
  )))) = signatures.decode_library_value(value)
}

pub fn duplicate_value_port_ids_are_rejected_with_lb01_test() {
  let value =
    replace_key(
      library(False, True, False, "unit", True),
      "value_ports",
      json.JsonValueArr([port("output", "unit"), port("output", "unit")]),
    )
  let assert Error(signatures.LibraryRejected(types.LibraryCheck(types.LibraryFailure(
    _,
    types.Lb01,
    _,
  )))) = signatures.decode_library_value(value)
}

pub fn library_schema_outside_the_version_is_rejected_with_lb01_test() {
  let value =
    replace_key(
      library(False, False, False, "unit", True),
      "schema",
      text("ncoh-type-signatures@9"),
    )
  let assert Error(signatures.LibraryRejected(types.LibraryCheck(types.LibraryFailure(
    _,
    types.Lb01,
    _,
  )))) = signatures.decode_library_value(value)
}

pub fn list_element_failures_keep_their_index_in_the_path_test() {
  let subject = library(False, False, False, "unit", True)
  let assert json.JsonValueObj(members) = subject
  let assert Ok(json.JsonValueArr([definition])) =
    list.key_find(members, "definitions")
  let assert json.JsonValueObj(definition_members) = definition
  let unknown =
    json.JsonValueObj(list.append(definition_members, [#("note", text("x"))]))
  let input =
    replace_member(
      subject,
      "definitions",
      json.JsonValueArr([definition, unknown]),
    )
  let assert Error(signatures.Wire(decode.UnknownField(
    ["definitions", "[1]"],
    "note",
  ))) = signatures.decode_library_value(input)
}
