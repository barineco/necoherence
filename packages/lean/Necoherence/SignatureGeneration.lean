-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SignatureCompositionWire
import Necoherence.SignatureGenerationCertificate

namespace Necoherence.SignatureComposition
open Lean Necoherence.SemanticComposition Necoherence.SignatureWire

structure VerifiedComposition (prepared : PreparedCompositionInput) where
  raw : RawComposition
  checked : CheckedComposition prepared
  verified : verifyComposition prepared raw = .ok checked

abbrev InputFailure := Sum WireFailure (Sum CompositionInputFailure WitnessFailure)

private def decodePrepared (input : Necoherence.SignatureGeneration.Input)
    (expected : Necoherence.SignatureGeneration.Basis) :
    Except InputFailure (Option (Json × Json × PreparedCompositionInput)) := do
  let some composition := input.composition | return none
  (keys composition ["problem", "derivation"]).mapError Sum.inl
  let problemJson ← liftJson (composition.getObjVal? "problem") |>.mapError Sum.inl
  let (problem, causes) ← decodeProblem input.signatures problemJson |>.mapError Sum.inl
  let prepared ← (prepare input.signatures expected.graphSha256 problem causes).mapError
    (fun failure => Sum.inr (Sum.inl failure))
  let derivationJson ← liftJson (composition.getObjVal? "derivation") |>.mapError Sum.inl
  pure (some (problemJson, derivationJson, prepared))

def decodeInput (input : Necoherence.SignatureGeneration.Input)
    (expected : Necoherence.SignatureGeneration.Basis) :
    Except InputFailure (Option (PreparedCompositionInput × CompositionPlan)) := do
  let some (problemJson, derivationJson, prepared) ← decodePrepared input expected | return none
  let plan ← Necoherence.SignatureCompositionWire.decodePlan input.signatures problemJson
    derivationJson |>.mapError fun
      | .inl failure => Sum.inl failure
      | .inr failure => Sum.inr (Sum.inr failure)
  pure (some (prepared, plan))

def decodeDerivationInput (input : Necoherence.SignatureGeneration.Input)
    (expected : Necoherence.SignatureGeneration.Basis) :
    Except InputFailure (Option (PreparedCompositionInput × RawComposition)) := do
  let some (problemJson, derivationJson, prepared) ← decodePrepared input expected | return none
  let supplied ← Necoherence.SignatureCompositionWire.decodeDerivation input.signatures problemJson
    prepared derivationJson |>.mapError fun
      | .inl failure => Sum.inl failure
      | .inr failure => Sum.inr (Sum.inr failure)
  pure (some (prepared, supplied.proofProjection))

def verifyDecoded (prepared : PreparedCompositionInput) (raw : RawComposition) :
    Except InputFailure (VerifiedComposition prepared) :=
  match verified : verifyComposition prepared raw with
  | .ok checked => pure { raw, checked, verified }
  | .error failure => throw (Sum.inr (Sum.inr failure))

def verifyInput (input : Necoherence.SignatureGeneration.Input)
    (expected : Necoherence.SignatureGeneration.Basis) :
    Except InputFailure (Option ((prepared : PreparedCompositionInput) × VerifiedComposition prepared)) := do
  let some ⟨prepared, raw⟩ ← decodeDerivationInput input expected | return none
  pure (some ⟨prepared, ← verifyDecoded prepared raw⟩)

end Necoherence.SignatureComposition

namespace Necoherence.SignatureGeneration
open Necoherence.TypeSignatures

/-- 証明書の観測。復号できる合成は返す節点から作り、それ以外の合成は goal から作って続く復号の失敗で拒否する。 -/
def certificateObservations (input : Input) (expected : Basis) : Option GoalObservations :=
  input.composition.map fun composition =>
    match Necoherence.SignatureComposition.decodeInput input expected with
    | .ok _ => planObservations composition
    | .error _ => goalObservations composition

def admitCore (input : Input) (expected : ExpectedBasis) :
    Except AdmissionFailure (CheckedInput input) := do
  if input.schema != ruleRevision then throw (.unsupportedSchema input.schema)
  if input.entrypoints.isEmpty && input.composition.isNone then throw .entrypointsEmpty
  if input.entrypoints.any (fun entry => entry.identity.isEmpty) then
    throw .entrypointIdentityEmpty
  match Necoherence.ExactJson.firstRepeated [] (input.entrypoints.map (·.identity)) with
  | some identity => throw (.entrypointDuplicate identity)
  | none => pure ()
  match input.entrypoints.find? (fun entry =>
      !input.signatures.definitions.any (fun definition => definition.id == entry.definition)) with
  | some entry => throw (.entrypointUnresolved entry.identity entry.definition)
  | none => pure ()
  let library ← (checkLibrary input.signatures).mapError AdmissionFailure.library
  match h : admitCertificate input expected (certificateObservations input expected.basis) with
  | .error failure => throw (.certificate failure)
  | .ok checked => pure { library, trusted := basis_of_admitted input expected _ checked h }

def inputFailure : Necoherence.SignatureComposition.InputFailure → AdmissionFailure
  | .inl failure => .wire failure
  | .inr (.inl failure) => .compositionInput failure
  | .inr (.inr failure) => .composition failure

def admit (input : Input) (expected : ExpectedBasis) :
    Except AdmissionFailure (CheckedInput input ×
      Option (Necoherence.SemanticComposition.PreparedCompositionInput ×
        Necoherence.SemanticComposition.CompositionPlan)) := do
  let checked ← admitCore input expected
  let decoded ← (Necoherence.SignatureComposition.decodeInput input expected.basis).mapError inputFailure
  pure (checked, decoded)

def admitWithComposition (input : Input) (expected : ExpectedBasis) :
    Except AdmissionFailure (CheckedInput input ×
      Option ((prepared : Necoherence.SemanticComposition.PreparedCompositionInput) ×
        Necoherence.SignatureComposition.VerifiedComposition prepared)) := do
  let checked ← admitCore input expected
  let verified ← (Necoherence.SignatureComposition.verifyInput input expected.basis).mapError inputFailure
  pure (checked, verified)

theorem signatureBasisSound (input : Input) (checked : CheckedInput input) :
    input.basis = basis input.signatures input.entrypoints input.composition := checked.trusted

theorem signatureWireMetadataOrthogonality (library : TypeSignatureLibrary) (annotations : List Annotation)
    (groups : List DefinitionGroup) :
    graphProjection { library with annotations := annotations, groups := groups } = graphProjection library := rfl

end Necoherence.SignatureGeneration
