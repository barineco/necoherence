-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SignatureCompositionStateWire

namespace Necoherence.SemanticInvariantDerivation
open Lean Necoherence.SemanticTypes Necoherence.SemanticComposition Necoherence.SemanticValidation Necoherence.SignatureWire Necoherence.SemanticInvariantWire
abbrev Library := Necoherence.TypeSignatures.TypeSignatureLibrary


def declaredShape (library : Library) (ref : TypeRef) : Except WireFailure Necoherence.TypeSignatures.Shape :=
  ((library.nodes.find? (fun node => node.id == ref.definitionName)).map (·.shape)).toExcept "undeclared type"

private def semanticShape (library : Library) (ref : TypeRef) : Except WireFailure TypeShape :=
  ((library.graph.nodes.find? (fun node => node.ref == ref)).map (·.shape)).toExcept "undeclared type"

def inclusionRuleName (shape : TypeShape) : InclusionRule → Except WireFailure String
  | .sameDefinedType => match shape with
    | .boolean _ => pure "Boolean" | .integer _ => pure "IntegerIntersection"
    | .string _ => pure "StringConditions" | .unit => pure "Unit"
    | _ => throw (WireFailure.syntax "$" "construction source requires a primitive inclusion")
  | .emptySource => pure "EmptySource" | .boolean => pure "Boolean"
  | .integerIntersection => pure "IntegerIntersection" | .finiteStrings => pure "FiniteStrings"
  | .stringConditions => pure "StringConditions" | .bytesLength => pure "BytesLength"
  | .unit => pure "Unit"
  | .unfoldSource => pure "UnfoldSource" | .unfoldDestination => pure "UnfoldDestination"
  | .array => pure "Array" | .product => pure "Product" | .sourceUnion => pure "SourceUnion"
  | .destinationUnion => pure "DestinationUnion"

def inclusionRuleDecode (tag : String) : Except WireFailure InclusionRule :=
  match tag with
  | "EmptySource" => pure .emptySource | "Boolean" => pure .boolean
  | "IntegerIntersection" => pure .integerIntersection | "FiniteStrings" => pure .finiteStrings
  | "StringConditions" => pure .stringConditions | "BytesLength" => pure .bytesLength
  | "Unit" => pure .unit
  | "UnfoldSource" => pure .unfoldSource | "UnfoldDestination" => pure .unfoldDestination
  | "Array" => pure .array | "Product" => pure .product | "SourceUnion" => pure .sourceUnion
  | "DestinationUnion" => pure .destinationUnion
  | _ => throw (WireFailure.syntax "$" "unknown inclusion rule")

def inclusionEncode (library : Library) (certificate : InclusionCertificate) : Except WireFailure Json := do
  let pairs ← certificate.pairs.mapM fun entry => do
    pure (Json.mkObj [("pair", encode entry.pair),
      ("source_shape", encode (← declaredShape library entry.pair.source.typeRef)),
      ("destination_shape", encode (← declaredShape library entry.pair.destination.typeRef)),
      ("rule", unitTag (← inclusionRuleName entry.sourceShape entry.rule)), ("children", encode entry.children)])
  pure (Json.mkObj [("basis", encode (Necoherence.SignatureGeneration.basis library [])),
    ("source", encode certificate.source), ("destination", encode certificate.destination),
    ("empty_types", encode certificate.emptyTypes), ("pairs", .arr pairs.toArray), ("root", encode certificate.root)])

