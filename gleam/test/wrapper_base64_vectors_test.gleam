// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/int
import gleam/list
import gleam/option.{Some}
import necoherence/exact_json as json
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_generation_native as native
import necoherence/semantic_generation_runtime as runtime
import necoherence/semantic_generation_values as values
import necoherence/semantic_signatures as signatures
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation

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

fn path_value(step: types.PathStep) -> json.JsonValue {
  let #(tag, value) = case step {
    types.Field(name) -> #("Field", name)
    types.Index(index) -> #("Index", int.to_string(index))
    types.Variant(name) -> #("Variant", name)
  }
  json.JsonValueObj([
    #("tag", json.JsonValueStr(tag)),
    #("value", json.JsonValueStr(value)),
  ])
}

fn outcome(
  library: signatures.AdmittedLibrary,
  root: String,
  input: json.JsonValue,
) -> json.JsonValue {
  let #(accepted, condition, path) = case
    signatures.validate_value(library, root, input)
  {
    Ok(_) -> #(True, json.JsonValueNull, [])
    Error(runtime.Constraint(validation.Rejected(failure))) -> {
      let assert Ok(condition) =
        decode.encode_value_condition(failure.condition)
      #(False, condition, failure.value_path)
    }
    Error(_) -> panic as "value validation did not resolve"
  }
  json.JsonValueObj([
    #("accepted", json.JsonValueBool(accepted)),
    #("condition", condition),
    #("path", json.JsonValueArr(list.map(path, path_value))),
  ])
}

fn library(
  profile: json.JsonValue,
  nodes: json.JsonValue,
) -> signatures.AdmittedLibrary {
  let assert Ok(library) =
    signatures.decode_library_value(
      json.JsonValueObj([
        #("schema", json.JsonValueStr("ncoh-type-signatures@1")),
        #("identity", json.JsonValueStr("wrapper-base64")),
        #("revision", json.JsonValueStr("1")),
        #("profile", profile),
        #("nodes", nodes),
        #("sources", json.JsonValueArr([])),
        #("provenance", json.JsonValueArr([])),
        #("groups", json.JsonValueArr([])),
        #("annotations", json.JsonValueArr([])),
        #("definitions", json.JsonValueArr([])),
      ]),
    )
  library
}

pub fn shared_wrapper_base64_vectors_match_lean_test() {
  let assert Ok(source) =
    read_file("../comparison/declaration/wrapper_base64_vectors.json")
  let assert Ok(vectors) = values.parse_wire(source)
  let assert json.JsonValueStr("wrapper-base64-vectors@1") =
    field(vectors, "schema")
  let branches = array(field(vectors, "branches"))
  let assert 25 = list.length(branches)
  let assert 25 =
    list.length(
      list.unique(list.map(branches, fn(branch) { field(branch, "id") })),
    )
  let count =
    list.fold(branches, 0, fn(count, branch) {
      let profile =
        field(field(vectors, "profiles"), text(field(branch, "profile")))
      let graph =
        field(field(vectors, "type_graphs"), text(field(branch, "type_graph")))
      let library = library(profile, field(graph, "nodes"))
      let root = text(field(graph, "root"))
      let cases = array(field(branch, "cases"))
      let assert False = list.is_empty(cases)
      let assert True =
        list.length(cases)
        == list.length(
          list.unique(list.map(cases, fn(case_) { field(case_, "id") })),
        )
      list.each(cases, fn(case_) {
        let actual = outcome(library, root, field(case_, "input"))
        let assert Ok(actual) = signatures.canonical(actual)
        let assert Ok(expected) = signatures.canonical(field(case_, "expected"))
        assert actual == expected as text(field(case_, "id"))
        case text(field(branch, "type_graph")), field(case_, "input") {
          "bytes", json.JsonValueObj([#("bytes", json.JsonValueStr(encoded))])
          -> {
            let assert Some(policy) =
              signatures.library_graph(library).profile.bytes_policy
            let accepted = case
              native.decode_bytes_with_policy(policy, encoded)
            {
              Ok(_) -> True
              Error(_) -> False
            }
            let expected = field(field(case_, "expected"), "accepted")
            assert json.JsonValueBool(accepted) == expected
              as text(field(case_, "id"))
            case accepted {
              True -> {
                let assert Ok(_) = native.decode_bytes(encoded)
                Nil
              }
              False -> Nil
            }
          }
          _, _ -> Nil
        }
      })
      count + list.length(cases)
    })
  let assert 55 = count
}

pub fn standalone_decoder_uses_shared_base64_rules_test() {
  let assert Ok([251, 255]) = native.decode_bytes("+_8=")
  let assert Ok([97]) = native.decode_bytes("YQ")
  let assert Ok([97]) = native.decode_bytes("YR==")
  let assert Ok([97, 98]) = native.decode_bytes("YWJ=")
  let assert Ok([97, 98, 99]) = native.decode_bytes("YWJj")
  let assert Ok([]) = native.decode_bytes("")
  list.each(["YQ=", "YWJj=", "YWJj==", "Y Q=="], fn(text) {
    let assert Error(_) = native.decode_bytes(text)
  })
  let assert Ok(encoded) = native.encode_bytes([0, 97, 251, 255])
  let assert Ok([0, 97, 251, 255]) = native.decode_bytes(encoded)
  let bytes = list.index_map(list.repeat(Nil, 256), fn(_, index) { index })
  let assert Ok(encoded) = native.encode_bytes(bytes)
  let assert Ok(decoded) = native.decode_bytes(encoded)
  assert decoded == bytes
}
