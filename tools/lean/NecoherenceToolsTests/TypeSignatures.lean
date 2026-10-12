-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import NecoherenceTools.SignatureGeneration

open Necoherence.TypeSignatures

private def require (condition : Bool) (message : String) : IO Unit :=
  if !condition then throw (IO.userError message) else pure ()

private def source : Necoherence.SemanticTypes.SourceIdentity :=
  { repository := "adapter", revision := "1", path := "opaque", contentDigest := String.ofList (List.replicate 64 '0') }

private def origin : Necoherence.SemanticTypes.Origin := { source := source, locator := ["operation"] }

private def profileReference : Necoherence.SemanticTypes.ProfileRef :=
  { identity := "value-only", revision := "2", contentDigest := String.ofList (List.replicate 64 '0') }

private def integerDomains : List Necoherence.SemanticTypes.IntegerDomainBinding :=
  [{ name := "integer", reference := profileReference, range := .unbounded, forms := [.number] }]

private def profile : ValueProfile :=
  { reference := profileReference, integerDomains, defaultIntegerDomain := "integer" }

private def nativeProfile : ValueProfile :=
  { profile with sourceRefs := [source], graphemeRules := some {
      reference := profile.reference, properties := [], extendedPictographic := [],
      indicConjunct := [], sources := [{ role := "table", origin }] } }

private def semanticProfile : Necoherence.SemanticTypes.VersionedSemanticProfile :=
  { reference := profile.reference, sourceRefs := [source], integerDomains,
    defaultIntegerDomain := "integer", graphemeRules := nativeProfile.graphemeRules }

private def success : OutcomeContract :=
  { id := "ok", form := .success, cause := .valueContract origin,
    valuePorts := [{ id := "value", contract := { typeId := "flag", required := true, nullable := false } }] }

private def external : OutcomeContract :=
  { id := "external", form := .declaredFailure, cause := .externalCondition origin,
    valuePorts := [{ id := "failure", contract := { typeId := "unit", required := true, nullable := false } }] }

private def operation : OperationContract :=
  { effect := .httpRequestResponse, inputs := [], outcomes := [success, external] }

private def library : TypeSignatureLibrary :=
  { identity := "opaque#library", revision := "2", profile := profile, sources := [source],
    nodes := [
      { id := "flag", shape := .boolean {} },
      { id := "unit", shape := .unit },
      { id := "record", shape := .product {
          fields := [Necoherence.TypeSignatures.Field.mk "known"
            { typeId := "flag", required := true, nullable := false }]
          extras := .reject } }],
    definitions := [{ id := "call", wireIdentity := "call", shape := .operation operation }],
    groups := [{ id := "document", members := ["call"] }],
    annotations := [{ target := .library, key := "description", value := .str "retained" },
      { target := .outcome "call" "external", key := "detail", value := .num 9007199254740993 }] }

