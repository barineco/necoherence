// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_generation_values as values
import necoherence/semantic_types as t
import necoherence/semantic_validation as v
import simplifile

pub fn atproto_uri_format_accepts_did_authority_and_rejects_missing_scheme_or_whitespace_test() {
  let assert Ok(text) =
    simplifile.read("../presets/atproto-data-model/profile.json")
  let assert Ok(encoded) = values.parse_wire(text)
  let assert Ok(profile) = decode.decode_semantic_profile(encoded)
  let assert Ok(binding) =
    list.find(profile.format_bindings, fn(binding) { binding.name == "uri" })
  v.recognizes(
    binding.rule,
    "at://did:plc:ymdqgzoop3puhkbwrd7njbke/app.bsky.actor.profile/self",
  )
  |> should.equal(True)
  v.recognizes(binding.rule, "https://example.com/has space")
  |> should.equal(False)
  v.recognizes(binding.rule, "example.com/path")
  |> should.equal(False)
}

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
    t.Labels(
      ".",
      2,
      Some(3),
      Some(5),
      t.Identifier("a", "a", None, 1, Some(2), []),
    )
  v.recognizes(labels, "a.a") |> should.equal(True)
  v.recognizes(labels, "a") |> should.equal(False)
  v.recognizes(t.Bounded(t.Utf8Bytes, 1, t.Literal("é")), "é")
  |> should.equal(False)
  v.recognizes(t.Bounded(t.Utf8Bytes, 2, t.Literal("ab")), "ab")
  |> should.equal(True)
  v.recognizes(t.Bounded(t.UnicodeScalars, 1, t.Literal("é")), "é")
  |> should.equal(True)
}
