-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import Necoherence.SemanticComposition
import Necoherence.SemanticValidation

namespace Necoherence.SemanticComposition
open Necoherence.ExactJson
open Necoherence.SemanticTypes
open Necoherence.SemanticValidation

private def verifyAmbiguity (prepared : PreparedCompositionInput)
    (candidates : List (VerifiedCompositionCandidate prepared)) :
    Except CompositionEngineFailure { proof : Unit // ∃ first ∈ candidates, ∃ second ∈ candidates,
      canonicalPlanKey prepared first.raw.plan.root ≠ canonicalPlanKey prepared second.raw.plan.root } :=
  match candidates with
  | [] => .error (.contractViolation "ambiguity needs checked candidates")
  | first :: rest =>
    match found : rest.find? (fun candidate => decide
        (canonicalPlanKey prepared first.raw.plan.root ≠ canonicalPlanKey prepared candidate.raw.plan.root)) with
    | none => .error (.contractViolation "ambiguity needs distinct canonical programs")
    | some second => .ok ⟨(), by
        have correct := find_sound rest _ second found
        exact ⟨first, List.mem_cons_self, second, List.mem_cons_of_mem first correct.1,
          of_decide_eq_true correct.2⟩⟩

def decideAmbiguous (prepared : PreparedCompositionInput)
    (candidates : List (VerifiedCompositionCandidate prepared)) :
    Except CompositionEngineFailure (CompositionDecision prepared) := do
  let distinction ← verifyAmbiguity prepared candidates
  return .ambiguous candidates distinction.property

def decideUnreachable (prepared : PreparedCompositionInput) (closure : CompositionClosureWitness)
    (checked : CheckedCompositionClosure prepared closure) :
    Except CompositionEngineFailure (CompositionDecision prepared) :=
  if noPrograms : programKeys prepared closure = [] then
    .ok (.unreachable { witness := closure, closure := checked, noPrograms })
  else .error (.contractViolation "closed program keys lack checked candidates")

end Necoherence.SemanticComposition

