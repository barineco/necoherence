// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/option.{None, Some}
import gleeunit/should
import necoherence/semantic_types as t
import necoherence/semantic_validation as v

pub fn sequence_scalar_boundaries_test() {
  let rule = t.Sequence([t.Literal("e"), t.Literal("\u{301}")])
  v.recognizes(rule, "e\u{301}") |> should.equal(True)
  v.recognizes(t.Sequence([]), "") |> should.equal(True)
  v.recognizes(t.Optional(t.Literal("x")), "") |> should.equal(True)
  v.recognizes(t.Optional(t.Literal("x")), "x") |> should.equal(True)
  v.recognizes(
    t.Sequence([t.Literal("😀"), t.Literal("é"), t.Literal("z")]),
    "😀éz",
  )
  |> should.equal(True)
}

pub fn choice_labels_and_bounds_test() {
  v.recognizes(t.Choice([t.Literal("x"), t.Literal("x")]), "x")
  |> should.equal(True)
  let labels =
    t.Labels(".", 2, Some(3), Some(5), t.Identifier("a", "a", None, 1, 2, []))
  v.recognizes(labels, "a.a") |> should.equal(True)
  v.recognizes(labels, "a") |> should.equal(False)
  v.recognizes(t.Bounded(t.Utf8Bytes, 1, t.Literal("é")), "é")
  |> should.equal(False)
  v.recognizes(t.Bounded(t.Utf8Bytes, 2, t.Literal("ab")), "ab")
  |> should.equal(True)
  v.recognizes(t.Bounded(t.UnicodeScalars, 1, t.Literal("é")), "é")
  |> should.equal(True)
}
