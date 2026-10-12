-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SemanticValidation

namespace Necoherence.Tests.LabelSeparatorRecognition

open Necoherence.SemanticTypes
open Necoherence.SemanticValidation

private def part : FormatRule := .literal "a"

private def doubleColon (minimum : Nat) : FormatRule := .labels "::" minimum none none part

theorem partOfSeparatorDoesNotSplit : formatAccepts (doubleColon 2) "a:a" = false := by native_decide

theorem wholeSeparatorSplits : formatAccepts (doubleColon 2) "a::a" = true := by native_decide

theorem wholeSeparatorSplitsEveryOccurrence :
    formatAccepts (doubleColon 3) "a::a::a" = true := by native_decide

theorem separatorPrefixInsideLabelIsNotASeparator :
    formatAccepts (.labels "::" 1 none none (.literal "a:")) "a:" = true := by native_decide

theorem emptySeparatorRecognizesNothing :
    formatAccepts (.labels "" 2 none none part) "a.a" = false ∧
    formatAccepts (.labels "" 2 none none part) "aa" = false := by native_decide

private def profileWith (rule : FormatRule) : VersionedSemanticProfile :=
  let reference : ProfileRef := { identity := "synthetic", revision := "1", contentDigest := "separator" }
  { reference,
    integerDomains := [{ name := "integer", reference, range := .unbounded, forms := [.number] }],
    defaultIntegerDomain := "integer",
    formatBindings := [{ name := "subject", reference, rule }] }

private def admitted (rule : FormatRule) : Bool :=
  match checkProfile (profileWith rule) with
  | .ok _ => true
  | .error _ => false

theorem profileWithNonEmptySeparatorAdmitted : admitted (doubleColon 2) = true := by native_decide

theorem profileWithEmptySeparatorRejected :
    admitted (.labels "" 2 none none part) = false := by native_decide

end Necoherence.Tests.LabelSeparatorRecognition
