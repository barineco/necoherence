// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import necoherence/exact_json as json
import necoherence/semantic_composition as composition
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import semantic_test_support as support

fn texts(rule: types.FormatRule, limit: Int) -> List(String) {
  let profile =
    types.SemanticProfile(..support.profile(), format_bindings: [
      types.FormatBinding("subject", support.profile_ref(), rule),
    ])
  let spec =
    types.StringSpec(
      Some(types.NamedFormat("subject")),
      [],
      None,
      None,
      None,
      [],
      None,
    )
  let graph =
    types.SemanticGraph(
      profile,
      [support.node("subject", types.StringShape(spec)), ..padding(limit)],
      [support.source()],
    )
  composition.samples(graph, support.reference("subject"), [], limit)
  |> list.filter_map(fn(value) {
    case value {
      json.JsonValueStr(text) -> Ok(text)
      _ -> Error(Nil)
    }
  })
}

fn padding(count: Int) -> List(types.TypeNode) {
  list.index_map(list.repeat(Nil, count), fn(_, index) {
    support.node("pad" <> int.to_string(index), types.UnitShape)
  })
}

fn label() -> types.FormatRule {
  types.Identifier("abc", "abc", None, 1, 3, [])
}

pub fn sequence_samples_are_cut_at_the_limit_test() {
  let rule =
    types.Sequence([
      types.Choice([types.Literal("a"), types.Literal("b"), types.Literal("c")]),
      types.Choice([types.Literal("x"), types.Literal("y")]),
    ])
  let assert ["ax"] = texts(rule, 1)
  let assert ["ax", "bx"] = texts(rule, 2)
  let assert ["ax", "bx", "cx", "ay"] = texts(rule, 50)
}

pub fn empty_separator_labels_recognize_nothing_test() {
  let rule = types.Labels("", 1, None, None, label())
  let assert False = validation.recognizes(rule, "")
  let assert False = validation.recognizes(rule, "a")
  let assert [] = texts(rule, 50)
}
