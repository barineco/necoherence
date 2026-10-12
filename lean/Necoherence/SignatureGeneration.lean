-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SignatureCompositionWire

namespace Necoherence.SignatureComposition
open Lean Necoherence.SemanticComposition Necoherence.SignatureWire

def verifyInput (input : Necoherence.SignatureGeneration.Input)
    (expected : Necoherence.SignatureGeneration.Basis) :
    Except (Sum WireFailure String)
      (Option ((prepared : PreparedCompositionInput) × CheckedComposition prepared)) := do
  let some composition := input.composition | return none
  (keys composition ["problem", "derivation"]).mapError Sum.inl
  let problemJson ← liftJson (composition.getObjVal? "problem") |>.mapError Sum.inl
  let (problem, causes) ← decodeProblem input.signatures problemJson |>.mapError Sum.inl
  let prepared ← (prepare input.signatures expected.graphSha256 problem causes).mapError
    (fun failure => Sum.inr (reprStr failure))
  let derivationJson ← liftJson (composition.getObjVal? "derivation") |>.mapError Sum.inl
  let supplied ← Necoherence.SignatureCompositionWire.decodeDerivation input.signatures problemJson
    prepared derivationJson |>.mapError Sum.inl
  let checked ← (verifyComposition prepared supplied.proofProjection).mapError
    (fun failure => Sum.inr (reprStr failure))
  pure (some ⟨prepared, checked⟩)

end Necoherence.SignatureComposition

namespace Necoherence.SignatureGeneration
open Necoherence.TypeSignatures

def admit (input : Input) (expected : Basis) :
    Except AdmissionFailure (CheckedInput input) := do
  let checked ← admitBasis input expected
  let _ ← (Necoherence.SignatureComposition.verifyInput input expected).mapError fun
    | .inl failure => AdmissionFailure.wire failure
    | .inr failure => AdmissionFailure.composition failure
  pure checked

theorem signatureBasisSound (input : Input) (checked : CheckedInput input) :
    input.basis = basis input.signatures input.entrypoints input.composition := checked.trusted

theorem signatureWireMetadataOrthogonality (library : TypeSignatureLibrary) (annotations : List Annotation)
    (groups : List DefinitionGroup) :
    graphProjection { library with annotations := annotations, groups := groups } = graphProjection library := rfl

end Necoherence.SignatureGeneration
