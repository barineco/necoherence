// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import gleam/list
import necoherence/exact_json as json
import necoherence/semantic_generation_values as values
import necoherence_tools/semantic_invariant_runner as runner
import semantic_tools_test_support as support

fn replace(
  value: json.JsonValue,
  key: String,
  child: json.JsonValue,
) -> json.JsonValue {
  let assert json.JsonValueObj(members) = value
  json.JsonValueObj(
    list.map(members, fn(member) {
      case member.0 == key {
        True -> #(key, child)
        False -> member
      }
    }),
  )
}

fn run(input: json.JsonValue) -> json.JsonValue {
  let assert Ok(output) = values.parse_wire(runner.run(support.wire(input)))
  output
}

pub fn profile_and_library_entries_admit_the_same_v4_library_test() {
  list.each(["profile", "library"], fn(kind) {
    let output =
      run(
        json.JsonValueObj([
          #("id", json.JsonValueStr(kind)),
          #("kind", json.JsonValueStr(kind)),
          #("library", support.library()),
        ]),
      )
    let assert json.JsonValueStr("Accepted") = support.field(output, "status")
  })
}

pub fn profile_entry_rejects_pr01_before_generation_test() {
  let library = support.library()
  let profile = support.field(library, "profile")
  let reference = support.field(profile, "reference")
  let invalid_reference = replace(reference, "identity", json.JsonValueStr(""))
  let invalid =
    replace(
      library,
      "profile",
      replace(profile, "reference", invalid_reference),
    )
  let output =
    run(
      json.JsonValueObj([
        #("id", json.JsonValueStr("profile-pr01")),
        #("kind", json.JsonValueStr("profile")),
        #("library", invalid),
      ]),
    )
  let assert json.JsonValueStr("Rejected") = support.field(output, "status")
  let failure = support.field(output, "failure")
  let assert json.JsonValueStr("PR01") = support.field(failure, "predicate")
}

pub fn value_adapter_matches_validation_for_unit_test() {
  list.each([json.JsonValueNull, json.JsonValueBool(True)], fn(value) {
    let output =
      run(
        json.JsonValueObj([
          #("id", json.JsonValueStr("unit")),
          #("kind", json.JsonValueStr("value")),
          #("library", support.library()),
          #("type_id", json.JsonValueStr("unit")),
          #("value", value),
        ]),
      )
    let expected = case value {
      json.JsonValueNull -> "Accepted"
      _ -> "Rejected"
    }
    let assert json.JsonValueStr(observed) = support.field(output, "status")
    let assert True = observed == expected
  })
}

pub fn generated_codec_preserves_unit_json_test() {
  let output =
    run(
      json.JsonValueObj([
        #("id", json.JsonValueStr("unit-codec")),
        #("kind", json.JsonValueStr("codec")),
        #("library", support.library()),
        #("type_id", json.JsonValueStr("unit")),
        #("value", json.JsonValueNull),
      ]),
    )
  let assert json.JsonValueStr("Accepted") = support.field(output, "status")
  let assert json.JsonValueNull = support.field(output, "encoded")
}
