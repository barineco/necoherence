-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import Necoherence.SignatureComposition
import NecoherenceTools.SemanticRenderer

namespace NecoherenceTools.TypeSignatures
open Necoherence Necoherence.SemanticTypes Necoherence.ExactJson Necoherence.TypeSignatures

def generate (library : TypeSignatureLibrary) : Except String String := do
  let _ ← (checkLibrary library).mapError reprStr
  let graph := library.graph
  for node in graph.nodes do
    let _ ← (Necoherence.SemanticValidation.checkMeaningDefined graph [node.ref]).mapError
      (fun failure => "undefined value meaning: " ++ reprStr failure)
  let source ← (NecoherenceTools.SemanticRenderer.renderDefinitions graph).mapError reprStr
  let mut declarations := ""
  for (definition, index) in library.definitions.zipIdx do
    let name := "SignatureDeclaration" ++ toString index
    let valueType := fun id => do
      let index ← (NecoherenceTools.SemanticRenderer.nodeIndex graph (typeRef id)).mapError reprStr
      pure ("Generated.Value" ++ toString index)
    let portType := fun (port : Port) => do
      let value ← valueType port.contract.typeId
      pure (if port.contract.required && !port.contract.nullable then value
        else if !port.contract.required && port.contract.nullable then "Necoherence.SemanticCodec.Presence " ++ value
        else "Option " ++ value)
    let body ← match definition.shape with
      | .value id | .message id => do pure ("abbrev Value := " ++ (← valueType id) ++ "\n")
      | .symbol symbol => pure ("def wireSymbol : String := " ++ reprStr symbol ++ "\n")
      | .operation operation => do
        let variants ← operation.outcomes.zipIdx |>.mapM fun (outcome, i) => do
          let ports ← outcome.valuePorts.mapM portType
          let payload := if ports.isEmpty then "Unit" else String.intercalate " × " ports
          pure ("  | outcome" ++ toString i ++ " (value : " ++ payload ++ ")\n")
        let arguments ← operation.inputs.zipIdx |>.mapM fun (port, i) => do
          pure ("  port" ++ toString i ++ " : " ++ (← portType port) ++ "\n")
        pure ("def contract : Necoherence.TypeSignatures.OperationContract := " ++
          (reprStr operation).replace "\n" " " ++ "\n" ++
          "structure Arguments where\n" ++ String.join arguments ++
          "inductive Result where\n" ++ String.join variants ++
          "abbrev Binding := Necoherence.TypeSignatures.NetworkBinding Arguments Result\n" ++
          "def call (binding : Binding) (arguments : Arguments) := Necoherence.TypeSignatures.call contract binding arguments\n")
    declarations := declarations ++ "namespace " ++ name ++ "\n" ++
      "def identity : String := " ++ reprStr definition.id ++ "\n" ++ body ++ "end " ++ name ++ "\n"
  pure ("-- SPDX-License-Identifier: MIT\nimport Necoherence.TypeSignatures\n" ++ source ++ "\n" ++ declarations ++
    "\ndef signatureAnnotations : List Necoherence.TypeSignatures.Annotation := " ++ (reprStr library.annotations).replace "\n" " " ++ "\n" ++
    "def signatureAnnotationsAt (target : Necoherence.TypeSignatures.Target) := signatureAnnotations.filter (fun annotation => annotation.target == target)\n")

end NecoherenceTools.TypeSignatures

namespace NecoherenceTools.SignatureComposition
open Lean Necoherence Necoherence.SemanticTypes Necoherence.SemanticComposition Necoherence.SignatureWire
open Necoherence.SignatureComposition

def generate (input : Necoherence.SignatureGeneration.Input)
    (expected : Necoherence.SignatureGeneration.Basis) :
    Except Necoherence.SignatureGeneration.AdmissionFailure String := do
  let _ ← Necoherence.SignatureGeneration.admitBasis input expected
  let verified ← (verifyInput input expected).mapError fun
    | .inl failure => Necoherence.SignatureGeneration.AdmissionFailure.wire failure
    | .inr failure => Necoherence.SignatureGeneration.AdmissionFailure.composition failure
  match verified with
  | none =>
    match NecoherenceTools.TypeSignatures.generate input.signatures with
    | .ok generated => pure generated
    | .error failure => throw (.generation failure)
  | some ⟨prepared, checked⟩ =>
    let some composition := input.composition |
      throw (Necoherence.SignatureGeneration.AdmissionFailure.generation
        "verified composition missing")
    let problemJson ← (liftJson (composition.getObjVal? "problem")).mapError
      Necoherence.SignatureGeneration.AdmissionFailure.wire
    let (problem, causes) ← (decodeProblem input.signatures problemJson).mapError
      Necoherence.SignatureGeneration.AdmissionFailure.wire
    let generated : Except String String := do
      let preparation := "Necoherence.SignatureComposition.prepare (" ++
        (reprStr input.signatures).replace "\n" " " ++ ") " ++ reprStr expected.graphSha256 ++
        " problem (" ++ (reprStr causes).replace "\n" " " ++ ")"
      let networkContracts ← problem.invocationDomain.sites.filterMap (fun site =>
        (problem.signatures.find? fun signature => signature.reference == site.function).map
          fun signature => (site.id, signature)) |>.mapM fun (site, signature) => do
            let contract ← signatureContract causes signature
            pure (site, (reprStr contract).replace "\n" " ")
      let rendered ← (NecoherenceTools.SemanticRenderer.renderChecked prepared checked preparation
        networkContracts).mapError reprStr
      pure ("-- SPDX-License-Identifier: MIT\nimport Necoherence.SignatureComposition\n" ++ rendered ++
        "\ndef signatureAnnotations : List Necoherence.TypeSignatures.Annotation := " ++
        (reprStr input.signatures.annotations).replace "\n" " " ++ "\n" ++
        "def signatureAnnotationsAt (target : Necoherence.TypeSignatures.Target) := signatureAnnotations.filter (fun annotation => annotation.target == target)\n")
    match generated with
    | .ok output => pure output
    | .error failure => throw (.generation failure)

end NecoherenceTools.SignatureComposition

namespace NecoherenceTools.SignatureGeneration
open Necoherence Necoherence.TypeSignatures Necoherence.SignatureGeneration

def generate (input : Input) (expected : Basis) : Except AdmissionFailure String := do
  let _ ← admit input expected
  if input.composition.isSome then
    throw (.generation "composition generation requires SignatureComposition.generate")
  (NecoherenceTools.TypeSignatures.generate input.signatures).mapError AdmissionFailure.generation

end NecoherenceTools.SignatureGeneration