def inclusionDecode (library : Library) (json : Json) : Except WireFailure InclusionCertificate := do
  let expected : Necoherence.SignatureGeneration.Basis ← get json "basis"
  if expected != Necoherence.SignatureGeneration.basis library [] then throw (WireFailure.syntax "$" "inclusion basis mismatch")
  let pairs ← (← liftJson ((← liftJson (json.getObjVal? "pairs")).getArr?)).toList.mapM fun row => do
    let pair : TypePair ← get row "pair"
    let source ← declaredShape library pair.source.typeRef
    let destination ← declaredShape library pair.destination.typeRef
    let sourceShape : Necoherence.TypeSignatures.Shape ← get row "source_shape"
    let destinationShape : Necoherence.TypeSignatures.Shape ← get row "destination_shape"
    if sourceShape != source || destinationShape != destination then throw (WireFailure.syntax "$" "inclusion shape mismatch")
    let sourceSemantic ← semanticShape library pair.source.typeRef
    let destinationSemantic ← semanticShape library pair.destination.typeRef
    let tag : String ← get (← liftJson (row.getObjVal? "rule")) "tag"
    let decodedRule ← inclusionRuleDecode tag
    let rule ← if source == destination && decodedRule != .emptySource then do
      if tag != (← inclusionRuleName sourceSemantic .sameDefinedType) then throw (WireFailure.syntax "$" "equal-shape inclusion rule mismatch")
      pure InclusionRule.sameDefinedType
    else pure decodedRule
    pure ({
      pair
      sourceShape := sourceSemantic
      destinationShape := destinationSemantic
      rule
      children := ← get row "children" } : PairEntry)
  pure {
    basis := SemanticBasis.of library.graph
    source := ← get json "source"
    destination := ← get json "destination"
    emptyTypes := ← get json "empty_types"
    pairs
    root := ← get json "root" }

