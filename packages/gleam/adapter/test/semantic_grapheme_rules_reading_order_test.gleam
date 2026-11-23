// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import necoherence/exact_json as json
import necoherence/semantic_generation_decode as decode

fn text(value: String) -> json.JsonValue {
  json.JsonValueStr(value)
}

fn rules(properties: json.JsonValue) -> json.JsonValue {
  json.JsonValueObj([
    #(
      "reference",
      json.JsonValueObj([
        #("identity", text("profile")),
        #("revision", text("1")),
        #("content_digest", text("digest")),
      ]),
    ),
    #(
      "component",
      json.JsonValueObj([
        #("unicode_version", text("16.0.0")),
        #("uax29_revision", text("45")),
        #("cluster_profile", text("default")),
        #("extra", json.JsonValueNum(1)),
      ]),
    ),
    #("table_sha256", text("digest")),
    #("sources", json.JsonValueArr([])),
    #("properties", properties),
    #("extended_pictographic", json.JsonValueArr([])),
    #("indic_conjunct", json.JsonValueArr([])),
  ])
}

pub fn component_is_read_before_the_ranges_test() {
  let assert Error(decode.UnknownField(_, "extra")) =
    decode.decode_grapheme_rules(rules(json.JsonValueNum(1)))
}
