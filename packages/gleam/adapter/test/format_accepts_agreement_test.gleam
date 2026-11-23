// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{None, Some}
import necoherence/semantic_types as t
import necoherence/semantic_validation as v

pub fn naive_format_acceptance_agrees_with_the_span_recognizer_test() {
  let rules = [
    t.Literal("ab"),
    t.Sequence([t.Literal("a"), t.Optional(t.Literal("b"))]),
    t.Sequence([]),
    t.Choice([t.Literal("x"), t.Sequence([t.Literal("a"), t.Text])]),
    t.Labels(
      separator: ",",
      min_count: 1,
      max_count: Some(2),
      total_max: Some(3),
      rule: t.Literal("x"),
    ),
    t.Bounded(t.UnicodeScalars, 2, t.Text),
    t.Not(t.Literal("a")),
    t.Sequence([t.Not(t.Text), t.Literal("b")]),
  ]
  let texts = ["", "a", "b", "ab", "aab", "x", "x,x", "a,x", ",", "xxx", "abc"]
  list.each(rules, fn(rule) {
    list.each(texts, fn(text) {
      let assert True =
        v.format_accepts(None, rule, text) == v.recognizes(None, rule, text)
    })
  })
}
