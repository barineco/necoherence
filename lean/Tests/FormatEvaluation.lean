-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SemanticValidation

namespace Necoherence.Tests.FormatEvaluation

open Necoherence.SemanticTypes

private def calendar : CalendarRule := {
  allowSecond60 := false
  minimumYear := 2000
  maximumYear := 2001
  rejectUtcYearOutsideRange := true
}

private def seeds : List FormatRule := [
  .literal "a",
  .text,
  .asciiDfa { stateCount := 1, initialState := 0, acceptingStates := [0], transitions := [] },
  .identifier "a" "a" none 1 (some 2) [],
  .timestamp calendar,
  .absoluteUri (some 16),
  .languageTag []]

private def grow (rule : FormatRule) : List FormatRule := [
  .sequence [rule, .literal "#"],
  .optional rule,
  .labels "." 1 (some 2) (some 8) rule,
  .bounded .unicodeScalars 2 rule,
  .choice [.literal "", rule],
  .not rule]

private def rules : List FormatRule :=
  seeds ++ seeds.flatMap grow ++ seeds.flatMap (fun rule =>
    grow rule |>.flatMap grow)

private def textSeeds : List String := ["", "a", "é"]

private def texts : List String :=
  textSeeds ++ textSeeds.flatMap (fun text => [text ++ "#", "a" ++ text])

private def agrees : Bool :=
  rules.all fun rule => texts.all fun text =>
    Necoherence.SemanticValidation.formatAcceptsFast rule text ==
      Necoherence.SemanticValidation.formatAccepts rule text

private def timedFast (text : String) : IO Bool := do
  let start ← IO.monoNanosNow
  let accepted := Necoherence.SemanticValidation.formatAcceptsFast
    (.not (.choice [.literal "", .sequence [.text, .literal "#main"]])) text
  unless accepted do throw <| IO.userError "fast format evaluation returned false"
  let finish ← IO.monoNanosNow
  let elapsed := finish - start
  IO.println s!"formatAcceptsFast elapsed ns: {elapsed}"
  pure (elapsed ≤ 1000000000)


def run : IO Unit := do
  unless agrees do throw <| IO.userError "generated format evaluations disagree"
  let longText := String.ofList (List.replicate 4000 'a')
  unless ← timedFast longText do throw <| IO.userError "fast format evaluation exceeded one second"

end Necoherence.Tests.FormatEvaluation

def main : IO Unit := Necoherence.Tests.FormatEvaluation.run

