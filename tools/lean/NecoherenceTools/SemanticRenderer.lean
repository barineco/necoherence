-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: AGPL-3.0-only

import Necoherence.SemanticCodec

namespace NecoherenceTools.SemanticRenderer

open Necoherence Necoherence.ExactJson Necoherence.SemanticTypes Necoherence.SemanticValidation
open Necoherence.SemanticComposition Necoherence.SemanticCodec

inductive GenerationFailure where
  | missingType (ref : TypeRef)
  | undefinedType (ref : TypeRef) (obligations : List SemanticObligation)
  | invalidInput (failure : CompositionInputFailure)
  | derivation (failure : CompositionEngineFailure)
  | unknown (obligations : List UnresolvedObligation)
  | unreachable
  | ambiguous
  | invalidEntrypoint (condition : String)
  | undefinedDefinition (ref : DefinitionRef) (obligations : List SemanticObligation)
  deriving Repr

abbrev RenderM := Except GenerationFailure

def quote (value : String) : String := reprStr value

def term [Repr α] (value : α) : String := (reprStr value).replace "\n" " "

private def declarationFormat (format : Lean.Format) : String := Id.run do
  let mut output := "\n      "
  let mut quoted := false
  let mut escaped := false
  for character in format.pretty (width := 1000000000) do
    output := output.push character
    if quoted then
      if escaped then escaped := false
      else if character == '\\' then escaped := true
      else if character == '"' then quoted := false
    else if character == '"' then quoted := true
    else if character == '{' || character == '[' || character == ',' then
      output := output ++ "\n      "
  return output

private def declarationTerm [Repr α] (value : α) : String :=
  declarationFormat (repr value)

private def sameFormat : Lean.Format → Lean.Format → Bool
  | .nil, .nil | .line, .line => true
  | .align a, .align b => a == b
  | .text a, .text b => a == b
  | .nest a x, .nest b y => a == b && sameFormat x y
  | .append a b, .append x y => sameFormat a x && sameFormat b y
  | .group a x, .group b y => x == y && sameFormat a b
  | .tag a x, .tag b y => a == b && sameFormat x y
  | _, _ => false

private def shareBasis (basis : Lean.Format) (value : Lean.Format) : Lean.Format :=
  if sameFormat basis value then .text "basis"
  else match value with
    | .nest n f => .nest n (shareBasis basis f)
    | .append a b => .append (shareBasis basis a) (shareBasis basis b)
    | .group f behavior => .group (shareBasis basis f) behavior
    | .tag n f => .tag n (shareBasis basis f)
    | f => f

private def basedTerm [Repr α] (basis : SemanticBasis) (value : α) : String :=
  declarationFormat (shareBasis (repr basis) (repr value))

def nodeIndex (graph : SemanticGraph) (ref : TypeRef) : RenderM Nat :=
  match (graph.nodes.zipIdx).find? (fun (node, _) => node.ref == ref) with
  | some (_, index) => pure index
  | none => .error (.missingType ref)

private def rawName (index : Nat) : String := "Raw" ++ toString index

private def typeName (graph : SemanticGraph) (ref : TypeRef) : RenderM String := do
  pure (rawName (← nodeIndex graph ref))

private def slotType (graph : SemanticGraph) (slot : SlotContract) : RenderM String := do
  let name ← typeName graph slot.typeRef
  pure (if slot.required && !slot.nullable then name
    else if !slot.required && slot.nullable then "(Presence " ++ name ++ ")"
    else "(Option " ++ name ++ ")")

private def slotCodec (slot : SlotContract) : String :=
  if slot.required && !slot.nullable then "Required"
  else if !slot.required && slot.nullable then "Presence"
  else if slot.required then "Nullable" else "Optional"

private def slotEncoder (slot : SlotContract) : String :=
  if slot.required && !slot.nullable then "requiredField"
  else if !slot.required && slot.nullable then "presenceField"
  else if slot.required then "nullableField" else "optionalField"

