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
  types.Identifier("abc", "abc", None, 1, Some(3), [])
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

pub fn sequence_grouping_preserves_concatenation_and_empty_parts_test() {
  let first = types.Choice([types.Literal(""), types.Literal("a")])
  let second = types.Optional(types.Literal("😀"))
  let third = types.Literal("!")
  let rules = [
    types.Sequence([first, second, third]),
    types.Sequence([types.Sequence([first, second]), third]),
    types.Sequence([first, types.Sequence([second, third])]),
    types.Sequence([
      types.Sequence([]),
      first,
      second,
      types.Sequence([third]),
      types.Sequence([]),
    ]),
  ]
  list.each(["", "!", "a!", "😀!", "a😀!", "aa!", "😀a!", "a😀", "x!"], fn(text) {
    list.each(rules, fn(rule) {
      let expected = list.contains(["!", "a!", "😀!", "a😀!"], text)
      let assert True = validation.recognizes(rule, text) == expected
    })
  })
  let assert True = validation.recognizes(types.Sequence([]), "")
  let assert False = validation.recognizes(types.Sequence([]), "a")
  let negated =
    types.Sequence([
      types.Literal("["),
      types.Not(types.Sequence([types.Literal("a"), types.Literal("😀")])),
      types.Literal("]"),
    ])
  let assert True = validation.recognizes(negated, "[]")
  let assert True = validation.recognizes(negated, "[😀]")
  let assert False = validation.recognizes(negated, "[a😀]")
}

pub fn sequence_labels_preserve_scalar_offsets_and_bounds_test() {
  let child =
    types.Sequence([types.Optional(types.Literal("a")), types.Literal("😀")])
  let inner = types.Labels("🔹", 2, Some(2), Some(4), child)
  let rule = types.Sequence([types.Literal("["), inner, types.Literal("]")])
  list.each(
    [
      #("[😀🔹a😀]", True),
      #("[a😀🔹😀]", True),
      #("[😀🔹b😀]", False),
      #("[😀🔹😀🔹😀]", False),
      #("[a😀🔹a😀]", False),
    ],
    fn(pair) {
      let assert True = validation.recognizes(rule, pair.0) == pair.1
    },
  )
  let assert True =
    validation.recognizes(types.Bounded(types.Utf8Bytes, 15, rule), "[😀🔹a😀]")
  let assert False =
    validation.recognizes(types.Bounded(types.Utf8Bytes, 14, rule), "[😀🔹a😀]")
}

pub fn flat_sequence_with_600_parts_preserves_acceptance_and_rejection_test() {
  let parts = list.repeat(types.Literal(""), 600)
  let rule = types.Sequence(parts)
  let assert True = validation.recognizes(rule, "")
  let assert False = validation.recognizes(rule, "x")
  let suffix = types.Sequence(list.append(parts, [types.Literal("x")]))
  let assert True = validation.recognizes(suffix, "x")
  let assert False = validation.recognizes(suffix, "")
}
