// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/option.{None, Some}
import necoherence/exact_json as json
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_types as types

fn absolute_uri(max_bytes: json.JsonValue) -> json.JsonValue {
  json.JsonValueObj([
    #("tag", json.JsonValueStr("AbsoluteUri")),
    #("fields", json.JsonValueObj([#("max_bytes", max_bytes)])),
  ])
}

pub fn absolute_uri_maximum_is_optional_test() {
  let assert Ok(types.AbsoluteUri(None)) =
    decode.decode_format_rule(absolute_uri(json.JsonValueNull))
  let assert Ok(types.AbsoluteUri(Some(8))) =
    decode.decode_format_rule(absolute_uri(json.JsonValueStr("8")))
  let assert Ok(wire) = decode.encode_format_rule(types.AbsoluteUri(None))
  let assert True = wire == absolute_uri(json.JsonValueNull)
}
