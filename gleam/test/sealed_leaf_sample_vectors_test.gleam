// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import necoherence/exact_json as json
import necoherence/semantic_composition as composition
import necoherence/semantic_generation_values as values
import necoherence/semantic_signatures as signatures
import necoherence/semantic_types as types

@external(erlang, "host_file_adapter_ffi", "read")
fn read_file(path: String) -> Result(String, Nil)

fn field(value: json.JsonValue, key: String) -> json.JsonValue {
  let assert json.JsonValueObj(members) = value
  let assert Ok(value) = list.key_find(members, key)
  value
}

fn text(value: json.JsonValue) -> String {
  let assert json.JsonValueStr(value) = value
  value
}

fn array(value: json.JsonValue) -> List(json.JsonValue) {
  let assert json.JsonValueArr(value) = value
  value
}

fn library(
  profile: json.JsonValue,
  sealed: json.JsonValue,
) -> signatures.AdmittedLibrary {
  let assert Ok(library) =
    signatures.decode_library_value(
      json.JsonValueObj([
        #("schema", json.JsonValueStr("ncoh-type-signatures@1")),
        #("identity", json.JsonValueStr("sealed-leaf-samples")),
        #("revision", json.JsonValueStr("1")),
        #("profile", profile),
        #(
          "nodes",
          json.JsonValueArr([
            json.JsonValueObj([
              #("id", json.JsonValueStr("value")),
              #("shape", sealed),
            ]),
          ]),
        ),
        #("sources", json.JsonValueArr([])),
        #("provenance", json.JsonValueArr([])),
        #("groups", json.JsonValueArr([])),
        #("annotations", json.JsonValueArr([])),
        #("definitions", json.JsonValueArr([])),
      ]),
    )
  library
}

pub fn shared_sealed_leaf_sample_vectors_match_lean_test() {
  let assert Ok(source) =
    read_file("../comparison/declaration/sealed_leaf_sample_vectors.json")
  let assert Ok(vectors) = values.parse_wire(source)
  let assert json.JsonValueStr("sealed-leaf-sample-vectors@1") =
    field(vectors, "schema")
  let cases = array(field(vectors, "cases"))
  let assert 7 = list.length(cases)
  list.each(cases, fn(case_) {
    let library = library(field(vectors, "profile"), field(case_, "sealed"))
    let graph = signatures.library_graph(library)
    let contract =
      types.SlotContract(signatures.type_ref(library, "value"), True, False)
    let samples =
      composition.bounded_slot_samples(
        graph,
        contract,
        list.length(graph.nodes) + 1,
        32,
      )
    let actual =
      list.map(samples.values, fn(sample) {
        let assert types.Present(value) = sample
        let assert Ok(_) = signatures.validate_value(library, "value", value)
        value
      })
    let assert Ok(actual) = signatures.canonical(json.JsonValueArr(actual))
    let assert Ok(expected) = signatures.canonical(field(case_, "expected"))
    assert actual == expected as text(field(case_, "id"))
  })
}