private def declaration (graph : SemanticGraph) (node : TypeNode) (index : Nat) : RenderM String := do
  let name := rawName index
  let body ← match node.shape with
    | .boolean _ => pure "  | mk (value : Bool)\n"
    | .integer _ => pure "  | mk (value : Int)\n"
    | .decimal _ => pure "  | mk (value : String)\n"
    | .string _ => pure "  | mk (value : String)\n"
    | .bytes _ | .rawBody _ => pure "  | mk (value : Bytes)\n"
    | .sealed _ _ => pure "  | mk (value : JsonValue)\n"
    | .never => pure ""
    | .unknown _ => pure "  | mk (value : JsonValue)\n"
    | .unit => pure "  | mk\n"
    | .alias target _ => do pure ("  | mk (value : " ++ (← typeName graph target) ++ ")\n")
    | .array spec => do
      let item ← typeName graph spec.item.typeRef
      pure ("  | mk (value : List " ++
        (if spec.item.nullable then "(Option " ++ item ++ ")" else item) ++ ")\n")
    | .product spec => do
      let fields ← (spec.fields.zipIdx).mapM fun (field, i) => do
        pure (" (f" ++ toString i ++ " : " ++ (← slotType graph field.slot) ++ ")")
      pure ("  | mk" ++ String.join fields ++ " (extras : List (String × JsonValue))\n")
    | .taggedUnion spec => do
      let branches ← (spec.branches.zipIdx).mapM fun (branch, i) => do
        pure ("  | branch" ++ toString i ++ " (value : " ++ (← typeName graph branch.target) ++ ")\n")
      pure (String.join branches)
    | .opaque _ => .error (.undefinedType node.ref (meaningObligations graph [node.ref]))
  pure ("inductive " ++ name ++ " where\n" ++ body)

private def encoder (graph : SemanticGraph) (node : TypeNode) (index : Nat) (cyclic : Bool) : RenderM String := do
  let name := rawName index
  let head := "  private " ++ (if cyclic then "partial " else "") ++ "def encode" ++ toString index ++ " : " ++ name ++ " → JsonValue\n"
  let body ← match node.shape with
    | .boolean _ => pure "    | .mk value => .bool value\n"
    | .integer _ => pure "    | .mk value => .num value\n"
    | .decimal _ => pure "    | .mk value => .dec value\n"
    | .string _ => pure "    | .mk value => .str value\n"
    | .bytes _ | .rawBody _ => pure "    | .mk value => bytesEncode graph.profile value\n"
    | .sealed _ _ => pure "    | .mk value => value\n"
    | .never => pure "    | value => nomatch value\n"
    | .unknown _ => pure "    | .mk value => value\n"
    | .unit => pure "    | .mk => .null\n"
    | .alias target _ => do pure ("    | .mk value => encode" ++ toString (← nodeIndex graph target) ++ " value\n")
    | .array spec => do
      let encode := "encode" ++ toString (← nodeIndex graph spec.item.typeRef)
      let item := if spec.item.nullable then
        "(fun | none => .null | some item => " ++ encode ++ " item)"
      else encode
      pure ("    | .mk value => .arr (value.map " ++ item ++ ")\n")
    | .product spec => do
      let fields ← (spec.fields.zipIdx).mapM fun (field, i) => do
        pure (slotEncoder field.slot ++ " " ++ quote field.wireName ++ " encode" ++ toString (← nodeIndex graph field.slot.typeRef) ++ " f" ++ toString i)
      let args := String.join ((spec.fields.zipIdx).map fun (_, i) => " f" ++ toString i)
      pure ("    | .mk" ++ args ++ " extras => .obj (" ++ String.intercalate " ++ " (fields ++ ["extras"]) ++ ")\n")
    | .taggedUnion spec => do
      let branches ← (spec.branches.zipIdx).mapM fun (branch, i) => do
        let encoded := "encode" ++ toString (← nodeIndex graph branch.target) ++ " value"
        pure ("    | .branch" ++ toString i ++ " value => " ++ match branch.selector with
          | .internalTag => "withMember ((graph.profile.tag.map (fun (model : TagModel) => model.key)).getD \"\") (.str " ++ quote branch.wireTag ++ ") (" ++ encoded ++ ")\n"
          | _ => encoded ++ "\n")
      pure (String.join branches)
    | .opaque _ => .error (.undefinedType node.ref (meaningObligations graph [node.ref]))
  pure (head ++ body)

