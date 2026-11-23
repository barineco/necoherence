// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import composition_wire_support.{
  type Step, Index, Key, admit_composition, exchange_of, member, path_with_key,
  update, with_extra_key, with_member, without_member,
}
import gleam/list
import gleam/option.{Some}
import necoherence/admission_failure as admission
import necoherence/exact_json as json
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_signatures as signatures

fn tag_only(name: String) -> fn(json.JsonValue) -> json.JsonValue {
  fn(_) { json.JsonValueObj([#("tag", json.JsonValueStr(name))]) }
}

fn first_inclusion_path(composition: json.JsonValue) -> List(Step) {
  let assert Some(path) = path_with_key(composition, "pairs")
  path
}

pub fn extra_cause_key_in_a_derivation_record_is_an_unknown_field_test() {
  let exchange = exchange_of("accepted-composition")
  let composition = member(exchange, "composition")
  let pair_record =
    list.flatten([
      first_inclusion_path(composition),
      [Key("pairs"), Index(0), Key("pair")],
    ])
  list.each([[Key("derivation"), Key("selection")], pair_record], fn(path) {
    let assert Error(admission.Wire(decode.UnknownField(_, "cause"))) =
      admit_composition(
        exchange,
        update(composition, path, fn(record) {
          with_member(record, "cause", json.JsonValueNull)
        }),
      )
  })
}

pub fn problem_root_keys_are_checked_before_the_signatures_are_read_test() {
  let exchange = exchange_of("accepted-composition")
  let composition = member(exchange, "composition")
  let assert Error(admission.Wire(decode.UnknownField(_, "extra"))) =
    admit_composition(
      exchange,
      update(composition, [Key("problem")], fn(problem) {
        with_extra_key(without_member(problem, "signatures"))
      }),
    )
}

pub fn signature_keys_are_checked_before_the_reference_is_read_test() {
  let exchange = exchange_of("accepted-composition")
  let composition = member(exchange, "composition")
  let assert Error(admission.Wire(decode.UnknownField(_, "extra"))) =
    admit_composition(
      exchange,
      update(
        composition,
        [Key("problem"), Key("signatures"), Index(0)],
        fn(signature) { with_extra_key(without_member(signature, "reference")) },
      ),
    )
}

pub fn problem_root_keys_are_checked_before_the_outcome_cause_is_read_test() {
  let exchange = exchange_of("accepted-composition")
  let composition = member(exchange, "composition")
  let cause_path = [
    Key("problem"),
    Key("signatures"),
    Index(0),
    Key("outcomes"),
    Index(0),
    Key("cause"),
  ]
  let assert Error(admission.Wire(decode.UnknownField(_, "extra"))) =
    admit_composition(
      exchange,
      update(composition, cause_path, tag_only("Bogus"))
        |> update([Key("problem")], with_extra_key),
    )
}

pub fn outcome_cause_is_read_before_the_outcome_id_test() {
  let exchange = exchange_of("accepted-composition")
  let composition = member(exchange, "composition")
  let outcome_path = [
    Key("problem"),
    Key("signatures"),
    Index(0),
    Key("outcomes"),
    Index(0),
  ]
  let assert Error(admission.Wire(decode.UnknownTag(_, "Bogus"))) =
    admit_composition(
      exchange,
      update(composition, outcome_path, fn(outcome) {
        let assert json.JsonValueObj(members) = outcome
        json.JsonValueObj(
          list.map(members, fn(entry) {
            case entry.0 {
              "cause" -> #("cause", tag_only("Bogus")(entry.1))
              "id" -> #("id", json.JsonValueNum(1))
              _ -> entry
            }
          }),
        )
      }),
    )
}

pub fn snapshot_basis_extra_key_is_a_snapshot_mismatch_test() {
  let exchange = exchange_of("accepted-composition")
  let composition = member(exchange, "composition")
  let basis_path = [
    Key("derivation"),
    Key("witness"),
    Key("input_snapshot"),
    Key("basis"),
  ]
  let assert Error(admission.Wire(decode.SyntaxFailure(
    _,
    "input snapshot mismatch",
  ))) =
    admit_composition(exchange, update(composition, basis_path, with_extra_key))
}

fn zz(_: json.JsonValue) -> json.JsonValue {
  json.JsonValueObj([#("zz", json.JsonValueNum(1))])
}

fn expect_syntax(result: Result(a, signatures.AdmissionFailure)) -> Nil {
  let assert Error(admission.Wire(decode.SyntaxFailure(_, _))) = result
  Nil
}

pub fn type_id_in_a_problem_slot_contract_is_a_string_test() {
  let exchange = exchange_of("accepted-composition")
  let composition = member(exchange, "composition")
  let assert Some(path) =
    path_with_key(member(composition, "problem"), "type_id")
  expect_syntax(admit_composition(
    exchange,
    update(
      composition,
      list.flatten([[Key("problem")], path, [Key("type_id")]]),
      zz,
    ),
  ))
}

pub fn empty_types_element_is_a_string_test() {
  let exchange = exchange_of("accepted-composition")
  let composition = member(exchange, "composition")
  let certificate = first_inclusion_path(composition)
  expect_syntax(admit_composition(
    exchange,
    update(
      composition,
      list.flatten([certificate, [Key("empty_types")]]),
      fn(_) { json.JsonValueArr([zz(json.JsonValueNull)]) },
    ),
  ))
}

pub fn operation_definition_is_a_string_test() {
  let exchange = exchange_of("accepted-composition")
  let composition = member(exchange, "composition")
  expect_syntax(admit_composition(
    exchange,
    update(
      composition,
      [
        Key("problem"),
        Key("signatures"),
        Index(0),
        Key("form"),
        Key("value"),
      ],
      zz,
    ),
  ))
}

pub fn source_binding_reads_the_compatibility_before_the_value_test() {
  let exchange = exchange_of("accepted-composition")
  let composition = member(exchange, "composition")
  let assert Some(path) =
    path_with_key(member(composition, "derivation"), "compatibility")
  let assert Error(admission.Wire(decode.UnknownTag(_, "Bogus"))) =
    admit_composition(
      exchange,
      update(composition, list.flatten([[Key("derivation")], path]), fn(fields) {
        let assert json.JsonValueObj(members) = fields
        json.JsonValueObj(
          list.map(members, fn(entry) {
            case entry.0 {
              "value" -> #("value", json.JsonValueNull)
              "compatibility" -> #("compatibility", tag_only("Bogus")(entry.1))
              _ -> entry
            }
          }),
        )
      }),
    )
}

fn with_values(
  changes: List(#(String, json.JsonValue)),
) -> fn(json.JsonValue) -> json.JsonValue {
  fn(record) {
    let assert json.JsonValueObj(members) = record
    json.JsonValueObj(
      list.map(members, fn(entry) {
        case list.key_find(changes, entry.0) {
          Ok(replacement) -> #(entry.0, replacement)
          Error(_) -> entry
        }
      }),
    )
  }
}

fn bogus() -> json.JsonValue {
  tag_only("Bogus")(json.JsonValueNull)
}

fn number() -> json.JsonValue {
  json.JsonValueNum(1)
}

fn invoke_fields_path(composition: json.JsonValue) -> List(Step) {
  let assert Some(path) =
    path_with_key(member(member(composition, "derivation"), "plan"), "arms")
  list.flatten([[Key("derivation"), Key("plan")], path])
}

fn invocation_path(composition: json.JsonValue) -> List(Step) {
  let assert Some(path) =
    path_with_key(member(member(composition, "derivation"), "plan"), "bindings")
  list.flatten([[Key("derivation"), Key("plan")], path])
}

pub fn invoke_reads_the_arms_before_the_invocation_test() {
  let exchange = exchange_of("accepted-composition")
  let composition = member(exchange, "composition")
  expect_syntax(admit_composition(
    exchange,
    update(
      composition,
      invoke_fields_path(composition),
      with_values([#("arms", number()), #("invocation", bogus())]),
    ),
  ))
}

pub fn invocation_reads_the_bindings_before_the_function_test() {
  let exchange = exchange_of("accepted-composition")
  let composition = member(exchange, "composition")
  expect_syntax(admit_composition(
    exchange,
    update(
      composition,
      invocation_path(composition),
      with_values([#("bindings", number()), #("function", bogus())]),
    ),
  ))
}

pub fn invocation_reads_the_resources_before_the_function_test() {
  let exchange = exchange_of("accepted-composition")
  let composition = member(exchange, "composition")
  expect_syntax(admit_composition(
    exchange,
    update(
      composition,
      invocation_path(composition),
      with_values([#("resources", number()), #("function", bogus())]),
    ),
  ))
}

pub fn guard_node_reads_the_arms_before_the_guard_test() {
  let wire =
    decode.DerivationDecoder(
      shapes: fn(_, _, _) { Error(decode.SyntaxFailure([], "unused")) },
      basis: fn(_) { Error(decode.SyntaxFailure([], "unused")) },
      token_identity: fn(id) { id },
    )
  let node =
    json.JsonValueObj([
      #("rank", json.JsonValueStr("0")),
      #(
        "node",
        json.JsonValueObj([
          #("tag", json.JsonValueStr("Guard")),
          #(
            "fields",
            json.JsonValueObj([
              #("guard", json.JsonValueStr("g")),
              #("inspected", bogus()),
              #("arms", number()),
            ]),
          ),
        ]),
      ),
    ])
  let assert Error(decode.SyntaxFailure(path, _)) =
    decode.decode_plan_tree(node, wire)
  let assert True = list.contains(path, "arms")
}
