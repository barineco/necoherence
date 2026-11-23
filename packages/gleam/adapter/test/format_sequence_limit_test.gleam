// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{None, Some}
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation

fn label() -> types.FormatRule {
  types.Identifier("abc", "abc", None, 1, Some(3), [])
}

pub fn empty_separator_labels_recognize_nothing_test() {
  let rule = types.Labels("", 1, None, None, label())
  let assert False = validation.recognizes(None, rule, "")
  let assert False = validation.recognizes(None, rule, "a")
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
      let assert True = validation.recognizes(None, rule, text) == expected
    })
  })
  let assert True = validation.recognizes(None, types.Sequence([]), "")
  let assert False = validation.recognizes(None, types.Sequence([]), "a")
  let negated =
    types.Sequence([
      types.Literal("["),
      types.Not(types.Sequence([types.Literal("a"), types.Literal("😀")])),
      types.Literal("]"),
    ])
  let assert True = validation.recognizes(None, negated, "[]")
  let assert True = validation.recognizes(None, negated, "[😀]")
  let assert False = validation.recognizes(None, negated, "[a😀]")
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
      let assert True = validation.recognizes(None, rule, pair.0) == pair.1
    },
  )
  let assert True =
    validation.recognizes(
      None,
      types.Bounded(types.Utf8Bytes, 15, rule),
      "[😀🔹a😀]",
    )
  let assert False =
    validation.recognizes(
      None,
      types.Bounded(types.Utf8Bytes, 14, rule),
      "[😀🔹a😀]",
    )
}

pub fn flat_sequence_with_600_parts_preserves_acceptance_and_rejection_test() {
  let parts = list.repeat(types.Literal(""), 600)
  let rule = types.Sequence(parts)
  let assert True = validation.recognizes(None, rule, "")
  let assert False = validation.recognizes(None, rule, "x")
  let suffix = types.Sequence(list.append(parts, [types.Literal("x")]))
  let assert True = validation.recognizes(None, suffix, "x")
  let assert False = validation.recognizes(None, suffix, "")
}
