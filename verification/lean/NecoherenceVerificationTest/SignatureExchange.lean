-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import NecoherenceGenerator.SignatureGeneration
import NecoherenceCompositionSolver.CompositionSearch
import NecoherenceVerificationTest.SignatureCompositionWire

open Lean Necoherence.SignatureGeneration Necoherence.SignatureWire

private def replace (json : Json) (key : String) (value : Json) : Json :=
  match json.getObj? with
  | .ok object => Json.mkObj ((object.toList.filter (fun item => item.1 != key)) ++ [(key, value)])
  | .error _ => json

private def changedCause (problem : Json) : Except String Json := do
  let signatures ← (← problem.getObjVal? "signatures").getArr?
  let some signature := signatures[0]? | throw "signature required"
  let outcomes ← (← signature.getObjVal? "outcomes").getArr?
  let some outcome := outcomes[0]? | throw "outcome required"
  let cause ← outcome.getObjVal? "cause"
  let fields ← cause.getObjVal? "fields"
  let origin ← fields.getObjVal? "origin"
  let altered := replace cause "fields" (replace fields "origin" (replace origin "locator" (.arr #[.str "altered-only-in-witness"])))
  let signature := replace signature "outcomes" (.arr (outcomes.set! 0 (replace outcome "cause" altered)))
  pure (replace problem "signatures" (.arr (signatures.set! 0 signature)))

private def producer (composition : Bool) : IO Input := do
  let arguments := #["run", "--quiet", "--manifest-path", "../../verification/declaration/signature_generator/Cargo.toml", "--bin", "signatures"] ++
    (if composition then #["--", "composition"] else #[])
  let result ← IO.Process.output { cmd := "cargo", args := arguments }
  if result.exitCode != 0 then throw (IO.userError (result.stdout ++ result.stderr))
  match decodeInput result.stdout with
  | .ok input => pure input
  | .error failure => throw (IO.userError (reprStr failure))

def runSignatureExchangeProperties : IO Unit := do
  for composition in [false, true] do
    let input ← producer composition
    let trusted := input.basis
    let expected := ExpectedBasis.ofInput input
    match admit input expected with
    | .ok _ => pure ()
    | .error failure => throw (IO.userError ("independent canonical admission: " ++ reprStr failure))
    let .ok restored := decodeInput (encodeInput input) | throw (IO.userError "native exchange roundtrip")
    if restored.signatures != input.signatures || restored.basis != trusted then
      throw (IO.userError "exchange value or basis changed")
    let reordered := { input with signatures := { input.signatures with nodes := input.signatures.nodes.reverse, definitions := input.signatures.definitions.reverse } }
    let .ok _ := admit reordered expected | throw (IO.userError "declaration permutation changed admission")
    let changed := { input with signatures := { input.signatures with annotations := [{ target := .library, key := "description", value := .dec "1.500e2" }] } }
    let changedBasis := basis changed.signatures changed.entrypoints changed.composition
    if changedBasis.graphSha256 != trusted.graphSha256 || changedBasis.provenanceSha256 != trusted.provenanceSha256 || changedBasis.metadataSha256 == trusted.metadataSha256 then
      throw (IO.userError "metadata digest orthogonality")
    if (admit changed expected).isOk then throw (IO.userError "metadata tampering admitted")
    if let some composition := input.composition then
      runSignatureCompositionWireProperties input
      let .ok problemJson := composition.getObjVal? "problem" | throw (IO.userError "problem required")
      let .ok (problem, causes) := Necoherence.SignatureComposition.decodeProblem input.signatures problemJson |
        throw (IO.userError "native problem decode")
      let retained := problem.signatures.filter (fun signature => signature.handlesFailure.isNone)
      let withoutHandler := { problem with signatures := retained, invocationDomain := {
        problem.invocationDomain with
        sites := problem.invocationDomain.sites.filter (fun site => retained.any (fun signature => signature.reference == site.function))
        permittedTransforms := problem.invocationDomain.permittedTransforms.filter (fun reference => retained.any (fun signature => signature.reference == reference)) } }
      let .ok incomplete := Necoherence.SignatureComposition.prepare input.signatures trusted.graphSha256 withoutHandler causes |
        throw (IO.userError "missing-handler problem preparation")
      match NecoherenceTools.CompositionSearch.derive incomplete with
      | .ok (.unreachable _) | .ok (.unknown _ _) => pure ()
      | _ => throw (IO.userError "unhandled external outcome was reachable")
      let .ok alteredProblem := changedCause problemJson | throw (IO.userError "cause mutation")
      let .ok derivation := composition.getObjVal? "derivation" | throw (IO.userError "derivation required")
      let .ok witness := derivation.getObjVal? "witness" | throw (IO.userError "witness required")
      let altered := replace composition "derivation" (replace derivation "witness" (replace witness "input_snapshot" alteredProblem))
      let alteredInput := { input with composition := some altered, basis := basis input.signatures input.entrypoints (some altered) }
      if (admit alteredInput (ExpectedBasis.ofInput alteredInput)).isOk then
        throw (IO.userError "witness cause substitution admitted")
      if (NecoherenceTools.SignatureComposition.generate alteredInput (ExpectedBasis.ofInput alteredInput)).isOk then
        throw (IO.userError "witness cause substitution admitted")
      IO.println "signature_external_branch missing_handler=unreachable_or_unknown witness_cause_substitution=rejected"
    let generated ← match NecoherenceTools.SignatureComposition.generate input expected with
      | .ok generated => pure generated
      | .error reason => throw (IO.userError (reprStr reason))
    IO.FS.withTempDir fun directory => do
      let path := directory / "ExchangeConsumer.lean"
      let checks := if composition then
        "\n#check Generated.StartFailure.preparation\n" ++
          "#check Generated.StartFailure.composition\n" ++
          "#check Generated.StartFailure.execution\n" ++
          "#check (Generated.run : Generated.Providers → Generated.Arguments → Necoherence.NetworkState → Except Generated.StartFailure Generated.RunProgress)\n" ++
          "#check (Generated.resume : Necoherence.SemanticExecution.Execution → Necoherence.SemanticExecution.ExecutionObservation → Except Necoherence.SemanticExecution.RunFailure Generated.RunProgress)\n"
        else ""
      IO.FS.writeFile path (generated ++ checks)
      let result ← IO.Process.output { cmd := "lake", args := #["env", "lean", path.toString] }
      if result.exitCode != 0 then throw (IO.userError (result.stdout ++ result.stderr))
    IO.println s!"signature_exchange composition={composition} canonical_basis=ok permutation=ok metadata=isolated generated=compiled"
