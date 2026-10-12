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

def runSignatureCompositionWireProperties (input : Input) : IO Unit := do
  checkDiagnosticSchema
  checkRoundtrip input
  checkTampering input
  checkSearchIndependentAdmission input
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
