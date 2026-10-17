-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import NecoherenceTools.SignatureGeneration
import NecoherenceTools.CompositionSearch

open Lean Necoherence.SignatureGeneration Necoherence.SignatureWire

private def replaceMember (json : Json) (key : String) (value : Json) : Except String Json := do
  let object ← json.getObj?
  pure (Json.mkObj (object.toList.map (fun member => if member.1 == key then (key, value) else member)))

private partial def replaceProducer : Json → Json
  | .obj object => Json.mkObj (object.toList.map fun (key, value) =>
      (key, if key == "producer" then Json.mkObj [("tag", .str "Initial"), ("value", .str "undeclared-input")] else replaceProducer value))
  | .arr values => .arr (values.map replaceProducer)
  | value => value

private def changedDerivation (input : Input) (change : Json → Except String Json) : Except String Input := do
  let some composition := input.composition | throw "composition required"
  let derivation ← change (← composition.getObjVal? "derivation")
  let composition ← replaceMember composition "derivation" derivation
  pure { input with composition := some composition, basis := basis input.signatures input.entrypoints (some composition) }

private def rejectPublic (name : String) (input : Input) : IO Unit := do
  if (admit input input.basis).isOk then throw (IO.userError (name ++ " admitted"))
  if (NecoherenceTools.SignatureComposition.generate input input.basis).isOk then throw (IO.userError (name ++ " generated"))

