// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/option.{None}
import gleeunit/should
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import semantic_test_support as support

fn checked(rule: types.FormatRule) -> Bool {
  let binding = types.FormatBinding("case", support.profile().reference, rule)
  let profile =
    types.SemanticProfile(..support.profile(), format_bindings: [binding])
  case validation.check_profile(profile) {
    Ok(_) -> True
    Error(types.ProfileFailure(_, types.Pr07, ["format_bindings"])) -> False
    Error(_) -> panic as "format binding failed for another predicate"
  }
}

fn dfa(transitions: List(types.DfaTransition)) -> types.FormatRule {
  types.AsciiDfa(types.DfaSpec(2, 0, [1], transitions))
}

pub fn dfa_transition_target_outside_states_is_rejected_test() {
  checked(dfa([types.DfaTransition(0, 48, 57, 2)])) |> should.equal(False)
  checked(
    types.AsciiDfa(
      types.DfaSpec(1, 0, [0], [
        types.DfaTransition(1, 48, 57, 0),
      ]),
    ),
  )
  |> should.equal(False)
}

pub fn dfa_transition_range_must_be_ordered_and_ascii_test() {
  checked(dfa([types.DfaTransition(0, 58, 48, 1)])) |> should.equal(False)
  checked(dfa([types.DfaTransition(0, 48, 128, 1)])) |> should.equal(False)
}

pub fn dfa_transitions_from_one_state_must_not_overlap_test() {
  checked(
    dfa([types.DfaTransition(0, 48, 57, 1), types.DfaTransition(0, 50, 60, 1)]),
  )
  |> should.equal(False)
  checked(
    dfa([types.DfaTransition(0, 48, 57, 1), types.DfaTransition(1, 48, 57, 1)]),
  )
  |> should.equal(True)
  checked(
    dfa([types.DfaTransition(0, 48, 57, 1), types.DfaTransition(0, 97, 122, 1)]),
  )
  |> should.equal(True)
}

pub fn identifier_alphabet_is_checked_by_codepoint_test() {
  checked(types.Identifier("\r\n", "a", None, 1, None, []))
  |> should.equal(True)
  checked(types.Identifier("é", "a", None, 1, None, []))
  |> should.equal(False)
  checked(types.Identifier("a\u{301}", "a", None, 1, None, []))
  |> should.equal(False)
}
