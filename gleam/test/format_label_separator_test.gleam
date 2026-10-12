// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/option.{None, Some}
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation

pub fn labels_accept_multicharacter_separator_test() {
  let rule =
    types.Labels(
      "::",
      2,
      Some(3),
      None,
      types.Identifier("ab", "ab", None, 1, 2, []),
    )
  let assert True = validation.recognizes(rule, "a::bb")
  let assert False = validation.recognizes(rule, "a:bb")
}

pub fn labels_apply_total_limit_test() {
  let rule = types.Labels("--", 1, None, Some(5), types.Text)
  let assert True = validation.recognizes(rule, "a--b")
  let assert False = validation.recognizes(rule, "aa--bb")
}