def runTypeSignatureInvariants : IO Unit := do
  let .ok restoredProfile := Necoherence.SignatureWire.decode (α := ValueProfile)
      (Necoherence.SignatureWire.encode nativeProfile) |
    throw (IO.userError "native origin profile wire decode")
  require (restoredProfile == nativeProfile) "native origin profile wire roundtrip"
  let nativeGraph := { library with profile := nativeProfile }.graph
  require (nativeGraph.profile == semanticProfile) "native profile source identity preservation"
  let some rules := restoredProfile.graphemeRules | throw (IO.userError "native grapheme rules")
  require (rules.sources == [{ role := "table", origin }]) "native grapheme origin locator preservation"
  require (checkLibrary library).isOk "valid direct signatures"
  require (!(checkLibrary { library with nodes := library.nodes ++ library.nodes }).isOk) "duplicate identity"
  require (!(checkLibrary { library with nodes := [{ id := "bad", shape := .alias "unresolved" }] }).isOk) "unresolved reference"
  let reordered := { library with nodes := library.nodes.reverse, definitions := library.definitions.reverse }
  require (checkLibrary reordered).isOk "permuted admission"
  let changed := { library with annotations := [{ target := .library, key := "description", value := .str "changed" }] }
  require (!(operationExtensionValid operation { operation with outcomes := [success] } library)) "base outcome deletion"
  require (!(operationExtensionValid operation { operation with outcomes := [success, { external with form := .success }] } library)) "base outcome replacement"
  require (operationExtensionValid { operation with outcomes := [success] } operation library) "external supplement"
  require (!(checkCoverage operation ["ok"]).isOk) "external outcome missing handler"
  require (checkCoverage operation ["ok", "external"]).isOk "all outcomes covered"
  require (!completedValid operation success && completedValid operation external) "prepare external failure restriction"
  let entrypoints : List Necoherence.SignatureGeneration.Entrypoint := [{ identity := "entry", definition := "call" }]
  let trusted := Necoherence.SignatureGeneration.basis library entrypoints
  let input : Necoherence.SignatureGeneration.Input := { basis := trusted, signatures := library, entrypoints := entrypoints }
  let .ok restored := Necoherence.SignatureGeneration.decodeInput (Necoherence.SignatureGeneration.encodeInput input) |
    throw (IO.userError "native signature wire roundtrip")
  require (restored.signatures == library && restored.basis == trusted) "signature wire identity"
  require (Necoherence.SignatureGeneration.admit restored trusted).isOk "wire admission"
  require ((Necoherence.SignatureGeneration.basis reordered entrypoints).graphSha256 == trusted.graphSha256) "wire canonical permutation"
  let metadataChanged := Necoherence.SignatureGeneration.basis changed entrypoints
  require (metadataChanged.graphSha256 == trusted.graphSha256 && metadataChanged.provenanceSha256 == trusted.provenanceSha256 &&
    metadataChanged.metadataSha256 != trusted.metadataSha256) "wire metadata orthogonality"
  require (!(Necoherence.SignatureGeneration.admit { input with signatures := changed } trusted).isOk) "wire metadata tampering"
  require (!(Necoherence.SignatureGeneration.admit input { trusted with graphSha256 := "tampered" }).isOk) "wire basis mismatch"
  require (!(Necoherence.SignatureJson.parse "{\"schema\":1,\"\\u0073chema\":2}").isOk) "duplicate wire field"
  require (!(Necoherence.SignatureWire.decodeExact (Lean.Json.mkObj [("tag", .str "Decimal"), ("text", .str "true")])).isOk) "invalid decimal"
  let inconsistent := { library with nodes := [{ id := "flag", shape := .integer { minimum := some 2, maximum := some 1 } }, { id := "unit", shape := .unit }] }
  require (!(checkLibrary inconsistent).isOk) "inconsistent range"
  let invalidDefault := { library with nodes := [{ id := "flag", shape := .integer { minimum := some 2, defaultValue := some 1 } }, { id := "unit", shape := .unit }] }
  require (!(checkLibrary invalidDefault).isOk) "default membership"
  let .ok generated := NecoherenceTools.SignatureGeneration.generate input trusted | throw (IO.userError "wire generation")
  IO.FS.withTempDir fun directory => do
    let path := directory / "SignatureSmoke.lean"
    IO.FS.writeFile path (generated ++ "\ndef main : IO Unit := do\n" ++
      "  let .ok value := Generated.decodeRaw0 (.bool true) | throw (IO.userError \"decode boolean\")\n" ++
      "  if Generated.encode0 value != .bool true then throw (IO.userError \"roundtrip\")\n" ++
      "  let productWire := Lean.Json.mkObj [(\"known\", .bool true)]\n" ++
      "  let .ok product := Generated.decode2 productWire | throw (IO.userError \"declared product member\")\n" ++
      "  let .ok encodedProduct := Generated.encodeJson2 product | throw (IO.userError \"encode product\")\n" ++
      "  if encodedProduct.compress != productWire.compress then throw (IO.userError \"product roundtrip\")\n" ++
      "  if (Generated.decode2 (Lean.Json.mkObj [(\"known\", .bool true), (\"extra\", .bool false)])).isOk then throw (IO.userError \"undeclared product member\")\n" ++
      "  if signatureAnnotationsAt (.outcome \"call\" \"external\") != [{ target := .outcome \"call\" \"external\", key := \"detail\", value := .num 9007199254740993 }] then throw (IO.userError \"exact outcome annotation\")\n" ++
      "  let .ok failure := Generated.make1 Generated.Raw1.mk | throw (IO.userError \"typed failure\")\n  let _ : SignatureDeclaration0.Result := .outcome1 failure\n" ++
      "  let .ok success := Generated.make0 value | throw (IO.userError \"typed success\")\n" ++
      "  let state ← IO.mkRef ({ attempts := [] } : Necoherence.NetworkState)\n" ++
      "  let commands ← IO.mkRef (0 : Nat)\n" ++
      "  let transport : Necoherence.SemanticNetwork.NetworkBinding Necoherence.AttemptInput SignatureDeclaration0.Result := {\n" ++
      "    state := state\n    encode := Except.ok\n    decode := fun _ => .error (.invalidPlan \"response not expected\")\n" ++
      "    start := fun _ => do commands.modify (· + 1); throw (IO.userError \"completed outcome issued HTTP\")\n" ++
      "    observe := fun _ => throw (IO.userError \"completed outcome observed HTTP\") }\n" ++
      "  let binding : SignatureDeclaration0.Binding := {\n    transport := transport\n" ++
      "    prepare := fun _ => .ok (.completed (SignatureDeclaration0.contract.outcomes[1]'(by decide)) (.outcome1 failure))\n" ++
      "    outcomeId := fun result => match result with | .outcome0 _ => \"ok\" | .outcome1 _ => \"external\" }\n" ++
      "  let .ok (.outcome1 _) ← SignatureDeclaration0.call binding {} | throw (IO.userError \"external completion\")\n" ++
      "  let invalid := { binding with prepare := fun _ => .ok (.completed (SignatureDeclaration0.contract.outcomes[0]'(by decide)) (.outcome0 success)) }\n" ++
      "  if (← SignatureDeclaration0.call invalid {}).isOk then throw (IO.userError \"success completed before HTTP\")\n" ++
      "  let mislabeled := { binding with prepare := fun _ => .ok (.completed (SignatureDeclaration0.contract.outcomes[1]'(by decide)) (.outcome0 success)) }\n" ++
      "  if (← SignatureDeclaration0.call mislabeled {}).isOk then throw (IO.userError \"completed result identity mismatch\")\n" ++
      "  if (← commands.get) != 0 || !(← state.get).attempts.isEmpty then throw (IO.userError \"completed outcome had network effects\")\n" ++
      "  IO.println \"signature_prepare completed=external rejected_success=ok rejected_mismatch=ok network_effects=0\"\n" ++
      "  IO.println \"signature_generated_roundtrip=ok metadata=exact external_result=typed\"\n")
    let result ← IO.Process.output { cmd := "lake", args := #["env", "lean", "--run", path.toString] }
    if result.exitCode != 0 then throw (IO.userError (result.stdout ++ result.stderr))
    IO.print result.stdout
  IO.println "signature_invalid=7 permutation=ok orthogonality=ok coverage=ok prepare=ok"

