// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/option.{None}
import gleam/string
import necoherence/exact_json as json
import necoherence/semantic_generation_values as values
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation

const shallow = 1000

const deep = 10_000

fn reference() -> types.ProfileRef {
  types.ProfileRef("profile", "1", "digest")
}

fn source() -> types.SourceRef {
  types.SourceRef("repository", "revision", "path", "digest", "document", None)
}

fn type_reference(name: String) -> types.TypeRef {
  types.TypeRef(source(), name, [])
}

fn profile() -> types.SemanticProfile {
  types.SemanticProfile(
    reference(),
    [],
    [
      types.IntegerDomainBinding("integer", reference(), types.Unbounded, [
        types.Number,
      ]),
    ],
    "integer",
    types.NumberModel(True),
    None,
    [],
    None,
    [],
    None,
  )
}

fn named_node(name: String, shape: types.TypeShape) -> types.TypeNode {
  types.TypeNode(type_reference(name), shape, None, [], [])
}

fn nested_arrays(depth: Int) -> String {
  string.repeat("[", depth) <> string.repeat("]", depth)
}

fn nested_objects(depth: Int) -> String {
  string.repeat("{\"child\":", depth) <> "{}" <> string.repeat("}", depth)
}

fn parsed(text: String) -> json.JsonValue {
  let assert Ok(value) = values.parse_wire(text)
  value
}

fn array_graph() -> types.SemanticGraph {
  types.SemanticGraph(
    profile(),
    [
      named_node(
        "list",
        types.ArrayShape(types.ArraySpec(
          types.ElementContract(type_reference("list"), False),
          None,
          None,
        )),
      ),
    ],
    [],
  )
}

fn product_graph() -> types.SemanticGraph {
  let child =
    types.FieldSpec(
      "child",
      types.SlotContract(type_reference("node"), False, False),
      types.OccurrenceRef(source(), []),
    )
  types.SemanticGraph(
    profile(),
    [
      named_node(
        "node",
        types.ProductShape(types.ProductSpec([child], types.RejectExtras)),
      ),
    ],
    [],
  )
}

fn unknown_graph() -> types.SemanticGraph {
  types.SemanticGraph(
    profile(),
    [
      named_node("any", types.UnknownShape(types.AnyValue)),
    ],
    [],
  )
}

pub fn nested_arrays_are_read_with_their_size_test() {
  let assert True = json.json_size(parsed(nested_arrays(shallow))) == shallow
  let assert True = json.json_size(parsed(nested_arrays(deep))) == deep
}

pub fn nested_objects_are_read_with_their_size_test() {
  let assert True =
    json.json_size(parsed(nested_objects(shallow))) == shallow + 1
  let assert True = json.json_size(parsed(nested_objects(deep))) == deep + 1
}

pub fn nested_values_are_written_back_as_their_text_test() {
  let assert Ok(arrays) = values.encode_wire(parsed(nested_arrays(deep)))
  let assert True = arrays == nested_arrays(deep)
  let assert Ok(objects) = values.encode_wire(parsed(nested_objects(deep)))
  let assert True = objects == nested_objects(deep)
}

pub fn nested_values_are_encoded_as_exact_values_test() {
  let assert Ok(_) = values.encode_exact(parsed(nested_arrays(shallow)))
  let assert Ok(_) = values.encode_exact(parsed(nested_arrays(deep)))
  let assert Ok(_) = values.encode_exact(parsed(nested_objects(deep)))
}

pub fn nested_arrays_are_accepted_by_a_recursive_array_type_test() {
  let assert Ok(_) =
    validation.validate_value(
      validation.prepare(array_graph()),
      type_reference("list"),
      parsed(nested_arrays(shallow)),
      None,
    )
  let assert Ok(_) =
    validation.validate_value(
      validation.prepare(array_graph()),
      type_reference("list"),
      parsed(nested_arrays(deep)),
      None,
    )
}

pub fn nested_objects_are_accepted_by_a_recursive_product_type_test() {
  let assert Ok(_) =
    validation.validate_value(
      validation.prepare(product_graph()),
      type_reference("node"),
      parsed(nested_objects(shallow)),
      None,
    )
  let assert Ok(_) =
    validation.validate_value(
      validation.prepare(product_graph()),
      type_reference("node"),
      parsed(nested_objects(deep)),
      None,
    )
}

pub fn nested_values_are_accepted_by_an_unknown_type_test() {
  let assert Ok(_) =
    validation.validate_value(
      validation.prepare(unknown_graph()),
      type_reference("any"),
      parsed(nested_arrays(deep)),
      None,
    )
  let assert Ok(_) =
    validation.validate_value(
      validation.prepare(unknown_graph()),
      type_reference("any"),
      parsed(nested_objects(deep)),
      None,
    )
}

pub fn nested_arrays_keep_their_size_when_defaults_are_materialized_test() {
  let assert Ok(defaulted) =
    validation.materialize_defaults(
      validation.prepare(array_graph()),
      type_reference("list"),
      parsed(nested_arrays(deep)),
    )
  let assert True = validation.defaulted_value_applications(defaulted) == []
  let assert True =
    json.json_size(validation.defaulted_value(defaulted)) == deep
}