private def runRust (manifest : System.FilePath) (mode : String) (input : Input) : IO Input := do
  let exchange := manifest.parent.get! / "exchange.json"
  IO.FS.writeFile exchange (encodeInput input)
  let cwd ← IO.currentDir
  let target := cwd / ".lake/signature-closure-target"
  let result ← IO.Process.output {
    cmd := "cargo"
    args := #["run", "--offline", "--quiet", "--manifest-path", manifest.toString, "--", mode, exchange.toString]
    env := #[("CARGO_TARGET_DIR", some target.toString)] }
  if result.exitCode != 0 then throw (IO.userError (result.stdout ++ result.stderr))
  match decodeInput result.stdout with
  | .ok input => pure input
  | .error failure => throw (IO.userError (reprStr failure))

private def checkRoundtrip (input : Input) : IO Unit := do
  let some composition := input.composition | throw (IO.userError "composition required")
  let .ok problemJson := composition.getObjVal? "problem" | throw (IO.userError "problem required")
  let .ok (problem, causes) := Necoherence.SignatureComposition.decodeProblem input.signatures problemJson | throw (IO.userError "problem decode")
  let .ok prepared := Necoherence.SignatureComposition.prepare input.signatures input.basis.graphSha256 problem causes | throw (IO.userError "problem preparation")
  let .ok supplied := composition.getObjVal? "derivation" | throw (IO.userError "derivation required")
  let wire ← match Necoherence.SignatureCompositionWire.decodeDerivation input.signatures problemJson prepared supplied with
    | .ok wire => pure wire
    | .error failure => throw (IO.userError (reprStr failure))
  match Necoherence.SemanticComposition.verifyComposition prepared wire.proofProjection with
  | .ok _ => pure ()
  | .error failure => throw (IO.userError ("supplied proof projection: " ++ reprStr failure))
  if canonicalJson (Necoherence.SignatureCompositionWire.encodeDerivation wire) != canonicalJson supplied then
    throw (IO.userError "wire diagnostics lost during roundtrip")
  let .ok _ := admit input input.basis | throw (IO.userError "public admission rejected verified derivation")
  let .ok _ := NecoherenceTools.SignatureComposition.generate input input.basis | throw (IO.userError "public generation rejected verified derivation")

private def checkTampering (input : Input) : IO Unit := do
  let mutations : List (String × (Json → Except String Json)) := [
    ("plan", fun derivation => do
      let plan ← derivation.getObjVal? "plan"
      replaceMember derivation "plan" (← replaceMember plan "input_revision" (.str "forged"))),
    ("binding", fun derivation => do
      let plan ← derivation.getObjVal? "plan"
      replaceMember derivation "plan" (replaceProducer plan)),
    ("selection", fun derivation => replaceMember derivation "selection" (Json.mkObj [("tag", .str "Unknown")])),
    ("branch witness", fun derivation => do
      let witness ← derivation.getObjVal? "witness"
      replaceMember derivation "witness" (← replaceMember witness "resource_traces" (.arr #[]))) ]
  for (name, change) in mutations do
    let forged ← match changedDerivation input change with
      | .ok value => pure value
      | .error failure => throw (IO.userError failure)
    rejectPublic name forged
  for classification in ["Unreachable", "Ambiguous", "Unknown"] do
    let .ok forged := changedDerivation input (fun derivation =>
      replaceMember derivation "selection" (Json.mkObj [("tag", .str classification)])) |
      throw (IO.userError "classification mutation")
    rejectPublic classification forged

private def checkDiagnosticSchema : IO Unit := do
  let canonical ← IO.FS.readFile "../../comparison/declaration/ncoh-checked-generation-v4.schema.json"
  let .ok json := Necoherence.SignatureJson.parse canonical | throw (IO.userError "canonical schema parse")
  let .ok definitions := (json.getObjVal? "$defs" >>= Json.getObj?) | throw (IO.userError "canonical definitions")
  let .ok saved := (Necoherence.SignatureJson.parse Necoherence.SignatureCompositionDiagnostics.schemaText >>= Json.getObj?) |
    throw (IO.userError "diagnostic schema parse")
  for (name, value) in saved.toList do
    let some expected := definitions[name]? | throw (IO.userError ("missing canonical definition " ++ name))
    if canonicalJson value != canonicalJson expected then throw (IO.userError ("diagnostic schema differs " ++ name))

private def checkSearchIndependentAdmission (input : Input) : IO Unit := do
  let adjusted : Except String Input := do
    let some composition := input.composition | throw "composition required"
    let problem ← composition.getObjVal? "problem"
    let bounds ← problem.getObjVal? "bounds"
    let problem ← replaceMember problem "bounds" (← replaceMember bounds "max_expanded_states" (.str "0"))
    let derivation ← composition.getObjVal? "derivation"
    let witness ← derivation.getObjVal? "witness"
    let derivation ← replaceMember derivation "witness" (← replaceMember witness "input_snapshot" problem)
    let composition ← replaceMember (← replaceMember composition "problem" problem) "derivation" derivation
    pure { input with composition := some composition, basis := basis input.signatures input.entrypoints (some composition) }
  let bounded ← match adjusted with
    | .ok value => pure value
    | .error failure => throw (IO.userError failure)
  let some composition := bounded.composition | throw (IO.userError "composition required")
  let .ok problemJson := composition.getObjVal? "problem" | throw (IO.userError "problem required")
  let .ok (problem, causes) := Necoherence.SignatureComposition.decodeProblem bounded.signatures problemJson | throw (IO.userError "bounded problem decode")
  let .ok prepared := Necoherence.SignatureComposition.prepare bounded.signatures bounded.basis.graphSha256 problem causes | throw (IO.userError "bounded problem preparation")
  match NecoherenceTools.CompositionSearch.derive prepared with
  | .ok (.unknown _ _) => pure ()
  | _ => throw (IO.userError "zero search bound must leave derivation unknown")
  let .ok _ := admit bounded bounded.basis | throw (IO.userError "valid supplied proof depends on solver completion")
  let .ok _ := NecoherenceTools.SignatureComposition.generate bounded bounded.basis | throw (IO.userError "valid supplied generation depends on solver completion")

private def changeDiagnostic (derivation : Json) (valid : Bool) : Except String Json := do
  let selection ← derivation.getObjVal? "selection"
  let fields ← selection.getObjVal? "fields"
  let closure ← fields.getObjVal? "closure"
  let states ← (← closure.getObjVal? "states").getArr?
  let some index := states.toList.findIdx? (fun state =>
      ((state.getObjVal? "terminals" >>= Json.getArr?).toOption.getD #[]).size > 0) |
    throw "terminal state required"
  let state := states[index]!
  let terminals ← (← state.getObjVal? "terminals").getArr?
  let terminal := terminals[0]!
  let assessment ← terminal.getObjVal? "assessment"
  let certificate ← assessment.getObjVal? "value"
  let diagnostic := Json.mkObj [("tag", .str "RejectedLowering"), ("fields", Json.mkObj [
    ("trace", ← certificate.getObjVal? "trace"),
    ("reason", if valid then .str "reason retained as a diagnostic" else .bool false)])]
  let coverage ← replaceMember terminal "assessment" diagnostic
  let state ← replaceMember state "terminals" (.arr (terminals.push coverage))
  let closure ← replaceMember closure "states" (.arr (states.set! index state))
  let fields ← replaceMember fields "closure" closure
  replaceMember derivation "selection" (← replaceMember selection "fields" fields)

private def checkSampleBounds (input : Input) : IO Unit := do
  let adjusted : Except String Input := do
    let some composition := input.composition | throw "composition required"
    let problem ← composition.getObjVal? "problem"
    let bounds ← problem.getObjVal? "bounds"
    let problem ← replaceMember problem "bounds" (← replaceMember bounds "max_sample_length" (.str "59"))
    let derivation ← composition.getObjVal? "derivation"
    let witness ← derivation.getObjVal? "witness"
    let derivation ← replaceMember derivation "witness" (← replaceMember witness "input_snapshot" problem)
    let composition ← replaceMember (← replaceMember composition "problem" problem) "derivation" derivation
    pure { input with composition := some composition, basis := basis input.signatures input.entrypoints (some composition) }
  let .ok adjusted := adjusted | throw (IO.userError "sample bound input")
  checkRoundtrip adjusted
  let some composition := adjusted.composition | throw (IO.userError "composition required")
  let .ok problemJson := composition.getObjVal? "problem" | throw (IO.userError "problem required")
  let .ok (problem, causes) := Necoherence.SignatureComposition.decodeProblem input.signatures problemJson | throw (IO.userError "bound problem decode")
  if problem.bounds.maxSampleLength != 59 then throw (IO.userError "caller sample length lost")
  let boundsJson := encode problem.bounds
  let .ok restored := (decode boundsJson : Except WireFailure Necoherence.SemanticComposition.SearchBounds) |
    throw (IO.userError "bound roundtrip")
  if restored != problem.bounds then throw (IO.userError "bound roundtrip changed")
  for invalid in [Json.num 59, .str "-1", .str "059"] do
    let .ok invalid := replaceMember boundsJson "max_sample_length" invalid | throw (IO.userError "invalid bound mutation")
    if (decode invalid : Except WireFailure Necoherence.SemanticComposition.SearchBounds).isOk then
      throw (IO.userError "noncanonical sample bound accepted")
  let .ok members := boundsJson.getObj? | throw (IO.userError "bounds object")
  let missing := Json.mkObj (members.toList.filter fun member => member.1 != "max_sample_length")
  if (decode missing : Except WireFailure Necoherence.SemanticComposition.SearchBounds).isOk then
    throw (IO.userError "missing sample bound accepted")
  let .ok prepared := Necoherence.SignatureComposition.prepare input.signatures input.basis.graphSha256 problem causes |
    throw (IO.userError "bound preparation")
  let some node := prepared.graph.nodes.head? | throw (IO.userError "sample graph node")
  for length in [7, 17, 59] do
    let text := String.ofList (List.replicate length 'x')
    let graph := { prepared.graph with nodes := [{ node with shape := .string { constValue := some text } }] }
    let contract : Necoherence.SemanticTypes.SlotContract := { typeRef := node.ref, required := true, nullable := false }
    for maximum in [length - 1, length] do
      let bounds : Necoherence.SemanticComposition.SearchBounds := { maxSampleLength := maximum }
      let finite : Necoherence.SemanticComposition.CompositionInput := { problem with
        basis := { profile := graph.profile, sources := graph.sourceRefs }
        signatures := []
        initialInputs := [{ id := ⟨"finite"⟩, contract, source := .argument, resource := none }]
        initialResources := []
        goal := { outputs := [{ id := ⟨"finite"⟩, contract, sourceConstraint := .anyCompatible }], failures := [], finalResources := [] }
        invocationDomain := { identity := "finite", revision := "1", sites := [], permittedProjections := [], permittedConstructions := [], permittedTransforms := [], guards := [] }
        allowedEffects := []
        explicitOrder := []
        selectionPolicy := some .anyFeasible
        bounds }
      let .ok finite := Necoherence.SemanticComposition.prepareDirectComposition graph finite (fun _ _ => .ok ()) (fun _ _ => []) |
        throw (IO.userError "finite preparation")
      let sampled := Necoherence.SemanticComposition.slotSamples finite contract
      match NecoherenceTools.CompositionSearch.derive finite with
      | .ok (.unknown _ _) =>
        if maximum == length || sampled.values != [] || !sampled.obligations.contains .sampleBound then
          throw (IO.userError "lower SampleBound and solver Unknown")
      | .ok (.solved checked) =>
        if maximum != length || !sampled.values.contains (.present (.str text)) then
          throw (IO.userError "accepted finite witness")
        let raw : Necoherence.SemanticComposition.RawComposition := {
          plan := checked.candidate.raw.plan, witness := checked.candidate.raw.witness, selection := .anyFeasible }
        if !(Necoherence.SemanticComposition.verifyComposition finite raw).isOk then
          throw (IO.userError "finite witness verification")
      | _ => throw (IO.userError "finite bound solver classification")
  let profileText ← IO.FS.readFile "../../presets/atproto-data-model/profile.json"
  let .ok profileJson := Necoherence.SignatureJson.parse profileText | throw (IO.userError "CID profile parse")
  let .ok profile := (decode profileJson : Except WireFailure Necoherence.TypeSignatures.ValueProfile) |
    throw (IO.userError "CID profile decode")
  let library := { input.signatures with profile }
  let graph := { prepared.graph with
    profile := library.graph.profile
    nodes := [{ node with shape := .string { format := some (.named "cid") } }] }
  let contract : Necoherence.SemanticTypes.SlotContract := { typeRef := node.ref, required := true, nullable := false }
  for maximum in [32, 58, 59] do
    let sampled := Necoherence.SemanticComposition.sampleValueFuel graph { maxSampleLength := maximum } (graph.nodes.length + 1) [] contract.typeRef
    if maximum < 59 then
      if sampled.values != [] || !sampled.obligations.contains .sampleBound then
        throw (IO.userError "CID lower SampleBound")
    else
      if sampled.values == [] then throw (IO.userError "CID finite sample")
      for value in sampled.values do
        let .str text := value | throw (IO.userError "CID string sample")
        if text.length != 59 then throw (IO.userError "CID sample length")
        if !(Necoherence.SemanticValidation.acceptsValue graph contract.typeRef value == .accepted) then
          throw (IO.userError "CID accepted sample")

def runSignatureCompositionWireProperties (input : Input) : IO Unit := do
  checkDiagnosticSchema
  checkRoundtrip input
  checkTampering input
  checkSearchIndependentAdmission input
  checkSampleBounds input
  let cwd ← IO.currentDir
  let source ← IO.FS.readFile "NecoherenceToolsTests/SignatureClosureProducer.rs"
  IO.FS.withTempDir fun directory => do
    IO.FS.createDirAll (directory / "src")
    IO.FS.writeFile (directory / "src/main.rs") source
    let manifest := directory / "Cargo.toml"
    IO.FS.writeFile manifest ("[package]\nname = \"ncoh-lean-closure-test\"\nversion = \"0.0.0\"\nedition = \"2021\"\n[dependencies]\nnecoherence = { path = " ++
      (Json.str (cwd.parent.get!.parent.get! / "rust").toString).compress ++ " }\nnecoherence-tools = { path = " ++ (Json.str (cwd.parent.get! / "rust").toString).compress ++ " }\nserde_json = { version = \"1\", features = [\"arbitrary_precision\", \"preserve_order\"] }\n")
    IO.FS.writeFile (directory / "Cargo.lock") (← IO.FS.readFile "../../comparison/declaration/signature_generator/Cargo.lock")
    let unique ← runRust manifest "unique" input
    checkRoundtrip unique
    checkTampering unique
    let compositionOnly : Input := {
      unique with entrypoints := [], basis := basis unique.signatures [] unique.composition }
    checkRoundtrip compositionOnly
    let _ ← runRust manifest "verify" compositionOnly
    let .ok diagnostic := changedDerivation unique (fun derivation => changeDiagnostic derivation true) |
      throw (IO.userError "diagnostic preservation input")
    checkRoundtrip diagnostic
    let .ok malformed := changedDerivation unique (fun derivation => changeDiagnostic derivation false) |
      throw (IO.userError "diagnostic shape input")
    rejectPublic "diagnostic type" malformed
    let preserved ← runRust manifest "verify" unique
    if canonicalJson (encode preserved) != canonicalJson (encode unique) then throw (IO.userError "Rust unique wire roundtrip")
    let .ok wrongPolicy := changedDerivation unique (fun derivation =>
      replaceMember derivation "selection" (Json.mkObj [("tag", .str "AnyFeasible")])) |
      throw (IO.userError "selection policy mutation")
    rejectPublic "RequireUnique/AnyFeasible mismatch" wrongPolicy
    IO.println "signature_unique wire=lossless proof=verified public_admission=checked tampering=rejected"
