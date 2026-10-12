// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import necoherence/exact_json as json
import necoherence/semantic_composition as composition
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import semantic_test_support as support

fn texts(spec: types.StringSpec, rule: types.FormatRule) -> List(String) {
  let profile =
    types.SemanticProfile(..support.profile(), format_bindings: [
      types.FormatBinding("subject", support.profile_ref(), rule),
    ])
  let graph =
    types.SemanticGraph(
      profile,
      [
        support.node("subject", types.StringShape(spec)),
      ],
      [support.source()],
    )
  composition.samples(graph, support.reference("subject"), [], 50)
  |> list.filter_map(fn(value) {
    case value {
      json.JsonValueStr(text) -> Ok(text)
      _ -> Error(Nil)
    }
  })
}

fn formatted(rule: types.FormatRule) -> List(String) {
  texts(
    types.StringSpec(
      Some(types.NamedFormat("subject")),
      [],
      None,
      None,
      None,
      [],
      None,
    ),
    rule,
  )
}

fn label() -> types.FormatRule {
  types.Identifier("abc", "abc", None, 1, 3, [])
}

pub fn labels_with_a_multi_character_separator_have_samples_test() {
  let assert ["a::a"] = formatted(types.Labels("::", 2, None, None, label()))
}

pub fn sequence_samples_replace_one_part_at_a_time_test() {
  let values =
    formatted(
      types.Sequence([
        types.Optional(types.Literal("a")),
        types.Literal("b"),
      ]),
    )
  let assert True = list.contains(values, "b")
  let assert True = list.contains(values, "ab")
}

pub fn absolute_uri_sample_fits_the_declared_maximum_test() {
  let assert ["a:"] = formatted(types.AbsoluteUri(2))
}

pub fn language_tag_sample_is_the_shortest_primary_language_test() {
  let assert ["aa"] = formatted(types.LanguageTag([]))
}

pub fn labels_join_every_part_sample_test() {
  let assert ["x.x", "y.y"] =
    formatted(types.Labels(
      ".",
      2,
      None,
      None,
      types.Choice([types.Literal("x"), types.Literal("y")]),
    ))
}

pub fn dfa_sample_is_the_shortest_accepted_word_test() {
  let spec =
    types.DfaSpec(3, 0, [1, 2], [
      types.DfaTransition(0, 97, 97, 1),
      types.DfaTransition(1, 98, 98, 2),
    ])
  let assert ["a", "a"] = formatted(types.AsciiDfa(spec))
}

pub fn identifier_sample_is_the_first_accepted_candidate_test() {
  let assert ["ad"] =
    formatted(types.Identifier("ab", "cd", Some(2), 1, 3, ["ac"]))
}

pub fn sequence_samples_vary_each_part_in_order_test() {
  let assert ["ax", "bx"] =
    formatted(
      types.Sequence([
        types.Choice([types.Literal("a"), types.Literal("b")]),
        types.Literal("x"),
      ]),
    )
}

pub fn sequence_with_an_optional_part_recognizes_the_bare_tail_test() {
  let assert True =
    validation.recognizes(
      types.Sequence([
        types.Optional(types.Literal("a")),
        types.Literal("b"),
      ]),
      "b",
    )
}

pub fn representative_format_samples_are_accepted_test() {
  let rules = [
    types.Text,
    types.Not(types.Literal("x")),
    types.Labels(".", 2, None, None, label()),
    types.Sequence([types.Optional(types.Literal("a")), types.Literal("b")]),
    types.AbsoluteUri(2),
    types.LanguageTag([]),
  ]
  list.each(rules, fn(rule) {
    list.each(formatted(rule), fn(text) {
      let assert True = validation.recognizes(rule, text)
    })
  })
}

pub fn examples_precede_fixed_samples_test() {
  let spec = types.StringSpec(None, [], None, None, None, ["kk"], None)
  let assert ["kk", "", "a"] = texts(spec, types.Text)
}

pub fn length_samples_follow_declared_bounds_test() {
  let spec =
    types.StringSpec(
      None,
      [types.LengthBound(types.UnicodeScalars, Some(3), Some(6))],
      None,
      None,
      None,
      [],
      None,
    )
  let values = texts(spec, types.Text)
  let assert ["aaa", "aaaaaa"] = list.unique(values)
  let assert True = list.contains(values, string.repeat("a", 6))
}
