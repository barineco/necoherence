-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SignatureGeneration

namespace Necoherence.SignatureComposition
open Lean Necoherence.SemanticTypes Necoherence.SemanticComposition Necoherence.SignatureWire

theorem signatureExternalInvocationCovered (prepared : PreparedCompositionInput)
    (state : SearchState) (rank : Nat) (invocation : InvocationPlan)
    (arms : List (OutcomeId × PlanTree)) (empty : List OutcomeId)
    (justified : PlanJustified prepared state (.invoke rank invocation arms empty))
    (function : InvocationJustified prepared state invocation)
    (outcome : OutcomeContract) (member : outcome ∈ function.function.outcomes)
    (cause : CauseBinding) (_functionCause : cause.function = function.function.reference)
    (_outcomeCause : cause.outcome = outcome.id) (specification : Origin)
    (_externalCause : cause.cause = .externalCondition specification)
    (inhabited : ¬ OutcomeImpossible prepared.graph outcome) :
    ∃ child, (outcome.id, child) ∈ arms := by
  cases justified with
  | invocation _ _ _ _ _ checked emptySound coverage _ =>
    have identity : checked.function = function.function := Option.some.inj (checked.resolved.symm.trans function.resolved)
    have declared : outcome ∈ checked.function.outcomes := identity.symm ▸ member
    rcases coverage.2 outcome declared with impossible | covered
    · exact False.elim (inhabited (emptySound outcome declared impossible))
    · exact covered

end Necoherence.SignatureComposition