partial def bindingEncode (library : Library) : BindingExpr → Except WireFailure Json
  | .source value projection compatibility => do
    let compatible ← match compatibility with
      | .suppliedValue value => pure (recordTag "SuppliedValue" [("value", encode value)])
      | .inclusion certificate => do pure (tupleTag "Inclusion" (← inclusionEncode library certificate))
    pure (recordTag "Source" [("value", encode value), ("projection", encode projection), ("compatibility", compatible)])
  | .product construction ref fields => do
    let rows ← fields.mapM fun (name, binding) => do pure (.arr #[encode name, ← bindingEncode library binding])
    pure (recordTag "Product" [("construction", encode construction), ("type_id", encode ref), ("fields", .arr rows.toArray)])
partial def bindingDecode (library : Library) (json : Json) : Except WireFailure BindingExpr := do
  let row ← fields json
  match ← get (α := String) json "tag" with
  | "Source" =>
    let compatibility ← liftJson (row.getObjVal? "compatibility")
    let compatible ← match ← get (α := String) compatibility "tag" with
      | "SuppliedValue" => do pure (BindingCompatibility.suppliedValue (← get (← fields compatibility) "value"))
      | "Inclusion" => do pure (BindingCompatibility.inclusion (← inclusionDecode library (← payload compatibility)))
      | _ => throw (WireFailure.syntax "$" "unknown binding compatibility")
    pure (.source (← get row "value") (← get row "projection") compatible)
  | "Product" =>
    let bindings ← (← liftJson ((← liftJson (row.getObjVal? "fields")).getArr?)).toList.mapM fun pair => do
      let pair ← liftJson pair.getArr?
      if pair.size != 2 then throw (WireFailure.syntax "$" "construction field pair size")
      pure (← decode pair[0]!, ← bindingDecode library pair[1]!)
    pure (.product (← get row "construction") (← get row "type_id") bindings)
  | _ => throw (WireFailure.syntax "$" "unknown binding tag")

def returnEncode (library : Library) : ReturnPlan → Except WireFailure Json
  | .success outputs => do
    let rows ← outputs.mapM fun (id, binding) => do pure (.arr #[encode id, ← bindingEncode library binding])
    pure (tupleTag "Success" (.arr rows.toArray))
  | .failure embedding value => do
    pure (recordTag "Failure" [("embedding", encode embedding), ("value", ← bindingEncode library value)])

def returnDecode (library : Library) (json : Json) : Except WireFailure ReturnPlan := do
  if (← get (α := String) json "tag") == "Failure" then
    let row ← fields json
    keys row ["embedding", "value"]
    return .failure (← get row "embedding") (← bindingDecode library (← liftJson (row.getObjVal? "value")))
  if (← get (α := String) json "tag") != "Success" then throw (WireFailure.syntax "$" "unknown return tag")
  let rows ← (← liftJson ((← payload json).getArr?)).toList.mapM fun pair => do
    let pair ← liftJson pair.getArr?
    if pair.size != 2 then throw (WireFailure.syntax "$" "output pair size")
    pure (← decode pair[0]!, ← bindingDecode library pair[1]!)
  pure (.success rows)

def invocationEncode (library : Library) (invocation : InvocationPlan) : Except WireFailure Json := do
  let resources ← invocation.resources.mapM fun binding => do
    pure (Json.mkObj [("requirement", encode binding.requirement), ("lot", encode binding.lot),
      ("inclusion", ← inclusionEncode library binding.inclusion)])
  let bindings ← invocation.bindings.mapM fun (id, binding) => do pure (.arr #[encode id, ← bindingEncode library binding])
  pure (Json.mkObj [("site", encode invocation.site), ("function", encode invocation.function),
    ("bindings", .arr bindings.toArray), ("resources", .arr resources.toArray)])

def invocationDecode (library : Library) (json : Json) : Except WireFailure InvocationPlan := do
  keys json ["site", "function", "bindings", "resources"]
  let resources ← (← liftJson ((← liftJson (json.getObjVal? "resources")).getArr?)).toList.mapM fun row => do
    keys row ["requirement", "lot", "inclusion"]
    pure ({
      requirement := ← get row "requirement"
      lot := ← get row "lot"
      inclusion := ← inclusionDecode library (← liftJson (row.getObjVal? "inclusion")) } : ResourceBinding)
  let bindings ← (← liftJson ((← liftJson (json.getObjVal? "bindings")).getArr?)).toList.mapM fun pair => do
    let pair ← liftJson pair.getArr?
    if pair.size != 2 then throw (WireFailure.syntax "$" "invocation binding pair size")
    pure (← decode pair[0]!, ← bindingDecode library pair[1]!)
  pure { site := ← get json "site", function := ← get json "function", bindings, resources }

partial def treeEncode (library : Library) (tree : PlanTree) : Except WireFailure Json := do
  let node ← match tree with
    | .returnValue _ terminal => do pure (tupleTag "Return" (← returnEncode library terminal))
    | .invoke _ invocation arms empty => do
      let rows ← arms.mapM fun (outcome, child) => do pure (.arr #[encode outcome, ← treeEncode library child])
      pure (recordTag "Invoke" [("invocation", ← invocationEncode library invocation),
        ("arms", .arr rows.toArray), ("empty_outcomes", encode empty)])
    | .guard _ guard inspected arms => do
      let rows ← arms.mapM fun (arm, child) => do pure (.arr #[encode arm, ← treeEncode library child])
      pure (recordTag "Guard" [("guard", encode guard), ("inspected", encode inspected), ("arms", .arr rows.toArray)])
  pure (Json.mkObj [("rank", encode tree.rank), ("node", node)])

partial def treeDecode (library : Library) (json : Json) : Except WireFailure PlanTree := do
  keys json ["rank", "node"]
  let rank ← get json "rank"
  let node ← liftJson (json.getObjVal? "node")
  match ← get (α := String) node "tag" with
  | "Return" => return .returnValue rank (← returnDecode library (← payload node))
  | "Invoke" =>
    let row ← fields node
    keys row ["invocation", "arms", "empty_outcomes"]
    let arms ← (← liftJson ((← liftJson (row.getObjVal? "arms")).getArr?)).toList.mapM fun pair => do
      let pair ← liftJson pair.getArr?
      if pair.size != 2 then throw (WireFailure.syntax "$" "invocation arm pair size")
      pure (← decode pair[0]!, ← treeDecode library pair[1]!)
    pure (.invoke rank (← invocationDecode library (← liftJson (row.getObjVal? "invocation"))) arms (← get row "empty_outcomes"))
  | "Guard" =>
    let row ← fields node
    keys row ["guard", "inspected", "arms"]
    let arms ← (← liftJson ((← liftJson (row.getObjVal? "arms")).getArr?)).toList.mapM fun pair => do
      let pair ← liftJson pair.getArr?
      if pair.size != 2 then throw (WireFailure.syntax "$" "guard arm pair size")
      pure (← decode pair[0]!, ← treeDecode library pair[1]!)
    pure (.guard rank (← get row "guard") (← get row "inspected") arms)
  | _ => throw (WireFailure.syntax "$" "unknown plan node")

def stepEncode (library : Library) : TraceStep → Except WireFailure Json
  | .invocation invocation outcome => do
    pure (recordTag "Invocation" [("invocation", ← invocationEncode library invocation), ("outcome", encode outcome)])
  | .guard guard inspected arm => pure (recordTag "Guard" [("guard", encode guard), ("inspected", encode inspected), ("arm", encode arm)])

def stepDecode (library : Library) (step : Json) : Except WireFailure TraceStep := do
  let row ← fields step
  match ← get (α := String) step "tag" with
  | "Invocation" => pure (TraceStep.invocation (← invocationDecode library (← liftJson (row.getObjVal? "invocation"))) (← get row "outcome"))
  | "Guard" => pure (TraceStep.guard (← get row "guard") (← get row "inspected") (← get row "arm"))
  | _ => throw (WireFailure.syntax "$" "unknown trace step")

def traceEncode (library : Library) (trace : BranchTrace) : Except WireFailure Json := do
  let steps ← trace.steps.mapM (stepEncode library)
  pure (Json.mkObj [("steps", .arr steps.toArray), ("terminal", ← returnEncode library trace.terminal)])

def traceDecode (library : Library) (json : Json) : Except WireFailure BranchTrace := do
  keys json ["steps", "terminal"]
  let steps ← (← liftJson ((← liftJson (json.getObjVal? "steps")).getArr?)).toList.mapM (stepDecode library)
  pure { steps, terminal := ← returnDecode library (← liftJson (json.getObjVal? "terminal")) }

def resourceTypeId (library : Library) (reverse : Bool) : Json → Json
  | .str value => .str ((library.graph.nodes.findSome? fun node =>
      let internal := typeIdentity node.ref
      let id := node.ref.definitionName
      if value == (if reverse then id else internal) then some (if reverse then internal else id) else none).getD value)
  | value => value
partial def resourceTypeIds (library : Library) (reverse : Bool) : Json → Json
  | .arr values => .arr (values.map (resourceTypeIds library reverse))
  | .obj object => Json.mkObj (object.toList.map fun (key, value) =>
      (key, if key == "token_type" then resourceTypeId library reverse value else resourceTypeIds library reverse value))
  | value => value

def resourceEncode (library : Library) (certificate : ResourceTraceCertificate) : Except WireFailure Json := do
  pure (Json.mkObj [("trace", ← traceEncode library certificate.trace),
    ("lowering", resourceTypeIds library false (encode certificate.lowering)),
    ("correspondence", Json.mkObj [("lots", resourceTypeIds library false (encode certificate.correspondence.lots)),
      ("values", encode certificate.correspondence.values),
      ("normalized_bindings", encode certificate.correspondence.normalizedBindings),
      ("execution_order", encode certificate.correspondence.executionOrder)]),
    ("reachability", encode certificate.reachability), ("acyclicity", encode certificate.acyclicity),
    ("value_sources", encode certificate.valueSources)])
def resourceDecode (library : Library) (json : Json) : Except WireFailure ResourceTraceCertificate := do
  let correspondence ← liftJson (json.getObjVal? "correspondence")
  pure {
    trace := ← traceDecode library (← liftJson (json.getObjVal? "trace"))
    lowering := ← decode (resourceTypeIds library true (← liftJson (json.getObjVal? "lowering")))
    correspondence := {
      lots := ← decode (resourceTypeIds library true (← liftJson (correspondence.getObjVal? "lots")))
      values := ← get correspondence "values"
      normalizedBindings := ← get correspondence "normalized_bindings"
      executionOrder := ← get correspondence "execution_order" }
    reachability := ← get json "reachability"
    acyclicity := ← get json "acyclicity"
    valueSources := ← get json "value_sources" }

def derivationEncode (library : Library) (problem : Json) (candidate : RawCompositionCandidate) : Except WireFailure Json := do
  let traces ← candidate.witness.resourceTraces.mapM (resourceEncode library)
  pure (Json.mkObj [("plan", Json.mkObj [("input_identity", encode candidate.plan.inputIdentity),
    ("input_revision", encode candidate.plan.inputRevision), ("root", ← treeEncode library candidate.plan.root)]),
    ("witness", Json.mkObj [("input_snapshot", problem), ("initial_membership", encode candidate.witness.initialMembership),
      ("resource_traces", .arr traces.toArray)]), ("selection", unitTag "AnyFeasible")])

end Necoherence.SemanticInvariantDerivation
