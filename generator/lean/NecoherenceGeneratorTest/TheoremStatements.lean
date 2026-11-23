-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import NecoherenceGenerator.SemanticRenderer
import NecoherenceGenerator.SignatureGeneration
import Lean

example : ∀ (prepared : Necoherence.SemanticComposition.PreparedCompositionInput)
  (checked : Necoherence.SemanticComposition.CheckedComposition prepared)
  (branch : Necoherence.SemanticComposition.BranchTrace),
  branch ∈ Necoherence.SemanticComposition.planBranches [] checked.candidate.raw.plan.root →
    Nonempty (Necoherence.SemanticComposition.CheckedResourceTrace prepared branch) :=
  @NecoherenceTools.SemanticRenderer.generatedCompositionSound

open Lean in
run_meta do
  let allowed : List Name := [`propext, `Quot.sound, `Classical.choice]
  let env ← getEnv
  let mut checked := 0
  for module in [`NecoherenceGenerator.SemanticRenderer, `NecoherenceGenerator.SignatureGeneration] do
    let some index := env.header.moduleNames.findIdx? (· == module) | throwError "{module} is not imported"
    let some data := env.header.moduleData[index]? | throwError "{module} has no data"
    for info in data.constants do
      match info with
      | .thmInfo _ | .defnInfo _ =>
        let axioms ← collectAxioms info.name
        let outside := axioms.filter (fun used => !allowed.contains used)
        unless outside.isEmpty do
          throwError "{info.name} depends on the axioms {outside}"
        checked := checked + 1
      | _ => pure ()
  if checked == 0 then throwError "no declaration was checked"
