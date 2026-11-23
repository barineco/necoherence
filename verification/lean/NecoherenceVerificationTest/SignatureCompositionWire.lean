-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import NecoherenceCompositionSolver.SemanticEvidence
import NecoherenceGenerator.SignatureGeneration
import NecoherenceCompositionSolver.CompositionSearch

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
  if (admitWithComposition input (ExpectedBasis.ofInput input)).isOk then throw (IO.userError (name ++ " admitted"))
  if (NecoherenceTools.SignatureComposition.generate input (ExpectedBasis.ofInput input)).isOk then throw (IO.userError (name ++ " generated"))

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
  let .ok _ := admitWithComposition input (ExpectedBasis.ofInput input) | throw (IO.userError "public admission rejected verified derivation")
  let .ok _ := NecoherenceTools.SignatureComposition.generate input (ExpectedBasis.ofInput input) | throw (IO.userError "public generation rejected verified derivation")

private def checkCompositionInputFailure (input : Input) : IO Unit := do
  let altered : Except String Input := do
    let some composition := input.composition | throw "composition required"
    let problem ← composition.getObjVal? "problem"
    let signatures ← (← problem.getObjVal? "signatures").getArr?
    let some first := signatures[0]? | throw "first signature required"
    let some second := signatures[1]? | throw "second signature required"
    let firstIdentity ← (← first.getObjVal? "reference").getObjVal? "identity"
    let secondReference ← second.getObjVal? "reference"
    let second ← replaceMember second "reference"
      (← replaceMember secondReference "identity" firstIdentity)
    let problem ← replaceMember problem "signatures" (.arr (signatures.set! 1 second))
    let derivation ← composition.getObjVal? "derivation"
    let witness ← derivation.getObjVal? "witness"
    let derivation ← replaceMember derivation "witness"
      (← replaceMember witness "input_snapshot" problem)
    let composition ← replaceMember (← replaceMember composition "problem" problem) "derivation" derivation
    pure { input with composition := some composition, basis := basis input.signatures input.entrypoints (some composition) }
  let altered ← match altered with
    | .ok altered => pure altered
    | .error failure => throw (IO.userError ("composition input mutation: " ++ failure))
  let preparationFailure ← match Necoherence.SignatureComposition.verifyInput altered altered.basis with
    | .error (.inr (.inl failure)) => pure failure
    | _ => throw (IO.userError "composition input mutation did not fail during preparation")
  let .unresolvedFunction _ := preparationFailure |
    throw (IO.userError ("composition input mutation returned another preparation failure: " ++
      reprStr preparationFailure))
  match admit altered (ExpectedBasis.ofInput altered) with
  | .error (.compositionInput failure) =>
      if failure != preparationFailure then
        throw (IO.userError "public admission changed composition input failure")
  | _ => throw (IO.userError "public admission did not preserve composition input failure")
  match NecoherenceTools.SignatureComposition.generate altered (ExpectedBasis.ofInput altered) with
  | .error (.admission (.compositionInput failure)) =>
      if failure != preparationFailure then
        throw (IO.userError "composition generation changed composition input failure")
  | _ => throw (IO.userError "composition generation did not preserve composition input failure")

private def checkLibraryCompositionFailure (input : Input) : IO Unit := do
  let some composition := input.composition | throw (IO.userError "composition required")
  let .ok problemJson := composition.getObjVal? "problem" | throw (IO.userError "problem required")
  let .ok (problem, causes) := Necoherence.SignatureComposition.decodeProblem input.signatures problemJson |
    throw (IO.userError "library mutation problem decode")
  let library := { input.signatures with nodes := input.signatures.nodes ++ input.signatures.nodes }
  match Necoherence.SignatureComposition.prepare library input.basis.graphSha256 problem causes with
  | .error (.invalidLibrary (.library failure)) => do
    if failure.predicate != .lb01 then throw (IO.userError "duplicate library declaration predicate")
    if failure.reference != library.identity then throw (IO.userError "duplicate library declaration reference")
  | .error failure => throw (IO.userError ("library declaration failure is not typed: " ++ reprStr failure))
  | .ok _ => throw (IO.userError "duplicate library declaration prepared")