private def decoder (graph : SemanticGraph) (node : TypeNode) (index : Nat) (cyclic : Bool) : RenderM String := do
  let head := "  private " ++ (if cyclic then "partial " else "") ++ "def decodeRaw" ++ toString index ++ " : JsonValue → Except ValidationFailure " ++ rawName index ++ "\n"
  let body ← match node.shape with
    | .boolean _ => pure "    | .bool value => pure (.mk value)\n    | _ => invariantFailure \"validated boolean\"\n"
    | .integer _ => pure "    | .num value => pure (.mk value)\n    | _ => invariantFailure \"validated integer\"\n"
    | .decimal _ => pure "    | .dec value => pure (.mk value)\n    | _ => invariantFailure \"validated decimal\"\n"
    | .string _ => pure "    | .str value => pure (.mk value)\n    | _ => invariantFailure \"validated string\"\n"
    | .bytes _ | .rawBody _ => pure "    | value => return .mk (← bytesDecode graph.profile value)\n"
    | .sealed _ _ => pure "    | value => pure (.mk value)\n"
    | .never => pure "    | _ => invariantFailure \"uninhabited type\"\n"
    | .unknown _ => pure "    | value => pure (.mk value)\n"
    | .unit => pure "    | .obj [] => pure .mk\n    | _ => invariantFailure \"validated unit\"\n"
    | .alias target _ => do pure ("    | value => return .mk (← decodeRaw" ++ toString (← nodeIndex graph target) ++ " value)\n")
    | .array spec => do
      let decode := "decodeRaw" ++ toString (← nodeIndex graph spec.item.typeRef)
      let item := if spec.item.nullable then
        "(fun | .null => pure none | value => return some (← " ++ decode ++ " value))"
      else decode
      pure ("    | .arr values => return .mk (← values.mapM " ++ item ++
        ")\n    | _ => invariantFailure \"validated array\"\n")
    | .product spec => do
      let fields ← (spec.fields.zipIdx).mapM fun (field, i) => do
        pure ("      let f" ++ toString i ++ " ← decode" ++ slotCodec field.slot ++ " decodeRaw" ++ toString (← nodeIndex graph field.slot.typeRef) ++ " (fieldValue members " ++ quote field.wireName ++ ")\n")
      let args := String.join ((spec.fields.zipIdx).map fun (_, i) => " f" ++ toString i)
      let names := "[" ++ String.intercalate ", " (spec.fields.map (quote ∘ FieldSpec.wireName)) ++ "]"
      pure ("    | .obj members => do\n" ++ String.join fields ++ "      pure (.mk" ++ args ++ " (members.filter (fun p => !" ++ names ++ ".contains p.1)))\n    | _ => invariantFailure \"validated product\"\n")
    | .taggedUnion spec => do
      let branches ← (spec.branches.zipIdx).mapM fun (branch, i) => do
        pure ("      | some (.str " ++ quote branch.wireTag ++ ") => return .branch" ++ toString i ++ " (← decodeRaw" ++ toString (← nodeIndex graph branch.target) ++ " (.obj members))\n")
      pure ("    | .obj members =>\n      match memberValue ((graph.profile.tag.map (fun (model : TagModel) => model.key)).getD \"\") members with\n" ++ String.join branches ++
        "      | _ => invariantFailure \"validated union discriminator\"\n    | _ => invariantFailure \"validated union object\"\n")
    | .opaque _ => .error (.undefinedType node.ref (meaningObligations graph [node.ref]))
  pure (head ++ body)

