-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SemanticValidation

namespace Necoherence.Tests.SequenceRecognition

open Necoherence.SemanticTypes
open Necoherence.SemanticValidation

example : formatAccepts (.sequence [.literal "a", .literal "b"]) "ab" = true := by
  decide

example : formatAccepts (.sequence [.literal "a", .literal "b"]) "a" = false := by
  decide

example : formatAccepts (.sequence []) "" = true := by
  decide

example : formatAccepts (.sequence []) "a" = false := by
  decide

example : formatAccepts (.sequence [.literal "a", .optional (.literal "b")]) "a" = true := by
  decide

example : formatAccepts (.sequence [.literal "a", .optional (.literal "b")]) "ab" = true := by
  decide

example : formatAccepts
    (.sequence [.choice [.literal "a", .literal "a"], .literal "b"]) "ab" = true := by
  decide

example : formatAccepts
    (.sequence [
      .bounded .utf8Bytes 2 (.literal "é"),
      .bounded .unicodeScalars 1 (.literal "λ")
    ]) "éλ" = true := by
  native_decide

example : formatAccepts
    (.sequence [.literal "a", .literal "b", .literal "c"]) "abc" = true := by
  decide

example : formatRuleIncluded
    (.sequence [.literal "a", .literal "b"])
    (.sequence [.literal "a", .literal "b"]) = true := by
  decide

example : formatRuleIncluded
    (.literal "x")
    (.choice [.literal "x", .literal "y"]) = true := by
  decide

example : formatRuleIncluded
    (.literal "z")
    (.choice [.literal "x", .literal "y"]) = false := by
  decide

example : formatRuleIncluded
    (.literal "x")
    (.choice [.choice [.literal "x", .literal "y"], .literal "z"]) = true := by
  decide

example : formatRuleIncluded
    (.literal "x")
    (.choice [.literal "x", .literal "x"]) = true := by
  decide

private def unicodeSequence : FormatRule :=
  .sequence [.literal "é", .optional (.literal "λ")]

private def deeperRule : FormatRule :=
  .bounded .unicodeScalars 3 (.optional (.sequence [.literal "a", .literal "b"]))

example : formatRuleIncluded
    unicodeSequence
    (.choice [deeperRule, unicodeSequence]) = true := by
  native_decide

example : formatAccepts unicodeSequence "éλ" = true := by
  native_decide

example : formatAccepts (.choice [deeperRule, unicodeSequence]) "éλ" = true :=
  formatRuleIncluded_sound unicodeSequence (.choice [deeperRule, unicodeSequence]) "éλ"
    (by native_decide) (by native_decide)

end Necoherence.Tests.SequenceRecognition
