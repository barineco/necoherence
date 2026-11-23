// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/result
import gleam/string
import gleeunit/should
import necoherence/exact_json as kdl
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_generation_values as values
import simplifile

fn sorted(value: kdl.JsonValue) -> kdl.JsonValue {
  case value {
    kdl.JsonValueArr(items) -> kdl.JsonValueArr(list.map(items, sorted))
    kdl.JsonValueObj(members) ->
      kdl.JsonValueObj(
        list.map(
          list.sort(members, fn(a, b) { string.compare(a.0, b.0) }),
          fn(member) { #(member.0, sorted(member.1)) },
        ),
      )
    other -> other
  }
}

fn sorted_text(value: kdl.JsonValue) -> String {
  let assert Ok(text) = values.encode_wire(sorted(value))
  text
}

fn fixture() -> kdl.JsonValue {
  let assert Ok(text) =
    simplifile.read("test/fixtures/derivation-lowering-lean.json")
  let assert Ok(value) = values.parse_wire(text)
  value
}

fn member(value: kdl.JsonValue, key: String) -> kdl.JsonValue {
  let assert kdl.JsonValueObj(members) = value
  let assert Ok(found) = list.key_find(members, key)
  found
}

pub fn reachability_encoding_reads_back_lean_wire_test() {
  let lean = fixture()
  let assert Ok(witness) =
    decode.decode_reachability_witness(member(lean, "reachability"))
    |> result.map_error(fn(_) { Nil })
  sorted_text(decode.encode_reachability_witness(witness))
  |> should.equal(sorted_text(member(lean, "reachability")))
}

pub fn acyclicity_encoding_reads_back_lean_wire_test() {
  let lean = fixture()
  let assert Ok(witness) =
    decode.decode_acyclic_witness(member(lean, "acyclicity"))
    |> result.map_error(fn(_) { Nil })
  sorted_text(decode.encode_acyclic_witness(witness))
  |> should.equal(sorted_text(member(lean, "acyclicity")))
}