private def checkedApi (node : TypeNode) (index : Nat) : String :=
  let n := toString index
  "def ref" ++ n ++ " : TypeRef := " ++ term node.ref ++ "\n" ++
  "abbrev Value" ++ n ++ " := CheckedValue Raw" ++ n ++ " graph ref" ++ n ++ " encode" ++ n ++ "\n" ++
  "def make" ++ n ++ " (value : Raw" ++ n ++ ") : Except ValidationFailure Value" ++ n ++ " := construct graph ref" ++ n ++ " encode" ++ n ++ " value\n" ++
  "def decode" ++ n ++ " (value : Lean.Json) : Except ValidationFailure Value" ++ n ++ " := do\n" ++
  "  let wire := Necoherence.ExactJson.fromJson value\n" ++
  "  let _ ← validateValue graph ref" ++ n ++ " wire\n" ++
  "  let raw ← decodeRaw" ++ n ++ " wire\n" ++
  "  make" ++ n ++ " raw\n" ++
  "def encodeJson" ++ n ++ " (value : Value" ++ n ++ ") : Except String Lean.Json := Necoherence.ExactJson.toJson (encode" ++ n ++ " value.value)\n" ++
  "def decodeDefaulted" ++ n ++ " (value : Lean.Json) : Except ValidationFailure (Value" ++ n ++ " × List DefaultApplication) := do\n" ++
  "  let defaulted ← materializeDefaults graph ref" ++ n ++ " (Necoherence.ExactJson.fromJson value)\n" ++
  "  let raw ← decodeRaw" ++ n ++ " defaulted.value\n" ++
  "  pure (← make" ++ n ++ " raw, defaulted.applications)\n"

private def tupleType (types : List String) : String :=
  if types.isEmpty then "Unit" else "(" ++ String.intercalate " × " types ++ ")"

private def tupleValue (values : List String) : String :=
  if values.isEmpty then "()" else if values.length == 1 then values.head!
  else "(" ++ String.intercalate ", " values ++ ")"

