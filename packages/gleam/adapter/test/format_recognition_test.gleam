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
    simplifile.read(
      "../../../verification/presets/atproto-data-model/profile.json",
    )
  let assert Ok(encoded) = values.parse_wire(text)
  let assert Ok(profile) = decode.decode_semantic_profile(encoded)
  let assert Ok(binding) =
    list.find(profile.format_bindings, fn(binding) { binding.name == "uri" })
  v.recognizes(
    None,
    binding.rule,
    "at://did:plc:ymdqgzoop3puhkbwrd7njbke/app.bsky.actor.profile/self",
  )
  |> should.equal(True)
  v.recognizes(None, binding.rule, "https://example.com/has space")
  |> should.equal(False)
  v.recognizes(None, binding.rule, "example.com/path")
  |> should.equal(False)
}

pub fn sequence_scalar_boundaries_test() {
  let rule = t.Sequence([t.Literal("e"), t.Literal("\u{301}")])
  v.recognizes(None, rule, "e\u{301}") |> should.equal(True)
  v.recognizes(None, t.Sequence([]), "") |> should.equal(True)
  v.recognizes(None, t.Optional(t.Literal("x")), "") |> should.equal(True)
  v.recognizes(None, t.Optional(t.Literal("x")), "x") |> should.equal(True)
  v.recognizes(
    None,
    t.Sequence([t.Literal("😀"), t.Literal("é"), t.Literal("z")]),
    "😀éz",
  )
  |> should.equal(True)
}

pub fn choice_labels_and_bounds_test() {
  v.recognizes(None, t.Choice([t.Literal("x"), t.Literal("x")]), "x")
  |> should.equal(True)
  let labels =
    t.Labels(
      ".",
      2,
      Some(3),
      Some(5),
      t.Identifier("a", "a", None, 1, Some(2), []),
    )
  v.recognizes(None, labels, "a.a") |> should.equal(True)
  v.recognizes(None, labels, "a") |> should.equal(False)
  v.recognizes(None, t.Bounded(t.Utf8Bytes, 1, t.Literal("é")), "é")
  |> should.equal(False)
  v.recognizes(None, t.Bounded(t.Utf8Bytes, 2, t.Literal("ab")), "ab")
  |> should.equal(True)
  v.recognizes(None, t.Bounded(t.UnicodeScalars, 1, t.Literal("é")), "é")
  |> should.equal(True)
}

pub fn grapheme_bounds_count_with_profile_rules_and_reject_without_them_test() {
  let assert Ok(text) =
    simplifile.read(
      "../../../verification/presets/atproto-data-model/profile.json",
    )
  let assert Ok(encoded) = values.parse_wire(text)
  let assert Ok(profile) = decode.decode_semantic_profile(encoded)
  let assert Some(rules) = profile.grapheme_rules
  let rule = t.Bounded(t.Graphemes, 1, t.Text)
  v.recognizes(Some(rules), rule, "e\u{301}") |> should.equal(True)
  v.recognizes(None, rule, "e\u{301}") |> should.equal(False)
  v.recognizes(None, rule, "") |> should.equal(False)
}