private def checkBindingPairKey : IO Unit := do
  match Necoherence.SignatureCompositionDiagnostics.bindingPairKey (Json.arr #[]) with
  | .error (.syntax "$" "diagnostic binding pair") => pure ()
  | _ => throw (IO.userError "empty binding pair must be a typed syntax failure")
  match Necoherence.SignatureCompositionDiagnostics.bindingPairKey (Json.arr #[.str "port", .bool true]) with
  | .ok "port" => pure ()
  | _ => throw (IO.userError "binding pair key changed")
  match Necoherence.SignatureCompositionDiagnostics.bindingPairKey (Json.arr #[.bool true, .bool false]) with
  | .error (.syntax _ _) => pure ()
  | _ => throw (IO.userError "non-string binding key accepted")

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

private def checkSelectionSum (input : Input) : IO Unit := do
  let some composition := input.composition | throw (IO.userError "composition required")
  let .ok problemJson := composition.getObjVal? "problem" | throw (IO.userError "problem required")
  let .ok (problem, causes) := Necoherence.SignatureComposition.decodeProblem input.signatures problemJson | throw (IO.userError "problem decode")
  let .ok prepared := Necoherence.SignatureComposition.prepare input.signatures input.basis.graphSha256 problem causes | throw (IO.userError "problem preparation")
  let .ok supplied := composition.getObjVal? "derivation" | throw (IO.userError "derivation required")
  let .ok selection := supplied.getObjVal? "selection" | throw (IO.userError "selection required")
  let failure (name : String) (changed : Json) (expected : Sum WireFailure Necoherence.SemanticComposition.WitnessFailure → Bool) : IO Unit := do
    let .ok derivation := replaceMember supplied "selection" changed | throw (IO.userError (name ++ " mutation"))
    match Necoherence.SignatureCompositionWire.decodeDerivation input.signatures problemJson prepared derivation with
    | .error failure => if !expected failure then throw (IO.userError (name ++ " returned another failure"))
    | .ok _ => throw (IO.userError (name ++ " accepted"))
  let extra (json : Json) : Json := json.setObjVal! "extra" (.num 1)
  failure "selection unknown tag" (Json.mkObj [("tag", .str "Bogus")]) fun
    | .inl (.unknownTag _ "Bogus") => true
    | _ => false
  failure "selection unknown tag with extra key" (Json.mkObj [("tag", .str "Bogus"), ("extra", .num 1)]) fun
    | .inl (.unknownTag _ "Bogus") => true
    | _ => false
  failure "selection known tag with extra key" (extra selection) fun
    | .inl (.unknownField _ "extra") => true
    | _ => false
  failure "selection tag missing" (Json.mkObj []) fun
    | .inl (.syntax _ _) => true
    | _ => false
  if let .ok members := selection.getObjVal? "fields" then
    failure "selection fields with extra key" (selection.setObjVal! "fields" (extra members)) fun
      | .inl (.unknownField _ "extra") => true
      | _ => false

private def hasMembers (keys : List String) (json : Json) : Bool :=
  match json.getObj? with
  | .ok object => keys.all fun key => object.contains key
  | .error _ => false

private partial def mutateFirst (selected : Json → Bool) (change : Json → Json) : Json → Option Json
  | json@(.obj object) =>
    if selected json then some (change json)
    else
      let rec go : List (String × Json) → List (String × Json) → Option Json
        | _, [] => none
        | before, (key, child) :: after =>
          match mutateFirst selected change child with
          | some changed => some (Json.mkObj (before.reverse ++ (key, changed) :: after))
          | none => go ((key, child) :: before) after
      go [] object.toList
  | .arr values =>
    match values.toList.findIdx? (fun child => (mutateFirst selected change child).isSome) with
    | some index => (mutateFirst selected change values[index]!).map fun changed => .arr (values.set! index changed)
    | none => none
  | _ => none

private def dropFirstMember (json : Json) : Json :=
  match json.getObj? with
  | .ok object => Json.mkObj (object.toList.drop 1)
  | .error _ => json

private def checkRecordKeys (input : Input) (kinds : List (String × List String)) : IO Unit := do
  let some composition := input.composition | throw (IO.userError "composition required")
  let .ok problemJson := composition.getObjVal? "problem" | throw (IO.userError "problem required")
  let .ok (problem, causes) := Necoherence.SignatureComposition.decodeProblem input.signatures problemJson | throw (IO.userError "problem decode")
  let .ok prepared := Necoherence.SignatureComposition.prepare input.signatures input.basis.graphSha256 problem causes | throw (IO.userError "problem preparation")
  let .ok supplied := composition.getObjVal? "derivation" | throw (IO.userError "derivation required")
  for (name, members) in kinds do
    let variants : List (String × (Json → Json)) := [
      ("extra key", fun json => json.setObjVal! "extra" (.num 1)),
      ("extra key and a missing member", fun json => (dropFirstMember json).setObjVal! "extra" (.num 1))]
    for (variant, change) in variants do
      let scope := if name.startsWith "resource" then "witness" else if name.startsWith "closure" then "selection" else "plan"
      let some part := (supplied.getObjVal? scope).toOption | throw (IO.userError (name ++ " scope missing"))
      let some changed := mutateFirst (hasMembers members) change part |
        throw (IO.userError (name ++ " record not found in the derivation"))
      let some derivation := (replaceMember supplied scope changed).toOption | throw (IO.userError (name ++ " mutation"))
      match Necoherence.SignatureCompositionWire.decodeDerivation input.signatures problemJson prepared derivation with
      | .error (.inl (.unknownField _ "extra")) => pure ()
      | .error failure => throw (IO.userError (name ++ " " ++ variant ++ " returned another failure: " ++ reprStr failure))
      | .ok _ => throw (IO.userError (name ++ " " ++ variant ++ " accepted"))

private def inclusionKinds : List (String × List String) := [
  ("inclusion certificate", ["basis", "source", "destination", "empty_types", "pairs", "root"]),
  ("inclusion pair", ["pair", "source_shape", "destination_shape", "rule", "children"]),
  ("resource certificate", ["trace", "lowering", "correspondence", "reachability", "acyclicity", "value_sources"]),
  ("resource correspondence", ["lots", "values", "normalized_bindings", "execution_order"])]

private def closureKinds : List (String × List String) :=
  inclusionKinds ++ [("closure row", ["state", "terminals", "choices", "rejected_connections", "missing_supply"])]

private def checkDiagnosticSchema : IO Unit := do
  let canonical ← IO.FS.readFile "../../verification/declaration/ncoh-checked-generation-v5.schema.json"
  let .ok json := Necoherence.SignatureJson.parse canonical | throw (IO.userError "canonical schema parse")
  let .ok definitions := (json.getObjVal? "$defs" >>= Json.getObj?) | throw (IO.userError "canonical definitions")
  let .ok saved := ((Necoherence.SignatureJson.parse Necoherence.SignatureCompositionDiagnostics.schemaText).mapError (fun failure => reprStr failure) >>= Json.getObj?) |
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
  let .ok _ := admitWithComposition bounded (ExpectedBasis.ofInput bounded) | throw (IO.userError "valid supplied proof depends on solver completion")
  let .ok _ := NecoherenceTools.SignatureComposition.generate bounded (ExpectedBasis.ofInput bounded) | throw (IO.userError "valid supplied generation depends on solver completion")

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
  let profileText ← IO.FS.readFile "../../verification/presets/atproto-data-model/profile.json"
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

private def withoutAppendedChoice (input : Input) : Except String Input := do
  let some composition := input.composition | throw "composition required"
  let derivation ← composition.getObjVal? "derivation"
  let selection ← derivation.getObjVal? "selection"
  let fields ← selection.getObjVal? "fields"
  let closure ← fields.getObjVal? "closure"
  let states ← (← closure.getObjVal? "states").getArr?
  let some row := states[1]? | throw "second closure state required"
  let choices ← (← row.getObjVal? "choices").getArr?
  if choices.isEmpty then throw "appended choice required"
  let row ← replaceMember row "choices" (.arr choices.pop)
  let closure ← replaceMember closure "states" (.arr (states.set! 1 row))
  let fields ← replaceMember fields "closure" closure
  let selection ← replaceMember selection "fields" fields
  let derivation ← replaceMember derivation "selection" selection
  let composition ← replaceMember composition "derivation" derivation
  pure { input with composition := some composition, basis := basis input.signatures input.entrypoints (some composition) }

private def checkClosureSignatureMismatch : IO Unit := do
  let text ← IO.FS.readFile "../../verification/declaration/signature_admission/examples/rejected-closure-used-site.request.json"
  let .ok request := Necoherence.SignatureJson.parse text | throw (IO.userError "rejected fixture parse")
  let .ok exchange := request.getObjVal? "exchange" >>= Json.getStr? | throw (IO.userError "rejected fixture exchange")
  let input ← match decodeInput exchange with
    | .ok input => pure input
    | .error failure => throw (IO.userError ("rejected fixture decode: " ++ reprStr failure))
  match admitWithComposition input (ExpectedBasis.ofInput input) with
  | .error (.composition (.signatureMismatch site)) =>
    if site.value != "operation" then throw (IO.userError "closure used-site mismatch site")
  | _ => throw (IO.userError "used-site closure invocation not rejected as composition signature mismatch")
  match NecoherenceTools.SignatureComposition.generate input (ExpectedBasis.ofInput input) with
  | .error (.admission (.composition (.signatureMismatch site))) =>
    if site.value != "operation" then throw (IO.userError "closure used-site generation mismatch site")
  | _ => throw (IO.userError "used-site closure invocation not rejected as composition signature mismatch by generation")
  let base ← match withoutAppendedChoice input with
    | .ok base => pure base
    | .error failure => throw (IO.userError ("rejected fixture base: " ++ failure))
  let .ok _ := admitWithComposition base (ExpectedBasis.ofInput base) | throw (IO.userError "closure without the appended choice rejected")
  IO.println "signature_closure_fixture used_site_invocation=signatureMismatch base=accepted"

def runSignatureCompositionWireProperties (input : Input) : IO Unit := do
  checkDiagnosticSchema
  checkRoundtrip input
  checkCompositionInputFailure input
  checkLibraryCompositionFailure input
  checkBindingPairKey
  checkTampering input
  checkSelectionSum input
  checkRecordKeys input inclusionKinds
  checkSearchIndependentAdmission input
  checkSampleBounds input
  checkClosureSignatureMismatch
  let cwd ← IO.currentDir
  let source ← IO.FS.readFile "NecoherenceVerificationTest/SignatureClosureProducer.rs"
  IO.FS.withTempDir fun directory => do
    IO.FS.createDirAll (directory / "src")
    IO.FS.writeFile (directory / "src/main.rs") source
    let manifest := directory / "Cargo.toml"
    IO.FS.writeFile manifest ("[package]\nname = \"ncoh-lean-closure-test\"\nversion = \"0.0.0\"\nedition = \"2021\"\n[dependencies]\nnecoherence = { path = " ++
      (Json.str (cwd.parent.get!.parent.get! / "packages/rust/adapter").toString).compress ++ " }\nnecoherence-composition-solver = { path = " ++ (Json.str (cwd.parent.get!.parent.get! / "solver/composition/rust").toString).compress ++ " }\nserde_json = { version = \"1\", features = [\"arbitrary_precision\", \"preserve_order\"] }\n")
    IO.FS.writeFile (directory / "Cargo.lock") (← IO.FS.readFile "../../verification/declaration/signature_generator/Cargo.lock")
    let unique ← runRust manifest "unique" input
    checkRoundtrip unique
    checkTampering unique
    checkSelectionSum unique
    checkRecordKeys unique closureKinds
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