private def executionApi (prepared : PreparedCompositionInput) (checked : CheckedComposition prepared)
    (preparation : String)
    (networkContracts : List (SiteId × String) := []) : RenderM String := do
  let graph := prepared.graph
  let input := prepared.input
  let mut outcomes := ""
  let mut providers := ""
  let mut dispatch := ""
  for (site, index) in input.invocationDomain.sites.zipIdx do
    let some signature := input.signatures.find? (fun s => s.reference == site.function) |
      throw (.invalidInput (.unresolvedFunction site.function))
    let n := toString index
    let inputTypes ← signature.inputs.mapM (fun port => slotType graph port.contract)
    outcomes := outcomes ++ "inductive Outcome" ++ n ++ " where\n"
    for (outcome, arm) in signature.outcomes.zipIdx do
      let fields ← (outcome.valuePorts.zipIdx).mapM fun (port, i) => do
        pure (" (f" ++ toString i ++ " : " ++ (← slotType graph port.contract) ++ ")")
      outcomes := outcomes ++ "  | k" ++ toString arm ++ String.join fields ++ "\n"
    let providerType := if signature.effect == .httpRequestResponse then
      (if networkContracts.any (fun item => item.1 == site.id) then "Necoherence.TypeSignatures.NetworkBinding " else "NetworkBinding ") ++ tupleType inputTypes ++ " Outcome" ++ n
      else tupleType inputTypes ++ " → IO (Except ExecutionFailure Outcome" ++ n ++ ")"
    providers := providers ++ "  call" ++ n ++ " : " ++ providerType ++ "\n"
    dispatch := dispatch ++ "  | " ++ quote site.id.value ++ " => do\n"
    for (port, i) in signature.inputs.zipIdx do
      let p := toString i
      let refIndex ← nodeIndex graph port.contract.typeRef
      dispatch := dispatch ++ "    let some (_, v" ++ p ++ ") := ports.find? (fun p => p.1.value == " ++ quote port.id.value ++ ") | return .error (.invalidPlan \"missing provider input\")\n" ++
        "    let .ok x" ++ p ++ " := decode" ++ slotCodec port.contract ++ " decodeRaw" ++ toString refIndex ++ " v" ++ p ++ " | return .error (.invalidPlan \"provider input representation\")\n"
    let args := tupleValue ((signature.inputs.zipIdx).map fun (_, i) => "x" ++ toString i)
    dispatch := dispatch ++ "    let outcome ← " ++
      (if signature.effect == .httpRequestResponse then
        match networkContracts.find? (fun item => item.1 == site.id) with
        | some (_, contract) => "Necoherence.TypeSignatures.call (" ++ contract ++ ") providers.call" ++ n ++ " " ++ args
        | none => "Necoherence.SemanticNetwork.call providers.call" ++ n ++ " " ++ args
       else "providers.call" ++ n ++ " " ++ args) ++ "\n" ++
      "    pure do\n      let outcome ← outcome\n      match outcome with\n"
    for (outcome, arm) in signature.outcomes.zipIdx do
      let vars := (outcome.valuePorts.zipIdx).map fun (_, i) => "f" ++ toString i
      let values ← (outcome.valuePorts.zipIdx).mapM fun (port, i) => do
        let refIndex ← nodeIndex graph port.contract.typeRef
        pure ("(⟨" ++ quote port.id.value ++ "⟩, fieldValue (" ++ slotEncoder port.contract ++ " " ++ quote port.id.value ++ " encode" ++ toString refIndex ++ " f" ++ toString i ++ ") " ++ quote port.id.value ++ ")")
      dispatch := dispatch ++ "      | .k" ++ toString arm ++ (if vars.isEmpty then "" else " " ++ String.intercalate " " vars) ++
        " => pure { outcome := ⟨" ++ quote outcome.id.value ++ "⟩, outputs := [" ++ String.intercalate ", " values ++ "] }\n"
  let arguments := input.initialInputs.filter fun initial =>
    match initial.source with | .argument => true | _ => false
  let argumentFields ← (arguments.zipIdx).mapM fun (initial, index) => do
    pure ("  argument" ++ toString index ++ " : " ++ (← slotType graph initial.contract) ++ "\n")
  let argumentValues ← (arguments.zipIdx).mapM fun (initial, index) => do
    let refIndex ← nodeIndex graph initial.contract.typeRef
    pure ("(⟨" ++ quote initial.id.value ++ "⟩, fieldValue (" ++ slotEncoder initial.contract ++
      " " ++ quote initial.id.value ++ " encode" ++ toString refIndex ++ " arguments.argument" ++ toString index ++ ") " ++ quote initial.id.value ++ ")")
  let goalTypes ← input.goal.outputs.mapM fun goal => do
    let name := "Value" ++ toString (← nodeIndex graph goal.contract.typeRef)
    pure (if goal.contract.required && !goal.contract.nullable then name
      else if !goal.contract.required && goal.contract.nullable then "(Presence " ++ name ++ ")"
      else "(Option " ++ name ++ ")")
  let mut results := "inductive Result where\n  | success (values : " ++ tupleType goalTypes ++ ")\n"
  let mut terminal := "  | .success outputs => do\n"
  for (goal, index) in input.goal.outputs.zipIdx do
    let refIndex ← nodeIndex graph goal.contract.typeRef
    let n := toString index
    let convert := if goal.contract.required && !goal.contract.nullable then
      "(make" ++ toString refIndex ++ " raw" ++ n ++ ").mapError ExecutionFailure.value"
      else if !goal.contract.required && goal.contract.nullable then
        "presenceMapM (fun value => (make" ++ toString refIndex ++ " value).mapError ExecutionFailure.value) raw" ++ n
      else "raw" ++ n ++ ".mapM (fun value => (make" ++ toString refIndex ++ " value).mapError ExecutionFailure.value)"
    terminal := terminal ++
      "    let some (_, value" ++ n ++ ") := outputs.find? (fun p => p.1.value == " ++ quote goal.id.value ++ ") | throw (.invalidPlan \"goal output missing\")\n" ++
      "    let raw" ++ n ++ " ← (decode" ++ slotCodec goal.contract ++ " decodeRaw" ++ toString refIndex ++ " value" ++ n ++ ").mapError ExecutionFailure.value\n" ++
      "    let checked" ++ n ++ " ← " ++ convert ++ "\n"
  terminal := terminal ++ "    pure (.success " ++ tupleValue ((input.goal.outputs.zipIdx).map fun (_, i) => "checked" ++ toString i) ++ ")\n"
  terminal := terminal ++ "  | .failure embedding value =>\n    match embedding.value with\n"
  for (failure, index) in input.goal.failures.zipIdx do
    let refIndex ← nodeIndex graph failure.contract.typeRef
    let n := toString index
    let valueType := "Value" ++ toString refIndex
    let resultType := if failure.contract.required && !failure.contract.nullable then valueType
      else if !failure.contract.required && failure.contract.nullable then "Presence " ++ valueType
      else "Option " ++ valueType
    let convert := if failure.contract.required && !failure.contract.nullable then
      "(make" ++ toString refIndex ++ " raw).mapError ExecutionFailure.value"
      else if !failure.contract.required && failure.contract.nullable then
        "presenceMapM (fun value => (make" ++ toString refIndex ++ " value).mapError ExecutionFailure.value) raw"
      else "raw.mapM (fun value => (make" ++ toString refIndex ++ " value).mapError ExecutionFailure.value)"
    results := results ++ "  | failure" ++ n ++ " (value : " ++ resultType ++ ")\n"
    terminal := terminal ++
      "    | " ++ quote failure.id.value ++ " => do\n" ++
      "      let raw ← (decode" ++ slotCodec failure.contract ++ " decodeRaw" ++ toString refIndex ++ " value).mapError ExecutionFailure.value\n" ++
      "      let checked ← " ++ convert ++ "\n" ++
      "      pure (.failure" ++ n ++ " checked)\n"
  terminal := terminal ++ "    | _ => throw (.invalidPlan \"failure output missing\")\n"
  pure (outcomes ++ "\nstructure Providers where\n" ++ providers ++
    "\nstructure Arguments where\n" ++ String.join argumentFields ++
    "\n" ++ results ++ "\nprivate def basis : SemanticBasis := {\n" ++
    "  profile := graph.profile\n  sources := " ++ declarationTerm input.basis.sources ++ " }\n" ++
    "\nprivate def problem : CompositionInput := " ++ basedTerm input.basis input ++ "\n" ++
    "\nprivate def selected : RawCompositionCandidate := {\n" ++
    "  plan := " ++ basedTerm input.basis checked.candidate.raw.plan ++ "\n" ++
    "  witness := {\n    inputSnapshot := problem\n" ++
    "    initialMembership := " ++ declarationTerm checked.candidate.raw.witness.initialMembership ++ "\n" ++
    "    resourceTraces := " ++ basedTerm input.basis checked.candidate.raw.witness.resourceTraces ++ " } }\n" ++
    "\nprivate def provider (providers : Providers) : Provider := fun site ports => do\n  match site.id.value with\n" ++
    dispatch ++ "  | _ => pure (.error (.provider site.id \"unknown provider\"))\n" ++
    "\ndef run (providers : Providers) (arguments : Arguments) : IO (Except ExecutionFailure Result) := do\n" ++
    "  let .ok prepared := " ++ preparation ++ " | return .error (.invalidPlan \"generated input preparation\")\n" ++
    "  let .ok checked := verifyCompositionCandidate prepared selected | return .error (.invalidPlan \"generated composition witness\")\n" ++
    "  let result ← Necoherence.SemanticExecution.executeCandidate prepared checked (provider providers) [" ++ String.intercalate ", " argumentValues ++ "]\n" ++
    "  pure do\n    let result ← result\n    match result with\n" ++
    ((terminal.splitOn "\n").map (fun line => "  " ++ line) |> String.intercalate "\n") ++ "\n")

