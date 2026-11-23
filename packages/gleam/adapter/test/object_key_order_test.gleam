// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import necoherence/exact_json as json
import necoherence/semantic_generation_values as values

pub fn wire_objects_order_their_members_by_key_test() {
  let assert Ok(json.JsonValueObj([
    #("a", json.JsonValueNum(2)),
    #("b", json.JsonValueNum(1)),
  ])) = values.parse_wire("{\"b\":1,\"a\":2}")
  let assert Ok(json.JsonValueObj([
    #("B", json.JsonValueNum(2)),
    #("a", json.JsonValueNum(1)),
  ])) = values.parse_wire("{\"a\":1,\"B\":2}")
}

pub fn wire_objects_order_nested_members_by_key_test() {
  let assert Ok(json.JsonValueObj([
    #(
      "x",
      json.JsonValueObj([
        #("y", json.JsonValueNum(1)),
        #("z", json.JsonValueNum(2)),
      ]),
    ),
  ])) = values.parse_wire("{\"x\":{\"z\":2,\"y\":1}}")
}