private def typeComponents (edges : Array (List Nat)) : List (List Nat) := Id.run do
  let mut visited := Array.replicate edges.size false
  let mut order : List Nat := []
  for start in List.range edges.size do
    let mut pending := [(start, false)]
    while !pending.isEmpty do
      let (node, exiting) := pending.head!
      pending := pending.tail!
      if exiting then
        order := node :: order
      else if !visited[node]! then
        visited := visited.set! node true
        pending := (edges[node]!.map (fun child => (child, false))) ++ (node, true) :: pending
  let mut reverseEdges := Array.replicate edges.size ([] : List Nat)
  for node in List.range edges.size do
    for child in edges[node]! do
      reverseEdges := reverseEdges.modify child (node :: ·)
  visited := Array.replicate edges.size false
  let mut components : List (List Nat) := []
  for start in order do
    if !visited[start]! then
      let mut component : List Nat := []
      let mut pending := [start]
      while !pending.isEmpty do
        let node := pending.head!
        pending := pending.tail!
        if !visited[node]! then
          visited := visited.set! node true
          component := node :: component
          pending := reverseEdges[node]! ++ pending
      components := component.mergeSort (· ≤ ·) :: components
  return components

private def renderTypeComponent (graph : SemanticGraph) (edges : Array (List Nat))
    (indices : List Nat) : RenderM String := do
  let cyclic := indices.length > 1 || indices.any (fun index => edges[index]!.contains index)
  let nodes ← indices.mapM fun index => do
    let some node := graph.nodes[index]? | throw (.invalidEntrypoint "type component index")
    pure (node, index)
  let declarations ← nodes.mapM fun (node, index) => declaration graph node index
  let encoders ← nodes.mapM fun (node, index) => encoder graph node index cyclic
  let decoders ← nodes.mapM fun (node, index) => decoder graph node index cyclic
  let block := fun (definitions : List String) =>
    if cyclic then "mutual\n" ++ String.join definitions ++ "end\n\n"
    else String.join definitions ++ "\n"
  pure (block declarations ++ block encoders ++ block decoders ++
    String.join (nodes.map fun (node, index) => checkedApi node index))

private def renderGraph (graph : SemanticGraph) (execution : String) : RenderM String := do
  let edges ← graph.nodes.toArray.mapM fun node =>
    (typeChildren node.shape).mapM (nodeIndex graph)
  let components ← (typeComponents edges).mapM (renderTypeComponent graph edges)
  pure ("import Necoherence.SemanticNetwork\n\nnamespace Generated\n\n" ++
    "open Necoherence.ExactJson Necoherence.SemanticTypes Necoherence.SemanticValidation Necoherence.SemanticCodec Necoherence.SemanticComposition Necoherence.SemanticExecution Necoherence.SemanticNetwork\n" ++
    "set_option maxRecDepth 100000\nset_option maxHeartbeats 0\n" ++
    "local instance (α : Type) : Nonempty (Except ValidationFailure α) := ⟨.error (.certificateMismatch \"decoder result\")⟩\n" ++
    "def graph : SemanticGraph := " ++ declarationTerm graph ++ "\n\n" ++
    String.join components ++
    execution ++
    "\nend Generated\n")

def renderDefinitions (graph : SemanticGraph) : RenderM String :=
  renderGraph graph ""

def renderChecked (prepared : PreparedCompositionInput) (checked : CheckedComposition prepared)
    (preparation : String)
    (networkContracts : List (SiteId × String) := []) : RenderM String := do
  renderGraph prepared.graph (← executionApi prepared checked preparation networkContracts)

theorem generatedCompositionSound (prepared : PreparedCompositionInput)
    (checked : CheckedComposition prepared) :
    ∀ branch ∈ planBranches [] checked.candidate.raw.plan.root,
      Nonempty (CheckedResourceTrace prepared branch) :=
  checked.candidate.branches

end NecoherenceTools.SemanticRenderer
